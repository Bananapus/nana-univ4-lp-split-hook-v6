# Audit Instructions -- univ4-lp-split-hook-v6

You are auditing a Uniswap V4 LP management hook for Juicebox V6 projects. The hook accumulates project tokens received through reserved token splits, then deploys a V4 liquidity position pairing those project tokens with the project's terminal token (ETH, USDC, etc.). After deployment, it collects LP fees and routes them back to the project with a configurable fee split. Read [RISKS.md](./RISKS.md) first -- it documents all known risks, Nemesis audit findings, and trust assumptions. Then come back here.

## Scope

**In scope -- all Solidity in `src/`:**
```
src/JBUniswapV4LPSplitHook.sol        # Core hook (~1,360 lines)
src/JBUniswapV4LPSplitHookDeployer.sol # Clone deployer (~87 lines)
src/interfaces/                        # Interfaces
```

**Out of scope:** Test files, OpenZeppelin/Solady/Uniswap/JB Core dependencies (assume correct), forge-std.

## Architecture

### JBUniswapV4LPSplitHook (Clone)

A clone-based contract deployed via `JBUniswapV4LPSplitHookDeployer`. Each clone has per-instance state (`FEE_PROJECT_ID`, `FEE_PERCENT`) set in `initialize()`, while infrastructure contracts are shared immutables from the implementation (`DIRECTORY`, `TOKENS`, `POOL_MANAGER`, `POSITION_MANAGER`, `PERMIT2`, `ORACLE_HOOK`).

The hook implements `IJBSplitHook` to receive project tokens during reserved token distribution. It also has four external entry points: `deployPool()`, `collectAndRouteLPFees()`, `rebalanceLiquidity()`, and `claimFeeTokensFor()`.

### JBUniswapV4LPSplitHookDeployer

Deploys clones of the implementation using Solady's `LibClone`. Supports deterministic CREATE2 deployment with caller-scoped salt. Registers each clone in `IJBAddressRegistry`.

### V4 Integration

All pools are created with:
- `POOL_FEE = 10_000` (1% fee tier)
- `TICK_SPACING = 200`
- `hooks = ORACLE_HOOK` (the JBUniswapV4Hook oracle, shared across all JB V4 pools)

LP positions are managed through Uniswap V4 `PositionManager`. Token approvals go through Permit2. The hook owns the position NFT and manages a single position per project/terminal-token pair.

## State Lifecycle

```
initialize()          Accumulation Stage                  Pool Deployed
     |                      |                                  |
     v                      v                                  v
  [Clone created]    processSplitWith()              deployPool()
  FEE_PROJECT_ID     -> accumulateTokens             -> _createAndInitializePool
  FEE_PERCENT        -> tracks initialWeightOf       -> _addUniswapLiquidity
                                                        (cashout portion for pairing)
                                                     -> tokenIdOf[project][token] = NFT ID
                                                     -> projectDeployed = true
                                                     -> deployedPoolCount++

                     Post-Deployment (all permissionless except rebalance/claim):
                     |--> processSplitWith()         -> burns received tokens
                     |--> collectAndRouteLPFees()    -> collect fees, route to projects
                     |--> rebalanceLiquidity()       -> burn position, remint at new ticks
                     |--> claimFeeTokensFor()        -> transfer fee project tokens to beneficiary
```

## Key Flows

### 1. Accumulation (pre-pool)

`processSplitWith(context)` -- called by JB controller during reserved token distribution.

- Validates `msg.sender == controllerOf(projectId)` and `context.groupId == 1` (reserved tokens only, not payout splits)
- If `deployedPoolCount[projectId] == 0`: accumulates tokens in `accumulatedProjectTokens[projectId]`, records `initialWeightOf` on first call
- If `deployedPoolCount[projectId] > 0`: burns all project tokens held by the contract via `controller.burnTokensOf()`

### 2. Pool Deployment

`deployPool(projectId, terminalToken, minCashOutReturn)` -- permission-gated or permissionless after 10x weight decay.

