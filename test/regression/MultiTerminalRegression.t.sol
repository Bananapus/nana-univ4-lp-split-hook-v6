// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract RegressionMultiTerminalRegression is LPSplitHookV4TestBase {
    MockERC20 internal altTerminalToken;
    address internal attacker;

    function setUp() public override {
        super.setUp();

        attacker = makeAddr("attacker");
        altTerminalToken = new MockERC20("Alt Terminal", "ALT", 18);

        // The project exposes two valid primary terminal tokens, but the hook does not bind
        // an intended terminal token during accumulation.
        _setDirectoryTerminal(PROJECT_ID, address(altTerminalToken), address(terminal));
        terminal.setAccountingContext(
            PROJECT_ID, address(altTerminalToken), uint32(uint160(address(altTerminalToken))), 18
        );
        terminal.addAccountingContext(
            PROJECT_ID,
            JBAccountingContext({
                token: address(altTerminalToken), decimals: 18, currency: uint32(uint160(address(altTerminalToken)))
            })
        );
    }

    function test_permissionlessDecayLetsAttackerLockWrongTerminalToken() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Set balances so that terminalToken has the highest value — the auto-select logic
        // in _findHighestValueTerminalToken will pick it regardless of what the attacker passes.
        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 10e18);
        store.setBalance(address(terminal), PROJECT_ID, address(altTerminalToken), 1e18);

        // Open the permissionless deployment window.
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10);

        // Attacker tries to deploy with the low-value altTerminalToken, but the fix
        // auto-selects terminalToken (highest value) instead.
        vm.prank(attacker);
        hook.deployPool(PROJECT_ID, 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "deployment should succeed");
        assertGt(
            hook.tokenIdOf(PROJECT_ID, address(terminalToken)),
            0,
            "auto-select should deploy the highest-value terminal token"
        );
        assertEq(
            hook.tokenIdOf(PROJECT_ID, address(altTerminalToken)),
            0,
            "attacker's low-value token should NOT be deployed"
        );
    }
}
