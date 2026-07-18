# Task 5 report — consolidate-and-re-mint + permissionless rebalance

Branch: `feat/single-sided-permissionless-lp-hook`
Base: commit `5e23f74` (Task 4+7: single-sided addLiquidity, cash-out sweep)
Result commits: `43194c4` (contract + interface), `3ee3efe` (caller migration), `<commit3>` (new tests + report)

## Consolidate design

`_consolidateAndReMint(projectId, projectToken, terminalToken, tickLower, tickUpper, controller)` is the single
lifecycle primitive behind deploy, add, AND rebalance. Steps, in order:

1. `_claimHookCreditsFor` (revived) claims any hook-held project-token credits into transferable ERC-20 so they join
   the mint. Returns `claimedCredits`.
2. If `tokenIdOf != 0`, burn the live position (`_burnExistingPosition` = `BURN_POSITION` + `TAKE_PAIR`) with a
   contract-derived slippage floor (never caller-supplied). `recoveredProject` is measured as a balance delta taken
   AFTER the credit claim so credits are not double-counted.
3. Held amounts: `projectAmount = accumulatedProjectTokens + recoveredProject + claimedCredits` (all now in the hook's
   transferable balance); `terminalAmount = _spendableTerminalTokenBalance(terminalToken)` (revived) — the burn's
   recovered terminal minus any balance reserved for fee-token claims.
4. Map to `(amount0, amount1)` by pool ordering; compute liquidity via `LiquidityAmounts.getLiquidityForAmounts` at the
   live spot across `[tickLower, tickUpper]`; revert `ZeroLiquidity` on a degenerate range or zero liquidity.
5. Clear the ledger (CEI), mint ONE position, set `tokenIdOf`/`activeTick{Lower,Upper}Of` to the fresh mint, and carry
   any leftover forward (project → ledger; terminal → project balance) via `_carryLeftovers`. Never burns project
   tokens.

Single-sided vs two-sided is decided purely by the passed `[tickLower, tickUpper]` relative to spot, so callers pick:
- deploy/add pass the spot-clamped asks-only range from `_singleSidedTicks` (project-only; ordering-aware, preserving
  both token orderings) → the position holds only project tokens.
- rebalance passes the full `[floor, ceiling]` corridor which spans spot → two-sided, so recovered terminal seeds the
  bid side.

## Single-position invariant

Enforced structurally: `_consolidateAndReMint` burns the prior `tokenIdOf` (when non-zero) BEFORE minting, then writes
`tokenIdOf` to `_nextTokenId() - 1`. So after any deploy/add/rebalance there is exactly one tracked, live position per
(project, terminalToken); the previously tracked id is burned, not orphaned. This directly fixes the confirmed defect
where `_addSingleSidedLiquidity` overwrote `tokenIdOf` without burning, stranding prior NFTs' liquidity/fees.

## Burn slippage-floor derivation

