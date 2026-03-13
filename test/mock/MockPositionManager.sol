// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {MockPoolManager} from "./MockPoolManager.sol";

/// @notice Mock PositionManager for testing JBUniswapV4LPSplitHook
/// @dev Simulates modifyLiquidities with realistic token flows:
///      - MINT_POSITION records how many tokens the position requires
///      - SETTLE pulls tokens from the caller (enforcing approval + balance)
///      - BURN_POSITION / DECREASE_LIQUIDITY track owed amounts for TAKE_PAIR
///      - TAKE_PAIR transfers owed + fee amounts to the recipient
///      - SWEEP returns any leftover tokens held by this contract
contract MockPositionManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 public nextTokenId = 1;

    // Configurable usage percent (how much of desired amounts are used in mint)
    uint256 public usagePercent = 10_000; // 100%

    // Reference to MockPoolManager for syncing Slot0 on pool init
    MockPoolManager public poolManager;

    struct Position {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Locked; // tokens locked in the position
        uint256 amount1Locked; // tokens locked in the position
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

    // Tokens locked in the "pool" (simulates PoolManager holding them).
    // SWEEP should not return these — only excess above poolLocked is sweepable.
    mapping(address token => uint256) public poolLocked;

    // --- Per-modifyLiquidities transient state ---
    // Tracks amounts owed to the caller after BURN/DECREASE, consumed by TAKE_PAIR.
    uint256 private _pendingOwed0;
    uint256 private _pendingOwed1;
    // Track the currencies for pending owed amounts.
    Currency private _pendingCurrency0;
    Currency private _pendingCurrency1;
    // Amounts the mint expects to settle (consumed by SETTLE).
    uint256 private _pendingSettle0;
    uint256 private _pendingSettle1;
    Currency private _settleCurrency0;
    Currency private _settleCurrency1;

    function setPoolManager(MockPoolManager pm) external {
        poolManager = pm;
    }

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

        // Sync Slot0 into MockPoolManager so StateLibrary.getSlot0 works.
        if (address(poolManager) != address(0)) {
            _syncSlot0(key, sqrtPriceX96);
        }

        return 0; // Simplified — return tick 0
    }

    /// @dev Write packed Slot0 data into MockPoolManager at the correct storage slot.
    function _syncSlot0(PoolKey calldata key, uint160 sqrtPriceX96) internal {
        bytes32 poolId = PoolId.unwrap(key.toId());
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        uint24 lpFee = key.fee;
        // Pack: lpFee (24) | protocolFee (24) | tick (24) | sqrtPriceX96 (160)
        // Safe: tick fits in uint24 after masking; uint24(tick) is standard V4 packing.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 packed = bytes32((uint256(lpFee) << 208) | (uint256(uint24(tick)) << 160) | uint256(sqrtPriceX96));
        poolManager.writeSlot(stateSlot, packed);
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
    /// @dev Decodes actions and params, simulates behavior with realistic token flows.
    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 /* deadline */
    )
        external
        payable
    {
        // Reset transient state
        _pendingOwed0 = 0;
        _pendingOwed1 = 0;
        _pendingSettle0 = 0;
        _pendingSettle1 = 0;

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
            address posOwner,
            /* hookData */
        ) = abi.decode(data, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));
        posOwner; // Silence unused variable warning.

        mintCallCount++;
        uint256 tokenId = nextTokenId++;
        lastMintTokenId = tokenId;

        // Calculate amounts used based on usagePercent
        uint256 amount0Used = (uint256(amount0Max) * usagePercent) / 10_000;
        uint256 amount1Used = (uint256(amount1Max) * usagePercent) / 10_000;

        _positions[tokenId] = Position({
            poolKey: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            // Safe: test mock; values in tests always fit in target type.
            // forge-lint: disable-next-line(unsafe-typecast)
            liquidity: uint128(liquidity),
            amount0Locked: amount0Used,
            amount1Locked: amount1Used,
            exists: true
        });

        // Record what SETTLE needs to pull from the caller.
        _pendingSettle0 = amount0Used;
        _pendingSettle1 = amount1Used;
        _settleCurrency0 = key.currency0;
        _settleCurrency1 = key.currency1;

        // Lock the used amounts in the "pool" so SWEEP doesn't return them.
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        poolLocked[token0] += amount0Used;
        poolLocked[token1] += amount1Used;
    }

    function _handleBurn(bytes memory data) internal {
        (
            uint256 tokenId,
            uint128 amount0Min,
            uint128 amount1Min, /* hookData */
        ) = abi.decode(data, (uint256, uint128, uint128, bytes));
        amount0Min; // Silence unused variable warning.
        amount1Min; // Silence unused variable warning.

        burnCallCount++;
        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");

        // Unlock the locked amounts from the "pool" back to PM's sweepable balance.
        address token0 = Currency.unwrap(pos.poolKey.currency0);
        address token1 = Currency.unwrap(pos.poolKey.currency1);
        poolLocked[token0] -= pos.amount0Locked;
        poolLocked[token1] -= pos.amount1Locked;

        // The underlying tokens + any fees become owed to the caller via TAKE_PAIR.
        _pendingOwed0 += pos.amount0Locked + collectableAmount0[tokenId];
        _pendingOwed1 += pos.amount1Locked + collectableAmount1[tokenId];
        _pendingCurrency0 = pos.poolKey.currency0;
        _pendingCurrency1 = pos.poolKey.currency1;

        // Clear fees since they're included in owed amounts.
        collectableAmount0[tokenId] = 0;
        collectableAmount1[tokenId] = 0;

        // Position is fully removed.
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
        amount0Min; // Silence unused variable warning.
        amount1Min; // Silence unused variable warning.

        decreaseLiquidityCallCount++;

        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");

        _pendingCurrency0 = pos.poolKey.currency0;
        _pendingCurrency1 = pos.poolKey.currency1;

        address token0 = Currency.unwrap(pos.poolKey.currency0);
        address token1 = Currency.unwrap(pos.poolKey.currency1);

        if (liquidity > 0) {
            // Calculate the pro-rata share of locked tokens being removed.
            uint256 fraction0;
            uint256 fraction1;
            if (pos.liquidity > 0) {
                // Safe: test mock; values in tests always fit in target type.
                // forge-lint: disable-next-line(unsafe-typecast)
                fraction0 = (pos.amount0Locked * uint128(liquidity)) / pos.liquidity;
                // Safe: test mock; values in tests always fit in target type.
                // forge-lint: disable-next-line(unsafe-typecast)
                fraction1 = (pos.amount1Locked * uint128(liquidity)) / pos.liquidity;
            }
            _pendingOwed0 += fraction0;
            _pendingOwed1 += fraction1;
            pos.amount0Locked -= fraction0;
            pos.amount1Locked -= fraction1;

            // Unlock the removed fraction from the pool.
            poolLocked[token0] -= fraction0;
            poolLocked[token1] -= fraction1;

            // Safe: test mock; values in tests always fit in target type.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (uint128(liquidity) >= pos.liquidity) {
                pos.liquidity = 0;
            } else {
                // Safe: test mock; values in tests always fit in target type.
                // forge-lint: disable-next-line(unsafe-typecast)
                pos.liquidity -= uint128(liquidity);
            }
        }

        // Fees are always owed regardless of liquidity amount (0 = collect-only).
        _pendingOwed0 += collectableAmount0[tokenId];
        _pendingOwed1 += collectableAmount1[tokenId];
        collectableAmount0[tokenId] = 0;
        collectableAmount1[tokenId] = 0;
    }

    function _handleTakePair(bytes memory data) internal {
        (Currency currency0, Currency currency1, address recipient) = abi.decode(data, (Currency, Currency, address));

        uint256 owed0 = _pendingOwed0;
        uint256 owed1 = _pendingOwed1;
        _pendingOwed0 = 0;
        _pendingOwed1 = 0;

        // Transfer owed amounts to the recipient.
        if (owed0 > 0) {
            if (currency0.isAddressZero()) {
                (bool success,) = recipient.call{value: owed0}("");
                require(success, "ETH transfer failed");
            } else {
                address token0 = Currency.unwrap(currency0);
                uint256 bal = IERC20(token0).balanceOf(address(this));
                uint256 toSend = owed0 > bal ? bal : owed0;
                if (toSend > 0) {
                    // Test mock: return value not checked intentionally.
                    // forge-lint: disable-next-line(erc20-unchecked-transfer)
                    IERC20(token0).transfer(recipient, toSend);
                }
            }
        }

        if (owed1 > 0) {
            if (currency1.isAddressZero()) {
                (bool success,) = recipient.call{value: owed1}("");
                require(success, "ETH transfer failed");
            } else {
                address token1 = Currency.unwrap(currency1);
                uint256 bal = IERC20(token1).balanceOf(address(this));
                uint256 toSend = owed1 > bal ? bal : owed1;
                if (toSend > 0) {
                    // Test mock: return value not checked intentionally.
                    // forge-lint: disable-next-line(erc20-unchecked-transfer)
                    IERC20(token1).transfer(recipient, toSend);
                }
            }
        }
    }

    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function _handleSettle(bytes memory data) internal {
        (Currency currency, uint256 amount, bool payerIsUser) = abi.decode(data, (Currency, uint256, bool));
        amount; // Silence unused variable warning.

        if (payerIsUser) {
            // Determine how much to pull: use the pending settle amount if available.
            uint256 toPull;
            if (Currency.unwrap(currency) == Currency.unwrap(_settleCurrency0) && _pendingSettle0 > 0) {
                toPull = _pendingSettle0;
                _pendingSettle0 = 0;
            } else if (Currency.unwrap(currency) == Currency.unwrap(_settleCurrency1) && _pendingSettle1 > 0) {
                toPull = _pendingSettle1;
                _pendingSettle1 = 0;
            }

            if (!currency.isAddressZero() && toPull > 0) {
                address token = Currency.unwrap(currency);
                // Pull via Permit2, matching real PositionManager behavior.
                // Safe: test mock; values in tests always fit in target type.
                // forge-lint: disable-next-line(unsafe-typecast)
                PERMIT2.transferFrom(msg.sender, address(this), uint160(toPull), token);
            }
            // For native ETH: msg.value already received
        }
        // payerIsUser=false: tokens already transferred to this contract
    }

    function _handleSweep(bytes memory data) internal {
        (Currency currency, address to) = abi.decode(data, (Currency, address));

        if (currency.isAddressZero()) {
            // For native ETH, pool-locked ETH is tracked at address(0).
            uint256 balance = address(this).balance;
            uint256 locked = poolLocked[address(0)];
            uint256 sweepable = balance > locked ? balance - locked : 0;
            if (sweepable > 0) {
                (bool success,) = to.call{value: sweepable}("");
                require(success, "ETH sweep failed");
            }
        } else {
            address token = Currency.unwrap(currency);
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 locked = poolLocked[token];
            uint256 sweepable = balance > locked ? balance - locked : 0;
            if (sweepable > 0) {
                // Test mock: return value not checked intentionally.
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                IERC20(token).transfer(to, sweepable);
            }
        }
    }

    // Accept ETH
    receive() external payable {}
}
