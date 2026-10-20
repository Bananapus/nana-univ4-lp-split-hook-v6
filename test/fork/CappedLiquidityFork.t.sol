// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";

/// @notice A plain ERC-20 that serves as the pool's currency1 so the test pool has a real, sortable token address.
contract CapTestToken is ERC20("Cap", "CAP") {
    /// @notice Mints tokens to an account with no access control, since only the test uses it.
    /// @param to The account that receives the tokens.
    /// @param amount The number of tokens to mint.
    function mint(address to, uint256 amount) external {
        // Mint directly so a test can fund any account it needs.
        _mint({account: to, value: amount});
    }
}

/// @notice Adds liquidity straight through the PoolManager and settles what it owes (native currency0 only here).
contract RawLiquidityAdder is IUnlockCallback {
    /// @notice The Uniswap V4 PoolManager this adder unlocks and settles against.
    IPoolManager public immutable POOL_MANAGER;

    /// @param poolManager The Uniswap V4 PoolManager to add liquidity through.
    constructor(IPoolManager poolManager) {
        // Store the PoolManager so `add` and the callback talk to the same instance.
        POOL_MANAGER = poolManager;
    }

    /// @notice Accepts the native ETH this adder later settles with.
    receive() external payable {}

    /// @notice Adds `liquidity` to a range of `key`'s pool, paying any native currency0 owed from this contract.
    /// @param key The pool key.
    /// @param tickLower The lower tick of the range.
    /// @param tickUpper The upper tick of the range.
    /// @param liquidity The liquidity to add.
    function add(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) external payable {
        // Unlock the PoolManager; the add itself runs inside `unlockCallback`.
        POOL_MANAGER.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
    }

    /// @notice Performs the add requested by `add` and settles the native currency0 it owes.
    /// @param data The ABI-encoded pool key, tick range and liquidity passed through `unlock`.
    /// @return result Empty bytes, since the caller ignores the callback's return value.
    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        // Recover the request that `add` encoded.
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint256));
        // Add the liquidity under a zero salt; the returned delta says what this contract owes.
        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: int256(liquidity),
                salt: 0
            }),
            ""
        );
        // The range sits above the spot, so only native currency0 is owed.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (delta.amount0() < 0) POOL_MANAGER.settle{value: uint256(uint128(-delta.amount0()))}();
        // Return nothing; `unlock` passes this back to `add`, which discards it.
        result = "";
    }
}

