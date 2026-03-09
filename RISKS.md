# univ4-lp-split-hook-v6 -- Risks

Deep implementation-level risk analysis. Line references are to `src/UniV4DeploymentSplitHook.sol` unless otherwise noted.

## Trust Assumptions

1. **Project Owner** -- Can trigger pool deployment (`deployPool`, line 491) and manage LP positions (`rebalanceLiquidity`, line 559). Has `SET_BUYBACK_POOL` permission and can delegate it. Cannot modify fee configuration post-initialization.
2. **Uniswap V4 Pool Manager + Position Manager** -- LP positions are managed through V4 PositionManager (immutable at line 107). Pool manager bugs or governance changes could affect all positions managed by this hook. The hook has no way to migrate positions to a different V4 deployment.
3. **JB Core Protocol** -- The hook trusts that `controllerOf(projectId)` returns the legitimate controller (line 537-539), that `processSplitWith` is called with accurate `context.amount` (line 534), and that `primaryTerminalOf` resolves correctly (line 236, 346-347, 521-522). Compromise of the JB directory would break all assumptions.
4. **Price Oracle (Implicit)** -- Initial pool price is derived from the project's bonding curve rates via `currentReclaimableSurplusOf` (line 238) and `currentRulesetOf` weight (line 290, 344, 401). These are on-chain reads, not external oracle feeds. Manipulation requires changing the project's actual surplus or ruleset weight.
5. **Fee Project** -- The `FEE_PROJECT_ID` must have a functioning terminal that accepts the terminal token. If the fee project's terminal disappears or reverts, fee routing silently fails (the terminal check at line 1105 returns early, and the fee amount is retained in the contract).

## Audit History

A Nemesis audit (`.audit/findings/nemesis-verified.md`) identified 6 true positives. All findings have been addressed in the current codebase:

| Finding | Severity | Status | Fix Applied |
|---------|----------|--------|-------------|
| NM-001: Permissionless rebalance bricks LP | HIGH | **Fixed** | Added `SET_BUYBACK_POOL` permission check to `rebalanceLiquidity` (line 569-573). Added `InsufficientLiquidity` revert guard when new position would have zero liquidity (line 646-652). |
| NM-002: Placeholder disables fee routing in rebalance | MEDIUM | **Fixed** | Replaced `_getAmountForCurrency()` with balance-delta tracking in `rebalanceLiquidity` (lines 587-602), matching the pattern used in `collectAndRouteLPFees`. |
| NM-003: Per-project flag prevents multi-terminal-token pools | MEDIUM | **Fixed** | Changed `projectDeployed` to `mapping(uint256 => mapping(address => bool))` (line 129). Added `deployedPoolCount` (line 134) for the accumulate-vs-burn decision in `processSplitWith` (line 545). |
| NM-004: Implementation contract initializable by anyone | LOW | **Acknowledged** | The implementation is not intended for direct use. Clones have separate storage. Low practical impact. |
| NM-005: Dead variables in rebalanceLiquidity | LOW | **Fixed** | Dead variables removed; balance-delta tracking replaces them. |
| NM-006: _poolKeys not cleared when tokenIdOf zeroed | LOW | **Mitigated** | `rebalanceLiquidity` now reverts instead of zeroing `tokenIdOf` (line 652), making the stale-data path unreachable. |

## Known Risks

### Severity: HIGH

#### H-1. Rebalance Sandwich Attack (MEV)

- **Severity:** HIGH
- **Tested:** Partially. `RebalanceTest.t.sol` tests the function mechanics and authorization but does not simulate MEV sandwich attacks.
- **Lines:** 559-658 (rebalanceLiquidity), specifically 607-613 (BURN_POSITION + TAKE_PAIR)
- **Description:** `rebalanceLiquidity` burns the entire LP position and mints a new one in a single transaction. Between the BURN_POSITION (which removes liquidity at the current pool price) and MINT_POSITION (which adds liquidity at new tick bounds), the hook holds both token types as raw balances. A sophisticated MEV bot can sandwich this transaction:
  1. Front-run: Swap in the V4 pool to move the price to one extreme of the tick range, making the BURN return skewed token amounts.
  2. The rebalance executes, minting a new position at the manipulated price point.
  3. Back-run: Swap back, extracting value from the new position's skewed liquidity.
