# Juicebox UniV4 LP Split Hook

## Purpose

Juicebox reserved-token split hook that accumulates project tokens, deploys a Uniswap V4 concentrated liquidity position bounded by the project's issuance and cash-out rates, and routes LP fees back to the project with a configurable fee split.

## Contracts

| Contract | Role |
|----------|------|
| `JBUniswapV4LPSplitHook` | Core split hook. Implements `IJBSplitHook.processSplitWith` to accumulate or burn tokens. Manages V4 pool creation (with `ORACLE_HOOK` for TWAP), LP position minting, fee collection, and liquidity rebalancing. Constructor takes 7 params: `directory`, `permissions`, `tokens`, `poolManager`, `positionManager`, `permit2` (`IAllowanceTransfer`), `oracleHook`. Inherits `JBPermissioned`. Deployed as clones via factory. |
| `JBUniswapV4LPSplitHookDeployer` | Factory that deploys hook clones via `LibClone` (Solady). Supports CREATE2 deterministic deployment. Initializes clones with `feeProjectId` and `feePercent`. Registers each deployed clone in `JBAddressRegistry` so frontends can verify the deployer. |

## Key Functions

### Split Hook

| Function | What it does |
|----------|-------------|
| `processSplitWith(context)` | Called by controller during reserved token distribution. If no pool deployed: accumulates tokens. If pool exists: burns received tokens. Only accepts `groupId == 1` (reserved tokens); reverts on payout splits (`groupId == 0`). |

### Pool Deployment

| Function | What it does |
|----------|-------------|
| `deployPool(projectId, terminalToken, amount0Min, amount1Min, minCashOutReturn)` | Requires `SET_BUYBACK_POOL` permission unless the current ruleset's weight has decayed to 1/10th or less of `initialWeightOf[projectId]` (becomes permissionless). Creates V4 pool at geometric mean of [cashOut, issuance] rates. Computes optimal cash-out fraction, cashes out tokens via terminal, mints concentrated LP position, handles leftovers (burns project tokens, adds terminal tokens to project balance). Sets `projectDeployed = true`. |

### Fee Management

| Function | What it does |
|----------|-------------|
| `collectAndRouteLPFees(projectId, terminalToken)` | **Permissionless.** Collects V4 position fees via `PositionManager.modifyLiquidities()`. Routes terminal token fees: `FEE_PERCENT` to fee project via `terminal.pay()`, remainder to original project via `addToBalanceOf()`. Burns collected project token fees. Tracks fee-project tokens for claiming. |
| `claimFeeTokensFor(projectId, beneficiary)` | Requires `SET_BUYBACK_POOL` permission. Transfers accumulated fee-project tokens to beneficiary. |

### Liquidity Management

| Function | What it does |
|----------|-------------|
| `rebalanceLiquidity(projectId, terminalToken, decreaseAmount0Min, decreaseAmount1Min)` | Requires `SET_BUYBACK_POOL` permission from the project owner. Burns old position (removes all liquidity + collects fees), recalculates tick bounds from current issuance/cashOut rates, mints new position with updated bounds. Routes collected fees. Handles leftovers. |

### Views

| Function | What it does |
|----------|-------------|
| `isPoolDeployed(projectId, terminalToken)` | Returns whether a V4 position exists for this project/token pair. |
| `poolKeyOf(projectId, terminalToken)` | Returns the V4 `PoolKey` for a deployed pool. |
| `supportsInterface(interfaceId)` | Returns `true` for `IJBUniswapV4LPSplitHook` and `IJBSplitHook`. |

### Factory

| Function | What it does |
|----------|-------------|
| `JBUniswapV4LPSplitHookDeployer.deployHookFor(feeProjectId, feePercent, salt)` | Deploys a new hook clone. Salt is scoped to `msg.sender` via `keccak256(abi.encode(msg.sender, salt))`. Pass `bytes32(0)` for plain CREATE. Calls `initialize()` on the new clone. Registers the clone in `JBAddressRegistry` (CREATE via nonce, CREATE2 via salt+bytecode). |

### Internal Pricing

