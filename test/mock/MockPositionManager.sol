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
/// PoolManager semantics for every action the hook encodes.
/// @dev
///      - MINT_POSITION / INCREASE_LIQUIDITY add exactly the requested liquidity at a cost computed from the live
///        price and range, rounded up as in v4-core, and revert with `MaximumAmountExceeded` above a maximum.
///      - BURN_POSITION / DECREASE_LIQUIDITY remove principal from the same math rounded down, owner-only. A pool
///        hook's take is subtracted from the signed principal delta, and `validateMinOut` semantics apply to it (fees
///        excluded): a negative principal delta reverts `SafeCastOverflow`, one below a minimum reverts
///        `MinimumAmountInsufficient`. By default the synthetic hook charges only removals that move liquidity;
///        `setHookTakesOnCollect` makes it charge collect-only decreases too, as a V4 hook may.
///      - Each batch tracks a delta per currency: SETTLE / SETTLE_PAIR pay debt (honoring amount and payer, crediting
///        what a user payer's transfer actually delivered), TAKE_PAIR takes credit, CLOSE_CURRENCY does whichever
///        applies, and the batch reverts with `CurrencyNotSettled` unless every delta ends at zero. A self-payer
///        ERC-20 settle pays with a measured `CurrencyLibrary.transfer` from this contract's loose balance. Outgoing
///        transfers use v4's `CurrencyLibrary.transfer` (a false or failed ERC-20 transfer reverts). Unsupported
///        actions revert with `UnsupportedAction`.
///      - The pool's reserves (`poolLocked`) are kept apart from this contract's own loose balance, which is all SWEEP
///        ever moves (the whole loose balance of the currency, native or ERC-20).
contract MockPositionManager {
    // Currency helpers for balances, transfers and native-token checks.
    using CurrencyLibrary for Currency;

    // Derives a pool's ID from its key.
    using PoolIdLibrary for PoolKey;

    //*********************************************************************//
    // ------------------------------ structs ---------------------------- //
    //*********************************************************************//

    /// @custom:member poolKey The pool the position provides liquidity to.
    /// @custom:member tickLower The lower tick of the position's range.
    /// @custom:member tickUpper The upper tick of the position's range.
    /// @custom:member liquidity The position's live liquidity.
    /// @custom:member amount0Locked The pool reserves of token0 backing this position.
    /// @custom:member amount1Locked The pool reserves of token1 backing this position.
    /// @custom:member exists Whether the position has been minted and not burned.
    struct Position {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Locked;
        uint256 amount1Locked;
        bool exists;
    }

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The canonical Permit2 deployment, which pulls a user payer's tokens on SETTLE.
    IAllowanceTransfer internal constant _PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    // Declared in storage-layout order, not alphabetically: tests poke `nextTokenId` at slot 0 with `vm.store`.

    /// @notice The ID the next minted position receives.
    uint256 public nextTokenId = 1;

    /// @notice The MockPoolManager that holds each pool's Slot0 and tick liquidity.
    MockPoolManager public poolManager;

    /// @notice Each position's range, liquidity and backing reserves.
    /// @dev Public with a leading underscore so tests can read whole positions through the generated getter.
    /// @custom:param tokenId The ID of the position.
    mapping(uint256 tokenId => Position) public _positions;

    /// @notice The owner of each live position, the only address allowed to modify it.
    /// @custom:param tokenId The ID of the position.
    mapping(uint256 tokenId => address) public ownerOf;

    /// @notice Fees accrued to each position in token0, held in the pool's reserves until collected.
    /// @custom:param tokenId The ID of the position.
    mapping(uint256 tokenId => uint256 amount0) public collectableAmount0;

    /// @notice Fees accrued to each position in token1, held in the pool's reserves until collected.
    /// @custom:param tokenId The ID of the position.
    mapping(uint256 tokenId => uint256 amount1) public collectableAmount1;

    /// @notice The token0 part of the removed principal a pool hook keeps on each removal (a V4
    /// `afterRemoveLiquidity` return delta).
    /// @custom:param tokenId The ID of the position.
    mapping(uint256 tokenId => uint256 amount0) public hookTakeOnRemove0;

    /// @notice The token1 part of the removed principal a pool hook keeps on each removal (a V4
    /// `afterRemoveLiquidity` return delta).
    /// @custom:param tokenId The ID of the position.
    mapping(uint256 tokenId => uint256 amount1) public hookTakeOnRemove1;

    /// @notice Whether the synthetic pool hook also takes from collect-only (zero-liquidity) decreases.
    bool public hookTakesOnCollect;

    /// @notice Whether `initializePool` has run for a pool.
    /// @custom:param poolId The `keccak256` of the ABI-encoded pool key.
    mapping(bytes32 poolId => bool) public poolInitialized;

    /// @notice The sqrt price each pool was initialized at.
    /// @custom:param poolId The `keccak256` of the ABI-encoded pool key.
    mapping(bytes32 poolId => uint160) public poolSqrtPrice;

    /// @notice How many MINT_POSITION actions this contract has processed.
    uint256 public mintCallCount;

    /// @notice How many INCREASE_LIQUIDITY actions this contract has processed.
    uint256 public increaseCallCount;

    /// @notice How many BURN_POSITION actions this contract has processed.
    uint256 public burnCallCount;

    /// @notice How many DECREASE_LIQUIDITY actions this contract has processed.
    uint256 public decreaseLiquidityCallCount;

    /// @notice The ID of the most recently minted position.
    uint256 public lastMintTokenId;

    /// @notice The token0 minimum the last BURN_POSITION / DECREASE_LIQUIDITY of each position was called with.
    /// @custom:param tokenId The ID of the position.
    mapping(uint256 tokenId => uint128) public lastMin0Of;

    /// @notice The token1 minimum the last BURN_POSITION / DECREASE_LIQUIDITY of each position was called with.
    /// @custom:param tokenId The ID of the position.
    mapping(uint256 tokenId => uint128) public lastMin1Of;

    /// @notice The pool's reserves per token (settled principal plus accrued fees). Everything this contract holds
    /// above it is its own loose balance.
    /// @custom:param token The token the reserves are held in.
    mapping(address token => uint256) public poolLocked;

    //*********************************************************************//
    // -------------------- private stored properties -------------------- //
    //*********************************************************************//

    /// @notice Whether a `modifyLiquidities` batch is in progress, which blocks re-entrant batches.
    bool private _unlocked;

    /// @notice The open delta of each currency in the current batch (positive = credit owed to the caller).
    /// @custom:param token The currency's address.
    mapping(address token => int256) private _delta;

    /// @notice The currencies whose delta the current batch has touched, checked for zero at the batch's end.
    address[] private _touched;

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Accepts native tokens, which join the loose balance until a SETTLE moves them into the reserves.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice IPoolInitializer_v4.initializePool: records the pool's starting price.
    /// @param key The pool to initialize.
    /// @param sqrtPriceX96 The starting sqrt price.
    /// @return tick `type(int24).max` when the pool is already initialized, otherwise 0.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24 tick) {
        // Key the pool by its encoded key, matching the public `poolInitialized` lookups.
        bytes32 id = keccak256(abi.encode(key));

        // An already-initialized pool reports `type(int24).max` and keeps its price, like V4's initializer.
        if (poolInitialized[id]) {
            return type(int24).max;
        }

        // Record the pool and its starting price.
        poolInitialized[id] = true;
        poolSqrtPrice[id] = sqrtPriceX96;

        // Sync Slot0 into MockPoolManager so StateLibrary.getSlot0 works.
        if (address(poolManager) != address(0)) {
            _syncSlot0({key: key, sqrtPriceX96: sqrtPriceX96});
        }

        // The mock does not derive the tick from the price here; callers read Slot0 for it.
        return 0;
    }

    /// @notice IPositionManager.modifyLiquidities: runs a batch of position and delta-resolution actions.
    /// @dev Like PoolManager.unlock, every currency delta must be zero when the batch ends.
    /// @param unlockData The ABI-encoded `(bytes actions, bytes[] params)` batch.
    /// @param deadline The timestamp after which the batch reverts.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        // Reject a stale batch and a re-entrant one, as V4 does.
        if (block.timestamp > deadline) revert IPositionManager.DeadlinePassed(deadline);
        if (_unlocked) revert IPoolManager.AlreadyUnlocked();
        _unlocked = true;

        // Each action byte pairs with one params entry.
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        if (actions.length != params.length) revert BaseActionsRouter.InputLengthMismatch();

        for (uint256 i; i < actions.length; i++) {
            // The action ID is the batch's i-th byte.
            uint256 action = uint8(actions[i]);

            if (action == Actions.INCREASE_LIQUIDITY) {
                // Add liquidity to an existing position.
                _handleIncreaseLiquidity(params[i]);
            } else if (action == Actions.MINT_POSITION) {
                // Mint a new position.
                _handleMint(params[i]);
            } else if (action == Actions.BURN_POSITION) {
                // Remove a position's remaining liquidity and delete it.
                _handleBurn(params[i]);
            } else if (action == Actions.DECREASE_LIQUIDITY) {
                // Remove part of a position's liquidity and collect its fees.
                _handleDecreaseLiquidity(params[i]);
            } else if (action == Actions.SETTLE) {
                // Pay the requested amount, from the caller or from this contract's loose balance.
                (Currency currency, uint256 amount, bool payerIsUser) = abi.decode(params[i], (Currency, uint256, bool));
                _settle({
                    currency: currency,
                    payer: payerIsUser ? msg.sender : address(this),
                    amount: _mapSettleAmount({amount: amount, currency: currency})
                });
            } else if (action == Actions.SETTLE_PAIR) {
                // Pay both currencies' full debt from the caller.
                (Currency currency0, Currency currency1) = abi.decode(params[i], (Currency, Currency));
                _settle({currency: currency0, payer: msg.sender, amount: _fullDebt(currency0)});
                _settle({currency: currency1, payer: msg.sender, amount: _fullDebt(currency1)});
            } else if (action == Actions.TAKE_PAIR) {
                // Take both currencies' full credit to the recipient.
                (Currency currency0, Currency currency1, address recipient) =
                    abi.decode(params[i], (Currency, Currency, address));
                recipient = _mapRecipient(recipient);
                _take({currency: currency0, recipient: recipient, amount: _fullCredit(currency0)});
                _take({currency: currency1, recipient: recipient, amount: _fullCredit(currency1)});
            } else if (action == Actions.CLOSE_CURRENCY) {
                // Settle a debt or take a credit, whichever the currency's open delta is.
                Currency currency = abi.decode(params[i], (Currency));
                int256 delta = _delta[Currency.unwrap(currency)];
                if (delta < 0) _settle({currency: currency, payer: msg.sender, amount: uint256(-delta)});
                else _take({currency: currency, recipient: msg.sender, amount: uint256(delta)});
            } else if (action == Actions.SWEEP) {
                // Send this contract's whole loose balance of the currency, never the pool's reserves.
                (Currency currency, address to) = abi.decode(params[i], (Currency, address));
                uint256 balance = _looseBalance(currency);
                if (balance > 0) currency.transfer(_mapRecipient(to), balance);
            } else {
                // Any other action is outside what the hook encodes.
                revert BaseActionsRouter.UnsupportedAction(action);
            }
        }

        // Like PoolManager.unlock: every currency delta must be cleared before the batch returns.
        for (uint256 i; i < _touched.length; i++) {
            if (_delta[_touched[i]] != 0) revert IPoolManager.CurrencyNotSettled();
        }

        // Reset the batch state for the next call.
        delete _touched;
        _unlocked = false;
    }

    /// @notice Test helper: fees accrued to `tokenId`. They join the pool's reserves, so the caller funds this
    /// contract with them.
    /// @param tokenId The ID of the position.
    /// @param amount0 The token0 fees the position can collect.
    /// @param amount1 The token1 fees the position can collect.
    function setCollectableFees(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        // Only a live position accrues fees.
        require(_positions[tokenId].exists, "Position does not exist");
        PoolKey memory key = _positions[tokenId].poolKey;
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Swap the old fee amounts for the new ones in the pool's reserves.
        poolLocked[token0] = poolLocked[token0] - collectableAmount0[tokenId] + amount0;
        poolLocked[token1] = poolLocked[token1] - collectableAmount1[tokenId] + amount1;

        // Record the fees the position can collect.
        collectableAmount0[tokenId] = amount0;
        collectableAmount1[tokenId] = amount1;
    }

    /// @notice Test helper: a pool hook keeps `amount0`/`amount1` of the principal each nonzero-liquidity removal
    /// from `tokenId` would return (V4's `afterRemoveLiquidity` return delta), so the caller receives less than the
    /// position's principal. A take above the principal leaves a negative principal delta, which reverts like V4.
    /// @param tokenId The ID of the position.
    /// @param amount0 The token0 amount the hook keeps per removal.
    /// @param amount1 The token1 amount the hook keeps per removal.
    function setHookTakeOnRemove(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        // Record the per-removal take for both currencies.
        hookTakeOnRemove0[tokenId] = amount0;
        hookTakeOnRemove1[tokenId] = amount1;
    }

    /// @notice Test helper: make the synthetic pool hook also charge its take on collect-only decreases. V4
    /// dispatches `afterRemoveLiquidity` for a zero-liquidity decrease too, so a positive take there leaves a negative
    /// fee-excluded delta, which `validateMinOut` rejects even when the collected fees would cover it.
    /// @param takes Whether collect-only decreases are charged.
    function setHookTakesOnCollect(bool takes) external {
        // Toggle the collect-only take.
        hookTakesOnCollect = takes;
    }

    /// @notice Test helper: set the MockPoolManager that holds the pools' Slot0 and tick liquidity.
    /// @param pm The pool manager to read and write pool state through.
    function setPoolManager(MockPoolManager pm) external {
        // Point pool-state reads and writes at the given manager.
        poolManager = pm;
    }

    /// @notice Test helper: overwrite a live position's liquidity.
    /// @param tokenId The ID of the position.
    /// @param liquidity The liquidity to give the position.
    function setPositionLiquidity(uint256 tokenId, uint128 liquidity) external {
        // Only a live position has liquidity to overwrite.
        require(_positions[tokenId].exists, "Position does not exist");
        _positions[tokenId].liquidity = liquidity;
    }

    /// @notice Test helper: overwrite a live position's pool reserves, as swaps through its range would (e.g. to
    /// mark it to a moved price).
    /// @dev The caller keeps this contract's balances backing the new amounts. A burn pays the principal from the
    /// position's liquidity at the live price and reverts if these reserves cannot cover it.
    /// @param tokenId The ID of the position.
    /// @param amount0 The token0 reserves backing the position.
    /// @param amount1 The token1 reserves backing the position.
    function setPositionPrincipal(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        // Only a live position has reserves to overwrite.
        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");
        address token0 = Currency.unwrap(pos.poolKey.currency0);
        address token1 = Currency.unwrap(pos.poolKey.currency1);

        // Swap the position's old reserves for the new ones in the pool's totals.
        poolLocked[token0] = poolLocked[token0] - pos.amount0Locked + amount0;
        poolLocked[token1] = poolLocked[token1] - pos.amount1Locked + amount1;

        // Record the position's new reserves.
        pos.amount0Locked = amount0;
        pos.amount1Locked = amount1;
    }

    /// @notice Test helper: liquidity other LPs already hold at `tick`, which counts against V4's per-tick cap.
    /// @param key The pool the tick belongs to.
    /// @param tick The tick to write.
    /// @param liquidityGross The tick's gross liquidity.
    function setTickLiquidityGross(PoolKey calldata key, int24 tick, uint128 liquidityGross) external {
        // Write the tick's gross liquidity straight into the pool manager's storage.
        _writeTickGross({key: key, tick: tick, gross: liquidityGross});
    }

    //*********************************************************************//
    // -------------------------- external views ------------------------- //
    //*********************************************************************//

    /// @notice IPositionManager.getPoolAndPositionInfo: the position's pool and packed range info.
    /// @param tokenId The ID of the position.
    /// @return poolKey The pool the position belongs to.
    /// @return info The packed position info built from the pool key and range.
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory poolKey, PositionInfo info) {
        // Pack the stored range the way V4's PositionInfoLibrary does.
        Position memory pos = _positions[tokenId];
        return (pos.poolKey, PositionInfoLibrary.initialize(pos.poolKey, pos.tickLower, pos.tickUpper));
    }

    /// @notice IPositionManager.getPositionLiquidity: the position's live liquidity.
    /// @param tokenId The ID of the position.
    /// @return liquidity The position's liquidity.
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        // Read the stored liquidity.
        return _positions[tokenId].liquidity;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Adds `amount` to a currency's open delta for the current batch.
    /// @param currency The currency whose delta changes.
    /// @param amount The signed change (positive = credit to the caller, negative = debt).
    function _accountDelta(Currency currency, int256 amount) internal {
        // A zero change touches nothing.
        if (amount == 0) return;
        address token = Currency.unwrap(currency);

        // Track a currency the first time its delta leaves zero, so the batch end checks it.
        if (_delta[token] == 0) _touched.push(token);
        _delta[token] += amount;
    }

    /// @notice Adds exactly `liquidity` to a position, charging its rounded-up cost at the live price as debt.
    /// @param tokenId The ID of the position.
    /// @param liquidity The liquidity to add.
    /// @param amount0Max The most token0 the caller pays.
    /// @param amount1Max The most token1 the caller pays.
    function _addLiquidity(uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max) internal {
        // Only a live position takes liquidity.
        Position storage pos = _positions[tokenId];
        require(pos.exists, "Position does not exist");

        // Grow both range ticks first, so V4's per-tick cap applies.
        uint128 added = _toUint128(liquidity);
        _growTicks({pos: pos, liquidity: added});

        // Price the liquidity rounded up, and enforce the caller's maximums like `validateMaxIn`.
        (uint256 cost0, uint256 cost1) = _amountsFor({pos: pos, liquidity: added, roundUp: true});
        if (cost0 > amount0Max) revert SlippageCheck.MaximumAmountExceeded(amount0Max, _toUint128(cost0));
        if (cost1 > amount1Max) revert SlippageCheck.MaximumAmountExceeded(amount1Max, _toUint128(cost1));

        // Back the liquidity with the cost as reserves, owed by the caller.
        pos.liquidity += added;
        pos.amount0Locked += cost0;
        pos.amount1Locked += cost1;
        _accountDelta({currency: pos.poolKey.currency0, amount: -int256(cost0)});
        _accountDelta({currency: pos.poolKey.currency1, amount: -int256(cost1)});
    }

    /// @notice Credits a position's accrued fees to the batch and clears them.
    /// @param tokenId The ID of the position.
    function _creditFees(uint256 tokenId) internal {
        // Fees are owed to the caller as credit in each currency.
        PoolKey memory key = _positions[tokenId].poolKey;
        _accountDelta({currency: key.currency0, amount: int256(collectableAmount0[tokenId])});
        _accountDelta({currency: key.currency1, amount: int256(collectableAmount1[tokenId])});

        // The fees can only be collected once.
        collectableAmount0[tokenId] = 0;
        collectableAmount1[tokenId] = 0;
    }

    /// @notice Grows both range ticks' gross liquidity.
    /// @dev V4 caps each initialized tick's gross liquidity at `tickSpacingToMaxLiquidityPerTick`.
    /// @param pos The position whose range ticks grow.
    /// @param liquidity The liquidity added to each tick.
    function _growTicks(Position storage pos, uint128 liquidity) internal {
        // The per-tick cap depends only on the pool's tick spacing.
        uint128 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(pos.poolKey.tickSpacing);
        int24[2] memory ticks = [pos.tickLower, pos.tickUpper];
        for (uint256 i; i < 2; i++) {
            // Revert like V4 when a tick would pass the cap, then write the grown liquidity.
            uint256 gross = uint256(_tickGross({key: pos.poolKey, tick: ticks[i]})) + liquidity;
            if (gross > maxPerTick) revert Pool.TickLiquidityOverflow(ticks[i]);
            _writeTickGross({key: pos.poolKey, tick: ticks[i], gross: uint128(gross)});
        }
    }

    /// @notice Handles BURN_POSITION: removes the position's remaining liquidity, collects its fees and deletes it.
    /// @param data The ABI-encoded `(tokenId, amount0Min, amount1Min, hookData)` params.
    function _handleBurn(bytes memory data) internal {
        (
            uint256 tokenId,
            uint128 amount0Min,
            uint128 amount1Min, /* hookData */
        ) = abi.decode(data, (uint256, uint128, uint128, bytes));

        // Count the call, then require a live position owned by the caller.
        burnCallCount++;
        require(_positions[tokenId].exists, "Position does not exist");
        _requireApproved(tokenId);

        // Record the minimums so tests can check what the hook asked for.
        lastMin0Of[tokenId] = amount0Min;
        lastMin1Of[tokenId] = amount1Min;

        // Like V4, a burn only touches the pool (and collects fees) when liquidity remains.
        uint128 liquidity = _positions[tokenId].liquidity;
        if (liquidity > 0) {
            _removeLiquidity({tokenId: tokenId, liquidity: liquidity, amount0Min: amount0Min, amount1Min: amount1Min});
            _creditFees(tokenId);
        }

        // Whatever reserves the rounded-down principal left behind stay in the pool.
        delete _positions[tokenId];
        delete ownerOf[tokenId];
    }

    /// @notice Handles DECREASE_LIQUIDITY: removes part of a position's liquidity and collects its fees.
    /// @param data The ABI-encoded `(tokenId, liquidity, amount0Min, amount1Min, hookData)` params.
    function _handleDecreaseLiquidity(bytes memory data) internal {
        (
            uint256 tokenId,
            uint256 liquidity,
            uint128 amount0Min,
            uint128 amount1Min, /* hookData */
        ) = abi.decode(data, (uint256, uint256, uint128, uint128, bytes));

        // Count the call, then require a live position owned by the caller.
        decreaseLiquidityCallCount++;
        require(_positions[tokenId].exists, "Position does not exist");
        _requireApproved(tokenId);

        // Record the minimums so tests can check what the hook asked for.
        lastMin0Of[tokenId] = amount0Min;
        lastMin1Of[tokenId] = amount1Min;

        // Remove the liquidity, checked against the minimums.
        _removeLiquidity({
            tokenId: tokenId, liquidity: _toUint128(liquidity), amount0Min: amount0Min, amount1Min: amount1Min
        });

        // Fees are always owed regardless of liquidity amount (0 = collect-only).
        _creditFees(tokenId);
    }

    /// @notice Handles INCREASE_LIQUIDITY: adds liquidity to a position the caller owns and collects its fees.
    /// @param data The ABI-encoded `(tokenId, liquidity, amount0Max, amount1Max, hookData)` params.
    function _handleIncreaseLiquidity(bytes memory data) internal {
        (
            uint256 tokenId,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max, /* hookData */
        ) = abi.decode(data, (uint256, uint256, uint128, uint128, bytes));

        // Count the call, then require the caller to own the position before adding to it.
        increaseCallCount++;
        _requireApproved(tokenId);
        _addLiquidity({tokenId: tokenId, liquidity: liquidity, amount0Max: amount0Max, amount1Max: amount1Max});

        // Increasing also collects the position's accrued fees, which are excluded from the max check.
        _creditFees(tokenId);
    }

    /// @notice Handles MINT_POSITION: validates the range and mints a position with the requested liquidity.
    /// @param data The ABI-encoded `(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)`
    /// params.
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

        // Count the call and assign the next token ID to the requested owner.
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

        // Create the empty position, then add the liquidity through the shared pricing path.
        _positions[tokenId] = Position({
            poolKey: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: 0,
            amount0Locked: 0,
            amount1Locked: 0,
            exists: true
        });
        _addLiquidity({tokenId: tokenId, liquidity: liquidity, amount0Max: amount0Max, amount1Max: amount1Max});
    }

    /// @notice Removes `liquidity` from a position, crediting its rounded-down principal at the live price less any
    /// pool-hook take.
    /// @dev The signed delta is checked like V4's `validateMinOut`, which casts the fee-excluded delta with
    /// `SafeCast.toUint128`.
    /// @param tokenId The ID of the position.
    /// @param liquidity The liquidity to remove.
    /// @param amount0Min The least token0 the caller accepts.
    /// @param amount1Min The least token1 the caller accepts.
    function _removeLiquidity(uint256 tokenId, uint128 liquidity, uint128 amount0Min, uint128 amount1Min) internal {
        // A position cannot give up more liquidity than it has.
        Position storage pos = _positions[tokenId];
        require(liquidity <= pos.liquidity, "liquidity underflow");

        // Price the liquidity rounded down.
        (uint256 principal0, uint256 principal1) = _amountsFor({pos: pos, liquidity: liquidity, roundUp: false});

        // The pool can only return reserves it holds for this position: a test moving the price must mark it.
        require(
            principal0 <= pos.amount0Locked && principal1 <= pos.amount1Locked,
            "principal exceeds the position's reserves; mark it to the moved price"
        );

        // Release the principal from the position's reserves and shrink its ticks.
        pos.amount0Locked -= principal0;
        pos.amount1Locked -= principal1;
        pos.liquidity -= liquidity;
        _shrinkTicks({pos: pos, liquidity: liquidity});

        // By default the synthetic pool hook takes only from removals that move liquidity (a fee-only collect then
        // returns a zero principal delta); `hookTakesOnCollect` charges collect-only decreases as well.
        (uint256 take0, uint256 take1) =
            liquidity == 0 && !hookTakesOnCollect ? (0, 0) : (hookTakeOnRemove0[tokenId], hookTakeOnRemove1[tokenId]);

        // Principal and takes are token amounts far below 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 out0 = int256(principal0) - int256(take0);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 out1 = int256(principal1) - int256(take1);

        // Enforce the minimums on the fee-excluded delta, then credit it to the batch.
        _validateMinOut({delta: out0, amountMin: amount0Min});
        _validateMinOut({delta: out1, amountMin: amount1Min});
        _accountDelta({currency: pos.poolKey.currency0, amount: out0});
        _accountDelta({currency: pos.poolKey.currency1, amount: out1});
    }

    /// @notice Pays `amount` of a currency into the pool's reserves.
    /// @dev Like `PoolManager.settle`, the credit is what the reserves actually received, so a short transfer leaves
    /// debt. Native comes out of the loose balance (V4 forwards it as `msg.value`). A self payer pays an ERC-20 from
    /// the loose balance with `CurrencyLibrary.transfer`, as V4's `PositionManager._pay` does to the PoolManager; the
    /// pool's reserves share this address, so the transfer is to self and the reserves are credited the amount less
    /// what the transfer cost this contract (a token that treats self-transfers specially would diverge). A user
    /// payer is pulled through Permit2.
    /// @param currency The currency to pay.
    /// @param payer The address paying, or this contract for a self payer.
    /// @param amount The amount to pay.
    function _settle(Currency currency, address payer, uint256 amount) internal {
        // A zero settle moves nothing.
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        uint256 received = amount;

        if (currency.isAddressZero()) {
            // Native is already held as loose balance, so it only needs to be there.
            require(_looseBalance(currency) >= amount, "settle: insufficient balance");
        } else if (payer == address(this)) {
            // A self payer's transfer is to self; whatever it costs this contract reduces the credit.
            require(_looseBalance(currency) >= amount, "settle: insufficient balance");
            uint256 balanceBefore = currency.balanceOfSelf();
            currency.transfer(address(this), amount);
            received = amount - (balanceBefore - currency.balanceOfSelf());
        } else {
            // A user payer is pulled through Permit2 and credited only what arrived.
            uint256 balanceBefore = currency.balanceOfSelf();
            _PERMIT2.transferFrom(payer, address(this), _toUint160(amount), token);
            received = currency.balanceOfSelf() - balanceBefore;
        }

        // What arrived joins the reserves and pays down the batch's debt.
        poolLocked[token] += received;
        _accountDelta({currency: currency, amount: int256(received)});
    }

    /// @notice Shrinks both range ticks' gross liquidity.
    /// @param pos The position whose range ticks shrink.
    /// @param liquidity The liquidity removed from each tick.
    function _shrinkTicks(Position storage pos, uint128 liquidity) internal {
        // Lower each tick's gross liquidity by the removed amount.
        _writeTickGross({
            key: pos.poolKey,
            tick: pos.tickLower,
            gross: _tickGross({key: pos.poolKey, tick: pos.tickLower}) - liquidity
        });
        _writeTickGross({
            key: pos.poolKey,
            tick: pos.tickUpper,
            gross: _tickGross({key: pos.poolKey, tick: pos.tickUpper}) - liquidity
        });
    }

    /// @notice Writes packed Slot0 data into MockPoolManager at the pool's state slot.
    /// @param key The pool to sync.
    /// @param sqrtPriceX96 The pool's sqrt price.
    function _syncSlot0(PoolKey calldata key, uint160 sqrtPriceX96) internal {
        // `pools` sits at slot 6 of the PoolManager, so the pool's state lives at keccak(poolId, 6).
        bytes32 poolId = PoolId.unwrap(key.toId());
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        uint24 lpFee = key.fee;
        // Pack: lpFee (24) | protocolFee (24) | tick (24) | sqrtPriceX96 (160)
        // Safe: tick fits in uint24 after masking; uint24(tick) is standard V4 packing.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 packed = bytes32((uint256(lpFee) << 208) | (uint256(uint24(tick)) << 160) | uint256(sqrtPriceX96));
        poolManager.writeSlot({slot: stateSlot, value: packed});
    }

    /// @notice Takes `amount` of a currency out of the pool's reserves to `recipient`.
    /// @dev Never pays from another position's stock or the loose balance.
    /// @param currency The currency to take.
    /// @param recipient The address receiving it.
    /// @param amount The amount to take.
    function _take(Currency currency, address recipient, uint256 amount) internal {
        // A zero take moves nothing.
        if (amount == 0) return;
        address token = Currency.unwrap(currency);

        // The reserves must be fully backed by this contract's balance before paying out of them.
        require(currency.balanceOfSelf() >= poolLocked[token], "take: pool reserves unbacked");

        // Release the reserves, reduce the batch's credit, then pay.
        poolLocked[token] -= amount;
        _accountDelta({currency: currency, amount: -int256(amount)});
        currency.transfer(recipient, amount);
    }

    /// @notice Writes `pools[id].ticks[tick].liquidityGross` (low 128 bits), keeping `liquidityNet`.
    /// @param key The pool the tick belongs to.
    /// @param tick The tick to write.
    /// @param gross The tick's gross liquidity.
    function _writeTickGross(PoolKey memory key, int24 tick, uint128 gross) internal {
        // Locate the tick's info slot under the pool's state, as StateLibrary does.
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), StateLibrary.POOLS_SLOT));
        bytes32 slot =
            keccak256(abi.encodePacked(int256(tick), bytes32(uint256(stateSlot) + StateLibrary.TICKS_OFFSET)));

        // Replace the low 128 bits and keep the high 128 bits (`liquidityNet`).
        uint256 word = uint256(poolManager.extsload(slot));
        poolManager.writeSlot({slot: slot, value: bytes32((word >> 128 << 128) | gross)});
    }

    //*********************************************************************//
    // ------------------------- internal helpers ------------------------ //
    //*********************************************************************//

    /// @notice Casts to uint128, reverting on overflow.
    /// @param value The value to cast.
    /// @return result The value as a uint128.
    function _toUint128(uint256 value) internal pure returns (uint128 result) {
        // Reject values that would truncate.
        require(value <= type(uint128).max, "uint128 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    /// @notice Casts to uint160, reverting on overflow.
    /// @param value The value to cast.
    /// @return result The value as a uint160.
    function _toUint160(uint256 value) internal pure returns (uint160 result) {
        // Reject values that would truncate.
        require(value <= type(uint160).max, "uint160 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(value);
    }

    /// @notice `SlippageCheck.validateMinOut` for one currency: the signed principal delta must cast to uint128 and
    /// meet the minimum.
    /// @param delta The signed fee-excluded principal delta.
    /// @param amountMin The least the caller accepts.
    function _validateMinOut(int256 delta, uint128 amountMin) internal pure {
        // A negative or oversized delta fails the cast, like `SafeCast.toUint128`.
        if (delta < 0 || delta > int256(uint256(type(uint128).max))) revert SafeCast.SafeCastOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 received = uint128(uint256(delta));
        if (received < amountMin) revert SlippageCheck.MinimumAmountInsufficient(amountMin, received);
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Token amounts for `liquidity` over the position's range at the live price.
    /// @dev Branches on the live tick like v4-core's `Pool.modifyLiquidity`.
    /// @param pos The position whose range is priced.
    /// @param liquidity The liquidity to price.
    /// @param roundUp Whether to round up (adding) or down (removing).
    /// @return amount0 The token0 amount.
    /// @return amount1 The token1 amount.
    function _amountsFor(
        Position storage pos,
        uint128 liquidity,
        bool roundUp
    )
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        // Read the live price; an uninitialized pool cannot price liquidity.
        (uint160 sqrtPriceX96, int24 tick,,) =
            StateLibrary.getSlot0(IPoolManager(address(poolManager)), pos.poolKey.toId());
        if (sqrtPriceX96 == 0) revert Pool.PoolNotInitialized();
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(pos.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(pos.tickUpper);

        if (tick < pos.tickLower) {
            // Below the range the position is all token0.
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
        } else if (tick < pos.tickUpper) {
            // Inside the range the position holds both tokens, split at the live price.
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, roundUp);
        } else {
            // At or above the range the position is all token1.
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
        }
    }

    /// @notice A currency's full open credit in the batch.
    /// @param currency The currency to read.
    /// @return credit The credit owed to the caller.
    function _fullCredit(Currency currency) internal view returns (uint256 credit) {
        // Taking credit from a currency in debt reverts like V4's DeltaResolver.
        int256 delta = _delta[Currency.unwrap(currency)];
        if (delta < 0) revert DeltaResolver.DeltaNotPositive(currency);
        return uint256(delta);
    }

    /// @notice A currency's full open debt in the batch.
    /// @param currency The currency to read.
    /// @return debt The debt the caller owes.
    function _fullDebt(Currency currency) internal view returns (uint256 debt) {
        // Paying debt for a currency in credit reverts like V4's DeltaResolver.
        int256 delta = _delta[Currency.unwrap(currency)];
        if (delta > 0) revert DeltaResolver.DeltaNotNegative(currency);
        return uint256(-delta);
    }

    /// @notice This contract's own balance of a currency, apart from the pool's reserves (what SWEEP moves).
    /// @param currency The currency to read.
    /// @return balance The loose balance.
    function _looseBalance(Currency currency) internal view returns (uint256 balance) {
        // Everything above the pool's reserves is loose.
        return currency.balanceOfSelf() - poolLocked[Currency.unwrap(currency)];
    }

    /// @notice Resolves V4's recipient sentinels to real addresses.
    /// @param recipient The requested recipient, possibly a sentinel.
    /// @return resolved The caller for `MSG_SENDER`, this contract for `ADDRESS_THIS`, otherwise `recipient`.
    function _mapRecipient(address recipient) internal view returns (address resolved) {
        // Map the two sentinels the way V4's BaseActionsRouter does.
        if (recipient == ActionConstants.MSG_SENDER) return msg.sender;
        if (recipient == ActionConstants.ADDRESS_THIS) return address(this);
        return recipient;
    }

    /// @notice Resolves V4's SETTLE amount sentinels to a concrete amount.
    /// @param amount The requested amount, possibly a sentinel.
    /// @param currency The currency being settled.
    /// @return resolved The loose balance for `CONTRACT_BALANCE`, the full debt for `OPEN_DELTA`, otherwise `amount`.
    function _mapSettleAmount(uint256 amount, Currency currency) internal view returns (uint256 resolved) {
        // Map the two sentinels the way V4's DeltaResolver does.
        if (amount == ActionConstants.CONTRACT_BALANCE) return _looseBalance(currency);
        if (amount == ActionConstants.OPEN_DELTA) return _fullDebt(currency);
        return amount;
    }

    /// @notice Reverts unless the caller owns the position.
    /// @param tokenId The ID of the position.
    function _requireApproved(uint256 tokenId) internal view {
        // Only the owner may modify a position.
        if (ownerOf[tokenId] != msg.sender) revert IPositionManager.NotApproved(msg.sender);
    }

    /// @notice A tick's gross liquidity, read from the pool manager.
    /// @param key The pool the tick belongs to.
    /// @param tick The tick to read.
    /// @return gross The tick's gross liquidity.
    function _tickGross(PoolKey memory key, int24 tick) internal view returns (uint128 gross) {
        // Read through StateLibrary, as the hook does.
        (gross,) = StateLibrary.getTickLiquidity(IPoolManager(address(poolManager)), key.toId(), tick);
    }
}
