# univ4-lp-split-hook-v6 -- Risks

Forward-looking risk analysis for `JBUniswapV4LPSplitHook`. References to `src/JBUniswapV4LPSplitHook.sol` unless noted.

---

## 1. Trust Assumptions

- **Uniswap V4 PoolManager** -- All LP positions are custodied by PoolManager. A bug or governance change there affects every pool managed by this hook. No migration path exists; positions cannot be moved to a different V4 deployment.
- **Uniswap V4 PositionManager** -- Immutable at construction (line 132). Burn, mint, decrease-liquidity, and fee collection all route through it. If PositionManager is paused or bricked, all LP operations freeze (no fallback).
- **ORACLE_HOOK** -- Baked into every PoolKey (line 1103). A malicious or broken oracle hook can manipulate swap behavior for all pools. Cannot be changed post-deployment.
- **Permit2** -- Used for ERC-20 approvals to PositionManager (lines 1253-1264). A Permit2 exploit could drain approved tokens during the `_mintPosition` window.
- **JB Directory / Controller** -- `controllerOf()`, `primaryTerminalOf()`, and `PROJECTS().ownerOf()` are all trusted. Directory compromise = full hook compromise. `processSplitWith` trusts `msg.sender == controllerOf(projectId)` (line 597) as its sole authentication.
- **Fee routing (38/62 default split)** -- `FEE_PERCENT` and `FEE_PROJECT_ID` are set once in `initialize()` and are immutable thereafter. The fee project must maintain a functioning terminal for the terminal token. If `primaryTerminalOf(FEE_PROJECT_ID, token)` returns `address(0)`, the fee share silently stays in the contract (line 1306 check), eventually absorbed into the next liquidity operation. The remaining 62% still routes correctly.
- **Clone initialization** -- Implementation contract can be `initialize()`d by anyone (NM-004, acknowledged). No practical impact since clones have separate storage, but the implementation's `FEE_PROJECT_ID` / `FEE_PERCENT` could be set to arbitrary values.

---

## 2. Economic Risks

- **LP range derived from bonding curve** -- Tick bounds are computed from `_getCashOutRate` (price floor) and `_getIssuanceRate` (price ceiling), both read from on-chain JB state (lines 262-348). These are spot values, not time-weighted. A single large payment or cashout in the same block can shift the range before `deployPool` or `rebalanceLiquidity` executes.
- **Extreme weight scenarios** -- Weight=1 produces `mulDiv(1e18, 1, 1e18) = 0` project tokens, yielding `sqrtPriceX96 = 0` (invalid). Correctly reverts with `TickMath.InvalidSqrtPrice(0)`. Weight=0 (after full decay) similarly reverts. Very high weight (1e30+) deploys successfully but produces extreme tick values near MIN_TICK/MAX_TICK boundaries.
- **Zero surplus** -- When `cashOutRate == 0`, `_calculateTickBounds` falls back to a minimal range centered on the issuance tick (+/- one TICK_SPACING = 200 ticks, line 931-933). `_computeOptimalCashOutAmount` returns 0 (line 1035), so the entire LP position is single-sided project tokens.
- **Max reserved percent (100%)** -- `_getIssuanceRate` returns 0 because `(10000-10000)/10000 = 0`. Produces `sqrtPriceX96 = 0`, correctly reverts. At 99% reserved, effective issuance is 1% of weight-based rate; deploys but with a very different tick range than lower reserved percents.
- **Dust handling** -- 1 wei accumulated tokens can produce zero liquidity in `LiquidityAmounts.getLiquidityForAmounts`, leading to a zero-liquidity mint. During `_addUniswapLiquidity` this mints a position with 0 liquidity (no explicit guard). During `rebalanceLiquidity`, the `InsufficientLiquidity` revert (line 734) catches this.
- **Rebalance value conservation** -- Rebalance burns old position, collects fees, then mints new. Leftover project tokens are burned via `_burnProjectTokens` (line 1160). Leftover terminal tokens are returned via `_addToProjectBalance` (line 1171). Value is conserved within rounding, but the new position's tick range may not capture all recovered tokens if the price has shifted, causing more leftovers to be burned/returned than optimal.
- **Impermanent loss amplification** -- Concentrated liquidity between cashout and issuance ticks amplifies IL compared to full-range. If market price exits the range, the position becomes 100% single-sided and earns zero fees until rebalanced.
- **Accumulation period idle capital** -- Between first `processSplitWith` and `deployPool`, tokens earn no yield. Value decays as issuance weight drops. The 10x weight decay permissionless threshold (line 558) ensures eventual deployment but may take multiple ruleset cycles.

