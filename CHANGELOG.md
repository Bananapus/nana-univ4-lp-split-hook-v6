# V5 to V6 Changelog

## 1.5.0 — Two single-sided positions, recycled on every distribution

- Each project holds at most **two single-sided positions**: an ask of project tokens from just past the spot to the issuance ceiling (never below the cash-out floor), tracked in `askTokenIdOf`, and a bid of terminal tokens from just past the spot to the cash-out floor (never above the issuance ceiling), tracked in `bidTokenIdOf`. Both sit on opposite sides of a gap around the spot, so every mint is single-sided, and both are anchored to the validated 30-minute TWAP: the ask never sells project tokens below the TWAP price and the bid never buys them above it, so recycling at a manipulated in-band spot only widens the gap.
- Every recycle (inline on each reserved-token distribution, or the permissionless `deployPool`/`addLiquidity`) routes both positions' fees, burns both, and re-mints the ask from every project token held and the bid from every terminal token held. Whatever trading converted is recycled to the side it belongs on.
- Removed `rebalanceLiquidity` and the adaptive two-sided solver, with the corridor-drift guard, `activeTickLowerOf`/`activeTickUpperOf`, `rangedCorridorLowerOf`/`rangedCorridorUpperOf`, `PermissionlessRebalanced`, `DriftBelowThreshold`, `AccumulationBelowThreshold`, `ZeroLiquidity`, `InsufficientLiquidity`, and `TerminalNotFound`. `addLiquidity` recycles at any time, with or without new tokens, under the TWAP guard. `tokenIdOf` is replaced by `askTokenIdOf` and `bidTokenIdOf`; `LiquidityAdded` carries both ids.
- Reserved-token intake is durable: `processSplitWith` accounts the allocation (ERC-20 or credits) first, then makes a best-effort, gas-bounded deploy or recycle attempt whose failure is reported through `LiquidityAutomationFailed` and retryable through `deployPool`/`addLiquidity`. The attempt starts only with at least 1,500,000 gas left (a full recycle with fee routing and the credit claim measured ~857k to ~1.39M across the mainnet fork suite; an attempt that runs short is reported like any failure).
- LP fees now accrue to the project: terminal side via addToBalance raises surplus, project side is burned, so both raise the cash-out floor. After the unchanged best-effort fee-project cut, the terminal-token remainder is added to the project's balance in its primary terminal for that token (`addToBalanceOf`, `shouldReturnHeldFees: false`) and the project-token remainder is burned through the controller (`burnTokensOf`). Fees are routed before the corridor is priced, so a recycle mints around the raised floor; `collectAndRouteLPFees` raises the floor without moving the positions. Either route is best effort: when it reverts (no primary terminal, a rejecting terminal, a reverting controller, an inexact burn), that side's remainder folds into its ledger as before (`accumulatedTerminalTokens` or `accumulatedProjectTokens`) and becomes liquidity at the next recycle, without blocking the collection or the other side. Core burns credits first, so before burning the hook claims every credit it holds for the project (accepted credits and credits sent from outside, never fee-credit claims it owes) into the ERC-20 and the ask ledger, the same claim a recycle runs; the burn is forgiven only while owed fee credits remain. `_claimHookCreditsFor` (used by recycles too) claims every non-owed credit rather than only `accumulatedProjectCredits`. Reserved tokens are still never burned. The `payFeeProjectCut` self-call is replaced by `sendToTerminal(terminal, projectId, token, amount, shouldPay)`, which pays the fee-project cut (`shouldPay: true`) or adds the remainder to the project's balance (`shouldPay: false`); the new `burnFeeRemainder(projectId, projectToken, count)` self-call reverts `JBUniswapV4LPSplitHook_FeeBurnNotExact` unless exactly `count` of the hook's ERC-20 is burned and its credit balance is unchanged. Both are callable only by the hook itself.
- The hook also works as a payout split, in native ETH or an ERC-20, to fund the bid. `processSplitWith` treats any group other than 1 as a payout, accepted only after deployment, in the deployed pool's terminal token, from a terminal of the project, under the token's group (`uint256(uint160(token))`); native payouts must carry exactly their amount as value, and ERC-20 payouts carry none and are pulled with `safeTransferFrom`. The received amount is credited to `accumulatedTerminalTokens`, `PayoutAccepted(projectId, terminalToken, amount, caller)` is emitted, and the inline automation attempt runs without the reserved-token `_MIN_ADD_ACCUMULATION` threshold (which now gates only reserved-token distributions). Any rejection reverts, and Core returns the whole payout to the project's balance. `JBUniswapV4LPSplitHook_InvalidSplitGroup(groupId, token)` replaces `JBUniswapV4LPSplitHook_TerminalTokensNotAllowed`.
- Each mint is capped at the pool's remaining per-tick liquidity at both range bounds (`JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity`): inventory a range near the tick limits cannot hold stays in the ledgers for a later recycle instead of reverting it.
- The corridor is empty when the cash-out value per token reaches the issuance price (compared on exact prices, so an inversion smaller than one tick counts) or when no aligned spacing fits between the bounds: `calculateTickBounds` returns `(0, 0)` instead of sorting the bounds, a recycle retires both positions and holds the tokens, and `deployPool` reverts `EmptyCorridor` before seeding or accepting a pool price (`computeInitialSqrtPrice` returns 0). The +/-1-spacing fallback around the issuance price, which could quote asks below the cash-out value, is removed.
- Both corridor bounds round inward against their exact prices: the lower bound to the first aligned tick at or above its price, the upper bound to the last aligned tick at or below it.
- Corridor prices are encoded conservatively: the floor is an upper bound on the per-token value of a 1-token cash-out preview (the preview plus two, never zero, so a preview that rounds to 0 still sets a floor), the ceiling is the net issuance rate bounded from above (the gross rate plus one, times the non-reserved share, rounded up; issuance counts as zero only with zero weight or a 100% reserved rate), and each is encoded toward the safe side (the floor toward a higher project price, the ceiling toward a lower one). The encoder scales before taking the square root, so small rates keep their precision (a rate of 2 no longer encodes like a rate of 1). With a zero cash-out preview, the floor side of the zero-surplus and full-range corridors stops at the cash-out bound, and the corridor is empty if that closes it. `getCashOutRateSqrtPriceX96` no longer returns a MIN/MAX extreme for a zero rate.
- The cash-out floor sums surplus across all of the project's local terminals through `JBSurplus.currentSurplusOf`, the way settlement does, instead of previewing only the primary terminal's store, so surplus held by terminals on other stores counts. The surplus and reclaim previews are no longer wrapped in try/catch: a failing read reverts the bounds (a recycle reverts; inline automation keeps the intake) rather than reading as a zero floor. Scaling a sub-token preview to a per-`1e18` rate saturates instead of overflowing. Under a cash-out tax, larger burns return more per token than the floor, because the curve is size dependent.
- Breaking library ABI: `JBUniswapV4LPSplitHookMath.getSqrtPriceX96ForCurrentJuiceboxPrice`, the unused `JBUniswapV4LPSplitHookMath.computeOptimalCashOutAmount`, and the `JBUniswapV4LPSplitHookMath_InvalidTickBounds` error are removed, and the hook error `JBUniswapV4LPSplitHook_InvertedCorridor` is renamed `JBUniswapV4LPSplitHook_EmptyCorridor`.
- Ships at fresh library, hook, and deployer addresses. Existing 1.4.0 clones are unchanged; a project adopts this version by routing its reserved split to a new clone.

