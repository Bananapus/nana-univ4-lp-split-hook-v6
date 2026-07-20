// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {MockGeomeanOracle} from "./mock/MockGeomeanOracle.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";

/// @notice Tests for the post-deployment `addLiquidity` entrypoint: continuous LP growth from accumulated reserved
/// tokens (consolidated as a single adaptive position, never a funding cash-out), the TWAP-deviation guard,
/// re-ranging, dust carry, permissionless access, and value safety.
contract AddLiquidityTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockGeomeanOracle internal oracle;

    function setUp() public override {
        super.setUp();
        // Override the base's spot-tracking oracle with a fixed-tick one so these tests can drive the TWAP explicitly
        // (deviation / unavailable cases). Overwrite it before any pool is deployed so the pool key embeds this
        // oracle.
        oracle = new MockGeomeanOracle();
        _overrideOracleHook(address(oracle));
    }

    // ─── Helpers
    // ─────────────────────────────────────────────────────────

    function _spotTick() internal view returns (int24) {
        PoolKey memory key = hook.poolKeyOf(PROJECT_ID, address(terminalToken));
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(key.toId());
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice Deploy a pool, align the oracle TWAP to the pool's spot price, and accumulate `extra` more tokens.
    function _deployAndAccumulateMore(uint256 extra) internal {
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        oracle.setTwapTick(_spotTick());
        _accumulateTokens(PROJECT_ID, extra);
    }

    // ─── Grow path: consolidate (burn + re-mint), never funding cash-out
    // ──────────────────────────────

    /// @notice `addLiquidity` consolidates: it burns the live position and re-mints ONE adaptive position that folds
    /// the recovered principal plus the newly accumulated tokens — it never tops up in place, and it never funds the
    /// add with a cash-out (no `cashOutTokensOf`, no project-token burn).
    function test_AddLiquidity_Consolidates_BurnsAndReMints_NoCashOut() public {
        _deployAndAccumulateMore(40e18);

        uint256 activeTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 mintsBefore = positionManager.mintCallCount();
        uint256 positionBurnsBefore = positionManager.burnCallCount();
        uint256 tokenBurnsBefore = controller.burnCallCount();
        uint256 cashOutsBefore = terminal.cashOutCallCount();

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        // The live position is burned and a single fresh position is minted (consolidation), not topped up in place.
        assertEq(positionManager.burnCallCount(), positionBurnsBefore + 1, "the live position must be burned");
        assertEq(positionManager.mintCallCount(), mintsBefore + 1, "a single fresh position must be minted");
        assertNotEq(
            hook.tokenIdOf(PROJECT_ID, address(terminalToken)), activeTokenId, "the tracked position id must change"
        );
        // The hook never burns project tokens and never funds the add via a cash-out.
        assertEq(controller.burnCallCount(), tokenBurnsBefore, "addLiquidity never burns project tokens");
        assertEq(terminal.cashOutCallCount(), cashOutsBefore, "addLiquidity never calls cashOutTokensOf");
    }

    // ─── TWAP-deviation guard
    // ────────────────────────────────────────────

    function test_AddLiquidity_RevertsWhenSpotDeviatesFromTwap() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        _accumulateTokens(PROJECT_ID, 40e18);

        // Push the oracle TWAP far from the pool's spot price (simulating a pool-price sandwich before our add).
        oracle.setTwapTick(_spotTick() + 1000);

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_PriceDeviationTooHigh.selector);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
    }

    function test_AddLiquidity_RevertsWhenTwapUnavailable() public {
        _deployAndAccumulateMore(40e18);

        // Simulate an un-warmed oracle (insufficient history): observe reverts.
        oracle.setShouldRevert(true);

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TwapUnavailable.selector);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
    }

    // ─── Re-range path
    // ───────────────────────────────────────────────────

    function test_AddLiquidity_RerangesByBurningAndReminting() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 oldTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Drop the issuance weight ~10% so the issuance-ceiling tick drifts ~1000 ticks (> the 400-tick re-range
        // threshold) while the cash-out floor (surplus-based) stays put and the spot price stays inside the new band.
        controller.setWeight(PROJECT_ID, 900e18);

        oracle.setTwapTick(_spotTick());
        _accumulateTokens(PROJECT_ID, 40e18);

        uint256 mintsBefore = positionManager.mintCallCount();
        uint256 positionBurnsBefore = positionManager.burnCallCount();
        uint256 tokenBurnsBefore = controller.burnCallCount();

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        // The stale position is BURNED and a single fresh position is re-minted at the live corridor — funds
        // consolidate into one position (no retired set), and no project tokens are burned.
        assertEq(
            positionManager.burnCallCount(), positionBurnsBefore + 1, "stale position should be burned on re-range"
        );
        assertEq(positionManager.mintCallCount(), mintsBefore + 1, "a single fresh position should be minted");
        assertEq(controller.burnCallCount(), tokenBurnsBefore, "re-range never burns project tokens");
        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != oldTokenId, "active position id should change on re-range");

        // Fees are collected from the single (new) position and routed.
        uint256 fee = 5e18;
        (address token0,) = _sort(address(projectToken), address(terminalToken));
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees(newTokenId, fee, 0);
        } else {
            positionManager.setCollectableFees(newTokenId, 0, fee);
        }
        terminalToken.mint(address(positionManager), fee);

        uint256 addToBalanceBefore = terminal.addToBalanceCallCount();
        uint256 payBefore = terminal.payCallCount();

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // The terminal-token fees from the active position were routed.
        assertGe(
            terminal.payCallCount() + terminal.addToBalanceCallCount(),
            payBefore + addToBalanceBefore + 1,
            "collected terminal fees should be routed"
        );
    }

    // ─── Dust carry
    // ──────────────────────────────────────────────────────

    function test_AddLiquidity_CarriesDustForward_NeverBurns() public {
        // PositionManager only consumes 80% of supplied amounts → leftover dust on the add.
        positionManager.setUsagePercent(8000);
        _deployAndAccumulateMore(40e18);

        uint256 burnsBefore = controller.burnCallCount();

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        assertEq(controller.burnCallCount(), burnsBefore, "dust is carried, never burned");
        assertGt(hook.accumulatedProjectTokens(PROJECT_ID), 0, "project-token dust carried back to the ledger");
    }

    // ─── No stranded / leaked value
    // ──────────────────────────────────────

    function test_AddLiquidity_NoStrandedProjectTokens() public {
        _deployAndAccumulateMore(40e18);

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        // Every project token the hook still holds is exactly the accounted accumulation ledger — nothing stranded.
        assertEq(
            projectToken.balanceOf(address(hook)),
            hook.accumulatedProjectTokens(PROJECT_ID),
            "hook holds no unaccounted project tokens after an add"
        );
    }

    function test_AddLiquidity_NoStrandedProjectTokens_WhenHookHasCredits() public {
        _deployAndAccumulateMore(40e18);

        // Model core cash-outs that burn a holder's credits before touching the ERC-20 balance. A third party can
        // send credits to the hook even though the normal reserved-token flow only accumulates ERC-20s here.
        terminal.setTokens(address(jbTokens));
        jbTokens.setCreditBalance(address(hook), PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        // Every project token the hook still holds is exactly the accounted accumulation ledger — nothing stranded.
        assertEq(
            projectToken.balanceOf(address(hook)),
            hook.accumulatedProjectTokens(PROJECT_ID),
            "hook holds no unaccounted project tokens after a credit-backed cash-out"
        );
    }

    function testFuzz_AddLiquidity_NoValueLeak(uint256 extra) public {
        extra = bound(extra, 1e15, 1_000_000e18);
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        oracle.setTwapTick(_spotTick());
        _accumulateTokens(PROJECT_ID, extra);

        vm.prank(owner);
        try hook.addLiquidity(PROJECT_ID, address(terminalToken)) {
            // Invariant: the hook never leaves project tokens unaccounted (everything is either in the LP or in the
            // accumulation ledger). An interacting EOA cannot extract value beyond the carried ledger.
            assertEq(
                projectToken.balanceOf(address(hook)),
                hook.accumulatedProjectTokens(PROJECT_ID),
                "no project-token value leaked or stranded"
            );
            assertEq(controller.burnCallCount(), 0, "no burns across the lifecycle");
        } catch {
            // A revert (e.g. zero-liquidity at extreme ratios) leaves all tokens in the ledger — also no leak.
        }
    }

    // ─── Access control
    // ──────────────────────────────────────────────────

    /// @notice `addLiquidity` is fully permissionless: a random caller (no owner permission, no weight decay) can
    /// extend the pool. The old owner gate is gone.
    function test_AddLiquidity_Permissionless_AnyCallerCanExtend() public {
        _deployAndAccumulateMore(40e18);

        uint256 firstId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        vm.prank(makeAddr("randomUser"));
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        assertNotEq(
            hook.tokenIdOf(PROJECT_ID, address(terminalToken)), firstId, "a permissionless caller consolidates the add"
        );
    }

    // ─── Stage / input guards
    // ────────────────────────────────────────────

    function test_AddLiquidity_RevertsWhenNoPoolDeployed() public {
        _accumulateTokens(PROJECT_ID, 40e18); // accumulate but never deploy

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidStageForAction.selector);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
    }

    function test_AddLiquidity_RevertsWhenNothingAccumulated() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18); // deploy consumes the accumulation (no dust at 100% usage)
        oracle.setTwapTick(_spotTick());

        // With nothing (or only dust) accumulated, addLiquidity reverts on the dust-churn threshold guard rather than
        // forcing a re-mint. Zero accumulation is below the threshold too.
        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_AccumulationBelowThreshold.selector);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
    }

    // ─── Gas
    // ─────────────────────────────────────────────────────────────

    function test_AddLiquidity_GasIsReasonable() public {
        _deployAndAccumulateMore(40e18);

        vm.prank(owner);
        uint256 gasBefore = gasleft();
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
        uint256 gasUsed = gasBefore - gasleft();

        // Batched top-up should stay well under a generous ceiling (sanity bound, not a tight target).
        assertLt(gasUsed, 1_500_000, "batched addLiquidity should be reasonably cheap");
    }

    function _sort(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }
}
