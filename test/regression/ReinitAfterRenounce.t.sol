// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
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
            IAllowanceTransfer(address(0)),
            IJBSuckerRegistry(address(0))
        );

        // Clone and initialize
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));
        hook.initialize({
            feeProjectId: 2,
            feePercent: 3800,
            poolManager: IPoolManager(address(1)),
            positionManager: IPositionManager(address(positionManager)),
            oracleHook: IHooks(address(0))
        }); // feeProjectId=2, feePercent=38%
    }

    /// @notice Re-initialization should revert.
    function test_reinitialize_reverts() public {
        assertEq(hook.FEE_PROJECT_ID(), 2);
        assertEq(hook.FEE_PERCENT(), 3800);
        // POOL_MANAGER doubles as the "initialized" sentinel — non-zero after `initialize`.
        assertTrue(address(hook.POOL_MANAGER()) != address(0));

        // Attacker tries to re-initialize with malicious parameters
        vm.prank(attacker);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_AlreadyInitialized.selector);
        hook.initialize({
            feeProjectId: 2,
            feePercent: 10_000,
            poolManager: IPoolManager(address(1)),
            positionManager: IPositionManager(address(positionManager)),
            oracleHook: IHooks(address(0))
        }); // trying to set 100% fee
    }

    /// @notice POOL_MANAGER acts as the initialization sentinel — non-zero after first initialization.
    function test_initialized_flag_set() public view {
        assertTrue(
            address(hook.POOL_MANAGER()) != address(0),
            "POOL_MANAGER should be non-zero after initialize() - it is the one-shot sentinel"
        );
    }

    /// @notice Double initialization also still reverts.
    function test_double_init_reverts() public {
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_AlreadyInitialized.selector);
        hook.initialize({
            feeProjectId: 2,
            feePercent: 5000,
            poolManager: IPoolManager(address(1)),
            positionManager: IPositionManager(address(positionManager)),
            oracleHook: IHooks(address(0))
        });
    }
}
