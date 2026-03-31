# Architecture

## Purpose

`univ4-lp-split-hook-v6` turns reserved project tokens into treasury-owned Uniswap V4 liquidity. It first accumulates reserved tokens, then deploys a single concentrated LP position bounded by the project's issuance rate and cash-out rate, and later manages fee routing and rebalancing.

## Boundaries

- The hook owns LP lifecycle and fee routing.
- It depends on Juicebox for token issuance and cash-out economics.
- It depends on Uniswap V4 for pool state and position management.
- It is intentionally a split hook, not a generic trading engine.

## Main Components

| Component | Responsibility |
| --- | --- |
| `JBUniswapV4LPSplitHook` | Accumulation-stage storage, pool deployment, LP management, and fee routing |
| `JBUniswapV4LPSplitHookDeployer` | Clone factory and deterministic deployment helper |

## Runtime Model

```text
reserved-token split distributions
  -> accumulate project tokens before pool deployment
authorized deploy call
  -> computes economic bounds from issuance and cash-out rates
  -> cashes out the optimal fraction for terminal tokens
  -> deploys or uses the pool and mints the concentrated LP position
post-deployment
  -> new reserved tokens are burned to avoid LP dilution
  -> fees can be collected, routed, and positions rebalanced
```

## Critical Invariants

- The LP range is meant to stay inside the project's economic envelope, not free-float arbitrarily.
- The hook's behavior changes materially before and after deployment; stage awareness is part of correctness.
- Fee routing must distinguish terminal-token fees from project-token fees and handle them differently.
- A project and terminal-token pair should map to one deployed pool path for a given hook instance.

## Where Complexity Lives

- The hook combines Juicebox economics, Uniswap V4 position math, and staged local state.
- The "optimal cash-out amount" is easy to destabilize if pricing or tick-bound assumptions move.
- Rebalance logic is effectively a remove-collect-recompute-mint pipeline and should be reviewed as one unit.

## Dependencies

- `nana-core-v6` split-hook, controller, terminal, and pricing behavior
- Uniswap V4 PoolManager and PositionManager
- An oracle hook compatible with the selected pool configuration

## Safe Change Guide

- Re-check both deployment-stage and post-deployment behavior whenever modifying state layout.
- Price-bound math, optimal cash-out math, and rebalance logic should be reviewed together.
- If you change fee routing, inspect fee-project accounting and claim paths.
- Keep deployer assumptions aligned with address registry and deployment scripts.
- Small math changes here can alter treasury behavior materially even when tests still pass locally.