- Permission check: requires `SET_BUYBACK_POOL` unless `ruleset.weight * 10 <= initialWeightOf[projectId]`
- Checks: `tokenIdOf == 0` (not already deployed), `accumulatedProjectTokens > 0`, valid terminal
- `_createAndInitializePool()`: builds `PoolKey` with sorted currencies, `POOL_FEE`, `TICK_SPACING`, `ORACLE_HOOK`. Initializes pool at geometric mean of cashout rate and issuance rate.
- `_addUniswapLiquidity()`:
  1. Computes tick bounds from cashout rate (floor) and issuance rate (ceiling) via `_calculateTickBounds()`
  2. Reads actual pool price from slot0 (pool may have been initialized by REVDeployer)
  3. Computes optimal cashout amount via `_computeOptimalCashOutAmount()` -- determines how many project tokens to cash out for terminal tokens to balance the LP position
  4. Calls `terminal.cashOutTokensOf()` to get terminal tokens
  5. Mints V4 position via `_mintPosition()` using Permit2 approvals
  6. Stores `tokenIdOf`, clears `accumulatedProjectTokens`
  7. Burns leftover project tokens, adds leftover terminal tokens to project balance

### 3. Fee Collection and Routing

`collectAndRouteLPFees(projectId, terminalToken)` -- permissionless.

- Calls `POSITION_MANAGER.modifyLiquidities()` with `DECREASE_LIQUIDITY(0) + TAKE_PAIR` to collect accrued swap fees
- Tracks balance deltas (before/after) to determine collected amounts
- `_routeCollectedFees()` identifies which amounts are terminal tokens vs project tokens
- `_routeFeesToProject()`:
  - Computes `feeAmount = amount * FEE_PERCENT / BPS`
  - Pays `feeAmount` to `FEE_PROJECT_ID` via `terminal.pay()` (minting fee project tokens to `address(this)`)
  - Tracks minted fee tokens in `claimableFeeTokens[projectId]`
  - Adds `remainingAmount` to original project balance via `terminal.addToBalanceOf()`
- Burns collected project token fees via `controller.burnTokensOf()`

### 4. Rebalance

`rebalanceLiquidity(projectId, terminalToken, decreaseAmount0Min, decreaseAmount1Min)` -- requires `SET_BUYBACK_POOL`.

Three-step atomic operation:
1. Collect accrued fees (same as `collectAndRouteLPFees`)
2. Burn the existing position via `BURN_POSITION + TAKE_PAIR` (with slippage params)
3. Mint new position at updated tick bounds from current issuance/cashout rates

Reverts with `InsufficientLiquidity` if new position would have zero liquidity (protects against bricking).

### 5. Fee Token Claims

`claimFeeTokensFor(projectId, beneficiary)` -- requires `SET_BUYBACK_POOL`.

- Reads and zeroes `claimableFeeTokens[projectId]` before transfer (CEI pattern)
- Transfers fee project ERC-20 tokens to beneficiary

## Key Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `BPS` | 10,000 | Basis points denominator |
| `POOL_FEE` | 10,000 | 1% V4 pool fee tier |
| `TICK_SPACING` | 200 | Tick spacing for 1% tier |
| `_CASH_OUT_SLIPPAGE_NUMERATOR / DENOMINATOR` | 97/100 | 3% default slippage tolerance on cashout |
| `_DEADLINE_SECONDS` | 60 | PositionManager/Permit2 deadline window |
| `_Q96` | 2^96 | V4 sqrtPriceX96 scale factor |
| `_WAD` | 1e18 | Unit amount for rate calculations |

Configurable per clone:
| Parameter | Typical Value | Meaning |
|-----------|---------------|---------|
| `FEE_PERCENT` | 3,800 | 38% of LP fees to fee project |
| `FEE_PROJECT_ID` | (varies) | Project ID receiving fee share |

## Priority Audit Areas

### 1. No Reentrancy Guard (Highest Priority)

The contract makes multiple external calls without any `ReentrancyGuard`:
- `deployPool`: calls `terminal.cashOutTokensOf()`, `POSITION_MANAGER.modifyLiquidities()`, `terminal.addToBalanceOf()`, `controller.burnTokensOf()`
- `collectAndRouteLPFees`: calls `POSITION_MANAGER.modifyLiquidities()`, `terminal.pay()`, `terminal.addToBalanceOf()`, `controller.burnTokensOf()`
- `rebalanceLiquidity`: all of the above plus `BURN_POSITION` and re-`MINT_POSITION`
- `claimFeeTokensFor`: calls `IERC20.safeTransfer()`

Verify that state ordering prevents all reentrancy paths. Pay special attention to:
- Can `terminal.pay()` (in fee routing) re-enter through a pay hook that calls back into this contract?
- Can `terminal.cashOutTokensOf()` trigger a cashout hook that re-enters?
- Can `POSITION_MANAGER.modifyLiquidities()` trigger callbacks that re-enter?

