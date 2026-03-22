# Administration

Admin privileges and their scope in univ4-lp-split-hook-v6.

## Roles

### 1. Project Owner

- **Assigned by:** Owning the JBProjects ERC-721 NFT for the given `projectId`.
- **Scope:** Per-project. Each project has its own owner, and ownership is verified through `IJBDirectory(DIRECTORY).PROJECTS().ownerOf(projectId)`.
- **Used for:** Gating `deployPool`, `rebalanceLiquidity`, and `claimFeeTokensFor`.

### 2. Authorized Operator (SET_BUYBACK_POOL)

- **Assigned by:** Project owner granting `JBPermissionIds.SET_BUYBACK_POOL` (permission ID 26) via `JBPermissions.setPermission(operator, account, projectId, permissionId, true)`.
- **Scope:** Per-project, per-operator. The operator can act on behalf of the project owner for functions that require `SET_BUYBACK_POOL`.
- **Used for:** Same functions as the project owner -- `deployPool`, `rebalanceLiquidity`, and `claimFeeTokensFor`.

### 3. Hook Deployer (Anyone)

- **Assigned by:** No assignment required. Anyone can call `JBUniswapV4LPSplitHookDeployer.deployHookFor()`.
- **Scope:** Global. The caller becomes the initial context for the deployed clone (their address is included in the CREATE2 salt scoping).

### 4. JB Controller (System Role)

- **Assigned by:** The Juicebox directory's `controllerOf(projectId)` mapping. Not directly assignable by the hook.
- **Scope:** Per-project. Only the controller registered for a given project can call `processSplitWith`.
- **Used for:** Sending reserved tokens to the hook during distribution.

## Privileged Functions

### JBUniswapV4LPSplitHook

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `deployPool(projectId, terminalToken, minCashOutReturn)` | Project owner or SET_BUYBACK_POOL operator. **Becomes permissionless** when the current ruleset weight has decayed to 1/10th or less of `initialWeightOf[projectId]`. | `JBPermissionIds.SET_BUYBACK_POOL` (26) | Per-project, single terminal-token path | Creates a Uniswap V4 pool at the geometric mean of issuance/cashout rates. Cashes out a computed fraction of accumulated project tokens for terminal tokens, mints a concentrated LP position, and transitions the project from accumulation to burn mode. This permanently commits the hook instance to one terminal-token path for that project. |
| `rebalanceLiquidity(projectId, terminalToken, ...)` | Project owner or SET_BUYBACK_POOL operator | `JBPermissionIds.SET_BUYBACK_POOL` (26) | Per-project, per-terminal-token | Burns the existing LP position NFT, collects and routes accrued fees, recalculates tick bounds from current issuance/cashout rates, and mints a new position with updated bounds. Reverts with `InsufficientLiquidity` if the new position would have zero liquidity. (Lines 632-667) |
| `claimFeeTokensFor(projectId, beneficiary)` | Project owner or SET_BUYBACK_POOL operator | `JBPermissionIds.SET_BUYBACK_POOL` (26) | Per-project | Transfers accumulated fee-project tokens to the specified beneficiary address. Validates the caller's permission, not the beneficiary's identity. Zeroes `claimableFeeTokens[projectId]` before transferring. (Lines 490-505) |
| `processSplitWith(context)` | JB Controller (system) | None (checked via `controllerOf`) | Per-project | Only callable by the project's registered controller. Accumulates project tokens (pre-deployment) or burns them (post-deployment). Validates `context.split.hook == address(this)`, `groupId == 1`, and controller identity. (Lines 596-627) |
| `initialize(feeProjectId, feePercent)` | Anyone (once only) | None | Per-clone instance | Sets `FEE_PROJECT_ID` and `FEE_PERCENT` on a clone. Can only be called once per clone (`initialized` flag). In practice, called immediately by the deployer factory. (Lines 215-232) |

### JBUniswapV4LPSplitHookDeployer

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `deployHookFor(feeProjectId, feePercent, salt)` | Anyone | None | Global | Deploys a new hook clone via `LibClone`, calls `initialize()` on it, and registers it in the `JBAddressRegistry`. CREATE2 salt is scoped to `msg.sender`. (Lines 53-85) |

### Permissionless Functions (No Privilege Required)

| Function | Scope | What It Does |
|----------|-------|-------------|
| `collectAndRouteLPFees(projectId, terminalToken)` | Per-project, per-terminal-token | Collects accrued V4 position fees and routes them: `FEE_PERCENT` of terminal token fees to the fee project via `terminal.pay()`, the remainder to the original project via `addToBalanceOf()`. Project token fees are burned. Safe because funds always go to verified project terminals. (Lines 509-549) |
| `isPoolDeployed(projectId, terminalToken)` | View | Returns whether `tokenIdOf[projectId][terminalToken] != 0`. |
| `poolKeyOf(projectId, terminalToken)` | View | Returns the stored `PoolKey` for a deployed pool. |
| `supportsInterface(interfaceId)` | View | Returns `true` for `IJBUniswapV4LPSplitHook` and `IJBSplitHook`. |
| `receive()` | Accepts ETH | Required for cash-out with native ETH and V4 TAKE operations. |

