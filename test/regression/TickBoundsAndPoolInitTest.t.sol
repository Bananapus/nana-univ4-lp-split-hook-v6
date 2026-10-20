// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase, DEFAULT_SURPLUS_PER_TOKEN} from "../TestBaseV4.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
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
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

/// @notice Wrapper that exposes internal tick calculation functions for testing.
contract TickBoundsTestableHook is JBUniswapV4LPSplitHook {
    using PoolIdLibrary for PoolKey;

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

/// @notice Tests verifying the regression fix: _createAndInitializePool no longer reverts on pre-initialized pools.
/// @dev fix allows deployPool to succeed even when an attacker or another deployer has already
///      initialized the Uniswap V4 pool at a different price. The hook now accepts whatever price
///      exists and adds liquidity (possibly out-of-range).
contract RegressionFixM4Test is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;

    // ─────────────────────────────────────────────────────────────────────
    // 1. Pool already initialized at a different price — deployPool succeeds
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When the pool is pre-initialized at a different but in-bounds price,
    ///         deployPool accepts it and succeeds.
    function test_M4_PreInitializedPoolAtInBoundsPrice_DeploySucceeds() public {
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
            hooks: hook.oracleHook()
        });

        // Pre-initialize the pool at a price within the project's economic bounds. With the terminal token as
        // token0 (default fixture ordering) the price is project tokens per terminal token: the issuance ceiling
        // (900) sits at tick ~68,023 (aligned up to 68,200) and the cash-out floor (1 / 0.0005 = 2000) at tick
        // ~76,013 (aligned down to 76,000), so tick 72,000 is inside the corridor.
        int24 inBoundsTick = int24(72_000);
        uint160 inBoundsSqrtPrice = TickMath.getSqrtPriceAtTick(inBoundsTick);
        positionManager.initializePool(key, inBoundsSqrtPrice);

        // Verify pool is initialized.
        bytes32 poolId = keccak256(abi.encode(key));
        assertTrue(positionManager.poolInitialized(poolId), "precondition: pool should be pre-initialized");

        // deployPool should succeed — the pre-initialized price is within bounds.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // Verify deployment succeeded.
        assertTrue(hook.hasDeployedPool(PROJECT_ID), "project should have a deployed pool");
        assertGt(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), 0, "LP position should be created");
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
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3)
        );
        testableHook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });

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
            hooks: hook.oracleHook()
        });

        // Pre-initialize at the expected price.
        positionManager.initializePool(key, expectedSqrtPrice);

        // deployPool should still succeed.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "project should have a deployed pool");
        assertGt(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), 0, "LP position should be created");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Out-of-range liquidity is added correctly when price is outside tick bounds
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When the pool is pre-initialized at a price past the issuance ceiling, the hook has no room to offer
    ///         asks and no terminal to offer as bids, so deployment reverts with NoDeployableLiquidityAtSpot instead
    ///         of adding single-sided liquidity at a manipulated price.
    function test_M4_OutOfRangeLiquidity_RefusesLegibly() public {
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
            hooks: hook.oracleHook()
        });

        // Pre-initialize at an extreme price (far below expected LP range).
        // This simulates an attacker setting a very low price.
        int24 extremeTick = int24(-50_000);
        uint160 extremeSqrtPrice = TickMath.getSqrtPriceAtTick(extremeTick);
        positionManager.initializePool(key, extremeSqrtPrice);

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector);
        hook.deployPool(PROJECT_ID);
    }
}