| Function | What it does |
|----------|-------------|
| `_getIssuanceRate(projectId, terminalToken)` | Returns project tokens per terminal token (price ceiling), accounting for reserved rate deduction. |
| `_getCashOutRate(projectId, terminalToken)` | Returns terminal tokens per project token (price floor), via `currentReclaimableSurplusOf`. Returns 0 if call fails. |
| `_getSqrtPriceX96ForCurrentJuiceboxPrice(...)` | Converts Juicebox pricing to V4 sqrtPriceX96 format for sorted token pair. |
| `_computeInitialSqrtPrice(...)` | Geometric mean of cashOut and issuance ticks. Falls back to issuance rate if cashOut is 0. |
| `_computeOptimalCashOutAmount(...)` | For concentrated LP in range [Pa, Pb] at price P, computes the fraction of project tokens to cash out so terminal/project ratio matches LP geometry. Typically 15-30%, capped at 50%. |
| `_calculateTickBounds(...)` | Returns (tickLower, tickUpper) aligned to `TICK_SPACING`, from cashOut (floor) and issuance (ceiling) sqrtPrices. Falls back to +/- one spacing around current price if rates are inverted. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@bananapus/core-v6` | `IJBController`, `IJBDirectory`, `IJBMultiTerminal`, `IJBPermissions`, `IJBSplitHook`, `IJBTerminal`, `IJBTerminalStore`, `IJBTokens`, `JBSplitHookContext`, `JBRuleset`, `JBRulesetMetadataResolver`, `JBConstants` | Juicebox protocol: controller queries, terminal pay/cashOut/addToBalance, permission checks, ruleset weight and pricing |
| `@bananapus/permission-ids-v6` | `JBPermissionIds` | `SET_BUYBACK_POOL` permission ID |
| `@uniswap/v4-core` | `IPoolManager`, `PoolKey`, `PoolId`, `Currency`, `TickMath`, `IHooks` | V4 pool creation, price math, currency handling. `IHooks` used for the `ORACLE_HOOK` (provides TWAP via `observe()`). |
| `@uniswap/v4-periphery` | `IPositionManager`, `Actions`, `LiquidityAmounts` | V4 position management: mint, modify, burn, collect |
| `@openzeppelin/contracts` | `IERC20`, `IERC20Metadata`, `SafeERC20` | Token operations |
| `@prb/math` | `mulDiv`, `sqrt` | Overflow-safe arithmetic for sqrtPriceX96 calculations |
| `@bananapus/address-registry-v6` | `IJBAddressRegistry` | On-chain registry mapping deployed hooks to their deployer contract |
| `solady` | `LibClone` | Clone factory for deploying hook instances |

## Key Types

| Struct | Key Fields | Used In |
|--------|------------|---------|
| `JBSplitHookContext` | `uint256 projectId`, `uint256 groupId`, `address token`, `uint256 amount`, `JBSplit split` | `processSplitWith` -- split execution context from controller |
| `PoolKey` | `Currency currency0`, `Currency currency1`, `uint24 fee`, `int24 tickSpacing`, `IHooks hooks` | `_poolKeys` mapping, V4 pool identification |

## Events

| Event | When |
|-------|------|
| `ProjectDeployed(projectId, terminalToken, poolId)` | V4 pool created and LP position minted |
| `LPFeesRouted(projectId, terminalToken, totalAmount, feeAmount, remainingAmount, feeTokensMinted)` | LP fees collected and distributed |
| `TokensBurned(projectId, token, amount)` | Project tokens burned (Stage 2 or fee collection) |
| `FeeTokensClaimed(projectId, beneficiary, amount)` | Fee-project tokens claimed |
| `HookDeployed(feeProjectId, feePercent, hook, caller)` | New hook clone deployed (from factory) |

## Errors

| Error | When |
|-------|------|
| `JBUniswapV4LPSplitHook_ZeroAddressNotAllowed` | Constructor receives zero address for required parameter |
| `JBUniswapV4LPSplitHook_InvalidProjectId` | Fee project ID doesn't have a controller |
| `JBUniswapV4LPSplitHook_NotHookSpecifiedInContext` | `processSplitWith` called but `context.split.hook != address(this)` |
| `JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal` | `processSplitWith` called by non-controller |
| `JBUniswapV4LPSplitHook_NoTokensAccumulated` | `deployPool` called with zero accumulated tokens |
| `JBUniswapV4LPSplitHook_InvalidStageForAction` | Operation requires deployed pool but none exists |
| `JBUniswapV4LPSplitHook_TerminalTokensNotAllowed` | `processSplitWith` called with `groupId != 1` (payout splits not supported) |
| `JBUniswapV4LPSplitHook_InvalidFeePercent` | `feePercent > BPS` (> 100%) |
| `JBUniswapV4LPSplitHook_InvalidTerminalToken` | No primary terminal found for project/token pair |
| `JBUniswapV4LPSplitHook_PoolAlreadyDeployed` | `deployPool` called for a pair that already has a position |
| `JBUniswapV4LPSplitHook_AlreadyInitialized` | `initialize` called on a clone that was already initialized |
| `JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject` | `initialize` called with `feePercent > 0` but `feeProjectId == 0` (fees would get stuck since `primaryTerminalOf(0, token)` returns `address(0)`) |

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `BPS` | 10,000 | Basis points denominator (100%) |
| `POOL_FEE` | 10,000 (1%) | V4 pool fee tier |
| `TICK_SPACING` | 200 | Tick spacing for 1% fee tier |

## Storage

| Mapping | Type | Purpose |
|---------|------|---------|
| `_poolKeys` | `projectId => terminalToken => PoolKey` | V4 pool key per project/token pair |
| `tokenIdOf` | `projectId => terminalToken => uint256` | V4 PositionManager NFT ID per pool |
| `accumulatedProjectTokens` | `projectId => uint256` | Pre-deployment token accumulation |
| `initialWeightOf` | `projectId => uint256` | Ruleset weight when first tokens were accumulated (for 10x decay check) |
| `projectDeployed` | `projectId => terminalToken => bool` | Whether a V4 pool has been deployed for this project/token pair |
| `deployedPoolCount` | `projectId => uint256` | Number of pools deployed for project (used for accumulate vs burn decision in processSplitWith) |
| `claimableFeeTokens` | `projectId => uint256` | Fee-project tokens claimable via `claimFeeTokensFor` |
| `initialized` | `bool` | Prevents re-initialization of clone instances |
| `ORACLE_HOOK` | `IHooks` (immutable) | Oracle hook for all JB V4 pools. Set in constructor. All pools are created with this hook in the `PoolKey.hooks` field, providing TWAP via `observe()`. |

## Gotchas

1. **This is a V4 hook, not V3.** Despite the repo history, the current implementation uses Uniswap V4 (`IPoolManager`, `IPositionManager`, `PoolKey`, `Actions`). All V3 references in older docs are outdated.
2. **Requires `via_ir = true` in foundry.toml.** Stack-too-deep errors occur without the IR pipeline, particularly in `_addUniswapLiquidity` and V4 `PositionManager` interactions.
3. **Only accepts reserved-token splits (`groupId == 1`).** Reverts with `TerminalTokensNotAllowed` if called from a payout split (`groupId == 0`). This is intentional -- it only manages project tokens.
4. **`deployPool` requires `SET_BUYBACK_POOL` permission, unless weight has decayed 10x.** The caller must be the project owner or have been granted this permission via `JBPermissions`. However, if the current ruleset's weight has decayed to 1/10th or less of the weight when the hook first started accumulating tokens (`initialWeightOf`), anyone can call `deployPool`. This prevents a stale owner from blocking LP deployment indefinitely.
5. **`collectAndRouteLPFees` is permissionless.** Anyone can call it. Safe because it only operates on existing positions and routes funds to verified project terminals. **`rebalanceLiquidity` requires `SET_BUYBACK_POOL` permission** from the project owner.
6. **`claimFeeTokensFor` requires `SET_BUYBACK_POOL` permission** from the project owner. It validates the caller, not the beneficiary.
7. **Cash-out fraction is geometrically optimized, not 50/50.** `_computeOptimalCashOutAmount` uses concentrated liquidity math to compute the exact ratio needed, typically 15-30%. Safety-capped at 50%.
8. **Pool initialization price is the geometric mean** of [cashOutRate, issuanceRate] in tick space. Falls back to issuance rate if cash-out rate is 0 or ticks are equal.
9. **All pools are created with `ORACLE_HOOK`.** The `PoolKey.hooks` field is set to the immutable `ORACLE_HOOK` (an `IHooks` providing TWAP via `observe()`), not `IHooks(address(0))`. This means all deployed pools go through the oracle hook for swap callbacks.
10. **One LP position per project/terminal-token pair.** The hook manages a single V4 NFT position. Rebalancing burns the old NFT and mints a new one, briefly leaving no active position.
11. **After deployment, newly received reserved tokens are burned.** This is intentional -- prevents inflating the project token supply without corresponding LP rebalancing.
12. **Native ETH handling:** Juicebox uses `JBConstants.NATIVE_TOKEN` (`0x000000000000000000000000000000000000EEEe`), V4 uses `Currency.wrap(address(0))`. The hook converts between them via `_toCurrency()`. The contract has `receive() external payable {}` to accept ETH during cash-outs and V4 TAKE operations.
13. **Deployed as clones via factory.** `JBUniswapV4LPSplitHookDeployer` uses Solady's `LibClone`. The constructor takes 7 params (`directory`, `permissions`, `tokens`, `poolManager`, `positionManager`, `permit2`, `oracleHook`) and sets shared infrastructure. Per-clone config (fee project, fee percent) is set via `initialize()`, which can only be called once.
14. **Tick alignment:** All ticks are aligned to `TICK_SPACING = 200`. Negative ticks use floor semantics in `_alignTickToSpacing()`.
15. **`minCashOutReturn = 0` defaults to 1% tolerance.** If no minimum is specified for `deployPool`, the hook applies a 1% slippage tolerance on the cash-out automatically.
16. **Fee routing splits terminal token fees only.** Project token fees are always burned. Terminal token fees are split: `FEE_PERCENT` to fee project via `terminal.pay()`, remainder to original project via `addToBalanceOf()`.
17. **Deterministic clone deployment** via CREATE2 uses `keccak256(abi.encode(msg.sender, salt))`, so different callers with the same salt get different addresses.

## Example Integration

```solidity
import {JBUniswapV4LPSplitHook} from "@bananapus/univ4-lp-split-hook-v6/src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookDeployer} from "@bananapus/univ4-lp-split-hook-v6/src/JBUniswapV4LPSplitHookDeployer.sol";
import {IJBUniswapV4LPSplitHook} from "@bananapus/univ4-lp-split-hook-v6/src/interfaces/IJBUniswapV4LPSplitHook.sol";

