// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Harness that exposes _computeOptimalCashOutAmount for edge-case testing.
contract OutOfRangeAmountHarness is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(
            _directory,
            _permissions,
            _tokens,
            _poolManager,
            _positionManager,
            _permit2,
            IHooks(address(0)),
            IJBSuckerRegistry(address(0))
        )
    {}

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_computeOptimalCashOutAmount(
        uint256 projectId,
        address terminalToken,
        address _projectToken,
        uint256 totalProjectTokens,
        uint160 sqrtPriceInit,
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        returns (uint256)
    {
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        return _computeOptimalCashOutAmount(
            projectId,
            terminalToken,
            _projectToken,
            totalProjectTokens,
            sqrtPriceInit,
            tickLower,
            tickUpper,
            controller,
            ruleset
        );
    }
}

/// @notice Tests out-of-range token ordering and credit-only split regressions.
contract LPSplitRegressionFixes is LPSplitHookV4TestBase {
    OutOfRangeAmountHarness internal harness;

    // A new project ID with no ERC-20 token set (for test).
    uint256 constant NO_TOKEN_PROJECT_ID = 99;

    function setUp() public override {
        super.setUp();

        // Deploy harness for tests.
        harness = new OutOfRangeAmountHarness(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(hook.PERMIT2()))
        );

        // Set up project 99 with a controller but NO ERC-20 token (for ).
        _setDirectoryController(NO_TOKEN_PROJECT_ID, address(controller));
        controller.setWeight(NO_TOKEN_PROJECT_ID, DEFAULT_WEIGHT);
        controller.setFirstWeight(NO_TOKEN_PROJECT_ID, DEFAULT_WEIGHT);
        // Deliberately do NOT call jbTokens.setToken(NO_TOKEN_PROJECT_ID, ...).
        // tokenOf(99) will return address(0).
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Out-of-range token ordering — below range
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When sqrtPriceInit <= sqrtPriceA (below range), only token0 has value.
    ///         If the terminal IS token0, all project tokens should be cashed out.
    ///         If the terminal is NOT token0, zero tokens should be cashed out.
    function test_M40_fix_belowRange_correct_cashout() public view {
        uint256 totalProjectTokens = 100e18;

        // Use narrow tick range near the top so that a low sqrtPriceInit is below range.
        int24 tickLower = 60;
        int24 tickUpper = 120;
        // sqrtPriceInit below the lower bound.
        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceInit = sqrtPriceA - 1; // strictly below range

        // Determine which ordering our test tokens have.
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);

        uint256 result = harness.exposed_computeOptimalCashOutAmount(
            PROJECT_ID,
            address(terminalToken),
            address(projectToken),
            totalProjectTokens,
            sqrtPriceInit,
            tickLower,
            tickUpper
        );

        if (terminalIsToken0) {
            // Below range: only token0 has value. Terminal IS token0, so cash out everything.
            assertEq(result, totalProjectTokens, "below range: terminalIsToken0 should return all tokens");
        } else {
            // Below range: only token0 has value. Terminal is NOT token0, so cash out nothing.
            assertEq(result, 0, "below range: terminal is token1 should return 0");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Out-of-range token ordering — above range
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When sqrtPriceInit >= sqrtPriceB (above range), only token1 has value.
    ///         If the terminal IS token0, zero tokens should be cashed out.
    ///         If the terminal is NOT token0, all project tokens should be cashed out.
    function test_M40_fix_aboveRange_correct_cashout() public view {
        uint256 totalProjectTokens = 100e18;

        // Use narrow tick range near the bottom so that a high sqrtPriceInit is above range.
        int24 tickLower = -120;
        int24 tickUpper = -60;
        // sqrtPriceInit above the upper bound.
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);
        uint160 sqrtPriceInit = sqrtPriceB; // at or above range (>= triggers the branch)

        bool terminalIsToken0 = address(terminalToken) < address(projectToken);

        uint256 result = harness.exposed_computeOptimalCashOutAmount(
            PROJECT_ID,
            address(terminalToken),
            address(projectToken),
            totalProjectTokens,
            sqrtPriceInit,
            tickLower,
            tickUpper
        );

        if (terminalIsToken0) {
            // Above range: only token1 has value. Terminal is token0, so cash out nothing.
            assertEq(result, 0, "above range: terminalIsToken0 should return 0");
        } else {
            // Above range: only token1 has value. Terminal IS token1, so cash out everything.
            assertEq(result, totalProjectTokens, "above range: terminal is token1 should return all tokens");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Credit-only splits strand — revert before accumulation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice processSplitWith should revert with JBUniswapV4LPSplitHook_InvalidProjectId
    ///         BEFORE updating accumulatedProjectTokens when the project has no ERC-20 token.
    function test_M41_fix_reverts_before_accumulate() public {
        // Verify the project has no ERC-20 token set.
        assertEq(address(jbTokens.tokenOf(NO_TOKEN_PROJECT_ID)), address(0), "precondition: no ERC-20 token");

        // Confirm accumulator is zero before.
        assertEq(hook.accumulatedProjectTokens(NO_TOKEN_PROJECT_ID), 0, "precondition: accumulator is zero");

        // Build a reserved-token split context for the project with no ERC-20 token.
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(projectToken), // token field (what token is being split)
            amount: 50e18,
            decimals: 18,
            projectId: NO_TOKEN_PROJECT_ID,
            groupId: 1, // reserved token group
            split: JBSplit({
                percent: 1_000_000,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(hook))
            })
        });

        // Call processSplitWith from the controller — should revert.
        vm.prank(address(controller));
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidProjectId.selector);
        hook.processSplitWith(context);

        // Accumulator should still be zero (revert happened before _accumulateTokens).
        assertEq(hook.accumulatedProjectTokens(NO_TOKEN_PROJECT_ID), 0, "accumulator must remain zero after revert");
    }
}
