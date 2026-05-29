# Changelog

## Scope

This repo was not part of the deployed v5 ecosystem that the top-level changelog measures, so it is excluded from the ecosystem delta.

## Current v6 surface

- `JBUniswapV4LPSplitHook`
- `JBUniswapV4LPSplitHookDeployer`
- `IJBUniswapV4LPSplitHook`
- `IJBUniswapV4LPSplitHookDeployer`

## 0.0.53 — Continuous LP growth: replace post-deploy burn with `addLiquidity`

- **The hook no longer burns.** Post-deployment, `processSplitWith` now ACCUMULATES reserved-token inflows into `accumulatedProjectTokens` (the same ledger used pre-deployment) instead of burning them. Supply-reducing burns are now a protocol-layer split-routing decision (route a reserved split to `{projectId:0, hook:0, beneficiary:0xdead}`), not this hook's job. Removed `_burnReceivedTokens` / `_burnProjectTokens` and the `TokensBurned` event.
- **New `addLiquidity(projectId, terminalToken, minCashOutReturn)`** converts post-deploy accumulation into more protocol-owned liquidity. Same authorization model as `deployPool` (permissionless once the ruleset weight has decayed 10x, else `SET_BUYBACK_POOL`). It:
  - rejects the add if the pool spot price deviates from the oracle TWAP by more than `_MAX_TWAP_DEVIATION_TICKS` (~200, ≈2%) or the TWAP is unavailable (30-minute window) — guarding against JIT/sandwich manipulation;
  - cashes out the optimal fraction DIRECTLY through the bonding curve via the buyback hook's `cashOut` skip metadata, keyed to a new immutable `BUYBACK_HOOK` registry reference (a chain-same strong reference passed to the constructor, decoupled from revnets), never routing the funding cash-out through the AMM it feeds;
  - tops up the active position (`INCREASE_LIQUIDITY`) while the live cash-out/issuance corridor is within `_RERANGE_THRESHOLD_TICKS` (~400, ≈4%) of the active ticks; once drift exceeds the threshold it collects fees, BURNS the stale position to recover its principal, and re-mints a single fresh position at the live corridor (folding in the recovered principal + new accumulation) — so all funds consolidate into one maximally-efficient position rather than fragmenting across stale bands.
- **Fee collection** routes the terminal-token side and carries the project-token side back into the accumulation ledger; there is always exactly one position per `(projectId, terminalToken)` pair.
- **Dust is carried forward, never burned** — leftover project tokens (from deploy, add, rebalance, and collected project-token fees) return to `accumulatedProjectTokens`; leftover terminal tokens are deposited to the project's terminal.
- New constructor immutable `BUYBACK_HOOK` (`IJBBuybackHookRegistry`, sixth constructor arg). New state: `activeTickLowerOf`, `activeTickUpperOf`. New errors: `JBUniswapV4LPSplitHook_PriceDeviationTooHigh`, `JBUniswapV4LPSplitHook_TwapUnavailable`. New event: `LiquidityAdded`. The TWAP `observe` interface is now imported from `@bananapus/suckers-v6` (`IGeomeanOracle`); the `AddLiquidityParams` struct moved to `src/structs/`.
- `package.json`: version 0.0.52 -> 0.0.53; added dependency `@bananapus/buyback-hook-v6@^0.0.63` (provides `IJBBuybackHookRegistry` and the deploy-script registry address).
- The force-direct funding cash-out keys its metadata to the buyback hook's `"cashOut"` purpose (the lifecycle-phase name introduced in buyback-hook-v6 0.0.63, renamed from `"cashOutMinReclaimed"`).

## 0.0.40 — Bump nana-core-v6 to 0.0.52

- `package.json`: version 0.0.39 -> 0.0.40, core dep ^0.0.49 -> ^0.0.52, univ4-router-v6 dep ^0.0.30 -> ^0.0.31 (the matching downstream bump for core 0.0.52).
- No src changes — `JBUniswapV4LPSplitHook` never referenced `IJBFeeTerminal.FEE()`, so the only impact is the new `pauseCrossProjectFeeFreeInflows` field added to `JBRulesetMetadata`. Patched all `JBRulesetMetadata` literals across `test/` to include `pauseCrossProjectFeeFreeInflows: false`.

## Summary

- This repo is a v6-era Uniswap v4 liquidity hook package, not a deployed-v5 migration target.
- The current repo includes dedicated deployment, fork, invariant, and regression coverage around concentrated-liquidity behavior, fee routing, rebalance logic, and lifecycle staging.
- The implementation baseline matches the rest of the v6 tree around Solidity `0.8.28`.
- Pool deployment validates outsider pre-initialization against the project's economic tick bounds and reverts if the price is out of range.


## Migration notes

- Do not count this repo in the deployed v5-to-v6 ecosystem summary.
- If you need this package, treat it as a current v6 surface and rebuild from the current contracts and tests.
