// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Regression tests for the LP-DOS-1 recovery valve (`burnAccumulatedTokens`).
/// @dev A lone actor can permissionlessly pre-initialize the hook's deterministic pool at an out-of-band price for the
///      cost of gas. `deployPool` then correctly reverts `ExistingPoolPriceOutOfBounds` (never minting a single-sided
///      position at the squatted price), and — because the pool's oracle hook routes every swap on a zero-liquidity
/// pool through Juicebox rather than the curve — the squatted price can never be moved back in-band. Without a
/// recovery
///      path the project's reserved tokens would be stranded in escrow forever. `burnAccumulatedTokens` lets the
/// project owner burn that escrow (raising the cash-out floor for remaining holders) without reading any pool price,
///      touching any Uniswap state, or sending value to any caller-controlled address.
contract SquatRecoveryRegression is LPSplitHookV4TestBase {
    event AccumulatedTokensBurned(uint256 indexed projectId, uint256 amount, address caller);

    /// @notice Build the PoolKey matching what the hook constructs internally.
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

    /// @notice A lone actor pre-initializes the deterministic pool at an attacker-chosen price.
    function _squatPoolInit(uint160 sqrtPriceX96) internal {
        positionManager.initializePool(_buildPoolKey(), sqrtPriceX96);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner can recover an escrow stranded by an out-of-band squat.
    // ─────────────────────────────────────────────────────────────────────

    function test_OwnerBurnsSquattedAccumulation() public {
        _accumulateTokens(PROJECT_ID, 1000e18);

        // Lone actor squats the pool above the economic band; deployPool is now bricked.
        _squatPoolInit(TickMath.MAX_SQRT_PRICE - 1);
        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds.selector);
        hook.deployPool(PROJECT_ID, 0);

        // Owner recovers the stranded escrow via the burn valve.
        vm.expectEmit(true, false, false, true, address(hook));
        emit AccumulatedTokensBurned(PROJECT_ID, 1000e18, owner);
        vm.prank(owner);
        hook.burnAccumulatedTokens(PROJECT_ID);

        // The ledger is zeroed and a single native burn of exactly the escrow was requested from this hook's balance.
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "ledger not cleared");
        assertEq(controller.burnCallCount(), 1, "expected exactly one burn");
        assertEq(controller.lastBurnAmount(), 1000e18, "wrong burn amount");
        assertEq(controller.lastBurnHolder(), address(hook), "burn must target the hook's own balance");
        assertEq(controller.lastBurnProjectId(), PROJECT_ID, "wrong burn project");
    }

    /// @notice The valve also handles a squat BELOW the band (single-sided in the other token).
    function test_OwnerBurnsSquattedAccumulation_BelowBand() public {
        _accumulateTokens(PROJECT_ID, 500e18);
        _squatPoolInit(TickMath.MIN_SQRT_PRICE + 1);

        vm.prank(owner);
        hook.burnAccumulatedTokens(PROJECT_ID);

        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "ledger not cleared");
        assertEq(controller.lastBurnAmount(), 500e18, "wrong burn amount");
    }

    // ─────────────────────────────────────────────────────────────────────
    // The valve cannot be abused.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A lone EOA with no permission cannot burn a project's escrow (would otherwise destroy a healthy
    ///         pre-deploy LP seed before its owner deploys).
    function test_BurnRevertsForNonOwner() public {
        _accumulateTokens(PROJECT_ID, 1000e18);
        _squatPoolInit(TickMath.MAX_SQRT_PRICE - 1);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        hook.burnAccumulatedTokens(PROJECT_ID);

        // Escrow is untouched.
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 1000e18, "escrow must be untouched on unauthorized call");
        assertEq(controller.burnCallCount(), 0, "no burn should have occurred");
    }

    /// @notice Once a live position exists the valve is closed — the LP can never be burned out from under itself.
    function test_BurnRevertsWhenPoolDeployed() public {
        _accumulateAndDeploy(PROJECT_ID, 1000e18);
        assertTrue(hook.isPoolDeployed(PROJECT_ID, address(terminalToken)), "pool should be deployed");

        // Accumulate more post-deploy so the ledger is non-zero (isolates the hasDeployedPool guard from the
        // empty-ledger guard).
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_PoolAlreadyDeployedForRecovery.selector);
        hook.burnAccumulatedTokens(PROJECT_ID);
    }

    /// @notice Nothing to burn → revert (also guards the CEI empty-ledger path).
    function test_BurnRevertsWhenNothingAccumulated() public {
        _squatPoolInit(TickMath.MAX_SQRT_PRICE - 1);
        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoTokensAccumulated.selector);
        hook.burnAccumulatedTokens(PROJECT_ID);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Graceful degrade: a squat never bricks reserved-token distribution, and recovery keeps the door open.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Reserved-token distribution (processSplitWith) keeps working while the pool is squatted.
    function test_AccumulationContinuesWhileSquatted() public {
        _squatPoolInit(TickMath.MAX_SQRT_PRICE - 1);

        _accumulateTokens(PROJECT_ID, 400e18);
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 400e18, "first accumulation failed");
        _accumulateTokens(PROJECT_ID, 600e18);
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 1000e18, "second accumulation failed");
    }

    /// @notice Recovery deliberately does not set `hasDeployedPool`, leaving a later deploy possible (e.g. on a fresh,
    ///         un-squatted terminal-token pairing) and accumulation able to resume.
    function test_BurnLeavesDeployDoorOpen() public {
        _accumulateTokens(PROJECT_ID, 1000e18);
        _squatPoolInit(TickMath.MAX_SQRT_PRICE - 1);

        vm.prank(owner);
        hook.burnAccumulatedTokens(PROJECT_ID);

        assertFalse(hook.hasDeployedPool(PROJECT_ID), "recovery must not mark the project deployed");
        assertFalse(
            hook.isPoolDeployed(PROJECT_ID, address(terminalToken)), "recovery must not mark the pairing deployed"
        );

        // Fresh reserved tokens can still accumulate afterward.
        _accumulateTokens(PROJECT_ID, 250e18);
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 250e18, "post-recovery accumulation failed");
    }
}
