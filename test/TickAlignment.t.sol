// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

/// @notice Regression test for asymmetric tick alignment in `JBUniswapV4LPSplitHook._calculateTickBounds`. Before
/// the fix, both `tickLower` and `tickUpper` were aligned via the floor helper, expanding the LP lower bound by up
/// to one tick-spacing interval. The fix ceils `tickLower` and floors `tickUpper` so the range contracts on both
/// sides toward the intended price band. This test reproduces both alignment helpers' math inline so no live hook
/// instance is needed.
contract TickAlignmentTest is Test {
    int24 internal constant SPACING = 60;

    /// @dev Mirrors `JBUniswapV4LPSplitHook._alignTickToSpacing` (floor).
    function _alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rounded = (tick / spacing) * spacing;
        if (tick < 0 && rounded > tick) {
            rounded -= spacing;
        }
        return rounded;
    }

    /// @dev Mirrors `JBUniswapV4LPSplitHook._alignTickToSpacingCeil` (ceiling).
    function _alignUp(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rounded = (tick / spacing) * spacing;
        if (rounded < tick) {
            rounded += spacing;
        }
        return rounded;
    }

    function test_alignDown_positiveNonBoundary_roundsToLowerBoundary() public pure {
        assertEq(_alignDown({tick: 100, spacing: SPACING}), 60);
        assertEq(_alignDown({tick: 119, spacing: SPACING}), 60);
    }

    function test_alignDown_positiveOnBoundary_returnsItself() public pure {
        assertEq(_alignDown({tick: 60, spacing: SPACING}), 60);
        assertEq(_alignDown({tick: 120, spacing: SPACING}), 120);
    }

    function test_alignDown_negativeNonBoundary_roundsToMoreNegative() public pure {
        assertEq(_alignDown({tick: -100, spacing: SPACING}), -120);
        assertEq(_alignDown({tick: -1, spacing: SPACING}), -60);
    }

    function test_alignDown_negativeOnBoundary_returnsItself() public pure {
        assertEq(_alignDown({tick: -60, spacing: SPACING}), -60);
        assertEq(_alignDown({tick: -120, spacing: SPACING}), -120);
    }

    function test_alignUp_positiveNonBoundary_roundsToUpperBoundary() public pure {
        assertEq(_alignUp({tick: 100, spacing: SPACING}), 120);
        assertEq(_alignUp({tick: 61, spacing: SPACING}), 120);
    }

    function test_alignUp_positiveOnBoundary_returnsItself() public pure {
        assertEq(_alignUp({tick: 60, spacing: SPACING}), 60);
        assertEq(_alignUp({tick: 120, spacing: SPACING}), 120);
    }

    function test_alignUp_negativeNonBoundary_roundsToLessNegative() public pure {
        assertEq(_alignUp({tick: -100, spacing: SPACING}), -60);
        assertEq(_alignUp({tick: -119, spacing: SPACING}), -60);
    }

    function test_alignUp_negativeOnBoundary_returnsItself() public pure {
        assertEq(_alignUp({tick: -60, spacing: SPACING}), -60);
        assertEq(_alignUp({tick: -120, spacing: SPACING}), -120);
    }

    function test_alignmentAsymmetry_contractsRangeOnBothSides() public pure {
        // For a raw range (50, 130) and spacing 60, the pre-fix flooring of both ticks would yield (0, 120) —
        // wider on the lower side. With the asymmetric fix, (60, 120) — strictly inside the raw range.
        int24 rawLower = 50;
        int24 rawUpper = 130;
        int24 alignedLower = _alignUp({tick: rawLower, spacing: SPACING});
        int24 alignedUpper = _alignDown({tick: rawUpper, spacing: SPACING});
        assertGe(alignedLower, rawLower, "tickLower must not be below raw");
        assertLe(alignedUpper, rawUpper, "tickUpper must not be above raw");
        assertEq(alignedLower, 60);
        assertEq(alignedUpper, 120);
    }
}