## Lifecycle States

Each project-terminal-token path on the hook transitions through two states:

```
ACCUMULATING --> DEPLOYED (burn mode)
```

| State | Condition | Behavior |
|-------|-----------|----------|
| **ACCUMULATING** | `tokenIdOf[projectId][terminalToken] == 0` | `processSplitWith()` accumulates project tokens in the hook's balance. `deployPool()` is available (permissioned or permissionless after 10x decay). |
| **DEPLOYED** | `tokenIdOf[projectId][terminalToken] != 0` | `processSplitWith()` burns incoming project tokens via the controller. `deployPool()` reverts with `PoolAlreadyDeployed`. `rebalanceLiquidity()` becomes available. LP fee collection is permissionless. |

**Transition:** `deployPool()` is the one-way transition. It cashes out a fraction of accumulated tokens for terminal tokens, creates a Uniswap V4 pool, mints a concentrated LP position, and stores the position's token ID. This transition is irreversible -- there is no mechanism to return to the accumulating state.

**Permissionless deployment trigger:** Once the current ruleset weight decays to 1/10th or less of `initialWeightOf[projectId]`, the `SET_BUYBACK_POOL` permission check is bypassed and anyone can call `deployPool()`. This ensures pools eventually deploy even if the project owner is inactive.

## Immutable Configuration

These values are set at deploy time and cannot be changed afterward.

### Implementation-Level (Constructor, Shared Across All Clones)

| Parameter | Set In | Value Source |
|-----------|--------|-------------|
| `DIRECTORY` | Constructor (line 202) | JBDirectory address |
| `TOKENS` | Constructor (line 207) | JBTokens address |
| `POOL_MANAGER` | Constructor (line 205) | Uniswap V4 PoolManager address |
| `POSITION_MANAGER` | Constructor (line 206) | Uniswap V4 PositionManager address |
| `ORACLE_HOOK` | Constructor (line 203) | Oracle hook (`IHooks`) for all JB V4 pools. Set in `PoolKey.hooks` when creating pools. Provides TWAP via `observe()`. |
| `PERMISSIONS` | Inherited from `JBPermissioned` constructor (line 195) | JBPermissions address |

### Clone-Level (initialize(), Per-Instance)

| Parameter | Set In | Value Source |
|-----------|--------|-------------|
| `FEE_PROJECT_ID` | `initialize()` (line 230) | Project ID receiving LP fee share |
| `FEE_PERCENT` | `initialize()` (line 231) | Basis points (0-10000) of LP fees routed to fee project |

### Protocol Constants (Hardcoded)

| Constant | Value | Purpose |
|----------|-------|---------|
| `BPS` | 10,000 | 100% in basis points |
| `POOL_FEE` | 10,000 | 1% Uniswap V4 fee tier |
| `TICK_SPACING` | 200 | Tick spacing for the 1% fee tier |

## Admin Boundaries

What admins **cannot** do:

1. **Cannot change fee configuration after initialization.** `FEE_PROJECT_ID` and `FEE_PERCENT` are write-once via `initialize()`. The `initialized` flag prevents re-initialization, even by the original deployer.

2. **Cannot withdraw accumulated tokens directly.** There is no `withdraw()` or `rescue()` function. Accumulated project tokens can only exit via `deployPool()` (into LP) or post-deployment burning.

3. **Cannot redirect LP fees to arbitrary addresses.** Fee routing is hardcoded to go through `primaryTerminalOf` for both the fee project and the original project. There is no admin-settable destination.

4. **Cannot modify pool parameters after deployment.** The `PoolKey` (fee tier, tick spacing, hook address, currency pair) is set during `_createAndInitializePool()` and stored immutably in `_poolKeys`.

5. **Cannot deploy a second pool for the same project/terminal-token pair.** `deployPool()` reverts with `PoolAlreadyDeployed` if `tokenIdOf[projectId][terminalToken] != 0`.

6. **Cannot deploy a second terminal-token pool for the same project.** `processSplitWith` only receives the project token, not the terminal token. Once any pool is deployed, the project enters burn mode and `deployPool()` reverts with `OnlyOneTerminalTokenSupported` for other terminal tokens.

7. **Cannot prevent permissionless fee collection.** `collectAndRouteLPFees()` has no access control. Anyone can trigger fee collection and routing for any deployed pool.

8. **Cannot prevent permissionless pool deployment after 10x weight decay.** Once the current ruleset weight drops to 1/10th of `initialWeightOf[projectId]`, the `SET_BUYBACK_POOL` permission check is bypassed and anyone can deploy.

9. **Cannot change the Uniswap V4 infrastructure contracts.** `POOL_MANAGER`, `POSITION_MANAGER`, `ORACLE_HOOK`, `DIRECTORY`, `TOKENS`, and `PERMISSIONS` are immutable, set in the implementation constructor, and shared across all clones.

10. **Cannot control which project tokens are sent via `processSplitWith`.** The controller decides when and how much to distribute. The hook only receives what the JB protocol sends it.

11. **Cannot recover funds sent to the wrong clone.** If tokens are sent directly (not through `processSplitWith`), there is no mechanism to retrieve them. Only project tokens sent via the controller accumulate correctly.
