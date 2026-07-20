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
| P1 | Post-deploy accumulate / add-liquidity and fee-accounting assumptions | After deployment, `addLiquidity` folds accumulation into the single position (burn prior, re-mint one) under a TWAP-deviation guard and never cashes out; tracked fee value must remain separate from LP-spendable balances. | Lifecycle docs, TWAP-guard + claim-segregation tests, and accounting invariants. |

## 1. Trust assumptions

- **Uniswap V4 PoolManager.** All LP positions are ultimately held through PoolManager.
- **Uniswap V4 PositionManager.** Burn, mint, decrease-liquidity, and fee collection depend on it.
- **Oracle hook.** The chosen hook in the pool key is immutable. A bad oracle hook can affect every pool managed by the split hook.
- **Permit2.** Used for ERC-20 approvals into the position-management flow.
- **JB Directory and Controller.** `controllerOf`, `primaryTerminalOf`, and project-owner resolution are all trusted integration points.
- **Fee routing config.** `FEE_PROJECT_ID` and `FEE_PERCENT` are fixed at initialization.

## 2. Economic risks

- **LP range derived from bonding-curve state.** Tick bounds come from live Juicebox issuance and cash-out economics, not from a market oracle.
- **Local versus total surplus.** Cash-out-rate derivation depends on whether the project uses local surplus or total surplus for cash outs.
- **Corridor floor derived from cash-out price.** The floor tick is the project's cash-out (redemption) price — surplus over supply. The hook ranges liquidity down to it but never performs a cash-out to reach it.
- **Extreme weight scenarios.** Very low or zero effective issuance rates can make deployment invalid; very high weights can push tick bounds toward the edges.
- **Zero-surplus fallback.** If cash-out rate is effectively zero, the hook falls back to a minimal issuance-centered range.
- **Dust handling.** Very small token balances can produce inert or effectively zero-liquidity outcomes.
- **Rebalance value conservation.** Rebalance conserves value only within rounding and leftover handling; extra leftover project tokens are carried back into the accumulation ledger and leftover terminal tokens are carried into the per-project terminal-token ledger (`accumulatedTerminalTokens`) — never burned, never deposited into the project's terminal.
- **Impermanent loss amplification.** This is concentrated liquidity. If price exits the range, the position becomes single-sided.
- **Accumulation-period idle capital.** Before deployment, accumulated reserved tokens are idle.

## 3. MEV and timing risks

- **Rebalance sandwich risk.** Rebalance depends on spot pool price at execution time. A searcher can try to skew the price around the transaction.
- **`addLiquidity` sandwich/JIT risk.** `addLiquidity` mints at the pool's live price, so it is bounded by a TWAP-deviation check (rejects adds whose spot is too far from the oracle TWAP, and refuses to add when the TWAP is unavailable). It never cashes out and never routes through the AMM it feeds, so it cannot move the pool spot within its own call.
- **Permissionless fee collection timing.** Anyone can trigger some fee-collection paths, so adversarial timing is possible even if direct extraction is limited.
- **Public pool pre-initialization.** The target pool can be initialized before the hook deploys its first position. The contract validates the existing price against the project's economic tick bounds and reverts if out of range — see §7.4.

## 4. Rebalance risks

- **Rebalance is permissionless.** It is bounded by a corridor-drift threshold (rejects churn that would not meaningfully re-range) and the oracle-TWAP deviation guard, so a third party cannot force-rebalance at an adversarial spot.
- **Consecutive rebalance safety matters.** New position IDs must only be stored after successful remint.
- **Leftover token handling matters.** Leftover project tokens are carried back into the accumulation ledger; leftover terminal tokens are carried into the per-project terminal-token ledger (`accumulatedTerminalTokens`). Nothing is burned and nothing is deposited into the project's terminal.
- **Fee collection order matters.** Collected fees should be separated before reminting principal; each side (project-token and terminal-token) takes a best-effort fee-project cut, and the non-cut remainder of each is carried into this project's own ledger — the ask-leg `accumulatedProjectTokens` or the bid-leg `accumulatedTerminalTokens` — rather than being re-read as burn principal.
- **Spot price is used during rebalance.** Operators should treat rebalance timing as economically sensitive.

## 5. Access control risks

- **`deployPool` is permissionless.** The seed reverts once the pool spot reaches the issuance ceiling, so accumulated tokens are never locked behind an operator and a caller cannot deploy outside the economic corridor.
- **`addLiquidity` is permissionless.** It reverts if the pool spot price deviates from the oracle TWAP by more than the bound, or if the TWAP is unavailable — accumulation continues safely until it can run.
- **`rebalanceLiquidity` is permissionless.** Bounded by the corridor-drift threshold and the oracle-TWAP deviation guard, so anyone can re-center a stale position without an operator, but never at a manipulated ratio.
- **`claimFeeTokensFor` is gated.** Unclaimed fee tokens or fee credits can sit in the hook indefinitely.
- **`initialize` is one-shot.** First-call semantics on clones matter.

