// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice Exposes the internal adaptive-range solver so the bid-depth math can be tested directly. Post cross-project
/// fix, `deployPool` is asks-only (no hook-held terminal is ever paired); the adaptive bid is exercised only when a
/// burn recovers this project's own terminal principal. The solver itself is unchanged and pure, so testing it
/// directly is the faithful way to cover bid-depth-vs-terminal-size behavior.
contract AdaptiveBidExposedHook is JBUniswapV4LPSplitHook {
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IAllowanceTransfer permit2,
        IJBSuckerRegistry suckerRegistry
    )
        JBUniswapV4LPSplitHook(directory, permissions, tokens, permit2, suckerRegistry)
    {}

    function exposed_adaptiveRange(
        bool projectIsToken0,
        int24 corridorLower,
        int24 corridorUpper,
        uint160 sqrtSpotX96,
        uint256 projectAmount,
        uint256 terminalAmount
    )
        external
        pure
        returns (int24 tickLower, int24 tickUpper, uint256 bidAmountForMint)
    {
        return _adaptiveRange({
            projectIsToken0: projectIsToken0,
            corridorLower: corridorLower,
            corridorUpper: corridorUpper,
            sqrtSpotX96: sqrtSpotX96,
            projectAmount: projectAmount,
            terminalAmount: terminalAmount
        });
    }
}

