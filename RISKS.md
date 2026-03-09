# univ4-lp-split-hook-v6 — Risks

## Trust Assumptions

1. **Project Owner** — Can trigger pool deployment, rebalance liquidity, and configure fee splits. `SET_BUYBACK_POOL` permission required.
2. **Uniswap V4 Pool Manager** — Pool integrity depends on Uniswap V4 contracts. Pool manager controls all position operations.
3. **Core Protocol** — Receives tokens via split hook calls from JBMultiTerminal. Trusts terminal to call correctly.
4. **Price Accuracy** — Initial pool price derived from bonding curve value at deployment time. Stale or manipulated surplus affects initial pricing.

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Pool deployment front-running | Pool deployment is permissionless once threshold met | Pool parameters are deterministic from hook config |
| Rebalance sandwich | Permissionless `rebalanceLiquidity` can be sandwiched | Min amount parameters provide protection |
| Initial price manipulation | Surplus manipulation before pool deployment affects initial LP price | Deploy when surplus is stable; operator reviews pricing |
| Token accumulation period | Accumulated tokens before pool deployment are not earning yield | Deploy pool promptly once threshold is reached |
| Impermanent loss | Standard UniV4 LP risk — price divergence causes IL | Concentrated liquidity; rebalancing available |
| Post-deploy token burning | After pool deployment, incoming tokens are burned (reduces supply) | By design — supports token price |

## Privileged Roles

| Role | Permission | Scope |
|------|-----------|-------|
| Project owner/operator | `SET_BUYBACK_POOL` — deploy pool, rebalance | Per-project |
| Hook deployer | Creates hook instances | Factory |
