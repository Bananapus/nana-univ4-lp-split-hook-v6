// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {JBLPSplitHookHelpers} from "../../src/libraries/JBLPSplitHookHelpers.sol";

/// @notice Halmos smoke proofs for the LP split hook's pure token-ordering and tick-alignment helpers.
contract JBUniswapV4LPSplitHookHalmos {
    /// @notice The hook's fixed Uniswap V4 spacing, mirrored as int24 for helper calls.
    int24 internal constant _TICK_SPACING = 200;

    /// @notice The hook's fixed Uniswap V4 spacing, mirrored as int256 for range assertions.
    int256 internal constant _TICK_SPACING_INT = 200;

    /// @notice Checks floor alignment at signed-division and TickMath-adjacent boundaries.
    function check_alignDownBoundaryTable() public pure {
        _assertAlignDown({tick: -887_272, expected: -887_400});
        _assertAlignDown({tick: -887_201, expected: -887_400});
        _assertAlignDown({tick: -887_200, expected: -887_200});
        _assertAlignDown({tick: -201, expected: -400});
        _assertAlignDown({tick: -200, expected: -200});
        _assertAlignDown({tick: -199, expected: -200});
        _assertAlignDown({tick: -1, expected: -200});
        _assertAlignDown({tick: 0, expected: 0});
        _assertAlignDown({tick: 1, expected: 0});
        _assertAlignDown({tick: 199, expected: 0});
        _assertAlignDown({tick: 200, expected: 200});
        _assertAlignDown({tick: 201, expected: 200});
        _assertAlignDown({tick: 887_199, expected: 887_000});
        _assertAlignDown({tick: 887_200, expected: 887_200});
        _assertAlignDown({tick: 887_272, expected: 887_200});
    }

    /// @notice Checks ceiling alignment at signed-division and TickMath-adjacent boundaries.
    function check_alignUpBoundaryTable() public pure {
        _assertAlignUp({tick: -887_272, expected: -887_200});
        _assertAlignUp({tick: -887_201, expected: -887_200});
        _assertAlignUp({tick: -887_200, expected: -887_200});
        _assertAlignUp({tick: -201, expected: -200});
        _assertAlignUp({tick: -200, expected: -200});
        _assertAlignUp({tick: -199, expected: 0});
        _assertAlignUp({tick: -1, expected: 0});
        _assertAlignUp({tick: 0, expected: 0});
        _assertAlignUp({tick: 1, expected: 200});
        _assertAlignUp({tick: 199, expected: 200});
        _assertAlignUp({tick: 200, expected: 200});
        _assertAlignUp({tick: 201, expected: 400});
        _assertAlignUp({tick: 887_199, expected: 887_200});
        _assertAlignUp({tick: 887_200, expected: 887_200});
        _assertAlignUp({tick: 887_272, expected: 887_400});
    }

    /// @notice Proves token sorting preserves both inputs and returns them in canonical order.
    /// @param tokenA The first token address.
    /// @param tokenB The second token address.
    function check_sortTokensReturnsCanonicalPair(address tokenA, address tokenB) public pure {
        (address token0, address token1) = JBLPSplitHookHelpers.sortTokens({tokenA: tokenA, tokenB: tokenB});

        assert(token0 <= token1);
        assert((token0 == tokenA && token1 == tokenB) || (token0 == tokenB && token1 == tokenA));
    }

    /// @notice Proves Juicebox's native-token sentinel maps to Uniswap V4's native currency.
    function check_nativeTokenMapsToZeroCurrency() public pure {
        assert(JBLPSplitHookHelpers.isNativeToken(JBConstants.NATIVE_TOKEN));
        assert(Currency.unwrap(JBLPSplitHookHelpers.toCurrency(JBConstants.NATIVE_TOKEN)) == address(0));
    }

    /// @notice Proves non-native tokens map through unchanged.
    /// @param token The token to convert.
    function check_nonNativeTokenMapsToItself(address token) public pure {
        if (token == JBConstants.NATIVE_TOKEN) return;

        assert(!JBLPSplitHookHelpers.isNativeToken(token));
        assert(Currency.unwrap(JBLPSplitHookHelpers.toCurrency(token)) == token);
    }

    /// @notice Assert one floor-alignment table row and its generic spacing properties.
    /// @param tick The input tick.
    /// @param expected The expected floor-aligned tick.
    function _assertAlignDown(int24 tick, int24 expected) internal pure {
        int24 aligned = JBLPSplitHookHelpers.alignTickToSpacing({tick: tick, spacing: _TICK_SPACING});
        int256 delta = int256(int24(tick)) - int256(int24(aligned));

        assert(aligned == expected);
        assert(int256(int24(aligned)) <= int256(int24(tick)));
        assert(delta >= 0);
        assert(delta < _TICK_SPACING_INT);
        // Once aligned, dividing and multiplying by spacing must reproduce the same boundary.
        // forge-lint: disable-next-line(divide-before-multiply)
        assert(int256(int24(aligned)) == (int256(int24(aligned)) / _TICK_SPACING_INT) * _TICK_SPACING_INT);
    }

    /// @notice Assert one ceiling-alignment table row and its generic spacing properties.
    /// @param tick The input tick.
    /// @param expected The expected ceiling-aligned tick.
    function _assertAlignUp(int24 tick, int24 expected) internal pure {
        int24 aligned = JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: tick, spacing: _TICK_SPACING});
        int256 delta = int256(int24(aligned)) - int256(int24(tick));

        assert(aligned == expected);
        assert(int256(int24(aligned)) >= int256(int24(tick)));
        assert(delta >= 0);
        assert(delta < _TICK_SPACING_INT);
        // Once aligned, dividing and multiplying by spacing must reproduce the same boundary.
        // forge-lint: disable-next-line(divide-before-multiply)
        assert(int256(int24(aligned)) == (int256(int24(aligned)) / _TICK_SPACING_INT) * _TICK_SPACING_INT);
    }
}
