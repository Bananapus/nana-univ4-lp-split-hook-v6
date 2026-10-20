// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
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
    mapping(uint256 projectId => mapping(address token => uint256)) public refundedOf;

    function accountingContextOf(address, uint256, address token) external pure returns (JBAccountingContext memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function recordAddedBalanceFor(uint256 projectId, address token, uint256 amount) external {
        refundedOf[projectId][token] += amount;
    }
}

/// @notice A terminal that sends payouts exactly the way `JBMultiTerminal` does: by delegatecalling Core's
/// `JBPayoutSplitGroupLib.invokeSplitHookWithPartial` (native ETH pushed as value, an ERC-20 offered as an allowance,
/// any unconsumed part refunded to the project's balance).
contract LibPayoutTerminal is MockJBMultiTerminal {
    PayoutStoreStub public immutable PAYOUT_STORE = new PayoutStoreStub();

    function sendPayout(
        JBSplit calldata split,
        uint256 projectId,
        address token,
        uint256 amount
    )
        external
        returns (uint256 sent)
    {
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

/// @notice The hook also works as a PAYOUT split: one of the project's terminals pays out native ETH or an ERC-20
/// terminal token to it, and the payout funds the bid. Payouts are only accepted for the deployed pool's terminal
/// token, from a
/// terminal of the project, under the token's payout group, with exactly matching value; every rejection makes Core
/// refund the whole payout to the project's balance. The reserved-token path is unchanged.
contract PayoutSplitTest is SingleProjectHarness {
    uint256 internal constant PAYOUT = 3e18;

    LibPayoutTerminal internal payer;

    function _setUpPayer() internal {
        payer = new LibPayoutTerminal();
        _addDirectoryTerminal(PID, address(payer));
        if (native) vm.deal(address(payer), 100 ether);
        else MockERC20(term).mint(address(payer), 100e18);
    }

    function _deployed(bool wantProjectToken0, bool useNative) internal {
        _wire(wantProjectToken0, useNative, new MockJBMultiTerminal());
        _setUpPayer();
    }

    function _split() internal view returns (JBSplit memory) {
        return JBSplit({
            percent: 1_000_000,
            projectId: 0,
            beneficiary: payable(address(0)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(hook))
        });
    }

    /// @notice Send `amount` of `token` through Core's payout path, with only enough gas for intake when `intakeOnly`.
    function _payout(address token, uint256 amount, bool intakeOnly) internal returns (uint256 sent) {
        if (intakeOnly) sent = payer.sendPayout{gas: INTAKE_ONLY_GAS}(_split(), PID, token, amount);
        else sent = payer.sendPayout(_split(), PID, token, amount);
    }

    /// @notice A rejected payout leaves everything where it was and Core refunds all of it to the project's balance.
    function _assertRefunded(address token, uint256 sent, uint256 ledgerBefore, uint256 payerBefore) internal view {
        assertEq(sent, 0, "the hook took nothing");
        assertEq(payer.PAYOUT_STORE().refundedOf(PID, token), PAYOUT, "the whole payout refunded to the project");
        assertEq(hook.accumulatedTerminalTokens(PID, term), ledgerBefore, "bid ledger unchanged");
        assertEq(_termBalanceOf(address(payer)), payerBefore, "the payout never left the terminal");
        if (!native) assertEq(MockERC20(term).allowance(address(payer), address(hook)), 0, "allowance revoked");
    }

    // ─── Intake: the bid ledger grows by exactly the payout
    // ─────────────────────────────────────────────────────

    function _runIntake(bool wantProjectToken0, bool useNative) internal {
        _deployed(wantProjectToken0, useNative);
        uint256 askBefore = hook.askTokenIdOf(PID, term);
        uint256 projectLedgerBefore = hook.accumulatedProjectTokens(PID);
        uint256 hookBefore = _termBalanceOf(address(hook));
        uint256 payerBefore = _termBalanceOf(address(payer));

        vm.expectEmit(address(hook));
        emit IJBUniswapV4LPSplitHook.PayoutAccepted({
            projectId: PID, terminalToken: term, amount: PAYOUT, caller: address(payer)
        });
        uint256 sent = _payout(term, PAYOUT, true);

        assertEq(sent, PAYOUT, "Core counts the whole payout as sent");
        assertEq(payer.PAYOUT_STORE().refundedOf(PID, term), 0, "nothing refunded");
        assertEq(hook.accumulatedTerminalTokens(PID, term), PAYOUT, "bid ledger grows by exactly the payout");
        assertEq(_termBalanceOf(address(hook)) - hookBefore, PAYOUT, "the hook holds exactly the payout");
        assertEq(payerBefore - _termBalanceOf(address(payer)), PAYOUT, "the payout left the terminal");
        assertEq(hook.accumulatedProjectTokens(PID), projectLedgerBefore, "ask ledger unchanged");
        assertEq(hook.askTokenIdOf(PID, term), askBefore, "no recycle without the gas for one");
    }

    function test_Payout_Intake_ProjectToken0() public {
        _runIntake(true, false);
    }

    function test_Payout_Intake_ProjectToken1() public {
        _runIntake(false, false);
    }

    function test_Payout_Intake_Native() public {
        _runIntake(false, true);
    }

    // ─── Automation: with the gas for it, the payout is minted into the bid in the same call
    // ─────────────────────────────────────────────────────

    function _runRecycle(bool wantProjectToken0, bool useNative) internal {
        _deployed(wantProjectToken0, useNative);
        assertEq(hook.bidTokenIdOf(PID, term), 0, "no bid before any terminal tokens");
        uint256 askBefore = hook.askTokenIdOf(PID, term);
        uint256 pmBefore = _termBalanceOf(address(positionManager));
        // Far below the reserved-token churn threshold: a payout is never held back as dust.
        uint256 projectLedgerBefore = hook.accumulatedProjectTokens(PID);
        assertLt(projectLedgerBefore, 1e15, "the ask ledger is below the reserved-token threshold");

        uint256 sent = _payout(term, PAYOUT, false);

        uint256 ledger = hook.accumulatedTerminalTokens(PID, term);
        assertEq(sent, PAYOUT, "the whole payout was taken");
        assertTrue(hook.bidTokenIdOf(PID, term) != 0, "the payout was minted into a bid");
        assertTrue(hook.askTokenIdOf(PID, term) != askBefore, "the recycle re-minted the ask");
        assertEq(_termBalanceOf(address(positionManager)) - pmBefore, PAYOUT - ledger, "the bid holds the rest");
        assertEq(_termBalanceOf(address(hook)), ledger, "the hook holds exactly its ledger");
        assertLt(ledger, PAYOUT, "the bid took the payout");
    }

    function test_Payout_RecyclesIntoBid_ProjectToken0() public {
        _runRecycle(true, false);
    }

    function test_Payout_RecyclesIntoBid_ProjectToken1() public {
        _runRecycle(false, false);
    }

    function test_Payout_RecyclesIntoBid_Native() public {
        _runRecycle(false, true);
    }

    /// @notice An automation attempt that fails still keeps the accepted payout in the ledger.
    function test_Payout_AutomationFails_KeepsIntake() public {
        _deployed(false, false);
        // A controller that cannot report a ruleset makes the recycle revert inside the attempt; intake never reads
        // it.
        _setDirectoryController(PID, address(0xdead));
        uint256 askBefore = hook.askTokenIdOf(PID, term);

        vm.expectEmit(address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed({
            projectId: PID, reasonSelector: bytes4(0), caller: address(payer)
        });
        uint256 sent = _payout(term, PAYOUT, false);

        assertEq(sent, PAYOUT, "the payout was taken");
        assertEq(hook.accumulatedTerminalTokens(PID, term), PAYOUT, "the payout stays ledgered");
        assertEq(_termBalanceOf(address(hook)), PAYOUT, "and held");
        assertEq(hook.askTokenIdOf(PID, term), askBefore, "the failed attempt rolled back");
        assertEq(hook.bidTokenIdOf(PID, term), 0, "no bid");
    }

    // ─── Rejections: each reverts and Core refunds the whole payout to the project's balance
    // ─────────────────────────────────────────────────────

    function test_Payout_RejectedBeforeDeploy() public {
        _wireUndeployed(false, false, new MockJBMultiTerminal());
        _setUpPayer();
        uint256 payerBefore = _termBalanceOf(address(payer));
        uint256 sent = _payout(term, PAYOUT, false);
        _assertRefunded(term, sent, 0, payerBefore);

        // The reason: there is no bid to fund yet.
        vm.startPrank(address(payer));
        MockERC20(term).approve(address(hook), PAYOUT);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidStageForAction.selector, PID, term, 0
            )
        );
        hook.processSplitWith(_context(term, PAYOUT, uint256(uint160(term))));
        vm.stopPrank();
    }

    function test_Payout_RejectedBeforeDeploy_Native() public {
        _wireUndeployed(false, true, new MockJBMultiTerminal());
        _setUpPayer();
        uint256 payerBefore = _termBalanceOf(address(payer));
        uint256 sent = _payout(term, PAYOUT, false);
        _assertRefunded(term, sent, 0, payerBefore);
    }

    function test_Payout_RejectsOtherToken() public {
        _deployed(false, false);
        MockERC20 other = new MockERC20("Other", "O", 18);
        other.mint(address(payer), PAYOUT);
        uint256 sent = _payout(address(other), PAYOUT, false);
        assertEq(sent, 0, "the hook took nothing");
        assertEq(payer.PAYOUT_STORE().refundedOf(PID, address(other)), PAYOUT, "refunded to the project");
        assertEq(other.balanceOf(address(payer)), PAYOUT, "never left the terminal");
        assertEq(other.allowance(address(payer), address(hook)), 0, "allowance revoked");
        assertEq(hook.accumulatedTerminalTokens(PID, address(other)), 0, "no ledger for it");
    }

    /// @notice Native ETH is not the deployed pool's token when the pool pairs an ERC-20.
    function test_Payout_RejectsNativeForErc20Pool() public {
        _deployed(false, false);
        vm.deal(address(payer), PAYOUT);
        uint256 sent = _payout(JBConstants.NATIVE_TOKEN, PAYOUT, false);
        assertEq(sent, 0, "the hook took nothing");
        assertEq(payer.PAYOUT_STORE().refundedOf(PID, JBConstants.NATIVE_TOKEN), PAYOUT, "refunded to the project");
        assertEq(address(payer).balance, PAYOUT, "never left the terminal");
    }

    function test_Payout_RejectsNonTerminalSender() public {
        _deployed(false, false);
        // A contract that sends through Core's lib but is not one of the project's terminals.
        LibPayoutTerminal stranger = new LibPayoutTerminal();
        MockERC20(term).mint(address(stranger), PAYOUT);
        uint256 sent = stranger.sendPayout(_split(), PID, term, PAYOUT);
        assertEq(sent, 0, "the hook took nothing");
        assertEq(stranger.PAYOUT_STORE().refundedOf(PID, term), PAYOUT, "refunded");
        assertEq(MockERC20(term).balanceOf(address(stranger)), PAYOUT, "never left the sender");
        assertEq(hook.accumulatedTerminalTokens(PID, term), 0, "bid ledger unchanged");

        // And a direct caller is rejected with the reason.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal.selector,
                PID,
                address(this),
                address(controller)
            )
        );
        hook.processSplitWith(_context(term, PAYOUT, uint256(uint160(term))));
    }

    function _context(address token, uint256 amount, uint256 groupId)
        internal
        view
        returns (JBSplitHookContext memory)
    {
        return _buildContext(PID, token, amount, groupId);
    }

    /// @notice Native value that does not match the payout amount, or any value on an ERC-20 payout, is rejected.
    function test_Payout_RejectsMsgValueMismatch() public {
        _deployed(false, true);
        vm.deal(address(payer), 10 ether);
        vm.startPrank(address(payer));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_UnexpectedMsgValue.selector, PAYOUT - 1
            )
        );
        hook.processSplitWith{value: PAYOUT - 1}(_context(term, PAYOUT, uint256(uint160(term))));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_UnexpectedMsgValue.selector, PAYOUT + 1
            )
        );
        hook.processSplitWith{value: PAYOUT + 1}(_context(term, PAYOUT, uint256(uint160(term))));
        vm.stopPrank();
        assertEq(hook.accumulatedTerminalTokens(PID, term), 0, "nothing ledgered");
    }

    function test_Payout_RejectsMsgValueOnErc20() public {
        _deployed(false, false);
        vm.deal(address(payer), 1);
        vm.startPrank(address(payer));
        MockERC20(term).approve(address(hook), PAYOUT);
        vm.expectRevert(
            abi.encodeWithSelector(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_UnexpectedMsgValue.selector, 1)
        );
        hook.processSplitWith{value: 1}(_context(term, PAYOUT, uint256(uint160(term))));
        vm.stopPrank();
        assertEq(hook.accumulatedTerminalTokens(PID, term), 0, "nothing ledgered");
    }

    /// @notice A payout filed under any group other than its token's is rejected.
    function test_Payout_RejectsWrongGroup() public {
        _deployed(false, false);
        vm.startPrank(address(payer));
        MockERC20(term).approve(address(hook), PAYOUT);
        vm.expectRevert(
            abi.encodeWithSelector(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidSplitGroup.selector, 2, term)
        );
        hook.processSplitWith(_context(term, PAYOUT, 2));
        vm.stopPrank();
        assertEq(hook.accumulatedTerminalTokens(PID, term), 0, "nothing ledgered");
    }

    /// @notice The reserved-token path is unchanged: a terminal cannot deliver reserved tokens.
    function test_Payout_TerminalCannotSendReservedGroup() public {
        _deployed(false, false);
        vm.prank(address(payer));
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal.selector,
                PID,
                address(payer),
                address(controller)
            )
        );
        hook.processSplitWith(_context(address(proj), 1e18, 1));
    }
}
