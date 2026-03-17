# User Journeys -- univ4-lp-split-hook-v6

Concrete end-to-end flows through the LP split hook system. Each journey traces the exact function calls, state changes, and external interactions.

## Journey 1: Deploy an LP Split Hook Clone

**Actor:** Project operator or protocol deployer.
**Goal:** Create a new hook instance configured for a specific fee project and fee percentage.

### Steps

1. **Call `JBUniswapV4LPSplitHookDeployer.deployHookFor(feeProjectId, feePercent, salt)`**

   - If `salt == bytes32(0)`: deploys via `LibClone.clone(HOOK)` (non-deterministic)
   - If `salt != bytes32(0)`: deploys via `LibClone.cloneDeterministic(HOOK, keccak256(abi.encode(msg.sender, salt)))` (CREATE2)
   - The clone delegates all calls to the implementation but has its own storage

2. **Deployer calls `hook.initialize(feeProjectId, feePercent)`**

   - Validates: `!initialized`, `feePercent <= BPS`, `feePercent > 0 implies feeProjectId != 0`, `controllerOf(feeProjectId) != address(0)`
   - Sets `initialized = true`, `FEE_PROJECT_ID`, `FEE_PERCENT`
   - These values are permanent -- no way to change them after initialization

3. **Deployer registers the clone in the address registry**

   - `ADDRESS_REGISTRY.registerAddress(deployer, nonce)` or deterministic variant
   - Increments deployer's internal nonce

### Result

A new `JBUniswapV4LPSplitHook` clone is deployed, initialized, and registered. It shares all immutable infrastructure (DIRECTORY, TOKENS, POOL_MANAGER, POSITION_MANAGER, PERMIT2, ORACLE_HOOK) with the implementation.

### What to verify

- The clone's `FEE_PROJECT_ID` and `FEE_PERCENT` match the constructor args.
- `initialize()` reverts on second call.
- The clone correctly delegates to the implementation for all function calls.
- CREATE2 deployment produces the expected address (predictable for frontends).

---

## Journey 2: Accumulate Tokens via Reserved Splits

**Actor:** JB Controller (system), triggered by reserved token distribution.
**Goal:** Build up a balance of project tokens for eventual LP deployment.

### Precondition

The project's ruleset has a reserved token split configured with `hook = address(lpSplitHook)`. No pool has been deployed yet (`deployedPoolCount[projectId] == 0`).

### Steps

1. **JB Controller calls `sendReservedTokensToSplitsOf(projectId)` on JBController**

   - Controller mints reserved tokens and distributes them to splits
   - For the LP hook split, controller calls `hook.processSplitWith(context)` where:
     - `context.split.hook == address(this)`
     - `context.projectId` is the project
     - `context.groupId == 1` (reserved tokens group)
     - `context.amount` is the token amount for this split
     - `context.token` is the project token address

2. **`processSplitWith` validates and accumulates**

   - Checks: `context.split.hook == address(this)`, `controllerOf(projectId) != address(0)`, `msg.sender == controllerOf(projectId)`, `context.groupId == 1`
   - Since `deployedPoolCount == 0`, enters accumulation branch:
     - On first accumulation: reads `currentRulesetOf(projectId)` and stores `initialWeightOf[projectId] = ruleset.weight`
     - Adds `context.amount` to `accumulatedProjectTokens[projectId]`

3. **Repeated over multiple reserved token distributions**

   - Each distribution cycle triggers another `processSplitWith` call
   - `accumulatedProjectTokens` grows with each cycle
   - `initialWeightOf` is only set once (first accumulation)

### Result

The hook holds project tokens in `accumulatedProjectTokens[projectId]`. The tokens are ERC-20 balances on the hook contract. `initialWeightOf[projectId]` records the ruleset weight at the time accumulation began.

### What to verify

