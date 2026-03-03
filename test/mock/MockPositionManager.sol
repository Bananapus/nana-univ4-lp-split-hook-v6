// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {MockWETH} from "./MockWETH.sol";

/// @notice Mock PositionManager for testing UniV4DeploymentSplitHook
/// @dev Simulates V4 PositionManager's modifyLiquidities, initializePool, and position queries
contract MockPositionManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 private _nextTokenId = 1;

    // Configurable usage percent (how much of desired amounts are used in mint)
    // Default 100% = 10000 bps
    uint256 public usagePercent = 10000;

    struct Position {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool exists;
    }

    mapping(uint256 tokenId => Position) internal _positions;

    // Pre-configured collectable fees per tokenId
    mapping(uint256 tokenId => uint256 amount0) public collectableAmount0;
    mapping(uint256 tokenId => uint256 amount1) public collectableAmount1;

    // Initialized pools
    mapping(PoolId => bool) public poolInitialized;
    mapping(PoolId => uint160) public poolSqrtPriceX96;

    // Track calls for verification
    uint256 public mintCallCount;
    uint256 public decreaseLiquidityCallCount;
    uint256 public burnCallCount;
    uint256 public collectCallCount;
    uint256 public lastMintTokenId;

    constructor() {}

    function setUsagePercent(uint256 percent) external {
        usagePercent = percent;
    }

    function setCollectableFees(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        collectableAmount0[tokenId] = amount0;
        collectableAmount1[tokenId] = amount1;
    }

    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        return _positions[tokenId].liquidity;
    }

    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, bytes32) {
        Position memory pos = _positions[tokenId];
        // Return packed PositionInfo as bytes32 (tickLower, tickUpper, poolId)
        return (pos.poolKey, bytes32(0));
    }

    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24) {
        PoolId poolId = key.toId();
        poolInitialized[poolId] = true;
        poolSqrtPriceX96[poolId] = sqrtPriceX96;
        return 0; // tick (not important for mock)
    }

    /// @notice Main entry point - decode actions and simulate them
    function modifyLiquidities(bytes calldata unlockData, uint256 /* deadline */) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));

        for (uint256 i = 0; i < actions.length; i++) {
            uint8 action = uint8(actions[i]);

            if (action == uint8(Actions.MINT_POSITION)) {
                _handleMint(params[i]);
            } else if (action == uint8(Actions.DECREASE_LIQUIDITY)) {
                _handleDecreaseLiquidity(params[i]);
            } else if (action == uint8(Actions.BURN_POSITION)) {
                _handleBurn(params[i]);
            } else if (action == uint8(Actions.SETTLE_PAIR)) {
                _handleSettlePair(params[i]);
            } else if (action == uint8(Actions.TAKE_PAIR)) {
                _handleTakePair(params[i]);
            } else if (action == uint8(Actions.SWEEP)) {
                // SWEEP: return any leftover tokens to recipient
                _handleSweep(params[i]);
            }
        }
    }

    function _handleMint(bytes memory data) internal {
        (
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint256 amount0Max,
            uint256 amount1Max,
            address recipient,
            /* bytes hookData */
        ) = abi.decode(data, (PoolKey, int24, int24, uint256, uint256, uint256, address, bytes));

        mintCallCount++;
        uint256 tokenId = _nextTokenId++;
        lastMintTokenId = tokenId;

        // Calculate amounts used based on usagePercent
        uint256 amount0Used = (amount0Max * usagePercent) / 10000;
        uint256 amount1Used = (amount1Max * usagePercent) / 10000;

        _positions[tokenId] = Position({
            poolKey: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: uint128(amount0Used + amount1Used),
            exists: true
        });

        // Store amounts that the SETTLE_PAIR action will pull
        // (In real V4, PositionManager handles this internally)
        _pendingSettle0 = amount0Used;
        _pendingSettle1 = amount1Used;
        _pendingSweep0 = amount0Max > amount0Used ? amount0Max - amount0Used : 0;
        _pendingSweep1 = amount1Max > amount1Used ? amount1Max - amount1Used : 0;
        _pendingKey = key;
    }

    // Temporary storage for multi-action coordination
    uint256 private _pendingSettle0;
    uint256 private _pendingSettle1;
    uint256 private _pendingSweep0;
    uint256 private _pendingSweep1;
    PoolKey private _pendingKey;

    function _handleSettlePair(bytes memory data) internal {
        (Currency currency0, Currency currency1) = abi.decode(data, (Currency, Currency));

        // Pull tokens from caller via Permit2 (simulated: just transferFrom)
        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);

        if (_pendingSettle0 > 0) {
            if (token0 == address(0)) {
                // Native ETH - already received as msg.value
            } else {
                // Try transferFrom first (Permit2 path), fall back to direct
                try IERC20(token0).transferFrom(msg.sender, address(this), _pendingSettle0) {} catch {}
            }
        }
        if (_pendingSettle1 > 0) {
            if (token1 == address(0)) {
                // Native ETH
            } else {
                try IERC20(token1).transferFrom(msg.sender, address(this), _pendingSettle1) {} catch {}
            }
        }

        _pendingSettle0 = 0;
        _pendingSettle1 = 0;
    }

    function _handleTakePair(bytes memory data) internal {
        (Currency currency0, Currency currency1, address recipient) = abi.decode(data, (Currency, Currency, address));

        // Transfer collected fees (from decrease liquidity or fee collection) to recipient
        // This reads from the pending take amounts set by decrease/burn
        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);

        if (_pendingTake0 > 0) {
            if (token0 == address(0)) {
                (bool success,) = recipient.call{value: _pendingTake0}("");
                require(success, "ETH transfer failed");
            } else if (IERC20(token0).balanceOf(address(this)) >= _pendingTake0) {
                IERC20(token0).transfer(recipient, _pendingTake0);
            }
        }
        if (_pendingTake1 > 0) {
            if (token1 == address(0)) {
                (bool success,) = recipient.call{value: _pendingTake1}("");
                require(success, "ETH transfer failed");
            } else if (IERC20(token1).balanceOf(address(this)) >= _pendingTake1) {
                IERC20(token1).transfer(recipient, _pendingTake1);
            }
        }

        _pendingTake0 = 0;
        _pendingTake1 = 0;
    }

    uint256 private _pendingTake0;
    uint256 private _pendingTake1;

    function _handleDecreaseLiquidity(bytes memory data) internal {
        (uint256 tokenId, uint256 liquidityDelta, , , ) =
            abi.decode(data, (uint256, uint256, uint256, uint256, bytes));

        decreaseLiquidityCallCount++;

        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");

        // Set fees for TAKE_PAIR
        _pendingTake0 = collectableAmount0[tokenId];
        _pendingTake1 = collectableAmount1[tokenId];

        if (liquidityDelta > 0 && liquidityDelta >= pos.liquidity) {
            // Also add proportional liquidity amounts
            _pendingTake0 += uint256(pos.liquidity) / 2;
            _pendingTake1 += uint256(pos.liquidity) / 2;
            pos.liquidity = 0;
        } else if (liquidityDelta > 0) {
            _pendingTake0 += liquidityDelta / 2;
            _pendingTake1 += liquidityDelta / 2;
            pos.liquidity -= uint128(liquidityDelta);
        }

        // Clear collectable fees
        collectableAmount0[tokenId] = 0;
        collectableAmount1[tokenId] = 0;
    }

    function _handleBurn(bytes memory data) internal {
        (uint256 tokenId, , , ) =
            abi.decode(data, (uint256, uint256, uint256, bytes));

        burnCallCount++;

        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");

        // Return all liquidity + fees
        _pendingTake0 = collectableAmount0[tokenId] + uint256(pos.liquidity) / 2;
        _pendingTake1 = collectableAmount1[tokenId] + uint256(pos.liquidity) / 2;

        // Clear
        collectableAmount0[tokenId] = 0;
        collectableAmount1[tokenId] = 0;

        delete _positions[tokenId];
    }

    function _handleSweep(bytes memory data) internal {
        (Currency currency, address recipient) = abi.decode(data, (Currency, address));

        // Return any remaining tokens that weren't used
        // In real V4, SWEEP returns leftovers from the PositionManager
        // In our mock, we track pending sweep amounts from mint
        // (handled by SETTLE_PAIR consuming exact amounts)
    }

    // Accept ETH
    receive() external payable {}
}
