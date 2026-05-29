// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Minimal mock of the shared Uniswap V4 geomean oracle hook used by JBUniswapV4LPSplitHook's TWAP guard.
/// @dev `observe` returns cumulative ticks such that `(tickCumulatives[last] - tickCumulatives[0]) / window` equals the
/// effective tick, where `window = secondsAgos[0] - secondsAgos[last]`. The effective tick is the configured
/// `twapTick`, or — when `trackSpot` is enabled via `enableSpotTracking` — the pool's live spot tick (so the hook's
/// spot-vs-TWAP guard passes by default in tests that aren't specifically exercising deviation). Set `shouldRevert` to
/// simulate an un-warmed oracle (insufficient history), which makes `observe` revert like the real Oracle library does.
///
/// @dev Also a minimal *passive* Uniswap V4 hook: it implements only `afterInitialize` (flag `AFTER_INITIALIZE_FLAG`)
/// so fork pools can legitimately embed it as their `hooks` (real V4 validates hook-permission flags at pool init).
/// It deliberately has NO swap callbacks, so — unlike the production routing oracle — it never intercepts swaps;
/// fork
/// swap helpers keep working unchanged. Deploy it at a flag-valid address with HookMiner when used on real V4.
contract MockGeomeanOracle {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice V4 `afterInitialize` callback — returns its own selector so PoolManager accepts the pool init.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    int24 public twapTick;
    bool public shouldRevert;
    IPoolManager public poolManager;
    bool public trackSpot;

    function setTwapTick(int24 tick) external {
        twapTick = tick;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    /// @notice Make `observe` report a TWAP equal to the pool's live spot tick, so the hook's spot-vs-TWAP guard passes
    /// by default. Wired by the shared test base so every pool-guarded path (deploy/add/rebalance) works without each
    /// test having to align the TWAP; tests that exercise deviation override this oracle with a fixed `twapTick`.
    /// @param pm The pool manager to read the live spot tick from.
    function enableSpotTracking(IPoolManager pm) external {
        poolManager = pm;
        trackSpot = true;
    }

    function observe(
        PoolKey calldata key,
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (shouldRevert) revert("MockGeomeanOracle: insufficient history");

        uint256 n = secondsAgos.length;
        tickCumulatives = new int56[](n);
        secondsPerLiquidityCumulativeX128s = new uint160[](n);

        if (n < 2) return (tickCumulatives, secondsPerLiquidityCumulativeX128s);

        // Effective tick: the pool's live spot tick when spot-tracking, otherwise the configured fixed `twapTick`.
        int24 tick = twapTick;
        if (trackSpot) {
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        }

        // window = secondsAgos[0] (older) - secondsAgos[last] (newer, usually 0).
        uint32 window = secondsAgos[0] - secondsAgos[n - 1];

        // delta = tick * window, placed across [0 .. last] so the consumer's mean recovers the effective tick exactly.
        int56 delta = int56(tick) * int56(uint56(window));
        tickCumulatives[0] = 0;
        tickCumulatives[n - 1] = delta;
        // Nonzero liquidity cumulative so any harmonic-mean liquidity sanity check passes.
        secondsPerLiquidityCumulativeX128s[n - 1] = uint160(window);
    }
}
