# Juicebox UniV4 LP Split Hook

## Use This File For

- Use this file when the task involves LP split accumulation, pool deployment, fee routing, rebalancing, or concentrated-liquidity math around the V4 LP split hook.
- Start here, then open the hook or deployer contract depending on whether the issue is runtime position management or clone deployment and configuration.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and lifecycle model | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Runtime split-hook behavior | [`src/JBUniswapV4LPSplitHook.sol`](./src/JBUniswapV4LPSplitHook.sol) |
| Clone deployment behavior | [`src/JBUniswapV4LPSplitHookDeployer.sol`](./src/JBUniswapV4LPSplitHookDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Interfaces and V4 test scaffolding | [`src/interfaces/`](./src/interfaces/), [`test/TestBaseV4.sol`](./test/TestBaseV4.sol) |
| Deployment-stage, rebalancing, fee-routing, or regression coverage | [`test/DeploymentStageTest.t.sol`](./test/DeploymentStageTest.t.sol), [`test/RebalanceTest.t.sol`](./test/RebalanceTest.t.sol), [`test/FeeRoutingTest.t.sol`](./test/FeeRoutingTest.t.sol), [`test/regression/`](./test/regression/) |

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

- Open [`references/runtime.md`](./references/runtime.md) when you need the lifecycle stages, pool-deployment math, or the main invariants around accumulation, burn mode, and fee routing.
- Open [`references/operations.md`](./references/operations.md) when you need deployer behavior, permission gates, test breadcrumbs, or the common stale assumptions around rebalancing and terminal-token choice.

## Working Rules

- Start in [`src/JBUniswapV4LPSplitHook.sol`](./src/JBUniswapV4LPSplitHook.sol) for runtime behavior, but check the deployer when the problem might be clone config or provenance.
- Treat pool deployment, rebalance logic, and fee routing as high-risk. Small math changes there alter economic behavior directly.
- When a task touches oracle or V4 hook assumptions, confirm whether the source of truth is this repo or `univ4-router-v6`.
- Once a pool is deployed for a project-token pair, treat that identity as sticky unless the code clearly says otherwise.