- `accumulatedProjectTokens` increases by exactly `context.amount` each time.
- `initialWeightOf` is only set once, on the first accumulation for each project.
- Tokens from different projects are tracked independently.
- `processSplitWith` reverts if called by anyone other than the project's controller.
- `processSplitWith` reverts if `groupId != 1` (prevents terminal token splits from reaching the hook).

---

## Journey 3: Deploy a Uniswap V4 Pool

**Actor:** Project owner or authorized operator (with `SET_BUYBACK_POOL` permission).
**Goal:** Transition from accumulation to active LP by deploying a V4 pool.

### Precondition

Tokens have been accumulated (`accumulatedProjectTokens[projectId] > 0`). No pool exists for this project/terminal-token pair.

### Steps

1. **Caller invokes `deployPool(projectId, terminalToken, minCashOutReturn)`**

   - Permission check: requires `SET_BUYBACK_POOL` from project owner, unless `ruleset.weight * 10 <= initialWeightOf[projectId]`
   - Checks: `tokenIdOf == 0`, `accumulatedProjectTokens > 0`, `primaryTerminalOf(projectId, terminalToken) != address(0)`

2. **`_createAndInitializePool()` creates the V4 pool**

   - Builds `PoolKey` with sorted currencies, `POOL_FEE = 10_000`, `TICK_SPACING = 200`, `hooks = ORACLE_HOOK`
   - Computes initial price as geometric mean of cashout rate and issuance rate via `_computeInitialSqrtPrice()`
   - Calls `POSITION_MANAGER.initializePool(key, sqrtPriceX96)` -- safe if pool already exists (returns `type(int24).max`)
   - Stores `_poolKeys[projectId][terminalToken]`

3. **`_addUniswapLiquidity()` creates the LP position**

   a. Computes tick bounds: `_calculateTickBounds()` derives `tickLower` from cashout rate and `tickUpper` from issuance rate (sorted, aligned to `TICK_SPACING`)

   b. Reads actual pool price from `POOL_MANAGER.getSlot0()`

   c. Computes how many project tokens to cash out: `_computeOptimalCashOutAmount()` uses LP geometry to balance both sides of the position

   d. Calls `terminal.cashOutTokensOf()` to convert a portion of project tokens to terminal tokens. Uses `minCashOutReturn` (or auto-calculates 3% slippage tolerance if 0)

   e. Mints V4 position via `_mintPosition()`:
      - Approves tokens via Permit2 (`_approveViaPermit2`)
      - Encodes `MINT_POSITION + SETTLE + SETTLE + SWEEP + SWEEP` actions
      - Calls `POSITION_MANAGER.modifyLiquidities()`

   f. Stores `tokenIdOf[projectId][terminalToken] = newTokenId`

   g. Handles leftovers: burns remaining project tokens, adds remaining terminal tokens to project balance

   h. Clears `accumulatedProjectTokens[projectId] = 0`

4. **State updates**

   - `deployedPoolCount[projectId]++`
   - Emits `ProjectDeployed(projectId, terminalToken, poolId)`

### Result

A Uniswap V4 pool exists with liquidity provided by the hook. The hook owns the position NFT. Future reserved token splits will burn tokens instead of accumulating.

### What to verify

- The pool is initialized at the correct geometric mean price.
- Tick bounds correctly bracket the cashout rate (floor) and issuance rate (ceiling).
- The cashout amount is optimal for the given tick range and price.
- No tokens are lost -- all accumulated tokens end up in the LP position, burned, or returned to the project.
- `tokenIdOf` is set to a valid, non-zero position NFT ID.
- The pool cannot be deployed twice for the same project/token pair.

---

## Journey 4: Collect and Route LP Fees

**Actor:** Anyone (permissionless).
**Goal:** Harvest accrued swap fees from the LP position and route them back to the project (with fee split).

### Precondition

A pool has been deployed (`tokenIdOf[projectId][terminalToken] != 0`). The position has accrued swap fees from trading activity.

### Steps

