// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

contract CodexNemesisMathHook is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(
            _directory, _permissions, _tokens, _poolManager, _positionManager, _permit2, IHooks(address(0))
        )
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
        return _calculateTickBounds(projectId, terminalToken, projectToken, controller, ruleset);
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
        return _computeOptimalCashOutAmount(
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

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getCashOutRate(uint256 projectId, address terminalToken) external view returns (uint256) {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return _getCashOutRate(projectId, terminalToken, controller, ruleset);
    }
}

contract CodexNemesisPreinitializedRangePoC is LPSplitHookV4TestBase {
    CodexNemesisMathHook internal mathHook;

    function setUp() public override {
        super.setUp();

        mathHook = new CodexNemesisMathHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(hook.PERMIT2()))
        );

        directory.setTerminal(PROJECT_ID, JBConstants.NATIVE_TOKEN, address(terminal));
        terminal.setAccountingContext(PROJECT_ID, JBConstants.NATIVE_TOKEN, 1, 18);
        terminal.addAccountingContext(
            PROJECT_ID, JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: 1})
        );

        vm.deal(address(terminal), 1000 ether);
    }

    /// @notice Verify the fix: below-range positions now cash out ALL project tokens
    ///         (terminal is token0, so only token0 is needed for one-sided liquidity).
    function test_PreinitializedBelowRange_DeploysWithFullTerminalSideCashOut() public {
        uint256 totalProjectTokens = 100e18;

        _accumulateTokens(PROJECT_ID, totalProjectTokens);

        (int24 tickLower, int24 tickUpper) =
            mathHook.exposed_calculateTickBounds(PROJECT_ID, JBConstants.NATIVE_TOKEN, address(projectToken));
        uint160 sqrtPriceBelowRange = TickMath.getSqrtPriceAtTick(tickLower - hook.TICK_SPACING());

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(projectToken)),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
        positionManager.initializePool(key, sqrtPriceBelowRange);

        uint256 actualCashOut = mathHook.exposed_computeOptimalCashOutAmount(
            PROJECT_ID,
            JBConstants.NATIVE_TOKEN,
            address(projectToken),
            totalProjectTokens,
            sqrtPriceBelowRange,
            tickLower,
            tickUpper
        );

        // Post-fix: below-range with terminalIsToken0 returns totalProjectTokens (not half).
        assertEq(actualCashOut, totalProjectTokens, "below-range branch now cashes out all project tokens");

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, JBConstants.NATIVE_TOKEN, 0);

        assertEq(terminal.lastCashOutAmount(), actualCashOut, "deployPool used the full cash-out amount");

        // With the full cash-out, all project tokens become terminal tokens (token0).
        // Below-range liquidity only uses token0, so this is the optimal deployment.
        uint256 cashOutRate = mathHook.exposed_getCashOutRate(PROJECT_ID, JBConstants.NATIVE_TOKEN);
        uint256 terminalFromCashOut = (actualCashOut * cashOutRate) / 1e18;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // Since all tokens are cashed out, amount1 (project tokens) = 0.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts({
            sqrtPriceX96: sqrtPriceBelowRange,
            sqrtPriceAX96: sqrtPriceA,
            sqrtPriceBX96: sqrtPriceB,
            amount0: terminalFromCashOut,
            amount1: 0
        });

        assertGt(liquidity, 0, "full terminal-side deployment mints non-zero liquidity");
    }
}
