// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {IJBUniswapV4LPSplitHook} from "../../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {BuySwapHelper} from "./Integration_SingleSidedRevnet.t.sol";
import {TwoPositionForkBase} from "./TwoPositionForkBase.sol";

/// @notice The heaviest inline automation through real Core and the real mainnet PositionManager: a payout reaches the
/// hook clone through `sendPayoutsOf`, and the capped attempt runs a full two-position recycle (fee collection and
/// routing on both positions, a credit claim, surplus read across every terminal, two burns and two mints). Every
/// top-level call runs as its own transaction, so storage starts cold as it would on chain.
/// forge-config: default.isolate = true
contract MultiTerminalRecycleFork is TwoPositionForkBase {
    uint224 constant PAYOUT_LIMIT = 1 ether;
    uint256 constant AUTOMATION_GAS_BUDGET = 2_000_000;

    address donor = address(0xD0D0);
    address buyer = address(0xB0B);

    function _launch(uint256 terminalCount) internal returns (uint256 pid, IJBTerminal[] memory terminals) {
        terminals = new IJBTerminal[](terminalCount);
        terminals[0] = jbMultiTerminal;
        for (uint256 i = 1; i < terminalCount; i++) {
            terminals[i] = new JBMultiTerminal(
                jbFeelessAddresses,
                jbPermissions,
                jbProjects,
                jbSplits,
                jbTerminalStore,
                jbTokens,
                IPermit2(address(PERMIT2)),
                trustedForwarder
            );
        }
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
        pid = _launchProjectOn({
            reservedPercent: 5000,
            weight: 1_000_000e18,
            splitGroups: splitGroups,
            fundAccessLimitGroups: limits,
            terminals: terminals
        });
    }

    /// @notice A payout split arriving with ample gas runs a full recycle inside the attempt budget.
    function test_fork_inlineRecycle_fourTerminals_fitsAttemptBudget() public {
        _assertInlineRecycleFits(4);
    }

    /// @notice The same recycle across eight terminals (~1.49M cold) also finishes inline.
    function test_fork_inlineRecycle_eightTerminals_fitsAttemptBudget() public {
        _assertInlineRecycleFits(8);
    }

    function _assertInlineRecycleFits(uint256 terminalCount) internal {
        (uint256 pid, IJBTerminal[] memory terminals) = _launch(terminalCount);
        assertEq(jbDirectory.terminalsOf(pid).length, terminalCount, "every terminal registered");

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
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Revnet Token", "RVNT", bytes32(0));
        _pay(pid, 10 ether);
        // Every other terminal holds surplus, so the surplus read has real work at each.
        for (uint256 i = 1; i < terminalCount; i++) {
            terminals[i].pay{value: 1 ether}({
                projectId: pid,
                token: NATIVE,
                amount: 1 ether,
                beneficiary: multisig,
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            });
        }
        _accumulateTokens(pid, address(pToken), 5_000_000e18);

        PoolKey memory key = _keyOf(address(pToken));
        {
            (int24 lo, int24 hi) = _corridorOf(pid, address(pToken));
            V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(_offGrid(lo + (hi - lo) / 2)));
        }
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        hook.deployPool(pid);

        // Open a bid, then trade through both positions so they earn fees on both sides.
        BuySwapHelper swapHelper = new BuySwapHelper(V4_POOL_MANAGER);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        swapHelper.swap{value: 2 ether}({key: key, zeroForOne: true, amountSpecified: -int256(2 ether)});
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        hook.addLiquidity(pid, NATIVE);
        uint256 askBefore = hook.askTokenIdOf(pid, NATIVE);
        uint256 bidBefore = hook.bidTokenIdOf(pid, NATIVE);
        assertTrue(askBefore != 0 && bidBefore != 0, "a live ask and bid");
        vm.prank(buyer);
        swapHelper.swap{value: 0.2 ether}({key: key, zeroForOne: true, amountSpecified: -int256(0.2 ether)});
        uint256 sellAmount = IERC20(address(pToken)).balanceOf(buyer) / 2;
        vm.startPrank(buyer);
        IERC20(address(pToken)).approve(address(swapHelper), sellAmount);
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap({key: key, zeroForOne: false, amountSpecified: -int256(sellAmount)});
        vm.stopPrank();
        {
            (uint256 askEth, uint256 askProject) = _feesOf(askBefore, key);
            (uint256 bidEth, uint256 bidProject) = _feesOf(bidBefore, key);
            assertGt(askEth + bidEth, 0, "terminal-token fees accrued");
            assertGt(askProject + bidProject, 0, "project-token fees accrued");
        }

        // A third party sends credits, so the recycle normalizes them.
        uint256 donated = jbTokens.creditBalanceOf(donor, pid);
        assertGt(donated, 0, "the donor holds credits");
        vm.prank(donor);
        jbController.transferCreditsFrom({
            holder: donor, projectId: pid, recipient: address(hook), creditCount: donated
        });
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        uint256 claimsBefore = hook.claimableFeeTokens(pid);
        uint256 snapshot = vm.snapshotState();

        // The payout reaches the hook through real Core, and the attempt is a self-call capped at the budget.
        vm.expectCall({
            callee: address(hook),
            msgValue: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            gas: uint64(AUTOMATION_GAS_BUDGET),
            data: abi.encodeCall(JBUniswapV4LPSplitHook.executeAutomationFor, (pid))
        });
        vm.recordLogs();
        jbMultiTerminal.sendPayoutsOf({
            projectId: pid,
            token: NATIVE,
            amount: PAYOUT_LIMIT,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(NATIVE)),
            minTokensPaidOut: 0
        });
        emit log_named_uint("  sendPayoutsOf with the inline recycle, whole tx (gas)", vm.lastCallGas().gasTotalUsed);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(
                logs[i].emitter != address(hook)
                    || logs[i].topics[0] != IJBUniswapV4LPSplitHook.LiquidityAutomationFailed.selector,
                "the automation did not fail"
            );
        }
        _assertRecycled(pid, askBefore, bidBefore, claimsBefore);

        // The attempt alone, from cold storage: the same payout taken intake-only, then the attempt's body called as
        // the hook calls it. A top-level call also pays the 21k transaction base, so this overstates the attempt.
        vm.revertToState(snapshot);
        uint256 net = PAYOUT_LIMIT - PAYOUT_LIMIT * 25 / 1000;
        vm.deal(address(jbMultiTerminal), address(jbMultiTerminal).balance + net);
        vm.prank(address(jbMultiTerminal));
        hook.processSplitWith{value: net, gas: INTAKE_ONLY_GAS}(_payoutContext({pid: pid, amount: net}));
        assertEq(hook.askTokenIdOf(pid, NATIVE), askBefore, "intake only: no recycle yet");
        vm.prank(address(hook));
        hook.executeAutomationFor(pid);
        uint256 attemptGas = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("  terminals", terminalCount);
        emit log_named_uint("  full recycle attempt, cold (gas)", attemptGas);
        assertLt(attemptGas, AUTOMATION_GAS_BUDGET, "the attempt fits its budget");
        _assertRecycled(pid, askBefore, bidBefore, claimsBefore);
    }

    function _assertRecycled(uint256 pid, uint256 askBefore, uint256 bidBefore, uint256 claimsBefore) internal view {
        uint256 ask = hook.askTokenIdOf(pid, NATIVE);
        uint256 bid = hook.bidTokenIdOf(pid, NATIVE);
        assertTrue(ask != 0 && ask != askBefore, "the ask was replaced");
        assertTrue(bid != 0 && bid != bidBefore, "the bid was replaced");
        assertEq(jbTokens.creditBalanceOf(address(hook), pid), 0, "credits normalized");
        assertGt(hook.claimableFeeTokens(pid), claimsBefore, "fee cuts were routed to the fee project");
    }

    function _payoutContext(uint256 pid, uint256 amount) internal view returns (JBSplitHookContext memory) {
        return JBSplitHookContext({
            token: NATIVE,
            amount: amount,
            decimals: 18,
            projectId: pid,
            groupId: uint256(uint160(NATIVE)),
            split: JBSplit({
                percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(hook))
            })
        });
    }
}
