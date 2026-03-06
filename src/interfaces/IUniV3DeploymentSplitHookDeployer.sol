// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { IUniV3DeploymentSplitHook } from "./IUniV3DeploymentSplitHook.sol";

interface IUniV3DeploymentSplitHookDeployer {
    event HookDeployed(
        uint256 indexed feeProjectId,
        uint256 feePercent,
        IUniV3DeploymentSplitHook hook,
        address caller
    );

    function DIRECTORY() external view returns (address);
    function TOKENS() external view returns (address);
    function UNISWAP_V3_FACTORY() external view returns (address);
    function UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER() external view returns (address);
    function REV_DEPLOYER() external view returns (address);

    function deployHookFor(
        uint256 feeProjectId,
        uint256 feePercent,
        bytes32 salt
    )
        external
        returns (IUniV3DeploymentSplitHook hook);
}
