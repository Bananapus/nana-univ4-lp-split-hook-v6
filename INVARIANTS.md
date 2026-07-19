# Invariants of `@bananapus/univ4-lp-split-hook-v6`

Scope: the `JBUniswapV4LPSplitHook` split hook and its `JBUniswapV4LPSplitHookDeployer` clone factory. Each cloned hook receives reserved-token distributions from one or more Juicebox V6 projects, accumulates them, and on anyone's permissionless signal mints a single concentrated Uniswap V4 LP position per `(projectId, terminalToken)` pair — seeded as a single-sided ask of the accumulated project tokens (asks-only at seed), never from a cash-out. After deployment the hook stays in accumulate-and-grow mode: incoming reserved tokens keep accumulating, `addLiquidity` folds that accumulation into the single position by burning the prior position and re-minting one adaptive position (under a TWAP-deviation guard), accumulated LP fees can be collected and routed back to the project terminal, and the position can be rebalanced. The floor of every position's corridor is placed at the project's cash-out (redemption) price, but **the hook never performs a cash-out**. **The hook never burns project tokens** — supply-reducing burns are a protocol-layer split-routing decision (route a split to `{projectId:0, hook:0, beneficiary:0xdead}`), not this hook's job. The only Uniswap V4 position the hook ever burns is its own, during the consolidate-and-re-mint.

The hook is one Juicebox V6 split-hook implementation among many. It does NOT own project issuance, ruleset behavior, or terminal accounting. Those invariants live in [`nana-core-v6/INVARIANTS.md`](../nana-core-v6/INVARIANTS.md) — read that first if you are reasoning about reserved-token economics, controller permissions, or terminal try/catch behavior. The router/oracle hook side lives in [`univ4-router-v6`](../univ4-router-v6/).

---

## Section A — Guarantees to users (token holders, payers, beneficiaries)

## A.1 Reserved-token routing (pre-deployment)

- A reserved-token split whose `hook == address(this)` deposits the allocated amount into `accumulatedProjectTokens[projectId]` exactly once per `processSplitWith` invocation. The hook pulls `context.amount` via `safeTransferFrom` from the controller and credits the **balance delta** (not the requested amount), so fee-on-transfer project tokens cannot inflate the internal ledger.
- `processSplitWith` rejects any split where `context.split.hook != this`. A misrouted split context cannot trick the hook into accounting for a foreign destination.
- `processSplitWith` rejects any caller that is not the project's currently-active controller (`controller == msg.sender`). The hook cannot be tricked into accumulating by a non-controller calling it directly with a forged context.
- `processSplitWith` only accepts the reserved-token split group (`groupId == 1`). Payout-side split contexts (which carry terminal tokens, not project tokens) are explicitly rejected with `JBUniswapV4LPSplitHook_TerminalTokensNotAllowed`. The hook does not silently accept arbitrary tokens.
- Before any tokens are accumulated, the hook requires the project to have a deployed ERC-20 token (`projectToken != address(0)`). Credit-only projects are rejected — the LP position must be paired against a real ERC-20.
- The first accumulation snapshots the project's then-current ruleset `weight` into `initialWeightOf[projectId]`. The snapshot is immutable thereafter and is retained purely as a reference; it does not gate deployment — deploy, add, and rebalance are permissionless, bounded only by the economic (spot-below-ceiling) and oracle-TWAP guards.
- Defense-in-depth balance reconciliation: after each accumulation, the hook re-checks that its on-chain ERC-20 balance minus committed fee-token reserves covers the accumulated total. Drift caused by a misbehaving controller reverts the call rather than silently mis-account.

## A.2 Reserved-token routing (post-deployment)

- Once `hasDeployedPool[projectId] == true`, any subsequent `processSplitWith` distribution for that project keeps accumulating into `accumulatedProjectTokens[projectId]` — the same ledger as pre-deployment. The hook never burns; supply-reducing burns are a protocol-layer split-routing decision (route a split to `{projectId:0, hook:0, beneficiary:0xdead}`), not this hook's job. The same defense-in-depth balance reconciliation as the pre-deploy path applies.
- That post-deploy accumulation is later converted into more liquidity by `addLiquidity`, which is keyed by `(projectId, terminalToken)` so other projects' balances on the same clone are never consumed.
- The deploy transition still sets `hasDeployedPool[projectId] = true` BEFORE the external Uniswap V4 calls inside `deployPool`. A reentrant `processSplitWith` during deploy only re-accumulates; it cannot re-enter the one-shot deploy path (which reverts as already-deployed).

## A.3 Deployment guarantees

