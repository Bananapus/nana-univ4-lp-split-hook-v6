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