---

## 3. MEV / Sandwich Risks

- **Rebalance sandwich** -- `rebalanceLiquidity` burns and re-mints in one tx. Between BURN_POSITION and MINT_POSITION, the hook holds raw token balances. A searcher can: (1) front-run with a swap to skew the pool price, (2) let the burn return skewed amounts, (3) back-run to extract value from the new position. `decreaseAmount0Min` / `decreaseAmount1Min` (lines 623-624) provide slippage protection on the burn, but the mint has no explicit slippage params -- it uses whatever `LiquidityAmounts.getLiquidityForAmounts` computes. Default of 0 for min amounts = no protection.
- **collectAndRouteLPFees is permissionless** -- Anyone can trigger fee collection (line 510, no access control). A searcher can time collection to coincide with favorable pool state. Impact is limited because fee collection does not move the pool price -- it only harvests accrued swap fees. However, the `_routeFeesToProject` call pays into the fee project with `minReturnedTokens: 0` (line 1316), allowing MEV extraction on that payment.
- **LP fee extraction timing** -- Fees accrue per-swap in the V4 pool. A searcher who generates swap volume (e.g., wash trading) before calling `collectAndRouteLPFees` can accumulate fees to themselves (as an LP in the same pool range) at the cost of 1% per swap. Not directly extracting from the hook, but gaming the fee distribution.
- **Atomic NFT position swap** -- The burn-then-mint in `rebalanceLiquidity` (lines 670-727) happens atomically within one transaction. No external actor can insert operations between the burn and mint. However, the fee collection step (lines 643-668) is a separate `modifyLiquidities` call from the burn step (lines 670-683), creating two PoolManager unlocks. V4 hooks (ORACLE_HOOK) execute callbacks during each unlock, creating a theoretical reentrancy surface if the oracle hook is malicious.
- **deployPool initial price manipulation** -- An attacker can pay into the project to inflate surplus, causing `_computeInitialSqrtPrice` to return a skewed midpoint. The 2.5% JB protocol fee on payments and the `minCashOutReturn` parameter (line 551) limit the attack's profitability but do not eliminate it.

---

## 4. Rebalance Mechanics

- **Authorization** -- Requires `SET_BUYBACK_POOL` permission from the project owner (line 626-630). Cannot be triggered by arbitrary callers, unlike `collectAndRouteLPFees`. This prevents forced rebalances at manipulated prices.
- **Consecutive rebalance safety** -- Each rebalance burns the old position and mints a new one. The new `tokenIdOf` is written only after a successful mint (line 727). If the mint fails with `InsufficientLiquidity` (line 734), the entire tx reverts, preserving the old position. Two consecutive rebalances work correctly because each reads the current `tokenIdOf` and operates on it.
- **Leftover token handling** -- After minting the new position, `_handleLeftoverTokens` (line 738) burns remaining project tokens and returns remaining terminal tokens to the project balance. This means rebalance is slightly deflationary on the project token side (leftovers are destroyed, not recycled).
- **Fee collection ordering** -- Rebalance collects fees first (Step 1, lines 643-668), routes them, then burns the principal (Step 2, lines 670-683). This ordering is critical: if fees were not collected first, they would be included in the burn amounts and the fee split would apply to principal + fees together (which is what happens for the burn step -- the entire terminal token delta gets fee-split, see SplitHookRegressions test_M1).
- **Zero-liquidity revert guard** -- If after burn, the recovered tokens produce zero liquidity for the new tick range (e.g., price moved entirely out of range), `rebalanceLiquidity` reverts with `InsufficientLiquidity` (line 734). This prevents bricking the position by setting `tokenIdOf = 0`. The downside: rebalance is impossible until conditions change.
- **Pool price vs. Juicebox price divergence** -- The new position's tick bounds are derived from JB bonding curve rates, but the pool's actual price may have diverged due to external swaps. `rebalanceLiquidity` reads the real pool price from `POOL_MANAGER.getSlot0()` for liquidity calculation (ensuring optimal token split), but if the actual pool price is outside the new tick bounds, the minted position is single-sided (one token amount = 0), and `LiquidityAmounts.getLiquidityForAmounts` may return low liquidity.

---

## 5. Price Edge Cases

