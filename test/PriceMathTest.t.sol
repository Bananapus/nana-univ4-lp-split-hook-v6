// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {JBLPSplitHookHelpers} from "../src/libraries/JBLPSplitHookHelpers.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Wrapper that exposes internal price math functions for testing.
contract TestableJBUniswapV4LPSplitHook is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(_directory, _permissions, _tokens, _permit2, IJBSuckerRegistry(address(0)))
    {}

    /// @dev Helper to fetch controller and ruleset for a project.
    function _fetchControllerAndRuleset(uint256 projectId)
        internal
        view
        returns (address controller, JBRuleset memory ruleset)
    {
        controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (ruleset,) = IJBController(controller).currentRulesetOf(projectId);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getIssuanceRate(uint256 projectId, address terminalToken) external view returns (uint256) {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.getIssuanceRate(
            IJBDirectory(DIRECTORY), projectId, terminalToken, controller, ruleset
        );
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getCashOutRate(uint256 projectId, address terminalToken) external view returns (uint256) {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.getCashOutRate(
            IJBDirectory(DIRECTORY), SUCKER_REGISTRY, projectId, terminalToken, controller, ruleset
        );
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
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.getIssuanceRateSqrtPriceX96(
            IJBDirectory(DIRECTORY), projectId, terminalToken, projectToken, controller, ruleset
        );
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
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.getCashOutRateSqrtPriceX96(
            IJBDirectory(DIRECTORY), SUCKER_REGISTRY, projectId, terminalToken, projectToken, controller, ruleset
        );
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
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.calculateTickBounds(
            IJBDirectory(DIRECTORY), SUCKER_REGISTRY, projectId, terminalToken, projectToken, controller, ruleset
        );
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_alignTickToSpacing(int24 tick, int24 spacing) external pure returns (int24) {
        return JBLPSplitHookHelpers.alignTickToSpacing(tick, spacing);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getSqrtPriceX96ForCurrentJuiceboxPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        external
        view
        returns (uint160)
    {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.getSqrtPriceX96ForCurrentJuiceboxPrice(
            IJBDirectory(DIRECTORY), projectId, terminalToken, projectToken, controller, ruleset
        );
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
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.computeInitialSqrtPrice(
            IJBDirectory(DIRECTORY), SUCKER_REGISTRY, projectId, terminalToken, projectToken, controller, ruleset
        );
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_computeOptimalCashOutAmount(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        uint256 totalProjectTokens,
        uint256 preHeldTerminalTokens,
        uint160 sqrtPriceInit,
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        returns (uint256)
    {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.computeOptimalCashOutAmount(
            IJBDirectory(DIRECTORY),
            SUCKER_REGISTRY,
            projectId,
            terminalToken,
            projectToken,
            totalProjectTokens,
            preHeldTerminalTokens,
            sqrtPriceInit,
            tickLower,
            tickUpper,
            controller,
            ruleset
        );
    }
}

/// @notice Tests for JBUniswapV4LPSplitHook internal price math functions.
/// @dev Uses TestableJBUniswapV4LPSplitHook to expose internal view functions.
///
/// Default mock setup (from LPSplitHookV4TestBase):
///   - weight = 1000e18, reservedPercent = 1000 (10%), baseCurrency = 1 (ETH)
///   - accountingContext currency = uint32(uint160(terminalToken)) (not 1)
///   - prices.pricePerUnitOf returns 1e18 by default
///   - store surplus = 0.5e18 per project token
///
/// Therefore:
///   weightRatio = 1e18 (from prices mock, since currencies differ)
///   rawTokensOut(1e18 input) = mulDiv(1e18, 1000e18, 1e18) = 1000e18
///   issuanceRate = 1000e18 * (10000-1000)/10000 = 900e18
///   cashOutRate  = (0.5e18 * 1e18) / 1e18 = 0.5e18
contract PriceMathTest is LPSplitHookV4TestBase {
    TestableJBUniswapV4LPSplitHook public testableHook;

    function setUp() public override {
        super.setUp();
        testableHook = new TestableJBUniswapV4LPSplitHook(
            address(directory), IJBPermissions(address(permissions)), address(jbTokens), IAllowanceTransfer(address(0))
        );
        testableHook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(1)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. Issuance rate with no reserved percent
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When reservedPercent is 0, issuance rate equals the raw conversion (no discount).
    function test_IssuanceRate_NoReserved() public {
        controller.setReservedPercent(PROJECT_ID, 0);

        uint256 rate = testableHook.exposed_getIssuanceRate(PROJECT_ID, address(terminalToken));

        // rawTokensOut = mulDiv(1e18, 1000e18, 1e18) = 1000e18
        // No reserved discount => issuanceRate = 1000e18
        assertEq(rate, 1000e18, "Issuance rate should equal raw conversion when no reserved percent");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Issuance rate with default 10% reserved
    // ─────────────────────────────────────────────────────────────────────

    /// @notice With 10% reserved, issuance rate = rawRate * 90%.
    function test_IssuanceRate_WithReserved() public view {
        uint256 rate = testableHook.exposed_getIssuanceRate(PROJECT_ID, address(terminalToken));

        // rawTokensOut = 1000e18
        // issuanceRate = 1000e18 * (10000 - 1000) / 10000 = 900e18
        assertEq(rate, 900e18, "Issuance rate should be 90% of raw conversion with 10% reserved");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Issuance rate with 100% reserved
    // ─────────────────────────────────────────────────────────────────────

    /// @notice With 100% reserved (10000), all tokens go to reserves so issuance rate = 0.
    ///         Returns 0 instead of reverting, allowing the LP to deploy with max upper range.
    function test_IssuanceRate_MaxReserved() public {
        controller.setReservedPercent(PROJECT_ID, 10_000);

        uint256 rate = testableHook.exposed_getIssuanceRate(PROJECT_ID, address(terminalToken));
        assertEq(rate, 0, "Issuance rate should be 0 with 100% reserved");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Cash out rate with positive surplus
    // ─────────────────────────────────────────────────────────────────────

    /// @notice With surplus = 0.5e18, cash out rate for 1e18 project tokens = 0.5e18.
    function test_CashOutRate_PositiveSurplus() public view {
        uint256 rate = testableHook.exposed_getCashOutRate(PROJECT_ID, address(terminalToken));

        // store returns (0.5e18 * 1e18) / 1e18 = 0.5e18
        assertEq(rate, 0.5e18, "Cash out rate should be 0.5e18 for default surplus");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. Cash out rate with zero surplus
    // ─────────────────────────────────────────────────────────────────────

    /// @notice With surplus = 0, cash out rate should be 0.
    function test_CashOutRate_ZeroSurplus() public {
        store.setSurplus(PROJECT_ID, 0);

        uint256 rate = testableHook.exposed_getCashOutRate(PROJECT_ID, address(terminalToken));

        assertEq(rate, 0, "Cash out rate should be 0 when surplus is 0");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. SqrtPriceX96 is nonzero for valid project
    // ─────────────────────────────────────────────────────────────────────

    /// @notice _getSqrtPriceX96ForCurrentJuiceboxPrice returns a nonzero value for valid project.
    function test_SqrtPriceX96_NonZero() public view {
        uint160 sqrtPrice = testableHook.exposed_getSqrtPriceX96ForCurrentJuiceboxPrice(
            PROJECT_ID, address(terminalToken), address(projectToken)
        );

        assertGt(sqrtPrice, 0, "sqrtPriceX96 should be nonzero for valid project");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. SqrtPriceX96 differs with swapped token order
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Swapping terminalToken and projectToken arguments yields different sqrtPrice.
    function test_SqrtPriceX96_TokenOrdering() public view {
        uint160 sqrtPriceA = testableHook.exposed_getSqrtPriceX96ForCurrentJuiceboxPrice(
            PROJECT_ID, address(terminalToken), address(projectToken)
        );

        // We confirm it is > 2^96 (since there are 1000 projectTokens per terminalToken)
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 Q96 = 2 ** 96;

        // Determine sort order to know which branch is taken
        (address token0,) = _sortTokens(address(terminalToken), address(projectToken));

        if (token0 == address(terminalToken)) {
            // token1Amount = 1000e18, token0Amount = 1e18 => price > 1 => sqrtPrice > Q96
            assertGt(uint256(sqrtPriceA), Q96, "sqrtPrice should exceed Q96 when price > 1");
        } else {
            // token1Amount = getTerminalTokensOut(1e18) = mulDiv(1e18, 1e18, 1000e18) = 1e15
            // price < 1 => sqrtPrice < Q96
            assertLt(uint256(sqrtPriceA), Q96, "sqrtPrice should be below Q96 when price < 1");
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. Issuance rate sqrtPriceX96 is nonzero
    // ─────────────────────────────────────────────────────────────────────

    /// @notice _getIssuanceRateSqrtPriceX96 returns nonzero for valid project.
    function test_IssuanceRateSqrtPriceX96_NonZero() public view {
        uint160 sqrtPrice =
            testableHook.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), address(projectToken));

        assertGt(sqrtPrice, 0, "Issuance rate sqrtPriceX96 should be nonzero");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 9. Cash out rate sqrtPriceX96 is nonzero
    // ─────────────────────────────────────────────────────────────────────

    /// @notice _getCashOutRateSqrtPriceX96 returns nonzero for valid project.
    function test_CashOutRateSqrtPriceX96_NonZero() public view {
        uint160 sqrtPrice =
            testableHook.exposed_getCashOutRateSqrtPriceX96(PROJECT_ID, address(terminalToken), address(projectToken));

        assertGt(sqrtPrice, 0, "Cash out rate sqrtPriceX96 should be nonzero");
    }

    /// @notice _getCashOutRateSqrtPriceX96 clamps high rates into Uniswap's valid sqrt-price range.
    function test_CashOutRateSqrtPriceX96_ClampsHighRate() public {
        address lowerProjectToken = address(1);
        assertLt(uint160(lowerProjectToken), uint160(address(terminalToken)), "precondition: terminal token is token1");

        store.setSurplus(PROJECT_ID, 1e58);

        uint160 sqrtPrice =
            testableHook.exposed_getCashOutRateSqrtPriceX96(PROJECT_ID, address(terminalToken), lowerProjectToken);

        assertEq(sqrtPrice, TickMath.MAX_SQRT_PRICE - 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 10. Tick bounds: tickLower < tickUpper for normal rates
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Under normal conditions (cashOutRate < issuanceRate), tickLower < tickUpper.
    function test_TickBounds_Normal() public view {
        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        assertLt(tickLower, tickUpper, "tickLower should be less than tickUpper under normal rates");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 11. Tick bounds: extreme rate disparity produces wide sorted range
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When the cash out rate is extremely small, its inverse (used for sqrtPrice
    ///         computation) becomes very large, pushing the cash out tick far from the issuance tick.
    ///         After the tick bounds inversion fix, the ticks are sorted so the range is wide (not the narrow
    /// fallback).
    function test_TickBounds_ExtremeRateDisparity_WideRange() public {
        // With token0 = terminalToken (lower address in our mock setup):
        //   issuance sqrtPrice  ~ sqrt(issuanceRate)          where issuanceRate = 900e18
        //   cashOut  sqrtPrice  ~ sqrt(1e36 / cashOutRate)
        // When cashOutRate < 1e36 / 900e18 ~ 1.11e15, the raw ticks are "inverted"
        // (cashOut tick > issuance tick for token0-terminal ordering).
        //
        // Set surplus to 1e12 so cashOutRate = (1e12 * 1e18) / 1e18 = 1e12.
        // That makes cashOut token1Amount = 1e36 / 1e12 = 1e24, far exceeding issuance at 900e18.
        store.setSurplus(PROJECT_ID, 1e12);

        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        // After the tick bounds inversion fix, ticks are sorted so the range is wide (not the narrow fallback).
        assertLt(tickLower, tickUpper, "Sorted ticks should produce tickLower < tickUpper");
        // The range should be much wider than the narrow 2*TICK_SPACING fallback.
        assertGt(tickUpper - tickLower, 2 * int24(200), "Range should be wider than the narrow fallback");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 12. Tick bounds are aligned to TICK_SPACING (200)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Both tick bounds are multiples of TICK_SPACING.
    function test_TickBounds_AlignedToSpacing() public view {
        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        assertEq(tickLower % 200, 0, "tickLower should be aligned to TICK_SPACING (200)");
        assertEq(tickUpper % 200, 0, "tickUpper should be aligned to TICK_SPACING (200)");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 13. Align tick: positive tick floors correctly
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Positive tick 150 floors to 0 (nearest multiple of 200 at or below 150).
    function test_AlignTick_Positive() public view {
        int24 aligned = testableHook.exposed_alignTickToSpacing(150, 200);

        // 150 / 200 = 0 (integer division), 0 * 200 = 0
        assertEq(aligned, 0, "150 should align to 0");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 14. Align tick: negative tick floors correctly (rounds toward -infinity)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Negative tick -150 floors to -200 (proper floor for negative values).
    function test_AlignTick_Negative() public view {
        int24 aligned = testableHook.exposed_alignTickToSpacing(-150, 200);

        // -150 / 200 = 0 in Solidity (rounds toward zero), 0 * 200 = 0
        // Since -150 < 0 and 0 > -150, subtract spacing: 0 - 200 = -200
        assertEq(aligned, -200, "-150 should align to -200");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 15. Fuzz: aligned tick is always a multiple of spacing
    // ─────────────────────────────────────────────────────────────────────

    /// @notice For any valid tick in the Uniswap V4 range, alignment always produces a multiple of 200.
    function testFuzz_AlignTick_AlwaysAligned(int24 tick) public view {
        // Constrain to valid Uniswap V4 tick range
        vm.assume(tick > -887_200 && tick < 887_200);

        int24 aligned = testableHook.exposed_alignTickToSpacing(tick, 200);

        assertEq(aligned % 200, 0, "Aligned tick must always be a multiple of TICK_SPACING");
        // Floor property: aligned <= tick
        assertLe(aligned, tick, "Aligned tick must be <= original tick (floor semantics)");
        // Not too far: aligned + spacing > tick
        assertGt(aligned + 200, tick, "Aligned tick must be within one spacing of original tick");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 16. Geometric mean: initial price is between cash-out and issuance
    // ─────────────────────────────────────────────────────────────────────

    /// @notice _computeInitialSqrtPrice returns a price between cash-out and issuance bounds.
    function test_GeometricMean_BetweenBounds() public view {
        uint160 sqrtPriceInit =
            testableHook.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), address(projectToken));
        uint160 sqrtPriceCashOut =
            testableHook.exposed_getCashOutRateSqrtPriceX96(PROJECT_ID, address(terminalToken), address(projectToken));
        uint160 sqrtPriceIssuance =
            testableHook.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), address(projectToken));

        // Determine which is lower/upper (depends on token ordering)
        uint160 lower = sqrtPriceCashOut < sqrtPriceIssuance ? sqrtPriceCashOut : sqrtPriceIssuance;
        uint160 upper = sqrtPriceCashOut < sqrtPriceIssuance ? sqrtPriceIssuance : sqrtPriceCashOut;

        assertGe(sqrtPriceInit, lower, "Initial price should be >= lower bound");
        assertLe(sqrtPriceInit, upper, "Initial price should be <= upper bound");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 17. Geometric mean: falls back to issuance rate when cash-out is 0
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When cash-out rate is 0, _computeInitialSqrtPrice falls back to issuance rate.
    function test_GeometricMean_FallbackOnZeroCashOut() public {
        store.setSurplus(PROJECT_ID, 0);

        uint160 sqrtPriceInit =
            testableHook.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), address(projectToken));
        uint160 sqrtPriceIssuance =
            testableHook.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), address(projectToken));

        assertEq(sqrtPriceInit, sqrtPriceIssuance, "Should fall back to issuance rate when cash-out is 0");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 18. Optimal cash-out: fraction is less than 50%
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The optimal cash-out amount should be less than 50% of total project tokens.
    function test_OptimalCashOut_LessThanHalf() public view {
        uint256 totalTokens = 100e18;

        // Get tick bounds and initial price
        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));
        uint160 sqrtPriceInit =
            testableHook.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), address(projectToken));

        uint256 cashOut = testableHook.exposed_computeOptimalCashOutAmount(
            PROJECT_ID,
            address(terminalToken),
            address(projectToken),
            totalTokens,
            0,
            sqrtPriceInit,
            tickLower,
            tickUpper
        );

        assertLe(cashOut, totalTokens / 2, "Optimal cash-out should be <= 50% of total");
        assertGt(cashOut, 0, "Optimal cash-out should be > 0 with positive cash-out rate");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 19. Optimal cash-out: returns 0 when cash-out rate is 0
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When cash-out rate is 0, optimal cash-out amount should be 0.
    function test_OptimalCashOut_ZeroWhenNoCashOutRate() public {
        store.setSurplus(PROJECT_ID, 0);

        uint256 totalTokens = 100e18;

        // When cash-out rate is 0, _computeInitialSqrtPrice falls back to issuance rate.
        // _computeOptimalCashOutAmount returns 0 when cash-out rate is 0.
        // We pass issuance-rate sqrtPrice and arbitrary tick bounds since the function
        // short-circuits on cashOutRate == 0.
        uint160 sqrtPriceInit =
            testableHook.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), address(projectToken));

        uint256 cashOut = testableHook.exposed_computeOptimalCashOutAmount(
            PROJECT_ID,
            address(terminalToken),
            address(projectToken),
            totalTokens,
            0,
            sqrtPriceInit,
            int24(-200),
            int24(200)
        );

        assertEq(cashOut, 0, "Cash-out should be 0 when surplus is 0");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 20. Optimal cash-out: scales linearly with total tokens
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Doubling total tokens should approximately double the cash-out amount.
    function test_OptimalCashOut_ScalesWithTotal() public view {
        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));
        uint160 sqrtPriceInit =
            testableHook.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), address(projectToken));

        uint256 cashOut100 = testableHook.exposed_computeOptimalCashOutAmount(
            PROJECT_ID, address(terminalToken), address(projectToken), 100e18, 0, sqrtPriceInit, tickLower, tickUpper
        );
        uint256 cashOut200 = testableHook.exposed_computeOptimalCashOutAmount(
            PROJECT_ID, address(terminalToken), address(projectToken), 200e18, 0, sqrtPriceInit, tickLower, tickUpper
        );

        // Should be ~2x (linear scaling); allow 1 wei tolerance for mulDiv rounding.
        assertApproxEqAbs(cashOut200, cashOut100 * 2, 1, "Cash-out should scale linearly with total tokens");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 21. Optimal cash-out: pre-held terminal tokens reduce the cash-out at the
    //     COMBINED rate H/(r+R), not H/r.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice With pre-held terminal tokens H, the cash-out must be reduced so the position's terminal:project ratio
    ///         is unchanged: (c·r + H)/(T − c) must equal the same ratio R the no-pre-held optimum targets. The old
    ///         logic subtracted H/r (the cash-out rate alone), which over-subtracts because the position also needs
    ///         R terminal per project — the correct offset is H/(r+R). This test pins the post-cash-out ratio.
    function test_OptimalCashOut_PreHeldPreservesPositionRatio() public view {
        uint256 totalTokens = 100e18;
        // Pre-held must be small enough to be fully consumable by the position (H < R·T), so the cashed-out + pre-held
        // terminal side still lands on the target ratio rather than leaving excess terminal as leftover.
        uint256 preHeld = 1e18; // terminal tokens recovered from a (hypothetical) re-range burn

        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));
        uint160 sqrtPriceInit =
            testableHook.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), address(projectToken));
        uint256 r = testableHook.exposed_getCashOutRate(PROJECT_ID, address(terminalToken)); // terminal per project,
        // WAD

        uint256 c0 = testableHook.exposed_computeOptimalCashOutAmount(
            PROJECT_ID,
            address(terminalToken),
            address(projectToken),
            totalTokens,
            0,
            sqrtPriceInit,
            tickLower,
            tickUpper
        );
        uint256 cH = testableHook.exposed_computeOptimalCashOutAmount(
            PROJECT_ID,
            address(terminalToken),
            address(projectToken),
            totalTokens,
            preHeld,
            sqrtPriceInit,
            tickLower,
            tickUpper
        );

        // Pre-held tokens should reduce the cash-out, but by LESS than H/r (the old over-subtraction).
        assertLt(cH, c0, "pre-held should reduce the cash-out");
        uint256 oldBuggyReduction = (preHeld * 1e18) / r; // H/r in project-token terms
        assertLt(c0 - cH, oldBuggyReduction, "reduction must be smaller than the old H/r over-subtraction");

        // The decisive check: the post-cash-out terminal:project ratio is the SAME with and without pre-held — i.e.
        // the
        // pre-held path lands on the position's required ratio R, instead of skewing toward an over-large project side.
        uint256 ratioNoPreHeld = (c0 * r) / (totalTokens - c0);
        uint256 ratioWithPreHeld = ((cH * r) + (preHeld * 1e18)) / (totalTokens - cH);
        assertApproxEqRel(
            ratioWithPreHeld, ratioNoPreHeld, 1e15, "pre-held add must preserve the position's terminal:project ratio"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helper: sort tokens (duplicated from the contract for assertions)
    // ─────────────────────────────────────────────────────────────────────

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