- `deployPool` mints exactly one LP position per `(projectId, terminalToken)` pair. A second call reverts with `JBUniswapV4LPSplitHook_PoolAlreadyDeployed`. A project's `hasDeployedPool` cannot be re-armed.
- `deployPool` rejects an attempt to deploy a second LP position with a different terminal token for the same project (`JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported`). The hook permanently commits to one terminal token per project, chosen by `_findHighestValueTerminalTokenOf` at deploy time.
- The terminal token is selected by the hook itself — it is the token (across all of the project's terminals) with the highest ETH-denominated balance, normalized through the project's price feeds where available, with token-decimal-normalized fallback for unpriced tokens. The caller cannot inject an arbitrary terminal token.
- **Pre-initialized pool defense.** If the pool's V4 PoolKey was already initialized (e.g. an attacker front-ran initialization at an extreme tick), `deployPool` reads the existing `sqrtPriceX96` and reverts with `JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds` if it is at or outside the project's `[cashOutTick, issuanceTick]` economic band. Equality at either bound is also rejected — preinitialization at the exact tick boundary would single-side the LP at the extreme of the band.
- If the existing initialization is inside the economic band, the hook accepts it and uses the existing pool price for downstream liquidity computation. The hook does not attempt to overwrite a valid initialization.
- The cash-out (redemption) price that defines the corridor floor is probed with `min(1e18, totalSupply)` and the reclaim preview is scaled back to a per-`1e18` rate. Projects with less than one whole project token of supply therefore keep their bonding-curve floor instead of falling into the zero-rate fallback. This price only places the floor tick; the hook never performs a cash-out.
- The seed mint is single-sided: it uses only the project tokens the hook already holds (accumulation ledger plus any claimed credits). There is no terminal-token (bid) leg at first deploy because there is no prior position to burn, so no terminal is recovered.
- When the hook does hold a terminal-token side (on a re-mint that burned a prior position), it is sized from the **actual recovered balance delta**, not a reported amount. Fee-on-transfer terminals cannot make the LP spend tokens it never received.
- Before minting, the hook claims any hook-held project credits into the project's ERC-20 and folds those tokens into the LP sizing. This keeps Juicebox's credit-first burn order from leaving transferable project tokens outside the accumulation ledger.
- The mint executor reverts if the computed `liquidity == 0`. A deploy attempt that would mint an empty position fails atomically — `hasDeployedPool` rolls back, `accumulatedProjectTokens` rolls back, and `tokenIdOf` is never set.
- Leftover project tokens after `MINT_POSITION + SETTLE + SWEEP` are carried back into `accumulatedProjectTokens[projectId]` (becoming future liquidity); leftover terminal tokens are returned to the project's primary terminal via `addToBalanceOf`. The hook never burns leftover.
- The accumulation ledger is zeroed before the external mint (CEI) and re-credited only with the unpaired remainder, so a successful deploy consumes the accumulation down to at most that dust; post-deploy inflows then re-accumulate into the same ledger for `addLiquidity`.

## A.4 Permissionless deployment

- `deployPool(projectId)` is fully permissionless — anyone may seed the pool. There is no permission gate and no weight-decay condition.
- The only gate is economic and lives inside the mint executor: the seed reverts once the pool's live spot has reached the project's issuance ceiling, so a pool can only be seeded while there is a live corridor for asks to fill. For an already-initialized pool, the oracle-TWAP deviation guard also applies.
- The permissionless path still goes through all the deployment validations (terminal-token selection, pre-init pool band check, zero-liquidity revert). A permissionless caller cannot deploy under worse-than-protected economics, and cannot redirect any value to themselves.

## A.4b Post-deploy liquidity growth (`addLiquidity`)

- `addLiquidity(projectId, terminalToken)` is fully permissionless. It requires a deployed pool (`tokenIdOf != 0`) and an accumulation of at least `_MIN_ADD_ACCUMULATION` (1e15) so LP-fee dust cannot force a full fee-collect+burn+re-mint churn on every accrual.
- It reverts with `JBUniswapV4LPSplitHook_TwapUnavailable` if the oracle TWAP (30-minute window) cannot be read, and with `JBUniswapV4LPSplitHook_PriceDeviationTooHigh` if the pool spot tick is more than `_MAX_TWAP_DEVIATION_TICKS` (200, ≈2%) from the TWAP tick. It never falls back to spot — accumulation keeps building safely until the add can run. This bounds how badly a JIT/sandwich attacker can skew the mint ratio.
- It never cashes out and never routes through the AMM it feeds. It mints from the project tokens the hook already holds (accumulation ledger + tokens recovered from burning the prior position + claimed credits); any terminal-token (bid) leg is funded solely by the terminal recovered from burning **this project's own** prior V4 position, never by redeeming project tokens against the terminal.
- Any hook-held credits for the project are claimed into ERC-20s before the mint, so externally sent credits are treated as additional project-token principal rather than an alternate burn source that can desync the ledger.
- Every add consolidates: it collects the active position's fees, BURNS the prior position to recover its principal, and re-mints a single fresh adaptive position at the live corridor — folding the recovered principal, the recovered terminal, and the new accumulation into one position. All allocated funds stay consolidated in exactly one position per `(projectId, terminalToken)`; nothing fragments across stale bands. The burn is a pure liquidity withdrawal (no AMM swap), so it adds no swap slippage.
- The accumulation ledger is zeroed before any external call (CEI), so a reentrant `addLiquidity` reverts (nothing accumulated); leftovers are carried forward afterward (project-token dust back to the ledger, terminal-token dust to the project terminal) — never burned.

## A.5 Fee routing (post-deployment)

- `collectAndRouteLPFees` is **permissionless**. Anyone can trigger a fee collection cycle. It collects fees from the single active position (re-ranging burns the old position and re-mints, so there is only ever one position per pair). The terminal-token side is split between the project (via `terminal.pay(remainingAmount)`) and the fee project (via `terminal.pay(feeAmount)`); the project-token side is carried back into the accumulation ledger. No caller receives extracted value.
- `_collectAndRouteFees` collects fees via `DECREASE_LIQUIDITY(0) + TAKE_PAIR`, which never removes principal liquidity — only accrued fees. A permissionless caller cannot drain the LP position by repeatedly invoking it.
- Before routing terminal-token fees externally, `_routeCollectedFees` carries the project-token fee side into `accumulatedProjectTokens[projectId]` — a state write done BEFORE the external `terminal.pay`, for CEI. The hook never burns the project-token fee side.
- Routed fees are credited to the project's **primary** terminal for that token, not an attacker-chosen one. If the fee project's primary terminal is missing (`address(0)`), the fee-project cut is forfeited and the full amount flows to the project's normal path. A misconfigured fee project never blocks the project's own fee collection.
- The fee-project payment uses `minReturnedTokens: 0` by design. Slippage protection is the fee project's responsibility (its own data hook / buyback hook); see `RISKS.md` §7.2.
- The fee project's returned ERC-20 amount is measured via balance delta, not the `pay()` return value. Fee-on-transfer or nonstandard fee-project terminals cannot overstate what the hook actually received.

## A.6 Fee-token claim segregation

- `claimableFeeTokens[projectId]` is denominated in the snapshotted `claimableFeeTokenOf[projectId]` ERC-20. Once a project has any unclaimed fee-token balance, that token address is pinned. A later fee-routing call where the fee project's ERC-20 has changed (e.g. token migration) reverts with `JBUniswapV4LPSplitHook_UnclaimedFeeTokenChanged` rather than silently mixing two different ERC-20s into the same balance.
- Fee tokens claimable for **other** projects' unclaimed balances are excluded from `_spendableTerminalTokenBalance` and the accumulation-ledger reconciliation via the `_unavailableFeeTokenBalance` reserve. Cross-project fee claims cannot be cannibalized by another project's accumulation or LP-funding path.
- Fee credits claimable for **other** projects' unclaimed balances are excluded from `_claimHookCreditsFor` via `_totalOutstandingFeeCreditClaims`. If the fee project later deploys LP through the same clone, only unreserved credits can be normalized into ERC-20 principal.
- During in-flight fee routing, `_inflightFeeRoutingCount[token]` makes `_unavailableFeeTokenBalance` conservatively report the **full balance** as unavailable. A reentrant accumulation or mint cannot read partially-updated reserve state and over-spend.
- `claimFeeTokensFor` clears `claimableFeeTokens[projectId]` and `claimableFeeTokenOf[projectId]` BEFORE the `safeTransfer`, so a reverting ERC-20 atomically restores state along with the event.
- Credit-only claims (when the fee project has no ERC-20) go through `transferCreditsFrom` in a try/catch. On failure the pending credit balance is restored, so a paused/misconfigured fee-project controller does not strand an ERC-20 fee-token claim that already succeeded earlier in the same call.

## A.7 Rebalance guarantees (gated)

- `rebalanceLiquidity(projectId, terminalToken)` is permissionless, bounded by two guards: the freshly recomputed corridor must have drifted at least `_MIN_REBALANCE_DRIFT_TICKS` (one tick spacing) from the corridor the live position was ranged against on at least one bound (so a caller cannot churn the position for gas/slippage with no real re-ranging), and the pool spot must be near the oracle TWAP (so a sandwiched spot cannot skew the re-mint ratio). A third party cannot force-rebalance the LP at an adversarial spot price or churn it for free.
- Rebalance is structurally `collect fees → recompute corridor → drift + TWAP guards → burn old position → re-mint one new position`. Fees are collected first (raising surplus, and therefore the true cash-out floor) so that LP fees are NOT silently re-injected as principal during the new mint.
- The burn slippage floor is contract-derived (a fraction of a pre-burn principal read at the live spot); callers never supply burn minimums.
- The mint step computes liquidity from the actual recovered balances (per-project snapshot deltas), not from the original deployment-time amounts. Other projects' balances held on the same hook clone cannot be drained into one project's rebalanced position.
- If the recomputed liquidity is zero (e.g. price has moved entirely outside the new tick range), the re-mint reverts with `JBUniswapV4LPSplitHook_InsufficientLiquidity`. This is intentional: the burn already destroyed the old NFT, and a zero-liquidity outcome would brick the project's LP. The revert keeps the entire transaction atomic — `tokenIdOf` is preserved and the position remains rebuildable in a subsequent call.
- Leftovers after re-mint: project-token leftovers are carried back into the accumulation ledger; terminal-token leftovers are routed back to the project's terminal balance via `addToBalanceOf`. Nothing is burned. Conservation holds modulo on-chain rounding.

## A.8 Initialization safety

- `initialize` on a clone is one-shot: the call reverts with `JBUniswapV4LPSplitHook_AlreadyInitialized` if `poolManager != address(0)`. The deployer factory calls `initialize` atomically with `clone`, so no third party can front-run the first call with hostile values.
- `initialize` rejects `newPoolManager == address(0)` (the sentinel for "not yet initialized"). The hook cannot be left in a half-initialized state where the sentinel passes but pool operations would silently no-op.
- `initialize` rejects `feePercent > BPS` (>100%) and `feePercent > 0 && feeProjectId == 0` (configured fees with no fee project — would strand routed fees).
- A configured `feeProjectId` is validated to have an existing controller (`controllerOf(feeProjectId) != address(0)`). Initialization against a non-existent fee project reverts up front.
- Fee config (`feeProjectId`, `feePercent`) and chain-specific Uniswap V4 wiring (`poolManager`, `positionManager`, `oracleHook`) are immutable post-initialization. Neither the project owner nor the deployer can rotate them.

## A.9 Permit2 hygiene

- Before any V4 `MINT_POSITION` settle, the hook grants Permit2 a time-bounded allowance (`expiration = block.timestamp + 60s`) and rejects `amount > type(uint160).max` up front.
- After the V4 mint returns, the hook clears both the Permit2 spender allowance (`approve(token, positionManager, 0, expiration=1)`) and the ERC-20 approval to Permit2 (`forceApprove(permit2, 0)`). No residual pull authority survives a successful mint.
- For the project's primary terminal during `terminal.pay` / `addToBalanceOf`, the hook calls `_requireTemporaryAllowanceConsumed` after the external call. A terminal that does not consume the full pre-call allowance reverts with `JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed`, preventing a leaked approval from sitting open for an attacker to exploit later.

---

## Section B — Guarantees to operators (project owner / `SET_BUYBACK_POOL` delegate)

## B.1 Powers the operator has

- **Deploy the LP position.** Call `deployPool(projectId)`. Permissionless — anyone (including the operator) may seed the pool; the seed reverts once the pool spot reaches the issuance ceiling.
- **Add post-deploy liquidity.** Call `addLiquidity(projectId, terminalToken)` to fold accumulated post-deploy reserved tokens into the single position (burn prior, re-mint one). Permissionless, subject to the TWAP-deviation guard.
- **Rebalance the position.** Call `rebalanceLiquidity(projectId, terminalToken)`. Permissionless, bounded by the corridor-drift threshold and the TWAP-deviation guard.
- **Claim accumulated fee tokens.** Call `claimFeeTokensFor(projectId, beneficiary)`. This is the one operator-exclusive power, gated by `SET_BUYBACK_POOL`. Pulls claimable ERC-20 fee tokens and/or fee-project credits to the chosen beneficiary.
- **Deploy new hook clones.** Anyone can call `JBUniswapV4LPSplitHookDeployer.deployHookFor(feeProjectId, feePercent, buybackHook, salt)`. The new clone's fee config is set at the salt-deterministic clone address; the caller is mixed into the salt so a competitor cannot squat a `(msg.sender, salt)` they don't control.

## B.2 Powers the operator does NOT have

- **No re-initialization.** A clone's `feeProjectId`, `feePercent`, `poolManager`, `positionManager`, and `oracleHook` are set once at `initialize` and cannot be rotated by anyone — including the deployer factory operator.
- **No reversal of accumulation → deploy.** `hasDeployedPool[projectId]` cannot be set back to false. There is no `undeployPool` path. A wrongly-deployed pool requires migrating to a new hook clone.
- **No override of terminal-token selection.** `_findHighestValueTerminalTokenOf` is what picks the terminal token at deploy. The operator cannot pass a different one to `deployPool`.
- **No caller-set slippage.** Burn slippage floors on re-mint and rebalance are contract-derived (a fraction of a pre-burn principal read at the live spot). Callers cannot supply or disable them.
- **No partial rebalance.** Rebalance is all-or-nothing: collect, recompute, burn, re-mint. The operator cannot rebalance just one side or skip the collect step.
- **No direct token withdrawal.** There is no `rescueTokens` or `withdraw` function. The hook's only paths out are: route via `terminal.pay`, route via `terminal.addToBalanceOf`, mint into / increase a V4 position. The hook never cashes out and never burns project tokens. Stuck tokens (e.g. accidentally-sent foreign ERC-20s) cannot be recovered by the operator.

## B.3 Permissionless triggers the operator should expect

- **`deployPool`.** Permissionless — anyone can seed the pool; the seed reverts once the pool spot reaches the issuance ceiling. This prevents a missing or hostile operator from locking accumulated reserved tokens forever. The operator cannot veto deployment timing.
- **`addLiquidity`.** Permissionless — anyone can fold accumulated post-deploy reserved tokens into the position. Bounded by the TWAP-deviation guard, so the caller can only force add timing, not extract value.
- **`rebalanceLiquidity`.** Permissionless — anyone can re-center the position. Bounded by the corridor-drift threshold and the TWAP-deviation guard, so the caller can only force rebalance timing when there is real drift, not extract value.
- **`collectAndRouteLPFees`.** Anyone can collect and route fees at any time. The operator cannot reserve "this fee cycle is for project usage X" — collection is opportunistic.
- **`JBUniswapV4LPSplitHookDeployer.deployHookFor`.** Anyone can deploy a hook clone with any `(feeProjectId, feePercent)` settings. Multiple hook clones can coexist for the same fee project. The operator chooses which clone(s) their splits reference.

## B.4 Liveness guarantees

- A reverting fee-project terminal does NOT block the project's own fee inflow: when `feeTerminal == address(0)`, `feeAmount` is set to 0 and the entire collected fee routes through the project's terminal path instead.
- A reverting fee-project credit transfer (in `_claimFeeCredits`) does NOT unwind a successful ERC-20 fee-token claim in the same `claimFeeTokensFor` call; the credit balance is restored for later retry.
- A reverting V4 mint (or terminal leftover routing) reverts the entire `deployPool` call — no partial deploy state survives. The accumulation ledger is preserved so anyone can retry.

---

## Section C — Per-contract operation inventory

## C.1 `JBUniswapV4LPSplitHook` — `src/JBUniswapV4LPSplitHook.sol`

Inherits `IJBUniswapV4LPSplitHook`, `IJBSplitHook`, `JBPermissioned`. Cloneable; each clone manages many projects but at most one deployed pool per project.

**Initialization (one-shot per clone):**

- **`initialize(initialFeeProjectId, initialFeePercent, newPoolManager, newPositionManager, newOracleHook, newBuybackHook)`** — anyone in principle, but in practice the deployer factory's `deployHookFor` calls it atomically with the clone.
  - **Invariant:** one-shot via `poolManager == address(0)` sentinel; `newPoolManager` must be non-zero; `feePercent ≤ BPS`; `feePercent > 0 ⇒ feeProjectId != 0`; configured `feeProjectId` must have a controller.

**Split routing (controller-only):**

- **`processSplitWith(JBSplitHookContext) payable`** — only the project's currently-active controller. Reserved-token splits (`groupId == 1`) only. Requires `context.split.hook == this`.
  - **Pre- AND post-deploy (identical):** accumulates `received = balance delta` into `accumulatedProjectTokens[projectId]`, snapshots `initialWeightOf` on first deposit, defense-in-depth ledger reconciliation (balance minus committed fee-token reserves must cover the accumulated total). The hook never burns.
  - **Invariant:** project token must be ERC-20 (not credits-only); transient ETH (`msg.value`) is allowed by the function signature but never spent here.

**Permissionless lifecycle triggers:**

- **`deployPool(projectId)`** — permissionless. Selects the highest-ETH-value terminal token via `findHighestValueTerminalTokenOf`. Sets `hasDeployedPool[projectId] = true` before any external calls. Initializes or accepts a pre-initialized pool (validated against economic tick bounds; the oracle-TWAP guard applies to an already-initialized pool). Mints a single-sided ask of the accumulated project tokens from the live spot up to the issuance ceiling via Permit2 + V4 `MINT_POSITION + SETTLE + SWEEP` — no cash-out. Carries project-token leftover back into `accumulatedProjectTokens[projectId]`, routes terminal-token leftover to terminal balance (never burns).
  - **Invariants:** one-shot per `(projectId, terminalToken)`; one-shot per project (only one terminal token supported per project); economic spot-below-ceiling gate; pre-init pool rejected if outside or AT `[floorTick, ceilingTick]`; zero-liquidity reverts atomically; leftover carried to the accumulation ledger (never burned).

- **`addLiquidity(projectId, terminalToken)`** — permissionless. Requires a deployed pool and accumulation ≥ `_MIN_ADD_ACCUMULATION`. Reverts on TWAP unavailability or spot/TWAP deviation > `_MAX_TWAP_DEVIATION_TICKS`. Collects + routes the active position's fees, burns the prior position to recover its principal, and re-mints a single fresh adaptive position at the live corridor (folding in the accumulation ledger + recovered principal + recovered terminal + claimed credits). No cash-out; any terminal-token bid leg comes only from the terminal recovered by burning this project's own position. Carries leftovers forward (never burns project tokens). Emits `LiquidityAdded`.
  - **Invariants:** never adds at a manipulated ratio (TWAP guard); never cashes out and never routes through the AMM it feeds; always consolidates to exactly one position per pair (burn prior + re-mint, no fragmentation); per-`(projectId, terminalToken)` keying isolates clone-shared balances.

- **`rebalanceLiquidity(projectId, terminalToken)`** — permissionless, bounded by the corridor-drift threshold (`_MIN_REBALANCE_DRIFT_TICKS` on at least one bound) and the TWAP guard (the same as `addLiquidity`, since the re-mint prices against the live spot). Collects + routes fees first; recomputes the corridor; burns the old position with a contract-derived slippage floor; re-mints one new position from per-project snapshot balance deltas. Reverts if recomputed liquidity is zero.
  - **Invariants:** old `tokenIdOf` is overwritten only after successful mint; drift guard prevents free churn; leftover handling uses per-project balance deltas so other projects' balances are not drained.

**Operator-gated:**

- **`claimFeeTokensFor(projectId, beneficiary)`** — `SET_BUYBACK_POOL` permission required. Sends `claimableFeeTokens[projectId]` of the snapshotted `claimableFeeTokenOf[projectId]` ERC-20, then `claimableFeeCredits[projectId]` via `transferCreditsFrom`. State cleared before external calls; credit path try/catch with rollback.
  - **Invariants:** ERC-20 fee-token claim atomic with its `safeTransfer`; failed credit claim does not unwind a successful prior ERC-20 claim.

**Permissionless triggers:**

- **`collectAndRouteLPFees(projectId, terminalToken)`** — anyone. Requires `tokenIdOf[projectId][terminalToken] != 0`. Calls `_collectAndRouteFees` which uses `DECREASE_LIQUIDITY(0) + TAKE_PAIR` to fetch only accrued fees from the single active position, carries the project-token fee side into the accumulation ledger, and routes the terminal-token fee side (split between fee project and main project per `feePercent`).
  - **Invariants:** principal liquidity never removed; project-token fee carry (a state write) precedes the external terminal call (reentrancy ordering); routed amounts measured by balance delta, not return values; fee-project terminal absence does not strand the project's share.

**Receive / interfaces:**

- **`receive() payable`** — accepts ETH for native-terminal operations (fee routing / leftover `addToBalanceOf`) and V4 `TAKE`/`SWEEP` operations.
- **`supportsInterface(bytes4)`** — `IJBUniswapV4LPSplitHook` and `IJBSplitHook`.

**Public state (selected, all read-only via auto-getters):**

- `accumulatedProjectTokens[projectId]` — the single reserved-token escrow ledger (pre- AND post-deploy); zeroed before each deploy/add and re-credited with any leftover/carry.
- `hasDeployedPool[projectId]` — irreversible first-deploy flag.
- `tokenIdOf[projectId][terminalToken]` — active V4 position NFT id; nonzero post-deploy and post-rebalance.
- `activeTickLowerOf[projectId][terminalToken]` / `activeTickUpperOf[projectId][terminalToken]` — the active position's stored ticks (including the adaptive bid bound), used to derive the burn slippage floor on re-mint.
- `rangedCorridorLowerOf[projectId][terminalToken]` / `rangedCorridorUpperOf[projectId][terminalToken]` — the economic corridor the live position was ranged against; the drift basis `rebalanceLiquidity` compares the freshly recomputed corridor against.
- `poolKeysOf[projectId][terminalToken]` — PoolKey; set during `_createAndInitializePool`.
- `initialWeightOf[projectId]` — snapshotted at first accumulation; retained as a reference and does not gate deployment.
- `claimableFeeTokens[projectId]` / `claimableFeeTokenOf[projectId]` / `claimableFeeCredits[projectId]` — fee-routing ledgers.
- `_totalOutstandingFeeTokenClaims[token]` / `_totalOutstandingFeeCreditClaims[feeProjectId]` / `_inflightFeeRoutingCount[token]` — internal reserves protecting cross-project claim segregation.
- `feeProjectId` / `feePercent` / `poolManager` / `positionManager` / `oracleHook` — initialization-immutable config.
- `buybackHook` — per-clone buyback-hook registry reference, configured via `initialize` (may be the zero address).

## C.2 `JBUniswapV4LPSplitHookDeployer` — `src/JBUniswapV4LPSplitHookDeployer.sol`

Clone factory. Holds `_HOOK_IMPLEMENTATION` (constructor-immutable) and chain-specific V4 addresses (storage, one-shot).

**Permissionless:**

- **`deployHookFor(feeProjectId, feePercent, buybackHook, salt) → hook`** — anyone. Requires `poolManager != address(0)` (i.e. chain wiring already configured). Clones via `LibClone.clone` (salt 0) or `LibClone.cloneDeterministic` with `keccak256(abi.encode(msg.sender, salt))`. Atomically calls `hook.initialize(...)` so no third party can race the first init. Registers the new hook in `ADDRESS_REGISTRY`.
  - **Invariant:** `msg.sender` is mixed into the deterministic salt — different callers cannot collide their CREATE2 addresses; the implementation cannot be redirected; init is uncontested.

**Deployer-only one-shot:**

- **`setChainSpecificConstants(newPoolManager, newPositionManager, newOracleHook)`** — only `_DEPLOYER` (constructor-immutable address). One-shot via `poolManager == address(0)` sentinel.
  - **Invariant:** mirrors the `setChainSpecificConstants` pattern across the V6 ecosystem (suckers, buyback, router, defifa). After this call the deployer's V4 wiring is effectively immutable for the contract's lifetime. CREATE2 inputs to the deployer remain byte-identical across chains because chain-different addresses are storage, not immutable.

**Views:** `hookImplementation()`, `ADDRESS_REGISTRY()`, `poolManager()`, `positionManager()`, `oracleHook()`.

## C.3 `JBLPSplitHookHelpers` — `src/libraries/JBLPSplitHookHelpers.sol`

Pure library. `alignTickToSpacing` (floor), `alignTickToSpacingCeil` (ceiling, asymmetric for `tickLower`), `isNativeToken`, `sortTokens`, `toCurrency`. No state, no auth.

---

## Section D — Cross-cutting invariants

1. **Balance-delta accounting everywhere.** All token-side amounts that drive subsequent state (accumulation, leftover handling, routed fee amount, rebalance leftover) are measured as `balanceAfter − balanceBefore`, not from external return values. Fee-on-transfer tokens and nonstandard terminals cannot inflate the hook's internal ledger.

2. **Per-project snapshot deltas in shared-clone storage.** Because one hook clone can manage many projects, every multi-project-touching path (accumulation reconciliation, post-mint leftover handling, fee-routing ERC-20 measurement) uses per-call before/after snapshots of `IERC20.balanceOf(this)`. Other projects' balances cannot leak into one project's leftover or be drained into one project's LP.

3. **Fee-token and fee-credit claim segregation.** `_unavailableFeeTokenBalance(token)` returns the full balance during in-flight routing (`_inflightFeeRoutingCount > 0`) and the cumulative outstanding claims otherwise. Every accumulation-ledger reconciliation and every "spendable terminal token" computation subtracts this reserve. `_claimHookCreditsFor` also subtracts `_totalOutstandingFeeCreditClaims[projectId]` before normalizing credits into ERC-20s. A project's claimable fee value cannot be cashed-out, claimed into principal, or spent into LP by another project sharing the clone.

4. **State-then-call ordering in fee routing.** `_routeFeesToProject` pre-increments `_totalOutstandingFeeTokenClaims` and `_inflightFeeRoutingCount` BEFORE calling `terminal.pay()`, then reconciles after. A reentrant collection during the external call sees an inflated reserve, which conservatively prevents over-spending.

5. **State-then-call ordering in deployment and adds.** `hasDeployedPool[projectId] = true` is set BEFORE the external V4 / terminal calls in `deployPool`, and `addLiquidity`/`deployPool` zero `accumulatedProjectTokens[projectId]` before the external mint. A reentrant `processSplitWith` during deploy/add only re-accumulates; a reentrant `addLiquidity` finds nothing accumulated and reverts; a reentrant `deployPool` reverts as already-deployed.

6. **State-then-call ordering in claims.** `claimFeeTokensFor` clears `claimableFeeTokens` / `claimableFeeTokenOf` and decrements the reserve BEFORE the `safeTransfer`. A reverting transfer atomically restores state via the EVM rollback.

7. **One-shot bindings everywhere.** `JBUniswapV4LPSplitHook.initialize`, `JBUniswapV4LPSplitHookDeployer.setChainSpecificConstants`, `deployPool` (per project / per terminal-token pair). None can be re-armed by anyone.

8. **No direct withdrawal.** The hook holds tokens only to (a) accumulate for LP, (b) route to project terminal, (c) mint into / increase a V4 position. The hook never cashes out. There is no `rescue` / `withdraw` / `recover` function, and no project-token burn path. Misrouted foreign tokens cannot be extracted by the operator.

9. **Pre-init pool defense.** A front-runner can initialize the V4 pool first, but cannot pin liquidity at an out-of-band tick: `_createAndInitializePool` reverts on existing prices `≤ sqrtPriceLower` or `≥ sqrtPriceUpper`. Boundary equality is rejected — preinitialization exactly at a band edge would single-side the LP.

10. **Burn slippage floor is contract-derived.** On every re-mint and rebalance, the burn's minimum-out is a fraction of a pre-burn principal read at the live spot (`_burnSlippageFloor`). Callers never supply or lower it, so a burn cannot be forced to accept an arbitrarily bad recovery.

11. **Rebalance atomicity.** If recomputed liquidity is zero after a successful burn, the entire rebalance reverts. The old position is never destroyed unless the new one will succeed.

12. **Permissionless settlement triggers never extract value beyond canonical allocation.** `deployPool` (economic spot-below-ceiling gate), `addLiquidity` (TWAP-deviation guard), `rebalanceLiquidity` (corridor-drift threshold + TWAP guard), `collectAndRouteLPFees`, `processSplitWith` (controller-only but downstream-permissionless through `sendReservedTokensToSplitsOf`) — none of these allow the caller to redirect value to themselves. The caller can only force settlement timing.

---

## Section E — Out-of-scope centralization caveats

These are NOT third-party attack vectors but are powers held outside the hook itself:

- **Per-project owner / `SET_BUYBACK_POOL` delegate.** Exclusively controls fee claiming (`claimFeeTokensFor`); like anyone else, they can deploy, add, and rebalance. Their project — their problem. Even a hostile delegate cannot rebalance (or add) at a spot price that deviates from the oracle TWAP beyond `_MAX_TWAP_DEVIATION_TICKS` — both paths revert on that deviation.
- **Fee-project owner.** Configures the fee-project terminal. A misconfigured fee-project terminal (missing primary terminal for the collected token) silently forfeits the fee cut to the project's normal path; this is documented in RISKS.md §7.2.
- **Deployer Safe (`_DEPLOYER`).** Sets `setChainSpecificConstants` once. Compromise of this Safe before the one-shot call could redirect V4 wiring (PoolManager, PositionManager, oracle hook) to a malicious implementation. After the one-shot call, the deployer Safe has no power over this contract.
- **Project's controller.** Calls `processSplitWith` on behalf of the project. A malicious controller could in principle send arbitrary `context` data, but `context.split.hook == this` and `controller == msg.sender` are checked. The controller cannot mint or burn tokens through the hook beyond what reserved-token splits authorize.
- **Uniswap V4 PoolManager / PositionManager.** Held trusted on the critical external-call boundary during deployment. A compromise of these contracts is outside the hook's local threat model — see `RISKS.md` §7.1.
- **Oracle hook (`oracleHook`).** Set at initialization and immutable thereafter. The hook trusts the oracle hook for TWAP / market-side behavior; see `univ4-router-v6` for the canonical oracle implementation.

---

## Section F — Key code references

- Accumulation accounting and balance-delta reconciliation: `src/JBUniswapV4LPSplitHook.sol:1062-1095`
- Post-deploy accumulation (no burn) in `processSplitWith`: `src/JBUniswapV4LPSplitHook.sol:1274`
- `addLiquidity` consolidate-and-re-mint entrypoint: `src/JBUniswapV4LPSplitHook.sol:597`
- Shared single-sided add core (`_addSingleSidedLiquidity`): `src/JBUniswapV4LPSplitHook.sol:1360`
- TWAP-deviation guard (`_requireSpotNearTwap`): `src/JBUniswapV4LPSplitHook.sol`
- Economic spot-below-ceiling gate (inside the mint executor `_consolidateAndReMint`): `src/JBUniswapV4LPSplitHook.sol:1569`
- Leftover carry-forward, never burned: `src/JBUniswapV4LPSplitHook.sol`
- Consolidate burn + re-mint of one position (`_consolidateAndReMint`): `src/JBUniswapV4LPSplitHook.sol:1569`
- Fee collection from the single active position, project-token side carried (`_collectAndRouteFees` / `_routeCollectedFees`)
- Controller-only and hook-identity check in `processSplitWith`: `src/JBUniswapV4LPSplitHook.sol`
- Permissionless `deployPool` (no permission gate): `src/JBUniswapV4LPSplitHook.sol:754`
- `deployPool` one-shot per project + per-terminal-token guards: `src/JBUniswapV4LPSplitHook.sol:987-996`
- State-before-call ordering on `hasDeployedPool`: `src/JBUniswapV4LPSplitHook.sol:1008-1010`
- Pre-initialized pool tick-band defense (rejects boundary equality): `src/JBUniswapV4LPSplitHook.sol:1819-1849`
- Burn slippage floor (contract-derived, `_burnSlippageFloor`): `src/JBUniswapV4LPSplitHook.sol`
- Reported vs recovered terminal-token reconciliation (balance delta): `src/JBUniswapV4LPSplitHook.sol`
- Zero-liquidity revert during deploy: `src/JBUniswapV4LPSplitHook.sol:1323-1325`
- Leftover handling via per-project snapshot deltas (deploy): `src/JBUniswapV4LPSplitHook.sol:1344-1371`
- Leftover handling via per-project snapshot deltas (rebalance): `src/JBUniswapV4LPSplitHook.sol:2032-2074`
- Rebalance zero-liquidity revert (atomic): `src/JBUniswapV4LPSplitHook.sol:2075-2082`
- Fee routing reserve pre-increment + reconciliation: `src/JBUniswapV4LPSplitHook.sol:2178-2261`
- Fee-token snapshot pinning (anti-migration mixing): `src/JBUniswapV4LPSplitHook.sol:2178-2184`
- `claimFeeTokensFor` permission gate (`SET_BUYBACK_POOL`): `src/JBUniswapV4LPSplitHook.sol:877-880`
- `_claimFeeTokens` state-then-call ordering: `src/JBUniswapV4LPSplitHook.sol:899-912`
- `_claimFeeCredits` try/catch rollback: `src/JBUniswapV4LPSplitHook.sol:920-937`
- Permit2 amount cap and time-bounded approve: `src/JBUniswapV4LPSplitHook.sol:2093-2108`
- Permit2 cleanup after mint: `src/JBUniswapV4LPSplitHook.sol:2114-2122`
- Temporary-allowance consumption check on terminal calls: `src/JBUniswapV4LPSplitHook.sol:820-828`
- One-shot `initialize` sentinel + validation: `src/JBUniswapV4LPSplitHook.sol:279-320`
- Deployer one-shot `setChainSpecificConstants`: `src/JBUniswapV4LPSplitHookDeployer.sol:143-156`
- Deployer salt mixing with `msg.sender`: `src/JBUniswapV4LPSplitHookDeployer.sol:106-108, 130-133`