/// @notice Adaptive bid-depth coverage for `deployPool`: the single minted position always deploys the ENTIRE project
/// balance as asks up to the issuance ceiling, and the bid bound moves with the hook's held terminal balance —
/// asks-only at `T = 0`, a shallow bid close to spot for small `T`, a deeper bid for larger `T`, and pinned at the
/// cash-out floor (with the excess terminal routed to the project balance, never stranded) when `T` is abundant. The
/// default harness ordering is terminal = token0 (project = token1); a sibling test forces the mirror ordering.
contract SingleSided_AdaptiveBidTest is LPSplitHookV4TestBase {
    /// @notice Project tokens deployed as asks. Sized so the full bid leg's terminal capacity (`maxBid`, which scales
    /// with this) comfortably exceeds the "small"/"larger" terminal sizes below, keeping them in the solve regime.
    uint256 internal constant PROJECT_AMOUNT = 10e18;

    int24 internal _corridorLower;
    int24 internal _corridorUpper;
    int24 internal _spotTick;
    int24 internal _ceilingEcon;
    int24 internal _floorEcon;

    AdaptiveBidExposedHook internal _solver;

    /// @notice The adaptive `[tickLower, tickUpper]` and paired bid for the current corridor/spot at a given terminal
    /// size, resolved via the pure solver, plus the ordering-derived ask-anchor and bid-bound ticks.
    function _solveRange(uint256 projectAmount, uint256 terminalAmount)
        internal
        returns (int24 askAnchorTick, int24 bidBoundTick, uint256 bidAmountForMint)
    {
        if (address(_solver) == address(0)) {
            _solver = new AdaptiveBidExposedHook(
                address(directory),
                IJBPermissions(address(permissions)),
                address(jbTokens),
                IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3),
                IJBSuckerRegistry(address(0))
            );
        }
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        (int24 tickLower, int24 tickUpper, uint256 bid) = _solver.exposed_adaptiveRange({
            projectIsToken0: projectIsToken0,
            corridorLower: _corridorLower,
            corridorUpper: _corridorUpper,
            sqrtSpotX96: TickMath.getSqrtPriceAtTick(_spotTick),
            projectAmount: projectAmount,
            terminalAmount: terminalAmount
        });
        (askAnchorTick, bidBoundTick) = projectIsToken0 ? (tickUpper, tickLower) : (tickLower, tickUpper);
        bidAmountForMint = bid;
    }

    /// @notice Set a realistic corridor, pre-initialize the pool at mid-corridor, and fund the PositionManager. Records
    /// the corridor bounds and the economic floor/ceiling (ordering-aware) for the tests.
    function _prepareCorridorAndPool() internal {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});

        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (_corridorLower, _corridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
        assertLt(_corridorLower, _corridorUpper, "precondition: corridor must be non-degenerate");

        // The issuance ceiling is the corridor's UPPER tick when the project is token0, its LOWER tick otherwise; the
        // cash-out floor is the opposite bound.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        (_ceilingEcon, _floorEcon) =
            projectIsToken0 ? (_corridorUpper, _corridorLower) : (_corridorLower, _corridorUpper);

        _spotTick = _corridorLower + (_corridorUpper - _corridorLower) / 2;
        positionManager.initializePool(_poolKey(), TickMath.getSqrtPriceAtTick(_spotTick));
        // No PositionManager pre-funding: a pure deploy has no BURN/TAKE_PAIR, so the mint's SETTLE provides exactly
        // what the position needs and SWEEP returns nothing. Pre-funding would be swept back to the hook and mis-read
        // as stranded terminal.
    }

    /// @notice Seed the hook with `terminalHeld` bid capital, accumulate `projectAmount`, and permissionlessly deploy.
    function _seedAndDeploy(uint256 projectAmount, uint256 terminalHeld) internal returns (uint256 tokenId) {
        if (terminalHeld > 0) terminalToken.mint(address(hook), terminalHeld);
        _accumulateTokens(PROJECT_ID, projectAmount);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
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

    /// @notice The active position's ask-anchor tick (issuance-ceiling side) and bid-bound tick (adaptive side),
    /// resolved for the live ordering.
    function _askAndBidTicks() internal view returns (int24 askAnchorTick, int24 bidBoundTick) {
        int24 lower = hook.activeTickLowerOf(PROJECT_ID, address(terminalToken));
        int24 upper = hook.activeTickUpperOf(PROJECT_ID, address(terminalToken));
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        (askAnchorTick, bidBoundTick) = projectIsToken0 ? (upper, lower) : (lower, upper);
    }

    /// @notice The (project side, terminal side) token amounts locked in the position, resolved for the live ordering.
    function _lockedSides(uint256 tokenId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(tokenId);
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        (projectSide, terminalSide) = terminalIsToken0 ? (amount1Locked, amount0Locked) : (amount0Locked, amount1Locked);
    }

    function _absDiff(int24 a, int24 b) internal pure returns (int24) {
        return a >= b ? a - b : b - a;
    }

    /// @notice The terminal capacity of the FULL bid leg ([floor, spot] or [spot, floor]) at the liquidity the ask leg
    /// anchors from `PROJECT_AMOUNT`. Mirrors the contract's sizing so tests can pick terminal amounts as fractions of
    /// capacity: a fraction below 1 stays in the "solve" regime (a real, unpinned bid), a fraction above 1 is abundant
    /// (pinned at the floor with routed excess).
    function _maxBidCapacity() internal view returns (uint256 maxBid) {
        uint160 sqrtSpot = TickMath.getSqrtPriceAtTick(_spotTick);
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        if (projectIsToken0) {
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0({
                sqrtPriceAX96: sqrtSpot,
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_corridorUpper),
                amount0: PROJECT_AMOUNT
            });
            maxBid = SqrtPriceMath.getAmount1Delta({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_corridorLower),
                sqrtPriceBX96: sqrtSpot,
                liquidity: liquidity,
                roundUp: false
            });
        } else {
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_corridorLower),
                sqrtPriceBX96: sqrtSpot,
                amount1: PROJECT_AMOUNT
            });
            maxBid = SqrtPriceMath.getAmount0Delta({
                sqrtPriceAX96: sqrtSpot,
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_corridorUpper),
                liquidity: liquidity,
                roundUp: false
            });
        }
    }

    // ─── T = 0: asks-only, no bid
    // ───────────────────────────────────────────────────────────────

    function test_Deploy_ZeroTerminal_AsksOnly() public {
        _prepareCorridorAndPool();
        uint256 tokenId = _seedAndDeploy({projectAmount: PROJECT_AMOUNT, terminalHeld: 0});

        (int24 askAnchorTick, int24 bidBoundTick) = _askAndBidTicks();
        (uint256 projectSide, uint256 terminalSide) = _lockedSides(tokenId);

        assertEq(askAnchorTick, _ceilingEcon, "asks must anchor to the issuance ceiling");
        assertEq(projectSide, PROJECT_AMOUNT, "the full project balance must deploy as asks");
        assertEq(terminalSide, 0, "no terminal held: the position is asks-only");

        // With no terminal, the bid bound collapses onto the live spot (no bid leg).
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        if (projectIsToken0) {
            assertGe(bidBoundTick, _spotTick, "asks-only: bid bound sits at/above spot (no bid leg)");
        } else {
            assertLe(bidBoundTick, _spotTick, "asks-only: bid bound sits at/below spot (no bid leg)");
        }
    }

    // ─── Small T: shallow bid close to spot
    // ─────────────────────────────────────────────────────

    function test_Deploy_SmallTerminal_ShallowBidCloseToSpot() public {
        _prepareCorridorAndPool();
        // A small fraction of the bid-leg capacity: enough to register a bid at least one tick-spacing deep, but far
        // from filling the leg — so the bid bound stays close to spot.
        uint256 smallTerminal = _maxBidCapacity() / 8;
        (, int24 bidBoundTick, uint256 bidPaired) = _solveRange(PROJECT_AMOUNT, smallTerminal);

        assertEq(bidPaired, smallTerminal, "a scarce terminal is fully paired (not floor-pinned)");
        assertTrue(bidBoundTick != _floorEcon, "a small terminal must NOT pin the bid at the floor");

        // The bid bound sits strictly between the live spot and the cash-out floor — a genuine, shallow bid.
        int24 depthFromSpot = _absDiff(bidBoundTick, _spotTick);
        int24 spanToFloor = _absDiff(_floorEcon, _spotTick);
        assertGt(depthFromSpot, 0, "the bid bound must move off the spot");
        assertLt(depthFromSpot, spanToFloor / 2, "a shallow bid stays much closer to spot than to the floor");
    }

    // ─── Larger T: deeper bid toward the floor
    // ──────────────────────────────────────────────────

    function test_Deploy_LargerTerminal_DeeperBid() public {
        _prepareCorridorAndPool();
        uint256 capacity = _maxBidCapacity();

        (, int24 bidSmall,) = _solveRange(PROJECT_AMOUNT, capacity / 8);
        int24 depthSmall = _absDiff(bidSmall, _spotTick);

        (, int24 bidLarge,) = _solveRange(PROJECT_AMOUNT, capacity / 2);
        int24 depthLarge = _absDiff(bidLarge, _spotTick);

        assertGt(depthLarge, depthSmall, "a larger terminal must push the bid bound deeper toward the floor");
        assertTrue(bidLarge != _floorEcon, "the larger (but not abundant) terminal must NOT pin at the floor");
    }

    // ─── Abundant T: pinned at the floor, excess left over (routed to the project balance by the caller)
    // ────────

    function test_Deploy_AbundantTerminal_PinnedAtFloor_ExcessRouted() public {
        _prepareCorridorAndPool();
        uint256 terminalHeld = 1000e18;
        (, int24 bidBoundTick, uint256 bidPaired) = _solveRange(PROJECT_AMOUNT, terminalHeld);

        assertEq(bidBoundTick, _floorEcon, "an abundant terminal pins the bid bound at the cash-out floor");
        assertGt(bidPaired, 0, "the floor-depth bid still pairs terminal into the position");
        assertLt(bidPaired, terminalHeld, "the abundant terminal exceeds the floor-leg capacity");
        // The excess (terminal beyond the floor-leg capacity) is NOT paired into the mint; the caller carries it to the
        // project's terminal balance as a leftover (covered by the consolidation/leftover tests), never stranded.
        assertGt(terminalHeld - bidPaired, 0, "a non-zero excess must be left over");
    }

    // ─── Asks are NEVER starved, across the whole terminal-size spectrum
    // ─────────────────────────

    function test_Deploy_AsksAlwaysFullyDeployed_AcrossTerminalSizes() public {
        _prepareCorridorAndPool();
        uint256 snap = vm.snapshotState();

        uint256[4] memory terminalSizes = [uint256(0), 0.02e18, 0.5e18, 1000e18];
        for (uint256 i; i < terminalSizes.length; i++) {
            vm.revertToState(snap);
            uint256 tokenId = _seedAndDeploy({projectAmount: PROJECT_AMOUNT, terminalHeld: terminalSizes[i]});
            (int24 askAnchorTick,) = _askAndBidTicks();
            (uint256 projectSide,) = _lockedSides(tokenId);
            assertEq(askAnchorTick, _ceilingEcon, "asks always reach the issuance ceiling");
            assertEq(projectSide, PROJECT_AMOUNT, "the entire project balance is always deployed as asks");
        }
    }
}