## 1.4.0 — Single-sided, cash-out-free, permissionless redesign

- The hook seeds a project's Uniswap V4 buyback pool with **single-sided liquidity**: at seed it is asks-only, offering the accumulated project tokens from the live spot up to the issuance ceiling. It maintains **exactly one adaptive position per `(projectId, terminalToken)`** via consolidate-and-re-mint — route accrued LP fees, burn the prior V4 position, and fold recovered principal, the accumulation ledger, and swept credits into one fresh position.
- The hook **never performs a cash-out**: it never calls `cashOutTokensOf`, never touches project surplus, and never burns project tokens. The corridor floor is still placed at the project's cash-out (redemption) price, but the price is used only to position the floor tick. Any terminal-token (bid) side of a re-minted position is funded solely from the terminal tokens the hook recovers by burning its own prior V4 position plus this project's own accumulated terminal-token fee ledger. The only Uniswap V4 position the hook burns is its own.
- The lifecycle is **fully permissionless**: `deployPool`, `addLiquidity`, `rebalanceLiquidity`, and `collectAndRouteLPFees` are callable by anyone, each `nonReentrant`. `deployPool` and `addLiquidity` are bounded by an economic gate (the mint reverts once spot reaches the issuance ceiling); `addLiquidity`, `rebalanceLiquidity`, and already-initialized-pool `deployPool` runs are bounded by a spot-vs-30-minute-TWAP guard, and `rebalanceLiquidity` additionally by a corridor-drift threshold. Only `claimFeeTokensFor` remains gated to the project owner or `SET_BUYBACK_POOL` delegate.
- `deployPool` auto-selects the terminal token by highest ETH-denominated value across the project's terminals and permanently locks it.
- LP-fee collection takes a best-effort `feeProjectId` protocol cut symmetrically on both the terminal-token and project-token sides: each side is paid to the fee project's primary terminal for that token when one exists, with a missing terminal or a reverting payment forgiven so collection never fails on the fee project's account. Every non-cut remainder becomes the originating project's own protocol-owned liquidity — the project-token remainder folds into `accumulatedProjectTokens`, and the terminal-token remainder folds into the per-project `accumulatedTerminalTokens[projectId][terminalToken]` ledger — rather than into the project's terminal balance, so LP fees never raise treasury surplus.
- Security-hardening pass: removed the funding-cash-out path and its `minCashOutReturn` parameter, deleted the `AddLiquidityParams` struct, and folded burn-slippage protection into contract-derived floors (callers no longer supply slippage). See `RISKS.md` §7.5 (fee-project cut is best-effort on both sides) and §7.6 (terminal auto-selection is influenceable — accepted low severity).

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. The closest V5 source comparison is `nana-lp-split-hook-v5` in `../../v5/evm`; the current repo is the V6 Uniswap V4 LP split hook package.