1. **Caller invokes `collectAndRouteLPFees(projectId, terminalToken)`**

   - Checks: `tokenIdOf != 0`

2. **Fee collection via V4 PositionManager**

   - Records balance snapshots: `bal0Before`, `bal1Before`
   - Calls `POSITION_MANAGER.modifyLiquidities()` with `DECREASE_LIQUIDITY(tokenId, 0, 0, 0) + TAKE_PAIR`
   - The zero-liquidity decrease collects accrued fees without removing any principal
   - Computes `amount0 = bal0After - bal0Before`, `amount1 = bal1After - bal1Before`

3. **Fee routing via `_routeCollectedFees()`**

   - Identifies which amounts correspond to terminal tokens vs project tokens based on currency ordering
   - For terminal token fees, calls `_routeFeesToProject()`:

     a. `feeAmount = amount * FEE_PERCENT / BPS` (e.g., 38% of terminal token fees)

     b. Pays `feeAmount` to `FEE_PROJECT_ID` via `terminal.pay()`, receiving fee project tokens in return

     c. Tracks `claimableFeeTokens[projectId] += feeTokensMinted`

     d. Adds `remainingAmount = amount - feeAmount` to original project balance via `terminal.addToBalanceOf()`

4. **Project token fee burning**

   - Calls `_burnReceivedTokens()` to burn any collected project token fees via `controller.burnTokensOf()`

### Result

LP fees are split: `FEE_PERCENT` goes to the fee project (minting fee project tokens claimable by the original project), the remainder returns to the original project's terminal balance. Collected project token fees are burned.

### What to verify

- Fee amounts are correct for both currency orderings.
- The fee split matches `FEE_PERCENT / BPS` exactly (rounding in favor of original project).
- If `FEE_PERCENT = 0`, all fees go to the original project.
- If the fee project's terminal is `address(0)`, the fee amount stays in the contract (not lost, but not routed).
- The `terminal.pay()` call to the fee project actually mints tokens to `address(this)`.
- `claimableFeeTokens` is incremented by the actual tokens received (delta-based, not the expected amount).
- No reentrancy path through `terminal.pay()` -> pay hook -> back into this contract.

---

## Journey 5: Rebalance Liquidity

**Actor:** Project owner or authorized operator (with `SET_BUYBACK_POOL` permission).
**Goal:** Adjust the LP position's tick range to match current issuance and cashout rates after they have changed (e.g., after a ruleset transition with weight decay).

### Precondition

A pool exists. The project's issuance or cashout rates have changed, making the current tick bounds suboptimal.

### Steps

1. **Caller invokes `rebalanceLiquidity(projectId, terminalToken, decreaseAmount0Min, decreaseAmount1Min)`**

   - Permission check: `SET_BUYBACK_POOL` from project owner
   - Checks: valid terminal, `tokenIdOf != 0`

2. **Step 1: Collect fees (same as Journey 4)**

   - `DECREASE_LIQUIDITY(0) + TAKE_PAIR` to harvest accrued fees
   - Routes fees via `_routeCollectedFees()` and `_routeFeesToProject()`
   - Burns project token fees

3. **Step 2: Burn the existing position**

   - `BURN_POSITION(tokenId, decreaseAmount0Min, decreaseAmount1Min) + TAKE_PAIR`
   - Slippage protection via caller-supplied minimums
   - All position principal is returned to the hook contract

