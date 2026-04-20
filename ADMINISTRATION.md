# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Per-project LP split hook lifecycle from accumulation to live Uniswap V4 LP management |
| Control posture | Project-owner or `SET_BUYBACK_POOL` delegated control over key lifecycle functions |
| Highest-risk actions | Premature `deployPool(...)`, incorrect rebalance assumptions, and bad hook initialization |
| Recovery posture | Usually requires replacement hooks or future split reconfiguration; no rollback to accumulation mode |

## Purpose

`univ4-lp-split-hook-v6` is administered per project path, with one major irreversible transition: the move from accumulation mode to deployed LP mode. The key admin surfaces are pool deployment, rebalance, and fee-claim paths gated by project ownership or `SET_BUYBACK_POOL`.

## Control Model

- Project owner or `SET_BUYBACK_POOL` delegate controls the key lifecycle functions.
- The deployer path is permissionless for creating a new hook instance.
- Some post-deployment fee collection is permissionless.
- Router, pool manager, and position manager dependencies are immutable.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Project owner | `JBProjects.ownerOf(projectId)` through directory lookup | Per project | May delegate through `JBPermissions` |
| Pool delegate | `SET_BUYBACK_POOL` permission | Per project | Controls deploy, rebalance, and fee-claim paths |
| Hook deployer caller | Anyone | Per new hook instance | Can deploy a clone through the deployer |

## Privileged Surfaces

| Contract | Function | Who Can Call | Effect |
| --- | --- | --- | --- |
| `JBUniswapV4LPSplitHook` | `deployPool(...)` | Project owner or `SET_BUYBACK_POOL` delegate, and eventually permissionless after the configured decay condition | Irreversibly transitions a project path into deployed LP mode |
| `JBUniswapV4LPSplitHook` | `rebalanceLiquidity(...)` | Project owner or `SET_BUYBACK_POOL` delegate | Rebuilds the LP position within the current economic envelope |
| `JBUniswapV4LPSplitHook` | `claimFeeTokensFor(...)` | Project owner or `SET_BUYBACK_POOL` delegate | Claims fee-project token balances |
| `JBUniswapV4LPSplitHookDeployer` | `deployHookFor(...)` | Anyone | Deploys and initializes a new hook clone |

## Immutable And One-Way

- Clone initialization is one-time.
- `deployPool(...)` is the irreversible lifecycle transition for a project path.
- Fee-project configuration on a clone is fixed at initialization.
- Constructor dependencies such as directory, permissions, pool manager, position manager, and oracle hook are immutable.

## Operational Notes

- Validate terminal token and expected economic bounds before calling `deployPool(...)`.
- Treat the accumulate-to-deployed transition as a treasury policy decision, not a routine action.
- Review rebalance logic as remove, collect, recompute, and mint together.
- Treat fee-token and credit-claim paths as retry-sensitive; some downstream failures preserve pending state for later recovery instead of cleanly unwinding every step.

## Machine Notes

- Do not treat `deployPool(...)` as a reversible setup step; it is the main lifecycle boundary.
- Inspect `src/JBUniswapV4LPSplitHook.sol` and the clone initialization path together before documenting authority.
- If live pool identity or initialization params differ from intended config, stop and use a replacement hook path rather than assuming patchability.
- If rebalance or fee-claim flows leave pending credits or hit zero-liquidity reverts, analyze the preserved state before assuming the project has been irreversibly bricked.

## Recovery

- If a hook instance was initialized or deployed against the wrong path, use a replacement hook instance and update split config for future flows.
- There is no generic rollback to accumulation mode.
- Some downstream controller failures are intentionally retryable because pending credits or fee-claim state can remain preserved for a later successful call.

## Admin Boundaries

- Admins cannot rewrite fee configuration after clone initialization.
- Admins cannot create multiple deployed pool identities for the same hook and project path.
- Admins cannot mutate constructor immutables or retroactively change the pool manager or oracle hook.
- Nobody can turn the permissionless fee-collection path into a gated path after deployment.

## Source Map

- `src/JBUniswapV4LPSplitHook.sol`
- `src/JBUniswapV4LPSplitHookDeployer.sol`
- `test/`
