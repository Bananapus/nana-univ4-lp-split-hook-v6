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
- **JB Directory and Controller.** `controllerOf`, `primaryTerminalOf`, `isTerminalOf`, and project-owner resolution are all trusted integration points. The project's primary terminal (`addToBalanceOf` of terminal-token fee remainders) and controller (`burnTokensOf` of project-token fee remainders) are called best effort, so a failing one only sends that remainder back to its ledger.
- **Fee routing config.** `FEE_PROJECT_ID` and `FEE_PERCENT` are fixed at initialization.

## 2. Economic risks

- **LP range derived from bonding-curve state.** Tick bounds come from live Juicebox issuance and cash-out economics, not from a market oracle.
- **Local versus total surplus.** The floor counts surplus across all of the project's local terminals (`JBSurplus.currentSurplusOf` over `directory.terminalsOf`), the way the terminal store sums it at settlement, so surplus held by a terminal on a different store still counts. When cash outs are not scoped to local balances, the corridor adds remote surplus and supply from the sucker registry, which matches settlement only if the project's data hook aggregates the same way. Pay and cash-out data hooks can also override the issuance and cash-out economics the corridor assumes.
- **Corridor floor derived from cash-out price.** The floor tick is the project's cash-out (redemption) price — surplus over supply — taken as an upper bound on the per-token value of a 1-token cash-out preview (the preview plus two, never zero). The hook ranges liquidity down to it but never performs a cash-out to reach it. Under a cash-out tax, larger burns return more per token than this floor, because the curve is size dependent; that is the intended design. The ceiling is the net issuance rate bounded from above, so it never sits above the price a payer mints at. Both bounds round inward to the tick spacing against these exact prices.
- **Extreme weight scenarios.** Very low or zero effective issuance rates can make deployment invalid; very high weights can push tick bounds toward the edges.
- **Zero-surplus fallback.** If the cash-out preview rounds to zero, the corridor starts two spacings wide, ending at the issuance ceiling (rounded inward), or as the full range with no issuance at all; either way its floor side is then lifted to the cash-out bound, which can shrink the corridor or empty it.
- **Bounds refresh only at recycle time.** Donations, ruleset changes and price-feed moves can carry the true cash-out value or issuance price past the outstanding quotes; the positions keep quoting their old range until the next recycle recomputes the corridor, which anyone can trigger at any time.
- **Recycling depends on every terminal and price feed staying callable.** The bounds read each terminal's surplus view, the reclaim preview and the price feeds without a fallback, so a failing read reverts the recycle instead of reading as a zero floor (a distribution's inline automation fails softly and keeps the intake). A permanently reverting terminal or feed halts recycling until it is repaired or the project's terminals are reconfigured; positions and ledgers stay intact and fee claims still work. Recycle gas grows with the number of terminals and accounting contexts: about 30k, 40k, 112k and 402k gas for the surplus read with 1, 2, 8 and 32 simple terminals.
- **Dust handling.** Very small token balances can produce inert or effectively zero-liquidity outcomes.
- **Recycle value conservation.** A recycle conserves value only within rounding, the burn slippage floor, and leftover handling; leftover project tokens are carried back into `accumulatedProjectTokens` and leftover terminal tokens into `accumulatedTerminalTokens`, never burned and never deposited into the project's terminal.
- **Impermanent loss amplification.** This is concentrated liquidity. Trading converts the ask into terminal tokens and the bid into project tokens; between recycles a converted position sits on the wrong side of the spot until the next recycle moves its tokens back to the side they belong on.
- **Economic caps on both positions.** The ask is never placed below the cash-out floor and the bid never above the issuance ceiling, as computed at the last recycle. The floor bounds what a cash-out of at most one token realizes per token, from the sampled 1-token preview; under a cash-out tax larger burns realize more per token, so a large enough cash-out can pay out above the ask. The caps also assume the economics the corridor reads are the ones settlement uses (see the surplus and data-hook notes above), and they go stale between recycles. Within those limits, neither position sells project tokens below what the treasury would pay out for one token or buys them above what the project would issue them for.
- **Idle side when the spot leaves the corridor.** With the spot at or past the issuance ceiling, the ask has no range and project tokens wait in their ledger; with the spot at or past the cash-out floor, the bid has no range and terminal tokens wait. If neither side can mint, the recycle reverts `NoDeployableLiquidityAtSpot` and the live positions are kept.
- **An empty corridor holds everything.** When a project's cash-out value per token reaches its issuance price (for example after `addToBalance` donations or a weight increase, even by less than one tick), or no pair of distinct aligned ticks fits between the bounds (at or above the cash-out value and at or below the issuance price), the corridor is empty: a recycle retires both positions and keeps every token in the ledgers until the corridor reopens, and `deployPool` reverts `EmptyCorridor`. Positions minted before the corridor emptied keep quoting until someone recycles, which anyone can do at any time. While the hook holds, its pool may be empty, so the spot (and over 30 minutes the oracle TWAP) is cheap to move; when the corridor reopens, the corridor bounds still cap where either quote can sit. With no live position, `collectAndRouteLPFees` reverts `InvalidStageForAction` until a recycle redeploys. Buying the hook's inventory below the cash-out value would beat paying the project directly, because direct payment also mints reserved tokens that dilute the cash-out value.
- **Accumulation-period idle capital.** Before deployment, accumulated reserved tokens are idle.