## 6. Invariants to verify

- Token conservation across rebalance.
- No value creation from rebalance.
- Fee routing completeness for collected fees.
- `tokenIdOf` stays nonzero for deployed project paths unless the whole transaction reverts.
- `accumulatedProjectTokens` is consumed by a successful deploy/add down to at most an unpaired remainder, which is carried forward (never burned); post-deploy inflows re-accumulate into it.
- Hook-held project credits are claimed into ERC-20 project tokens before deploy/add mints, so credit-first burns cannot leave project tokens outside the accumulation ledger.
- `addLiquidity` never mints at a price far from the oracle TWAP (it rejects spot/TWAP deviation beyond the bound and refuses to add when the TWAP is unavailable). It never cashes out and never routes through the AMM it feeds, so it cannot move the pool spot within its own call: any terminal-token (bid) side of the re-minted position is funded solely from the terminal the hook recovers by burning its own prior V4 position.
- Cross-project isolation holds across all keyed storage.
- Fee-token and fee-credit bookkeeping match actual claimable balances and keep those claims out of deploy/add principal.
- Tick bounds stay valid, aligned, and ordered.
- Only one deployed pool identity exists per `(projectId, terminalToken)` path.

## 7. Accepted behaviors

### 7.1 Reentrancy trust boundary during `deployPool`

The design assumes trusted Juicebox and Uniswap components on the critical external-call boundary during deployment. Re-entering through a compromised core dependency is outside the local threat model.

### 7.2 Fee routing uses `minReturnedTokens: 0`

Fee routing into the fee project intentionally does not set a local slippage floor. The fee project's own terminal and hook logic are expected to own that behavior.

If the fee project has no primary terminal for the collected token, the fee project simply misses that collection and the full amount is carried into the originating project's own ledger instead (the ask-leg `accumulatedProjectTokens` or the bid-leg `accumulatedTerminalTokens`, depending on which side was being cut). This is accepted because fee-project terminal configuration is owned by the fee project, not by this LP split hook.

### 7.3 Permit2 approval bounds and cleanup

The hook checks for `uint160` overflow before narrowing approval amounts for Permit2. Successful mint paths also clear
both the Permit2 spender allowance and the ERC-20 allowance granted to Permit2, because Uniswap V4 mints can consume
less than the max amount approved for settlement.

### 7.4 Pre-initialized pools are validated against economic tick bounds

When `deployPool` encounters an already-initialized pool (e.g. by an attacker or another deployer), the hook validates the existing price against the project's economic tick bounds (cashout floor to issuance ceiling). If the price is outside those bounds, `deployPool` reverts with `JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds`.

- An attacker who front-runs pool creation with an extreme price cannot force the project into a single-sided position or extract value.
- A reverted `deployPool` does not mark the pool as deployed, so the project can retry once the pool is re-initialized at a valid price (e.g. via a different pool key or after pool state is corrected).
- If the existing price is within the tick bounds, the hook accepts it and proceeds normally.

### 7.5 Fee-project cut is best-effort on both sides

LP trading fees accrue in both tokens. When fees are collected and routed, the `feeProjectId` protocol cut is attempted symmetrically on both the terminal-token side and the project-token side: for each side, the hook checks whether the fee project has a primary terminal that accepts that token, and if so pays the cut there so it becomes claimable by the fee project as fee tokens or fee-project credits. The payment is wrapped so a missing fee-project terminal or a reverting payment is forgiven — fee collection never fails because of the fee project's own configuration or state.

Whatever is not taken as a cut becomes the originating project's own protocol-owned liquidity, never the project's terminal balance: the project-token remainder is carried into `accumulatedProjectTokens` (the ask-side ledger), and the terminal-token remainder is carried into `accumulatedTerminalTokens[projectId][terminalToken]` (the per-project bid-side ledger). Both ledgers fold into the next mint.

In practice, the project-token cut is usually forgiven, because the fee project rarely has a terminal configured to accept an arbitrary project's token — so project-token fees typically stay entirely as the project's own liquidity. The mechanism captures the cut whenever such a fee-project terminal does exist; nothing in the design privileges one side over the other.

### 7.6 `deployPool` auto-selects and permanently locks the terminal token

`deployPool` selects the terminal token by highest ETH-denominated value across the project's terminals and permanently locks it (`hasDeployedPool`); one terminal token is supported per project. A party willing to fund the project's own terminal could shift which token holds the highest ETH-denominated value at deploy time and thereby influence which pairing is chosen.

This is accepted as low severity: the influencer must deposit real value into the project's terminal to move the ranking, that value accrues to the project, and the selection only affects which of the project's own terminal tokens is paired — it cannot inject a foreign or attacker-controlled token, since selection is constrained to the project's registered terminals.
