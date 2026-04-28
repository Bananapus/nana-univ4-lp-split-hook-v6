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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Wrapper that exposes internal tick calculation functions for L-6 testing.
contract TickBoundsTestableHook is JBUniswapV4LPSplitHook {
    using PoolIdLibrary for PoolKey;

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

/// @notice Tests verifying the M-4 audit fix: _createAndInitializePool no longer reverts on pre-initialized pools.
/// @dev M-4 fix allows deployPool to succeed even when an attacker or another deployer has already
///      initialized the Uniswap V4 pool at a different price. The hook now accepts whatever price
///      exists and adds liquidity (possibly out-of-range).
contract AuditFixM4Test is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;

    // ─────────────────────────────────────────────────────────────────────
    // 1. Pool already initialized at a different price — deployPool succeeds
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When an attacker pre-initializes the pool at a wildly different price,
    ///         deployPool should succeed instead of reverting.
    function test_M4_PreInitializedPoolAtDifferentPrice_DeploySucceeds() public {
        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        // Build the pool key that the hook will use.
        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        // Pre-initialize the pool at a very different price (far outside expected bounds).
        // Use a tick well above the expected range.
        int24 attackerTick = int24(50_000); // far from typical Juicebox price
        uint160 attackerSqrtPrice = TickMath.getSqrtPriceAtTick(attackerTick);
        positionManager.initializePool(key, attackerSqrtPrice);

        // Verify pool is initialized.
        bytes32 poolId = keccak256(abi.encode(key));
        assertTrue(positionManager.poolInitialized(poolId), "precondition: pool should be pre-initialized");

        // deployPool should succeed (M-4 fix: no revert on pre-initialized pools).
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        // Verify deployment succeeded.
        assertTrue(hook.hasDeployedPool(PROJECT_ID), "project should have a deployed pool");
        assertGt(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), 0, "LP position should be created");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Pool initialized at expected price — works as before
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When the pool is pre-initialized at the exact expected price (matching the hook's
    ///         _computeInitialSqrtPrice), deployPool succeeds normally.
    function test_M4_PreInitializedPoolAtExpectedPrice_DeploySucceeds() public {
        TickBoundsTestableHook testableHook = new TickBoundsTestableHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3)
        );
        testableHook.initialize(FEE_PROJECT_ID, FEE_PERCENT);

        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        // Compute the price the hook would normally set.
        uint160 expectedSqrtPrice =
            testableHook.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), address(projectToken));

        // Build pool key.
        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        // Pre-initialize at the expected price.
        positionManager.initializePool(key, expectedSqrtPrice);

        // deployPool should still succeed.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "project should have a deployed pool");
        assertGt(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), 0, "LP position should be created");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Out-of-range liquidity is added correctly when price is outside tick bounds
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When the pool is pre-initialized at a price outside the LP tick bounds,
    ///         the hook adds single-sided (out-of-range) liquidity. The LP position is created
    ///         and the PositionManager mint is called exactly once.
    function test_M4_OutOfRangeLiquidity_AddedCorrectly() public {
        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        // Build pool key.
        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        // Pre-initialize at an extreme price (far below expected LP range).
        // This simulates an attacker setting a very low price — the liquidity will be
        // single-sided (all in one token).
        int24 extremeTick = int24(-50_000);
        uint160 extremeSqrtPrice = TickMath.getSqrtPriceAtTick(extremeTick);
        positionManager.initializePool(key, extremeSqrtPrice);

        uint256 mintCountBefore = positionManager.mintCallCount();

        // deployPool should succeed with out-of-range liquidity.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        // The position should still be minted.
        assertEq(
            positionManager.mintCallCount(),
            mintCountBefore + 1,
            "PositionManager mint should be called once for out-of-range position"
        );
        assertTrue(hook.hasDeployedPool(PROJECT_ID), "project should have a deployed pool");
        assertGt(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), 0, "LP position NFT should exist");
    }
}

