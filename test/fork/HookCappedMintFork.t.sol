// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized)
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// Local: test helpers
import {ThirdPartyLP, TwoPositionForkBase} from "./TwoPositionForkBase.sol";

/// @notice A recycle through the real hook and mainnet PositionManager whose TWAP-anchored ask range cannot hold all of
/// its inventory because of Uniswap's per-tick liquidity cap (`Pool.tickSpacingToMaxLiquidityPerTick(200)`, about
/// 3.8e34). The hook must mint exactly the cap (or the room a third-party LP left at a bound), pay exactly what that
/// liquidity costs at the live price, and keep the rest in its ledger.
/// @dev Why this configuration: the cap only binds when one spacing of range needs ~3.8e34 liquidity. For project
/// tokens (currency1 against native ETH) one spacing costs `liquidity * sqrtPrice * ~0.01`, so at an ordinary issuance
/// price
/// (1M tokens per ETH, tick ~138k) the cap is ~3.8e17 tokens, which no real project mints. The test therefore uses the
/// extreme-price corner where the cap is reachable with ordinary token counts: a weight of 1 (one wei of project token
/// per ETH, bounded at 2 wei by the ceiling), which puts the issuance ceiling near tick -407,400 where one spacing at
/// the cap costs ~5.4e5 tokens. The pool is pre-initialized one spacing inside that ceiling, so the TWAP-anchored ask
/// is exactly one spacing wide, and 2M tokens of inventory overflow it. The second case adds the configuration that
/// applies at any price: a third-party LP already holding most of the cap at the ask's lower bound, so the room left is
/// small.
contract HookCappedMintFork is TwoPositionForkBase {
    // Reads tick liquidity from the PoolManager's storage.
    using StateLibrary for IPoolManager;

    // Derives a pool ID from its key.
    using PoolIdLibrary for PoolKey;

    /// @notice Inventory far above what one spacing at the cap holds (~5.4e5 tokens here).
    uint256 internal constant _BIG_INVENTORY = 2_000_000e18;

    /// @notice An unprivileged caller that deploys the pool and triggers the recycle.
    address randomRecycler = address(0xBEEF2);

    /// @notice With no other liquidity at either bound, the recycled ask mints exactly the per-tick cap.
    function test_fork_cappedRecycle_mintsExactlyThePerTickCap() public {
        _runCappedRecycle({thirdPartyLiquidity: 0});
    }

    /// @notice A third-party LP holds 90% of the cap at the ask's lower bound: the ask mints exactly the 10% left.
    function test_fork_cappedRecycle_thirdPartyAtLowerBound_mintsRemainingRoom() public {
        _runCappedRecycle({thirdPartyLiquidity: Pool.tickSpacingToMaxLiquidityPerTick(200) * 9 / 10});
    }

    /// @notice Recycles an overflowing ask and checks it mints exactly the remaining per-tick room, pays exactly that
    /// liquidity's cost, and keeps the rest in the project ledger.
    /// @param thirdPartyLiquidity Liquidity a third-party LP places at the ask's lower bound first; 0 places none.
    function _runCappedRecycle(uint256 thirdPartyLiquidity) internal {
        // The per-tick cap at the hook's spacing.
        uint256 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(hook.TICK_SPACING());

        // A weight-1 project with real surplus and a small first allocation that fits easily.
        uint256 pid = _launchProject({reservedPercent: 0, weight: 1});
        vm.prank(multisig);
        IJBToken pToken =
            jbController.deployERC20For({projectId: pid, name: "Extreme Price", symbol: "XP", salt: bytes32(0)});
        _pay({pid: pid, amount: 1 ether});
        _accumulateTokens({pid: pid, pToken: address(pToken), amount: 1000e18});

        // Pre-initialize the pool one spacing (plus an off-grid offset) above the issuance ceiling, so the ask is the
        // single spacing [lo, lo + 200] below the spot.
        (int24 lo,) = _corridorOf({pid: pid, pToken: address(pToken)});
        int24 spacing = hook.TICK_SPACING();
        assertLt(lo, -400_000, "the issuance ceiling sits at the extreme-price end");
        PoolKey memory key = _keyOf(address(pToken));
        _V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(_offGrid(lo + spacing)));

        // Deploy the pool's first ask from an unprivileged caller.
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: _V4_POOL_MANAGER, key: key});
        vm.prank(randomRecycler);
        hook.deployPool(pid);
        uint256 oldAskId = hook.askTokenIdOf({projectId: pid, terminalToken: _NATIVE});
        assertTrue(oldAskId != 0, "the first ask must exist");
        assertLt(_V4_POSITION_MANAGER.getPositionLiquidity(oldAskId), maxPerTick / 100, "the first ask fits easily");

        // The next distribution overflows the range.
        _accumulateTokens({pid: pid, pToken: address(pToken), amount: _BIG_INVENTORY});

        // Optionally, a third-party LP takes most of the cap at the ask's lower bound (a range below the spot, so it
        // pays only project tokens).
        if (thirdPartyLiquidity != 0) {
            ThirdPartyLP lp = new ThirdPartyLP(_V4_POOL_MANAGER);
            vm.prank(multisig);
            jbController.mintTokensOf({
                projectId: pid, tokenCount: 1_000_000e18, beneficiary: address(lp), memo: "", useReservedPercent: false
            });
            lp.add({key: key, tickLower: lo - spacing, tickUpper: lo, liquidity: thirdPartyLiquidity});

            // The lower bound's gross liquidity is the third party's plus the old ask's.
            (uint128 gross,) = _V4_POOL_MANAGER.getTickLiquidity(key.toId(), lo);
            assertEq(
                gross,
                thirdPartyLiquidity + _V4_POSITION_MANAGER.getPositionLiquidity(oldAskId),
                "the third party shares the lower bound with the old ask"
            );
        }

        // Pre-recycle snapshot: what burning the old ask returns, the ledger and the hook's balance.
        (uint256 oldPrincipal0, uint256 oldPrincipal1) = _principalOf({tokenId: oldAskId, key: key});
        assertEq(oldPrincipal0, 0, "the old ask holds only project tokens");
        uint256 ledgerBefore = hook.accumulatedProjectTokens(pid);
        uint256 balBefore = IERC20(address(pToken)).balanceOf(address(hook));
        assertEq(ledgerBefore, balBefore, "ledger matches the hook balance before");

        // Recycle from an unprivileged caller and log its gas.
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: _V4_POOL_MANAGER, key: key});
        uint256 gasBefore = gasleft();
        vm.prank(randomRecycler);
        hook.addLiquidity({projectId: pid, terminalToken: _NATIVE});
        emit log_named_uint("  capped recycle gas", gasBefore - gasleft());

        // The fresh ask sits on the same single spacing and holds exactly the cap or the room left.
        uint256 askId = hook.askTokenIdOf({projectId: pid, terminalToken: _NATIVE});
        assertTrue(askId != 0 && askId != oldAskId, "a fresh ask was minted");
        assertEq(_V4_POSITION_MANAGER.getPositionLiquidity(oldAskId), 0, "the old ask was burned");
        assertEq(hook.bidTokenIdOf({projectId: pid, terminalToken: _NATIVE}), 0, "no bid without terminal tokens");
        (int24 tickLower, int24 tickUpper) = _ticksOf(askId);
        assertEq(tickLower, lo, "ask lower bound is the issuance ceiling");
        assertEq(tickUpper, lo + spacing, "ask upper bound is the spot floor");
        uint128 minted = _V4_POSITION_MANAGER.getPositionLiquidity(askId);
        assertEq(minted, maxPerTick - thirdPartyLiquidity, "minted liquidity is exactly the remaining per-tick room");
        (uint128 grossLower,) = _V4_POOL_MANAGER.getTickLiquidity(key.toId(), lo);
        assertEq(grossLower, maxPerTick, "the lower bound is now exactly full");

        // Exactly what that liquidity costs at the live price, rounded up as core does on an add.
        uint256 cost = SqrtPriceMath.getAmount1Delta({
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity: minted,
            roundUp: true
        });
        uint256 balAfter = IERC20(address(pToken)).balanceOf(address(hook));
        assertEq(balAfter + cost, balBefore + oldPrincipal1, "the hook paid exactly the minted liquidity's cost");

        // Everything else stays in the ledger and in the hook's balance.
        uint256 ledgerAfter = hook.accumulatedProjectTokens(pid);
        assertEq(ledgerAfter + cost, ledgerBefore + oldPrincipal1, "the excess stays in the project ledger");
        assertEq(ledgerAfter, balAfter, "ledger equals the hook's balance");
        assertGt(ledgerAfter, _BIG_INVENTORY / 2, "most of the inventory did not fit");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: pid, terminalToken: _NATIVE}),
            0,
            "no terminal tokens were involved"
        );
        assertEq(address(hook).balance, 0, "the hook holds no ETH");
    }
}