- **Very low weight (weight < 1e18)** -- `_getProjectTokensOutForTerminalTokensIn` computes `mulDiv(1e18, weight, weightRatio)`. When `weight < weightRatio` (typically 1e18), this truncates to 0. `sqrtPriceX96 = sqrt(0) * Q96 / sqrt(1e18) = 0`. Reverts with `InvalidSqrtPrice(0)`. Safe but means pool cannot be deployed.
- **Very high weight (1e30+)** -- Produces large `projectTokensPerTerminalToken`, pushing the issuance tick near `MAX_TICK`. The clamp at lines 958-961 (`minUsable` / `maxUsable`) prevents TickMath overflow. Deploys but with tick bounds near the V4 boundary -- liquidity is extremely diluted.
- **Zero surplus, nonzero weight** -- `_getCashOutRate` returns 0. `_getCashOutRateSqrtPriceX96` returns `TickMath.MIN_SQRT_PRICE` (line 306). Tick bounds use the issuance-centered fallback (lines 923-934). Pool is initialized at the issuance rate price. Position is 100% project tokens (no terminal tokens paired).
- **Max reserved percent (10000)** -- Effective issuance = 0. Both `_getIssuanceRateSqrtPriceX96` and `_getSqrtPriceX96ForCurrentJuiceboxPrice` return 0. Reverts at pool initialization.
- **Narrow tick ranges** -- When cashout rate is close to issuance rate (high surplus), the tick range collapses toward `tickLower == tickUpper`. The fallback (lines 963-971) centers on the current JB price with +/- one TICK_SPACING. This produces highly concentrated liquidity vulnerable to any price movement.
- **Token ordering inversion** -- When `terminalToken < projectToken` (terminal is token0, e.g., native ETH), the cashout tick can be higher than the issuance tick. Fixed by sorting (lines 951-952), but the inverted ordering means the economic interpretation (cashout=floor, issuance=ceiling) maps to different tick assignments depending on token ordering.
- **Low-decimal terminal tokens (e.g., USDC, 6 decimals)** -- `_getCashOutRate` passes `_getTokenDecimals(terminalToken)` to `currentReclaimableSurplusOf`. With 6 decimals and large token supply, the reclaimable amount can round to 0, triggering the `cashOutRate == 0` fallback. LP range becomes issuance-centered with minimal width.

---

## 6. Access Control

- **`deployPool`** -- Requires `SET_BUYBACK_POOL` permission OR current weight has decayed to <= 1/10th of `initialWeightOf` (line 558). The permissionless path prevents indefinite token lockup by absent owners. When `initialWeightOf == 0` (no accumulation yet), permission is always required (line 558: `initialWeight == 0 || ...`).
- **`rebalanceLiquidity`** -- Always requires `SET_BUYBACK_POOL` permission (line 626-630). No permissionless fallback. A hostile or absent owner can prevent rebalancing indefinitely, leaving the position at stale tick bounds.
- **`collectAndRouteLPFees`** -- Fully permissionless (line 510). Any address can trigger. Enables keeper-based fee harvesting but also enables adversarial timing.
- **`claimFeeTokensFor`** -- Requires `SET_BUYBACK_POOL` permission (line 491-495). Fee tokens accumulate in `claimableFeeTokens[projectId]` and are only withdrawable by the project owner or operator. If unclaimed, tokens sit in the hook contract indefinitely.
- **`processSplitWith`** -- Only callable by `controllerOf(projectId)` (line 597). Validates `context.split.hook == address(this)` (line 593) and `context.groupId == 1` (reserved tokens only, line 599).
- **`initialize`** -- One-shot, no access control. First caller wins. The deployer factory calls it immediately after clone creation (line 70 in deployer). Validates `feePercent <= BPS` and `feeProjectId != 0` when `feePercent > 0`.

---

## 7. Invariants to Verify

