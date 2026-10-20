// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";

import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockJBMultiTerminal, MockJBTerminalStore, MockJBTokens} from "./mock/MockJBContracts.sol";
import {SingleProjectHarness} from "./SingleProjectHarness.sol";

/// @notice A project terminal whose `addToBalanceOf` first tries to re-enter every hook entry point that could spend
/// hook balances, then behaves like the mock terminal (pulls an ERC-20 / keeps the value) or reverts.
contract ReenteringAddTerminal is MockJBMultiTerminal {
    JBUniswapV4LPSplitHook internal immutable _HOOK;
    uint256 internal immutable _PROJECT_ID;
    address internal _terminalToken;

    /// @notice How many re-entry attempts were made, and how many were let through (must stay 0).
    uint256 public reentryAttempts;
    uint256 public reentrySuccesses;
    /// @notice Whether the add itself reverts after the re-entry attempts.
    bool public revertAfterReentry;

    constructor(JBUniswapV4LPSplitHook hook, uint256 projectId) {
        _HOOK = hook;
        _PROJECT_ID = projectId;
    }

    function setTerminalToken(address token) external {
        _terminalToken = token;
    }

    function setRevertAfterReentry(bool value) external {
        revertAfterReentry = value;
    }

    function _try(bytes memory data) internal {
        reentryAttempts++;
        (bool ok,) = address(_HOOK).call(data);
        if (ok) reentrySuccesses++;
    }

    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
    {
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.addLiquidity, (_PROJECT_ID, _terminalToken)));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.collectAndRouteLPFees, (_PROJECT_ID, _terminalToken)));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.deployPool, (_PROJECT_ID)));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.claimFeeTokensFor, (_PROJECT_ID, address(this))));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.sendToTerminal, (address(this), _PROJECT_ID, token, amount, false)));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.burnFeeRemainder, (_PROJECT_ID, token, amount)));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.executeAutomationFor, (_PROJECT_ID)));
        require(!revertAfterReentry, "ADD_REVERTS");
        addCount++;
        lastAddAmount = amount;
        if (amount > 0 && token != JBConstants.NATIVE_TOKEN) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }
        MockJBTerminalStore store = MockJBTerminalStore(storeAddress);
        store.setSurplus(projectId, store.surplusPerToken(projectId) + amount);
    }

    uint256 public addCount;

    uint256 public lastAddAmount;
}

/// @notice A controller stand-in for the burn route: `burnTokensOf` either reverts, burns nothing, or re-enters the
/// hook and then burns exactly like Core (credits first, then the ERC-20).
contract MisbehavingBurnController {
    enum Mode {
        Revert,
        NoOp,
        Reenter
    }

    Mode public mode;
    JBUniswapV4LPSplitHook internal immutable _HOOK;
    MockJBTokens internal immutable _TOKENS;
    uint256 public reentryAttempts;
    uint256 public reentrySuccesses;

    constructor(JBUniswapV4LPSplitHook hook, MockJBTokens tokens) {
        _HOOK = hook;
        _TOKENS = tokens;
    }

    function setMode(Mode newMode) external {
        mode = newMode;
    }

    function burnTokensOf(address holder, uint256 projectId, uint256 count, string calldata) external {
        if (mode == Mode.Revert) revert("BURN_PAUSED");
        if (mode == Mode.Reenter) {
            reentryAttempts++;
            (bool ok,) = address(_HOOK).call(abi.encodeCall(JBUniswapV4LPSplitHook.deployPool, (projectId)));
            if (ok) reentrySuccesses++;
            reentryAttempts++;
            (ok,) =
                address(_HOOK).call(abi.encodeCall(JBUniswapV4LPSplitHook.claimFeeTokensFor, (projectId, msg.sender)));
            if (ok) reentrySuccesses++;
            _TOKENS.burnFrom({holder: holder, projectId: projectId, count: count});
        }
    }
}

