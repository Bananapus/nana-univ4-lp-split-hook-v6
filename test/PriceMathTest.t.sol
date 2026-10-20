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

/// @notice Wrapper that exposes the internal price math library functions for testing.
/// @dev Standalone rather than inheriting the hook: the wrappers only call `JBUniswapV4LPSplitHookMath` and
/// `JBLPSplitHookHelpers`, and inheriting the full hook would push this test contract past the EIP-170 runtime size
/// checked by `forge build --sizes`.
contract TestableJBUniswapV4LPSplitHook {
    /// @notice The directory the math library reads controllers, terminals and stores from, mirroring the hook's
    /// immutable.
    address public immutable DIRECTORY;

    /// @notice The sucker registry passed to the math library, the zero address because these tests deploy no
    /// registry.
    IJBSuckerRegistry public immutable SUCKER_REGISTRY = IJBSuckerRegistry(address(0));

    /// @notice Stores the directory the wrapped math reads from.
    /// @dev The unnamed permissions, tokens and permit2 parameters keep the hook's constructor shape so callers deploy
    /// this wrapper the same way they deploy the hook; the math never reads them.
    /// @param directory The directory to expose to the math library.
    constructor(address directory, IJBPermissions, address, IAllowanceTransfer) {
        // Record the directory every wrapper reads through `_fetchControllerAndRuleset` and the math library.
        DIRECTORY = directory;
    }

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
}

/// @notice Tests for JBUniswapV4LPSplitHook internal price math functions.
/// @dev Uses TestableJBUniswapV4LPSplitHook to expose internal view functions.
///
/// Default mock setup (from LPSplitHookV4TestBase):
///   - weight = 1000e18, reservedPercent = 1000 (10%), baseCurrency = 1 (ETH)
///   - accountingContext currency = uint32(uint160(terminalToken)) (not 1)
///   - prices.pricePerUnitOf returns 1e18 by default
///   - store surplus = DEFAULT_SURPLUS_PER_TOKEN = 0.0005e18 per project token
///
/// Therefore:
///   weightRatio = 1e18 (from prices mock, since currencies differ)
///   rawTokensOut(1e18 input) = mulDiv(1e18, 1000e18, 1e18) = 1000e18
///   issuanceRate = 1000e18 * (10000-1000)/10000 = 900e18
///   cashOutRate  = (0.0005e18 * 1e18) / 1e18 = 0.0005e18 (below the issuance price 1e18 / 900)
contract PriceMathTest is LPSplitHookV4TestBase {
    TestableJBUniswapV4LPSplitHook public testableHook;

    function setUp() public override {
        super.setUp();
        testableHook = new TestableJBUniswapV4LPSplitHook(
            address(directory), IJBPermissions(address(permissions)), address(jbTokens), IAllowanceTransfer(address(0))
        );
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

    /// @notice With surplus = 0.0005e18, cash out rate for 1e18 project tokens = 0.0005e18.
    function test_CashOutRate_PositiveSurplus() public view {
        uint256 rate = testableHook.exposed_getCashOutRate(PROJECT_ID, address(terminalToken));

        // store returns (0.0005e18 * 1e18) / 1e18 = 0.0005e18
        assertEq(rate, 0.0005e18, "Cash out rate should be 0.0005e18 for default surplus");
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
    // 6. Issuance rate sqrtPriceX96 is nonzero
    // ─────────────────────────────────────────────────────────────────────

    /// @notice _getIssuanceRateSqrtPriceX96 returns nonzero for valid project.
    function test_IssuanceRateSqrtPriceX96_NonZero() public view {
        uint160 sqrtPrice =
            testableHook.exposed_getIssuanceRateSqrtPriceX96(PROJECT_ID, address(terminalToken), address(projectToken));

        assertGt(sqrtPrice, 0, "Issuance rate sqrtPriceX96 should be nonzero");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. Cash out rate sqrtPriceX96 is nonzero
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
    // 8. Tick bounds: tickLower < tickUpper for normal rates
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Under normal conditions (cashOutRate < issuanceRate), tickLower < tickUpper.
    function test_TickBounds_Normal() public view {
        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        assertLt(tickLower, tickUpper, "tickLower should be less than tickUpper under normal rates");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 9. Tick bounds: extreme rate disparity produces wide sorted range
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When the cash out rate is extremely small, its inverse (used for sqrtPrice
    ///         computation) becomes very large, pushing the cash out tick far from the issuance tick.
    ///         The bounds are sorted by price, so the range is wide.
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

        // The bounds are sorted by price, so the range is wide.
        assertLt(tickLower, tickUpper, "Sorted ticks should produce tickLower < tickUpper");
        // The extreme cash-out inverse places the bounds more than two spacings apart.
        assertGt(tickUpper - tickLower, 2 * int24(200), "Range should span more than two spacings");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 10. Tick bounds are aligned to TICK_SPACING (200)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Both tick bounds are multiples of TICK_SPACING.
    function test_TickBounds_AlignedToSpacing() public view {
        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        assertEq(tickLower % 200, 0, "tickLower should be aligned to TICK_SPACING (200)");
        assertEq(tickUpper % 200, 0, "tickUpper should be aligned to TICK_SPACING (200)");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 11. Align tick: positive tick floors correctly
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Positive tick 150 floors to 0 (nearest multiple of 200 at or below 150).
    function test_AlignTick_Positive() public view {
        int24 aligned = testableHook.exposed_alignTickToSpacing(150, 200);

        // 150 / 200 = 0 (integer division), 0 * 200 = 0
        assertEq(aligned, 0, "150 should align to 0");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 12. Align tick: negative tick floors correctly (rounds toward -infinity)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Negative tick -150 floors to -200 (proper floor for negative values).
    function test_AlignTick_Negative() public view {
        int24 aligned = testableHook.exposed_alignTickToSpacing(-150, 200);

        // -150 / 200 = 0 in Solidity (rounds toward zero), 0 * 200 = 0
        // Since -150 < 0 and 0 > -150, subtract spacing: 0 - 200 = -200
        assertEq(aligned, -200, "-150 should align to -200");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 13. Fuzz: aligned tick is always a multiple of spacing
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
    // 14. Geometric mean: initial price is between cash-out and issuance
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
    // 15. Geometric mean: falls back to issuance rate when cash-out is 0
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When cash-out rate is 0, the cold-start seed sits strictly inside the economic corridor (one aligned
    /// spacing off the floor), NOT on the issuance ceiling — so the hook never rejects its own zero-cash-out pool.
    function test_GeometricMean_FallbackOnZeroCashOut() public {
        store.setSurplus(PROJECT_ID, 0);

        uint160 sqrtPriceInit =
            testableHook.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), address(projectToken));
        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        int24 seedTick = TickMath.getTickAtSqrtPrice(sqrtPriceInit);
        assertGt(seedTick, tickLower, "zero cash-out seed sits strictly inside the corridor floor");
        assertLt(seedTick, tickUpper, "zero cash-out seed sits strictly below the issuance ceiling");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helper: sort tokens (duplicated from the contract for assertions)
    // ─────────────────────────────────────────────────────────────────────

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
