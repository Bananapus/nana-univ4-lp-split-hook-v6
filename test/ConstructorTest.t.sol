// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {LPSplitHookTestBase} from "./TestBase.sol";
import {UniV3DeploymentSplitHook} from "../src/UniV3DeploymentSplitHook.sol";
import {IJBPermissions} from "@bananapus/core/interfaces/IJBPermissions.sol";

/// @notice Tests for UniV3DeploymentSplitHook constructor and initialize() behavior.
/// @dev Verifies all immutables are set correctly by the constructor (6 params),
///      per-clone config is set by initialize(), zero-address checks revert,
///      fee percent validation works, feeProjectId=0 skips controllerOf check,
///      and double-initialization reverts.
contract ConstructorTest is LPSplitHookTestBase {
    // ─────────────────────────────────────────────────────────────────────
    // Constructor tests (6 immutable params)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Verify all immutables are correctly set after construction + initialize.
    function test_Constructor_SetsAllImmutables() public view {
        assertEq(hook.DIRECTORY(), address(directory), "DIRECTORY mismatch");
        assertEq(hook.TOKENS(), address(jbTokens), "TOKENS mismatch");
        assertEq(hook.UNISWAP_V3_FACTORY(), address(v3Factory), "UNISWAP_V3_FACTORY mismatch");
        assertEq(
            hook.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER(),
            address(nfpm),
            "UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER mismatch"
        );
        assertEq(hook.REV_DEPLOYER(), address(revDeployer), "REV_DEPLOYER mismatch");
    }

    /// @notice Verify initialize() sets per-clone config (owner, feeProjectId, feePercent).
    function test_Initialize_SetsCloneConfig() public view {
        assertEq(hook.FEE_PROJECT_ID(), FEE_PROJECT_ID, "FEE_PROJECT_ID mismatch");
        assertEq(hook.FEE_PERCENT(), FEE_PERCENT, "FEE_PERCENT mismatch");
        assertEq(hook.owner(), owner, "owner mismatch");
    }

    /// @notice Constructor reverts when directory is address(0).
    function test_Constructor_RevertsOn_ZeroDirectory() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV3DeploymentSplitHook(
            address(0), // directory = zero
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(nfpm),
            address(revDeployer)
        );
    }

    /// @notice Constructor reverts when tokens is address(0).
    function test_Constructor_RevertsOn_ZeroTokens() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV3DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(0), // tokens = zero
            address(v3Factory),
            address(nfpm),
            address(revDeployer)
        );
    }

    /// @notice Constructor reverts when uniswapV3Factory is address(0).
    function test_Constructor_RevertsOn_ZeroFactory() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV3DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(0), // uniswapV3Factory = zero
            address(nfpm),
            address(revDeployer)
        );
    }

    /// @notice Constructor reverts when uniswapV3NonfungiblePositionManager is address(0).
    function test_Constructor_RevertsOn_ZeroNFPM() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV3DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(0), // nfpm = zero
            address(revDeployer)
        );
    }

    /// @notice Constructor reverts when revDeployer is address(0).
    function test_Constructor_RevertsOn_ZeroRevDeployer() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV3DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(nfpm),
            address(0) // revDeployer = zero
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // initialize() tests
    // ─────────────────────────────────────────────────────────────────────

    /// @notice initialize() reverts when feePercent exceeds 10000 (100%).
    function test_Initialize_RevertsOn_FeePercentOver100() public {
        // Deploy a fresh implementation
        UniV3DeploymentSplitHook impl = new UniV3DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(nfpm),
            address(revDeployer)
        );
        // Zero out slot 0 (owner) so initialize() can be called
        vm.store(address(impl), bytes32(uint256(0)), bytes32(0));

        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_InvalidFeePercent.selector);
        impl.initialize(owner, FEE_PROJECT_ID, 10_001);
    }

    /// @notice When feeProjectId is 0, initialize() skips the controllerOf validation
    ///         and completes successfully without requiring a valid fee project.
    function test_Initialize_FeeProjectIdZero_NoValidation() public {
        // Deploy a fresh implementation
        UniV3DeploymentSplitHook impl = new UniV3DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(nfpm),
            address(revDeployer)
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
        assertEq(impl.UNISWAP_V3_FACTORY(), address(v3Factory), "UNISWAP_V3_FACTORY mismatch");
        assertEq(
            impl.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER(),
            address(nfpm),
            "UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER mismatch"
        );
        assertEq(impl.REV_DEPLOYER(), address(revDeployer), "REV_DEPLOYER mismatch");
    }

    /// @notice Calling initialize() a second time reverts with AlreadyInitialized.
    function test_Initialize_RevertsOn_DoubleInit() public {
        // Deploy a fresh implementation
        UniV3DeploymentSplitHook impl = new UniV3DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(nfpm),
            address(revDeployer)
        );
        // Zero out slot 0 (owner) so initialize() can be called
        vm.store(address(impl), bytes32(uint256(0)), bytes32(0));

        // First init succeeds
        impl.initialize(owner, FEE_PROJECT_ID, FEE_PERCENT);

        // Second init reverts
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_AlreadyInitialized.selector);
        impl.initialize(owner, FEE_PROJECT_ID, FEE_PERCENT);
    }
}
