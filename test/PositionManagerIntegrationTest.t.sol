// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Tests validating realistic PositionManager token flows.
/// @dev The improved MockPositionManager tracks locked amounts, owed amounts, and
///      enforces approval/balance during SETTLE. These tests verify the hook's
///      token handling works correctly against that more realistic simulation.
contract PositionManagerIntegrationTest is LPSplitHookV4TestBase {
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

    /// @notice A recycle burns the old ask (returning its locked project AND filled terminal to the hook), then
    /// re-mints a project-only ask and a terminal-only bid, leaving nothing on the hook or in the ledgers.
    function test_Recycle_TokensReturnedAndRedeposited() public {
        _preInitAtMid();
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 oldTokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(oldTokenId, 0, "should have a position");

        // Buyers filled part of the ask: the position now also holds terminal tokens the burn recovers.
        terminalToken.mint(address(positionManager), 5e18);
        positionManager.injectPositionBalance(oldTokenId, address(terminalToken), 5e18);

        uint256 burnsBefore = positionManager.burnCallCount();
        _accumulateTokens(PROJECT_ID, 1e18);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        assertEq(positionManager.burnCallCount(), burnsBefore + 1, "the old ask is burned");
        (,,,,,, bool oldExists) = positionManager._positions(oldTokenId);
        assertFalse(oldExists, "the old ask no longer exists");

        uint256 askId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 bidId = hook.bidTokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(askId != oldTokenId && bidId != oldTokenId && askId != bidId, "fresh, distinct ask and bid ids");
        (uint256 askProject, uint256 askTerminal) = _lockedSides(askId);
        (uint256 bidProject, uint256 bidTerminal) = _lockedSides(bidId);
        assertEq(askProject, 101e18, "the ask re-deposits recovered plus new project tokens");
        assertEq(askTerminal, 0, "the ask holds no terminal");
        assertEq(bidTerminal, 5e18, "the bid re-deposits the recovered terminal");
        assertEq(bidProject, 0, "the bid holds no project token");

        assertEq(projectToken.balanceOf(address(hook)), 0, "no project tokens left on the hook");
        assertEq(terminalToken.balanceOf(address(hook)), 0, "no terminal tokens left on the hook");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "project ledger fully minted");
        assertEq(hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)), 0, "terminal ledger fully minted");
    }

    // ─── Fee collection: fees transfer from PM to hook ───────────────

    /// @notice collectAndRouteLPFees should collect fees from PM and route them.
    function test_FeeCollection_FeesTransferFromPM() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 tokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));

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

    // ─── Deploy: conservation — no tokens created from thin air ──────

    /// @notice The total token supply across hook + PM should be conserved during deploy.
    ///         (Minus any tokens burned by the hook.)
    function test_Deploy_TokenConservation() public {
        uint256 accumAmount = 100e18;
        _accumulateTokens(PROJECT_ID, accumAmount);

        // Record total supply across hook + PM + terminal (terminal may receive cash-out tokens).
        uint256 totalProjectBefore = projectToken.balanceOf(address(hook))
            + projectToken.balanceOf(address(positionManager)) + projectToken.balanceOf(address(terminal));
        uint256 totalTermBefore = terminalToken.balanceOf(address(hook))
            + terminalToken.balanceOf(address(positionManager)) + terminalToken.balanceOf(address(terminal));

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        uint256 totalProjectAfter = projectToken.balanceOf(address(hook))
            + projectToken.balanceOf(address(positionManager)) + projectToken.balanceOf(address(terminal));
        uint256 totalTermAfter = terminalToken.balanceOf(address(hook))
            + terminalToken.balanceOf(address(positionManager)) + terminalToken.balanceOf(address(terminal));

        // Project tokens may decrease (burned by _handleLeftoverTokens), but never increase.
        assertLe(totalProjectAfter, totalProjectBefore, "Project tokens should not be created");
        // Terminal tokens are minted by mock terminal during cash-out, so they can increase.
        // But they should never be lost (terminal tokens across all contracts >= before).
        assertGe(totalTermAfter, totalTermBefore, "Terminal tokens should not be destroyed");
    }

    // ─── Recycle with fees: full cycle collect → route → burn → mint ─

    /// @notice End-to-end recycle with accumulated fees exercises the full token flow: collect fees → route the
    /// fee-project cut → burn → mint, with the terminal-fee remainder re-minted as the bid.
    function test_Recycle_FullCycleWithFees() public {
        _preInitAtMid();
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 tokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));

        // Configure terminal-side fees on the old position and fund the PM to pay them.
        (address token0,) = _sortTokens(address(projectToken), address(terminalToken));
        uint256 termFee = 3e18;
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees(tokenId, termFee, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, termFee);
        }
        terminalToken.mint(address(positionManager), termFee);

        uint256 payBefore = terminal.payCallCount();
        uint256 addBefore = terminal.addToBalanceCallCount();
        uint256 terminalHeldBefore = terminalToken.balanceOf(address(terminal));

        _accumulateTokens(PROJECT_ID, 1e18);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        // The fee-project cut was paid; nothing was deposited into the project's treasury.
        assertEq(terminal.payCallCount(), payBefore + 1, "the fee-project cut is paid");
        assertEq(terminal.addToBalanceCallCount(), addBefore, "fees are never deposited into the treasury");
        uint256 feeCut = terminalToken.balanceOf(address(terminal)) - terminalHeldBefore;
        assertGt(feeCut, 0, "a nonzero cut left the hook");

        // The remainder is the new bid; the ask re-mints every project token.
        uint256 newTokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(newTokenId, tokenId, "New position should be minted");
        (uint256 askProject, uint256 askTerminal) = _lockedSides(newTokenId);
        (uint256 bidProject, uint256 bidTerminal) = _lockedSides(hook.bidTokenIdOf(PROJECT_ID, address(terminalToken)));
        assertEq(askProject, 101e18, "the ask holds every project token");
        assertEq(askTerminal, 0, "the ask holds no terminal");
        assertEq(bidTerminal, termFee - feeCut, "the bid holds exactly the fee remainder");
        assertEq(bidProject, 0, "the bid holds no project token");
        assertEq(terminalToken.balanceOf(address(hook)), 0, "no terminal stranded on the hook");
    }

    // ─── Deploy: partial usage — sweep returns unused tokens ─────────

    /// @notice When the PositionManager only uses a fraction of provided tokens,
    ///         SWEEP should return the unused portion to the hook.
    function test_Deploy_PartialUsage_SweepReturnsLeftover() public {
        // Configure PM to only use 80% of provided amounts.
        positionManager.setUsagePercent(8000);

        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // Position should still be created successfully.
        uint256 tokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(tokenId, 0, "Position should be created even with partial usage");

        // SWEEP returned the unused 20% and the ledger carries it forward for the next recycle.
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 20e18, "the unused 20% returns to the ledger");
        assertEq(projectToken.balanceOf(address(hook)), 20e18, "the swept leftover is held by the hook");
    }

    // ─── Helper
    // ──────────────────────────────────────────────────────

    /// @notice Pre-initialize the pool mid-corridor so the recycle has room for both an ask and a bid around spot
    /// (a hook-seeded pool sits one spacing inside the cash-out floor, leaving no bid range).
    function _preInitAtMid() internal {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});
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
        (address token0, address token1) = _sortTokens(address(projectToken), address(terminalToken));
        positionManager.initializePool(
            PoolKey({
                currency0: Currency.wrap(token0),
                currency1: Currency.wrap(token1),
                fee: hook.POOL_FEE(),
                tickSpacing: hook.TICK_SPACING(),
                hooks: hook.oracleHook()
            }),
            TickMath.getSqrtPriceAtTick(corridorLower + (corridorUpper - corridorLower) / 2)
        );
    }

    /// @notice A position's locked (project, terminal) amounts.
    function _lockedSides(uint256 tokenId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(tokenId);
        (projectSide, terminalSide) = address(projectToken) < address(terminalToken)
            ? (amount0Locked, amount1Locked)
            : (amount1Locked, amount0Locked);
    }

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