// --- Deploy a hook clone via the factory ---

IJBUniswapV4LPSplitHook hook = deployer.deployHookFor({
    feeProjectId: 1,             // fee-project receives share of LP fees
    feePercent: 3800,            // 38% of LP fees to fee project
    salt: bytes32("my-hook")     // deterministic address (or bytes32(0) for CREATE)
});

// --- Configure as a reserved-token split in a Juicebox ruleset ---
// JBSplit({ ... hook: address(hook), ... })

// --- After enough tokens accumulate, deploy the pool ---

hook.deployPool({
    projectId: projectId,
    terminalToken: JBConstants.NATIVE_TOKEN,  // ETH
    amount0Min: 0,                            // slippage (0 = no check)
    amount1Min: 0,                            // slippage (0 = no check)
    minCashOutReturn: 0                       // 0 = auto 1% tolerance
});

// --- Periodically collect and route LP fees (permissionless) ---

hook.collectAndRouteLPFees(projectId, JBConstants.NATIVE_TOKEN);

// --- Rebalance when rates change significantly (permissionless) ---

hook.rebalanceLiquidity({
    projectId: projectId,
    terminalToken: JBConstants.NATIVE_TOKEN,
    decreaseAmount0Min: 0,
    decreaseAmount1Min: 0,
    increaseAmount0Min: 0,
    increaseAmount1Min: 0
});

// --- Claim accumulated fee-project tokens (requires permission) ---

hook.claimFeeTokensFor(projectId, beneficiaryAddress);
```