### 2. MEV on Rebalance

`rebalanceLiquidity` burns the entire position and remints in a single transaction. Between burn and mint, the contract holds raw token balances. Verify:
- Are slippage parameters (`decreaseAmount0Min`, `decreaseAmount1Min`) sufficient to prevent sandwich attacks?
- Can the `InsufficientLiquidity` revert be triggered intentionally by an attacker (DoS via price manipulation)?
- Is there a gap where an attacker can extract value between BURN and MINT?

### 3. Fee Routing Correctness

- Verify `_routeFeesToProject()` correctly identifies terminal token amounts vs project token amounts in all currency orderings (projectToken as token0 vs token1)
- Verify fee routing with `FEE_PERCENT = 0` (no fee project) and `FEE_PERCENT = BPS` (100% to fee project)
- What happens if `terminal.pay()` to the fee project reverts? The fee amount is computed but never sent. Where does it go?
- Can `claimableFeeTokens` be inflated if the fee project's terminal mints tokens to this contract through a separate path?

### 4. Cashout Amount Computation

`_computeOptimalCashOutAmount()` determines how many project tokens to cash out to pair with terminal tokens for the LP position.
- Verify the math for all token orderings (terminal as token0 vs token1)
- Verify edge cases: `sqrtPriceInit <= sqrtPriceA` (returns totalProjectTokens / 2), `sqrtPriceInit >= sqrtPriceB` (returns 0)
- Can the cashout amount exceed what the terminal will actually return (causing the LP mint to fail)?
- Is the 50% cap (`maxCashOut = totalProjectTokens / 2`) sufficient?

### 5. Clone Initialization

- The implementation contract can be initialized by anyone (NM-004, acknowledged). Verify this truly has no impact.
- After `initialize()`, `FEE_PROJECT_ID` and `FEE_PERCENT` are immutable. Verify there is no path to re-initialize.
- What happens if `initialize()` is called with `feePercent = 0` and `feeProjectId = 0`? All fees go to the original project.

### 6. Permissionless Pool Deployment

After 10x weight decay (`ruleset.weight * 10 <= initialWeightOf`), anyone can call `deployPool()`. Verify:
- Can an attacker manipulate `initialWeightOf` (set on first accumulation)?
- Can an attacker trigger pool deployment at a manipulated price by timing it with a surplus change?
- Is the 10x threshold appropriate? (For 80% weight cut per cycle, this is ~3 cycles.)

### 7. Leftover Token Handling

`_handleLeftoverTokens()` burns leftover project tokens and adds leftover terminal tokens to project balance. Verify:
- Can leftover handling be exploited to extract value?
- What if `controller.burnTokensOf()` reverts? (Would prevent the entire operation from completing.)
- What if `terminal.addToBalanceOf()` reverts? (Terminal tokens would be stuck in the contract.)

## Invariants to Verify

1. **Token conservation**: After `deployPool()`, all accumulated project tokens are either in the LP position, burned, or returned to the project balance. None are lost.
2. **Fee split correctness**: `feeAmount + remainingAmount == totalFees` for every fee routing operation.
3. **Position integrity**: `tokenIdOf[projectId][terminalToken] != 0` if and only if an active LP position exists for that pair.
4. **One pool per pair**: `deployPool()` reverts if `tokenIdOf != 0`. No duplicate positions.
5. **Fee token accounting**: `claimableFeeTokens[projectId]` accurately reflects the fee project tokens held by the contract for that project.
6. **Accumulation isolation**: `accumulatedProjectTokens[projectA]` is never affected by operations on project B.

## Testing Setup

```bash
cd univ4-lp-split-hook-v6
npm install
forge build
forge test

# Run specific test suites
forge test --match-contract SecurityTest -vvv
forge test --match-contract FeeRoutingTest -vvv
forge test --match-contract RebalanceTest -vvv
forge test --match-contract IntegrationLifecycle -vvv

# Run fork tests (requires RPC)
forge test --match-contract Fork -vvv

# Write a PoC
forge test --match-path test/audit/ExploitPoC.t.sol -vvv
```

Test base: `TestBaseV4.sol` provides a complete mock environment with V4 PoolManager, PositionManager, JB Core contracts, and helper functions.

Go break it.
