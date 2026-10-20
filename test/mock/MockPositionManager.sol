// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {MockPoolManager} from "./MockPoolManager.sol";

/// @notice Mock PositionManager for testing JBUniswapV4LPSplitHook
/// @dev Simulates modifyLiquidities with realistic token flows:
///      - MINT_POSITION records how many tokens the position requires
///      - SETTLE pulls tokens from the caller (enforcing approval + balance)
///      - BURN_POSITION / DECREASE_LIQUIDITY record their minimums, enforce them against the principal removed (fees
///        excluded, like V4's `validateMinOut`) and track owed amounts for TAKE_PAIR
///      - TAKE_PAIR transfers owed + fee amounts to the recipient, reverting when the unlocked balance cannot pay
///      - SWEEP returns only the native value this call sent but did not use (ERC-20s are pulled exactly)
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
    uint256 public increaseCallCount;
    uint256 public burnCallCount;
    uint256 public decreaseLiquidityCallCount;
    uint256 public lastMintTokenId;

    // Minimums the last BURN_POSITION / DECREASE_LIQUIDITY of each tokenId was called with.
    mapping(uint256 tokenId => uint128) public lastMin0Of;
    mapping(uint256 tokenId => uint128) public lastMin1Of;

    // Tokens locked in positions (simulates PoolManager holding them). TAKE_PAIR only pays out of the balance above
    // this, so an unfunded fee or principal reverts instead of being paid from another position's stock.
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
    // Native value sent with this call and not yet consumed by a mint/increase (what SWEEP may return).
    uint256 private _nativeCredit;

    function setPoolManager(MockPoolManager pm) external {
        poolManager = pm;
    }

    /// @notice Test helper: grow a live position's locked balance of `token` (simulating buyers filling the position's
    /// asks and leaving `token` behind as principal), so a subsequent BURN recovers real principal of that token —
    /// the
    /// only legitimate way terminal enters an LP position. The caller must have already funded this contract with
    /// `amount` of `token` (mint an ERC-20 to it, or `vm.deal` for native ETH) so TAKE_PAIR can pay it out on burn.
    function injectPositionBalance(uint256 tokenId, address token, uint256 amount) external {
        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");
        if (token == Currency.unwrap(pos.poolKey.currency0)) {
            pos.amount0Locked += amount;
        } else if (token == Currency.unwrap(pos.poolKey.currency1)) {
            pos.amount1Locked += amount;
        } else {
            revert("token not in pool");
        }
        poolLocked[token] += amount;
    }

    /// @notice Test helper: overwrite a live position's recorded principal (e.g. to mark it to a moved price or to
    /// return slightly less than a burn floor). The caller keeps this contract's balances backing the new amounts.
    function setPositionPrincipal(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");
        address token0 = Currency.unwrap(pos.poolKey.currency0);
        address token1 = Currency.unwrap(pos.poolKey.currency1);
        poolLocked[token0] = poolLocked[token0] - pos.amount0Locked + amount0;
        poolLocked[token1] = poolLocked[token1] - pos.amount1Locked + amount1;
        pos.amount0Locked = amount0;
        pos.amount1Locked = amount1;
    }

    /// @notice Test helper: overwrite a live position's liquidity.
    function setPositionLiquidity(uint256 tokenId, uint128 liquidity) external {
        require(_positions[tokenId].exists, "Position does not exist");
        _positions[tokenId].liquidity = liquidity;
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
        return (pos.poolKey, PositionInfoLibrary.initialize(pos.poolKey, pos.tickLower, pos.tickUpper));
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
        _nativeCredit = msg.value;

        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));

        for (uint256 i = 0; i < actions.length; i++) {
            uint8 action = uint8(actions[i]);

            if (action == uint8(Actions.INCREASE_LIQUIDITY)) {
                _handleIncreaseLiquidity(params[i]);
            } else if (action == uint8(Actions.MINT_POSITION)) {
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
            // The position holds liquidity in proportion to what it used, so its principal and burn floor agree.
            // Safe: test mock; values in tests always fit in target type.
            // forge-lint: disable-next-line(unsafe-typecast)
            liquidity: uint128((liquidity * usagePercent) / 10_000),
            amount0Locked: amount0Used,
            amount1Locked: amount1Used,
            exists: true
        });

        // Record what SETTLE needs to pull from the caller.
        _pendingSettle0 = amount0Used;
        _pendingSettle1 = amount1Used;
        _settleCurrency0 = key.currency0;
        _settleCurrency1 = key.currency1;

        // Lock the used amounts in the "pool".
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        poolLocked[token0] += amount0Used;
        poolLocked[token1] += amount1Used;
        _consumeNative(key, amount0Used, amount1Used);
    }

    function _handleIncreaseLiquidity(bytes memory data) internal {
        (
            uint256 tokenId,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max, /* hookData */
        ) = abi.decode(data, (uint256, uint256, uint128, uint128, bytes));

        increaseCallCount++;

        // Calculate amounts used based on usagePercent (same model as mint).
        uint256 amount0Used = (uint256(amount0Max) * usagePercent) / 10_000;
        uint256 amount1Used = (uint256(amount1Max) * usagePercent) / 10_000;

        // Grow the existing position's recorded liquidity/locked amounts.
        Position storage position = _positions[tokenId];
        // Safe: test mock; values in tests always fit in target type.
        // forge-lint: disable-next-line(unsafe-typecast)
        position.liquidity += uint128((liquidity * usagePercent) / 10_000);
        position.amount0Locked += amount0Used;
        position.amount1Locked += amount1Used;

        // Record what SETTLE needs to pull from the caller.
        _pendingSettle0 = amount0Used;
        _pendingSettle1 = amount1Used;
        _settleCurrency0 = position.poolKey.currency0;
        _settleCurrency1 = position.poolKey.currency1;

        // Lock the used amounts in the "pool".
        poolLocked[Currency.unwrap(position.poolKey.currency0)] += amount0Used;
        poolLocked[Currency.unwrap(position.poolKey.currency1)] += amount1Used;
        _consumeNative(position.poolKey, amount0Used, amount1Used);
    }

    /// @dev Native liquidity is paid with the call's value; using more than was sent fails like V4's settle would.
    function _consumeNative(PoolKey memory key, uint256 amount0Used, uint256 amount1Used) internal {
        uint256 nativeUsed;
        if (key.currency0.isAddressZero()) nativeUsed += amount0Used;
        if (key.currency1.isAddressZero()) nativeUsed += amount1Used;
        require(nativeUsed <= _nativeCredit, "native underpaid");
        _nativeCredit -= nativeUsed;
    }

    /// @dev Mirrors V4's `SlippageCheck.validateMinOut` on the principal removed (fees excluded).
    function _validateMinOut(
        uint256 principal0,
        uint256 principal1,
        uint128 amount0Min,
        uint128 amount1Min
    )
        internal
        pure
    {
        // Safe: test mock; principal fits uint128 in every fixture.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (principal0 < amount0Min) revert SlippageCheck.MinimumAmountInsufficient(amount0Min, uint128(principal0));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (principal1 < amount1Min) revert SlippageCheck.MinimumAmountInsufficient(amount1Min, uint128(principal1));
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
        lastMin0Of[tokenId] = amount0Min;
        lastMin1Of[tokenId] = amount1Min;
        _validateMinOut(pos.amount0Locked, pos.amount1Locked, amount0Min, amount1Min);

        // Unlock the locked amounts from the "pool" so TAKE_PAIR can pay them out.
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

        decreaseLiquidityCallCount++;

        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");
        lastMin0Of[tokenId] = amount0Min;
        lastMin1Of[tokenId] = amount1Min;

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
            _validateMinOut(fraction0, fraction1, amount0Min, amount1Min);
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
        } else {
            // Collect-only: no principal is removed, so any nonzero minimum fails.
            _validateMinOut(0, 0, amount0Min, amount1Min);
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

        _pay(currency0, recipient, owed0);
        _pay(currency1, recipient, owed1);
    }

    /// @dev Pay `amount` out of the balance no position has locked; never silently pays less.
    function _pay(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        uint256 balance =
            currency.isAddressZero() ? address(this).balance - _nativeCredit : IERC20(token).balanceOf(address(this));
        require(balance >= poolLocked[token] + amount, "TAKE_PAIR: unbacked payout");
        if (currency.isAddressZero()) {
            (bool success,) = recipient.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // Test mock: return value not checked intentionally.
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(token).transfer(recipient, amount);
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

        // SETTLE pulls ERC-20s exactly, so only unused native value is ever left over for the caller. Donations and
        // fee/principal stock held for other positions are never swept out.
        if (currency.isAddressZero() && _nativeCredit > 0) {
            uint256 refund = _nativeCredit;
            _nativeCredit = 0;
            (bool success,) = to.call{value: refund}("");
            require(success, "ETH sweep failed");
        }
    }

    // Accept ETH
    receive() external payable {}
}
