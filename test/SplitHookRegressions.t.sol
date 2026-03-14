// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {MockERC20} from "./mock/MockERC20.sol";

/// @notice Regression tests for rebalance authorization, fee routing, and per-token deployment flags.
contract SplitHookRegressionsTest is LPSplitHookV4TestBase {
    uint256 poolTokenId;
    bool terminalTokenIsToken0;

    function setUp() public override {
        super.setUp();

        // Deploy a pool so we have a position to test rebalance
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        poolTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Ensure PositionManager has tokens for rebalance
        projectToken.mint(address(positionManager), 50e18);
        terminalToken.mint(address(positionManager), 50e18);

        // Determine token ordering
        terminalTokenIsToken0 = address(terminalToken) < address(projectToken);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Permissionless Rebalance Can Permanently Brick Project LP
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice rebalanceLiquidity reverts when called by an unauthorized account.
    function test_H2_rebalance_unauthorized_reverts() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert();
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        // Verify the position was not disturbed
        uint256 tokenIdAfter = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(tokenIdAfter, poolTokenId, "tokenIdOf should remain unchanged after unauthorized attempt");
    }

    /// @notice rebalanceLiquidity succeeds when called by the project owner.
    function test_H2_rebalance_owner_succeeds() public {
        uint256 originalTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(originalTokenId != 0, "should have an active position");

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != 0, "new tokenId should be nonzero");
        assertTrue(newTokenId != originalTokenId, "tokenId should change after rebalance");
    }

    /// @notice rebalanceLiquidity succeeds when called by an authorized operator.
    function test_H2_rebalance_authorizedOperator_succeeds() public {
        address operator = makeAddr("operator");

        // Grant SET_BUYBACK_POOL permission to operator
        permissions.setPermission(operator, owner, PROJECT_ID, JBPermissionIds.SET_BUYBACK_POOL, true);

        uint256 originalTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        vm.prank(operator);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != 0, "new tokenId should be nonzero");
        assertTrue(newTokenId != originalTokenId, "tokenId should change after authorized rebalance");
    }

    /// @notice rebalanceLiquidity reverts with InsufficientLiquidity when the new
    ///         position would have zero liquidity (prevents bricking via tokenIdOf=0).
    function test_H2_rebalance_zeroLiquidity_reverts() public {
        // Drain all tokens from PositionManager and hook so burn returns 0
        uint256 pmProjectBal = projectToken.balanceOf(address(positionManager));
        uint256 pmTerminalBal = terminalToken.balanceOf(address(positionManager));
        // Test helper: draining mock balances; return value not relevant.
        vm.startPrank(address(positionManager));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        if (pmProjectBal > 0) projectToken.transfer(address(0xdead), pmProjectBal);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        if (pmTerminalBal > 0) terminalToken.transfer(address(0xdead), pmTerminalBal);
        vm.stopPrank();

        uint256 hookProjectBal = projectToken.balanceOf(address(hook));
        uint256 hookTerminalBal = terminalToken.balanceOf(address(hook));
        // Test helper: draining mock balances; return value not relevant.
        vm.startPrank(address(hook));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        if (hookProjectBal > 0) projectToken.transfer(address(0xdead), hookProjectBal);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        if (hookTerminalBal > 0) terminalToken.transfer(address(0xdead), hookTerminalBal);
        vm.stopPrank();

        // Should revert instead of zeroing tokenIdOf
        vm.prank(owner);
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InsufficientLiquidity.selector);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        // tokenIdOf should remain unchanged (revert rolled back state)
        assertEq(
            hook.tokenIdOf(PROJECT_ID, address(terminalToken)),
            poolTokenId,
            "tokenIdOf should remain unchanged after revert"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Placeholder _getAmountForCurrency() Disables Fee Routing
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Fees collected during rebalanceLiquidity are properly
    ///         routed via balance-delta tracking (same pattern as collectAndRouteLPFees).
    ///         Note: The balance delta includes both principal and fees from the burned position.
    ///         The fee-splitting is applied to the full terminal-token delta.
    function test_M1_rebalance_routesFeesDuringBurn() public {
        // Set up collectable fees on the terminal token side
        uint256 feeAmount = 10e18;
        if (terminalTokenIsToken0) {
            positionManager.setCollectableFees(poolTokenId, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(poolTokenId, 0, feeAmount);
        }
        terminalToken.mint(address(positionManager), feeAmount);

        // Set up fee project terminal accounting context
        terminal.setAccountingContext(
            FEE_PROJECT_ID, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );

        uint256 payCountBefore = terminal.payCallCount();
        uint256 addToBalanceCountBefore = terminal.addToBalanceCallCount();

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        // Verify fees were routed: pay (for fee project) and/or addToBalance (for project)
        bool feesRouted =
            (terminal.payCallCount() > payCountBefore) || (terminal.addToBalanceCallCount() > addToBalanceCountBefore);
        assertTrue(feesRouted, "Fees collected during rebalance burn should be routed");

        // Verify routing targets the fee project
        if (terminal.payCallCount() > payCountBefore) {
            assertEq(terminal.lastPayProjectId(), FEE_PROJECT_ID, "Fee payment should target FEE_PROJECT_ID");
            // The pay amount is FEE_PERCENT of the total terminal token balance delta
            // (principal + fees), not just the fee portion.
            assertGt(terminal.lastPayAmount(), 0, "Fee payment amount should be nonzero");
        }
    }

    /// @notice Verify that claimable fee tokens are generated during rebalance.
    function test_M1_rebalance_generatesClaimableFeeTokens() public {
        // Set up collectable fees on the terminal token side
        uint256 feeAmount = 100e18;
        if (terminalTokenIsToken0) {
            positionManager.setCollectableFees(poolTokenId, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(poolTokenId, 0, feeAmount);
        }
        terminalToken.mint(address(positionManager), feeAmount);

        // Set up fee project terminal
        terminal.setAccountingContext(
            FEE_PROJECT_ID, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );

        uint256 claimableBefore = hook.claimableFeeTokens(PROJECT_ID);

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        uint256 claimableAfter = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimableAfter, claimableBefore, "claimableFeeTokens should increase after rebalance with fees");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Per-Project projectDeployed Flag Prevents Multi-Terminal-Token Pools
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice projectDeployed is now keyed by [projectId][terminalToken].
    ///         After deploying a pool for terminalToken, projectDeployed[projectId][terminalToken]
    ///         is true, but projectDeployed[projectId][otherToken] is false.
    function test_M2_projectDeployed_perTerminalToken() public {
        // PROJECT_ID already has a pool deployed for terminalToken
        assertTrue(
            hook.projectDeployed(PROJECT_ID, address(terminalToken)),
            "projectDeployed should be true for the deployed terminal token"
        );

        // For a different terminal token, projectDeployed should be false
        MockERC20 otherTerminalToken = new MockERC20("Other Terminal", "OTERM", 18);
        assertFalse(
            hook.projectDeployed(PROJECT_ID, address(otherTerminalToken)),
            "projectDeployed should be false for a different terminal token"
        );
    }

    /// @notice deployedPoolCount increments per deployment.
    function test_M2_deployedPoolCount_increments() public view {
        // After the setUp, one pool is deployed for PROJECT_ID
        assertEq(hook.deployedPoolCount(PROJECT_ID), 1, "deployedPoolCount should be 1 after first deploy");
    }

    /// @notice processSplitWith uses deployedPoolCount to decide accumulate vs burn.
    ///         After deploying a pool, new tokens are burned (count > 0).
    function test_M2_processSplitWith_burnsAfterDeploy() public {
        // PROJECT_ID has a deployed pool (deployedPoolCount == 1)
        assertEq(hook.deployedPoolCount(PROJECT_ID), 1, "should have 1 deployed pool");

        uint256 burnCountBefore = controller.burnCallCount();

        // Send more tokens via processSplitWith -- should burn, not accumulate
        uint256 newAmount = 50e18;
        projectToken.mint(address(hook), newAmount);
        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);
        vm.prank(address(controller));
        hook.processSplitWith(context);

        assertGt(controller.burnCallCount(), burnCountBefore, "Tokens should be burned after pool deployed");
    }

    /// @notice processSplitWith accumulates when no pools are deployed (count == 0).
    function test_M2_processSplitWith_accumulatesBeforeDeploy() public {
        // Set up a fresh project with no pools deployed
        uint256 freshProjectId = 5;
        _setDirectoryController(freshProjectId, address(controller));
        controller.setWeight(freshProjectId, DEFAULT_WEIGHT);
        controller.setFirstWeight(freshProjectId, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(freshProjectId, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(freshProjectId, 1);
        jbProjects.setOwner(freshProjectId, owner);
        jbTokens.setToken(freshProjectId, address(projectToken));

        assertEq(hook.deployedPoolCount(freshProjectId), 0, "No pools deployed for fresh project");

        // Accumulate tokens
        uint256 amount = 100e18;
        projectToken.mint(address(hook), amount);
        JBSplitHookContext memory context = _buildContext(freshProjectId, address(projectToken), amount, 1);
        vm.prank(address(controller));
        hook.processSplitWith(context);

        assertEq(
            hook.accumulatedProjectTokens(freshProjectId),
            amount,
            "Tokens should be accumulated when no pool is deployed"
        );
    }

    /// @notice Demonstrates that multiple terminal tokens can have independent
    ///         projectDeployed flags per the new mapping structure.
    function test_M2_multiTerminalToken_independentFlags() public {
        // PROJECT_ID already has a pool for terminalToken
        assertTrue(
            hook.projectDeployed(PROJECT_ID, address(terminalToken)), "First terminal token pool should be deployed"
        );

        // Set up a second terminal token
        MockERC20 secondTerminalToken = new MockERC20("Second Terminal", "TERM2", 18);
        _setDirectoryTerminal(PROJECT_ID, address(secondTerminalToken), address(terminal));
        terminal.setAccountingContext(
            PROJECT_ID, address(secondTerminalToken), uint32(uint160(address(secondTerminalToken))), 18
        );
        terminal.addAccountingContext(
            PROJECT_ID,
            JBAccountingContext({
                token: address(secondTerminalToken),
                decimals: 18,
                currency: uint32(uint160(address(secondTerminalToken)))
            })
        );

        // The second terminal token should NOT be flagged as deployed
        assertFalse(
            hook.projectDeployed(PROJECT_ID, address(secondTerminalToken)),
            "Second terminal token should not be deployed yet"
        );

        // The first terminal token should still be deployed
        assertTrue(
            hook.projectDeployed(PROJECT_ID, address(terminalToken)), "First terminal token should still be deployed"
        );

        // Note: processSplitWith limitation -- it uses deployedPoolCount (per-project) to decide
        // accumulate vs burn. Once any pool is deployed, all subsequent splits burn tokens.
        // A future improvement could track per-terminal-token accumulation, but this requires
        // the split context to include the terminal token, which it currently does not.
    }
}
