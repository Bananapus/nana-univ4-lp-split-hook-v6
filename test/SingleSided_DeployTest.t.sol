// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Task 1: `deployPool` mints a single-sided ask position from the project's accumulated reserved tokens
/// only — no funding cash-out. Covers the primary path where the pool is already initialized (the revnet norm).
contract SingleSided_DeployTest is LPSplitHookV4TestBase {
    function setUp() public override {
        super.setUp();
    }

    /// @notice deployPool mints a single-sided (asks-only) position: the minted position holds zero terminal
    /// tokens, the hook never calls `cashOutTokensOf`, and the store's surplus is left untouched.
    function test_DeployPool_MintsSingleSidedAsk_NoCashOut() public {
        // Realistic corridor: a real bonding-curve floor via the mock store's taxed-curve model (nonzero
        // cashOutTaxRate), so `getCashOutRate` returns an actual floor rather than falling back to a degenerate
        // band.
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});

        // Compute the project's economic corridor via the same math helper `deployPool` uses internally, so the
        // pre-initialized spot below is guaranteed to land strictly between the floor and the ceiling.
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (int24 corridorLower, int24 corridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
        assertLt(corridorLower, corridorUpper, "precondition: corridor must be non-degenerate");

        int24 midTick = corridorLower + (corridorUpper - corridorLower) / 2;
        uint160 midSqrtPrice = TickMath.getSqrtPriceAtTick(midTick);

        // Pre-initialize the pool at the mid-corridor spot BEFORE calling deployPool — the primary path assumes the
        // pool already exists (the revnet norm). Build the pool key exactly as the hook will.
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
            hooks: hook.oracleHook()
        });
        positionManager.initializePool(key, midSqrtPrice);

        _accumulateTokens(PROJECT_ID, 0.5e18);

        uint256 surplusBefore = store.surplusPerToken(PROJECT_ID);
        uint256 cashOutCallsBefore = terminal.cashOutCallCount();

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // (a) A position was minted.
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(tokenId, 0, "tokenIdOf should be nonzero after deployPool");

        // (b) The minted position holds ZERO terminal tokens (asks-only) and the full accumulated project-token
        // side — proving the mint really is single-sided, not just "some cash-out happened to round to zero".
        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(tokenId);
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        if (terminalIsToken0) {
            assertEq(amount0Locked, 0, "terminal-token side must be zero (asks-only)");
            assertEq(amount1Locked, 0.5e18, "project-token side should equal the full accumulated amount");
        } else {
            assertEq(amount1Locked, 0, "terminal-token side must be zero (asks-only)");
            assertEq(amount0Locked, 0.5e18, "project-token side should equal the full accumulated amount");
        }

        // (c) The hook never cashed out to fund the deploy.
        assertEq(terminal.cashOutCallCount(), cashOutCallsBefore, "deployPool must never call cashOutTokensOf");

        // (d) The store's surplus is left untouched (no reclaim ran against the bonding curve).
        assertEq(store.surplusPerToken(PROJECT_ID), surplusBefore, "surplus must be unchanged by a single-sided deploy");

        // The ledger is fully cleared: the mock PositionManager consumes 100% of the offered amount by default, so
        // there is no leftover to carry forward.
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "no leftover expected at 100% PositionManager usage");
    }
}
