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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {JBLPSplitHookHelpers} from "../src/libraries/JBLPSplitHookHelpers.sol";

/// @notice A recycle must place a project-only ask and a terminal-only bid on the correct sides of spot in BOTH Uniswap
/// currency orderings: project = token0 (a fresh ERC-20 pair where the project token sorts lower) and native ETH as the
/// terminal (address(0) = token0, so project = token1). Each case asserts the exact ask/bid ranges against the spot and
/// the (moved) corridor, the full project balance in the ask, and the full recovered terminal in the bid (each at its
/// exact V4 cost, any rounding remainder ledgered).
contract SingleSided_OrderingTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;

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
        _setWideTaxedCurve(PID);
        store.setBalance(address(terminal), PID, address(term), 10e18);
        _addDirectoryTerminal(PID, address(terminal));
    }

    /// @notice Assert a position's exact range.
    function _assertPosition(uint256 tokenId, int24 tickLower, int24 tickUpper) internal view {
        (, int24 lower, int24 upper, uint128 liquidity,,,) = positionManager._positions(tokenId);
        assertGt(liquidity, 0, "liquidity must be nonzero");
        assertEq(lower, tickLower, "tickLower");
        assertEq(upper, tickUpper, "tickUpper");
    }

    /// @notice Buyers fill part of `tokenId`, moving the spot into it: returns the new spot tick and the project and
    /// terminal the burn will recover.
    function _fill(
        uint256 tokenId,
        address proj
    )
        internal
        returns (int24 spotTick, uint256 recoveredProject, uint256 recoveredTerminal)
    {
        (uint256 amount0, uint256 amount1) = _fillHalfOf(tokenId);
        (PoolKey memory key,,,,,,) = positionManager._positions(tokenId);
        (, spotTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), key.toId());
        (recoveredProject, recoveredTerminal) =
            Currency.unwrap(key.currency0) == proj ? (amount0, amount1) : (amount1, amount0);
    }

    function test_ProjectIsToken0_RecycleAskAboveBidBelow() public {
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
        // fix), then let buyers fill part of it (moving the spot into it) so the recycle burn recovers bid capital.
        proj.mint(address(controller), 2e18);
        vm.prank(address(controller));
        proj.approve(address(hook), 2e18);
        vm.prank(address(controller));
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildContext(PID, address(proj), 1e18, 1));

        vm.prank(owner);
        hook.deployPool(PID);

        (int24 filledSpot, uint256 recoveredProject, uint256 recoveredTerminal) =
            _fill(hook.askTokenIdOf(PID, address(term)), address(proj));
        spotTick = filledSpot;

        // Move the corridor (drop the weight) so the recycle must re-derive it; the spot stays.
        controller.setWeight(PID, (DEFAULT_WEIGHT * 9) / 10);
        vm.prank(address(controller));
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildContext(PID, address(proj), 1e18, 1));
        uint256 projectIn = recoveredProject + hook.accumulatedProjectTokens(PID);
        vm.prank(user);
        hook.addLiquidity(PID, address(term));

        (JBRuleset memory movedRuleset,) = controller.currentRulesetOf(PID);
        (int24 movedLower, int24 movedUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PID,
            terminalToken: address(term),
            projectToken: address(proj),
            controller: address(controller),
            ruleset: movedRuleset
        });
        int24 spotFloor = JBLPSplitHookHelpers.alignTickToSpacing({tick: spotTick, spacing: hook.TICK_SPACING()});
        // The spot sits exactly on `spotTick`, so token0 starts at it when aligned, else one spacing up.
        int24 spotCeil = spotTick == spotFloor ? spotFloor : spotFloor + hook.TICK_SPACING();
        assertGt(spotFloor + hook.TICK_SPACING(), movedLower, "precondition: spot sits above the floor");
        assertLt(spotFloor, movedUpper, "precondition: spot sits below the ceiling");

        // project = token0: the ask (token0) rests above spot up to the ceiling, the bid (token1) from the floor to
        // spot.
        _assertPosition({tokenId: hook.askTokenIdOf(PID, address(term)), tickLower: spotCeil, tickUpper: movedUpper});
        _assertPosition({tokenId: hook.bidTokenIdOf(PID, address(term)), tickLower: movedLower, tickUpper: spotFloor});
        _assertPlacedExactly(PID, address(proj), address(term), projectIn, recoveredTerminal);
        assertTrue(movedLower != corridorLower || movedUpper != corridorUpper, "the recycle used the moved corridor");
    }

    function test_NativeEthTerminal_RecycleAskBelowBidAbove() public {
        // Wire the base PROJECT_ID against native ETH as the terminal token (address(0) = token0, project = token1).
        _setDirectoryTerminal(PROJECT_ID, NATIVE, address(terminal));
        terminal.setAccountingContext(PROJECT_ID, NATIVE, uint32(uint160(NATIVE)), 18);
        terminal.addAccountingContext(
            PROJECT_ID, JBAccountingContext({token: NATIVE, decimals: 18, currency: uint32(uint160(NATIVE))})
        );
        _setWideTaxedCurve(PROJECT_ID);
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

        // Deploy the project ask capital (asks-only), then let buyers fill part of it with native ETH (moving the
        // spot into it) so the recycle burn recovers bid capital.
        _accumulateTokens(PROJECT_ID, 1e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        (int24 filledSpot, uint256 recoveredProject, uint256 recoveredTerminal) =
            _fill(hook.askTokenIdOf(PROJECT_ID, NATIVE), address(projectToken));
        spotTick = filledSpot;

        // Move the corridor (drop the weight) so the recycle must re-derive it; the spot stays.
        controller.setWeight(PROJECT_ID, (DEFAULT_WEIGHT * 9) / 10);
        _accumulateTokens(PROJECT_ID, 1e18);
        uint256 projectIn = recoveredProject + hook.accumulatedProjectTokens(PROJECT_ID);
        vm.prank(user);
        hook.addLiquidity(PROJECT_ID, NATIVE);

        (JBRuleset memory movedRuleset,) = controller.currentRulesetOf(PROJECT_ID);
        (int24 movedLower, int24 movedUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: NATIVE,
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: movedRuleset
        });
        int24 spotFloor = JBLPSplitHookHelpers.alignTickToSpacing({tick: spotTick, spacing: hook.TICK_SPACING()});
        // The spot sits exactly on `spotTick`, so token0 starts at it when aligned, else one spacing up.
        int24 spotCeil = spotTick == spotFloor ? spotFloor : spotFloor + hook.TICK_SPACING();
        assertGt(spotFloor, movedLower, "precondition: spot sits above the ceiling");
        assertLt(spotFloor + hook.TICK_SPACING(), movedUpper, "precondition: spot sits below the floor");

        // project = token1: the ask (token1) rests from the ceiling up to spot, the bid (native, token0) above spot up
        // to the floor.
        _assertPosition({tokenId: hook.askTokenIdOf(PROJECT_ID, NATIVE), tickLower: movedLower, tickUpper: spotFloor});
        _assertPosition({tokenId: hook.bidTokenIdOf(PROJECT_ID, NATIVE), tickLower: spotCeil, tickUpper: movedUpper});
        _assertPlacedExactly(PROJECT_ID, address(projectToken), NATIVE, projectIn, recoveredTerminal);
        assertTrue(movedLower != corridorLower || movedUpper != corridorUpper, "the recycle used the moved corridor");
    }
}