- **Slippage parameters** (`decreaseAmount0Min`, `decreaseAmount1Min`, `increaseAmount0Min`, `increaseAmount1Min`) provide some protection but require the caller to set them correctly. The default of `0` offers no protection.
- **Mitigation:** Callers should use private mempools (e.g., Flashbots Protect) and set non-zero slippage parameters. The 1% fee tier (POOL_FEE = 10,000) increases the cost of sandwich attacks.

#### H-2. collectAndRouteLPFees Sandwich Attack (MEV)

- **Severity:** HIGH
- **Tested:** `FeeRoutingTest.t.sol` tests fee arithmetic and routing but not MEV vectors.
- **Lines:** 459-488 (collectAndRouteLPFees), specifically 471-477 (DECREASE_LIQUIDITY + TAKE_PAIR)
- **Description:** `collectAndRouteLPFees` is permissionless (no access control). A MEV bot can:
  1. Observe a pending `collectAndRouteLPFees` transaction.
  2. Front-run: Swap in the pool to manipulate the price, affecting the value of collected fees.
  3. The fee collection executes, routing fees at the manipulated value.
  4. Back-run: Swap back.
- **Impact is lower than H-1** because fee collection only touches accrued fees (not the full position principal), but large accumulated fees create meaningful MEV opportunities.
- **Mitigation:** The 1% pool fee makes sandwich attacks costly relative to extracted value. Frequent fee collection reduces the size of any single extraction.

### Severity: MEDIUM

#### M-1. Impermanent Loss on Concentrated Liquidity

- **Severity:** MEDIUM (inherent to AMM design)
- **Tested:** Not directly tested. The tick bounds are tested in `PriceMathTest.t.sol` (test_TickBounds_Normal, test_TickBounds_AlignedToSpacing).
- **Lines:** 798-820 (_calculateTickBounds), 862-922 (_computeOptimalCashOutAmount)
- **Description:** The LP position is concentrated between the cashout rate (price floor, line 807) and issuance rate (price ceiling, line 808). If the market price moves outside this range, the position becomes 100% single-sided and stops earning fees. Concentrated liquidity amplifies impermanent loss compared to full-range V3/V2 positions. With a 1% fee tier and 200-tick spacing, the position range is relatively wide, limiting but not eliminating this risk.
- **Mitigation:** `rebalanceLiquidity` allows repositioning to track changing rates. The tick range is derived from the project's actual issuance and cashout parameters, so it tracks fundamental value.

#### M-2. Initial Pool Price Manipulation

- **Severity:** MEDIUM
- **Tested:** `PriceMathTest.t.sol` tests the geometric mean calculation (test_GeometricMean_BetweenBounds, test_GeometricMean_FallbackOnZeroCashOut). `WeightDecayDeployTest.t.sol` tests the weight-zero edge case.
- **Lines:** 822-859 (_computeInitialSqrtPrice), 702-706 (cash-out amount computation)
- **Description:** The initial pool price is the geometric mean of the cashout and issuance rates (line 851). These rates are derived from on-chain state (`currentReclaimableSurplusOf` at line 238, `currentRulesetOf` at line 290). If an attacker can manipulate the project's surplus (by paying in then cashing out) or trigger a ruleset change just before `deployPool`, the initial price will be skewed.
- **Attack scenario:**
  1. Attacker pays a large amount into the project, inflating surplus.
  2. Owner calls `deployPool`, which computes the initial price from the inflated surplus.
  3. Pool is created at an artificially high cashout rate.
  4. Attacker cashes out, reducing surplus back to normal.
  5. The pool's initial price is now misaligned, creating arbitrage profit for the attacker.
- **Mitigation:** The bonding curve math in JB core limits the degree of price manipulation. The `minCashOutReturn` parameter (line 496) provides slippage protection on the cash-out portion. The 1% auto-tolerance (line 716-721) provides a default safety margin.

#### M-3. Token Accumulation Period: No Yield, Counterparty Risk

- **Severity:** MEDIUM
- **Tested:** `AccumulationStageTest.t.sol` covers accumulation mechanics. `DeploymentStageTest.t.sol` tests the transition.
- **Lines:** 665-667 (_accumulateTokens), 545-551 (processSplitWith accumulation branch)
- **Description:** Between the first `processSplitWith` call and the eventual `deployPool`, project tokens sit in the contract earning no yield. During this period:
  - The contract holds raw ERC-20 tokens with no protective mechanism.
  - Token value may decrease as the project's issuance rate decays (the weight cut mechanism).
  - If the project owner never calls `deployPool`, tokens are stranded until weight decays 10x (line 506) and becomes permissionless.
