// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";

import {Sphinx} from "@sphinx-labs/contracts/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {UniV3DeploymentSplitHook} from "../src/UniV3DeploymentSplitHook.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice the salt that is used to deploy the contract.
    bytes32 SPLIT_HOOK = "UniV3DeploymentSplitHookV6";

    /// @notice tracks the addresses that are required for the chain we are deploying to.
    address factory;
    address nonfungiblePositionManager;

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-univ3-lp-split-hook-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        // Ethereum Mainnet
        if (block.chainid == 1) {
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            nonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
            // Ethereum Sepolia
        } else if (block.chainid == 11_155_111) {
            factory = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
            nonfungiblePositionManager = 0x1238536071E1c677A632429e3655c799b22cDA52;
            // Optimism Mainnet
        } else if (block.chainid == 10) {
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            nonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
            // Base Mainnet
        } else if (block.chainid == 8453) {
            factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
            nonfungiblePositionManager = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
            // Optimism Sepolia
        } else if (block.chainid == 11_155_420) {
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            nonfungiblePositionManager = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2;
            // BASE Sepolia
        } else if (block.chainid == 84_532) {
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            nonfungiblePositionManager = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2;
            // Arbitrum Mainnet
        } else if (block.chainid == 42_161) {
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            nonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
            // Arbitrum Sepolia
        } else if (block.chainid == 421_614) {
            factory = 0x248AB79Bbb9bC29bB72f7Cd42F17e054Fc40188e;
            nonfungiblePositionManager = 0x6b2937Bde17889EDCf8fbD8dE31C3C2a70Bc4d65;
        } else {
            revert("Invalid RPC / no juice contracts deployed on this network");
        }

        // Perform the deployment transactions.
        deploy();
    }

    function deploy() public sphinx {
        new UniV3DeploymentSplitHook{salt: SPLIT_HOOK}(
            safeAddress(),
            address(core.directory),
            address(core.tokens),
            factory,
            nonfungiblePositionManager,
            vm.envOr("FEE_PROJECT_ID", uint256(0)),
            vm.envOr("FEE_PERCENT", uint256(3800)),
            vm.envOr("REV_DEPLOYER", address(0))
        );
    }

    function _isDeployed(bytes32 salt, bytes memory creationCode, bytes memory arguments) internal view returns (bool) {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            // Arachnid/deterministic-deployment-proxy address.
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        // Return if code is already present at this address.
        return address(_deployedTo).code.length != 0;
    }
}
