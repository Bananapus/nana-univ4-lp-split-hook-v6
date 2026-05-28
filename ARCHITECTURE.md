# Architecture

## Purpose

`univ4-lp-split-hook-v6` turns reserved project tokens into treasury-owned Uniswap V4 liquidity. It accumulates reserved tokens, deploys a single concentrated LP position bounded by Juicebox economics, and later manages fees and rebalancing.

## System Overview

`JBUniswapV4LPSplitHook` is a staged split hook: before LP deployment it accumulates reserved tokens; after deployment it keeps accumulating later inflows and grows the position via `addLiquidity`, while managing fee collection and the rebalance lifecycle. `JBUniswapV4LPSplitHookDeployer` creates deterministic instances for projects that want this liquidity policy.

## Core Invariants

- The LP range should stay inside the project's economic envelope rather than float arbitrarily.
- The hook has materially different pre-deployment and post-deployment behavior.
- Fee routing must distinguish project-token fees from terminal-token fees.
- A project's accumulation ledger is the single sink for reserved-token inflows both before AND after pool deployment; the hook never burns. Pre-deploy, `deployPool` consumes the accumulation; post-deploy, `addLiquidity` does.
- A hook instance should map a project and terminal-token pair to one pool path.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBUniswapV4LPSplitHook` | Accumulation, pool deployment, LP management, fee routing, rebalancing | Runtime core |
| `JBUniswapV4LPSplitHookDeployer` | Deterministic clone deployment with immutable implementation and one-shot V4 wiring | Keeps deployer address stable across chains |

## Trust Boundaries

- Reserved-token issuance and cash-out economics come from `nana-core-v6`.
- Pool and position behavior come from Uniswap V4.
- Oracle behavior comes from the selected compatible hook configuration, usually `univ4-router-v6`.

## Critical Flows

### Accumulate, Deploy, Manage

```text
reserved-token split distributions
  -> accumulate project tokens before pool deployment
authorized deploy call
  -> computes price bounds from issuance and cash-out economics
  -> cashes out the optimal fraction for terminal tokens
  -> deploys or uses the target pool and mints the concentrated LP position
post-deployment
  -> new reserved tokens keep accumulating; `addLiquidity` converts them into more liquidity (top-up while the live corridor matches the active position, else re-range into a new position), validating the pool spot price against the oracle TWAP and cashing out the optimal fraction directly through the bonding curve
  -> fees can be collected (from the active and all retired positions) and the position can be rebalanced
```

## Accounting Model

The hook owns local staging and LP-management state. It does not own reserved-token issuance or terminal accounting.

It also owns claim segregation for routed LP fees. Outstanding fee-token claims are tracked separately so the hook's accumulation and LP-funding paths do not consume fee assets being held for beneficiaries.

## Security Model

- The main risks are price-bound math, optimal cash-out math, and staged behavior drift.
- Rebalance is effectively a remove-collect-recompute-mint pipeline and should be reviewed as one unit.
- Pool initialization race conditions matter on first deployment.
- Accumulation/LP-funding logic, fee routing, and outstanding-claim accounting are coupled.

## Safe Change Guide

- Review pre-deployment and post-deployment behavior together whenever state layout changes.
- Keep price-bound math, optimal cash-out math, and rebalance logic synchronized.
- If you change fee routing or accumulation/leftover-carry behavior, re-check outstanding fee-token claim segregation and in-flight fee routing assumptions.
- If fee routing changes, inspect downstream fee-project behavior and claim paths.
- Keep deployer assumptions aligned with the address registry, deployment scripts, immutable implementation address, and one-shot V4 constants used to preserve the deployer address across chains.

## Canonical Checks

- staged accumulation, deployment, and rebalance lifecycle:
  `test/IntegrationLifecycle.t.sol`
- fee-token claim segregation against the accumulation / LP-funding paths:
  `test/regression/FeeTokenTerminalAccountingRegression.t.sol`
- split-hook staging and accounting invariants:
  `test/invariant/LPSplitHookInvariant.t.sol`
- edge-case unit tests (zero-rate fallback, tokenId resolution, price/tick/bounds edge cases):
  `test/regression/`
- fork tests (full JB core deployment per scenario):
  `test/fork/`
- integration fork tests (cross-scenario interaction chains):
  `test/fork/Integration_MultiProjectDeploy.t.sol`, `test/fork/Integration_HighReservedZeroTax.t.sol`, `test/fork/Integration_BurnPathCrossProject.t.sol`, `test/fork/Integration_RebalanceChangedRuleset.t.sol`

## Source Map

- `src/JBUniswapV4LPSplitHook.sol`
- `src/JBUniswapV4LPSplitHookDeployer.sol`
- `test/IntegrationLifecycle.t.sol`
- `test/regression/FeeTokenTerminalAccountingRegression.t.sol`
- `test/invariant/LPSplitHookInvariant.t.sol`
