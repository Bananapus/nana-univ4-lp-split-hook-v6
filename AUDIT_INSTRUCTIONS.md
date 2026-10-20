# Audit Instructions

This repo turns reserved project tokens into Uniswap V4 liquidity held as at most two single-sided positions per project (an ask and a bid). Audit it as a treasury-management hook with meaningful external-call, pricing, and lifecycle risk.

## Audit objective

There is a billion dollars of well-meaning projects' money in the Juicebox Money Engine, growing exponentially. Your job is to hack it before anyone else. Whoever hacks it first saves/steals the money, and you are obsessed with being this winner, while also being a steward of the protocol and wanting it to keep growing safely.

Suggestions of where to look:

- misprice or misbound the LP position relative to Juicebox economics
- let callers extract value during deployment, a recycle, fee collection, or fee claiming
- accumulate, route, add-as-liquidity, or claim the wrong project or terminal-token amounts
- time a recycle (reserved distribution and `addLiquidity` are permissionless) around a manipulated spot inside the TWAP band to re-center the ask and bid at a bad price, or make either position quote outside the corridor
- make a recycle burn a position for less than its principal, or mint a position that is not single-sided
- break clone initialization or redeploy safety
- leave stale position or fee-accounting state that later calls trust incorrectly

## Scope

In scope:

- `src/JBUniswapV4LPSplitHook.sol`
- `src/JBUniswapV4LPSplitHookDeployer.sol`
- `src/interfaces/`
- deployment scripts in `script/`

Key integrations:

- `nana-core-v6`
- `univ4-router-v6`

## Start here

1. `src/JBUniswapV4LPSplitHook.sol`
2. `src/JBUniswapV4LPSplitHookDeployer.sol`

## Security model

Lifecycle:

- before pool deployment, reserved project tokens accumulate in the hook
- `deployPool(...)` (or the inline attempt on a distribution) creates or joins a V4 pool and runs the first recycle, which mints the ask
- every later recycle (inline on each reserved distribution, or permissionless `addLiquidity(...)` at any time) runs under a 30-minute spot-vs-TWAP guard (200 ticks): for each live position, collect and route fees, burn with a contract-derived slippage floor, credit recovered principal; claim credits; recompute the corridor; mint the ask from the whole project ledger on `[max(spotCeil, floor), ceiling]` (`spotCeil` = first aligned tick at or above the spot) and the bid from the whole terminal ledger on `[floor, min(spotFloor, ceiling)]` (in token0/token1 tick terms). If neither side mints the recycle reverts `NoDeployableLiquidityAtSpot`. The hook never cashes out and never burns project tokens.
- fees can be collected from both positions, routed, and claimed through separate accounting paths

## Roles and privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Project owner or delegate | Claim tracked fee value | Must hold `SET_BUYBACK_POOL` |
| Permissionless caller | Deploy a fresh clone, deploy the pool, recycle (`addLiquidity` or reserved distribution), collect fees | Accumulation threshold, spot-vs-TWAP guard, corridor caps, contract-derived burn floor |
| Hook contract | Hold tokens, manage LP state, and route fees | Must preserve treasury value and claim segregation |

## Integration assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-core-v6` | Reserved-token issuance and cash-out economics match the hook's pricing model | LP bounds and cash-out math drift |
| `univ4-router-v6` or selected oracle hook | Market-side assumptions stay coherent enough for pool behavior | Pool behavior and price reasoning drift |
| Uniswap V4 managers | Position and liquidity operations behave as expected | Burn, mint, collect, or recycle paths break |

## Critical invariants

1. One project path transitions from accumulation mode to deployed-LP mode exactly once.
2. Tick bounds remain valid and inside the intended economic envelope.
3. Fee-token claims stay segregated from freely spendable or routable balances.
4. A recycle must not destroy tracked fee claims or silently mint value.
5. At most two positions exist per project and terminal token; the ask never sits below the cash-out floor and the bid never above the issuance ceiling; both are single-sided with the spot in a gap of at most one spacing.
6. Clone initialization must not allow configuration drift after deployment.
7. A recycle never runs at a spot beyond the TWAP bound (it reverts when spot deviates from the oracle TWAP beyond 200 ticks, or the TWAP is unavailable), and the hook never cashes out.

## Attack surfaces

- first pool deployment and outsider initialization
- price-bound math and the ask/bid range geometry in `_recycle`
- the collect, burn, recompute, mint recycle flow across two positions (`_recycle`, `_retirePosition`, `_mintSingleSided`)
- best-effort inline automation (`_attemptAutomation`, `executeAutomationFor`) and its rollback boundary
- fee-token and fee-credit bookkeeping
- clone initialization and project-path identity

## Accepted risks or behaviors

- Some fee collection paths are intentionally permissionless.
- Newly received reserved tokens are intentionally re-accumulated after deployment and later added as liquidity via `addLiquidity`. The hook never burns; supply-reducing burns are a protocol-layer split-routing decision (`{projectId:0, hook:0, beneficiary:0xdead}`).
- Recycles are permissionless at any time, so a caller controls their timing, down to the block. A manipulation inside the TWAP band can shift the gap between the positions by up to the TWAP tolerance; the one-spacing gap means the hook never quotes at the exact spot, and the corridor caps bound both positions.
- A recycle can revert (below threshold, TWAP unavailable or deviated, nothing deployable at spot) and is expected to be retried; the inline attempt reports failures with `LiquidityAutomationFailed` and never reverts intake.

## Verification

- `npm install`
- `forge build`
- `forge test`
- the real-swap two-position lifecycle: `forge test --match-path test/fork/Integration_SingleSidedRevnet.t.sol`
