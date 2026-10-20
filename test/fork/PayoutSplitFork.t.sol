// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized)
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// Local: interfaces
import {IJBUniswapV4LPSplitHook} from "../../src/interfaces/IJBUniswapV4LPSplitHook.sol";

// Local: test helpers
import {TwoPositionForkBase} from "./TwoPositionForkBase.sol";

/// @notice The hook as a native-ETH PAYOUT split through real Core (`JBMultiTerminal.sendPayoutsOf`) and the real
/// mainnet PositionManager: before the pool is deployed the payout is refused and Core returns all of it to the
/// project's balance; after, the net payout lands in the hook and is minted into the bid in the same call.
contract PayoutSplitFork is TwoPositionForkBase {
    /// @notice The project's native-ETH payout limit, all of it split to the hook.
    uint224 internal constant _PAYOUT_LIMIT = 1 ether;

    /// @notice Before deployment there is no bid to fund: the hook refuses and Core keeps all of it in the project.
    function test_fork_payoutBeforeDeploy_refundedToProject() public {
        (uint256 pid,) = _launchWithPayoutSplit();

        // Snapshot the project's recorded balance and the terminal's actual ETH.
        uint256 balanceBefore =
            jbTerminalStore.balanceOf({terminal: address(jbMultiTerminal), projectId: pid, token: _NATIVE});
        uint256 terminalEthBefore = address(jbMultiTerminal).balance;

        // The hook has no pool yet, so it refuses the payout.
        _sendPayouts(pid);

        // Core returned the refused payout to the project, and the hook took nothing.
        assertEq(
            jbTerminalStore.balanceOf({terminal: address(jbMultiTerminal), projectId: pid, token: _NATIVE}),
            balanceBefore,
            "the whole payout is back in the project's balance"
        );
        assertEq(address(jbMultiTerminal).balance, terminalEthBefore, "no ETH left the terminal");
        assertEq(address(hook).balance, 0, "the hook holds nothing");
        assertEq(hook.accumulatedTerminalTokens({projectId: pid, terminalToken: _NATIVE}), 0, "no bid ledger");
    }

    /// @notice After deployment the net payout (the payout less Core's 2.5% fee) is accepted and minted into the bid.
    function test_fork_payoutAfterDeploy_fundsTheBid() public {
        (uint256 pid, IJBToken pToken) = _launchWithPayoutSplit();

        // Initialize the pool off-grid at the corridor's midpoint, then deploy the hook's positions there.
        PoolKey memory key = _keyOf(address(pToken));
        {
            (int24 lo, int24 hi) = _corridorOf({pid: pid, pToken: address(pToken)});
            _V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(_offGrid(lo + (hi - lo) / 2)));
        }
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: _V4_POOL_MANAGER, key: key});
        hook.deployPool(pid);
        assertEq(hook.bidTokenIdOf({projectId: pid, terminalToken: _NATIVE}), 0, "no bid before any terminal tokens");

        // Snapshot the ask and the project's balance, and compute the payout net of Core's 2.5% fee.
        uint256 askBefore = hook.askTokenIdOf({projectId: pid, terminalToken: _NATIVE});
        uint256 balanceBefore =
            jbTerminalStore.balanceOf({terminal: address(jbMultiTerminal), projectId: pid, token: _NATIVE});
        uint256 net = _PAYOUT_LIMIT - _PAYOUT_LIMIT * 25 / 1000;

        // The hook accepts exactly the net payout from the terminal.
        vm.expectEmit(address(hook));
        emit IJBUniswapV4LPSplitHook.PayoutAccepted({
            projectId: pid, terminalToken: _NATIVE, amount: net, caller: address(jbMultiTerminal)
        });
        _sendPayouts(pid);

        // The full payout left the project, and the same call recycled the ask and minted a bid.
        assertEq(
            balanceBefore
                - jbTerminalStore.balanceOf({terminal: address(jbMultiTerminal), projectId: pid, token: _NATIVE}),
            _PAYOUT_LIMIT,
            "the payout left the project's balance"
        );
        uint256 bidId = hook.bidTokenIdOf({projectId: pid, terminalToken: _NATIVE});
        assertTrue(bidId != 0, "the payout was minted into a bid");
        assertTrue(
            hook.askTokenIdOf({projectId: pid, terminalToken: _NATIVE}) != askBefore, "the recycle re-minted the ask"
        );

        // The bid's ETH plus the leftover ledger account for the net payout, within V4's rounding.
        uint256 ledger = hook.accumulatedTerminalTokens({projectId: pid, terminalToken: _NATIVE});
        assertEq(address(hook).balance, ledger, "the hook holds exactly its terminal ledger");
        (uint256 bidEth,) = _principalOf({tokenId: bidId, key: key});
        assertLe(bidEth + ledger, net, "the bid and the ledger hold no more than the payout");
        assertGe(bidEth + ledger + 2, net, "and at most V4's rounding less");
    }

    /// @notice Launches a project whose whole native-ETH payout limit splits to the hook, with surplus and ask
    /// inventory.
    /// @return pid The new project's ID.
    /// @return pToken The project's ERC-20.
    function _launchWithPayoutSplit() internal returns (uint256 pid, IJBToken pToken) {
        // One split sends 100% of the payouts to the hook.
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(address(0)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(hook))
        });

        // Payout split groups are keyed by the terminal token's address.
        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(_NATIVE)), splits: splits});

        // A native-ETH payout limit on the multi-terminal, with no surplus allowance.
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        // The native token's address truncated to 32 bits is its currency ID.
        // forge-lint: disable-next-line(unsafe-typecast)
        payoutLimits[0] = JBCurrencyAmount({amount: _PAYOUT_LIMIT, currency: uint32(uint160(_NATIVE))});
        JBFundAccessLimitGroup[] memory limits = new JBFundAccessLimitGroup[](1);
        limits[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal),
            token: _NATIVE,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        // Launch, deploy the ERC-20, fund the surplus and give the hook ask inventory.
        pid = _launchProjectWith({
            reservedPercent: 5000, weight: 1_000_000e18, splitGroups: splitGroups, fundAccessLimitGroups: limits
        });
        vm.prank(multisig);
        pToken = jbController.deployERC20For({projectId: pid, name: "Payout Token", symbol: "PAY", salt: bytes32(0)});
        _pay({pid: pid, amount: 10 ether});
        _accumulateTokens({pid: pid, pToken: address(pToken), amount: 5_000_000e18});
    }

    /// @notice Sends the project's full native-ETH payout limit through the multi-terminal.
    /// @param pid The project whose payouts to send.
    function _sendPayouts(uint256 pid) internal {
        // Anyone may send payouts, since the ruleset does not require the owner to.
        jbMultiTerminal.sendPayoutsOf({
            projectId: pid,
            token: _NATIVE,
            amount: _PAYOUT_LIMIT,
            // The native token's address truncated to 32 bits is its currency ID.
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(_NATIVE)),
            minTokensPaidOut: 0
        });
    }
}
