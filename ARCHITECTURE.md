# univ4-lp-split-hook-v6 — Architecture

## Purpose

Uniswap V4 liquidity pool deployment hook for Juicebox V6. Receives project tokens via reserved token splits, accumulates them until a deployment threshold is met, then creates one Uniswap V4 pool for the project and provides initial liquidity. After deployment, burns new tokens and routes LP fees back to the project.

**Requirement:** The project must have a deployed ERC-20 token (via `JBTokens.deployERC20For`). Projects using only internal credits (`tokenOf == address(0)`) are rejected — credits cannot be paired as Uniswap V4 LP. `processSplitWith` reverts with `InvalidProjectId` if the token is `address(0)`.

## Contract Map

```
src/
├── JBUniswapV4LPSplitHook.sol         — Split hook: token accumulation, pool deployment (with oracle hook), LP management
├── JBUniswapV4LPSplitHookDeployer.sol — Factory for deploying split hooks
└── interfaces/
    ├── IJBUniswapV4LPSplitHook.sol
    └── IJBUniswapV4LPSplitHookDeployer.sol
```

## Key Data Flows

### Pre-Deployment (Accumulation)
```
Reserved token distribution → JBController.sendReservedTokensToSplitsOf()
  → Split to JBUniswapV4LPSplitHook.processSplitWith()
    → Record initialWeightOf on first call (for permissionless deployment threshold)
    → Accumulate project tokens in accumulatedProjectTokens[projectId]
    → Verify ERC-20 balance covers accumulated total (defense-in-depth)

Owner/Operator → deployPool(projectId, terminalToken, minCashOutReturn)
  → Validate: tokens accumulated, no pool exists for this project (deployedPoolCount == 0)
  → Increment deployedPoolCount (flips project to burn mode before external calls)
  → Create Uniswap V4 pool (projectToken/terminalToken) with ORACLE_HOOK
  → Cash out a computed fraction of accumulated tokens to get terminal tokens for pairing
  → Provide initial two-sided liquidity from both token balances
  → Burn any leftover project tokens, return leftover terminal tokens to project balance
```

**Pool deployment constraint:** Only one pool can exist per project across all terminal tokens. `deployedPoolCount[projectId]` is checked and incremented during `deployPool`, and `processSplitWith` cannot distinguish which terminal token a reserved-token distribution is intended for. Once any pool is deployed, the project permanently switches from accumulation to burn mode.

**Permissionless deployment:** If the current ruleset weight has decayed to 10% or less of the `initialWeightOf` value (recorded on first accumulation), anyone can call `deployPool` without `SET_BUYBACK_POOL` permission. This prevents indefinite accumulation if the project owner is inactive.

### Post-Deployment (Burn and Maintain)
```
Reserved token distribution → processSplitWith()
  → Burn all newly received project tokens via the controller (no more accumulation)

Anyone → collectAndRouteLPFees(projectId, terminalToken)
  → Collect accrued Uniswap trading fees (DECREASE_LIQUIDITY with 0 amount + TAKE_PAIR)
  → Route terminal-token fees to project balance (minus configurable FEE_PERCENT to fee project)
  → Burn any project-token fees to avoid inflating supply

Owner/Operator → rebalanceLiquidity(projectId, terminalToken, decreaseAmount0Min, decreaseAmount1Min)
  → Requires SET_BUYBACK_POOL permission
  → Step 1: Collect and route any accrued LP fees (same as collectAndRouteLPFees)
  → Step 2: Burn the existing LP position NFT, recovering all principal (both tokens) to this contract
  → Step 3: Recalculate tick bounds from current issuance rate (ceiling) and cash-out rate (floor)
  → Step 4: Mint a new LP position with the updated tick range using recovered tokens
  → Step 5: Route leftover tokens back to the project
  → Reverts with InsufficientLiquidity if the new position would have zero liquidity
```

**When to rebalance:** As a project's ruleset weight decays or its surplus changes, the issuance rate (price ceiling) and cash-out rate (price floor) shift. The LP tick bounds are derived from these rates, so the existing position may no longer span the active trading range. Rebalancing destroys the old position and creates a new one with tick bounds matching the current protocol rates, keeping liquidity concentrated where trades actually happen.

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Split hook | `IJBSplitHook` | Receives tokens from reserved distribution |
| Pool deployment | Uniswap V4 PositionManager | Creates and manages LP positions. Pools use `ORACLE_HOOK` (`IHooks`) for TWAP via `observe()`. |

## Design Decisions

**Why burn tokens after pool deployment instead of continuing to add liquidity?**
Once a pool is deployed, `processSplitWith` burns all newly received project tokens instead of accumulating more. Adding liquidity requires pairing project tokens with terminal tokens (e.g. ETH), which the hook does not receive via reserved splits — it only receives project tokens. The initial deployment solves this by cashing out a fraction of accumulated project tokens to obtain terminal tokens for pairing. Post-deployment, continuously cashing out to pair would degrade the project's surplus. Burning reduces circulating supply, which strengthens the remaining LP position and cash-out value for holders.

**Why require an accumulation threshold before pool deployment?**
A Uniswap V4 pool needs two-sided liquidity to function. The hook receives only project tokens through reserved splits, and must cash out some of them to obtain terminal tokens for the other side. Accumulating a meaningful balance before deployment ensures the pool launches with enough depth for trading. Deploying too early with thin liquidity would result in extreme slippage and poor price discovery.

**Why one pool per project (not per terminal token)?**
`processSplitWith` receives project tokens from reserved-token distributions via the controller, but the split hook context (`groupId == 1`) does not carry information about which terminal token the distribution relates to. The hook cannot route incoming tokens to different pools for different terminal tokens. Once any pool is deployed, `deployedPoolCount` is incremented and the project permanently enters burn mode for all subsequent `processSplitWith` calls.

**Why use reserved token splits as the funding mechanism?**
Reserved tokens are minted as part of the project's issuance schedule — they represent the project's share of newly issued tokens. Routing a split to this hook channels a predictable fraction of each distribution into LP formation without requiring the project owner to manually fund the pool or divert payment terminal funds. This makes LP bootstrapping automatic and proportional to project activity.

**Why initialize the pool price at the geometric mean of cash-out and issuance rates?**
The cash-out rate represents the price floor (what holders can redeem for) and the issuance rate represents the price ceiling (what new buyers pay). The pool price should sit between these bounds so that liquidity is active in both directions. The geometric mean (midpoint of the two ticks) balances the LP position across both sides, avoiding a configuration where all liquidity is single-sided at launch.

## Dependencies
- `@bananapus/core-v6` — Core protocol
- `@bananapus/permission-ids-v6` — SET_BUYBACK_POOL permission
- `@bananapus/ownable-v6` — JB ownership
- `@openzeppelin/contracts` — SafeERC20, Ownable
- `@prb/math` — mulDiv, sqrt
- `@uniswap/v4-core` — Pool manager, currency types
- `@uniswap/v4-periphery` — Position manager, actions
- `@rev-net/core-v6` — Revnet integration
