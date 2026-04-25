// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {DeployScript} from "../../script/Deploy.s.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";

contract CodexNemesisDeployScriptHarness is DeployScript {
    function exposedGetPoolManager() external view returns (IPoolManager) {
        return _getPoolManager();
    }
}

contract CodexNemesisRound2HookPoC is LPSplitHookV4TestBase {
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

        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10);

        vm.prank(user);
        hook.deployPool(PROJECT_ID, address(altTerminalToken), 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "outsider should be able to flip the project into deployed mode");
        assertGt(
            hook.tokenIdOf(PROJECT_ID, address(altTerminalToken)), 0, "outsider should be able to lock the alt pair"
        );
        assertEq(
            hook.tokenIdOf(PROJECT_ID, address(terminalToken)),
            0,
            "the intended terminal token pair should remain undeployed"
        );

        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported()")));
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);
    }
}

contract CodexNemesisRound2DeployScriptPoC is Test {
    function test_deployScriptDoesNotSupportOptimismSepolia() public {
        CodexNemesisDeployScriptHarness harness = new CodexNemesisDeployScriptHarness();

        vm.chainId(11_155_420);
        vm.expectRevert(bytes("Unsupported chain"));
        harness.exposedGetPoolManager();
    }
}
