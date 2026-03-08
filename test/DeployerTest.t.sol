// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core/interfaces/IJBPermissions.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {UniV4DeploymentSplitHook} from "../src/UniV4DeploymentSplitHook.sol";
import {UniV4DeploymentSplitHookDeployer} from "../src/UniV4DeploymentSplitHookDeployer.sol";
import {IUniV4DeploymentSplitHook} from "../src/interfaces/IUniV4DeploymentSplitHook.sol";
import {IUniV4DeploymentSplitHookDeployer} from "../src/interfaces/IUniV4DeploymentSplitHookDeployer.sol";

import {MockJBDirectory, MockJBPermissions} from "./mock/MockJBContracts.sol";

contract DeployerTest is Test {
    UniV4DeploymentSplitHook hookImpl;
    UniV4DeploymentSplitHookDeployer deployer;
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

        hookImpl = new UniV4DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(1), // tokens placeholder
            IPoolManager(address(2)), // pool manager placeholder
            IPositionManager(address(3)) // position manager placeholder
        );

        addressRegistry = new JBAddressRegistry();
        deployer = new UniV4DeploymentSplitHookDeployer(hookImpl, IJBAddressRegistry(address(addressRegistry)));
    }

    // ─── CREATE deployment registers in address registry ─────────────

    function test_deployHookFor_CREATE_registersInAddressRegistry() public {
        vm.prank(caller);
        IUniV4DeploymentSplitHook hook = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(0));

        // The deployed hook should be registered with this deployer.
        address registeredDeployer = addressRegistry.deployerOf(address(hook));
        assertEq(registeredDeployer, address(deployer), "CREATE: deployer not registered");
    }

    // ─── CREATE2 deployment registers in address registry ────────────

    function test_deployHookFor_CREATE2_registersInAddressRegistry() public {
        bytes32 salt = bytes32(uint256(0xBEEF));

        vm.prank(caller);
        IUniV4DeploymentSplitHook hook = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, salt);

        address registeredDeployer = addressRegistry.deployerOf(address(hook));
        assertEq(registeredDeployer, address(deployer), "CREATE2: deployer not registered");
    }

    // ─── Multiple CREATE deployments increment nonce correctly ───────

    function test_deployHookFor_CREATE_multipleDeployments() public {
        vm.startPrank(caller);
        IUniV4DeploymentSplitHook hook1 = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(0));
        IUniV4DeploymentSplitHook hook2 = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(0));
        vm.stopPrank();

        // Both should be different addresses.
        assertTrue(address(hook1) != address(hook2), "hooks should be different");

        // Both should be registered.
        assertEq(addressRegistry.deployerOf(address(hook1)), address(deployer), "hook1 not registered");
        assertEq(addressRegistry.deployerOf(address(hook2)), address(deployer), "hook2 not registered");
    }

    // ─── Hook is properly initialized
    // ────────────────────────────────

    function test_deployHookFor_initializesHook() public {
        vm.prank(caller);
        IUniV4DeploymentSplitHook hook = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(0));

        UniV4DeploymentSplitHook concreteHook = UniV4DeploymentSplitHook(payable(address(hook)));
        assertEq(concreteHook.FEE_PROJECT_ID(), FEE_PROJECT_ID, "feeProjectId not set");
        assertEq(concreteHook.FEE_PERCENT(), FEE_PERCENT, "feePercent not set");
    }

    // ─── HookDeployed event is emitted
    // ───────────────────────────────

    function test_deployHookFor_emitsHookDeployedEvent() public {
        vm.recordLogs();

        vm.prank(caller);
        IUniV4DeploymentSplitHook hook = deployer.deployHookFor(FEE_PROJECT_ID, FEE_PERCENT, bytes32(0));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 hookDeployedSig = keccak256("HookDeployed(uint256,uint256,address,address)");

        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == hookDeployedSig) {
                assertEq(logs[i].topics[1], bytes32(FEE_PROJECT_ID), "wrong feeProjectId in event");
                found = true;
                break;
            }
        }
        assertTrue(found, "HookDeployed event not emitted");
    }

    // ─── ADDRESS_REGISTRY getter works
    // ───────────────────────────────

    function test_ADDRESS_REGISTRY_returnsRegistry() public view {
        assertEq(address(deployer.ADDRESS_REGISTRY()), address(addressRegistry));
    }

    // ─── HOOK getter works
    // ───────────────────────────────────────────

    function test_HOOK_returnsImplementation() public view {
        assertEq(address(deployer.HOOK()), address(hookImpl));
    }
}
