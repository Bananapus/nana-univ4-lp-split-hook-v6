# Audit Instructions

This repo turns reserved project tokens into a Uniswap V4 LP position. Audit it as a treasury-management hook with meaningful external-call, pricing, and lifecycle risk.

## Audit Objective

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

## Start Here

1. `src/JBUniswapV4LPSplitHook.sol`
2. `src/JBUniswapV4LPSplitHookDeployer.sol`

## Security Model

Lifecycle:
- before pool deployment, reserved project tokens accumulate in the hook
- `deployPool(...)` creates or joins a V4 pool and mints one managed LP position
- after deployment, later reserved distributions are burned rather than added to the LP
- fees can be collected, split between the project and fee project, and later claimed
- the position can be rebalanced as issuance and cash-out conditions change

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Project authority | Configure or trigger pool lifecycle actions | Must not repurpose another project's state |
| Hook clone | Hold reserved tokens and LP accounting state | Must be one-shot initialized and project-isolated |
| Fee claimant | Recover accrued fee entitlements | Must not double-claim or exceed tracked balances |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-core-v6` | Reserved-token flow and fee-project semantics match hook expectations | Treasury accounting drifts |
| `univ4-router-v6` | Pool and oracle assumptions stay coherent | LP geometry and pricing bounds become unsafe |

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

## Attack Surfaces

- pool deployment and first LP position creation
- fee collection, fee accounting, and fee claims
- rebalance and position metadata updates
- tick bound and price initialization math
- clone initialization and per-project state isolation

## Verification

- `npm install`
- `forge build`
- `forge test`
