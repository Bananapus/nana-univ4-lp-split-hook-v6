// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @notice Attacker that holds the V4 lock via `PoolManager.unlock()` and, from its callback, attempts to call
/// `PositionManager.modifyLiquidities()`. The V4 PoolManager has a transient "unlocked" flag that must be cleared
/// before another unlock can succeed; the position manager always tries to unlock when it modifies liquidity, so
/// the inner call must revert with `AlreadyUnlocked()`. Anything the LP hook starts under that condition reverts
/// atomically, preventing partial state mutation.
contract _LockHoldingAttacker is IUnlockCallback {
    IPoolManager immutable poolManager;
    IPositionManager immutable positionManager;
    bool public sawAlreadyUnlocked;

    constructor(IPoolManager pm, IPositionManager posMgr) {
        poolManager = pm;
        positionManager = posMgr;
    }

    function attack() external {
        poolManager.unlock(bytes(""));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        // Inside the callback the V4 lock is held by this contract. Any inner unlock from PositionManager
        // must revert with AlreadyUnlocked().
        bytes memory empty = new bytes(0);
        bytes[] memory params = new bytes[](0);
        bytes memory unlockData = abi.encode(empty, params);

        try positionManager.modifyLiquidities{value: 0}(unlockData, block.timestamp + 60) {
            // If this returns, the protection failed — V4 should have rejected the reentrant unlock.
            sawAlreadyUnlocked = false;
        } catch (bytes memory reason) {
            // Selector for V4's `AlreadyUnlocked()` is the first 4 bytes of the revert reason.
            bytes4 selector = bytes4(reason);
            sawAlreadyUnlocked = selector == IPoolManager.AlreadyUnlocked.selector;
        }
        return bytes("");
    }
}

/// @notice Fork test against canonical V4 PoolManager + PositionManager on mainnet. Confirms that holding the V4
/// lock and invoking the position manager from inside the unlock callback reverts with `AlreadyUnlocked()` — the
/// V4-level protection our LP-split-hook implicitly relies on. If V4 ever weakens this guarantee, the inner call
/// would succeed and the hook's lock-held safety story changes.
contract PoolManagerLockHeldFork is Test {
    // Mainnet canonical addresses.
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    _LockHoldingAttacker attacker;

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);
        attacker = new _LockHoldingAttacker(POOL_MANAGER, POSITION_MANAGER);
    }

    /// @notice Holding the V4 lock then invoking `positionManager.modifyLiquidities` from the callback reverts
    /// with `AlreadyUnlocked()` from the real deployed V4 PoolManager.
    function testFork_lockHeld_positionManagerModifyReverts() public {
        attacker.attack();
        assertTrue(
            attacker.sawAlreadyUnlocked(),
            "V4 must revert AlreadyUnlocked when modifyLiquidities is called inside an active unlock"
        );
    }
}
