// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {TwoPositionFixture} from "./TwoPositionFixture.sol";

/// @notice Every recycle burns both live positions with a contract-derived floor of 95% of each position's principal
/// at the live price, per side. A burn returning even one unit less on either side of either position reverts the
/// whole recycle; returning exactly the floor is accepted.
contract BurnSlippageFloorTest is TwoPositionFixture {
    /// @custom:member ask0 The token0 minimum a recycle passes for the ask's burn.
    /// @custom:member ask1 The token1 minimum a recycle passes for the ask's burn.
    /// @custom:member bid0 The token0 minimum a recycle passes for the bid's burn.
    /// @custom:member bid1 The token1 minimum a recycle passes for the bid's burn.
    struct Floors {
        uint256 ask0;
        uint256 ask1;
        uint256 bid0;
        uint256 bid1;
    }

    /// @notice The live ask position's token ID after setup.
    uint256 internal _askId;

    /// @notice The live bid position's token ID after setup.
    uint256 internal _bidId;

    /// @notice Deploys the pool and grows it into a live ask and a live bid.
    function setUp() public override {
        super.setUp();
        // Every test starts from two live positions, so a recycle burns both.
        (_askId, _bidId) = _deployTwoPositions();
    }

    /// @notice Both positions sit out of range at the live spot (one above it, one below), so each floor is one-sided
    /// and equals 95% of an independently computed principal.
    function test_floor_isNinetyFivePercentOfLivePrincipal_outOfRange() public {
        // Compute each position's principal at the spot independently of the hook.
        (uint256 ask0, uint256 ask1) = _principalAtSpot(_askId);
        (uint256 bid0, uint256 bid1) = _principalAtSpot(_bidId);
        // Each position holds exactly one currency, and the two hold opposite ones.
        assertTrue((ask0 == 0) != (ask1 == 0), "ask is single-sided at the spot");
        assertTrue((bid0 == 0) != (bid1 == 0), "bid is single-sided at the spot");
        assertTrue((ask0 == 0) == (bid1 == 0), "ask and bid hold opposite currencies");

        // Every floor the recycle passes is 95% of that side's principal, rounded down.
        Floors memory f = _recordFloors();
        assertEq(f.ask0, ask0 * 9500 / 10_000, "ask floor0");
        assertEq(f.ask1, ask1 * 9500 / 10_000, "ask floor1");
        assertEq(f.bid0, bid0 * 9500 / 10_000, "bid floor0");
        assertEq(f.bid1, bid1 * 9500 / 10_000, "bid floor1");
    }

    /// @notice The spot inside the ask's range: the ask holds both currencies and both of its floors are nonzero.
    function test_floor_isNinetyFivePercentOfLivePrincipal_inRange() public {
        // Put the spot inside the ask so it holds both currencies.
        _moveSpotIntoAsk();
        (uint256 ask0, uint256 ask1) = _principalAtSpot(_askId);
        assertTrue(ask0 > 0 && ask1 > 0, "ask is in range");

        // Both of the ask's floors are 95% of its principal on that side, rounded down.
        Floors memory f = _recordFloors();
        assertEq(f.ask0, ask0 * 9500 / 10_000, "ask floor0");
        assertEq(f.ask1, ask1 * 9500 / 10_000, "ask floor1");
    }

    /// @notice An out-of-range ask burn returning one unit below its floor reverts the whole recycle.
    function test_askOneBelowFloor_revertsAtomically() public {
        // Read the floors, then short the ask's burn by one unit on its nonzero side.
        Floors memory f = _recordFloors();
        _assertShortByOneReverts({tokenId: _askId, floor0: f.ask0, floor1: f.ask1});
    }

    /// @notice An out-of-range bid burn returning one unit below its floor reverts the whole recycle.
    function test_bidOneBelowFloor_revertsAtomically() public {
        // Read the floors, then short the bid's burn by one unit on its nonzero side.
        Floors memory f = _recordFloors();
        _assertShortByOneReverts({tokenId: _bidId, floor0: f.bid0, floor1: f.bid1});
    }

    /// @notice An in-range ask burn returning one unit below either of its floors reverts the whole recycle.
    function test_inRangeAskOneBelowEitherFloor_revertsAtomically() public {
        // Put the spot inside the ask so both of its floors are nonzero, then short each side in turn.
        _moveSpotIntoAsk();
        Floors memory f = _recordFloors();
        _assertShortByOneReverts({tokenId: _askId, floor0: f.ask0, floor1: f.ask1});
    }

    /// @notice Out-of-range burns returning exactly their floors let the recycle succeed and conserve tokens.
    function test_burnsReturningExactlyTheFloor_areAccepted() public {
        // Return exactly each floor from the out-of-range positions.
        _assertExactFloorsAccepted();
    }

    /// @notice In-range burns returning exactly their floors let the recycle succeed and conserve tokens.
    function test_inRangeBurnsReturningExactlyTheFloor_areAccepted() public {
        // Put the spot inside the ask, then return exactly each floor.
        _moveSpotIntoAsk();
        _assertExactFloorsAccepted();
    }

    /// @notice A principal whose 95% floor exceeds uint128 reverts rather than wrapping to a smaller floor.
    function test_floorOverflowingUint128_reverts() public {
        // Find the position whose principal at maximal liquidity yields a floor above uint128.
        uint128 maxLiquidity = type(uint128).max;
        uint256 overflowing;
        for (uint256 i; i < 2; i++) {
            // Check the ask first, then the bid.
            uint256 tokenId = i == 0 ? _askId : _bidId;
            (, int24 lower, int24 upper,,,,) = positionManager._positions(tokenId);
            (uint256 amount0, uint256 amount1) =
                _principalAt({sqrtPriceX96: _spotSqrtPrice(), lower: lower, upper: upper, liquidity: maxLiquidity});
            // Only the larger side can overflow, so test its 95% floor against the uint128 range.
            if ((amount0 > amount1 ? amount0 : amount1) * 9500 / 10_000 > type(uint128).max) overflowing = tokenId;
        }
        assertNotEq(overflowing, 0, "fixture: one position's floor can overflow");
        // Give that position maximal liquidity so its derived floor overflows.
        positionManager.setPositionLiquidity({tokenId: overflowing, liquidity: maxLiquidity});

        // The recycle reverts on the overflowing floor instead of truncating it.
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_AmountExceedsUint128.selector);
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Both positions stay in place.
        assertEq(hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}), _askId, "ask kept");
        assertEq(hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}), _bidId, "bid kept");
    }

    /// @notice Every burn returns exactly its floor: the recycle succeeds and redeploys exactly what was recovered.
    function _assertExactFloorsAccepted() internal {
        // Read the floors, then make each burn return exactly them.
        Floors memory f = _recordFloors();
        _returnExactly({tokenId: _askId, amount0: f.ask0, amount1: f.ask1});
        _returnExactly({tokenId: _bidId, amount0: f.bid0, amount1: f.bid1});
        // Total what the recycle has to redeploy per side: both burns' floors plus the accumulated ledger.
        (uint256 floor0, uint256 floor1) = (f.ask0 + f.bid0, f.ask1 + f.bid1);
        (uint256 projectFloors, uint256 terminalFloors) = _projectIsToken0() ? (floor0, floor1) : (floor1, floor0);
        uint256 projectTotal = projectFloors + hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 terminalTotal = terminalFloors
            + hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The recycle accepts burns that return exactly their floors.
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Both positions are replaced.
        uint256 newAsk = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        uint256 newBid = hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertTrue(newAsk != _askId && newBid != _bidId, "both positions recycled");
        // The new positions plus the ledger hold exactly what the burns recovered, per side.
        (uint256 newAskProject, uint256 newAskTerminal) = _sides(newAsk);
        (uint256 newBidProject, uint256 newBidTerminal) = _sides(newBid);
        assertEq(
            newAskProject + newBidProject + hook.accumulatedProjectTokens(PROJECT_ID),
            projectTotal,
            "project tokens conserved"
        );
        assertEq(
            newAskTerminal + newBidTerminal
                + hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            terminalTotal,
            "terminal tokens conserved"
        );
    }

    /// @notice For each nonzero floor of `tokenId`, return one unit less on that side only: the recycle reverts with
    /// the PositionManager's slippage error and nothing changes.
    /// @param tokenId The position whose burn is shorted.
    /// @param floor0 The token0 floor the recycle passes for the position's burn.
    /// @param floor1 The token1 floor the recycle passes for the position's burn.
    function _assertShortByOneReverts(uint256 tokenId, uint256 floor0, uint256 floor1) internal {
        // At least one side has to carry a floor for the check to prove anything.
        assertTrue(floor0 > 0 || floor1 > 0, "fixture: a nonzero floor");
        (uint256 principal0, uint256 principal1) = _principalAtSpot(tokenId);
        for (uint256 side; side < 2; side++) {
            // A zero floor cannot be undershot, so skip that side.
            uint256 floor = side == 0 ? floor0 : floor1;
            if (floor == 0) continue;

            // Each side runs from the same untouched state.
            uint256 snapshot = vm.snapshotState();
            // A pool hook keeps just enough of this side's principal that the burn returns one unit below its floor.
            positionManager.setHookTakeOnRemove({
                tokenId: tokenId,
                amount0: side == 0 ? principal0 - floor + 1 : 0,
                amount1: side == 1 ? principal1 - floor + 1 : 0
            });
            // Snapshot the ledgers to prove the revert leaves them untouched.
            uint256 projectLedger = hook.accumulatedProjectTokens(PROJECT_ID);
            uint256 terminalLedger =
                hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

            // The PositionManager's slippage check rejects a return one unit below the floor.
            vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, floor, floor - 1));
            hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

            // The whole recycle unwinds: both positions stay recorded and live, and both ledgers are unchanged.
            assertEq(
                hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}), _askId, "ask kept"
            );
            assertEq(
                hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}), _bidId, "bid kept"
            );
            assertGt(positionManager.getPositionLiquidity(_askId), 0, "ask not burned");
            assertGt(positionManager.getPositionLiquidity(_bidId), 0, "bid not burned");
            assertEq(hook.accumulatedProjectTokens(PROJECT_ID), projectLedger, "project ledger unchanged");
            assertEq(
                hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
                terminalLedger,
                "terminal ledger unchanged"
            );
            vm.revertToState(snapshot);
        }
    }

    /// @notice Push the spot to the middle of the ask's range and mark both positions to it.
    function _moveSpotIntoAsk() internal {
        // Move the spot to the ask's midpoint, rounded to a tick the pool's spacing allows.
        (, int24 lower, int24 upper,,,,) = positionManager._positions(_askId);
        _setSpotTick((lower + upper) / 2 / hook.TICK_SPACING() * hook.TICK_SPACING());
        // Re-mark both positions' recorded principal at the new spot so the mock's balances back it.
        _markToSpot(_askId);
        _markToSpot(_bidId);
    }

    /// @notice The minimums a recycle passes for each burn, read from a recycle that is then undone.
    /// @return f The token0/token1 floors of the ask's and the bid's burns.
    function _recordFloors() internal returns (Floors memory f) {
        // Run a recycle so the mock records each burn's minimums, then undo it.
        uint256 snapshot = vm.snapshotState();
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        f = Floors({
            ask0: positionManager.lastMin0Of(_askId),
            ask1: positionManager.lastMin1Of(_askId),
            bid0: positionManager.lastMin0Of(_bidId),
            bid1: positionManager.lastMin1Of(_bidId)
        });
        vm.revertToState(snapshot);
    }

    /// @notice A pool hook keeps everything above `amount0`/`amount1` of `tokenId`'s principal, so its burn returns
    /// exactly those amounts.
    /// @param tokenId The position whose burn is configured.
    /// @param amount0 The token0 amount the burn returns.
    /// @param amount1 The token1 amount the burn returns.
    function _returnExactly(uint256 tokenId, uint256 amount0, uint256 amount1) internal {
        // The pool hook takes the principal above each requested amount on removal.
        (uint256 principal0, uint256 principal1) = _principalAtSpot(tokenId);
        positionManager.setHookTakeOnRemove({
            tokenId: tokenId, amount0: principal0 - amount0, amount1: principal1 - amount1
        });
    }
}
