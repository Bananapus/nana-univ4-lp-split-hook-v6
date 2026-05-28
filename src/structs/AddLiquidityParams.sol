// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Bundled arguments for `JBUniswapV4LPSplitHook._executeAddToPosition`, shared by the deploy and
/// `addLiquidity` paths.
/// @dev Bundled into a struct so the shared mint/increase internal stays within the Yul stack budget under `via_ir`.
/// @custom:member projectId The ID of the project.
/// @custom:member projectToken The project's ERC-20 token address.
/// @custom:member terminalToken The terminal token paired with the project token.
/// @custom:member key The pool key identifying the Uniswap V4 pool.
/// @custom:member tickLower The lower tick of the position to add into.
/// @custom:member tickUpper The upper tick of the position to add into.
/// @custom:member projectTokenBalance The accumulated project-token balance to deploy as liquidity.
/// @custom:member minCashOutReturn Minimum terminal tokens to accept from the funding cash-out (slippage protection).
/// @custom:member forceDirectCashOut Whether to force the funding cash-out directly through the bonding curve.
/// @custom:member isNewPosition Whether to mint a new position (true) or increase the existing one (false).
/// @custom:member existingTokenId The position token ID to increase when `isNewPosition` is false.
/// @custom:member controller The project's controller address (pre-fetched to avoid redundant lookups).
/// @custom:member ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
struct AddLiquidityParams {
    uint256 projectId;
    address projectToken;
    address terminalToken;
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
    uint256 projectTokenBalance;
    uint256 minCashOutReturn;
    bool forceDirectCashOut;
    bool isNewPosition;
    uint256 existingTokenId;
    address controller;
    JBRuleset ruleset;
}
