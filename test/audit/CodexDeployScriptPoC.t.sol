// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployScript} from "../../script/Deploy.s.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract CodexDeployScriptHarness is DeployScript {
    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getPoolManager() external view returns (IPoolManager) {
        return _getPoolManager();
    }
}

contract CodexDeployScriptPoC is Test {
    function test_getPoolManager_revertsOnUnsupportedOptimismSepolia() public {
        CodexDeployScriptHarness harness = new CodexDeployScriptHarness();

        vm.chainId(11_155_420);
        vm.expectRevert("Unsupported chain");
        harness.exposed_getPoolManager();
    }
}
