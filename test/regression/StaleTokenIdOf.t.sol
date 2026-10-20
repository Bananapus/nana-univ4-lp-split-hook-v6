// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBUniswapV4LPSplitHook} from "../../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {MockPermit2} from "../TestBaseV4.sol";
import {TwoPositionFixture} from "./TwoPositionFixture.sol";

/// @notice The stored position IDs become stale when a recycle burns the live positions but mints nothing.
/// @dev A recycle that cannot mint either side reverts with NoDeployableLiquidityAtSpot, rolling back both burns, the
///      fee routing and every ledger write, rather than leaving askTokenIdOf/bidTokenIdOf zeroed (or pointing at burned
///      positions) while the project is marked deployed, which would brick it. A recycle that does mint replaces BOTH
///      stored IDs with fresh ones and never keeps a burned ID.
contract StaleTokenIdOfTest is TwoPositionFixture {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice A cash-out surplus that narrows this fixture's corridor to exactly one tick spacing: a cash-out value
    /// just below the issuance price (1/900 ~= 1.111e15). With the terminal token as token0 the issuance tick (~68,027)
    /// aligns up to 68,200 and the cash-out tick (~68,494) aligns down to 68,400.
    uint256 internal constant ONE_SPACING_SURPLUS = 1.06e15;

    uint256 internal constant NEW_ALLOCATION = 7e18;

    uint256 internal askId;
    uint256 internal bidId;

    /// @notice Everything a rolled-back recycle must leave untouched.
    struct Snapshot {
        uint256 askId;
        uint256 bidId;
        bytes askPosition;
        bytes bidPosition;
        uint256[4] pendingFees; // ask0, ask1, bid0, bid1
        uint256 accumulatedProject;
        uint256 accumulatedTerminal;
        uint256 accumulatedCredits;
        uint256[3] hookBalances; // project, terminal, fee-project
        uint256[2] positionManagerBalances; // project, terminal
        uint256 feeTerminalBalance;
        uint256[4] approvals; // project->Permit2, terminal->Permit2, Permit2 project->PM, Permit2 terminal->PM
        uint256 claimableFeeTokens;
        uint256 claimableFeeCredits;
        address claimableFeeTokenOf;
        uint256 outstandingFeeTokenClaims;
        uint256 inflightFeeRouting;
    }

    function setUp() public override {
        super.setUp();
        (askId, bidId) = _deployTwoPositions();
        _accumulateTokens(PROJECT_ID, 10e18);
    }

    /// @notice With both positions live, recovered inventory on both sides and fees on both sides, a corridor that no
    /// longer leaves room for either side reverts the whole recycle with the exact NoDeployableLiquidityAtSpot error.
    /// Both burns, the fee routing (including the fee-project cut and its claim credit) and every ledger write roll
    /// back.
    function test_recycle_noDeployableSide_revertsAndRollsBackEverything() public {
        (int24 spotTick, int24 ceilingTick, uint256 projectAmount, uint256 terminalAmount) = _arrangeNoDeployableSide();
        Snapshot memory before = _snapshot();

        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector,
                spotTick,
                ceilingTick,
                projectAmount,
                terminalAmount
            )
        );
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        assertEq(abi.encode(_snapshot()), abi.encode(before), "the revert rolls back every effect");
        assertGt(positionManager.getPositionLiquidity(askId), 0, "ask still live");
        assertGt(positionManager.getPositionLiquidity(bidId), 0, "bid still live");
    }

    /// @notice The same failure during full-gas inline automation: the newly accepted allocation stays accounted for,
    /// the failure is reported, and the old positions (with their pending fees) survive untouched.
    function test_automation_noDeployableSide_keepsPositionsAndAcceptsAllocation() public {
        _arrangeNoDeployableSide();
        Snapshot memory expected = _snapshot();
        expected.accumulatedProject += NEW_ALLOCATION;
        expected.hookBalances[0] += NEW_ALLOCATION;

        projectToken.mint(address(controller), NEW_ALLOCATION);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), NEW_ALLOCATION);
        vm.expectEmit(true, false, false, true, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed({
            projectId: PROJECT_ID,
            reasonSelector: JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector,
            caller: address(controller)
        });
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, NEW_ALLOCATION));
        vm.stopPrank();

        assertEq(abi.encode(_snapshot()), abi.encode(expected), "only the accepted allocation changed");
    }

    /// @notice A recycle that mints replaces both stored IDs with fresh positions; burned IDs are never kept.
    function test_recycle_replacesBothTokenIds_neverKeepsBurnedIds() public {
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        uint256 newAskId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 newBidId = hook.bidTokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newAskId != 0 && newBidId != 0, "both sides re-minted");
        assertTrue(newAskId != askId && newAskId != bidId, "ask ID is fresh");
        assertTrue(newBidId != askId && newBidId != bidId, "bid ID is fresh");
        assertEq(positionManager.getPositionLiquidity(askId), 0, "previous ask burned");
        assertEq(positionManager.getPositionLiquidity(bidId), 0, "previous bid burned");
        assertGt(positionManager.getPositionLiquidity(newAskId), 0, "new ask live");
        assertGt(positionManager.getPositionLiquidity(newBidId), 0, "new bid live");

        // A second recycle retires both again and stores two more new IDs.
        _accumulateTokens(PROJECT_ID, 10e18);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        uint256 thirdAskId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 thirdBidId = hook.bidTokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(thirdAskId > newBidId && thirdBidId > newBidId, "both IDs fresh again");
        assertEq(positionManager.getPositionLiquidity(newAskId), 0, "second ask burned");
        assertEq(positionManager.getPositionLiquidity(newBidId), 0, "second bid burned");
    }

    /// @notice Narrow the corridor to one spacing, park the spot strictly inside it (so neither the token0 range above
    /// nor the token1 range below has room), mark both positions to that spot and put fees on both.
    /// @return spotTick The spot tick the error reports.
    /// @return ceilingTick The issuance-ceiling bound the error reports.
    /// @return projectAmount Every project token the recycle would try to deploy.
    /// @return terminalAmount Every terminal token the recycle would try to deploy.
    function _arrangeNoDeployableSide()
        internal
        returns (int24 spotTick, int24 ceilingTick, uint256 projectAmount, uint256 terminalAmount)
    {
        store.setSurplus(PROJECT_ID, ONE_SPACING_SURPLUS);
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
        assertEq(corridorUpper - corridorLower, hook.TICK_SPACING(), "fixture: one-spacing corridor");

        spotTick = corridorLower + hook.TICK_SPACING() / 2;
        _setSpotTick(spotTick);
        assertEq(TickMath.getTickAtSqrtPrice(_spotSqrtPrice()), spotTick, "fixture: spot tick");
        ceilingTick = _projectIsToken0() ? corridorUpper : corridorLower;

        _markToSpot(askId);
        _markToSpot(bidId);

        uint256 projectFee = 3e18;
        uint256 terminalFee = 2e18;
        _setFees(askId, projectFee, 0);
        _setFees(bidId, projectFee, terminalFee);

        (uint256 askProject, uint256 askTerminal) = _sides(askId);
        (uint256 bidProject, uint256 bidTerminal) = _sides(bidId);
        assertTrue(askProject + bidProject > 0 && askTerminal + bidTerminal > 0, "fixture: inventory on both sides");

        // The fees leave before the mint: the project-side fees are burned and the terminal-side remainder is added to
        // the project's balance, so the recycle tries to deploy only the ledgers plus the retired principal.
        projectAmount = hook.accumulatedProjectTokens(PROJECT_ID) + askProject + bidProject;
        terminalAmount = hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)) + askTerminal + bidTerminal;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.askId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        s.bidId = hook.bidTokenIdOf(PROJECT_ID, address(terminalToken));
        s.askPosition = _position(s.askId);
        s.bidPosition = _position(s.bidId);
        s.pendingFees = [
            positionManager.collectableAmount0(s.askId),
            positionManager.collectableAmount1(s.askId),
            positionManager.collectableAmount0(s.bidId),
            positionManager.collectableAmount1(s.bidId)
        ];
        s.accumulatedProject = hook.accumulatedProjectTokens(PROJECT_ID);
        s.accumulatedTerminal = hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken));
        s.accumulatedCredits = hook.accumulatedProjectCredits(PROJECT_ID);
        s.hookBalances = [
            projectToken.balanceOf(address(hook)),
            terminalToken.balanceOf(address(hook)),
            feeProjectToken.balanceOf(address(hook))
        ];
        s.positionManagerBalances =
            [projectToken.balanceOf(address(positionManager)), terminalToken.balanceOf(address(positionManager))];
        s.feeTerminalBalance = terminalToken.balanceOf(address(terminal));
        s.approvals = [
            projectToken.allowance(address(hook), PERMIT2),
            terminalToken.allowance(address(hook), PERMIT2),
            MockPermit2(PERMIT2).allowances(address(hook), address(projectToken), address(positionManager)),
            MockPermit2(PERMIT2).allowances(address(hook), address(terminalToken), address(positionManager))
        ];
        s.claimableFeeTokens = hook.claimableFeeTokens(PROJECT_ID);
        s.claimableFeeCredits = hook.claimableFeeCredits(PROJECT_ID);
        s.claimableFeeTokenOf = hook.claimableFeeTokenOf(PROJECT_ID);
        s.outstandingFeeTokenClaims = uint256(
            vm.load(
                address(hook),
                keccak256(abi.encode(address(feeProjectToken), uint256(SLOT_OUTSTANDING_FEE_TOKEN_CLAIMS)))
            )
        );
        s.inflightFeeRouting = uint256(
            vm.load(
                address(hook), keccak256(abi.encode(address(feeProjectToken), uint256(SLOT_INFLIGHT_FEE_ROUTING_COUNT)))
            )
        );
    }

    function _position(uint256 tokenId) internal view returns (bytes memory) {
        (, int24 lower, int24 upper, uint128 liquidity, uint256 amount0, uint256 amount1, bool exists) =
            positionManager._positions(tokenId);
        return abi.encode(lower, upper, liquidity, amount0, amount1, exists);
    }
}