## 3. MEV and timing risks

- **Recycle sandwich/JIT risk.** Each recycle burns and re-mints both positions around the live spot. Recycles are permissionless at any time (`addLiquidity` is open to anyone, with or without new tokens), so a searcher controls their timing, down to the block. The edge is bounded by the TWAP band and roughly offset by the 1% pool fee paid into and out of the positions; the caller pays the recycle's gas and the hook loses no principal to churn. They are bounded by the spot-vs-TWAP guard: the spot must sit within 200 ticks (about 2%) of the 30-minute oracle TWAP, and the recycle refuses to run when the TWAP is unavailable. Both quotes are anchored to the validated TWAP: the ask never sells project tokens below the TWAP price and the bid never buys them above it, so a manipulation inside the band only widens the gap between the positions. Without the anchor, walking the spot through the empty gaps (a dust trade across each boundary, then a recycle) and trading only at the band edges captured the full band width, about 4%, against 2% of fees. The gap keeps both mints single-sided (it closes onto the spot only when the spot sits exactly on an aligned tick and the TWAP tick equals it), and the corridor caps bound what either position can be filled at. A recycle never cashes out and never swaps through the pool it feeds, so it cannot move the spot within its own call.
- **Burn slippage floor.** Each burn requires at least 95% of the position's principal computed from its on-chain liquidity and ticks (read from the PositionManager) at the live spot. Callers never supply burn minimums.
- **Permissionless fee collection timing.** Anyone can trigger some fee-collection paths, so adversarial timing is possible even if direct extraction is limited.
- **Public pool pre-initialization.** The target pool can be initialized before the hook deploys its first position. The contract validates the existing price against the project's economic tick bounds and reverts if out of range — see §7.4.

## 4. Recycle risks

- **Recycles run on every distribution.** Reserved-token distributions and payout splits both make the inline attempt. It is best-effort with a fixed budget of 2,000,000 gas (`_AUTOMATION_GAS_BUDGET`): it starts only with the budget plus a 64,000 reserve left and is forwarded at most the budget (an attempt that still runs out of gas is reported like any failure). Measured cold through the clone on a mainnet fork with real Core (`MultiTerminalRecycleFork`), a full two-position recycle reached through `sendPayoutsOf` costs about 1.28M with one terminal and about 30k more per additional terminal the project registers, since the surplus read visits each one: about 1.37M with four, 1.43M with six and 1.49M with eight, so the budget covers about 20 terminals; a project with more relies on the uncapped permissionless `addLiquidity` retry. Because the attempt can never take more than its budget, a distribution that supplies the budget plus its own remaining work (the terminal's later payout recipients, the controller's later reserved splits) always finishes, even when the attempt burns its whole budget. A failed attempt emits `LiquidityAutomationFailed` while the accepted inventory stays in the ledgers for the permissionless `addLiquidity` retry. Fee routing adds up to four external calls per recycle (an add to balance and a burn per retired position), which count against the same budget, so more inline attempts can fall back to the retry. Reserved-token distributions skip the attempt while the project ledger is below the churn threshold; payouts attempt at any size.
- **Atomicity matters.** Both positions are retired and both mints happen in one call; `askTokenIdOf` and `bidTokenIdOf` are written only after the mints, and a recycle that cannot mint either side reverts with the old positions intact.
- **Leftover token handling matters.** Leftover project tokens are carried back into `accumulatedProjectTokens`; leftover terminal tokens into `accumulatedTerminalTokens`. Leftovers are never burned and never deposited into the project's terminal.
- **Fee collection order matters.** Each position's fees are collected and routed before it is burned, so the fee-project cut applies to trading fees only, never to principal. Each side takes a best-effort fee-project cut; the non-cut terminal-token remainder is added to the project's balance and the project-token remainder is burned, each landing in this project's own ledger (`accumulatedTerminalTokens` or `accumulatedProjectTokens`) when that route fails. Fees are routed before the corridor is priced, so the recycle mints around the raised floor. A terminal token that charges the sender on top of a transfer cannot underback the other ledgers through fee routing: `sendToTerminal` measures the hook's balance and reverts `JBUniswapV4LPSplitHook_TransferNotExact` when a send debits more than its amount, so that cut is forgiven or that remainder falls back to its ledger.
- **Tokens that charge the sender on top of a transfer.** Every outgoing path measures what left the hook. A fee send that is debited more than it sent reverts `TransferNotExact` and falls back to the ledger; a mint that is debited more than it offered reverts the recycle (the tokens stay ledgered, and the token cannot be recycled). Such a token therefore never spends balances that back another project's ledger on the same clone, but it cannot be used as liquidity. The fee-token claim measures the debit too: `claimFeeTokensFor` reverts `TransferNotExact` when the transfer debits the hook more than the claim, so the claim and its reserve stay intact and the other ledgers stay fully backed.
- **Spot price is used during every recycle.** Operators should treat recycle timing as economically sensitive; the TWAP guard bounds it, it does not remove it.