- **Mitigation:** The 10x weight decay permissionless deployment (line 500-512, tested in `WeightDecayDeployTest.t.sol`) ensures pools can eventually be deployed even without owner cooperation. The `initialWeightOf` tracking (line 547-549) records the weight at first accumulation.

#### M-4. Rebalance Reverts: Temporary Position Gap

- **Severity:** MEDIUM
- **Tested:** `M31_StaleTokenIdOf.t.sol` tests the `InsufficientLiquidity` revert. `UniV4DeploymentSplitHook_AuditFindings.t.sol` (test_H2_rebalance_zeroLiquidity_reverts) confirms the guard.
- **Lines:** 605-614 (BURN_POSITION in rebalanceLiquidity), 638-653 (liquidity check and revert)
- **Description:** `rebalanceLiquidity` burns the old position (line 607-613) before minting the new one (line 641-643). If the MINT_POSITION step fails (e.g., due to price moving outside tick bounds causing zero liquidity), the transaction reverts with `InsufficientLiquidity` (line 652), rolling back the burn. This is the correct behavior (prevents bricking), but it means the rebalance cannot succeed until conditions change. During the revert, no state changes occur, and the old position remains intact.
- **Edge case:** If the V4 PositionManager itself has a bug or is paused, neither burn nor mint would succeed, effectively freezing the position in place.

#### M-5. Fee Project Terminal Disappearance

- **Severity:** MEDIUM
- **Tested:** `L25_FeeProjectIdValidation.t.sol` tests the `initialize` validation. Fee routing is tested in `FeeRoutingTest.t.sol`.
- **Lines:** 1103-1137 (_routeFeesToProject), specifically 1103-1105 (fee terminal lookup)
- **Description:** If the fee project's primary terminal for the terminal token is removed or changed to `address(0)`, the fee routing silently skips the fee payment (line 1105: `if (feeTerminal != address(0))`). The `feeAmount` is computed (line 1098) but never transferred. The terminal token fee amount is retained in the contract and eventually gets absorbed into the next liquidity operation.
- **Mitigation:** The `initialize` validation (line 184-188) checks that the fee project has a controller at initialization time. However, the terminal could be removed later. This is a graceful degradation -- the project's share (`remainingAmount`) is still routed correctly.

### Severity: LOW

#### L-1. Implementation Contract Initializable

- **Tested:** `M32_ReinitAfterRenounce.t.sol` tests clone re-initialization prevention.
- **Lines:** 177-194 (initialize)
- **Description:** The implementation contract deployed by the factory never calls `initialize` in its constructor. Anyone can call `initialize()` on the implementation with arbitrary parameters. This has no practical impact because clones have separate storage, and the implementation is not used directly.

#### L-2. processSplitWith Burns for All Terminal Tokens After First Pool

- **Tested:** `UniV4DeploymentSplitHook_AuditFindings.t.sol` (test_M2_processSplitWith_burnsAfterDeploy, test_M2_multiTerminalToken_independentFlags).
- **Lines:** 545 (deployedPoolCount check), 134 (deployedPoolCount mapping)
- **Description:** `processSplitWith` uses `deployedPoolCount[projectId]` (per-project, not per-terminal-token) to decide whether to accumulate or burn (line 545). Once any pool is deployed for a project, all subsequent reserved token splits burn tokens. This prevents accumulation for a second terminal token's pool. The `JBSplitHookContext` does not include the terminal token, so per-token accumulation is not possible with the current interface.
- **Mitigation:** This is a known architectural constraint. To deploy pools for multiple terminal tokens, the project must deploy separate hook clones.

#### L-3. Irreversible Pool Deployment

