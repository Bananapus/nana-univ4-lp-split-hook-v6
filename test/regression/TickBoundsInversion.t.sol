// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase, DEFAULT_SURPLUS_PER_TOKEN} from "../TestBaseV4.sol";
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
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {MockERC20} from "../mock/MockERC20.sol";

/// @notice Wrapper that exposes internal tick-bounds functions for testing tick bounds inversion.
contract TestableHookForTickBounds is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(_directory, _permissions, _tokens, _permit2, IJBSuckerRegistry(address(0)))
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
    function exposed_getCashOutRateSqrtPriceX96(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        external
        view
        returns (uint160)
    {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.getCashOutRateSqrtPriceX96(
            IJBDirectory(DIRECTORY), SUCKER_REGISTRY, projectId, terminalToken, projectToken, controller, ruleset
        );
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getIssuanceRateSqrtPriceX96(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        external
        view
        returns (uint160)
    {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return JBUniswapV4LPSplitHookMath.getIssuanceRateSqrtPriceX96(
            IJBDirectory(DIRECTORY), projectId, terminalToken, projectToken, controller, ruleset
        );
    }
}

/// @notice Regression test: Tick bounds inversion for token0-terminal pools.
///
/// @dev The bug: `_calculateTickBounds` assigned cashOut tick to tickLower and issuance tick to
///      tickUpper without sorting. For pools where the terminal token is token0 (lower address),
///      e.g. native ETH pools, the cashOut tick is HIGHER than the issuance tick, causing
///      tickLower >= tickUpper and collapsing the intended economic range.
///
///      The bounds are sorted by their exact sqrt prices before rounding inward to tickLower/tickUpper.
contract TickBoundsInversionTest is LPSplitHookV4TestBase {
    TestableHookForTickBounds public testableHook;

    // Token pair where terminalToken < projectToken (terminal is token0).
    // This is the ordering that triggers the bug.
    MockERC20 public lowTerminalToken;
    MockERC20 public highProjectToken;

    uint256 public constant TEST_PROJECT_ID = 10;

    function setUp() public override {
        super.setUp();

        // Deploy the testable hook (view-only, no pool manager needed).
        testableHook = new TestableHookForTickBounds(
            address(directory), IJBPermissions(address(permissions)), address(jbTokens), IAllowanceTransfer(address(0))
        );
        testableHook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(1)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });

        // Deploy two tokens at controlled addresses so that terminal < project (terminal is token0).
        // We use vm.etch to place MockERC20 code at specific addresses.
        address lowAddr = address(0x1111111111111111111111111111111111111111);
        address highAddr = address(0x9999999999999999999999999999999999999999);
        require(lowAddr < highAddr, "Test setup: lowAddr must be < highAddr");

        // Deploy real MockERC20s and copy their code to the target addresses.
        MockERC20 templateLow = new MockERC20("Low Terminal", "LOW", 18);
        MockERC20 templateHigh = new MockERC20("High Project", "HIGH", 18);
        vm.etch(lowAddr, address(templateLow).code);
        vm.etch(highAddr, address(templateHigh).code);

        lowTerminalToken = MockERC20(lowAddr);
        highProjectToken = MockERC20(highAddr);

        // Wire the test project with this token pair.
        _setDirectoryController(TEST_PROJECT_ID, address(controller));
        controller.setWeight(TEST_PROJECT_ID, DEFAULT_WEIGHT);
        controller.setFirstWeight(TEST_PROJECT_ID, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(TEST_PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(TEST_PROJECT_ID, 1); // ETH

        jbProjects.setOwner(TEST_PROJECT_ID, owner);
        jbTokens.setToken(TEST_PROJECT_ID, address(highProjectToken));

        _setDirectoryTerminal(TEST_PROJECT_ID, address(lowTerminalToken), address(terminal));
        _addDirectoryTerminal(TEST_PROJECT_ID, address(terminal));

        // Safe: lowAddr sentinel is a known test constant that fits in uint32.
        // forge-lint: disable-next-line(unsafe-typecast)
        terminal.setAccountingContext(
            TEST_PROJECT_ID, address(lowTerminalToken), uint32(uint160(address(lowTerminalToken))), 18
        );
        terminal.addAccountingContext(
            TEST_PROJECT_ID,
            JBAccountingContext({
                token: address(lowTerminalToken),
                decimals: 18,
                // forge-lint: disable-next-line(unsafe-typecast)
                currency: uint32(uint160(address(lowTerminalToken)))
            })
        );

        // Set surplus so the cash-out rate is nonzero and below the issuance price.
        store.setSurplus({projectId: TEST_PROJECT_ID, surplus: DEFAULT_SURPLUS_PER_TOKEN});

        // Set balance so auto-select picks lowTerminalToken for this project.
        store.setBalance(address(terminal), TEST_PROJECT_ID, address(lowTerminalToken), 10e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Tick bounds inversion when terminal token is token0
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Verify that terminalToken < projectToken (terminal is token0 in the V4 pool).
    ///         This is the precondition for the tick bounds inversion bug.
    function test_precondition_terminalIsToken0() public view {
        assertTrue(
            address(lowTerminalToken) < address(highProjectToken), "Terminal token should be token0 (lower address)"
        );
    }

    /// @notice When terminal is token0, the cashOut sqrtPrice > issuance sqrtPrice.
    ///         This demonstrates the root cause: the raw ticks are inverted relative
    ///         to the naive cashOut=lower, issuance=upper assumption.
    function test_rawTicksAreInverted_whenTerminalIsToken0() public view {
        // Read both raw bound prices for the token0-terminal pair.
        uint160 sqrtPriceCashOut = testableHook.exposed_getCashOutRateSqrtPriceX96({
            projectId: TEST_PROJECT_ID,
            terminalToken: address(lowTerminalToken),
            projectToken: address(highProjectToken)
        });
        uint160 sqrtPriceIssuance = testableHook.exposed_getIssuanceRateSqrtPriceX96({
            projectId: TEST_PROJECT_ID,
            terminalToken: address(lowTerminalToken),
            projectToken: address(highProjectToken)
        });

        // When terminal is token0 the price is project tokens per terminal token:
        //   cashOut sqrtPrice  = sqrt(WAD^2 / cashOutRate) = sqrt(1e36 / 0.0005e18) = sqrt(2000e18)
        //   issuance sqrtPrice = sqrt(issuanceRate)         = sqrt(900e18)
        // A cash-out value below the issuance price puts the cash-out tick ABOVE the issuance tick in this ordering.
        assertGt(sqrtPriceIssuance, 0, "Issuance sqrtPrice should be nonzero");
        assertGt(sqrtPriceCashOut, sqrtPriceIssuance, "CashOut sqrtPrice sits above issuance when terminal is token0");
    }

    /// @notice The fix ensures _calculateTickBounds produces a wide economic range
    ///         when terminal is token0.
    function test_tickBoundsAreWide_whenTerminalIsToken0() public view {
        (int24 tickLower, int24 tickUpper) = testableHook.exposed_calculateTickBounds(
            TEST_PROJECT_ID, address(lowTerminalToken), address(highProjectToken)
        );

        int24 tickSpacing = int24(200); // TICK_SPACING

        // Verify tickLower < tickUpper (basic correctness).
        assertLt(tickLower, tickUpper, "tickLower must be less than tickUpper");

        // A proper economic range spans many spacings.
        int24 range = tickUpper - tickLower;
        assertGt(range, 2 * tickSpacing, "Tick range should span more than two spacings");
    }

    /// @notice Demonstrate the bug with a low cash-out rate that makes the inversion obvious.
    ///         With cashOutRate = 1e12 and issuanceRate = 900e18:
    ///         - When terminal is token0: cashOut token1Amount = 1e36/1e12 = 1e24,
    ///           issuance token1Amount = 900e18.
    ///           So cashOut sqrtPrice = sqrt(1e24) >> sqrt(900e18) = issuance sqrtPrice.
    ///           This means cashOut tick >> issuance tick, triggering inversion.
    ///         With the fix, sorting ensures tickLower < tickUpper and the range is correct.
    function test_lowCashOutRate_wideRange_whenTerminalIsToken0() public {
        // Set a very low surplus => low cash-out rate.
        store.setSurplus({projectId: TEST_PROJECT_ID, surplus: 1e12});

        // Read both raw bound prices for the token0-terminal pair.
        uint160 sqrtPriceCashOut = testableHook.exposed_getCashOutRateSqrtPriceX96({
            projectId: TEST_PROJECT_ID,
            terminalToken: address(lowTerminalToken),
            projectToken: address(highProjectToken)
        });
        uint160 sqrtPriceIssuance = testableHook.exposed_getIssuanceRateSqrtPriceX96({
            projectId: TEST_PROJECT_ID,
            terminalToken: address(lowTerminalToken),
            projectToken: address(highProjectToken)
        });

        // Convert each raw price to the tick at or below it.
        int24 tickCashOut = TickMath.getTickAtSqrtPrice(sqrtPriceCashOut);
        int24 tickIssuance = TickMath.getTickAtSqrtPrice(sqrtPriceIssuance);

        // Confirm inversion: cashOut tick > issuance tick.
        assertGt(
            tickCashOut,
            tickIssuance,
            "With low cashOutRate and terminal as token0, cashOut tick should exceed issuance tick"
        );

        // Despite the raw tick inversion, _calculateTickBounds should sort correctly.
        (int24 tickLower, int24 tickUpper) = testableHook.exposed_calculateTickBounds({
            projectId: TEST_PROJECT_ID,
            terminalToken: address(lowTerminalToken),
            projectToken: address(highProjectToken)
        });

        assertLt(tickLower, tickUpper, "tickLower must be < tickUpper after sorting");

        // The range should be wide.
        int24 range = tickUpper - tickLower;
        assertGt(range, 2 * int24(200), "Range should span more than two spacings");

        // Verify tickLower came from the issuance tick (the lower one) and
        // tickUpper came from the cashOut tick (the higher one), after alignment.
        // Both bounds round inward against their exact prices: tickLower to the first aligned tick at or above the
        // issuance price, tickUpper to the last aligned tick at or below the cash-out price, so no project liquidity
        // sits outside the bonding-curve-sanctioned range.
        int24 issuanceTickAtOrAbove =
            TickMath.getSqrtPriceAtTick(tickIssuance) < sqrtPriceIssuance ? tickIssuance + 1 : tickIssuance;
        int24 alignedIssuance = _alignTickToSpacingCeil({tick: issuanceTickAtOrAbove, spacing: 200});
        int24 alignedCashOut = _alignTickToSpacing({tick: tickCashOut, spacing: 200});
        assertEq(tickLower, alignedIssuance, "tickLower should be the ceil-aligned issuance tick (the lower raw tick)");
        assertEq(tickUpper, alignedCashOut, "tickUpper should be the floor-aligned cashOut tick (the higher raw tick)");
    }

    function _alignTickToSpacingCeil(int24 tick, int24 spacing) internal pure returns (int24) {
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 rounded = (tick / spacing) * spacing;
        if (rounded < tick) rounded += spacing;
        return rounded;
    }

    /// @notice Confirm tick bounds are correct when terminal is token1 (no inversion).
    ///         This is the case that worked correctly even before the fix.
    function test_noInversion_whenTerminalIsToken1() public view {
        // Use the default tokens from the base setup (terminalToken, projectToken).
        // Check if terminalToken > projectToken (terminal is token1).
        bool terminalIsToken1 = address(terminalToken) > address(projectToken);

        // If the default ordering already has terminal as token1, test it.
        // Otherwise skip (the test above covers the token0 case).
        if (!terminalIsToken1) return;

        (int24 tickLower, int24 tickUpper) =
            testableHook.exposed_calculateTickBounds(PROJECT_ID, address(terminalToken), address(projectToken));

        assertLt(tickLower, tickUpper, "tickLower < tickUpper when terminal is token1");
        int24 range = tickUpper - tickLower;
        assertGt(range, 2 * int24(200), "Range should span more than two spacings");
    }

    /// @notice End-to-end: deploy a pool where terminal is token0.
    ///         With the fix, the pool deploys with a proper LP range.
    ///         Without the sort, the bounds would collapse and the corridor would be empty.
    function test_e2e_deployPool_whenTerminalIsToken0() public {
        // Accumulate project tokens.
        uint256 accAmount = 100e18;
        highProjectToken.mint(address(controller), accAmount);

        // Build context for the test project.
        vm.startPrank(address(controller));
        highProjectToken.approve(address(hook), accAmount);
        // Cap the gas below the inline-automation floor so the split is only accumulated.
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: TEST_PROJECT_ID, token: address(highProjectToken), amount: accAmount, groupId: 1})
        );
        vm.stopPrank();

        assertEq(hook.accumulatedProjectTokens(TEST_PROJECT_ID), accAmount, "Tokens should be accumulated");

        // Deploy the pool as owner.
        vm.prank(owner);
        hook.deployPool(TEST_PROJECT_ID);

        // Verify pool was deployed successfully with an ask position.
        uint256 tokenId = hook.askTokenIdOf({projectId: TEST_PROJECT_ID, terminalToken: address(lowTerminalToken)});
        assertNotEq(tokenId, 0, "tokenIdOf should be nonzero after deploy");
        assertTrue(hook.isPoolDeployed(TEST_PROJECT_ID, address(lowTerminalToken)), "projectDeployed should be true");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Economic inversion: cash-out value above the issuance price
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice A cash-out value of 0.5 terminal tokens per project token exceeds the issuance price (1/900): no price
    /// respects both bounds, so the corridor is empty instead of sorted, and a first deploy refuses.
    function test_economicInversion_emptyCorridor_deployReverts_whenTerminalIsToken0() public {
        // Lift the cash-out value above the issuance price.
        store.setSurplus({projectId: TEST_PROJECT_ID, surplus: 0.5e18});

        // No price respects both bounds, so the corridor is the empty (0, 0) band.
        (int24 tickLower, int24 tickUpper) = testableHook.exposed_calculateTickBounds({
            projectId: TEST_PROJECT_ID,
            terminalToken: address(lowTerminalToken),
            projectToken: address(highProjectToken)
        });
        assertEq(tickLower, 0, "inverted economics: empty corridor lower");
        assertEq(tickUpper, 0, "inverted economics: empty corridor upper");

        // Accumulate reserved tokens through the controller, capping the gas below the inline-automation floor so the
        // split is only accumulated.
        uint256 accAmount = 100e18;
        highProjectToken.mint({to: address(controller), amount: accAmount});
        vm.startPrank(address(controller));
        highProjectToken.approve({spender: address(hook), amount: accAmount});
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: TEST_PROJECT_ID, token: address(highProjectToken), amount: accAmount, groupId: 1})
        );
        vm.stopPrank();

        // The first deploy refuses the empty corridor and leaves the reserved tokens ledgered.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_EmptyCorridor.selector,
                TEST_PROJECT_ID,
                address(lowTerminalToken)
            )
        );
        vm.prank(owner);
        hook.deployPool(TEST_PROJECT_ID);
        assertEq(hook.accumulatedProjectTokens(TEST_PROJECT_ID), accAmount, "the reserved tokens stay ledgered");
    }

    // ─── Helper
    // ──────────────────────────────────────────────────────────

    /// @notice Replicate _alignTickToSpacing for test assertions.
    function _alignTickToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        // Intentional: rounding tick down to nearest spacing boundary
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 rounded = (tick / spacing) * spacing;
        if (tick < 0 && rounded > tick) {
            rounded -= spacing;
        }
        return rounded;
    }
}