## 5. Access control risks

- **`deployPool` is permissionless.** The seed reverts once the pool spot reaches the issuance ceiling, so accumulated tokens are never locked behind an operator and a caller cannot deploy outside the economic corridor.
- **`addLiquidity` is permissionless.** It runs at any time, and reverts if the pool spot price deviates from the oracle TWAP by more than the bound or the TWAP is unavailable; accumulation continues safely until it can run.
- **`collectAndRouteLPFees` is permissionless.** It collects fees from the ask and bid without touching principal. It raises the cash-out floor without moving the positions, which keep quoting their old range until the next recycle.
- **`processSplitWith` accepts two senders.** Reserved-token splits (group 1) only from the project's controller; payout splits only from a terminal of the project, under the token's group, after deployment, in the pool's terminal token. Any rejection reverts, and Core returns the allocation to the project.
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

If the fee project has no primary terminal for the collected token, the fee project simply misses that collection and the full amount is routed to the originating project like any remainder (added to its balance or burned, falling back to `accumulatedTerminalTokens` or `accumulatedProjectTokens`). This is accepted because fee-project terminal configuration is owned by the fee project, not by this LP split hook.

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

Whatever is not taken as a cut accrues to the originating project and raises its cash-out floor: the terminal-token remainder is added to the project's balance in its primary terminal for that token (`addToBalanceOf`, more surplus), and the project-token remainder is burned through the controller (`burnTokensOf`, less supply). Each route is best effort: when it reverts (no primary terminal, a rejecting terminal, a reverting controller, an inexact burn), that remainder is carried into `accumulatedTerminalTokens[projectId][terminalToken]` (the bid-side ledger) or `accumulatedProjectTokens` (the ask-side ledger) and becomes liquidity at the next recycle. A failure never blocks the collection or the other side.

In practice, the project-token cut is usually forgiven, because the fee project rarely has a terminal configured to accept an arbitrary project's token — so project-token fees are typically burned in full. The mechanism captures the cut whenever such a fee-project terminal does exist; nothing in the design privileges one side over the other.

### 7.6 `deployPool` auto-selects and permanently locks the terminal token

`deployPool` selects the terminal token by highest ETH-denominated value across the project's terminals and permanently locks it (`hasDeployedPool`); one terminal token is supported per project. A party willing to fund the project's own terminal could shift which token holds the highest ETH-denominated value at deploy time and thereby influence which pairing is chosen.

This is accepted as low severity: the influencer must deposit real value into the project's terminal to move the ranking, that value accrues to the project, and the selection only affects which of the project's own terminal tokens is paired — it cannot inject a foreign or attacker-controlled token, since selection is constrained to the project's registered terminals.

### 7.7 Existing clones keep their own position model

The two-position hook ships as a new library, implementation, and deployer at fresh addresses. Clones of an earlier deployment (for example 1.4.0) are unaffected and keep their single-position behavior. A project adopts the two-position model by deploying a clone from the new deployer and re-pointing its reserved-token split to it; inventory already held by the old clone stays under the old clone's rules.

### 7.8 Owed fee credits keep a fee project's own fee burns in the ledger

Core burns a holder's credits before its ERC-20, so `burnFeeRemainder` first claims every credit the hook holds for the project into the ERC-20 and the ask ledger (`_claimHookCreditsFor`, the same step a recycle runs), then accepts the burn only when exactly the remainder left the hook's ERC-20 balance and its credit balance is unchanged (otherwise `JBUniswapV4LPSplitHook_FeeBurnNotExact`, forgiven). Credits a third party sends the hook are claimed this way, so they cannot divert the burn; they become ask inventory. The one exception is fee-credit claims the hook owes (`_totalOutstandingFeeCreditClaims`): they exist only when the project is itself the fee project and accrued fee credits before it had an ERC-20. They are never claimed, so while any are outstanding the burn would consume them first and is forgiven instead; that project's project-token fee remainders become ask liquidity rather than a supply reduction until the claims are settled. No value is lost.

### 7.9 Payout splits pay Core's fee

Core charges its normal fee on payouts to split hooks unless the project is feeless, so a payout routed to this hook funds the bid with the net amount.
