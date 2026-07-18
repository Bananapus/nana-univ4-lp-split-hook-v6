// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Task 4: `addLiquidity` mints ANOTHER single-sided ask position from the project's post-deployment
/// accumulated reserved tokens — no funding cash-out — through the same `_addSingleSidedLiquidity` executor
/// `deployPool` uses. Covers the primary path: pool deployed, spot lifted by trading, more tokens accumulated, then
/// `addLiquidity` mints asks above the (new) live spot up to the corridor ceiling.
contract SingleSided_AddLiquidityTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;

    /// @notice Directly overwrite the pool's Slot0 tick/price in the mock PoolManager, simulating that organic
    /// trading against the deployed ask position pushed the pool's spot price to `tick`. Mirrors the packing
    /// `MockPositionManager._syncSlot0` uses so `StateLibrary.getSlot0` (and the spot-tracking base oracle, which
    /// reads live from the same PoolManager) both observe the moved price.
    function _setSpotTick(PoolKey memory key, int24 tick) internal {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        bytes32 poolId = PoolId.unwrap(key.toId());
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        uint24 lpFee = key.fee;
        // Pack: lpFee (24) | protocolFee (24) | tick (24) | sqrtPriceX96 (160) — same layout as the real
        // PoolManager's
        // Slot0 and `MockPositionManager._syncSlot0`.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 packed = bytes32((uint256(lpFee) << 208) | (uint256(uint24(tick)) << 160) | uint256(sqrtPriceX96));
        poolManager.writeSlot(stateSlot, packed);
    }

    function test_AddLiquidity_MintsAnotherSingleSidedAsk_NoCashOut() public {
        // Realistic corridor via the mock store's taxed-curve model (nonzero cashOutTaxRate), matching
        // SingleSided_DeployTest so the pre-set spot is guaranteed to land strictly inside [floor, ceiling].
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});

        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (int24 corridorLower, int24 corridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
        assertLt(corridorLower, corridorUpper, "precondition: corridor must be non-degenerate");

        // Initialize the pool a quarter of the way up the corridor, leaving room both for the initial deploy's ask
        // AND for a second, higher-spot ask after the simulated buy.
        int24 initialTick = corridorLower + (corridorUpper - corridorLower) / 4;
        uint160 initialSqrtPrice = TickMath.getSqrtPriceAtTick(initialTick);

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
        positionManager.initializePool(key, initialSqrtPrice);

        // Deploy: accumulate + deployPool mints the FIRST single-sided ask at the initial spot.
        _accumulateTokens(PROJECT_ID, 0.5e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        uint256 firstTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(firstTokenId, 0, "deployPool should have minted the first position");

        // Simulate a buy that lifts the pool's spot price roughly halfway between the initial spot and the
        // corridor ceiling — as if buyers traded through part of the first ask position.
        int24 liftedTick = initialTick + (corridorUpper - initialTick) / 2;
        assertLt(liftedTick, corridorUpper, "precondition: lifted spot must still leave room below the ceiling");
        _setSpotTick(key, liftedTick);

        // More reserved tokens accumulate after the deploy, as the "grow-and-route" stage describes.
        _accumulateTokens(PROJECT_ID, 0.3e18);

        uint256 cashOutCallsBefore = terminal.cashOutCallCount();
        uint256 accumulatedBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        assertEq(accumulatedBefore, 0.3e18, "ledger should hold exactly the post-deploy accumulation");

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        // (a) A (second) position is tracked, minted above the lifted spot.
        uint256 secondTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(secondTokenId, 0, "tokenIdOf should be nonzero after addLiquidity");
        assertNotEq(secondTokenId, firstTokenId, "addLiquidity should mint a fresh ask, not overwrite the first");

        // (b) The new position holds ZERO terminal tokens (asks-only) and the full post-deploy accumulation as its
        // project-token side.
        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(secondTokenId);
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        if (terminalIsToken0) {
            assertEq(amount0Locked, 0, "terminal-token side must be zero (asks-only)");
            assertEq(amount1Locked, 0.3e18, "project-token side should equal the post-deploy accumulation");
        } else {
            assertEq(amount1Locked, 0, "terminal-token side must be zero (asks-only)");
            assertEq(amount0Locked, 0.3e18, "project-token side should equal the post-deploy accumulation");
        }

        // (c) The new ask's range sits on the "above current spot, up to the ceiling" side of the corridor. In RAW
        // tick terms this is `[>=liftedTick, corridorUpper]` when the project token is currency0, or the mirror
        // `[corridorLower, <=liftedTick]` when the project token is currency1 (raw ticks price token1 in terms of
        // token0, so a project-as-token1 "ask" sits at or below the current tick) — `_addSingleSidedLiquidity`
        // branches on token ordering for exactly this reason.
        int24 newLower = hook.activeTickLowerOf(PROJECT_ID, address(terminalToken));
        int24 newUpper = hook.activeTickUpperOf(PROJECT_ID, address(terminalToken));
        if (terminalIsToken0) {
            assertEq(newLower, corridorLower, "the new ask should start at the corridor floor");
            assertLe(newUpper, liftedTick, "the new ask must not extend past the lifted spot");
        } else {
            assertGe(newLower, liftedTick, "the new ask must not dip below the lifted spot");
            assertEq(newUpper, corridorUpper, "the new ask should reach the corridor ceiling");
        }

        // (d) The hook never cashed out to fund the add.
        assertEq(terminal.cashOutCallCount(), cashOutCallsBefore, "addLiquidity must never call cashOutTokensOf");

        // (e) The ledger is fully cleared: the mock PositionManager consumes 100% of the offered amount by default,
        // so accumulatedProjectTokens decreased by exactly the added amount (no leftover to carry forward).
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            0,
            "no leftover expected at 100% PositionManager usage; ledger should be fully consumed"
        );
    }
}
