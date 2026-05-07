# Juicebox UniV4 LP Split Hook

`@bananapus/univ4-lp-split-hook-v6` is a split hook that accumulates reserved Juicebox project tokens and then deploys them into a Uniswap V4 concentrated liquidity position bounded by the project's issuance and cash-out economics.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)  
User journeys: [USER_JOURNEYS.md](./USER_JOURNEYS.md)  
Skills: [SKILLS.md](./SKILLS.md)  
Risks: [RISKS.md](./RISKS.md)  
Administration: [ADMINISTRATION.md](./ADMINISTRATION.md)  
Review instructions: [REVIEW_GUIDE.md](./REVIEW_GUIDE.md)

## Overview

The hook has a two-stage lifecycle:

- before pool deployment, it accumulates reserved project tokens
- after deployment, it manages the LP position, fee collection, and rebalancing

The LP range is derived from project economics rather than from an arbitrary price target.

Use this repo when reserved-token issuance should become managed concentrated liquidity. Do not use it when a project only needs a buyback hook or normal reserved-token splits.

## Key Contracts

| Contract | Role |
| --- | --- |
| `JBUniswapV4LPSplitHook` | Main split hook that accumulates tokens, deploys a V4 pool position, rebalances, and routes fees. |
| `JBUniswapV4LPSplitHookDeployer` | Clone factory for deploying hook instances and registering them in the address registry. |

## Mental Model

This repo owns a post-issuance lifecycle:

1. accumulate reserved tokens
2. deploy them into a bounded V4 position
3. manage that position over time

It does not own the project's issuance logic itself.

## Read These Files First

1. `src/JBUniswapV4LPSplitHook.sol`
2. `src/JBUniswapV4LPSplitHookDeployer.sol`
3. `univ4-router-v6/src/JBUniswapV4Hook.sol`
4. `nana-core-v6/src/JBController.sol` for reserved-token origin context

## Integration Traps

- this hook governs post-issuance liquidity, so it should not be used to infer how project tokens were originally priced or minted
- first-pool deployment assumptions are economically sensitive because outside actors can initialize the pool first
- LP management depends on both live market state and live Juicebox economics
- newly received reserved tokens are intentionally burned after deployment instead of added pro rata to the LP

## Where State Lives

- accumulation-stage and deployed-position behavior live in `JBUniswapV4LPSplitHook`
- deployment and registration flows live in `JBUniswapV4LPSplitHookDeployer`
- oracle and route assumptions live in `univ4-router-v6`
- reserved-token origin economics live upstream in `nana-core-v6`

## Install

```bash
npm install @bananapus/univ4-lp-split-hook-v6
```

## Development

```bash
npm install
forge build
forge test
```

Useful scripts:

- `npm run test:fork`

## Deployment Notes

This repo composes with the UniV4 router package, the address registry, core protocol contracts, and Permit2. Teams should usually deploy one hook instance per project and terminal-token pair they want to manage.

## Repository Layout

```text
src/
  JBUniswapV4LPSplitHook.sol
  JBUniswapV4LPSplitHookDeployer.sol
  interfaces/
test/
  stage, deployment, fee, rebalance, fork, invariant, review, and regression coverage
script/
  Deploy.s.sol
```

## Risks And Notes

- once a pool path is chosen for a deployed project-token pair, that choice becomes part of the hook's operational identity
- first-pool deployment is publicly observable and can be front-run by outside initialization
- LP deployment and rebalancing depend on current project economics and live market structure
- after deployment, newly received reserved tokens are intentionally burned to avoid LP dilution
- TWAP and oracle assumptions come from the UniV4 router and should be evaluated together with this hook

## For AI Agents

- Treat this repo as reserved-token liquidity management, not as the swap router itself.
- Read the deployment-stage, rebalance, and preinitialized-pool tests before summarizing failure modes.
