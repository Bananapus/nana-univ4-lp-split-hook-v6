// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal mock sucker registry that returns zero for all remote queries.
/// @dev Required so that `_getCashOutRate` can traverse the `scopeCashOutsToLocalBalances: false`
///      path without reverting on SUCKER_REGISTRY calls.
contract MockSuckerRegistry {
    uint256 public remoteSurplus;
    uint256 public remoteSupply;

    function setRemoteValues(uint256 remoteSurplus_, uint256 remoteSupply_) external {
        remoteSurplus = remoteSurplus_;
        remoteSupply = remoteSupply_;
    }

    function remoteSurplusOf(uint256, uint256, uint256) external view returns (uint256) {
        return remoteSurplus;
    }

    function remoteTotalSupplyOf(uint256) external view returns (uint256) {
        return remoteSupply;
    }
}
