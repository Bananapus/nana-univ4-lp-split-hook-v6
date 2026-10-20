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

contract CapTestToken is ERC20("Cap", "CAP") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Adds liquidity straight through the PoolManager and settles what it owes (native currency0 only here).
contract RawLiquidityAdder is IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    receive() external payable {}

    function add(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) external payable {
        poolManager.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint256));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                // forge-lint: disable-next-line(unsafe-typecast)
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity),
                salt: 0
            }),
            ""
        );
        // The range sits above the spot, so only native currency0 is owed.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (delta.amount0() < 0) poolManager.settle{value: uint256(uint128(-delta.amount0()))}();
        return "";
    }
}

/// @notice Codex pass-3 scenario on the real mainnet PoolManager: a TWAP-anchored range near MAX_TICK that cannot hold
/// the inventory's liquidity. The capped liquidity must mint exactly up to Uniswap's per-tick cap instead of reverting
/// the recycle.
contract CappedLiquidityFork is Test {
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    int24 constant SPACING = 200;
    int24 constant LOWER = 886_800;
    int24 constant UPPER = 887_000;

    PoolKey key;
    RawLiquidityAdder adder;

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(new CapTestToken())),
            fee: 10_000,
            tickSpacing: SPACING,
            hooks: IHooks(address(0))
        });
        V4_POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(886_600));
        adder = new RawLiquidityAdder(V4_POOL_MANAGER);
        vm.deal(address(adder), 1000 ether);
    }

    function test_fork_oversizedInventory_capsAtPerTickLimit() public {
        uint256 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(SPACING);
        uint128 liquidity = JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
            poolManager: V4_POOL_MANAGER,
            key: key,
            tickLower: LOWER,
            tickUpper: UPPER,
            amount0: 30_000_000_000_000,
            amount1: 0
        });
        assertEq(liquidity, maxPerTick, "an oversized amount mints exactly the per-tick cap");

        // One unit past the cap is what the uncapped mint hit; the cap itself fits.
        vm.expectRevert();
        adder.add(key, LOWER, UPPER, uint256(liquidity) + 1);
        adder.add(key, LOWER, UPPER, liquidity);

        assertEq(
            JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
                poolManager: V4_POOL_MANAGER, key: key, tickLower: LOWER, tickUpper: UPPER, amount0: 1e18, amount1: 0
            }),
            0,
            "a full bound leaves no room"
        );
    }

    function test_fork_existingLiquidityAtABound_shrinksRoom() public {
        uint256 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(SPACING);
        uint256 thirdParty = maxPerTick / 3;
        // Another LP shares only the upper bound.
        adder.add(key, UPPER, UPPER + SPACING, thirdParty);
        uint128 liquidity = JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
            poolManager: V4_POOL_MANAGER,
            key: key,
            tickLower: LOWER,
            tickUpper: UPPER,
            amount0: 30_000_000_000_000,
            amount1: 0
        });
        assertEq(liquidity, maxPerTick - thirdParty, "room is the cap minus the fuller bound's gross liquidity");
        adder.add(key, LOWER, UPPER, liquidity);
    }

    function test_fork_fittingAmount_matchesLiquidityAmounts() public view {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(UPPER);
        assertEq(
            JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
                poolManager: V4_POOL_MANAGER, key: key, tickLower: LOWER, tickUpper: UPPER, amount0: 1e9, amount1: 0
            }),
            LiquidityAmounts.getLiquidityForAmount0({sqrtPriceAX96: sqrtLower, sqrtPriceBX96: sqrtUpper, amount0: 1e9}),
            "token0 below the cap"
        );
        assertEq(
            JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
                poolManager: V4_POOL_MANAGER, key: key, tickLower: -1000, tickUpper: -200, amount0: 0, amount1: 5e20
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
