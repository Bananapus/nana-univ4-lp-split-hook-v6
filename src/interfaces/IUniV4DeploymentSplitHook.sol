// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title IUniV4DeploymentSplitHook
 * @notice JuiceBox v4 Split Hook contract that manages a two-stage deployment process:
 * Stage 1: Accumulate project tokens without deploying Uniswap V4 pool
 * Stage 2: Deploy pool with accumulated tokens (triggered manually by project owner or operator)
 * After deployment: Route LP fees back to project, burn newly received project tokens
 */
interface IUniV4DeploymentSplitHook {

    /// @dev Emitted when a project transitions from Stage 1 to Stage 2
    event ProjectDeployed(uint256 indexed projectId, address indexed terminalToken, PoolId indexed poolId);

    /// @dev Emitted when LP fees are routed back to the project
    /// @param feeAmount Amount sent to fee project
    /// @param remainingAmount Amount sent to original project
    /// @param feeTokensMinted Number of fee project tokens minted
    event LPFeesRouted(
        uint256 indexed projectId,
        address indexed terminalToken,
        uint256 totalAmount,
        uint256 feeAmount,
        uint256 remainingAmount,
        uint256 feeTokensMinted
    );

    /// @dev Emitted when tokens are burned in Stage 2
    event TokensBurned(uint256 indexed projectId, address indexed token, uint256 amount);

    /// @dev Emitted when fee tokens are claimed by a revnet operator
    event FeeTokensClaimed(uint256 indexed projectId, address indexed beneficiary, uint256 amount);

    /**
     * @notice Check if a pool has been deployed for a project/terminal token pair
     * @param _projectId The Juicebox project ID
     * @param _terminalToken The terminal token address
     * @return deployed True if pool exists
     */
    function isPoolDeployed(uint256 _projectId, address _terminalToken) external view returns (bool deployed);

    /**
     * @notice Get the PoolKey for a project/terminal token pair
     * @param _projectId The Juicebox project ID
     * @param _terminalToken The terminal token address
     * @return poolKey The Uniswap V4 PoolKey
     */
    function poolKeyOf(uint256 _projectId, address _terminalToken) external view returns (PoolKey memory poolKey);

    /**
     * @notice Deploy a Uniswap V4 pool using accumulated project tokens
     * @dev Only callable by the project owner or an operator with SET_BUYBACK_POOL permission
     * @param _projectId The Juicebox project ID
     * @param _terminalToken The terminal token address
     * @param _amount0Min Minimum amount of token0 to add (slippage protection, defaults to 0)
     * @param _amount1Min Minimum amount of token1 to add (slippage protection, defaults to 0)
     * @param _minCashOutReturn Minimum terminal tokens from cash-out (slippage protection, 0 = auto 1% tolerance)
     */
    function deployPool(
        uint256 _projectId,
        address _terminalToken,
        uint256 _amount0Min,
        uint256 _amount1Min,
        uint256 _minCashOutReturn
    ) external;

    /**
     * @notice Collect LP fees and route them back to the project
     * @param _projectId The Juicebox project ID
     * @param _terminalToken The terminal token address
     */
    function collectAndRouteLPFees(uint256 _projectId, address _terminalToken) external;

    /**
     * @notice Claim fee tokens for a beneficiary (must be the project's revnet operator)
     * @param _projectId The Juicebox project ID
     * @param _beneficiary The beneficiary address to claim tokens for
     */
    function claimFeeTokensFor(uint256 _projectId, address _beneficiary) external;
}
