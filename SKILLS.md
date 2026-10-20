# Juicebox UniV4 LP Split Hook

## Use this file for

- Use this file when the task involves LP split accumulation, pool deployment, the ask/bid recycle, fee routing, fee claiming, or concentrated-liquidity math around the V4 LP split hook.
- Start here, then decide whether the issue is still in pre-deploy accumulation, in post-deployment recycling (inline automation, `addLiquidity`, fee collection), or actually in clone/deployer setup.

## Read this next

| If you need... | Open this next |
|---|---|
| Repo overview and lifecycle model | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Runtime split-hook behavior | [`src/JBUniswapV4LPSplitHook.sol`](./src/JBUniswapV4LPSplitHook.sol) |
| Clone deployment behavior | [`src/JBUniswapV4LPSplitHookDeployer.sol`](./src/JBUniswapV4LPSplitHookDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Runtime and operational invariants | [`references/runtime.md`](./references/runtime.md), [`references/operations.md`](./references/operations.md) |
| Interfaces and V4 test scaffolding | [`src/interfaces/`](./src/interfaces/), [`test/TestBaseV4.sol`](./test/TestBaseV4.sol) |
| Lifecycle, fee-routing, and recycle coverage | [`test/AccumulationStageTest.t.sol`](./test/AccumulationStageTest.t.sol), [`test/DeploymentStageTest.t.sol`](./test/DeploymentStageTest.t.sol), [`test/FeeRoutingTest.t.sol`](./test/FeeRoutingTest.t.sol), [`test/DurableIntakeTest.t.sol`](./test/DurableIntakeTest.t.sol), [`test/IntegrationLifecycle.t.sol`](./test/IntegrationLifecycle.t.sol), [`test/fork/Integration_SingleSidedRevnet.t.sol`](./test/fork/Integration_SingleSidedRevnet.t.sol) (real-swap two-position lifecycle) |
| Security, deployment, and weight-decay edge cases | [`test/SecurityTest.t.sol`](./test/SecurityTest.t.sol), [`test/ReentrancyTest.t.sol`](./test/ReentrancyTest.t.sol), [`test/DeployerTest.t.sol`](./test/DeployerTest.t.sol), [`test/WeightDecayDeployTest.t.sol`](./test/WeightDecayDeployTest.t.sol), [`test/SplitHookRegressions.t.sol`](./test/SplitHookRegressions.t.sol), [`test/TestRegressionGaps.sol`](./test/TestRegressionGaps.sol) |

## Repo map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Interfaces | [`src/interfaces/`](./src/interfaces/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Reserved-token split hook that accumulates Juicebox project tokens and holds them as Uniswap V4 liquidity in at most two single-sided positions per project: an ask of project tokens (spot to issuance ceiling, never below the cash-out floor) and a bid of terminal tokens (spot to cash-out floor, never above the issuance ceiling). Every reserved distribution recycles both around the live spot, and after deployment payout splits in the pool's terminal token fund the bid; fees net of a fee-project cut raise the project's cash-out floor (terminal side added to its balance, project side burned), falling back to the ledgers when that fails.

## Reference files

- Open [`references/runtime.md`](./references/runtime.md) for lifecycle stages, pool-deployment math, and the main invariants around accumulation, post-deploy liquidity growth, and fee routing.
- Open [`references/operations.md`](./references/operations.md) for deployer behavior, permission gates, test breadcrumbs, and common stale assumptions around recycling and terminal-token choice.

## Working rules

- Start in [`src/JBUniswapV4LPSplitHook.sol`](./src/JBUniswapV4LPSplitHook.sol) for runtime behavior, but check the deployer when the problem might be clone config or provenance.
- Pool deployment is a one-way lifecycle transition. Once a project has a pool, every reserved distribution (or `addLiquidity`) recycles: collect fees, burn the ask and bid, re-mint both from everything the hook holds for the project. The hook never burns reserved tokens, only collected project-token LP fees.
- Treat pool deployment, the recycle (`_recycle` geometry, TWAP guard, burn floor), fee routing, and fee claiming as high-risk.
- `deployPool(...)`, `addLiquidity(...)`, and `collectAndRouteLPFees(...)` are permissionless; only `claimFeeTokensFor(...)` is gated by `SET_BUYBACK_POOL`. Recycles run at any time once the spot is within 200 ticks of the 30-minute TWAP; only the inline attempt on a reserved distribution skips dust below `1e15`; payouts attempt at any size.
- Position ids live in `askTokenIdOf` and `bidTokenIdOf`; either can be zero when that side had no range or no tokens at the last recycle.
- This hook supports only one deployed terminal-token pool per project because split contexts do not carry terminal-token identity.
- Fee accounting can end up as ERC-20 fee tokens or fee credits depending on whether the fee project has an ERC-20 deployed.
- Recycling and fee-claim logic share accounting surfaces. Verify outstanding fee-token claims before changing token or routing assumptions.
- When a task touches oracle or V4 hook assumptions, confirm whether the source of truth is this repo or `univ4-router-v6`.
