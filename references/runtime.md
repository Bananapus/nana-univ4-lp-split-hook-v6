# UniV4 LP Split Hook Runtime

## Core Roles

- [`src/JBUniswapV4LPSplitHook.sol`](../src/JBUniswapV4LPSplitHook.sol) accumulates reserved tokens, deploys the V4 position, manages fee collection, and rebalances liquidity.
- [`src/JBUniswapV4LPSplitHookDeployer.sol`](../src/JBUniswapV4LPSplitHookDeployer.sol) deploys clones and registers them in the address registry.

## Lifecycle

1. Reserved-token splits accumulate project tokens before a pool exists.
2. A pool is deployed for a chosen terminal token and bounded by project issuance and cash-out economics.
3. After deployment, newly received reserved tokens keep accumulating; `addLiquidity` converts them into more liquidity (top-up, or — on corridor drift — burn the stale position and re-mint a single fresh one, under an oracle-TWAP deviation guard), and fees can be collected from the single active position or the position rebalanced over time. The hook never burns project tokens.

## High-Risk Areas

- Pool deployment math: issuance and cash-out rates define the initial liquidity shape.
- Stage transition: pre-deploy uses `deployPool` to consume accumulation; post-deploy uses `addLiquidity` (top-up/re-range, TWAP-guarded). Accumulation is the single inflow sink in both phases.
- `addLiquidity` add path: TWAP-deviation guard, force-direct bonding-curve cash-out, and top-up-vs-re-range selection define how new liquidity is added safely.
- Fee routing: the terminal-token side of collected fees is split across fee project and project balance; the project-token side is carried back into the accumulation ledger (never burned).
- Rebalancing: position teardown and re-minting can change treasury exposure materially.

## Tests To Trust First

- [`test/AccumulationStageTest.t.sol`](../test/AccumulationStageTest.t.sol) and [`test/DeploymentStageTest.t.sol`](../test/DeploymentStageTest.t.sol) for lifecycle behavior.
- [`test/FeeRoutingTest.t.sol`](../test/FeeRoutingTest.t.sol) for fee behavior.
- [`test/RebalanceTest.t.sol`](../test/RebalanceTest.t.sol) for position updates.
- [`test/Fork.t.sol`](../test/Fork.t.sol), [`test/SecurityTest.t.sol`](../test/SecurityTest.t.sol), [`test/ReentrancyTest.t.sol`](../test/ReentrancyTest.t.sol), and [`test/SplitHookRegressions.t.sol`](../test/SplitHookRegressions.t.sol) for broader safety.
- [`test/regression/`](../test/regression/) for edge-case unit tests (zero-rate fallback, tokenId resolution, price/tick/bounds edge cases).
- [`test/fork/`](../test/fork/) for fork tests and integration fork tests verifying cross-scenario interactions.
