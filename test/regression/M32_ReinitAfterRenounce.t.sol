// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core/interfaces/IJBPermissions.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {UniV4DeploymentSplitHook} from "../../src/UniV4DeploymentSplitHook.sol";
import {MockPositionManager} from "../mock/MockPositionManager.sol";
import {
    MockJBDirectory,
    MockJBController,
    MockJBMultiTerminal,
    MockJBTokens,
    MockJBPrices,
    MockJBTerminalStore,
    MockJBProjects,
    MockJBPermissions
} from "../mock/MockJBContracts.sol";

/// @notice Re-initialization protection.
/// @dev The `initialized` boolean prevents calling initialize() more than once.
contract M32_ReinitAfterRenounceTest is Test {
    UniV4DeploymentSplitHook public hookImpl;
    UniV4DeploymentSplitHook public hook;
    MockJBDirectory public directory;
    MockJBController public controller;
    MockJBTokens public jbTokens;
    MockJBPermissions public permissions;
    MockPositionManager public positionManager;

    address public attacker;

    function setUp() public {
        attacker = makeAddr("attacker");

        directory = new MockJBDirectory();
        controller = new MockJBController();
        jbTokens = new MockJBTokens();
        permissions = new MockJBPermissions();
        positionManager = new MockPositionManager();

        // Set up controller for fee project ID 2
        bytes32 slot = keccak256(abi.encode(uint256(2), uint256(1)));
        vm.store(address(directory), slot, bytes32(uint256(uint160(address(controller)))));

        hookImpl = new UniV4DeploymentSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager))
        );

        // Clone and initialize
        hook = UniV4DeploymentSplitHook(payable(LibClone.clone(address(hookImpl))));
        hook.initialize(2, 3800); // feeProjectId=2, feePercent=38%
    }

    /// @notice Re-initialization should revert.
    function test_reinitialize_reverts() public {
        assertEq(hook.FEE_PROJECT_ID(), 2);
        assertEq(hook.FEE_PERCENT(), 3800);
        assertTrue(hook.initialized());

        // Attacker tries to re-initialize with malicious parameters
        vm.prank(attacker);
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_AlreadyInitialized.selector);
        hook.initialize(2, 10_000); // trying to set 100% fee
    }

    /// @notice The `initialized` flag is set to true after first initialization.
    function test_initialized_flag_set() public view {
        assertTrue(hook.initialized(), "initialized should be true after initialize()");
    }

    /// @notice Double initialization also still reverts.
    function test_double_init_reverts() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_AlreadyInitialized.selector);
        hook.initialize(2, 5000);
    }
}