Always contract-derived; callers cannot supply burn minimums. `_burnSlippageFloor` reads the live liquidity
(`positionManager.getPositionLiquidity`), computes the position's principal at the current spot via `_positionPrincipal`
(the canonical `getAmountsForLiquidity`, implemented with `SqrtPriceMath.getAmount0Delta`/`getAmount1Delta` because
v4-periphery's `LiquidityAmounts` only exposes the inverse), and takes `_BURN_SLIPPAGE_BPS = 9500` (95%) of each side,
returned in (currency0, currency1) order to match `BURN_POSITION`. A sandwiched spot therefore cannot force the hook to
accept an arbitrarily bad unwind.

## Credit-sweep wiring

`_claimHookCreditsFor` (previously unreferenced → credits silently stranded) is called first in `_consolidateAndReMint`,
so every deploy/add/rebalance folds hook-held project-token credits into the mint. It already excludes credits reserved
for fee-token claims (`_totalOutstandingFeeCreditClaims`).

## Rebalance guards

`rebalanceLiquidity(projectId, terminalToken)` is permissionless (SET_BUYBACK_POOL gate removed; `decreaseAmount*Min`
params removed from the interface + all callers). Guards, in order: (a) recompute `[floorTick, ceilingTick]`; if BOTH
bounds are within `_MIN_REBALANCE_DRIFT_TICKS` (= one `TICK_SPACING` = 200) of the live position's `activeTick*Of`,
revert `JBUniswapV4LPSplitHook_DriftBelowThreshold`; (b) `_requireSpotNearTwap`. Then `_consolidateAndReMint(...,
floorTick, ceilingTick, ...)` and emit `PermissionlessRebalanced(projectId, terminalToken, tickLower, tickUpper,
caller)`. Basic reverts kept: `InvalidTerminalToken` (no terminal), `InvalidStageForAction` (no position).

Interface note: consistent with all ~20 sibling errors, `JBUniswapV4LPSplitHook_DriftBelowThreshold` is declared on the
CONTRACT; the `PermissionlessRebalanced` event and the `rebalanceLiquidity` function signature are added to the
interface (where all events/functions live). The `ruleset` param in the task's suggested `_consolidateAndReMint`
signature was dropped — with the tick range precomputed by callers it is genuinely unused, so keeping it would be a
dead parameter.

## Size (`forge build --sizes`)

`JBUniswapV4LPSplitHook` runtime = **20,187 bytes** (was 19,453; +734). Margin under 24,576 = **4,389 bytes**.
`JBUniswapV4LPSplitHookMath` and the deployer were not modified.

## Tests (all red→green verified)

New file `test/SingleSided_RebalanceTest.t.sol`:
- `test_Rebalance_Permissionless_ReCentersAndUsesTerminalBid` — `address(0xBEEF)` rebalances; one live position (old
  burned), re-centers to fresh `[floor, ceiling]`, accrued terminal used as bid side, `PermissionlessRebalanced`
  emitted, no cashOut. PASS.
- `test_Rebalance_RevertsWhenDriftBelowThreshold` — first rebalance re-centers single-sided→full corridor; second with
  unchanged corridor reverts `DriftBelowThreshold`. PASS.
- `test_Rebalance_RevertsWhenSpotDeviatesFromTwap` — fixed oracle far from spot → `PriceDeviationTooHigh` (drift guard
  passes first). PASS.

Augmented `test/SingleSided_AddLiquidityTest.t.sol`:
- `test_AddLiquidity_MintsAnotherSingleSidedAsk_NoCashOut` — updated for consolidation: first position burned, new ask
  folds recovered 0.5e18 + new 0.3e18 = 0.8e18. PASS.
- `test_AddLiquidity_NoFragmentation_OneLivePositionAfterRepeatedAdds` — deploy + two spot-moved adds; exactly one live
  position (prior ids burned, not orphaned), full 1.0e18 folded, `collectAndRouteLPFees` still collects, no cashOut.
  PASS.
- `test_Deploy_FoldsHookHeldProjectTokenCredits` — hook credits folded into the mint (0.5 + 0.2 = 0.7), credit balance
  swept to 0. PASS.

Red→green evidence:
- Compile-red: with the pre-Task-5 source stashed, the new tests fail to compile (`Wrong argument count: 2 given but
  expected 4`) — the 2-arg permissionless signature + new event/error do not exist.
- Behavioral-red: temporarily neutering the burn in `_consolidateAndReMint` (reverting to the fragmenting overwrite)
  makes `test_AddLiquidity_NoFragmentation_...` fail with "first position must be burned, not orphaned: <id> != 0".

Required subset: `forge test --no-match-path 'test/fork/*' --match-path 'test/SingleSided_*'` → 7/7 PASS.
`SingleSided_DeployTest` 1/1, `DeploymentStageTest` 19/19 PASS. `forge fmt --check` clean; `forge lint` clean.

Full non-fork suite: 308 passed / 29 failed (baseline 300/32 — failures DOWN, no non-churn regression). All 29
failures are in rebalance/cash-out-dependent files deferred to the test-rework task (AddLiquidityTest, RebalanceTest,
IntegrationLifecycle, PositionManagerIntegrationTest, SplitHookRegressions, TestRegressionGaps,
NextTokenIdAfterMintRegression, StaleTokenIdOf, RegressionCoverageSuite::FeeTokensExcludedFromRebalance) plus the two
explicitly protected tests, which still fail for their identical baseline reasons with bodies untouched:
`ReentrancyTest::test_reentrancy_deployPool_reentryAccumulatesSafely` ("Re-entry should have been attempted during
cashOutTokensOf") and `FeeClaimReserveCapture::test_overreportedCashOutCannotConsumeOtherProjectsFeeClaims` ("next
call did not revert as expected").

## Concerns / notes

1. The old rebalance collected+routed terminal fees to the project before burning; the new consolidate rolls the
   burn's recovered fees back into the position (everything becomes liquidity) — consistent with the design, but a
   behavior change worth noting for reviewers.
2. `_spendableTerminalTokenBalance` returns the whole spendable terminal balance (not a per-op recovered delta). For
   the one-pool-per-clone-per-project norm this equals recovered + dust; a multi-project clone holding transient
   terminal for another project between txs is the only edge, and the hook holds no terminal between operations.
3. The 29 churn failures need the dedicated test-rework pass (semantics: permissionless + drift guard + consolidation);
   several old rebalance assertions (auth-required, immediate-rebalance-succeeds, per-add fresh-NFT) no longer hold.

## Fix: pre-burn fee routing

Follow-up to Concern #1 above, confirmed by review as Critical: `_consolidateAndReMint` burned the existing position
and refolded ALL recovered terminal tokens (principal + accrued trading fees) into the new position, without ever
calling `_collectAndRouteFees`. Since this hook IS the JBP6Fee fee hook (`feeProjectId`/`feePercent`), every
add/rebalance (the default, permissionless path) silently forgave the protocol's fee cut forever — recovered fees
became LP principal and could never be collected as fees again.

### What changed

In `_consolidateAndReMint` (`src/JBUniswapV4LPSplitHook.sol`), inside the `if (existingTokenId != 0)` branch, inserted
a call to the existing `_collectAndRouteFees({projectId, projectToken, terminalToken, tokenId: existingTokenId, key})`
BEFORE `_burnSlippageFloor`/`_burnExistingPosition`. This is the exact same internal function `collectAndRouteLPFees`
(the public entry point) calls, and the exact sequencing the OLD pre-redesign `rebalanceLiquidity` used (confirmed via
`git show 5e23f74:src/JBUniswapV4LPSplitHook.sol`, lines ~861-865: it called `_collectAndRouteFees` immediately after
the TWAP guard and before snapshotting balances / calling `_burnExistingPosition`).

`_collectAndRouteFees` does `DECREASE_LIQUIDITY(tokenId, 0)` + `TAKE_PAIR` (collects fees without touching principal),
then `_routeCollectedFees` splits the two currencies: the terminal-token side goes to `_routeFeesToProject` (fee-project
cut via `pay()`, remainder via `addToBalanceOf`); the project-token side is carried into `accumulatedProjectTokens`
(unchanged behavior — project-token fees always ended up back in the next mint either way, pre- or post-fix, so the
defect was specifically the terminal-token side). Only AFTER this collection does the burn fire, so `BURN_POSITION`
now recovers PRINCIPAL only. The `projBalBeforeBurn` snapshot was moved inside the `if` block (it's only used there,
and skipping it when there's no existing position avoids a redundant `balanceOf` call).

Updated the natspec on `_consolidateAndReMint` (both the summary and `@dev`) to state fees are collected/routed before
the burn, not folded into the recovered principal.

### Test update

`test/SingleSided_RebalanceTest.t.sol::test_Rebalance_Permissionless_ReCentersAndUsesTerminalBid` previously asserted
the re-minted position's bid side equalled the full pre-funded terminal balance with no fees involved — it never
exercised the defect at all. Updated it to:
- Set a real accrued LP trading fee (`accruedFee = 0.2e18`) on the OLD position via
  `positionManager.setCollectableFees(oldTokenId, ...)` (ordering-aware) + mint the fee amount to the mock
  PositionManager so `TAKE_PAIR` can pay it out — same pattern as `test/FeeRoutingTest.t.sol`.
- Assert BOTH `LPFeesRouted` (with `totalAmount=accruedFee`, `feeAmount=expectedFeeCut=accruedFee*FEE_PERCENT/BPS`,
  `remainingAmount`, `feeTokensMinted=expectedFeeCut`, `caller=STRANGER`) and `PermissionlessRebalanced` are emitted,
  in that order (the fee-collect now fires before the rebalance's own event).
- Assert `terminal.payCallCount()` increased with `lastPayProjectId() == FEE_PROJECT_ID` and
  `lastPayAmount() == expectedFeeCut` (the fee-project cut was actually paid), and `terminal.addToBalanceCallCount()`
  increased (the remainder was routed to the project's own terminal balance).
- Critically, changed the final bid-side assertion: the new position's terminal side must equal exactly the
  pre-existing `1e18` (the pre-funded balance, unrelated to the fee) — **NOT** `1e18 + accruedFee`. This is the
  regression check: pre-fix, the accrued fee would have been swept into the burn and compounded into the bid side
  (`1.2e18`); post-fix it is routed away first and the bid side is untouched principal.

### Test results

```
forge test --no-match-path 'test/fork/*' --match-path 'test/SingleSided_*'
  → 3 suites, 7/7 PASS (SingleSided_DeployTest 1/1, SingleSided_AddLiquidityTest 3/3,
    SingleSided_RebalanceTest 3/3 including the updated fee-routing assertions)

forge test --no-match-path 'test/fork/*' --match-path 'test/DeploymentStageTest.t.sol'
  → 19/19 PASS
```

`forge build --sizes`: `JBUniswapV4LPSplitHook` runtime = **20,246 bytes** (was 20,187 before this fix; +59 bytes).
Margin under the 24,576 EIP-170 limit = **4,330 bytes**. `JBUniswapV4LPSplitHookMath` and the deployer untouched.

`forge fmt --check`: clean. `forge lint` (project-wide): clean, no findings.

### Collateral in out-of-scope legacy test files (expected, not a regression)

Ran the full non-fork suite before/after (name-only diff, ignoring gas/error-message noise since baseline already had
churn): baseline (HEAD, pre-fix) = 308 passed / 29 failed; post-fix = 304 passed / 33 failed. Exactly 4 tests flip
PASS→FAIL, 0 flip FAIL→PASS:
- `test_Rebalance_HandlesFees` (`test/RebalanceTest.t.sol`)
- `test_M1_rebalance_routesFeesDuringBurn` (`test/SplitHookRegressions.t.sol`)
- `test_Rebalance_FeesRoutedBeforeNewPosition` (`test/TestRegressionGaps.sol`)
- `test_Rebalance_FullCycleWithFees` (`test/PositionManagerIntegrationTest.t.sol`)

All 4 files are already named in this report's Concern #3 list of "29 churn failures [that] need the dedicated
test-rework pass" (pre-existing, pre-redesign fixtures not yet migrated to the permissionless single-sided model).
Root cause of the flip: each of these 4 tests calls `rebalanceLiquidity` on a single-sided (asks-only, zero
terminal-principal) position after seeding `positionManager.setCollectableFees(...)` with a terminal-token fee, then
asserts the mint/burn succeeds. Pre-fix, the buggy fee-compounding accidentally supplied the terminal-side liquidity
these degenerate legacy fixtures need to avoid `JBUniswapV4LPSplitHook_ZeroLiquidity` — i.e. they only passed
*because* of the bug this task fixes. Post-fix, the fee is correctly routed away before the mint, and these 4 tests
now fail for the same `ZeroLiquidity` reason every sibling test in the same suites already fails for at baseline (a
pre-existing, already-scoped-out fixture gap, not new fragility). No test flips FAIL→PASS or PASS→FAIL outside this
set; the two explicitly protected tests
(`ReentrancyTest::test_reentrancy_deployPool_reentryAccumulatesSafely`,
`FeeClaimReserveCapture::test_overreportedCashOutCannotConsumeOtherProjectsFeeClaims`) still fail for their identical
baseline reasons, bodies untouched.

### Concern: reentrancy window newly exercised (bounded severity)

`ReentrancyTest::test_reentrancy_rebalance_cannotReenter` was already failing at baseline (assertion failure:
`reentrancyAttempted()` was false, because rebalance never called `pay()` at all pre-fix — direct evidence of the same
defect). Post-fix it still fails, but via a different mechanism: `MockERC20.transferFrom` panics with an arithmetic
underflow (0x11). Traced the cause: the malicious `ReentrantFeeTerminal`'s `pay()` callback (invoked from
`_routeFeesToProject`, now reachable during rebalance for the first time) reenters `hook.rebalanceLiquidity` on the
SAME project/token pair BEFORE `tokenIdOf` is updated by the outer call. Because `rebalanceLiquidity` is fully
permissionless (a prior, out-of-scope design decision from this same branch), the reentrant call is not blocked by any
permission check; it runs the entire consolidate-and-re-mint cycle to completion (burns the original position, mints a
new one), consuming the exact terminal-token remainder the OUTER call still intends to route via `addToBalanceOf`
after `pay()` returns. The outer call's `transferFrom` then underflows against the now-empty balance and the whole
transaction reverts atomically — no state persists, no funds move. Practical severity is bounded: (a) the reentrant
actor must control the terminal registered for `(feeProjectId, terminalToken)` in `JBDirectory` — a protocol-owned
resource already treated as trusted elsewhere in this file ("the fee project is protocol-controlled and expected to
maintain a functioning terminal"); (b) EVM atomicity means the worst outcome demonstrated is a clean revert (DoS of
that one rebalance call), not fund loss or corrupted state. Flagging for the dedicated test-rework pass: consider a
`nonReentrant` guard on `rebalanceLiquidity`/`addLiquidity`, or clearing `tokenIdOf` before the pre-burn external fee
call, as hardening — out of scope for this fee-routing fix per the task's minimal-impact constraint, and this specific
test was never green to begin with.

Commit: this fix (src + test + report) is committed as a single commit on `feat/single-sided-permissionless-lp-hook`
following `6e87aa6`; see `git log -1` for the hash.