- **Tested:** `DeploymentStageTest.t.sol` (test_DeployPool_RevertsIf_PoolAlreadyDeployed).
- **Lines:** 514 (PoolAlreadyDeployed check), 527 (projectDeployed set to true)
- **Description:** Once `deployPool` succeeds, there is no way to undeploy, reconfigure, or redeploy the pool for the same project/terminal-token pair. The `projectDeployed` flag is a one-way latch. If the pool is deployed at a suboptimal price or with wrong parameters, the only remedy is `rebalanceLiquidity` (which adjusts tick bounds but cannot change the pool's fee tier, hook address, or currency pair).

#### L-4. Rounding in Fee Split Arithmetic

- **Tested:** `FeeRoutingTest.t.sol` (test_RouteFees_SplitsBetweenFeeAndOriginal) tests the split with 1000e18.
- **Lines:** 1098 (fee calculation: `feeAmount = (amount * FEE_PERCENT) / BPS`)
- **Description:** Integer division truncates in favor of the original project (the fee project receives slightly less). For a 38% fee with an amount of `N`, the fee project receives `floor(N * 3800 / 10000)` and the project receives `N - floor(N * 3800 / 10000)`. The rounding error is at most 1 wei per fee routing operation. This matches the Juicebox core convention.

#### L-5. No Reentrancy Guard

- **Tested:** `SecurityTest.t.sol` (test_ClaimFeeTokens_ClearsBeforeTransfer) verifies the checks-effects-interactions pattern for `claimFeeTokensFor`.
- **Lines:** 448-449 (claimFeeTokensFor: zeroes balance before transfer), 724-733 (deployPool: external call to terminal.cashOutTokensOf)
- **Description:** The contract has no explicit `ReentrancyGuard`. It relies on state ordering: `claimFeeTokensFor` zeroes `claimableFeeTokens` before the `safeTransfer` (line 449 before 453). `deployPool` and `rebalanceLiquidity` make multiple external calls (to `PositionManager`, `terminal.cashOutTokensOf`, `terminal.pay`, `addToBalanceOf`). The state is generally updated before external calls, but the call chains are complex. Reentrancy through V4 PositionManager callbacks is theoretically possible but requires a malicious PoolManager or hook contract (both of which are immutable and trusted).
- **Mitigation:** The trust model assumes V4 infrastructure is not malicious. JB terminal calls use try-catch internally. The `processSplitWith` function validates `msg.sender == controllerOf(projectId)` (line 539), preventing reentrancy through the split hook interface.

#### L-6. Permissionless Fee Collection Timing

- **Tested:** `SecurityTest.t.sol` (test_CollectFees_Permissionless).
- **Lines:** 459-488 (collectAndRouteLPFees, no access control)
- **Description:** Anyone can trigger `collectAndRouteLPFees` at any time. While this is a feature (enabling keepers), it means an adversary can time fee collection to their advantage. For example, collecting fees just before a large swap (when the pool price is at one extreme) versus after. The practical impact is minimal because fee collection does not change the pool price -- it only harvests accrued swap fees.

## Concrete Attack Scenarios

### Scenario 1: Rebalance Sandwich (H-1)

**Attacker:** MEV bot monitoring the mempool.
**Cost:** Gas + swap fees (1% per swap in the V4 pool).
**Profit potential:** Proportional to position size and price impact achievable.

```
1. Observe pending rebalanceLiquidity(projectId, ETH, 0, 0, 0, 0) in mempool
2. Front-run: Swap large amount of project tokens into the pool, pushing price down
3. rebalanceLiquidity executes:
   - BURN_POSITION returns skewed amounts (mostly project tokens)
   - New tick bounds computed from current Juicebox rates (not the pool price)
   - MINT_POSITION creates position at new bounds with skewed amounts
4. Back-run: Swap back, buying cheap project tokens from the new position
```

**Defense:** Set non-zero slippage parameters. Use Flashbots or private mempool. The 1% fee tier makes each swap leg expensive.

### Scenario 2: Stale Owner Blocks Pool Deployment (M-3)

**Attacker:** Project owner who loses keys or becomes unresponsive.
**Timeline:** Until weight decays 10x from `initialWeightOf`.

```
1. Project accumulates tokens via reserved splits
2. Owner never calls deployPool
3. Tokens sit idle, losing value as issuance rate decays
4. Eventually (after enough ruleset cycles with weight cut), weight drops below 1/10th
5. Anyone can call deployPool permissionlessly
```

**Defense:** Built into the protocol. The 10x decay threshold (line 506) ensures eventual permissionless deployment. For a project with 80% weight cut per cycle and 1-day duration, this takes approximately 3 days (confirmed in `Fork.t.sol` test_fork_deployPool_permissionlessAfterWeightDecay).

### Scenario 3: Initial Price Front-Running (M-2)

**Attacker:** Anyone who can pay into the project.
**Cost:** JB protocol fees (2.5%) on the pay-in amount.

```
1. Observe pending deployPool transaction
2. Front-run: Pay large amount into the project to inflate surplus
3. deployPool executes with inflated cashout rate, creating pool at wrong price
4. Back-run: Cash out to reclaim most of the paid amount
5. Arbitrage the mispriced pool
```

**Defense:** The 2.5% JB protocol fee on payments makes this expensive. The `minCashOutReturn` parameter limits how much value can be extracted during the pool's initial cash-out. Concentrated liquidity's narrow range limits the total arbitrageable amount.

## Test Coverage Analysis

### Well-Tested Areas

| Area | Test Files | Coverage |
|------|-----------|----------|
| Access control (processSplitWith) | SecurityTest, AccumulationStageTest | Comprehensive: controller-only, wrong hook, wrong groupId, invalid project |
| Access control (deployPool) | DeploymentStageTest, WeightDecayDeployTest, SecurityTest | Comprehensive: unauthorized, owner, operator, weight-decay permissionless, edge cases |
| Access control (rebalanceLiquidity) | AuditFindingsTest, RebalanceTest | Comprehensive: unauthorized reverts, owner succeeds, operator succeeds, zero-liquidity revert |
| Access control (claimFeeTokensFor) | SecurityTest, FeeRoutingTest | Comprehensive: valid operator, invalid operator, zero-balance no-op |
| Fee routing arithmetic | FeeRoutingTest | Thorough: 38/62 split verified, zero-fee no-op, claimable tracking, event emission |
| Accumulation mechanics | AccumulationStageTest | Thorough: single, multiple, zero-amount, cross-project isolation |
| Pool deployment lifecycle | DeploymentStageTest, IntegrationLifecycle | Thorough: creates pool, sets tokenId, clears accumulated, handles leftovers |
| Price math | PriceMathTest | Thorough: issuance rate (0/10/100% reserved), cashout rate (0/positive surplus), sqrtPriceX96, tick bounds, alignment, geometric mean, optimal cashout |
| Native ETH handling | NativeETHTest | Good: isNativeToken, receive(), accounting setup, end-to-end deploy with NATIVE_TOKEN |
| Clone deployment | DeployerTest | Good: CREATE, CREATE2, address registry, initialization, events |
| Re-initialization prevention | M32_ReinitAfterRenounce, ConstructorTest | Good: double-init reverts, initialized flag |
| Fork integration | Fork.t.sol | Good: real V4 contracts, full lifecycle with real JB core, weight-decay permissionless deploy |
| Token conservation | PositionManagerIntegrationTest | Good: token flows, no creation from thin air, partial usage with sweep |

### Untested or Lightly Tested Areas

| Area | Gap | Risk Level |
|------|-----|------------|
| MEV/sandwich attacks | No simulation of front-running or back-running around rebalance/collect operations | HIGH |
| Extreme price scenarios | No tests for MIN_TICK/MAX_TICK boundaries in production conditions | LOW |
| Fee-on-transfer tokens | No tests with non-standard ERC-20 tokens (not applicable -- JB project tokens are standard) | N/A |
| Concurrent multi-project rebalance | No tests for multiple projects rebalancing in the same block | LOW |
| V4 PositionManager edge cases | Mock-based tests do not cover real PositionManager revert conditions (e.g., insufficient pool liquidity for burn) | MEDIUM |
| Gas limits | No tests for gas consumption with large accumulated balances or many fee collection cycles | LOW |

## Privileged Roles

| Role | Permission | Scope |
|------|-----------|-------|
| Project owner | `SET_BUYBACK_POOL` -- deploy pool, rebalance, claim fees | Per-project |
| Authorized operator | `SET_BUYBACK_POOL` -- same as owner when granted | Per-project, delegated |
| Anyone (post-10x-decay) | `deployPool` -- bypasses permission check | Per-project, conditional |
| Anyone (post-deployment) | `collectAndRouteLPFees` -- trigger fee collection | Permissionless |
| JB Controller | `processSplitWith` -- send tokens to hook | System role, per-project |
