# univ4-lp-split-hook-v6 — Risks

## Trust Assumptions

1. **Project Owner** — Can trigger pool deployment and configure LP parameters. Has `SET_BUYBACK_POOL` permission.
2. **Uniswap V4 Pool Manager** — LP position managed through V4 PositionManager. Pool manager bugs affect liquidity.
3. **Core Protocol** — Receives tokens via split hook mechanism. Relies on JBMultiTerminal to correctly call `processSplitWith`.
4. **Price Oracle** — Initial pool price derived from project's terminal store. Incorrect pricing creates arbitrage opportunities.

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Pool deployment front-running | Pool deployment is permissionless once threshold is met | Pool parameters are deterministic from hook config |
| Rebalance sandwich | Permissionless `rebalanceLiquidity` can be sandwiched | Min amount parameters provide some protection |
| Impermanent loss | Standard LP risk — price divergence causes IL | Inherent to AMM design; LP position is long-term |
| Initial price manipulation | If deployment price is off, arbitrageurs extract value | Price derived from bonding curve; limited manipulation surface |
| Token accumulation period | Tokens sit in contract pre-deployment without earning yield | Acceptable trade-off for deployment simplicity |
| Irreversible deployment | Once pool is deployed, cannot redeploy with different parameters | Verify configuration before deployment |

## Privileged Roles

| Role | Permission | Scope |
|------|-----------|-------|
| Project owner | `SET_BUYBACK_POOL` — trigger pool deployment | Per-project |
| Anyone (post-deployment) | `rebalanceLiquidity` — adjust LP position | Permissionless |
