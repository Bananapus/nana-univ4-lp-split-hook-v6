# Administration

## At a glance

| Item | Details |
| --- | --- |
| Scope | Per-project LP split hook lifecycle from accumulation to live Uniswap V4 LP management |
| Control posture | Permissionless lifecycle (deploy, add, rebalance, fee collection); only fee claiming is gated to the project owner or `SET_BUYBACK_POOL` delegate |
| Highest-risk actions | Premature `deployPool(...)`, incorrect rebalance assumptions, and bad hook initialization |
| Recovery posture | Usually requires replacement hooks or future split reconfiguration; there is no rollback to accumulation mode |

## Purpose

`univ4-lp-split-hook-v6` is administered per project path, with one major irreversible transition: the move from accumulation mode to deployed LP mode. The key admin surface is the fee-claim path, gated by project ownership or `SET_BUYBACK_POOL`; pool deployment, liquidity adds, rebalances, and fee collection are permissionless, bounded by economic and oracle-TWAP guards.

## Control model

- Project owner or `SET_BUYBACK_POOL` delegate controls only the fee-claim path (`claimFeeTokensFor`).
- The deployer path is permissionless for creating a new hook instance.
- Pool deployment, liquidity adds, rebalancing, and fee collection are permissionless.
- The deployer's hook implementation is immutable, and chain-specific V4 constants are configured once. Each clone receives the pool manager, position manager, and oracle hook during one-time initialization.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Project owner | `JBProjects.ownerOf(projectId)` through directory lookup | Per project | May delegate through `JBPermissions` |
| Pool delegate | `SET_BUYBACK_POOL` permission | Per project | Controls the fee-claim path (`claimFeeTokensFor`) |
| Hook deployer caller | Anyone | Per new hook instance | Can deploy a clone through the deployer |

## Privileged surfaces

| Contract | Function | Who Can Call | Effect |
| --- | --- | --- | --- |
| `JBUniswapV4LPSplitHook` | `deployPool(...)` | Anyone (permissionless); the seed reverts once spot reaches the issuance ceiling | Irreversibly transitions a project path into deployed LP mode |
| `JBUniswapV4LPSplitHook` | `addLiquidity(...)` | Anyone (permissionless), bounded by an oracle-TWAP deviation check | Folds accumulated post-deploy reserved tokens into the single position (burn prior, re-mint one) |
| `JBUniswapV4LPSplitHook` | `rebalanceLiquidity(...)` | Anyone (permissionless), bounded by a corridor-drift threshold and an oracle-TWAP deviation check | Rebuilds the LP position within the current economic envelope |
| `JBUniswapV4LPSplitHook` | `claimFeeTokensFor(...)` | Project owner or `SET_BUYBACK_POOL` delegate | Claims fee-project token balances |
| `JBUniswapV4LPSplitHookDeployer` | `deployHookFor(...)` | Anyone | Deploys and initializes a new hook clone |

## Immutable and one-way

- Clone initialization is one-time.
- `deployPool(...)` is the irreversible lifecycle transition.
- Fee-project configuration on a clone is fixed at initialization.
- Constructor dependencies such as directory and permissions are immutable.
- The deployer's hook implementation is constructor-immutable.
- The deployer's pool manager, position manager, and oracle hook are one-shot configured via `setChainSpecificConstants`.
- Each clone's pool manager, position manager, and oracle hook are fixed at initialization.

## Operational notes

- Validate terminal token and expected economic bounds before calling `deployPool(...)`.
- Treat the accumulate-to-deployed transition as a treasury policy decision, not a routine action.
- Review rebalance logic as remove, collect, recompute, and mint together.
- Treat fee-token and credit-claim paths as retry-sensitive; some downstream failures preserve pending state for later recovery.

## Machine notes

- Do not treat `deployPool(...)` as a reversible setup step.
- Inspect `src/JBUniswapV4LPSplitHook.sol` and the clone initialization path together before documenting authority.
- If live pool identity or initialization params differ from intended config, stop and use a replacement hook path.
- If rebalance or fee-claim flows leave pending credits or hit zero-liquidity reverts, analyze preserved state before assuming the project is bricked.

## Recovery

- If a hook instance was initialized or deployed against the wrong path, use a replacement hook instance and update split config for future flows.
- There is no generic rollback to accumulation mode.
- Some downstream controller failures are intentionally retryable because pending credits or fee-claim state can remain preserved.

## Admin boundaries

- Admins cannot rewrite fee configuration after clone initialization.
- Admins cannot create multiple deployed pool identities for the same hook and project path.
- Admins cannot mutate constructor immutables, the deployer's one-shot V4 constants, or a clone's initialized pool manager or oracle wiring.
- Nobody can turn the permissionless fee-collection path into a gated path after deployment.

## Source map

- `src/JBUniswapV4LPSplitHook.sol`
- `src/JBUniswapV4LPSplitHookDeployer.sol`
- `test/`
