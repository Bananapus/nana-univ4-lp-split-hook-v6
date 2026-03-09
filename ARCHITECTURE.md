# univ4-lp-split-hook-v6 — Architecture

## Purpose

Uniswap V4 liquidity deployment hook for Juicebox V6. Receives project tokens via reserved token splits, accumulates them, then deploys a Uniswap V4 pool and provides liquidity. After pool deployment, burns incoming tokens and manages LP positions.

## Contract Map

```
src/
├── UniV4DeploymentSplitHook.sol         — Split hook: accumulate tokens → deploy pool → manage LP
├── UniV4DeploymentSplitHookDeployer.sol — Factory for deploying hook instances
└── interfaces/
    └── IUniV4DeploymentSplitHook.sol
```

## Key Data Flows

### Before Pool Deployment
```
Reserved token distribution → JBMultiTerminal splits
  → UniV4DeploymentSplitHook.processSplitWith()
    → Accumulate project tokens
    → Wait for threshold or manual trigger

Owner/Operator → deployPool()
  → Create Uniswap V4 pool (project token / terminal token)
  → Provide initial liquidity from accumulated tokens
  → Set price based on current bonding curve value
```

### After Pool Deployment
```
Reserved token distribution → processSplitWith()
  → Burn received project tokens (reduce supply)
  → Route LP fees back to project

Operator → rebalanceLiquidity()
  → Adjust LP position tick range
  → Re-concentrate liquidity around current price
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Split hook | `IJBSplitHook` | Receives tokens from reserved distributions |
| Pool creation | UniV4 PoolManager | Creates and manages LP positions |

## Dependencies
- `@bananapus/core-v6` — Core protocol, terminal store, permissions
- `@bananapus/permission-ids-v6` — SET_BUYBACK_POOL permission
- `@bananapus/ownable-v6` — JB-aware ownership
- `@uniswap/v4-core` — Pool manager
- `@uniswap/v4-periphery` — Position manager, actions
- `@openzeppelin/contracts` — SafeERC20, Ownable
- `@prb/math` — mulDiv, sqrt
