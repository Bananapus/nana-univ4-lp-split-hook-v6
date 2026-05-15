# Changelog

## Scope

This repo was not part of the deployed v5 ecosystem that the top-level changelog measures, so it is excluded from the ecosystem delta.

## Current v6 surface

- `JBUniswapV4LPSplitHook`
- `JBUniswapV4LPSplitHookDeployer`
- `IJBUniswapV4LPSplitHook`
- `IJBUniswapV4LPSplitHookDeployer`

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
