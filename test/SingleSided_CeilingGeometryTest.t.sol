// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice Exposes the internal adaptive-range solver so the ceiling-side geometry can be driven directly for BOTH
/// token orderings (the `projectIsToken0` flag is an input, so one harness covers the native-ETH flip too).
contract CeilingGeometryExposedHook is JBUniswapV4LPSplitHook {
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IAllowanceTransfer permit2,
        IJBSuckerRegistry suckerRegistry
    )
        JBUniswapV4LPSplitHook(directory, permissions, tokens, permit2, suckerRegistry)
    {}

    function exposed_adaptiveRange(
        bool projectIsToken0,
        int24 corridorLower,
        int24 corridorUpper,
        uint160 sqrtSpotX96,
        uint256 projectAmount,
        uint256 terminalAmount
    )
        external
        pure
        returns (int24 tickLower, int24 tickUpper, uint256 bidAmountForMint)
    {
        return _adaptiveRange({
            projectIsToken0: projectIsToken0,
            corridorLower: corridorLower,
            corridorUpper: corridorUpper,
            sqrtSpotX96: sqrtSpotX96,
            projectAmount: projectAmount,
            terminalAmount: terminalAmount
        });
    }
}

/// @notice Ceiling-side geometry of the adaptive range. The hook offers project tokens as asks between the live spot
/// and the issuance ceiling, and terminal tokens as bids between the live spot and the cash-out floor. As the asks
/// fill, the hook's holdings convert to terminal, so the steady state near the ceiling is a BID-ONLY position: the
/// terminal must still deploy as bids even when there is no project token left (or no room left) to offer as asks.
contract SingleSided_CeilingGeometryTest is LPSplitHookV4TestBase {
    /// @notice The tick spacing of the 1% fee tier the hook deploys into.
    int24 internal constant SPACING = 200;

    /// @notice A wide, spacing-aligned corridor used for the pure geometry cases.
    int24 internal constant CORRIDOR_LOWER = -36_800;
    int24 internal constant CORRIDOR_UPPER = 68_000;

    /// @notice Project tokens available to offer as asks in the pure geometry cases.
    uint256 internal constant PROJECT_AMOUNT = 10e18;

    /// @notice Terminal tokens available to offer as bids in the pure geometry cases.
    uint256 internal constant TERMINAL_AMOUNT = 5e18;

    CeilingGeometryExposedHook internal _solver;

    function setUp() public override {
        super.setUp();
        _solver = new CeilingGeometryExposedHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3),
            IJBSuckerRegistry(address(0))
        );
    }

    /// @notice Resolve the adaptive range at a given spot tick for a given ordering and holdings.
    function _range(
        bool projectIsToken0,
        int24 spotTick,
        uint256 projectAmount,
        uint256 terminalAmount
    )
        internal
        view
        returns (int24 tickLower, int24 tickUpper, uint256 bidAmountForMint)
    {
        return _solver.exposed_adaptiveRange({
            projectIsToken0: projectIsToken0,
            corridorLower: CORRIDOR_LOWER,
            corridorUpper: CORRIDOR_UPPER,
            sqrtSpotX96: TickMath.getSqrtPriceAtTick(spotTick),
            projectAmount: projectAmount,
            terminalAmount: terminalAmount
        });
    }

    // ─── Near the ceiling with terminal held: a one-spacing ask leg survives instead of collapsing

    /// @notice Project = token0, spot one tick below the ceiling. The solved bid bound aligns onto the ceiling tick, so
    /// the range is clamped to keep a one-spacing ask leg rather than collapsing to a zero-width range.
    function test_AdaptiveRange_NearCeiling_ProjectToken0_KeepsOneSpacingAskLeg() public view {
        (int24 tickLower, int24 tickUpper, uint256 bid) =
            _range({projectIsToken0: true, spotTick: 67_999, projectAmount: PROJECT_AMOUNT, terminalAmount: 1e15});

        assertEq(tickUpper, CORRIDOR_UPPER, "asks still anchor to the issuance ceiling");
        assertEq(tickLower, CORRIDOR_UPPER - SPACING, "a one-spacing leg survives instead of collapsing");
        assertEq(bid, 1e15, "the held terminal is paired as the bid");
    }

    /// @notice Project = token1 (the native-ETH ordering): the mirror clamp keeps a one-spacing ask leg above the
    /// ceiling tick.
    function test_AdaptiveRange_NearCeiling_ProjectToken1_KeepsOneSpacingAskLeg() public view {
        (int24 tickLower, int24 tickUpper, uint256 bid) =
            _range({projectIsToken0: false, spotTick: -36_799, projectAmount: PROJECT_AMOUNT, terminalAmount: 1e15});

        assertEq(tickLower, CORRIDOR_LOWER, "asks still anchor to the issuance ceiling");
        assertEq(tickUpper, CORRIDOR_LOWER + SPACING, "a one-spacing leg survives instead of collapsing");
        assertEq(bid, 1e15, "the held terminal is paired as the bid");
    }

    // ─── Near the ceiling with nothing to bid with: a legible, documented refusal

    /// @notice Project = token0, spot inside the top spacing with no terminal held: there is no aligned ask leg above
    /// spot and nothing to bid with below it, so the refusal is the descriptive error, not the generic zero-liquidity
    /// one. The project tokens simply wait for the issuance price to rise or the spot to fall.
    function test_AdaptiveRange_NearCeiling_ZeroTerminal_ProjectToken0_Reverts() public {
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector);
        _solver.exposed_adaptiveRange({
            projectIsToken0: true,
            corridorLower: CORRIDOR_LOWER,
            corridorUpper: CORRIDOR_UPPER,
            sqrtSpotX96: TickMath.getSqrtPriceAtTick(67_999),
            projectAmount: PROJECT_AMOUNT,
            terminalAmount: 0
        });
    }

    /// @notice Project = token1: the mirror of the near-ceiling, nothing-to-bid-with refusal.
    function test_AdaptiveRange_NearCeiling_ZeroTerminal_ProjectToken1_Reverts() public {
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector);
        _solver.exposed_adaptiveRange({
            projectIsToken0: false,
            corridorLower: CORRIDOR_LOWER,
            corridorUpper: CORRIDOR_UPPER,
            sqrtSpotX96: TickMath.getSqrtPriceAtTick(-36_799),
            projectAmount: PROJECT_AMOUNT,
            terminalAmount: 0
        });
    }

    // ─── The filled-asks steady state: no project tokens left, terminal deploys as a bid-only position

    /// @notice Project = token0 with the asks fully filled (no project tokens left): the terminal deploys as bids from
    /// the cash-out floor up to the spot, and the whole terminal balance is paired.
    function test_AdaptiveRange_ZeroProject_ProjectToken0_BidOnly() public view {
        (int24 tickLower, int24 tickUpper, uint256 bid) =
            _range({projectIsToken0: true, spotTick: 15_700, projectAmount: 0, terminalAmount: TERMINAL_AMOUNT});

        assertEq(tickLower, CORRIDOR_LOWER, "bids reach down to the cash-out floor");
        assertEq(tickUpper, 15_600, "the bid leg's upper bound aligns inward to at/below spot");
        assertEq(bid, TERMINAL_AMOUNT, "the whole terminal balance is paired as the bid");
    }

    /// @notice Project = token1 with the asks fully filled: the mirror bid-only leg runs from spot up to the floor.
    function test_AdaptiveRange_ZeroProject_ProjectToken1_BidOnly() public view {
        (int24 tickLower, int24 tickUpper, uint256 bid) =
            _range({projectIsToken0: false, spotTick: 15_700, projectAmount: 0, terminalAmount: TERMINAL_AMOUNT});

        assertEq(tickLower, 15_800, "the bid leg's lower bound aligns inward to at/above spot");
        assertEq(tickUpper, CORRIDOR_UPPER, "bids reach up to the cash-out floor");
        assertEq(bid, TERMINAL_AMOUNT, "the whole terminal balance is paired as the bid");
    }

    // ─── Spot at/past the ceiling: bids still deploy, capped at the issuance price

    /// @notice Project = token0 with spot resting on the issuance ceiling: the bid leg spans the whole corridor and the
    /// project tokens are left for the caller to carry back to the accumulation ledger.
    function test_AdaptiveRange_SpotAtCeiling_ProjectToken0_BidOnly() public view {
        (int24 tickLower, int24 tickUpper, uint256 bid) = _range({
            projectIsToken0: true,
            spotTick: CORRIDOR_UPPER,
            projectAmount: PROJECT_AMOUNT,
            terminalAmount: TERMINAL_AMOUNT
        });

        assertEq(tickLower, CORRIDOR_LOWER, "bids reach down to the cash-out floor");
        assertEq(tickUpper, CORRIDOR_UPPER, "bids are capped at the issuance ceiling");
        assertEq(bid, TERMINAL_AMOUNT, "the whole terminal balance is paired as the bid");
    }

    /// @notice Project = token1 with spot past the issuance ceiling: bids are still capped at the ceiling, so the hook
    /// never buys project tokens above the issuance price.
    function test_AdaptiveRange_SpotPastCeiling_ProjectToken1_BidOnly() public view {
        (int24 tickLower, int24 tickUpper, uint256 bid) = _range({
            projectIsToken0: false,
            spotTick: CORRIDOR_LOWER - 3200,
            projectAmount: PROJECT_AMOUNT,
            terminalAmount: TERMINAL_AMOUNT
        });

        assertEq(tickLower, CORRIDOR_LOWER, "bids are capped at the issuance ceiling");
        assertEq(tickUpper, CORRIDOR_UPPER, "bids reach up to the cash-out floor");
        assertEq(bid, TERMINAL_AMOUNT, "the whole terminal balance is paired as the bid");
    }

    /// @notice Spot past the ceiling with nothing to bid with is the genuine nothing-to-deploy case.
    function test_AdaptiveRange_SpotPastCeiling_ZeroTerminal_Reverts() public {
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector);
        _solver.exposed_adaptiveRange({
            projectIsToken0: true,
            corridorLower: CORRIDOR_LOWER,
            corridorUpper: CORRIDOR_UPPER,
            sqrtSpotX96: TickMath.getSqrtPriceAtTick(CORRIDOR_UPPER + 2000),
            projectAmount: PROJECT_AMOUNT,
            terminalAmount: 0
        });
    }

    /// @notice A spot below the cash-out floor leaves no bid leg either, so a terminal-only holding refuses legibly.
    function test_AdaptiveRange_SpotBelowFloor_ZeroProject_Reverts() public {
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector);
        _solver.exposed_adaptiveRange({
            projectIsToken0: true,
            corridorLower: CORRIDOR_LOWER,
            corridorUpper: CORRIDOR_UPPER,
            sqrtSpotX96: TickMath.getSqrtPriceAtTick(CORRIDOR_LOWER - 100),
            projectAmount: 0,
            terminalAmount: TERMINAL_AMOUNT
        });
    }

    // ─── The healthy mid-corridor path is untouched

    /// @notice A mid-corridor deploy with a scarce terminal still anchors asks to the ceiling and solves the bid bound
    /// from the terminal balance, matching the ask-anchored geometry exactly.
    function test_AdaptiveRange_MidCorridor_ProjectToken0_MatchesAskAnchoredGeometry() public view {
        int24 spotTick = 15_700;
        uint160 sqrtSpot = TickMath.getSqrtPriceAtTick(spotTick);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0({
            sqrtPriceAX96: sqrtSpot, sqrtPriceBX96: TickMath.getSqrtPriceAtTick(CORRIDOR_UPPER), amount0: PROJECT_AMOUNT
        });
        uint160 sqrtBid = SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown({
            sqrtPX96: sqrtSpot, liquidity: liquidity, amount: TERMINAL_AMOUNT, add: false
        });
        int24 expectedLower = TickMath.getTickAtSqrtPrice(sqrtBid);
        expectedLower = ((expectedLower / SPACING) * SPACING) + (expectedLower % SPACING > 0 ? SPACING : int24(0));

        (int24 tickLower, int24 tickUpper, uint256 bid) = _range({
            projectIsToken0: true, spotTick: spotTick, projectAmount: PROJECT_AMOUNT, terminalAmount: TERMINAL_AMOUNT
        });

        assertEq(tickUpper, CORRIDOR_UPPER, "asks anchor to the issuance ceiling");
        assertEq(tickLower, expectedLower, "the bid bound is the ask-anchored solve, aligned inward");
        assertEq(bid, TERMINAL_AMOUNT, "a scarce terminal is fully paired");
    }

    /// @notice An abundant terminal still pins the bid bound at the cash-out floor and leaves the excess over.
    function test_AdaptiveRange_MidCorridor_AbundantTerminal_PinsAtFloor() public view {
        (int24 tickLower, int24 tickUpper, uint256 bid) = _range({
            projectIsToken0: true, spotTick: 15_700, projectAmount: PROJECT_AMOUNT, terminalAmount: 1_000_000e18
        });

        assertEq(tickLower, CORRIDOR_LOWER, "an abundant terminal pins the bid bound at the floor");
        assertEq(tickUpper, CORRIDOR_UPPER, "asks anchor to the issuance ceiling");
        assertLt(bid, 1_000_000e18, "only the floor-leg capacity is paired; the excess is a leftover");
        assertGt(bid, 0, "the floor-depth bid still pairs terminal into the position");
    }

    // ─── A pool pre-initialized at the issuance price is not permanently undeployable

    /// @notice The project's corridor for the live mock ruleset.
    function _corridor() internal view returns (int24 lower, int24 upper) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (lower, upper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
    }

    /// @notice Credit the project's OWN terminal bid-leg ledger and back it with real tokens, mirroring the ledger the
    /// hook writes when it routes collected LP fees or carries a mint leftover. The hook never sizes a bid from its raw
    /// (commingled) balance, so the ledger entry is what makes the terminal spendable for this project.
    function _creditTerminalLedger(uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(address(terminalToken), keccak256(abi.encode(PROJECT_ID, uint256(1)))));
        vm.store(address(hook), slot, bytes32(amount));
        terminalToken.mint(address(hook), amount);
        assertEq(hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)), amount, "ledger credited");
    }

    /// @notice Pre-initialize the pool at the issuance-ceiling price, exactly where a squatter would sit to make the
    /// pair undeployable. With terminal in the project's own ledger the hook deploys a bid-only position, which itself
    /// gives the market something to trade against.
    function test_Deploy_PreInitializedAtIssuanceCeiling_DeploysBidOnly() public {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});

        (int24 lower, int24 upper) = _corridor();
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        int24 ceilingTick = projectIsToken0 ? upper : lower;
        positionManager.initializePool(_poolKey(), TickMath.getSqrtPriceAtTick(ceilingTick));

        _accumulateTokens(PROJECT_ID, 1e18);
        _creditTerminalLedger(2e18);

        hook.deployPool(PROJECT_ID);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(tokenId, 0, "a pool squatted at the issuance price must still be deployable");

        // The minted range is the bid leg alone: it runs from the cash-out floor to the issuance ceiling and sits
        // wholly on the bid side of the spot, so only terminal tokens are drawn into it. (The mock PositionManager
        // settles the full caps rather than the range's real requirement, so the range is what pins the geometry.)
        int24 activeLower = hook.activeTickLowerOf(PROJECT_ID, address(terminalToken));
        int24 activeUpper = hook.activeTickUpperOf(PROJECT_ID, address(terminalToken));
        assertEq(activeLower, lower, "the bid leg starts at the corridor's lower bound");
        assertEq(activeUpper, upper, "the bid leg ends at the corridor's upper bound");
        if (projectIsToken0) {
            assertLe(activeUpper, ceilingTick, "bids never sit above the issuance ceiling");
        } else {
            assertGe(activeLower, ceilingTick, "bids never sit above the issuance ceiling");
        }

        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(tokenId);
        (, uint256 terminalSide) = projectIsToken0 ? (amount0Locked, amount1Locked) : (amount1Locked, amount0Locked);
        assertGt(terminalSide, 0, "the project's own terminal deploys as bids");
        assertLe(terminalSide, 2e18, "the bid never exceeds the project's own ledgered terminal");
    }

    /// @notice Deploy with the spot one tick inside the ceiling and BOTH project tokens and terminal held: the solved
    /// bid bound aligns onto the ceiling, so the range clamps to a one-spacing leg that straddles the spot and draws
    /// both tokens through the real mint rather than collapsing to zero width.
    function test_Deploy_NearCeiling_WithBothTokens_KeepsOneSpacingLeg() public {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});

        (int24 lower, int24 upper) = _corridor();
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        int24 ceilingTick = projectIsToken0 ? upper : lower;
        // One tick inside the ceiling: within the top spacing, where the bid bound would otherwise snap onto the
        // ceiling and collapse the range.
        int24 spotTick = projectIsToken0 ? ceilingTick - 1 : ceilingTick + 1;
        positionManager.initializePool(_poolKey(), TickMath.getSqrtPriceAtTick(spotTick));

        _accumulateTokens(PROJECT_ID, 1e18);
        _creditTerminalLedger(2e18);

        hook.deployPool(PROJECT_ID);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(tokenId, 0, "a spot inside the top spacing must still deploy, not collapse");

        // The clamp keeps a one-spacing ask leg pinned at the ceiling, straddling the spot so both sides are drawn.
        int24 activeLower = hook.activeTickLowerOf(PROJECT_ID, address(terminalToken));
        int24 activeUpper = hook.activeTickUpperOf(PROJECT_ID, address(terminalToken));
        assertEq(activeUpper - activeLower, SPACING, "the clamped leg is exactly one spacing wide");
        if (projectIsToken0) {
            assertEq(activeUpper, ceilingTick, "asks stay anchored to the issuance ceiling");
        } else {
            assertEq(activeLower, ceilingTick, "asks stay anchored to the issuance ceiling");
        }

        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(tokenId);
        (uint256 projectSide, uint256 terminalSide) =
            projectIsToken0 ? (amount0Locked, amount1Locked) : (amount1Locked, amount0Locked);
        assertGt(projectSide, 0, "the ask leg draws project tokens");
        assertGt(terminalSide, 0, "the straddle draws the project's own terminal as the bid");
        assertLe(terminalSide, 2e18, "the bid never exceeds the project's own ledgered terminal");
    }

    /// @notice The same squat with nothing to bid with refuses legibly rather than being permanently rejected as an
    /// out-of-bounds pool price: the accumulated tokens wait until the issuance price rises or the spot falls.
    function test_Deploy_PreInitializedAtIssuanceCeiling_NoTerminal_RevertsNoDeployableLiquidity() public {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});

        (int24 lower, int24 upper) = _corridor();
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        int24 ceilingTick = projectIsToken0 ? upper : lower;
        positionManager.initializePool(_poolKey(), TickMath.getSqrtPriceAtTick(ceilingTick));

        _accumulateTokens(PROJECT_ID, 1e18);

        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector);
        hook.deployPool(PROJECT_ID);
    }
}
