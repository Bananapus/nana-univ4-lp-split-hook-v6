// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {BuySwapHelper} from "./Integration_SingleSidedRevnet.t.sol";
import {TwoPositionForkBase} from "./TwoPositionForkBase.sol";

/// @notice An empty corridor on the real mainnet PoolManager/PositionManager: the project's cash-out value per token
/// reaches its issuance price (here by inverting, including by less than one tick), so no price is both at or above
/// the cash-out value and at or below the issuance price. The hook must refuse to seed a pool, retire live positions
/// into its ledgers when the corridor empties, never let a buyer take project tokens below their cash-out value from
/// it, and redeploy once the corridor reopens.
///
/// Economics: weight 1M tokens per ETH with a 50% reserved percent, so the hook's issuance ceiling is the net price,
/// 2e-6 ETH per token, while payments mint at 1e-6 ETH per token gross. A 100 ETH `addToBalanceOf` donation lifts the
/// cash-out value far above 2e-6 (inverted); later payments pull it back toward 1e-6, below the ceiling (normal).
contract EmptyCorridorFork is TwoPositionForkBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address randomCaller = address(0xD00D);
    address buyer = address(0xB0B);

    /// @notice With cash-out value above issuance from the start, a permissionless `deployPool` reverts and keeps the
    /// inventory ledgered.
    function test_fork_deployPool_emptyCorridor_reverts() public {
        uint256 pid = _launchProject({reservedPercent: 0, weight: 1_000_000e18});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Inverted", "INV", bytes32(0));
        _pay(pid, 1 ether);
        _accumulateTokens(pid, address(pToken), 1000e18);
        _donate(pid, 100 ether);

        (int24 lo, int24 hi) = _corridorOf(pid, address(pToken));
        assertEq(lo, hi, "the corridor is empty");

        vm.expectRevert(
            abi.encodeWithSelector(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_EmptyCorridor.selector, pid, NATIVE)
        );
        vm.prank(randomCaller);
        hook.deployPool(pid);

        assertFalse(hook.isPoolDeployed(pid, NATIVE), "no pool was deployed");
        assertEq(hook.accumulatedProjectTokens(pid), 1000e18, "the inventory stays ledgered");
        assertEq(IERC20(address(pToken)).balanceOf(address(hook)), 1000e18, "and in the hook's balance");
    }

    /// @notice Live ask and bid deployed under normal economics; a donation inverts the corridor. A permissionless
    /// recycle retires both positions and ledgers every recovered token exactly; no buyer can then take project tokens
    /// from the hook below their cash-out value; once payments reopen the corridor, the recycle redeploys inside it.
    function test_fork_emptyCorridor_retiresBothPositions_thenRedeploys() public {
        // ── Normal economics: deploy an ask, let a buyer fill part of it, recycle into an ask and a bid.
        uint256 pid = _launchProject({reservedPercent: 5000, weight: 1_000_000e18});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Revnet Token", "RVNT", bytes32(0));
        _pay(pid, 10 ether);
        _accumulateTokens(pid, address(pToken), 5_000_000e18);

        PoolKey memory key = _keyOf(address(pToken));
        {
            (int24 lo, int24 hi) = _corridorOf(pid, address(pToken));
            assertGt(hi - lo, 20 * hook.TICK_SPACING(), "a wide normal corridor");
            V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(_offGrid(lo + (hi - lo) / 2)));
        }
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        vm.prank(randomCaller);
        hook.deployPool(pid);

        BuySwapHelper swapHelper = new BuySwapHelper(V4_POOL_MANAGER);
        vm.deal(buyer, 100 ether);
        _buy(swapHelper, key, 1 ether);
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        vm.prank(randomCaller);
        hook.addLiquidity(pid, NATIVE);
        uint256 askId = hook.askTokenIdOf(pid, NATIVE);
        uint256 bidId = hook.bidTokenIdOf(pid, NATIVE);
        assertTrue(askId != 0 && bidId != 0, "both positions are live");

        // Trade into both positions so each carries fees to route at retirement.
        _buy(swapHelper, key, 0.2 ether);
        {
            uint256 sellAmount = IERC20(address(pToken)).balanceOf(buyer) / 2;
            vm.startPrank(buyer);
            IERC20(address(pToken)).approve(address(swapHelper), sellAmount);
            // forge-lint: disable-next-line(unsafe-typecast)
            swapHelper.swap({key: key, zeroForOne: false, amountSpecified: -int256(sellAmount)});
            vm.stopPrank();
        }

        // ── Invert: a donation lifts the cash-out value above the issuance price.
        _donate(pid, 100 ether);
        {
            (int24 lo, int24 hi) = _corridorOf(pid, address(pToken));
            assertEq(lo, hi, "the donation empties the corridor");
        }

        // Expected ledgers: pre-retire ledgers plus each position's burn principal at the live spot. The fees accrue to
        // the project instead: the ETH fees after the fee-project cut are added to its balance, and the project-token
        // fees (no cut: the fee project has no terminal for this token) are burned.
        uint256 expectedProject = hook.accumulatedProjectTokens(pid);
        uint256 expectedTerminal = hook.accumulatedTerminalTokens(pid, NATIVE);
        uint256 routedFees0;
        uint256 routedFees1;
        uint256 ethRemainder;
        uint256[2] memory ids = [askId, bidId];
        for (uint256 i; i < 2; i++) {
            (uint256 principal0, uint256 principal1) = _principalOf(ids[i], key);
            (uint256 fee0, uint256 fee1) = _feesOf(ids[i], key);
            routedFees0 += fee0;
            routedFees1 += fee1;
            expectedTerminal += principal0;
            expectedProject += principal1;
            ethRemainder += fee0 - (fee0 * hook.feePercent()) / hook.BPS();
        }
        assertGt(routedFees0, 0, "the ask earned ETH fees");
        assertGt(routedFees1, 0, "the bid earned project-token fees");
        uint256 projectBalanceBefore = jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, NATIVE);
        uint256 supplyBefore = IERC20(address(pToken)).totalSupply();

        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        vm.prank(randomCaller);
        hook.addLiquidity(pid, NATIVE);

        assertEq(V4_POSITION_MANAGER.getPositionLiquidity(askId), 0, "the ask was retired");
        assertEq(V4_POSITION_MANAGER.getPositionLiquidity(bidId), 0, "the bid was retired");
        assertEq(hook.askTokenIdOf(pid, NATIVE), 0, "no live ask");
        assertEq(hook.bidTokenIdOf(pid, NATIVE), 0, "no live bid");
        assertEq(V4_POOL_MANAGER.getLiquidity(key.toId()), 0, "the pool holds no liquidity at all");
        assertEq(hook.accumulatedProjectTokens(pid), expectedProject, "project ledger: principal");
        assertEq(hook.accumulatedTerminalTokens(pid, NATIVE), expectedTerminal, "terminal ledger: principal");
        assertEq(
            jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, NATIVE) - projectBalanceBefore,
            ethRemainder,
            "the ETH fee remainders were added to the project's balance"
        );
        assertEq(
            supplyBefore - IERC20(address(pToken)).totalSupply(), routedFees1, "the project-token fees were burned"
        );
        assertEq(IERC20(address(pToken)).balanceOf(address(hook)), expectedProject, "project tokens all held");
        assertEq(address(hook).balance, expectedTerminal, "ETH all held");

        // With nothing left to retire, another recycle reverts rather than quoting into the empty corridor.
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        vm.expectRevert(
            abi.encodeWithSelector(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_EmptyCorridor.selector, pid, NATIVE)
        );
        vm.prank(randomCaller);
        hook.addLiquidity(pid, NATIVE);

        // ── Codex economics check: a buyer sweeping the price to the cash-out value gets no fill from the hook, so
        // no hook quote sells project tokens below what they cash out for.
        {
            uint160 cashOutSqrtPrice = _cashOutSqrtPrice(pid, address(pToken));
            (uint160 spot,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
            assertLt(cashOutSqrtPrice, spot, "buying toward the cash-out value moves the price down");
            uint256 tokensBefore = IERC20(address(pToken)).balanceOf(buyer);
            uint256 ethBefore = buyer.balance;
            vm.prank(buyer);
            swapHelper.swapTo{value: 10 ether}({
                key: key, zeroForOne: true, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: cashOutSqrtPrice
            });
            assertEq(IERC20(address(pToken)).balanceOf(buyer), tokensBefore, "no project tokens below cash-out value");
            assertEq(buyer.balance, ethBefore, "the buyer paid nothing");
            assertEq(hook.accumulatedProjectTokens(pid), expectedProject, "the hook's inventory is untouched");
        }

        // ── Normal again: payments at the gross price pull the cash-out value back below the net issuance price.
        _pay(pid, 300 ether);
        (int24 newLo, int24 newHi) = _corridorOf(pid, address(pToken));
        assertGt(newHi - newLo, 4 * hook.TICK_SPACING(), "the corridor reopened");

        // The empty pool lets anyone move its spot for free; the TWAP guard is what protects the recycle. Put the spot
        // mid-corridor and recycle at a TWAP equal to it.
        vm.prank(buyer);
        swapHelper.swapTo({
            key: key,
            zeroForOne: false,
            amountSpecified: -int256(1e30),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(_offGrid(newLo + (newHi - newLo) / 2))
        });
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        vm.prank(randomCaller);
        hook.addLiquidity(pid, NATIVE);

        askId = hook.askTokenIdOf(pid, NATIVE);
        bidId = hook.bidTokenIdOf(pid, NATIVE);
        assertTrue(askId != 0 && bidId != 0, "both positions are redeployed");
        (uint160 sqrtSpot,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        (int24 askLower, int24 askUpper) = _ticksOf(askId);
        (int24 bidLower, int24 bidUpper) = _ticksOf(bidId);
        assertGe(askLower, newLo, "ask never sells above the issuance ceiling's tick");
        assertLe(TickMath.getSqrtPriceAtTick(askUpper), sqrtSpot, "ask rests below the spot");
        assertGe(TickMath.getSqrtPriceAtTick(bidLower), sqrtSpot, "bid rests above the spot");
        assertLe(bidUpper, newHi, "bid never buys below the cash-out floor's tick");
        assertLt(hook.accumulatedProjectTokens(pid), 1e12, "project inventory redeployed");
        assertLt(hook.accumulatedTerminalTokens(pid, NATIVE), 1e9, "terminal inventory redeployed");
    }

    /// @notice A cash-out value 0.001% above the issuance price shares its tick, so only the exact prices show the
    /// inversion: the corridor is empty and a permissionless `deployPool` reverts before seeding the pool.
    function test_fork_deployPool_subTickInversion_reverts() public {
        // Issuance 1.25e-6 ETH per token (no reserve). 1 ETH paid plus 800 tokens minted to the hook leaves a
        // cash-out value of 1/800,800; a 0.00101 ETH donation lifts it to 1.00101/800,800, about 0.001% above 1.25e-6.
        // Both sit inside tick 135,930 (project tokens per ETH).
        uint256 pid = _launchProject({reservedPercent: 0, weight: 800_000e18});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "SubTick", "SUB", bytes32(0));
        _pay(pid, 1 ether);
        _accumulateTokens(pid, address(pToken), 800e18);
        _donate(pid, 0.001_01 ether);

        uint160 cashOutSqrtPrice = _cashOutSqrtPrice(pid, address(pToken));
        uint160 issuanceSqrtPrice = _issuanceSqrtPrice(pid, address(pToken));
        assertEq(
            TickMath.getTickAtSqrtPrice(cashOutSqrtPrice),
            TickMath.getTickAtSqrtPrice(issuanceSqrtPrice),
            "precondition: both prices round to one tick"
        );
        // ETH is currency0, so the pool price is project tokens per ETH: a higher cash-out value is a lower price.
        assertLt(cashOutSqrtPrice, issuanceSqrtPrice, "precondition: the cash-out value is above the issuance price");
        (int24 lo, int24 hi) = _corridorOf(pid, address(pToken));
        assertEq(lo, 0, "the corridor is empty: lower");
        assertEq(hi, 0, "the corridor is empty: upper");

        vm.expectRevert(
            abi.encodeWithSelector(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_EmptyCorridor.selector, pid, NATIVE)
        );
        vm.prank(randomCaller);
        hook.deployPool(pid);

        (uint160 spot,,,) = V4_POOL_MANAGER.getSlot0(_keyOf(address(pToken)).toId());
        assertEq(spot, 0, "the pool was not initialized");
        assertFalse(hook.isPoolDeployed(pid, NATIVE), "no pool was deployed");
        assertEq(hook.accumulatedProjectTokens(pid), 800e18, "the inventory stays ledgered");
    }

    /// @notice A buyer swaps exact `amount` ETH in for project tokens through the pool.
    function _buy(BuySwapHelper swapHelper, PoolKey memory key, uint256 amount) internal {
        vm.prank(buyer);
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap{value: amount}({key: key, zeroForOne: true, amountSpecified: -int256(amount)});
    }

    function _donate(uint256 pid, uint256 amount) internal {
        jbMultiTerminal.addToBalanceOf{value: amount}({
            projectId: pid, token: NATIVE, amount: amount, shouldReturnHeldFees: false, memo: "", metadata: ""
        });
    }

    /// @notice The raw (unaligned) cash-out price as a sqrt price, from the hook's own linked math.
    function _cashOutSqrtPrice(uint256 pid, address pToken) internal view returns (uint160) {
        (JBRuleset memory ruleset,) = jbController.currentRulesetOf(pid);
        return JBUniswapV4LPSplitHookMath.getCashOutRateSqrtPriceX96({
            directory: jbDirectory,
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: pid,
            terminalToken: NATIVE,
            projectToken: pToken,
            controller: address(jbController),
            ruleset: ruleset
        });
    }

    /// @notice The raw (unaligned) issuance price as a sqrt price, from the hook's own linked math.
    function _issuanceSqrtPrice(uint256 pid, address pToken) internal view returns (uint160) {
        (JBRuleset memory ruleset,) = jbController.currentRulesetOf(pid);
        return JBUniswapV4LPSplitHookMath.getIssuanceRateSqrtPriceX96({
            directory: jbDirectory,
            projectId: pid,
            terminalToken: NATIVE,
            projectToken: pToken,
            controller: address(jbController),
            ruleset: ruleset
        });
    }
}
