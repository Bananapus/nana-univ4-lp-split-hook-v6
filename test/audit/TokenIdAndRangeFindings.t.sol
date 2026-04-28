// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract CodexNemesisFindingsTest is LPSplitHookV4TestBase {
    function test_codex_nemesis_preinitializedPoolAcceptsAttackerChosenPrice() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        int24 attackerTick = 50_000;
        uint160 attackerSqrtPrice = TickMath.getSqrtPriceAtTick(attackerTick);
        positionManager.initializePool(key, attackerSqrtPrice);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        bytes32 poolId = keccak256(abi.encode(key));
        assertEq(positionManager.poolSqrtPrice(poolId), attackerSqrtPrice, "hook should not accept attacker price");
        assertGt(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), 0, "LP position should still mint");
    }

    function test_codex_nemesis_permissionlessDeployCanLockWrongTerminalToken() public {
        MockERC20 secondTerminalToken = new MockERC20("Second Terminal Token", "TERM2", 18);

        directory.setTerminal(PROJECT_ID, address(secondTerminalToken), address(terminal));
        terminal.setAccountingContext(
            PROJECT_ID, address(secondTerminalToken), uint32(uint160(address(secondTerminalToken))), 18
        );
        terminal.addAccountingContext(
            PROJECT_ID,
            JBAccountingContext({
                token: address(secondTerminalToken),
                decimals: 18,
                currency: uint32(uint160(address(secondTerminalToken)))
            })
        );

        _accumulateTokens(PROJECT_ID, 100e18);

        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 10);

        vm.prank(user);
        hook.deployPool(PROJECT_ID, address(secondTerminalToken), 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "outsider should not be able to finalize deployment");
        assertGt(hook.tokenIdOf(PROJECT_ID, address(secondTerminalToken)), 0, "wrong token pair should be locked in");

        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported.selector);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);
    }
}
