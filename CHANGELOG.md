# Changelog

## Scope

This repo was not part of the deployed v5 ecosystem that the top-level changelog measures, so it is excluded from the ecosystem delta.

## Current v6 surface

- `JBUniswapV4LPSplitHook`
- `JBUniswapV4LPSplitHookDeployer`
- `IJBUniswapV4LPSplitHook`
- `IJBUniswapV4LPSplitHookDeployer`

## Summary

- This repo is a v6-era Uniswap v4 liquidity hook package, not a deployed-v5 migration target.
- The current repo includes dedicated deployment, fork, invariant, and regression coverage around concentrated-liquidity behavior, fee routing, rebalance logic, and lifecycle staging.
- The implementation baseline matches the rest of the v6 tree around Solidity `0.8.28`.
- Pool deployment now tolerates outsider pre-initialization when the existing V4 price is still inside the hook's LP band, and rejects only out-of-band prices that would force a single-sided or invalid first position.
- Coverage includes both local PoC and fork-level assertions for the bounded pre-initialization rule.

## Migration notes

- Do not count this repo in the deployed v5-to-v6 ecosystem summary.
- If you need this package, treat it as a current v6 surface and rebuild from the current contracts and tests.