## Current V6 Surface

- `JBUniswapV4LPSplitHook`
- `JBUniswapV4LPSplitHookDeployer`
- `IJBUniswapV4LPSplitHook`
- `IJBUniswapV4LPSplitHookDeployer`
- `JBUniswapV4LPSplitHookMath`

## Summary

- The V5 comparison package was a Uniswap V3 deployment split hook. V6 is a Uniswap V4 pool-manager and position-manager design.
- V6 deploys hook clones through a deployer and initializes per-clone state, rather than treating one hook as a static V3 deployment helper.
- Post-deployment reserved-token inflows are accumulated and can be converted into more protocol-owned liquidity through `addLiquidity(...)`.
- V6 removes the V5 post-deploy burn event/path from this hook; burning reserved tokens is a split-routing decision outside this hook. The hook burns only the project-token side of collected LP fees.
- LP fee routing, fee-token claims, pool deployment, and liquidity growth have V6-specific events and errors.

## ABI, Event, and Error Changes

- Replaced interface:
  - `IUniV3DeploymentSplitHook` -> `IJBUniswapV4LPSplitHook`
- Removed V5 functions/events:
  - V5 `deployPool(projectId, terminalToken, amount0Min, amount1Min)` shape
  - `isAccumulationStage(...)`
  - `TokensBurned`
- Added or changed functions:
  - `initialize(...)`
  - `deployPool(uint256)`
  - `addLiquidity(uint256,address)`
  - `poolKeyOf(uint256,address)`
  - `isPoolDeployed(uint256,address)`
  - deployer `deployHookFor(...)`
  - deployer `setChainSpecificConstants(...)`
- Added or changed events:
  - `HookDeployed`
  - `ProjectDeployed` carries a V4 pool ID.
  - `LiquidityAdded`
  - `LPFeesRouted`
  - `FeeTokensClaimed`
  - `PayoutAccepted`
- Added or migration-sensitive errors include:
  - V4 price-deviation / TWAP availability errors
  - deployer one-shot configuration errors
  - pool-deployment and liquidity-range validation errors

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: `nana-lp-split-hook-v5`.
- Own-source ABI artifacts compared: V6 `6`, V5 `2`.
- Contract/interface coverage: `6` added, `2` removed, `0` shared names with ABI changes, `0` shared names ABI-identical.
- Shared-name ABI item deltas: `0` added, `0` removed, `0` modified.

Added V6 ABI artifacts:
- `IJBUniswapV4LPSplitHook` from `src/interfaces/IJBUniswapV4LPSplitHook.sol`: `10` functions, `6` events, `0` errors.
- `IJBUniswapV4LPSplitHookDeployer` from `src/interfaces/IJBUniswapV4LPSplitHookDeployer.sol`: `7` functions, `1` events, `0` errors.
- `JBLPSplitHookHelpers` from `src/libraries/JBLPSplitHookHelpers.sol`: `0` functions, `0` events, `0` errors.
- `JBUniswapV4LPSplitHook` from `src/JBUniswapV4LPSplitHook.sol`: `39` functions, `6` events, `28` errors.
- `JBUniswapV4LPSplitHookDeployer` from `src/JBUniswapV4LPSplitHookDeployer.sol`: `7` functions, `1` events, `3` errors.
- `JBUniswapV4LPSplitHookMath` from `src/libraries/JBUniswapV4LPSplitHookMath.sol`: `9` functions, `0` events, `2` errors.

