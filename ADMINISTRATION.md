# Administration

## At a glance

| Item | Details |
| --- | --- |
| Scope | Per-project LP split hook lifecycle from accumulation to live Uniswap V4 LP management |
| Control posture | Permissionless lifecycle (deploy, recycle via `addLiquidity` or reserved distribution, fee collection); only fee claiming is gated to the project owner or `SET_BUYBACK_POOL` delegate |
| Highest-risk actions | Premature `deployPool(...)`, recycle timing at a skewed spot, and bad hook initialization |
| Recovery posture | Usually requires replacement hooks or future split reconfiguration; there is no rollback to accumulation mode |

## Purpose

`univ4-lp-split-hook-v6` is administered per project path, with one major irreversible transition: the move from accumulation mode to deployed LP mode. The key admin surface is the fee-claim path, gated by project ownership or `SET_BUYBACK_POOL`; pool deployment, recycles, and fee collection are permissionless, bounded by economic and oracle-TWAP guards.

## Control model

- Project owner or `SET_BUYBACK_POOL` delegate controls only the fee-claim path (`claimFeeTokensFor`).
- The deployer path is permissionless for creating a new hook instance.
- Pool deployment, recycles (`addLiquidity`, and the inline attempt on every reserved distribution), and fee collection are permissionless.
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
| `JBUniswapV4LPSplitHook` | `addLiquidity(...)` | Anyone (permissionless), at any time, bounded by an oracle-TWAP deviation check | Recycles the project's ask and bid: collects fees, burns both, re-mints both single-sided around the live spot inside the corridor |
| `JBUniswapV4LPSplitHook` | `collectAndRouteLPFees(...)` | Anyone (permissionless) | Collects fees from the ask and bid into the project's ledgers, net of the best-effort fee-project cut |
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
- Review the recycle as collect, burn, recompute, and mint across both positions together.
- Treat fee-token and credit-claim paths as retry-sensitive; some downstream failures preserve pending state for later recovery.

## Machine notes

- Do not treat `deployPool(...)` as a reversible setup step.
- Inspect `src/JBUniswapV4LPSplitHook.sol` and the clone initialization path together before documenting authority.
- If live pool identity or initialization params differ from intended config, stop and use a replacement hook path.
- If a recycle reverts `NoDeployableLiquidityAtSpot` or a fee-claim flow leaves pending credits, analyze preserved state (the live positions and ledgers survive) before assuming the project is bricked.
- `LiquidityAutomationFailed` on a distribution is not a loss: the tokens are in the ledgers and `addLiquidity` retries the recycle.

## Recovery

- If a hook instance was initialized or deployed against the wrong path, use a replacement hook instance and update split config for future flows.
- The same path adopts a new hook version: the two-position hook ships as a new deployer, and clones of earlier deployments (for example 1.4.0) keep their own behavior until the project re-points its reserved-token split to a new clone.
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
