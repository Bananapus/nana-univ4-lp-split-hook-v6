// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {TwoPositionFixture} from "./TwoPositionFixture.sol";

/// @notice Every recycle burns both live positions with a contract-derived floor of 95% of each position's principal
/// at the live price, per side. A burn returning even one unit less on either side of either position reverts the
/// whole recycle; returning exactly the floor is accepted.
contract BurnSlippageFloorTest is TwoPositionFixture {
    uint256 internal askId;
    uint256 internal bidId;

    struct Floors {
        uint256 ask0;
        uint256 ask1;
        uint256 bid0;
        uint256 bid1;
    }

    function setUp() public override {
        super.setUp();
        (askId, bidId) = _deployTwoPositions();
    }

    /// @notice Both positions sit out of range at the live spot (one above it, one below), so each floor is one-sided
    /// and equals 95% of an independently computed principal.
    function test_floor_isNinetyFivePercentOfLivePrincipal_outOfRange() public {
        (uint256 ask0, uint256 ask1) = _principalAtSpot(askId);
        (uint256 bid0, uint256 bid1) = _principalAtSpot(bidId);
        assertTrue((ask0 == 0) != (ask1 == 0), "ask is single-sided at the spot");
        assertTrue((bid0 == 0) != (bid1 == 0), "bid is single-sided at the spot");
        assertTrue((ask0 == 0) == (bid1 == 0), "ask and bid hold opposite currencies");

        Floors memory f = _recordFloors();
        assertEq(f.ask0, ask0 * 9500 / 10_000, "ask floor0");
        assertEq(f.ask1, ask1 * 9500 / 10_000, "ask floor1");
        assertEq(f.bid0, bid0 * 9500 / 10_000, "bid floor0");
        assertEq(f.bid1, bid1 * 9500 / 10_000, "bid floor1");
    }

    /// @notice The spot inside the ask's range: the ask holds both currencies and both of its floors are nonzero.
    function test_floor_isNinetyFivePercentOfLivePrincipal_inRange() public {
        _moveSpotIntoAsk();
        (uint256 ask0, uint256 ask1) = _principalAtSpot(askId);
        assertTrue(ask0 > 0 && ask1 > 0, "ask is in range");

        Floors memory f = _recordFloors();
        assertEq(f.ask0, ask0 * 9500 / 10_000, "ask floor0");
        assertEq(f.ask1, ask1 * 9500 / 10_000, "ask floor1");
    }

    function test_askOneBelowFloor_revertsAtomically() public {
        Floors memory f = _recordFloors();
        _assertShortByOneReverts(askId, f.ask0, f.ask1);
    }

    function test_bidOneBelowFloor_revertsAtomically() public {
        Floors memory f = _recordFloors();
        _assertShortByOneReverts(bidId, f.bid0, f.bid1);
    }

    function test_inRangeAskOneBelowEitherFloor_revertsAtomically() public {
        _moveSpotIntoAsk();
        Floors memory f = _recordFloors();
        _assertShortByOneReverts(askId, f.ask0, f.ask1);
    }

    function test_burnsReturningExactlyTheFloor_areAccepted() public {
        _assertExactFloorsAccepted();
    }

    function test_inRangeBurnsReturningExactlyTheFloor_areAccepted() public {
        _moveSpotIntoAsk();
        _assertExactFloorsAccepted();
    }

    /// @notice A principal whose 95% floor no longer fits uint128 reverts rather than wrapping to a smaller floor.
    function test_floorOverflowingUint128_reverts() public {
        uint128 maxLiquidity = type(uint128).max;
        uint256 overflowing;
        for (uint256 i; i < 2; i++) {
            uint256 tokenId = i == 0 ? askId : bidId;
            (, int24 lower, int24 upper,,,,) = positionManager._positions(tokenId);
            (uint256 amount0, uint256 amount1) = _principalAt(_spotSqrtPrice(), lower, upper, maxLiquidity);
            if ((amount0 > amount1 ? amount0 : amount1) * 9500 / 10_000 > type(uint128).max) overflowing = tokenId;
        }
        assertNotEq(overflowing, 0, "fixture: one position's floor can overflow");
        positionManager.setPositionLiquidity(overflowing, maxLiquidity);

        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_AmountExceedsUint128.selector);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        assertEq(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), askId, "ask kept");
        assertEq(hook.bidTokenIdOf(PROJECT_ID, address(terminalToken)), bidId, "bid kept");
    }

    /// @notice Push the spot to the middle of the ask's range and mark both positions to it.
    function _moveSpotIntoAsk() internal {
        (, int24 lower, int24 upper,,,,) = positionManager._positions(askId);
        _setSpotTick((lower + upper) / 2 / hook.TICK_SPACING() * hook.TICK_SPACING());
        _markToSpot(askId);
        _markToSpot(bidId);
    }

    /// @notice The minimums a recycle passes for each burn, read from a recycle that is then undone.
    function _recordFloors() internal returns (Floors memory f) {
        uint256 snapshot = vm.snapshotState();
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
        f = Floors({
            ask0: positionManager.lastMin0Of(askId),
            ask1: positionManager.lastMin1Of(askId),
            bid0: positionManager.lastMin0Of(bidId),
            bid1: positionManager.lastMin1Of(bidId)
        });
        vm.revertToState(snapshot);
    }

    /// @notice For each nonzero floor of `tokenId`, return one unit less on that side only: the recycle reverts with
    /// the PositionManager's slippage error and nothing changes.
    function _assertShortByOneReverts(uint256 tokenId, uint256 floor0, uint256 floor1) internal {
        assertTrue(floor0 > 0 || floor1 > 0, "fixture: a nonzero floor");
        (,,,, uint256 locked0, uint256 locked1,) = positionManager._positions(tokenId);
        for (uint256 side; side < 2; side++) {
            uint256 floor = side == 0 ? floor0 : floor1;
            if (floor == 0) continue;

            uint256 snapshot = vm.snapshotState();
            _setPrincipal(tokenId, side == 0 ? floor - 1 : locked0, side == 1 ? floor - 1 : locked1);
            uint256 projectLedger = hook.accumulatedProjectTokens(PROJECT_ID);
            uint256 terminalLedger = hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken));

            vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, floor, floor - 1));
            hook.addLiquidity(PROJECT_ID, address(terminalToken));

            assertEq(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), askId, "ask kept");
            assertEq(hook.bidTokenIdOf(PROJECT_ID, address(terminalToken)), bidId, "bid kept");
            assertGt(positionManager.getPositionLiquidity(askId), 0, "ask not burned");
            assertGt(positionManager.getPositionLiquidity(bidId), 0, "bid not burned");
            assertEq(hook.accumulatedProjectTokens(PROJECT_ID), projectLedger, "project ledger unchanged");
            assertEq(
                hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)),
                terminalLedger,
                "terminal ledger unchanged"
            );
            vm.revertToState(snapshot);
        }
    }

    /// @notice Every burn returns exactly its floor: the recycle succeeds and redeploys exactly what was recovered.
    function _assertExactFloorsAccepted() internal {
        Floors memory f = _recordFloors();
        _setPrincipal(askId, f.ask0, f.ask1);
        _setPrincipal(bidId, f.bid0, f.bid1);
        (uint256 askProject, uint256 askTerminal) = _sides(askId);
        (uint256 bidProject, uint256 bidTerminal) = _sides(bidId);
        uint256 projectTotal = askProject + bidProject + hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 terminalTotal =
            askTerminal + bidTerminal + hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken));

        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        uint256 newAsk = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 newBid = hook.bidTokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newAsk != askId && newBid != bidId, "both positions recycled");
        (uint256 newAskProject, uint256 newAskTerminal) = _sides(newAsk);
        (uint256 newBidProject, uint256 newBidTerminal) = _sides(newBid);
        assertEq(
            newAskProject + newBidProject + hook.accumulatedProjectTokens(PROJECT_ID),
            projectTotal,
            "project tokens conserved"
        );
        assertEq(
            newAskTerminal + newBidTerminal + hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)),
            terminalTotal,
            "terminal tokens conserved"
        );
    }
}
