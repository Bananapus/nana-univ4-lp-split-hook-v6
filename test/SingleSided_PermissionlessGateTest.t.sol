// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice `deployPool` and `addLiquidity` are fully permissionless, with no owner or weight-decay gate. The only
/// gate is economic: the hook offers project tokens as asks only between the spot and the project's issuance-price
/// (ceiling) tick, so once the spot reaches the ceiling the asks have nowhere left to sit. Seeding/extending then
/// deploys a bid-only position from the project's own terminal, or reverts `NoDeployableLiquidityAtSpot` when there is
/// no terminal to bid with.
contract SingleSided_PermissionlessGateTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;

    address internal constant STRANGER = address(0xBEEF);

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

    function _key() internal view returns (PoolKey memory key) {
        (address c0, address c1) = address(terminalToken) < address(projectToken)
            ? (address(terminalToken), address(projectToken))
            : (address(projectToken), address(terminalToken));
        key = PoolKey({
            currency0: _wrap(c0),
            currency1: _wrap(c1),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
    }

    function _wrap(address a) internal pure returns (Currency c) {
        c = Currency.wrap(a);
    }

    function _setSpotTick(int24 tick) internal {
        PoolKey memory key = _key();
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        bytes32 poolId = PoolId.unwrap(key.toId());
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        uint24 lpFee = key.fee;
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 packed = bytes32((uint256(lpFee) << 208) | (uint256(uint24(tick)) << 160) | uint256(sqrtPriceX96));
        poolManager.writeSlot(stateSlot, packed);
    }

    /// @notice A complete stranger (no owner permission, no weight decay) can seed the pool permissionlessly.
    function test_Deploy_Permissionless_StrangerCanSeed() public {
        // Give the project a wide corridor and some inventory to seed.
        _setWideTaxedCurve(PROJECT_ID);
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});

        // A stranger with no permission deploys while the weight is still undecayed.
        vm.prank(STRANGER);
        hook.deployPool(PROJECT_ID);

        // The deploy mints the ask.
        assertNotEq(
            hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "a stranger must be able to seed the pool"
        );
    }

    /// @notice A stranger can extend an existing pool permissionlessly while a live corridor remains.
    function test_AddLiquidity_Permissionless_StrangerCanExtend() public {
        // A stranger seeds the pool from a wide corridor.
        _setWideTaxedCurve(PROJECT_ID);
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        vm.prank(STRANGER);
        hook.deployPool(PROJECT_ID);
        uint256 firstId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Accumulate more and extend as a stranger; the burn returns exactly the ask's principal at the spot.
        _accumulateTokens({projectId: PROJECT_ID, amount: 0.3e18});
        (uint256 recovered0, uint256 recovered1) = _principalAtSpot(firstId);
        uint256 projectIn = recovered0 + recovered1 + hook.accumulatedProjectTokens(PROJECT_ID);

        // The stranger recycles the ask with the new inventory.
        vm.prank(STRANGER);
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The recycle burns the first ask and mints a fresh one.
        uint256 secondId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(secondId, 0, "a stranger must be able to extend the pool");
        assertNotEq(secondId, firstId, "the extend consolidates into a fresh position");

        // The fresh ask (plus V4 rounding left in the ledger) holds the recovered principal and the new tokens.
        _assertPlacedExactly({
            projectId: PROJECT_ID,
            projectTokenAddr: address(projectToken),
            terminalTokenAddr: address(terminalToken),
            projectIn: projectIn,
            terminalIn: 0
        });

        // Every one of the 1.3e18 delivered tokens sits in the pool's reserves or the ledger.
        _assertPoolAndLedgerHold(1.3e18);
    }

    /// @notice `addLiquidity` reverts `NoDeployableLiquidityAtSpot` once the issuance ceiling has reached the spot and
    /// the project holds no terminal to offer as bids: there is no corridor left for asks to fill, and nothing to bid
    /// with. The accumulated project tokens wait until the issuance price rises or the spot falls.
    /// @dev The ceiling moves (the ruleset weight rises) rather than the spot, so the live ask keeps exactly the
    /// project-token principal it was minted with: had buyers pushed the spot to the ceiling instead, the ask would
    /// have filled into terminal tokens, which the recycle then deploys as a bid.
    function test_AddLiquidity_RevertsWhenSpotAtCeilingWithNothingToBidWith() public {
        // A non-inverted corridor: the cash-out floor sits genuinely below the issuance ceiling.
        _setWideTaxedCurve(PROJECT_ID);
        (int24 lower, int24 upper) = _corridor();

        // Pre-initialize the pool at the spacing-aligned middle of the corridor.
        int24 midTick = ((lower + (upper - lower) / 2) / hook.TICK_SPACING()) * hook.TICK_SPACING();
        positionManager.initializePool({key: _key(), sqrtPriceX96: TickMath.getSqrtPriceAtTick(midTick)});

        // A stranger seeds an asks-only pool, so the project holds no bid.
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        vm.prank(STRANGER);
        hook.deployPool(PROJECT_ID);
        assertEq(
            hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "precondition: nothing to bid with"
        );

        // More project tokens arrive for the next recycle.
        _accumulateTokens({projectId: PROJECT_ID, amount: 0.3e18});

        // Issuance cheapens 200x: the issuance ceiling crosses the unchanged spot. Ordering-aware: the ceiling is the
        // corridor's UPPER tick when the project is token0 and its LOWER tick when it is token1.
        controller.setWeight({projectId: PROJECT_ID, weight: DEFAULT_WEIGHT * 200});
        (lower, upper) = _corridor();
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        if (projectIsToken0) assertLe(upper, midTick, "precondition: the ceiling is at or below the spot");
        else assertGe(lower, midTick, "precondition: the ceiling is at or above the spot");
        assertLt(lower, upper, "precondition: the corridor is still well formed");

        // With no corridor for asks and no terminal for bids, the recycle has nothing to deploy.
        vm.prank(STRANGER);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector);
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
    }
}