Removed V5 ABI artifacts:
- `IUniV3DeploymentSplitHook` from `src/interfaces/IUniV3DeploymentSplitHook.sol`: `4` functions, `4` events, `0` errors.
- `UniV3DeploymentSplitHook` from `src/UniV3DeploymentSplitHook.sol`: `26` functions, `5` events, `16` errors.

Generated event/error name deltas:
- Event names added:
  - `FeeTokensClaimed`, `HookDeployed`, `LPFeesRouted`, `LiquidityAdded`, `LiquidityAutomationFailed`, `PayoutAccepted`, `ProjectDeployed`.
- Event names removed or replaced:
  - `FeeTokensClaimed`, `LPFeesRouted`, `OwnershipTransferred`, `ProjectDeployed`, `TokensBurned`.
- Error names added:
  - `JBPermissioned_Unauthorized`, `JBUniswapV4LPSplitHookDeployer_AlreadyConfigured`, `JBUniswapV4LPSplitHookDeployer_NotConfigured`, `JBUniswapV4LPSplitHookDeployer_Unauthorized`, `JBUniswapV4LPSplitHookMath_NoTerminalTokenFound`, `JBUniswapV4LPSplitHook_AlreadyInitialized`, `JBUniswapV4LPSplitHook_AmountExceedsUint128`, `JBUniswapV4LPSplitHook_EmptyCorridor`.
  - `JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds`, `JBUniswapV4LPSplitHook_FeeBurnNotExact`, `JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject`, `JBUniswapV4LPSplitHook_InsufficientBalance`, `JBUniswapV4LPSplitHook_InvalidFeePercent`, `JBUniswapV4LPSplitHook_InvalidProjectId`, `JBUniswapV4LPSplitHook_InvalidSplitGroup`, `JBUniswapV4LPSplitHook_InvalidStageForAction`.
  - `JBUniswapV4LPSplitHook_InvalidTerminalToken`, `JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot`, `JBUniswapV4LPSplitHook_NoTokensAccumulated`, `JBUniswapV4LPSplitHook_NotHookSpecifiedInContext`, `JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported`, `JBUniswapV4LPSplitHook_Permit2AmountOverflow`, `JBUniswapV4LPSplitHook_PoolAlreadyDeployed`, `JBUniswapV4LPSplitHook_PriceDeviationTooHigh`.
  - `JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal`, `JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed`, `JBUniswapV4LPSplitHook_TwapUnavailable`, `JBUniswapV4LPSplitHook_Unauthorized`, `JBUniswapV4LPSplitHook_UnclaimedFeeTokenChanged`, `JBUniswapV4LPSplitHook_UnexpectedMsgValue`, `PRBMath_MulDiv_Overflow`, `Reentrancy`.
  - `SafeERC20FailedOperation`.
- Error names removed or replaced:
  - `JBPermissioned_Unauthorized`, `OwnableInvalidOwner`, `OwnableUnauthorizedAccount`, `PRBMath_MulDiv_Overflow`, `SafeERC20FailedOperation`, `UniV3DeploymentSplitHook_InvalidFeePercent`, `UniV3DeploymentSplitHook_InvalidProjectId`, `UniV3DeploymentSplitHook_InvalidStageForAction`.
  - `UniV3DeploymentSplitHook_InvalidTerminalToken`, `UniV3DeploymentSplitHook_NoTokensAccumulated`, `UniV3DeploymentSplitHook_NotHookSpecifiedInContext`, `UniV3DeploymentSplitHook_PoolAlreadyDeployed`, `UniV3DeploymentSplitHook_SplitSenderNotValidControllerOrTerminal`, `UniV3DeploymentSplitHook_TerminalTokensNotAllowed`, `UniV3DeploymentSplitHook_UnauthorizedBeneficiary`, `UniV3DeploymentSplitHook_ZeroAddressNotAllowed`.

## Migration Notes

- Treat this as a V3-to-V4 architecture migration. V5 pool addresses and V3 min-amount assumptions do not map directly.
- Regenerate ABIs from V6 and update indexers for `LiquidityAdded` instead of V5 `TokensBurned`.
- If you operated the V5 hook, re-evaluate permissions around `SET_BUYBACK_POOL` and V6 post-deploy liquidity growth.
