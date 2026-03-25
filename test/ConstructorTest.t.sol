// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice Tests for JBUniswapV4LPSplitHook constructor and initialize() behavior.
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
        assertEq(address(hook.POOL_MANAGER()), address(poolManager), "POOL_MANAGER mismatch");
        assertEq(address(hook.POSITION_MANAGER()), address(positionManager), "POSITION_MANAGER mismatch");
    }

    /// @notice Verify initialize() sets per-clone config (feeProjectId, feePercent).
    function test_Initialize_SetsCloneConfig() public view {
        assertEq(hook.FEE_PROJECT_ID(), FEE_PROJECT_ID, "FEE_PROJECT_ID mismatch");
        assertEq(hook.FEE_PERCENT(), FEE_PERCENT, "FEE_PERCENT mismatch");
    }

    /// @notice Constructor reverts when directory is address(0).
    function test_Constructor_RevertsOn_ZeroDirectory() public {
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ZeroAddressNotAllowed.selector);
        new JBUniswapV4LPSplitHook(
            address(0), // directory = zero
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(0)),
            IHooks(address(0))
        );
    }

    /// @notice Constructor reverts when tokens is address(0).
    function test_Constructor_RevertsOn_ZeroTokens() public {
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ZeroAddressNotAllowed.selector);
        new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(0), // tokens = zero
            IPoolManager(address(1)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(0)),
            IHooks(address(0))
        );
    }

    /// @notice Constructor reverts when poolManager is address(0).
    function test_Constructor_RevertsOn_ZeroPoolManager() public {
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ZeroAddressNotAllowed.selector);
        new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(0)), // poolManager = zero
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(0)),
            IHooks(address(0))
        );
    }

    /// @notice Constructor reverts when positionManager is address(0).
    function test_Constructor_RevertsOn_ZeroPositionManager() public {
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ZeroAddressNotAllowed.selector);
        new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(0)), // positionManager = zero
            IAllowanceTransfer(address(0)),
            IHooks(address(0))
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // initialize() tests
    // ─────────────────────────────────────────────────────────────────────

    /// @notice initialize() reverts when feePercent exceeds 10000 (100%).
    function test_Initialize_RevertsOn_FeePercentOver100() public {
        // Deploy a fresh implementation
        JBUniswapV4LPSplitHook impl = new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(0)),
            IHooks(address(0))
        );

        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidFeePercent.selector);
        impl.initialize(FEE_PROJECT_ID, 10_001);
    }

    /// @notice initialize() reverts when feeProjectId is 0 but feePercent > 0.
    function test_Initialize_RevertsOn_FeePercentWithoutFeeProject() public {
        // Deploy a fresh implementation
        JBUniswapV4LPSplitHook impl = new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(0)),
            IHooks(address(0))
        );

        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject.selector);
        impl.initialize(0, FEE_PERCENT);
    }

    /// @notice When both feeProjectId and feePercent are 0, initialize() succeeds (no fees configured).
    function test_Initialize_FeeProjectIdZero_FeePercentZero_Succeeds() public {
        // Deploy a fresh implementation
        JBUniswapV4LPSplitHook impl = new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(0)),
            IHooks(address(0))
        );

        impl.initialize(0, 0);

        assertEq(impl.FEE_PROJECT_ID(), 0, "FEE_PROJECT_ID should be 0");
        assertEq(impl.FEE_PERCENT(), 0, "FEE_PERCENT should be 0");
    }

    /// @notice Calling initialize() a second time reverts with AlreadyInitialized.
    function test_Initialize_RevertsOn_DoubleInit() public {
        // Deploy a fresh implementation
        JBUniswapV4LPSplitHook impl = new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(0)),
            IHooks(address(0))
        );

        // First init succeeds
        impl.initialize(FEE_PROJECT_ID, FEE_PERCENT);

        // Second init reverts
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_AlreadyInitialized.selector);
        impl.initialize(FEE_PROJECT_ID, FEE_PERCENT);
    }
}
