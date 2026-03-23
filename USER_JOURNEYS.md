# User Journeys -- univ4-lp-split-hook-v6

Concrete end-to-end flows through the LP split hook system. Each journey traces the exact function calls, state changes, and external interactions.

## Journey 1: Deploy an LP Split Hook Clone

**Entry point:** `JBUniswapV4LPSplitHookDeployer.deployHookFor(uint256 feeProjectId, uint256 feePercent, bytes32 salt) external returns (IJBUniswapV4LPSplitHook hook)`

**Who can call:** Anyone. No access control.

**Parameters:**
- `feeProjectId` — The Juicebox project ID that receives a share of LP fees. Must be 0 if `feePercent` is 0; must have a valid controller if non-zero.
- `feePercent` — Percentage of LP fees routed to the fee project, in basis points (e.g., 3800 = 38%). Must be <= 10,000.
- `salt` — Optional salt for deterministic CREATE2 deployment. Pass `bytes32(0)` for a plain CREATE clone.

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

### State changes

1. `hook.initialized` = `true`
2. `hook.FEE_PROJECT_ID` = `feeProjectId`
3. `hook.FEE_PERCENT` = `feePercent`
4. `deployer._nonce` incremented by 1

### Events

- `HookDeployed(uint256 indexed feeProjectId, uint256 feePercent, IJBUniswapV4LPSplitHook hook, address caller)` — emitted by the deployer after initialization

### Edge cases

- `JBUniswapV4LPSplitHook_AlreadyInitialized()` — `initialize()` reverts on second call
- `JBUniswapV4LPSplitHook_InvalidFeePercent()` — `feePercent > 10,000`
- `JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject()` — `feePercent > 0 && feeProjectId == 0`
- `JBUniswapV4LPSplitHook_InvalidProjectId()` — (in `initialize`) `feeProjectId != 0` but `controllerOf(feeProjectId) == address(0)`
- CREATE2 deployment produces a predictable address for frontends; reverts if salt reused with same sender

### Result

A new `JBUniswapV4LPSplitHook` clone is deployed, initialized, and registered. It shares all immutable infrastructure (DIRECTORY, TOKENS, POOL_MANAGER, POSITION_MANAGER, PERMIT2, ORACLE_HOOK) with the implementation.

---

## Journey 2: Accumulate Tokens via Reserved Splits

**Entry point:** `JBUniswapV4LPSplitHook.processSplitWith(JBSplitHookContext calldata context) external payable`

**Who can call:** Only the project's controller (`controllerOf(context.projectId)`). Reverts with `JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal` otherwise.

**Parameters (via `JBSplitHookContext`):**
- `context.split.hook` — Must equal `address(this)`
- `context.projectId` — The Juicebox project ID
- `context.groupId` — Must be `1` (reserved tokens group)
- `context.amount` — The token amount for this split
- `context.token` — The project token address (must be a deployed ERC-20, not `address(0)`)

### Precondition

The project's ruleset has a reserved token split configured with `hook = address(lpSplitHook)`. No pool has been deployed yet (`deployedPoolCount[projectId] == 0`). This hook instance supports only one terminal-token deployment per project because the split context does not include the terminal token.

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
   - Validates that `context.token != address(0)` (requires deployed ERC-20)
   - Defense-in-depth: verifies `IERC20(projectToken).balanceOf(address(this)) >= accumulatedProjectTokens[projectId]`

3. **Repeated over multiple reserved token distributions**

   - Each distribution cycle triggers another `processSplitWith` call
   - `accumulatedProjectTokens` grows with each cycle
   - `initialWeightOf` is only set once (first accumulation)

### State changes

1. `hook.initialWeightOf[projectId]` = `ruleset.weight` (only on first accumulation, when previously 0)
2. `hook.accumulatedProjectTokens[projectId]` += `context.amount`

### Events

None emitted by this function.

### Edge cases

- `JBUniswapV4LPSplitHook_NotHookSpecifiedInContext()` — `context.split.hook != address(this)`
- `JBUniswapV4LPSplitHook_InvalidProjectId()` — (in `processSplitWith`, project validation) `controllerOf(projectId) == address(0)`
- `JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal()` — `msg.sender != controllerOf(projectId)`
- `JBUniswapV4LPSplitHook_TerminalTokensNotAllowed()` — `context.groupId != 1` (prevents terminal token splits from reaching the hook)
- `JBUniswapV4LPSplitHook_InvalidProjectId()` — (in `processSplitWith`, token validation) `context.token == address(0)` (credits cannot be paired as LP)
- `JBUniswapV4LPSplitHook_InsufficientBalance()` — actual ERC-20 balance is less than recorded `accumulatedProjectTokens`
- If `deployedPoolCount > 0` (post-deployment), `processSplitWith` burns received tokens instead of accumulating via `_burnReceivedTokens()`

