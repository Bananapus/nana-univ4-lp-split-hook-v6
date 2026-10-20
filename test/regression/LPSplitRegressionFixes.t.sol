// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";

/// @notice Tests the credit-only split regression.
contract LPSplitRegressionFixes is LPSplitHookV4TestBase {
    // A project ID with no ERC-20 token set, so its splits take the credits path.
    uint256 constant NO_TOKEN_PROJECT_ID = 99;

    function setUp() public override {
        super.setUp();

        // Set up project 99 with a controller but NO ERC-20 token.
        _setDirectoryController(NO_TOKEN_PROJECT_ID, address(controller));
        controller.setWeight(NO_TOKEN_PROJECT_ID, DEFAULT_WEIGHT);
        controller.setFirstWeight(NO_TOKEN_PROJECT_ID, DEFAULT_WEIGHT);
        // Deliberately do NOT call jbTokens.setToken(NO_TOKEN_PROJECT_ID, ...).
        // tokenOf(99) will return address(0).
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Credit-only splits — unbacked claims revert before any ledger write
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For a project with no ERC-20 token, processSplitWith takes the credits path. When no credits were
    ///         actually transferred to the hook (a lying controller), the backing check reverts with
    ///         JBUniswapV4LPSplitHook_InsufficientBalance BEFORE any ledger write.
    function test_M41_fix_reverts_before_accumulate() public {
        // Verify the project has no ERC-20 token set.
        assertEq(address(jbTokens.tokenOf(NO_TOKEN_PROJECT_ID)), address(0), "precondition: no ERC-20 token");

        // Confirm accumulator is zero before.
        assertEq(hook.accumulatedProjectTokens(NO_TOKEN_PROJECT_ID), 0, "precondition: accumulator is zero");

        // Build a reserved-token split context for the project with no ERC-20 token.
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(projectToken), // token field (what token is being split)
            amount: 50e18,
            decimals: 18,
            projectId: NO_TOKEN_PROJECT_ID,
            groupId: 1, // reserved token group
            split: JBSplit({
                percent: 1_000_000,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(hook))
            })
        });

        // Call processSplitWith from the controller — the unbacked credits claim must revert.
        vm.prank(address(controller));
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InsufficientBalance.selector);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);

        // Neither ledger is written, because the revert happens before any accounting.
        assertEq(hook.accumulatedProjectTokens(NO_TOKEN_PROJECT_ID), 0, "accumulator must remain zero after revert");
        assertEq(hook.accumulatedProjectCredits(NO_TOKEN_PROJECT_ID), 0, "credit ledger must remain zero after revert");
    }
}
