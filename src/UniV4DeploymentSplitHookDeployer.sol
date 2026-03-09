// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";

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

    /// @notice A registry which stores references to contracts and their deployers.
    IJBAddressRegistry public immutable override ADDRESS_REGISTRY;

    /// @notice The hook implementation that all clones delegate to.
    UniV4DeploymentSplitHook public immutable override HOOK;

    //*********************************************************************//
    // ----------------------- internal properties ----------------------- //
    //*********************************************************************//

    /// @notice This contract's current nonce, used for the Juicebox address registry.
    uint256 internal _nonce;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param hook The hook implementation contract.
    /// @param addressRegistry A registry which stores references to contracts and their deployers.
    constructor(UniV4DeploymentSplitHook hook, IJBAddressRegistry addressRegistry) {
        HOOK = hook;
        ADDRESS_REGISTRY = addressRegistry;
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

        IUniV4DeploymentSplitHook(address(hook)).initialize(feeProjectId, feePercent);

        emit HookDeployed(feeProjectId, feePercent, hook, msg.sender);

        // Increment the nonce.
        ++_nonce;

        // Add the hook to the address registry. This contract's nonce starts at 1.
        salt == bytes32(0)
            ? ADDRESS_REGISTRY.registerAddress({deployer: address(this), nonce: _nonce})
            : ADDRESS_REGISTRY.registerAddress({
                deployer: address(this),
                salt: keccak256(abi.encode(msg.sender, salt)),
                bytecode: LibClone.initCode(address(HOOK))
            });
    }
}
