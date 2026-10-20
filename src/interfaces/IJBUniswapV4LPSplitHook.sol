// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice Manages a two-stage Uniswap V4 pool deployment process for Juicebox projects, routing LP fees back to the
/// project.
interface IJBUniswapV4LPSplitHook {
    /// @notice Emitted when fee tokens are claimed for a beneficiary.
    /// @param projectId The Juicebox project ID.
    /// @param beneficiary The address receiving the claimed tokens.
    /// @param amount The amount of tokens claimed.
    /// @param caller The address that claimed the tokens.
    event FeeTokensClaimed(uint256 indexed projectId, address indexed beneficiary, uint256 amount, address caller);

    /// @notice Emitted when a recycle after deployment re-mints the project's ask and bid positions.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @param askTokenId The ask position's token ID (zero if no ask range was available).
    /// @param bidTokenId The bid position's token ID (zero if no bid range or terminal tokens were available).
    /// @param caller The address that triggered the recycle.
    event LiquidityAdded(
        uint256 indexed projectId, address indexed terminalToken, uint256 askTokenId, uint256 bidTokenId, address caller
    );

    /// @notice Emitted when a best-effort inline automation attempt (pool deployment or liquidity addition) fails
    /// after a successful intake. The accepted inventory remains accounted and retryable through the permissionless
    /// `deployPool`/`addLiquidity` entry points.
    /// @param projectId The Juicebox project ID.
    /// @param reasonSelector The first four bytes of the attempt's revert data (zero when none was returned).
    /// @param caller The address that triggered the distribution.
    event LiquidityAutomationFailed(uint256 indexed projectId, bytes4 reasonSelector, address caller);

    /// @notice Emitted when LP fees are routed back to the project.
    /// @param projectId The Juicebox project ID.
    /// @param token The token that was routed (the project token or the terminal token).
    /// @param totalAmount The total amount of fees collected.
    /// @param feeAmount The amount sent to the fee project.
    /// @param remainingAmount The amount sent to the original project.
    /// @param feeTokensMinted The number of fee project tokens minted.
    /// @param caller The address that routed the LP fees.
    event LPFeesRouted(
        uint256 indexed projectId,
        address indexed token,
        uint256 totalAmount,
        uint256 feeAmount,
        uint256 remainingAmount,
        uint256 feeTokensMinted,
        address caller
    );

    /// @notice Emitted when a payout split from one of the project's terminals is accepted into the bid's ledger.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token paid out (the deployed pool's).
    /// @param amount The amount received and ledgered.
    /// @param caller The terminal that sent the payout.
    event PayoutAccepted(uint256 indexed projectId, address indexed terminalToken, uint256 amount, address caller);

    /// @notice Emitted when a project transitions from Stage 1 to Stage 2 by deploying a pool.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @param poolId The Uniswap V4 pool ID.
    /// @param caller The address that deployed the pool.
    event ProjectDeployed(
        uint256 indexed projectId, address indexed terminalToken, bytes32 indexed poolId, address caller
    );

    /// @notice The token ID of a project's ask position (project tokens from the spot out to the issuance ceiling).
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @return tokenId The ask position's token ID, or zero if there is none.
    function askTokenIdOf(uint256 projectId, address terminalToken) external view returns (uint256 tokenId);

    /// @notice The token ID of a project's bid position (terminal tokens from the spot back to the cash-out floor).
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    /// @return tokenId The bid position's token ID, or zero if there is none.
    function bidTokenIdOf(uint256 projectId, address terminalToken) external view returns (uint256 tokenId);

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

    /// @notice Recycle the project's positions, folding in any accumulated reserved tokens: collect fees, burn the ask
    /// and bid, and re-mint both single-sided around the live spot. Permissionless at any time, gated by the
    /// oracle-TWAP deviation guard.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token paired with the project token in the deployed pool.
    function addLiquidity(uint256 projectId, address terminalToken) external;

    /// @notice Claim fee tokens for a beneficiary.
    /// @param projectId The Juicebox project ID.
    /// @param beneficiary The beneficiary address to send claimed tokens to.
    function claimFeeTokensFor(uint256 projectId, address beneficiary) external;

    /// @notice Collect LP fees from the ask and bid positions and route them into the project's ledgers.
    /// @param projectId The Juicebox project ID.
    /// @param terminalToken The terminal token address.
    // forge-lint: disable-next-line(mixed-case-function)
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external;

    /// @notice Deploy a Uniswap V4 pool using accumulated project tokens.
    /// @dev Auto-selects the terminal token with the highest ETH-denominated value across all terminals. Mints the
    /// first ask from the accumulated project tokens. Permissionless: anyone may seed the pool.
    /// @param projectId The Juicebox project ID.
    function deployPool(uint256 projectId) external;

    /// @notice Initialize per-instance config + chain-specific Uniswap V4 addresses on a clone. Callable once.
    /// @param initialFeeProjectId Project ID to receive LP fees.
    /// @param initialFeePercent Percentage of LP fees to route to fee project, out of `BPS`.
    /// @param newPoolManager The Uniswap V4 PoolManager on this chain.
    /// @param newPositionManager The Uniswap V4 PositionManager on this chain.
    /// @param newOracleHook The Uniswap V4 oracle hook deployed against `newPoolManager` on this chain.
    /// @param newBuybackHook The buyback-hook registry to configure for this clone (may be zero).
    function initialize(
        uint256 initialFeeProjectId,
        uint256 initialFeePercent,
        IPoolManager newPoolManager,
        IPositionManager newPositionManager,
        IHooks newOracleHook,
        IJBBuybackHookRegistry newBuybackHook
    )
        external;
}