### Result

The hook holds project tokens in `accumulatedProjectTokens[projectId]`. The tokens are ERC-20 balances on the hook contract. `initialWeightOf[projectId]` records the ruleset weight at the time accumulation began.

---

## Journey 3: Deploy a Uniswap V4 Pool

**Entry point:** `JBUniswapV4LPSplitHook.deployPool(uint256 projectId, address terminalToken, uint256 minCashOutReturn) external`

**Who can call:** Project owner or authorized operator with `SET_BUYBACK_POOL` permission. Alternatively, anyone if `ruleset.weight * 10 <= initialWeightOf[projectId]` (see Journey 7).

**Parameters:**
- `projectId` — The Juicebox project ID
- `terminalToken` — The terminal token address (e.g., ETH or USDC) to pair with the project token
- `minCashOutReturn` — Minimum terminal tokens received from cash-out (slippage protection). Pass `0` for auto-calculated 3% slippage tolerance.

### Precondition

Tokens have been accumulated (`accumulatedProjectTokens[projectId] > 0`). No pool exists for this project and no terminal-token path has been committed yet.

### Steps

1. **Caller invokes `deployPool(projectId, terminalToken, minCashOutReturn)`**

   - Permission check: requires `SET_BUYBACK_POOL` from project owner, unless `ruleset.weight * 10 <= initialWeightOf[projectId]`
   - Checks: `tokenIdOf[projectId][terminalToken] == 0`, `deployedPoolCount[projectId] == 0`, `accumulatedProjectTokens[projectId] > 0`, `primaryTerminalOf(projectId, terminalToken) != address(0)`

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

### State changes

1. `hook.deployedPoolCount[projectId]` incremented by 1 (set before external calls for reentrancy protection)
2. `hook._poolKeys[projectId][terminalToken]` = new `PoolKey`
3. `hook.tokenIdOf[projectId][terminalToken]` = new V4 position NFT token ID
4. `hook.accumulatedProjectTokens[projectId]` = 0

### Events

- `ProjectDeployed(uint256 indexed projectId, address indexed terminalToken, bytes32 indexed poolId)` — emitted after pool and LP position are created
- `TokensBurned(uint256 indexed projectId, address indexed token, uint256 amount)` — emitted for each burn of leftover project tokens (may fire multiple times: once for cash-out leftovers, once for post-mint leftovers)

### Edge cases

- `JBUniswapV4LPSplitHook_PoolAlreadyDeployed()` — `tokenIdOf[projectId][terminalToken] != 0`
- `JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported()` — `deployedPoolCount[projectId] != 0` (a pool already exists for a different terminal token)
- `JBUniswapV4LPSplitHook_NoTokensAccumulated()` — `accumulatedProjectTokens[projectId] == 0`
- `JBUniswapV4LPSplitHook_InvalidTerminalToken()` — `primaryTerminalOf(projectId, terminalToken) == address(0)`
- `JBUniswapV4LPSplitHook_Permit2AmountOverflow()` — token amount exceeds `type(uint160).max` during Permit2 approval
- If the pool was already initialized by another party (e.g., REVDeployer), `initializePool` succeeds harmlessly and the actual pool price is used for LP geometry
- `deployedPoolCount` is incremented before external calls so reentrancy cannot observe the project as still being in accumulation mode

### Result

A Uniswap V4 pool exists with liquidity provided by the hook. The hook owns the position NFT. Future reserved token splits will burn tokens instead of accumulating.

---

## Journey 4: Collect and Route LP Fees

**Entry point:** `JBUniswapV4LPSplitHook.collectAndRouteLPFees(uint256 projectId, address terminalToken) external`

**Who can call:** Anyone. No access control (permissionless).

**Parameters:**
- `projectId` — The Juicebox project ID whose LP fees to collect
- `terminalToken` — The terminal token address of the deployed pool

### Precondition

A pool has been deployed (`tokenIdOf[projectId][terminalToken] != 0`). The position has accrued swap fees from trading activity.

### Steps

1. **Caller invokes `collectAndRouteLPFees(projectId, terminalToken)`**

   - Checks: `tokenIdOf[projectId][terminalToken] != 0`

