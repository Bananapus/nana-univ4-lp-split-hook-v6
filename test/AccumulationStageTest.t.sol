// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

/// @notice Tests for JBUniswapV4LPSplitHook pre-deployment (accumulation) behavior.
/// @dev Covers projectDeployed/isPoolDeployed logic, processSplitWith accumulation, revert conditions, and
/// supportsInterface.
contract AccumulationStageTest is LPSplitHookV4TestBase {
    // -----------------------------------------------------------------------
    // 1. projectDeployed -- false before any pool deployed
    // -----------------------------------------------------------------------

    /// @notice Before any pool is deployed, projectDeployed should be false.
    function test_ProjectDeployed_FalseBeforeDeploy() public view {
        assertFalse(
            hook.isPoolDeployed(PROJECT_ID, address(terminalToken)), "projectDeployed should be false before any deploy"
        );
    }

    // -----------------------------------------------------------------------
    // 2. isPoolDeployed -- false before pool deployed for token pair
    // -----------------------------------------------------------------------

    /// @notice Before deployPool is called, isPoolDeployed should return false.
    function test_IsPoolDeployed_FalseBeforeDeploy() public view {
        assertFalse(
            hook.isPoolDeployed(PROJECT_ID, address(terminalToken)), "isPoolDeployed should be false before deploy"
        );
    }

    // -----------------------------------------------------------------------
    // 3. projectDeployed -- true after pool deployed
    // -----------------------------------------------------------------------

    /// @notice After deployPool succeeds, projectDeployed should be true and
    ///         isPoolDeployed should return true for the deployed token pair.
    function test_ProjectDeployed_TrueAfterDeploy() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        assertTrue(
            hook.isPoolDeployed(PROJECT_ID, address(terminalToken)), "projectDeployed should be true after deploy"
        );
        assertTrue(
            hook.isPoolDeployed(PROJECT_ID, address(terminalToken)), "isPoolDeployed should be true after deploy"
        );
    }

    // -----------------------------------------------------------------------
    // 4. processSplitWith -- accumulates tokens correctly
    // -----------------------------------------------------------------------

    /// @notice Calling processSplitWith before pool deployment increments accumulatedProjectTokens.
    function test_ProcessSplit_Accumulates() public {
        uint256 amount = 500e18;

        _accumulateTokens(PROJECT_ID, amount);

        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID), amount, "accumulatedProjectTokens should equal deposited amount"
        );
    }

    // -----------------------------------------------------------------------
    // 5. processSplitWith -- multiple accumulations sum correctly
    // -----------------------------------------------------------------------

    /// @notice Three separate accumulations should sum to the total.
    function test_ProcessSplit_MultipleAccumulations() public {
        uint256 amount1 = 100e18;
        uint256 amount2 = 250e18;
        uint256 amount3 = 650e18;

        _accumulateTokens(PROJECT_ID, amount1);
        _accumulateTokens(PROJECT_ID, amount2);
        _accumulateTokens(PROJECT_ID, amount3);

        uint256 expectedTotal = amount1 + amount2 + amount3;
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            expectedTotal,
            "accumulatedProjectTokens should equal sum of all deposits"
        );
    }

    // -----------------------------------------------------------------------
    // 6. processSplitWith -- reverts if caller is not the controller
    // -----------------------------------------------------------------------

    /// @notice processSplitWith reverts when msg.sender is not the project controller.
    function test_ProcessSplit_RevertsIf_NotController() public {
        uint256 amount = 100e18;
        projectToken.mint(address(hook), amount);

        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, amount);

        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal.selector);
        // Call from `user` instead of controller
        vm.prank(user);
        hook.processSplitWith(context);
    }

    // -----------------------------------------------------------------------
    // 7. processSplitWith -- reverts if hook in context does not match
    // -----------------------------------------------------------------------

    /// @notice processSplitWith reverts when context.split.hook points to a different address.
    function test_ProcessSplit_RevertsIf_HookMismatch() public {
        uint256 amount = 100e18;
        projectToken.mint(address(hook), amount);

        // Build context with a split whose hook is a different address
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(projectToken),
            amount: amount,
            decimals: 18,
            projectId: PROJECT_ID,
            groupId: 1,
            split: JBSplit({
                percent: 1_000_000,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0xdead)) // Wrong hook address
            })
        });

        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NotHookSpecifiedInContext.selector);
        vm.prank(address(controller));
        hook.processSplitWith(context);
    }

    // -----------------------------------------------------------------------
    // 8. processSplitWith -- reverts if groupId is not 1
    // -----------------------------------------------------------------------

    /// @notice processSplitWith reverts with TerminalTokensNotAllowed when groupId != 1.
    function test_ProcessSplit_RevertsIf_GroupIdNotOne() public {
        uint256 amount = 100e18;
        projectToken.mint(address(hook), amount);

        // Build context with groupId=0 (payout split, not reserved tokens)
        JBSplitHookContext memory context = _buildContext(PROJECT_ID, address(projectToken), amount, 0);

        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TerminalTokensNotAllowed.selector);
        vm.prank(address(controller));
        hook.processSplitWith(context);
    }

    // -----------------------------------------------------------------------
    // 9. processSplitWith -- reverts if project has no controller
    // -----------------------------------------------------------------------

    /// @notice processSplitWith reverts with InvalidProjectId when controllerOf returns address(0).
    function test_ProcessSplit_RevertsIf_InvalidProject() public {
        uint256 invalidProjectId = 999;
        uint256 amount = 100e18;
        projectToken.mint(address(hook), amount);

        // Project 999 has no controller set in directory (defaults to address(0))
        JBSplitHookContext memory context = _buildReservedContext(invalidProjectId, amount);

        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidProjectId.selector);
        // Even pranking as some address, it will fail at the controllerOf check first
        vm.prank(address(controller));
        hook.processSplitWith(context);
    }

    // -----------------------------------------------------------------------
    // 10. supportsInterface -- both interface IDs return true
    // -----------------------------------------------------------------------

    /// @notice supportsInterface returns true for IJBUniswapV4LPSplitHook and IJBSplitHook.
    function test_SupportsInterface() public view {
        assertTrue(
            hook.supportsInterface(type(IJBUniswapV4LPSplitHook).interfaceId), "Should support IJBUniswapV4LPSplitHook"
        );
        assertTrue(hook.supportsInterface(type(IJBSplitHook).interfaceId), "Should support IJBSplitHook");
        // Verify a random interface ID returns false
        assertFalse(hook.supportsInterface(bytes4(0xdeadbeef)), "Should NOT support arbitrary interface");
    }

    // -----------------------------------------------------------------------
    // 11. processSplitWith -- burns after pool deployed
    // -----------------------------------------------------------------------

    /// @notice After deployPool is called, processSplitWith burns tokens instead of accumulating.
    function test_ProcessSplit_BurnsAfterDeployed() public {
        // Deploy pool first
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        assertTrue(hook.isPoolDeployed(PROJECT_ID, address(terminalToken)), "projectDeployed should be true");

        uint256 burnCountBefore = controller.burnCallCount();

        // Now processSplitWith should burn instead of accumulate
        uint256 newAmount = 50e18;
        projectToken.mint(address(hook), newAmount);
        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);

        vm.prank(address(controller));
        hook.processSplitWith(context);

        // Verify tokens were burned
        assertGt(controller.burnCallCount(), burnCountBefore, "burnTokensOf should be called after deployment");

        // Verify accumulated stays 0
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "accumulatedProjectTokens should remain 0 after burn");
    }

    // -----------------------------------------------------------------------
    // 12. processSplitWith -- zero amount succeeds, accumulated stays same
    // -----------------------------------------------------------------------

    /// @notice Calling processSplitWith with 0 tokens succeeds and does not change accumulated balance.
    function test_ProcessSplit_ZeroAmount() public {
        // First accumulate some tokens so we can verify the balance is unchanged
        uint256 initialAmount = 200e18;
        _accumulateTokens(PROJECT_ID, initialAmount);

        // Now call with 0 amount
        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, 0);

        vm.prank(address(controller));
        hook.processSplitWith(context);

        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            initialAmount,
            "accumulatedProjectTokens should remain unchanged after zero-amount call"
        );
    }

    // -----------------------------------------------------------------------
    // 13. processSplitWith -- reverts for credit tokens (address(0))
    // -----------------------------------------------------------------------

    /// @notice processSplitWith reverts when the project token is address(0) (credits, no ERC-20 deployed).
    ///         The hook requires an ERC-20 project token because credits cannot be paired as Uniswap V4 LP.
    function test_ProcessSplit_RevertsIf_CreditToken() public {
        uint256 amount = 100e18;

        // Build context with token = address(0) — simulating a project that only has credits
        JBSplitHookContext memory context = _buildContext(PROJECT_ID, address(0), amount, 1);

        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidProjectId.selector);
        vm.prank(address(controller));
        hook.processSplitWith(context);
    }

    // -----------------------------------------------------------------------
    // 14. processSplitWith -- reverts if balance doesn't cover accumulated
    // -----------------------------------------------------------------------

    /// @notice processSplitWith reverts with InsufficientBalance when the contract's ERC-20 balance
    ///         is less than the accumulated total (e.g., a custom controller that doesn't transfer first).
    function test_ProcessSplit_RevertsIf_InsufficientBalance() public {
        // First, do a legitimate accumulation so the counter is nonzero
        _accumulateTokens(PROJECT_ID, 100e18);
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 100e18);

        // Now simulate a custom controller that calls processSplitWith WITHOUT transferring tokens first.
        // The hook's balance is 100e18 but after this call the accumulator would be 200e18.
        // We burn tokens from the hook to create the deficit.
        vm.prank(address(hook));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        projectToken.transfer(address(0xdead), 50e18);

        // Hook balance is now 50e18 but accumulator is 100e18.
        // Another accumulation of 1e18 would push accumulator to 101e18 > balance of 51e18 (if transferred).
        // But we simulate no transfer — just the call.
        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, 1e18);

        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InsufficientBalance.selector);
        vm.prank(address(controller));
        hook.processSplitWith(context);
    }
}
