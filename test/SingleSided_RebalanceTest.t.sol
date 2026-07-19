// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {MockGeomeanOracle} from "./mock/MockGeomeanOracle.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice `rebalanceLiquidity` unifies onto the adaptive `_consolidateAndReMint`: it burns the project's single live
/// position and re-mints ONE adaptive position across a freshly recomputed corridor, anchoring asks to the recovered
/// project principal and seeding the bid side from accrued terminal. Guards: a drift threshold measured on CORRIDOR
/// movement (so a pure terminal inflow can't churn the position) and the spot-vs-TWAP check.
contract SingleSided_RebalanceTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant STRANGER = address(0xBEEF);

    /// @notice Set a realistic corridor, pre-initialize the pool at mid (so the asks-only deploy sits mid-corridor with
    /// room for a bid leg below spot), accumulate, and deploy. Inject `bidAmount` terminal INTO the deployed position
    /// (simulating buyers filling asks and leaving terminal principal behind) so the rebalance's burn recovers it as
    /// the bid — the only legitimate terminal source after the cross-project-capture fix (recovered terminal only).
    function _deploySingleSidedWithBid(uint256 projectAmount, uint256 bidAmount) internal returns (uint256 tokenId) {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});

        (int24 corridorLower, int24 corridorUpper) = _freshCorridor();
        positionManager.initializePool(
            _poolKey(), TickMath.getSqrtPriceAtTick(corridorLower + (corridorUpper - corridorLower) / 2)
        );

        _accumulateTokens(PROJECT_ID, projectAmount);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // The bid capital lives INSIDE the position (recovered on burn), not loose on the hook.
        terminalToken.mint(address(positionManager), bidAmount);
        positionManager.injectPositionBalance(tokenId, address(terminalToken), bidAmount);
        // The PositionManager must hold enough of both tokens to satisfy TAKE_PAIR on burn and SWEEP after mint.
        projectToken.mint(address(positionManager), 1000e18);
        terminalToken.mint(address(positionManager), 1000e18);
    }

    /// @notice Move the project's economic corridor past the drift threshold by dropping the issuance weight ~10% (the
    /// issuance-ceiling tick shifts ~1000 ticks while the cash-out floor stays put and spot stays inside the band).
    function _moveCorridor() internal {
        controller.setWeight(PROJECT_ID, 900e18);
    }

    function _freshCorridor() internal view returns (int24 floorTick, int24 ceilingTick) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (floorTick, ceilingTick) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
    }

    function _spotTick() internal view returns (int24) {
        PoolKey memory key = hook.poolKeyOf(PROJECT_ID, address(terminalToken));
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(key.toId());
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice The project-side and terminal-side amounts locked in a position (ordering-aware).
    function _lockedSides(uint256 tokenId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(tokenId);
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        (projectSide, terminalSide) = terminalIsToken0 ? (amount1Locked, amount0Locked) : (amount0Locked, amount1Locked);
    }

    /// @notice A non-owner permissionlessly rebalances after the corridor has moved. The position re-centers onto the
    /// fresh corridor, anchors asks to the recovered project principal, seeds the bid side from the accrued terminal,
    /// tracks exactly one live position, and emits `PermissionlessRebalanced`.
    ///
    /// The burned position also carries accrued LP trading fees: `_consolidateAndReMint` must call
    /// `_collectAndRouteFees` BEFORE burning so the fee-project cut is taken and only PRINCIPAL is folded into the
    /// re-minted position — trading fees must never be silently compounded into LP.
    function test_Rebalance_Permissionless_ReCentersAndUsesTerminalBid() public {
        uint256 oldTokenId = _deploySingleSidedWithBid({projectAmount: 0.5e18, bidAmount: 1e18});
        _moveCorridor();

        int24 spot = _spotTick();
        (int24 floorTick, int24 ceilingTick) = _freshCorridor();
        assertGt(spot, floorTick, "precondition: spot must sit above the corridor floor");
        assertLt(spot, ceilingTick, "precondition: spot must sit below the corridor ceiling");

        bool terminalIsToken0 = address(terminalToken) < address(projectToken);

        // Accrue a real LP trading fee on the terminal-token side of the live position.
        uint256 accruedFee = 0.2e18;
        if (terminalIsToken0) {
            positionManager.setCollectableFees(oldTokenId, accruedFee, 0);
        } else {
            positionManager.setCollectableFees(oldTokenId, 0, accruedFee);
        }
        terminalToken.mint(address(positionManager), accruedFee);

        uint256 expectedFeeCut = (accruedFee * FEE_PERCENT) / 10_000;
        uint256 expectedRemainder = accruedFee - expectedFeeCut;

        uint256 payCountBefore = terminal.payCallCount();
        uint256 addToBalanceCountBefore = terminal.addToBalanceCallCount();

        // A complete stranger (no permission) triggers the rebalance. The pre-burn fee collection fires first (and
        // routes the fee-project cut), then the rebalance itself. The emitted ticks are the adaptive bounds.
        vm.expectEmit(true, true, false, true, address(hook));
        emit IJBUniswapV4LPSplitHook.LPFeesRouted(
            PROJECT_ID, address(terminalToken), accruedFee, expectedFeeCut, expectedRemainder, expectedFeeCut, STRANGER
        );
        vm.prank(STRANGER);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));

        // The accrued fee was routed BEFORE the burn: fee-project cut via `pay`, remainder into the terminal bid-leg
        // ledger (protocol-owned liquidity), never deposited into the project's treasury.
        assertGt(terminal.payCallCount(), payCountBefore, "the fee-project cut must be paid via terminal.pay");
        assertEq(terminal.lastPayProjectId(), FEE_PROJECT_ID, "the fee cut must be paid to the fee project");
        assertEq(terminal.lastPayAmount(), expectedFeeCut, "the fee cut must be feePercent of the accrued fee");
        assertEq(
            terminal.addToBalanceCallCount(),
            addToBalanceCountBefore,
            "the fee remainder is no longer deposited into the project's treasury"
        );

        // Exactly one live position: the old id is burned, a fresh id is tracked.
        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(newTokenId, oldTokenId, "rebalance must mint a fresh position id");
        assertEq(positionManager.getPositionLiquidity(oldTokenId), 0, "old position must be burned, not orphaned");
        assertGt(positionManager.getPositionLiquidity(newTokenId), 0, "the tracked position must be live");

        // The drift-guard basis is the ranged-against corridor, now the fresh corridor.
        assertEq(hook.rangedCorridorLowerOf(PROJECT_ID, address(terminalToken)), floorTick, "corridor floor recorded");
        assertEq(
            hook.rangedCorridorUpperOf(PROJECT_ID, address(terminalToken)), ceilingTick, "corridor ceiling recorded"
        );

        // Adaptive two-sided re-mint: asks anchored to the recovered 0.5e18 project principal, a nonzero terminal bid
        // seeded by the recovered 1e18 PLUS the non-cut fee remainder (now folded into the bid-leg ledger rather than
        // paid out to the treasury).
        (uint256 projectSide, uint256 terminalSide) = _lockedSides(newTokenId);
        assertEq(projectSide, 0.5e18, "the recovered project tokens must be re-minted as the ask side");
        assertGt(terminalSide, 0, "the accrued terminal must seed a bid side");
        assertLe(
            terminalSide, 1e18 + expectedRemainder, "the bid side never exceeds the recovered terminal plus the ledger"
        );

        assertEq(terminal.cashOutCallCount(), 0, "rebalance must never call cashOutTokensOf");
    }

    /// @notice A rebalance whose freshly recomputed corridor has NOT moved past the drift threshold reverts
    /// `DriftBelowThreshold` — cheap churn is rejected. The deploy already ranges against the full corridor, so a
    /// same-rate rebalance has zero corridor drift.
    function test_Rebalance_RevertsWhenCorridorUnchanged() public {
        _deploySingleSidedWithBid({projectAmount: 0.5e18, bidAmount: 1e18});

        vm.prank(STRANGER);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_DriftBelowThreshold.selector);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));
    }

    /// @notice A pure terminal-only inflow (no rate change) must NOT let a rebalance churn the position: the drift is
    /// measured on corridor movement, not on the adaptive bid bound (which moves with the terminal balance).
    function test_Rebalance_TerminalOnlyInflow_DoesNotChurn() public {
        _deploySingleSidedWithBid({projectAmount: 0.5e18, bidAmount: 1e18});

        // Pile on more terminal (the adaptive bid bound would move) but leave the rates — and thus the corridor —
        // untouched. The rebalance must still be rejected as no-op churn.
        terminalToken.mint(address(hook), 500e18);

        vm.prank(STRANGER);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_DriftBelowThreshold.selector);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));
    }

    /// @notice A rebalance reverts when the pool's spot price has deviated too far from the oracle TWAP. The corridor
    /// is moved first so the drift guard passes and the TWAP guard is the one that fires.
    function test_Rebalance_RevertsWhenSpotDeviatesFromTwap() public {
        _deploySingleSidedWithBid({projectAmount: 0.5e18, bidAmount: 1e18});
        _moveCorridor();

        // Pin a fixed-tick oracle far from the live spot (slot 1 == oracleHook).
        MockGeomeanOracle fixedOracle = new MockGeomeanOracle();
        fixedOracle.setTwapTick(_spotTick() + 1000);
        vm.store(address(hook), bytes32(uint256(1)), bytes32(uint256(uint160(address(fixedOracle)))));

        vm.prank(STRANGER);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_PriceDeviationTooHigh.selector);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));
    }
}
