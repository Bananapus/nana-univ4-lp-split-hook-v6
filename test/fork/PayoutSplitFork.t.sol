// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IJBUniswapV4LPSplitHook} from "../../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {TwoPositionForkBase} from "./TwoPositionForkBase.sol";

/// @notice The hook as a native-ETH PAYOUT split through real Core (`JBMultiTerminal.sendPayoutsOf`) and the real
/// mainnet PositionManager: before the pool is deployed the payout is refused and Core returns all of it to the
/// project's balance; after, the net payout lands in the hook and is minted into the bid in the same call.
contract PayoutSplitFork is TwoPositionForkBase {
    uint224 constant PAYOUT_LIMIT = 1 ether;

    function _launchWithPayoutSplit() internal returns (uint256 pid, IJBToken pToken) {
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(address(0)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(hook))
        });
        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(NATIVE)), splits: splits});
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        payoutLimits[0] = JBCurrencyAmount({amount: PAYOUT_LIMIT, currency: uint32(uint160(NATIVE))});
        JBFundAccessLimitGroup[] memory limits = new JBFundAccessLimitGroup[](1);
        limits[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal),
            token: NATIVE,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        pid = _launchProjectWith({
            reservedPercent: 5000, weight: 1_000_000e18, splitGroups: splitGroups, fundAccessLimitGroups: limits
        });
        vm.prank(multisig);
        pToken = jbController.deployERC20For(pid, "Payout Token", "PAY", bytes32(0));
        _pay(pid, 10 ether);
        _accumulateTokens(pid, address(pToken), 5_000_000e18);
    }

    function _sendPayouts(uint256 pid) internal {
        jbMultiTerminal.sendPayoutsOf({
            projectId: pid,
            token: NATIVE,
            amount: PAYOUT_LIMIT,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(NATIVE)),
            minTokensPaidOut: 0
        });
    }

    /// @notice Before deployment there is no bid to fund: the hook refuses and Core keeps all of it in the project.
    function test_fork_payoutBeforeDeploy_refundedToProject() public {
        (uint256 pid,) = _launchWithPayoutSplit();
        uint256 balanceBefore = jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, NATIVE);
        uint256 terminalEthBefore = address(jbMultiTerminal).balance;

        _sendPayouts(pid);

        assertEq(
            jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, NATIVE),
            balanceBefore,
            "the whole payout is back in the project's balance"
        );
        assertEq(address(jbMultiTerminal).balance, terminalEthBefore, "no ETH left the terminal");
        assertEq(address(hook).balance, 0, "the hook holds nothing");
        assertEq(hook.accumulatedTerminalTokens(pid, NATIVE), 0, "no bid ledger");
    }

    /// @notice After deployment the net payout (the payout less Core's 2.5% fee) is accepted and minted into the bid.
    function test_fork_payoutAfterDeploy_fundsTheBid() public {
        (uint256 pid, IJBToken pToken) = _launchWithPayoutSplit();
        PoolKey memory key = _keyOf(address(pToken));
        {
            (int24 lo, int24 hi) = _corridorOf(pid, address(pToken));
            V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(_offGrid(lo + (hi - lo) / 2)));
        }
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        hook.deployPool(pid);
        assertEq(hook.bidTokenIdOf(pid, NATIVE), 0, "no bid before any terminal tokens");
        uint256 askBefore = hook.askTokenIdOf(pid, NATIVE);
        uint256 balanceBefore = jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, NATIVE);
        uint256 net = PAYOUT_LIMIT - PAYOUT_LIMIT * 25 / 1000;

        vm.expectEmit(address(hook));
        emit IJBUniswapV4LPSplitHook.PayoutAccepted({
            projectId: pid, terminalToken: NATIVE, amount: net, caller: address(jbMultiTerminal)
        });
        _sendPayouts(pid);

        assertEq(
            balanceBefore - jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, NATIVE),
            PAYOUT_LIMIT,
            "the payout left the project's balance"
        );
        uint256 bidId = hook.bidTokenIdOf(pid, NATIVE);
        assertTrue(bidId != 0, "the payout was minted into a bid");
        assertTrue(hook.askTokenIdOf(pid, NATIVE) != askBefore, "the recycle re-minted the ask");
        uint256 ledger = hook.accumulatedTerminalTokens(pid, NATIVE);
        assertEq(address(hook).balance, ledger, "the hook holds exactly its terminal ledger");
        (uint256 bidEth,) = _principalOf(bidId, key);
        assertLe(bidEth + ledger, net, "the bid and the ledger hold no more than the payout");
        assertGe(bidEth + ledger + 2, net, "and at most V4's rounding less");
    }
}
