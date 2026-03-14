// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {MockPositionManager} from "../mock/MockPositionManager.sol";
import {MockJBDirectory, MockJBController, MockJBTokens, MockJBPermissions} from "../mock/MockJBContracts.sol";

/// @notice Re-initialization protection.
/// @dev The `initialized` boolean prevents calling initialize() more than once.
contract ReinitAfterRenounceTest is Test {
    JBUniswapV4LPSplitHook public hookImpl;
    JBUniswapV4LPSplitHook public hook;
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

        hookImpl = new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(0)),
            IHooks(address(0))
        );

        // Clone and initialize
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));
        hook.initialize(2, 3800); // feeProjectId=2, feePercent=38%
    }

    /// @notice Re-initialization should revert.
    function test_reinitialize_reverts() public {
        assertEq(hook.FEE_PROJECT_ID(), 2);
        assertEq(hook.FEE_PERCENT(), 3800);
        assertTrue(hook.initialized());

        // Attacker tries to re-initialize with malicious parameters
        vm.prank(attacker);
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_AlreadyInitialized.selector);
        hook.initialize(2, 10_000); // trying to set 100% fee
    }

    /// @notice The `initialized` flag is set to true after first initialization.
    function test_initialized_flag_set() public view {
        assertTrue(hook.initialized(), "initialized should be true after initialize()");
    }

    /// @notice Double initialization also still reverts.
    function test_double_init_reverts() public {
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_AlreadyInitialized.selector);
        hook.initialize(2, 5000);
    }
}
