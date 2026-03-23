// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import {
    AddressRegistryDeployment,
    AddressRegistryDeploymentLib
} from "@bananapus/address-registry-v6/script/helpers/AddressRegistryDeploymentLib.sol";
import {
    Univ4RouterDeployment,
    Univ4RouterDeploymentLib
} from "@bananapus/univ4-router-v6/script/helpers/Univ4RouterDeploymentLib.sol";

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookDeployer} from "../src/JBUniswapV4LPSplitHookDeployer.sol";

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice tracks the deployment of the address registry for the chain we are deploying to.
    AddressRegistryDeployment registry;

    /// @notice tracks the deployment of the univ4-router contracts for the chain we are deploying to.
    Univ4RouterDeployment router;

    /// @notice the salts used to deploy the contracts.
    bytes32 hookSalt = "JBUniswapV4LPSplitHookV6";
    bytes32 deployerSalt = "JBUniswapV4LPSplitHookDeployerV6";

    /// @notice Uniswap V4 addresses (same on all chains)
    IPoolManager poolManager;
    IPositionManager positionManager;

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-univ4-lp-split-hook-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        // Get the deployment addresses for the address registry for this chain.
        registry = AddressRegistryDeploymentLib.getDeployment(
            vm.envOr(
                "NANA_ADDRESS_REGISTRY_DEPLOYMENT_PATH",
                string("node_modules/@bananapus/address-registry-v6/deployments/")
            )
        );

        // Get the deployment addresses for the univ4-router for this chain.
        router = Univ4RouterDeploymentLib.getDeployment(
            vm.envOr(
                "NANA_UNIV4_ROUTER_DEPLOYMENT_PATH", string("node_modules/@bananapus/univ4-router-v6/deployments/")
            )
        );

        // Uniswap V4 PoolManager — canonical address on all chains
        poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

        // Uniswap V4 PositionManager — per-chain addresses
        if (block.chainid == 1) {
            // Ethereum Mainnet
            positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        } else if (block.chainid == 11_155_111) {
            // Ethereum Sepolia
            positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        } else if (block.chainid == 10) {
            // Optimism Mainnet
            positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        } else if (block.chainid == 8453) {
            // Base Mainnet
            positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        } else if (block.chainid == 11_155_420) {
            // Optimism Sepolia
            positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        } else if (block.chainid == 84_532) {
            // Base Sepolia
            positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        } else if (block.chainid == 42_161) {
            // Arbitrum Mainnet
            positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        } else if (block.chainid == 421_614) {
            // Arbitrum Sepolia
            positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        } else {
            revert("Invalid RPC / no juice contracts deployed on this network");
        }

        // Perform the deployment transactions.
        deploy();
    }

    function deploy() public sphinx {
        JBUniswapV4LPSplitHook hookImpl = new JBUniswapV4LPSplitHook{salt: hookSalt}(
            address(core.directory),
            core.permissions,
            address(core.tokens),
            poolManager,
            positionManager,
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3),
            router.hook
        );

        new JBUniswapV4LPSplitHookDeployer{salt: deployerSalt}(hookImpl, registry.registry);
    }


}
