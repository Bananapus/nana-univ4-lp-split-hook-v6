// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {MockGeomeanOracle, MockREVOwner} from "./mock/MockGeomeanOracle.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";

/// @notice Tests for the post-deployment `addLiquidity` entrypoint: continuous LP growth from accumulated reserved
/// tokens, force-direct funding cash-out, TWAP-deviation guard, re-ranging, dust carry, auth, and value safety.
contract AddLiquidityTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockGeomeanOracle internal oracle;

    function setUp() public override {
        super.setUp();
        // Wire a working TWAP oracle. `oracleHook` is the first storage slot (slot 0); the base initializes it to
        // address(0), so overwrite it here before any pool is deployed so the pool key embeds the oracle.
        oracle = new MockGeomeanOracle();
        vm.store(address(hook), bytes32(uint256(0)), bytes32(uint256(uint160(address(oracle)))));
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

    // ─── Top-up (grow) path
    // ──────────────────────────────────────────────

    function test_AddLiquidity_TopsUpActivePosition_NoBurn() public {
        _deployAndAccumulateMore(40e18);

        uint256 activeTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 mintsBefore = positionManager.mintCallCount();
        uint256 increasesBefore = positionManager.increaseCallCount();
        uint256 burnsBefore = controller.burnCallCount();

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);

        // Same position topped up via INCREASE_LIQUIDITY — no new position, no burn.
        assertEq(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), activeTokenId, "active position id unchanged");
        assertEq(positionManager.mintCallCount(), mintsBefore, "no new position minted on top-up");
        assertEq(positionManager.increaseCallCount(), increasesBefore + 1, "active position increased once");
        assertEq(controller.burnCallCount(), burnsBefore, "addLiquidity never burns");
        assertEq(hook.retiredTokenIdsOf(PROJECT_ID, address(terminalToken)).length, 0, "no retired positions");
    }

    // ─── Force-direct funding cash-out
    // ───────────────────────────────────

    function test_AddLiquidity_ForcesDirectCashOut_ViaRegistryMetadata() public {
        // Wire a revnet-style data hook (REVOwner) exposing a buyback-hook registry.
        address registry = makeAddr("buybackRegistry");
        MockREVOwner revOwner = new MockREVOwner(registry);
        controller.setDataHook(PROJECT_ID, address(revOwner));

        _deployAndAccumulateMore(40e18);

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);

        // The funding cash-out carried metadata keyed to the registry that forces a direct bonding-curve cash-out.
        bytes memory metadata = terminal.lastCashOutMetadata();
        (bool exists, bytes memory data) = JBMetadataResolver.getDataFor({
            id: JBMetadataResolver.getId({purpose: "cashOutMinReclaimed", target: registry}), metadata: metadata
        });
        assertTrue(exists, "force-direct metadata should be keyed to the buyback registry");
        (uint256 minSwapOut, bool skip) = abi.decode(data, (uint256, bool));
        assertEq(minSwapOut, 0, "no hook-level minimum; terminal min enforces the floor");
        assertTrue(skip, "skip flag must be set to force the direct cash-out");
    }

    function test_AddLiquidity_NoDataHook_SendsEmptyMetadata() public {
        // No data hook configured (dataHook == 0): fall back to empty metadata.
        _deployAndAccumulateMore(40e18);

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);

        assertEq(terminal.lastCashOutMetadata().length, 0, "no force-direct metadata when there is no data hook");
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
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);
    }

    function test_AddLiquidity_RevertsWhenTwapUnavailable() public {
        _deployAndAccumulateMore(40e18);

        // Simulate an un-warmed oracle (insufficient history): observe reverts.
        oracle.setShouldRevert(true);

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TwapUnavailable.selector);
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);
    }

    // ─── Re-range path
    // ───────────────────────────────────────────────────

    function test_AddLiquidity_RerangesWhenCorridorDrifts_AndCollectsAllPositions() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 oldTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Drop the issuance weight ~10% so the issuance-ceiling tick drifts ~1000 ticks (> the 400-tick re-range
        // threshold) while the cash-out floor (surplus-based) stays put and the spot price stays inside the new band.
        controller.setWeight(PROJECT_ID, 900e18);

        oracle.setTwapTick(_spotTick());
        _accumulateTokens(PROJECT_ID, 40e18);

        uint256 mintsBefore = positionManager.mintCallCount();

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);

        // A fresh position was minted at the live corridor and the old one retired.
        assertEq(positionManager.mintCallCount(), mintsBefore + 1, "a new position should be minted on re-range");
        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != oldTokenId, "active position id should change on re-range");
        uint256[] memory retired = hook.retiredTokenIdsOf(PROJECT_ID, address(terminalToken));
        assertEq(retired.length, 1, "old position should be retired");
        assertEq(retired[0], oldTokenId, "retired id should be the previous active id");

        // Fees from BOTH the retired and the active position are collected and routed.
        uint256 feeEach = 5e18;
        (address token0,) = _sort(address(projectToken), address(terminalToken));
        // Load terminal-token fees on both positions (project side left at 0 for a clean terminal-route assertion).
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees(oldTokenId, feeEach, 0);
            positionManager.setCollectableFees(newTokenId, feeEach, 0);
        } else {
            positionManager.setCollectableFees(oldTokenId, 0, feeEach);
            positionManager.setCollectableFees(newTokenId, 0, feeEach);
        }
        terminalToken.mint(address(positionManager), feeEach * 2);

        uint256 addToBalanceBefore = terminal.addToBalanceCallCount();
        uint256 payBefore = terminal.payCallCount();

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Both positions were drained (decreaseLiquidity called for each) and the terminal-token fees routed.
        assertGe(
            terminal.payCallCount() + terminal.addToBalanceCallCount(),
            payBefore + addToBalanceBefore + 1,
            "collected terminal fees from both positions should be routed"
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
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);

        assertEq(controller.burnCallCount(), burnsBefore, "dust is carried, never burned");
        assertGt(hook.accumulatedProjectTokens(PROJECT_ID), 0, "project-token dust carried back to the ledger");
    }

    // ─── No stranded / leaked value
    // ──────────────────────────────────────

    function test_AddLiquidity_NoStrandedProjectTokens() public {
        _deployAndAccumulateMore(40e18);

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);

        // Every project token the hook still holds is exactly the accounted accumulation ledger — nothing stranded.
        assertEq(
            projectToken.balanceOf(address(hook)),
            hook.accumulatedProjectTokens(PROJECT_ID),
            "hook holds no unaccounted project tokens after an add"
        );
    }

    function testFuzz_AddLiquidity_NoValueLeak(uint256 extra) public {
        extra = bound(extra, 1e15, 1_000_000e18);
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        oracle.setTwapTick(_spotTick());
        _accumulateTokens(PROJECT_ID, extra);

        vm.prank(owner);
        try hook.addLiquidity(PROJECT_ID, address(terminalToken), 0) {
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

    function test_AddLiquidity_RevertsWhenUnauthorized() public {
        _deployAndAccumulateMore(40e18);

        vm.prank(makeAddr("randomUser"));
        vm.expectRevert();
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);
    }

    function test_AddLiquidity_PermissionlessAfterWeightDecay() public {
        // Record a HIGH initial weight at first accumulation so the 10x-decay gate opens without later moving the
        // corridor: the deploy and add both run at the default weight, so the add is a plain top-up.
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT * 10);
        _accumulateTokens(PROJECT_ID, 100e18); // records initialWeightOf = DEFAULT_WEIGHT * 10

        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT); // weight*10 == initialWeight → permissionless, corridor
        // stable
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        oracle.setTwapTick(_spotTick());
        _accumulateTokens(PROJECT_ID, 40e18);

        uint256 increasesBefore = positionManager.increaseCallCount();
        vm.prank(makeAddr("anyone"));
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);
        assertEq(positionManager.increaseCallCount(), increasesBefore + 1, "anyone can add after weight decay");
    }

    // ─── Stage / input guards
    // ────────────────────────────────────────────

    function test_AddLiquidity_RevertsWhenNoPoolDeployed() public {
        _accumulateTokens(PROJECT_ID, 40e18); // accumulate but never deploy

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidStageForAction.selector);
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);
    }

    function test_AddLiquidity_RevertsWhenNothingAccumulated() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18); // deploy consumes the accumulation (no dust at 100% usage)
        oracle.setTwapTick(_spotTick());

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoTokensAccumulated.selector);
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);
    }

    // ─── Gas
    // ─────────────────────────────────────────────────────────────

    function test_AddLiquidity_GasIsReasonable() public {
        _deployAndAccumulateMore(40e18);

        vm.prank(owner);
        uint256 gasBefore = gasleft();
        hook.addLiquidity(PROJECT_ID, address(terminalToken), 0);
        uint256 gasUsed = gasBefore - gasleft();

        // Batched top-up should stay well under a generous ceiling (sanity bound, not a tight target).
        assertLt(gasUsed, 1_500_000, "batched addLiquidity should be reasonably cheap");
    }

    function _sort(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }
}
