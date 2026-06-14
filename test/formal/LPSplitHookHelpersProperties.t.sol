// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBLPSplitHookHelpers} from "../../src/libraries/JBLPSplitHookHelpers.sol";

/// @notice Functional-correctness harness for the LP split hook's pure tick/token helpers.
/// @dev Each property is DUAL-implemented:
///        - `check_<name>(...)` proven symbolically by Halmos over the FULL int24/address domain.
///        - `testFuzz_<name>(...)` re-checked by the forge fuzzer.
///      All helpers under test are `internal pure`, so the proofs need no chain state.
///      These verify the documented spec of `JBLPSplitHookHelpers`:
///        * `alignTickToSpacing` = greatest spacing-multiple <= tick (floor)
///        * `alignTickToSpacingCeil` = least spacing-multiple >= tick (ceil)
///        * `sortTokens` returns the inputs in canonical (ascending) order
///        * native sentinel maps to `address(0)`, every other address maps to itself
contract LPSplitHookHelpersProperties is Test {
    /// @notice The hook's only production spacing (1% fee tier).
    int24 internal constant SPACING = 200;

    //*********************************************************************//
    // ------------------- alignTickToSpacing (floor) -------------------- //
    //*********************************************************************//

    /// @dev Spec of `alignTickToSpacing`: the greatest spacing-aligned tick <= `tick`.
    ///      Equivalent to mathematical floor(tick / spacing) * spacing for positive spacing.
    function _assertAlignDown(int24 tick) internal pure {
        int24 aligned = JBLPSplitHookHelpers.alignTickToSpacing({tick: tick, spacing: SPACING});

        // (1) Result is a multiple of spacing.
        assert(aligned % SPACING == 0);
        // (2) Floor: aligned <= tick.
        assert(aligned <= tick);
        // (3) Tight: the next boundary up is strictly above tick (so it really is the greatest such multiple).
        assert(int256(aligned) + int256(SPACING) > int256(tick));
        // (4) Matches a closed-form mathematical floor independent of the helper's branch structure.
        assert(aligned == _mathFloor(tick, SPACING));
    }

    /// @notice HALMOS: prove floor-alignment over the whole valid V4 tick range.
    /// @param tick The symbolic input tick.
    function check_alignDownIsMathematicalFloor(int24 tick) public pure {
        // Bound to the V4 usable range so the +spacing tightness check cannot overflow int24.
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) return;
        _assertAlignDown(tick);
    }

    /// @notice FUZZ twin of {check_alignDownIsMathematicalFloor}.
    /// @param tick The fuzzed input tick.
    function testFuzz_alignDownIsMathematicalFloor(int24 tick) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        _assertAlignDown(tick);
    }

    //*********************************************************************//
    // ------------------ alignTickToSpacingCeil (ceil) ------------------ //
    //*********************************************************************//

    /// @dev Spec of `alignTickToSpacingCeil`: the least spacing-aligned tick >= `tick`.
    function _assertAlignUp(int24 tick) internal pure {
        int24 aligned = JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: tick, spacing: SPACING});

        // (1) Result is a multiple of spacing.
        assert(aligned % SPACING == 0);
        // (2) Ceil: aligned >= tick.
        assert(aligned >= tick);
        // (3) Tight: the next boundary down is strictly below tick.
        assert(int256(aligned) - int256(SPACING) < int256(tick));
        // (4) Matches a closed-form mathematical ceil.
        assert(aligned == _mathCeil(tick, SPACING));
    }

    /// @notice HALMOS: prove ceil-alignment over the whole valid V4 tick range.
    /// @param tick The symbolic input tick.
    function check_alignUpIsMathematicalCeil(int24 tick) public pure {
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) return;
        _assertAlignUp(tick);
    }

    /// @notice FUZZ twin of {check_alignUpIsMathematicalCeil}.
    /// @param tick The fuzzed input tick.
    function testFuzz_alignUpIsMathematicalCeil(int24 tick) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        _assertAlignUp(tick);
    }

    /// @dev Ceil is never below floor and the two coincide exactly on aligned ticks, differ by one spacing otherwise.
    function _assertCeilFloorRelation(int24 tick) internal pure {
        int24 down = JBLPSplitHookHelpers.alignTickToSpacing({tick: tick, spacing: SPACING});
        int24 up = JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: tick, spacing: SPACING});

        assert(up >= down);
        if (tick % SPACING == 0) {
            // Already aligned: both reproduce the input.
            assert(down == tick && up == tick);
        } else {
            // Strictly between two boundaries: they straddle by exactly one spacing.
            assert(int256(up) - int256(down) == int256(SPACING));
        }
    }

    /// @notice HALMOS: floor and ceil straddle the input by exactly one spacing off-boundary, coincide on-boundary.
    /// @param tick The symbolic input tick.
    function check_ceilFloorStraddle(int24 tick) public pure {
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) return;
        _assertCeilFloorRelation(tick);
    }

    /// @notice FUZZ twin of {check_ceilFloorStraddle}.
    /// @param tick The fuzzed input tick.
    function testFuzz_ceilFloorStraddle(int24 tick) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        _assertCeilFloorRelation(tick);
    }

    /// @dev Alignment is idempotent: aligning an already-aligned tick is the identity.
    function _assertAlignIdempotent(int24 tick) internal pure {
        int24 down = JBLPSplitHookHelpers.alignTickToSpacing({tick: tick, spacing: SPACING});
        int24 up = JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: tick, spacing: SPACING});

        assert(JBLPSplitHookHelpers.alignTickToSpacing({tick: down, spacing: SPACING}) == down);
        assert(JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: down, spacing: SPACING}) == down);
        assert(JBLPSplitHookHelpers.alignTickToSpacing({tick: up, spacing: SPACING}) == up);
        assert(JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: up, spacing: SPACING}) == up);
    }

    /// @notice HALMOS: re-aligning an aligned tick is a no-op for both directions.
    /// @param tick The symbolic input tick.
    function check_alignIdempotent(int24 tick) public pure {
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) return;
        _assertAlignIdempotent(tick);
    }

    /// @notice FUZZ twin of {check_alignIdempotent}.
    /// @param tick The fuzzed input tick.
    function testFuzz_alignIdempotent(int24 tick) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        _assertAlignIdempotent(tick);
    }

    //*********************************************************************//
    // ----------------------------- sortTokens -------------------------- //
    //*********************************************************************//

    /// @dev Spec of `sortTokens`: returns the two inputs in ascending order, preserving the multiset.
    function _assertSort(address tokenA, address tokenB) internal pure {
        (address token0, address token1) = JBLPSplitHookHelpers.sortTokens({tokenA: tokenA, tokenB: tokenB});

        // Canonical (Uniswap) order.
        assert(token0 <= token1);
        // The pair is exactly the input pair (no value invented or dropped).
        assert((token0 == tokenA && token1 == tokenB) || (token0 == tokenB && token1 == tokenA));
        // Sorting is symmetric in its arguments.
        (address s0, address s1) = JBLPSplitHookHelpers.sortTokens({tokenA: tokenB, tokenB: tokenA});
        assert(s0 == token0 && s1 == token1);
    }

    /// @notice HALMOS: prove sort is canonical, multiset-preserving, and argument-symmetric.
    /// @param tokenA First address.
    /// @param tokenB Second address.
    function check_sortTokensCanonical(address tokenA, address tokenB) public pure {
        _assertSort(tokenA, tokenB);
    }

    /// @notice FUZZ twin of {check_sortTokensCanonical}.
    /// @param tokenA First address.
    /// @param tokenB Second address.
    function testFuzz_sortTokensCanonical(address tokenA, address tokenB) public pure {
        _assertSort(tokenA, tokenB);
    }

    //*********************************************************************//
    // ------------------------ toCurrency / native --------------------- //
    //*********************************************************************//

    /// @dev Spec of `toCurrency`: native sentinel -> address(0); every other token -> itself.
    ///      `isNativeToken` must agree with the JB native sentinel exactly.
    function _assertCurrency(address token) internal pure {
        bool isNative = JBLPSplitHookHelpers.isNativeToken(token);
        address mapped = Currency.unwrap(JBLPSplitHookHelpers.toCurrency(token));

        assert(isNative == (token == JBConstants.NATIVE_TOKEN));
        if (isNative) {
            assert(mapped == address(0));
        } else {
            assert(mapped == token);
        }
    }

    /// @notice HALMOS: prove the native-sentinel mapping for an arbitrary address.
    /// @param token The token to convert.
    function check_toCurrencyMapping(address token) public pure {
        _assertCurrency(token);
    }

    /// @notice FUZZ twin of {check_toCurrencyMapping}.
    /// @param token The token to convert.
    function testFuzz_toCurrencyMapping(address token) public pure {
        _assertCurrency(token);
    }

    //*********************************************************************//
    // ------------------------ closed-form oracles ---------------------- //
    //*********************************************************************//

    /// @notice Branch-independent mathematical floor of `tick/spacing*spacing` for positive `spacing`.
    /// @param tick The value to floor.
    /// @param spacing The positive spacing.
    /// @return The greatest multiple of `spacing` that is <= `tick`.
    function _mathFloor(int24 tick, int24 spacing) private pure returns (int24) {
        int256 q = int256(tick) / int256(spacing);
        int256 r = int256(tick) % int256(spacing);
        // Solidity truncates toward zero; for a negative remainder, step one boundary down.
        if (r < 0) q -= 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(q * int256(spacing));
    }

    /// @notice Branch-independent mathematical ceil of `tick/spacing*spacing` for positive `spacing`.
    /// @param tick The value to ceil.
    /// @param spacing The positive spacing.
    /// @return The least multiple of `spacing` that is >= `tick`.
    function _mathCeil(int24 tick, int24 spacing) private pure returns (int24) {
        int256 q = int256(tick) / int256(spacing);
        int256 r = int256(tick) % int256(spacing);
        // Solidity truncates toward zero; for a positive remainder, step one boundary up.
        if (r > 0) q += 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(q * int256(spacing));
    }
}
