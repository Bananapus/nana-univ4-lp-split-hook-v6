// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Functional-correctness harness for the LP split hook's permissionless-deploy weight-decay gate.
/// @dev The hook's `_requireDeployOrAddAuth` skips the owner-permission requirement (i.e. allows ANYONE to call
///      `deployPool` / `addLiquidity`) once the current ruleset weight has decayed to <= 10% of the weight snapshotted
///      when accumulation began. The exact source predicate is:
///
///          requirePermission  ==  (initialWeight == 0 || currentWeight * 10 > initialWeight)
///          permissionless     ==  (initialWeight != 0 && currentWeight * 10 <= initialWeight)
///
///      `currentWeight`/`initialWeight` originate from `JBRuleset.weight`, a `uint112`, and the multiplication is
///      performed in `uint256` (`initialWeight` is a `uint256` storage slot), so `currentWeight * 10` cannot overflow
///      (`10 * (2**112 - 1) < 2**256`). This harness mirrors that predicate EXACTLY and proves its documented
///      decay-threshold semantics. Each property is dual halmos (`check_`) / fuzz (`testFuzz_`).
contract LPSplitHookAuthGateProperties is Test {
    /// @notice The maximum a `JBRuleset.weight` (uint112) can be — the real input domain bound.
    uint256 internal constant MAX_WEIGHT = type(uint112).max;

    /// @notice Mirror of the hook's gate: true when owner permission is REQUIRED (not permissionless).
    /// @dev Byte-for-byte the predicate in `JBUniswapV4LPSplitHook._requireDeployOrAddAuth`.
    /// @param currentWeight The current ruleset weight.
    /// @param initialWeight The accumulation-era snapshot weight.
    /// @return required True if owner SET_BUYBACK_POOL permission is required.
    function _permissionRequired(uint256 currentWeight, uint256 initialWeight) internal pure returns (bool required) {
        return initialWeight == 0 || currentWeight * 10 > initialWeight;
    }

    /// @dev Core decay-threshold contract:
    ///   - With no snapshot (initialWeight == 0) permission is ALWAYS required.
    ///   - With a snapshot, permissionless IFF the weight decayed to <= 10% (currentWeight*10 <= initialWeight).
    ///   - The gate is monotone: lowering currentWeight can only ever open access, never close it.
    function _assertGate(uint256 currentWeight, uint256 initialWeight) internal pure {
        bool required = _permissionRequired(currentWeight, initialWeight);

        // (1) No accumulation snapshot => always gated.
        if (initialWeight == 0) {
            assert(required);
            return;
        }

        // (2) Exact 10%-decay threshold equivalence.
        bool permissionless = !required;
        assert(permissionless == (currentWeight * 10 <= initialWeight));

        // (3) At-or-below the 10% point is open; strictly above is gated (boundary is inclusive on the open side).
        if (currentWeight * 10 <= initialWeight) {
            assert(permissionless);
        } else {
            assert(required);
        }

        // (4) Monotonicity: if a given weight is permissionless, every smaller weight is too.
        if (permissionless && currentWeight > 0) {
            assert(!_permissionRequired({currentWeight: currentWeight - 1, initialWeight: initialWeight}));
        }
    }

    /// @notice HALMOS: prove the decay-gate contract over the full uint112 weight domain.
    /// @param currentWeight Symbolic current weight.
    /// @param initialWeight Symbolic snapshot weight.
    function check_decayGateContract(uint256 currentWeight, uint256 initialWeight) public pure {
        // Constrain to the real (uint112) domain so the proof reflects production inputs and `*10` cannot overflow.
        if (currentWeight > MAX_WEIGHT) return;
        if (initialWeight > MAX_WEIGHT) return;
        _assertGate({currentWeight: currentWeight, initialWeight: initialWeight});
    }

    /// @notice FUZZ twin of {check_decayGateContract}.
    /// @param currentWeight Fuzzed current weight.
    /// @param initialWeight Fuzzed snapshot weight.
    function testFuzz_decayGateContract(uint256 currentWeight, uint256 initialWeight) public pure {
        currentWeight = bound(currentWeight, 0, MAX_WEIGHT);
        initialWeight = bound(initialWeight, 0, MAX_WEIGHT);
        _assertGate({currentWeight: currentWeight, initialWeight: initialWeight});
    }

    /// @dev Spot the documented "10x decay" wording: a weight at EXACTLY 10% is open, one wei above 10% is gated.
    function _assertTenXBoundary(uint256 initialWeight) internal pure {
        // Pick currentWeight = initialWeight / 10 (the largest weight that is exactly <= 10%).
        uint256 atThreshold = initialWeight / 10;
        // atThreshold*10 <= initialWeight always holds, so this must be permissionless when a snapshot exists.
        if (initialWeight != 0) {
            assert(!_permissionRequired({currentWeight: atThreshold, initialWeight: initialWeight}));
        }

        // One step above the threshold must be gated when it actually exceeds 10% (guards the rounding boundary).
        uint256 aboveThreshold = atThreshold + 1;
        if (aboveThreshold * 10 > initialWeight) {
            assert(_permissionRequired({currentWeight: aboveThreshold, initialWeight: initialWeight}));
        }
    }

    /// @notice HALMOS: prove the exact 10%-boundary behavior.
    /// @param initialWeight Symbolic snapshot weight.
    function check_tenXBoundary(uint256 initialWeight) public pure {
        if (initialWeight > MAX_WEIGHT) return;
        _assertTenXBoundary(initialWeight);
    }

    /// @notice FUZZ twin of {check_tenXBoundary}.
    /// @param initialWeight Fuzzed snapshot weight.
    function testFuzz_tenXBoundary(uint256 initialWeight) public pure {
        initialWeight = bound(initialWeight, 0, MAX_WEIGHT);
        _assertTenXBoundary(initialWeight);
    }
}
