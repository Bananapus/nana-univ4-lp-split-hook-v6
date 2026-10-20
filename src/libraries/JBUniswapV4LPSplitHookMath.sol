// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBSurplus} from "@bananapus/core-v6/src/libraries/JBSurplus.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {mulDiv, sqrt} from "@prb/math/src/Common.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {JBLPSplitHookHelpers} from "./JBLPSplitHookHelpers.sol";

/// @notice Pricing and tick-range math for `JBUniswapV4LPSplitHook`, factored into a linked library so the heavy
/// Juicebox-price → Uniswap-tick computation lives outside the hook's runtime bytecode (keeping the hook under the
/// EIP-170 24,576-byte limit). Every function here is a pure/view computation that depends only on the project's
/// `controller`/`ruleset` plus the `directory` and `suckerRegistry` the hook passes in from its own immutables — none
/// of them read hook storage or `address(this)`, so they behave identically whether inlined or delegatecall-linked.
/// @dev Mirrors the `JBSuckerLib` precedent in nana-suckers-v6: `public` functions are deployed once and
/// delegatecall-linked, so Sphinx deploys this deterministically and the hook's CREATE2 address stays chain-same.
library JBUniswapV4LPSplitHookMath {
    using JBRulesetMetadataResolver for JBRuleset;
    using PoolIdLibrary for PoolKey;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the computed LP tick range collapses to an empty or inverted band.
    /// @notice Thrown when no terminal token with a non-zero balance is found across a project's terminals.
    error JBUniswapV4LPSplitHookMath_NoTerminalTokenFound(uint256 projectId);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Uniswap V4 Q96 fixed-point scale factor for sqrtPriceX96 values.
    uint256 internal constant _Q96 = 2 ** 96;

    /// @notice Tick spacing for the 1% fee tier (200 ticks). Mirrors `JBUniswapV4LPSplitHook.TICK_SPACING`.
    int24 internal constant _TICK_SPACING = 200;

    /// @notice 1e18 scale factor used as a unit amount in rate calculations.
    uint256 internal constant _WAD = 10 ** 18;

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The liquidity a single-sided mint over `[tickLower, tickUpper]` supports, funded by `amount0` (or by
    /// `amount1` when `amount0` is zero), capped at the pool's remaining per-tick capacity at both bounds.
    /// @dev A range that sits entirely on one side of the spot holds only one token: a range above the spot is all
    /// token0 (the price has not risen into it yet) and a range below the spot is all token1 (the price has already
    /// passed through it). The hook only mints such ranges, so the caller passes the one funding token and zero for
    /// the other. Liquidity `L` relates to the amount held across `[sqrtLower, sqrtUpper]` as:
    ///
    /// - token0 only: `amount0 = L * (sqrtUpper - sqrtLower) * 2^96 / (sqrtLower * sqrtUpper)`, so
    /// `L = amount0 * (sqrtLower * sqrtUpper / 2^96) / (sqrtUpper - sqrtLower)`.
    /// - token1 only: `amount1 = L * (sqrtUpper - sqrtLower) / 2^96`, so
    /// `L = amount1 * 2^96 / (sqrtUpper - sqrtLower)`.
    ///
    /// These are `LiquidityAmounts.getLiquidityForAmount0/1`, rounded down so the mint never needs more than the
    /// amount supplied, but computed in 256 bits and capped instead of reverting.
    ///
    /// The cap: Uniswap tracks, at every initialized tick, the total liquidity of all positions that use it as a bound
    /// (`liquidityGross`), and reverts a mint (`TickLiquidityOverflow`) that would push it past
    /// `Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing)`. A mint adds `L` to `liquidityGross` at BOTH its lower and
    /// its upper tick, so both are read, and the fuller of the two (the one with less room left) sets how much this
    /// mint can add. An amount the range cannot hold mints only what fits; the unminted tokens are never pulled, and
    /// the caller's `_carryLeftovers` balance delta returns them to the project's ledgers for a later recycle.
    /// @param poolManager The Uniswap V4 PoolManager holding the pool.
    /// @param key The pool key.
    /// @param tickLower The lower tick of the range.
    /// @param tickUpper The upper tick of the range.
    /// @param amount0 The token0 amount (single-sided above the spot), or zero.
    /// @param amount1 The token1 amount (single-sided below the spot), used when `amount0` is zero.
    /// @return liquidity The liquidity to mint.
    function cappedSingleSidedLiquidity(
        IPoolManager poolManager,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    )
        public
        view
        returns (uint128 liquidity)
    {
        uint256 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint256 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // The liquidity the funding amount would buy with no cap: the token0 formula when token0 funds the range (it
        // sits above the spot), otherwise the token1 formula (it sits below). Both round down.
        uint256 wanted = amount0 != 0
            ? mulDiv(amount0, mulDiv(sqrtLower, sqrtUpper, 1 << 96), sqrtUpper - sqrtLower)
            : mulDiv(amount1, 1 << 96, sqrtUpper - sqrtLower);

        // The liquidity already referencing each bound from other positions (including the hook's own other leg when
        // the ask and bid share a bound), read straight from the PoolManager's tick state.
        PoolId poolId = key.toId();
        (uint128 grossLower,) = StateLibrary.getTickLiquidity({manager: poolManager, poolId: poolId, tick: tickLower});
        (uint128 grossUpper,) = StateLibrary.getTickLiquidity({manager: poolManager, poolId: poolId, tick: tickUpper});
        // Both bounds gain `L`, so the fuller bound is the binding one: its remaining room is the most this mint can
        // add without reverting. A bound already at (or over) the cap leaves no room, and the mint is skipped.
        uint256 used = grossLower > grossUpper ? grossLower : grossUpper;
        uint256 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(key.tickSpacing);
        uint256 room = maxPerTick > used ? maxPerTick - used : 0;

        // Mint what fits. Bounded by `room`, which is at most the uint128 per-tick cap, so the cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        liquidity = uint128(wanted < room ? wanted : room);
    }

    /// @notice Calculate tick bounds for liquidity position based on issuance and cash out rates.
    /// @dev The corridor is the range of pool prices at which the hook is willing to trade: never selling project
    /// tokens for less than a holder could cash one out for (the cash-out FLOOR), and never buying them for more than
    /// the project mints one for (the issuance CEILING). Outside it, anyone could buy from the ask and cash out, or pay
    /// the project and sell into the bid, at the project's expense.
    ///
    /// Uniswap prices are `token1 / token0`, so the project price rises with the pool price when the project is token0
    /// (floor = lower tick, ceiling = upper tick) and falls with it when the project is token1 (floor = upper tick,
    /// ceiling = lower tick). Both bounds are aligned to the 200-tick spacing and rounded INWARD, so the aligned range
    /// never reaches past either economic price. The result is a sorted `(lower, upper)` pair either way, and `(0, 0)`
    /// means empty.
    ///
    /// Three cases:
    ///
    /// - A positive cash-out preview: the corridor between the two prices (`_corridorBetween`).
    /// - A preview that rounds to 0 with issuance on: a corridor that ends exactly at the issuance tick
    /// (`_zeroCashOutCorridor`), then lifted to the cash-out bound.
    /// - A preview of 0 with no issuance (zero weight or 100% reserved): no ceiling, so the full usable tick range,
    /// then lifted to the cash-out bound.
    /// @param directory The JBDirectory used to resolve the project's primary terminal.
    /// @param suckerRegistry The sucker registry for cross-chain surplus/supply queries.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return tickLower The lower tick bound of the LP position.
    /// @return tickUpper The upper tick bound of the LP position. Equal to `tickLower` (an empty corridor) when the
    /// cash-out value per token reaches the issuance price, or no aligned spacing fits between them.
    function calculateTickBounds(
        IJBDirectory directory,
        IJBSuckerRegistry suckerRegistry,
        uint256 projectId,
        address terminalToken,
        address projectToken,
        address controller,
        JBRuleset memory ruleset
    )
        public
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        // Uniswap orders the pair by address; the ordering decides which tick is the floor and which the ceiling.
        (address token0,) = JBLPSplitHookHelpers.sortTokens({tokenA: terminalToken, tokenB: projectToken});
        bool projectIsToken0 = projectToken == token0;

        // The preview may round to 0 with low-decimal tokens like USDC and a large supply, so a 0 only picks the
        // geometry below; the floor itself always comes from the rate's upper bound.
        uint256 cashOutRate = getCashOutRate({
            directory: directory,
            suckerRegistry: suckerRegistry,
            projectId: projectId,
            terminalToken: terminalToken,
            controller: controller,
            ruleset: ruleset
        });
        uint160 cashOutSqrtPrice = _cashOutBoundSqrtPrice({rate: cashOutRate, projectIsToken0: projectIsToken0});

        // Issuance is structurally zero only with zero weight or a 100% reserved rate; any other weight gets a ceiling
        // bounded from above rather than being read as zero.
        bool noIssuance = ruleset.weight == 0
            || JBRulesetMetadataResolver.reservedPercent(ruleset) == JBConstants.MAX_RESERVED_PERCENT;

        if (cashOutRate == 0) {
            if (noIssuance) {
                // No ceiling and a negligible floor: full range, so liquidity tracks the prevailing market.
                tickLower = JBLPSplitHookHelpers.alignTickToSpacing({tick: TickMath.MIN_TICK, spacing: _TICK_SPACING})
                    + _TICK_SPACING;
                tickUpper = JBLPSplitHookHelpers.alignTickToSpacing({tick: TickMath.MAX_TICK, spacing: _TICK_SPACING})
                    - _TICK_SPACING;
            } else {
                (tickLower, tickUpper) = _zeroCashOutCorridor({
                    ceilingSqrtPrice: getIssuanceRateSqrtPriceX96({
                        directory: directory,
                        projectId: projectId,
                        terminalToken: terminalToken,
                        projectToken: projectToken,
                        controller: controller,
                        ruleset: ruleset
                    }),
                    projectIsToken0: projectIsToken0
                });
            }

            // Neither geometry may reach below the cash-out bound. `_cashOutBoundSqrtPrice` never returns 0, so even
            // a preview that rounded to 0 leaves a real (if tiny) floor: round it inward (up for a token0 project's
            // lower bound, down for a token1 project's upper bound) and pull the corridor's floor side in to it.
            if (projectIsToken0) {
                int24 floorTick = JBLPSplitHookHelpers.alignTickToSpacingCeil({
                    tick: _tickAtOrAbove(cashOutSqrtPrice), spacing: _TICK_SPACING
                });
                if (floorTick > tickLower) tickLower = floorTick;
            } else {
                int24 floorTick = JBLPSplitHookHelpers.alignTickToSpacing({
                    tick: TickMath.getTickAtSqrtPrice(cashOutSqrtPrice), spacing: _TICK_SPACING
                });
                if (floorTick < tickUpper) tickUpper = floorTick;
            }
            // Lifting the floor can close the corridor entirely: report it empty rather than inverted.
            if (tickLower >= tickUpper) return (0, 0);
            return (tickLower, tickUpper);
        }

        // The normal case: a positive floor and an issuance ceiling.
        return _corridorBetween({
            cashOutSqrtPrice: cashOutSqrtPrice,
            issuanceSqrtPrice: getIssuanceRateSqrtPriceX96({
                directory: directory,
                projectId: projectId,
                terminalToken: terminalToken,
                projectToken: projectToken,
                controller: controller,
                ruleset: ruleset
            }),
            projectIsToken0: projectIsToken0
        });
    }

    /// @notice The corridor when the cash-out preview rounds to 0: the issuance ceiling plus a two-spacing floor gap.
    /// @dev The ceiling-side bound lands EXACTLY on the aligned issuance tick, as in the normal path, so the ask leg is
    /// offered only strictly below the issuance price. The floor side sits two spacings away (not one) so a spot
    /// strictly below the ceiling can still align an ask leg one spacing deep, keeping a pre-initialized pool below
    /// the issuance price deployable. The caller then lifts the floor to the cash-out bound.
    /// @param ceilingSqrtPrice The issuance price as a pool sqrtPriceX96.
    /// @param projectIsToken0 Whether the project token is the pool's currency0.
    /// @return tickLower The lower tick bound.
    /// @return tickUpper The upper tick bound.
    function _zeroCashOutCorridor(
        uint160 ceilingSqrtPrice,
        bool projectIsToken0
    )
        private
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        // The lowest and highest ticks a position may use: one spacing inside the aligned ends of Uniswap's tick range,
        // so a bound is never the extreme tick itself.
        int24 floorGap = 2 * _TICK_SPACING;
        int24 minUsable =
            JBLPSplitHookHelpers.alignTickToSpacing({tick: TickMath.MIN_TICK, spacing: _TICK_SPACING}) + _TICK_SPACING;
        int24 maxUsable =
            JBLPSplitHookHelpers.alignTickToSpacing({tick: TickMath.MAX_TICK, spacing: _TICK_SPACING}) - _TICK_SPACING;

        if (projectIsToken0) {
            // The issuance ceiling is the corridor UPPER bound: align it down.
            tickUpper = JBLPSplitHookHelpers.alignTickToSpacing({
                tick: TickMath.getTickAtSqrtPrice(ceilingSqrtPrice), spacing: _TICK_SPACING
            });
            // Keep the ceiling usable and leave room for the two-spacing gap below it.
            if (tickUpper > maxUsable) tickUpper = maxUsable;
            if (tickUpper < minUsable + floorGap) tickUpper = minUsable + floorGap;
            tickLower = tickUpper - floorGap;
        } else {
            // The issuance ceiling is the corridor LOWER bound: round it up against its exact price.
            tickLower = JBLPSplitHookHelpers.alignTickToSpacingCeil({
                tick: _tickAtOrAbove(ceilingSqrtPrice), spacing: _TICK_SPACING
            });
            // Leave room for the two-spacing gap above the ceiling.
            if (tickLower > maxUsable - floorGap) tickLower = maxUsable - floorGap;
            tickUpper = tickLower + floorGap;
        }
    }

    /// @notice Encode an upper bound on the per-token cash-out value as a pool sqrtPriceX96.
    /// @dev The preview of a 1-token cash-out truncates up to twice (the proportional share, then the tax curve), so
    /// what any burn of at most 1 token realizes per token is below `rate + 2`. Larger burns under a tax return more
    /// per token by design of the curve. The bound is never 0, so even a preview that rounds to 0 keeps a floor.
    /// @param rate The cash-out preview: terminal tokens per 1e18 project tokens.
    /// @param projectIsToken0 Whether the project token is the pool's currency0.
    /// @return sqrtPriceX96 The floor, rounded toward a HIGHER project price: up when the project is token0 (pool
    /// price = terminal per project), down when it is token1 (pool price = project per terminal).
    function _cashOutBoundSqrtPrice(uint256 rate, bool projectIsToken0) private pure returns (uint160 sqrtPriceX96) {
        // `rate + 2` covers both truncations; saturate rather than overflow on an absurd rate.
        uint256 bound = rate > type(uint256).max - 2 ? type(uint256).max : rate + 2;
        // Token0 project: pool price is terminal per project, `bound / 1e18`. Token1 project: pool price is project per
        // terminal, `1e18 / bound`. Each rounds the way that raises the project price, keeping the floor conservative.
        return projectIsToken0
            ? _toSqrtPriceX96({amount1: bound, amount0: _WAD, roundUp: true})
            : _toSqrtPriceX96({amount1: _WAD, amount0: bound, roundUp: false});
    }

    /// @notice The aligned corridor between the cash-out and issuance prices, or an empty one when there is none.
    /// @dev The two prices are sorted into a lower and an upper sqrt price, and each is snapped to the 200-tick grid
    /// toward the other one, so the aligned range sits inside the exact economic range. The corridor is empty,
    /// `(0, 0)`, when the floor is not strictly cheaper than the ceiling, or when the inward rounding leaves no full
    /// spacing between the bounds.
    /// @param cashOutSqrtPrice The cash-out value per token as a pool sqrtPriceX96.
    /// @param issuanceSqrtPrice The issuance price as a pool sqrtPriceX96.
    /// @param projectIsToken0 Whether the project token is the pool's currency0.
    /// @return tickLower The lower tick bound.
    /// @return tickUpper The upper tick bound, equal to `tickLower` when the corridor is empty.
    function _corridorBetween(
        uint160 cashOutSqrtPrice,
        uint160 issuanceSqrtPrice,
        bool projectIsToken0
    )
        private
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        // The cash-out floor must sit on the cheap side of the issuance ceiling: below it in project price. Project
        // price rises with the pool price when the project is token0 and falls with it when the project is token1.
        // Compared on exact sqrt prices, since tick rounding hides inversions smaller than one tick.
        if (projectIsToken0 ? cashOutSqrtPrice >= issuanceSqrtPrice : cashOutSqrtPrice <= issuanceSqrtPrice) {
            return (0, 0);
        }

        // Round both bounds INWARD against their exact prices: the lower bound to the first aligned tick at or above
        // its price, the upper bound to the last aligned tick at or below it, so the range never reaches past either.
        (uint160 sqrtLower, uint160 sqrtUpper) = cashOutSqrtPrice < issuanceSqrtPrice
            ? (cashOutSqrtPrice, issuanceSqrtPrice)
            : (issuanceSqrtPrice, cashOutSqrtPrice);
        tickLower =
            JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: _tickAtOrAbove(sqrtLower), spacing: _TICK_SPACING});
        tickUpper = JBLPSplitHookHelpers.alignTickToSpacing({
            tick: TickMath.getTickAtSqrtPrice(sqrtUpper), spacing: _TICK_SPACING
        });

        // Clamp the upper bound to the usable V4 range. The ceil-aligned lower bound of any tick at or above MIN_TICK
        // is already at or above the lowest usable tick, so it needs no clamp.
        int24 maxUsable =
            JBLPSplitHookHelpers.alignTickToSpacing({tick: TickMath.MAX_TICK, spacing: _TICK_SPACING}) - _TICK_SPACING;
        if (tickUpper > maxUsable) tickUpper = maxUsable;

        // When no aligned spacing fits between the bounds, no price respects both: return the corridor empty.
        if (tickLower >= tickUpper) return (0, 0);
    }

    /// @notice The lowest tick whose price is at or above `sqrtPriceX96`.
    /// @param sqrtPriceX96 The exact price to round up to a tick.
    /// @return tick `getTickAtSqrtPrice` rounded up when that tick sits strictly below the price.
    function _tickAtOrAbove(uint160 sqrtPriceX96) private pure returns (int24 tick) {
        // `getTickAtSqrtPrice` rounds DOWN (the greatest tick whose price is at or below the input). A lower bound must
        // not sit below its price, so step up one tick when the input falls strictly between two ticks.
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (TickMath.getSqrtPriceAtTick(tick) < sqrtPriceX96) tick++;
    }

    /// @notice Compute the initial sqrtPriceX96 for pool initialization.
    /// @param directory The JBDirectory used to resolve the project's primary terminal.
    /// @param suckerRegistry The sucker registry for cross-chain surplus/supply queries.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return sqrtPriceX96 The cash-out (floor) price as sqrtPriceX96 (the issuance/ceiling price when there is no
    /// surplus and thus no floor), or 0 when the corridor is empty.
    function computeInitialSqrtPrice(
        IJBDirectory directory,
        IJBSuckerRegistry suckerRegistry,
        uint256 projectId,
        address terminalToken,
        address projectToken,
        address controller,
        JBRuleset memory ruleset
    )
        public
        view
        returns (uint160 sqrtPriceX96)
    {
        // Seed a hook-initialized pool just inside the cash-out (floor) bound of the economic corridor so nearly the
        // entire project balance deploys as asks across the [floor, ceiling] corridor rather than wasting the
        // [floor, midpoint] band. The seed sits ONE spacing inside the floor rather than exactly on it: the exact
        // economic boundary is the same extreme the pre-init guard treats as manipulation, so keeping the seed
        // strictly within the band stays consistent with that invariant. This uses the same corridor as every other
        // path, so a zero-cash-out project (whose corridor pins its ceiling on the exact issuance tick) still seeds
        // STRICTLY below that ceiling and deploys, rather than seeding at the issuance price and rejecting its own
        // pool. Ordering-aware: the floor bound is the corridor's LOWER tick when the project is token0 and its UPPER
        // tick when it is token1 (the ask leg always fills from the floor toward the issuance ceiling).
        (int24 tickLower, int24 tickUpper) = calculateTickBounds({
            directory: directory,
            suckerRegistry: suckerRegistry,
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });
        // An empty corridor has no price to seed.
        if (tickLower == tickUpper) return 0;
        (address token0,) = JBLPSplitHookHelpers.sortTokens({tokenA: terminalToken, tokenB: projectToken});
        // Offset one spacing off the floor bound toward the ceiling, then clamp so the seed stays at least one spacing
        // short of the ceiling. Both bounds are spacing-aligned, so the seed is too — never landing on an unaligned
        // tick that would collapse the asks-only adaptive range. For a one-spacing corridor the clamp folds the seed
        // back
        // onto the floor bound itself (spot == floor), leaving a non-degenerate one-spacing ask leg to the ceiling.
        int24 seedTick;
        if (projectToken == token0) {
            seedTick = tickLower + _TICK_SPACING;
            if (seedTick > tickUpper - _TICK_SPACING) seedTick = tickUpper - _TICK_SPACING;
        } else {
            seedTick = tickUpper - _TICK_SPACING;
            if (seedTick < tickLower + _TICK_SPACING) seedTick = tickLower + _TICK_SPACING;
        }
        return TickMath.getSqrtPriceAtTick(seedTick);
    }

    /// @notice Find the primary terminal token with the highest ETH-denominated value across the project's terminals.
    /// @dev Converts each token's balance to 18-decimal ETH using price feeds. Falls back to token-decimal-normalized
    /// balance comparison when no price feed exists.
    /// @param directory The JBDirectory used to resolve the project's terminals and primary terminals.
    /// @param projectId The ID of the project.
    /// @param controller The project's controller address.
    /// @return highestToken The token address with the highest ETH-denominated balance.
    function findHighestValueTerminalTokenOf(
        IJBDirectory directory,
        uint256 projectId,
        address controller
    )
        public
        view
        returns (address highestToken)
    {
        // Fetch all terminals registered for this project.
        IJBTerminal[] memory terminals = directory.terminalsOf(projectId);

        // Track the highest ETH-denominated value found so far.
        uint256 highestValue = 0;

        // Fallback tracking for tokens without a price feed.
        address highestUnpricedToken = address(0);
        uint256 highestUnpricedBalance = 0;

        // The ETH currency identifier used for price normalization.
        // JB currency ids are a token address's low 32 bits by convention (ETH = 61166).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 ethCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));

        // Cache terminal count for gas-efficient iteration.
        uint256 terminalCount = terminals.length;

        // Iterate over each terminal to inspect its token balances.
        for (uint256 i; i < terminalCount; i++) {
            // Cast to IJBMultiTerminal to access store and accounting context methods.
            IJBMultiTerminal term = IJBMultiTerminal(address(terminals[i]));

            // A project's terminal set can include non-`IJBMultiTerminal` terminals that hold no balances of their
            // own (e.g. the router terminal registry, which forwards to per-token terminals and has no `STORE()`).
            // Probe `STORE()` in a try/catch and skip any terminal that doesn't expose one, rather than reverting the
            // whole selection — otherwise a single such terminal permanently DoSes `deployPool`/`addLiquidity` for
            // the project.
            IJBTerminalStore termStore;
            // Bounded by the project's own terminal and context lists; view reads only.
            // forge-lint: disable-next-line(calls-loop)
            try term.STORE() returns (IJBTerminalStore store_) {
                termStore = store_;
            } catch {
                continue;
            }

            // Get all accounting contexts (one per accepted token) for this project on this terminal. Guard the same
            // way so a terminal that reverts here is skipped rather than aborting the loop.
            JBAccountingContext[] memory contexts;
            // Bounded by the project's own terminal and context lists; view reads only.
            // forge-lint: disable-next-line(calls-loop)
            try term.accountingContextsOf(projectId) returns (JBAccountingContext[] memory contexts_) {
                contexts = contexts_;
            } catch {
                continue;
            }

            // Cache context count for gas-efficient iteration.
            uint256 contextCount = contexts.length;

            // Iterate over each token accepted by this terminal.
            for (uint256 j; j < contextCount; j++) {
                // Load the accounting context for this token.
                JBAccountingContext memory context = contexts[j];

                // This hook keys each LP by terminal token and, when it operates, cashes out through the project's
                // primary terminal for that token. Holders may still cash out directly from same-token secondary
                // terminals, but those balances are not available to this hook's primary-terminal path.
                address primaryTerminal =
                    _primaryTerminalOf({directory: directory, projectId: projectId, token: context.token});
                if (primaryTerminal == address(0) || primaryTerminal != address(term)) continue;

                // Look up how much of this token the terminal holds for the project.
                // Bounded like the calls above. `termStore` is set in the `STORE()` try; its catch skips ahead.
                // forge-lint: disable-start(calls-loop,uninitialized-local)
                uint256 balance =
                    termStore.balanceOf({terminal: address(term), projectId: projectId, token: context.token});
                // forge-lint: disable-end(calls-loop,uninitialized-local)

                // Skip tokens with zero balance — they can't be the highest value.
                if (balance == 0) continue;

                // Convert the balance to an 18-decimal ETH-denominated value for apples-to-apples comparison.
                uint256 ethValue = 0;

                if (context.currency == ethCurrency) {
                    // Native ETH: balance is already denominated in 18-decimal ETH.
                    ethValue = balance;
                } else {
                    // For non-ETH tokens, use the price feed to normalize to ETH.
                    // pricePerUnit = how many of `context.currency` per 1 ETH at `context.decimals` precision.
                    // ethValue (18-decimal) = balance * 10^18 / pricePerUnit.
                    // Bounded by the project's own terminal and context lists; view reads only.
                    // forge-lint: disable-start(calls-loop)
                    try IJBController(controller).PRICES().pricePerUnitOf({
                        projectId: projectId,
                        pricingCurrency: context.currency,
                        unitCurrency: ethCurrency,
                        decimals: context.decimals
                    }) returns (
                        uint256 pricePerUnit
                    ) {
                        // Normalize the balance to 18-decimal ETH using the price feed result.
                        ethValue = mulDiv({x: balance, y: 10 ** 18, denominator: pricePerUnit});
                    } catch {
                        // No price feed available — skip this token while priced candidates exist. If every candidate
                        // is unpriced, compare 18-decimal token-unit balances so low-decimal tokens are not penalized.
                        uint256 normalizedBalance =
                            mulDiv({x: balance, y: 10 ** 18, denominator: 10 ** context.decimals});
                        if (normalizedBalance > highestUnpricedBalance) {
                            highestUnpricedBalance = normalizedBalance;
                            highestUnpricedToken = context.token;
                        }
                        continue;
                    }
                    // forge-lint: disable-end(calls-loop)
                }

                // Update the highest value and corresponding token if this one exceeds the current best.
                if (ethValue > highestValue) {
                    highestValue = ethValue;
                    highestToken = context.token;
                }
            }
        }

        // If no priced token was found, fall back to the highest-balance unpriced token.
        if (highestToken == address(0)) highestToken = highestUnpricedToken;

        // Revert if no token with a non-zero balance was found across any terminal.
        if (highestToken == address(0)) revert JBUniswapV4LPSplitHookMath_NoTerminalTokenFound({projectId: projectId});
    }

    /// @notice Calculate the cash out rate (price floor).
    /// @dev The floor is what a holder would reclaim by cashing out 1e18 project tokens right now, as previewed by the
    /// project's own terminal store, so the ruleset's cash-out tax curve is included.
    /// Uses total on-chain surplus across all terminals (matching JBTerminalStore._computeCashOutFrom).
    /// When `scopeCashOutsToLocalBalances` is false, also includes remote cross-chain surplus and supply
    /// from the sucker registry for accurate omnichain pricing.
    /// @param directory The JBDirectory used to resolve the project's primary terminal.
    /// @param suckerRegistry The sucker registry for cross-chain surplus/supply queries.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return terminalTokensPerProjectToken Terminal tokens returned per project token burned (18-decimal
    /// fixed-point).
    function getCashOutRate(
        IJBDirectory directory,
        IJBSuckerRegistry suckerRegistry,
        uint256 projectId,
        address terminalToken,
        address controller,
        JBRuleset memory ruleset
    )
        public
        view
        returns (uint256 terminalTokensPerProjectToken)
    {
        // Resolve the project's primary terminal for this token.
        IJBMultiTerminal terminal =
            IJBMultiTerminal(_primaryTerminalOf({directory: directory, projectId: projectId, token: terminalToken}));

        // Get the store for surplus queries.
        // No loop in src reaches this view read, so it runs once per call.
        // forge-lint: disable-next-line(calls-loop)
        IJBTerminalStore store = terminal.STORE();

        // Read the terminal's declared currency for this token. Using `uint32(uint160(terminalToken))` here would
        // diverge from `getIssuanceRate`, which reads the accounting context directly. The two paths must agree on
        // the same currency identifier so issuance and cash-out price the LP bounds against a consistent reference.
        // No loop in src reaches this view read, so it runs once per call.
        // forge-lint: disable-start(calls-loop)
        JBAccountingContext memory accountingContext =
            terminal.accountingContextForTokenOf({projectId: projectId, token: terminalToken});
        // forge-lint: disable-end(calls-loop)
        uint256 decimals = accountingContext.decimals;
        uint256 currency = uint256(accountingContext.currency);

        // Local surplus across every terminal in the directory, summed the way the terminal store sums it at
        // settlement (each terminal reports its own surplus), so terminals backed by different stores all count.
        uint256 surplus = JBSurplus.currentSurplusOf({
            projectId: projectId,
            // No loop in src reaches this view read, so it runs once per call.
            // forge-lint: disable-next-line(calls-loop)
            terminals: directory.terminalsOf(projectId),
            tokens: new address[](0),
            decimals: decimals,
            currency: currency
        });
        // No loop in src reaches this view read, so it runs once per call.
        // forge-lint: disable-next-line(calls-loop)
        uint256 totalSupply = IJBController(controller).totalTokenSupplyWithReservedTokensOf(projectId);

        // If the project doesn't scope cash outs to local balances, include remote cross-chain surplus and supply.
        if (!ruleset.scopeCashOutsToLocalBalances()) {
            // No loop in src reaches this view read, so it runs once per call.
            // forge-lint: disable-start(calls-loop)
            surplus += suckerRegistry.totalRemoteSurplusOf({
                projectId: projectId, decimals: decimals, currency: currency
            });
            // forge-lint: disable-end(calls-loop)
            // No loop in src reaches this view read, so it runs once per call.
            // forge-lint: disable-next-line(calls-loop)
            totalSupply += suckerRegistry.remoteTotalSupplyOf(projectId);
        }

        // Ask the store what cashing out one token (1e18) would reclaim against that surplus and supply.
        terminalTokensPerProjectToken = _terminalTokensPerProjectToken({
            store: store, projectId: projectId, totalSupply: totalSupply, surplus: surplus
        });
    }

    /// @notice Convert cash out rate to sqrtPriceX96 (price floor).
    /// @param directory The JBDirectory used to resolve the project's primary terminal.
    /// @param suckerRegistry The sucker registry for cross-chain surplus/supply queries.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return sqrtPriceX96 An upper bound on the per-token cash-out value encoded as a Uniswap V4 sqrtPriceX96 (see
    /// `_cashOutBoundSqrtPrice`).
    function getCashOutRateSqrtPriceX96(
        IJBDirectory directory,
        IJBSuckerRegistry suckerRegistry,
        uint256 projectId,
        address terminalToken,
        address projectToken,
        address controller,
        JBRuleset memory ruleset
    )
        public
        view
        returns (uint160 sqrtPriceX96)
    {
        (address token0,) = JBLPSplitHookHelpers.sortTokens({tokenA: terminalToken, tokenB: projectToken});
        return _cashOutBoundSqrtPrice({
            rate: getCashOutRate({
                directory: directory,
                suckerRegistry: suckerRegistry,
                projectId: projectId,
                terminalToken: terminalToken,
                controller: controller,
                ruleset: ruleset
            }),
            projectIsToken0: projectToken == token0
        });
    }

    /// @notice Calculate the issuance rate (price ceiling).
    /// @dev The number of project tokens a payer receives for 1e18 terminal tokens at the current weight, after the
    /// reserved percent is set aside. A bid that paid more than this per token could be filled by anyone who pays the
    /// project, mints at this rate, and sells the tokens into the bid at a profit, so the hook's bid never pays more.
    /// @param directory The JBDirectory used to resolve the project's primary terminal.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return projectTokensPerTerminalToken Project tokens minted (after reserves) per terminal token (18-decimal).
    function getIssuanceRate(
        IJBDirectory directory,
        uint256 projectId,
        address terminalToken,
        address controller,
        JBRuleset memory ruleset
    )
        public
        view
        returns (uint256 projectTokensPerTerminalToken)
    {
        // Extract the reserved token percentage from the ruleset metadata.
        uint16 reservedPercent = JBRulesetMetadataResolver.reservedPercent(ruleset);

        // Compute the raw mint output for 1 WAD of terminal tokens at the current weight.
        uint256 tokensPerTerminalToken = getProjectTokensOutForTerminalTokensIn({
            directory: directory,
            projectId: projectId,
            terminalToken: terminalToken,
            terminalTokenInAmount: _WAD,
            controller: controller,
            ruleset: ruleset
        });

        // Subtract the reserved portion — only the non-reserved fraction trades on the open market.
        if (reservedPercent > 0) {
            projectTokensPerTerminalToken = mulDiv({
                x: tokensPerTerminalToken,
                y: uint256(JBConstants.MAX_RESERVED_PERCENT - reservedPercent),
                denominator: uint256(JBConstants.MAX_RESERVED_PERCENT)
            });
        } else {
            projectTokensPerTerminalToken = tokensPerTerminalToken;
        }
    }

    /// @notice Convert issuance rate to sqrtPriceX96 (price ceiling).
    /// @param directory The JBDirectory used to resolve the project's primary terminal.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return sqrtPriceX96 The issuance-derived price encoded as a Uniswap V4 sqrtPriceX96.
    function getIssuanceRateSqrtPriceX96(
        IJBDirectory directory,
        uint256 projectId,
        address terminalToken,
        address projectToken,
        address controller,
        JBRuleset memory ruleset
    )
        public
        view
        returns (uint160 sqrtPriceX96)
    {
        // Sort tokens to determine which is token0 (lower address) for the Uniswap pair.
        (address token0,) = JBLPSplitHookHelpers.sortTokens({tokenA: terminalToken, tokenB: projectToken});

        // One sample of 1 WAD at the current weight, before reserves.
        uint256 gross = getProjectTokensOutForTerminalTokensIn({
            directory: directory,
            projectId: projectId,
            terminalToken: terminalToken,
            terminalTokenInAmount: _WAD,
            controller: controller,
            ruleset: ruleset
        });
        uint256 netShare = JBConstants.MAX_RESERVED_PERCENT - JBRulesetMetadataResolver.reservedPercent(ruleset);

        // Issuance is structurally zero only with zero weight or a 100% reserved rate (the test `calculateTickBounds`
        // uses for its branches); return an extreme price then. A sampled output that merely rounds to 0 is bounded
        // below.
        // The correct extreme depends on token ordering since sqrtPriceX96 = sqrt(token1/token0):
        // - terminalToken is token0: token1(PT)/token0(TT) → 0 as PT becomes unmintable → MIN
        // - projectToken is token0: token1(TT)/token0(PT) → ∞ as PT becomes unmintable → MAX
        if (ruleset.weight == 0 || netShare == 0) {
            return token0 == terminalToken ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE - 1;
        }

        // The net rate truncates twice (weight conversion, then the reserved split), while larger payments mint at the
        // untruncated rate. Bound it from above so the ceiling never sits above what a payer can mint at: the gross
        // conversion is below `gross + 1`, and the reserved split of that rounds up.
        uint256 projectTokensPerTerminalToken =
            _mulDiv({x: gross + 1, y: netShare, denominator: JBConstants.MAX_RESERVED_PERCENT, roundUp: true});

        // The ceiling rounds toward a LOWER project price: down when the project is token0 (pool price = terminal per
        // project), up when it is token1 (pool price = project per terminal).
        return token0 == terminalToken
            ? _toSqrtPriceX96({amount1: projectTokensPerTerminalToken, amount0: _WAD, roundUp: true})
            : _toSqrtPriceX96({amount1: _WAD, amount0: projectTokensPerTerminalToken, roundUp: false});
    }

    /// @notice Encode the price `amount1 / amount0` as a sqrtPriceX96, clamped to Uniswap's valid range.
    /// @dev Scales before taking the root so small ratios keep their precision (an integer root of the raw ratio
    /// would encode a rate of 2 like a rate of 1). Ratios below 2^64 scale by 2^192; larger ones by 2^64 and shift the
    /// root up by 2^64, which still leaves at least 64 bits of root precision. Ratios at or above 2^128 clamp to the
    /// maximum before any scaling.
    /// @param amount1 The token1 side of the price.
    /// @param amount0 The token0 side of the price (nonzero).
    /// @param roundUp Whether to round the encoded price up rather than down.
    /// @return sqrtPriceX96 The encoded price.
    function _toSqrtPriceX96(
        uint256 amount1,
        uint256 amount0,
        bool roundUp
    )
        private
        pure
        returns (uint160 sqrtPriceX96)
    {
        // A pool's sqrtPriceX96 is `sqrt(amount1 / amount0) * 2^96`, which equals `sqrt(amount1 * 2^192 / amount0)`.
        // Prices at or above 2^128 are past MAX_SQRT_PRICE (about 2^160) already; clamping first keeps the scaled
        // ratio below 2^192 so the multiplication cannot overflow.
        uint256 ratio = amount1 / amount0;
        if (ratio >= 2 ** 128) return TickMath.MAX_SQRT_PRICE - 1;
        uint256 result;
        if (ratio < 2 ** 64) {
            // Small ratio: scale by the full 2^192 before the root.
            result = _sqrt({
                x: _mulDiv({x: amount1, y: 2 ** 192, denominator: amount0, roundUp: roundUp}), roundUp: roundUp
            });
        } else {
            // Large ratio: 2^192 would overflow, so scale by 2^64 and multiply the root by 2^64 (sqrt(2^128)).
            result = _sqrt({
                x: _mulDiv({x: amount1, y: 2 ** 64, denominator: amount0, roundUp: roundUp}), roundUp: roundUp
            }) << 64;
        }

        // Clamp into the range Uniswap accepts for a price.
        if (result < uint256(TickMath.MIN_SQRT_PRICE)) return TickMath.MIN_SQRT_PRICE;
        if (result > uint256(TickMath.MAX_SQRT_PRICE - 1)) return TickMath.MAX_SQRT_PRICE - 1;
        // The value was clamped into the uint160 Uniswap sqrt-price range above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(result);
    }

    /// @notice `x * y / denominator`, rounded up or down.
    function _mulDiv(uint256 x, uint256 y, uint256 denominator, bool roundUp) private pure returns (uint256 result) {
        result = mulDiv({x: x, y: y, denominator: denominator});
        if (roundUp && mulmod(x, y, denominator) != 0) result++;
    }

    /// @notice The integer square root of `x`, rounded up or down.
    function _sqrt(uint256 x, bool roundUp) private pure returns (uint256 result) {
        result = sqrt(x);
        if (roundUp && result * result < x) result++;
    }

    /// @notice For given terminalToken amount, compute equivalent projectToken amount at current JuiceboxV4 price.
    /// @dev Mirrors how a terminal prices a payment: `amount * weight / weightRatio`, where `weightRatio` is one whole
    /// terminal token when its currency is the ruleset's base currency, else its price in the base currency.
    /// @param directory The JBDirectory used to resolve the project's primary terminal.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param terminalTokenInAmount The amount of terminal tokens to convert.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return projectTokenOutAmount The equivalent project token amount at the current issuance weight.
    function getProjectTokensOutForTerminalTokensIn(
        IJBDirectory directory,
        uint256 projectId,
        address terminalToken,
        uint256 terminalTokenInAmount,
        address controller,
        JBRuleset memory ruleset
    )
        public
        view
        returns (uint256 projectTokenOutAmount)
    {
        // Look up the project's primary terminal for this token.
        address terminal = _primaryTerminalOf({directory: directory, projectId: projectId, token: terminalToken});
        // Fetch the terminal's accounting context (decimals, currency) for this project/token pair.
        // No loop in src reaches this view read, so it runs once per call.
        // forge-lint: disable-start(calls-loop)
        JBAccountingContext memory context =
            IJBMultiTerminal(terminal).accountingContextForTokenOf({projectId: projectId, token: terminalToken});
        // forge-lint: disable-end(calls-loop)

        // Read the base currency from the ruleset (e.g. ETH=1, USD=2).
        uint32 baseCurrency = ruleset.baseCurrency();

        // Compute the weight ratio: if the terminal currency matches the base currency, use 10^decimals
        // directly; otherwise, convert via the price oracle.
        // No loop in src reaches this view read, so it runs once per call.
        // forge-lint: disable-start(calls-loop)
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES().pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        // forge-lint: disable-end(calls-loop)

        // Apply the ruleset weight to convert terminal tokens → project tokens at the current rate.
        projectTokenOutAmount = mulDiv({x: terminalTokenInAmount, y: ruleset.weight, denominator: weightRatio});
    }

    //*********************************************************************//
    // ------------------------- private views --------------------------- //
    //*********************************************************************//

    /// @notice Look up the primary terminal for a project/token pair.
    /// @param directory The JBDirectory to query.
    /// @param projectId The ID of the project.
    /// @param token The token whose primary terminal to resolve.
    /// @return terminal The project's primary terminal for `token` (address(0) if none is set).
    function _primaryTerminalOf(
        IJBDirectory directory,
        uint256 projectId,
        address token
    )
        private
        view
        returns (address terminal)
    {
        // Called once per context in the bounded terminal scan; a view read.
        // forge-lint: disable-next-line(calls-loop)
        return address(directory.primaryTerminalOf({projectId: projectId, token: token}));
    }

    /// @notice Convert a reclaim preview into a per-1e18 project-token cash-out rate.
    /// @param store The terminal store to query.
    /// @param projectId The ID of the project.
    /// @param totalSupply The project token supply used by the cash-out curve.
    /// @param surplus The surplus used by the cash-out curve.
    /// @return terminalTokensPerProjectToken Terminal tokens returned per 1e18 project tokens burned.
    function _terminalTokensPerProjectToken(
        IJBTerminalStore store,
        uint256 projectId,
        uint256 totalSupply,
        uint256 surplus
    )
        private
        view
        returns (uint256 terminalTokensPerProjectToken)
    {
        // No supply means nothing can be cashed out, so there is no floor to read.
        if (totalSupply == 0) return 0;

        // Preview a 1e18-token cash-out. With less than 1e18 tokens in existence, preview the whole supply instead (a
        // larger count would still reclaim only the whole surplus, understating the rate) and scale it to 1e18 below.
        uint256 cashOutCount = totalSupply < _WAD ? totalSupply : _WAD;
        // No try/catch: a preview failure must not read as a zero floor.
        // No loop in src reaches this view read, so it runs once per call.
        // forge-lint: disable-start(calls-loop)
        uint256 reclaimableAmount = store.currentReclaimableSurplusOf({
            projectId: projectId, cashOutCount: cashOutCount, totalSupply: totalSupply, surplus: surplus
        });
        // forge-lint: disable-end(calls-loop)
        if (cashOutCount == _WAD) return reclaimableAmount;
        // Scaling a partial-supply preview up to 1e18 tokens saturates rather than overflowing.
        if (reclaimableAmount / cashOutCount >= type(uint256).max / _WAD) return type(uint256).max;
        terminalTokensPerProjectToken = mulDiv({x: reclaimableAmount, y: _WAD, denominator: cashOutCount});
    }
}
