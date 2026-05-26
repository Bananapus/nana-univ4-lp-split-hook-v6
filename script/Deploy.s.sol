// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {SuckerDeployment, SuckerDeploymentLib} from "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice tracks the deployment of the address registry for the chain we are deploying to.
    AddressRegistryDeployment registry;

    /// @notice tracks the deployment of the univ4-router contracts for the chain we are deploying to.
    Univ4RouterDeployment router;

    /// @notice tracks the deployment of the sucker contracts for the chain we are deploying to.
    SuckerDeployment suckers;

    /// @notice the salts used to deploy the contracts.
    bytes32 hookSalt = "JBUniswapV4LPSplitHookV6";
    bytes32 deployerSalt = "JBUniswapV4LPSplitHookDeployerV6";

    /// @notice Uniswap V4 addresses (per-chain)
    IPoolManager poolManager;
    IPositionManager positionManager;

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-univ4-lp-split-hook-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "base_sepolia", "arbitrum_sepolia"];
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

        // Get the deployment addresses for the suckers for this chain.
        suckers = SuckerDeploymentLib.getDeployment(
            vm.envOr("NANA_SUCKERS_DEPLOYMENT_PATH", string("node_modules/@bananapus/suckers-v6/deployments/"))
        );

        // Uniswap V4 PoolManager — per-chain addresses.
        // Verify at https://docs.uniswap.org/contracts/v4/deployments
        poolManager = _getPoolManager();

        // Uniswap V4 PositionManager — per-chain addresses
        positionManager = _getPositionManager();

        // Perform the deployment transactions.
        deploy();
    }

    function deploy() public sphinx {
        // Chain-same constructor args — the chain-specific Uniswap V4 addresses are no longer in the constructor;
        // they are passed into each fresh clone by `JBUniswapV4LPSplitHookDeployer.deployHookFor` via its own
        // setChainSpecificConstants storage.
        bytes memory hookArgs = abi.encode(
            address(core.directory),
            core.permissions,
            address(core.tokens),
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3),
            suckers.registry
        );

        address hookImplAddress = vm.computeCreate2Address({
            salt: hookSalt,
            initCodeHash: keccak256(abi.encodePacked(type(JBUniswapV4LPSplitHook).creationCode, hookArgs))
        });
        bool hookAlreadyDeployed = hookImplAddress.code.length != 0;
        if (!hookAlreadyDeployed) {
            hookImplAddress = address(
                new JBUniswapV4LPSplitHook{salt: hookSalt}({
                    directory: address(core.directory),
                    permissions: core.permissions,
                    tokens: address(core.tokens),
                    permit2: IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3),
                    suckerRegistry: suckers.registry
                })
            );
        }

        // Thread the actual implementation address from the active deployment path into the deployer.
        // Deployer construction is chain-identical (CREATE2 inputs are byte-identical across chains); the
        // chain-specific hook implementation is wired in afterwards via setChainSpecificConstants.
        JBUniswapV4LPSplitHook hookImpl = JBUniswapV4LPSplitHook(payable(hookImplAddress));

        bytes memory deployerCtorArgs = abi.encode(address(registry.registry), safeAddress());
        JBUniswapV4LPSplitHookDeployer deployer = JBUniswapV4LPSplitHookDeployer(
            vm.computeCreate2Address({
                salt: deployerSalt,
                initCodeHash: keccak256(
                    abi.encodePacked(type(JBUniswapV4LPSplitHookDeployer).creationCode, deployerCtorArgs)
                ),
                deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
            })
        );
        if (address(deployer).code.length == 0) {
            deployer = new JBUniswapV4LPSplitHookDeployer{salt: deployerSalt}({
                addressRegistry: registry.registry, deployer: safeAddress()
            });
        }
        if (address(deployer.hookImplementation()) == address(0)) {
            deployer.setChainSpecificConstants({
                newHookImplementation: hookImpl,
                newPoolManager: poolManager,
                newPositionManager: positionManager,
                newOracleHook: router.hook
            });
        }
    }

    /// @dev Returns the Uniswap V4 PositionManager address for the current chain.
    /// @dev Addresses sourced from https://developers.uniswap.org/docs/protocols/v4/deployments — testnet
    /// PositionManagers are NOT the same as the mainnet address.
    function _getPositionManager() internal view returns (IPositionManager) {
        if (block.chainid == 1) return IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e); // Mainnet
        if (block.chainid == 10) return IPositionManager(0x3C3Ea4B57a46241e54610e5f022E5c45859A1017); // Optimism
        if (block.chainid == 8453) return IPositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc); // Base
        if (block.chainid == 42_161) return IPositionManager(0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869); // Arbitrum
        if (block.chainid == 11_155_111) return IPositionManager(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4); // Sepolia
        if (block.chainid == 84_532) return IPositionManager(0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80); // Base
        // Sepolia
        if (block.chainid == 421_614) return IPositionManager(0xAc631556d3d4019C95769033B5E719dD77124BAc); // Arb
        // Sepolia
        revert("Unsupported chain");
    }

    /// @dev Returns the Uniswap V4 PoolManager address for the current chain.
    function _getPoolManager() internal view returns (IPoolManager) {
        if (block.chainid == 1) return IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90); // Mainnet
        if (block.chainid == 10) return IPoolManager(0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3); // Optimism
        if (block.chainid == 8453) return IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b); // Base
        if (block.chainid == 42_161) return IPoolManager(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32); // Arbitrum
        if (block.chainid == 11_155_111) return IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543); // Sepolia
        if (block.chainid == 84_532) return IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408); // Base Sepolia
        if (block.chainid == 421_614) return IPoolManager(0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317); // Arb Sepolia
        revert("Unsupported chain");
    }

    /// @dev Uses the deterministic CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C).
    /// Sphinx deployments use a different deployer, so this will not detect Sphinx-deployed contracts.
    function _isDeployed(bytes32 salt, bytes memory creationCode, bytes memory arguments) internal view returns (bool) {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        return address(_deployedTo).code.length != 0;
    }
}
