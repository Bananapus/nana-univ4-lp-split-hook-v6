// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {MockERC20} from "./mock/MockERC20.sol";

/// @notice Tests for the permissionless deployPool griefing attack and its fix.
/// @dev The attack: after weight decays 10x, anyone can call deployPool with any valid
///      terminal token. Since hasDeployedPool is permanently set, the attacker can lock
///      the project into a low-liquidity token, preventing the owner from deploying with
///      the intended high-liquidity token.
/// @dev The fix: in the permissionless path, require the chosen terminal token to have
///      the highest balance among all terminal tokens for the project.
contract PermissionlessDeployGriefingTest is LPSplitHookV4TestBase {
    address attacker;
    MockERC20 lowLiquidityToken;

    function setUp() public override {
        super.setUp();
        attacker = makeAddr("attacker");

        // Deploy a second "low liquidity" terminal token
        lowLiquidityToken = new MockERC20("Low Liquidity Token", "LOW", 18);

        // Register the low-liquidity token with a terminal for this project
        _setDirectoryTerminal(PROJECT_ID, address(lowLiquidityToken), address(terminal));

        // Add accounting context for the low-liquidity token
        terminal.setAccountingContext(
            PROJECT_ID, address(lowLiquidityToken), uint32(uint160(address(lowLiquidityToken))), 18
        );
        terminal.addAccountingContext(
            PROJECT_ID,
            JBAccountingContext({
                token: address(lowLiquidityToken), decimals: 18, currency: uint32(uint160(address(lowLiquidityToken)))
            })
        );

        // Set up balances in the store:
        // terminalToken (intended) has 10 ETH of liquidity
        // lowLiquidityToken (attacker's choice) has 0.01 ETH of liquidity
        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 10e18);
        store.setBalance(address(terminal), PROJECT_ID, address(lowLiquidityToken), 0.01e18);

        // Set surplus for low liquidity token too
        store.setSurplus(PROJECT_ID, 0.5e18);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test: Griefing attack is prevented by the fix
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacker cannot deploy with the low-liquidity token when another token has more balance.
    function test_permissionlessDeployReverts_whenTokenDoesNotHaveMostLiquidity() public {
        // Accumulate tokens (this records initialWeight)
        _accumulateTokens(PROJECT_ID, 100e18);

        // Decay weight 10x so deployment becomes permissionless
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10);

        // Attacker tries to deploy with low-liquidity token — should revert
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TokenDoesNotHaveMostLiquidity.selector);
        vm.prank(attacker);
        hook.deployPool(PROJECT_ID, address(lowLiquidityToken), 0);

        // Verify the pool was NOT deployed and the flag was NOT set
        assertFalse(hook.hasDeployedPool(PROJECT_ID), "hasDeployedPool should not be set after failed attack");
        assertEq(hook.tokenIdOf(PROJECT_ID, address(lowLiquidityToken)), 0, "no pool should exist for low-liq token");
    }

    /// @notice After attack is blocked, owner can still deploy with the correct token.
    function test_ownerCanDeployAfterAttackBlocked() public {
        // Accumulate tokens
        _accumulateTokens(PROJECT_ID, 100e18);

        // Decay weight 10x
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10);

        // Attacker's attempt fails
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TokenDoesNotHaveMostLiquidity.selector);
        vm.prank(attacker);
        hook.deployPool(PROJECT_ID, address(lowLiquidityToken), 0);

        // Owner can still deploy with the correct (highest-liquidity) token
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "pool should be deployed by owner");
        assertTrue(hook.tokenIdOf(PROJECT_ID, address(terminalToken)) != 0, "pool should exist for high-liq token");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test: Permissionless deploy succeeds with highest-liquidity token
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Anyone can permissionlessly deploy with the token that has the most liquidity.
    function test_permissionlessDeploySucceeds_withHighestLiquidityToken() public {
        // Accumulate tokens
        _accumulateTokens(PROJECT_ID, 100e18);

        // Decay weight 10x
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10);

        // Approve tokens for position manager
        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        terminalToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        // Attacker (or anyone) can deploy with the highest-liquidity token
        vm.prank(attacker);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "pool should be deployed");
        assertTrue(hook.tokenIdOf(PROJECT_ID, address(terminalToken)) != 0, "pool should exist for highest-liq token");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test: Tied balances are allowed (no griefing when equal)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When two tokens have equal balance, either can be chosen permissionlessly.
    function test_permissionlessDeploySucceeds_whenBalancesAreTied() public {
        // Set both tokens to equal balance
        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 5e18);
        store.setBalance(address(terminal), PROJECT_ID, address(lowLiquidityToken), 5e18);

        // Accumulate tokens
        _accumulateTokens(PROJECT_ID, 100e18);

        // Decay weight 10x
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10);

        // Approve tokens for position manager
        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        terminalToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        // Either token should be deployable when tied
        vm.prank(attacker);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "pool should deploy with tied balance");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test: Owner bypass — owner can deploy any token regardless of liquidity
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Owner can deploy with any valid terminal token, even if it doesn't have the most liquidity.
    ///         The liquidity check only applies to the permissionless path.
    function test_ownerCanDeployLowLiquidityToken() public {
        // Accumulate tokens
        _accumulateTokens(PROJECT_ID, 100e18);

        // Weight has NOT decayed — owner uses permission path (no liquidity check)
        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        lowLiquidityToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        // Owner can deploy with the low-liquidity token via permission path
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(lowLiquidityToken), 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "owner should deploy with any token");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test: Single token (no other tokens) — permissionless deploy works
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When only one terminal token exists, permissionless deploy works fine.
    function test_permissionlessDeploySucceeds_withSingleToken() public {
        // Remove the low-liquidity token's accounting context by deploying fresh
        // We re-deploy the terminal mock to have only one accounting context
        // Actually, we can just set it up so only terminalToken has a context.
        // The base setUp already added terminalToken context. Let's use a fresh project.
        uint256 freshProjectId = 42;
        _setDirectoryController(freshProjectId, address(controller));
        controller.setWeight(freshProjectId, DEFAULT_WEIGHT);
        controller.setFirstWeight(freshProjectId, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(freshProjectId, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(freshProjectId, 1);
        _setDirectoryTerminal(freshProjectId, address(terminalToken), address(terminal));
        _addDirectoryTerminal(freshProjectId, address(terminal));
        jbTokens.setToken(freshProjectId, address(projectToken));
        jbProjects.setOwner(freshProjectId, owner);
        terminal.setAccountingContext(
            freshProjectId, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );
        // Note: we intentionally do NOT add a second accounting context for this project.
        // But we need to add at least the terminalToken context to the contexts list.
        terminal.addAccountingContext(
            freshProjectId,
            JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        );
        store.setSurplus(freshProjectId, 0.5e18);
        store.setBalance(address(terminal), freshProjectId, address(terminalToken), 10e18);

        // Accumulate tokens
        projectToken.mint(address(hook), 100e18);
        JBSplitHookContext memory context = _buildContext(freshProjectId, address(projectToken), 100e18, 1);
        vm.prank(address(controller));
        hook.processSplitWith(context);

        // Decay weight 10x
        controller.setWeight(freshProjectId, DEFAULT_WEIGHT / 10);

        // Approve tokens for position manager
        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        terminalToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        // Permissionless deploy should succeed with the only token
        vm.prank(attacker);
        hook.deployPool(freshProjectId, address(terminalToken), 0);

        assertTrue(hook.hasDeployedPool(freshProjectId), "pool should deploy with single token");
    }
}
