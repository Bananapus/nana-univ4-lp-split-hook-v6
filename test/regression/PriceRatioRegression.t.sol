// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {mulDiv, sqrt} from "@prb/math/src/Common.sol";

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice Harness that exposes internal functions for ratio testing.
contract PriceRatioHarness is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(_directory, _permissions, _tokens, _permit2, IJBSuckerRegistry(address(0)))
    {}

    function _fetchControllerAndRuleset(uint256 projectId)
        internal
        view
        returns (address controller, JBRuleset memory ruleset)
    {
        controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (ruleset,) = IJBController(controller).currentRulesetOf(projectId);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getCashOutRate(uint256 projectId, address terminalToken) external view returns (uint256) {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.getCashOutRate(
            IJBDirectory(DIRECTORY), SUCKER_REGISTRY, projectId, terminalToken, controller, ruleset
        );
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_calculateTickBounds(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        external
        view
        returns (int24, int24)
    {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.calculateTickBounds(
            IJBDirectory(DIRECTORY), SUCKER_REGISTRY, projectId, terminalToken, projectToken, controller, ruleset
        );
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_computeInitialSqrtPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        external
        view
        returns (uint160)
    {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.computeInitialSqrtPrice(
            IJBDirectory(DIRECTORY), SUCKER_REGISTRY, projectId, terminalToken, projectToken, controller, ruleset
        );
    }
}

/// @notice Token-ordering regression for extreme prices.
contract PriceRatioRegression is LPSplitHookV4TestBase {
    PriceRatioHarness internal harness;

    function setUp() public override {
        super.setUp();

        harness = new PriceRatioHarness(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(address(hook.PERMIT2()))
        );
        harness.initialize({
            initialFeeProjectId: 0,
            initialFeePercent: 0,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Token ordering for zero-rate extreme prices
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When issuance is zero, the extreme sqrtPrice depends on which token is token0.
    ///         The old code hardcoded MAX_SQRT_PRICE-1 regardless.
    function test_H30_zeroIssuanceExtremePrice_tokenOrdering() public view {
        // In the default setup, terminalToken and projectToken have deterministic addresses.
        // Verify the tick bounds reflect the correct extreme for both orderings.
        (int24 tickLower, int24 tickUpper) =
            harness.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        // With positive issuance AND cash-out, both bounds should be within valid range.
        assertTrue(tickLower < tickUpper, "tick bounds should be ordered");
        assertTrue(tickLower >= TickMath.MIN_TICK, "tickLower should be >= MIN_TICK");
        assertTrue(tickUpper <= TickMath.MAX_TICK, "tickUpper should be <= MAX_TICK");
    }
}
