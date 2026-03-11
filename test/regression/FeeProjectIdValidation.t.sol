// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {MockPositionManager} from "../mock/MockPositionManager.sol";
import {
    MockJBDirectory,
    MockJBController,
    MockJBTokens,
    MockJBPermissions
} from "../mock/MockJBContracts.sol";

/// @notice feeProjectId=0 with non-zero feePercent locks fees.
/// @dev When feePercent > 0 and feeProjectId == 0, primaryTerminalOf(0, token) returns address(0),
///      causing fee tokens to get stuck. The fix validates this combination in initialize().
contract FeeProjectIdValidationTest is Test {
    JBUniswapV4LPSplitHook public hookImpl;
    MockJBDirectory public directory;
    MockJBController public controller;
    MockJBTokens public jbTokens;
    MockJBPermissions public permissions;
    MockPositionManager public positionManager;

    function setUp() public {
        directory = new MockJBDirectory();
        controller = new MockJBController();
        jbTokens = new MockJBTokens();
        permissions = new MockJBPermissions();
        positionManager = new MockPositionManager();

        hookImpl = new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager)),
            IHooks(address(0))
        );
    }

    /// @notice initialize reverts when feePercent > 0 and feeProjectId == 0.
    function test_initialize_reverts_feePercent_without_feeProjectId() public {
        JBUniswapV4LPSplitHook clone = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));

        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject.selector);
        clone.initialize(0, 3800); // feeProjectId=0, feePercent=38%
    }

    /// @notice initialize succeeds when feePercent == 0 and feeProjectId == 0 (no fees configured).
    function test_initialize_succeeds_zero_feePercent_zero_feeProjectId() public {
        JBUniswapV4LPSplitHook clone = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));

        clone.initialize(0, 0); // both zero is fine

        assertEq(clone.FEE_PERCENT(), 0);
        assertEq(clone.FEE_PROJECT_ID(), 0);
    }

    /// @notice initialize succeeds when feePercent > 0 and feeProjectId != 0 (valid fee config).
    function test_initialize_succeeds_valid_fee_config() public {
        // Set up controller for project ID 2 so the directory lookup succeeds
        bytes32 slot = keccak256(abi.encode(uint256(2), uint256(1)));
        vm.store(address(directory), slot, bytes32(uint256(uint160(address(controller)))));

        JBUniswapV4LPSplitHook clone = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));

        clone.initialize(2, 3800); // feeProjectId=2, feePercent=38%

        assertEq(clone.FEE_PERCENT(), 3800);
        assertEq(clone.FEE_PROJECT_ID(), 2);
    }
}
