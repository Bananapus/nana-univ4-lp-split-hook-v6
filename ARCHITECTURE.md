# Architecture

## Purpose

`univ4-lp-split-hook-v6` turns reserved project tokens into treasury-owned Uniswap V4 liquidity. It accumulates reserved tokens, deploys a pool, and holds the liquidity as at most two single-sided positions per project (an ask of project tokens and a bid of terminal tokens) bounded by Juicebox economics, recycling both on every reserved-token distribution.

## System overview

`JBUniswapV4LPSplitHook` is a staged split hook: before LP deployment it accumulates reserved tokens; after deployment each distribution triggers a best-effort inline recycle of the project's ask and bid (with `addLiquidity` as the permissionless retry), and fee collection stays permissionless. `JBUniswapV4LPSplitHookDeployer` creates deterministic instances for projects that want this liquidity policy.

## Core invariants

- Both positions stay inside the project's economic corridor: the ask never sells below the cash-out floor and the bid never buys above the issuance ceiling.
- A project holds at most two positions per pair, tracked in `askTokenIdOf` and `bidTokenIdOf`; both are single-sided, with the spot in the gap between them and neither quote past the validated TWAP.
- The hook has materially different pre-deployment and post-deployment behavior.
- Fee routing takes a best-effort `feeProjectId` cut symmetrically on both the project-token and terminal-token fee sides, then carries each side's non-cut remainder into the project's own ask/bid ledgers — never into the project's treasury.
- A project's accumulation ledger is the single sink for reserved-token inflows both before AND after pool deployment; the hook never burns. Pre-deploy, `deployPool` consumes the accumulation; post-deploy, each recycle does.
- A hook instance should map a project and terminal-token pair to one pool path.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBUniswapV4LPSplitHook` | Accumulation, pool deployment, ask/bid recycling, fee routing | Runtime core |
| `JBUniswapV4LPSplitHookDeployer` | Deterministic clone deployment with immutable implementation and one-shot V4 wiring | Keeps deployer address stable across chains |

## Trust boundaries

- Reserved-token issuance and cash-out economics come from `nana-core-v6`.
- Pool and position behavior come from Uniswap V4.
- Oracle behavior comes from the selected compatible hook configuration, usually `univ4-router-v6`.

## Critical flows

### Accumulate, deploy, manage

```text
reserved-token split distributions
  -> accumulate project tokens before pool deployment
deploy (inline on a distribution, or permissionless `deployPool`)
  -> computes price bounds from issuance and cash-out economics (floor tick = cash-out price), each rounded inward against its exact price
  -> deploys or uses the target pool (an already-initialized pool must pass the spot-vs-TWAP guard)
  -> runs the first recycle, which mints a single-sided ask from the accumulated project tokens (no cash-out)
post-deployment, every recycle (inline on each distribution, or permissionless `addLiquidity` at any time)
  -> requires the pool spot within 200 ticks of the 30-minute oracle TWAP
  -> for each live position: collect fees (best-effort `feeProjectId` cut per side; project remainder into `accumulatedProjectTokens`, terminal remainder into `accumulatedTerminalTokens`), burn it with a contract-derived slippage floor, credit recovered principal to the same ledgers
  -> claims hook-held credits into the project ledger and recomputes the corridor
  -> spotFloor = min(spot, TWAP) aligned down to the 200 spacing
     spotCeil = max(first aligned tick at or above the spot, TWAP aligned up)
     token0 rests on [max(spotCeil, corridorLower), corridorUpper]
     token1 rests on [corridorLower, min(spotFloor, corridorUpper)]
  -> mints the ask from the whole project ledger and the bid from the whole terminal ledger; a side with an empty range or zero amount stays in its ledger
  -> if neither side mints, reverts `NoDeployableLiquidityAtSpot` and the live positions are kept
  -> if the corridor is empty (cash-out value at or above the issuance price, or a band narrower than one spacing), retires both positions and holds the tokens; reverts `EmptyCorridor` when nothing was live
