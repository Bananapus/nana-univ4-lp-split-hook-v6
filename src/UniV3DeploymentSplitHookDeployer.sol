// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LibClone} from "solady/src/utils/LibClone.sol";

import {UniV3DeploymentSplitHook} from "./UniV3DeploymentSplitHook.sol";
import {IUniV3DeploymentSplitHook} from "./interfaces/IUniV3DeploymentSplitHook.sol";
import {IUniV3DeploymentSplitHookDeployer} from "./interfaces/IUniV3DeploymentSplitHookDeployer.sol";

/// @notice Deploys `UniV3DeploymentSplitHook` clones with shared infrastructure baked into the implementation.
/// @dev Anyone can deploy a hook by providing only `feeProjectId` and `feePercent`.
/// @dev Supports deterministic deployment via CREATE2 when a non-zero salt is provided.
contract UniV3DeploymentSplitHookDeployer is IUniV3DeploymentSplitHookDeployer {
    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The hook implementation that all clones delegate to.
    UniV3DeploymentSplitHook public immutable override HOOK;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param hook The hook implementation contract.
    constructor(UniV3DeploymentSplitHook hook) {
        HOOK = hook;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploy a new `UniV3DeploymentSplitHook` clone with the caller as its initial owner.
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
        returns (IUniV3DeploymentSplitHook hook)
    {
        // Clone with CREATE or CREATE2 depending on whether a salt was provided.
        hook = IUniV3DeploymentSplitHook(
            salt == bytes32(0)
                ? LibClone.clone(address(HOOK))
                : LibClone.cloneDeterministic({
                    implementation: address(HOOK),
                    salt: keccak256(abi.encode(msg.sender, salt))
                })
        );

        IUniV3DeploymentSplitHook(address(hook)).initialize(msg.sender, feeProjectId, feePercent);

        emit HookDeployed(feeProjectId, feePercent, hook, msg.sender);
    }
}
