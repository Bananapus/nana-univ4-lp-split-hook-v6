# Invariants of `@bananapus/univ4-lp-split-hook-v6`

Scope: the `JBUniswapV4LPSplitHook` split hook and its `JBUniswapV4LPSplitHookDeployer` clone factory. Each cloned hook receives reserved-token distributions (and, after deployment, payout splits in the pool's terminal token) from one or more Juicebox V6 projects, accumulates them, and deploys one Uniswap V4 pool per project. Each project holds at most TWO single-sided positions per `(projectId, terminalToken)` pair: an **ask** of project tokens (`askTokenIdOf`) from just past the live spot up to the issuance ceiling, never below the cash-out floor, and a **bid** of terminal tokens (`bidTokenIdOf`) from just past the live spot down to the cash-out floor, never above the issuance ceiling. Every recycle (inline on each reserved-token distribution via best-effort automation, or the permissionless `deployPool`/`addLiquidity`) collects and routes each live position's fees (net of a best-effort `feeProjectId` cut, the terminal-token remainder added to the project's balance and the project-token remainder burned, each best effort), burns it, claims hook-held credits, recomputes the corridor, and re-mints the ask from the whole project-token ledger and the bid from the whole terminal-token ledger, under a spot-vs-TWAP guard. The corridor floor is the project's cash-out price, but **the hook never performs a cash-out**. **The hook never burns reserved tokens**; the only project tokens it burns are collected LP fees. Supply-reducing burns of reserved tokens are a protocol-layer split-routing decision (route a split to `{projectId:0, hook:0, beneficiary:0xdead}`), not this hook's job. The only Uniswap V4 positions the hook ever burns are its own, during a recycle.

The hook is one Juicebox V6 split-hook implementation among many. It does NOT own project issuance, ruleset behavior, or terminal accounting. Those invariants live in [`nana-core-v6/INVARIANTS.md`](../nana-core-v6/INVARIANTS.md) — read that first if you are reasoning about reserved-token economics, controller permissions, or terminal try/catch behavior. The router/oracle hook side lives in [`univ4-router-v6`](../univ4-router-v6/).

---

## Section A — Guarantees to users (token holders, payers, beneficiaries)

## A.1 Reserved-token routing (pre-deployment)

- A reserved-token split whose `hook == address(this)` deposits the allocated amount into `accumulatedProjectTokens[projectId]` exactly once per `processSplitWith` invocation. The hook pulls `context.amount` via `safeTransferFrom` from the controller and credits the **balance delta** (not the requested amount), so fee-on-transfer project tokens cannot inflate the internal ledger.
- `processSplitWith` rejects any split where `context.split.hook != this`. A misrouted split context cannot trick the hook into accounting for a foreign destination.
- `processSplitWith` rejects any reserved-token split (`groupId == 1`) whose caller is not the project's currently-active controller (`controller == msg.sender`). The hook cannot be tricked into accumulating by a non-controller calling it directly with a forged context.
- `processSplitWith` treats `groupId == 1` as reserved tokens and any other group as a payout of `context.token`, which must arrive under `groupId == uint256(uint160(context.token))` or revert `JBUniswapV4LPSplitHook_InvalidSplitGroup`. The hook does not silently accept arbitrary tokens (see A.2b).
- A credits-only project (no ERC-20 yet) is accepted, not rejected: core transfers the credits to the hook before calling it, so the hook records them in `accumulatedProjectCredits[projectId]` after checking its credit balance covers the prior ledger, the new amount, and outstanding fee-credit claims. No Uniswap work runs until the project deploys an ERC-20; the next recycle then claims the credits into the project-token ledger.
- Intake is durable: once the allocation is accounted, nothing in the `processSplitWith` frame reverts. Automation runs afterward behind a gas-bounded self-call (`executeAutomationFor`); a failed attempt emits `LiquidityAutomationFailed` and the inventory stays in the ledgers for a permissionless retry. The attempt has a fixed budget, `_AUTOMATION_GAS_BUDGET` (2,000,000): it is skipped with less than the budget plus a 64,000 reserve left (and, for reserved-token distributions, below `1e15` accumulated project tokens), and the self-call is forwarded at most the budget. A failed attempt therefore never costs the caller more than the budget, and a caller that supplies the budget plus its own remaining work (later payout recipients or reserved splits) always finishes.
- The first successful deploy or add snapshots the then-current ruleset `weight` into `initialWeightOf[projectId]`. The snapshot is retained purely as a reference; it does not gate anything.
- Balance reconciliation: before a deploy or add consumes the ledger, the hook checks that its ERC-20 balance minus committed fee-token reserves covers `accumulatedProjectTokens`. The check runs at consumption time, not at intake, so a pre-existing inconsistency cannot make core burn a newly delivered allocation.

## A.2 Reserved-token routing (post-deployment)

- Once `hasDeployedPool[projectId] == true`, any subsequent `processSplitWith` distribution for that project keeps accumulating into `accumulatedProjectTokens[projectId]`, the same ledger as pre-deployment, then best-effort recycles inline. The hook never burns reserved tokens; supply-reducing burns of reserved tokens are a protocol-layer split-routing decision (route a split to `{projectId:0, hook:0, beneficiary:0xdead}`), not this hook's job.
- Post-deploy automation recycles the pool recorded in `deployedTerminalTokenOf[projectId]`. Every recycle is keyed by `(projectId, terminalToken)`, so other projects' balances on the same clone are never consumed.
- The deploy transition still sets `hasDeployedPool[projectId] = true` BEFORE the external Uniswap V4 calls inside `deployPool`. Every state-changing external entry point is `nonReentrant`, so a reentrant `processSplitWith` or `deployPool` during deploy reverts; the early flag write is defense in depth.

## A.3 Deployment guarantees

- `deployPool` deploys exactly one pool per project. A second call reverts with `JBUniswapV4LPSplitHook_PoolAlreadyDeployed`. A project's `hasDeployedPool` cannot be re-armed, and `deployedTerminalTokenOf[projectId]` is written once, after the deploy succeeds; `isPoolDeployed` reads both.
- `deployPool` rejects an attempt to deploy a second LP position with a different terminal token for the same project (`JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported`). The hook permanently commits to one terminal token per project, chosen by `JBUniswapV4LPSplitHookMath.findHighestValueTerminalTokenOf` at deploy time.
- The terminal token is selected by the hook itself — it is the token (across all of the project's terminals) with the highest ETH-denominated balance, normalized through the project's price feeds where available, with token-decimal-normalized fallback for unpriced tokens. The caller cannot inject an arbitrary terminal token.
- **Pre-initialized pool defense.** If the pool's V4 PoolKey was already initialized (e.g. an attacker front-ran initialization at an extreme tick), `deployPool` reads the existing `sqrtPriceX96` and reverts with `JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds` if it is at or past the cash-out floor (equality included), ordering-aware. A price at or past the issuance ceiling is accepted: the first recycle then has no ask range and no terminal tokens for a bid, so it reverts `NoDeployableLiquidityAtSpot` until the spot is back inside the corridor. An already-initialized pool must also pass the spot-vs-TWAP guard.
- If the existing initialization passes, the hook uses the existing pool price. The hook does not attempt to overwrite it. A pool the hook initializes itself starts one spacing inside the cash-out floor (on the floor bound itself for a one-spacing corridor). With an empty corridor there is no seed price: `deployPool` reverts `JBUniswapV4LPSplitHook_EmptyCorridor` before initializing a pool or accepting an existing price.
- The cash-out (redemption) price that defines the corridor floor counts surplus across all of the project's local terminals, summed the way settlement does (plus remote surplus and supply when cash outs are not scoped to local balances). A failing surplus, reclaim or price read reverts the bounds rather than reading as zero, and scaling the preview to a per-`1e18` rate saturates at `type(uint256).max` instead of overflowing. It is probed with `min(1e18, totalSupply)` and the reclaim preview is scaled back to a per-`1e18` rate. Projects with less than one whole project token of supply therefore keep their bonding-curve floor instead of falling into the zero-rate fallback. The floor encodes an upper bound on that preview's per-token value (the preview plus two, never zero, since the preview truncates up to twice) toward a higher project price, and the ceiling encodes the net issuance rate bounded from above (the gross rate plus one, times the non-reserved share, rounded up) toward a lower project price. Issuance counts as zero only with zero weight or a 100% reserved rate; a sample that merely rounds to zero is still bounded. With a zero cash-out preview, the floor side of the zero-surplus and full-range corridors still stops at the cash-out bound, and the corridor is empty if that closes it. Both are scaled before the square root, so small rates keep their precision, and both bounds then round inward to the spacing against these exact prices. Under a cash-out tax, larger burns return more per token than the floor, because the curve is size dependent; that is the intended design. This price only places the floor tick; the hook never performs a cash-out.
- The deploy runs the first recycle. With no prior positions and an empty terminal-token ledger, it mints only the ask, from the project tokens the hook already holds (accumulation ledger plus any claimed credits).
- Recovered principal is credited from the **actual balance delta** of each burn, not a reported amount. Fee-on-transfer terminals cannot make the LP spend tokens it never received.
- Before minting, every recycle claims any hook-held project credits into the project's ERC-20 and folds them into the project-token ledger. This keeps Juicebox's credit-first burn order from leaving transferable project tokens outside the ledger.
- A side whose range is empty or whose computed liquidity is zero is skipped, not minted. If neither side mints, the recycle reverts with `JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot`: a deploy then rolls back `hasDeployedPool` and the ledgers, and an add keeps the live positions and their token IDs.
- Leftover project tokens after `MINT_POSITION + SETTLE + SWEEP` are carried back into `accumulatedProjectTokens[projectId]`; leftover terminal tokens into `accumulatedTerminalTokens[projectId][terminalToken]`. The hook never burns leftover and never deposits it into the project's terminal.
- Both ledgers are zeroed before the external mints (CEI) and re-credited only with what a skipped side or mint rounding left unconsumed.

## A.4 Permissionless deployment

- `deployPool(projectId)` is fully permissionless — anyone may seed the pool. There is no permission gate and no weight-decay condition.
- The only gate is economic and lives inside `_recycle`: the seed reverts once the pool's live spot has reached the project's issuance ceiling (there is no ask range and no terminal tokens for a bid), so a pool can only be seeded while there is a live corridor for asks to fill. For an already-initialized pool, the oracle-TWAP deviation guard also applies.
- The permissionless path still goes through all the deployment validations (terminal-token selection, pre-init floor check, `NoDeployableLiquidityAtSpot`). A permissionless caller cannot deploy under worse-than-protected economics, and cannot redirect any value to themselves.

## A.4b Post-deploy recycle (inline automation and `addLiquidity`)

- The inline attempt in `processSplitWith` and `addLiquidity(projectId, terminalToken)` share one executor (`_addLiquidity`). `addLiquidity` is fully permissionless. Both require a deployed pool for that exact pairing (`isPoolDeployed`). `addLiquidity` runs at any time, with or without new tokens, so idle fee inventory and a moved corridor are always recoverable; only the inline attempt on a reserved-token distribution skips below `_MIN_ADD_ACCUMULATION` (1e15) so dust distributions do not spend the distributor's gas; a payout attempts at any size. Recycle timing is open to anyone.
- It reverts with `JBUniswapV4LPSplitHook_TwapUnavailable` if the oracle TWAP (30-minute window) cannot be read, and with `JBUniswapV4LPSplitHook_PriceDeviationTooHigh` if the pool spot tick is more than `_MAX_TWAP_DEVIATION_TICKS` (200, about 2%) from the TWAP tick. It never falls back to spot; accumulation keeps building safely until the recycle can run. A manipulation inside that band can shift the gap between the positions by up to the TWAP tolerance.
- Range geometry: with `spotFloor` the lower of the spot tick and the validated TWAP tick, aligned down to the 200 spacing, and `spotCeil` the higher of the first aligned tick at or above the spot (the spot itself when it sits exactly on an aligned tick) and the TWAP tick aligned up, token0 rests on `[max(spotCeil, corridorLower), corridorUpper]` and token1 on `[corridorLower, min(spotFloor, corridorUpper)]`. Both mints are single-sided and the spot sits in the gap between them: one spacing wide when the spot is off the tick grid, closed when the spot sits exactly on an aligned tick and the TWAP tick equals it (both ranges then touch the spot), and wider when the TWAP anchor sits on the far side of either range's spot bound. The ask never sits below the cash-out floor and the bid never above the issuance ceiling. Anchoring to the TWAP keeps each quote on its own side of it, so the hook never sells project tokens below the TWAP price or buys them above it: a within-band manipulation only widens the gap, it cannot pull a quote past the TWAP.
- Every recycle retires each live position (collect and route fees, then burn with the contract-derived slippage floor, crediting recovered principal to the ledgers), claims hook-held credits, recomputes the corridor, then mints the ask from the whole `accumulatedProjectTokens` and the bid from the whole `accumulatedTerminalTokens`. Tokens a position converted into while trading are thereby moved back to the side they belong on. The burns are pure liquidity withdrawals (no AMM swap).
- It never cashes out and never routes through the AMM it feeds. The bid is funded solely from **this project's own** `accumulatedTerminalTokens[projectId][terminalToken]`, which is credited only from its own burns, mint leftovers, payout splits, and terminal-token fee remainders whose add to its balance failed.
- At most two positions exist per `(projectId, terminalToken)`. `askTokenIdOf` and `bidTokenIdOf` are deleted when the old positions are retired and written only after the new mints; a side that did not mint is zero.
- Both ledgers are zeroed before the external mints (CEI); leftovers are carried forward afterward, never burned, never deposited into the project's terminal.

## A.2b Payout splits (post-deployment)

- A payout split (`groupId != 1`) must arrive under `groupId == uint256(uint160(context.token))` (else `InvalidSplitGroup`), from a terminal of the project (`DIRECTORY.isTerminalOf`, else `SplitSenderNotValidControllerOrTerminal`), after deployment (else `InvalidStageForAction`), in `deployedTerminalTokenOf[projectId]` (else `InvalidTerminalToken`). Payouts can only ever fund the deployed pool's bid.
- Native payouts must carry `msg.value == context.amount`; ERC-20 payouts must carry no value, and the hook pulls `context.amount` with `safeTransferFrom` and credits the balance delta. Otherwise `UnexpectedMsgValue`.
- The received amount is credited to `accumulatedTerminalTokens[projectId][token]` exactly once and `PayoutAccepted` is emitted, then the same gas-bounded automation attempt runs, with no `_MIN_ADD_ACCUMULATION` gate. Every rejection happens before the ledger write and reverts, so Core returns the whole payout to the project's balance.

## A.5 Fee routing (post-deployment)

- `collectAndRouteLPFees` is **permissionless**. Anyone can trigger a fee collection cycle. It collects fees from the ask and the bid, whichever are live, and reverts `InvalidStageForAction` when neither is. Each side — project-token and terminal-token — takes a best-effort `feeProjectId` cut (via `_attemptFeeProjectCut`), and the non-cut remainder of each side accrues to this project and raises its cash-out floor: the terminal-token remainder is added to the project's balance in its primary terminal for that token, and the project-token remainder is burned through the controller. A side whose route reverts is carried into this project's own ledger instead: `accumulatedTerminalTokens[projectId][terminalToken]` or `accumulatedProjectTokens[projectId]`. No caller receives extracted value.
- `_collectAndRouteFees` collects fees via `DECREASE_LIQUIDITY(0) + TAKE_PAIR`, which never removes principal liquidity — only accrued fees. A permissionless caller cannot drain the LP position by repeatedly invoking it.
- `_routeCollectedFees` splits the collected pair into its project-token and terminal-token sides and calls `_attemptFeeProjectCut` on EACH side independently — the cut is symmetric, not one-sided. The remainder is then routed through a try/catch self-call (`sendToTerminal` with `shouldPay: false` for the terminal side, `burnFeeRemainder` for the project side) and credited to its ledger only when that call reverts. It is in no ledger while the external call runs, and every entry point that could spend hook balances holds the reentrancy lock, so it can neither be spent nor double-counted. A failure never blocks the collection or the other side.
- The fee-project cut on either side is credited to the fee project's **primary** terminal for that token, not an attacker-chosen one. If the fee project has no primary terminal accepting that token, `_attemptFeeProjectCut` forgives the cut for that side and the full amount is routed to the project as its remainder — a misconfigured fee project never blocks or shrinks the project's own fee collection.
- A reverting fee-project `pay` call is forgiven the same way: `_attemptFeeProjectCut` pays through a try/catch self-call (`sendToTerminal` with `shouldPay: true`) and, on failure, fully rolls back any pre-incremented reserve and routes the whole amount to the project as its remainder. Fee collection itself can never fail because of the fee project's state.
- The fee-project payment uses `minReturnedTokens: 0` by design. Slippage protection is the fee project's responsibility (its own data hook / buyback hook); see `RISKS.md` §7.2.
- The fee project's returned ERC-20 amount is measured via balance delta, not the `pay()` return value, whenever the fee project has an ERC-20 deployed. Fee-on-transfer or nonstandard fee-project terminals cannot overstate what the hook actually received.

## A.6 Fee-token claim segregation

- `claimableFeeTokens[projectId]` is denominated in the snapshotted `claimableFeeTokenOf[projectId]` ERC-20. Once a project has any unclaimed fee-token balance, that token address is pinned. A later fee-routing call where the fee project's ERC-20 has changed (e.g. token migration) reverts with `JBUniswapV4LPSplitHook_UnclaimedFeeTokenChanged` rather than silently mixing two different ERC-20s into the same balance.
- Fee tokens claimable for **other** projects' unclaimed balances are excluded from the ledger reconciliation before deploy and add via the `_unavailableFeeTokenBalance` reserve. Cross-project fee claims cannot be cannibalized by another project's accumulation or LP-funding path.
- Fee credits claimable for **other** projects' unclaimed balances are never normalized into principal: `_claimHookCreditsFor` claims every credit the hook holds for the project except the owed `_totalOutstandingFeeCreditClaims[projectId]` (accepted `accumulatedProjectCredits` plus any credits sent from outside, which become ask inventory), and intake requires the credit balance to cover that ledger plus `_totalOutstandingFeeCreditClaims[projectId]`. If the fee project later deploys LP through the same clone, only credits not owed as fee claims become ERC-20 principal.
- During in-flight fee routing, `_inflightFeeRoutingCount[token]` makes `_unavailableFeeTokenBalance` conservatively report the **full balance** as unavailable. A reentrant accumulation or mint cannot read partially-updated reserve state and over-spend.
- `claimFeeTokensFor` clears `claimableFeeTokens[projectId]` and `claimableFeeTokenOf[projectId]` BEFORE the `safeTransfer`, so a reverting ERC-20 atomically restores state along with the event.
- Credit-only claims (when the fee project has no ERC-20) go through `transferCreditsFrom` in a try/catch. On failure the pending credit balance is restored, so a paused/misconfigured fee-project controller does not strand an ERC-20 fee-token claim that already succeeded earlier in the same call.

## A.7 Recycle guarantees

- A recycle is structurally `TWAP guard -> for each live position: collect and route fees, burn -> claim credits -> recompute corridor -> mint ask and bid`. Fees are collected before each burn so the fee-project cut applies to trading fees only, and each side's non-cut remainder is routed once rather than being read twice, once as fees and once as burn principal. Fee routing runs before the corridor is recomputed, so the surplus it adds and the supply it burns are priced into the new floor.
- The burn slippage floor is contract-derived: 95% of the position's principal computed from its on-chain liquidity and the ticks read from the PositionManager, at the live spot. Callers never supply burn minimums.
- Mint amounts come from the per-project ledgers, which are credited from per-call balance deltas. Other projects' balances held on the same hook clone cannot be drained into one project's positions.
- If neither side can mint (empty ranges or zero liquidity), the recycle reverts with `JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot`. The burns roll back with it, so the live positions and their token IDs are preserved and the recycle can run again later.
- Leftovers after the mints: project-token leftovers are carried back into `accumulatedProjectTokens`; terminal-token leftovers into `accumulatedTerminalTokens[projectId][terminalToken]`. Leftovers are never burned and never deposited into the project's terminal balance. Conservation holds modulo on-chain rounding and the burn slippage floor.

## A.8 Initialization safety

- `initialize` on a clone is one-shot: the call reverts with `JBUniswapV4LPSplitHook_AlreadyInitialized` if `poolManager != address(0)`. The deployer factory calls `initialize` atomically with `clone`, so no third party can front-run the first call with hostile values.
- `initialize` rejects `newPoolManager == address(0)` (the sentinel for "not yet initialized"). The hook cannot be left in a half-initialized state where the sentinel passes but pool operations would silently no-op.
- `initialize` rejects `feePercent > BPS` (>100%) and `feePercent > 0 && feeProjectId == 0` (configured fees with no fee project — would strand routed fees).
- A configured `feeProjectId` is validated to have an existing controller (`controllerOf(feeProjectId) != address(0)`). Initialization against a non-existent fee project reverts up front.
- Fee config (`feeProjectId`, `feePercent`) and chain-specific Uniswap V4 wiring (`poolManager`, `positionManager`, `oracleHook`) are immutable post-initialization. Neither the project owner nor the deployer can rotate them.

## A.9 Permit2 hygiene

- Before any V4 `MINT_POSITION` settle, the hook grants Permit2 a time-bounded allowance (`expiration = block.timestamp + 60s`) and rejects `amount > type(uint160).max` up front.
- After the V4 mint returns, the hook clears both the Permit2 spender allowance (`approve(token, positionManager, 0, expiration=1)`) and the ERC-20 approval to Permit2 (`forceApprove(permit2, 0)`). No residual pull authority survives a successful mint.
- For the fee project's terminal during the best-effort fee-cut payment (`sendToTerminal` with `shouldPay: true`), and for the project's own terminal during the best-effort fee-remainder add (`shouldPay: false`), the hook calls `_requireTemporaryAllowanceConsumed` after the external `pay` or `addToBalanceOf` call for ERC-20 tokens. A fee terminal that does not consume the full pre-call allowance reverts with `JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed` — caught and forgiven by the surrounding best-effort wrapper rather than blocking collection, so a leaked approval never sits open for an attacker to exploit later.

---

## Section B — Guarantees to operators (project owner / `SET_BUYBACK_POOL` delegate)

## B.1 Powers the operator has

- **Deploy the pool.** Call `deployPool(projectId)`. Permissionless; anyone (including the operator) may seed the pool, and the seed reverts once the pool spot reaches the issuance ceiling. A reserved-token distribution also attempts it inline.
- **Recycle the positions.** Call `addLiquidity(projectId, terminalToken)` to collect fees, burn the ask and bid, and re-mint both around the live spot. Permissionless at any time, subject to the TWAP-deviation guard. A reserved-token distribution also attempts it inline.
- **Claim accumulated fee tokens.** Call `claimFeeTokensFor(projectId, beneficiary)`. This is the one operator-exclusive power, gated by `SET_BUYBACK_POOL`. Pulls claimable ERC-20 fee tokens and/or fee-project credits to the chosen beneficiary.
- **Deploy new hook clones.** Anyone can call `JBUniswapV4LPSplitHookDeployer.deployHookFor(feeProjectId, feePercent, buybackHook, salt)`. The new clone's fee config is set at the salt-deterministic clone address; the caller is mixed into the salt so a competitor cannot squat a `(msg.sender, salt)` they don't control.

## B.2 Powers the operator does NOT have

- **No re-initialization.** A clone's `feeProjectId`, `feePercent`, `poolManager`, `positionManager`, and `oracleHook` are set once at `initialize` and cannot be rotated by anyone — including the deployer factory operator.
- **No reversal of accumulation → deploy.** `hasDeployedPool[projectId]` cannot be set back to false. There is no `undeployPool` path. A wrongly-deployed pool requires migrating to a new hook clone.
- **No override of terminal-token selection.** `_findHighestValueTerminalTokenOf` is what picks the terminal token at deploy. The operator cannot pass a different one to `deployPool`.
- **No caller-set slippage.** Burn slippage floors are contract-derived (a fraction of a pre-burn principal read at the live spot). Callers cannot supply or disable them.
- **No partial recycle.** A recycle retires and re-mints both positions in one call. The operator cannot recycle just one side, choose ranges, or skip the collect step.
- **No direct token withdrawal.** There is no `rescueTokens` or `withdraw` function. The hook's only paths out are: pay a best-effort `feeProjectId` cut to the fee project's terminal via `terminal.pay`, add a collected terminal-token LP-fee remainder to the project's own balance via `terminal.addToBalanceOf`, burn a collected project-token LP-fee remainder via `controller.burnTokensOf`, or mint a V4 position. The hook never cashes out and never burns reserved tokens. Stuck tokens (e.g. accidentally-sent foreign ERC-20s) cannot be recovered by the operator.

## B.3 Permissionless triggers the operator should expect

- **`deployPool`.** Permissionless — anyone can seed the pool; the seed reverts once the pool spot reaches the issuance ceiling. This prevents a missing or hostile operator from locking accumulated reserved tokens forever. The operator cannot veto deployment timing.
- **`addLiquidity` and reserved distribution.** Permissionless; anyone can trigger a recycle at any time, directly or by distributing reserved tokens. Bounded by the TWAP-deviation guard and the corridor caps, so the caller can only force recycle timing (and, within the TWAP band, where the gap sits), not extract value.
- **`collectAndRouteLPFees`.** Anyone can collect and route fees at any time. The operator cannot reserve "this fee cycle is for project usage X" — collection is opportunistic.
- **`JBUniswapV4LPSplitHookDeployer.deployHookFor`.** Anyone can deploy a hook clone with any `(feeProjectId, feePercent)` settings. Multiple hook clones can coexist for the same fee project. The operator chooses which clone(s) their splits reference.

## B.4 Liveness guarantees

- A missing or reverting fee-project terminal does NOT block the project's own fee inflow: `_attemptFeeProjectCut` forgives the cut (whether from a missing terminal or a reverting `pay`) and the entire collected amount for that side is carried into the project's own ledger (`accumulatedProjectTokens` or `accumulatedTerminalTokens`) instead.
- A reverting fee-project credit transfer (in `_claimFeeCredits`) does NOT unwind a successful ERC-20 fee-token claim in the same `claimFeeTokensFor` call; the credit balance is restored for later retry.
- A reverting V4 mint reverts the entire `deployPool` or `addLiquidity` call; no partial state survives and the ledgers are preserved so anyone can retry. Inside `processSplitWith` the same failure is caught by the automation self-call and reported as `LiquidityAutomationFailed`; intake still succeeds.

---

## Section C — Per-contract operation inventory

## C.1 `JBUniswapV4LPSplitHook` — `src/JBUniswapV4LPSplitHook.sol`

Inherits `IJBUniswapV4LPSplitHook`, `IJBSplitHook`, `JBPermissioned`. Cloneable; each clone manages many projects but at most one deployed pool per project.

**Initialization (one-shot per clone):**

- **`initialize(initialFeeProjectId, initialFeePercent, newPoolManager, newPositionManager, newOracleHook, newBuybackHook)`** — anyone in principle, but in practice the deployer factory's `deployHookFor` calls it atomically with the clone.
  - **Invariant:** one-shot via `poolManager == address(0)` sentinel; `newPoolManager` must be non-zero; `feePercent ≤ BPS`; `feePercent > 0 ⇒ feeProjectId != 0`; configured `feeProjectId` must have a controller.

**Split routing (controller-only):**

- **`processSplitWith(JBSplitHookContext) payable`** — reserved-token splits (`groupId == 1`) only from the project's currently-active controller; payout splits (`groupId == uint256(uint160(token))`) only from a terminal of the project (see A.2b). Requires `context.split.hook == this`.
  - **Pre- AND post-deploy (identical intake):** credits-only projects record the amount in `accumulatedProjectCredits` (credit balance must cover ledger, amount, and outstanding fee-credit claims) and return; ERC-20 projects accumulate `received = balance delta` into `accumulatedProjectTokens[projectId]`, then, at or above `_MIN_ADD_ACCUMULATION`, call `_attemptAutomation` (deploy if no pool, otherwise recycle) behind a gas-bounded self-call. The hook never burns reserved tokens.
  - **Payout (post-deploy only):** credits `received` to `accumulatedTerminalTokens[projectId][token]`, emits `PayoutAccepted(projectId, terminalToken, amount, caller)`, then calls `_attemptAutomation` at any size.
  - **Invariant:** intake never reverts after accounting; a failed automation attempt rolls back only itself; nonzero `msg.value` on a reserved-token or ERC-20 payout split, or a native payout's `msg.value != context.amount`, reverts `UnexpectedMsgValue`.

**Permissionless lifecycle triggers:**

- **`deployPool(projectId)`** — permissionless. Selects the highest-ETH-value terminal token via `findHighestValueTerminalTokenOf`. Sets `hasDeployedPool[projectId] = true` before any external calls. Initializes or accepts a pre-initialized pool (rejected at or past the cash-out floor; the oracle-TWAP guard applies to an already-initialized pool). Runs the first recycle, which mints a single-sided ask of the accumulated project tokens from just past the live spot up to the issuance ceiling via Permit2 + V4 `MINT_POSITION + SETTLE + SWEEP`, with no cash-out. Records `deployedTerminalTokenOf` and emits `ProjectDeployed`.
  - **Invariants:** one-shot per project (only one terminal token supported per project); economic spot-below-ceiling gate; pre-init pool rejected at or past the floor; `NoDeployableLiquidityAtSpot` reverts atomically; leftover carried to the project's own ledgers, never burned, never deposited into the project's terminal.

- **`addLiquidity(projectId, terminalToken)`** — permissionless. Requires `isPoolDeployed` for the pairing; runs with or without new accumulation (`_MIN_ADD_ACCUMULATION` gates only the inline automation attempt). Reverts on TWAP unavailability or spot/TWAP deviation above `_MAX_TWAP_DEVIATION_TICKS`. Runs `_recycle`: for each live position, collect and route fees (best-effort `feeProjectId` cut per side, non-cut remainder added to the project's balance or burned, falling back to this project's own ledger), burn it with a contract-derived slippage floor, credit recovered principal; claim credits; recompute the corridor; mint the ask from the whole project ledger and the bid from the whole terminal ledger around the live spot. Carries leftovers forward. Emits `LiquidityAdded(projectId, terminalToken, askTokenId, bidTokenId, caller)`.
  - **Invariants:** never recycles at a manipulated ratio beyond the TWAP band; never cashes out and never routes through the AMM it feeds; at most two positions per pair; ask never below the floor, bid never above the ceiling; `NoDeployableLiquidityAtSpot` keeps the live positions; per-`(projectId, terminalToken)` keying isolates clone-shared balances.

**Operator-gated:**

- **`claimFeeTokensFor(projectId, beneficiary)`** — `SET_BUYBACK_POOL` permission required. Sends `claimableFeeTokens[projectId]` of the snapshotted `claimableFeeTokenOf[projectId]` ERC-20, then `claimableFeeCredits[projectId]` via `transferCreditsFrom`. State cleared before external calls; credit path try/catch with rollback.
  - **Invariants:** ERC-20 fee-token claim atomic with its `safeTransfer`, which reverts `TransferNotExact` if it debits the hook more than the claim; failed credit claim does not unwind a successful prior ERC-20 claim.

**Permissionless triggers:**

- **`collectAndRouteLPFees(projectId, terminalToken)`** — anyone. Requires `askTokenIdOf` or `bidTokenIdOf` to be nonzero. Calls `_collectAndRouteFees` for each live position, which uses `DECREASE_LIQUIDITY(0) + TAKE_PAIR` to fetch only accrued fees; `_routeCollectedFees` then takes a best-effort `feeProjectId` cut on EACH side (project-token and terminal-token) via `_attemptFeeProjectCut`, then adds the terminal-token remainder to the project's balance (`sendToTerminal`, `shouldPay: false`) and burns the project-token remainder (`burnFeeRemainder`), carrying a remainder whose route reverts into this project's own ledger — `accumulatedTerminalTokens[projectId][terminalToken]` for the terminal-token side, `accumulatedProjectTokens[projectId]` for the project-token side. The positions are not moved.
  - **Invariants:** principal liquidity never removed; the non-cut remainder sits in no ledger during the external calls and is credited only when its route reverts, under the reentrancy lock; routed amounts measured by balance delta, not return values; a missing or reverting fee-project terminal forgives that side's cut rather than stranding the project's share; a send that debits the hook more than its amount (a terminal token that charges the sender on top of the transfer) reverts `TransferNotExact`, so that cut is forgiven or that remainder is ledgered.

**Receive / interfaces:**

- **`receive() payable`** — accepts ETH from V4 `TAKE`/`SWEEP` operations (native payouts arrive as `processSplitWith` value, not here). Unledgered ETH is settlement dust.
- **`supportsInterface(bytes4)`** — `IJBUniswapV4LPSplitHook` and `IJBSplitHook`.

**Public state (selected, all read-only via auto-getters):**

- `accumulatedProjectTokens[projectId]` — the ask ledger (pre- AND post-deploy); credited by reserved inflows, recovered principal, claimed credits, leftovers, and non-cut project-token fee remainders whose burn failed; zeroed before each recycle's mints and re-credited with what they leave.
- `accumulatedProjectCredits[projectId]` — credits accepted while the project has no ERC-20; claimed into the ask ledger by the next recycle or project-side fee burn, together with any other non-owed credits the hook holds.
- `accumulatedTerminalTokens[projectId][terminalToken]` — the per-project bid ledger; credited only from this project's own burn principal, its own mint leftovers, its own payout splits, and its own non-cut terminal-token fee remainder whose add to its balance failed, never from another project's balance or the shared clone's raw terminal-token balance. Zeroed before each recycle's mints and re-credited the same way as the ask ledger.
- `hasDeployedPool[projectId]` — irreversible first-deploy flag; `deployedTerminalTokenOf[projectId]` — the deployed pairing, written once after the deploy succeeds.
- `askTokenIdOf[projectId][terminalToken]` / `bidTokenIdOf[projectId][terminalToken]` — the live ask and bid position NFT ids (zero when that side is not minted). Burn floors read each position's ticks from the PositionManager, so no tick state is stored.
- `poolKeysOf[projectId][terminalToken]` — PoolKey; set during `_createAndInitializePool`.
- `initialWeightOf[projectId]` — snapshotted on the first successful deploy or add; retained as a reference and does not gate anything.
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

1. **Balance-delta accounting everywhere.** All token-side amounts that drive subsequent state (accumulation, recovered burn principal, leftover handling, routed fee amount) are measured as `balanceAfter − balanceBefore`, not from external return values. Fee-on-transfer tokens and nonstandard terminals cannot inflate the hook's internal ledger. Fee-routing sends also check the outgoing side: `sendToTerminal` reverts `TransferNotExact` when the hook is debited more than it sent, and the fee-remainder burn reverts unless exactly the remainder is burned. Mints check it too: `_carryLeftovers` reverts `TransferNotExact` when a mint debits the hook more than it offered, so a token that charges the sender on top of a pull cannot spend another project's balance. The fee-token claim checks it as well: `_claimFeeTokens` reverts `TransferNotExact` when the transfer debits the hook more than the claim, restoring the claim and its reserve.

2. **Per-project snapshot deltas in shared-clone storage.** Because one hook clone can manage many projects, every multi-project-touching path (accumulation reconciliation, post-mint leftover handling, fee-routing ERC-20 measurement) uses per-call before/after snapshots of `IERC20.balanceOf(this)`. Other projects' balances cannot leak into one project's leftover or be drained into one project's LP; a mint, send or fee-token claim that debits the hook more than it offered reverts `TransferNotExact`.

3. **Fee-token and fee-credit claim segregation.** `_unavailableFeeTokenBalance(token)` returns the full balance during in-flight routing (`_inflightFeeRoutingCount > 0`) and the cumulative outstanding claims otherwise. Every ledger reconciliation before deploy and add subtracts this reserve. `_claimHookCreditsFor` claims only the accounted `accumulatedProjectCredits`, never credits held for fee claimants. A project's claimable fee value cannot be cashed-out, claimed into principal, or spent into LP by another project sharing the clone.

4. **State-then-call ordering in fee routing.** `_attemptFeeProjectCut` pre-increments `_totalOutstandingFeeTokenClaims` and `_inflightFeeRoutingCount` BEFORE calling the fee project's terminal `pay()` (via the self-called `sendToTerminal`), then reconciles after — or fully rolls back both reserves on the forgive/catch path. A reentrant collection during the external call sees an inflated reserve, which conservatively prevents over-spending.

5. **State-then-call ordering in deployment and recycles.** `hasDeployedPool[projectId] = true` is set BEFORE the external V4 / terminal calls in `deployPool`, and `_recycle` zeroes both ledgers before the external mints. Every state-changing external entry point is `nonReentrant`, so a reentrant call into any of them during a deploy or recycle reverts; the unguarded self-call targets `executeAutomationFor`, `sendToTerminal`, and `burnFeeRemainder` are callable only by the hook itself (else `Unauthorized`) and run under the outer lock, so a reentrant terminal or controller cannot reach a guarded entry point.

6. **State-then-call ordering in claims.** `claimFeeTokensFor` clears `claimableFeeTokens` / `claimableFeeTokenOf` and decrements the reserve BEFORE the `safeTransfer`. A reverting transfer atomically restores state via the EVM rollback.

7. **One-shot bindings everywhere.** `JBUniswapV4LPSplitHook.initialize`, `JBUniswapV4LPSplitHookDeployer.setChainSpecificConstants`, `deployPool` (per project / per terminal-token pair). None can be re-armed by anyone.

8. **No direct withdrawal.** The hook holds tokens only to (a) accumulate for LP in `accumulatedProjectTokens` / `accumulatedTerminalTokens`, (b) pay a best-effort protocol fee cut to the fee project's terminal, (c) mint into / increase a V4 position, (d) add collected terminal-token LP-fee remainders to the project's own balance and burn collected project-token LP-fee remainders. The hook never cashes out and never burns reserved tokens. There is no `rescue` / `withdraw` / `recover` function. Misrouted foreign tokens cannot be extracted by the operator.

9. **Pre-init pool defense.** A front-runner can initialize the V4 pool first, but cannot make the hook sell below the cash-out floor: `_createAndInitializePool` reverts on an existing price at or past the floor (ordering-aware, equality included). A price at or past the issuance ceiling is accepted and leaves the first recycle without an ask range, so the deploy waits until the spot returns inside the corridor.

10. **Burn slippage floor is contract-derived.** On every recycle, each burn's minimum-out is a fraction of a pre-burn principal read at the live spot (`_burnSlippageFloor`). Callers never supply or lower it, so a burn cannot be forced to accept an arbitrarily bad recovery.

11. **Recycle atomicity.** If neither side mints after the burns, the entire recycle reverts with `NoDeployableLiquidityAtSpot`. The old positions are never destroyed unless at least one new position is minted, except when the corridor is empty (the cash-out value reaches the issuance price, or no aligned spacing fits between the bounds), where `calculateTickBounds` returns `(0, 0)` and the recycle deliberately retires both positions and holds every token in the ledgers; with nothing to retire it reverts `EmptyCorridor`.

12. **At most two positions per pair.** `askTokenIdOf` and `bidTokenIdOf` are the only position ids the hook tracks for a `(projectId, terminalToken)`; every recycle burns both before minting at most one of each.

13. **Permissionless settlement triggers never extract value beyond canonical allocation.** `deployPool` (economic spot-below-ceiling gate), `addLiquidity` (TWAP-deviation guard + TWAP-anchored quotes + corridor caps), `collectAndRouteLPFees`, `processSplitWith` (controller- or terminal-only but downstream-permissionless through `sendReservedTokensToSplitsOf` and `sendPayoutsOf`) — none of these allow the caller to redirect value to themselves. The caller can only force settlement timing.

---

## Section E — Out-of-scope centralization caveats

These are NOT third-party attack vectors but are powers held outside the hook itself:

- **Per-project owner / `SET_BUYBACK_POOL` delegate.** Exclusively controls fee claiming (`claimFeeTokensFor`); like anyone else, they can deploy and add. Their project, their problem. Even a hostile delegate cannot recycle at a spot price that deviates from the oracle TWAP beyond `_MAX_TWAP_DEVIATION_TICKS`; both deploy (on an existing pool) and add revert on that deviation.
- **Fee-project owner.** Configures the fee-project terminal. A misconfigured fee-project terminal (missing primary terminal for the collected token) silently forfeits the fee cut on that side, and the full amount is routed to the project as its remainder instead; this is documented in RISKS.md §7.2 and §7.5.
- **Deployer Safe (`_DEPLOYER`).** Sets `setChainSpecificConstants` once. Compromise of this Safe before the one-shot call could redirect V4 wiring (PoolManager, PositionManager, oracle hook) to a malicious implementation. After the one-shot call, the deployer Safe has no power over this contract.
- **Project's controller.** Calls `processSplitWith` on behalf of the project. A malicious controller could in principle send arbitrary `context` data, but `context.split.hook == this` and `controller == msg.sender` are checked. The controller cannot mint or burn tokens through the hook beyond what reserved-token splits authorize.
- **Project's terminals.** Deliver payout splits; any terminal of the project is accepted, but only in the deployed pool's terminal token under that token's group. The primary terminal also receives LP-fee remainders through `addToBalanceOf`; a rejecting terminal only sends the remainder back to the bid ledger.
- **Uniswap V4 PoolManager / PositionManager.** Held trusted on the critical external-call boundary during deployment. A compromise of these contracts is outside the hook's local threat model — see `RISKS.md` §7.1.
- **Oracle hook (`oracleHook`).** Set at initialization and immutable thereafter. The hook trusts the oracle hook for TWAP / market-side behavior; see `univ4-router-v6` for the canonical oracle implementation.

---

## Section F — Key code references

All in `src/JBUniswapV4LPSplitHook.sol` unless noted. Function names are used instead of line numbers.

- Durable intake and best-effort automation: `processSplitWith`, `_accumulateTokens`, `_attemptAutomation`, `executeAutomationFor`, `_boundedSelfCall`
- Credit intake and normalization: `processSplitWith` (credits branch), `_claimHookCreditsFor`
- Recycle entry and gates (threshold, balance reconciliation, TWAP guard): `addLiquidity`, `_addLiquidity`
- Two-position recycle (range geometry, CEI ledger zeroing, `NoDeployableLiquidityAtSpot`): `_recycle`
- Retire one position (fees, burn floor, recovered principal): `_retirePosition`, `_burnSlippageFloor`, `_burnExistingPosition`
- Single-sided mint (skips empty range or zero liquidity): `_mintSingleSided`, `_mintPosition`
- Leftover carry-forward, never burned: `_carryLeftovers`
- TWAP-deviation guard: `_requireSpotNearTwap`
- Fee collection from both positions and per-side routing: `collectAndRouteLPFees`, `_collectAndRouteFees`, `_routeCollectedFees`
- Fee-project cut, reserve pre-increment and rollback, fee-token pinning: `_attemptFeeProjectCut`, `sendToTerminal`
- Fee remainder routing and ledger fallback: `_routeCollectedFees`, `sendToTerminal`, `burnFeeRemainder`
- Payout intake: `processSplitWith`, `_acceptPayout`
- Permissionless `deployPool`, one-shot guards, state-before-call `hasDeployedPool`: `deployPool`, `_deployPool`, `_deployPoolAndAddLiquidity`
- Pre-initialized pool floor check: `_createAndInitializePool`
- `claimFeeTokensFor` permission gate (`SET_BUYBACK_POOL`) and claim ordering: `claimFeeTokensFor`, `_claimFeeTokens`, `_claimFeeCredits`
- Permit2 amount cap, time-bounded approve, cleanup: `_approveViaPermit2`, `_clearPermit2Approval`
- Temporary-allowance consumption check on terminal calls: `_requireTemporaryAllowanceConsumed`
- Fee-token reserve: `_unavailableFeeTokenBalance`
- One-shot `initialize` sentinel + validation: `initialize`
- Deployer one-shot `setChainSpecificConstants` and salt mixing with `msg.sender`: `setChainSpecificConstants`, `deployHookFor` in `src/JBUniswapV4LPSplitHookDeployer.sol`
