# Juicebox UniV4 LP Split Hook Risk Register

This file focuses on the lifecycle, pricing, and fee-accounting risks in `JBUniswapV4LPSplitHook`. The main question is whether the hook moves reserved-token value into liquidity without losing track of ownership, bounds, or fee claims.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections to separate deployment-stage risks from post-deployment management risks.
- Treat `Accepted Behaviors` and `Invariants to Verify` as the line between intended lifecycle behavior and bugs.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Wrong LP bounds or recycle geometry | Bad price math can misplace treasury liquidity and destroy value. | Bound validation, the ask/bid corridor clamps in `_recycle`, lifecycle tests, and careful review of the deployment and recycle formulas. |
| P1 | Public first-pool initialization | Outside actors can initialize the target pool first. | Contract-side range validation and operator awareness. |
| P1 | Permissionless recycle timing and fee-accounting assumptions | Every reserved distribution (itself permissionless) and every `addLiquidity` call recycles both positions on the live spot under a TWAP-deviation guard and never cashes out; tracked fee value must remain separate from LP-spendable balances. | Spot-vs-TWAP guard, one-spacing gap, corridor caps on both positions, claim-segregation tests, and accounting invariants. |

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
- **Recycle value conservation.** A recycle conserves value only within rounding, the burn slippage floor, and leftover handling; leftover project tokens are carried back into `accumulatedProjectTokens` and leftover terminal tokens into `accumulatedTerminalTokens`, never burned and never deposited into the project's terminal.
- **Impermanent loss amplification.** This is concentrated liquidity. Trading converts the ask into terminal tokens and the bid into project tokens; between recycles a converted position sits on the wrong side of the spot until the next recycle moves its tokens back to the side they belong on.
- **Economic caps on both positions.** The ask is never placed below the cash-out floor and the bid never above the issuance ceiling, so neither position sells project tokens below what the treasury would pay out or buys them above what the project would issue them for.
- **Idle side when the spot leaves the corridor.** With the spot at or past the issuance ceiling, the ask has no range and project tokens wait in their ledger; with the spot at or past the cash-out floor, the bid has no range and terminal tokens wait. If neither side can mint, the recycle reverts `NoDeployableLiquidityAtSpot` and the live positions are kept.
- **Accumulation-period idle capital.** Before deployment, accumulated reserved tokens are idle.

## 3. MEV and timing risks

- **Recycle sandwich/JIT risk.** Each recycle burns and re-mints both positions around the live spot. Recycles are permissionless at any time (`addLiquidity` is open to anyone, with or without new tokens), so a searcher controls their timing, down to the block. The edge is bounded by the TWAP band and roughly offset by the 1% pool fee paid into and out of the positions; the caller pays the recycle's gas and the hook loses no principal to churn. They are bounded by the spot-vs-TWAP guard: the spot must sit within 200 ticks (about 2%) of the 30-minute oracle TWAP, and the recycle refuses to run when the TWAP is unavailable. A manipulation inside that band can shift the one-spacing gap by up to the TWAP tolerance. The gap means the hook never quotes at the exact spot, and the corridor caps bound what either position can be filled at. A recycle never cashes out and never swaps through the pool it feeds, so it cannot move the spot within its own call.
- **Burn slippage floor.** Each burn requires at least 95% of the position's principal computed from its on-chain liquidity and ticks (read from the PositionManager) at the live spot. Callers never supply burn minimums.
- **Permissionless fee collection timing.** Anyone can trigger some fee-collection paths, so adversarial timing is possible even if direct extraction is limited.
- **Public pool pre-initialization.** The target pool can be initialized before the hook deploys its first position. The contract validates the existing price against the project's economic tick bounds and reverts if out of range — see §7.4.

## 4. Recycle risks

- **Recycles run on every distribution.** The inline attempt is best-effort: it needs at least 1,000,000 gas plus a 64,000 reserve (a full recycle measured about 955k on a mainnet fork), and a failed attempt emits `LiquidityAutomationFailed` while the accepted inventory stays in the ledgers for the permissionless `addLiquidity` retry.
- **Atomicity matters.** Both positions are retired and both mints happen in one call; `askTokenIdOf` and `bidTokenIdOf` are written only after the mints, and a recycle that cannot mint either side reverts with the old positions intact.
- **Leftover token handling matters.** Leftover project tokens are carried back into `accumulatedProjectTokens`; leftover terminal tokens into `accumulatedTerminalTokens`. Nothing is burned and nothing is deposited into the project's terminal.
- **Fee collection order matters.** Each position's fees are collected and routed before it is burned, so the fee-project cut applies to trading fees only, never to principal. Each side takes a best-effort fee-project cut, and the non-cut remainder lands in this project's own ledger (`accumulatedProjectTokens` or `accumulatedTerminalTokens`).
- **Spot price is used during every recycle.** Operators should treat recycle timing as economically sensitive; the TWAP guard bounds it, it does not remove it.

## 5. Access control risks

- **`deployPool` is permissionless.** The seed reverts once the pool spot reaches the issuance ceiling, so accumulated tokens are never locked behind an operator and a caller cannot deploy outside the economic corridor.
- **`addLiquidity` is permissionless.** It runs at any time, and reverts if the pool spot price deviates from the oracle TWAP by more than the bound or the TWAP is unavailable; accumulation continues safely until it can run.
- **`collectAndRouteLPFees` is permissionless.** It collects fees from the ask and bid without touching principal.
- **`claimFeeTokensFor` is gated.** Unclaimed fee tokens or fee credits can sit in the hook indefinitely.
- **`initialize` is one-shot.** First-call semantics on clones matter.

