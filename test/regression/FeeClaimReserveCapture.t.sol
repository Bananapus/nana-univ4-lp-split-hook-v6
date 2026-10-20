// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TwoPositionFixture} from "./TwoPositionFixture.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

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
/// another project's (or its own) reserved fee-claim balance as LP principal.
/// @dev The single-sided redesign removed the funding cash-out entirely, so the ORIGINAL attack vector here (an
/// `OverreportingCashOutTerminal` inflating a reported cash-out reclaim to drain another project's reserved fee
/// tokens) no longer exists: there is no cash-out call anywhere in `deployPool`/`addLiquidity` to overreport through.
/// The underlying invariant this regression protects still matters, though: `_recycle` sizes the ask only from the
/// project's own `accumulatedProjectTokens` ledger and the bid only from its own `accumulatedTerminalTokens` ledger
/// (recovered principal and fee remainders included), never from the hook's raw ERC-20 balance. Even when the shared
/// clone's balance holds a reserved fee-token claim (and a terminal ledger, and unrelated free balance) in the very
/// token a project's bid is denominated in, a deploy or recycle cannot spend any of the reserve. This test exercises
/// that boundary with a reserved fee claim, a per-project terminal ledger, and a non-trivial "free" balance all
/// sitting on the shared clone, across another project's deploy and the claiming project's own two-sided recycle.
contract FeeClaimReserveCaptureRegression is TwoPositionFixture {
    using PoolIdLibrary for PoolKey;

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
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildContext(PROJECT_ID, address(projectToken), 100e18, 1));
        vm.stopPrank();

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // 2. Project A's LP position accrues fees, which are collected and routed — reserving a claimable
        // fee-token balance for project A.
        uint256 tokenId = hook.askTokenIdOf(PROJECT_ID, address(feeProjectToken));
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
        // The terminal token here IS the fee-project token, so the non-cut remainder is carried into project A's
        // terminal ledger. The hook therefore holds A's reserved fee claim PLUS A's terminal ledger.
        uint256 ledgerA = hook.accumulatedTerminalTokens(PROJECT_ID, address(feeProjectToken));
        assertGt(ledgerA, 0, "precondition: project A's terminal ledger holds the fee remainder");
        assertEq(
            feeProjectToken.balanceOf(address(hook)),
            claimableFeeTokens + ledgerA,
            "hook holds exactly project A's reserved fee claim plus A's terminal ledger"
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
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildContext(PROJECT_B, address(projectTokenB), 100e18, 1));
        vm.stopPrank();

        vm.prank(owner);
        hook.deployPool(PROJECT_B);

        // 5. The core invariant: project B's deployment must never touch project A's reserved fee-token balance NOR
        // project A's terminal ledger. B sizes its mint only from its own recovered terminal (0 on a first deploy) and
        // its own ledger (0), so it consumes none of the shared-clone balance.
        assertGe(
            feeProjectToken.balanceOf(address(hook)),
            claimableFeeTokens + ledgerA,
            "project B's deployment must not consume project A's reserved fee claim or terminal ledger"
        );
        assertEq(
            hook.accumulatedTerminalTokens(PROJECT_ID, address(feeProjectToken)),
            ledgerA,
            "project A's terminal ledger is untouched by project B's deployment"
        );

        // 6. Project A recycles two-sided: buyers fill part of its ask (moving the spot into the ask range), its ask
        // accrues more fees, and a new reserved distribution arrives. The recycle routes those fees (growing the
        // reserve), burns the ask, and re-mints an ask plus a bid denominated in feeProjectToken. The bid may spend
        // only A's terminal ledger, never the reserve sitting in the same token.
        (PoolKey memory key, int24 askLower, int24 askUpper,,,,) = positionManager._positions(tokenId);
        int24 spotTick = (askLower + askUpper) / 2 / key.tickSpacing * key.tickSpacing;
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 packed = bytes32(
            (uint256(key.fee) << 208) | (uint256(uint24(spotTick)) << 160)
                | uint256(TickMath.getSqrtPriceAtTick(spotTick))
        );
        poolManager.writeSlot(keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6)))), packed);
        // The fill left the ask holding exactly what its liquidity holds at the new spot.
        _markToSpot(tokenId);
        if (feeTokenIsToken0) {
            positionManager.setCollectableFees(tokenId, 20e18, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, 20e18);
        }
        feeProjectToken.mint(address(positionManager), 20e18);

        projectToken.mint(address(controller), 10e18);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), 10e18);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildContext(PROJECT_ID, address(projectToken), 10e18, 1));
        vm.stopPrank();

        hook.addLiquidity(PROJECT_ID, address(feeProjectToken));

        uint256 claimableAfterRecycle = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimableAfterRecycle, claimableFeeTokens, "the recycle's fee collection grew A's reserve");
        assertNotEq(hook.bidTokenIdOf(PROJECT_ID, address(feeProjectToken)), 0, "A's recycle minted a bid");
        assertGe(
            feeProjectToken.balanceOf(address(hook)),
            claimableAfterRecycle + hook.accumulatedTerminalTokens(PROJECT_ID, address(feeProjectToken))
                + hook.accumulatedTerminalTokens(PROJECT_B, address(feeProjectToken)),
            "A's recycle must not consume the reserved fee claim as LP principal"
        );

        // 7. Project A can still claim its FULL reserved balance afterward — proving the reserve was never
        // partially (or fully) consumed by project B's mint or by A's own recycle.
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);
        assertEq(
            feeProjectToken.balanceOf(user),
            claimableAfterRecycle,
            "project A can still claim its full fee-token reserve"
        );
    }
}
