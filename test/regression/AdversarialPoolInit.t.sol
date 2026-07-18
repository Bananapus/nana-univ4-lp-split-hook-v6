// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
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

/// @notice Harness that exposes internal tick/price computation for test assertions.
contract AdversarialPoolInitHook is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(_directory, _permissions, _tokens, _permit2, IJBSuckerRegistry(address(0)))
    {}

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
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        return JBUniswapV4LPSplitHookMath.calculateTickBounds(
            IJBDirectory(DIRECTORY), SUCKER_REGISTRY, projectId, terminalToken, projectToken, controller, ruleset
        );
    }
}

/// @notice Regression test for bug AR — adversarial pool pre-initialization.
/// @dev The fix validates that a pre-initialized pool's sqrtPriceX96 falls within the project's
///      economic tick range. Out-of-band prices are rejected (revert). In-band existing prices
///      are accepted and used for downstream liquidity calculations. This prevents an attacker
///      from either DoS-ing pool deployment (zero liquidity at extreme price) or extracting value
///      (single-sided position at a manipulated price).
contract AdversarialPoolInitTest is LPSplitHookV4TestBase {
    AdversarialPoolInitHook internal mathHook;

    function setUp() public override {
        super.setUp();

        mathHook = new AdversarialPoolInitHook(
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
            newOracleHook: IHooks(address(0)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });
    }

    function _buildPoolKey() internal view returns (PoolKey memory) {
        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);

        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
    }

    /// @notice Adversary pre-initializes pool at extreme low price (below economic range) → deployment reverts.
    function test_adversarialExtremePrice_belowRange_reverts() public {
        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        (int24 tickLower,) =
            mathHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        // Attacker sets an extreme low price below the economic range.
        uint160 extremePrice = TickMath.getSqrtPriceAtTick(tickLower - hook.TICK_SPACING() * 5);

        PoolKey memory key = _buildPoolKey();
        positionManager.initializePool(key, extremePrice);

        // The fix rejects out-of-band prices.
        vm.prank(owner);
        vm.expectRevert(); // JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds
        hook.deployPool(PROJECT_ID);
    }

    /// @notice Adversary pre-initializes pool at extreme high price (above economic range) → deployment reverts.
    function test_adversarialExtremePrice_aboveRange_reverts() public {
        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        (, int24 tickUpper) =
            mathHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        // Attacker sets an extreme high price above the economic range.
        uint160 extremePrice = TickMath.getSqrtPriceAtTick(tickUpper + hook.TICK_SPACING() * 5);

        PoolKey memory key = _buildPoolKey();
        positionManager.initializePool(key, extremePrice);

        // The fix rejects out-of-band prices.
        vm.prank(owner);
        vm.expectRevert(); // JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds
        hook.deployPool(PROJECT_ID);
    }

    /// @notice Pre-initialized pool within economic range → accepted, uses existing price.
    function test_inBandPreInit_accepted() public {
        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        (int24 tickLower,) =
            mathHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        // Set a price within the economic range (just above tickLower).
        uint160 inBandPrice = TickMath.getSqrtPriceAtTick(tickLower + hook.TICK_SPACING());

        PoolKey memory key = _buildPoolKey();
        positionManager.initializePool(key, inBandPrice);

        // In-band price is accepted — deployment succeeds.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "deployment should succeed with in-band price");
        assertGt(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), 0, "LP position should exist");
    }

    /// @notice No pre-initialization → normal flow, deployment succeeds.
    function test_noPreInit_normalFlow() public {
        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        // No adversary pre-init — clean deployment.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "normal deployment should succeed");
        assertGt(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), 0, "LP position should exist");
    }
}
