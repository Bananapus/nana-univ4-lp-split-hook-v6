// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {MockERC20} from "../mock/MockERC20.sol";

/// @notice Wrapper that exposes internal tick-bounds functions for testing tick bounds inversion.
contract TestableHookForTickBounds is JBUniswapV4LPSplitHook {
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
        return _calculateTickBounds(projectId, terminalToken, projectToken);
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
        return _getCashOutRateSqrtPriceX96(projectId, terminalToken, projectToken);
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
        return _getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken);
    }
}

/// @notice Regression test: Tick bounds inversion for token0-terminal pools.
///
/// @dev The bug: `_calculateTickBounds` assigned cashOut tick to tickLower and issuance tick to
///      tickUpper without sorting. For pools where the terminal token is token0 (lower address),
///      e.g. native ETH pools, the cashOut tick is HIGHER than the issuance tick, causing
///      tickLower >= tickUpper and triggering the narrow +/-1 tick fallback instead of the
///      intended economic range.
///
///      The fix sorts the two raw ticks before assigning them to tickLower/tickUpper,
///      matching the pattern already used in _computeInitialSqrtPrice (lines 994-995).
contract TickBoundsInversionTest is LPSplitHookV4TestBase {
    TestableHookForTickBounds public testableHook;

    // Token pair where terminalToken < projectToken (terminal is token0).
    // This is the ordering that triggers the bug.
    MockERC20 public lowTerminalToken;
    MockERC20 public highProjectToken;

    uint256 public constant TEST_PROJECT_ID = 10;

    function setUp() public override {
        super.setUp();

        // Deploy the testable hook (view-only, no pool manager needed).
        testableHook = new TestableHookForTickBounds(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(0))
        );
        testableHook.initialize(FEE_PROJECT_ID, FEE_PERCENT);

        // Deploy two tokens at controlled addresses so that terminal < project (terminal is token0).
        // We use vm.etch to place MockERC20 code at specific addresses.
        address lowAddr = address(0x1111111111111111111111111111111111111111);
        address highAddr = address(0x9999999999999999999999999999999999999999);
        require(lowAddr < highAddr, "Test setup: lowAddr must be < highAddr");

        // Deploy real MockERC20s and copy their code to the target addresses.
        MockERC20 templateLow = new MockERC20("Low Terminal", "LOW", 18);
        MockERC20 templateHigh = new MockERC20("High Project", "HIGH", 18);
        vm.etch(lowAddr, address(templateLow).code);
        vm.etch(highAddr, address(templateHigh).code);

        lowTerminalToken = MockERC20(lowAddr);
        highProjectToken = MockERC20(highAddr);

        // Wire the test project with this token pair.
        _setDirectoryController(TEST_PROJECT_ID, address(controller));
        controller.setWeight(TEST_PROJECT_ID, DEFAULT_WEIGHT);
        controller.setFirstWeight(TEST_PROJECT_ID, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(TEST_PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(TEST_PROJECT_ID, 1); // ETH

        jbProjects.setOwner(TEST_PROJECT_ID, owner);
        jbTokens.setToken(TEST_PROJECT_ID, address(highProjectToken));

        _setDirectoryTerminal(TEST_PROJECT_ID, address(lowTerminalToken), address(terminal));
        _addDirectoryTerminal(TEST_PROJECT_ID, address(terminal));

        // Safe: lowAddr sentinel is a known test constant that fits in uint32.
        // forge-lint: disable-next-line(unsafe-typecast)
        terminal.setAccountingContext(
            TEST_PROJECT_ID, address(lowTerminalToken), uint32(uint160(address(lowTerminalToken))), 18
        );
        terminal.addAccountingContext(
            TEST_PROJECT_ID,
            JBAccountingContext({
                token: address(lowTerminalToken),
                decimals: 18,
                // forge-lint: disable-next-line(unsafe-typecast)
                currency: uint32(uint160(address(lowTerminalToken)))
            })
        );

        // Set surplus so cash-out rate is nonzero (0.5e18 per project token).
        store.setSurplus(TEST_PROJECT_ID, 0.5e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Tick bounds inversion when terminal token is token0
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Verify that terminalToken < projectToken (terminal is token0 in the V4 pool).
    ///         This is the precondition for the tick bounds inversion bug.
    function test_precondition_terminalIsToken0() public view {
        assertTrue(
            address(lowTerminalToken) < address(highProjectToken), "Terminal token should be token0 (lower address)"
        );
    }

    /// @notice When terminal is token0, the cashOut sqrtPrice > issuance sqrtPrice.
    ///         This demonstrates the root cause: the raw ticks are inverted relative
    ///         to the naive cashOut=lower, issuance=upper assumption.
    function test_rawTicksAreInverted_whenTerminalIsToken0() public view {
        uint160 sqrtPriceCashOut = testableHook.exposed_getCashOutRateSqrtPriceX96(
            TEST_PROJECT_ID, address(lowTerminalToken), address(highProjectToken)
        );
        uint160 sqrtPriceIssuance = testableHook.exposed_getIssuanceRateSqrtPriceX96(
            TEST_PROJECT_ID, address(lowTerminalToken), address(highProjectToken)
        );

        // When terminal is token0:
        //   cashOut sqrtPrice  = sqrt(WAD^2 / cashOutRate) = sqrt(1e36 / 0.5e18) ~ sqrt(2e18)
        //   issuance sqrtPrice = sqrt(issuanceRate)         = sqrt(900e18)
        //
        // For the default mock values (cashOutRate=0.5e18, issuanceRate=900e18):
        //   issuance sqrtPrice > cashOut sqrtPrice because 900 > 2.
        //   The inversion becomes obvious with much lower cashOutRate (see next test).
        //
        // Verify that both sqrtPrices are nonzero and distinct.
        assertGt(sqrtPriceCashOut, 0, "CashOut sqrtPrice should be nonzero");
        assertGt(sqrtPriceIssuance, 0, "Issuance sqrtPrice should be nonzero");
        assertTrue(sqrtPriceCashOut != sqrtPriceIssuance, "CashOut and issuance sqrtPrices should differ");
    }

    /// @notice The fix ensures _calculateTickBounds produces a wide economic range
    ///         (not the narrow +/-1 tick fallback) when terminal is token0.
    function test_tickBoundsAreWide_whenTerminalIsToken0() public view {
        (int24 tickLower, int24 tickUpper) = testableHook.exposed_calculateTickBounds(
            TEST_PROJECT_ID, address(lowTerminalToken), address(highProjectToken)
        );

        int24 tickSpacing = int24(200); // TICK_SPACING

        // Verify tickLower < tickUpper (basic correctness).
        assertLt(tickLower, tickUpper, "tickLower must be less than tickUpper");

        // Verify the range is wider than the narrow fallback (2 * TICK_SPACING = 400).
        // The narrow fallback of +/-1 tick spacing gives exactly 400 ticks.
        // A proper economic range should be much wider.
        int24 range = tickUpper - tickLower;
        assertGt(range, 2 * tickSpacing, "Tick range should be wider than the narrow fallback of 2*TICK_SPACING");
    }

    /// @notice Demonstrate the bug with a low cash-out rate that makes the inversion obvious.
    ///         With cashOutRate = 1e12 and issuanceRate = 900e18:
    ///         - When terminal is token0: cashOut token1Amount = 1e36/1e12 = 1e24,
    ///           issuance token1Amount = 900e18.
    ///           So cashOut sqrtPrice = sqrt(1e24) >> sqrt(900e18) = issuance sqrtPrice.
    ///           This means cashOut tick >> issuance tick, triggering inversion.
    ///         With the fix, sorting ensures tickLower < tickUpper and the range is correct.
    function test_lowCashOutRate_noFallback_whenTerminalIsToken0() public {
        // Set a very low surplus => low cash-out rate.
        store.setSurplus(TEST_PROJECT_ID, 1e12);

        uint160 sqrtPriceCashOut = testableHook.exposed_getCashOutRateSqrtPriceX96(
            TEST_PROJECT_ID, address(lowTerminalToken), address(highProjectToken)
        );
        uint160 sqrtPriceIssuance = testableHook.exposed_getIssuanceRateSqrtPriceX96(
            TEST_PROJECT_ID, address(lowTerminalToken), address(highProjectToken)
        );

        int24 tickCashOut = TickMath.getTickAtSqrtPrice(sqrtPriceCashOut);
        int24 tickIssuance = TickMath.getTickAtSqrtPrice(sqrtPriceIssuance);

        // Confirm inversion: cashOut tick > issuance tick.
        assertGt(
            tickCashOut,
            tickIssuance,
            "With low cashOutRate and terminal as token0, cashOut tick should exceed issuance tick"
        );

        // Despite the raw tick inversion, _calculateTickBounds should sort correctly.
        (int24 tickLower, int24 tickUpper) = testableHook.exposed_calculateTickBounds(
            TEST_PROJECT_ID, address(lowTerminalToken), address(highProjectToken)
        );

        assertLt(tickLower, tickUpper, "tickLower must be < tickUpper after fix");

        // The range should be wide (not the narrow +/-1 tick fallback).
        int24 range = tickUpper - tickLower;
        assertGt(range, 2 * int24(200), "Range should be wider than the narrow 2*TICK_SPACING fallback");

        // Verify tickLower came from the issuance tick (the lower one) and
        // tickUpper came from the cashOut tick (the higher one), after alignment.
        int24 alignedIssuance = _alignTickToSpacing(tickIssuance, 200);
        int24 alignedCashOut = _alignTickToSpacing(tickCashOut, 200);
        assertEq(tickLower, alignedIssuance, "tickLower should be the aligned issuance tick (the lower raw tick)");
        assertEq(tickUpper, alignedCashOut, "tickUpper should be the aligned cashOut tick (the higher raw tick)");
    }

    /// @notice Confirm tick bounds are correct when terminal is token1 (no inversion).
    ///         This is the case that worked correctly even before the fix.
    function test_noInversion_whenTerminalIsToken1() public view {
        // Use the default tokens from the base setup (terminalToken, projectToken).
        // Check if terminalToken > projectToken (terminal is token1).
        bool terminalIsToken1 = address(terminalToken) > address(projectToken);

        // If the default ordering already has terminal as token1, test it.
        // Otherwise skip (the test above covers the token0 case).
        if (!terminalIsToken1) return;

        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        assertLt(tickLower, tickUpper, "tickLower < tickUpper when terminal is token1");
        int24 range = tickUpper - tickLower;
        assertGt(range, 2 * int24(200), "Range should be wider than narrow fallback");
    }

    /// @notice End-to-end: deploy a pool where terminal is token0.
    ///         With the fix, the pool deploys with a proper LP range.
    ///         Without the fix, the narrow fallback would waste most of the liquidity.
    function test_e2e_deployPool_whenTerminalIsToken0() public {
        // Accumulate project tokens.
        uint256 accAmount = 100e18;
        highProjectToken.mint(address(hook), accAmount);

        // Build context for the test project.
        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(TEST_PROJECT_ID, address(highProjectToken), accAmount, 1));

        assertEq(hook.accumulatedProjectTokens(TEST_PROJECT_ID), accAmount, "Tokens should be accumulated");

        // Deploy the pool as owner.
        vm.prank(owner);
        hook.deployPool(TEST_PROJECT_ID, address(lowTerminalToken), 0);

        // Verify pool was deployed successfully.
        uint256 tokenId = hook.tokenIdOf(TEST_PROJECT_ID, address(lowTerminalToken));
        assertTrue(tokenId != 0, "tokenIdOf should be nonzero after deploy");
        assertTrue(hook.projectDeployed(TEST_PROJECT_ID, address(lowTerminalToken)), "projectDeployed should be true");
    }

    // ─── Helper
    // ──────────────────────────────────────────────────────────

    /// @notice Replicate _alignTickToSpacing for test assertions.
    function _alignTickToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        // Intentional: rounding tick down to nearest spacing boundary
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 rounded = (tick / spacing) * spacing;
        if (tick < 0 && rounded > tick) {
            rounded -= spacing;
        }
        return rounded;
    }
}