trading between recycles
  -> buys fill the ask (it accrues terminal tokens); sells fill the bid (it accrues project tokens)
  -> the next recycle moves each converted amount back to the side it belongs on
`collectAndRouteLPFees` (permissionless)
  -> collects and routes fees from both positions without touching principal
```

## Accounting model

The hook owns local staging and LP-management state. It does not own reserved-token issuance or terminal accounting.

It owns two per-project ledgers that hold protocol-owned liquidity outside any Uniswap V4 position: `accumulatedProjectTokens` (the ask-side ledger) and `accumulatedTerminalTokens[projectId][terminalToken]` (the per-terminal-token bid-side ledger). The project ledger accrues from split distributions and claimed credits; both accrue from the principal recovered by burning the project's own positions, mint leftovers, and the non-cut remainder of collected LP fees. Each recycle mints the whole project ledger into the ask and the whole terminal ledger into the bid. Neither is ever deposited into the project's terminal.

It also owns claim segregation for routed LP-fee cuts. Outstanding ERC-20 fee-token claims and credit-only fee claims owed to the fee project are tracked separately so the hook's accumulation and LP-funding paths do not consume fee assets being held for that beneficiary.

## Security model

- The main risks are price-bound math (including the cash-out-price floor), the ask/bid range geometry around the spot, and staged behavior drift.
- A recycle is a collect, burn, recompute, mint pipeline across two positions and should be reviewed as one unit (`_recycle`, `_retirePosition`, `_mintSingleSided`).
- Recycles are permissionless at any time, bounded by the spot-vs-TWAP guard; both quotes are anchored to the validated TWAP, so a within-band manipulation only widens the gap and never pulls a quote past the TWAP price.
- Pool initialization race conditions matter on first deployment.
- Accumulation/LP-funding logic, fee routing, and outstanding-claim accounting are coupled.

## Safe change guide

- Review pre-deployment and post-deployment behavior together whenever state layout changes.
- Keep price-bound math, the cash-out-price floor derivation, and the ask/bid range geometry in `_recycle` synchronized.
- If you change fee routing or accumulation/leftover-carry behavior, re-check outstanding fee-token and fee-credit claim segregation and in-flight fee routing assumptions.
- If fee routing changes, inspect downstream fee-project behavior and claim paths.
- Keep deployer assumptions aligned with the address registry, deployment scripts, immutable implementation address, and one-shot V4 constants used to preserve the deployer address across chains.

## Canonical checks

- staged accumulation and deployment lifecycle:
  `test/IntegrationLifecycle.t.sol`
- two-position recycle lifecycle with real swaps (buy, sell, recycle, no cash-out):
  `test/fork/Integration_SingleSidedRevnet.t.sol`
- fee-token claim segregation against the accumulation / LP-funding paths:
  `test/regression/FeeTokenTerminalAccountingRegression.t.sol`
- split-hook staging and accounting invariants:
  `test/invariant/LPSplitHookInvariant.t.sol`
- edge-case unit tests (zero-rate fallback, tokenId resolution, price/tick/bounds edge cases):
  `test/regression/`
- fork tests (full JB core deployment per scenario):
  `test/fork/`
- integration fork tests (cross-scenario interaction chains):
  `test/fork/Integration_MultiProjectDeploy.t.sol`, `test/fork/Integration_HighReservedZeroTax.t.sol`, `test/fork/Integration_BurnPathCrossProject.t.sol`, `test/fork/Integration_TerminalMigration.t.sol`

## Source map

- `src/JBUniswapV4LPSplitHook.sol`
- `src/JBUniswapV4LPSplitHookDeployer.sol`
- `src/libraries/JBUniswapV4LPSplitHookMath.sol` (linked pricing/tick math, kept out of the hook's runtime bytecode)
- `test/IntegrationLifecycle.t.sol`
- `test/fork/Integration_SingleSidedRevnet.t.sol`
- `test/regression/FeeTokenTerminalAccountingRegression.t.sol`
- `test/invariant/LPSplitHookInvariant.t.sol`
