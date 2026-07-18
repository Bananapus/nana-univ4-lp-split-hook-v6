// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PullingFeeTerminal {
    address public storeAddress;

    mapping(uint256 projectId => mapping(address token => JBAccountingContext)) public contexts;
    mapping(uint256 projectId => JBAccountingContext[]) internal _contextsList;
    mapping(uint256 projectId => address token) public projectTokens;

    function setStore(address store) external {
        storeAddress = store;
    }

    function setProjectToken(uint256 projectId, address token) external {
        projectTokens[projectId] = token;
    }

    function setAccountingContext(uint256 projectId, address token, uint32 currency, uint8 decimals) external {
        JBAccountingContext memory ctx = JBAccountingContext({token: token, decimals: decimals, currency: currency});
        contexts[projectId][token] = ctx;
        _contextsList[projectId].push(ctx);
    }

    function STORE() external view returns (address) {
        return storeAddress;
    }

    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        returns (JBAccountingContext memory)
    {
        return contexts[projectId][token];
    }

    function accountingContextsOf(uint256 projectId) external view returns (JBAccountingContext[] memory) {
        return _contextsList[projectId];
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 beneficiaryTokenCount)
    {
        if (token != address(0x000000000000000000000000000000000000EEEe) && amount > 0) {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }

        beneficiaryTokenCount = amount;

        address projectToken = projectTokens[projectId];
        if (projectToken != address(0) && beneficiaryTokenCount > 0) {
            MockERC20(projectToken).mint(beneficiary, beneficiaryTokenCount);
        }
    }

    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        if (token != address(0x000000000000000000000000000000000000EEEe) && amount > 0) {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }
    }
}

