// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {IUniV4DeploymentSplitHook} from "./IUniV4DeploymentSplitHook.sol";
import {UniV4DeploymentSplitHook} from "../UniV4DeploymentSplitHook.sol";

/// @notice Deploys clones of the UniV4DeploymentSplitHook contract.
interface IUniV4DeploymentSplitHookDeployer {
    /// @notice Emitted when a new hook clone is deployed.
    /// @param feeProjectId The project ID that receives LP fees.
    /// @param feePercent The percentage of LP fees routed to the fee project.
    /// @param hook The deployed hook clone.
    /// @param caller The address that deployed the hook.
    event HookDeployed(
        uint256 indexed feeProjectId, uint256 feePercent, IUniV4DeploymentSplitHook hook, address caller
    );

    /// @notice The address registry used to register deployed hooks.
    /// @return The address registry contract.
    function ADDRESS_REGISTRY() external view returns (IJBAddressRegistry);

    /// @notice The implementation contract used as the base for clones.
    /// @return The hook implementation contract.
    function HOOK() external view returns (UniV4DeploymentSplitHook);

    /// @notice Deploy a new hook clone for a fee project.
    /// @param feeProjectId The project ID to receive LP fees.
    /// @param feePercent The percentage of LP fees to route to the fee project.
    /// @param salt A salt to use for the deterministic deployment.
    /// @return hook The deployed hook clone.
    function deployHookFor(
        uint256 feeProjectId,
        uint256 feePercent,
        bytes32 salt
    )
        external
        returns (IUniV4DeploymentSplitHook hook);
}
