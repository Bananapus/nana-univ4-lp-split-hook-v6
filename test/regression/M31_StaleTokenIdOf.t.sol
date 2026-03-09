// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {UniV4DeploymentSplitHook} from "../../src/UniV4DeploymentSplitHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Regression test for M-31: tokenIdOf becomes stale when rebalance yields zero liquidity.
/// @dev After the H-2 audit fix, rebalanceLiquidity now reverts with InsufficientLiquidity when
///      the new position would have zero liquidity, rather than silently zeroing tokenIdOf.
///      This prevents the bricking scenario where tokenIdOf=0 + projectDeployed=true creates
///      a permanent circular dependency.
contract M31_StaleTokenIdOfTest is LPSplitHookV4TestBase {
    uint256 poolTokenId;

    function setUp() public override {
        super.setUp();

        // Deploy a pool so we have a position to rebalance
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        poolTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(poolTokenId != 0, "Initial tokenId should be nonzero");
    }

    /// @notice When rebalance would yield zero liquidity, it now reverts with InsufficientLiquidity.
    ///         This prevents the state inconsistency that would brick the project.
    function test_rebalance_zeroLiquidity_reverts() public {
        // Drain all tokens from the mock PositionManager so burn's TAKE_PAIR sends 0
        uint256 pmProjectBal = projectToken.balanceOf(address(positionManager));
        uint256 pmTerminalBal = terminalToken.balanceOf(address(positionManager));
        vm.startPrank(address(positionManager));
        if (pmProjectBal > 0) projectToken.transfer(address(0xdead), pmProjectBal);
        if (pmTerminalBal > 0) terminalToken.transfer(address(0xdead), pmTerminalBal);
        vm.stopPrank();

        // Also drain any tokens the hook might have
        uint256 hookProjectBal = projectToken.balanceOf(address(hook));
        uint256 hookTerminalBal = terminalToken.balanceOf(address(hook));
        vm.startPrank(address(hook));
        if (hookProjectBal > 0) projectToken.transfer(address(0xdead), hookProjectBal);
        if (hookTerminalBal > 0) terminalToken.transfer(address(0xdead), hookTerminalBal);
        vm.stopPrank();

        // After H-2 fix: rebalance now reverts instead of zeroing tokenIdOf
        vm.prank(owner);
        vm.expectRevert(UniV4DeploymentSplitHook.UniV4DeploymentSplitHook_InsufficientLiquidity.selector);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        // tokenIdOf should remain unchanged (revert rolled back state)
        uint256 tokenIdAfter = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(tokenIdAfter, poolTokenId, "tokenIdOf should remain unchanged after revert");
    }

    /// @notice Normal rebalance (with nonzero liquidity) still updates tokenIdOf correctly.
    function test_rebalance_nonzeroLiquidity_updates_tokenIdOf() public {
        // Ensure PositionManager has tokens for the rebalance
        projectToken.mint(address(positionManager), 50e18);
        terminalToken.mint(address(positionManager), 50e18);

        uint256 originalTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != 0, "tokenIdOf should be nonzero after normal rebalance");
        assertTrue(newTokenId != originalTokenId, "tokenIdOf should change after rebalance");
    }
}
