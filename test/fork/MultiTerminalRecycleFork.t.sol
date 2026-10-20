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
    /// @notice The project's payout limit in native ETH, all of it routed to the hook as a payout split.
    uint224 constant _PAYOUT_LIMIT = 1 ether;

    /// @notice The gas the hook's capped inline automation attempt receives, mirroring the hook's attempt budget.
    uint256 constant _AUTOMATION_GAS_BUDGET = 2_000_000;

    /// @notice An account that pays before the project has an ERC-20, so it holds credits it later sends to the hook.
    address donor = address(0xD0D0);

    /// @notice A trader that buys from and sells into the pool.
    address buyer = address(0xB0B);

    /// @notice A payout split arriving with ample gas runs a full recycle inside the attempt budget.
    function test_fork_inlineRecycle_fourTerminals_fitsAttemptBudget() public {
        // Four terminals: the primary plus three with surplus.
        _assertInlineRecycleFits(4);
    }

    /// @notice The same recycle across eight terminals (~1.49M cold) also finishes inline.
    function test_fork_inlineRecycle_eightTerminals_fitsAttemptBudget() public {
        // Eight terminals: the primary plus seven with surplus.
        _assertInlineRecycleFits(8);
    }

    /// @notice Build a live two-position pool with fees on both positions and donated credits, then prove a payout
    /// through real Core runs the full recycle inline within the attempt budget, and measure the attempt alone.
    /// @param terminalCount The number of native-ETH terminals the project uses, each holding surplus.
    function _assertInlineRecycleFits(uint256 terminalCount) internal {
        // Launch the project across `terminalCount` terminals with the payout split routed to the hook.
        (uint256 pid, IJBTerminal[] memory terminals) = _launch(terminalCount);
        assertEq(jbDirectory.terminalsOf(pid).length, terminalCount, "every terminal registered");

        // The donor pays before the project has an ERC-20, so it holds credits.
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        jbMultiTerminal.pay{value: 1 ether}({
            projectId: pid,
            token: _NATIVE,
            amount: 1 ether,
            beneficiary: donor,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Deploy the ERC-20 and pay the primary terminal so the project has surplus there.
        vm.prank(multisig);
        IJBToken pToken =
            jbController.deployERC20For({projectId: pid, name: "Revnet Token", symbol: "RVNT", salt: bytes32(0)});
        _pay({pid: pid, amount: 10 ether});

        // Every other terminal holds surplus, so the surplus read has real work at each.
        for (uint256 i = 1; i < terminalCount; i++) {
            terminals[i].pay{value: 1 ether}({
                projectId: pid,
                token: _NATIVE,
                amount: 1 ether,
                beneficiary: multisig,
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            });
        }

        // Ledger an inventory of project tokens in the hook.
        _accumulateTokens({pid: pid, pToken: address(pToken), amount: 5_000_000e18});

        // Initialize the pool off-grid mid-corridor, then deploy the first ask at a TWAP equal to the spot.
        PoolKey memory key = _keyOf(address(pToken));
        {
            (int24 lo, int24 hi) = _corridorOf({pid: pid, pToken: address(pToken)});
            _V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(_offGrid(lo + (hi - lo) / 2)));
        }
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: _V4_POOL_MANAGER, key: key});
        hook.deployPool(pid);

        // Open a bid, then trade through both positions so they earn fees on both sides.
        BuySwapHelper swapHelper = new BuySwapHelper(_V4_POOL_MANAGER);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        swapHelper.swap{value: 2 ether}({key: key, zeroForOne: true, amountSpecified: -int256(2 ether)});

        // The buyer's ETH funds a bid, so the recycle opens one beside the ask.
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: _V4_POOL_MANAGER, key: key});
        hook.addLiquidity({projectId: pid, terminalToken: _NATIVE});
        uint256 askBefore = hook.askTokenIdOf({projectId: pid, terminalToken: _NATIVE});
        uint256 bidBefore = hook.bidTokenIdOf({projectId: pid, terminalToken: _NATIVE});
        assertTrue(askBefore != 0 && bidBefore != 0, "a live ask and bid");

        // A buy fills the ask and a sell of half the buyer's tokens fills the bid, so both earn fees.
        vm.prank(buyer);
        swapHelper.swap{value: 0.2 ether}({key: key, zeroForOne: true, amountSpecified: -int256(0.2 ether)});
        uint256 sellAmount = IERC20(address(pToken)).balanceOf(buyer) / 2;
        vm.startPrank(buyer);
        IERC20(address(pToken)).approve(address(swapHelper), sellAmount);
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap({key: key, zeroForOne: false, amountSpecified: -int256(sellAmount)});
        vm.stopPrank();
        {
            // Both fee sides carry something for the recycle to collect and route.
            (uint256 askEth, uint256 askProject) = _feesOf({tokenId: askBefore, key: key});
            (uint256 bidEth, uint256 bidProject) = _feesOf({tokenId: bidBefore, key: key});
            assertGt(askEth + bidEth, 0, "terminal-token fees accrued");
            assertGt(askProject + bidProject, 0, "project-token fees accrued");
        }

        // A third party sends credits, so the recycle normalizes them.
        uint256 donated = jbTokens.creditBalanceOf({holder: donor, projectId: pid});
        assertGt(donated, 0, "the donor holds credits");
        vm.prank(donor);
        jbController.transferCreditsFrom({
            holder: donor, projectId: pid, recipient: address(hook), creditCount: donated
        });

        // Fix the TWAP at the spot, record the fee-claim baseline and snapshot for the cold-attempt measurement.
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: _V4_POOL_MANAGER, key: key});
        uint256 claimsBefore = hook.claimableFeeTokens(pid);
        uint256 snapshot = vm.snapshotState();

        // The payout reaches the hook through real Core, and the attempt is a self-call capped at the budget.
        vm.expectCall({
            callee: address(hook),
            msgValue: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            gas: uint64(_AUTOMATION_GAS_BUDGET),
            data: abi.encodeCall(JBUniswapV4LPSplitHook.executeAutomationFor, (pid))
        });
        vm.recordLogs();

        // Distribute the full payout limit, which reaches the hook as a split.
        jbMultiTerminal.sendPayoutsOf({
            projectId: pid,
            token: _NATIVE,
            amount: _PAYOUT_LIMIT,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(_NATIVE)),
            minTokensPaidOut: 0
        });
        emit log_named_uint("  sendPayoutsOf with the inline recycle, whole tx (gas)", vm.lastCallGas().gasTotalUsed);

        // The hook emitted no automation-failure event, and the positions were recycled.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(
                logs[i].emitter != address(hook)
                    || logs[i].topics[0] != IJBUniswapV4LPSplitHook.LiquidityAutomationFailed.selector,
                "the automation did not fail"
            );
        }
        _assertRecycled({pid: pid, askBefore: askBefore, bidBefore: bidBefore, claimsBefore: claimsBefore});

        // The attempt alone, from cold storage: the same payout taken intake-only, then the attempt's body called as
        // the hook calls it. A top-level call also pays the 21k transaction base, so this overstates the attempt.
        vm.revertToState(snapshot);

        // The split receives the payout net of the 2.5% protocol fee; fund the terminal and deliver it intake-only.
        uint256 net = _PAYOUT_LIMIT - _PAYOUT_LIMIT * 25 / 1000;
        vm.deal(address(jbMultiTerminal), address(jbMultiTerminal).balance + net);
        vm.prank(address(jbMultiTerminal));
        hook.processSplitWith{value: net, gas: INTAKE_ONLY_GAS}(_payoutContext({pid: pid, amount: net}));
        assertEq(hook.askTokenIdOf({projectId: pid, terminalToken: _NATIVE}), askBefore, "intake only: no recycle yet");

        // Run the attempt's body as the hook's self-call and measure its gas.
        vm.prank(address(hook));
        hook.executeAutomationFor(pid);
        uint256 attemptGas = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("  terminals", terminalCount);
        emit log_named_uint("  full recycle attempt, cold (gas)", attemptGas);

        // The attempt fits the budget and leaves the same recycled state.
        assertLt(attemptGas, _AUTOMATION_GAS_BUDGET, "the attempt fits its budget");
        _assertRecycled({pid: pid, askBefore: askBefore, bidBefore: bidBefore, claimsBefore: claimsBefore});
    }

    /// @notice Launch a native-ETH project on `terminalCount` terminals whose full payout limit on the primary
    /// terminal is split to the hook.
    /// @param terminalCount The number of terminals: the shared primary plus freshly deployed extras.
    /// @return pid The ID of the launched project.
    /// @return terminals The project's terminals, the primary first.
    function _launch(uint256 terminalCount) internal returns (uint256 pid, IJBTerminal[] memory terminals) {
        // The shared multi-terminal is primary; each extra terminal is a fresh deployment wired to the same core.
        terminals = new IJBTerminal[](terminalCount);
        terminals[0] = jbMultiTerminal;
        for (uint256 i = 1; i < terminalCount; i++) {
            terminals[i] = new JBMultiTerminal({
                feelessAddresses: jbFeelessAddresses,
                permissions: jbPermissions,
                projects: jbProjects,
                splits: jbSplits,
                store: jbTerminalStore,
                tokens: jbTokens,
                permit2: IPermit2(address(PERMIT2)),
                trustedForwarder: trustedForwarder
            });
        }

        // One split sends 100% of the native-ETH payout group to the hook.
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
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(_NATIVE)), splits: splits});

        // The payout limit applies on the primary terminal only.
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        payoutLimits[0] = JBCurrencyAmount({amount: _PAYOUT_LIMIT, currency: uint32(uint160(_NATIVE))});
        JBFundAccessLimitGroup[] memory limits = new JBFundAccessLimitGroup[](1);
        limits[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal),
            token: _NATIVE,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        // Launch with a 50% reserved percent at 1M tokens per ETH across every terminal.
        pid = _launchProjectOn({
            reservedPercent: 5000,
            weight: 1_000_000e18,
            splitGroups: splitGroups,
            fundAccessLimitGroups: limits,
            terminals: terminals
        });
    }

    /// @notice Assert a full recycle happened: both positions were replaced, donated credits were claimed and fee cuts
    /// reached the fee project.
    /// @param pid The ID of the project.
    /// @param askBefore The ask position's token ID before the recycle.
    /// @param bidBefore The bid position's token ID before the recycle.
    /// @param claimsBefore The project's claimable fee tokens before the recycle.
    function _assertRecycled(uint256 pid, uint256 askBefore, uint256 bidBefore, uint256 claimsBefore) internal view {
        // Fresh ask and bid positions replaced the old ones.
        uint256 ask = hook.askTokenIdOf({projectId: pid, terminalToken: _NATIVE});
        uint256 bid = hook.bidTokenIdOf({projectId: pid, terminalToken: _NATIVE});
        assertTrue(ask != 0 && ask != askBefore, "the ask was replaced");
        assertTrue(bid != 0 && bid != bidBefore, "the bid was replaced");

        // The hook's credits were claimed as ERC-20 and its fee cuts were routed.
        assertEq(jbTokens.creditBalanceOf({holder: address(hook), projectId: pid}), 0, "credits normalized");
        assertGt(hook.claimableFeeTokens(pid), claimsBefore, "fee cuts were routed to the fee project");
    }

    /// @notice The split-hook context the terminal hands the hook for a native-ETH payout split.
    /// @param pid The ID of the project paying out.
    /// @param amount The ETH amount the split receives.
    /// @return context The context for `processSplitWith`.
    function _payoutContext(uint256 pid, uint256 amount) internal view returns (JBSplitHookContext memory context) {
        // A 100% split in the native-ETH payout group, pointing at the hook.
        return JBSplitHookContext({
            token: _NATIVE,
            amount: amount,
            decimals: 18,
            projectId: pid,
            groupId: uint256(uint160(_NATIVE)),
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
