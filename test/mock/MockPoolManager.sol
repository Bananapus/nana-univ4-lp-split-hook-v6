// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal mock PoolManager that supports StateLibrary.getSlot0 via extsload.
/// @dev StateLibrary reads pool state from the PoolManager's storage via extsload.
///      MockPositionManager calls writeSlot to sync Slot0 when a pool is initialized,
///      and tests can use vm.store for custom slot overrides.
contract MockPoolManager {
    /// @notice IExtsload.extsload — reads a storage slot.
    function extsload(bytes32 slot) external view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    /// @notice Write a storage slot. Called by MockPositionManager to sync Slot0 after pool init.
    function writeSlot(bytes32 slot, bytes32 value) external {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }
}
