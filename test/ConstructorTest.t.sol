// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {UniV4DeploymentSplitHook} from "../src/UniV4DeploymentSplitHook.sol";
import {IJBPermissions} from "@bananapus/core/interfaces/IJBPermissions.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice Tests for UniV4DeploymentSplitHook constructor and initialize() behavior.
/// @dev Verifies all immutables are set correctly by the constructor (5 params),
///      per-clone config is set by initialize(), zero-address checks revert,
///      fee percent validation works, feeProjectId=0 skips controllerOf check,
///      and double-initialization reverts.
contract ConstructorTest is LPSplitHookV4TestBase {
    // ─────────────────────────────────────────────────────────────────────
    // Constructor tests (5 immutable params)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Verify all immutables are correctly set after construction + initialize.
    function test_Constructor_SetsAllImmutables() public view {
        assertEq(hook.DIRECTORY(), address(directory), "DIRECTORY mismatch");
        assertEq(hook.TOKENS(), address(jbTokens), "TOKENS mismatch");
        assertEq(address(hook.POOL_MANAGER()), address(1), "POOL_MANAGER mismatch");
        assertEq(address(hook.POSITION_MANAGER()), address(positionManager), "POSITION_MANAGER mismatch");
    }

    /// @notice Verify initialize() sets per-clone config (owner, feeProjectId, feePercent).
    function test_Initialize_SetsCloneConfig() public view {
        assertEq(hook.FEE_PROJECT_ID(), FEE_PROJECT_ID, "FEE_PROJECT_ID mismatch");
        assertEq(hook.FEE_PERCENT(), FEE_PERCENT, "FEE_PERCENT mismatch");
        assertEq(hook.owner(), owner, "owner mismatch");
    }

    /// @notice Constructor reverts when directory is address(0).
    function test_Constructor_RevertsOn_ZeroDirectory() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV4DeploymentSplitHook(
            address(0), // directory = zero
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager))
        );
    }

    /// @notice Constructor reverts when tokens is address(0).
    function test_Constructor_RevertsOn_ZeroTokens() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV4DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(0), // tokens = zero
            IPoolManager(address(1)),
            IPositionManager(address(positionManager))
        );
    }

    /// @notice Constructor reverts when poolManager is address(0).
    function test_Constructor_RevertsOn_ZeroPoolManager() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV4DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(0)), // poolManager = zero
            IPositionManager(address(positionManager))
        );
    }

    /// @notice Constructor reverts when positionManager is address(0).
    function test_Constructor_RevertsOn_ZeroPositionManager() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV4DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(0)) // positionManager = zero
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // initialize() tests
    // ─────────────────────────────────────────────────────────────────────

    /// @notice initialize() reverts when feePercent exceeds 10000 (100%).
    function test_Initialize_RevertsOn_FeePercentOver100() public {
        // Deploy a fresh implementation
        UniV4DeploymentSplitHook impl = new UniV4DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager))
        );
        // Zero out slot 0 (owner) so initialize() can be called
        vm.store(address(impl), bytes32(uint256(0)), bytes32(0));

        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_InvalidFeePercent.selector);
        impl.initialize(owner, FEE_PROJECT_ID, 10_001);
    }

    /// @notice When feeProjectId is 0, initialize() skips the controllerOf validation
    ///         and completes successfully without requiring a valid fee project.
    function test_Initialize_FeeProjectIdZero_NoValidation() public {
        // Deploy a fresh implementation
        UniV4DeploymentSplitHook impl = new UniV4DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager))
        );
        // Zero out slot 0 (owner) so initialize() can be called
        vm.store(address(impl), bytes32(uint256(0)), bytes32(0));

        impl.initialize(owner, 0, FEE_PERCENT);

        assertEq(impl.FEE_PROJECT_ID(), 0, "FEE_PROJECT_ID should be 0");
        assertEq(impl.FEE_PERCENT(), FEE_PERCENT, "FEE_PERCENT mismatch");
        assertEq(impl.owner(), owner, "owner mismatch");
        // All immutables should still be set correctly.
        assertEq(impl.DIRECTORY(), address(directory), "DIRECTORY mismatch");
        assertEq(impl.TOKENS(), address(jbTokens), "TOKENS mismatch");
        assertEq(address(impl.POOL_MANAGER()), address(1), "POOL_MANAGER mismatch");
        assertEq(address(impl.POSITION_MANAGER()), address(positionManager), "POSITION_MANAGER mismatch");
    }

    /// @notice Calling initialize() a second time reverts with AlreadyInitialized.
    function test_Initialize_RevertsOn_DoubleInit() public {
        // Deploy a fresh implementation
        UniV4DeploymentSplitHook impl = new UniV4DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager))
        );
        // Zero out slot 0 (owner) so initialize() can be called
        vm.store(address(impl), bytes32(uint256(0)), bytes32(0));

        // First init succeeds
        impl.initialize(owner, FEE_PROJECT_ID, FEE_PERCENT);

        // Second init reverts
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_AlreadyInitialized.selector);
        impl.initialize(owner, FEE_PROJECT_ID, FEE_PERCENT);
    }
}