4. **Step 3: Mint new position at updated tick bounds**

   - Reads current project token and terminal token balances
   - Computes new tick bounds from current rates via `_calculateTickBounds()`
   - Reads actual pool price from `POOL_MANAGER.getSlot0()` for liquidity calculation (using the real pool price ensures the position matches the pool's current state, even if it has diverged from the JB issuance price)
   - Calculates liquidity from available amounts
   - If liquidity > 0: mints new position, stores new `tokenIdOf`
   - If liquidity == 0: reverts with `InsufficientLiquidity` (rolls back entire transaction, preserving old position)
   - Handles leftover tokens (burn project tokens, add terminal tokens to project balance)

### Result

The LP position is repositioned to bracket the current issuance and cashout rates. The old position NFT is burned, a new one is minted.

### What to verify

- The entire operation is atomic -- if mint fails, the burn is rolled back.
- Slippage parameters protect against sandwich attacks during the burn step.
- New tick bounds correctly reflect the current rates.
- `tokenIdOf` is updated to the new position NFT ID.
- No tokens are lost during the burn-then-mint cycle.
- The `InsufficientLiquidity` guard prevents bricking (old position survives a revert).

---

## Journey 6: Claim Fee Tokens

**Actor:** Project owner or authorized operator (with `SET_BUYBACK_POOL` permission).
**Goal:** Transfer accumulated fee project tokens to a beneficiary address.

### Precondition

`claimableFeeTokens[projectId] > 0` (fee tokens have been accumulated via previous `collectAndRouteLPFees` or `rebalanceLiquidity` calls).

### Steps

1. **Caller invokes `claimFeeTokensFor(projectId, beneficiary)`**

   - Permission check: `SET_BUYBACK_POOL` from project owner

2. **CEI pattern execution**

   - Reads `claimableAmount = claimableFeeTokens[projectId]`
   - Zeroes `claimableFeeTokens[projectId] = 0` (effects before interactions)
   - If `claimableAmount > 0`: transfers fee project ERC-20 tokens to `beneficiary` via `IERC20.safeTransfer()`
   - Emits `FeeTokensClaimed(projectId, beneficiary, claimableAmount)`

### Result

The beneficiary receives the accumulated fee project tokens. The project's claimable balance is zeroed.

### What to verify

- The CEI pattern prevents reentrancy (balance zeroed before transfer).
- If `claimableAmount == 0`, no transfer occurs and no event is emitted (silent no-op).
- The fee project token address is looked up fresh from `TOKENS.tokenOf(FEE_PROJECT_ID)` -- not cached.
- If the fee project has not deployed an ERC-20 token, `tokenOf` returns `address(0)` and the transfer reverts.
- Tokens are transferred to `beneficiary`, not to `msg.sender`.

---

## Journey 7: Permissionless Pool Deployment After Weight Decay

**Actor:** Anyone (no permission required).
**Goal:** Deploy a pool when the project owner has not acted and the issuance weight has decayed sufficiently.

### Precondition

Tokens have been accumulated. The project's current ruleset weight has decayed to less than 1/10th of `initialWeightOf[projectId]`.

### Steps

1. **Anyone calls `deployPool(projectId, terminalToken, minCashOutReturn)`**

2. **Permission bypass check**

   - Reads `initialWeight = initialWeightOf[projectId]`
   - Reads current `ruleset.weight` from `currentRulesetOf(projectId)`
   - If `initialWeight == 0` (never accumulated): permission required (reverts for non-owner)
   - If `ruleset.weight * 10 > initialWeight`: permission required (weight has not decayed enough)
   - If `ruleset.weight * 10 <= initialWeight`: permission bypassed, anyone can deploy

3. **Proceeds identically to Journey 3 (Steps 2-4)**

### Result

The pool is deployed permissionlessly. This prevents a stale or unresponsive project owner from permanently blocking LP deployment.

### What to verify

- The 10x decay threshold is correct: `weight * 10 <= initialWeight` means the weight is at most 10% of its original value.
- `initialWeightOf` cannot be manipulated by an attacker (it is set only once, by the controller, during the first `processSplitWith`).
- The pool is deployed at the current (decayed) rates, not the initial rates.
- For a project with 80% weight cut per cycle and 1-day duration, the threshold is reached in approximately 3 cycles (3 days). For smaller weight cuts, it takes longer.
- An attacker cannot grief by front-running with a tiny accumulation to set `initialWeightOf` to a very low value (the initial weight is the ruleset weight at first accumulation, not the amount accumulated).
