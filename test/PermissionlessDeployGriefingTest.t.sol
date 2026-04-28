// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {MockERC20} from "./mock/MockERC20.sol";

/// @notice Tests for permissionless deployPool auto-selecting the highest-value terminal token.
/// @dev The attack scenario: after weight decays 10x, anyone can call deployPool. Without protection,
///      an attacker could deploy with a low-liquidity token, permanently locking out the project's
///      intended high-liquidity token via the hasDeployedPool flag.
/// @dev The fix: in the permissionless path, the caller's terminalToken argument is ignored. The hook
///      auto-selects the token with the highest ETH-denominated value across all terminals.
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
    // Test: Auto-selection overrides attacker's token choice
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacker specifies a low-liquidity token, but the hook auto-selects the highest-value one.
    function test_permissionlessDeploy_autoSelectsHighestValueToken() public {
        // Accumulate tokens (this records initialWeight)
        _accumulateTokens(PROJECT_ID, 100e18);

        // Decay weight 10x so deployment becomes permissionless
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10);

        // Approve tokens for position manager
        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        terminalToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        // Attacker tries to deploy with low-liquidity token — hook ignores it and auto-selects terminalToken
        vm.prank(attacker);
        hook.deployPool(PROJECT_ID, 0);

        // Pool was deployed with the HIGH-liquidity token, not the attacker's choice
        assertTrue(hook.hasDeployedPool(PROJECT_ID), "pool should be deployed");
        assertTrue(
            hook.tokenIdOf(PROJECT_ID, address(terminalToken)) != 0,
            "pool should exist for highest-value token (terminalToken)"
        );
        assertEq(
            hook.tokenIdOf(PROJECT_ID, address(lowLiquidityToken)),
            0,
            "no pool should exist for low-value token"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test: Permissionless deploy succeeds with any argument (auto-selects)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Anyone can permissionlessly deploy — the terminalToken argument is irrelevant.
    function test_permissionlessDeploySucceeds_anyArgument() public {
        // Accumulate tokens
        _accumulateTokens(PROJECT_ID, 100e18);

        // Decay weight 10x
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10);

        // Approve tokens for position manager
        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        terminalToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        // Pass the correct token — auto-select still picks terminalToken
        vm.prank(attacker);
        hook.deployPool(PROJECT_ID, 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "pool should be deployed");
        assertTrue(hook.tokenIdOf(PROJECT_ID, address(terminalToken)) != 0, "pool should exist for highest-value token");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test: Owner bypass — owner can deploy any token regardless of value
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Owner can deploy with any valid terminal token, even if it doesn't have the most value.
    ///         The auto-selection only applies to the permissionless path.
    function test_ownerCanDeployLowLiquidityToken() public {
        // Accumulate tokens
        _accumulateTokens(PROJECT_ID, 100e18);

        // Weight has NOT decayed — owner uses permission path (no auto-selection)
        vm.startPrank(address(hook));
        projectToken.approve(address(positionManager), type(uint256).max);
        lowLiquidityToken.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        // Owner can deploy with the low-liquidity token via permission path
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "owner should deploy with any token");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test: Single token — permissionless deploy auto-selects the only token
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When only one terminal token exists, permissionless deploy auto-selects it.
    function test_permissionlessDeploySucceeds_withSingleToken() public {
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

        // Permissionless deploy auto-selects the only available token
        vm.prank(attacker);
        hook.deployPool(freshProjectId, 0);

        assertTrue(hook.hasDeployedPool(freshProjectId), "pool should deploy with single token");
    }
}