/// @notice A token that debits the sender a surcharge on top of every `transferFrom` that `surchargeSpender` makes and
/// every `transfer` it sends: the amount (and any allowance) moves exactly, but the sender loses more.
contract SurchargeERC20 is MockERC20 {
    address public surchargeSpender;
    uint256 public surchargeBps;

    constructor() MockERC20("Surcharge", "S", 18) {}

    function setSurcharge(address spender, uint256 bps) external {
        surchargeSpender = spender;
        surchargeBps = bps;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        if (msg.sender == surchargeSpender) this.burn(from, amount * surchargeBps / 10_000);
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        if (msg.sender == surchargeSpender) this.burn(msg.sender, amount * surchargeBps / 10_000);
        return true;
    }
}

/// @notice LP fees accrue to the project and raise its cash-out floor: after the unchanged fee-project cut, the
/// terminal-token remainder is added to the project's balance in its primary terminal and the project-token remainder
/// is burned. Either route that fails falls back to that side's ledger exactly, without blocking the other side or the
/// collection, and a reentrant route cannot spend tokens in flight.
contract FeeAccretionTest is SingleProjectHarness {
    uint256 internal constant PROJECT_FEE = 30e18;
    uint256 internal constant TERMINAL_FEE = 4e18;

    /// @notice After a collection of `PROJECT_FEE`/`TERMINAL_FEE` with no fee-project cut, each side either accrued to
    /// the project (`accrued`) or fell back to its ledger exactly.
    function _assertRouted(Books memory b, bool terminalAccrued, bool projectAccrued) internal view {
        Books memory a = _books();
        if (terminalAccrued) {
            assertEq(
                a.projTerminalHeld - b.projTerminalHeld, TERMINAL_FEE, "terminal fee added to the project's balance"
            );
            assertEq(a.surplus - b.surplus, TERMINAL_FEE, "surplus rose by exactly the terminal fee");
            assertEq(a.terminalLedger, b.terminalLedger, "bid ledger unchanged");
            assertEq(a.hookTerminal, b.hookTerminal, "no terminal fee left on the hook");
        } else {
            assertEq(a.projTerminalHeld, b.projTerminalHeld, "nothing added to the project's balance");
            assertEq(a.surplus, b.surplus, "surplus unchanged");
            assertEq(a.terminalLedger, b.terminalLedger + TERMINAL_FEE, "the terminal fee falls back to the bid ledger");
            assertEq(a.hookTerminal, b.hookTerminal + TERMINAL_FEE, "the hook holds exactly the ledgered fee");
        }
        if (projectAccrued) {
            assertEq(b.supply - a.supply, PROJECT_FEE, "supply fell by exactly the project fee");
            assertEq(a.projectLedger, b.projectLedger, "ask ledger unchanged");
            assertEq(a.hookProject, b.hookProject, "no project fee left on the hook");
        } else {
            assertEq(a.supply, b.supply, "nothing burned");
            assertEq(a.projectLedger, b.projectLedger + PROJECT_FEE, "the project fee falls back to the ask ledger");
            assertEq(a.hookProject, b.hookProject + PROJECT_FEE, "the hook holds exactly the ledgered fee");
        }
        assertEq(proj.allowance(address(hook), address(projTerminal)), 0, "no project-token allowance left");
        if (!native) assertEq(MockERC20(term).allowance(address(hook), address(projTerminal)), 0, "no allowance left");
    }

    function _collect() internal {
        hook.collectAndRouteLPFees(PID, term);
    }

    // ─── Success: both sides accrue, both orders and native
    // ─────────────────────────────────────────────────────

    function _runAccrues(bool wantProjectToken0, bool useNative) internal {
        _wireDefault(wantProjectToken0, useNative);
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        _collect();
        _assertRouted(b, true, true);
        assertEq(projTerminal.lastAddToBalanceProjectId(), PID, "added to the originating project");
        assertEq(projTerminal.lastAddToBalanceToken(), term, "in the terminal token");
        assertEq(projTerminal.lastAddToBalanceValue(), useNative ? TERMINAL_FEE : 0, "value only for native");
        assertFalse(projTerminal.lastAddToBalanceShouldReturnHeldFees(), "held fees are not returned");
        assertEq(bytes(projTerminal.lastAddToBalanceMemo()).length, 0, "empty memo");
        assertEq(projTerminal.lastAddToBalanceMetadata().length, 0, "empty metadata");
        assertEq(controller.lastBurnHolder(), address(hook), "the hook burns its own tokens");
        assertEq(controller.lastBurnProjectId(), PID, "of the originating project");
        assertEq(controller.lastBurnAmount(), PROJECT_FEE, "exactly the project fee");
    }

    function test_Accrues_ProjectToken0() public {
        _runAccrues(true, false);
    }

    function test_Accrues_ProjectToken1() public {
        _runAccrues(false, false);
    }

    function test_Accrues_Native() public {
        _runAccrues(false, true);
    }

    /// @notice The fee-project cut still comes first and is unchanged; only the remainder accrues to the project.
    function test_CutFirst_RemainderAccrues() public {
        _wireDefault(true, false);
        // The fee project accepts both fee currencies through the default terminal.
        _setDirectoryTerminal(FEE_PROJECT_ID, term, address(terminal));
        _setDirectoryTerminal(FEE_PROJECT_ID, address(proj), address(terminal));
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        uint256 projectCut = PROJECT_FEE * FEE_PERCENT / 10_000;
        uint256 terminalCut = TERMINAL_FEE * FEE_PERCENT / 10_000;
        Books memory b = _books();

        _collect();

        Books memory a = _books();
        assertEq(MockERC20(term).balanceOf(address(terminal)), terminalCut, "terminal cut paid to the fee project");
        assertEq(proj.balanceOf(address(terminal)), projectCut, "project cut paid to the fee project");
        assertEq(hook.claimableFeeTokens(PID), projectCut + terminalCut, "both cuts credited as claims");
        assertEq(a.projTerminalHeld - b.projTerminalHeld, TERMINAL_FEE - terminalCut, "terminal remainder added");
        assertEq(a.surplus - b.surplus, TERMINAL_FEE - terminalCut, "surplus rose by the terminal remainder");
        assertEq(b.supply - a.supply, PROJECT_FEE - projectCut, "project remainder burned");
        assertEq(a.projectLedger, b.projectLedger, "ask ledger unchanged");
        assertEq(a.terminalLedger, b.terminalLedger, "bid ledger unchanged");
    }

    /// @notice A recycle routes the fees before it prices the corridor, so the raised floor is already priced in and
    /// the re-minted ask holds only the principal and the ledger.
    function test_Recycle_RoutesFeesBeforeMinting() public {
        _wireDefault(false, false);
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        hook.addLiquidity(PID, term);
        Books memory a = _books();
        assertEq(a.projTerminalHeld - b.projTerminalHeld, TERMINAL_FEE, "terminal fee added");
        assertEq(b.supply - a.supply, PROJECT_FEE, "project fee burned");
        assertEq(hook.bidTokenIdOf(PID, term), 0, "no terminal inventory, so no bid");
        assertEq(a.terminalLedger, 0, "nothing ledgered on the terminal side");
    }

    // ─── Fallbacks: each failing route keeps its side's fee in the ledger exactly, never blocking the other side
    // ─────────────────────────────────────────────────────

    /// @notice No primary terminal for the token: the terminal side falls back while the project side still burns.
    function test_Fallback_TerminalMissing() public {
        _wireDefault(true, false);
        _setDirectoryTerminal(PID, term, address(0));
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        _collect();
        _assertRouted(b, false, true);
    }

    function test_Fallback_TerminalMissing_Native() public {
        _wireDefault(false, true);
        _setDirectoryTerminal(PID, term, address(0));
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        _collect();
        _assertRouted(b, false, true);
    }

    /// @notice A primary terminal that rejects the deposit: the terminal side falls back, the project side burns.
    function test_Fallback_AddToBalanceReverts_ProjectToken0() public {
        _wireDefault(true, false);
        projTerminal.setRevertOnAddToBalance(true);
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        _collect();
        _assertRouted(b, false, true);
    }

    function test_Fallback_AddToBalanceReverts_ProjectToken1() public {
        _wireDefault(false, false);
        projTerminal.setRevertOnAddToBalance(true);
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        _collect();
        _assertRouted(b, false, true);
    }

    function test_Fallback_AddToBalanceReverts_Native() public {
        _wireDefault(false, true);
        projTerminal.setRevertOnAddToBalance(true);
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        _collect();
        _assertRouted(b, false, true);
    }

    function _swapController(MisbehavingBurnController.Mode mode) internal returns (MisbehavingBurnController c) {
        c = new MisbehavingBurnController(hook, jbTokens);
        c.setMode(mode);
        _setDirectoryController(PID, address(c));
    }

    /// @notice A controller whose burn reverts: the project side falls back, the terminal side is still added.
    function test_Fallback_BurnReverts_ProjectToken0() public {
        _wireDefault(true, false);
        _swapController(MisbehavingBurnController.Mode.Revert);
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        _collect();
        _assertRouted(b, true, false);
    }

    function test_Fallback_BurnReverts_ProjectToken1() public {
        _wireDefault(false, false);
        _swapController(MisbehavingBurnController.Mode.Revert);
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        _collect();
        _assertRouted(b, true, false);
    }

    /// @notice A controller whose burn "succeeds" without burning: the burn is not exact, so it is forgiven.
    function test_Fallback_BurnBurnsNothing() public {
        _wireDefault(false, true);
        _swapController(MisbehavingBurnController.Mode.NoOp);
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        _collect();
        _assertRouted(b, true, false);
    }

    /// @dev Storage slots of the hook's credit ledger and its owed fee-credit total (`forge inspect ...
    /// storageLayout`).
    uint256 internal constant _SLOT_ACCUMULATED_PROJECT_CREDITS = 0;
    uint256 internal constant _SLOT_OUTSTANDING_FEE_CREDIT_CLAIMS = 19;

    function _mapSlot(uint256 slot, uint256 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    /// @notice Core burns a holder's credits before its ERC-20, so credits on the hook would divert the burn. The hook
    /// first claims its own credits (accepted ones and ones a third party sent it) into the ask ledger, then burns
    /// exactly the fee remainder.
    function test_HookCredits_ClaimedAndLedgered_FeeStillBurned() public {
        _wireDefault(true, false);
        // 2e18 accepted credits on the ledger, plus 5e18 a third party sent the hook.
        vm.store(address(hook), _mapSlot(_SLOT_ACCUMULATED_PROJECT_CREDITS, PID), bytes32(uint256(2e18)));
        jbTokens.setCreditBalance({holder: address(hook), projectId: PID, creditCount: 7e18});
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();

        _collect();

        Books memory a = _books();
        assertEq(controller.lastBurnAmount(), PROJECT_FEE, "the burn was exactly the fee remainder");
        assertEq(a.supply, b.supply + 7e18 - PROJECT_FEE, "the claim minted the credits, the burn took the fee");
        assertEq(jbTokens.creditBalanceOf(address(hook), PID), 0, "every hook credit was claimed");
        assertEq(hook.accumulatedProjectCredits(PID), 0, "the credit ledger moved to the ERC-20 ledger");
        assertEq(a.projectLedger, b.projectLedger + 7e18, "the claimed credits are ask inventory");
        assertEq(a.hookProject, b.hookProject + 7e18, "and held as ERC-20");
        assertEq(a.projTerminalHeld - b.projTerminalHeld, TERMINAL_FEE, "the terminal side is still added");
    }

    // ─── Sender surcharge: a terminal token that debits the hook more than it sends falls back to the ledger
    // ─────────────────────────────────────────────────────

    uint256 internal constant SURCHARGED_PAYOUT = 1000e18;
    uint256 internal constant SURCHARGED_FEE = 100e18;

    /// @notice Swap the terminal token's code for one that surcharges the sender 10% on `spender`'s pulls. Balances and
    /// allowances carry over (same storage layout).
    function _surchargeTerminalToken(address spender) internal {
        vm.etch(term, address(new SurchargeERC20()).code);
        SurchargeERC20(term).setSurcharge({spender: spender, bps: 1000});
    }

    /// @notice Accept a payout of `amount` from the project's terminal, intake only.
    function _acceptPayout(uint256 amount) internal {
        MockERC20(term).mint(address(projTerminal), amount);
        vm.startPrank(address(projTerminal));
        MockERC20(term).approve(address(hook), amount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildContext(PID, term, amount, uint256(uint160(term))));
        vm.stopPrank();
    }

    /// @notice The project's terminal surcharges the hook on the fee add: the add would debit 110 for 100 sent and
    /// leave the payout ledger underbacked, so it is not exact, rolls back, and the whole fee joins the bid ledger.
    function _runSurchargedAdd(bool wantProjectToken0) internal {
        _wireDefault(wantProjectToken0, false);
        _surchargeTerminalToken(address(projTerminal));
        _acceptPayout(SURCHARGED_PAYOUT);
        _setFees(0, SURCHARGED_FEE);
        Books memory b = _books();
        assertEq(b.terminalLedger, SURCHARGED_PAYOUT, "precondition: the payout is ledgered");

        _collect();

        Books memory a = _books();
        assertEq(a.projTerminalHeld, b.projTerminalHeld, "the surcharged add rolled back");
        assertEq(a.terminalLedger, SURCHARGED_PAYOUT + SURCHARGED_FEE, "the whole fee joins the bid ledger");
        assertEq(a.hookTerminal, a.terminalLedger, "the hook holds exactly its ledger");
        assertEq(MockERC20(term).allowance(address(hook), address(projTerminal)), 0, "no allowance left");
    }

    function test_SurchargedAdd_FallsBack_ProjectToken0() public {
        _runSurchargedAdd(true);
    }

    function test_SurchargedAdd_FallsBack_ProjectToken1() public {
        _runSurchargedAdd(false);
    }

    /// @notice The fee project's terminal surcharges the hook on the cut: the cut is not exact, so it is forgiven, and
    /// the whole fee is added to the project's balance through its own (exact) terminal.
    function _runSurchargedCut(bool wantProjectToken0) internal {
        _wireDefault(wantProjectToken0, false);
        _setDirectoryTerminal(FEE_PROJECT_ID, term, address(terminal));
        _surchargeTerminalToken(address(terminal));
        _acceptPayout(SURCHARGED_PAYOUT);
        _setFees(0, SURCHARGED_FEE);
        uint256 feeTerminalBefore = MockERC20(term).balanceOf(address(terminal));
        uint256 claimsBefore = hook.claimableFeeTokens(PID);
        Books memory b = _books();

        _collect();

        Books memory a = _books();
        assertEq(MockERC20(term).balanceOf(address(terminal)), feeTerminalBefore, "the surcharged cut rolled back");
        assertEq(hook.claimableFeeTokens(PID), claimsBefore, "no claim for a forgiven cut");
        assertEq(a.projTerminalHeld - b.projTerminalHeld, SURCHARGED_FEE, "the whole fee is added to the project");
        assertEq(a.terminalLedger, b.terminalLedger, "bid ledger unchanged");
        assertEq(a.hookTerminal, a.terminalLedger, "the hook holds exactly its ledger");
        assertEq(MockERC20(term).allowance(address(hook), address(terminal)), 0, "no allowance left");
    }

    function test_SurchargedCut_Forgiven_ProjectToken0() public {
        _runSurchargedCut(true);
    }

    function test_SurchargedCut_Forgiven_ProjectToken1() public {
        _runSurchargedCut(false);
    }

    /// @notice The fee project's token surcharges the hook on the claim's send: the debit would exceed the claim and
    /// take the rest from the fee project's own ask ledger on this clone, so the claim reverts and stays intact.
    function test_SurchargedFeeTokenClaim_RevertsAndOtherLedgerStaysBacked() public {
        _wireDefault(true, false);
        _setDirectoryTerminal(FEE_PROJECT_ID, term, address(terminal));
        _setDirectoryTerminal(FEE_PROJECT_ID, address(proj), address(terminal));
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        _collect();
        uint256 claim = hook.claimableFeeTokens(PID);
        assertGt(claim, 0, "precondition: a fee-token claim accrued");

        // The fee project also uses this clone: 1,000 of its own tokens back its ask ledger here.
        uint256 feeLedger = 1000e18;
        vm.store(address(hook), keccak256(abi.encode(FEE_PROJECT_ID, uint256(1))), bytes32(feeLedger));
        feeProjectToken.mint(address(hook), feeLedger);
        bytes32 reserveSlot = keccak256(abi.encode(address(feeProjectToken), uint256(20)));
        uint256 reserve = uint256(vm.load(address(hook), reserveSlot));
        assertEq(reserve, claim, "precondition: the claim is reserved");
        assertEq(feeProjectToken.balanceOf(address(hook)), claim + feeLedger, "precondition: both fully backed");

        vm.etch(address(feeProjectToken), address(new SurchargeERC20()).code);
        SurchargeERC20(address(feeProjectToken)).setSurcharge({spender: address(hook), bps: 1000});

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TransferNotExact.selector);
        hook.claimFeeTokensFor(PID, address(0xCAFE));

        assertEq(hook.claimableFeeTokens(PID), claim, "the claim is intact");
        assertEq(hook.claimableFeeTokenOf(PID), address(feeProjectToken), "the claim token is intact");
        assertEq(uint256(vm.load(address(hook), reserveSlot)), reserve, "the reserve is intact");
        assertEq(hook.accumulatedProjectTokens(FEE_PROJECT_ID), feeLedger, "the fee project's ledger is untouched");
        assertEq(feeProjectToken.balanceOf(address(hook)), claim + feeLedger, "the hook still backs both");
        assertEq(feeProjectToken.balanceOf(address(0xCAFE)), 0, "nothing was sent");
    }

    /// @notice A controller that delivers a claim elsewhere gives the hook nothing, so the ledger gains nothing: it
    /// records only the ERC-20 this hook received, and every ledger stays backed.
    function test_MisroutedClaim_LedgersOnlyWhatArrived() public {
        _wireDefault(true, false);
        jbTokens.setCreditBalance({holder: address(hook), projectId: PID, creditCount: 7e18});
        controller.setClaimRedirect(address(0xBEEF));
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();

        _collect();

        Books memory a = _books();
        assertEq(controller.lastBurnAmount(), PROJECT_FEE, "the burn was exactly the fee remainder");
        assertEq(a.projectLedger, b.projectLedger, "nothing arrived, so nothing was ledgered");
        assertEq(a.hookProject, b.hookProject, "the hook received none of the claim");
        assertLe(a.projectLedger, a.hookProject, "the project-token ledger stays backed");
    }

    /// @notice Fee-credit claims the hook owes (a fee project that holds claims from before it tokenized) are never
    /// claimed or burned: the burn would consume them first, so it is forgiven, and only the rest is claimed later.
    function test_OwedFeeCredits_NeverConsumed() public {
        _wireDefault(true, false);
        vm.store(address(hook), _mapSlot(_SLOT_OUTSTANDING_FEE_CREDIT_CLAIMS, PID), bytes32(uint256(4e18)));
        jbTokens.setCreditBalance({holder: address(hook), projectId: PID, creditCount: 9e18});
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();

        _collect();

        _assertRouted(b, true, false);
        assertEq(jbTokens.creditBalanceOf(address(hook), PID), 9e18, "the forgiven burn rolled its claim back");
        assertEq(
            uint256(vm.load(address(hook), _mapSlot(_SLOT_OUTSTANDING_FEE_CREDIT_CLAIMS, PID))),
            4e18,
            "the owed fee credits are untouched"
        );

        // A recycle claims only what is not owed.
        hook.addLiquidity(PID, term);
        assertEq(jbTokens.creditBalanceOf(address(hook), PID), 4e18, "exactly the owed credits remain");
    }

    /// @notice Both routes failing at once is the previous behavior: both fees ledgered.
    function test_Fallback_BothFail_BothLedgered() public {
        _wireDefault(true, false);
        projTerminal.setRevertOnAddToBalance(true);
        controller.setRevertOnBurn(true);
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        _collect();
        _assertRouted(b, false, false);
        assertEq(controller.burnCallCount(), 0, "the forgiven burn left no trace");
        assertEq(projTerminal.addToBalanceCallCount(), 0, "the forgiven add left no trace");
    }

    // ─── Reentrancy: a route that re-enters cannot spend the fee in flight
    // ─────────────────────────────────────────────────────

    function _runReenteringTerminal(bool useNative, bool revertAfter) internal {
        ReenteringAddTerminal t = new ReenteringAddTerminal(hook, PID);
        _wire(false, useNative, t);
        t.setTerminalToken(term);
        t.setRevertAfterReentry(revertAfter);
        // More inventory so a successful re-entrant recycle or add would visibly move tokens.
        proj.mint(address(controller), 10e18);
        vm.startPrank(address(controller));
        proj.approve(address(hook), 10e18);
        JBSplitHookContext memory context = _buildContext(PID, address(proj), 10e18, 1);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        uint256 askBefore = _askId();
        Books memory b = _books();

        _collect();

        // A reverting add rolls its own re-entry attempts back too, so only the accepted add leaves counters.
        assertEq(t.reentryAttempts(), revertAfter ? 0 : 7, "every re-entry was attempted");
        assertEq(t.reentrySuccesses(), 0, "every re-entry was rejected");
        assertEq(t.addCount(), revertAfter ? 0 : 1, "at most one add landed");
        assertEq(_askId(), askBefore, "no re-entrant recycle replaced the ask");
        _assertRouted(b, !revertAfter, true);
        if (!revertAfter) assertEq(t.lastAddAmount(), TERMINAL_FEE, "the add received exactly the fee once");
    }

    function test_Reentrancy_TerminalAdd_Succeeds() public {
        _runReenteringTerminal(false, false);
    }

    function test_Reentrancy_TerminalAdd_Reverts_FeeLedgeredOnce() public {
        _runReenteringTerminal(false, true);
    }

    function test_Reentrancy_TerminalAdd_Native() public {
        _runReenteringTerminal(true, false);
    }

    function test_Reentrancy_TerminalAdd_Native_Reverts_FeeLedgeredOnce() public {
        _runReenteringTerminal(true, true);
    }

    /// @notice A controller that re-enters during the burn: every re-entry is rejected and the fee is burned exactly
    /// once.
    function test_Reentrancy_Burn_RejectedAndBurnedOnce() public {
        _wireDefault(true, false);
        MisbehavingBurnController c = _swapController(MisbehavingBurnController.Mode.Reenter);
        _setFees(PROJECT_FEE, TERMINAL_FEE);
        Books memory b = _books();
        _collect();
        assertEq(c.reentryAttempts(), 2, "both re-entries were attempted");
        assertEq(c.reentrySuccesses(), 0, "both re-entries were rejected");
        _assertRouted(b, true, true);
    }

    /// @notice The route self-calls are reachable only from the hook itself.
    function test_RouteSelfCalls_RejectOutsiders() public {
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_Unauthorized.selector);
        hook.burnFeeRemainder(PROJECT_ID, address(projectToken), 1);
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_Unauthorized.selector);
        hook.sendToTerminal(address(terminal), PROJECT_ID, address(terminalToken), 1, false);
        // The guard is solady's: a reentrant entry reverts with `Reentrancy()`.
        assertEq(ReentrancyGuard.Reentrancy.selector, bytes4(keccak256("Reentrancy()")), "solady guard selector");
    }
}
