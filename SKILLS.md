# Juicebox UniV4 LP Split Hook

## Use This File For

- Use this file when the task involves LP split accumulation, pool deployment, fee routing, rebalancing, fee claiming, or concentrated-liquidity math around the V4 LP split hook.
- Start here, then open the hook or deployer contract depending on whether the issue is runtime position management or clone deployment and configuration.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and lifecycle model | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Runtime split-hook behavior | [`src/JBUniswapV4LPSplitHook.sol`](./src/JBUniswapV4LPSplitHook.sol) |
| Clone deployment behavior | [`src/JBUniswapV4LPSplitHookDeployer.sol`](./src/JBUniswapV4LPSplitHookDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Interfaces and V4 test scaffolding | [`src/interfaces/`](./src/interfaces/), [`test/TestBaseV4.sol`](./test/TestBaseV4.sol) |
| Deployment-stage, rebalancing, fee-routing, fee-claim, or regression coverage | [`test/DeploymentStageTest.t.sol`](./test/DeploymentStageTest.t.sol), [`test/RebalanceTest.t.sol`](./test/RebalanceTest.t.sol), [`test/FeeRoutingTest.t.sol`](./test/FeeRoutingTest.t.sol), [`test/regression/`](./test/regression/) |

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
- Treat pool deployment, rebalance logic, fee routing, and fee claiming as high-risk. Small math or accounting changes there alter economic behavior directly.
- `deployPool(...)` is usually gated by `SET_BUYBACK_POOL`, but becomes permissionless once the current ruleset weight has decayed to 1/10th or less of `initialWeightOf[projectId]`.
- This hook supports only one deployed terminal-token pool per project because split contexts do not carry terminal-token identity.
- Fee accounting can end up as ERC-20 fee tokens or fee credits depending on whether the fee project has an ERC-20 deployed. Check both `claimableFeeTokens` and `claimableFeeCredits`.
- When a task touches oracle or V4 hook assumptions, confirm whether the source of truth is this repo or `univ4-router-v6`.
- Once a pool is deployed for a project-token pair, treat that deployment as the switch from accumulation mode into burn-and-manage mode unless the code clearly says otherwise.
