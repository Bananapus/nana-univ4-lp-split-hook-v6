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
    /// @notice Everything a rolled-back recycle must leave untouched.
    /// @custom:member askId The stored ask position ID.
    /// @custom:member bidId The stored bid position ID.
    /// @custom:member askPosition The ask's encoded mock position (range, liquidity, principal, existence).
    /// @custom:member bidPosition The bid's encoded mock position (range, liquidity, principal, existence).
    /// @custom:member pendingFees The collectable fees, ordered ask0, ask1, bid0, bid1.
    /// @custom:member accumulatedProject The project-token ledger.
    /// @custom:member accumulatedTerminal The terminal-token ledger.
    /// @custom:member accumulatedCredits The project-credit ledger.
    /// @custom:member hookBalances The hook's balances, ordered project, terminal, fee-project.
    /// @custom:member positionManagerBalances The PositionManager's balances, ordered project, terminal.
    /// @custom:member feeTerminalBalance The project terminal's terminal-token balance.
    /// @custom:member approvals The hook's approvals, ordered project->Permit2, terminal->Permit2, Permit2 project->PM,
    /// Permit2 terminal->PM.
    /// @custom:member claimableFeeTokens The project's claimable fee tokens.
    /// @custom:member claimableFeeCredits The project's claimable fee credits.
    /// @custom:member claimableFeeTokenOf The project's claim-token snapshot.
    /// @custom:member outstandingFeeTokenClaims The hook's outstanding fee-token claims for the fee-project token.
    /// @custom:member inflightFeeRouting The hook's in-flight fee-routing count for the fee-project token.
    struct Snapshot {
        uint256 askId;
        uint256 bidId;
        bytes askPosition;
        bytes bidPosition;
        uint256[4] pendingFees;
        uint256 accumulatedProject;
        uint256 accumulatedTerminal;
        uint256 accumulatedCredits;
        uint256[3] hookBalances;
        uint256[2] positionManagerBalances;
        uint256 feeTerminalBalance;
        uint256[4] approvals;
        uint256 claimableFeeTokens;
        uint256 claimableFeeCredits;
        address claimableFeeTokenOf;
        uint256 outstandingFeeTokenClaims;
        uint256 inflightFeeRouting;
    }

    /// @notice The project allocation a reserved distribution delivers during inline automation.
    uint256 internal constant _NEW_ALLOCATION = 7e18;

    /// @notice A cash-out surplus that narrows this fixture's corridor to exactly one tick spacing: a cash-out value
    /// just below the issuance price (1/900 ~= 1.111e15). With the terminal token as token0 the issuance tick (~68,027)
    /// aligns up to 68,200 and the cash-out tick (~68,494) aligns down to 68,400.
    uint256 internal constant _ONE_SPACING_SURPLUS = 1.06e15;

    /// @notice The canonical Permit2 address, where the base fixture etches its Permit2 mock.
    address internal constant _PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice The live ask position's token ID after setup.
    uint256 internal _askId;

    /// @notice The live bid position's token ID after setup.
    uint256 internal _bidId;

    /// @notice Grows the pool into a live ask and bid, then accumulates more project tokens for the next recycle.
    function setUp() public override {
        super.setUp();
        // Two live positions, so every recycle burns both.
        (_askId, _bidId) = _deployTwoPositions();
        // Fresh project inventory, so the recycle has something to place on top of the retired principal.
        _accumulateTokens({projectId: PROJECT_ID, amount: 10e18});
    }

    /// @notice With both positions live, recovered inventory on both sides and fees on both sides, a corridor that no
    /// longer leaves room for either side reverts the whole recycle with the exact NoDeployableLiquidityAtSpot error.
    /// Both burns, the fee routing (including the fee-project cut and its claim credit) and every ledger write roll
    /// back.
    function test_recycle_noDeployableSide_revertsAndRollsBackEverything() public {
        // Leave no deployable room on either side, then snapshot every effect a recycle could have.
        (int24 spotTick, int24 ceilingTick, uint256 projectAmount, uint256 terminalAmount) = _arrangeNoDeployableSide();
        Snapshot memory before = _snapshot();

        // The recycle reverts with the exact spot, ceiling and inventory it could not place.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector,
                spotTick,
                ceilingTick,
                projectAmount,
                terminalAmount
            )
        );
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Every effect rolls back, and both positions stay live.
        assertEq(abi.encode(_snapshot()), abi.encode(before), "the revert rolls back every effect");
        assertGt(positionManager.getPositionLiquidity(_askId), 0, "ask still live");
        assertGt(positionManager.getPositionLiquidity(_bidId), 0, "bid still live");
    }

    /// @notice The same failure during full-gas inline automation: the newly accepted allocation stays accounted for,
    /// the failure is reported, and the old positions (with their pending fees) survive untouched.
    function test_automation_noDeployableSide_keepsPositionsAndAcceptsAllocation() public {
        // Leave no deployable room on either side; the only expected change is the accepted allocation.
        _arrangeNoDeployableSide();
        Snapshot memory expected = _snapshot();
        expected.accumulatedProject += _NEW_ALLOCATION;
        expected.hookBalances[0] += _NEW_ALLOCATION;

        // A full-gas reserved distribution accepts the allocation and reports the failed inline recycle.
        projectToken.mint({to: address(controller), amount: _NEW_ALLOCATION});
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: _NEW_ALLOCATION});
        vm.expectEmit(true, false, false, true, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed({
            projectId: PROJECT_ID,
            reasonSelector: JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector,
            caller: address(controller)
        });
        hook.processSplitWith(_buildReservedContext({projectId: PROJECT_ID, amount: _NEW_ALLOCATION}));
        vm.stopPrank();

        // Nothing else changes: positions, fees, approvals and claims are untouched.
        assertEq(abi.encode(_snapshot()), abi.encode(expected), "only the accepted allocation changed");
    }

    /// @notice A recycle that mints replaces both stored IDs with fresh positions; burned IDs are never kept.
    function test_recycle_replacesBothTokenIds_neverKeepsBurnedIds() public {
        // Recycle the setup's ask and bid.
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Both stored IDs point at fresh live positions, and the previous ones are burned.
        uint256 newAskId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        uint256 newBidId = hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertTrue(newAskId != 0 && newBidId != 0, "both sides re-minted");
        assertTrue(newAskId != _askId && newAskId != _bidId, "ask ID is fresh");
        assertTrue(newBidId != _askId && newBidId != _bidId, "bid ID is fresh");
        assertEq(positionManager.getPositionLiquidity(_askId), 0, "previous ask burned");
        assertEq(positionManager.getPositionLiquidity(_bidId), 0, "previous bid burned");
        assertGt(positionManager.getPositionLiquidity(newAskId), 0, "new ask live");
        assertGt(positionManager.getPositionLiquidity(newBidId), 0, "new bid live");

        // A second recycle retires both again and stores two more new IDs.
        _accumulateTokens({projectId: PROJECT_ID, amount: 10e18});
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The mock mints increasing IDs, so both third-generation IDs exceed every earlier one.
        uint256 thirdAskId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        uint256 thirdBidId = hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
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
        // Raise the cash-out floor until the corridor spans exactly one tick spacing.
        store.setSurplus({projectId: PROJECT_ID, surplus: _ONE_SPACING_SURPLUS});
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

        // Park the spot mid-spacing, so no aligned range fits on either side of it inside the corridor.
        spotTick = corridorLower + hook.TICK_SPACING() / 2;
        _setSpotTick(spotTick);
        assertEq(TickMath.getTickAtSqrtPrice(_spotSqrtPrice()), spotTick, "fixture: spot tick");
        // The issuance ceiling is the corridor's upper bound with the project as token0 and its lower bound otherwise.
        ceilingTick = _projectIsToken0() ? corridorUpper : corridorLower;

        // Re-mark both positions' recorded principal at the new spot so the mock's balances back it.
        _markToSpot(_askId);
        _markToSpot(_bidId);

        // Put fees on both positions, terminal-side fees only on the bid.
        uint256 projectFee = 3e18;
        uint256 terminalFee = 2e18;
        _setFees({tokenId: _askId, projectFee: projectFee, terminalFee: 0});
        _setFees({tokenId: _bidId, projectFee: projectFee, terminalFee: terminalFee});

        // The retired principal covers both sides, so the revert is about room, not inventory.
        (uint256 askProject, uint256 askTerminal) = _sides(_askId);
        (uint256 bidProject, uint256 bidTerminal) = _sides(_bidId);
        assertTrue(askProject + bidProject > 0 && askTerminal + bidTerminal > 0, "fixture: inventory on both sides");

        // The fees leave before the mint: the project-side fees are burned and the terminal-side remainder is added to
        // the project's balance, so the recycle tries to deploy only the ledgers plus the retired principal.
        projectAmount = hook.accumulatedProjectTokens(PROJECT_ID) + askProject + bidProject;
        terminalAmount = hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)})
            + askTerminal + bidTerminal;
    }

    /// @notice A mock position's range, liquidity, principal and existence, encoded for comparison.
    /// @param tokenId The position to read.
    /// @return position The ABI-encoded position fields, without its pool key.
    function _position(uint256 tokenId) internal view returns (bytes memory position) {
        // Skip the pool key: it never changes for a live position, and encoding the rest keeps the comparison flat.
        (, int24 lower, int24 upper, uint128 liquidity, uint256 amount0, uint256 amount1, bool exists) =
            positionManager._positions(tokenId);
        return abi.encode(lower, upper, liquidity, amount0, amount1, exists);
    }

    /// @notice Every effect a recycle could have, read from the hook, the mocks and the hook's raw storage.
    /// @return s The snapshot.
    function _snapshot() internal view returns (Snapshot memory s) {
        // Stored position IDs and their mock positions.
        s.askId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        s.bidId = hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        s.askPosition = _position(s.askId);
        s.bidPosition = _position(s.bidId);
        // Pending fees on both positions.
        s.pendingFees = [
            positionManager.collectableAmount0(s.askId),
            positionManager.collectableAmount1(s.askId),
            positionManager.collectableAmount0(s.bidId),
            positionManager.collectableAmount1(s.bidId)
        ];
        // The project's ledgers.
        s.accumulatedProject = hook.accumulatedProjectTokens(PROJECT_ID);
        s.accumulatedTerminal =
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        s.accumulatedCredits = hook.accumulatedProjectCredits(PROJECT_ID);
        // Token balances on the hook, the PositionManager and the project terminal.
        s.hookBalances = [
            projectToken.balanceOf(address(hook)),
            terminalToken.balanceOf(address(hook)),
            feeProjectToken.balanceOf(address(hook))
        ];
        s.positionManagerBalances =
            [projectToken.balanceOf(address(positionManager)), terminalToken.balanceOf(address(positionManager))];
        s.feeTerminalBalance = terminalToken.balanceOf(address(terminal));
        // ERC-20 approvals to Permit2 and Permit2 allowances to the PositionManager.
        s.approvals = [
            projectToken.allowance({owner: address(hook), spender: _PERMIT2}),
            terminalToken.allowance({owner: address(hook), spender: _PERMIT2}),
            MockPermit2(_PERMIT2).allowances({
                owner: address(hook), token: address(projectToken), spender: address(positionManager)
            }),
            MockPermit2(_PERMIT2).allowances({
                owner: address(hook), token: address(terminalToken), spender: address(positionManager)
            })
        ];
        // Fee-claim state.
        s.claimableFeeTokens = hook.claimableFeeTokens(PROJECT_ID);
        s.claimableFeeCredits = hook.claimableFeeCredits(PROJECT_ID);
        s.claimableFeeTokenOf = hook.claimableFeeTokenOf(PROJECT_ID);
        // Internal reserve counters, read from their mapping slots keyed by the fee-project token.
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
}