/// @notice Tests verifying the tick bounds stay inside the valid TickMath range at extreme prices, and that a band
/// narrower than one spacing is an empty corridor.
/// @dev Without the clamp, a bound past MIN_TICK or MAX_TICK would make TickMath.getSqrtPriceAtTick revert. A collapsed
///      band returns (0, 0) and the hook holds, rather than opening a band around the issuance price whose asks would
///      sit below the cash-out value.
contract RegressionFixL6Test is LPSplitHookV4TestBase {
    TickBoundsTestableHook public testableHook;

    int24 constant TICK_SPACING = 200;

    function setUp() public override {
        super.setUp();

        testableHook = new TickBoundsTestableHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3)
        );
        testableHook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });
    }

    /// @dev Compute the valid tick boundaries (matching the contract's logic).
    function _minUsableTick() internal pure returns (int24) {
        // Intentionally divide before multiplying to align the minimum tick to the spacing grid.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 aligned = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        if (TickMath.MIN_TICK < 0 && aligned > TickMath.MIN_TICK) {
            aligned -= TICK_SPACING;
        }
        return aligned + TICK_SPACING;
    }

    function _maxUsableTick() internal pure returns (int24) {
        // Intentionally divide before multiplying to align the maximum tick to the spacing grid.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 aligned = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        if (TickMath.MAX_TICK < 0 && aligned > TickMath.MAX_TICK) {
            aligned -= TICK_SPACING;
        }
        return aligned - TICK_SPACING;
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. An extreme issuance price is clamped to the valid range
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A weight of 1 wei puts the issuance price at the far end of the tick range (a cash-out value of 900
    /// sits far below it): the issuance-side bound clamps to the usable range and the corridor stays wide.
    function test_L6_ExtremeIssuancePrice_ClampedToValidRange() public {
        store.setSurplus(PROJECT_ID, 900e18);
        controller.setWeight(PROJECT_ID, 1);
        controller.setReservedPercent(PROJECT_ID, 0);

        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        assertGe(tickLower, _minUsableTick(), "tickLower must be >= minUsable after clamping");
        assertLe(tickUpper, _maxUsableTick(), "tickUpper must be <= maxUsable after clamping");
        assertGt(tickUpper - tickLower, TICK_SPACING, "the corridor stays wider than one spacing");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. A band narrower than one spacing at an extreme price is empty
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A cash-out value 1% under an extreme issuance price (weight type(uint88).max, around tick +/-195,500)
    /// leaves a band about 100 ticks wide with no aligned spacing in it. The corridor is empty, not reopened as
    /// currentTick +/- one spacing, and the hook refuses to deploy into it.
    function test_L6_NarrowBandAtExtremePrice_EmptyCorridor() public {
        // The issuance price is 1e36 / weight terminal-token wei per 1e18 project tokens.
        // Intentionally divide first: the issuance price per token, then 99% of it.
        // forge-lint: disable-next-line(divide-before-multiply)
        store.setSurplus(PROJECT_ID, (1e36 / uint256(type(uint88).max)) * 99 / 100);
        controller.setWeight(PROJECT_ID, type(uint88).max);
        controller.setReservedPercent(PROJECT_ID, 0);

        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));
        assertEq(tickLower, 0, "empty corridor lower");
        assertEq(tickUpper, 0, "empty corridor upper");

        _accumulateTokens(PROJECT_ID, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_EmptyCorridor.selector, PROJECT_ID, address(terminalToken)
            )
        );
        hook.deployPool(PROJECT_ID);
        assertFalse(hook.isPoolDeployed(PROJECT_ID, address(terminalToken)), "the pool is not deployed");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 1e18, "the reserved tokens stay ledgered");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. Well-separated prices (in middle of range) give a wide corridor
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When cashOut and issuance rates produce well-separated ticks (middle of range),
    ///         the corridor is valid, clamped and wide.
    function test_L6_NormalTicks_ValidBounds() public {
        // With moderate surplus and default weight, cashout and issuance ticks are well-separated (cash-out value
        // 0.0005 vs issuance price 1/900, about 39 spacings).
        store.setSurplus(PROJECT_ID, DEFAULT_SURPLUS_PER_TOKEN);

        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        int24 minUsable = _minUsableTick();
        int24 maxUsable = _maxUsableTick();

        // Verify ticks are within valid range (always true post-fix).
        assertGe(tickLower, minUsable, "tickLower must be >= minUsable");
        assertLe(tickUpper, maxUsable, "tickUpper must be <= maxUsable");
        assertLt(tickLower, tickUpper, "tickLower must be < tickUpper");

        // The corridor spans many spacings.
        assertGt(tickUpper - tickLower, 2 * TICK_SPACING, "the corridor should span more than two spacings");
    }
}
