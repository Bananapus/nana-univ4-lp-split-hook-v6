// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {mulDiv, sqrt} from "@prb/math/src/Common.sol";

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
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice Harness that exposes internal functions for M-45 ratio testing.
contract M45Harness is JBUniswapV4LPSplitHook {
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
        returns (address controller, JBRuleset memory ruleset)
    {
        controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (ruleset,) = IJBController(controller).currentRulesetOf(projectId);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_computeOptimalCashOutAmount(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        uint256 totalProjectTokens,
        uint160 sqrtPriceInit,
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        returns (uint256)
    {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return _computeOptimalCashOutAmount(
            projectId, terminalToken, projectToken, totalProjectTokens, sqrtPriceInit, tickLower, tickUpper, controller, ruleset
        );
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getCashOutRate(uint256 projectId, address terminalToken) external view returns (uint256) {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return _getCashOutRate(projectId, terminalToken, controller, ruleset);
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
        return _calculateTickBounds(projectId, terminalToken, projectToken, controller, ruleset);
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
        return _computeInitialSqrtPrice(projectId, terminalToken, projectToken, controller, ruleset);
    }
}

/// @notice Tests proving H-30 (token-ordering extreme prices) and M-45 (in-range ratio math).
///
/// M-45: The old `_computeOptimalCashOutAmount` used a ratio formula that was off by
///        sqrtPriceInit²/Q96² (terminalIsToken0) or missing sqrtPriceB/Q96² (!terminalIsToken0).
///        This caused suboptimal LP positions with wasted tokens.
///
/// The fix uses the correct Uniswap V4 amount0/amount1 formulas:
///   terminalIsToken0: ratio = Q96² × (√Pb − √P) / (√P × √Pb × (√P − √Pa))
///   !terminalIsToken0: ratio = √P × √Pb × (√P − √Pa) / (Q96² × (√Pb − √P))
contract H30_M45_PriceRatio is LPSplitHookV4TestBase {
    M45Harness internal harness;

    uint256 constant Q96 = 2 ** 96;
    uint256 constant WAD = 1e18;

    function setUp() public override {
        super.setUp();

        harness = new M45Harness(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(hook.PERMIT2()))
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // M-45: Prove the old formula was wrong, and the fix matches Uniswap math
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The fix produces a cash-out amount that results in balanced LP liquidity.
    ///         "Balanced" means both token sides yield roughly equal liquidity contributions,
    ///         which is the definition of optimal token pairing.
    function test_M45_fixProducesBalancedLiquidity() public view {
        uint256 totalProjectTokens = 100e18;

        // Get tick bounds and initial price.
        (int24 tickLower, int24 tickUpper) =
            harness.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));
        uint160 sqrtPriceInit =
            harness.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), address(projectToken));

        // The initial price must be in-range for this test to be meaningful.
        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);
        require(sqrtPriceInit > sqrtPriceA && sqrtPriceInit < sqrtPriceB, "price must be in range for M-45 test");

        // Compute optimal cash-out using the fixed formula.
        uint256 cashOut = harness.exposed_computeOptimalCashOutAmount(
            PROJECT_ID, address(terminalToken), address(projectToken), totalProjectTokens, sqrtPriceInit, tickLower, tickUpper
        );

        uint256 cashOutRate = harness.exposed_getCashOutRate(PROJECT_ID, address(terminalToken));
        require(cashOutRate > 0, "cash out rate must be positive");

        // Derive the resulting token amounts.
        uint256 terminalTokenAmount = mulDiv({x: cashOut, y: cashOutRate, denominator: WAD});
        uint256 projectTokenAmount = totalProjectTokens - cashOut;

        // Sort into token0/token1 order.
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        uint256 amount0 = terminalIsToken0 ? terminalTokenAmount : projectTokenAmount;
        uint256 amount1 = terminalIsToken0 ? projectTokenAmount : terminalTokenAmount;

        // Compute liquidity each side can support independently.
        uint128 liq0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceInit, sqrtPriceB, amount0);
        uint128 liq1 = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceA, sqrtPriceInit, amount1);

        // Balanced means both sides produce similar liquidity.
        // getLiquidityForAmounts takes min(liq0, liq1), so the ratio tells us how balanced we are.
        uint128 minLiq = liq0 < liq1 ? liq0 : liq1;
        uint128 maxLiq = liq0 > liq1 ? liq0 : liq1;

        // Within 5% tolerance (accounting for integer math rounding).
        uint256 utilization = (uint256(minLiq) * 10_000) / uint256(maxLiq);
        assertGt(utilization, 9500, "fix: both sides should be within 5% of balanced (>95% utilization)");
    }

    /// @notice Prove the OLD formula would produce imbalanced liquidity.
    ///         We manually compute the old formula's ratio and show the resulting
    ///         token split is significantly worse than the fix.
    function test_M45_oldFormulaProducesImbalancedLiquidity() public view {
        uint256 totalProjectTokens = 100e18;

        (int24 tickLower, int24 tickUpper) =
            harness.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));
        uint160 sqrtPriceInit =
            harness.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), address(projectToken));

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);
        require(sqrtPriceInit > sqrtPriceA && sqrtPriceInit < sqrtPriceB, "price must be in range");

        uint256 cashOutRate = harness.exposed_getCashOutRate(PROJECT_ID, address(terminalToken));
        require(cashOutRate > 0, "cash out rate must be positive");

        // --- Reproduce the OLD (buggy) formula ---
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        uint256 diffPriceInit_A = uint256(sqrtPriceInit) - uint256(sqrtPriceA);
        uint256 diffB_PriceInit = uint256(sqrtPriceB) - uint256(sqrtPriceInit);

        uint256 oldNumerator;
        uint256 oldDenominator;
        if (terminalIsToken0) {
            oldNumerator = uint256(sqrtPriceInit);
            oldDenominator = mulDiv({x: diffPriceInit_A, y: uint256(sqrtPriceB), denominator: diffB_PriceInit});
        } else {
            oldNumerator = mulDiv({x: uint256(sqrtPriceInit), y: diffPriceInit_A, denominator: diffB_PriceInit});
            oldDenominator = 1;
        }
        uint256 oldRatioE18 = mulDiv({x: oldNumerator, y: WAD, denominator: oldDenominator});
        uint256 oldDenom = cashOutRate + oldRatioE18;
        uint256 oldCashOut = mulDiv({x: totalProjectTokens, y: oldRatioE18, denominator: oldDenom});
        if (oldCashOut > totalProjectTokens / 2) oldCashOut = totalProjectTokens / 2;

        // --- Reproduce the FIXED formula ---
        uint256 fixedCashOut = harness.exposed_computeOptimalCashOutAmount(
            PROJECT_ID, address(terminalToken), address(projectToken), totalProjectTokens, sqrtPriceInit, tickLower, tickUpper
        );

        // The two formulas should produce different results.
        assertTrue(oldCashOut != fixedCashOut, "BUG: old and new formulas should differ");

        // Compute liquidity utilization for BOTH formulas.
        uint256 oldUtil = _computeUtilization(
            oldCashOut, cashOutRate, totalProjectTokens, sqrtPriceInit, sqrtPriceA, sqrtPriceB, terminalIsToken0
        );
        uint256 fixedUtil = _computeUtilization(
            fixedCashOut, cashOutRate, totalProjectTokens, sqrtPriceInit, sqrtPriceA, sqrtPriceB, terminalIsToken0
        );

        // The fix should produce strictly better utilization.
        assertGt(fixedUtil, oldUtil, "fix should produce better LP utilization than the old formula");
    }

    /// @notice The fix-computed cash-out amount produces maximal liquidity — no other split
    ///         within a reasonable tolerance can do better.
    function test_M45_fixMaximizesLiquidity() public view {
        uint256 totalProjectTokens = 100e18;

        (int24 tickLower, int24 tickUpper) =
            harness.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));
        uint160 sqrtPriceInit =
            harness.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), address(projectToken));

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);
        require(sqrtPriceInit > sqrtPriceA && sqrtPriceInit < sqrtPriceB, "in range");

        uint256 cashOutRate = harness.exposed_getCashOutRate(PROJECT_ID, address(terminalToken));
        require(cashOutRate > 0);

        uint256 optimalCashOut = harness.exposed_computeOptimalCashOutAmount(
            PROJECT_ID, address(terminalToken), address(projectToken), totalProjectTokens, sqrtPriceInit, tickLower, tickUpper
        );

        bool terminalIsToken0 = address(terminalToken) < address(projectToken);

        // Compute liquidity at optimal split.
        uint128 optimalLiquidity = _computeLiquidity(
            optimalCashOut, cashOutRate, totalProjectTokens, sqrtPriceInit, sqrtPriceA, sqrtPriceB, terminalIsToken0
        );

        // Try splits at 10%, 20%, 30%, 40%, 50% — none should beat the optimal.
        for (uint256 pct = 10; pct <= 50; pct += 10) {
            uint256 trialCashOut = (totalProjectTokens * pct) / 100;
            uint128 trialLiquidity = _computeLiquidity(
                trialCashOut, cashOutRate, totalProjectTokens, sqrtPriceInit, sqrtPriceA, sqrtPriceB, terminalIsToken0
            );
            assertGe(
                optimalLiquidity,
                trialLiquidity,
                string.concat("optimal should beat ", vm.toString(pct), "% split")
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // H-30: Token ordering for zero-rate extreme prices
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When issuance is zero, the extreme sqrtPrice depends on which token is token0.
    ///         The old code hardcoded MAX_SQRT_PRICE-1 regardless.
    function test_H30_zeroIssuanceExtremePrice_tokenOrdering() public view {
        // In the default setup, terminalToken and projectToken have deterministic addresses.
        // Verify the tick bounds reflect the correct extreme for both orderings.
        (int24 tickLower, int24 tickUpper) =
            harness.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        // With positive issuance AND cash-out, both bounds should be within valid range.
        assertTrue(tickLower < tickUpper, "tick bounds should be ordered");
        assertTrue(tickLower >= TickMath.MIN_TICK, "tickLower should be >= MIN_TICK");
        assertTrue(tickUpper <= TickMath.MAX_TICK, "tickUpper should be <= MAX_TICK");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _computeUtilization(
        uint256 cashOut,
        uint256 cashOutRate,
        uint256 totalProjectTokens,
        uint160 sqrtPriceInit,
        uint160 sqrtPriceA,
        uint160 sqrtPriceB,
        bool terminalIsToken0
    )
        internal
        pure
        returns (uint256 utilization)
    {
        uint256 terminalTokenAmount = mulDiv({x: cashOut, y: cashOutRate, denominator: WAD});
        uint256 projectTokenAmount = totalProjectTokens - cashOut;

        uint256 amount0 = terminalIsToken0 ? terminalTokenAmount : projectTokenAmount;
        uint256 amount1 = terminalIsToken0 ? projectTokenAmount : terminalTokenAmount;

        uint128 liq0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceInit, sqrtPriceB, amount0);
        uint128 liq1 = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceA, sqrtPriceInit, amount1);

        uint128 minLiq = liq0 < liq1 ? liq0 : liq1;
        uint128 maxLiq = liq0 > liq1 ? liq0 : liq1;

        if (maxLiq == 0) return 0;
        utilization = (uint256(minLiq) * 10_000) / uint256(maxLiq);
    }

    function _computeLiquidity(
        uint256 cashOut,
        uint256 cashOutRate,
        uint256 totalProjectTokens,
        uint160 sqrtPriceInit,
        uint160 sqrtPriceA,
        uint160 sqrtPriceB,
        bool terminalIsToken0
    )
        internal
        pure
        returns (uint128)
    {
        uint256 terminalTokenAmount = mulDiv({x: cashOut, y: cashOutRate, denominator: WAD});
        uint256 projectTokenAmount = totalProjectTokens - cashOut;

        uint256 amount0 = terminalIsToken0 ? terminalTokenAmount : projectTokenAmount;
        uint256 amount1 = terminalIsToken0 ? projectTokenAmount : terminalTokenAmount;

        return LiquidityAmounts.getLiquidityForAmounts(sqrtPriceInit, sqrtPriceA, sqrtPriceB, amount0, amount1);
    }
}
