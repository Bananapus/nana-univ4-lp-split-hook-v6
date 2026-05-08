// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal mock sucker registry that returns zero for all remote queries.
/// @dev Required so that `_getCashOutRate` can traverse the `scopeCashOutsToLocalBalances: false`
///      path without reverting on SUCKER_REGISTRY calls.
contract MockSuckerRegistry {
    function remoteSurplusOf(uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function remoteTotalSupplyOf(uint256) external pure returns (uint256) {
        return 0;
    }
}