## 6. Invariants to verify

- Token conservation across each recycle.
- No value creation from a recycle.
- Fee routing completeness for collected fees.
- At most two positions per `(projectId, terminalToken)`; `askTokenIdOf` and `bidTokenIdOf` only ever name positions the hook holds, and at least one is nonzero after a successful recycle.
- `accumulatedProjectTokens` and `accumulatedTerminalTokens` are consumed by a successful recycle down to whatever a skipped side or mint rounding leaves, which is carried forward (never burned); post-deploy inflows re-accumulate into them.
- Hook-held project credits are claimed into ERC-20 project tokens before deploy/add mints, so credit-first burns cannot leave project tokens outside the accumulation ledger.
- A recycle never mints at a price far from the oracle TWAP (it rejects spot/TWAP deviation beyond the bound and refuses to run when the TWAP is unavailable). It never cashes out and never routes through the AMM it feeds, so it cannot move the pool spot within its own call: the bid is funded solely from this project's terminal-token ledger.
- The ask never sits below the cash-out floor and the bid never above the issuance ceiling.
- Cross-project isolation holds across all keyed storage.
- Fee-token and fee-credit bookkeeping match actual claimable balances and keep those claims out of deploy/add principal.
- Tick bounds stay valid, aligned, and ordered.
- Only one deployed pool identity exists per `(projectId, terminalToken)` path.

## 7. Accepted behaviors

### 7.1 Reentrancy trust boundary during `deployPool`

The design assumes trusted Juicebox and Uniswap components on the critical external-call boundary during deployment. Re-entering through a compromised core dependency is outside the local threat model.

### 7.2 Fee routing uses `minReturnedTokens: 0`

Fee routing into the fee project intentionally does not set a local slippage floor. The fee project's own terminal and hook logic are expected to own that behavior.

If the fee project has no primary terminal for the collected token, the fee project simply misses that collection and the full amount is carried into the originating project's own ledger instead (the ask ledger `accumulatedProjectTokens` or the bid ledger `accumulatedTerminalTokens`, depending on which side was being cut). This is accepted because fee-project terminal configuration is owned by the fee project, not by this LP split hook.

### 7.3 Permit2 approval bounds and cleanup

The hook checks for `uint160` overflow before narrowing approval amounts for Permit2. Successful mint paths also clear
both the Permit2 spender allowance and the ERC-20 allowance granted to Permit2, because Uniswap V4 mints can consume
less than the max amount approved for settlement.

### 7.4 Pre-initialized pools are validated against economic tick bounds

When `deployPool` encounters an already-initialized pool (e.g. by an attacker or another deployer), the hook validates the existing price against the project's cash-out floor. If the price is at or past the floor, `deployPool` reverts with `JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds`. A price at or past the issuance ceiling is accepted: the first recycle then has no ask range and, holding no terminal tokens yet, reverts `NoDeployableLiquidityAtSpot` until the spot returns inside the corridor or the ceiling moves. Rejecting that side would strand the pair, since with no liquidity nothing could trade the price back. The deploy also requires the existing spot to pass the spot-vs-TWAP guard.

- An attacker who front-runs pool creation with an extreme price cannot make the hook sell project tokens below the cash-out floor or extract value.
- A reverted `deployPool` does not mark the pool as deployed, so the project can retry once the pool price is valid.
- If the existing price is inside the corridor, the hook accepts it and proceeds normally.

### 7.5 Fee-project cut is best-effort on both sides

LP trading fees accrue in both tokens. When fees are collected and routed, the `feeProjectId` protocol cut is attempted symmetrically on both the terminal-token side and the project-token side: for each side, the hook checks whether the fee project has a primary terminal that accepts that token, and if so pays the cut there so it becomes claimable by the fee project as fee tokens or fee-project credits. The payment is wrapped so a missing fee-project terminal or a reverting payment is forgiven — fee collection never fails because of the fee project's own configuration or state.

Whatever is not taken as a cut becomes the originating project's own protocol-owned liquidity, never the project's terminal balance: the project-token remainder is carried into `accumulatedProjectTokens` (the ask-side ledger), and the terminal-token remainder is carried into `accumulatedTerminalTokens[projectId][terminalToken]` (the per-project bid-side ledger). Each recycle mints the whole project ledger into the ask and the whole terminal ledger into the bid.

In practice, the project-token cut is usually forgiven, because the fee project rarely has a terminal configured to accept an arbitrary project's token — so project-token fees typically stay entirely as the project's own liquidity. The mechanism captures the cut whenever such a fee-project terminal does exist; nothing in the design privileges one side over the other.

### 7.6 `deployPool` auto-selects and permanently locks the terminal token

`deployPool` selects the terminal token by highest ETH-denominated value across the project's terminals and permanently locks it (`hasDeployedPool`); one terminal token is supported per project. A party willing to fund the project's own terminal could shift which token holds the highest ETH-denominated value at deploy time and thereby influence which pairing is chosen.

This is accepted as low severity: the influencer must deposit real value into the project's terminal to move the ranking, that value accrues to the project, and the selection only affects which of the project's own terminal tokens is paired — it cannot inject a foreign or attacker-controlled token, since selection is constrained to the project's registered terminals.

### 7.7 Existing clones keep their own position model

The two-position hook ships as a new library, implementation, and deployer at fresh addresses. Clones of an earlier deployment (for example 1.4.0) are unaffected and keep their single-position behavior. A project adopts the two-position model by deploying a clone from the new deployer and re-pointing its reserved-token split to it; inventory already held by the old clone stays under the old clone's rules.
