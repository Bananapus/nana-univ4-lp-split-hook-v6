// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";

/// @notice Shared fixture for tests that need the hook's two live positions (ask + bid) and a PositionManager whose
/// balances back exactly the principal it records (no spare funding).
abstract contract TwoPositionFixture is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;

    function _key() internal view returns (PoolKey memory) {
        return hook.poolKeyOf(PROJECT_ID, address(terminalToken));
    }

    function _projectIsToken0() internal view returns (bool) {
        return address(projectToken) < address(terminalToken);
    }

    function _spotSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), _key().toId());
    }

    /// @notice Write the pool's spot price (the base oracle tracks spot, so the TWAP guard keeps passing).
    function _setSpotSqrtPrice(uint160 sqrtPriceX96) internal {
        PoolKey memory key = _key();
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 packed = bytes32((uint256(key.fee) << 208) | (uint256(uint24(tick)) << 160) | uint256(sqrtPriceX96));
        poolManager.writeSlot(stateSlot, packed);
    }

    function _setSpotTick(int24 tick) internal {
        _setSpotSqrtPrice(TickMath.getSqrtPriceAtTick(tick));
    }

    /// @notice The token0/token1 principal `liquidity` across `[lower, upper]` holds at `sqrtPriceX96`, rounded down.
    /// @dev Independent of the hook: the canonical V4 amount formulas.
    function _principalAt(
        uint160 sqrtPriceX96,
        int24 lower,
        int24 upper,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        uint160 sqrtP = sqrtPriceX96 < sqrtA ? sqrtA : sqrtPriceX96 > sqrtB ? sqrtB : sqrtPriceX96;
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, false);
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, false);
    }

    /// @notice The principal of a live mock position at its own pool's live spot.
    function _principalAtSpot(uint256 tokenId) internal view returns (uint256 amount0, uint256 amount1) {
        (PoolKey memory key, int24 lower, int24 upper, uint128 liquidity,,,) = positionManager._positions(tokenId);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), key.toId());
        return _principalAt(sqrtPriceX96, lower, upper, liquidity);
    }

    /// @notice The project-side and terminal-side principal the mock records for `tokenId`.
    function _sides(uint256 tokenId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        (,,,, uint256 amount0, uint256 amount1,) = positionManager._positions(tokenId);
        return _projectIsToken0() ? (amount0, amount1) : (amount1, amount0);
    }

    /// @notice Set the mock's recorded principal of `tokenId`, minting or removing the difference from the
    /// PositionManager so its balances keep backing exactly what it records.
    function _setPrincipal(uint256 tokenId, uint256 amount0, uint256 amount1) internal {
        (PoolKey memory key,,,, uint256 old0, uint256 old1,) = positionManager._positions(tokenId);
        _rebalance(key.currency0, old0, amount0);
        _rebalance(key.currency1, old1, amount1);
        positionManager.setPositionPrincipal(tokenId, amount0, amount1);
    }

    /// @notice Re-mark `tokenId`'s principal to what its liquidity holds at the live spot, as if swaps had moved the
    /// price through it.
    function _markToSpot(uint256 tokenId) internal {
        (uint256 amount0, uint256 amount1) = _principalAtSpot(tokenId);
        _setPrincipal(tokenId, amount0, amount1);
    }

    /// @notice Fund and configure collectable fees on `tokenId` by side.
    function _setFees(uint256 tokenId, uint256 projectFee, uint256 terminalFee) internal {
        if (projectFee > 0) projectToken.mint(address(positionManager), projectFee);
        if (terminalFee > 0) terminalToken.mint(address(positionManager), terminalFee);
        if (_projectIsToken0()) positionManager.setCollectableFees(tokenId, projectFee, terminalFee);
        else positionManager.setCollectableFees(tokenId, terminalFee, projectFee);
    }

    /// @notice Deploy the pool and grow it into two live positions (see `_recycleIntoTwoPositions`).
    function _deployTwoPositions() internal returns (uint256 askId, uint256 bidId) {
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        return _recycleIntoTwoPositions();
    }

    /// @notice Move the spot to the middle of the live ask so it holds both tokens, then recycle: the hook ends with a
    /// live ask (project tokens on one side of the spot) and a live bid (terminal tokens on the other). The spot is
    /// left on an aligned tick between them, so both positions are single-sided at the live price.
    function _recycleIntoTwoPositions() internal returns (uint256 askId, uint256 bidId) {
        uint256 seedAsk = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        (, int24 lower, int24 upper,,,,) = positionManager._positions(seedAsk);
        _setSpotTick((lower + upper) / 2 / hook.TICK_SPACING() * hook.TICK_SPACING());
        _markToSpot(seedAsk);

        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        askId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        bidId = hook.bidTokenIdOf(PROJECT_ID, address(terminalToken));
        require(askId != 0 && bidId != 0, "fixture: both positions live");
    }

    function _rebalance(Currency currency, uint256 oldAmount, uint256 newAmount) private {
        MockERC20 token = MockERC20(Currency.unwrap(currency));
        if (newAmount > oldAmount) {
            token.mint(address(positionManager), newAmount - oldAmount);
        } else if (oldAmount > newAmount) {
            token.burn(address(positionManager), oldAmount - newAmount);
        }
    }
}
