// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TwoPositionFixture} from "./TwoPositionFixture.sol";
import {DEFAULT_SURPLUS_PER_TOKEN} from "../TestBaseV4.sol";
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

    /// @notice When set, `addToBalanceOf` reverts, so a project's LP-fee remainder falls back to its terminal ledger.
    bool public rejectAddToBalance;

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

    /// @notice Sets whether `addToBalanceOf` reverts.
    /// @param value True to make every `addToBalanceOf` call revert.
    function setRejectAddToBalance(bool value) external {
        // Read by `addToBalanceOf` on every deposit.
        rejectAddToBalance = value;
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

    /// @notice This terminal's surplus for a project, which is always zero.
    /// @dev Matches IJBTerminal.currentSurplusOf: this terminal holds no surplus for any project.
    /// @return surplus Always zero.
    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure returns (uint256 surplus) {
        // The terminal keeps no balance the cash-out floor could count.
        return 0;
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
        // A rejected deposit makes the hook keep the remainder in the project's terminal ledger.
        require(!rejectAddToBalance, "ADD_TO_BALANCE_REJECTED");
        if (token != address(0x000000000000000000000000000000000000EEEe) && amount > 0) {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }
    }
}

/// @notice Regression coverage for the fee-claim isolation invariant: a project must never be able to consume
/// another project's (or its own) reserved fee-claim balance as LP principal.
/// @dev `deployPool` and `addLiquidity` make no cash-out call, so no terminal can inflate a reported reclaim to drain
/// another project's reserved fee tokens through them. The invariant this regression protects: `_recycle` sizes the ask
/// only from the project's own `accumulatedProjectTokens` ledger and the bid only from its own
/// `accumulatedTerminalTokens` ledger
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
        store.setSurplus({projectId: PROJECT_B, surplus: DEFAULT_SURPLUS_PER_TOKEN});

        // Project B is paired with the SAME terminal token (feeProjectToken) that project A's reserved fee claim
        // will be denominated in — the scenario where cross-project bleed-through would matter.
        pullingTerminal.setAccountingContext(
            PROJECT_B, address(feeProjectToken), uint32(uint160(address(feeProjectToken))), 18
        );
        _setDirectoryTerminal(PROJECT_B, address(feeProjectToken), address(pullingTerminal));
        _addDirectoryTerminal(PROJECT_B, address(pullingTerminal));
        store.setBalance(address(pullingTerminal), PROJECT_B, address(feeProjectToken), 100e18);
    }

    /// @notice Neither another project's deploy nor the claiming project's own two-sided recycle spends a reserved
    /// fee-token claim held in the same token as the pools' terminal side, and the full reserve stays claimable.
    function test_projectBDeployCannotConsumeProjectAsReservedFeeClaim() public {
        // A's terminal rejects deposits, so A's terminal-side fee remainders fall back to A's terminal ledger: the
        // hook then holds a ledger and a reserved claim in the same token, the case this regression isolates.
        pullingTerminal.setRejectAddToBalance(true);

        // 1. Project A distributes reserved tokens and deploys its pool, paired with feeProjectToken as the
        // terminal token.
        projectToken.mint({to: address(controller), amount: 100e18});

        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: 100e18});
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: PROJECT_ID, token: address(projectToken), amount: 100e18, groupId: 1})
        );
        vm.stopPrank();

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // 2. Project A's LP position accrues fees, which are collected and routed — reserving a claimable
        // fee-token balance for project A.
        uint256 tokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(feeProjectToken)});
        bool feeTokenIsToken0 = address(feeProjectToken) < address(projectToken);

        // Accrue the fees on the fee-token side, which depends on the pool's currency order.
        if (feeTokenIsToken0) {
            positionManager.setCollectableFees({tokenId: tokenId, amount0: 100e18, amount1: 0});
        } else {
            positionManager.setCollectableFees({tokenId: tokenId, amount0: 0, amount1: 100e18});
        }
        feeProjectToken.mint({to: address(positionManager), amount: 100e18});

        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: address(feeProjectToken)});

        uint256 claimableFeeTokens = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimableFeeTokens, 0, "precondition: project A should have claimable fee tokens");
        // The terminal token here IS the fee-project token, and A's terminal rejected the remainder, so the non-cut
        // remainder is carried into project A's terminal ledger. The hook therefore holds A's reserved fee claim PLUS
        // A's terminal ledger.
        uint256 ledgerA =
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(feeProjectToken)});
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
        feeProjectToken.mint({to: address(hook), amount: freeBalance});

        // 4. Project B accumulates its own tokens and deploys a pool paired with the SAME terminal token that
        // project A's reserved claim is denominated in.
        projectTokenB.mint({to: address(controller), amount: 100e18});

        vm.startPrank(address(controller));
        projectTokenB.approve({spender: address(hook), amount: 100e18});
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: PROJECT_B, token: address(projectTokenB), amount: 100e18, groupId: 1})
        );
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
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(feeProjectToken)}),
            ledgerA,
            "project A's terminal ledger is untouched by project B's deployment"
        );

        // 6. Project A recycles two-sided: buyers fill part of its ask (moving the spot into the ask range), its ask
        // accrues more fees, and a new reserved distribution arrives. The recycle routes those fees (growing the
        // reserve), burns the ask, and re-mints an ask plus a bid denominated in feeProjectToken. The bid may spend
        // only A's terminal ledger, never the reserve sitting in the same token.
        (PoolKey memory key, int24 askLower, int24 askUpper,,,,) = positionManager._positions(tokenId);
        // Move the spot to the ask's midpoint, rounded to a tick the pool's spacing allows.
        int24 spotTick = (askLower + askUpper) / 2 / key.tickSpacing * key.tickSpacing;
        // Pack slot0 (fee, tick, sqrt price) and write it straight into the pool's state slot.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 packed = bytes32(
            (uint256(key.fee) << 208) | (uint256(uint24(spotTick)) << 160)
                | uint256(TickMath.getSqrtPriceAtTick(spotTick))
        );
        poolManager.writeSlot({
            slot: keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6)))), value: packed
        });
        // The fill left the ask holding exactly what its liquidity holds at the new spot.
        _markToSpot(tokenId);
        // Accrue more fees on the ask's fee-token side and fund the PositionManager to pay them.
        if (feeTokenIsToken0) {
            positionManager.setCollectableFees({tokenId: tokenId, amount0: 20e18, amount1: 0});
        } else {
            positionManager.setCollectableFees({tokenId: tokenId, amount0: 0, amount1: 20e18});
        }
        feeProjectToken.mint({to: address(positionManager), amount: 20e18});

        // A new reserved distribution gives the recycle fresh project tokens to place.
        projectToken.mint({to: address(controller), amount: 10e18});
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: 10e18});
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: PROJECT_ID, token: address(projectToken), amount: 10e18, groupId: 1})
        );
        vm.stopPrank();

        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(feeProjectToken)});

        // The recycle grew A's reserve, minted a bid, and left the reserve and both ledgers backed by the hook's
        // balance.
        uint256 claimableAfterRecycle = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimableAfterRecycle, claimableFeeTokens, "the recycle's fee collection grew A's reserve");
        assertNotEq(
            hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(feeProjectToken)}),
            0,
            "A's recycle minted a bid"
        );
        assertGe(
            feeProjectToken.balanceOf(address(hook)),
            claimableAfterRecycle
                + hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(feeProjectToken)})
                + hook.accumulatedTerminalTokens({projectId: PROJECT_B, terminalToken: address(feeProjectToken)}),
            "A's recycle must not consume the reserved fee claim as LP principal"
        );

        // 7. Project A can still claim its FULL reserved balance afterward — proving the reserve was never
        // partially (or fully) consumed by project B's mint or by A's own recycle.
        vm.prank(owner);
        hook.claimFeeTokensFor({projectId: PROJECT_ID, beneficiary: user});
        assertEq(
            feeProjectToken.balanceOf(user),
            claimableAfterRecycle,
            "project A can still claim its full fee-token reserve"
        );
    }
}
