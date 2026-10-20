// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BuySwapHelper} from "./Integration_SingleSidedRevnet.t.sol";
import {TwoPositionForkBase} from "./TwoPositionForkBase.sol";

/// @notice Real Core burns a holder's credits before its ERC-20. A third party who sends the hook project credits must
/// not be able to divert the burn of collected project-token LP fees: the hook claims the credits into its ask ledger
/// first, then burns exactly the fees. Also measures a full inline-sized recycle that includes the credit claim.
contract FeeCreditDonationFork is TwoPositionForkBase {
    address donor = address(0xD0D0);
    address buyer = address(0xB0B);

    function test_fork_donatedCredits_claimedAndLedgered_feesStillBurned() public {
        uint256 pid = _launchProject({reservedPercent: 5000, weight: 1_000_000e18});
        // The donor pays before the project has an ERC-20, so it holds credits.
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        jbMultiTerminal.pay{value: 1 ether}({
            projectId: pid,
            token: NATIVE,
            amount: 1 ether,
            beneficiary: donor,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        uint256 donated = jbTokens.creditBalanceOf(donor, pid);
        assertGt(donated, 0, "the donor holds credits");
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Revnet Token", "RVNT", bytes32(0));
        _pay(pid, 10 ether);
        _accumulateTokens(pid, address(pToken), 5_000_000e18);

        PoolKey memory key = _keyOf(address(pToken));
        {
            (int24 lo, int24 hi) = _corridorOf(pid, address(pToken));
            V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(_offGrid(lo + (hi - lo) / 2)));
        }
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        hook.deployPool(pid);
        uint256 askId = hook.askTokenIdOf(pid, NATIVE);

        // Trade through the ask both ways so it earns project-token fees.
        BuySwapHelper swapHelper = new BuySwapHelper(V4_POOL_MANAGER);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap{value: 1 ether}({key: key, zeroForOne: true, amountSpecified: -int256(1 ether)});
        uint256 sellAmount = IERC20(address(pToken)).balanceOf(buyer) / 2;
        vm.startPrank(buyer);
        IERC20(address(pToken)).approve(address(swapHelper), sellAmount);
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap({key: key, zeroForOne: false, amountSpecified: -int256(sellAmount)});
        vm.stopPrank();
        (, uint256 projectFee) = _feesOf(askId, key);
        assertGt(projectFee, 0, "the ask earned project-token fees");

        // A third party sends its credits to the hook.
        vm.prank(donor);
        jbController.transferCreditsFrom({
            holder: donor, projectId: pid, recipient: address(hook), creditCount: donated
        });
        assertEq(jbTokens.creditBalanceOf(address(hook), pid), donated, "the hook holds the donated credits");

        uint256 supplyBefore = IERC20(address(pToken)).totalSupply();
        uint256 ledgerBefore = hook.accumulatedProjectTokens(pid);
        uint256 heldBefore = IERC20(address(pToken)).balanceOf(address(hook));

        hook.collectAndRouteLPFees(pid, NATIVE);

        assertEq(jbTokens.creditBalanceOf(address(hook), pid), 0, "the donated credits were claimed");
        assertEq(hook.accumulatedProjectTokens(pid), ledgerBefore + donated, "and ledgered as ask inventory");
        assertEq(
            IERC20(address(pToken)).balanceOf(address(hook)), heldBefore + donated, "held as ERC-20, fees all burned"
        );
        assertEq(
            IERC20(address(pToken)).totalSupply(),
            supplyBefore + donated - projectFee,
            "the claim minted the credits and the burn took exactly the fees"
        );
    }

    /// @notice Gas of a full recycle with both positions earning fees on both sides, fee routing (cut, add, burn) and a
    /// credit claim, as inline automation would run it.
    function test_fork_fullRecycleWithCreditClaim_gas() public {
        uint256 pid = _launchProject({reservedPercent: 5000, weight: 1_000_000e18});
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        jbMultiTerminal.pay{value: 1 ether}({
            projectId: pid,
            token: NATIVE,
            amount: 1 ether,
            beneficiary: donor,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Revnet Token", "RVNT", bytes32(0));
        _pay(pid, 10 ether);
        _accumulateTokens(pid, address(pToken), 5_000_000e18);
        PoolKey memory key = _keyOf(address(pToken));
        {
            (int24 lo, int24 hi) = _corridorOf(pid, address(pToken));
            V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(_offGrid(lo + (hi - lo) / 2)));
        }
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        hook.deployPool(pid);

        // Open a bid, then trade through both positions so each earns fees on both sides.
        BuySwapHelper swapHelper = new BuySwapHelper(V4_POOL_MANAGER);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap{value: 2 ether}({key: key, zeroForOne: true, amountSpecified: -int256(2 ether)});
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        hook.addLiquidity(pid, NATIVE);
        assertTrue(hook.bidTokenIdOf(pid, NATIVE) != 0, "a live bid");
        vm.prank(buyer);
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap{value: 0.2 ether}({key: key, zeroForOne: true, amountSpecified: -int256(0.2 ether)});
        uint256 sellAmount = IERC20(address(pToken)).balanceOf(buyer) / 2;
        vm.startPrank(buyer);
        IERC20(address(pToken)).approve(address(swapHelper), sellAmount);
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap({key: key, zeroForOne: false, amountSpecified: -int256(sellAmount)});
        vm.stopPrank();
        uint256 donated = jbTokens.creditBalanceOf(donor, pid);
        vm.prank(donor);
        jbController.transferCreditsFrom({
            holder: donor, projectId: pid, recipient: address(hook), creditCount: donated
        });

        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        uint256 gasBefore = gasleft();
        hook.addLiquidity(pid, NATIVE);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("  full recycle with fee routing and credit claim (gas)", used);
        assertTrue(hook.askTokenIdOf(pid, NATIVE) != 0 && hook.bidTokenIdOf(pid, NATIVE) != 0, "both re-minted");
        assertEq(jbTokens.creditBalanceOf(address(hook), pid), 0, "credits claimed");
    }
}
