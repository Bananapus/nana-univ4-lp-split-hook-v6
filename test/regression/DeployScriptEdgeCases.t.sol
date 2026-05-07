// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployScript} from "../../script/Deploy.s.sol";
import {JBUniswapV4LPSplitHookDeployer} from "../../src/JBUniswapV4LPSplitHookDeployer.sol";

contract RegressionDeployScriptHarness is DeployScript {
    function exposed_isDeployed(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory arguments
    )
        external
        view
        returns (bool)
    {
        return _isDeployed(salt, creationCode, arguments);
    }
}

contract RegressionDeployScriptRegression is Test {
    function test_IsDeployedFalseNegativeForNonDeterministicDeployerFactory() public {
        RegressionDeployScriptHarness harness = new RegressionDeployScriptHarness();

        bytes32 salt = keccak256(bytes("regression-salt"));
        bytes memory creationCode = type(JBUniswapV4LPSplitHookDeployer).creationCode;
        bytes memory constructorArgs = abi.encode(address(0xBEEF), address(0xCAFE));

        address nonFoundryCreate2Factory = address(0x1234567890123456789012345678901234567890);
        address alreadyDeployed = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, constructorArgs)),
            deployer: nonFoundryCreate2Factory
        });

        vm.etch(alreadyDeployed, hex"60006000");

        assertTrue(alreadyDeployed.code.length != 0, "sanity: the alternate-factory deployment exists");
        assertFalse(
            harness.exposed_isDeployed(salt, creationCode, constructorArgs),
            "_isDeployed only checks the 0x4e59 factory and misses an existing deployment from another factory"
        );
    }
}
