// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {MockGeomeanOracle} from "./mock/MockGeomeanOracle.sol";

/// @notice Subclass exposing internals so unit tests can drive them directly.
contract CodexExposedHook is JBUniswapV4LPSplitHook {
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IAllowanceTransfer permit2,
        IJBSuckerRegistry suckerRegistry
    )
        JBUniswapV4LPSplitHook(directory, permissions, tokens, permit2, suckerRegistry)
    {}

    function exposed_mintPosition(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    )
        external
    {
        _mintPosition({
            key: key, tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity, amount0: amount0, amount1: amount1
        });
    }
}

/// @notice Codex audit fix coverage. Each test names its finding and asserts the corrected behavior.
contract SingleSided_CodexFixesTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    CodexExposedHook internal exposedHook;

    function _spotTickOf(uint256 projectId) internal view returns (int24) {
        PoolKey memory key = hook.poolKeyOf(projectId, address(terminalToken));
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(key.toId());
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
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

    function _deployExposedHook() internal {
        CodexExposedHook impl = new CodexExposedHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3),
            IJBSuckerRegistry(address(0))
        );
        exposedHook = CodexExposedHook(payable(LibClone.clone(address(impl))));
        exposedHook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(baseOracleHook)),
            newBuybackHook: IJBBuybackHookRegistry(BUYBACK_REGISTRY)
        });
    }

    // ─── Finding 8: unsafe uint128 casts revert instead of silently truncating ───

    /// @notice A settle-cap amount at or above 2^128 must revert `AmountExceedsUint128` rather than wrap to a smaller
    /// value (which would silently mint a truncated/zero-cap position).
    function test_Finding8_MintCapAtUint128Boundary_Reverts() public {
        _deployExposedHook();
        PoolKey memory key = _poolKey();
        positionManager.initializePool(key, TickMath.getSqrtPriceAtTick(0));

        int24 spacing = hook.TICK_SPACING();
        uint256 overflowAmount = uint256(type(uint128).max) + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_AmountExceedsUint128.selector, overflowAmount
            )
        );
        exposedHook.exposed_mintPosition({
            key: key, tickLower: -spacing, tickUpper: spacing, liquidity: 1000, amount0: overflowAmount, amount1: 0
        });
    }

    // ─── Finding 9: a hook-initialized (fresh) pool seeds at the cash-out floor, not the geometric midpoint ───

    /// @notice Deploying onto a pool the hook initializes itself seeds the pool just inside the cash-out (floor) bound,
    /// so nearly the entire project balance deploys as asks across [floor, ceiling] rather than wasting the
    /// [floor, midpoint] band the old geometric-midpoint seed left empty.
    function test_Finding9_FreshPoolSeedsAtFloor() public {
        // A non-inverted corridor: cash-out value (floor) sits genuinely below the issuance ceiling. A low surplus
        // relative to a large supply keeps the cash-out rate small, so the cash-out price is the economic floor.
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 1e18, supply: 1_000_000e18, taxRate: 4000});

        (int24 corridorLower, int24 corridorUpper) = _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));
        // The floor bound is ordering-aware: corridor LOWER when project is token0, UPPER when project is token1. The
        // seed sits exactly one spacing inside that floor.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        int24 expectedSeedTick = projectIsToken0 ? corridorLower + TICK_SPACING() : corridorUpper - TICK_SPACING();

        // No pre-initialization: the hook initializes the pool itself during deployPool.
        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        int24 seedTick = _spotTickOf(PROJECT_ID);
        assertEq(seedTick, expectedSeedTick, "fresh pool must seed one spacing inside the cash-out floor");

        // The seed sits near the floor extreme, not the geometric midpoint the old code used.
        int24 midTick = corridorLower + (corridorUpper - corridorLower) / 2;
        int24 distFromMid = seedTick >= midTick ? seedTick - midTick : midTick - seedTick;
        assertGt(distFromMid, (corridorUpper - corridorLower) / 4, "seed must sit near the floor, not the midpoint");
    }

    // ─── Finding 3: cashOutRate == 0 corridor pins the ceiling on the EXACT issuance tick ───

    function _zeroCashOutIssuanceTick(uint256 projectId, address term, address proj) internal view returns (int24) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(projectId);
        uint160 issuanceSqrtPrice = JBUniswapV4LPSplitHookMath.getIssuanceRateSqrtPriceX96({
            directory: IJBDirectory(address(directory)),
            projectId: projectId,
            terminalToken: term,
            projectToken: proj,
            controller: address(controller),
            ruleset: ruleset
        });
        return TickMath.getTickAtSqrtPrice(issuanceSqrtPrice);
    }

    function _corridorOf(uint256 projectId, address term, address proj) internal view returns (int24 lo, int24 hi) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(projectId);
        (lo, hi) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: projectId,
            terminalToken: term,
            projectToken: proj,
            controller: address(controller),
            ruleset: ruleset
        });
    }

    /// @notice Default harness ordering. With cashOutRate rounding to 0, the corridor's ceiling-side bound must equal
    /// the aligned issuance tick, so a fresh-pool deploy (seeded at issuance = the ceiling) reverts SpotAboveCeilingAtSeed
    /// instead of wrongly passing a bound one spacing past issuance.
    function test_Finding3_ZeroCashOut_CeilingIsIssuanceTick_DefaultOrdering() public {
        store.setSurplus(PROJECT_ID, 0);

        int24 issuanceTick = _zeroCashOutIssuanceTick(PROJECT_ID, address(terminalToken), address(projectToken));
        (int24 corridorLower, int24 corridorUpper) = _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));

        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        int24 ceilingBound = projectIsToken0 ? corridorUpper : corridorLower;
        // The ceiling bound sits on the aligned issuance tick (within one alignment step), not one spacing past it.
        assertLt(_absTick(ceilingBound, issuanceTick), TICK_SPACING(), "ceiling anchors on the issuance tick");

        // A fresh-pool deploy seeds at the issuance price; the spot lands at the ceiling and must be rejected.
        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_SpotAboveCeilingAtSeed.selector);
        hook.deployPool(PROJECT_ID);
    }

    /// @notice A spot STRICTLY below the issuance ceiling still deploys successfully under the zero-cashout corridor.
    function test_Finding3_ZeroCashOut_StrictlyBelowCeiling_Succeeds() public {
        store.setSurplus(PROJECT_ID, 0);
        (int24 corridorLower, int24 corridorUpper) = _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));

        // Seat spot one spacing on the ask-fillable side of the ceiling: strictly inside the corridor, leaving a
        // one-spacing ask leg between spot and the exact-issuance ceiling. Ordering-aware.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        int24 spotTick = projectIsToken0 ? corridorUpper - TICK_SPACING() : corridorLower + TICK_SPACING();

        PoolKey memory key = _poolKey();
        positionManager.initializePool(key, TickMath.getSqrtPriceAtTick(spotTick));

        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        assertNotEq(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), 0, "deploy strictly below ceiling must succeed");
    }

    function _absTick(int24 a, int24 b) internal pure returns (int24) {
        return a >= b ? a - b : b - a;
    }

    function TICK_SPACING() internal view returns (int24) {
        return hook.TICK_SPACING();
    }

    // ─── Finding 2: deployPool validates spot against the oracle TWAP on a pre-initialized pool ───

    function _preInitAtMid() internal returns (int24 midTick) {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});
        (int24 corridorLower, int24 corridorUpper) = _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));
        midTick = corridorLower + (corridorUpper - corridorLower) / 2;
        positionManager.initializePool(_poolKey(), TickMath.getSqrtPriceAtTick(midTick));
    }

    /// @notice Deploying onto a pre-initialized pool whose spot has been shoved off the oracle TWAP reverts, so a
    /// deploy cannot be sandwiched into minting at a manipulated price (parity with addLiquidity/rebalance).
    function test_Finding2_DeployOnPreInitPool_RevertsWhenSpotOffTwap() public {
        // The pool key includes the oracle hook, so install the fixed oracle BEFORE pre-initializing so the pre-init
        // pool and the hook's computed key match.
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});
        (int24 corridorLower, int24 corridorUpper) = _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));
        int24 midTick = corridorLower + (corridorUpper - corridorLower) / 2;

        MockGeomeanOracle fixedOracle = new MockGeomeanOracle();
        fixedOracle.setTwapTick(midTick + 1000);
        vm.store(address(hook), bytes32(uint256(1)), bytes32(uint256(uint160(address(fixedOracle)))));

        positionManager.initializePool(_poolKey(), TickMath.getSqrtPriceAtTick(midTick));

        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_PriceDeviationTooHigh.selector);
        hook.deployPool(PROJECT_ID);
    }

    /// @notice A deploy onto a pre-initialized pool whose spot is near the TWAP succeeds (guard passes).
    function test_Finding2_DeployOnPreInitPool_SucceedsWhenSpotNearTwap() public {
        _preInitAtMid(); // base oracle tracks spot → TWAP == spot → guard passes.
        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        assertNotEq(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), 0, "near-TWAP deploy must succeed");
    }

    /// @notice A fresh pool the hook initializes itself has no TWAP history, so the guard is skipped and the cold-start
    /// deploy still succeeds even when the oracle would revert.
    function test_Finding2_FreshPoolColdStart_SkipsTwapGuard() public {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});

        MockGeomeanOracle revertingOracle = new MockGeomeanOracle();
        revertingOracle.setShouldRevert(true);
        vm.store(address(hook), bytes32(uint256(1)), bytes32(uint256(uint160(address(revertingOracle)))));

        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        assertNotEq(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), 0, "cold-start deploy must skip the TWAP guard");
    }
}