2. **Fee collection via V4 PositionManager**

   - Records balance snapshots: `bal0Before`, `bal1Before`
   - Calls `POSITION_MANAGER.modifyLiquidities()` with `DECREASE_LIQUIDITY(tokenId, 0, 0, 0) + TAKE_PAIR`
   - The zero-liquidity decrease collects accrued fees without removing any principal
   - Computes `amount0 = bal0After - bal0Before`, `amount1 = bal1After - bal1Before`

3. **Fee routing via `_routeCollectedFees()` and `_routeFeesToProject()`**

   - Identifies which amounts correspond to terminal tokens vs project tokens based on currency ordering
   - For terminal token fees:

     a. `feeAmount = amount * FEE_PERCENT / BPS` (e.g., 38% of terminal token fees)

     b. Pays `feeAmount` to `FEE_PROJECT_ID` via `terminal.pay()`, receiving fee project tokens in return

     c. Tracks `claimableFeeTokens[projectId] += feeTokensMinted` (delta-based measurement)

     d. Adds `remainingAmount = amount - feeAmount` to original project balance via `terminal.addToBalanceOf()`

4. **Project token fee burning**

   - Calls `_burnReceivedTokens()` to burn any collected project token fees via `controller.burnTokensOf()`

### State changes

1. `hook.claimableFeeTokens[projectId]` += fee project tokens minted (only if fee project has a deployed ERC-20)

### Events

- `LPFeesRouted(uint256 indexed projectId, address indexed terminalToken, uint256 totalAmount, uint256 feeAmount, uint256 remainingAmount, uint256 feeTokensMinted)` — emitted for each terminal-token fee routing
- `TokensBurned(uint256 indexed projectId, address indexed token, uint256 amount)` — emitted if project token fees are burned

### Edge cases

- `JBUniswapV4LPSplitHook_InvalidStageForAction()` — `tokenIdOf[projectId][terminalToken] == 0` (no pool deployed)
- If `FEE_PERCENT == 0`, all terminal token fees go to the original project (no fee split)
- If the fee project has no terminal (`primaryTerminalOf(FEE_PROJECT_ID, terminalToken) == address(0)`), the fee amount stays in the contract (stranded, not lost)
- If the fee project has no deployed ERC-20 (`tokenOf(FEE_PROJECT_ID) == address(0)`), the `terminal.pay()` still routes value via credits but `claimableFeeTokens` is not incremented
- Fee routing uses zero slippage (`minReturnedTokens = 0`) by design -- MEV extraction on fee amounts is economically insignificant
- No reentrancy guard; relies on burn-before-route ordering (project tokens burned before `terminal.pay()` can trigger pay hooks)

### Result

LP fees are split: `FEE_PERCENT` goes to the fee project (minting fee project tokens claimable by the original project), the remainder returns to the original project's terminal balance. Collected project token fees are burned.

---

## Journey 5: Rebalance Liquidity

**Entry point:** `JBUniswapV4LPSplitHook.rebalanceLiquidity(uint256 projectId, address terminalToken, uint256 decreaseAmount0Min, uint256 decreaseAmount1Min) external`

**Who can call:** Project owner or authorized operator with `SET_BUYBACK_POOL` permission. No permissionless bypass.

**Parameters:**
- `projectId` — The Juicebox project ID
- `terminalToken` — The terminal token address of the deployed pool
- `decreaseAmount0Min` — Minimum amount of token0 to receive when burning the old position (slippage protection)
- `decreaseAmount1Min` — Minimum amount of token1 to receive when burning the old position (slippage protection)

### Precondition

A pool exists. The project's issuance or cashout rates have changed, making the current tick bounds suboptimal.

### Steps

1. **Caller invokes `rebalanceLiquidity(projectId, terminalToken, decreaseAmount0Min, decreaseAmount1Min)`**

   - Permission check: `SET_BUYBACK_POOL` from project owner
   - Checks: `primaryTerminalOf(projectId, terminalToken) != address(0)`, `tokenIdOf[projectId][terminalToken] != 0`

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

### State changes

1. `hook.tokenIdOf[projectId][terminalToken]` = new V4 position NFT token ID (old position NFT is burned)
2. `hook.claimableFeeTokens[projectId]` += fee project tokens minted during fee collection step

### Events

- `LPFeesRouted(uint256 indexed projectId, address indexed terminalToken, uint256 totalAmount, uint256 feeAmount, uint256 remainingAmount, uint256 feeTokensMinted)` — from the fee collection step
- `TokensBurned(uint256 indexed projectId, address indexed token, uint256 amount)` — emitted for project token fee burns and/or leftover project token burns (may fire multiple times)

