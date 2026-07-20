// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice The adaptive seed must produce a valid two-sided position in BOTH Uniswap currency orderings: project =
/// token0 (a fresh ERC-20 pair where the project token sorts lower) and native ETH as the terminal (address(0) =
/// token0, so project = token1). Each case asserts nonzero liquidity, asks anchored to the issuance ceiling with the
/// full project balance, and a bid leg on the correct single side of spot.
contract SingleSided_OrderingTest is LPSplitHookV4TestBase {
    uint256 internal constant PID = 7;
    address internal constant NATIVE = JBConstants.NATIVE_TOKEN;

    /// @notice Wire a fresh project (id `PID`) whose ERC-20 project token sorts BELOW the ERC-20 terminal token, so the
    /// project is Uniswap currency0 — the mirror of the default harness ordering.
    function _wireProjectToken0() internal returns (MockERC20 proj, MockERC20 term) {
        // Deploy candidate tokens until the project token's address sorts below the terminal token's.
        proj = new MockERC20("Proj0", "P0", 18);
        term = new MockERC20("Term1", "T1", 18);
        uint256 salt;
        while (address(proj) >= address(term)) {
            salt++;
            if (salt % 2 == 1) proj = new MockERC20("Proj0", "P0", 18);
            else term = new MockERC20("Term1", "T1", 18);
        }
        assertLt(
            uint256(uint160(address(proj))), uint256(uint160(address(term))), "precondition: project sorts as token0"
        );

        controller.setWeight(PID, DEFAULT_WEIGHT);
        controller.setFirstWeight(PID, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(PID, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(PID, 1);
        _setDirectoryController(PID, address(controller));
        _setDirectoryTerminal(PID, address(term), address(terminal));
        jbProjects.setOwner(PID, owner);
        terminal.setProjectToken(PID, address(proj));
        terminal.setAccountingContext(PID, address(term), uint32(uint160(address(term))), 18);
        terminal.addAccountingContext(
            PID, JBAccountingContext({token: address(term), decimals: 18, currency: uint32(uint160(address(term)))})
        );
        jbTokens.setToken(PID, address(proj));
        store.setTaxedCashOutCurve({projectId: PID, surplus: 100e18, supply: 2e18, taxRate: 4000});
        store.setBalance(address(terminal), PID, address(term), 10e18);
        _addDirectoryTerminal(PID, address(terminal));
    }

    function test_ProjectIsToken0_AdaptiveTwoSided() public {
        (MockERC20 proj, MockERC20 term) = _wireProjectToken0();

        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PID);
        (int24 corridorLower, int24 corridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PID,
            terminalToken: address(term),
            projectToken: address(proj),
            controller: address(controller),
            ruleset: ruleset
        });
        assertLt(corridorLower, corridorUpper, "precondition: corridor must be non-degenerate");

        // project = token0 → issuance ceiling is the UPPER tick, cash-out floor the LOWER tick.
        int24 spotTick = corridorLower + (corridorUpper - corridorLower) / 2;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(proj)),
            currency1: Currency.wrap(address(term)),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
        positionManager.initializePool(key, TickMath.getSqrtPriceAtTick(spotTick));

        // Deploy the project ask capital (asks-only — no hook-held terminal is ever paired after the cross-project
        // fix), then inject bid capital INTO the position (as buyers filling asks would) so the rebalance burn recovers
        // it as the two-sided bid.
        proj.mint(address(controller), 1e18);
        vm.prank(address(controller));
        proj.approve(address(hook), 1e18);
        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(PID, address(proj), 1e18, 1));

        vm.prank(owner);
        hook.deployPool(PID);

        uint256 tokenId = hook.tokenIdOf(PID, address(term));
        term.mint(address(positionManager), 0.05e18);
        positionManager.injectPositionBalance(tokenId, address(term), 0.05e18);
        proj.mint(address(positionManager), 1000e18);
        term.mint(address(positionManager), 1000e18);

        // Move the corridor (drop issuance) so the rebalance clears its drift guard; this shifts the issuance ceiling
        // but leaves the cash-out floor and spot, so the recovered-terminal bid leg is exercised.
        controller.setWeight(PID, (DEFAULT_WEIGHT * 9) / 10);
        vm.prank(owner);
        hook.rebalanceLiquidity(PID, address(term));

        tokenId = hook.tokenIdOf(PID, address(term));
        assertGt(positionManager.getPositionLiquidity(tokenId), 0, "liquidity must be nonzero");

        // Re-derive the ceiling after the corridor move.
        (JBRuleset memory movedRuleset,) = controller.currentRulesetOf(PID);
        (, int24 movedCorridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PID,
            terminalToken: address(term),
            projectToken: address(proj),
            controller: address(controller),
            ruleset: movedRuleset
        });

        int24 activeLower = hook.activeTickLowerOf(PID, address(term));
        int24 activeUpper = hook.activeTickUpperOf(PID, address(term));
        assertEq(activeUpper, movedCorridorUpper, "project=token0: asks anchor at the corridor ceiling (upper tick)");
        assertGt(activeLower, corridorLower - 1, "the bid bound must not dip below the corridor floor");
        assertLt(activeLower, spotTick, "the bid bound (lower tick) must sit below spot: a real bid leg");

        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(tokenId);
        assertEq(amount0Locked, 1e18, "project (token0) asks must be fully deployed");
        assertGt(amount1Locked, 0, "terminal (token1) must seed a nonzero bid");
    }

    function test_NativeEthTerminal_AdaptiveTwoSided() public {
        // Wire the base PROJECT_ID against native ETH as the terminal token (address(0) = token0, project = token1).
        _setDirectoryTerminal(PROJECT_ID, NATIVE, address(terminal));
        terminal.setAccountingContext(PROJECT_ID, NATIVE, uint32(uint160(NATIVE)), 18);
        terminal.addAccountingContext(
            PROJECT_ID, JBAccountingContext({token: NATIVE, decimals: 18, currency: uint32(uint160(NATIVE))})
        );
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});
        store.setBalance(address(terminal), PROJECT_ID, NATIVE, 10e18);
        // Zero the base ERC-20 terminal's balance so `findHighestValueTerminalTokenOf` auto-selects native ETH.
        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 0);

        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (int24 corridorLower, int24 corridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: NATIVE,
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
        assertLt(corridorLower, corridorUpper, "precondition: corridor must be non-degenerate");

        // Native ETH is token0, project is token1 → issuance ceiling is the LOWER tick, cash-out floor the UPPER
        // tick.
        int24 spotTick = corridorLower + (corridorUpper - corridorLower) / 2;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
        positionManager.initializePool(key, TickMath.getSqrtPriceAtTick(spotTick));

        // Deploy the project ask capital (asks-only), then inject native-ETH bid capital INTO the position so the
        // rebalance burn recovers it as the two-sided bid.
        _accumulateTokens(PROJECT_ID, 1e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, NATIVE);
        vm.deal(address(positionManager), address(positionManager).balance + 0.05 ether);
        positionManager.injectPositionBalance(tokenId, address(0), 0.05 ether);
        projectToken.mint(address(positionManager), 1000e18);
        vm.deal(address(positionManager), address(positionManager).balance + 1000 ether);

        // Move the corridor (drop issuance) so the rebalance clears its drift guard.
        controller.setWeight(PROJECT_ID, (DEFAULT_WEIGHT * 9) / 10);
        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, NATIVE);

        tokenId = hook.tokenIdOf(PROJECT_ID, NATIVE);
        assertGt(positionManager.getPositionLiquidity(tokenId), 0, "liquidity must be nonzero");

        // Re-derive the ceiling after the corridor move (project=token1 → ceiling is the corridor LOWER tick).
        (JBRuleset memory movedRuleset,) = controller.currentRulesetOf(PROJECT_ID);
        (int24 movedCorridorLower,) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: NATIVE,
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: movedRuleset
        });

        int24 activeLower = hook.activeTickLowerOf(PROJECT_ID, NATIVE);
        int24 activeUpper = hook.activeTickUpperOf(PROJECT_ID, NATIVE);
        assertEq(activeLower, movedCorridorLower, "project=token1: asks anchor at the corridor ceiling (lower tick)");
        assertLt(activeUpper, corridorUpper + 1, "the bid bound must not exceed the corridor floor");
        assertGt(activeUpper, spotTick, "the bid bound (upper tick) must sit above spot: a real bid leg");

        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(tokenId);
        assertEq(amount1Locked, 1e18, "project (token1) asks must be fully deployed");
        assertGt(amount0Locked, 0, "native ETH (token0) must seed a nonzero bid");
    }
}
