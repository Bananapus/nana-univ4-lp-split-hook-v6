// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UniV4DeploymentSplitHook} from "../UniV4DeploymentSplitHook.sol";
import {IUniV4DeploymentSplitHook} from "./IUniV4DeploymentSplitHook.sol";

interface IUniV4DeploymentSplitHookDeployer {
    event HookDeployed(
        uint256 indexed feeProjectId, uint256 feePercent, IUniV4DeploymentSplitHook hook, address caller
    );

    function HOOK() external view returns (UniV4DeploymentSplitHook);

    function deployHookFor(
        uint256 feeProjectId,
        uint256 feePercent,
        bytes32 salt
    )
        external
        returns (IUniV4DeploymentSplitHook hook);
}
