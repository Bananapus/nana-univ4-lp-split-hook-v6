# Single-sided, cash-out-free, permissionless-rebalance LP split hook — design

**Date:** 2026-07-18
**Status:** Draft for review
**Working name:** `JBUniswapV4LPSplitHookSingleSided`

## Summary

A sibling to the existing `JBUniswapV4LPSplitHook` that seeds a Uniswap V4 buyback pool from a
project's reserved tokens **without ever cashing out**, and lets **anyone** re-range the position as
the corridor moves. It reuses the existing corridor math, accumulation, and fee routing. Two things
change versus the current hook:

1. **No cash-out, ever.** `deployPool` mints a single-sided position from accumulated **project tokens
   only**. The bid side is not bought with a cash-out; it accrues organically from trading.
2. **Permissionless rebalance.** `rebalanceLiquidity` becomes callable by anyone (a keeper), guarded by
   a spot-vs-oracle-TWAP check and a drift threshold, so the position stays inside `[floor, ceiling]`
   without owner intervention.

## Motivation

The current hook funds the terminal-token side of a two-sided position by cashing out part of the
accumulated project tokens through the bonding curve. That cash-out:

- Drains the project's surplus into the pool.
- Carries bonding-curve slippage, the cash-out tax/fee, and a surplus dependency.
- Is the entire source of the convexity `JBMultiTerminal_UnderMin` class of bug (see
  `fix/deploypool-convex-cashout-floor`): the funding cash-out's slippage floor is derived from the
  cash-out rate, which behaves badly for small accumulations on convex (taxed) curves.

Removing the cash-out removes all of that. The bonding curve is already the canonical redemption floor
for holders (they can cash out any time), so the AMM does not need to *buy* its own bid side — it only
needs to offer the token for sale, and let real buyers supply the terminal tokens that become the bid.

Making rebalance permissionless addresses a real gap: `[floor, ceiling]` drifts (ceiling rises as the
issuance weight decays; floor rises as surplus grows relative to supply), and today only the owner can
re-range. A permissionless, guarded rebalance lets a keeper keep the position productive.

## Non-goals

- Not a replacement for the two-sided hook. Both ship; a project picks one when routing its reserved
  split. The audited two-sided contract is left untouched.
- No keeper bounty / active incentive economics (rejected during design — added extraction surface).
- No change to the fee-routing model or the accumulation model.

## Corridor (unchanged)

The position range is always `[cash-out floor, issuance ceiling]`, both derived from **protocol state**,
not from the AMM spot price:

- **Floor** = the cash-out (redemption) price = `surplus / supply` through the bonding curve, via the
  existing `JBUniswapV4LPSplitHookMath` corridor helpers.
- **Ceiling** = the issuance price = `1 / issuance weight`.

Spot never affects these bounds. It enters only through Uniswap's mint mechanics (see Rebalance).

## Position shape

A **single** concentrated position, matching the current hook's shape — but seeded single-sided and
never cash-out-funded. Its steady-state range is the full `[floor, ceiling]` corridor (smooth liquidity
across the whole corridor); at seed it occupies only the ask sub-range above the current spot
(`[max(spot, floor), ceiling]`), and grows to span the corridor as trading + rebalances build the bid
side. It is always one position (not separate legs).

