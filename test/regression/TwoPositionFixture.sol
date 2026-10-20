// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";

/// @notice Shared fixture for tests that need the hook's two live positions (ask + bid) and a PositionManager whose
/// balances back exactly the principal it records (no spare funding).
abstract contract TwoPositionFixture is LPSplitHookV4TestBase {
    // Derives a pool's ID from its key for the PoolManager state reads.
    using PoolIdLibrary for PoolKey;

    /// @notice The pool key of the default project's pool against the terminal token.
    /// @return key The pool key the hook records for `PROJECT_ID` and the terminal token.
    function _key() internal view returns (PoolKey memory key) {
        // Read the key from the hook so every helper targets the pool the hook manages.
        return hook.poolKeyOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
    }

    /// @notice Whether the project token sorts as the pool's token0.
    /// @return projectIsToken0 True when the project token's address is lower than the terminal token's.
    function _projectIsToken0() internal view returns (bool projectIsToken0) {
        // Uniswap V4 orders currencies by address, so the lower address is token0.
        return address(projectToken) < address(terminalToken);
    }

    /// @notice The pool's current spot price.
    /// @return sqrtPriceX96 The spot sqrt price, as a Q64.96 fixed point number.
    function _spotSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        // Read slot0 from the PoolManager for the hook's pool.
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), _key().toId());
    }

    /// @notice Write the pool's spot price (the base oracle tracks spot, so the TWAP guard keeps passing).
    /// @param sqrtPriceX96 The spot sqrt price to write, as a Q64.96 fixed point number.
    function _setSpotSqrtPrice(uint160 sqrtPriceX96) internal {
        // Overwrite the pool's slot0 directly so no swap is needed to move the price.
        _writeSpot({key: _key(), sqrtPriceX96: sqrtPriceX96});
    }

    /// @notice Write the pool's spot price at an exact tick.
    /// @param tick The tick to move the spot to.
    function _setSpotTick(int24 tick) internal {
        // Convert the tick to its sqrt price and write that as the spot.
        _setSpotSqrtPrice(TickMath.getSqrtPriceAtTick(tick));
    }

    /// @notice The token0/token1 principal `liquidity` across `[lower, upper]` holds at `sqrtPriceX96`, rounded down.
    /// @param sqrtPriceX96 The sqrt price to value the range at, as a Q64.96 fixed point number.
    /// @param lower The range's lower tick.
    /// @param upper The range's upper tick.
    /// @param liquidity The liquidity the range holds.
    /// @return amount0 The token0 principal.
    /// @return amount1 The token1 principal.
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
        // Round down, matching what a burn of the range returns.
        return _amountsForLiquidity({
            sqrtPriceX96: sqrtPriceX96, lower: lower, upper: upper, liquidity: liquidity, roundUp: false
        });
    }

    /// @notice The project-side and terminal-side principal the mock records for `tokenId`.
    /// @param tokenId The position to read.
    /// @return projectSide The principal held in the project token.
    /// @return terminalSide The principal held in the terminal token.
    function _sides(uint256 tokenId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        // Read the mock's recorded token0/token1 principal for the position.
        (,,,, uint256 amount0, uint256 amount1,) = positionManager._positions(tokenId);
        // Map token0/token1 onto the project/terminal sides by the pool's currency order.
        return _projectIsToken0() ? (amount0, amount1) : (amount1, amount0);
    }

    /// @notice Fund and configure collectable fees on `tokenId` by side.
    /// @param tokenId The position to accrue fees on.
    /// @param projectFee The collectable fee in the project token.
    /// @param terminalFee The collectable fee in the terminal token.
    function _setFees(uint256 tokenId, uint256 projectFee, uint256 terminalFee) internal {
        // Fund the PositionManager so a collect can pay the fees out of real balances.
        if (projectFee > 0) projectToken.mint({to: address(positionManager), amount: projectFee});
        if (terminalFee > 0) terminalToken.mint({to: address(positionManager), amount: terminalFee});
        // Record the fees in token0/token1 order, which depends on which side the project token sorts to.
        if (_projectIsToken0()) {
            positionManager.setCollectableFees({tokenId: tokenId, amount0: projectFee, amount1: terminalFee});
        } else {
            positionManager.setCollectableFees({tokenId: tokenId, amount0: terminalFee, amount1: projectFee});
        }
    }

    /// @notice Deploy the pool and grow it into two live positions (see `_recycleIntoTwoPositions`).
    /// @return askId The live ask position's token ID.
    /// @return bidId The live bid position's token ID.
    function _deployTwoPositions() internal returns (uint256 askId, uint256 bidId) {
        // Accumulate project tokens and deploy the pool with its seed ask.
        _accumulateAndDeploy({projectId: PROJECT_ID, amount: 100e18});
        // Recycle the seed ask into an ask and a bid.
        return _recycleIntoTwoPositions();
    }

    /// @notice Move the spot to the middle of the live ask so it holds both tokens, then recycle: the hook ends with a
    /// live ask (project tokens on one side of the spot) and a live bid (terminal tokens on the other). The spot is
    /// left on an aligned tick between them, so both positions are single-sided at the live price.
    /// @return askId The live ask position's token ID.
    /// @return bidId The live bid position's token ID.
    function _recycleIntoTwoPositions() internal returns (uint256 askId, uint256 bidId) {
        // Move the spot into the middle of the seed ask so it holds both tokens.
        uint256 seedAsk = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        _fillHalfOf(seedAsk);

        // Recycle the two-token seed ask into a single-sided ask and bid.
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Read both positions back and require that the recycle left each one live.
        askId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        bidId = hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        require(askId != 0 && bidId != 0, "fixture: both positions live");
    }
}
