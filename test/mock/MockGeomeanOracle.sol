// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Minimal mock of the shared Uniswap V4 geomean oracle hook used by JBUniswapV4LPSplitHook's TWAP guard.
/// @dev `observe` returns cumulative ticks such that `(tickCumulatives[last] - tickCumulatives[0]) / window` equals the
/// configured `twapTick`, where `window = secondsAgos[0] - secondsAgos[last]`. Set `shouldRevert` to simulate an
/// un-warmed oracle (insufficient history), which makes `observe` revert like the real Oracle library does.
contract MockGeomeanOracle {
    int24 public twapTick;
    bool public shouldRevert;

    function setTwapTick(int24 tick) external {
        twapTick = tick;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function observe(
        PoolKey calldata,
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

        // window = secondsAgos[0] (older) - secondsAgos[last] (newer, usually 0).
        uint32 window = secondsAgos[0] - secondsAgos[n - 1];

        // delta = twapTick * window, placed across [0 .. last] so the consumer's mean recovers twapTick exactly.
        int56 delta = int56(twapTick) * int56(uint56(window));
        tickCumulatives[0] = 0;
        tickCumulatives[n - 1] = delta;
        // Nonzero liquidity cumulative so any harmonic-mean liquidity sanity check passes.
        secondsPerLiquidityCumulativeX128s[n - 1] = uint160(window);
    }
}
