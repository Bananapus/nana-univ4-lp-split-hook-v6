// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { UniV3DeploymentSplitHook } from "./UniV3DeploymentSplitHook.sol";
import { IUniV3DeploymentSplitHook } from "./interfaces/IUniV3DeploymentSplitHook.sol";
import { IUniV3DeploymentSplitHookDeployer } from "./interfaces/IUniV3DeploymentSplitHookDeployer.sol";

/// @notice Deploys `UniV3DeploymentSplitHook` instances with shared infrastructure baked in.
/// @dev Anyone can deploy a hook by providing only `feeProjectId` and `feePercent`.
/// @dev Supports deterministic deployment via CREATE2 when a non-zero salt is provided.
contract UniV3DeploymentSplitHookDeployer is IUniV3DeploymentSplitHookDeployer {
    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The JBDirectory shared by all deployed hooks.
    address public immutable override DIRECTORY;

    /// @notice The JBTokens shared by all deployed hooks.
    address public immutable override TOKENS;

    /// @notice The Uniswap V3 factory shared by all deployed hooks.
    address public immutable override UNISWAP_V3_FACTORY;

    /// @notice The Uniswap V3 NonfungiblePositionManager shared by all deployed hooks.
    address public immutable override UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER;

    /// @notice The REVDeployer shared by all deployed hooks.
    address public immutable override REV_DEPLOYER;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The JBDirectory address.
    /// @param tokens The JBTokens address.
    /// @param uniswapV3Factory The Uniswap V3 factory address.
    /// @param uniswapV3NonfungiblePositionManager The Uniswap V3 NonfungiblePositionManager address.
    /// @param revDeployer The REVDeployer address.
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

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploy a new `UniV3DeploymentSplitHook` with the caller as its initial owner.
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
        // Deploy with CREATE or CREATE2 depending on whether a salt was provided.
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
            // Scope the salt to the caller to prevent front-running.
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
