# Single-sided, cash-out-free, permissionless-rebalance LP hook — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change `JBUniswapV4LPSplitHook` **in place** to seed the Uniswap V4 buyback pool from a project's reserved tokens with **no cash-out** (asks-only above the pre-set spot) and make `rebalanceLiquidity` **permissionless** behind a spot-vs-TWAP + drift guard. This REPLACES the contract's cash-out-funded two-sided design and removes the now-unused code it depended on.

**Architecture:** Edit `src/JBUniswapV4LPSplitHook.sol` directly. Keep accumulation / fee-routing / Permit2-for-project-token / mint-burn / TWAP internals; DELETE the funding cash-out (`_fundTerminalTokenSide`) and its dead dependencies; rewrite deploy/add to mint single-sided project tokens in `[max(spot, floor), ceiling]`; make `rebalanceLiquidity` permissionless with a drift threshold + contract-derived burn floor. Reuse the existing deployer and library. Rework the existing tests that assert cash-out behavior.

**Tech Stack:** Solidity 0.8.28, Foundry, Uniswap V4, Permit2, `@bananapus/core-v6`, `solady` LibClone.

## Supersession note

Removing the cash-out deletes the buggy `_fundTerminalTokenSide`, so **PR #171 / `fix/deploypool-convex-cashout-floor`** becomes moot for this contract. Decide before building: **(a)** merge PR #171 first (fix the currently-deployed contract), then land this redesign on top; or **(b)** supersede/close PR #171 and ship only this. This plan assumes we branch off `main` (post-#171) — confirm at handoff. This is an in-place redesign requiring a **redeploy**.

## Global Constraints

- Solidity `0.8.28`; `forge fmt` clean; `forge lint` clean; no unused imports/vars/errors/constants after Task 7.
- Reuse `src/libraries/JBUniswapV4LPSplitHookMath.sol` and `src/JBUniswapV4LPSplitHookDeployer.sol` as-is. Edit `src/JBUniswapV4LPSplitHook.sol` + `src/interfaces/IJBUniswapV4LPSplitHook.sol` in place.
- The hook NEVER calls `cashOutTokensOf` / `currentReclaimableSurplusOf` for funding. `_fundTerminalTokenSide` is DELETED.
- The hook NEVER burns project tokens; leftover is carried in the accumulation ledger.
- Reserved-split-only intake (`groupId == 1`), unchanged.
- Non-fork tests: `forge test --no-match-path 'test/fork/*'`. Fork tests: `vm.createSelectFork("ethereum", 21_700_000)`, keyless archive RPC `RPC_ETHEREUM_MAINNET=https://eth.drpc.org`.
- **EIP-170 final gate:** `forge build --sizes` must show `JBUniswapV4LPSplitHook` runtime <= 24,576 bytes (it deploys directly, not behind a proxy). Intermediate commits MAY exceed while the single-sided logic coexists with the not-yet-removed cash-out path; the cash-out removal frees the space. Verify `--sizes` immediately after the cash-out removal and again at the final gate. (Baseline pre-redesign: 23,589; +1,277 from single-sided logic; the removed cash-out path must net negative.)
- Spec: `docs/superpowers/specs/2026-07-18-single-sided-permissionless-lp-hook-design.md`.

## File Structure