Uniswap concentrated-liquidity fact this design leans on: a position `[Pa, Pb]` at spot `Pc` holds only
the "ask" asset when `Pc <= Pa` (spot at/below the range's bottom), only the "bid" asset when
`Pc >= Pb`, and a spot-determined mix in between.

## deployPool — single-sided seed, no cash-out

**Primary path (pool pre-initialized — the revnet norm).** For revnets (and most buyback-pool
projects), the Uniswap pool is created and initialized *before* the LP split hook ever allocates, and
its initial price is the project's **initial issuance rate** `P0`. Since no liquidity existed yet, the
untraded spot is still `P0` at deploy time — a **mid-corridor** price (typically `floor < P0 <=
ceiling`, because the issuance ceiling rises above `P0` as the weight decays, and the cash-out floor
sits below the issuance price). The hook does NOT initialize or reprice the pool.

At a mid-corridor spot the hook cannot mint a full `[floor, ceiling]` position single-sided: the
below-spot part `[floor, P0]` would require terminal tokens the hook does not have (no cash-out), so it
would mint zero liquidity there. Therefore `deployPool`:

1. Auto-select the terminal token (unchanged: highest ETH-denominated value).
2. Read the pool's current spot `P` and compute the corridor `[floor, ceiling]` from protocol state.
3. **Mint one single-sided position from accumulated project tokens only, in `[max(P, floor), ceiling]`
   — the ask band above the current spot.** No `cashOutTokensOf`, no terminal-token side at seed, no
   surplus dependency, no Permit2-for-terminal-token, and none of the cash-out slippage/`UnderMin`
   surface. Because `ceiling` (current issuance) has risen above `P0` via weight decay, these asks
   undercut current minting — buyers take the discounted reserved tokens from the pool before minting.
4. Leftover project tokens beyond what the mint accepts stay in the accumulation ledger, folded into the
   next add/rebalance. Never burned.

The **floor side is not part of the seed.** The bid side toward the floor materializes later: as buyers
lift the price, filled asks accrue terminal tokens, and the first permissionless rebalance places those
as bids down toward the floor. "Spans `[floor, ceiling]`" is the rebalanced steady state, not the seed.

**Fallback (hook creates the pool).** If no pool exists yet, the hook initializes it at the **floor**
tick and mints the single-sided asks across the full `[floor, ceiling]` (spot at the bottom → all
project tokens). This is the only case where the hook sets the price; it is uncommon for revnets.

**Degenerate cases to handle:** if `P >= ceiling` (deployed so early that no decay has occurred, so the
pre-set spot equals/exceeds the current issuance ceiling), the ask band `[P, ceiling]` is empty or
inverted — defer (revert with a clear error / no-op) until decay opens a band, since asks at/above the
current ceiling are dead (arbitrage mints instead). If `P` is far ABOVE `ceiling` (an adversary
mis-initialized the pool), the seed still only ever deposits project-token asks above spot; it can never
be tricked into funding a terminal side, and the first TWAP-guarded rebalance re-centers it.

**Access:** unchanged from the current hook — owner / `SET_BUYBACK_POOL` until the issuance weight has
decayed to <= 10% of the accumulation-time weight, then permissionless (`_requireDeployOrAddAuth`).

## Organic two-sided evolution (no cash-out)

- Freshly seeded (spot at the pre-set `P0` = initial issuance rate, 100% project-token asks in
  `[P0, ceiling]`): **buys work, sells do not** — the pool has only asks, and everything below `P0` is
  empty. Sellers use the bonding curve (the always-on redemption floor).
- As buyers lift the price above `P0`, the position auto-converts: the terminal tokens buyers pay in are
  held below the moving spot as **bid** liquidity. After the first buys, sells work too.
- The first permissionless rebalance re-mints across the full `[floor, ceiling]` using the accrued
  terminal tokens, extending the bid side down toward the floor.
- Bid depth therefore **lags** and grows with cumulative buy volume. This is an accepted property: the
  bonding curve is the guaranteed floor; the in-pool bid is a demand-funded supplement, never a
  surplus-funded one.

## addLiquidity — single-sided top-ups

Post-deploy reserved inflow accumulates and is added to the existing position by `addLiquidity`
(unchanged access model). The add is single-sided project tokens placed above spot (asks); no cash-out.
If spot has risen, the add extends the ask side toward the ceiling. Same accumulation ledger + spendable
balance invariant as today.

## rebalanceLiquidity — permissionless, guarded

Anyone may call. Burns the position and re-mints across the fresh `[floor, ceiling]` at current spot;
the accrued terminal tokens become the bid side of the new position.

Guards:

1. **Spot-vs-TWAP (mandatory).** Reuse `_requireSpotNearTwap` (30-min oracle TWAP, max tick deviation).
   Because a single `[floor, ceiling]` position re-mints at the spot-determined ratio, a manipulated
   spot could otherwise let an attacker sandwich the burn+remint. This guard makes the permissionless
   call safe; it also reverts if the oracle TWAP has not warmed up.
2. **Drift threshold.** Only proceed if the target `[floor, ceiling]` ticks differ from the live
   position's ticks by more than a configured minimum. Prevents churning an already-correctly-ranged
   position (gas/fee griefing, and pointless re-mints).
3. **Contract-derived burn slippage floor.** The caller is untrusted, so the contract derives its own
   `decreaseAmountMin` values from a fresh pre-burn read (mirroring the remove-liquidity path's
   internal floor) rather than trusting caller-supplied mins. No caller-supplied minimums.

Leftover after a re-mint (one token over the spot ratio) is carried in the hook and folded into the
next rebalance/add. Never burned.

## Access-control summary

| Action | Current two-sided hook | This variant |
|---|---|---|
| `deployPool` | owner → permissionless at 10x weight decay | same |
| `addLiquidity` | owner → permissionless at 10x weight decay | same |
| `rebalanceLiquidity` | owner / `SET_BUYBACK_POOL`, always | **permissionless + TWAP + drift** |
| `collectAndRouteLPFees` | permissionless | same |
| `claimFeeTokensFor` | owner / `SET_BUYBACK_POOL` | same |

## Contract structure

- New contract `JBUniswapV4LPSplitHookSingleSided`, a sibling of `JBUniswapV4LPSplitHook`. The existing
  audited contract is not modified.
- Reuse `JBUniswapV4LPSplitHookMath` (corridor/tick math) and the same interfaces
  (`IJBSplitHook`, `IJBUniswapV4LPSplitHook`, permissions, terminal store).
- Shared internals to lift or factor: accumulation (`processSplitWith` / `_accumulateTokens`), fee
  routing (`collectAndRouteLPFees`, `claimFeeTokensFor`), spot-vs-TWAP guard, Permit2 helpers for the
  **project** token side, tick-bounds derivation. The deleted surface is the funding cash-out
  (`_fundTerminalTokenSide` and its slippage-floor logic) — this variant never calls it.
- A new deployer `JBUniswapV4LPSplitHookSingleSidedDeployer` mirroring the existing deployer, if the
  fixed-instance / clone pattern is retained.

## Testing plan

Unit (mock terminal/store, no RPC):
- **Primary path:** pool pre-initialized at a mid-corridor spot `P0` → `deployPool` mints asks-only in
  `[max(P0, floor), ceiling]`; assert 100% project tokens, no `cashOutTokensOf` call, surplus untouched.
- Fallback path: no pool exists → hook initializes at the floor and mints asks across `[floor, ceiling]`.
- Degenerate: `P0 >= ceiling` (no decay yet) → deploy defers with a clear error, no bad mint.
- Simulate buys → position accrues terminal tokens below spot (bids appear); assert two-sided after
  trading.
- Permissionless rebalance re-centers to a moved `[floor, ceiling]` using accrued terminal as the bid
  side; anyone can call.
- Drift threshold: a rebalance with an unchanged corridor reverts / no-ops.
- Spot-vs-TWAP: a rebalance with spot skewed off TWAP reverts.

Fork (real `JBMultiTerminal`/`JBTerminalStore`, mainnet fork like the existing fork suite):
- Launch a project (with a non-zero cash-out tax, to prove the cash-out path is genuinely gone),
  route reserved tokens to the hook, `deployPool` single-sided, simulate buys, permissionless
  `rebalanceLiquidity` succeeds and re-centers; a manipulated-spot rebalance reverts.
- Assert the project's surplus is **never** touched by the hook (no cash-out).

## Documented risks / notes

- **Thin early bid depth.** Sell-side liquidity lags buy volume; the bonding curve is the always-on
  floor in the meantime. Acceptable and intended.
- **Seed price is the pre-set initial issuance rate**, not something the hook controls (common case).
  The asks sit in `[P0, ceiling]` and undercut current minting as the ceiling decays upward; the floor
  side is served by the bonding curve until trading builds an in-pool bid. In the rare hook-creates-the-
  pool case the seed is at the floor (the floor is the redemption value, so early buys are not below
  fair).
- **Permissionless rebalance MEV.** Bounded by the spot-vs-TWAP deviation cap and the drift threshold,
  not zero. No cash-out means the rebalance cannot be steered into a bad cash-out (that surface is gone
  entirely).
- **Pre-existing pool at an extreme spot.** If an adversary creates the pool far outside `[floor,
  ceiling]` before deploy, the single-sided seed still only ever deposits project tokens (asks above
  spot); it cannot be tricked into buying a terminal-token side. Worst case is asks placed at a poor
  range until the first rebalance re-centers under the TWAP guard.

## Open questions for the plan phase

- Exact drift-threshold unit (tick delta vs percentage of range) and default.
- Whether `addLiquidity` and `rebalanceLiquidity` share a single internal re-range routine.
- Whether to also expose a permissionless-after-decay gate on `rebalanceLiquidity` in addition to the
  TWAP+drift guards, or rely on the guards alone (current design: guards alone, fully permissionless).