/// @notice Tests verifying the L-6 audit fix: fallback tick computation re-clamps to valid TickMath range.
/// @dev L-6 fix adds a second clamping pass after the fallback calculation (currentTick +/- TICK_SPACING).
///      Without it, a currentTick at MIN_TICK or MAX_TICK would produce ticks outside the valid range,
///      causing TickMath.getSqrtPriceAtTick to revert.
contract AuditFixL6Test is LPSplitHookV4TestBase {
    TickBoundsTestableHook public testableHook;

    int24 constant TICK_SPACING = 200;

    function setUp() public override {
        super.setUp();

        testableHook = new TickBoundsTestableHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3)
        );
        testableHook.initialize(FEE_PROJECT_ID, FEE_PERCENT);
    }

    /// @dev Compute the valid tick boundaries (matching the contract's logic).
    function _minUsableTick() internal pure returns (int24) {
        int24 aligned = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        if (TickMath.MIN_TICK < 0 && aligned > TickMath.MIN_TICK) {
            aligned -= TICK_SPACING;
        }
        return aligned + TICK_SPACING;
    }

    function _maxUsableTick() internal pure returns (int24) {
        int24 aligned = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        if (TickMath.MAX_TICK < 0 && aligned > TickMath.MAX_TICK) {
            aligned -= TICK_SPACING;
        }
        return aligned - TICK_SPACING;
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Fallback ticks near MIN_TICK are clamped to valid range
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When cashOut and issuance rates produce nearly identical ticks (collapsing
    ///         tickLower >= tickUpper), the fallback uses currentTick +/- TICK_SPACING.
    ///         If currentTick is near MIN_TICK, the L-6 fix clamps tickLower to minUsable.
    function test_L6_FallbackTickNearMinTick_ClampedToValidRange() public {
        // Force the fallback branch by making cashOut and issuance rates nearly equal.
        // With very high surplus, cashOutRate approaches issuanceRate, causing tick collapse.
        store.setSurplus(PROJECT_ID, 900e18); // Very high surplus relative to supply

        // Set weight very low so the current Juicebox price maps to a tick near MIN_TICK.
        // A very low issuance rate means: for 1 WAD terminal tokens, very few project tokens.
        // If project is token1 and terminal is token0, low issuance means low token1/token0 ratio => low sqrtPrice =>
        // near MIN_TICK.
        controller.setWeight(PROJECT_ID, 1); // Extremely low weight => near-zero issuance
        controller.setReservedPercent(PROJECT_ID, 0);

        // The fallback should trigger and the L-6 fix ensures no revert.
        // Without the fix, this would revert in TickMath.getSqrtPriceAtTick if tick < MIN_TICK.
        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        int24 minUsable = _minUsableTick();
        int24 maxUsable = _maxUsableTick();

        // Verify ticks are within valid range.
        assertGe(tickLower, minUsable, "tickLower must be >= minUsable after L-6 clamping");
        assertLe(tickUpper, maxUsable, "tickUpper must be <= maxUsable after L-6 clamping");
        assertLt(tickLower, tickUpper, "tickLower must be < tickUpper");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. Fallback ticks near MAX_TICK are clamped to valid range
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When the current Juicebox price maps to a tick near MAX_TICK, the fallback
    ///         calculation (currentTick + TICK_SPACING) would exceed MAX_TICK without L-6 clamping.
    function test_L6_FallbackTickNearMaxTick_ClampedToValidRange() public {
        // Force the fallback branch: make cashOut and issuance rates nearly equal.
        store.setSurplus(PROJECT_ID, 900e18);

        // Set extremely high weight to push currentTick toward MAX_TICK.
        // High issuance rate means: for 1 WAD terminal tokens, lots of project tokens.
        // If project is token1 and terminal is token0, high issuance means high token1/token0 ratio => high sqrtPrice
        // => near MAX_TICK.
        controller.setWeight(PROJECT_ID, type(uint88).max); // Very high weight
        controller.setReservedPercent(PROJECT_ID, 0);

        // The fallback should trigger and the L-6 fix ensures no revert.
        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        int24 minUsable = _minUsableTick();
        int24 maxUsable = _maxUsableTick();

        // Verify ticks are within valid range.
        assertGe(tickLower, minUsable, "tickLower must be >= minUsable after L-6 clamping");
        assertLe(tickUpper, maxUsable, "tickUpper must be <= maxUsable after L-6 clamping");
        assertLt(tickLower, tickUpper, "tickLower must be < tickUpper");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. Normal fallback ticks (in middle of range) are unaffected
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When cashOut and issuance rates produce well-separated ticks (middle of range),
    ///         the normal (non-fallback) path produces valid, clamped tick bounds.
    function test_L6_NormalTicks_ValidBounds() public {
        // With moderate surplus and default weight, cashout and issuance ticks are well-separated,
        // so the normal path runs (not the fallback).
        store.setSurplus(PROJECT_ID, 900e18);

        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        int24 minUsable = _minUsableTick();
        int24 maxUsable = _maxUsableTick();

        // Verify ticks are within valid range (always true post-fix).
        assertGe(tickLower, minUsable, "tickLower must be >= minUsable");
        assertLe(tickUpper, maxUsable, "tickUpper must be <= maxUsable");
        assertLt(tickLower, tickUpper, "tickLower must be < tickUpper");

        // Range should be wider than the minimal fallback width.
        assertGt(
            tickUpper - tickLower,
            2 * TICK_SPACING,
            "normal path should produce a wider range than the fallback minimum"
        );
    }
}
