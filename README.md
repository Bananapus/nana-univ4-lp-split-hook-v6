# Juicebox UniV4 LP Split Hook

`@bananapus/univ4-lp-split-hook-v6` is a split hook that accumulates reserved Juicebox project tokens and then deploys them into a Uniswap V4 concentrated liquidity position bounded by the project's issuance and cash-out economics.


## Documentation

- Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)
- User journeys: [USER_JOURNEYS.md](./USER_JOURNEYS.md)
- Skills: [SKILLS.md](./SKILLS.md)
- Risks: [RISKS.md](./RISKS.md)
- Invariants: [INVARIANTS.md](./INVARIANTS.md)
- Administration: [ADMINISTRATION.md](./ADMINISTRATION.md)
- Audit instructions: [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md)
- V5 to V6 migration changelog: [CHANGELOG.md](./CHANGELOG.md)

## Overview

The hook has a two-stage lifecycle:

- before pool deployment, it accumulates reserved project tokens
- after deployment, further reserved-token inflows keep accumulating, and anyone can call `addLiquidity` to fold them into the project's single Uniswap V4 position (consolidated by burning the prior position and re-minting one adaptive position); the hook also manages permissionless fee collection and rebalancing

The LP range is derived from project economics — asks anchored to the project balance up to the issuance ceiling, with the floor placed at the project's cash-out (redemption) price — rather than from an arbitrary price target.

Use this repo when reserved-token issuance should become managed concentrated liquidity. Do not use it when a project only needs a buyback hook or normal reserved-token splits.

## Key contracts

| Contract | Role |
| --- | --- |
| `JBUniswapV4LPSplitHook` | Main split hook that accumulates tokens, deploys a V4 pool position, rebalances, and routes fees. |
| `JBUniswapV4LPSplitHookDeployer` | Clone factory for deploying hook instances and registering them in the address registry. |

## Mental model

This repo owns a post-issuance lifecycle:

1. accumulate reserved tokens
2. deploy them into a bounded V4 position
3. keep accumulating later inflows and grow the position via `addLiquidity` (which consolidates into a single re-minted position), collecting fees and rebalancing over time

It does not own the project's issuance logic itself.

## Read these files first

1. `src/JBUniswapV4LPSplitHook.sol`
2. `src/JBUniswapV4LPSplitHookDeployer.sol`
3. `univ4-router-v6/src/JBUniswapV4Hook.sol`
4. `nana-core-v6/src/JBController.sol` for reserved-token origin context

## Integration traps

- this hook governs post-issuance liquidity, so it should not be used to infer how project tokens were originally priced or minted
- first-pool deployment validates any pre-initialized pool price against the project's economic tick bounds and reverts if out of range
- LP management depends on both live market state and live Juicebox economics
- fee claiming (`claimFeeTokensFor`) is an operational power gated to the project owner or `SET_BUYBACK_POOL` delegate; deploy, add, rebalance, and fee collection are permissionless but bounded by economic and oracle-TWAP guards, so projects should understand who can trigger them and how new ranges are chosen before treating the hook as hands-off infrastructure
- newly received reserved tokens keep accumulating after deployment and are converted into additional liquidity via `addLiquidity` (the hook never burns project tokens; supply-reducing burns are a protocol-layer split-routing decision)
- the normal reserved-token path requires a deployed project ERC-20; if the hook also holds internal project credits, deploy/add liquidity claims them into that ERC-20 before minting so accounting remains tied to transferable tokens
- the hook never cashes out: any terminal-token (bid) side of a position is funded only from the terminal tokens the hook recovers by burning its own prior V4 position plus this project's own accumulated terminal-token fee ledger, never by redeeming project tokens against the terminal
- LP-fee collection takes a best-effort `feeProjectId` cut symmetrically on both the project-token and terminal-token sides (each paid to the fee project's primary terminal for that token when one exists, forgiven otherwise); every non-cut remainder becomes the project's own protocol-owned liquidity, never a deposit into the project's terminal
- fee-project credits owed to claimants are reserved from that credit normalization, so a fee project cannot consume other projects' claimable fee credits as its own LP principal

## Where state lives

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

## Deployment notes

This repo composes with the UniV4 router package, the address registry, core protocol contracts, and Permit2. Teams should usually deploy one hook instance per project and terminal-token pair they want to manage.

## Repository layout

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

## Risks and notes

- once a pool path is chosen for a deployed project-token pair, that choice becomes part of the hook's operational identity
- first-pool deployment is publicly observable and can be front-run by outside initialization
- LP deployment and rebalancing depend on current project economics and live market structure
- direct ETH or tokens sent to the hook are settlement dust unless a supported LP-management path accounts for them
- after deployment, newly received reserved tokens keep accumulating and are added as more liquidity via `addLiquidity`; the hook never burns
- TWAP and oracle assumptions come from the UniV4 router and should be evaluated together with this hook

## For AI agents

- Treat this repo as reserved-token liquidity management, not as the swap router itself.
- Read the deployment-stage, rebalance, frontrun-validation, and preinitialized-pool tests before summarizing failure modes.