- **Edit in place** `src/JBUniswapV4LPSplitHook.sol` — rewrite `deployPool`/`addLiquidity`/`rebalanceLiquidity`, add `_addSingleSidedLiquidity`, delete `_fundTerminalTokenSide` + cash-out plumbing.
- **Edit** `src/interfaces/IJBUniswapV4LPSplitHook.sol` — add `_DriftBelowThreshold`, `_SpotAboveCeilingAtSeed` errors + `PermissionlessRebalanced` event; drop the `rebalanceLiquidity` min params; remove cash-out-only members.
- **Reuse** `test/mock/MockJBContracts.sol` (taxed-curve mode present; add a `cashOutCallCount` counter on the mock terminal to assert zero cash-outs).
- **Rework** `test/DeploymentStageTest.t.sol` (cash-out-tax + convex-floor tests) and `test/fork/Integration_ConvexTaxSmallSupply.t.sol` (PR #171) to single-sided assertions or delete if wholly cash-out-premised.
- **Create** `test/SingleSided_DeployTest.t.sol`, `test/SingleSided_AddLiquidityTest.t.sol`, `test/SingleSided_RebalanceTest.t.sol`, `test/fork/Integration_SingleSidedRevnet.t.sol`.

---

## Task 1: deployPool mints single-sided project asks (no cash-out) — primary path

**Files:** Modify `src/JBUniswapV4LPSplitHook.sol`; Create `test/SingleSided_DeployTest.t.sol`.

**Interfaces:**
- Produces: internal `_addSingleSidedLiquidity(uint256 projectId, address projectToken, address terminalToken, address controller, JBRuleset ruleset)` — mints project tokens as asks in `[max(spotTick, floorTick), ceilingTick]`, no cash-out. `deployPool(uint256 projectId)` (min param dropped).

- [ ] **Step 1: Add `cashOutCallCount` to the mock terminal** (`test/mock/MockJBContracts.sol`): `uint256 public cashOutCallCount;` incremented in `cashOutTokensOf`. (Enables "never cashes out" assertions.)
- [ ] **Step 2: Write the failing test** — pool pre-initialized at a mid-corridor spot (`store.setTaxedCashOutCurve(PROJECT_ID, 100e18, 2e18, 4000)` + init pool spot between floor and ceiling); `_accumulateTokens(PROJECT_ID, 0.5e18)`; `hook.deployPool(PROJECT_ID)`; assert `tokenIdOf != 0`, the position's terminal-token amount == 0 (asks-only), `terminal.cashOutCallCount() == 0`, and store surplus unchanged.
- [ ] **Step 3: Run — expect FAIL** (current deployPool cashes out; also signature mismatch).
- [ ] **Step 4: Implement** — replace the deploy path: read `slot0` spot tick; compute `[floorTick, ceilingTick]` via the Math lib; mint single-sided in `[max(spotTick, floorTick), ceilingTick]` from `accumulatedProjectTokens`, terminal amount 0; carry leftover in the ledger; drop the `minCashOutReturn` param. Do NOT delete `_fundTerminalTokenSide` yet (Task 7 sweep) but stop calling it.
- [ ] **Step 5: Run — expect PASS.**
- [ ] **Step 6: Rework the existing deploy cash-out test** in `test/DeploymentStageTest.t.sol` (`test_DeployPool_NonzeroCashOutTax_NetsDerivedMinReturn`) to assert single-sided instead; run `forge test --match-path test/DeploymentStageTest.t.sol` green.
- [ ] **Step 7: Commit** `feat: deployPool mints single-sided project asks, no cash-out`.

## Task 2: deploy boundary + degenerate handling

**Files:** Modify contract + interface; Test `test/SingleSided_DeployTest.t.sol`.

- [ ] **Step 1: Failing tests** — (a) `spot >= ceiling` → revert `_SpotAboveCeilingAtSeed`; (b) `spot <= floor` → mint spans `[floorTick, ceilingTick]`, asks-only; (c) `accumulatedProjectTokens == 0` → revert `_NoTokensAccumulated`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** the `max(spot, floor)` clamp + `spot>=ceiling` revert; add `_SpotAboveCeilingAtSeed` to the interface.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat: deploy seed boundary + degenerate handling`.

## Task 3: fallback — initialize at floor when no pool exists

**Files:** Modify contract; Test `test/SingleSided_DeployTest.t.sol`.

- [ ] **Step 1: Failing test** — no pool for the pair; `deployPool` initializes at `floorTick`, mints asks across `[floorTick, ceilingTick]`; assert slot0 == floor price, asks-only.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** the "not initialized" branch (init at floor, then `_addSingleSidedLiquidity` with `spotTick = floorTick`).
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat: initialize at floor when creating the pool`.

## Task 4: addLiquidity single-sided (no cash-out)

**Files:** Modify contract + interface; Test `test/SingleSided_AddLiquidityTest.t.sol`.

- [ ] **Step 1: Failing test** — deploy, simulate a buy that lifts spot, accumulate more, `addLiquidity(projectId, terminalToken)`; assert asks minted in `[currentSpot, ceiling]`, `cashOutCallCount == 0`, ledger decremented.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** — route `addLiquidity` through `_addSingleSidedLiquidity`; drop its `minCashOutReturn`; keep `_requireDeployOrAddAuth`.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat: addLiquidity tops up single-sided`.

## Task 5: permissionless rebalance (TWAP + drift + contract-derived burn floor)

**Files:** Modify contract + interface; Test `test/SingleSided_RebalanceTest.t.sol`.

**Interfaces:**
- Produces: `rebalanceLiquidity(uint256 projectId, address terminalToken)` (min params REMOVED); `_MIN_REBALANCE_DRIFT_TICKS` constant (default = one `tickSpacing`); event `PermissionlessRebalanced(uint256 projectId, address terminalToken, int24 tickLower, int24 tickUpper, address caller)`.

- [ ] **Step 1: Failing tests** — (a) non-owner (`address(0xBEEF)`) rebalances after the corridor moved → re-centers to fresh `[floor,ceiling]`, re-mints two-sided from accrued terminal + project; (b) drift below threshold → revert `_DriftBelowThreshold`; (c) spot off TWAP → revert (reuse `_requireSpotNearTwap`).
- [ ] **Step 2: Run — expect FAIL** (owner-gated + min params).
- [ ] **Step 3: Implement** — remove `_requirePermissionFrom`; add drift check vs live ticks; keep `_requireSpotNearTwap`; derive burn `decreaseAmountMin` internally (95% of a fresh position read, like `prepareRemoveLiquidity`); burn + re-mint `[floor,ceiling]`; emit event; drop min params.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat: permissionless rebalance with TWAP + drift guard`.

## Task 6: rework/remove cash-out-premised tests

**Files:** `test/DeploymentStageTest.t.sol`, `test/fork/Integration_ConvexTaxSmallSupply.t.sol`, any other cash-out tests.

- [ ] **Step 1:** grep the suite for `cashOut`, `UnderMin`, `minCashOutReturn`, `_fundTerminalTokenSide`, two-sided-at-deploy assertions.
- [ ] **Step 2:** For each: convert to a single-sided assertion, or delete if the whole test premise is the (now-removed) cash-out. `Integration_ConvexTaxSmallSupply` (PR #171) is deleted or repurposed to assert deploy does NOT cash out.
- [ ] **Step 3:** `forge test --no-match-path 'test/fork/*'` green.
- [ ] **Step 4: Commit** `test: rework cash-out-premised tests for the single-sided design`.

## Task 7: dependency / dead-code sweep

**Files:** `src/JBUniswapV4LPSplitHook.sol`, `src/interfaces/IJBUniswapV4LPSplitHook.sol`.

- [ ] **Step 1:** Delete `_fundTerminalTokenSide`, `_forceDirectCashOutMetadata`, `_CASH_OUT_SLIPPAGE_NUMERATOR/DENOMINATOR`, cash-out-only errors, and the `getExpectedCashOutReturn` call site.
- [ ] **Step 2:** grep each remaining import/state var/constant for use; remove unused (`JBFees`, `JBCashOuts` if present, cash-out ABIs, `minCashOutReturn` remnants). For `SUCKER_REGISTRY`/`IJBSuckerRegistry`: keep ONLY if still referenced by the corridor math; else remove from the contract (leave the library alone).
- [ ] **Step 3:** `forge build` (no warnings) + `forge lint` (no unused).
- [ ] **Step 4:** `forge test --no-match-path 'test/fork/*'` still green.
- [ ] **Step 5: Commit** `refactor: drop cash-out dependencies and dead code`.

## Task 8: full revnet-shaped unit lifecycle

**Files:** Test `test/SingleSided_RebalanceTest.t.sol`.

- [ ] **Step 1:** Lifecycle test — reserved split to the hook, non-zero cash-out tax, weight-decay: accumulate → deploy (asks-only at pre-set spot) → simulate buys (spot rises, bids appear) → permissionless rebalance re-centers → assert corridor spanned, `cashOutCallCount == 0` throughout, surplus untouched.
- [ ] **Step 2: Run — expect PASS.**
- [ ] **Step 3: Commit** `test: full revnet-shaped lifecycle`.

## Task 9: fork end-to-end revnet use case

**Files:** Create `test/fork/Integration_SingleSidedRevnet.t.sol` (model on `Integration_HighReservedZeroTax.t.sol`).

- [ ] **Step 1:** Real terminal/store on a mainnet fork: launch a revnet-shaped project (reserved % + non-zero cash-out tax + decaying weight); initialize the buyback pool at the initial issuance rate; route reserved to the hook; `deployPool` (asks-only, no cash-out); swap through the real pool to simulate buys; non-owner `rebalanceLiquidity` re-centers; assert surplus never touched and a manipulated-spot rebalance reverts.
- [ ] **Step 2: Run — expect PASS** (`RPC_ETHEREUM_MAINNET=https://eth.drpc.org`).
- [ ] **Step 3: Commit** `test: fork revnet end-to-end`.

## Task 10: fmt/lint, full suite, version bump, PR

- [ ] **Step 1:** `forge fmt && forge lint`.
- [ ] **Step 2:** `forge test --no-match-path 'test/fork/*'` all pass.
- [ ] **Step 3:** `RPC_ETHEREUM_MAINNET=https://eth.drpc.org forge test --match-path 'test/fork/*'` all pass.
- [ ] **Step 4:** bump npm **minor** (breaking behavior change) in `package.json` + `package-lock.json` root version.
- [ ] **Step 5: Commit** `chore: fmt/lint + version bump` and open the PR.

---

## Self-Review

- **Spec coverage:** primary seed (T1), boundary/degenerate (T2), fallback create-at-floor (T3), single-sided add (T4), permissionless rebalance + guards + contract-derived burn floor (T5), cash-out test rework incl. PR #171 (T6), dependency/dead-code removal (T7), organic evolution + surplus-untouched (T8), fork revnet (T9), access-control delta (T5 removes the owner gate; deploy/add keep `_requireDeployOrAddAuth`). Fee routing / accumulation / claim unchanged (untouched in place).
- **Placeholders:** none. Copied internals stay in place (in-place edit, nothing to reproduce). New logic + tests are explicit.
- **Type consistency:** `_addSingleSidedLiquidity` (T1) reused by T3/T4; `rebalanceLiquidity(projectId, terminalToken)` (T5) drops min params everywhere; `cashOutCallCount` introduced T1, reused T4/T8/T9; `_MIN_REBALANCE_DRIFT_TICKS` defined T5.
- **Open items for execution:** confirm PR #171 disposition (merge-first vs supersede); `deployPool(projectId)` new signature vs keeping the old selector; exact drift default.
