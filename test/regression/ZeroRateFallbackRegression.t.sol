// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Harness exposing internal price functions for zero-rate fallback testing.
contract ZeroRateFallbackHarness is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(
            _directory, _permissions, _tokens, _poolManager, _positionManager, _permit2, IHooks(address(0))
        )
    {}

    function _fetchControllerAndRuleset(uint256 projectId)
        internal
        view
        returns (address ctrl, JBRuleset memory ruleset)
    {
        ctrl = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (ruleset,) = IJBController(ctrl).currentRulesetOf(projectId);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getCashOutRateSqrtPriceX96(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        external
        view
        returns (uint160)
    {
        (address ctrl, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return _getCashOutRateSqrtPriceX96(projectId, terminalToken, projectToken, ctrl, ruleset);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getIssuanceRateSqrtPriceX96(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        external
        view
        returns (uint160)
    {
        (address ctrl, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return _getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken, ctrl, ruleset);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_calculateTickBounds(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        external
        view
        returns (int24, int24)
    {
        (address ctrl, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return _calculateTickBounds(projectId, terminalToken, projectToken, ctrl, ruleset);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_computeInitialSqrtPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        external
        view
        returns (uint160)
    {
        (address ctrl, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return _computeInitialSqrtPrice(projectId, terminalToken, projectToken, ctrl, ruleset);
    }
}

/// @notice Tests token-order-aware zero-rate fallback prices.
///
/// Bug: `_getCashOutRateSqrtPriceX96` and `_getIssuanceRateSqrtPriceX96` returned hardcoded
/// extreme sqrtPriceX96 values when rates are zero, without checking which token sorts to
/// `token0`. Since sqrtPriceX96 = sqrt(token1/token0), the correct extreme depends on
/// token ordering. When terminalToken is `token0`, both fallbacks were inverted.
///
/// Fix: Return MAX or MIN based on `token0 == terminalToken` for each function.
///
/// Test strategy: We pass different `projectToken` addresses (one lower, one higher than
/// `terminalToken`) to exercise both sort orderings. The `projectToken` address only affects
/// the `_sortTokens` call — the rate lookup uses `terminalToken` which is wired up in the mock
/// directory.
contract ZeroRateFallbackRegression is LPSplitHookV4TestBase {
    ZeroRateFallbackHarness internal harness;

    // Controlled addresses for testing both token orderings.
    // lowProjectToken < terminalToken → projectToken is token0, terminalToken is token1
    // highProjectToken > terminalToken → terminalToken is token0, projectToken is token1
    address internal lowProjectToken;
    address internal highProjectToken;

    function setUp() public override {
        super.setUp();

        harness = new ZeroRateFallbackHarness(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(hook.PERMIT2()))
        );

        // Choose addresses that sort deterministically relative to terminalToken.
        lowProjectToken = address(uint160(address(terminalToken)) - 1);
        highProjectToken = address(uint160(address(terminalToken)) + 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 1. Cash-out fallback: terminalToken is token0 → returns MAX_SQRT_PRICE - 1
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When cashOutRate=0 and terminalToken < projectToken (terminal is token0),
    ///         sqrtPriceX96 = sqrt(PT/TT). Project token is worthless → ratio → ∞ → MAX.
    function test_cashOutFallback_terminalIsToken0_returnsMax() public {
        store.setSurplus(PROJECT_ID, 0);

        uint160 result =
            harness.exposed_getCashOutRateSqrtPriceX96(PROJECT_ID, address(terminalToken), highProjectToken);

        assertEq(result, TickMath.MAX_SQRT_PRICE - 1, "terminal=token0: cashOut fallback should be MAX");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 2. Cash-out fallback: terminalToken is token1 → returns MIN_SQRT_PRICE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When cashOutRate=0 and terminalToken > projectToken (project is token0),
    ///         sqrtPriceX96 = sqrt(TT/PT). Project token is worthless → ratio → 0 → MIN.
    function test_cashOutFallback_terminalIsToken1_returnsMin() public {
        store.setSurplus(PROJECT_ID, 0);

        uint160 result = harness.exposed_getCashOutRateSqrtPriceX96(PROJECT_ID, address(terminalToken), lowProjectToken);

        assertEq(result, TickMath.MIN_SQRT_PRICE, "terminal=token1: cashOut fallback should be MIN");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 3. Issuance fallback: terminalToken is token0 → returns MIN_SQRT_PRICE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When issuanceRate=0 and terminalToken < projectToken (terminal is token0),
    ///         sqrtPriceX96 = sqrt(PT/TT). No project tokens mintable → ratio → 0 → MIN.
    function test_issuanceFallback_terminalIsToken0_returnsMin() public {
        controller.setReservedPercent(PROJECT_ID, 10_000); // 100% reserved → issuanceRate = 0

        uint160 result =
            harness.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), highProjectToken);

        assertEq(result, TickMath.MIN_SQRT_PRICE, "terminal=token0: issuance fallback should be MIN");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 4. Issuance fallback: terminalToken is token1 → returns MAX_SQRT_PRICE - 1
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When issuanceRate=0 and terminalToken > projectToken (project is token0),
    ///         sqrtPriceX96 = sqrt(TT/PT). No project tokens mintable → ratio → ∞ → MAX.
    function test_issuanceFallback_terminalIsToken1_returnsMax() public {
        controller.setReservedPercent(PROJECT_ID, 10_000);

        uint160 result =
            harness.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), lowProjectToken);

        assertEq(result, TickMath.MAX_SQRT_PRICE - 1, "terminal=token1: issuance fallback should be MAX");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5. Cash-out continuity: fallback matches limit direction as rate → 0+
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice As surplus decreases toward 0, the formula's sqrtPrice monotonically approaches
    ///         the fallback extreme. Verifies the fallback is the correct limit for both orderings.
    function test_cashOutFallback_continuityWithFormula() public {
        // ── Ordering A: terminalToken is token0 ──
        // As cashOutRate decreases, token1Amount = WAD²/rate increases → sqrtPrice increases → MAX
        store.setSurplus(PROJECT_ID, 0.5e18); // normal surplus
        uint160 price_normal_A =
            harness.exposed_getCashOutRateSqrtPriceX96(PROJECT_ID, address(terminalToken), highProjectToken);

        store.setSurplus(PROJECT_ID, 0.001e18); // tiny surplus
        uint160 price_tiny_A =
            harness.exposed_getCashOutRateSqrtPriceX96(PROJECT_ID, address(terminalToken), highProjectToken);

        store.setSurplus(PROJECT_ID, 0); // zero → fallback
        uint160 fallback_A =
            harness.exposed_getCashOutRateSqrtPriceX96(PROJECT_ID, address(terminalToken), highProjectToken);

        // Monotonicity: price increases toward MAX as rate decreases
        assertGt(price_tiny_A, price_normal_A, "A: smaller surplus -> higher sqrtPrice");
        assertEq(fallback_A, TickMath.MAX_SQRT_PRICE - 1, "A: zero surplus -> MAX");
        assertGt(fallback_A, price_tiny_A, "A: fallback >= tiny surplus price");

        // ── Ordering B: terminalToken is token1 ──
        // As cashOutRate decreases, token1Amount = rate decreases → sqrtPrice decreases → MIN
        store.setSurplus(PROJECT_ID, 0.5e18);
        uint160 price_normal_B =
            harness.exposed_getCashOutRateSqrtPriceX96(PROJECT_ID, address(terminalToken), lowProjectToken);

        store.setSurplus(PROJECT_ID, 0.001e18);
        uint160 price_tiny_B =
            harness.exposed_getCashOutRateSqrtPriceX96(PROJECT_ID, address(terminalToken), lowProjectToken);

        store.setSurplus(PROJECT_ID, 0);
        uint160 fallback_B =
            harness.exposed_getCashOutRateSqrtPriceX96(PROJECT_ID, address(terminalToken), lowProjectToken);

        // Monotonicity: price decreases toward MIN as rate decreases
        assertLt(price_tiny_B, price_normal_B, "B: smaller surplus -> lower sqrtPrice");
        assertEq(fallback_B, TickMath.MIN_SQRT_PRICE, "B: zero surplus -> MIN");
        assertLt(fallback_B, price_tiny_B, "B: fallback <= tiny surplus price");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 6. Issuance continuity: fallback matches limit direction as rate → 0+
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice As reserved percent increases toward 100%, the issuance rate approaches 0
    ///         and the sqrtPrice monotonically approaches the fallback extreme.
    function test_issuanceFallback_continuityWithFormula() public {
        // ── Ordering A: terminalToken is token0 ──
        // As issuanceRate decreases, token1Amount = rate decreases → sqrtPrice decreases → MIN
        controller.setReservedPercent(PROJECT_ID, 1000); // 10% reserved (default)
        uint160 price_normal_A =
            harness.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), highProjectToken);

        controller.setReservedPercent(PROJECT_ID, 9900); // 99% reserved → near-zero issuance
        uint160 price_tiny_A =
            harness.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), highProjectToken);

        controller.setReservedPercent(PROJECT_ID, 10_000); // 100% → zero issuance
        uint160 fallback_A =
            harness.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), highProjectToken);

        // Monotonicity: sqrtPrice decreases toward MIN as issuance decreases
        assertLt(price_tiny_A, price_normal_A, "A: less issuance -> lower sqrtPrice");
        assertEq(fallback_A, TickMath.MIN_SQRT_PRICE, "A: zero issuance -> MIN");
        assertLt(fallback_A, price_tiny_A, "A: fallback <= near-zero issuance price");

        // ── Ordering B: terminalToken is token1 ──
        // As issuanceRate decreases, token1Amount = WAD²/rate increases → sqrtPrice increases → MAX
        controller.setReservedPercent(PROJECT_ID, 1000);
        uint160 price_normal_B =
            harness.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), lowProjectToken);

        controller.setReservedPercent(PROJECT_ID, 9900);
        uint160 price_tiny_B =
            harness.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), lowProjectToken);

        controller.setReservedPercent(PROJECT_ID, 10_000);
        uint160 fallback_B =
            harness.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), lowProjectToken);

        // Monotonicity: sqrtPrice increases toward MAX as issuance decreases
        assertGt(price_tiny_B, price_normal_B, "B: less issuance -> higher sqrtPrice");
        assertEq(fallback_B, TickMath.MAX_SQRT_PRICE - 1, "B: zero issuance -> MAX");
        assertGt(fallback_B, price_tiny_B, "B: fallback >= near-zero issuance price");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 7. Tick bounds: zero cashout rate with both orderings → valid ranges
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When cashOutRate=0, _calculateTickBounds centers around the issuance tick.
    ///         Both token orderings should produce valid, non-collapsed ranges within bounds.
    function test_tickBounds_zeroRates_bothOrderings() public {
        store.setSurplus(PROJECT_ID, 0);

        // ── Ordering A: terminalToken is token0 ──
        (int24 tickLower_A, int24 tickUpper_A) =
            harness.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), highProjectToken);
        assertLt(tickLower_A, tickUpper_A, "A: tickLower < tickUpper");
        assertGe(tickLower_A, TickMath.MIN_TICK, "A: tickLower >= MIN_TICK");
        assertLe(tickUpper_A, TickMath.MAX_TICK, "A: tickUpper <= MAX_TICK");
        // Range should span at least 2 * TICK_SPACING (not collapsed)
        assertGe(tickUpper_A - tickLower_A, 2 * int24(200), "A: range >= 2 * TICK_SPACING");

        // ── Ordering B: terminalToken is token1 ──
        (int24 tickLower_B, int24 tickUpper_B) =
            harness.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), lowProjectToken);
        assertLt(tickLower_B, tickUpper_B, "B: tickLower < tickUpper");
        assertGe(tickLower_B, TickMath.MIN_TICK, "B: tickLower >= MIN_TICK");
        assertLe(tickUpper_B, TickMath.MAX_TICK, "B: tickUpper <= MAX_TICK");
        assertGe(tickUpper_B - tickLower_B, 2 * int24(200), "B: range >= 2 * TICK_SPACING");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 8. Initial price: zero cashout rate with both orderings → sane values
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When cashOutRate=0, _computeInitialSqrtPrice falls back to the issuance rate
    ///         sqrtPrice. Both orderings should produce a valid price strictly within (MIN, MAX).
    function test_initialPrice_zeroCashOut_bothOrderings() public {
        store.setSurplus(PROJECT_ID, 0);

        // ── Ordering A: terminalToken is token0 ──
        uint160 initPrice_A =
            harness.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), highProjectToken);
        assertGt(initPrice_A, TickMath.MIN_SQRT_PRICE, "A: initial price > MIN");
        assertLt(initPrice_A, TickMath.MAX_SQRT_PRICE, "A: initial price < MAX");

        // Should equal the issuance rate sqrtPrice (fallback behavior).
        uint160 issuance_A =
            harness.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), highProjectToken);
        assertEq(initPrice_A, issuance_A, "A: initial price == issuance sqrtPrice");

        // ── Ordering B: terminalToken is token1 ──
        uint160 initPrice_B =
            harness.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), lowProjectToken);
        assertGt(initPrice_B, TickMath.MIN_SQRT_PRICE, "B: initial price > MIN");
        assertLt(initPrice_B, TickMath.MAX_SQRT_PRICE, "B: initial price < MAX");

        uint160 issuance_B =
            harness.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), lowProjectToken);
        assertEq(initPrice_B, issuance_B, "B: initial price == issuance sqrtPrice");
    }
}
