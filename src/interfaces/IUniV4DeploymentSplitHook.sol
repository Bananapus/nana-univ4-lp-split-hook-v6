// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Manages a two-stage Uniswap V4 pool deployment process for Juicebox projects, routing LP fees back to the
/// project.
interface IUniV4DeploymentSplitHook {
    /// @notice Emitted when fee tokens are claimed for a beneficiary.
    /// @param projectId The Juicebox project ID.
    /// @param beneficiary The address receiving the claimed tokens.
    /// @param amount The amount of tokens claimed.
    event FeeTokensClaimed(uint256 indexed projectId, address indexed beneficiary, uint256 amount);

    /// @notice Emitted when LP fees are routed back to the project.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @param totalAmount The total amount of fees collected.
    /// @param feeAmount The amount sent to the fee project.
    /// @param remainingAmount The amount sent to the original project.
    /// @param feeTokensMinted The number of fee project tokens minted.
    event LPFeesRouted(
        uint256 indexed projectId,
        address indexed terminalToken,
        uint256 totalAmount,
        uint256 feeAmount,
        uint256 remainingAmount,
        uint256 feeTokensMinted
    );

    /// @notice Emitted when a project transitions from Stage 1 to Stage 2 by deploying a pool.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @param poolId The Uniswap V4 pool ID.
    event ProjectDeployed(uint256 indexed projectId, address indexed terminalToken, bytes32 indexed poolId);

    /// @notice Emitted when tokens are burned in Stage 2.
    /// @param projectId The Juicebox project ID.
    /// @param token The token address that was burned.
    /// @param amount The amount of tokens burned.
    event TokensBurned(uint256 indexed projectId, address indexed token, uint256 amount);

    /// @notice Check if a pool has been deployed for a project/terminal token pair.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @return deployed True if pool exists.
    function isPoolDeployed(uint256 projectId, address terminalToken) external view returns (bool deployed);

    /// @notice Get the PoolKey for a deployed project/terminal token pair.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @return key The Uniswap V4 PoolKey.
    function poolKeyOf(uint256 projectId, address terminalToken) external view returns (PoolKey memory key);

    /// @notice Claim fee tokens for a beneficiary.
    /// @param projectId The Juicebox project ID.
    /// @param beneficiary The beneficiary address to send claimed tokens to.
    function claimFeeTokensFor(uint256 projectId, address beneficiary) external;

    /// @notice Collect LP fees and route them back to the project.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external;

    /// @notice Deploy a Uniswap V4 pool using accumulated project tokens.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @param amount0Min Minimum amount of token0 to add (slippage protection, defaults to 0).
    /// @param amount1Min Minimum amount of token1 to add (slippage protection, defaults to 0).
    /// @param minCashOutReturn Minimum terminal tokens from cash-out (slippage protection, 0 = auto 1% tolerance).
    function deployPool(
        uint256 projectId,
        address terminalToken,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minCashOutReturn
    )
        external;

    /// @notice Initialize per-instance config on a clone.
    /// @param feeProjectId Project ID to receive LP fees.
    /// @param feePercent Percentage of LP fees to route to fee project (in basis points).
    function initialize(uint256 feeProjectId, uint256 feePercent) external;
}
