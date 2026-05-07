# Juicebox UniV4 LP Split Hook

## Use This File For

- Use this file when the task involves LP split accumulation, pool deployment, fee routing, rebalancing, fee claiming, or concentrated-liquidity math around the V4 LP split hook.
- Start here, then decide whether the issue is still in accumulation mode, already in post-deployment burn-and-manage mode, or actually in clone/deployer setup.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and lifecycle model | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Runtime split-hook behavior | [`src/JBUniswapV4LPSplitHook.sol`](./src/JBUniswapV4LPSplitHook.sol) |
| Clone deployment behavior | [`src/JBUniswapV4LPSplitHookDeployer.sol`](./src/JBUniswapV4LPSplitHookDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Runtime and operational invariants | [`references/runtime.md`](./references/runtime.md), [`references/operations.md`](./references/operations.md) |
| Interfaces and V4 test scaffolding | [`src/interfaces/`](./src/interfaces/), [`test/TestBaseV4.sol`](./test/TestBaseV4.sol) |
| Lifecycle, fee-routing, and rebalancing coverage | [`test/AccumulationStageTest.t.sol`](./test/AccumulationStageTest.t.sol), [`test/DeploymentStageTest.t.sol`](./test/DeploymentStageTest.t.sol), [`test/FeeRoutingTest.t.sol`](./test/FeeRoutingTest.t.sol), [`test/RebalanceTest.t.sol`](./test/RebalanceTest.t.sol), [`test/IntegrationLifecycle.t.sol`](./test/IntegrationLifecycle.t.sol) |
| Security, deployment, and weight-decay edge cases | [`test/SecurityTest.t.sol`](./test/SecurityTest.t.sol), [`test/ReentrancyTest.t.sol`](./test/ReentrancyTest.t.sol), [`test/DeployerTest.t.sol`](./test/DeployerTest.t.sol), [`test/WeightDecayDeployTest.t.sol`](./test/WeightDecayDeployTest.t.sol), [`test/SplitHookRegressions.t.sol`](./test/SplitHookRegressions.t.sol), [`test/TestRegressionGaps.sol`](./test/TestRegressionGaps.sol) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Interfaces | [`src/interfaces/`](./src/interfaces/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Reserved-token split hook that accumulates Juicebox project tokens, deploys them into a Uniswap V4 concentrated-liquidity position derived from project economics, and routes resulting fees back into the project and fee project.

## Reference Files

- Open [`references/runtime.md`](./references/runtime.md) for lifecycle stages, pool-deployment math, and the main invariants around accumulation, burn mode, and fee routing.
- Open [`references/operations.md`](./references/operations.md) for deployer behavior, permission gates, test breadcrumbs, and common stale assumptions around rebalancing and terminal-token choice.

## Working Rules

- Start in [`src/JBUniswapV4LPSplitHook.sol`](./src/JBUniswapV4LPSplitHook.sol) for runtime behavior, but check the deployer when the problem might be clone config or provenance.
- Pool deployment is a one-way lifecycle transition. Once a project has a pool, assume the repo is in burn-and-manage mode unless the code proves otherwise.
- Treat pool deployment, rebalance logic, fee routing, and fee claiming as high-risk.
- `deployPool(...)` is usually gated by `SET_BUYBACK_POOL`, but becomes permissionless once the current ruleset weight has decayed enough.
- This hook supports only one deployed terminal-token pool per project because split contexts do not carry terminal-token identity.
- Fee accounting can end up as ERC-20 fee tokens or fee credits depending on whether the fee project has an ERC-20 deployed.
- Rebalancing and fee-claim logic share accounting surfaces. Verify outstanding fee-token claims before changing token or routing assumptions.
- When a task touches oracle or V4 hook assumptions, confirm whether the source of truth is this repo or `univ4-router-v6`.
