// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv, sqrt} from "@prb/math/src/Common.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

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

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the computed LP tick range collapses to an empty or inverted band.
    error JBUniswapV4LPSplitHookMath_InvalidTickBounds(int24 tickLower, int24 tickUpper);
    /// @notice Thrown when no terminal token with a non-zero balance is found across a project's terminals.
    error JBUniswapV4LPSplitHookMath_NoTerminalTokenFound(uint256 projectId);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Tick spacing for the 1% fee tier (200 ticks). Mirrors `JBUniswapV4LPSplitHook.TICK_SPACING`.
    int24 internal constant _TICK_SPACING = 200;

    /// @notice Uniswap V4 Q96 fixed-point scale factor for sqrtPriceX96 values.
    uint256 internal constant _Q96 = 2 ** 96;

    /// @notice 1e18 scale factor used as a unit amount in rate calculations.
    uint256 internal constant _WAD = 10 ** 18;

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Calculate tick bounds for liquidity position based on issuance and cash out rates.
    /// @param directory The JBDirectory used to resolve the project's primary terminal.
    /// @param suckerRegistry The sucker registry for cross-chain surplus/supply queries.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return tickLower The lower tick bound of the LP position.
    /// @return tickUpper The upper tick bound of the LP position.
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
        // Check if the cash out rate can be computed (may round to 0 with low-decimal tokens like USDC).
        uint256 cashOutRate = getCashOutRate({
            directory: directory,
            suckerRegistry: suckerRegistry,
            projectId: projectId,
            terminalToken: terminalToken,
            controller: controller,
            ruleset: ruleset
        });

        if (cashOutRate == 0) {
            uint256 issuanceRate = getIssuanceRate({
                directory: directory,
                projectId: projectId,
                terminalToken: terminalToken,
                controller: controller,
                ruleset: ruleset
            });

            if (issuanceRate == 0) {
                // No floor and no ceiling — full range LP. The project has no economic anchor (no surplus to set a
                // floor, no issuance to set a ceiling) so any market-set price is acceptable. Liquidity is intended
                // to track the prevailing market in this state rather than enforce a project-defined band.
                tickLower = JBLPSplitHookHelpers.alignTickToSpacing({tick: TickMath.MIN_TICK, spacing: _TICK_SPACING})
                    + _TICK_SPACING;
                tickUpper = JBLPSplitHookHelpers.alignTickToSpacing({tick: TickMath.MAX_TICK, spacing: _TICK_SPACING})
                    - _TICK_SPACING;
                return (tickLower, tickUpper);
            }

            // Cash out rate rounds to 0 due to precision loss (e.g. 6-decimal USDC with large token supply). With no
            // redemption floor, the corridor's ceiling-side bound must land EXACTLY on the issuance tick — matching
            // the cashOutRate != 0 path, where the issuance-derived bound is aligned onto the issuance tick — so that
            // `_requireSpotBelowCeiling` rejects a spot that has reached the true issuance price. The opposite bound
            // is the floor side; with no floor it sits one spacing away purely to keep the range non-empty (bids are
            // empty when there is no terminal). Ordering-aware: the issuance ceiling is the corridor UPPER when the
            // project is token0 and the corridor LOWER when it is token1.
            int24 issuanceTick = TickMath.getTickAtSqrtPrice(
                getIssuanceRateSqrtPriceX96({
                    directory: directory,
                    projectId: projectId,
                    terminalToken: terminalToken,
                    projectToken: projectToken,
                    controller: controller,
                    ruleset: ruleset
                })
            );

            (address token0,) = JBLPSplitHookHelpers.sortTokens({tokenA: terminalToken, tokenB: projectToken});

            // The floor-side bound sits two spacings from the exact-issuance ceiling. Two spacings (not one) leaves room
            // for a spot strictly below the ceiling to still align an ask leg one spacing deep, so a pre-initialized
            // pool below the issuance price remains deployable; there is no redemption floor to place more precisely.
            int24 floorGap = 2 * _TICK_SPACING;

            int24 zeroMinUsable =
                JBLPSplitHookHelpers.alignTickToSpacing({tick: TickMath.MIN_TICK, spacing: _TICK_SPACING}) + _TICK_SPACING;
            int24 zeroMaxUsable =
                JBLPSplitHookHelpers.alignTickToSpacing({tick: TickMath.MAX_TICK, spacing: _TICK_SPACING}) - _TICK_SPACING;

            if (projectToken == token0) {
                // Project is token0: the issuance ceiling is the corridor UPPER bound. Align DOWN (as the cashOut != 0
                // path aligns tickUpper) and keep the floor-gap below it inside the usable range.
                tickUpper = JBLPSplitHookHelpers.alignTickToSpacing({tick: issuanceTick, spacing: _TICK_SPACING});
                if (tickUpper > zeroMaxUsable) tickUpper = zeroMaxUsable;
                if (tickUpper < zeroMinUsable + floorGap) tickUpper = zeroMinUsable + floorGap;
                tickLower = tickUpper - floorGap;
            } else {
                // Project is token1: the issuance ceiling is the corridor LOWER bound. Align UP (as the cashOut != 0
                // path aligns tickLower) and keep the floor-gap above it inside the usable range.
                tickLower = JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: issuanceTick, spacing: _TICK_SPACING});
                if (tickLower < zeroMinUsable) tickLower = zeroMinUsable;
                if (tickLower > zeroMaxUsable - floorGap) tickLower = zeroMaxUsable - floorGap;
                tickUpper = tickLower + floorGap;
            }
            return (tickLower, tickUpper);
        }

        int24 rawTickA = TickMath.getTickAtSqrtPrice(
            getCashOutRateSqrtPriceX96({
                directory: directory,
                suckerRegistry: suckerRegistry,
                projectId: projectId,
                terminalToken: terminalToken,
                projectToken: projectToken,
                controller: controller,
                ruleset: ruleset
            })
        );
        int24 rawTickB = TickMath.getTickAtSqrtPrice(
            getIssuanceRateSqrtPriceX96({
                directory: directory,
                projectId: projectId,
                terminalToken: terminalToken,
                projectToken: projectToken,
                controller: controller,
                ruleset: ruleset
            })
        );

        // Sort ticks so tickLower <= tickUpper regardless of token ordering.
        // Without sorting, pools where terminalToken is token0 (e.g. native ETH)
        // would have cashOut tick > issuance tick, collapsing into the narrow fallback.
        tickLower = rawTickA < rawTickB ? rawTickA : rawTickB;
        tickUpper = rawTickA < rawTickB ? rawTickB : rawTickA;

        // Align ASYMMETRICALLY: tickLower up, tickUpper down. Both moves contract the LP range toward the
        // intended price band. Flooring both ticks would expand the lower side by up to one spacing interval,
        // exposing project liquidity at prices below what the bonding curve sanctioned.
        tickLower = JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: tickLower, spacing: _TICK_SPACING});
        tickUpper = JBLPSplitHookHelpers.alignTickToSpacing({tick: tickUpper, spacing: _TICK_SPACING});

        // Clamp to valid V4 tick range after alignment.
        int24 minUsable =
            JBLPSplitHookHelpers.alignTickToSpacing({tick: TickMath.MIN_TICK, spacing: _TICK_SPACING}) + _TICK_SPACING;
        int24 maxUsable =
            JBLPSplitHookHelpers.alignTickToSpacing({tick: TickMath.MAX_TICK, spacing: _TICK_SPACING}) - _TICK_SPACING;
        if (tickLower < minUsable) tickLower = minUsable;
        if (tickUpper > maxUsable) tickUpper = maxUsable;

        if (tickLower >= tickUpper) {
            uint160 currentSqrtPrice = getSqrtPriceX96ForCurrentJuiceboxPrice({
                directory: directory,
                projectId: projectId,
                terminalToken: terminalToken,
                projectToken: projectToken,
                controller: controller,
                ruleset: ruleset
            });
            int24 currentTick = TickMath.getTickAtSqrtPrice(currentSqrtPrice);
            currentTick = JBLPSplitHookHelpers.alignTickToSpacing({tick: currentTick, spacing: _TICK_SPACING});
            tickLower = currentTick - _TICK_SPACING;
            tickUpper = currentTick + _TICK_SPACING;

            // Re-clamp to valid range — the fallback ticks may exceed boundaries when currentTick is near extremes.
            if (tickLower < minUsable) tickLower = minUsable;
            if (tickUpper > maxUsable) tickUpper = maxUsable;

            // Final validation: if clamping collapsed the range, revert rather than create an invalid position.
            if (tickLower >= tickUpper) {
                revert JBUniswapV4LPSplitHookMath_InvalidTickBounds({tickLower: tickLower, tickUpper: tickUpper});
            }
        }
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
    /// surplus and thus no floor).
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
        (address token0,) = JBLPSplitHookHelpers.sortTokens({tokenA: terminalToken, tokenB: projectToken});
        // Offset one spacing off the floor bound toward the ceiling, then clamp so the seed stays at least one spacing
        // short of the ceiling. Both bounds are spacing-aligned, so the seed is too — never landing on an unaligned tick
        // that would collapse the asks-only adaptive range. For a one-spacing corridor the clamp folds the seed back
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

    /// @notice Compute optimal cash-out amount based on LP position geometry.
    /// @dev A standalone pricing primitive: given a target terminal/project pairing ratio, it returns how many project
    /// tokens a cash-out at the bonding-curve rate would need to surrender. The hook's current single-sided flow does
    /// not invoke it — the hook never cashes out — so it exists purely as a reusable valuation helper.
    /// @param directory The JBDirectory used to resolve the project's primary terminal.
    /// @param suckerRegistry The sucker registry for cross-chain surplus/supply queries.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param totalProjectTokens Total project tokens available for the LP position.
    /// @param preHeldTerminalTokens Terminal tokens already held (e.g. recovered from a re-range burn) that count
    /// toward the position's terminal side, so the cash-out is reduced accordingly. Pass 0 when none are held.
    /// @param sqrtPriceInit The initial sqrt price of the pool.
    /// @param tickLower The lower tick bound of the LP position.
    /// @param tickUpper The upper tick bound of the LP position.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return cashOutAmount The number of project tokens to cash out for optimal terminal-token pairing.
    function computeOptimalCashOutAmount(
        IJBDirectory directory,
        IJBSuckerRegistry suckerRegistry,
        uint256 projectId,
        address terminalToken,
        address projectToken,
        uint256 totalProjectTokens,
        uint256 preHeldTerminalTokens,
        uint160 sqrtPriceInit,
        int24 tickLower,
        int24 tickUpper,
        address controller,
        JBRuleset memory ruleset
    )
        public
        view
        returns (uint256 cashOutAmount)
    {
        // The cash-out rate (terminal tokens received per project token burned, 18-decimal) is the "exchange rate" a
        // cash-out would run at. Without it there is no way to value the terminal side, so no cash-out amount can be
        // sized.
        uint256 cashOutRate = getCashOutRate({
            directory: directory,
            suckerRegistry: suckerRegistry,
            projectId: projectId,
            terminalToken: terminalToken,
            controller: controller,
            ruleset: ruleset
        });

        // No surplus / unpriceable: a zero rate means cashing out yields nothing, so don't cash out any project tokens.
        if (cashOutRate == 0) return 0;

        // The position spans [tickLower, tickUpper]. Convert those bounds to sqrt prices (√Pa, √Pb, Q96
        // fixed-point) so
        // we can compare the pool's current price against the range and derive the token0:token1 ratio the mint needs.
        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // Uniswap orders a pool's two currencies by address (token0 = lower). Which physical token is token0 flips the
        // amount-ratio formula below, so resolve it once. `toCurrency` maps the native sentinel to address(0).
        Currency terminalCurrency = JBLPSplitHookHelpers.toCurrency(terminalToken);
        bool terminalIsToken0 = Currency.unwrap(terminalCurrency) < projectToken;

        // numerator/denominator will hold the position's required (terminal-token : project-token) amount ratio.
        uint256 numerator;
        uint256 denominator;

        // Price at or below the lower bound: a concentrated position there is single-sided in token0. If the terminal
        // token IS token0 the whole position must be terminal tokens, so cash out everything; otherwise (project is
        // token0) the position is all project tokens, so cash out nothing.
        if (uint160(sqrtPriceInit) <= sqrtPriceA) {
            return terminalIsToken0 ? totalProjectTokens : 0;
        }
        // Price at or above the upper bound: single-sided in token1. Mirror image of the case above.
        if (uint160(sqrtPriceInit) >= sqrtPriceB) {
            return terminalIsToken0 ? 0 : totalProjectTokens;
        }

        // In-range: both sides are needed. Precompute the two sqrt-price gaps that drive the Uniswap amount formula —
        // (√P − √Pa) governs the token1 side and (√Pb − √P) governs the token0 side.
        uint256 diffPriceInitA = uint256(sqrtPriceInit) - uint256(sqrtPriceA);
        uint256 diffBPriceInit = uint256(sqrtPriceB) - uint256(sqrtPriceInit);

        if (terminalIsToken0) {
            // terminal = token0, project = token1. The pool wants amount0/amount1 (i.e. terminal/project) =
            //   Q96² × (√Pb − √P) / (√P × √Pb × (√P − √Pa)).
            // Evaluate in two mulDiv steps so no intermediate (Q96² × gap) overflows 256 bits:
            // step1 = Q96 × (√Pb − √P) / √P, then numerator = step1 × Q96 / √Pb; denominator = (√P −
            // √Pa).
            uint256 step1 = mulDiv({x: _Q96, y: diffBPriceInit, denominator: uint256(sqrtPriceInit)});
            numerator = mulDiv({x: step1, y: _Q96, denominator: uint256(sqrtPriceB)});
            denominator = diffPriceInitA;
        } else {
            // terminal = token1, project = token0. The pool wants amount1/amount0 (i.e. terminal/project) =
            //   √P × √Pb × (√P − √Pa) / (Q96² × (√Pb − √P)) — the reciprocal-shaped formula.
            // Again split into two mulDiv steps: step1 = √P × √Pb / Q96, then numerator = step1 × (√P −
            // √Pa) / Q96.
            uint256 step1 = mulDiv({x: uint256(sqrtPriceInit), y: uint256(sqrtPriceB), denominator: _Q96});
            numerator = mulDiv({x: step1, y: diffPriceInitA, denominator: _Q96});
            denominator = diffBPriceInit;
        }

        // Collapse the ratio to a single 18-decimal scalar: ratioE18 = terminal tokens the position needs per 1 project
        // token of position value (× 1e18). This is the target the cash-out must produce.
        uint256 ratioE18 = mulDiv({x: numerator, y: _WAD, denominator: denominator});

        // Degenerate ratio (rounds to 0): the position needs effectively no terminal side, so cash out nothing.
        if (ratioE18 == 0) return 0;

        // Solve for the cash-out amount `c`, folding in any pre-held terminal tokens `H`. After cashing out c project
        // tokens the position holds (c·cashOutRate + H) terminal and (T − c) project; we want terminal/project ==
        // ratioE18 (= R), i.e. (c·cashOutRate + H)/(T − c) = R. Rearranged:
        //   c = (T·R − H) / (cashOutRate + R)  →  c = T·ratioE18/(r+R) − H/(r+R).
        // The pre-held reduction MUST use the combined divisor (cashOutRate + ratioE18), not cashOutRate alone:
        // subtracting H/cashOutRate over-subtracts (since r+R > r), under-deploying capital and stranding project
        // tokens as leftovers. `denom` is that combined divisor.
        uint256 denom = cashOutRate + ratioE18;
        if (denom == 0) return 0;

        // Gross optimum ignoring pre-held tokens: T·R/(r+R).
        uint256 grossCashOut = mulDiv({x: totalProjectTokens, y: ratioE18, denominator: denom});

        // Project-token equivalent of the pre-held terminal tokens at the SAME combined rate: H/(r+R).
        uint256 preHeldReduction =
            preHeldTerminalTokens == 0 ? 0 : mulDiv({x: preHeldTerminalTokens, y: _WAD, denominator: denom});

        // Cash out the gross optimum minus the pre-held offset, so the cashed-out + pre-held terminal side and the
        // leftover project side land exactly on the position's required ratio. Clamp at 0 if pre-held already covers
        // it.
        cashOutAmount = grossCashOut > preHeldReduction ? grossCashOut - preHeldReduction : 0;
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
        uint256 highestValue;

        // Fallback tracking for tokens without a price feed.
        address highestUnpricedToken;
        uint256 highestUnpricedBalance;

        // The ETH currency identifier used for price normalization.
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
            try term.STORE() returns (IJBTerminalStore store_) {
                termStore = store_;
            } catch {
                continue;
            }

            // Get all accounting contexts (one per accepted token) for this project on this terminal. Guard the same
            // way so a terminal that reverts here is skipped rather than aborting the loop.
            JBAccountingContext[] memory contexts;
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
                uint256 balance =
                    termStore.balanceOf({terminal: address(term), projectId: projectId, token: context.token});

                // Skip tokens with zero balance — they can't be the highest value.
                if (balance == 0) continue;

                // Convert the balance to an 18-decimal ETH-denominated value for apples-to-apples comparison.
                uint256 ethValue;

                if (context.currency == ethCurrency) {
                    // Native ETH: balance is already denominated in 18-decimal ETH.
                    ethValue = balance;
                } else {
                    // For non-ETH tokens, use the price feed to normalize to ETH.
                    // pricePerUnit = how many of `context.currency` per 1 ETH at `context.decimals` precision.
                    // ethValue (18-decimal) = balance * 10^18 / pricePerUnit.
                    try IJBController(controller).PRICES()
                        .pricePerUnitOf({
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
    /// @dev Uses total on-chain surplus across all terminals (matching JBTerminalStore._computeCashOutFrom).
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
        IJBTerminalStore store = terminal.STORE();

        // Read the terminal's declared currency for this token. Using `uint32(uint160(terminalToken))` here would
        // diverge from `getIssuanceRate`, which reads the accounting context directly. The two paths must agree on
        // the same currency identifier so issuance and cash-out price the LP bounds against a consistent reference.
        JBAccountingContext memory accountingContext =
            terminal.accountingContextForTokenOf({projectId: projectId, token: terminalToken});
        uint256 decimals = accountingContext.decimals;
        uint256 currency = uint256(accountingContext.currency);

        // If the project doesn't scope cash outs to local balances, include remote cross-chain
        // surplus and supply in the bonding curve calculation.
        if (!ruleset.scopeCashOutsToLocalBalances()) {
            // Get on-chain total surplus across all terminals.
            try store.currentTotalSurplusOf({projectId: projectId, decimals: decimals, currency: currency}) returns (
                uint256 surplus
            ) {
                // Get on-chain total supply including pending reserved tokens.
                uint256 totalSupply = IJBController(controller).totalTokenSupplyWithReservedTokensOf(projectId);

                // Add remote cross-chain surplus and supply.
                surplus += suckerRegistry.totalRemoteSurplusOf({
                    projectId: projectId, decimals: decimals, currency: currency
                });
                totalSupply += suckerRegistry.remoteTotalSupplyOf(projectId);

                // Apply the bonding curve with the combined on-chain + remote values.
                terminalTokensPerProjectToken = _terminalTokensPerProjectToken({
                    store: store, projectId: projectId, totalSupply: totalSupply, surplus: surplus
                });
            } catch {
                terminalTokensPerProjectToken = 0;
            }
        } else {
            // Scoped to local balances — keep the terminal store's direct helper for normal supply, but avoid asking
            // it to preview burning 1e18 tokens when fewer than 1e18 project tokens exist.
            try IJBController(controller).totalTokenSupplyWithReservedTokensOf(projectId) returns (
                uint256 totalSupply
            ) {
                if (totalSupply >= _WAD) {
                    try store.currentTotalReclaimableSurplusOf({
                        projectId: projectId, cashOutCount: _WAD, decimals: decimals, currency: currency
                    }) returns (
                        uint256 reclaimableAmount
                    ) {
                        terminalTokensPerProjectToken = reclaimableAmount;
                    } catch {
                        terminalTokensPerProjectToken = 0;
                    }
                } else {
                    try store.currentTotalSurplusOf({
                        projectId: projectId, decimals: decimals, currency: currency
                    }) returns (
                        uint256 surplus
                    ) {
                        terminalTokensPerProjectToken =
                            _terminalTokensPerProjectToken({
                                store: store, projectId: projectId, totalSupply: totalSupply, surplus: surplus
                            });
                    } catch {
                        terminalTokensPerProjectToken = 0;
                    }
                }
            } catch {
                terminalTokensPerProjectToken = 0;
            }
        }
    }

    /// @notice Convert cash out rate to sqrtPriceX96 (price floor).
    /// @param directory The JBDirectory used to resolve the project's primary terminal.
    /// @param suckerRegistry The sucker registry for cross-chain surplus/supply queries.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return sqrtPriceX96 The cash-out-derived price encoded as a Uniswap V4 sqrtPriceX96.
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
        // Sort tokens to determine which is token0 (lower address) for the Uniswap pair.
        (address token0,) = JBLPSplitHookHelpers.sortTokens({tokenA: terminalToken, tokenB: projectToken});

        // Query the bonding curve cash out rate — terminal tokens received per project token burned.
        uint256 terminalTokensPerProjectToken = getCashOutRate({
            directory: directory,
            suckerRegistry: suckerRegistry,
            projectId: projectId,
            terminalToken: terminalToken,
            controller: controller,
            ruleset: ruleset
        });

        // If the cash out rate is 0 (no surplus or negligible surplus), return an extreme price.
        // The correct extreme depends on token ordering since sqrtPriceX96 = sqrt(token1/token0):
        // - terminalToken is token0: token1(PT)/token0(TT) → ∞ as PT becomes worthless → MAX
        // - projectToken is token0: token1(TT)/token0(PT) → 0 as PT becomes worthless → MIN
        if (terminalTokensPerProjectToken == 0) {
            return token0 == terminalToken ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE;
        }

        // Use 1 WAD of token0 as the reference amount for price computation.
        uint256 token0Amount = _WAD;
        uint256 token1Amount;

        // Map the cash out rate to token0/token1 amounts depending on which side is the terminal token.
        if (token0 == terminalToken) {
            // terminal is token0: invert the rate to get projectTokens per terminalToken.
            token1Amount = mulDiv({x: token0Amount, y: _WAD, denominator: terminalTokensPerProjectToken});
        } else {
            // terminal is token1: the rate directly gives token1 per token0.
            token1Amount = terminalTokensPerProjectToken;
        }

        // Encode as sqrtPriceX96: sqrt(token1/token0) × 2^96.
        uint256 result = mulDiv({x: sqrt(token1Amount), y: _Q96, denominator: sqrt(token0Amount)});

        // Clamp to valid Uniswap V4 sqrt price range.
        if (result < uint256(TickMath.MIN_SQRT_PRICE)) return TickMath.MIN_SQRT_PRICE;
        if (result > uint256(TickMath.MAX_SQRT_PRICE - 1)) return TickMath.MAX_SQRT_PRICE - 1;
        // The value was clamped into the uint160 Uniswap sqrt-price range above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(result);
    }

    /// @notice Calculate the issuance rate (price ceiling).
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

        // Query the net issuance rate — project tokens minted (after reserves) per terminal token.
        uint256 projectTokensPerTerminalToken = getIssuanceRate({
            directory: directory,
            projectId: projectId,
            terminalToken: terminalToken,
            controller: controller,
            ruleset: ruleset
        });

        // If the issuance rate is 0 (e.g. 100% reserved rate or zero weight), return an extreme price.
        // The correct extreme depends on token ordering since sqrtPriceX96 = sqrt(token1/token0):
        // - terminalToken is token0: token1(PT)/token0(TT) → 0 as PT becomes unmintable → MIN
        // - projectToken is token0: token1(TT)/token0(PT) → ∞ as PT becomes unmintable → MAX
        if (projectTokensPerTerminalToken == 0) {
            return token0 == terminalToken ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE - 1;
        }

        // Compute sqrtPriceX96 directly from the rate to avoid intermediate division
        // that rounds to 0 when projectTokensPerTerminalToken > 1e36.
        uint256 result;
        if (token0 == terminalToken) {
            // terminal is token0: sqrtPrice = sqrt(PT/TT) × 2^96 = sqrt(rate) × 2^96 / sqrt(WAD).
            result = mulDiv({x: sqrt(projectTokensPerTerminalToken), y: _Q96, denominator: sqrt(_WAD)});
        } else {
            // project is token0: sqrtPrice = sqrt(TT/PT) × 2^96 = sqrt(WAD) × 2^96 / sqrt(rate).
            result = mulDiv({x: sqrt(_WAD), y: _Q96, denominator: sqrt(projectTokensPerTerminalToken)});
        }

        // Clamp to valid Uniswap V4 sqrt price range.
        if (result < uint256(TickMath.MIN_SQRT_PRICE)) return TickMath.MIN_SQRT_PRICE;
        if (result > uint256(TickMath.MAX_SQRT_PRICE - 1)) return TickMath.MAX_SQRT_PRICE - 1;
        // The value was clamped into the uint160 Uniswap sqrt-price range above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(result);
    }

    /// @notice For given terminalToken amount, compute equivalent projectToken amount at current JuiceboxV4 price.
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
        JBAccountingContext memory context =
            IJBMultiTerminal(terminal).accountingContextForTokenOf({projectId: projectId, token: terminalToken});

        // Read the base currency from the ruleset (e.g. ETH=1, USD=2).
        uint32 baseCurrency = ruleset.baseCurrency();

        // Compute the weight ratio: if the terminal currency matches the base currency, use 10^decimals
        // directly; otherwise, convert via the price oracle.
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES()
                .pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });

        // Apply the ruleset weight to convert terminal tokens → project tokens at the current rate.
        projectTokenOutAmount = mulDiv({x: terminalTokenInAmount, y: ruleset.weight, denominator: weightRatio});
    }

    /// @notice Compute Uniswap SqrtPriceX96 for current JuiceboxV4 price.
    /// @param directory The JBDirectory used to resolve the project's primary terminal.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return sqrtPriceX96 The current Juicebox issuance price encoded as a Uniswap V4 sqrtPriceX96.
    function getSqrtPriceX96ForCurrentJuiceboxPrice(
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

        // Use the net issuance rate (after reserved% deduction) so the fallback price
        // reflects the tokens a payer actually receives, not the gross weight.
        uint256 issuanceRate = getIssuanceRate({
            directory: directory,
            projectId: projectId,
            terminalToken: terminalToken,
            controller: controller,
            ruleset: ruleset
        });

        // Guard against zero issuance (e.g. 100% reserved or weight=0) — return an extreme price
        // matching the token ordering convention used by getIssuanceRateSqrtPriceX96.
        if (issuanceRate == 0) {
            return token0 == terminalToken ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE - 1;
        }

        // Compute sqrtPriceX96 directly from the rate, then clamp once to Uniswap's valid sqrt-price range.
        uint256 result;
        if (token0 == terminalToken) {
            result = mulDiv({x: sqrt(issuanceRate), y: _Q96, denominator: sqrt(_WAD)});
        } else {
            result = mulDiv({x: sqrt(_WAD), y: _Q96, denominator: sqrt(issuanceRate)});
        }

        // Clamp to valid Uniswap V4 sqrt price range.
        if (result < uint256(TickMath.MIN_SQRT_PRICE)) return TickMath.MIN_SQRT_PRICE;
        if (result > uint256(TickMath.MAX_SQRT_PRICE - 1)) return TickMath.MAX_SQRT_PRICE - 1;
        // The value was clamped into the uint160 Uniswap sqrt-price range above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(result);
    }

    //*********************************************************************//
    // ------------------------- private views --------------------------- //
    //*********************************************************************//

    /// @notice Look up the primary terminal for a project/token pair.
    /// @param directory The JBDirectory to query.
    /// @param projectId The ID of the project.
    /// @param token The token whose primary terminal to resolve.
    /// @return The project's primary terminal for `token` (address(0) if none is set).
    function _primaryTerminalOf(
        IJBDirectory directory,
        uint256 projectId,
        address token
    )
        private
        view
        returns (address)
    {
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
        if (totalSupply == 0) return 0;

        uint256 cashOutCount = totalSupply < _WAD ? totalSupply : _WAD;
        try store.currentReclaimableSurplusOf({
            projectId: projectId, cashOutCount: cashOutCount, totalSupply: totalSupply, surplus: surplus
        }) returns (
            uint256 reclaimableAmount
        ) {
            if (cashOutCount == _WAD) return reclaimableAmount;
            terminalTokensPerProjectToken = mulDiv({x: reclaimableAmount, y: _WAD, denominator: cashOutCount});
        } catch {
            terminalTokensPerProjectToken = 0;
        }
    }
}
