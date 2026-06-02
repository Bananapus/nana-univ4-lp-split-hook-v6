# Juicebox UniV4 LP Split Hook Risk Register

This file focuses on the lifecycle, pricing, and fee-accounting risks in `JBUniswapV4LPSplitHook`. The main question is whether the hook moves reserved-token value into liquidity without losing track of ownership, bounds, or fee claims.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections to separate deployment-stage risks from post-deployment management risks.
- Treat `Accepted Behaviors` and `Invariants to Verify` as the line between intended lifecycle behavior and bugs.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Wrong LP bounds or rebalance math | Bad price math can misplace treasury liquidity and destroy value. | Bound validation, lifecycle tests, and careful review of deployment/rebalance formulas. |
| P1 | Public first-pool initialization | Outside actors can initialize the target pool first. | Contract-side range validation and operator awareness. |
| P1 | Post-deploy accumulate / add-liquidity and fee-accounting assumptions | After deployment, `addLiquidity` cashes out directly through the bonding curve and adds liquidity under a TWAP-deviation guard; tracked fee value must remain separate from LP-spendable balances. | Lifecycle docs, TWAP-guard + claim-segregation tests, and accounting invariants. |

## 1. Trust Assumptions

- **Uniswap V4 PoolManager.** All LP positions are ultimately held through PoolManager.
- **Uniswap V4 PositionManager.** Burn, mint, decrease-liquidity, and fee collection depend on it.
- **Oracle hook.** The chosen hook in the pool key is immutable. A bad oracle hook can affect every pool managed by the split hook.
- **Permit2.** Used for ERC-20 approvals into the position-management flow.
- **JB Directory and Controller.** `controllerOf`, `primaryTerminalOf`, and project-owner resolution are all trusted integration points.
- **Fee routing config.** `FEE_PROJECT_ID` and `FEE_PERCENT` are fixed at initialization.

## 2. Economic Risks

- **LP range derived from bonding-curve state.** Tick bounds come from live Juicebox issuance and cash-out economics, not from a market oracle.
- **Local versus total surplus.** Cash-out-rate derivation depends on whether the project uses local surplus or total surplus for cash outs.
- **Pool-deploy cash-out floor.** `minCashOutReturn` can raise the deployment cash-out floor, but it cannot lower the
  floor derived from the same cash-out rate used to size the LP position.
- **Extreme weight scenarios.** Very low or zero effective issuance rates can make deployment invalid; very high weights can push tick bounds toward the edges.
- **Zero-surplus fallback.** If cash-out rate is effectively zero, the hook falls back to a minimal issuance-centered range.
- **Dust handling.** Very small token balances can produce inert or effectively zero-liquidity outcomes.
- **Rebalance value conservation.** Rebalance conserves value only within rounding and leftover handling; extra leftover project tokens are carried back into the accumulation ledger and leftover terminal tokens are returned to the project terminal — never burned.
- **Impermanent loss amplification.** This is concentrated liquidity. If price exits the range, the position becomes single-sided.
- **Accumulation-period idle capital.** Before deployment, accumulated reserved tokens are idle.

## 3. MEV And Timing Risks

- **Rebalance sandwich risk.** Rebalance depends on spot pool price at execution time. A searcher can try to skew the price around the transaction.
- **`addLiquidity` sandwich/JIT risk.** `addLiquidity` mints at the pool's live price, so it is bounded by a TWAP-deviation check (rejects adds whose spot is too far from the oracle TWAP, and refuses to add when the TWAP is unavailable) and by a force-direct cash-out that never routes through the AMM being fed.
- **Permissionless fee collection timing.** Anyone can trigger some fee-collection paths, so adversarial timing is possible even if direct extraction is limited.
- **Public pool pre-initialization.** The target pool can be initialized before the hook deploys its first position. The contract validates the existing price against the project's economic tick bounds and reverts if out of range — see §7.4.

## 4. Rebalance Risks

