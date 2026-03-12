# univ4-lp-split-hook-v6 — Architecture

## Purpose

Uniswap V4 liquidity pool deployment hook for Juicebox V6. Receives project tokens via reserved token splits, accumulates them until a deployment threshold is met, then creates a Uniswap V4 pool and provides initial liquidity. After deployment, burns new tokens and routes LP fees back to the project.

## Contract Map

```
src/
├── JBUniswapV4LPSplitHook.sol         — Split hook: token accumulation, pool deployment (with oracle hook), LP management
├── JBUniswapV4LPSplitHookDeployer.sol — Factory for deploying split hooks
└── interfaces/
    └── IJBUniswapV4LPSplitHook.sol
```

## Key Data Flows

### Pre-Deployment (Accumulation)
```
Reserved token distribution → JBMultiTerminal.sendPayoutsOf()
  → Split to JBUniswapV4LPSplitHook.processSplitWith()
    → Accumulate project tokens
    → Track accumulated balance

Owner/Operator → deployPool()
  → Validate: enough tokens accumulated
  → Create Uniswap V4 pool (projectToken/terminalToken) with ORACLE_HOOK (TWAP via observe())
  → Provide initial liquidity from accumulated tokens
  → Set up LP position
```

### Post-Deployment (Maintenance)
```
Reserved token distribution → processSplitWith()
  → Burn newly received project tokens (no more accumulation)

Anyone → rebalanceLiquidity()
  → Adjust LP position based on current rates
  → Route LP fees back to project
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Split hook | `IJBSplitHook` | Receives tokens from reserved distribution |
| Pool deployment | Uniswap V4 PositionManager | Creates and manages LP positions. Pools use `ORACLE_HOOK` (`IHooks`) for TWAP via `observe()`. |

## Dependencies
- `@bananapus/core-v6` — Core protocol
- `@bananapus/permission-ids-v6` — SET_BUYBACK_POOL permission
- `@bananapus/ownable-v6` — JB ownership
- `@openzeppelin/contracts` — SafeERC20, Ownable
- `@prb/math` — mulDiv, sqrt
- `@uniswap/v4-core` — Pool manager, currency types
- `@uniswap/v4-periphery` — Position manager, actions
- `@rev-net/core-v6` — Revnet integration