/// @notice On the real mainnet PoolManager, a TWAP-anchored range near MAX_TICK that cannot hold the inventory's
/// liquidity. The capped liquidity mints exactly up to Uniswap's per-tick cap instead of reverting the recycle.
contract CappedLiquidityFork is Test {
    /// @notice The canonical Uniswap V4 PoolManager on Ethereum mainnet.
    IPoolManager internal constant _V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    /// @notice The pool's tick spacing, matching the hook's 1% fee tier.
    int24 internal constant _SPACING = 200;

    /// @notice The lower tick of the one-spacing range near MAX_TICK.
    int24 internal constant _LOWER = 886_800;

    /// @notice The upper tick of the one-spacing range near MAX_TICK.
    int24 internal constant _UPPER = 887_000;

    /// @notice The test pool: native ETH against a fresh token, with no hooks.
    PoolKey key;

    /// @notice The helper that adds raw liquidity to the test pool.
    RawLiquidityAdder adder;

    /// @notice Forks mainnet, initializes the pool one spacing below the range and funds the adder.
    function setUp() public {
        // Pin the fork block so the PoolManager state is reproducible.
        vm.createSelectFork("ethereum", 21_700_000);
        // Pair native ETH (currency0) with a fresh token (currency1) on the 1% tier spacing, with no hooks.
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(new CapTestToken())),
            fee: 10_000,
            tickSpacing: _SPACING,
            hooks: IHooks(address(0))
        });
        // Start the spot below the range so a position there is funded by currency0 alone.
        _V4_POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(886_600));
        // Deploy the adder against the same PoolManager and give it ETH to settle with.
        adder = new RawLiquidityAdder(_V4_POOL_MANAGER);
        vm.deal(address(adder), 1000 ether);
    }

    /// @notice An amount far above what the range holds yields exactly the per-tick cap, which mints, while one unit
    /// more reverts and a full bound leaves no room.
    function test_fork_oversizedInventory_capsAtPerTickLimit() public {
        // Uniswap's per-tick gross liquidity cap for this spacing.
        uint256 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(_SPACING);
        // Ask for far more currency0 than the range can hold.
        uint128 liquidity = JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
            poolManager: _V4_POOL_MANAGER,
            key: key,
            tickLower: _LOWER,
            tickUpper: _UPPER,
            amount0: 30_000_000_000_000,
            amount1: 0
        });
        assertEq(liquidity, maxPerTick, "an oversized amount mints exactly the per-tick cap");

        // One unit past the cap reverts in the PoolManager; the cap itself fits.
        vm.expectRevert();
        adder.add({key: key, tickLower: _LOWER, tickUpper: _UPPER, liquidity: uint256(liquidity) + 1});
        adder.add({key: key, tickLower: _LOWER, tickUpper: _UPPER, liquidity: liquidity});

        // With both bounds at the cap, any further amount yields zero liquidity.
        assertEq(
            JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
                poolManager: _V4_POOL_MANAGER, key: key, tickLower: _LOWER, tickUpper: _UPPER, amount0: 1e18, amount1: 0
            }),
            0,
            "a full bound leaves no room"
        );
    }

    /// @notice Another LP's liquidity at one bound shrinks the room to the cap minus that bound's gross liquidity, and
    /// the shrunk amount mints.
    function test_fork_existingLiquidityAtABound_shrinksRoom() public {
        // Uniswap's per-tick gross liquidity cap for this spacing.
        uint256 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(_SPACING);
        // A third of the cap, held by another LP.
        uint256 thirdParty = maxPerTick / 3;
        // Another LP shares only the upper bound.
        adder.add({key: key, tickLower: _UPPER, tickUpper: _UPPER + _SPACING, liquidity: thirdParty});
        // Ask for far more currency0 than the range can hold.
        uint128 liquidity = JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
            poolManager: _V4_POOL_MANAGER,
            key: key,
            tickLower: _LOWER,
            tickUpper: _UPPER,
            amount0: 30_000_000_000_000,
            amount1: 0
        });
        assertEq(liquidity, maxPerTick - thirdParty, "room is the cap minus the fuller bound's gross liquidity");
        // The capped amount mints without overflowing the shared bound.
        adder.add({key: key, tickLower: _LOWER, tickUpper: _UPPER, liquidity: liquidity});
    }

    /// @notice An amount that fits under the cap yields exactly Uniswap's `LiquidityAmounts` result, for a token0
    /// range above the spot and a token1 range below it.
    function test_fork_fittingAmount_matchesLiquidityAmounts() public view {
        // The range's bound prices, for the reference token0 computation.
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(_UPPER);
        // A small token0 amount above the spot matches the uncapped token0 formula.
        assertEq(
            JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
                poolManager: _V4_POOL_MANAGER, key: key, tickLower: _LOWER, tickUpper: _UPPER, amount0: 1e9, amount1: 0
            }),
            LiquidityAmounts.getLiquidityForAmount0({sqrtPriceAX96: sqrtLower, sqrtPriceBX96: sqrtUpper, amount0: 1e9}),
            "token0 below the cap"
        );
        // A token1 amount in a range below the spot matches the uncapped token1 formula.
        assertEq(
            JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
                poolManager: _V4_POOL_MANAGER, key: key, tickLower: -1000, tickUpper: -200, amount0: 0, amount1: 5e20
            }),
            LiquidityAmounts.getLiquidityForAmount1({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(-1000),
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(-200),
                amount1: 5e20
            }),
            "token1 below the cap"
        );
    }
}
