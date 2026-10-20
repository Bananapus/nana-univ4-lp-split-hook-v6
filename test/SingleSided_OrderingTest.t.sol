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

    /// @notice Buyers fill part of `tokenId`, moving the spot into it: returns the new spot tick and the project and
    /// terminal the burn will recover.
    /// @param tokenId The position to fill.
    /// @param proj The project token, used to map token0/token1 onto the project and terminal sides.
    /// @return spotTick The pool's spot tick after the fill.
    /// @return recoveredProject The project-token principal the position holds after the fill.
    /// @return recoveredTerminal The terminal-token principal the position holds after the fill.
    function _fill(
        uint256 tokenId,
        address proj
    )
        internal
        returns (int24 spotTick, uint256 recoveredProject, uint256 recoveredTerminal)
    {
        // Move the spot to the range's midpoint and re-mark the position's reserves to it.
        (uint256 amount0, uint256 amount1) = _fillHalfOf(tokenId);
        // Read the moved spot from the position's own pool.
        (PoolKey memory key,,,,,,) = positionManager._positions(tokenId);
        (, spotTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), key.toId());
        // Map token0/token1 onto the project and terminal sides by the pool's currency order.
        (recoveredProject, recoveredTerminal) =
            Currency.unwrap(key.currency0) == proj ? (amount0, amount1) : (amount1, amount0);
    }

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
    /// @param tokenId The position to check.
    /// @param tickLower The expected lower tick.
    /// @param tickUpper The expected upper tick.
    function _assertPosition(uint256 tokenId, int24 tickLower, int24 tickUpper) internal view {
        // A live position holds liquidity on exactly the expected range.
        (, int24 lower, int24 upper, uint128 liquidity,,,) = positionManager._positions(tokenId);
        assertGt(liquidity, 0, "liquidity must be nonzero");
        assertEq(lower, tickLower, "tickLower");
        assertEq(upper, tickUpper, "tickUpper");
    }

    /// @notice With project = token0, a recycle after a partial fill places the ask above spot up to the moved
    /// ceiling and the bid from the moved floor up to spot, each holding exactly its inventory.
    function test_ProjectIsToken0_RecycleAskAboveBidBelow() public {
        (MockERC20 proj, MockERC20 term) = _wireProjectToken0();

        // Compute the corridor with the same math and inputs the hook uses.
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
        positionManager.initializePool({key: key, sqrtPriceX96: TickMath.getSqrtPriceAtTick(spotTick)});

        // Deploy the project ask capital (asks-only: no hook-held terminal is ever paired into a deploy), then let
        // buyers fill part of it (moving the spot into it) so the recycle burn recovers bid capital. The controller is
        // funded for both splits up front.
        proj.mint({to: address(controller), amount: 2e18});
        vm.prank(address(controller));
        proj.approve({spender: address(hook), amount: 2e18});
        // Cap gas below the inline-automation floor so the split only records intake.
        vm.prank(address(controller));
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: PID, token: address(proj), amount: 1e18, groupId: 1})
        );

        vm.prank(owner);
        hook.deployPool(PID);

        // Fill the ask and track the moved spot the recycle prices against.
        (int24 filledSpot, uint256 recoveredProject, uint256 recoveredTerminal) =
            _fill({tokenId: hook.askTokenIdOf({projectId: PID, terminalToken: address(term)}), proj: address(proj)});
        spotTick = filledSpot;

        // Move the corridor (drop the weight) so the recycle must re-derive it; the spot stays.
        controller.setWeight({projectId: PID, weight: (DEFAULT_WEIGHT * 9) / 10});
        // Accumulate the second split with intake-only gas so the recycle runs only when triggered below.
        vm.prank(address(controller));
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: PID, token: address(proj), amount: 1e18, groupId: 1})
        );
        // The re-minted ask may place the recovered project principal plus the whole project ledger.
        uint256 projectIn = recoveredProject + hook.accumulatedProjectTokens(PID);
        // Any account may trigger the recycle.
        vm.prank(user);
        hook.addLiquidity({projectId: PID, terminalToken: address(term)});

        // Re-derive the corridor after the weight change, as the recycle did.
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
        // Align the spot down to the tick spacing, matching how the hook bounds positions around spot.
        int24 spotFloor = JBLPSplitHookHelpers.alignTickToSpacing({tick: spotTick, spacing: hook.TICK_SPACING()});
        // The spot sits exactly on `spotTick`, so token0 starts at it when aligned, else one spacing up.
        int24 spotCeil = spotTick == spotFloor ? spotFloor : spotFloor + hook.TICK_SPACING();
        assertGt(spotFloor + hook.TICK_SPACING(), movedLower, "precondition: spot sits above the floor");
        assertLt(spotFloor, movedUpper, "precondition: spot sits below the ceiling");

        // project = token0: the ask (token0) rests above spot up to the ceiling, the bid (token1) from the floor to
        // spot.
        _assertPosition({
            tokenId: hook.askTokenIdOf({projectId: PID, terminalToken: address(term)}),
            tickLower: spotCeil,
            tickUpper: movedUpper
        });
        _assertPosition({
            tokenId: hook.bidTokenIdOf({projectId: PID, terminalToken: address(term)}),
            tickLower: movedLower,
            tickUpper: spotFloor
        });
        // Each position holds exactly its inventory at its V4 cost.
        _assertPlacedExactly(PID, address(proj), address(term), projectIn, recoveredTerminal);
        assertTrue(movedLower != corridorLower || movedUpper != corridorUpper, "the recycle used the moved corridor");
    }

    /// @notice With native ETH as the terminal (project = token1), a recycle after a partial fill places the ask from
    /// the moved ceiling up to spot and the bid above spot up to the moved floor, each holding exactly its inventory.
    function test_NativeEthTerminal_RecycleAskBelowBidAbove() public {
        // Wire the base PROJECT_ID against native ETH as the terminal token (address(0) = token0, project = token1).
        _setDirectoryTerminal({projectId: PROJECT_ID, token: NATIVE, term: address(terminal)});
        terminal.setAccountingContext({
            projectId: PROJECT_ID, token: NATIVE, currency: uint32(uint160(NATIVE)), decimals: 18
        });
        terminal.addAccountingContext({
            projectId: PROJECT_ID,
            ctx: JBAccountingContext({token: NATIVE, decimals: 18, currency: uint32(uint160(NATIVE))})
        });
        // Widen the cash-out curve so the corridor spans enough ticks for both positions.
        _setWideTaxedCurve(PROJECT_ID);
        store.setBalance({terminal: address(terminal), projectId: PROJECT_ID, token: NATIVE, balance: 10e18});
        // Zero the base ERC-20 terminal's balance so `findHighestValueTerminalTokenOf` auto-selects native ETH.
        store.setBalance({
            terminal: address(terminal), projectId: PROJECT_ID, token: address(terminalToken), balance: 0
        });

        // Compute the corridor with the same math and inputs the hook uses.
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
        positionManager.initializePool({key: key, sqrtPriceX96: TickMath.getSqrtPriceAtTick(spotTick)});

        // Deploy the project ask capital (asks-only), then let buyers fill part of it with native ETH (moving the
        // spot into it) so the recycle burn recovers bid capital.
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // Fill the ask and track the moved spot the recycle prices against.
        (int24 filledSpot, uint256 recoveredProject, uint256 recoveredTerminal) = _fill({
            tokenId: hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: NATIVE}), proj: address(projectToken)
        });
        spotTick = filledSpot;

        // Move the corridor (drop the weight) so the recycle must re-derive it; the spot stays.
        controller.setWeight({projectId: PROJECT_ID, weight: (DEFAULT_WEIGHT * 9) / 10});
        // Accumulate fresh inventory so the recycle has something to add.
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        // The re-minted ask may place the recovered project principal plus the whole project ledger.
        uint256 projectIn = recoveredProject + hook.accumulatedProjectTokens(PROJECT_ID);
        // Any account may trigger the recycle.
        vm.prank(user);
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: NATIVE});

        // Re-derive the corridor after the weight change, as the recycle did.
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
        // Align the spot down to the tick spacing, matching how the hook bounds positions around spot.
        int24 spotFloor = JBLPSplitHookHelpers.alignTickToSpacing({tick: spotTick, spacing: hook.TICK_SPACING()});
        // The spot sits exactly on `spotTick`, so token0 starts at it when aligned, else one spacing up.
        int24 spotCeil = spotTick == spotFloor ? spotFloor : spotFloor + hook.TICK_SPACING();
        assertGt(spotFloor, movedLower, "precondition: spot sits above the ceiling");
        assertLt(spotFloor + hook.TICK_SPACING(), movedUpper, "precondition: spot sits below the floor");

        // project = token1: the ask (token1) rests from the ceiling up to spot, the bid (native, token0) above spot up
        // to the floor.
        _assertPosition({
            tokenId: hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: NATIVE}),
            tickLower: movedLower,
            tickUpper: spotFloor
        });
        _assertPosition({
            tokenId: hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: NATIVE}),
            tickLower: spotCeil,
            tickUpper: movedUpper
        });
        // Each position holds exactly its inventory at its V4 cost.
        _assertPlacedExactly(PROJECT_ID, address(projectToken), NATIVE, projectIn, recoveredTerminal);
        assertTrue(movedLower != corridorLower || movedUpper != corridorUpper, "the recycle used the moved corridor");
    }
}
