# Audit Instructions

This repo turns reserved project tokens into a Uniswap V4 LP position. Audit it as a treasury-management hook with meaningful external-call, pricing, and lifecycle risk.

## Audit Objective

There is a billion dollars of well-meaning projects' money in the Juicebox Money Engine, growing exponentially. Your job is to hack it before anyone else. Whoever hacks it first saves/steals the money, and you are obsessed with being this winner, while also being a steward of the protocol and wanting it to keep growing safely.

Suggestions of where to look:

- misprice or misbound the LP position relative to Juicebox economics
- let callers extract value during deployment, fee collection, rebalancing, or fee claiming
- accumulate, route, add-as-liquidity, or claim the wrong project or terminal-token amounts
- manipulate the pool price to make `addLiquidity` mint at a bad ratio, or route its funding cash-out through the AMM
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

## Start Here

1. `src/JBUniswapV4LPSplitHook.sol`
2. `src/JBUniswapV4LPSplitHookDeployer.sol`

## Security Model

Lifecycle:

- before pool deployment, reserved project tokens accumulate in the hook
- `deployPool(...)` creates or joins a V4 pool and mints one managed LP position
- after deployment, later reserved tokens keep accumulating; `addLiquidity(...)` converts them into more liquidity (top-up or re-range), guarded by an oracle-TWAP deviation check and a force-direct bonding-curve cash-out. The hook never burns.
- fees can be collected from the single active position, routed, and claimed through separate accounting paths

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Project owner or delegate | Deploy pool, rebalance, and claim tracked fee value | Must hold `SET_BUYBACK_POOL` or meet the documented decay exception |
| Permissionless caller | Deploy a fresh clone or trigger some fee collection paths | Must stay inside lifecycle and accounting bounds |
| Hook contract | Hold tokens, manage LP state, and route fees | Must preserve treasury value and claim segregation |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-core-v6` | Reserved-token issuance and cash-out economics match the hook's pricing model | LP bounds and cash-out math drift |
| `univ4-router-v6` or selected oracle hook | Market-side assumptions stay coherent enough for pool behavior | Pool behavior and price reasoning drift |
| Uniswap V4 managers | Position and liquidity operations behave as expected | Burn, mint, collect, or rebalance paths break |

## Critical Invariants

1. One project path transitions from accumulation mode to deployed-LP mode exactly once.
2. Tick bounds remain valid and inside the intended economic envelope.
3. Fee-token claims stay segregated from freely spendable or routable balances.
4. Rebalance must not destroy tracked fee claims or silently mint value.
5. Clone initialization must not allow configuration drift after deployment.
6. `addLiquidity` never adds at a manipulated ratio: it reverts when spot deviates from the oracle TWAP beyond the bound (or the TWAP is unavailable), and cashes out only directly through the bonding curve, never through the AMM it feeds.

## Attack Surfaces

- first pool deployment and outsider initialization
- price-bound and optimal-cash-out math
- remove-collect-recompute-mint rebalance flow
- fee-token and fee-credit bookkeeping
- clone initialization and project-path identity

## Accepted Risks Or Behaviors

- Some fee collection paths are intentionally permissionless.
- Newly received reserved tokens are intentionally re-accumulated after deployment and later added as liquidity via `addLiquidity`. The hook never burns; supply-reducing burns are a protocol-layer split-routing decision (`{projectId:0, hook:0, beneficiary:0xdead}`).
- `addLiquidity` is permissionless once the ruleset weight has decayed 10x; it can revert (TWAP unavailable / deviation) and is expected to be retried as the oracle warms up or the price settles.

## Verification

- `npm install`
- `forge build`
- `forge test`