/// @notice Regression coverage for the fee-claim isolation invariant: a project must never be able to consume
/// another project's reserved fee-claim balance.
/// @dev The single-sided redesign removed the funding cash-out entirely, so the ORIGINAL attack vector here (an
/// `OverreportingCashOutTerminal` inflating a reported cash-out reclaim to drain another project's reserved fee
/// tokens) no longer exists — there is no cash-out call anywhere in `deployPool`/`addLiquidity`/`rebalanceLiquidity`
/// to overreport through. The underlying invariant this regression protects still matters, though:
/// `_consolidateAndReMint` sizes every mint's terminal-token side from `_spendableTerminalTokenBalance`, which must
/// always exclude
/// `_totalOutstandingFeeTokenClaims` — otherwise one project's deploy/add could size its LP mint using ERC-20 balance
/// that is actually owed to a DIFFERENT project's fee-token claim. This test re-expresses that invariant directly
/// against the current consolidate + fee-routing flow, with a non-trivial "free" balance sitting alongside the
/// reserved claim so the exclusion boundary is actually exercised (not a trivial all-reserved case).
contract FeeClaimReserveCaptureRegression is LPSplitHookV4TestBase {
    uint256 internal constant PROJECT_B = 3;

    PullingFeeTerminal internal pullingTerminal;
    MockERC20 internal projectTokenB;

    function setUp() public override {
        super.setUp();

        pullingTerminal = new PullingFeeTerminal();
        pullingTerminal.setStore(address(store));
        pullingTerminal.setProjectToken(PROJECT_ID, address(projectToken));
        pullingTerminal.setProjectToken(FEE_PROJECT_ID, address(feeProjectToken));
        pullingTerminal.setAccountingContext(
            PROJECT_ID, address(feeProjectToken), uint32(uint160(address(feeProjectToken))), 18
        );
        pullingTerminal.setAccountingContext(
            FEE_PROJECT_ID, address(feeProjectToken), uint32(uint160(address(feeProjectToken))), 18
        );

        _setDirectoryTerminal(PROJECT_ID, address(feeProjectToken), address(pullingTerminal));
        _setDirectoryTerminal(FEE_PROJECT_ID, address(feeProjectToken), address(pullingTerminal));
        _addDirectoryTerminal(PROJECT_ID, address(pullingTerminal));
        _addDirectoryTerminal(FEE_PROJECT_ID, address(pullingTerminal));

        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 0);
        store.setBalance(address(pullingTerminal), PROJECT_ID, address(feeProjectToken), 100e18);

        projectTokenB = new MockERC20("Project B", "PRJB", 18);
        jbTokens.setToken(PROJECT_B, address(projectTokenB));
        jbProjects.setOwner(PROJECT_B, owner);
        _setDirectoryController(PROJECT_B, address(controller));
        controller.setWeight(PROJECT_B, DEFAULT_WEIGHT);
        controller.setFirstWeight(PROJECT_B, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(PROJECT_B, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(PROJECT_B, 1);
        store.setSurplus(PROJECT_B, 0.5e18);

        // Project B is paired with the SAME terminal token (feeProjectToken) that project A's reserved fee claim
        // will be denominated in — the scenario where cross-project bleed-through would matter.
        pullingTerminal.setAccountingContext(
            PROJECT_B, address(feeProjectToken), uint32(uint160(address(feeProjectToken))), 18
        );
        _setDirectoryTerminal(PROJECT_B, address(feeProjectToken), address(pullingTerminal));
        _addDirectoryTerminal(PROJECT_B, address(pullingTerminal));
        store.setBalance(address(pullingTerminal), PROJECT_B, address(feeProjectToken), 100e18);
    }

    function test_projectBDeployCannotConsumeProjectAsReservedFeeClaim() public {
        // 1. Project A distributes reserved tokens and deploys its pool, paired with feeProjectToken as the
        // terminal token.
        projectToken.mint(address(controller), 100e18);

        vm.startPrank(address(controller));
        projectToken.approve(address(hook), 100e18);
        hook.processSplitWith(_buildContext(PROJECT_ID, address(projectToken), 100e18, 1));
        vm.stopPrank();

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // 2. Project A's LP position accrues fees, which are collected and routed — reserving a claimable
        // fee-token balance for project A.
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(feeProjectToken));
        bool feeTokenIsToken0 = address(feeProjectToken) < address(projectToken);

        if (feeTokenIsToken0) {
            positionManager.setCollectableFees(tokenId, 100e18, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, 100e18);
        }
        feeProjectToken.mint(address(positionManager), 100e18);

        hook.collectAndRouteLPFees(PROJECT_ID, address(feeProjectToken));

        uint256 claimableFeeTokens = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimableFeeTokens, 0, "precondition: project A should have claimable fee tokens");
        assertEq(
            feeProjectToken.balanceOf(address(hook)),
            claimableFeeTokens,
            "hook should currently hold exactly project A's reserved fee tokens"
        );

        // 3. Fund the hook with SOME independent, non-reserved feeProjectToken balance (e.g. dust unrelated to
        // project A's claim) so the isolation boundary is actually exercised, rather than testing a trivial
        // all-reserved-nothing-free case.
        uint256 freeBalance = 50e18;
        feeProjectToken.mint(address(hook), freeBalance);

        // 4. Project B accumulates its own tokens and deploys a pool paired with the SAME terminal token that
        // project A's reserved claim is denominated in.
        projectTokenB.mint(address(controller), 100e18);

        vm.startPrank(address(controller));
        projectTokenB.approve(address(hook), 100e18);
        hook.processSplitWith(_buildContext(PROJECT_B, address(projectTokenB), 100e18, 1));
        vm.stopPrank();

        vm.prank(owner);
        hook.deployPool(PROJECT_B);

        // 5. The core invariant: project B's deployment must never touch project A's reserved fee-token balance.
        // `_spendableTerminalTokenBalance` must always exclude `_totalOutstandingFeeTokenClaims`, so the hook must
        // still hold at least project A's full claimable amount after project B's mint.
        assertGe(
            feeProjectToken.balanceOf(address(hook)),
            claimableFeeTokens,
            "project B's deployment must not consume project A's reserved fee-claim balance"
        );

        // 6. Project A can still claim its FULL reserved balance afterward — proving the reserve was never
        // partially (or fully) consumed by project B's mint.
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);
        assertEq(
            feeProjectToken.balanceOf(user), claimableFeeTokens, "project A can still claim its full fee-token reserve"
        );
    }
}
