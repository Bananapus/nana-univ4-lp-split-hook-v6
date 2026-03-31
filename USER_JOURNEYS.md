# User Journeys

## Who This Repo Serves

- project teams turning reserved tokens into protocol-native liquidity
- operators deploying, collecting, and rebalancing a bounded UniV4 position
- integrators who need treasury-aware LP behavior rather than generic LP automation

## Journey 1: Accumulate Reserved Tokens Before A Pool Exists

**Starting state:** the hook is configured as a reserved-token split on a project.

**Success:** reserved project tokens accumulate until the team is ready to deploy the LP position.

**Flow**
1. Install the hook as a reserved-token split recipient in the project's ruleset.
2. Each reserved-token distribution sends project tokens into the hook.
3. The hook tracks the accumulated balance per project before any pool exists.
4. No LP is deployed yet, so the hook is just building inventory for the eventual position.

## Journey 2: Deploy The Initial UniV4 LP Position

**Starting state:** enough project tokens have accumulated and the operator is ready to choose the terminal-token pair for this hook instance.

**Success:** the project now has a concentrated liquidity position whose bounds are derived from Juicebox economics rather than arbitrary manual ticks.

**Flow**
1. Call `deployPool(...)` for the project and terminal token.
2. The hook derives the lower and upper ticks from the project's cash-out and issuance rates.
3. It cashes out the required fraction of project tokens for terminal tokens.
4. It initializes the pool if needed and mints the concentrated LP position.
5. From this point forward, the hook's identity includes that chosen project-token and terminal-token path.

## Journey 3: Operate The Position After Deployment

**Starting state:** the pool has been deployed.

**Success:** fees are collected and routed correctly, and the LP range can be refreshed when economics move.

**Flow**
1. Collect and route LP fees with `collectAndRouteLPFees(...)`.
2. Send the configured fee share to the fee project and the remainder back to the original project.
3. Burn any project-token fee residue the design says should not remain in circulation.
4. Rebalance with `rebalanceLiquidity(...)` when the project's economics have moved enough to justify a new range.
5. After deployment, newly received reserved tokens are burned instead of added pro rata, preventing LP dilution.

## Hand-Offs

- Use [univ4-router-v6](../univ4-router-v6/USER_JOURNEYS.md) to understand the oracle and routing assumptions this hook depends on.
