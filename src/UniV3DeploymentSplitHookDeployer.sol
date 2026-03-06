// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {UniV3DeploymentSplitHook} from "./UniV3DeploymentSplitHook.sol";
import {IUniV3DeploymentSplitHook} from "./interfaces/IUniV3DeploymentSplitHook.sol";
import {IUniV3DeploymentSplitHookDeployer} from "./interfaces/IUniV3DeploymentSplitHookDeployer.sol";

contract UniV3DeploymentSplitHookDeployer is IUniV3DeploymentSplitHookDeployer {
    address public immutable override DIRECTORY;
    address public immutable override TOKENS;
    address public immutable override UNISWAP_V3_FACTORY;
    address public immutable override UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER;
    address public immutable override REV_DEPLOYER;

    constructor(
        address directory,
        address tokens,
        address uniswapV3Factory,
        address uniswapV3NonfungiblePositionManager,
        address revDeployer
    ) {
        DIRECTORY = directory;
        TOKENS = tokens;
        UNISWAP_V3_FACTORY = uniswapV3Factory;
        UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER = uniswapV3NonfungiblePositionManager;
        REV_DEPLOYER = revDeployer;
    }

    function deployHookFor(
        uint256 feeProjectId,
        uint256 feePercent,
        bytes32 salt
    ) external override returns (IUniV3DeploymentSplitHook hook) {
        if (salt == bytes32(0)) {
            hook = IUniV3DeploymentSplitHook(
                address(
                    new UniV3DeploymentSplitHook(
                        msg.sender,
                        DIRECTORY,
                        TOKENS,
                        UNISWAP_V3_FACTORY,
                        UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER,
                        feeProjectId,
                        feePercent,
                        REV_DEPLOYER
                    )
                )
            );
        } else {
            hook = IUniV3DeploymentSplitHook(
                address(
                    new UniV3DeploymentSplitHook{salt: keccak256(abi.encode(msg.sender, salt))}(
                        msg.sender,
                        DIRECTORY,
                        TOKENS,
                        UNISWAP_V3_FACTORY,
                        UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER,
                        feeProjectId,
                        feePercent,
                        REV_DEPLOYER
                    )
                )
            );
        }

        emit HookDeployed(feeProjectId, feePercent, hook, msg.sender);
    }
}
