// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {DeployScript} from "../../script/Deploy.s.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";

contract RegressionDeployScriptHarness is DeployScript {
    function exposedGetPoolManager() external view returns (IPoolManager) {
        return _getPoolManager();
    }
}

contract RegressionRound2HookRegression is LPSplitHookV4TestBase {
    function test_permissionlessDeployCanPermanentlyLockWrongTerminalToken() public {
        MockERC20 altTerminalToken = new MockERC20("Alt Terminal", "ALT", 18);

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

        _accumulateTokens(PROJECT_ID, 200e18);

        // Set balances so that terminalToken has the highest value — the auto-select logic
        // in _findHighestValueTerminalToken will pick it regardless of what the attacker passes.
        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 10e18);
        store.setBalance(address(terminal), PROJECT_ID, address(altTerminalToken), 1e18);

        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10);

        // Outsider tries to deploy with the low-value altTerminalToken, but the fix
        // auto-selects terminalToken (highest value) instead.
        vm.prank(user);
        hook.deployPool(PROJECT_ID, 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "outsider should be able to trigger deployment");
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

contract RegressionRound2DeployScriptRegression is Test {
    function test_deployScriptDoesNotSupportOptimismSepolia() public {
        RegressionDeployScriptHarness harness = new RegressionDeployScriptHarness();

        vm.chainId(11_155_420);
        vm.expectRevert(bytes("Unsupported chain"));
        harness.exposedGetPoolManager();
    }
}
