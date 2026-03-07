// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

/// @notice Mock PositionManager for testing UniV4DeploymentSplitHook
/// @dev Simulates modifyLiquidities with MINT_POSITION/BURN_POSITION/DECREASE_LIQUIDITY/TAKE_PAIR/SETTLE/SWEEP
contract MockPositionManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 public nextTokenId = 1;

    // Configurable usage percent (how much of desired amounts are used in mint)
    uint256 public usagePercent = 10_000; // 100%

    struct Position {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool exists;
    }

    mapping(uint256 tokenId => Position) public _positions;

    // Pre-configured collectable fees per tokenId
    mapping(uint256 tokenId => uint256 amount0) public collectableAmount0;
    mapping(uint256 tokenId => uint256 amount1) public collectableAmount1;

    // Initialized pools
    mapping(bytes32 poolId => bool) public poolInitialized;
    mapping(bytes32 poolId => uint160) public poolSqrtPrice;

    // Track calls for verification
    uint256 public mintCallCount;
    uint256 public burnCallCount;
    uint256 public decreaseLiquidityCallCount;
    uint256 public lastMintTokenId;

    function setUsagePercent(uint256 percent) external {
        usagePercent = percent;
    }

    function setCollectableFees(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        collectableAmount0[tokenId] = amount0;
        collectableAmount1[tokenId] = amount1;
    }

    /// @notice IPoolInitializer_v4.initializePool
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24) {
        bytes32 id = keccak256(abi.encode(key));
        if (poolInitialized[id]) {
            return type(int24).max; // Already initialized
        }
        poolInitialized[id] = true;
        poolSqrtPrice[id] = sqrtPriceX96;
        return 0; // Simplified — return tick 0
    }

    /// @notice IPositionManager.getPositionLiquidity
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return _positions[tokenId].liquidity;
    }

    /// @notice IPositionManager.getPoolAndPositionInfo
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, PositionInfo) {
        Position memory pos = _positions[tokenId];
        // Return PoolKey; PositionInfo is packed — return empty for mock
        return (pos.poolKey, PositionInfo.wrap(0));
    }

    /// @notice IPositionManager.modifyLiquidities — the main entry point
    /// @dev Decodes actions and params, simulates behavior
    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 /* deadline */
    )
        external
        payable
    {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));

        for (uint256 i = 0; i < actions.length; i++) {
            uint8 action = uint8(actions[i]);

            if (action == uint8(Actions.MINT_POSITION)) {
                _handleMint(params[i]);
            } else if (action == uint8(Actions.BURN_POSITION)) {
                _handleBurn(params[i]);
            } else if (action == uint8(Actions.DECREASE_LIQUIDITY)) {
                _handleDecreaseLiquidity(params[i]);
            } else if (action == uint8(Actions.TAKE_PAIR)) {
                _handleTakePair(params[i]);
            } else if (action == uint8(Actions.SETTLE)) {
                _handleSettle(params[i]);
            } else if (action == uint8(Actions.SETTLE_PAIR)) {
                // No-op in mock — tokens already transferred
            } else if (action == uint8(Actions.SWEEP)) {
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
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            /* hookData */
        ) = abi.decode(data, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));

        mintCallCount++;
        uint256 tokenId = nextTokenId++;
        lastMintTokenId = tokenId;

        // Calculate amounts used based on usagePercent
        uint256 amount0Used = (uint256(amount0Max) * usagePercent) / 10_000;
        uint256 amount1Used = (uint256(amount1Max) * usagePercent) / 10_000;

        _positions[tokenId] = Position({
            poolKey: key, tickLower: tickLower, tickUpper: tickUpper, liquidity: uint128(liquidity), exists: true
        });

        // Transfer tokens from caller (settled via SETTLE actions that follow)
        // In mock, we pull directly since SETTLE is handled separately
    }

    function _handleBurn(bytes memory data) internal {
        (
            uint256 tokenId,
            uint128 amount0Min,
            uint128 amount1Min, /* hookData */
        ) = abi.decode(data, (uint256, uint128, uint128, bytes));

        burnCallCount++;
        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");

        // Position is fully removed
        pos.liquidity = 0;
        delete _positions[tokenId];
    }

    function _handleDecreaseLiquidity(bytes memory data) internal {
        (
            uint256 tokenId,
            uint256 liquidity,
            uint128 amount0Min,
            uint128 amount1Min, /* hookData */
        ) = abi.decode(data, (uint256, uint256, uint128, uint128, bytes));

        decreaseLiquidityCallCount++;

        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");

        if (liquidity > 0) {
            if (uint128(liquidity) >= pos.liquidity) {
                pos.liquidity = 0;
            } else {
                pos.liquidity -= uint128(liquidity);
            }
        }
        // When liquidity == 0, this is a fee collection operation
        // Fees are distributed via TAKE_PAIR
    }

    function _handleTakePair(bytes memory data) internal {
        (Currency currency0, Currency currency1, address recipient) = abi.decode(data, (Currency, Currency, address));

        // For fee collection: transfer collectable amounts
        // Find the relevant tokenId — use lastMintTokenId as proxy
        uint256 fee0 = collectableAmount0[lastMintTokenId];
        uint256 fee1 = collectableAmount1[lastMintTokenId];

        if (fee0 > 0) {
            if (currency0.isAddressZero()) {
                (bool success,) = recipient.call{value: fee0}("");
                require(success, "ETH transfer failed");
            } else {
                address token0 = Currency.unwrap(currency0);
                if (IERC20(token0).balanceOf(address(this)) >= fee0) {
                    IERC20(token0).transfer(recipient, fee0);
                }
            }
            collectableAmount0[lastMintTokenId] = 0;
        }

        if (fee1 > 0) {
            if (currency1.isAddressZero()) {
                (bool success,) = recipient.call{value: fee1}("");
                require(success, "ETH transfer failed");
            } else {
                address token1 = Currency.unwrap(currency1);
                if (IERC20(token1).balanceOf(address(this)) >= fee1) {
                    IERC20(token1).transfer(recipient, fee1);
                }
            }
            collectableAmount1[lastMintTokenId] = 0;
        }
    }

    function _handleSettle(bytes memory data) internal {
        (Currency currency, uint256 amount, bool payerIsUser) = abi.decode(data, (Currency, uint256, bool));

        if (payerIsUser) {
            // Pull tokens from msg.sender (the hook contract)
            if (!currency.isAddressZero()) {
                address token = Currency.unwrap(currency);
                uint256 allowance = IERC20(token).allowance(msg.sender, address(this));
                if (allowance > 0) {
                    uint256 bal = IERC20(token).balanceOf(msg.sender);
                    uint256 transferAmount = allowance < bal ? allowance : bal;
                    if (transferAmount > 0) {
                        IERC20(token).transferFrom(msg.sender, address(this), transferAmount);
                    }
                }
            }
            // For native ETH: msg.value already received
        }
        // payerIsUser=false: tokens already transferred to this contract
    }

    function _handleSweep(bytes memory data) internal {
        (Currency currency, address to) = abi.decode(data, (Currency, address));

        if (currency.isAddressZero()) {
            uint256 balance = address(this).balance;
            if (balance > 0) {
                (bool success,) = to.call{value: balance}("");
                require(success, "ETH sweep failed");
            }
        } else {
            address token = Currency.unwrap(currency);
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).transfer(to, balance);
            }
        }
    }

    // Accept ETH
    receive() external payable {}
}
