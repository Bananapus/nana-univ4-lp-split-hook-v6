// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {MockERC20} from "./mock/MockERC20.sol";
import {MockPoolManager} from "./mock/MockPoolManager.sol";
import {MockPositionManager} from "./mock/MockPositionManager.sol";
import {MockPermit2} from "./TestBaseV4.sol";

/// @notice An ERC-20 that keeps `taxBps` of every `transferFrom` and returns nothing from `transfer` (USDT-style).
contract QuirkToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public taxBps;

    function setTaxBps(uint256 bps) external {
        taxBps = bps;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - amount * taxBps / 10_000;
        return true;
    }
}

/// @notice Direct conformance checks for the MockPositionManager's delta-resolution branches the hook rarely encodes
/// (SETTLE_PAIR, TAKE_PAIR, CLOSE_CURRENCY), its measured settlement, its v4 `CurrencyLibrary.transfer` payouts and its
/// signed removal deltas, each against the v4-core/periphery semantics it models.
contract MockPositionManagerConformanceTest is Test {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint128 internal constant LIQUIDITY = 1e18;
    int24 internal constant LOWER = -200;
    int24 internal constant UPPER = 200;

    MockPoolManager internal poolManager;
    MockPositionManager internal positionManager;
    MockERC20 internal tokenA;
    QuirkToken internal quirk;
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        vm.etch(PERMIT2, address(new MockPermit2()).code);
        poolManager = new MockPoolManager();
        positionManager = new MockPositionManager();
        positionManager.setPoolManager(poolManager);
        tokenA = new MockERC20("A", "A", 18);
        quirk = new QuirkToken();
    }

    /// @notice A [-200, 200] pool of `tokenA` and `other` initialized at tick 0, with this contract funded and
    /// approved through Permit2 for both.
    function _pool(address other) internal returns (PoolKey memory key) {
        (address c0, address c1) = address(tokenA) < other ? (address(tokenA), other) : (other, address(tokenA));
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        positionManager.initializePool(key, TickMath.getSqrtPriceAtTick(0));
        tokenA.mint(address(this), 10e18);
        tokenA.approve(PERMIT2, type(uint256).max);
        MockPermit2(PERMIT2).approve(address(tokenA), address(positionManager), type(uint160).max, type(uint48).max);
        if (other == address(quirk)) {
            quirk.mint(address(this), 10e18);
            quirk.approve(PERMIT2, type(uint256).max);
            MockPermit2(PERMIT2).approve(address(quirk), address(positionManager), type(uint160).max, type(uint48).max);
        }
    }

    /// @notice v4's rounded-up mint cost (`up`) or rounded-down principal of `LIQUIDITY` at tick 0, per currency.
    function _amount(bool up) internal pure returns (uint256) {
        // Symmetric around tick 0 to one unit; computed per side the way v4-core does.
        return SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(UPPER), LIQUIDITY, up
        );
    }

    function _amount1(bool up) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(LOWER), TickMath.getSqrtPriceAtTick(0), LIQUIDITY, up
        );
    }

    function _mintThen(
        PoolKey memory key,
        bytes1 resolve,
        bytes memory resolveParams,
        bytes1 resolve2,
        bytes memory p2
    )
        internal
    {
        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.MINT_POSITION)), resolve, resolve2);
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(key, LOWER, UPPER, LIQUIDITY, type(uint128).max, type(uint128).max, address(this), bytes(""));
        params[1] = resolveParams;
        params[2] = p2;
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _burnThen(
        uint256 tokenId,
        bytes1 resolve,
        bytes memory resolveParams,
        bytes1 resolve2,
        bytes memory p2
    )
        internal
    {
        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.BURN_POSITION)), resolve, resolve2);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = resolveParams;
        params[2] = p2;
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _settlePair(PoolKey memory key) internal {
        _mintThen(
            key,
            bytes1(uint8(Actions.SETTLE_PAIR)),
            abi.encode(key.currency0, key.currency1),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency0)
        );
    }

    function _balance(Currency currency, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(currency)).balanceOf(who);
    }

    /// @notice SETTLE_PAIR pays both rounded-up costs from the caller through Permit2 into the pool's reserves (the
    /// trailing CLOSE_CURRENCY then finds a zero delta and does nothing).
    function test_SettlePair_PaysBothCostsFromTheCaller() public {
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        uint256 before0 = _balance(key.currency0, address(this));
        uint256 before1 = _balance(key.currency1, address(this));

        _settlePair(key);

        assertEq(before0 - _balance(key.currency0, address(this)), _amount(true), "token0 cost paid");
        assertEq(before1 - _balance(key.currency1, address(this)), _amount1(true), "token1 cost paid");
        assertEq(positionManager.poolLocked(Currency.unwrap(key.currency0)), _amount(true), "token0 in reserves");
        assertEq(positionManager.poolLocked(Currency.unwrap(key.currency1)), _amount1(true), "token1 in reserves");
    }

    /// @notice SETTLE_PAIR refuses a currency that is owed to the caller rather than by it.
    function test_SettlePair_RevertsOnCredit() public {
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        _settlePair(key);
        uint256 tokenId = positionManager.lastMintTokenId();
        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotNegative.selector, key.currency0));
        _burnThen(
            tokenId,
            bytes1(uint8(Actions.SETTLE_PAIR)),
            abi.encode(key.currency0, key.currency1),
            bytes1(uint8(Actions.TAKE_PAIR)),
            abi.encode(key.currency0, key.currency1, recipient)
        );
    }

    /// @notice TAKE_PAIR pays both rounded-down principals to the named recipient; only the rounding stays pooled.
    function test_TakePair_PaysBothPrincipalsToTheRecipient() public {
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        _settlePair(key);
        uint256 tokenId = positionManager.lastMintTokenId();

        _burnThen(
            tokenId,
            bytes1(uint8(Actions.TAKE_PAIR)),
            abi.encode(key.currency0, key.currency1, recipient),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency1)
        );

        assertEq(_balance(key.currency0, recipient), _amount(false), "token0 principal taken");
        assertEq(_balance(key.currency1, recipient), _amount1(false), "token1 principal taken");
        assertEq(
            positionManager.poolLocked(Currency.unwrap(key.currency0)),
            _amount(true) - _amount(false),
            "token0 rounding stays pooled"
        );
        assertEq(
            positionManager.poolLocked(Currency.unwrap(key.currency1)),
            _amount1(true) - _amount1(false),
            "token1 rounding stays pooled"
        );
    }

    /// @notice TAKE_PAIR refuses a currency the caller still owes.
    function test_TakePair_RevertsOnDebt() public {
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotPositive.selector, key.currency0));
        _mintThen(
            key,
            bytes1(uint8(Actions.TAKE_PAIR)),
            abi.encode(key.currency0, key.currency1, recipient),
            bytes1(uint8(Actions.SETTLE_PAIR)),
            abi.encode(key.currency0, key.currency1)
        );
    }

    /// @notice CLOSE_CURRENCY settles a debt from the caller after a mint and takes a credit to the caller after a
    /// burn.
    function test_CloseCurrency_SettlesDebtAndTakesCredit() public {
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        uint256 before0 = _balance(key.currency0, address(this));
        uint256 before1 = _balance(key.currency1, address(this));

        _mintThen(
            key,
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency0),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency1)
        );
        assertEq(before0 - _balance(key.currency0, address(this)), _amount(true), "close settled token0 debt");
        assertEq(before1 - _balance(key.currency1, address(this)), _amount1(true), "close settled token1 debt");

        _burnThen(
            positionManager.lastMintTokenId(),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency0),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency1)
        );
        assertEq(before0 - _balance(key.currency0, address(this)), _amount(true) - _amount(false), "close took token0");
        assertEq(
            before1 - _balance(key.currency1, address(this)), _amount1(true) - _amount1(false), "close took token1"
        );
    }

    /// @notice An unsettled delta fails the whole batch, like `PoolManager.unlock`.
    function test_UnsettledDelta_Reverts() public {
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        _mintThen(
            key,
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency0),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency0)
        );
    }

    /// @notice Settlement credits what the reserves received, as `PoolManager.settle` does: a token that keeps a
    /// transfer tax leaves debt and the batch reverts, while the same mint of untaxed tokens settles.
    function test_Settle_CreditsMeasuredReceipt() public {
        PoolKey memory key = _pool(address(quirk));
        quirk.setTaxBps(100);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        _settlePair(key);

        quirk.setTaxBps(0);
        _settlePair(key);
        assertEq(
            positionManager.poolLocked(address(quirk)),
            address(quirk) < address(tokenA) ? _amount(true) : _amount1(true)
        );
    }

    /// @notice Payouts use v4's `CurrencyLibrary.transfer`: a token whose `transfer` returns nothing still pays, and
    /// one whose `transfer` returns false reverts with v4's wrapped `ERC20TransferFailed`.
    function test_Take_TransferReturnHandling() public {
        PoolKey memory key = _pool(address(quirk));
        _settlePair(key);
        uint256 tokenId = positionManager.lastMintTokenId();
        bytes memory takePair = abi.encode(key.currency0, key.currency1, recipient);

        uint256 snapshot = vm.snapshotState();
        _burnThen(
            tokenId,
            bytes1(uint8(Actions.TAKE_PAIR)),
            takePair,
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency0)
        );
        bool quirkIs0 = address(quirk) < address(tokenA);
        assertEq(quirk.balanceOf(recipient), quirkIs0 ? _amount(false) : _amount1(false), "empty return still pays");
        vm.revertToState(snapshot);

        vm.mockCall(address(tokenA), abi.encodeWithSelector(MockERC20.transfer.selector), abi.encode(false));
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        _burnThen(
            tokenId,
            bytes1(uint8(Actions.TAKE_PAIR)),
            takePair,
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency0)
        );
    }

    /// @notice A pool-hook take is subtracted from the signed principal delta: up to the principal it passes (and the
    /// caller receives the rest), past it the negative delta reverts `SafeCastOverflow` like `validateMinOut`.
    function test_RemovalDelta_IsSignedAndValidated() public {
        PoolKey memory key = _pool(address(new MockERC20("B", "B", 18)));
        _fundOther(key);
        _settlePair(key);
        uint256 tokenId = positionManager.lastMintTokenId();
        bytes memory takePair = abi.encode(key.currency0, key.currency1, recipient);

        uint256 snapshot = vm.snapshotState();
        positionManager.setHookTakeOnRemove(tokenId, _amount(false), 0);
        _burnThen(
            tokenId,
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency1),
            bytes1(uint8(Actions.TAKE_PAIR)),
            takePair
        );
        assertEq(_balance(key.currency0, recipient), 0, "the hook took all token0 principal");
        vm.revertToState(snapshot);

        positionManager.setHookTakeOnRemove(tokenId, _amount(false) + 1, 0);
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        _burnThen(
            tokenId,
            bytes1(uint8(Actions.TAKE_PAIR)),
            takePair,
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            abi.encode(key.currency1)
        );
    }

    /// @notice Fund and approve the pool's other (non-`tokenA`) plain ERC-20.
    function _fundOther(PoolKey memory key) internal {
        address other = Currency.unwrap(key.currency0) == address(tokenA)
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);
        MockERC20(other).mint(address(this), 10e18);
        MockERC20(other).approve(PERMIT2, type(uint256).max);
        MockPermit2(PERMIT2).approve(other, address(positionManager), type(uint160).max, type(uint48).max);
    }
}
