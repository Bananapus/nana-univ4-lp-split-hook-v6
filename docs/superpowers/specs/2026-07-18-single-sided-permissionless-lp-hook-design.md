# Single-sided, cash-out-free, permissionless-rebalance LP split hook — design

**Date:** 2026-07-18
**Status:** Draft for review
**Working name:** `JBUniswapV4LPSplitHookSingleSided`

## Summary

Changes `JBUniswapV4LPSplitHook` **in place** so it seeds a Uniswap V4 buyback pool from a project's
reserved tokens **without ever cashing out**, and lets **anyone** re-range the position as the corridor
moves. This REPLACES the contract's cash-out-funded two-sided design (and removes the code it depended
on). It keeps the existing corridor math, accumulation, and fee routing. Two things change:

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

- No keeper bounty / active incentive economics (rejected during design — added extraction surface).
- No change to the fee-routing model or the accumulation model.
- Not preserving the cash-out-funded two-sided path — it is removed. (Consequence: PR #171's cash-out
  floor fix becomes moot for this contract; see the plan's supersession note. This is an in-place
  redesign requiring a redeploy.)

## Corridor (unchanged)

The position range is always `[cash-out floor, issuance ceiling]`, both derived from **protocol state**,
not from the AMM spot price:

- **Floor** = the cash-out (redemption) price = `surplus / supply` through the bonding curve, via the
  existing `JBUniswapV4LPSplitHookMath` corridor helpers.
- **Ceiling** = the issuance price = `1 / issuance weight`.

Spot never affects these bounds. It enters only through Uniswap's mint mechanics (see Rebalance).

## Position shape — one adaptive position with terminal-driven bid depth

Always **exactly one** position, never separate legs. Its upper bound is always the **ceiling**; its
lower bound `X` is **adaptive**, set so the position absorbs everything the hook holds:

- **Asks are anchored to ALL project tokens.** The liquidity `L` is chosen so the ask leg
  `[spot, ceiling]` deploys the hook's entire project-token balance up to the ceiling. Asks are never
  starved by a scarce terminal balance.
- **The lower bound `X` is a function of how much terminal the hook holds.** Solve
  `sqrt(X) = sqrt(spot) − T/L`, so the terminal balance `T` exactly fills the bid leg `[X, spot]` at the
  same `L`. Consequences:
  - `T = 0` → `X = spot` → asks-only (this is the fresh-deploy case).
  - small `T` → `X` just below spot → a thin, shallow bid.
  - larger `T` → `X` slides deeper toward the floor.
- **Clamp `X ≥ floor`.** Never bid below the redemption floor (such bids are economically dead — a
  seller would cash out instead). If `T` is so abundant that `X` would fall below the floor, pin
  `X = floor` and **route the excess terminal to the project's balance** (reuse the fee/route plumbing)
  rather than strand it.

This single adaptive range replaces the earlier "fixed `[floor, ceiling]` vs asks-only
`[max(spot, floor), ceiling]`" choice: it deploys all project as asks AND all affordable terminal as a
bid whose depth scales with terminal — one position, no leftover in the normal case, and a real AMM
sell venue as soon as any terminal has accrued (on top of the always-available bonding-curve floor).

Closed form uses the `LiquidityAmounts`/tick math already in the repo. Applied uniformly by the
consolidate routine to deploy, add, and rebalance.

Uniswap fact this leans on: a position `[Pa, Pb]` at spot `Pc` holds only the "ask" asset when
`Pc <= Pa`, only the "bid" asset when `Pc >= Pb`, and a spot-determined mix in between — so anchoring
`L` to the project (ask) side and solving `X` for the terminal (bid) side deploys both without leftover.

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

**Access + economic gate (permissionless):** `deployPool` and `addLiquidity` are **fully permissionless**
— the old owner-until-10×-weight-decay gate (`_requireDeployOrAddAuth`) is REMOVED. In its place, both
ask-minting paths revert when the **current AMM spot ≥ the current issuance price** (`ceiling`):
`JBUniswapV4LPSplitHook_SpotAboveCeilingAtSeed`. This is the precise economic version of the old proxy —
at genesis `spot == issuance` (blocked), and only once the weight decays does the issuance price rise
above the pre-set spot, opening a live corridor where asks below the ceiling are fillable. It also means
nobody can seed/extend the pool at or above the mint price (where asks would be dead and the price could
be griefed). The hook-initializes-at-floor fallback trivially passes (`floor < ceiling`). If an
adversary mis-initialized the pool far above the ceiling, this guard simply blocks deploy until arbitrage
/ decay brings spot back below issuance. `rebalanceLiquidity` keeps its own TWAP + drift guards (it
re-ranges an existing position); it may apply the same spot-below-issuance check.

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
| `deployPool` | owner → permissionless at 10x weight decay | **permissionless; reverts if spot ≥ issuance price** |
| `addLiquidity` | owner → permissionless at 10x weight decay | **permissionless; reverts if spot ≥ issuance price** |
| `rebalanceLiquidity` | owner / `SET_BUYBACK_POOL`, always | **permissionless + TWAP + drift** |
| `collectAndRouteLPFees` | permissionless | same |
| `claimFeeTokensFor` | owner / `SET_BUYBACK_POOL` | same |

## Contract structure

- **Edit `JBUniswapV4LPSplitHook` in place** (no sibling). The existing deployer, interface, and
  `JBUniswapV4LPSplitHookMath` library are reused (the interface gains a couple of errors/an event).
- Kept: accumulation (`processSplitWith` / `_accumulateTokens`), fee routing (`collectAndRouteLPFees`,
  `claimFeeTokensFor`), spot-vs-TWAP guard, Permit2 helpers for the **project** token side, tick-bounds
  derivation.
- Deleted: the funding cash-out (`_fundTerminalTokenSide` and its slippage-floor logic) and every
  dependency that becomes unused once it is gone (cash-out slippage constants, `JBFees`/`JBCashOuts`
  usage, force-direct cash-out metadata, and — if no longer referenced — the sucker-registry wiring).
  Verify each with grep before removing.

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
