// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {UniV3DeploymentSplitHook} from "../UniV3DeploymentSplitHook.sol";
import {IUniV3DeploymentSplitHook} from "./IUniV3DeploymentSplitHook.sol";

interface IUniV3DeploymentSplitHookDeployer {
    event HookDeployed(
        uint256 indexed feeProjectId,
        uint256 feePercent,
        IUniV3DeploymentSplitHook hook,
        address caller
    );

    function HOOK() external view returns (UniV3DeploymentSplitHook);

    function deployHookFor(
        uint256 feeProjectId,
        uint256 feePercent,
        bytes32 salt
    )
        external
        returns (IUniV3DeploymentSplitHook hook);
}