### Edge cases

- `JBUniswapV4LPSplitHook_InvalidTerminalToken()` — `primaryTerminalOf(projectId, terminalToken) == address(0)`
- `JBUniswapV4LPSplitHook_InvalidStageForAction()` — `tokenIdOf[projectId][terminalToken] == 0` (no pool deployed)
- `JBUniswapV4LPSplitHook_InsufficientLiquidity()` — new position would have zero liquidity (e.g., price moved entirely outside the new tick range). The entire transaction reverts, preserving the old position.
- The entire operation is atomic -- if mint fails, the burn is rolled back
- Slippage parameters protect against sandwich attacks during the burn step
- `decreaseAmount0Min` / `decreaseAmount1Min` are cast to `uint128` for PositionManager

### Result

The LP position is repositioned to bracket the current issuance and cashout rates. The old position NFT is burned, a new one is minted.

---

## Journey 6: Claim Fee Tokens

**Entry point:** `JBUniswapV4LPSplitHook.claimFeeTokensFor(uint256 projectId, address beneficiary) external`

**Who can call:** Project owner or authorized operator with `SET_BUYBACK_POOL` permission.

**Parameters:**
- `projectId` — The Juicebox project ID whose accumulated fee tokens to claim
- `beneficiary` — The address to receive the fee project tokens

### Precondition

`claimableFeeTokens[projectId] > 0` (fee tokens have been accumulated via previous `collectAndRouteLPFees` or `rebalanceLiquidity` calls).

### Steps

1. **Caller invokes `claimFeeTokensFor(projectId, beneficiary)`**

   - Permission check: `SET_BUYBACK_POOL` from project owner

2. **CEI pattern execution**

   - Reads `claimableAmount = claimableFeeTokens[projectId]`
   - Zeroes `claimableFeeTokens[projectId] = 0` (effects before interactions)
   - If `claimableAmount > 0`: transfers fee project ERC-20 tokens to `beneficiary` via `IERC20.safeTransfer()`

### State changes

1. `hook.claimableFeeTokens[projectId]` = 0

### Events

- `FeeTokensClaimed(uint256 indexed projectId, address indexed beneficiary, uint256 amount)` — emitted only if `claimableAmount > 0`

### Edge cases

- If `claimableAmount == 0`, no transfer occurs and no event is emitted (silent no-op)
- The fee project token address is looked up fresh from `TOKENS.tokenOf(FEE_PROJECT_ID)` -- not cached
- If the fee project has not deployed an ERC-20 token, `tokenOf` returns `address(0)` and the `safeTransfer` reverts
- Tokens are transferred to `beneficiary`, not to `msg.sender`
- The CEI pattern prevents reentrancy (balance zeroed before transfer)

### Result

The beneficiary receives the accumulated fee project tokens. The project's claimable balance is zeroed.

---

## Journey 7: Permissionless Pool Deployment After Weight Decay

**Entry point:** `JBUniswapV4LPSplitHook.deployPool(uint256 projectId, address terminalToken, uint256 minCashOutReturn) external` (same as Journey 3)

**Who can call:** Anyone (no permission required), provided `ruleset.weight * 10 <= initialWeightOf[projectId]`.

**Parameters:**
- `projectId` — The Juicebox project ID
- `terminalToken` — The terminal token address to pair with the project token
- `minCashOutReturn` — Minimum terminal tokens from cash-out (slippage protection, `0` = auto 3% tolerance)

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

### State changes

Same as Journey 3.

### Events

Same as Journey 3:
- `ProjectDeployed(uint256 indexed projectId, address indexed terminalToken, bytes32 indexed poolId)`
- `TokensBurned(uint256 indexed projectId, address indexed token, uint256 amount)` — for leftover project token burns

### Edge cases

- The 10x decay threshold is correct: `weight * 10 <= initialWeight` means the weight is at most 10% of its original value.
- `initialWeightOf` cannot be manipulated by an attacker (it is set only once, by the controller, during the first `processSplitWith`).
- The pool is deployed at the current (decayed) rates, not the initial rates.
- For a project with 80% weight cut per cycle and 1-day duration, the threshold is reached in approximately 3 cycles (3 days). For smaller weight cuts, it takes longer.
- An attacker cannot grief by front-running with a tiny accumulation to set `initialWeightOf` to a very low value (the initial weight is the ruleset weight at first accumulation, not the amount accumulated).

### Result

The pool is deployed permissionlessly. This prevents a stale or unresponsive project owner from permanently blocking LP deployment.
