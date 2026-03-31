# UniV4 LP Split Hook Runtime

## Core Roles

- [`src/JBUniswapV4LPSplitHook.sol`](../src/JBUniswapV4LPSplitHook.sol) accumulates reserved tokens, deploys the V4 position, manages fee collection, and rebalances liquidity.
- [`src/JBUniswapV4LPSplitHookDeployer.sol`](../src/JBUniswapV4LPSplitHookDeployer.sol) deploys clones and registers them in the address registry.

## Lifecycle

1. Reserved-token splits accumulate project tokens before a pool exists.
2. A pool is deployed for a chosen terminal token and bounded by project issuance and cash-out economics.
3. After deployment, newly received reserved tokens are treated differently and fees can be collected or rebalanced over time.

## High-Risk Areas

- Pool deployment math: issuance and cash-out rates define the initial liquidity shape.
- Stage transition: accumulation mode and post-deployment behavior are intentionally different.
- Fee routing: collected fees are split across fee project, project balance, and burned project tokens.
- Rebalancing: position teardown and re-minting can change treasury exposure materially.

## Tests To Trust First

- [`test/AccumulationStageTest.t.sol`](../test/AccumulationStageTest.t.sol) and [`test/DeploymentStageTest.t.sol`](../test/DeploymentStageTest.t.sol) for lifecycle behavior.
- [`test/FeeRoutingTest.t.sol`](../test/FeeRoutingTest.t.sol) for fee behavior.
- [`test/RebalanceTest.t.sol`](../test/RebalanceTest.t.sol) for position updates.
- [`test/Fork.t.sol`](../test/Fork.t.sol), [`test/invariant/`](../test/invariant/), and [`test/regression/`](../test/regression/) for broader safety.
