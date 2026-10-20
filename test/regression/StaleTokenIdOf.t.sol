// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";

/// @notice The stored position IDs become stale when a recycle burns the live positions but mints nothing.
/// @dev A recycle that cannot mint either side now reverts with NoDeployableLiquidityAtSpot, rolling back the burns,
///      rather than leaving askTokenIdOf/bidTokenIdOf zeroed (or pointing at burned positions) while the project is
///      marked deployed, which would brick it. A recycle that does mint replaces BOTH stored IDs with fresh ones and
///      never keeps a burned ID.
contract StaleTokenIdOfTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;

    uint256 poolTokenId;

    function setUp() public override {
        super.setUp();

        // Deploy a pool so we have a position to recycle.
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        poolTokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(poolTokenId, 0, "Initial tokenId should be nonzero");

        // A new reserved distribution clears addLiquidity's accumulation threshold.
        _accumulateTokens(PROJECT_ID, 10e18);
    }

    /// @notice Write the pool's spot tick (the base oracle tracks spot, so the TWAP guard keeps passing).
    function _setSpotTick(PoolKey memory key, int24 tick) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 packed = bytes32(
            (uint256(key.fee) << 208) | (uint256(uint24(tick)) << 160) | uint256(TickMath.getSqrtPriceAtTick(tick))
        );
        poolManager.writeSlot(stateSlot, packed);
    }

    /// @notice When the project holds only project tokens and the spot is past the issuance ceiling, neither side can
    ///         be minted, so the recycle reverts with NoDeployableLiquidityAtSpot and the stored IDs (and the live
    ///         position) survive. This prevents the state inconsistency that would brick the project.
    function test_recycle_noDeployableSide_reverts_keepsTokenIds() public {
        // The seed spot sits at the ask range's floor-side end; push it well past the opposite (ceiling) end.
        (PoolKey memory key, int24 askLower, int24 askUpper,,,,) = positionManager._positions(poolTokenId);
        (, int24 seedTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), key.toId());
        _setSpotTick(key, seedTick >= askUpper ? askLower - 10 * key.tickSpacing : askUpper + 10 * key.tickSpacing);

        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        // The revert rolled back the burn: both stored IDs and the live position are unchanged.
        assertEq(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), poolTokenId, "ask ID unchanged after revert");
        assertEq(hook.bidTokenIdOf(PROJECT_ID, address(terminalToken)), 0, "bid ID unchanged after revert");
        assertGt(positionManager.getPositionLiquidity(poolTokenId), 0, "live position not burned");
    }

    /// @notice A recycle that mints replaces both stored IDs with fresh positions; burned IDs are never kept.
    function test_recycle_replacesBothTokenIds_neverKeepsBurnedIds() public {
        // Buyers fill part of the ask: the spot moves into the ask range and terminal tokens become its principal.
        (PoolKey memory key, int24 askLower, int24 askUpper,,,,) = positionManager._positions(poolTokenId);
        _setSpotTick(key, (askLower + askUpper) / 2 / key.tickSpacing * key.tickSpacing);
        terminalToken.mint(address(positionManager), 5e18);
        positionManager.injectPositionBalance(poolTokenId, address(terminalToken), 5e18);

        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        uint256 askId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 bidId = hook.bidTokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(askId != 0 && bidId != 0, "both sides minted");
        assertTrue(askId != poolTokenId && bidId != poolTokenId, "burned ID not kept");
        assertEq(positionManager.getPositionLiquidity(poolTokenId), 0, "original position burned");

        // A second recycle retires both and stores two new IDs.
        _accumulateTokens(PROJECT_ID, 10e18);
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
    }
}
