// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {Position as V4Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseActionsRouter} from "@uniswap/v4-periphery/src/base/BaseActionsRouter.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";

import {MockPoolManager} from "./MockPoolManager.sol";

/// @notice Mock PositionManager for testing JBUniswapV4LPSplitHook, following Uniswap V4's PositionManager and
/// PoolManager semantics for every action the hook encodes:
///      - MINT_POSITION / INCREASE_LIQUIDITY add exactly the requested liquidity at a cost computed from the live
///        price and range, rounded up as in v4-core, and revert with `MaximumAmountExceeded` above a maximum.
///      - BURN_POSITION / DECREASE_LIQUIDITY remove principal from the same math rounded down, owner-only. A pool
///        hook's take is subtracted from the signed principal delta, and `validateMinOut` semantics apply to it (fees
///        excluded): a negative principal delta reverts `SafeCastOverflow`, one below a minimum reverts
///        `MinimumAmountInsufficient`.
///      - Each batch tracks a delta per currency: SETTLE / SETTLE_PAIR pay debt (honoring amount and payer, crediting
///        what a user payer's transfer actually delivered), TAKE_PAIR takes credit, CLOSE_CURRENCY does whichever
///        applies, and the batch reverts with `CurrencyNotSettled` unless every delta ends at zero. Outgoing transfers
///        use v4's `CurrencyLibrary.transfer` (a false or failed ERC-20 transfer reverts). Unsupported actions revert
///        with `UnsupportedAction`.
///      - The pool's reserves (`poolLocked`) are kept apart from this contract's own loose balance, which is all SWEEP
///        ever moves (the whole loose balance of the currency, native or ERC-20).
contract MockPositionManager {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    uint256 public nextTokenId = 1;

    // Reference to MockPoolManager for the pool's Slot0 and tick liquidity.
    MockPoolManager public poolManager;

    struct Position {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Locked; // pool reserves of token0 backing this position
        uint256 amount1Locked; // pool reserves of token1 backing this position
        bool exists;
    }

    mapping(uint256 tokenId => Position) public _positions;
    mapping(uint256 tokenId => address) public ownerOf;

    // Fees accrued to each position, held in the pool's reserves until collected.
    mapping(uint256 tokenId => uint256 amount0) public collectableAmount0;
    mapping(uint256 tokenId => uint256 amount1) public collectableAmount1;

    // Part of the removed principal a pool hook keeps on each removal (a V4 `afterRemoveLiquidity` return delta).
    mapping(uint256 tokenId => uint256 amount0) public hookTakeOnRemove0;
    mapping(uint256 tokenId => uint256 amount1) public hookTakeOnRemove1;

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

    // The pool's reserves per token (settled principal plus accrued fees). Everything this contract holds above it is
    // its own loose balance.
    mapping(address token => uint256) public poolLocked;

    // --- Per-batch state ---
    bool private _unlocked;
    mapping(address token => int256) private _delta;
    address[] private _touched;

    function setPoolManager(MockPoolManager pm) external {
        poolManager = pm;
    }

    /// @notice Test helper: overwrite a live position's pool reserves, as swaps through its range would (e.g. to mark
    /// it to a moved price). The caller keeps this contract's balances backing the new amounts. A burn pays the
    /// principal from the position's liquidity at the live price and reverts if these reserves cannot cover it.
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

    /// @notice Test helper: fees accrued to `tokenId`. They join the pool's reserves, so the caller funds this contract
    /// with them.
    function setCollectableFees(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        require(_positions[tokenId].exists, "Position does not exist");
        PoolKey memory key = _positions[tokenId].poolKey;
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        poolLocked[token0] = poolLocked[token0] - collectableAmount0[tokenId] + amount0;
        poolLocked[token1] = poolLocked[token1] - collectableAmount1[tokenId] + amount1;
        collectableAmount0[tokenId] = amount0;
        collectableAmount1[tokenId] = amount1;
    }

    /// @notice Test helper: a pool hook keeps `amount0`/`amount1` of the principal each nonzero-liquidity removal from
    /// `tokenId` would return (V4's `afterRemoveLiquidity` return delta), so the caller receives less than the
    /// position's principal. A take above the principal leaves a negative principal delta, which reverts like V4.
    function setHookTakeOnRemove(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        hookTakeOnRemove0[tokenId] = amount0;
        hookTakeOnRemove1[tokenId] = amount1;
    }

    /// @notice Test helper: liquidity other LPs already hold at `tick`, which counts against V4's per-tick cap.
    function setTickLiquidityGross(PoolKey calldata key, int24 tick, uint128 liquidityGross) external {
        _writeTickGross(key, tick, liquidityGross);
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

    /// @notice IPositionManager.modifyLiquidities — the main entry point.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        if (block.timestamp > deadline) revert IPositionManager.DeadlinePassed(deadline);
        if (_unlocked) revert IPoolManager.AlreadyUnlocked();
        _unlocked = true;

        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        if (actions.length != params.length) revert BaseActionsRouter.InputLengthMismatch();

        for (uint256 i; i < actions.length; i++) {
            uint256 action = uint8(actions[i]);

            if (action == Actions.INCREASE_LIQUIDITY) {
                _handleIncreaseLiquidity(params[i]);
            } else if (action == Actions.MINT_POSITION) {
                _handleMint(params[i]);
            } else if (action == Actions.BURN_POSITION) {
                _handleBurn(params[i]);
            } else if (action == Actions.DECREASE_LIQUIDITY) {
                _handleDecreaseLiquidity(params[i]);
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = abi.decode(params[i], (Currency, uint256, bool));
                _settle(currency, payerIsUser ? msg.sender : address(this), _mapSettleAmount(amount, currency));
            } else if (action == Actions.SETTLE_PAIR) {
                (Currency currency0, Currency currency1) = abi.decode(params[i], (Currency, Currency));
                _settle(currency0, msg.sender, _fullDebt(currency0));
                _settle(currency1, msg.sender, _fullDebt(currency1));
            } else if (action == Actions.TAKE_PAIR) {
                (Currency currency0, Currency currency1, address recipient) =
                    abi.decode(params[i], (Currency, Currency, address));
                recipient = _mapRecipient(recipient);
                _take(currency0, recipient, _fullCredit(currency0));
                _take(currency1, recipient, _fullCredit(currency1));
            } else if (action == Actions.CLOSE_CURRENCY) {
                Currency currency = abi.decode(params[i], (Currency));
                int256 delta = _delta[Currency.unwrap(currency)];
                if (delta < 0) _settle(currency, msg.sender, uint256(-delta));
                else _take(currency, msg.sender, uint256(delta));
            } else if (action == Actions.SWEEP) {
                (Currency currency, address to) = abi.decode(params[i], (Currency, address));
                uint256 balance = _looseBalance(currency);
                if (balance > 0) currency.transfer(_mapRecipient(to), balance);
            } else {
                revert BaseActionsRouter.UnsupportedAction(action);
            }
        }

        // Like PoolManager.unlock: every currency delta must be cleared before the batch returns.
        for (uint256 i; i < _touched.length; i++) {
            if (_delta[_touched[i]] != 0) revert IPoolManager.CurrencyNotSettled();
        }
        delete _touched;
        _unlocked = false;
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

        mintCallCount++;
        uint256 tokenId = nextTokenId++;
        lastMintTokenId = tokenId;
        ownerOf[tokenId] = _mapRecipient(posOwner);

        // V4 checks the range before touching the position.
        if (tickLower >= tickUpper) revert Pool.TicksMisordered(tickLower, tickUpper);
        if (tickLower < TickMath.MIN_TICK) revert Pool.TickLowerOutOfBounds(tickLower);
        if (tickUpper > TickMath.MAX_TICK) revert Pool.TickUpperOutOfBounds(tickUpper);
        if (tickLower % key.tickSpacing != 0) revert TickBitmap.TickMisaligned(tickLower, key.tickSpacing);
        if (tickUpper % key.tickSpacing != 0) revert TickBitmap.TickMisaligned(tickUpper, key.tickSpacing);
        if (liquidity == 0) revert V4Position.CannotUpdateEmptyPosition();

        _positions[tokenId] = Position({
            poolKey: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: 0,
            amount0Locked: 0,
            amount1Locked: 0,
            exists: true
        });
        _addLiquidity(tokenId, liquidity, amount0Max, amount1Max);
    }

    function _handleIncreaseLiquidity(bytes memory data) internal {
        (
            uint256 tokenId,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max, /* hookData */
        ) = abi.decode(data, (uint256, uint256, uint128, uint128, bytes));

        increaseCallCount++;
        _requireApproved(tokenId);
        _addLiquidity(tokenId, liquidity, amount0Max, amount1Max);
        // Increasing also collects the position's accrued fees, which are excluded from the max check.
        _creditFees(tokenId);
    }

    /// @dev Adds exactly `liquidity`, charging its rounded-up cost at the live price as debt.
    function _addLiquidity(uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max) internal {
        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");
        uint128 added = _toUint128(liquidity);
        _growTicks(pos, added);

        (uint256 cost0, uint256 cost1) = _amountsFor(pos, added, true);
        if (cost0 > amount0Max) revert SlippageCheck.MaximumAmountExceeded(amount0Max, _toUint128(cost0));
        if (cost1 > amount1Max) revert SlippageCheck.MaximumAmountExceeded(amount1Max, _toUint128(cost1));

        pos.liquidity += added;
        pos.amount0Locked += cost0;
        pos.amount1Locked += cost1;
        _accountDelta(pos.poolKey.currency0, -int256(cost0));
        _accountDelta(pos.poolKey.currency1, -int256(cost1));
    }

    function _handleBurn(bytes memory data) internal {
        (
            uint256 tokenId,
            uint128 amount0Min,
            uint128 amount1Min, /* hookData */
        ) = abi.decode(data, (uint256, uint128, uint128, bytes));

        burnCallCount++;
        require(_positions[tokenId].exists, "Position does not exist");
        _requireApproved(tokenId);
        lastMin0Of[tokenId] = amount0Min;
        lastMin1Of[tokenId] = amount1Min;

        // Like V4, a burn only touches the pool (and collects fees) when liquidity remains.
        uint128 liquidity = _positions[tokenId].liquidity;
        if (liquidity > 0) {
            _removeLiquidity(tokenId, liquidity, amount0Min, amount1Min);
            _creditFees(tokenId);
        }

        // Whatever reserves the rounded-down principal left behind stay in the pool.
        delete _positions[tokenId];
        delete ownerOf[tokenId];
    }

    function _handleDecreaseLiquidity(bytes memory data) internal {
        (
            uint256 tokenId,
            uint256 liquidity,
            uint128 amount0Min,
            uint128 amount1Min, /* hookData */
        ) = abi.decode(data, (uint256, uint256, uint128, uint128, bytes));

        decreaseLiquidityCallCount++;
        require(_positions[tokenId].exists, "Position does not exist");
        _requireApproved(tokenId);
        lastMin0Of[tokenId] = amount0Min;
        lastMin1Of[tokenId] = amount1Min;

        _removeLiquidity(tokenId, _toUint128(liquidity), amount0Min, amount1Min);
        // Fees are always owed regardless of liquidity amount (0 = collect-only).
        _creditFees(tokenId);
    }

    /// @dev Removes `liquidity`, crediting its rounded-down principal at the live price less any pool-hook take, as a
    /// signed delta checked like V4's `validateMinOut` (which casts the fee-excluded delta with `SafeCast.toUint128`).
    function _removeLiquidity(uint256 tokenId, uint128 liquidity, uint128 amount0Min, uint128 amount1Min) internal {
        Position storage pos = _positions[tokenId];
        require(liquidity <= pos.liquidity, "liquidity underflow");

        (uint256 principal0, uint256 principal1) = _amountsFor(pos, liquidity, false);
        // The pool can only return reserves it holds for this position: a test moving the price must mark it.
        require(
            principal0 <= pos.amount0Locked && principal1 <= pos.amount1Locked,
            "principal exceeds the position's reserves; mark it to the moved price"
        );
        pos.amount0Locked -= principal0;
        pos.amount1Locked -= principal1;
        pos.liquidity -= liquidity;
        _shrinkTicks(pos, liquidity);

        // The synthetic pool hook takes only from removals that move liquidity (a fee-only collect returns its own
        // signed delta of zero principal).
        (uint256 take0, uint256 take1) =
            liquidity == 0 ? (0, 0) : (hookTakeOnRemove0[tokenId], hookTakeOnRemove1[tokenId]);
        // Principal and takes are token amounts far below 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 out0 = int256(principal0) - int256(take0);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 out1 = int256(principal1) - int256(take1);
        _validateMinOut(out0, amount0Min);
        _validateMinOut(out1, amount1Min);

        _accountDelta(pos.poolKey.currency0, out0);
        _accountDelta(pos.poolKey.currency1, out1);
    }

    /// @dev `SlippageCheck.validateMinOut` for one currency: the signed principal delta must cast to uint128 and meet
    /// the minimum.
    function _validateMinOut(int256 delta, uint128 amountMin) internal pure {
        if (delta < 0 || delta > int256(uint256(type(uint128).max))) revert SafeCast.SafeCastOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 received = uint128(uint256(delta));
        if (received < amountMin) revert SlippageCheck.MinimumAmountInsufficient(amountMin, received);
    }

    function _creditFees(uint256 tokenId) internal {
        PoolKey memory key = _positions[tokenId].poolKey;
        _accountDelta(key.currency0, int256(collectableAmount0[tokenId]));
        _accountDelta(key.currency1, int256(collectableAmount1[tokenId]));
        collectableAmount0[tokenId] = 0;
        collectableAmount1[tokenId] = 0;
    }

    /// @dev Token amounts for `liquidity` over the position's range at the live price, branching on the live tick like
    /// v4-core's `Pool.modifyLiquidity`.
    function _amountsFor(
        Position storage pos,
        uint128 liquidity,
        bool roundUp
    )
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96, int24 tick,,) =
            StateLibrary.getSlot0(IPoolManager(address(poolManager)), pos.poolKey.toId());
        if (sqrtPriceX96 == 0) revert Pool.PoolNotInitialized();
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(pos.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(pos.tickUpper);
        if (tick < pos.tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
        } else if (tick < pos.tickUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
        }
    }

    /// @dev V4 caps each initialized tick's gross liquidity at `tickSpacingToMaxLiquidityPerTick`.
    function _growTicks(Position storage pos, uint128 liquidity) internal {
        uint128 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(pos.poolKey.tickSpacing);
        int24[2] memory ticks = [pos.tickLower, pos.tickUpper];
        for (uint256 i; i < 2; i++) {
            uint256 gross = uint256(_tickGross(pos.poolKey, ticks[i])) + liquidity;
            if (gross > maxPerTick) revert Pool.TickLiquidityOverflow(ticks[i]);
            _writeTickGross(pos.poolKey, ticks[i], uint128(gross));
        }
    }

    function _shrinkTicks(Position storage pos, uint128 liquidity) internal {
        _writeTickGross(pos.poolKey, pos.tickLower, _tickGross(pos.poolKey, pos.tickLower) - liquidity);
        _writeTickGross(pos.poolKey, pos.tickUpper, _tickGross(pos.poolKey, pos.tickUpper) - liquidity);
    }

    function _tickGross(PoolKey memory key, int24 tick) internal view returns (uint128 gross) {
        (gross,) = StateLibrary.getTickLiquidity(IPoolManager(address(poolManager)), key.toId(), tick);
    }

    /// @dev Writes `pools[id].ticks[tick].liquidityGross` (low 128 bits), keeping `liquidityNet`.
    function _writeTickGross(PoolKey memory key, int24 tick, uint128 gross) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), StateLibrary.POOLS_SLOT));
        bytes32 slot =
            keccak256(abi.encodePacked(int256(tick), bytes32(uint256(stateSlot) + StateLibrary.TICKS_OFFSET)));
        uint256 word = uint256(poolManager.extsload(slot));
        poolManager.writeSlot(slot, bytes32((word >> 128 << 128) | gross));
    }

    function _requireApproved(uint256 tokenId) internal view {
        if (ownerOf[tokenId] != msg.sender) revert IPositionManager.NotApproved(msg.sender);
    }

    // --- Delta resolution (DeltaResolver / PoolManager semantics) ---

    function _accountDelta(Currency currency, int256 amount) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        if (_delta[token] == 0) _touched.push(token);
        _delta[token] += amount;
    }

    function _mapSettleAmount(uint256 amount, Currency currency) internal view returns (uint256) {
        if (amount == ActionConstants.CONTRACT_BALANCE) return _looseBalance(currency);
        if (amount == ActionConstants.OPEN_DELTA) return _fullDebt(currency);
        return amount;
    }

    function _fullDebt(Currency currency) internal view returns (uint256) {
        int256 delta = _delta[Currency.unwrap(currency)];
        if (delta > 0) revert DeltaResolver.DeltaNotNegative(currency);
        return uint256(-delta);
    }

    function _fullCredit(Currency currency) internal view returns (uint256) {
        int256 delta = _delta[Currency.unwrap(currency)];
        if (delta < 0) revert DeltaResolver.DeltaNotPositive(currency);
        return uint256(delta);
    }

    /// @dev Pays `amount` into the pool's reserves: native and payer-is-this-contract come out of the loose balance
    /// (as V4 pays them from the PositionManager's own balance); a user payer is pulled through Permit2. Like
    /// `PoolManager.settle`, the credit is what the reserves actually received, so a short transfer leaves debt.
    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        uint256 received = amount;
        if (currency.isAddressZero() || payer == address(this)) {
            require(_looseBalance(currency) >= amount, "settle: insufficient balance");
        } else {
            uint256 balanceBefore = currency.balanceOfSelf();
            PERMIT2.transferFrom(payer, address(this), _toUint160(amount), token);
            received = currency.balanceOfSelf() - balanceBefore;
        }
        poolLocked[token] += received;
        _accountDelta(currency, int256(received));
    }

    /// @dev Takes `amount` out of the pool's reserves; never pays from another position's stock or the loose balance.
    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        require(currency.balanceOfSelf() >= poolLocked[token], "take: pool reserves unbacked");
        poolLocked[token] -= amount;
        _accountDelta(currency, -int256(amount));
        currency.transfer(recipient, amount);
    }

    /// @dev This contract's own balance, apart from the pool's reserves (what SWEEP moves).
    function _looseBalance(Currency currency) internal view returns (uint256) {
        return currency.balanceOfSelf() - poolLocked[Currency.unwrap(currency)];
    }

    function _mapRecipient(address recipient) internal view returns (address) {
        if (recipient == ActionConstants.MSG_SENDER) return msg.sender;
        if (recipient == ActionConstants.ADDRESS_THIS) return address(this);
        return recipient;
    }

    function _toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "uint128 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    function _toUint160(uint256 value) internal pure returns (uint160) {
        require(value <= type(uint160).max, "uint160 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(value);
    }

    // Accept ETH
    receive() external payable {}
}
