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

    // ─── Finding 1 (CRITICAL): a deploy spends ONLY this project's own burn-recovered terminal ───

    function _lockedSides(uint256 tokenId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(tokenId);
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        (projectSide, terminalSide) = terminalIsToken0 ? (amount1Locked, amount0Locked) : (amount0Locked, amount1Locked);
    }

    /// @notice Terminal sitting loose on the shared clone (a donation, or another project's recovered terminal) is
    /// NEVER paired into a project's deploy nor routed out — the deploy is asks-only and the loose balance is untouched.
    /// On the pre-fix code this balance was read as the mint's terminal side and captured.
    function test_Finding1_DonatedTerminalNotSweptAtDeploy() public {
        int24 midTick = _preInitAtMid();
        midTick; // pool is pre-initialized at mid.

        uint256 donation = 5e18;
        terminalToken.mint(address(hook), donation);

        uint256 addToBalanceBefore = terminal.addToBalanceCallCount();
        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        (uint256 projectSide, uint256 terminalSide) = _lockedSides(hook.tokenIdOf(PROJECT_ID, address(terminalToken)));
        assertEq(terminalSide, 0, "donated terminal must not be paired into the position (asks-only)");
        assertEq(projectSide, 0.5e18, "the full project balance deploys as asks");
        assertEq(terminalToken.balanceOf(address(hook)), donation, "donation stays on the hook, never swept or routed");
        assertEq(terminal.addToBalanceCallCount(), addToBalanceBefore, "no terminal is routed out on an asks-only deploy");
    }

    /// @notice Two projects share the clone. Project B's terminal accumulated on the hook is not consumed when project
    /// A deploys — A only spends terminal recovered from burning A's own position (none on a first deploy).
    function test_Finding1_CrossProjectTerminalNotCaptured() public {
        // Project B's terminal (modeled as a balance the clone holds on B's behalf).
        uint256 bBalance = 7e18;
        terminalToken.mint(address(hook), bBalance);

        _preInitAtMid();
        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        (, uint256 terminalSide) = _lockedSides(hook.tokenIdOf(PROJECT_ID, address(terminalToken)));
        assertEq(terminalSide, 0, "project A must not pair another project's terminal as its bid");
        assertEq(terminalToken.balanceOf(address(hook)), bBalance, "the other project's terminal is fully preserved");
    }

    /// @notice Existing behavior preserved: a rebalance still folds this project's OWN recovered terminal (the burn's
    /// principal) into the re-minted bid leg.
    function test_Finding1_RebalanceFoldsRecoveredBid() public {
        (int24 corridorLower, int24 corridorUpper) = _corridorAtMid();
        positionManager.initializePool(_poolKey(), TickMath.getSqrtPriceAtTick(corridorLower + (corridorUpper - corridorLower) / 2));
        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Inject this project's OWN terminal into its position (as filled asks would), recovered on the burn.
        uint256 bid = 1e18;
        terminalToken.mint(address(positionManager), bid);
        positionManager.injectPositionBalance(tokenId, address(terminalToken), bid);
        projectToken.mint(address(positionManager), 1000e18);
        terminalToken.mint(address(positionManager), 1000e18);

        controller.setWeight(PROJECT_ID, 900e18); // move corridor to clear the drift guard.
        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));

        (, uint256 terminalSide) = _lockedSides(hook.tokenIdOf(PROJECT_ID, address(terminalToken)));
        assertGt(terminalSide, 0, "the burn-recovered terminal must seed the re-minted bid leg");
        assertLe(terminalSide, bid, "the bid never exceeds the recovered terminal");
    }

    function _corridorAtMid() internal returns (int24 lo, int24 hi) {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});
        (lo, hi) = _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));
    }

    // ─── Finding 5 (MEDIUM): the corridor (and drift basis) reflect POST-fee-routing surplus ───

    /// @notice A rebalance collects and routes LP fees BEFORE computing the corridor, so routing terminal fees (which
    /// raise surplus and thus the cash-out floor) is reflected in the stored corridor. The fee-driven floor move is what
    /// clears the drift guard for the first rebalance; an immediate second rebalance then sees no further drift and
    /// reverts — no free double-rebalance. On the pre-fix code the corridor was computed BEFORE fee routing, so the
    /// first rebalance would find no drift at all (and revert), and the stored corridor would lag the post-fee surplus.
    function test_Finding5_CorridorReflectsPostFeeSurplus_NoDoubleRebalance() public {
        terminal.setBumpSurplusOnAddToBalance(true);
        (int24 corridorLower, int24 corridorUpper) = _corridorAtMid();
        positionManager.initializePool(_poolKey(), TickMath.getSqrtPriceAtTick(corridorLower + (corridorUpper - corridorLower) / 2));
        _accumulateTokens(PROJECT_ID, 1e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Give the position a bid and MATERIAL pending terminal-side LP fees; routing them raises surplus (the floor).
        terminalToken.mint(address(positionManager), 1e18);
        positionManager.injectPositionBalance(tokenId, address(terminalToken), 1e18);
        uint256 fee = 60e18;
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        if (terminalIsToken0) positionManager.setCollectableFees(tokenId, fee, 0);
        else positionManager.setCollectableFees(tokenId, 0, fee);
        terminalToken.mint(address(positionManager), fee);
        projectToken.mint(address(positionManager), 1000e18);
        terminalToken.mint(address(positionManager), 1000e18);

        // First rebalance: the fee-driven surplus bump moves the floor enough to clear the drift guard.
        vm.prank(user);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));

        // The stored drift basis reflects the POST-fee corridor: recomputing the corridor now equals what was stored.
        (int24 postLower, int24 postUpper) = _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));
        assertEq(hook.rangedCorridorLowerOf(PROJECT_ID, address(terminalToken)), postLower, "stored floor is post-fee");
        assertEq(hook.rangedCorridorUpperOf(PROJECT_ID, address(terminalToken)), postUpper, "stored ceiling is post-fee");

        // An immediate second rebalance finds no further drift (no new fees, no rate change) and reverts.
        vm.prank(user);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_DriftBelowThreshold.selector);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));
    }

    // ─── Finding 7 (LOW): addLiquidity rejects dust accumulation to prevent churn ───

    function _deployForAdd() internal returns (int24 midTick) {
        midTick = _preInitAtMid();
        _accumulateTokens(PROJECT_ID, 1e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        projectToken.mint(address(positionManager), 1000e18);
        terminalToken.mint(address(positionManager), 1000e18);
    }

    /// @notice A 1-wei accumulation cannot force an addLiquidity churn.
    function test_Finding7_DustAccumulation_CannotForceChurn() public {
        _deployForAdd();
        // Deploy consumed the accumulation; accrue a single wei of project-token dust.
        _accumulateTokens(PROJECT_ID, 1);

        vm.prank(user);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_AccumulationBelowThreshold.selector);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
    }

    /// @notice A meaningful accumulation still adds liquidity (a fresh position is minted).
    function test_Finding7_MeaningfulAccumulation_StillAdds() public {
        _deployForAdd();
        uint256 oldTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        _accumulateTokens(PROJECT_ID, 0.5e18);

        vm.prank(user);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
        assertNotEq(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), oldTokenId, "meaningful accumulation must add");
    }
}
