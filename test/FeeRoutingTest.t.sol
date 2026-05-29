// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

/// @notice Tests for JBUniswapV4LPSplitHook fee routing logic.
/// @dev Covers collectAndRouteLPFees, _routeFeesToProject, _routeCollectedFees, and claimFeeTokensFor.
contract FeeRoutingTest is LPSplitHookV4TestBase {
    // --- Test State --------------------------------------------------------

    uint256 public poolTokenId;

    // Token ordering helpers (set in setUp)
    bool public terminalTokenIsToken0;

    function setUp() public override {
        super.setUp();

        // Accumulate and deploy a pool for PROJECT_ID
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        poolTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Determine token ordering for this pool
        terminalTokenIsToken0 = address(terminalToken) < address(projectToken);
    }

    // --- Helpers -----------------------------------------------------------

    /// @notice Set collectable fees on the terminal token side of the pool and fund the PositionManager.
    function _setTerminalTokenFees(uint256 amount) internal {
        if (terminalTokenIsToken0) {
            positionManager.setCollectableFees(poolTokenId, amount, 0);
        } else {
            positionManager.setCollectableFees(poolTokenId, 0, amount);
        }
        // Mint terminal tokens to PositionManager so it can transfer them during collect
        terminalToken.mint(address(positionManager), amount);
    }

    /// @notice Set collectable fees on the project token side of the pool and fund the PositionManager.
    function _setProjectTokenFees(uint256 amount) internal {
        if (terminalTokenIsToken0) {
            // Project token is token1
            positionManager.setCollectableFees(poolTokenId, 0, amount);
        } else {
            // Project token is token0
            positionManager.setCollectableFees(poolTokenId, amount, 0);
        }
        // Mint project tokens to PositionManager so it can transfer them during collect
        projectToken.mint(address(positionManager), amount);
    }

    /// @notice Set collectable fees on both sides of the pool and fund the PositionManager.
    function _setBothFees(uint256 terminalAmount, uint256 projectAmount) internal {
        if (terminalTokenIsToken0) {
            positionManager.setCollectableFees(poolTokenId, terminalAmount, projectAmount);
        } else {
            positionManager.setCollectableFees(poolTokenId, projectAmount, terminalAmount);
        }
        terminalToken.mint(address(positionManager), terminalAmount);
        projectToken.mint(address(positionManager), projectAmount);
    }

    // -----------------------------------------------------------------------
    // 1. collectAndRouteLPFees collects from PositionManager
    // -----------------------------------------------------------------------

    /// @notice Verifies that collectAndRouteLPFees calls PositionManager.modifyLiquidities.
    function test_CollectFees_CollectsFromPositionManager() public {
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);

        // The mock doesn't track collectCallCount directly, but we can verify
        // the fee routing happened by checking terminal.pay was called
        uint256 payCountBefore = terminal.payCallCount();
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));
        uint256 payCountAfter = terminal.payCallCount();

        assertGt(payCountAfter, payCountBefore, "Fees should have been collected and routed");
    }

    // -----------------------------------------------------------------------
    // 2. Terminal token fees are routed via pay and addToBalance
    // -----------------------------------------------------------------------

    /// @notice When terminal token fees are collected, they should be routed:
    /// fee portion via terminal.pay (to fee project) and remainder via terminal.addToBalanceOf (to project).
    function test_CollectFees_RoutesTerminalTokenFees() public {
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);

        uint256 payCountBefore = terminal.payCallCount();
        uint256 addBalanceCountBefore = terminal.addToBalanceCallCount();

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertGt(terminal.payCallCount(), payCountBefore, "terminal.pay should have been called for fee routing");
        assertGt(
            terminal.addToBalanceCallCount(),
            addBalanceCountBefore,
            "terminal.addToBalanceOf should have been called for remainder routing"
        );
    }

    // -----------------------------------------------------------------------
    // 3. Project token fees are carried forward (not burned)
    // -----------------------------------------------------------------------

    /// @notice When project-token LP fees are collected, they are carried into the accumulation ledger to become future
    ///         liquidity, never burned.
    function test_CollectFees_CarriesProjectTokenFeesForward() public {
        uint256 projFeeAmount = 500e18;
        _setProjectTokenFees(projFeeAmount);

        uint256 burnCountBefore = controller.burnCallCount();
        uint256 accumulatedBefore = hook.accumulatedProjectTokens(PROJECT_ID);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertEq(controller.burnCallCount(), burnCountBefore, "no burn should occur when collecting fees");
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            accumulatedBefore + projFeeAmount,
            "project-token fees should be carried into the accumulation ledger"
        );
    }

    // -----------------------------------------------------------------------
    // 4. collectAndRouteLPFees reverts when no pool deployed
    // -----------------------------------------------------------------------

    /// @notice collectAndRouteLPFees should revert if no pool has been deployed for the project.
    function test_CollectFees_RevertsIfNoPoolDeployed() public {
        // Use a fresh project that has no pool deployed
        uint256 freshProjectId = 3;
        controller.setWeight(freshProjectId, DEFAULT_WEIGHT);
        controller.setFirstWeight(freshProjectId, DEFAULT_FIRST_WEIGHT);
        _setDirectoryController(freshProjectId, address(controller));

        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidStageForAction.selector);
        hook.collectAndRouteLPFees(freshProjectId, address(terminalToken));
    }

    // -----------------------------------------------------------------------
    // 5. collectAndRouteLPFees reverts if no pool exists for token pair
    // -----------------------------------------------------------------------

    /// @notice collectAndRouteLPFees should revert for a deployed project but without a pool for the given token.
    function test_CollectFees_RevertsIfNoPool() public {
        // Create a project without a deployed pool for a specific token
        uint256 noPoolProjectId = 4;
        controller.setWeight(noPoolProjectId, 1);
        controller.setFirstWeight(noPoolProjectId, DEFAULT_FIRST_WEIGHT);
        _setDirectoryController(noPoolProjectId, address(controller));

        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidStageForAction.selector);
        hook.collectAndRouteLPFees(noPoolProjectId, address(terminalToken));
    }

    // -----------------------------------------------------------------------
    // 6. collectAndRouteLPFees reverts if pool exists but tokenId is 0
    // -----------------------------------------------------------------------

    /// @notice collectAndRouteLPFees should revert when tokenIdOf is cleared.
    function test_CollectFees_RevertsIfNoTokenId() public {
        // tokenIdOf is: mapping(uint256 => mapping(address => uint256))
        // Storage layout (from forge inspect):
        //   slot  0 = buybackHook
        //   slot  1 = oracleHook
        //   slot  2 = poolManager
        //   slot  3 = positionManager
        //   slot  4 = feeProjectId
        //   slot  5 = feePercent
        //   slot 12 = poolKeysOf
        //   slot 13 = tokenIdOf
        bytes32 outerSlot = keccak256(abi.encode(PROJECT_ID, uint256(13)));
        bytes32 slot = keccak256(abi.encode(address(terminalToken), outerSlot));
        vm.store(address(hook), slot, bytes32(0));

        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidStageForAction.selector);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));
    }

    // -----------------------------------------------------------------------
    // 7. Fee split arithmetic: 38% to fee project, 62% to original project
    // -----------------------------------------------------------------------

    /// @notice Terminal token fees should be split: 38% paid to fee project, 62% added to project balance.
    function test_RouteFees_SplitsBetweenFeeAndOriginal() public {
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // FEE_PERCENT = 3800 => feeAmount = 1000e18 * 3800 / 10000 = 380e18
        uint256 expectedFee = (feeAmount * FEE_PERCENT) / 10_000;
        assertEq(expectedFee, 380e18, "Expected fee should be 380e18");

        // Verify terminal.pay was called with the fee amount
        assertEq(terminal.lastPayProjectId(), FEE_PROJECT_ID, "Pay should target FEE_PROJECT_ID");
        assertEq(terminal.lastPayAmount(), expectedFee, "Pay amount should be 38% of total fees");

        // Verify addToBalance was called (for the remaining 62%)
        assertGt(terminal.addToBalanceCallCount(), 0, "addToBalance should have been called for remainder");
    }

    // -----------------------------------------------------------------------
    // 8. Zero collectable fees result in no routing
    // -----------------------------------------------------------------------

    /// @notice When there are zero collectable fees, no pay or addToBalance calls should occur.
    function test_RouteFees_ZeroAmount_NoOp() public {
        // Don't set any collectable fees (defaults to 0)
        uint256 payCountBefore = terminal.payCallCount();
        uint256 addBalanceCountBefore = terminal.addToBalanceCallCount();

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertEq(terminal.payCallCount(), payCountBefore, "No pay calls expected for zero fees");
        assertEq(
            terminal.addToBalanceCallCount(), addBalanceCountBefore, "No addToBalance calls expected for zero fees"
        );
    }

    // -----------------------------------------------------------------------
    // 9. Fee routing tracks claimable fee tokens
    // -----------------------------------------------------------------------

    /// @notice After routing fees, claimableFeeTokens[PROJECT_ID] should be updated with minted fee tokens.
    function test_RouteFees_TracksFeeTokens() public {
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);

        uint256 claimableBefore = hook.claimableFeeTokens(PROJECT_ID);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 claimableAfter = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimableAfter, claimableBefore, "claimableFeeTokens should increase after fee routing");

        // The mock terminal mints 1:1, so fee tokens minted = feeAmount paid
        uint256 expectedFeePayment = (feeAmount * FEE_PERCENT) / 10_000; // 380e18
        assertEq(
            claimableAfter - claimableBefore,
            expectedFeePayment,
            "claimableFeeTokens should equal fee tokens minted by terminal.pay"
        );
    }

    // -----------------------------------------------------------------------
    // 10. claimFeeTokensFor -- valid operator receives tokens
    // -----------------------------------------------------------------------

    /// @notice A caller with SET_BUYBACK_POOL permission can claim accumulated fee tokens.
    function test_ClaimFeeTokens_ValidOperator() public {
        // First generate claimable fee tokens
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 claimable = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimable, 0, "Should have claimable fee tokens");

        // Grant SET_BUYBACK_POOL permission to user
        permissions.setPermission(user, owner, PROJECT_ID, JBPermissionIds.SET_BUYBACK_POOL, true);

        uint256 userBalanceBefore = feeProjectToken.balanceOf(user);

        vm.prank(user);
        hook.claimFeeTokensFor(PROJECT_ID, user);

        uint256 userBalanceAfter = feeProjectToken.balanceOf(user);
        assertEq(userBalanceAfter - userBalanceBefore, claimable, "User should receive all claimable fee tokens");
    }

    // -----------------------------------------------------------------------
    // 11. claimFeeTokensFor -- reverts for non-operator
    // -----------------------------------------------------------------------

    /// @notice claimFeeTokensFor should revert when caller lacks SET_BUYBACK_POOL permission.
    function test_ClaimFeeTokens_InvalidOperator_Reverts() public {
        // Generate claimable fee tokens first
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Do NOT grant permission to user
        vm.prank(user);
        vm.expectRevert();
        hook.claimFeeTokensFor(PROJECT_ID, user);
    }

    // -----------------------------------------------------------------------
    // 12. claimFeeTokensFor -- clears balance after claim
    // -----------------------------------------------------------------------

    /// @notice After claiming, claimableFeeTokens for the project should be zero.
    function test_ClaimFeeTokens_ClearsBalance() public {
        // Generate claimable fee tokens
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertGt(hook.claimableFeeTokens(PROJECT_ID), 0, "Should have claimable fee tokens before claim");

        // Claim as owner (has implicit permission)
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);

        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "claimableFeeTokens should be zero after claim");
    }

    // -----------------------------------------------------------------------
    // 13. collectAndRouteLPFees emits LPFeesRouted event
    // -----------------------------------------------------------------------

    /// @notice collectAndRouteLPFees should emit the LPFeesRouted event with correct parameters.
    function test_CollectFees_EmitsLPFeesRouted() public {
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);

        // Expected values
        uint256 expectedFee = (feeAmount * FEE_PERCENT) / 10_000; // 380e18
        uint256 expectedRemaining = feeAmount - expectedFee; // 620e18
        // Mock terminal mints 1:1, so feeTokensMinted = expectedFee
        uint256 expectedFeeTokensMinted = expectedFee;

        vm.expectEmit(true, true, false, true, address(hook));
        emit IJBUniswapV4LPSplitHook.LPFeesRouted(
            PROJECT_ID,
            address(terminalToken),
            feeAmount,
            expectedFee,
            expectedRemaining,
            expectedFeeTokensMinted,
            address(this)
        );

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));
    }

    // -----------------------------------------------------------------------
    // 14. Fee routing uses minReturnedTokens == 0 (accepted behavior)
    // -----------------------------------------------------------------------

    /// @notice terminal.pay() in _routeFeesToProject uses minReturnedTokens = 0 by design.
    ///         Slippage protection is the fee project's responsibility (via its own data hook /
    ///         buyback hook). A non-zero floor would revert on dust amounts where mulDiv
    ///         rounding yields 0 tokens. See RISKS.md §8.1.
    function test_feeRouting_minReturnedTokens_isZero() public {
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // The mock terminal records the minReturnedTokens argument from the last pay() call.
        assertEq(
            terminal.lastPayMinReturnedTokens(),
            0,
            "Fee routing uses minReturnedTokens = 0: slippage is fee project's responsibility"
        );
    }

    // -----------------------------------------------------------------------
    // 15. Credit path: fees tracked as claimableFeeCredits when no ERC-20
    // -----------------------------------------------------------------------

    /// @notice When the fee project has no ERC-20 deployed, fee tokens are tracked as credits
    /// and claimed via controller.transferCreditsFrom.
    function test_ClaimFeeTokens_CreditsPath() public {
        // Remove the fee project's ERC-20 so tokenOf(FEE_PROJECT_ID) returns address(0).
        jbTokens.setToken(FEE_PROJECT_ID, address(0));
        // Also remove from mock terminal so it doesn't mint ERC-20 (simulates credit-only).
        terminal.setProjectToken(FEE_PROJECT_ID, address(0));

        // Collect fees — should route to claimableFeeCredits, not claimableFeeTokens.
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 expectedFeePayment = (feeAmount * FEE_PERCENT) / 10_000; // 380e18

        // Credits should be tracked, not ERC-20 claims.
        assertEq(
            hook.claimableFeeCredits(PROJECT_ID),
            expectedFeePayment,
            "claimableFeeCredits should equal fee tokens minted as credits"
        );
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "claimableFeeTokens should remain zero for credit path");

        // Claim — should call controller.transferCreditsFrom.
        permissions.setPermission(user, owner, PROJECT_ID, JBPermissionIds.SET_BUYBACK_POOL, true);
        vm.prank(user);
        hook.claimFeeTokensFor(PROJECT_ID, user);

        // Verify transferCreditsFrom was called with correct params.
        assertEq(controller.transferCreditsCallCount(), 1, "transferCreditsFrom should be called once");
        assertEq(controller.lastTransferCreditsHolder(), address(hook), "Holder should be the hook");
        assertEq(controller.lastTransferCreditsProjectId(), FEE_PROJECT_ID, "Should transfer credits for fee project");
        assertEq(controller.lastTransferCreditsRecipient(), user, "Recipient should be the beneficiary");
        assertEq(controller.lastTransferCreditsCreditCount(), expectedFeePayment, "Credit count should match");

        // Credits should be zeroed after claim.
        assertEq(hook.claimableFeeCredits(PROJECT_ID), 0, "claimableFeeCredits should be zero after claim");
    }

    // -----------------------------------------------------------------------
    // 16. Credits do NOT increment _totalOutstandingFeeTokenClaims
    // -----------------------------------------------------------------------

    /// @notice When fee tokens are credits (no ERC-20), _totalOutstandingFeeTokenClaims should NOT increase.
    /// Credits live in JBTokens storage, not in balanceOf(this), so they don't need balance segregation.
    function test_ClaimFeeTokens_CreditsNotInTotalOutstandingClaims() public {
        // Remove the fee project's ERC-20.
        jbTokens.setToken(FEE_PROJECT_ID, address(0));
        terminal.setProjectToken(FEE_PROJECT_ID, address(0));

        // Record the hook's fee project token balance before (should be 0 since no ERC-20).
        uint256 hookBalanceBefore = feeProjectToken.balanceOf(address(hook));

        // Collect fees.
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // The hook's ERC-20 balance should not have changed (no ERC-20 minted).
        uint256 hookBalanceAfter = feeProjectToken.balanceOf(address(hook));
        assertEq(hookBalanceAfter, hookBalanceBefore, "Hook ERC-20 balance should not change for credit path");

        // claimableFeeCredits should be nonzero, claimableFeeTokens should be zero.
        assertGt(hook.claimableFeeCredits(PROJECT_ID), 0, "Credits should be tracked");
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "ERC-20 claims should not be tracked");
    }

    // -----------------------------------------------------------------------
    // 17. Transition: credits accumulated before ERC-20, then ERC-20 after
    // -----------------------------------------------------------------------

    /// @notice Accumulate credits while no ERC-20, then set tokenOf to an ERC-20 and accumulate more.
    /// Claim should transfer both: credits via controller, ERC-20 via safeTransfer.
    function test_ClaimFeeTokens_TransitionFromCreditsToERC20() public {
        // Phase 1: No ERC-20 — accumulate credits.
        jbTokens.setToken(FEE_PROJECT_ID, address(0));
        terminal.setProjectToken(FEE_PROJECT_ID, address(0));

        uint256 feeAmount1 = 1000e18;
        _setTerminalTokenFees(feeAmount1);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 expectedCredits = (feeAmount1 * FEE_PERCENT) / 10_000; // 380e18
        assertEq(hook.claimableFeeCredits(PROJECT_ID), expectedCredits, "Phase 1: credits should be tracked");
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "Phase 1: no ERC-20 claims");

        // Phase 2: Deploy ERC-20 for fee project — accumulate ERC-20 tokens.
        jbTokens.setToken(FEE_PROJECT_ID, address(feeProjectToken));
        terminal.setProjectToken(FEE_PROJECT_ID, address(feeProjectToken));

        uint256 feeAmount2 = 500e18;
        _setTerminalTokenFees(feeAmount2);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 expectedTokens = (feeAmount2 * FEE_PERCENT) / 10_000; // 190e18
        assertEq(hook.claimableFeeCredits(PROJECT_ID), expectedCredits, "Phase 2: credits unchanged");
        assertEq(hook.claimableFeeTokens(PROJECT_ID), expectedTokens, "Phase 2: ERC-20 claims tracked");

        // Claim both in one call.
        permissions.setPermission(user, owner, PROJECT_ID, JBPermissionIds.SET_BUYBACK_POOL, true);
        uint256 userBalanceBefore = feeProjectToken.balanceOf(user);

        vm.prank(user);
        hook.claimFeeTokensFor(PROJECT_ID, user);

        // ERC-20 transfer should have happened.
        uint256 userBalanceAfter = feeProjectToken.balanceOf(user);
        assertEq(userBalanceAfter - userBalanceBefore, expectedTokens, "User should receive ERC-20 tokens");

        // Credit transfer should have happened.
        assertEq(controller.transferCreditsCallCount(), 1, "transferCreditsFrom should be called");
        assertEq(controller.lastTransferCreditsCreditCount(), expectedCredits, "Credit count should match phase 1");

        // Both mappings should be zeroed.
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "ERC-20 claims should be zero after claim");
        assertEq(hook.claimableFeeCredits(PROJECT_ID), 0, "Credits should be zero after claim");
    }
}
