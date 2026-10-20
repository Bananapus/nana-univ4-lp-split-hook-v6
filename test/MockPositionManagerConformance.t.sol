// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {MockERC20} from "./mock/MockERC20.sol";
import {MockPoolManager} from "./mock/MockPoolManager.sol";
import {MockPositionManager} from "./mock/MockPositionManager.sol";
import {MockPermit2} from "./TestBaseV4.sol";

/// @notice An ERC-20 that keeps `taxBps` of every transfer, returns nothing from `transfer` (USDT-style), and returns
/// `true`, `false` (after moving the tokens) or nothing from `transferFrom`, per `transferFromReturn`.
contract QuirkToken {
    /// @notice The `transferFromReturn` mode in which `transferFrom` moves the tokens and returns `false`.
    uint8 internal constant _RETURN_FALSE = 1;

    /// @notice The `transferFromReturn` mode in which `transferFrom` moves the tokens and returns no data.
    uint8 internal constant _RETURN_NOTHING = 2;

    /// @notice The `transferFromReturn` mode in which `transferFrom` moves the tokens and returns `true`.
    uint8 internal constant _RETURN_TRUE = 0;

    /// @notice How many tokens each spender may still pull from each owner.
    /// @custom:param owner The account the tokens are pulled from.
    /// @custom:param spender The account allowed to pull them.
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    /// @notice The token balance of each account.
    /// @custom:param account The account whose balance is held.
    mapping(address account => uint256) public balanceOf;

    /// @notice The share of every transfer the token keeps, in basis points.
    uint256 public taxBps;

    /// @notice What `transferFrom` returns: `_RETURN_TRUE`, `_RETURN_FALSE` or `_RETURN_NOTHING`.
    uint8 public transferFromReturn;

    /// @notice Let `spender` pull up to `amount` of the caller's tokens.
    /// @param spender The account allowed to pull the tokens.
    /// @param amount The allowance to set.
    /// @return approved Always `true`.
    function approve(address spender, uint256 amount) external returns (bool approved) {
        // Overwrite the allowance outright, as a plain ERC-20 does.
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @notice Create `amount` tokens for `to`.
    /// @param to The account credited.
    /// @param amount The number of tokens created.
    function mint(address to, uint256 amount) external {
        // Credit the balance without any supply bookkeeping; the tests only read balances.
        balanceOf[to] += amount;
    }

    /// @notice Set the share of every transfer the token keeps.
    /// @param bps The kept share, in basis points.
    function setTaxBps(uint256 bps) external {
        // Every later transfer delivers `amount - amount * bps / 10_000`.
        taxBps = bps;
    }

    /// @notice Set what `transferFrom` returns.
    /// @param mode `_RETURN_TRUE` (0), `_RETURN_FALSE` (1) or `_RETURN_NOTHING` (2).
    function setTransferFromReturn(uint8 mode) external {
        // Every later `transferFrom` moves the tokens, then answers per this mode.
        transferFromReturn = mode;
    }

    /// @notice Move `amount` of the caller's tokens to `to`, keeping the tax, and return no data (USDT-style).
    /// @param to The account credited.
    /// @param amount The number of tokens debited from the caller.
    function transfer(address to, uint256 amount) external {
        // Debit the full amount but credit only what is left after the tax.
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount - amount * taxBps / 10_000;
    }

    /// @notice Move `amount` of `from`'s tokens to `to` against the caller's allowance, keeping the tax, then return
    /// per `transferFromReturn`.
    /// @param from The account debited.
    /// @param to The account credited.
    /// @param amount The number of tokens debited from `from`.
    /// @return succeeded `true` in `_RETURN_TRUE` mode and `false` in `_RETURN_FALSE` mode; nothing is returned in
    /// `_RETURN_NOTHING` mode.
    function transferFrom(address from, address to, uint256 amount) external returns (bool succeeded) {
        // Spend the allowance, debit the full amount and credit only what is left after the tax.
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - amount * taxBps / 10_000;
        // Return empty returndata so callers see a token that answers nothing, after the tokens moved.
        if (transferFromReturn == _RETURN_NOTHING) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        // Report success or failure even though the tokens moved either way.
        return transferFromReturn == _RETURN_TRUE;
    }
}

/// @notice Direct conformance checks for the MockPositionManager's delta-resolution branches the hook rarely encodes
/// (SETTLE_PAIR, TAKE_PAIR, CLOSE_CURRENCY), its measured settlement, its v4 `CurrencyLibrary.transfer` payouts and its
/// signed removal deltas, each against the v4-core/periphery semantics it models.
contract MockPositionManagerConformanceTest is Test {
    /// @notice The liquidity every test position mints.
    uint128 internal constant _LIQUIDITY = 1e18;

    /// @notice The lower tick of every test position.
    int24 internal constant _LOWER = -200;

    /// @notice The canonical Permit2 address, where the mock Permit2 is etched.
    address internal constant _PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice The upper tick of every test position.
    int24 internal constant _UPPER = 200;

    /// @notice The mock PoolManager the PositionManager settles against.
    MockPoolManager internal _poolManager;

    /// @notice The PositionManager under test.
    MockPositionManager internal _positionManager;

    /// @notice The quirky ERC-20 used for transfer-tax and return-value cases.
    QuirkToken internal _quirk;

    /// @notice The account TAKE_PAIR pays out to.
    address internal _recipient = makeAddr("recipient");

    /// @notice The plain ERC-20 every test pool pairs against.
    MockERC20 internal _tokenA;

    /// @notice Etch the mock Permit2 and deploy the PoolManager, PositionManager and both test tokens.
    function setUp() public {
        // Put Permit2 at its canonical address, where the PositionManager pulls through it.
        vm.etch(_PERMIT2, address(new MockPermit2()).code);
        // Wire a fresh PositionManager to a fresh PoolManager.
        _poolManager = new MockPoolManager();
        _positionManager = new MockPositionManager();
        _positionManager.setPoolManager(_poolManager);
        // Deploy the plain and the quirky test tokens.
        _tokenA = new MockERC20("A", "A", 18);
        _quirk = new QuirkToken();
    }

    /// @notice SETTLE_PAIR pays both rounded-up costs from the caller through Permit2 into the pool's reserves (the
    /// trailing CLOSE_CURRENCY then finds a zero delta and does nothing).
    function test_SettlePair_PaysBothCostsFromTheCaller() public {
        // Pair `_tokenA` with a fresh plain token and fund both.
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        uint256 before0 = _balance({currency: key.currency0, who: address(this)});
        uint256 before1 = _balance({currency: key.currency1, who: address(this)});

        // Mint, then settle both currencies in one action.
        _settlePair(key);

        // The caller paid the rounded-up mint cost on each side, and the reserves hold exactly it.
        assertEq(before0 - _balance({currency: key.currency0, who: address(this)}), _amount0(true), "token0 cost paid");
        assertEq(before1 - _balance({currency: key.currency1, who: address(this)}), _amount1(true), "token1 cost paid");
        assertEq(_positionManager.poolLocked(Currency.unwrap(key.currency0)), _amount0(true), "token0 in reserves");
        assertEq(_positionManager.poolLocked(Currency.unwrap(key.currency1)), _amount1(true), "token1 in reserves");
    }

    /// @notice SETTLE_PAIR refuses a currency that is owed to the caller rather than by it.
    function test_SettlePair_RevertsOnCredit() public {
        // Mint a settled position to burn.
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        _settlePair(key);
        uint256 tokenId = _positionManager.lastMintTokenId();
        // A burn leaves credits, so SETTLE_PAIR rejects the first currency as not negative.
        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotNegative.selector, key.currency0));
        _burnThen({
            tokenId: tokenId,
            resolve: bytes1(uint8(Actions.SETTLE_PAIR)),
            resolveParams: abi.encode(key.currency0, key.currency1),
            resolve2: bytes1(uint8(Actions.TAKE_PAIR)),
            resolve2Params: abi.encode(key.currency0, key.currency1, _recipient)
        });
    }

    /// @notice TAKE_PAIR pays both rounded-down principals to the named recipient; only the rounding stays pooled.
    function test_TakePair_PaysBothPrincipalsToTheRecipient() public {
        // Mint a settled position to burn.
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        _settlePair(key);
        uint256 tokenId = _positionManager.lastMintTokenId();

        // Burn it and take both credits to the recipient; the trailing close finds nothing left.
        _burnThen({
            tokenId: tokenId,
            resolve: bytes1(uint8(Actions.TAKE_PAIR)),
            resolveParams: abi.encode(key.currency0, key.currency1, _recipient),
            resolve2: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolve2Params: abi.encode(key.currency1)
        });

        // The recipient got the rounded-down principals, and the rounding difference stays in the reserves.
        assertEq(_balance({currency: key.currency0, who: _recipient}), _amount0(false), "token0 principal taken");
        assertEq(_balance({currency: key.currency1, who: _recipient}), _amount1(false), "token1 principal taken");
        assertEq(
            _positionManager.poolLocked(Currency.unwrap(key.currency0)),
            _amount0(true) - _amount0(false),
            "token0 rounding stays pooled"
        );
        assertEq(
            _positionManager.poolLocked(Currency.unwrap(key.currency1)),
            _amount1(true) - _amount1(false),
            "token1 rounding stays pooled"
        );
    }

    /// @notice TAKE_PAIR refuses a currency the caller still owes.
    function test_TakePair_RevertsOnDebt() public {
        // Pair and fund, but do not settle.
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        // A mint leaves debts, so TAKE_PAIR rejects the first currency as not positive.
        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotPositive.selector, key.currency0));
        _mintThen({
            key: key,
            resolve: bytes1(uint8(Actions.TAKE_PAIR)),
            resolveParams: abi.encode(key.currency0, key.currency1, _recipient),
            resolve2: bytes1(uint8(Actions.SETTLE_PAIR)),
            resolve2Params: abi.encode(key.currency0, key.currency1)
        });
    }

    /// @notice CLOSE_CURRENCY settles a debt from the caller after a mint and takes a credit to the caller after a
    /// burn.
    function test_CloseCurrency_SettlesDebtAndTakesCredit() public {
        // Pair and fund, recording the caller's balances.
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        uint256 before0 = _balance({currency: key.currency0, who: address(this)});
        uint256 before1 = _balance({currency: key.currency1, who: address(this)});

        // Mint and close each currency: both debts are settled from the caller.
        _mintThen({
            key: key,
            resolve: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolveParams: abi.encode(key.currency0),
            resolve2: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolve2Params: abi.encode(key.currency1)
        });
        assertEq(
            before0 - _balance({currency: key.currency0, who: address(this)}),
            _amount0(true),
            "close settled token0 debt"
        );
        assertEq(
            before1 - _balance({currency: key.currency1, who: address(this)}),
            _amount1(true),
            "close settled token1 debt"
        );

        // Burn and close each currency: both credits are taken back to the caller, net of rounding.
        _burnThen({
            tokenId: _positionManager.lastMintTokenId(),
            resolve: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolveParams: abi.encode(key.currency0),
            resolve2: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolve2Params: abi.encode(key.currency1)
        });
        assertEq(
            before0 - _balance({currency: key.currency0, who: address(this)}),
            _amount0(true) - _amount0(false),
            "close took token0"
        );
        assertEq(
            before1 - _balance({currency: key.currency1, who: address(this)}),
            _amount1(true) - _amount1(false),
            "close took token1"
        );
    }

    /// @notice An unsettled delta fails the whole batch, like `PoolManager.unlock`.
    function test_UnsettledDelta_Reverts() public {
        // Pair and fund.
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        // Closing currency0 twice leaves currency1's debt open, so the unlock reverts.
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        _mintThen({
            key: key,
            resolve: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolveParams: abi.encode(key.currency0),
            resolve2: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolve2Params: abi.encode(key.currency0)
        });
    }

    /// @notice Settlement credits what the reserves received, as `PoolManager.settle` does: a token that keeps a
    /// transfer tax leaves debt and the batch reverts, while the same mint of untaxed tokens settles.
    function test_Settle_CreditsMeasuredReceipt() public {
        // A 1% tax delivers less than the cost, so the measured settlement leaves debt.
        PoolKey memory key = _pool(address(_quirk));
        _quirk.setTaxBps(100);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        _settlePair(key);

        // Without the tax the same mint settles, and the reserves hold exactly the quirky side's cost.
        _quirk.setTaxBps(0);
        _settlePair(key);
        assertEq(
            _positionManager.poolLocked(address(_quirk)),
            address(_quirk) < address(_tokenA) ? _amount0(true) : _amount1(true)
        );
    }

    /// @notice Payouts use v4's `CurrencyLibrary.transfer`: a token whose `transfer` returns nothing still pays, and
    /// one whose `transfer` returns false reverts with v4's wrapped `ERC20TransferFailed`.
    function test_Take_TransferReturnHandling() public {
        // Mint a settled position against the quirky token.
        PoolKey memory key = _pool(address(_quirk));
        _settlePair(key);
        uint256 tokenId = _positionManager.lastMintTokenId();
        bytes memory takePair = abi.encode(key.currency0, key.currency1, _recipient);

        // The quirky `transfer` returns nothing, yet the take still pays the recipient.
        uint256 snapshot = vm.snapshotState();
        _burnThen({
            tokenId: tokenId,
            resolve: bytes1(uint8(Actions.TAKE_PAIR)),
            resolveParams: takePair,
            resolve2: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolve2Params: abi.encode(key.currency0)
        });
        bool quirkIs0 = address(_quirk) < address(_tokenA);
        assertEq(_quirk.balanceOf(_recipient), quirkIs0 ? _amount0(false) : _amount1(false), "empty return still pays");
        vm.revertToState(snapshot);

        // From the same state, a `transfer` of `_tokenA` that returns false reverts with v4's wrapped error.
        vm.mockCall(address(_tokenA), abi.encodeWithSelector(MockERC20.transfer.selector), abi.encode(false));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(_tokenA),
                MockERC20.transfer.selector,
                abi.encode(false),
                abi.encodePacked(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        _burnThen({
            tokenId: tokenId,
            resolve: bytes1(uint8(Actions.TAKE_PAIR)),
            resolveParams: takePair,
            resolve2: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolve2Params: abi.encode(key.currency0)
        });
    }

    /// @notice A pool-hook take is subtracted from the signed principal delta: up to the principal it passes (and the
    /// caller receives the rest), past it the negative delta reverts `SafeCastOverflow` like `validateMinOut`.
    function test_RemovalDelta_IsSignedAndValidated() public {
        // Mint a settled position to burn.
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        _settlePair(key);
        uint256 tokenId = _positionManager.lastMintTokenId();
        bytes memory takePair = abi.encode(key.currency0, key.currency1, _recipient);

        // A hook take of exactly the token0 principal passes and leaves the recipient no token0.
        uint256 snapshot = vm.snapshotState();
        _positionManager.setHookTakeOnRemove({tokenId: tokenId, amount0: _amount0(false), amount1: 0});
        _burnThen({
            tokenId: tokenId,
            resolve: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolveParams: abi.encode(key.currency1),
            resolve2: bytes1(uint8(Actions.TAKE_PAIR)),
            resolve2Params: takePair
        });
        assertEq(_balance({currency: key.currency0, who: _recipient}), 0, "the hook took all token0 principal");
        vm.revertToState(snapshot);

        // One unit more makes the token0 delta negative, which the min-out validation rejects.
        _positionManager.setHookTakeOnRemove({tokenId: tokenId, amount0: _amount0(false) + 1, amount1: 0});
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        _burnThen({
            tokenId: tokenId,
            resolve: bytes1(uint8(Actions.TAKE_PAIR)),
            resolveParams: takePair,
            resolve2: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolve2Params: abi.encode(key.currency1)
        });
    }

    /// @notice A pool-hook take on a collect-only decrease (V4 dispatches `afterRemoveLiquidity` for it too) leaves a
    /// negative fee-excluded delta that `validateMinOut` rejects with `SafeCastOverflow`, even though the collected
    /// fees would cover it. With collect-only takes off (the default) the same collect pays the fees in full.
    function test_CollectOnlyTake_IsSignedAndValidated() public {
        // Mint a settled position, give it a funded token0 fee of 10 and a pool-hook take of 1.
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        _settlePair(key);
        uint256 tokenId = _positionManager.lastMintTokenId();
        MockERC20(Currency.unwrap(key.currency0)).mint({to: address(_positionManager), amount: 10});
        _positionManager.setCollectableFees({tokenId: tokenId, amount0: 10, amount1: 0});
        _positionManager.setHookTakeOnRemove({tokenId: tokenId, amount0: 1, amount1: 0});

        // A zero-liquidity decrease collects the fees, then TAKE_PAIR pays them to the recipient.
        bytes memory actions =
            abi.encodePacked(bytes1(uint8(Actions.DECREASE_LIQUIDITY)), bytes1(uint8(Actions.TAKE_PAIR)));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, _recipient);
        bytes memory unlockData = abi.encode(actions, params);

        // With collect-only takes off, the collect pays every fee.
        uint256 snapshot = vm.snapshotState();
        _positionManager.modifyLiquidities({unlockData: unlockData, deadline: block.timestamp});
        assertEq(_balance({currency: key.currency0, who: _recipient}), 10, "default: the collect pays every fee");
        vm.revertToState(snapshot);

        // With them on, the take makes the fee-excluded delta negative and the collect reverts.
        _positionManager.setHookTakesOnCollect(true);
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        _positionManager.modifyLiquidities({unlockData: unlockData, deadline: block.timestamp});
    }

    /// @notice Permit2 pulls with safe-transfer semantics: a `transferFrom` that moves the tokens but returns `false`
    /// reverts `TRANSFER_FROM_FAILED`, while one that returns nothing settles the exact cost.
    function test_Permit2Pull_TransferFromReturnHandling() public {
        // Pair against the quirky token and note the quirky side's mint cost.
        PoolKey memory key = _pool(address(_quirk));
        uint256 cost = address(_quirk) < address(_tokenA) ? _amount0(true) : _amount1(true);

        // A `transferFrom` that returns false fails the Permit2 pull.
        _quirk.setTransferFromReturn(1);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        _settlePair(key);

        // A `transferFrom` that returns nothing pays and settles exactly the cost.
        _quirk.setTransferFromReturn(2);
        uint256 before = _quirk.balanceOf(address(this));
        _settlePair(key);
        assertEq(before - _quirk.balanceOf(address(this)), cost, "empty return pays the cost");
        assertEq(_positionManager.poolLocked(address(_quirk)), cost, "empty return settles the cost");
    }

    /// @notice A self-payer SETTLE pays from the PositionManager's own balance with a measured transfer, as V4's
    /// `_pay` does: a token that keeps a transfer tax leaves debt and the batch reverts, while an untaxed one settles
    /// the exact cost from the loose balance and nothing from the caller.
    function test_SelfPayerSettle_CreditsMeasuredTransfer() public {
        // Give the PositionManager a loose quirky balance, and build a self-payer SETTLE of the full open delta.
        PoolKey memory key = _pool(address(_quirk));
        _quirk.mint({to: address(_positionManager), amount: 10e18});
        Currency quirkCurrency = Currency.wrap(address(_quirk));
        Currency other = key.currency0 == quirkCurrency ? key.currency1 : key.currency0;
        uint256 cost = address(_quirk) < address(_tokenA) ? _amount0(true) : _amount1(true);
        bytes memory selfSettle = abi.encode(quirkCurrency, ActionConstants.OPEN_DELTA, false);

        // A 1% tax delivers less than the cost to the reserves, so the measured settlement leaves debt.
        _quirk.setTaxBps(100);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        _mintThen({
            key: key,
            resolve: bytes1(uint8(Actions.SETTLE)),
            resolveParams: selfSettle,
            resolve2: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolve2Params: abi.encode(other)
        });

        // Without the tax the self-payer settles exactly the cost from the loose balance.
        _quirk.setTaxBps(0);
        uint256 callerBefore = _quirk.balanceOf(address(this));
        _mintThen({
            key: key,
            resolve: bytes1(uint8(Actions.SETTLE)),
            resolveParams: selfSettle,
            resolve2: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolve2Params: abi.encode(other)
        });
        assertEq(_positionManager.poolLocked(address(_quirk)), cost, "the reserves hold the cost");
        assertEq(
            _quirk.balanceOf(address(_positionManager)) - _positionManager.poolLocked(address(_quirk)),
            10e18 - cost,
            "paid from the loose balance"
        );
        assertEq(_quirk.balanceOf(address(this)), callerBefore, "nothing pulled from the caller");
    }

    // ─── Helpers ───

    /// @notice v4's rounded-up mint cost (`up`) or rounded-down principal of token0 for `_LIQUIDITY` at tick 0.
    /// @param up Whether to round up (the mint cost) or down (the burn principal).
    /// @return amount0 The token0 amount across [0, `_UPPER`].
    function _amount0(bool up) internal pure returns (uint256 amount0) {
        // Token0 sits above the spot, so it spans [tick 0, _UPPER], computed the way v4-core does.
        return SqrtPriceMath.getAmount0Delta({
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(0),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_UPPER),
            liquidity: _LIQUIDITY,
            roundUp: up
        });
    }

    /// @notice v4's rounded-up mint cost (`up`) or rounded-down principal of token1 for `_LIQUIDITY` at tick 0.
    /// @param up Whether to round up (the mint cost) or down (the burn principal).
    /// @return amount1 The token1 amount across [`_LOWER`, 0].
    function _amount1(bool up) internal pure returns (uint256 amount1) {
        // Token1 sits below the spot, so it spans [_LOWER, tick 0], computed the way v4-core does.
        return SqrtPriceMath.getAmount1Delta({
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_LOWER),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(0),
            liquidity: _LIQUIDITY,
            roundUp: up
        });
    }

    /// @notice The ERC-20 balance of `who` in `currency`.
    /// @param currency The pool currency to read (always an ERC-20 here).
    /// @param who The account whose balance is read.
    /// @return balance The account's balance.
    function _balance(Currency currency, address who) internal view returns (uint256 balance) {
        // Every currency in these tests is an ERC-20 exposing `balanceOf`.
        return MockERC20(Currency.unwrap(currency)).balanceOf(who);
    }

    /// @notice Burn `tokenId`, then resolve the deltas with two actions.
    /// @param tokenId The position to burn.
    /// @param resolve The first resolving action.
    /// @param resolveParams The first resolving action's parameters.
    /// @param resolve2 The second resolving action.
    /// @param resolve2Params The second resolving action's parameters.
    function _burnThen(
        uint256 tokenId,
        bytes1 resolve,
        bytes memory resolveParams,
        bytes1 resolve2,
        bytes memory resolve2Params
    )
        internal
    {
        // BURN_POSITION with zero minimums, followed by the two resolving actions.
        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.BURN_POSITION)), resolve, resolve2);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = resolveParams;
        params[2] = resolve2Params;
        // Run the batch with the current timestamp as the deadline.
        _positionManager.modifyLiquidities({unlockData: abi.encode(actions, params), deadline: block.timestamp});
    }

    /// @notice Fund and approve the pool's other (non-`_tokenA`) plain ERC-20.
    /// @param key The pool whose other currency is funded.
    function _fundOther(PoolKey memory key) internal {
        // Pick whichever currency is not `_tokenA`.
        address other = Currency.unwrap(key.currency0) == address(_tokenA)
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);
        // Mint it to this contract and approve the PositionManager through Permit2.
        MockERC20(other).mint({to: address(this), amount: 10e18});
        MockERC20(other).approve({spender: _PERMIT2, amount: type(uint256).max});
        MockPermit2(_PERMIT2).approve({
            token: other, spender: address(_positionManager), amount: type(uint160).max, expiration: type(uint48).max
        });
    }

    /// @notice Mint `_LIQUIDITY` on [`_LOWER`, `_UPPER`] in `key` to this contract, then resolve the deltas with two
    /// actions.
    /// @param key The pool to mint in.
    /// @param resolve The first resolving action.
    /// @param resolveParams The first resolving action's parameters.
    /// @param resolve2 The second resolving action.
    /// @param resolve2Params The second resolving action's parameters.
    function _mintThen(
        PoolKey memory key,
        bytes1 resolve,
        bytes memory resolveParams,
        bytes1 resolve2,
        bytes memory resolve2Params
    )
        internal
    {
        // MINT_POSITION with unlimited maximums, followed by the two resolving actions.
        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.MINT_POSITION)), resolve, resolve2);
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(key, _LOWER, _UPPER, _LIQUIDITY, type(uint128).max, type(uint128).max, address(this), bytes(""));
        params[1] = resolveParams;
        params[2] = resolve2Params;
        // Run the batch with the current timestamp as the deadline.
        _positionManager.modifyLiquidities({unlockData: abi.encode(actions, params), deadline: block.timestamp});
    }

    /// @notice A [-200, 200] pool of `_tokenA` and `other` initialized at tick 0, with this contract funded and
    /// approved through Permit2 for `_tokenA` (and for `other` when it is the quirky token).
    /// @param other The token paired with `_tokenA`.
    /// @return key The sorted pool key.
    function _pool(address other) internal returns (PoolKey memory key) {
        // Sort the pair into currency0 and currency1, as v4 requires.
        (address c0, address c1) = address(_tokenA) < other ? (address(_tokenA), other) : (other, address(_tokenA));
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        // Initialize at tick 0 so both sides of [-200, 200] cost tokens.
        _positionManager.initializePool({key: key, sqrtPriceX96: TickMath.getSqrtPriceAtTick(0)});
        // Fund `_tokenA` and approve the PositionManager through Permit2.
        _tokenA.mint({to: address(this), amount: 10e18});
        _tokenA.approve({spender: _PERMIT2, amount: type(uint256).max});
        MockPermit2(_PERMIT2).approve({
            token: address(_tokenA),
            spender: address(_positionManager),
            amount: type(uint160).max,
            expiration: type(uint48).max
        });
        // The quirky token is funded here; a plain partner is funded by `_fundOther`.
        if (other == address(_quirk)) {
            _quirk.mint({to: address(this), amount: 10e18});
            _quirk.approve({spender: _PERMIT2, amount: type(uint256).max});
            MockPermit2(_PERMIT2).approve({
                token: address(_quirk),
                spender: address(_positionManager),
                amount: type(uint160).max,
                expiration: type(uint48).max
            });
        }
    }

    /// @notice Mint in `key`, settle both currencies with SETTLE_PAIR, then close currency0 (a no-op once settled).
    /// @param key The pool to mint in.
    function _settlePair(PoolKey memory key) internal {
        // SETTLE_PAIR pays both debts; the trailing CLOSE_CURRENCY finds a zero delta.
        _mintThen({
            key: key,
            resolve: bytes1(uint8(Actions.SETTLE_PAIR)),
            resolveParams: abi.encode(key.currency0, key.currency1),
            resolve2: bytes1(uint8(Actions.CLOSE_CURRENCY)),
            resolve2Params: abi.encode(key.currency0)
        });
    }
}
