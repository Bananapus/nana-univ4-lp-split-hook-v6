# UniV4 LP Split Hook Runtime

## Core roles

- [`src/JBUniswapV4LPSplitHook.sol`](../src/JBUniswapV4LPSplitHook.sol) accumulates reserved tokens, deploys the V4 position, manages fee collection, and rebalances liquidity.
- [`src/JBUniswapV4LPSplitHookDeployer.sol`](../src/JBUniswapV4LPSplitHookDeployer.sol) deploys clones and registers them in the address registry.

## Lifecycle

1. Reserved-token splits accumulate project tokens before a pool exists.
2. A pool is deployed for a chosen terminal token and bounded by project issuance and cash-out economics.
3. After deployment, newly received reserved tokens keep accumulating; `addLiquidity` folds them into the project's single position (burn the prior position and re-mint one adaptive position, under an oracle-TWAP deviation guard), and fees can be collected from the single active position or the position rebalanced over time. The hook never burns project tokens.

## High-risk areas

- Pool deployment math: issuance and cash-out rates define the initial liquidity shape.
- Stage transition: pre-deploy uses `deployPool` to consume accumulation; post-deploy uses `addLiquidity` (consolidate-and-re-mint, TWAP-guarded). Accumulation is the single inflow sink in both phases.
- `addLiquidity` add path: the TWAP-deviation guard and the consolidate-and-re-mint executor define how new liquidity is added safely. The hook never cashes out — any terminal-token (bid) side is funded only from the terminal the hook recovers by burning its own prior V4 position plus this project's own accumulated terminal-token fee ledger.
- Corridor floor: the floor tick is derived from the project's cash-out (redemption) price — surplus over supply — and is used only to place the tick. The hook never performs a cash-out.
- Fee routing: each side of collected fees (terminal-token and project-token) takes a best-effort `feeProjectId` cut; fee-token and fee-credit claims for the fee project stay reserved from LP principal; every non-cut remainder is carried into this project's own ledger — `accumulatedTerminalTokens` for the terminal-token side, `accumulatedProjectTokens` for the project-token side — never into the project's terminal, and never burned.
- Rebalancing: position teardown and re-minting can change treasury exposure materially.

## Tests to trust first

- [`test/AccumulationStageTest.t.sol`](../test/AccumulationStageTest.t.sol) and [`test/DeploymentStageTest.t.sol`](../test/DeploymentStageTest.t.sol) for lifecycle behavior.
- [`test/FeeRoutingTest.t.sol`](../test/FeeRoutingTest.t.sol) for fee behavior.
- [`test/RebalanceTest.t.sol`](../test/RebalanceTest.t.sol) for position updates.
- [`test/Fork.t.sol`](../test/Fork.t.sol), [`test/SecurityTest.t.sol`](../test/SecurityTest.t.sol), [`test/ReentrancyTest.t.sol`](../test/ReentrancyTest.t.sol), and [`test/SplitHookRegressions.t.sol`](../test/SplitHookRegressions.t.sol) for broader safety.
- [`test/regression/`](../test/regression/) for edge-case unit tests (zero-rate fallback, tokenId resolution, price/tick/bounds edge cases).
- [`test/fork/`](../test/fork/) for fork tests and integration fork tests verifying cross-scenario interactions.
