// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {JBLPSplitHookHelpers} from "../src/libraries/JBLPSplitHookHelpers.sol";
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
import {MockERC20} from "./mock/MockERC20.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";

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
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            amount0: amount0,
            amount1: amount1
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

    // ─── Finding 9: a hook-initialized (fresh) pool seeds at the cash-out floor, not the geometric midpoint
    // ───

    /// @notice Deploying onto a pool the hook initializes itself seeds the pool just inside the cash-out (floor) bound,
    /// so nearly the entire project balance deploys as asks across [floor, ceiling] rather than wasting the
    /// [floor, midpoint] band the old geometric-midpoint seed left empty.
    function test_Finding9_FreshPoolSeedsAtFloor() public {
        // A non-inverted corridor: cash-out value (floor) sits genuinely below the issuance ceiling. A low surplus
        // relative to a large supply keeps the cash-out rate small, so the cash-out price is the economic floor.
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 1e18, supply: 1_000_000e18, taxRate: 4000});

        (int24 corridorLower, int24 corridorUpper) =
            _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));
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
    /// the aligned issuance tick. A pool PRE-INITIALIZED at exactly that issuance price (spot == the ceiling) leaves no
    /// room to offer asks, and this project holds no terminal to offer as bids, so nothing is deployable — the deploy
    /// refuses legibly and the accumulated tokens wait rather than being sold at the ceiling.
    function test_Finding3_ZeroCashOut_CeilingIsIssuanceTick_DefaultOrdering() public {
        store.setSurplus(PROJECT_ID, 0);

        int24 issuanceTick = _zeroCashOutIssuanceTick(PROJECT_ID, address(terminalToken), address(projectToken));
        (int24 corridorLower, int24 corridorUpper) =
            _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));

        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        int24 ceilingBound = projectIsToken0 ? corridorUpper : corridorLower;
        // The ceiling bound sits on the aligned issuance tick (within one alignment step), not one spacing past it.
        assertLt(_absTick(ceilingBound, issuanceTick), TICK_SPACING(), "ceiling anchors on the issuance tick");

        // Pre-initialize the pool at exactly the issuance ceiling; with nothing to bid with, nothing is deployable.
        positionManager.initializePool(_poolKey(), TickMath.getSqrtPriceAtTick(ceilingBound));
        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector);
        hook.deployPool(PROJECT_ID);
    }

    /// @notice A spot STRICTLY below the issuance ceiling still deploys successfully under the zero-cashout corridor.
    function test_Finding3_ZeroCashOut_StrictlyBelowCeiling_Succeeds() public {
        store.setSurplus(PROJECT_ID, 0);
        (int24 corridorLower, int24 corridorUpper) =
            _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));

        // Seat spot one spacing on the ask-fillable side of the ceiling: strictly inside the corridor, leaving a
        // one-spacing ask leg between spot and the exact-issuance ceiling. Ordering-aware.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        int24 spotTick = projectIsToken0 ? corridorUpper - TICK_SPACING() : corridorLower + TICK_SPACING();

        PoolKey memory key = _poolKey();
        positionManager.initializePool(key, TickMath.getSqrtPriceAtTick(spotTick));

        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        assertNotEq(
            hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), 0, "deploy strictly below ceiling must succeed"
        );
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
        (int24 corridorLower, int24 corridorUpper) =
            _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));
        midTick = corridorLower + (corridorUpper - corridorLower) / 2;
        positionManager.initializePool(_poolKey(), TickMath.getSqrtPriceAtTick(midTick));
    }

    /// @notice Deploying onto a pre-initialized pool whose spot has been shoved off the oracle TWAP reverts, so a
    /// deploy cannot be sandwiched into minting at a manipulated price (parity with addLiquidity).
    function test_Finding2_DeployOnPreInitPool_RevertsWhenSpotOffTwap() public {
        // The pool key includes the oracle hook, so install the fixed oracle BEFORE pre-initializing so the pre-init
        // pool and the hook's computed key match.
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});
        (int24 corridorLower, int24 corridorUpper) =
            _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));
        int24 midTick = corridorLower + (corridorUpper - corridorLower) / 2;

        MockGeomeanOracle fixedOracle = new MockGeomeanOracle();
        fixedOracle.setTwapTick(midTick + 1000);
        _overrideOracleHook(address(fixedOracle));

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
        assertNotEq(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), 0, "near-TWAP deploy must succeed");
    }

    /// @notice A fresh pool the hook initializes itself has no TWAP history, so the guard is skipped and the cold-start
    /// deploy still succeeds even when the oracle would revert.
    function test_Finding2_FreshPoolColdStart_SkipsTwapGuard() public {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});

        MockGeomeanOracle revertingOracle = new MockGeomeanOracle();
        revertingOracle.setShouldRevert(true);
        _overrideOracleHook(address(revertingOracle));

        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        assertNotEq(
            hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), 0, "cold-start deploy must skip the TWAP guard"
        );
    }

    // ─── Finding 1 (CRITICAL): a deploy spends ONLY this project's own burn-recovered terminal ───

    function _lockedSides(uint256 tokenId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(tokenId);
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        (projectSide, terminalSide) = terminalIsToken0 ? (amount1Locked, amount0Locked) : (amount0Locked, amount1Locked);
    }

    /// @notice Terminal sitting loose on the shared clone (a donation, or another project's recovered terminal) is
    /// NEVER paired into a project's deploy nor routed out — the deploy is asks-only and the loose balance is
    /// untouched. On the pre-fix code this balance was read as the mint's terminal side and captured.
    function test_Finding1_DonatedTerminalNotSweptAtDeploy() public {
        int24 midTick = _preInitAtMid();
        midTick; // pool is pre-initialized at mid.

        uint256 donation = 5e18;
        terminalToken.mint(address(hook), donation);

        uint256 addToBalanceBefore = terminal.addToBalanceCallCount();
        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        (uint256 projectSide, uint256 terminalSide) =
            _lockedSides(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)));
        assertEq(terminalSide, 0, "donated terminal must not be paired into the position (asks-only)");
        assertEq(projectSide, 0.5e18, "the full project balance deploys as asks");
        // The mid-corridor spot leaves room for a bid (see `test_Finding1_RecycleFoldsRecoveredTerminalIntoBid`), so a
        // captured donation would surface as a bid position.
        assertEq(hook.bidTokenIdOf(PROJECT_ID, address(terminalToken)), 0, "the donation must not mint a bid");
        assertEq(terminalToken.balanceOf(address(hook)), donation, "donation stays on the hook, never swept or routed");
        assertEq(
            terminal.addToBalanceCallCount(), addToBalanceBefore, "no terminal is routed out on an asks-only deploy"
        );
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

        (, uint256 terminalSide) = _lockedSides(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)));
        assertEq(terminalSide, 0, "project A must not pair another project's terminal as its bid");
        assertEq(
            hook.bidTokenIdOf(PROJECT_ID, address(terminalToken)), 0, "another project's terminal must not mint A a bid"
        );
        assertEq(terminalToken.balanceOf(address(hook)), bBalance, "the other project's terminal is fully preserved");
    }

    /// @notice A recycle folds this project's OWN recovered terminal (the burned ask's principal) into a terminal-only
    /// bid below the spot, while the ask re-mints project-only above it.
    function test_Finding1_RecycleFoldsRecoveredTerminalIntoBid() public {
        (int24 corridorLower, int24 corridorUpper) = _corridorAtMid();
        positionManager.initializePool(
            _poolKey(), TickMath.getSqrtPriceAtTick(corridorLower + (corridorUpper - corridorLower) / 2)
        );
        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        uint256 tokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(hook.bidTokenIdOf(PROJECT_ID, address(terminalToken)), 0, "no bid before any terminal is held");

        // Inject this project's OWN terminal into its ask (as filled asks would), recovered on the burn.
        uint256 bid = 1e18;
        terminalToken.mint(address(positionManager), bid);
        positionManager.injectPositionBalance(tokenId, address(terminalToken), bid);

        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(user);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        (uint256 askProject, uint256 askTerminal) = _lockedSides(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)));
        (uint256 bidProject, uint256 bidTerminal) = _lockedSides(hook.bidTokenIdOf(PROJECT_ID, address(terminalToken)));
        assertEq(askProject, 1e18, "the ask re-mints every project token");
        assertEq(askTerminal, 0, "the ask holds no terminal");
        assertEq(bidTerminal, bid, "the bid holds exactly the recovered terminal");
        assertEq(bidProject, 0, "the bid holds no project token");
        _assertRecycleGeometry(PROJECT_ID, address(terminalToken), address(projectToken));
    }

    function _corridorAtMid() internal returns (int24 lo, int24 hi) {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});
        (lo, hi) = _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));
    }

    // ─── Finding 5 (MEDIUM): a recycle collects fees before the re-mint, folding them into the bid ledger
    // ───

    /// @notice A recycle collects and routes LP fees BEFORE the burn/re-mint. The terminal-fee remainder is folded
    /// into this project's bid ledger and re-minted as bid liquidity — it is NOT deposited into the treasury and does
    /// NOT bump the project's surplus (so it never moves the cash-out floor).
    function test_Finding5_FeesFoldToBidLedgerNotSurplus() public {
        // Even with the treasury-surplus bump enabled, no `addToBalanceOf` deposit happens for routed fees.
        terminal.setBumpSurplusOnAddToBalance(true);
        (int24 corridorLower, int24 corridorUpper) = _corridorAtMid();
        positionManager.initializePool(
            _poolKey(), TickMath.getSqrtPriceAtTick(corridorLower + (corridorUpper - corridorLower) / 2)
        );
        _accumulateTokens(PROJECT_ID, 1e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        uint256 tokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));

        // Give the position recovered terminal and MATERIAL pending terminal-side LP fees.
        terminalToken.mint(address(positionManager), 1e18);
        positionManager.injectPositionBalance(tokenId, address(terminalToken), 1e18);
        uint256 fee = 60e18;
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        if (terminalIsToken0) positionManager.setCollectableFees(tokenId, fee, 0);
        else positionManager.setCollectableFees(tokenId, 0, fee);
        terminalToken.mint(address(positionManager), fee);

        uint256 surplusBefore = store.surplusPerToken(PROJECT_ID);
        uint256 addToBalanceBefore = terminal.addToBalanceCallCount();
        uint256 feeProjectBalanceBefore = terminalToken.balanceOf(address(terminal));

        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(user);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        // The terminal fee remainder was NOT deposited to the treasury and did NOT bump the project's surplus.
        assertEq(
            terminal.addToBalanceCallCount(), addToBalanceBefore, "routed fees are not deposited into the treasury"
        );
        assertEq(store.surplusPerToken(PROJECT_ID), surplusBefore, "routed fees do not bump the project's surplus");

        // The fee remainder (fee minus the fee-project cut paid to the terminal) joins the recovered terminal in the
        // bid.
        uint256 feeCut = terminalToken.balanceOf(address(terminal)) - feeProjectBalanceBefore;
        assertLt(feeCut, fee, "only a cut of the fee leaves the hook");
        (uint256 bidProject, uint256 bidTerminal) = _lockedSides(hook.bidTokenIdOf(PROJECT_ID, address(terminalToken)));
        assertEq(bidTerminal, 1e18 + fee - feeCut, "recovered terminal plus the fee remainder re-mint as the bid");
        assertEq(bidProject, 0, "the bid holds no project token");
        assertEq(
            hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)), 0, "the bid ledger is fully minted"
        );
        _assertRecycleGeometry(PROJECT_ID, address(terminalToken), address(projectToken));
    }

    // ─── Finding 7 (LOW): dust accumulation never triggers an inline recycle ───

    function _deployForAdd() internal returns (int24 midTick) {
        midTick = _preInitAtMid();
        _accumulateTokens(PROJECT_ID, 1e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        projectToken.mint(address(positionManager), 1000e18);
        terminalToken.mint(address(positionManager), 1000e18);
    }

    /// @notice A dust accumulation never triggers an inline recycle, but an explicit recycle folds it into the ask.
    function test_Finding7_DustAccumulation_FoldsIntoExplicitRecycle() public {
        // No extra PositionManager funding here: the mock's SWEEP would hand it to the hook and skew the ledger read.
        _preInitAtMid();
        _accumulateTokens(PROJECT_ID, 1e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        uint256 oldTokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));

        // A single wei arriving with full gas still skips the inline attempt (below `_MIN_ADD_ACCUMULATION`).
        projectToken.mint(address(controller), 1);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), 1);
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, 1));
        vm.stopPrank();
        assertEq(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), oldTokenId, "dust intake does not recycle");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 1, "dust is held in the ledger");

        // Anyone may still recycle explicitly; the dust joins the new ask.
        vm.prank(user);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
        assertNotEq(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), oldTokenId, "explicit recycle re-mints");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "the dust is folded into the ask");
    }

    /// @notice A meaningful accumulation still adds liquidity (a fresh position is minted).
    function test_Finding7_MeaningfulAccumulation_StillAdds() public {
        _deployForAdd();
        uint256 oldTokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        _accumulateTokens(PROJECT_ID, 0.5e18);

        vm.prank(user);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
        assertNotEq(
            hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), oldTokenId, "meaningful accumulation must add"
        );
    }

    // ─── Cold-start seed helpers (Fix A / Fix B) ───

    /// @notice Wire a fresh project whose ERC-20 project token sorts BELOW its ERC-20 terminal token (project =
    /// token0), mirroring `SingleSided_OrderingTest` — the opposite of the default harness ordering.
    function _wireProjectToken0Codex(uint256 pid) internal returns (MockERC20 proj, MockERC20 term) {
        proj = new MockERC20("Proj0", "P0", 18);
        term = new MockERC20("Term1", "T1", 18);
        uint256 salt;
        while (address(proj) >= address(term)) {
            salt++;
            if (salt % 2 == 1) proj = new MockERC20("Proj0", "P0", 18);
            else term = new MockERC20("Term1", "T1", 18);
        }
        controller.setWeight(pid, DEFAULT_WEIGHT);
        controller.setFirstWeight(pid, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(pid, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(pid, 1);
        _setDirectoryController(pid, address(controller));
        _setDirectoryTerminal(pid, address(term), address(terminal));
        jbProjects.setOwner(pid, owner);
        terminal.setProjectToken(pid, address(proj));
        terminal.setAccountingContext(pid, address(term), uint32(uint160(address(term))), 18);
        terminal.addAccountingContext(
            pid, JBAccountingContext({token: address(term), decimals: 18, currency: uint32(uint160(address(term)))})
        );
        jbTokens.setToken(pid, address(proj));
        store.setBalance(address(terminal), pid, address(term), 10e18);
        _addDirectoryTerminal(pid, address(terminal));
    }

    function _accumulateFor(uint256 pid, MockERC20 proj, uint256 amount) internal {
        proj.mint(address(controller), amount);
        vm.startPrank(address(controller));
        proj.approve(address(hook), amount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildContext(pid, address(proj), amount, 1));
        vm.stopPrank();
    }

    function _spotTickFor(uint256 pid, address term) internal view returns (int24) {
        return TickMath.getTickAtSqrtPrice(_spotSqrtPriceFor(pid, term));
    }

    function _spotSqrtPriceFor(uint256 pid, address term) internal view returns (uint160 sqrtPriceX96) {
        PoolKey memory key = hook.poolKeyOf(pid, term);
        (sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(key.toId());
    }

    function _lockedSidesFor(
        uint256 tokenId,
        address term,
        address proj
    )
        internal
        view
        returns (uint256 projectSide, uint256 terminalSide)
    {
        (,,,, uint256 a0, uint256 a1,) = positionManager._positions(tokenId);
        bool terminalIsToken0 = term < proj;
        (projectSide, terminalSide) = terminalIsToken0 ? (a1, a0) : (a0, a1);
    }

    /// @notice Assert the live ask/bid sit exactly on the recycle geometry at the current spot: token0 on
    /// [max(spotCeil, corridorLower), corridorUpper], token1 on [corridorLower, min(spotFloor, corridorUpper)], where
    /// spotCeil is spotFloor when the spot sits exactly on it and one spacing above otherwise.
    function _assertRecycleGeometry(uint256 pid, address term, address proj) internal view {
        (int24 lo, int24 hi) = _corridorOf(pid, term, proj);
        int24 spotFloor =
            JBLPSplitHookHelpers.alignTickToSpacing({tick: _spotTickFor(pid, term), spacing: TICK_SPACING()});
        bool projectIsToken0 = proj < term;
        uint256 token0Id = projectIsToken0 ? hook.askTokenIdOf(pid, term) : hook.bidTokenIdOf(pid, term);
        uint256 token1Id = projectIsToken0 ? hook.bidTokenIdOf(pid, term) : hook.askTokenIdOf(pid, term);
        if (token0Id != 0) {
            (, int24 tickLower, int24 tickUpper,,,,) = positionManager._positions(token0Id);
            int24 spotCeil = TickMath.getSqrtPriceAtTick(spotFloor) == _spotSqrtPriceFor(pid, term)
                ? spotFloor
                : spotFloor + TICK_SPACING();
            assertEq(tickLower, spotCeil > lo ? spotCeil : lo, "token0 lower");
            assertEq(tickUpper, hi, "token0 upper is the corridor upper");
            assertLt(tickLower, tickUpper, "token0 range non-degenerate");
        }
        if (token1Id != 0) {
            (, int24 tickLower, int24 tickUpper,,,,) = positionManager._positions(token1Id);
            assertEq(tickLower, lo, "token1 lower is the corridor lower");
            assertEq(tickUpper, spotFloor < hi ? spotFloor : hi, "token1 upper");
            assertLt(tickLower, tickUpper, "token1 range non-degenerate");
        }
    }

    /// @notice Assert a cold-start deploy minted an asks-only position seeded strictly on the ask-fillable side of the
    /// issuance ceiling, with a non-degenerate range — the invariant both Fix A (zero-cashout) and Fix B (one-spacing
    /// corridor) must satisfy for either token ordering.
    function _assertColdStartAsksOnlyBelowCeiling(uint256 pid, address term, address proj) internal view {
        uint256 tokenId = hook.askTokenIdOf(pid, term);
        assertNotEq(tokenId, 0, "cold-start deploy must mint a position");

        (uint256 projectSide, uint256 terminalSide) = _lockedSidesFor(tokenId, term, proj);
        assertEq(terminalSide, 0, "cold-start deploy is asks-only (no terminal paired)");
        assertGt(projectSide, 0, "the project balance deploys as asks");

        (int24 lo, int24 hi) = _corridorOf(pid, term, proj);
        int24 spot = _spotTickFor(pid, term);
        if (proj < term) {
            // project = token0: asks fill upward toward the ceiling (upper tick); the seed must sit strictly below it.
            assertLt(spot, hi, "seed sits strictly below the issuance ceiling (upper tick)");
        } else {
            // project = token1: asks fill downward toward the ceiling (lower tick); the seed must sit strictly above
            // it.
            assertGt(spot, lo, "seed sits strictly above the issuance ceiling (lower tick)");
        }

        assertEq(hook.bidTokenIdOf(pid, term), 0, "no bid without terminal");
        _assertRecycleGeometry(pid, term, proj);
    }

    /// @notice Sweep the (linear) cash-out surplus to find a value that collapses the economic corridor to exactly one
    /// tick spacing, so the cold-start seed lands on the minimum-width corridor Fix B targets.
    function _findOneSpacingSurplus(uint256 pid, address term, address proj) internal returns (uint256) {
        int24 spacing = TICK_SPACING();
        for (uint256 i = 0; i < 600; i++) {
            uint256 surplus = 1e15 + i * 5e11;
            store.setSurplus(pid, surplus);
            (int24 lo, int24 hi) = _corridorOf(pid, term, proj);
            if (hi - lo == spacing) return surplus;
        }
        revert("no one-spacing surplus found");
    }

    // ─── Fix A (MEDIUM): a zero-cashout cold-start pool seeds strictly below the ceiling and deploys ───

    /// @notice Default ordering (project = token1): cashOutRate rounds to 0 (no surplus) with nonzero issuance. The
    /// hook-initialized pool seeds strictly on the ask side of the issuance ceiling, so the cold-start deploy SUCCEEDS
    /// (asks-only) rather than self-reverting on its own seed.
    function test_FixA_ZeroCashOut_ColdStartDeploys_DefaultOrdering() public {
        store.setSurplus(PROJECT_ID, 0);
        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        _assertColdStartAsksOnlyBelowCeiling(PROJECT_ID, address(terminalToken), address(projectToken));
    }

    /// @notice Mirror ordering (project = token0): the same zero-cashout cold-start deploy succeeds.
    function test_FixA_ZeroCashOut_ColdStartDeploys_ProjectToken0() public {
        uint256 pid = 21;
        (MockERC20 proj, MockERC20 term) = _wireProjectToken0Codex(pid);
        store.setSurplus(pid, 0);
        _accumulateFor(pid, proj, 0.5e18);
        vm.prank(owner);
        hook.deployPool(pid);
        _assertColdStartAsksOnlyBelowCeiling(pid, address(term), address(proj));
    }

    // ─── Fix B (LOW): a one-spacing-wide corridor cold-start yields a non-degenerate asks-only range ───

    /// @notice Default ordering (project = token1): a corridor exactly one tick spacing wide seeds the cold-start pool
    /// on the aligned floor bound, leaving a non-degenerate one-spacing asks-only range instead of collapsing to
    /// tickLower >= tickUpper.
    function test_FixB_OneSpacingCorridor_ColdStartDeploys_DefaultOrdering() public {
        uint256 surplus = _findOneSpacingSurplus(PROJECT_ID, address(terminalToken), address(projectToken));
        store.setSurplus(PROJECT_ID, surplus);
        (int24 lo, int24 hi) = _corridorOf(PROJECT_ID, address(terminalToken), address(projectToken));
        assertEq(hi - lo, TICK_SPACING(), "precondition: corridor is exactly one spacing wide");

        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        _assertColdStartAsksOnlyBelowCeiling(PROJECT_ID, address(terminalToken), address(projectToken));
    }

    /// @notice Mirror ordering (project = token0): a one-spacing corridor cold-start also deploys non-degenerately.
    function test_FixB_OneSpacingCorridor_ColdStartDeploys_ProjectToken0() public {
        uint256 pid = 22;
        (MockERC20 proj, MockERC20 term) = _wireProjectToken0Codex(pid);
        uint256 surplus = _findOneSpacingSurplus(pid, address(term), address(proj));
        store.setSurplus(pid, surplus);
        (int24 lo, int24 hi) = _corridorOf(pid, address(term), address(proj));
        assertEq(hi - lo, TICK_SPACING(), "precondition: corridor is exactly one spacing wide");

        _accumulateFor(pid, proj, 0.5e18);
        vm.prank(owner);
        hook.deployPool(pid);
        _assertColdStartAsksOnlyBelowCeiling(pid, address(term), address(proj));
    }

    /// @notice A wide corridor still seeds one aligned spacing inside the cash-out floor for the project = token0
    /// ordering (the token1 case is covered by `test_Finding9_FreshPoolSeedsAtFloor`).
    function test_FixB_WideCorridor_SeedsOneSpacingInsideFloor_ProjectToken0() public {
        uint256 pid = 23;
        (MockERC20 proj, MockERC20 term) = _wireProjectToken0Codex(pid);
        // A low surplus over a large supply keeps the cash-out floor genuinely below the issuance ceiling (wide band).
        store.setTaxedCashOutCurve({projectId: pid, surplus: 1e18, supply: 1_000_000e18, taxRate: 4000});

        (int24 corridorLower, int24 corridorUpper) = _corridorOf(pid, address(term), address(proj));
        // project = token0 → the cash-out floor is the corridor's LOWER tick; the seed sits one spacing inside it.
        int24 expectedSeedTick = corridorLower + TICK_SPACING();

        _accumulateFor(pid, proj, 0.5e18);
        vm.prank(owner);
        hook.deployPool(pid);

        assertEq(_spotTickFor(pid, address(term)), expectedSeedTick, "wide corridor seeds one spacing inside the floor");
        assertLt(expectedSeedTick, corridorUpper - TICK_SPACING() + 1, "seed stays strictly below the ceiling");
    }
}
