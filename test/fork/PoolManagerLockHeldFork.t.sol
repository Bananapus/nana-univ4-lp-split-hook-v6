// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {ExposedJBUniswapV4LPSplitHook} from "../Fork.t.sol";

/// @notice Minimal stub returning a non-zero PROJECTS address so the hook's constructor succeeds. The lock-held
/// adversarial path we exercise here never reads PROJECTS, so any non-zero value is fine.
contract _StubDirectory {
    function PROJECTS() external pure returns (address) {
        return address(1);
    }
}

/// @notice Attacker that holds the V4 lock via `PoolManager.unlock()` and, from its callback, attempts to invoke
/// the LP-split-hook's `_modifyLiquidities` path (via the exposed harness). This routes through:
///     attacker.unlockCallback → hook._modifyLiquidities → positionManager.modifyLiquidities → poolManager.unlock
/// The inner `poolManager.unlock` must revert with `AlreadyUnlocked()`, and the revert must propagate up through
/// the hook unchanged — i.e., the hook must NOT swallow the revert or leave partial state behind.
contract _LockHoldingAttacker is IUnlockCallback {
    IPoolManager immutable poolManager;
    ExposedJBUniswapV4LPSplitHook immutable hook;
    bool public sawAlreadyUnlocked;
    bytes4 public capturedSelector;

    constructor(IPoolManager pm, ExposedJBUniswapV4LPSplitHook hk) {
        poolManager = pm;
        hook = hk;
    }

    function attack() external {
        poolManager.unlock(bytes(""));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        // Build a minimal modifyLiquidities payload. We don't care about the actions — the call must revert
        // before V4 ever interprets them, because positionManager.modifyLiquidities itself opens a fresh unlock,
        // which V4 rejects with AlreadyUnlocked() because THIS contract is still holding the lock.
        bytes memory actions = new bytes(0);
        bytes[] memory params = new bytes[](0);
        bytes memory unlockData = abi.encode(actions, params);

        try hook.exposed_modifyLiquidities{value: 0}(unlockData, 0) {
            sawAlreadyUnlocked = false;
        } catch (bytes memory reason) {
            // The revert is propagated up from V4's AlreadyUnlocked() through positionManager and back through
            // the hook. The hook must not catch or repackage it.
            capturedSelector = bytes4(reason);
            sawAlreadyUnlocked = capturedSelector == IPoolManager.AlreadyUnlocked.selector;
        }
        return bytes("");
    }
}

/// @notice Routes the V4 lock-held adversarial scenario THROUGH the LP-split-hook (not bypassing it). Confirms
/// the hook's path `hook._modifyLiquidities → positionManager.modifyLiquidities → poolManager.unlock` reverts
/// with `AlreadyUnlocked()` and the revert propagates unchanged — proving the hook doesn't swallow the V4
/// protection or leave partial state behind.
contract PoolManagerLockHeldFork is Test {
    // Mainnet canonical addresses.
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    ExposedJBUniswapV4LPSplitHook hook;
    _LockHoldingAttacker attacker;

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);

        // The hook is designed to be a clone; the `_modifyLiquidities` path we exercise here only touches
        // `positionManager`. The constructor reads `directory.PROJECTS()`, so we pass a stub that returns
        // a non-zero address — the value is never read on this code path.
        _StubDirectory stubDirectory = new _StubDirectory();
        ExposedJBUniswapV4LPSplitHook hookImpl =
            new ExposedJBUniswapV4LPSplitHook(address(stubDirectory), IJBPermissions(address(0)), address(0), PERMIT2);
        hook = ExposedJBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));
        hook.initialize({
            initialFeeProjectId: 0,
            initialFeePercent: 0,
            newPoolManager: POOL_MANAGER,
            newPositionManager: POSITION_MANAGER,
            newOracleHook: IHooks(address(0))
        });

        attacker = new _LockHoldingAttacker(POOL_MANAGER, hook);
    }

    /// @notice The hook's `_modifyLiquidities` path reverts with `AlreadyUnlocked()` when called from inside a
    /// V4 unlock callback. Proves the hook surfaces the V4 protection rather than swallowing it.
    function testFork_lockHeld_throughHookPath_reverts() public {
        attacker.attack();
        assertTrue(
            attacker.sawAlreadyUnlocked(),
            "Hook's modifyLiquidities path must revert with AlreadyUnlocked() when V4 lock is held"
        );
        assertEq(
            attacker.capturedSelector(),
            IPoolManager.AlreadyUnlocked.selector,
            "Hook must propagate V4's revert selector unchanged"
        );
    }
}
