# Juicebox UniV4 LP Split Hook

`@bananapus/univ4-lp-split-hook-v6` is a split hook that accumulates reserved Juicebox project tokens and then deploys them into a Uniswap V4 concentrated liquidity position bounded by the project's issuance and cash-out economics.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)

## Overview

The hook has a two-stage lifecycle:

- before pool deployment, it accumulates reserved project tokens over time
- after deployment, it manages the LP position, fee collection, and rebalancing

The LP range is derived from the project's economics rather than from an arbitrary market price target, which makes it a natural fit for protocol-native liquidity.

Use this repo when reserved-token issuance should become managed concentrated liquidity. Do not use it when a project just needs a buyback hook or ordinary reserved-token splits.

If the issue is "which route wins between Juicebox and the market?" start in the buyback or UniV4 router repo first. This package starts mattering after issuance, when reserved tokens are being deployed into liquidity.

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

This repo composes with the UniV4 router package, the address registry, core protocol contracts, and Permit2. Teams generally deploy one hook instance per project and terminal-token pair they want to manage.

## Repository Layout

```text
src/
  JBUniswapV4LPSplitHook.sol
  JBUniswapV4LPSplitHookDeployer.sol
  interfaces/
test/
  stage, deployment, fee, rebalance, fork, invariant, audit, and regression coverage
script/
  Deploy.s.sol
```

## Risks And Notes

- once a pool path is chosen for a deployed project-token pair, that choice becomes part of the hook's operational identity
- first-pool deployment is publicly observable; if a third party initializes the V4 pool first, operators should only proceed when the live initialized price is still within the expected floor-to-ceiling band
- LP deployment and rebalancing depend on current project economics and live market structure
- after deployment, newly received reserved tokens are intentionally burned instead of added pro rata to avoid LP dilution
- TWAP and oracle assumptions come from the UniV4 router and should be evaluated as part of the same liquidity design
