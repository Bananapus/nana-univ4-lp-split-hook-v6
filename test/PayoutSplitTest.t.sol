// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBSplits} from "@bananapus/core-v6/src/interfaces/IJBSplits.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBPayoutSplitGroupLib} from "@bananapus/core-v6/src/libraries/JBPayoutSplitGroupLib.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockJBMultiTerminal} from "./mock/MockJBContracts.sol";
import {SingleProjectHarness} from "./SingleProjectHarness.sol";

/// @notice The two terminal-store reads and writes Core's payout split path makes: the payout token's decimals, and
/// the refund of whatever the hook did not take back into the project's balance.
contract PayoutStoreStub {
    /// @notice The total amount refunded to each project's balance, per token.
    /// @custom:param projectId The ID of the project refunded.
    /// @custom:param token The token refunded.
    mapping(uint256 projectId => mapping(address token => uint256)) public refundedOf;

    /// @notice An 18-decimal accounting context for `token`, with its currency derived from its address.
    /// @param token The payout token.
    /// @return context The token's accounting context.
    function accountingContextOf(
        address,
        uint256,
        address token
    )
        external
        pure
        returns (JBAccountingContext memory context)
    {
        // The currency is the token's address truncated to 32 bits, as Core derives it.
        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    /// @notice Record a refund of `amount` of `token` to `projectId`'s balance.
    /// @param projectId The ID of the project refunded.
    /// @param token The token refunded.
    /// @param amount The amount refunded.
    function recordAddedBalanceFor(uint256 projectId, address token, uint256 amount) external {
        // Accumulate so a test can read the total refunded.
        refundedOf[projectId][token] += amount;
    }
}

/// @notice A terminal that sends payouts exactly the way `JBMultiTerminal` does: by delegatecalling Core's
/// `JBPayoutSplitGroupLib.invokeSplitHookWithPartial` (native ETH pushed as value, an ERC-20 offered as an allowance,
/// any unconsumed part refunded to the project's balance).
contract LibPayoutTerminal is MockJBMultiTerminal {
    /// @notice The store stub Core's payout path reads decimals from and records refunds in.
    PayoutStoreStub public immutable PAYOUT_STORE = new PayoutStoreStub();

    /// @notice Pay `amount` of `token` out to `split`'s hook through Core's partial-pull path.
    /// @param split The split to pay.
    /// @param projectId The ID of the project paying out.
    /// @param token The payout token.
    /// @param amount The payout amount.
    /// @return sent The amount the hook took.
    function sendPayout(
        JBSplit calldata split,
        uint256 projectId,
        address token,
        uint256 amount
    )
        external
        returns (uint256 sent)
    {
        // Core's library offers the payout and refunds whatever the hook does not take.
        (sent,) = JBPayoutSplitGroupLib.invokeSplitHookWithPartial({
            split: split,
            projectId: projectId,
            token: token,
            amount: amount,
            netPayoutAmount: amount,
            store: IJBTerminalStore(address(PAYOUT_STORE))
        });
    }
}

/// @notice A terminal that distributes a whole payout split group the way `JBMultiTerminal` does: Core's
/// `JBPayoutSplitGroupLib.sendPayoutsToSplitGroupOf` loop, calling back into `executePayout` per split. Hook splits go
/// through Core's partial-pull path; every other split is an ERC-20 transfer to its beneficiary.
contract PayoutLoopTerminal is LibPayoutTerminal {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The split group this terminal distributes.
    JBSplit[] internal _splits;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Distribute `amount` of `token` across the split group through Core's payout loop.
    /// @param projectId The ID of the project paying out.
    /// @param token The payout token.
    /// @param amount The total payout amount.
    /// @return leftover The amount no split took.
    function distribute(uint256 projectId, address token, uint256 amount) external returns (uint256 leftover) {
        // Core's loop reads the splits from this contract and calls `executePayout` back for each one.
        (leftover,) = JBPayoutSplitGroupLib.sendPayoutsToSplitGroupOf({
            splits: IJBSplits(address(this)),
            store: IJBTerminalStore(address(PAYOUT_STORE)),
            projectId: projectId,
            token: token,
            rulesetId: 0,
            amount: amount,
            caller: msg.sender
        });
    }

    /// @notice Pay one split: a hook split through Core's partial-pull path, any other split by direct transfer.
    /// @param split The split to pay.
    /// @param projectId The ID of the project paying out.
    /// @param token The payout token.
    /// @param amount The split's payout amount.
    /// @return netPayoutAmount The amount the split took.
    /// @return feeEligibleAmount The amount fees apply to (always 0 here).
    function executePayout(
        JBSplit calldata split,
        uint256 projectId,
        address token,
        uint256 amount,
        address
    )
        external
        returns (uint256 netPayoutAmount, uint256 feeEligibleAmount)
    {
        // Only Core's loop, running in this contract, may pay a split.
        require(msg.sender == address(this), "ONLY_SELF");

        if (address(split.hook) != address(0)) {
            // A hook split is offered the payout the way Core offers it.
            (netPayoutAmount,) = JBPayoutSplitGroupLib.invokeSplitHookWithPartial({
                split: split,
                projectId: projectId,
                token: token,
                amount: amount,
                netPayoutAmount: amount,
                store: IJBTerminalStore(address(PAYOUT_STORE))
            });
        } else {
            // Any other split receives the payout directly.
            require(MockERC20(token).transfer({to: split.beneficiary, amount: amount}), "TRANSFER_FAILED");
            netPayoutAmount = amount;
        }

        // No fees apply in this stand-in.
        feeEligibleAmount = 0;
    }

    /// @notice Replace the split group.
    /// @param splits The new split group.
    function setSplits(JBSplit[] memory splits) external {
        // Copy the memory array into storage one split at a time.
        delete _splits;
        for (uint256 i; i < splits.length; i++) {
            _splits.push(splits[i]);
        }
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The split group, for any project, ruleset and group.
    /// @return splits The split group.
    function splitsOf(uint256, uint256, uint256) external view returns (JBSplit[] memory splits) {
        return _splits;
    }
}

/// @notice The hook also works as a PAYOUT split: one of the project's terminals pays out native ETH or an ERC-20
/// terminal token to it, and the payout funds the bid. Payouts are only accepted for the deployed pool's terminal
/// token, from a terminal of the project, under the token's payout group, with exactly matching value; every rejection
/// makes Core refund the whole payout to the project's balance. Reserved tokens are accepted only from the controller.
contract PayoutSplitTest is SingleProjectHarness {
    /// @dev Mirrors the hook's `_AUTOMATION_GAS_BUDGET`.
    uint256 internal constant _AUTOMATION_GAS_BUDGET = 2_000_000;

    /// @notice The payout amount each test sends.
    uint256 internal constant _PAYOUT = 3e18;

    /// @notice The project terminal that pays out to the hook.
    LibPayoutTerminal internal _payer;

    // ─── Intake: the bid ledger grows by exactly the payout
    // ─────────────────────────────────────────────────────

    /// @notice A payout is ledgered exactly when the project is token0 against an ERC-20.
    function test_Payout_Intake_ProjectToken0() public {
        _runIntake({wantProjectToken0: true, useNative: false});
    }

    /// @notice A payout is ledgered exactly when the project is token1 against an ERC-20.
    function test_Payout_Intake_ProjectToken1() public {
        _runIntake({wantProjectToken0: false, useNative: false});
    }

    /// @notice A native ETH payout is ledgered exactly.
    function test_Payout_Intake_Native() public {
        _runIntake({wantProjectToken0: false, useNative: true});
    }

    // ─── Automation: with the gas for it, the payout is minted into the bid in the same call
    // ─────────────────────────────────────────────────────

    /// @notice With enough gas, a payout is minted into a bid when the project is token0 against an ERC-20.
    function test_Payout_RecyclesIntoBid_ProjectToken0() public {
        _runRecycle({wantProjectToken0: true, useNative: false});
    }

    /// @notice With enough gas, a payout is minted into a bid when the project is token1 against an ERC-20.
    function test_Payout_RecyclesIntoBid_ProjectToken1() public {
        _runRecycle({wantProjectToken0: false, useNative: false});
    }

    /// @notice With enough gas, a native ETH payout is minted into a bid.
    function test_Payout_RecyclesIntoBid_Native() public {
        _runRecycle({wantProjectToken0: false, useNative: true});
    }

    /// @notice An automation attempt that fails still keeps the accepted payout in the ledger.
    function test_Payout_AutomationFails_KeepsIntake() public {
        _deployed({wantProjectToken0: false, useNative: false});

        // A controller that cannot report a ruleset makes the recycle revert inside the attempt; intake never reads
        // it.
        _setDirectoryController({projectId: _PID, ctrl: address(0xdead)});
        uint256 askBefore = hook.askTokenIdOf({projectId: _PID, terminalToken: _term});

        // The failed attempt is reported, and the payout is still taken.
        vm.expectEmit(address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed({
            projectId: _PID, reasonSelector: bytes4(0), caller: address(_payer)
        });
        uint256 sent = _payout({token: _term, amount: _PAYOUT, intakeOnly: false});

        // The payout stays ledgered and held, and the attempt left no position behind.
        assertEq(sent, _PAYOUT, "the payout was taken");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term}),
            _PAYOUT,
            "the payout stays ledgered"
        );
        assertEq(_termBalanceOf(address(hook)), _PAYOUT, "and held");
        assertEq(
            hook.askTokenIdOf({projectId: _PID, terminalToken: _term}), askBefore, "the failed attempt rolled back"
        );
        assertEq(hook.bidTokenIdOf({projectId: _PID, terminalToken: _term}), 0, "no bid");
    }

    // ─── Automation budget: an attempt never takes more than its budget from the payout loop
    // ─────────────────────────────────────────────────────

    /// @notice An attempt whose dependency burns every unit of gas it is given costs the caller at most the budget,
    /// however much gas the caller supplied: the payout is still taken and ledgered.
    function test_Payout_AutomationGasIsCapped() public {
        _deployed({wantProjectToken0: false, useNative: false});

        // The oracle burns all the gas the attempt forwards to it.
        baseOracleHook.setBurnGas(true);

        // Pay out with far more gas than the budget and measure what the call used.
        vm.expectEmit(true, false, false, false, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed({
            projectId: _PID, reasonSelector: bytes4(0), caller: address(_payer)
        });
        uint256 gasBefore = gasleft();
        uint256 sent =
            _payer.sendPayout{gas: 10_000_000}({split: _split(), projectId: _PID, token: _term, amount: _PAYOUT});
        uint256 gasUsed = gasBefore - gasleft();

        // The payout was ledgered and the attempt stayed within its budget.
        assertEq(sent, _PAYOUT, "the payout was taken");
        assertEq(hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term}), _PAYOUT, "and stays ledgered");
        assertLt(gasUsed, _AUTOMATION_GAS_BUDGET + INTAKE_ONLY_GAS, "the attempt used at most its budget");
    }

    /// @notice Core's payout loop with the hook first and 20 ordinary recipients after it, where the hook's attempt
    /// exhausts its budget: with the budget plus the loop's own needs, every later recipient is still paid.
    function test_Payout_AutomationBudget_LaterRecipientsPaid() public {
        _wire({wantProjectToken0: false, useNative: false, projectTerminal: new MockJBMultiTerminal()});

        // A funded payout-loop terminal of the project.
        PayoutLoopTerminal loop = new PayoutLoopTerminal();
        _addDirectoryTerminal({projectId: _PID, term: address(loop)});
        MockERC20(_term).mint({to: address(loop), amount: 100e18});

        // The hook first, then 20 ordinary recipients, each with an equal share.
        uint256 count = 21;
        uint32 percent = JBConstants.SPLITS_TOTAL_PERCENT / 21;
        JBSplit[] memory splits = new JBSplit[](count);
        splits[0] = _split();
        splits[0].percent = percent;
        for (uint256 i = 1; i < count; i++) {
            splits[i] = JBSplit({
                percent: percent,
                projectId: 0,
                beneficiary: payable(vm.addr(0xB0B0000 + i)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            });
        }
        loop.setSplits(splits);

        // The oracle burns all the gas the hook's attempt forwards to it.
        baseOracleHook.setBurnGas(true);

        // Distribute with only the budget plus the loop's own needs.
        vm.expectEmit(true, false, false, false, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed({
            projectId: _PID, reasonSelector: bytes4(0), caller: address(loop)
        });
        loop.distribute{gas: 3_500_000}({projectId: _PID, token: _term, amount: 21e18});

        // The hook's share was ledgered and every later recipient was paid.
        assertGt(
            hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term}),
            0,
            "the hook's payout was taken and ledgered"
        );
        for (uint256 i = 1; i < count; i++) {
            assertGt(MockERC20(_term).balanceOf(splits[i].beneficiary), 0, "every later recipient is paid");
        }
    }

    // ─── Rejections: each reverts and Core refunds the whole payout to the project's balance
    // ─────────────────────────────────────────────────────

    /// @notice A payout before the pool is deployed is refunded, because there is no bid to fund yet.
    function test_Payout_RejectedBeforeDeploy() public {
        // Wire the project without deploying its pool.
        _wireUndeployed({wantProjectToken0: false, useNative: false, projectTerminal: new MockJBMultiTerminal()});
        _setUpPayer();

        // Core's path refunds the whole payout.
        uint256 payerBefore = _termBalanceOf(address(_payer));
        uint256 sent = _payout({token: _term, amount: _PAYOUT, intakeOnly: false});
        _assertRefunded({token: _term, sent: sent, ledgerBefore: 0, payerBefore: payerBefore});

        // The reason: there is no bid to fund yet.
        vm.startPrank(address(_payer));
        MockERC20(_term).approve({spender: address(hook), amount: _PAYOUT});
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidStageForAction.selector, _PID, _term, 0
            )
        );
        hook.processSplitWith(_context({token: _term, amount: _PAYOUT, groupId: uint256(uint160(_term))}));
        vm.stopPrank();
    }

    /// @notice A native ETH payout before the pool is deployed is refunded.
    function test_Payout_RejectedBeforeDeploy_Native() public {
        // Wire the project without deploying its pool.
        _wireUndeployed({wantProjectToken0: false, useNative: true, projectTerminal: new MockJBMultiTerminal()});
        _setUpPayer();

        // Core's path refunds the whole payout.
        uint256 payerBefore = _termBalanceOf(address(_payer));
        uint256 sent = _payout({token: _term, amount: _PAYOUT, intakeOnly: false});
        _assertRefunded({token: _term, sent: sent, ledgerBefore: 0, payerBefore: payerBefore});
    }

    /// @notice A payout in a token other than the deployed pool's terminal token is refunded.
    function test_Payout_RejectsOtherToken() public {
        _deployed({wantProjectToken0: false, useNative: false});

        // The terminal holds a token the pool does not pair.
        MockERC20 other = new MockERC20("Other", "O", 18);
        other.mint({to: address(_payer), amount: _PAYOUT});

        uint256 sent = _payout({token: address(other), amount: _PAYOUT, intakeOnly: false});

        // The whole payout is refunded and nothing is ledgered for the token.
        assertEq(sent, 0, "the hook took nothing");
        assertEq(
            _payer.PAYOUT_STORE().refundedOf({projectId: _PID, token: address(other)}),
            _PAYOUT,
            "refunded to the project"
        );
        assertEq(other.balanceOf(address(_payer)), _PAYOUT, "never left the terminal");
        assertEq(other.allowance({owner: address(_payer), spender: address(hook)}), 0, "allowance revoked");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: address(other)}), 0, "no ledger for it"
        );
    }

    /// @notice Native ETH is not the deployed pool's token when the pool pairs an ERC-20.
    function test_Payout_RejectsNativeForErc20Pool() public {
        _deployed({wantProjectToken0: false, useNative: false});

        // The terminal pays out exactly the ETH it holds.
        vm.deal(address(_payer), _PAYOUT);
        uint256 sent = _payout({token: JBConstants.NATIVE_TOKEN, amount: _PAYOUT, intakeOnly: false});

        // The whole payout is refunded and the ETH never left.
        assertEq(sent, 0, "the hook took nothing");
        assertEq(
            _payer.PAYOUT_STORE().refundedOf({projectId: _PID, token: JBConstants.NATIVE_TOKEN}),
            _PAYOUT,
            "refunded to the project"
        );
        assertEq(address(_payer).balance, _PAYOUT, "never left the terminal");
    }

    /// @notice A payout from a sender that is not one of the project's terminals is refunded, and a direct caller is
    /// rejected with the reason.
    function test_Payout_RejectsNonTerminalSender() public {
        _deployed({wantProjectToken0: false, useNative: false});

        // A contract that sends through Core's lib but is not one of the project's terminals.
        LibPayoutTerminal stranger = new LibPayoutTerminal();
        MockERC20(_term).mint({to: address(stranger), amount: _PAYOUT});
        uint256 sent = stranger.sendPayout({split: _split(), projectId: _PID, token: _term, amount: _PAYOUT});

        // The whole payout is refunded and nothing is ledgered.
        assertEq(sent, 0, "the hook took nothing");
        assertEq(stranger.PAYOUT_STORE().refundedOf({projectId: _PID, token: _term}), _PAYOUT, "refunded");
        assertEq(MockERC20(_term).balanceOf(address(stranger)), _PAYOUT, "never left the sender");
        assertEq(hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term}), 0, "bid ledger unchanged");

        // And a direct caller is rejected with the reason.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal.selector,
                _PID,
                address(this),
                address(controller)
            )
        );
        hook.processSplitWith(_context({token: _term, amount: _PAYOUT, groupId: uint256(uint160(_term))}));
    }

    /// @notice Native value that does not match the payout amount, or any value on an ERC-20 payout, is rejected.
    function test_Payout_RejectsMsgValueMismatch() public {
        _deployed({wantProjectToken0: false, useNative: true});
        vm.deal(address(_payer), 10 ether);
        vm.startPrank(address(_payer));

        // One wei short of the payout amount is rejected.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_UnexpectedMsgValue.selector, _PAYOUT - 1
            )
        );
        hook.processSplitWith{value: _PAYOUT - 1}(
            _context({token: _term, amount: _PAYOUT, groupId: uint256(uint160(_term))})
        );

        // One wei over the payout amount is rejected.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_UnexpectedMsgValue.selector, _PAYOUT + 1
            )
        );
        hook.processSplitWith{value: _PAYOUT + 1}(
            _context({token: _term, amount: _PAYOUT, groupId: uint256(uint160(_term))})
        );
        vm.stopPrank();

        // Neither attempt ledgered anything.
        assertEq(hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term}), 0, "nothing ledgered");
    }

    /// @notice Any native value on an ERC-20 payout is rejected.
    function test_Payout_RejectsMsgValueOnErc20() public {
        _deployed({wantProjectToken0: false, useNative: false});
        vm.deal(address(_payer), 1);
        vm.startPrank(address(_payer));
        MockERC20(_term).approve({spender: address(hook), amount: _PAYOUT});

        // A single wei of value alongside an ERC-20 payout is rejected.
        vm.expectRevert(
            abi.encodeWithSelector(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_UnexpectedMsgValue.selector, 1)
        );
        hook.processSplitWith{value: 1}(_context({token: _term, amount: _PAYOUT, groupId: uint256(uint160(_term))}));
        vm.stopPrank();

        // Nothing was ledgered.
        assertEq(hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term}), 0, "nothing ledgered");
    }

    /// @notice A payout filed under any group other than its token's is rejected.
    function test_Payout_RejectsWrongGroup() public {
        _deployed({wantProjectToken0: false, useNative: false});
        vm.startPrank(address(_payer));
        MockERC20(_term).approve({spender: address(hook), amount: _PAYOUT});

        // Group 2 is not the terminal token's payout group.
        vm.expectRevert(
            abi.encodeWithSelector(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidSplitGroup.selector, 2, _term)
        );
        hook.processSplitWith(_context({token: _term, amount: _PAYOUT, groupId: 2}));
        vm.stopPrank();

        // Nothing was ledgered.
        assertEq(hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term}), 0, "nothing ledgered");
    }

    /// @notice Only the controller delivers reserved tokens: a terminal sending under the reserved group is rejected.
    function test_Payout_TerminalCannotSendReservedGroup() public {
        _deployed({wantProjectToken0: false, useNative: false});

        // The terminal files project tokens under the reserved-token group.
        vm.prank(address(_payer));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal.selector,
                _PID,
                address(_payer),
                address(controller)
            )
        );
        hook.processSplitWith(_context({token: address(_proj), amount: 1e18, groupId: 1}));
    }

    // ─── Helpers
    // ─────────────────────────────────────────────────────

    /// @notice Wire and deploy the harness project, then add a funded payout terminal to it.
    /// @param wantProjectToken0 Whether the project token should sort as currency0.
    /// @param useNative Whether the terminal token is native ETH.
    function _deployed(bool wantProjectToken0, bool useNative) internal {
        _wire({wantProjectToken0: wantProjectToken0, useNative: useNative, projectTerminal: new MockJBMultiTerminal()});
        _setUpPayer();
    }

    /// @notice Send `amount` of `token` through Core's payout path, with only enough gas for intake when `intakeOnly`.
    /// @param token The payout token.
    /// @param amount The payout amount.
    /// @param intakeOnly Whether to cap the gas below the hook's automation floor.
    /// @return sent The amount the hook took.
    function _payout(address token, uint256 amount, bool intakeOnly) internal returns (uint256 sent) {
        // The intake-only cap keeps automation from running inside the payout.
        if (intakeOnly) {
            sent = _payer.sendPayout{gas: INTAKE_ONLY_GAS}({
                split: _split(), projectId: _PID, token: token, amount: amount
            });
        } else {
            sent = _payer.sendPayout({split: _split(), projectId: _PID, token: token, amount: amount});
        }
    }

    /// @notice Send an intake-only payout and assert the bid ledger grows by exactly it, with no recycle.
    /// @param wantProjectToken0 Whether the project token should sort as currency0.
    /// @param useNative Whether the terminal token is native ETH.
    function _runIntake(bool wantProjectToken0, bool useNative) internal {
        _deployed({wantProjectToken0: wantProjectToken0, useNative: useNative});

        // Snapshot the ask, the ask ledger, and both holders' balances.
        uint256 askBefore = hook.askTokenIdOf({projectId: _PID, terminalToken: _term});
        uint256 projectLedgerBefore = hook.accumulatedProjectTokens(_PID);
        uint256 hookBefore = _termBalanceOf(address(hook));
        uint256 payerBefore = _termBalanceOf(address(_payer));

        // The hook reports the accepted payout.
        vm.expectEmit(address(hook));
        emit IJBUniswapV4LPSplitHook.PayoutAccepted({
            projectId: _PID, terminalToken: _term, amount: _PAYOUT, caller: address(_payer)
        });
        uint256 sent = _payout({token: _term, amount: _PAYOUT, intakeOnly: true});

        // The whole payout moved into the bid ledger and nothing else changed.
        assertEq(sent, _PAYOUT, "Core counts the whole payout as sent");
        assertEq(_payer.PAYOUT_STORE().refundedOf({projectId: _PID, token: _term}), 0, "nothing refunded");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term}),
            _PAYOUT,
            "bid ledger grows by exactly the payout"
        );
        assertEq(_termBalanceOf(address(hook)) - hookBefore, _PAYOUT, "the hook holds exactly the payout");
        assertEq(payerBefore - _termBalanceOf(address(_payer)), _PAYOUT, "the payout left the terminal");
        assertEq(hook.accumulatedProjectTokens(_PID), projectLedgerBefore, "ask ledger unchanged");
        assertEq(
            hook.askTokenIdOf({projectId: _PID, terminalToken: _term}), askBefore, "no recycle without the gas for one"
        );
    }

    /// @notice Send a payout with full gas and assert it is minted into a new bid in the same call.
    /// @param wantProjectToken0 Whether the project token should sort as currency0.
    /// @param useNative Whether the terminal token is native ETH.
    function _runRecycle(bool wantProjectToken0, bool useNative) internal {
        _deployed({wantProjectToken0: wantProjectToken0, useNative: useNative});

        // Snapshot the positions and the PositionManager's terminal-token balance.
        assertEq(hook.bidTokenIdOf({projectId: _PID, terminalToken: _term}), 0, "no bid before any terminal tokens");
        uint256 askBefore = hook.askTokenIdOf({projectId: _PID, terminalToken: _term});
        uint256 pmBefore = _termBalanceOf(address(positionManager));

        // Far below the reserved-token churn threshold: a payout is never held back as dust.
        uint256 projectLedgerBefore = hook.accumulatedProjectTokens(_PID);
        assertLt(projectLedgerBefore, 1e15, "the ask ledger is below the reserved-token threshold");

        uint256 sent = _payout({token: _term, amount: _PAYOUT, intakeOnly: false});

        // The payout funded a bid, the ask was re-minted, and only rounding stays on the ledger.
        uint256 ledger = hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term});
        assertEq(sent, _PAYOUT, "the whole payout was taken");
        assertTrue(hook.bidTokenIdOf({projectId: _PID, terminalToken: _term}) != 0, "the payout was minted into a bid");
        assertTrue(
            hook.askTokenIdOf({projectId: _PID, terminalToken: _term}) != askBefore, "the recycle re-minted the ask"
        );
        assertEq(_termBalanceOf(address(positionManager)) - pmBefore, _PAYOUT - ledger, "the bid holds the rest");
        assertEq(_termBalanceOf(address(hook)), ledger, "the hook holds exactly its ledger");
        assertLt(ledger, _PAYOUT, "the bid took the payout");
    }

    /// @notice Add a payout terminal to the harness project and fund it with 100 terminal tokens (or ETH).
    function _setUpPayer() internal {
        // The payer must be one of the project's terminals for the hook to accept its payouts.
        _payer = new LibPayoutTerminal();
        _addDirectoryTerminal({projectId: _PID, term: address(_payer)});

        // Fund it in the harness terminal token.
        if (_native) vm.deal(address(_payer), 100 ether);
        else MockERC20(_term).mint({to: address(_payer), amount: 100e18});
    }

    /// @notice A rejected payout leaves everything where it was and Core refunds all of it to the project's balance.
    /// @param token The payout token.
    /// @param sent The amount the hook took.
    /// @param ledgerBefore The bid ledger before the payout.
    /// @param payerBefore The payer's balance before the payout.
    function _assertRefunded(address token, uint256 sent, uint256 ledgerBefore, uint256 payerBefore) internal view {
        // The hook took nothing and Core refunded the whole payout.
        assertEq(sent, 0, "the hook took nothing");
        assertEq(
            _payer.PAYOUT_STORE().refundedOf({projectId: _PID, token: token}),
            _PAYOUT,
            "the whole payout refunded to the project"
        );

        // The ledger, the payer's balance and the allowance are all as they were.
        assertEq(
            hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term}),
            ledgerBefore,
            "bid ledger unchanged"
        );
        assertEq(_termBalanceOf(address(_payer)), payerBefore, "the payout never left the terminal");
        if (!_native) {
            assertEq(
                MockERC20(_term).allowance({owner: address(_payer), spender: address(hook)}), 0, "allowance revoked"
            );
        }
    }

    /// @notice A split hook context for the harness project.
    /// @param token The token the context carries.
    /// @param amount The amount the context carries.
    /// @param groupId The split group the context is filed under.
    /// @return context The context.
    function _context(
        address token,
        uint256 amount,
        uint256 groupId
    )
        internal
        view
        returns (JBSplitHookContext memory context)
    {
        // Delegate to the base builder with the harness project.
        return _buildContext({projectId: _PID, token: token, amount: amount, groupId: groupId});
    }

    /// @notice A 100% split whose hook is the LP split hook.
    /// @return split The split.
    function _split() internal view returns (JBSplit memory split) {
        // The whole payout goes to the hook, with no project, beneficiary or lock.
        return JBSplit({
            percent: 1_000_000,
            projectId: 0,
            beneficiary: payable(address(0)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(hook))
        });
    }
}
