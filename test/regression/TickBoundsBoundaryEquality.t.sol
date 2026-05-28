// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Harness exposing internal tick-bounds calculation so we can read the band the production code would use.
contract TickBoundsHarness is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(_directory, _permissions, _tokens, _permit2, IJBSuckerRegistry(address(0)), address(0))
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
        return _calculateTickBounds(projectId, terminalToken, projectToken, controller, ruleset);
    }
}

/// @notice The AR check at `_createAndInitializePool` used strict `<` / `>` comparisons against the project's
/// economic tick bounds, so boundary-equal preinitializations
/// (`existingSqrtPriceX96 == sqrtPriceAtTick(tickLower)` or `... == sqrtPriceAtTick(tickUpper)`) slipped through.
/// Boundary equality is the cheapest still-passing manipulation and sites the LP at the extreme of the economic
/// band, single-siding initial liquidity. Tightening to `<=` / `>=` rejects exact-edge preinit while keeping
/// strictly in-band prices accepted.
contract TickBoundsBoundaryEqualityTest is LPSplitHookV4TestBase {
    TickBoundsHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new TickBoundsHarness(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3)
        );
        harness.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0))
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
            hooks: IHooks(address(0))
        });
    }

    function test_boundaryEquality_lower_rejected() public {
        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        (int24 tickLower,) =
            harness.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        // Attacker preinitializes at exactly the lower-bound price. Pre-fix this slipped through the strict `<` check;
        // post-fix it must revert.
        uint160 boundaryPrice = TickMath.getSqrtPriceAtTick(tickLower);
        PoolKey memory key = _buildPoolKey();
        positionManager.initializePool(key, boundaryPrice);

        vm.prank(owner);
        vm.expectRevert();
        hook.deployPool(PROJECT_ID, 0);
    }

    function test_boundaryEquality_upper_rejected() public {
        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        (, int24 tickUpper) =
            harness.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        uint160 boundaryPrice = TickMath.getSqrtPriceAtTick(tickUpper);
        PoolKey memory key = _buildPoolKey();
        positionManager.initializePool(key, boundaryPrice);

        vm.prank(owner);
        vm.expectRevert();
        hook.deployPool(PROJECT_ID, 0);
    }

    function test_strictlyInBand_stillAccepted() public {
        uint256 totalProjectTokens = 100e18;
        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        (int24 tickLower,) =
            harness.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        // One spacing above the lower edge — strictly inside the band, should remain accepted under the tighter
        // comparison.
        uint160 inBandPrice = TickMath.getSqrtPriceAtTick(tickLower + hook.TICK_SPACING());
        PoolKey memory key = _buildPoolKey();
        positionManager.initializePool(key, inBandPrice);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);
        assertTrue(hook.hasDeployedPool(PROJECT_ID), "in-band preinit still accepted post-fix");
    }
}
