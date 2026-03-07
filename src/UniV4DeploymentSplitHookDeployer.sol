// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LibClone} from "solady/src/utils/LibClone.sol";

import {UniV4DeploymentSplitHook} from "./UniV4DeploymentSplitHook.sol";
import {IUniV4DeploymentSplitHook} from "./interfaces/IUniV4DeploymentSplitHook.sol";
import {IUniV4DeploymentSplitHookDeployer} from "./interfaces/IUniV4DeploymentSplitHookDeployer.sol";

/// @notice Deploys `UniV4DeploymentSplitHook` clones with shared infrastructure baked into the implementation.
/// @dev Anyone can deploy a hook by providing only `feeProjectId` and `feePercent`.
/// @dev Supports deterministic deployment via CREATE2 when a non-zero salt is provided.
contract UniV4DeploymentSplitHookDeployer is IUniV4DeploymentSplitHookDeployer {
    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The hook implementation that all clones delegate to.
    UniV4DeploymentSplitHook public immutable override HOOK;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param hook The hook implementation contract.
    constructor(UniV4DeploymentSplitHook hook) {
        HOOK = hook;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploy a new `UniV4DeploymentSplitHook` clone with the caller as its initial owner.
    /// @param feeProjectId The Juicebox project ID that receives a share of LP fees.
    /// @param feePercent The percentage of LP fees routed to the fee project (in basis points, e.g. 3800 = 38%).
    /// @param salt An optional salt for deterministic CREATE2 deployment. Pass `bytes32(0)` for a plain CREATE.
    /// @return hook The newly deployed hook.
    function deployHookFor(
        uint256 feeProjectId,
        uint256 feePercent,
        bytes32 salt
    )
        external
        override
        returns (IUniV4DeploymentSplitHook hook)
    {
        hook = IUniV4DeploymentSplitHook(
            salt == bytes32(0)
                ? LibClone.clone(address(HOOK))
                : LibClone.cloneDeterministic({
                    implementation: address(HOOK), salt: keccak256(abi.encode(msg.sender, salt))
                })
        );

        IUniV4DeploymentSplitHook(address(hook)).initialize(msg.sender, feeProjectId, feePercent);

        emit HookDeployed(feeProjectId, feePercent, hook, msg.sender);
    }
}
