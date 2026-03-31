# Audit Instructions

This repo turns reserved project tokens into a Uniswap V4 LP position. Audit it as a treasury-management hook with meaningful external-call, pricing, and lifecycle risk.

## Objective

Find issues that:
- misprice or misbound the LP position relative to Juicebox economics
- let callers extract value during deployment, fee collection, rebalancing, or fee claiming
- burn, route, or claim the wrong project or terminal-token amounts
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

## System Model

Lifecycle:
- before pool deployment, reserved project tokens accumulate in the hook
- `deployPool(...)` creates or joins a V4 pool and mints one managed LP position
- after deployment, later reserved distributions are burned rather than added to the LP
- fees can be collected, split between the project and fee project, and later claimed
- the position can be rebalanced as issuance and cash-out conditions change

## Critical Invariants

1. Accumulation is conserved
Pre-deployment reserved tokens must either remain accumulated or be consumed exactly once during pool creation.

2. LP bounds reflect intended economics
The selected tick range and initial price must stay within the project’s intended issuance and cash-out envelope.

3. Post-deployment token handling is exact
After a pool exists, additional reserved-token inflow must not silently accumulate, dilute LP ownership, or become stranded.

4. Fee routing is complete
Collected LP fees must be distributed, tracked, or burned exactly according to the configured fee split.

5. Fee claims are recoverable and exact
`claimableFeeTokens` and `claimableFeeCredits` must match what the hook actually owes and must not be double-claimable.

6. Clone initialization is one-shot
No caller should be able to reinitialize or repurpose a deployed clone.

## Threat Model

Prioritize:
- reentrancy during deploy, collect, rebalance, and fee-claim paths
- stale `tokenIdOf` or position metadata
- incorrect fee-project self-routing
- boundary inversion in tick math
- permissionless deployment after 10x weight decay
- one-project or one-terminal assumptions leaking into another project’s state

## Build And Verification

Standard workflow:
- `npm install`
- `forge build`
- `forge test`

Current tests focus on:
- accumulation and deployment stages
- fee routing and fee claiming
- reentrancy
- tick-bound and position regressions
- invariant coverage

Good findings here show treasury value leakage, incorrect LP geometry, incorrect fee accounting, or lifecycle state that becomes trusted after the underlying position has changed.
