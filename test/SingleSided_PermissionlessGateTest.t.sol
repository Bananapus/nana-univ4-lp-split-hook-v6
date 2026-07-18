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

/// @notice `deployPool` and `addLiquidity` are fully permissionless — the weight-decay owner gate is gone. The only
/// gate is economic: seeding/extending reverts `SpotAboveCeilingAtSeed` once the pool's spot has reached the project's
/// issuance-price (ceiling) tick, since there is then no live corridor for asks to fill.
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
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});
        _accumulateTokens(PROJECT_ID, 1e18);

        // The old owner-gate would revert `JBPermissioned_Unauthorized` here (weight is undecayed). It's gone.
        vm.prank(STRANGER);
        hook.deployPool(PROJECT_ID);

        assertNotEq(hook.tokenIdOf(PROJECT_ID, address(terminalToken)), 0, "a stranger must be able to seed the pool");
    }

    /// @notice A stranger can extend an existing pool permissionlessly while a live corridor remains.
    function test_AddLiquidity_Permissionless_StrangerCanExtend() public {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});
        _accumulateTokens(PROJECT_ID, 1e18);
        vm.prank(STRANGER);
        hook.deployPool(PROJECT_ID);
        uint256 firstId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Fund the PositionManager for the burn+re-mint consolidation, then accumulate more and extend as a stranger.
        projectToken.mint(address(positionManager), 100e18);
        terminalToken.mint(address(positionManager), 100e18);
        _accumulateTokens(PROJECT_ID, 0.3e18);

        vm.prank(STRANGER);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        uint256 secondId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(secondId, 0, "a stranger must be able to extend the pool");
        assertNotEq(secondId, firstId, "the extend consolidates into a fresh position");
    }

    /// @notice `addLiquidity` reverts `SpotAboveCeilingAtSeed` once the spot has reached the issuance ceiling, even for
    /// a permissionless caller — there is no live corridor for asks to fill.
    function test_AddLiquidity_RevertsWhenSpotAtCeiling() public {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});
        _accumulateTokens(PROJECT_ID, 1e18);
        vm.prank(STRANGER);
        hook.deployPool(PROJECT_ID);

        projectToken.mint(address(positionManager), 100e18);
        terminalToken.mint(address(positionManager), 100e18);
        _accumulateTokens(PROJECT_ID, 0.3e18);

        // Push spot onto the issuance ceiling. Ordering-aware: project = token1 here, so the issuance ceiling is the
        // corridor's LOWER tick; drive spot down onto it.
        (int24 lower, int24 upper) = _corridor();
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        int24 ceilingTick = projectIsToken0 ? upper : lower;
        _setSpotTick(ceilingTick);

        vm.prank(STRANGER);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_SpotAboveCeilingAtSeed.selector);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
    }
}
