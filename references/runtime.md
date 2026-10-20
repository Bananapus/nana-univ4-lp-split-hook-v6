# UniV4 LP Split Hook Runtime

## Core roles

- [`src/JBUniswapV4LPSplitHook.sol`](../src/JBUniswapV4LPSplitHook.sol) accumulates reserved tokens, deploys the V4 pool, recycles the project's ask and bid positions, and manages fee collection.
- [`src/JBUniswapV4LPSplitHookDeployer.sol`](../src/JBUniswapV4LPSplitHookDeployer.sol) deploys clones and registers them in the address registry.

## Lifecycle

1. Reserved-token splits accumulate project tokens before a pool exists.
2. A pool is deployed for a chosen terminal token and bounded by project issuance and cash-out economics.
3. After deployment, each reserved distribution recycles inline (best-effort), with `addLiquidity` as the permissionless retry: collect and route each position's fees, burn the ask and bid, claim credits, recompute the corridor, and re-mint the ask from every project token held and the bid from every terminal token held, under an oracle-TWAP deviation guard. Fees can also be collected from both positions at any time. The hook never burns project tokens.

## High-risk areas

- Pool deployment math: issuance and cash-out rates define the initial liquidity shape.
- Stage transition: pre-deploy, `deployPool` consumes accumulation; post-deploy, each recycle does (inline or `addLiquidity`, TWAP-guarded). Accumulation is the single inflow sink in both phases.
- Recycle geometry: with `spotFloor` the lower of the spot tick and the validated TWAP tick, aligned down to the 200 spacing, and `spotCeil` the higher of the first aligned tick at or above the spot (the spot itself when it sits exactly on an aligned tick) and the TWAP tick aligned up, token0 rests on `[max(spotCeil, corridorLower), corridorUpper]` and token1 on `[corridorLower, min(spotFloor, corridorUpper)]`, so both mints are single-sided, the spot sits in the gap between them, neither quote crosses the TWAP, the ask never sits below the cash-out floor, and the bid never above the issuance ceiling. The hook never cashes out; the bid is funded only from this project's own terminal-token ledger.
- Corridor floor: the floor tick is derived from the project's cash-out (redemption) price — surplus over supply, an upper bound on the 1-token preview (plus two, never zero) — and is used only to place the tick. The hook never performs a cash-out. The ceiling is the net issuance rate bounded from above. Both bounds round inward against the exact prices; a cash-out value at or above the issuance price, or a band narrower than one spacing, is an empty corridor (`EmptyCorridor` when nothing is live to retire).
- Fee routing: each side of collected fees (terminal-token and project-token) takes a best-effort `feeProjectId` cut; fee-token and fee-credit claims for the fee project stay reserved from LP principal; every non-cut remainder is carried into this project's own ledger — `accumulatedTerminalTokens` for the terminal-token side, `accumulatedProjectTokens` for the project-token side — never into the project's terminal, and never burned.
- Recycling: position teardown and re-minting on every distribution can change treasury exposure materially, and its timing is permissionless within the TWAP band.

## Tests to trust first

- [`test/AccumulationStageTest.t.sol`](../test/AccumulationStageTest.t.sol) and [`test/DeploymentStageTest.t.sol`](../test/DeploymentStageTest.t.sol) for lifecycle behavior.
- [`test/FeeRoutingTest.t.sol`](../test/FeeRoutingTest.t.sol) for fee behavior.
- [`test/fork/Integration_SingleSidedRevnet.t.sol`](../test/fork/Integration_SingleSidedRevnet.t.sol) for the real-swap two-position recycle lifecycle.
- [`test/Fork.t.sol`](../test/Fork.t.sol), [`test/SecurityTest.t.sol`](../test/SecurityTest.t.sol), [`test/ReentrancyTest.t.sol`](../test/ReentrancyTest.t.sol), and [`test/SplitHookRegressions.t.sol`](../test/SplitHookRegressions.t.sol) for broader safety.
- [`test/regression/`](../test/regression/) for edge-case unit tests (zero-rate fallback, tokenId resolution, price/tick/bounds edge cases).
- [`test/fork/`](../test/fork/) for fork tests and integration fork tests verifying cross-scenario interactions.