- **Authorization is narrower than fee collection.** Rebalance is owner or delegate gated, but fee collection is not always gated.
- **Consecutive rebalance safety matters.** New position IDs must only be stored after successful remint.
- **Leftover token handling matters.** Leftover project tokens are carried back into the accumulation ledger; leftover terminal tokens are returned to project balance. Nothing is burned.
- **Fee collection order matters.** Collected fees should be separated before reminting principal; the project-token fee side is carried into the accumulation ledger (not burned).
- **Spot price is used during rebalance.** Operators should treat rebalance timing as economically sensitive.

## 5. Access Control Risks

- **`deployPool` can become permissionless after weight decay.** This is intentional so tokens do not remain locked forever.
- **`addLiquidity` shares `deployPool`'s authorization** (permissionless once the ruleset weight has decayed 10x, else `SET_BUYBACK_POOL`). It reverts if the pool spot price deviates from the oracle TWAP by more than the bound, or if the TWAP is unavailable — accumulation continues safely until it can run.
- **`rebalanceLiquidity` stays gated.** Absent or hostile operators can leave a stale position un-rebalanced.
- **`claimFeeTokensFor` is gated.** Unclaimed fee tokens or fee credits can sit in the hook indefinitely.
- **`initialize` is one-shot.** First-call semantics on clones matter.

## 6. Invariants to Verify

- Token conservation across rebalance.
- No value creation from rebalance.
- Fee routing completeness for collected fees.
- `tokenIdOf` stays nonzero for deployed project paths unless the whole transaction reverts.
- `accumulatedProjectTokens` is consumed by a successful deploy/add down to at most an unpaired remainder, which is carried forward (never burned); post-deploy inflows re-accumulate into it.
- Hook-held project credits are claimed into ERC-20 project tokens before deploy/add funding cash-outs, so credit-first burns cannot leave project tokens outside the accumulation ledger.
- `addLiquidity` never mints at a price far from the oracle TWAP. Its funding cash-out is force-routed to the bonding curve (never through the AMM) **when a buyback hook is configured** — the production deployment path. A clone initialized with `buybackHook == address(0)` skips the force-direct metadata, so the project's own cash-out data hook runs instead: if that hook routes cash-outs through the same pool the LP hook feeds, it can move spot price within the call before liquidity is sized against the pre-cash-out `sqrtPriceInit`. Pair the LP hook with a buyback hook to preserve this invariant.
- Cross-project isolation holds across all keyed storage.
- Fee-token and fee-credit bookkeeping match actual claimable balances.
- Tick bounds stay valid, aligned, and ordered.
- Only one deployed pool identity exists per `(projectId, terminalToken)` path.

## 7. Accepted Behaviors

### 7.1 Reentrancy trust boundary during `deployPool`

The design assumes trusted Juicebox and Uniswap components on the critical external-call boundary during deployment. Re-entering through a compromised core dependency is outside the local threat model.

### 7.2 Fee routing uses `minReturnedTokens: 0`

Fee routing into the fee project intentionally does not set a local slippage floor. The fee project's own terminal and hook logic are expected to own that behavior.

If the fee project has no primary terminal for the collected token, the fee project simply misses that collection and the full amount stays in the project's normal split-hook flow. This is accepted because fee-project terminal configuration is owned by the fee project, not by this LP split hook.

### 7.3 Permit2 approval bounds and cleanup

The hook checks for `uint160` overflow before narrowing approval amounts for Permit2. Successful mint paths also clear
both the Permit2 spender allowance and the ERC-20 allowance granted to Permit2, because Uniswap V4 mints can consume
less than the max amount approved for settlement.

### 7.4 Pre-initialized pools are validated against economic tick bounds

When `deployPool` encounters an already-initialized pool (e.g. by an attacker or another deployer), the hook validates the existing price against the project's economic tick bounds (cashout floor to issuance ceiling). If the price is outside those bounds, `deployPool` reverts with `JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds`.

- An attacker who front-runs pool creation with an extreme price cannot force the project into a single-sided position or extract value.
- A reverted `deployPool` does not mark the pool as deployed, so the project can retry once the pool is re-initialized at a valid price (e.g. via a different pool key or after pool state is corrected).
- If the existing price is within the tick bounds, the hook accepts it and proceeds normally.
