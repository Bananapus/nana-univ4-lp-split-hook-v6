// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookDeployer} from "../../src/JBUniswapV4LPSplitHookDeployer.sol";
import {IJBUniswapV4LPSplitHook} from "../../src/interfaces/IJBUniswapV4LPSplitHook.sol";

import {MockJBDirectory, MockJBPermissions} from "../mock/MockJBContracts.sol";

/// @notice Regression test for deployer nonce tracking: Verify nonce tracking stays in sync across mixed
/// CREATE2/CREATE deployments.
/// @dev Both CREATE and CREATE2 opcodes increment the sender's EVM nonce, so the deployer's
/// `_nonce` must increment for both paths to stay in sync for address registry registration.
contract AuditFixM31Test is Test {
    JBUniswapV4LPSplitHook hookImpl;
    JBUniswapV4LPSplitHookDeployer deployer;
    JBAddressRegistry addressRegistry;
    MockJBDirectory directory;
    MockJBPermissions permissions;

    uint256 constant FEE_PROJECT_ID = 2;
    uint256 constant FEE_PERCENT = 3800;

    address caller;

    function setUp() public {
        caller = makeAddr("caller");

        directory = new MockJBDirectory();
        permissions = new MockJBPermissions();

        // Wire a controller for FEE_PROJECT_ID so initialize() doesn't revert.
        address mockController = makeAddr("controller");
        bytes32 slot = keccak256(abi.encode(FEE_PROJECT_ID, uint256(1)));
        vm.store(address(directory), slot, bytes32(uint256(uint160(mockController))));

        hookImpl = new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(1), // tokens placeholder
            IPoolManager(address(2)), // pool manager placeholder
            IPositionManager(address(3)), // position manager placeholder
            IAllowanceTransfer(address(0)),
            IHooks(address(0))
        );

        addressRegistry = new JBAddressRegistry();
        deployer = new JBUniswapV4LPSplitHookDeployer(hookImpl, IJBAddressRegistry(address(addressRegistry)));
    }

    /// @notice Deploy with CREATE2 first, then CREATE, and verify both hooks are correctly
    /// registered in the address registry.
    function test_create2ThenCreate_bothRegistered() public {
        // Step 1: Deploy with CREATE2.
        bytes32 salt = bytes32(uint256(0xCAFE));
        vm.prank(caller);
        IJBUniswapV4LPSplitHook create2Hook = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, salt);

        // The CREATE2 hook should be registered.
        assertEq(
            addressRegistry.deployerOf(address(create2Hook)), address(deployer), "CREATE2 hook should be registered"
        );

        // Step 2: Deploy with CREATE.
        vm.prank(caller);
        IJBUniswapV4LPSplitHook createHook = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(0));

        // The CREATE hook should also be registered — nonce tracking stays in sync because
        // both CREATE and CREATE2 increment the EVM nonce.
        assertEq(addressRegistry.deployerOf(address(createHook)), address(deployer), "CREATE hook should be registered");

        // Both hooks should be different addresses.
        assertTrue(address(create2Hook) != address(createHook), "hooks should be different addresses");
    }

    /// @notice Multiple CREATE2 deploys followed by a CREATE deploy — all registered correctly.
    function test_multipleCREATE2ThenCREATE_allRegistered() public {
        vm.startPrank(caller);
        IJBUniswapV4LPSplitHook hook1 = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(uint256(1)));
        IJBUniswapV4LPSplitHook hook2 = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(uint256(2)));
        IJBUniswapV4LPSplitHook hook3 = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(uint256(3)));

        // Deploy 1 hook via CREATE.
        IJBUniswapV4LPSplitHook createHook = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(0));
        vm.stopPrank();

        assertEq(addressRegistry.deployerOf(address(hook1)), address(deployer), "hook1 not registered");
        assertEq(addressRegistry.deployerOf(address(hook2)), address(deployer), "hook2 not registered");
        assertEq(addressRegistry.deployerOf(address(hook3)), address(deployer), "hook3 not registered");
        assertEq(
            addressRegistry.deployerOf(address(createHook)),
            address(deployer),
            "CREATE hook after multiple CREATE2s should be registered"
        );
    }

    /// @notice Interleaved CREATE and CREATE2 deploys maintain correct registration.
    function test_interleavedDeployments_allRegistered() public {
        vm.startPrank(caller);

        // CREATE
        IJBUniswapV4LPSplitHook hook1 = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(0));
        // CREATE2
        IJBUniswapV4LPSplitHook hook2 = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(uint256(42)));
        // CREATE
        IJBUniswapV4LPSplitHook hook3 = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(0));
        // CREATE2
        IJBUniswapV4LPSplitHook hook4 = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(uint256(99)));
        // CREATE
        IJBUniswapV4LPSplitHook hook5 = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(0));

        vm.stopPrank();

        // All hooks should be registered correctly.
        assertEq(addressRegistry.deployerOf(address(hook1)), address(deployer), "hook1 not registered");
        assertEq(addressRegistry.deployerOf(address(hook2)), address(deployer), "hook2 not registered");
        assertEq(addressRegistry.deployerOf(address(hook3)), address(deployer), "hook3 not registered");
        assertEq(addressRegistry.deployerOf(address(hook4)), address(deployer), "hook4 not registered");
        assertEq(addressRegistry.deployerOf(address(hook5)), address(deployer), "hook5 not registered");
    }
}
