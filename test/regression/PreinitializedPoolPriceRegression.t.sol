// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract RegressionPriceMathHook is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(_directory, _permissions, _tokens, _permit2, IJBSuckerRegistry(address(0)), address(0))
    {}

    /// @dev Helper to fetch controller and ruleset for a project.
    function _fetchControllerAndRuleset(uint256 projectId)
        internal
        view
        returns (address controller, JBRuleset memory ruleset)
    {
        controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (ruleset,) = IJBController(controller).currentRulesetOf(projectId);
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

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_computeOptimalCashOutAmount(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        uint256 totalProjectTokens,
        uint160 sqrtPriceInit,
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        returns (uint256)
    {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.computeOptimalCashOutAmount(
            IJBDirectory(DIRECTORY),
            SUCKER_REGISTRY,
            projectId,
            terminalToken,
            projectToken,
            totalProjectTokens,
            sqrtPriceInit,
            tickLower,
            tickUpper,
            controller,
            ruleset
        );
    }
}

contract RegressionPreinitializedPoolPriceRegression is LPSplitHookV4TestBase {
    RegressionPriceMathHook internal mathHook;

    function setUp() public override {
        super.setUp();

        mathHook = new RegressionPriceMathHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3)
        );
        mathHook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0))
        });
    }

    /// @notice Pre-initialized pool at an out-of-bounds price now causes a revert,
    ///         protecting against frontrunning attacks that set extreme prices.
    function test_preinitializedPoolAtUnexpectedPrice_Reverts() public {
        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        (int24 tickLower,) =
            mathHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        // An attacker initializes the public pool outside the LP band before deployPool().
        uint160 attackerSqrtPrice = TickMath.getSqrtPriceAtTick(tickLower - hook.TICK_SPACING() * 5);

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

        positionManager.initializePool(key, attackerSqrtPrice);

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds.selector);
        hook.deployPool(PROJECT_ID, 0);
    }

    function test_preinitializedPoolWithinBandAcceptedByDeployment() public {
        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        (int24 tickLower, int24 tickUpper) =
            mathHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        uint160 expectedSqrtPrice =
            mathHook.exposed_computeInitialSqrtPrice(PROJECT_ID, address(terminalToken), address(projectToken));

        // Pick a price still inside the computed LP band, but not equal to the exact midpoint that deployPool expects.
        uint160 inBandSqrtPrice = TickMath.getSqrtPriceAtTick(tickLower + hook.TICK_SPACING());
        assertNotEq(inBandSqrtPrice, expectedSqrtPrice, "precondition: in-band price must differ from midpoint");
        assertTrue(inBandSqrtPrice > TickMath.getSqrtPriceAtTick(tickLower), "precondition: price stays in-band");
        assertTrue(inBandSqrtPrice < TickMath.getSqrtPriceAtTick(tickUpper), "precondition: price stays in-band");

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

        positionManager.initializePool(key, inBandSqrtPrice);

        // In-band pre-initialization should be accepted — the bounded price check tolerates it.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "the project should deploy successfully with an in-band price");
        assertGt(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), 0, "an LP position should be created");
    }
}
