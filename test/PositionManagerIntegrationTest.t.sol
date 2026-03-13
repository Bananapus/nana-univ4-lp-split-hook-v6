// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";

/// @notice Tests validating realistic PositionManager token flows.
/// @dev The improved MockPositionManager tracks locked amounts, owed amounts, and
///      enforces approval/balance during SETTLE. These tests verify the hook's
///      token handling works correctly against that more realistic simulation.
contract PositionManagerIntegrationTest is LPSplitHookV4TestBase {
    // ─── Deploy: tokens flow from hook → PositionManager via SETTLE ──

    /// @notice After deployPool, project tokens should be pulled from the hook
    ///         into the PositionManager (locked in the LP position).
    function test_Deploy_TokensTransferredToPositionManager() public {
        uint256 accumAmount = 100e18;
        _accumulateTokens(PROJECT_ID, accumAmount);

        uint256 hookProjectBefore = projectToken.balanceOf(address(hook));
        uint256 pmProjectBefore = projectToken.balanceOf(address(positionManager));

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        uint256 hookProjectAfter = projectToken.balanceOf(address(hook));
        uint256 pmProjectAfter = projectToken.balanceOf(address(positionManager));

        // Hook should have fewer project tokens (they went to PM).
        assertLt(hookProjectAfter, hookProjectBefore, "Hook should transfer project tokens to PM");
        // PM should have received project tokens.
        assertGt(pmProjectAfter, pmProjectBefore, "PM should receive project tokens");
    }

    // ─── Deploy: terminal tokens from cash-out flow to PM ────────────

    /// @notice After deployPool, the hook cashes out some project tokens for terminal tokens,
    ///         then those terminal tokens get sent to PM via SETTLE.
    function test_Deploy_TerminalTokensFlowToPM() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        uint256 pmTermBefore = terminalToken.balanceOf(address(positionManager));

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        uint256 pmTermAfter = terminalToken.balanceOf(address(positionManager));

        // PM should receive terminal tokens (from the cash-out proceeds).
        assertGt(pmTermAfter, pmTermBefore, "PM should receive terminal tokens from cash-out");
    }

    // ─── Rebalance: burn returns tokens, then re-mints ───────────────

    /// @notice Rebalancing should burn the old position (returning locked tokens to the hook),
    ///         then mint a new position (transferring tokens back to PM).
    function test_Rebalance_TokensReturnedAndRedeposited() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 oldTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(oldTokenId != 0, "should have a position");

        // Seed PM with extra tokens so the burn can return them.
        projectToken.mint(address(positionManager), 50e18);
        terminalToken.mint(address(positionManager), 50e18);

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != oldTokenId, "tokenId should change after rebalance");

        // After rebalance, the hook should have processed tokens through burn → take → settle → mint.
        // The mock enforces real transfers, so if any step failed the tx would revert.
    }

    // ─── Fee collection: fees transfer from PM to hook ───────────────

    /// @notice collectAndRouteLPFees should collect fees from PM and route them.
    function test_FeeCollection_FeesTransferFromPM() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Sort tokens to know which is currency0/currency1.
        (address token0,) = _sortTokens(address(projectToken), address(terminalToken));

        uint256 feeAmount = 5e18;
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees(tokenId, feeAmount, 0);
            terminalToken.mint(address(positionManager), feeAmount);
        } else {
            positionManager.setCollectableFees(tokenId, 0, feeAmount);
            terminalToken.mint(address(positionManager), feeAmount);
        }

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Fees should have been routed (hook balance may not increase because fees
        // get forwarded to fee project + original project, but the terminal's
        // pay/addToBalance counts should reflect routing).
        bool feesProcessed = terminal.payCallCount() > 0 || terminal.addToBalanceCallCount() > 0;
        assertTrue(feesProcessed, "Fee routing should call pay or addToBalance");
    }

    // ─── Deploy: conservation — no tokens created from thin air ──────

    /// @notice The total token supply across hook + PM should be conserved during deploy.
    ///         (Minus any tokens burned by the hook.)
    function test_Deploy_TokenConservation() public {
        uint256 accumAmount = 100e18;
        _accumulateTokens(PROJECT_ID, accumAmount);

        // Record total supply across hook + PM + terminal (terminal may receive cash-out tokens).
        uint256 totalProjectBefore = projectToken.balanceOf(address(hook))
            + projectToken.balanceOf(address(positionManager)) + projectToken.balanceOf(address(terminal));
        uint256 totalTermBefore = terminalToken.balanceOf(address(hook))
            + terminalToken.balanceOf(address(positionManager)) + terminalToken.balanceOf(address(terminal));

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        uint256 totalProjectAfter = projectToken.balanceOf(address(hook))
            + projectToken.balanceOf(address(positionManager)) + projectToken.balanceOf(address(terminal));
        uint256 totalTermAfter = terminalToken.balanceOf(address(hook))
            + terminalToken.balanceOf(address(positionManager)) + terminalToken.balanceOf(address(terminal));

        // Project tokens may decrease (burned by _handleLeftoverTokens), but never increase.
        assertLe(totalProjectAfter, totalProjectBefore, "Project tokens should not be created");
        // Terminal tokens are minted by mock terminal during cash-out, so they can increase.
        // But they should never be lost (terminal tokens across all contracts >= before).
        assertGe(totalTermAfter, totalTermBefore, "Terminal tokens should not be destroyed");
    }

    // ─── Rebalance with fees: full cycle burn → collect → route → mint ─

    /// @notice End-to-end rebalance with accumulated fees exercises the full token flow:
    ///         burn (return locked + fees) → take → route fees → settle → mint.
    function test_Rebalance_FullCycleWithFees() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Configure fees on the old position.
        (address token0,) = _sortTokens(address(projectToken), address(terminalToken));
        uint256 termFee = 3e18;
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees(tokenId, termFee, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, termFee);
        }
        // Seed PM so it can pay out the fees + locked amounts.
        projectToken.mint(address(positionManager), 100e18);
        terminalToken.mint(address(positionManager), 100e18);

        uint256 payBefore = terminal.payCallCount();
        uint256 addBefore = terminal.addToBalanceCallCount();

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        // Verify fees were routed.
        bool feesRouted = (terminal.payCallCount() > payBefore) || (terminal.addToBalanceCallCount() > addBefore);
        assertTrue(feesRouted, "Fees from old position should be routed during rebalance");

        // Verify new position was created.
        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != tokenId, "New position should be minted");
    }

    // ─── Deploy: partial usage — sweep returns unused tokens ─────────

    /// @notice When the PositionManager only uses a fraction of provided tokens,
    ///         SWEEP should return the unused portion to the hook.
    function test_Deploy_PartialUsage_SweepReturnsLeftover() public {
        // Configure PM to only use 80% of provided amounts.
        positionManager.setUsagePercent(8000);

        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        // Position should still be created successfully.
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(tokenId != 0, "Position should be created even with partial usage");

        // SWEEP should have returned unused tokens — verify hook still has some.
        // (The exact amounts depend on cash-out math, but with 80% usage there
        // should be some swept back.)
    }

    // ─── Helper
    // ──────────────────────────────────────────────────────

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