- **Token conservation across rebalance** -- Total tokens (hook + PositionManager) should not increase after `rebalanceLiquidity`. Leftover project tokens are burned (deflationary). Leftover terminal tokens are returned to project balance. Verified in `TestAuditGaps.test_Rebalance_ConservesTokenBalances`.
- **No value creation from rebalance** -- The hook cannot mint tokens or create surplus. Rebalance only redistributes existing tokens between the LP position and the project balance. An external observer should see: `position_value_after + leftovers_burned + leftovers_returned <= position_value_before + accrued_fees`.
- **Fee routing completeness** -- For every `collectAndRouteLPFees` or rebalance fee collection: `feeAmount + remainingAmount == totalCollected` (line 1300). The fee project receives `floor(total * FEE_PERCENT / BPS)`, the project receives the rest. Rounding error <= 1 wei per operation.
- **`tokenIdOf` never zero for deployed projects** -- After `deployPool` sets `tokenIdOf != 0`, `rebalanceLiquidity` either updates it to a new nonzero value or reverts entirely (line 734). The invariant `tokenIdOf[projectId][terminalToken] != 0 iff deployedPoolCount[projectId] > 0` should always hold.
- **`accumulatedProjectTokens` cleared on deploy** -- After `_addUniswapLiquidity` succeeds, `accumulatedProjectTokens[projectId]` is set to 0 (line 869). No path exists where tokens are deployed but the accumulator retains a nonzero balance.
- **Cross-project isolation** -- `accumulatedProjectTokens`, `tokenIdOf`, `_poolKeys`, `claimableFeeTokens`, and `deployedPoolCount` are all keyed by `projectId`. Operations on one project must never read or write another project's state.
- **Fee tokens match actual balance** -- `claimableFeeTokens[projectId]` should equal the actual fee project token balance attributable to that project. After `claimFeeTokensFor`, balance is zeroed before transfer (lines 498-499), preventing reentrancy double-claim.
- **Tick bounds always valid** -- `tickLower < tickUpper`, both aligned to TICK_SPACING (200), both within `[MIN_TICK + TICK_SPACING, MAX_TICK - TICK_SPACING]`. The sorting fix (lines 951-952) and clamp (lines 958-961) enforce this.
- **One pool per (projectId, terminalToken)** -- `deployPool` reverts with `PoolAlreadyDeployed` if `tokenIdOf != 0` (line 566). No path creates a second pool for the same pair.

---

## 8. Accepted Behaviors

### 8.1 Fee routing uses `minReturnedTokens: 0` (no slippage floor)

`_routeFeesToProject` pays LP fees into the fee project's terminal with `minReturnedTokens: 0` (lines 1336, 1348). This is by design:

- **Slippage protection is the fee project's responsibility.** The fee project (Juicebox protocol, project ID 1) controls its own data hook and buyback hook, which handle routing and slippage for incoming payments. The LP split hook has no oracle or TWAP reference for the fee project's token price, so any floor it sets would be arbitrary.
- **A non-zero floor would revert on dust amounts.** When `feeAmount` is small (e.g., 1-100 wei), the fee project's weight-based minting via `mulDiv(feeAmount, weight, weightRatio)` can truncate to 0 tokens. Setting `minReturnedTokens: 1` would cause these payments to revert, blocking fee collection for the main project entirely.
- **MEV surface is limited.** The fee payment does not move the LP pool price (it routes to a JB terminal, not V4). A sandwich attacker would need to manipulate the fee project's terminal state, which requires its own payment/cashout cycle — the payoff does not justify the complexity for the small amounts involved (typically 38% of accrued LP swap fees).

### 8.2 Permit2 approval guards `uint160` overflow with explicit revert

`_approveViaPermit2` checks `amount > type(uint160).max` and reverts with `JBUniswapV4LPSplitHook_Permit2AmountOverflow` before the narrowing cast. This is preferred over `SafeCast.toUint160` to avoid an external library dependency for a single check. The overflow condition is unreachable in practice — no ERC-20 in production has supply exceeding `type(uint160).max` (~1.46e48), and Permit2 itself enforces uint160 approval amounts at the protocol level — but the explicit revert provides defense-in-depth against silent truncation.

### 8.3 No runtime balance check in `processSplitWith`

`processSplitWith` accumulates project tokens via `_accumulateTokens` (line 609) without verifying that the contract's actual ERC-20 balance covers the accumulated total. This is safe because:

- **Tokens are transferred before accumulation.** The JB controller transfers tokens to this contract before calling `processSplitWith` (via the split hook mechanism). By the time `_accumulateTokens` increments the counter, the tokens are already in the contract's balance. The accumulator cannot exceed the balance unless an external actor directly transfers tokens out of the contract — which is impossible since only the hook itself initiates transfers.
- **The accumulator is cleared atomically on deploy.** When `deployPool` calls `_addUniswapLiquidity`, the full accumulated balance is used to mint the LP position, and the accumulator is set to 0 (line 869). No partial-use path exists.
- **A runtime check adds gas to every split payment.** `processSplitWith` is called once per reserved token distribution cycle per project. The `balanceOf` SLOAD (~2,100 gas cold) on every call protects against a condition that cannot occur through normal protocol operation.
