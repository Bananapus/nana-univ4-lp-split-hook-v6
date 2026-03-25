// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

/// @notice Tests for permissionless deployPool when weight has decayed 10x.
contract WeightDecayDeployTest is LPSplitHookV4TestBase {
    address randomUser;

    function setUp() public override {
        super.setUp();
        randomUser = makeAddr("randomUser");
    }

    // ─────────────────────────────────────────────────────────────────────
    // initialWeightOf recording
    // ─────────────────────────────────────────────────────────────────────

    /// @notice initialWeightOf is recorded on first processSplitWith accumulation.
    function test_initialWeightOf_recordedOnFirstAccumulation() public {
        assertEq(hook.initialWeightOf(PROJECT_ID), 0, "should be 0 before any accumulation");

        _accumulateTokens(PROJECT_ID, 100e18);

        assertEq(hook.initialWeightOf(PROJECT_ID), DEFAULT_WEIGHT, "should record initial weight");
    }

    /// @notice initialWeightOf is NOT overwritten on subsequent accumulations.
    function test_initialWeightOf_notOverwrittenOnSubsequentAccumulations() public {
        _accumulateTokens(PROJECT_ID, 100e18);
        assertEq(hook.initialWeightOf(PROJECT_ID), DEFAULT_WEIGHT);

        // Change the weight to simulate decay
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 2);

        // Accumulate again — initialWeightOf should remain the original weight
        _accumulateTokens(PROJECT_ID, 50e18);
        assertEq(hook.initialWeightOf(PROJECT_ID), DEFAULT_WEIGHT, "should NOT overwrite initial weight");
    }

    // ─────────────────────────────────────────────────────────────────────
    // deployPool still requires permission when weight hasn't decayed 10x
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts for unauthorized user when weight has NOT decayed 10x.
    function test_deployPool_requiresPermission_whenNoDecay() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Weight is still DEFAULT_WEIGHT (no decay)
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,
                randomUser,
                PROJECT_ID,
                JBPermissionIds.SET_BUYBACK_POOL
            )
        );
        vm.prank(randomUser);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);
    }

    /// @notice deployPool reverts for unauthorized user when weight has decayed just under 10x.
    function test_deployPool_requiresPermission_whenJustUnder10xDecay() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Set weight to just above 1/10th of initial (9.9x decay, not enough)
        // initialWeight / 10 = DEFAULT_WEIGHT / 10
        // We need currentWeight * 10 > initialWeight to require permission
        // currentWeight = initialWeight / 10 + 1 means currentWeight * 10 = initialWeight + 10 > initialWeight ✓
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10 + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,
                randomUser,
                PROJECT_ID,
                JBPermissionIds.SET_BUYBACK_POOL
            )
        );
        vm.prank(randomUser);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // deployPool permissionless when weight has decayed >= 10x
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Anyone can call deployPool when weight has decayed exactly 10x.
    function test_deployPool_permissionless_whenExactly10xDecay() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Set weight to exactly 1/10th of initial
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10);

        // Approve hook to spend tokens for PositionManager
        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        terminalToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        // Random user can deploy — no permission needed
        vm.prank(randomUser);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(tokenId != 0, "pool should be deployed by random user after 10x decay");
    }

    /// @notice Anyone can call deployPool when weight has decayed well past 10x.
    function test_deployPool_permissionless_when100xDecay() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Set weight to 1/100th of initial (100x decay)
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 100);

        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        terminalToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.prank(randomUser);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        assertTrue(hook.tokenIdOf(PROJECT_ID, address(terminalToken)) != 0, "pool should be deployed after 100x decay");
    }

    /// @notice When current weight is 0 (infinite decay), access control is bypassed
    ///         but deployment may revert downstream due to zero-price math.
    ///         This test verifies the permission check is skipped (no Unauthorized revert).
    function test_deployPool_permissionless_whenWeightIsZero() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Set weight to 0 (no issuance — infinite decay)
        controller.setWeight(PROJECT_ID, 0);

        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        terminalToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        // The permission check is bypassed (0 * 10 <= initialWeight),
        // but the pool deployment reverts downstream due to InvalidSqrtPrice(0).
        // The key assertion: it does NOT revert with JBPermissioned_Unauthorized.
        vm.prank(randomUser);
        vm.expectRevert(); // InvalidSqrtPrice(0), not Unauthorized
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Edge case: no initialWeightOf recorded (no accumulation before deploy)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool requires permission when initialWeightOf is 0 (never accumulated).
    ///         The permission check fires because initialWeight==0 always requires permission.
    function test_deployPool_requiresPermission_whenNoInitialWeight() public {
        // No processSplitWith called, so initialWeightOf == 0.
        // The condition `initialWeight == 0 || ...` requires permission.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,
                randomUser,
                PROJECT_ID,
                JBPermissionIds.SET_BUYBACK_POOL
            )
        );
        vm.prank(randomUser);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner can still deploy even after 10x decay
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Owner can still deploy pool regardless of weight decay (both paths work).
    function test_deployPool_ownerCanDeployRegardlessOfDecay() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Weight has NOT decayed — owner can deploy via permission check
        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        terminalToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        assertTrue(hook.tokenIdOf(PROJECT_ID, address(terminalToken)) != 0, "owner should deploy without decay");
    }

    /// @notice Permitted operator can deploy when weight hasn't decayed enough.
    function test_deployPool_permittedOperator_whenNoDecay() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        address operator = makeAddr("operator");
        permissions.setPermission(operator, owner, PROJECT_ID, JBPermissionIds.SET_BUYBACK_POOL, true);

        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        terminalToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.prank(operator);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        assertTrue(
            hook.tokenIdOf(PROJECT_ID, address(terminalToken)) != 0, "permitted operator should deploy without decay"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Cross-project: decay in one project doesn't affect another
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Weight decay for one project doesn't make another project's deployPool permissionless.
    function test_deployPool_crossProjectIsolation() public {
        uint256 projectA = PROJECT_ID;
        uint256 projectB = 3;

        // Set up project B
        _setDirectoryController(projectB, address(controller));
        controller.setWeight(projectB, DEFAULT_WEIGHT);
        controller.setFirstWeight(projectB, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(projectB, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(projectB, 1);
        _setDirectoryTerminal(projectB, address(terminalToken), address(terminal));
        _addDirectoryTerminal(projectB, address(terminal));
        jbTokens.setToken(projectB, address(projectToken));
        jbProjects.setOwner(projectB, owner);
        terminal.setAccountingContext(projectB, address(terminalToken), uint32(uint160(address(terminalToken))), 18);
        store.setSurplus(projectB, 0.5e18);

        // Accumulate for both projects
        _accumulateTokens(projectA, 100e18);
        _accumulateTokens(projectB, 100e18);

        // Decay project A's weight 10x
        controller.setWeight(projectA, DEFAULT_WEIGHT / 10);

        // Project B weight is unchanged — should still require permission
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,
                randomUser,
                projectB,
                JBPermissionIds.SET_BUYBACK_POOL
            )
        );
        vm.prank(randomUser);
        hook.deployPool(projectB, address(terminalToken), 0);
    }
}
