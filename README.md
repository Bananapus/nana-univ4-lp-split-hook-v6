# Juicebox UniV4 LP Split Hook

`@bananapus/univ4-lp-split-hook-v6` is a split hook that accumulates reserved Juicebox project tokens and turns them into protocol-owned Uniswap V4 liquidity, held as at most two single-sided positions per project (an ask and a bid) bounded by the project's issuance and cash-out economics.


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
- after deployment, every reserved-token distribution recycles the project's positions inline (best-effort, gas permitting), and anyone can run the same recycle through `addLiquidity` at any time; fee collection is also permissionless

Each project holds at most two positions on its pool:

- the **ask** (`askTokenIdOf`) holds project tokens from just past the live spot up to the issuance ceiling, never below the cash-out floor
- the **bid** (`bidTokenIdOf`) holds terminal tokens from just past the live spot down to the cash-out floor, never above the issuance ceiling

The spot sits in the gap between them, so both mints are single-sided. The gap is one spacing (200 ticks) when the spot is off the tick grid; when the spot sits exactly on an aligned tick and the TWAP tick equals it, both ranges touch the spot; anchoring to the TWAP can widen the gap. A recycle collects and routes each position's fees, burns both, claims any hook-held credits, recomputes the corridor, and re-mints the ask from every project token the hook holds for the project and the bid from every terminal token. Trading converts each position toward the other token; the next recycle moves those tokens back to the side they belong on.

The corridor is derived from project economics (the floor at the project's cash-out price, the ceiling at its issuance price) rather than from an arbitrary price target. Both bounds round inward against the exact prices; when the cash-out value reaches the issuance price, or no aligned spacing fits between them, the corridor is empty and the hook holds its tokens until it reopens.

Use this repo when reserved-token issuance should become managed concentrated liquidity. Do not use it when a project only needs a buyback hook or normal reserved-token splits.

## Key contracts

| Contract | Role |
| --- | --- |
| `JBUniswapV4LPSplitHook` | Main split hook that accumulates tokens, deploys the V4 pool, recycles the project's ask and bid positions, and routes fees. |
| `JBUniswapV4LPSplitHookDeployer` | Clone factory for deploying hook instances and registering them in the address registry. |

## Mental model

This repo owns a post-issuance lifecycle:

1. accumulate reserved tokens
2. deploy the pool and mint the first ask from the accumulation
3. on every later distribution (or permissionless `addLiquidity`), recycle: collect fees, burn the ask and bid, and re-mint both single-sided around the live spot from everything the hook holds for the project

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
- fee claiming (`claimFeeTokensFor`) is an operational power gated to the project owner or `SET_BUYBACK_POOL` delegate; deploy, add, and fee collection are permissionless but bounded by economic and oracle-TWAP guards, so projects should understand who can trigger them and how new ranges are chosen before treating the hook as hands-off infrastructure
- newly received reserved tokens keep accumulating after deployment and become liquidity at the next recycle (inline on the distribution, or via `addLiquidity`); the hook never burns project tokens (supply-reducing burns are a protocol-layer split-routing decision)
- the normal reserved-token path requires a deployed project ERC-20; if the hook also holds internal project credits, deploy/add liquidity claims them into that ERC-20 before minting so accounting remains tied to transferable tokens
- the hook never cashes out: the bid is funded only from this project's terminal-token ledger, which holds the terminal tokens recovered by burning its own positions, its own LP-fee remainders, and its own mint leftovers, never by redeeming project tokens against the terminal
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

This repo composes with the UniV4 router package, the address registry, core protocol contracts, and Permit2. One hook clone can serve many projects, with one deployed pool per project.

The two-position hook ships as a new library, hook implementation, and deployer at fresh addresses. Clones of the 1.4.0 deployment keep their single-position behavior; a project adopts the two-position model by deploying a clone from the new deployer and re-pointing its reserved-token split to it.

## Repository layout

```text
src/
  JBUniswapV4LPSplitHook.sol
  JBUniswapV4LPSplitHookDeployer.sol
  interfaces/
test/
  stage, deployment, fee, recycle, fork, invariant, review, and regression coverage
script/
  Deploy.s.sol
```

## Risks and notes

- once a pool path is chosen for a deployed project-token pair, that choice becomes part of the hook's operational identity
- first-pool deployment is publicly observable and can be front-run by outside initialization
- LP deployment and every recycle depend on current project economics and live market structure
- direct ETH or tokens sent to the hook are settlement dust unless a supported LP-management path accounts for them
- after deployment, newly received reserved tokens keep accumulating and are recycled into the ask on the next distribution or `addLiquidity`; the hook never burns
- TWAP and oracle assumptions come from the UniV4 router and should be evaluated together with this hook

## For AI agents

- Treat this repo as reserved-token liquidity management, not as the swap router itself.
- Read the deployment-stage, recycle (`test/fork/Integration_SingleSidedRevnet.t.sol`), frontrun-validation, and preinitialized-pool tests before summarizing failure modes.
