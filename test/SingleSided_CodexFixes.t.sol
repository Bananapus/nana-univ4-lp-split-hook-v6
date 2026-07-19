// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

/// @notice Subclass exposing internals so unit tests can drive them directly.
contract CodexExposedHook is JBUniswapV4LPSplitHook {
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IAllowanceTransfer permit2,
        IJBSuckerRegistry suckerRegistry
    )
        JBUniswapV4LPSplitHook(directory, permissions, tokens, permit2, suckerRegistry)
    {}

    function exposed_mintPosition(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    )
        external
    {
        _mintPosition({
            key: key, tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity, amount0: amount0, amount1: amount1
        });
    }
}

/// @notice Codex audit fix coverage. Each test names its finding and asserts the corrected behavior.
contract SingleSided_CodexFixesTest is LPSplitHookV4TestBase {
    CodexExposedHook internal exposedHook;

    function _poolKey() internal view returns (PoolKey memory key) {
        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
    }

    function _deployExposedHook() internal {
        CodexExposedHook impl = new CodexExposedHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3),
            IJBSuckerRegistry(address(0))
        );
        exposedHook = CodexExposedHook(payable(LibClone.clone(address(impl))));
        exposedHook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(baseOracleHook)),
            newBuybackHook: IJBBuybackHookRegistry(BUYBACK_REGISTRY)
        });
    }

    // ─── Finding 8: unsafe uint128 casts revert instead of silently truncating ───

    /// @notice A settle-cap amount at or above 2^128 must revert `AmountExceedsUint128` rather than wrap to a smaller
    /// value (which would silently mint a truncated/zero-cap position).
    function test_Finding8_MintCapAtUint128Boundary_Reverts() public {
        _deployExposedHook();
        PoolKey memory key = _poolKey();
        positionManager.initializePool(key, TickMath.getSqrtPriceAtTick(0));

        int24 spacing = hook.TICK_SPACING();
        uint256 overflowAmount = uint256(type(uint128).max) + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_AmountExceedsUint128.selector, overflowAmount
            )
        );
        exposedHook.exposed_mintPosition({
            key: key, tickLower: -spacing, tickUpper: spacing, liquidity: 1000, amount0: overflowAmount, amount1: 0
        });
    }
}
