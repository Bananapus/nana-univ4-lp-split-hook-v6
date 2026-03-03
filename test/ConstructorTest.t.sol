// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPSplitHookTestBase} from "./TestBase.sol";
import {UniV4DeploymentSplitHook} from "../src/UniV4DeploymentSplitHook.sol";
import {IJBPermissions} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";

/// @notice Tests for UniV4DeploymentSplitHook constructor behavior.
contract ConstructorTest is LPSplitHookTestBase {
    function test_Constructor_SetsAllImmutables() public view {
        assertEq(hook.DIRECTORY(), address(directory), "DIRECTORY mismatch");
        assertEq(hook.TOKENS(), address(jbTokens), "TOKENS mismatch");
        assertEq(address(hook.POOL_MANAGER()), address(positionManager), "POOL_MANAGER mismatch");
        assertEq(address(hook.POSITION_MANAGER()), address(positionManager), "POSITION_MANAGER mismatch");
        assertEq(address(hook.PERMIT2()), address(permit2), "PERMIT2 mismatch");
        assertEq(hook.WETH(), address(weth), "WETH mismatch");
        assertEq(hook.FEE_PROJECT_ID(), FEE_PROJECT_ID, "FEE_PROJECT_ID mismatch");
        assertEq(hook.FEE_PERCENT(), FEE_PERCENT, "FEE_PERCENT mismatch");
        assertEq(hook.REV_DEPLOYER(), address(revDeployer), "REV_DEPLOYER mismatch");
        assertEq(hook.owner(), owner, "owner mismatch");
    }

    function test_Constructor_RevertsOn_ZeroDirectory() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV4DeploymentSplitHook(
            owner, address(0), IJBPermissions(address(permissions)), address(jbTokens),
            address(positionManager), address(positionManager), address(permit2), address(weth),
            FEE_PROJECT_ID, FEE_PERCENT, address(revDeployer), address(0)
        );
    }

    function test_Constructor_RevertsOn_ZeroTokens() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV4DeploymentSplitHook(
            owner, address(directory), IJBPermissions(address(permissions)), address(0),
            address(positionManager), address(positionManager), address(permit2), address(weth),
            FEE_PROJECT_ID, FEE_PERCENT, address(revDeployer), address(0)
        );
    }

    function test_Constructor_RevertsOn_ZeroPoolManager() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV4DeploymentSplitHook(
            owner, address(directory), IJBPermissions(address(permissions)), address(jbTokens),
            address(0), address(positionManager), address(permit2), address(weth),
            FEE_PROJECT_ID, FEE_PERCENT, address(revDeployer), address(0)
        );
    }

    function test_Constructor_RevertsOn_ZeroPositionManager() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV4DeploymentSplitHook(
            owner, address(directory), IJBPermissions(address(permissions)), address(jbTokens),
            address(positionManager), address(0), address(permit2), address(weth),
            FEE_PROJECT_ID, FEE_PERCENT, address(revDeployer), address(0)
        );
    }

    function test_Constructor_RevertsOn_ZeroPermit2() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV4DeploymentSplitHook(
            owner, address(directory), IJBPermissions(address(permissions)), address(jbTokens),
            address(positionManager), address(positionManager), address(0), address(weth),
            FEE_PROJECT_ID, FEE_PERCENT, address(revDeployer), address(0)
        );
    }

    function test_Constructor_RevertsOn_ZeroRevDeployer() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV4DeploymentSplitHook(
            owner, address(directory), IJBPermissions(address(permissions)), address(jbTokens),
            address(positionManager), address(positionManager), address(permit2), address(weth),
            FEE_PROJECT_ID, FEE_PERCENT, address(0), address(0)
        );
    }

    function test_Constructor_RevertsOn_FeePercentOver100() public {
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_InvalidFeePercent.selector);
        new UniV4DeploymentSplitHook(
            owner, address(directory), IJBPermissions(address(permissions)), address(jbTokens),
            address(positionManager), address(positionManager), address(permit2), address(weth),
            FEE_PROJECT_ID, 10001, address(revDeployer), address(0)
        );
    }

    function test_Constructor_FeeProjectIdZero_NoValidation() public {
        UniV4DeploymentSplitHook noFeeHook = new UniV4DeploymentSplitHook(
            owner, address(directory), IJBPermissions(address(permissions)), address(jbTokens),
            address(positionManager), address(positionManager), address(permit2), address(weth),
            0, FEE_PERCENT, address(revDeployer), address(0)
        );
        assertEq(noFeeHook.FEE_PROJECT_ID(), 0, "FEE_PROJECT_ID should be 0");
    }
}
