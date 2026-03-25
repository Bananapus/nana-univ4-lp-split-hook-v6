// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {IJBUniswapV4LPSplitHook} from "./IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHook} from "../JBUniswapV4LPSplitHook.sol";

/// @notice Deploys clones of the JBUniswapV4LPSplitHook contract.
interface IJBUniswapV4LPSplitHookDeployer {
    /// @notice Emitted when a new hook clone is deployed.
    /// @param feeProjectId The project ID that receives LP fees.
    /// @param feePercent The percentage of LP fees routed to the fee project.
    /// @param hook The deployed hook clone.
    /// @param caller The address that deployed the hook.
    event HookDeployed(uint256 indexed feeProjectId, uint256 feePercent, IJBUniswapV4LPSplitHook hook, address caller);

    /// @notice The address registry used to register deployed hooks.
    /// @return The address registry contract.
    function ADDRESS_REGISTRY() external view returns (IJBAddressRegistry);

    /// @notice The implementation contract used as the base for clones.
    /// @return The hook implementation contract.
    function HOOK() external view returns (JBUniswapV4LPSplitHook);

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
        returns (IJBUniswapV4LPSplitHook hook);
}
