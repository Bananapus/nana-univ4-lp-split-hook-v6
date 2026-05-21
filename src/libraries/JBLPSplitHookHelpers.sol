// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Pure helper functions shared by the Uniswap V4 LP split hook and formal proof harnesses.
library JBLPSplitHookHelpers {
    /// @notice Align a tick down to the nearest spacing boundary using floor semantics.
    /// @dev Solidity integer division truncates toward zero, so negative non-boundary ticks need an extra step to
    /// round toward negative infinity.
    /// @param tick The tick to align.
    /// @param spacing The positive tick spacing to align to.
    /// @return alignedTick The greatest spacing-aligned tick less than or equal to `tick`.
    function alignTickToSpacing(int24 tick, int24 spacing) internal pure returns (int24 alignedTick) {
        // Intentional: rounding tick down to nearest spacing boundary.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 rounded = (tick / spacing) * spacing;
        if (tick < 0 && rounded > tick) {
            rounded -= spacing;
        }
        return rounded;
    }

    /// @notice Align a tick up to the nearest spacing boundary using ceiling semantics.
    /// @dev Used for lower bounds so the LP range contracts inward instead of extending below the intended band.
    /// @param tick The tick to align.
    /// @param spacing The positive tick spacing to align to.
    /// @return alignedTick The least spacing-aligned tick greater than or equal to `tick`.
    function alignTickToSpacingCeil(int24 tick, int24 spacing) internal pure returns (int24 alignedTick) {
        // Intentional: rounding tick down first, then moving upward when `tick` was not already aligned.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 rounded = (tick / spacing) * spacing;
        if (rounded < tick) {
            rounded += spacing;
        }
        return rounded;
    }

    /// @notice Whether `terminalToken` is Juicebox's native-token sentinel.
    /// @param terminalToken The terminal token to check.
    /// @return isNative True if `terminalToken` represents native ETH.
    function isNativeToken(address terminalToken) internal pure returns (bool isNative) {
        return terminalToken == JBConstants.NATIVE_TOKEN;
    }

    /// @notice Sort two token addresses into canonical Uniswap V4 order.
    /// @param tokenA The first token address.
    /// @param tokenB The second token address.
    /// @return token0 The lower address.
    /// @return token1 The higher address.
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @notice Convert a Juicebox terminal-token address to the equivalent Uniswap V4 `Currency`.
    /// @dev Juicebox uses `JBConstants.NATIVE_TOKEN` for ETH; Uniswap V4 uses `address(0)`.
    /// @param terminalToken The Juicebox terminal token to convert.
    /// @return currency The equivalent Uniswap V4 currency.
    function toCurrency(address terminalToken) internal pure returns (Currency currency) {
        return Currency.wrap(isNativeToken(terminalToken) ? address(0) : terminalToken);
    }
}
