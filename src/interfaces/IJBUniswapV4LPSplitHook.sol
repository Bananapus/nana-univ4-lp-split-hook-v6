// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Manages a two-stage Uniswap V4 pool deployment process for Juicebox projects, routing LP fees back to the
/// project.
interface IJBUniswapV4LPSplitHook {
    /// @notice Emitted when fee tokens are claimed for a beneficiary.
    /// @param projectId The Juicebox project ID.
    /// @param beneficiary The address receiving the claimed tokens.
    /// @param amount The amount of tokens claimed.
    /// @param caller The address that claimed the tokens.
    event FeeTokensClaimed(uint256 indexed projectId, address indexed beneficiary, uint256 amount, address caller);

    /// @notice Emitted when accumulated reserved tokens are converted into additional liquidity after deployment.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @param tokenId The LP position token ID that received the liquidity.
    /// @param isNewPosition True if a new (re-ranged) position was minted; false if the active position was topped up.
    /// @param caller The address that added the liquidity.
    event LiquidityAdded(
        uint256 indexed projectId,
        address indexed terminalToken,
        uint256 indexed tokenId,
        bool isNewPosition,
        address caller
    );

    /// @notice Emitted when LP fees are routed back to the project.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @param totalAmount The total amount of fees collected.
    /// @param feeAmount The amount sent to the fee project.
    /// @param remainingAmount The amount sent to the original project.
    /// @param feeTokensMinted The number of fee project tokens minted.
    /// @param caller The address that routed the LP fees.
    event LPFeesRouted(
        uint256 indexed projectId,
        address indexed terminalToken,
        uint256 totalAmount,
        uint256 feeAmount,
        uint256 remainingAmount,
        uint256 feeTokensMinted,
        address caller
    );

    /// @notice Emitted when a project transitions from Stage 1 to Stage 2 by deploying a pool.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @param poolId The Uniswap V4 pool ID.
    /// @param caller The address that deployed the pool.
    event ProjectDeployed(
        uint256 indexed projectId, address indexed terminalToken, bytes32 indexed poolId, address caller
    );

    /// @notice Check if a pool has been deployed for a project/terminal token pair.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @return deployed True if pool exists.
    function isPoolDeployed(uint256 projectId, address terminalToken) external view returns (bool deployed);

    /// @notice The Permit2 utility.
    // forge-lint: disable-next-line(mixed-case-function)
    function PERMIT2() external view returns (IAllowanceTransfer);

    /// @notice Get the PoolKey for a deployed project/terminal token pair.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @return key The Uniswap V4 PoolKey.
    function poolKeyOf(uint256 projectId, address terminalToken) external view returns (PoolKey memory key);

    /// @notice Convert the project's post-deployment accumulated reserved tokens into additional liquidity. Tops up the
    /// active position, or — once the live corridor has drifted — burns the stale position and re-mints a single
    /// fresh
    /// position at the current corridor. Permissionless once the ruleset weight has decayed 10x from accumulation;
    /// otherwise requires `SET_BUYBACK_POOL` from the project owner.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token paired with the project token in the deployed pool.
    /// @param minCashOutReturn Minimum terminal tokens from the funding cash-out (slippage protection, 0 = auto 3%).
    function addLiquidity(uint256 projectId, address terminalToken, uint256 minCashOutReturn) external;

    /// @notice Claim fee tokens for a beneficiary.
    /// @param projectId The Juicebox project ID.
    /// @param beneficiary The beneficiary address to send claimed tokens to.
    function claimFeeTokensFor(uint256 projectId, address beneficiary) external;

    /// @notice Collect LP fees and route them back to the project.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    // forge-lint: disable-next-line(mixed-case-function)
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external;

    /// @notice Deploy a Uniswap V4 pool using accumulated project tokens.
    /// @dev Auto-selects the terminal token with the highest ETH-denominated value across all terminals.
    /// @param projectId The Juicebox project ID.
    /// @param minCashOutReturn Minimum terminal tokens from cash-out (slippage protection, 0 = auto 3% tolerance).
    function deployPool(uint256 projectId, uint256 minCashOutReturn) external;

    /// @notice Initialize per-instance config + chain-specific Uniswap V4 addresses on a clone. Callable once.
    /// @param initialFeeProjectId Project ID to receive LP fees.
    /// @param initialFeePercent Percentage of LP fees to route to fee project, out of `BPS`.
    /// @param newPoolManager The Uniswap V4 PoolManager on this chain.
    /// @param newPositionManager The Uniswap V4 PositionManager on this chain.
    /// @param newOracleHook The Uniswap V4 oracle hook deployed against `newPoolManager` on this chain.
    function initialize(
        uint256 initialFeeProjectId,
        uint256 initialFeePercent,
        IPoolManager newPoolManager,
        IPositionManager newPositionManager,
        IHooks newOracleHook
    )
        external;
}
