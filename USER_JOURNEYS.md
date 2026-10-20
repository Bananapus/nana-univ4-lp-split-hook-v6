# User Journeys

## Repo purpose

This repo takes reserved Juicebox token issuance and turns it into managed UniV4 liquidity, held as at most two single-sided positions per project: an ask of project tokens and a bid of terminal tokens. It owns the post-issuance lifecycle of accumulation, first-pool deployment, recycling both positions on every distribution, and fee tracking. It does not own project issuance logic or the lower-level UniV4 routing primitive it depends on.

## Primary actors

- projects that want reserved-token issuance to become managed UniV4 liquidity
- operators deploying the pool and keeping reserved distributions flowing (each one recycles the positions)
- auditors checking range math, fee tracking, and post-deployment lifecycle assumptions

## Key surfaces

- `JBUniswapV4LPSplitHook`: accumulation, deployment, ask/bid recycling, and fee tracking
- `JBUniswapV4LPSplitHookDeployer`: clone and provenance packaging
- `deployPool(...)`: first-pool deployment entrypoint
- `addLiquidity(...)`: permissionless recycle (collect fees, burn the ask and bid, re-mint both around the live spot); the same recycle runs inline on each reserved distribution
- `askTokenIdOf(...)` / `bidTokenIdOf(...)`: the live ask and bid position ids
- `collectAndRouteLPFees(...)`: permissionless fee collection from both positions; `claimFeeTokensFor(...)`: owner/`SET_BUYBACK_POOL`-gated release of tracked fee value

## Journey 1: Accumulate reserved tokens before a pool exists

**Actor:** project operator.

**Intent:** collect reserved issuance into the LP hook before liquidity exists.

**Preconditions**

- the project is issuing reserved tokens
- the split hook is installed as the reserved-token destination

**Main Flow**

1. Install `JBUniswapV4LPSplitHook` as the reserved-token split recipient.
2. Let reserved issuance accumulate during the pre-deployment phase.
3. Treat core issuance as upstream and this repo as the post-issuance destination.

**Failure Modes**

- teams expect this repo to create reserved issuance rather than receive it
- split configuration points reserved tokens somewhere else

**Postconditions**

- reserved issuance accumulates in the LP hook and is ready for later pool deployment

## Journey 2: Deploy the initial UniV4 LP position

**Actor:** anyone (deployment is permissionless).

**Intent:** create the first bounded LP position using project economics.

**Preconditions**

- enough reserved tokens have accumulated
- the terminal token and project-token assumptions are correct
- the caller understands the economic gate (the seed reverts once the pool spot reaches the issuance ceiling)

**Main Flow**

1. Distribute reserved tokens (the hook attempts the deploy inline once `1e15` project tokens have accumulated), or call `deployPool(...)` directly.
2. Note that deployment is permissionless; the seed reverts if the pool spot has already reached the issuance ceiling.
3. The first recycle mints the ask: project tokens from just past the live spot up to the issuance ceiling. There is no bid yet because the hook holds no terminal tokens.
4. Derive tick bounds from issuance and cash-out assumptions rather than arbitrary price intuition (the floor tick is placed at the project's cash-out price).
5. Optionally register the deployed instance in the address registry.

**Failure Modes**

- a second pool is attempted for the same project-token and terminal-token pair
- the terminal token is invalid
- third-party initialization occurs at a price outside the expected band

**Postconditions**

- the pool exists with the project's first ask (`askTokenIdOf`), or deployment is blocked before an invalid pool is created

## Journey 3: Keep the positions recycling after deployment

**Actor:** anyone (reserved distribution and `addLiquidity` are permissionless).

**Intent:** keep the ask and bid centered on the live spot and inside the project's economics.

**Preconditions**

- the pool is deployed
- the pool oracle has 30 minutes of history and the spot is within 200 ticks of the TWAP

**Main Flow**

1. Distribute reserved tokens. The hook accepts them, then attempts a recycle inline if at least 1,000,000 gas (plus a 64,000 reserve) remains.
2. The recycle collects and routes each position's fees, burns both, claims hook-held credits, recomputes the corridor, and re-mints the ask from every project token the hook holds for the project and the bid from every terminal token.
3. Between recycles, buys convert the ask into terminal tokens and sells convert the bid into project tokens; the next recycle moves them back to the side they belong on.
4. If the inline attempt was skipped or emitted `LiquidityAutomationFailed`, call `addLiquidity(projectId, terminalToken)` to run the same recycle.
5. Call `collectAndRouteLPFees(...)` at any time to move fees into the ledgers without recycling.

**Failure Modes**

- oracle not warmed up or spot off the TWAP (`TwapUnavailable`, `PriceDeviationTooHigh`): retry once the price settles
- the spot is past both ends of what the ledgers can fill (`NoDeployableLiquidityAtSpot`): the live positions are kept and the tokens wait in their ledgers
- the corridor is empty (`EmptyCorridor` on a first deploy): the project's cash-out value per token reaches its issuance price, or sits within one tick spacing of it; nothing deploys until at least one aligned spacing opens between them; a recycle with live positions succeeds and retires them
- a distribution with too little gas skips the inline attempt; nothing is lost

**Postconditions**

- the project holds at most one ask and one bid, both single-sided around the live spot, with the ask never below the cash-out floor and the bid never above the issuance ceiling

## Journey 4: Track and claim fee value generated by LP operations

**Actor:** operator or fee beneficiary.

**Intent:** separate tracked fee value from incidental LP state and release it deliberately.

**Preconditions**

- operations have generated tracked fee tokens or credits

**Main Flow**

1. Observe `claimableFeeTokens(...)` and `claimableFeeCredits(...)`.
2. Use `claimFeeTokensFor(...)` when tracked fee value should move to a beneficiary.
3. Treat this state as protocol-relevant accounting, not LP dust.

**Failure Modes**

- operators ignore tracked fee balances and misstate treasury outcomes
- integrations assume all fee value is immediately distributed on a recycle

**Postconditions**

- tracked fee value is observable and can be deliberately claimed to a beneficiary

## Trust boundaries

- this repo trusts core reserved-token issuance and fee-project assumptions
- this repo trusts the UniV4 oracle and pool stack for market-side behavior
- once deployed, the chosen pool path becomes part of the hook's economic identity

## Hand-offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for the reserved-token issuance this hook consumes.
- Use [univ4-router-v6](../univ4-router-v6/USER_JOURNEYS.md) when the question is about swap routing or oracle behavior rather than reserved-token liquidity deployment.
