// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {MockGeomeanOracle} from "./mock/MockGeomeanOracle.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Task 5: `rebalanceLiquidity` is now PERMISSIONLESS and unifies onto `_consolidateAndReMint`. It burns the
/// project's single live position and re-mints ONE position across a freshly recomputed `[floor, ceiling]` corridor,
/// folding the recovered tokens (and any hook-held credits) back in and seeding the bid side from accrued terminal.
/// Guards: a drift threshold (reject churn when the corridor barely moved) and the spot-vs-TWAP check.
contract SingleSided_RebalanceTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant STRANGER = address(0xBEEF);

    /// @notice Set a realistic corridor, accumulate, and deploy the single-sided position. Also seed the hook with
    /// terminal tokens (an accrued bid side) and the PositionManager with both tokens so burns/mints settle.
    function _deploySingleSidedWithBid(uint256 projectAmount, uint256 bidAmount) internal returns (uint256 tokenId) {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});

        _accumulateTokens(PROJECT_ID, projectAmount);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Accrued terminal tokens sitting on the hook become the re-mint's bid side.
        terminalToken.mint(address(hook), bidAmount);
        // The PositionManager must hold enough of both tokens to satisfy TAKE_PAIR on burn and SWEEP after mint.
        projectToken.mint(address(positionManager), 1000e18);
        terminalToken.mint(address(positionManager), 1000e18);
    }

    function _freshCorridor() internal view returns (int24 floorTick, int24 ceilingTick) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (floorTick, ceilingTick) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    function _spotTick() internal view returns (int24) {
        PoolKey memory key = hook.poolKeyOf(PROJECT_ID, address(terminalToken));
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(key.toId());
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice A non-owner permissionlessly rebalances after the position's range has diverged from the fresh
    /// corridor. The position re-centers onto the full `[floor, ceiling]`, folds the accrued terminal in as the bid
    /// side, tracks exactly one live position, and emits `PermissionlessRebalanced`.
    function test_Rebalance_Permissionless_ReCentersAndUsesTerminalBid() public {
        uint256 oldTokenId = _deploySingleSidedWithBid({projectAmount: 0.5e18, bidAmount: 1e18});

        // The deploy minted a single-sided (asks-only) range; its bounds differ from the full corridor.
        int24 activeLowerBefore = hook.activeTickLowerOf(PROJECT_ID, address(terminalToken));
        int24 activeUpperBefore = hook.activeTickUpperOf(PROJECT_ID, address(terminalToken));
        (int24 floorTick, int24 ceilingTick) = _freshCorridor();

        // Preconditions: the spot is strictly inside the corridor (so the re-mint is genuinely two-sided), and the
        // fresh corridor diverges from the live range by more than the drift threshold on at least one bound.
        int24 spot = _spotTick();
        assertGt(spot, floorTick, "precondition: spot must sit above the corridor floor");
        assertLt(spot, ceilingTick, "precondition: spot must sit below the corridor ceiling");
        assertTrue(
            activeLowerBefore != floorTick || activeUpperBefore != ceilingTick,
            "precondition: single-sided range should differ from the full corridor"
        );

        bool terminalIsToken0 = address(terminalToken) < address(projectToken);

        // A complete stranger (no permission) triggers the rebalance.
        vm.expectEmit(true, true, false, true, address(hook));
        emit IJBUniswapV4LPSplitHook.PermissionlessRebalanced(
            PROJECT_ID, address(terminalToken), floorTick, ceilingTick, STRANGER
        );
        vm.prank(STRANGER);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));

        // Exactly one live position: the old id is burned, a fresh id is tracked.
        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(newTokenId, oldTokenId, "rebalance must mint a fresh position id");
        assertEq(positionManager.getPositionLiquidity(oldTokenId), 0, "old position must be burned, not orphaned");
        assertGt(positionManager.getPositionLiquidity(newTokenId), 0, "the tracked position must be live");

        // Re-centered exactly onto the fresh corridor.
        assertEq(hook.activeTickLowerOf(PROJECT_ID, address(terminalToken)), floorTick, "re-centered to fresh floor");
        assertEq(
            hook.activeTickUpperOf(PROJECT_ID, address(terminalToken)), ceilingTick, "re-centered to fresh ceiling"
        );

        // Two-sided: the accrued terminal seeded the bid side, and the recovered project tokens the ask side.
        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(newTokenId);
        uint256 terminalSide = terminalIsToken0 ? amount0Locked : amount1Locked;
        uint256 projectSide = terminalIsToken0 ? amount1Locked : amount0Locked;
        assertEq(terminalSide, 1e18, "the accrued terminal must be used as the position's bid side");
        assertEq(projectSide, 0.5e18, "the recovered project tokens must be re-minted as the ask side");

        // The hook never cashed out.
        assertEq(terminal.cashOutCallCount(), 0, "rebalance must never call cashOutTokensOf");
    }

    /// @notice A rebalance whose freshly recomputed corridor is within the drift threshold of the live position on
    /// BOTH bounds reverts `DriftBelowThreshold` — cheap churn is rejected.
    function test_Rebalance_RevertsWhenDriftBelowThreshold() public {
        _deploySingleSidedWithBid({projectAmount: 0.5e18, bidAmount: 1e18});

        // First rebalance (rates unchanged) re-centers the single-sided deploy onto the full corridor.
        vm.prank(STRANGER);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));

        // The live range now equals the fresh corridor exactly.
        (int24 floorTick, int24 ceilingTick) = _freshCorridor();
        assertEq(hook.activeTickLowerOf(PROJECT_ID, address(terminalToken)), floorTick, "sanity: on floor");
        assertEq(hook.activeTickUpperOf(PROJECT_ID, address(terminalToken)), ceilingTick, "sanity: on ceiling");

        // A second rebalance with the corridor unchanged has zero drift on both bounds → revert.
        vm.prank(STRANGER);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_DriftBelowThreshold.selector);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));
    }

    /// @notice A rebalance reverts when the pool's spot price has deviated too far from the oracle TWAP, so a
    /// sandwiched spot cannot skew the re-mint ratio. The drift guard passes first (single-sided deploy range differs
    /// from the full corridor), so the TWAP guard is the one that fires.
    function test_Rebalance_RevertsWhenSpotDeviatesFromTwap() public {
        _deploySingleSidedWithBid({projectAmount: 0.5e18, bidAmount: 1e18});

        // Pin a fixed-tick oracle far from the live spot (slot 1 == oracleHook).
        MockGeomeanOracle fixedOracle = new MockGeomeanOracle();
        fixedOracle.setTwapTick(_spotTick() + 1000);
        vm.store(address(hook), bytes32(uint256(1)), bytes32(uint256(uint160(address(fixedOracle)))));

        vm.prank(STRANGER);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_PriceDeviationTooHigh.selector);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));
    }
}
