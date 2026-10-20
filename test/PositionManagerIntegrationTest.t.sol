// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TwoPositionFixture} from "./regression/TwoPositionFixture.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Tests validating realistic PositionManager token flows.
/// @dev MockPositionManager follows V4's PositionManager: exact-liquidity mints priced at the live spot, per-currency
///      deltas that must settle, and SWEEP of its whole loose balance. These tests verify the hook's token handling
///      against it.
contract PositionManagerIntegrationTest is TwoPositionFixture {
    // ─── Deploy: tokens flow from hook → PositionManager via SETTLE ──

    /// @notice After deployPool, project tokens should be pulled from the hook
    ///         into the PositionManager (locked in the LP position).
    function test_Deploy_TokensTransferredToPositionManager() public {
        uint256 accumAmount = 100e18;
        _accumulateTokens(PROJECT_ID, accumAmount);

        uint256 hookProjectBefore = projectToken.balanceOf(address(hook));
        uint256 pmProjectBefore = projectToken.balanceOf(address(positionManager));

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        uint256 hookProjectAfter = projectToken.balanceOf(address(hook));
        uint256 pmProjectAfter = projectToken.balanceOf(address(positionManager));

        // Hook should have fewer project tokens (they went to PM).
        assertLt(hookProjectAfter, hookProjectBefore, "Hook should transfer project tokens to PM");
        // PM should have received project tokens.
        assertGt(pmProjectAfter, pmProjectBefore, "PM should receive project tokens");
    }

    // ─── Deploy: single-sided — no terminal tokens flow to PM ────────

    /// @notice After deployPool, the hook mints a single-sided ask from accumulated project tokens only: there is
    /// no funding cash-out, so PM never receives any terminal tokens from the deploy.
    function test_Deploy_NoTerminalTokensFlowToPM() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        uint256 pmTermBefore = terminalToken.balanceOf(address(positionManager));

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        uint256 pmTermAfter = terminalToken.balanceOf(address(positionManager));

        // PM should receive ZERO terminal tokens — the deploy is single-sided (asks-only).
        assertEq(pmTermAfter, pmTermBefore, "PM should never receive terminal tokens from a single-sided deploy");
        assertEq(terminal.cashOutCallCount(), 0, "deployPool must never call cashOutTokensOf");
    }

    // ─── Recycle: burn returns tokens, then re-mints both sides ──────

    /// @notice A recycle burns the old ask (returning its project AND filled terminal to the hook), then re-mints a
    /// project-only ask and a terminal-only bid, leaving on the hook only what those mints did not cost, ledgered.
    function test_Recycle_TokensReturnedAndRedeposited() public {
        // Seed the pool mid-corridor so the recycle has room for a bid below spot.
        _preInitAtMid();
        _accumulateAndDeploy({projectId: PROJECT_ID, amount: 100e18});

        // The deploy mints the ask the recycle burns.
        uint256 oldTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(oldTokenId, 0, "should have a position");

        // Buyers filled part of the ask: the price moved into its range, so the burn also recovers terminal tokens.
        _fillHalfOf(oldTokenId);
        (uint256 recoveredProject, uint256 recoveredTerminal) = _sides(oldTokenId);

        // Snapshot the burn count so the assertion isolates the recycle's burn.
        uint256 burnsBefore = positionManager.burnCallCount();
        // Accumulate fresh inventory so the recycle has something to add.
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        // The re-minted ask may place the recovered project principal plus the whole project ledger.
        uint256 projectIn = recoveredProject + hook.accumulatedProjectTokens(PROJECT_ID);
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The recycle burns the old ask exactly once and the mock drops it.
        assertEq(positionManager.burnCallCount(), burnsBefore + 1, "the old ask is burned");
        (,,,,,, bool oldExists) = positionManager._positions(oldTokenId);
        assertFalse(oldExists, "the old ask no longer exists");

        // The recycle mints a fresh ask and a fresh bid, distinct from each other and from the burned position.
        uint256 askId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        uint256 bidId = hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertTrue(askId != oldTokenId && bidId != oldTokenId && askId != bidId, "fresh, distinct ask and bid ids");
        assertGt(bidId, 0, "the recovered terminal mints a bid");
        // Both positions hold exactly what their liquidity costs at spot, from the inventory the recycle had.
        _assertPlacedExactly(PROJECT_ID, address(projectToken), address(terminalToken), projectIn, recoveredTerminal);

        // Whatever the mints did not cost stays on the hook and is fully ledgered.
        assertEq(
            projectToken.balanceOf(address(hook)),
            hook.accumulatedProjectTokens(PROJECT_ID),
            "the hook holds exactly its project ledger"
        );
        assertEq(
            terminalToken.balanceOf(address(hook)),
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            "the hook holds exactly its terminal ledger"
        );
    }

    // ─── Fee collection: fees transfer from PM to hook ───────────────

    /// @notice collectAndRouteLPFees should collect fees from PM and route them.
    function test_FeeCollection_FeesTransferFromPM() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        // The deploy mints the ask that accrues the fees.
        uint256 tokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Sort tokens to know which is currency0/currency1.
        (address token0,) = _sortTokens(address(projectToken), address(terminalToken));

        uint256 feeAmount = 5e18;
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees(tokenId, feeAmount, 0);
            terminalToken.mint(address(positionManager), feeAmount);
        } else {
            positionManager.setCollectableFees(tokenId, 0, feeAmount);
            terminalToken.mint(address(positionManager), feeAmount);
        }

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Fees should have been routed (hook balance may not increase because fees
        // get forwarded to fee project + original project, but the terminal's
        // pay/addToBalance counts should reflect routing).
        bool feesProcessed = terminal.payCallCount() > 0 || terminal.addToBalanceCallCount() > 0;
        assertTrue(feesProcessed, "Fee routing should call pay or addToBalance");
    }

    // ─── Deploy: conservation — no tokens created or lost ──────

    /// @notice A deploy is fee-free and single-sided: every accumulated project token moves from the hook into the
    ///         ask (or stays in the ledger), and no terminal token moves anywhere.
    function test_Deploy_TokenConservation() public {
        uint256 accumAmount = 100e18;
        _accumulateTokens({projectId: PROJECT_ID, amount: accumAmount});

        // Record total supply across hook + PM + terminal.
        uint256 totalProjectBefore = projectToken.balanceOf(address(hook))
            + projectToken.balanceOf(address(positionManager)) + projectToken.balanceOf(address(terminal));
        uint256 totalTermBefore = terminalToken.balanceOf(address(hook))
            + terminalToken.balanceOf(address(positionManager)) + terminalToken.balanceOf(address(terminal));
        // The accumulated tokens are the whole project supply, so the conservation check covers all of it.
        assertEq(totalProjectBefore, accumAmount, "precondition: the only project tokens are the accumulated ones");

        // Deploy as the owner, which mints the single-sided ask.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // Re-total the same three holders after the deploy.
        uint256 totalProjectAfter = projectToken.balanceOf(address(hook))
            + projectToken.balanceOf(address(positionManager)) + projectToken.balanceOf(address(terminal));
        uint256 totalTermAfter = terminalToken.balanceOf(address(hook))
            + terminalToken.balanceOf(address(positionManager)) + terminalToken.balanceOf(address(terminal));

        // Neither token is created or destroyed across the holders.
        assertEq(totalProjectAfter, totalProjectBefore, "a fee-free deploy neither creates nor loses project tokens");
        assertEq(totalTermAfter, totalTermBefore, "a single-sided deploy moves no terminal tokens");

        // Every accumulated project token is in the ask or still ledgered on the hook, and the hook holds exactly its
        // ledger.
        (uint256 askProject, uint256 askTerminal) =
            _sides(hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}));
        uint256 ledger = hook.accumulatedProjectTokens(PROJECT_ID);
        assertEq(askProject + ledger, accumAmount, "the ask plus the ledger hold every accumulated project token");
        assertEq(askTerminal, 0, "the ask holds no terminal");
        assertEq(projectToken.balanceOf(address(positionManager)), askProject, "the PositionManager holds the ask");
        assertEq(projectToken.balanceOf(address(hook)), ledger, "the hook holds exactly its ledger");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "no terminal ledgered"
        );
    }

    // ─── Recycle with fees: full cycle collect → route → burn → mint ─

    /// @notice End-to-end recycle with accumulated fees exercises the full token flow: collect fees → route the
    /// fee-project cut → add the terminal-fee remainder to the project's balance → burn → mint.
    function test_Recycle_FullCycleWithFees() public {
        // Seed the pool mid-corridor so the recycle's spot sits inside the corridor.
        _preInitAtMid();
        _accumulateAndDeploy({projectId: PROJECT_ID, amount: 100e18});

        // The deploy mints the ask that accrues the fees.
        uint256 tokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Configure terminal-side fees on the old position and fund the PM to pay them.
        (address token0,) = _sortTokens({tokenA: address(projectToken), tokenB: address(terminalToken)});
        uint256 termFee = 3e18;
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees({tokenId: tokenId, amount0: termFee, amount1: 0});
        } else {
            positionManager.setCollectableFees({tokenId: tokenId, amount0: 0, amount1: termFee});
        }
        terminalToken.mint({to: address(positionManager), amount: termFee});

        // Snapshot the terminal's call counts and balance so the assertions isolate the recycle's routing.
        uint256 payBefore = terminal.payCallCount();
        uint256 addBefore = terminal.addToBalanceCallCount();
        uint256 terminalHeldBefore = terminalToken.balanceOf(address(terminal));

        // Accumulate fresh inventory so the recycle has something to add.
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        // The unfilled ask holds only project tokens, so both principal sides sum to the recovered project amount.
        (uint256 recovered0, uint256 recovered1) = _principalAtSpot(tokenId);
        uint256 projectIn = recovered0 + recovered1 + hook.accumulatedProjectTokens(PROJECT_ID);
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The fee-project cut was paid and the remainder added to the project's balance (the two share a terminal).
        uint256 feeCut = termFee * FEE_PERCENT / 10_000;
        assertEq(terminal.payCallCount(), payBefore + 1, "the fee-project cut is paid");
        assertEq(terminal.lastPayAmount(), feeCut, "the cut");
        assertEq(terminal.addToBalanceCallCount(), addBefore + 1, "the remainder is added to the project's balance");
        assertEq(terminal.lastAddToBalanceAmount(), termFee - feeCut, "the remainder");
        assertEq(terminalToken.balanceOf(address(terminal)) - terminalHeldBefore, termFee, "every fee left the hook");

        // With no terminal principal and the fee gone to the treasury, the recycle mints only the ask.
        uint256 newTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(newTokenId, tokenId, "New position should be minted");
        assertEq(
            hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "no terminal inventory, no bid"
        );
        _assertPlacedExactly(PROJECT_ID, address(projectToken), address(terminalToken), projectIn, 0);
        // Any terminal left on the hook is mint rounding, and it is ledgered.
        assertEq(
            terminalToken.balanceOf(address(hook)),
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            "no terminal stranded on the hook beyond its ledgered rounding"
        );
    }

    // ─── Mint: SWEEP returns the PositionManager's loose balance ─────

    /// @notice Like V4's, the PositionManager's SWEEP moves its whole loose balance of a currency (anything that is not
    /// pool reserves) to the hook. Tokens left on the PositionManager reach the hook through both sweeps of a mint;
    /// the pool keeps exactly the ask's cost.
    function test_Deploy_SweepReturnsLooseManagerBalance() public {
        _accumulateTokens({projectId: PROJECT_ID, amount: 100e18});
        // Leave loose tokens of both currencies on the PositionManager, outside any pool reserves.
        uint256 looseProject = 7e18;
        uint256 looseTerminal = 3e18;
        projectToken.mint({to: address(positionManager), amount: looseProject});
        terminalToken.mint({to: address(positionManager), amount: looseTerminal});

        // Deploy as the owner, which mints the ask and sweeps both currencies.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // The ask's reserves are exactly what its liquidity costs, and none of it is terminal.
        uint256 askId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        uint256 cost = _projectCost(askId);
        (uint256 askProject, uint256 askTerminal) = _sides(askId);
        assertEq(askProject, cost, "the ask's reserves are exactly its cost");
        assertEq(askTerminal, 0, "the ask holds no terminal");

        // Source: the PositionManager keeps only the pool's reserves.
        assertEq(projectToken.balanceOf(address(positionManager)), cost, "loose project tokens swept off the PM");
        assertEq(terminalToken.balanceOf(address(positionManager)), 0, "loose terminal tokens swept off the PM");
        // Destination: the hook receives every swept token on top of its unspent inventory.
        assertEq(
            projectToken.balanceOf(address(hook)),
            100e18 - cost + looseProject,
            "the hook holds its unspent inventory plus the swept project tokens"
        );
        assertEq(terminalToken.balanceOf(address(hook)), looseTerminal, "the hook received the swept terminal tokens");
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            100e18 - cost + looseProject,
            "the swept project tokens are carried in the ledger"
        );
    }

    // ─── Helper
    // ──────────────────────────────────────────────────────

    /// @notice Pre-initialize the pool mid-corridor so the recycle has room for both an ask and a bid around spot
    /// (a hook-seeded pool sits one spacing inside the cash-out floor, leaving no bid range).
    function _preInitAtMid() internal {
        // Widen the cash-out curve so the corridor spans enough ticks for both positions.
        _setWideTaxedCurve(PROJECT_ID);
        // Compute the corridor with the same math and inputs the hook uses.
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (int24 corridorLower, int24 corridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
        // Initialize the hook's pool key at the corridor midpoint before the hook can seed its own price.
        (address token0, address token1) = _sortTokens({tokenA: address(projectToken), tokenB: address(terminalToken)});
        positionManager.initializePool({
            key: PoolKey({
                currency0: Currency.wrap(token0),
                currency1: Currency.wrap(token1),
                fee: hook.POOL_FEE(),
                tickSpacing: hook.TICK_SPACING(),
                hooks: hook.oracleHook()
            }),
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(corridorLower + (corridorUpper - corridorLower) / 2)
        });
    }

    /// @notice The project-side cost of minting `tokenId`'s liquidity at the live spot.
    /// @param tokenId The position to price.
    /// @return cost The project-token amount the position's liquidity costs at spot, rounded up.
    function _projectCost(uint256 tokenId) internal view returns (uint256 cost) {
        // Price the position's liquidity at the live spot, rounding up like a mint.
        (uint256 cost0, uint256 cost1) = _mintCostAtSpot(tokenId);
        // Pick the side that holds the project token.
        return _projectIsToken0() ? cost0 : cost1;
    }

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
