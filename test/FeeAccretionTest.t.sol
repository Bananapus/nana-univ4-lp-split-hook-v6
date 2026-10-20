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
    //*********************************************************************//
    // -------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    /// @notice The hook this terminal re-enters.
    JBUniswapV4LPSplitHook internal immutable _HOOK;

    /// @notice The project whose hook entry points this terminal re-enters.
    uint256 internal immutable _PROJECT_ID;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice How many adds landed.
    uint256 public addCount;

    /// @notice The amount of the last add that landed.
    uint256 public lastAddAmount;

    /// @notice How many re-entry attempts were made.
    uint256 public reentryAttempts;

    /// @notice How many re-entry attempts were let through (must stay 0).
    uint256 public reentrySuccesses;

    /// @notice Whether the add itself reverts after the re-entry attempts.
    bool public revertAfterReentry;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The terminal token the re-entrant calls name.
    address internal _terminalToken;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Bind the terminal to the hook and project it re-enters.
    /// @param hook The hook to re-enter.
    /// @param projectId The project whose hook entry points to re-enter.
    constructor(JBUniswapV4LPSplitHook hook, uint256 projectId) {
        _HOOK = hook;
        _PROJECT_ID = projectId;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Attempt every re-entry, then pull the deposit and raise the project's surplus by it, or revert.
    /// @param projectId The project whose balance is added to.
    /// @param token The token deposited.
    /// @param amount The amount deposited.
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
        // Try every hook entry point that could spend hook balances while the deposit is in flight.
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.addLiquidity, (_PROJECT_ID, _terminalToken)));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.collectAndRouteLPFees, (_PROJECT_ID, _terminalToken)));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.deployPool, (_PROJECT_ID)));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.claimFeeTokensFor, (_PROJECT_ID, address(this))));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.sendToTerminal, (address(this), _PROJECT_ID, token, amount, false)));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.burnFeeRemainder, (_PROJECT_ID, token, amount)));
        _try(abi.encodeCall(JBUniswapV4LPSplitHook.executeAutomationFor, (_PROJECT_ID)));

        // Optionally reject the deposit after the attempts, which rolls them back too.
        require(!revertAfterReentry, "ADD_REVERTS");

        // Record the add that landed.
        addCount++;
        lastAddAmount = amount;

        // Pull an ERC-20 deposit; native value already arrived with the call.
        if (amount > 0 && token != JBConstants.NATIVE_TOKEN) {
            require(
                MockERC20(token).transferFrom({from: msg.sender, to: address(this), amount: amount}),
                "TRANSFER_FROM_FAILED"
            );
        }

        // A real terminal's deposit raises the project's surplus.
        MockJBTerminalStore store = MockJBTerminalStore(storeAddress);
        store.setSurplus({projectId: projectId, surplus: store.surplusPerToken(projectId) + amount});
    }

    /// @notice Set whether the add reverts after the re-entry attempts.
    /// @param value Whether the add reverts.
    function setRevertAfterReentry(bool value) external {
        revertAfterReentry = value;
    }

    /// @notice Set the terminal token the re-entrant calls name.
    /// @param token The terminal token.
    function setTerminalToken(address token) external {
        _terminalToken = token;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Call the hook with `data` and count the attempt and whether it succeeded.
    /// @param data The calldata to send the hook.
    function _try(bytes memory data) internal {
        // Count the attempt, then count it again as a success if the hook let it through.
        reentryAttempts++;
        (bool ok,) = address(_HOOK).call(data);
        if (ok) reentrySuccesses++;
    }
}

/// @notice A controller stand-in for the burn route: `burnTokensOf` either reverts, burns nothing, or re-enters the
/// hook and then burns exactly like Core (credits first, then the ERC-20).
contract MisbehavingBurnController {
    /// @notice How `burnTokensOf` behaves.
    /// @dev `Revert`: the burn reverts.
    /// `NoOp`: the burn succeeds without burning anything.
    /// `Reenter`: the burn re-enters the hook, then burns like Core.
    enum Mode {
        Revert,
        NoOp,
        Reenter
    }

    //*********************************************************************//
    // -------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    /// @notice The hook this controller re-enters.
    JBUniswapV4LPSplitHook internal immutable _HOOK;

    /// @notice The token store the burn debits.
    MockJBTokens internal immutable _TOKENS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice How `burnTokensOf` behaves.
    Mode public mode;

    /// @notice How many re-entry attempts were made.
    uint256 public reentryAttempts;

    /// @notice How many re-entry attempts were let through (must stay 0).
    uint256 public reentrySuccesses;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Bind the controller to the hook it re-enters and the token store it burns from.
    /// @param hook The hook to re-enter.
    /// @param tokens The token store the burn debits.
    constructor(JBUniswapV4LPSplitHook hook, MockJBTokens tokens) {
        _HOOK = hook;
        _TOKENS = tokens;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Revert, burn nothing, or re-enter the hook and then burn `count` of `holder`'s tokens, per `mode`.
    /// @param holder The holder whose tokens are burned.
    /// @param projectId The project whose tokens are burned.
    /// @param count The number of tokens to burn.
    function burnTokensOf(address holder, uint256 projectId, uint256 count, string calldata) external {
        // The revert mode rejects the burn outright.
        if (mode == Mode.Revert) revert("BURN_PAUSED");

        // The re-enter mode tries two guarded hook entry points before burning.
        if (mode == Mode.Reenter) {
            // Try to deploy the pool mid-burn.
            reentryAttempts++;
            (bool ok,) = address(_HOOK).call(abi.encodeCall(JBUniswapV4LPSplitHook.deployPool, (projectId)));
            if (ok) reentrySuccesses++;

            // Try to claim fee tokens mid-burn.
            reentryAttempts++;
            (ok,) =
                address(_HOOK).call(abi.encodeCall(JBUniswapV4LPSplitHook.claimFeeTokensFor, (projectId, msg.sender)));
            if (ok) reentrySuccesses++;

            // Burn like Core: credits first, then the ERC-20.
            _TOKENS.burnFrom({holder: holder, projectId: projectId, count: count});
        }
    }

    /// @notice Set how `burnTokensOf` behaves.
    /// @param newMode The behavior.
    function setMode(Mode newMode) external {
        mode = newMode;
    }
}

/// @notice A token that debits the sender a surcharge on top of every `transferFrom` that `surchargeSpender` makes and
/// every `transfer` it sends: the amount (and any allowance) moves exactly, but the sender loses more.
contract SurchargeERC20 is MockERC20 {
    /// @notice The surcharge, in basis points of each surcharged transfer.
    uint256 public surchargeBps;

    /// @notice The only caller whose transfers are surcharged.
    address public surchargeSpender;

    /// @notice Deploy as an 18-decimal token named "Surcharge".
    constructor() MockERC20("Surcharge", "S", 18) {}

    /// @notice Surcharge `spender`'s transfers by `bps` basis points.
    /// @param spender The caller whose transfers are surcharged.
    /// @param bps The surcharge, in basis points.
    function setSurcharge(address spender, uint256 bps) external {
        surchargeSpender = spender;
        surchargeBps = bps;
    }

    /// @notice Transfer `amount`, then burn the surcharge from the sender if the surcharged spender sent it.
    /// @param to The recipient.
    /// @param amount The amount the recipient receives.
    /// @return success Always true.
    function transfer(address to, uint256 amount) public override returns (bool success) {
        // Move the exact amount, then take the surcharge on top from the sender.
        super.transfer({to: to, amount: amount});
        if (msg.sender == surchargeSpender) this.burn({from: msg.sender, amount: amount * surchargeBps / 10_000});
        return true;
    }

    /// @notice Transfer `amount` from `from`, then burn the surcharge from `from` if the surcharged spender pulled it.
    /// @param from The holder the amount is pulled from.
    /// @param to The recipient.
    /// @param amount The amount the recipient receives.
    /// @return success Always true.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool success) {
        // Move the exact amount against the allowance, then take the surcharge on top from the holder.
        super.transferFrom({from: from, to: to, amount: amount});
        if (msg.sender == surchargeSpender) this.burn({from: from, amount: amount * surchargeBps / 10_000});
        return true;
    }
}

/// @notice LP fees accrue to the project and raise its cash-out floor: after the fee-project cut, the
/// terminal-token remainder is added to the project's balance in its primary terminal and the project-token remainder
/// is burned. Either route that fails falls back to that side's ledger exactly, without blocking the other side or the
/// collection, and a reentrant route cannot spend tokens in flight.
contract FeeAccretionTest is SingleProjectHarness {
    /// @notice The project-token fee each collection accrues on the ask.
    uint256 internal constant _PROJECT_FEE = 30e18;

    /// @notice Storage slot of the hook's `accumulatedProjectCredits` mapping (`forge inspect ... storageLayout`).
    uint256 internal constant _SLOT_ACCUMULATED_PROJECT_CREDITS = 0;

    /// @notice Storage slot of the hook's `accumulatedProjectTokens` mapping (`forge inspect ... storageLayout`).
    uint256 internal constant _SLOT_ACCUMULATED_PROJECT_TOKENS = 1;

    /// @notice Storage slot of the hook's owed fee-credit total, `_totalOutstandingFeeCreditClaims`.
    uint256 internal constant _SLOT_OUTSTANDING_FEE_CREDIT_CLAIMS = 19;

    /// @notice The terminal-token fee the surcharge tests collect.
    uint256 internal constant _SURCHARGED_FEE = 100e18;

    /// @notice The terminal-token payout the surcharge tests ledger before collecting.
    uint256 internal constant _SURCHARGED_PAYOUT = 1000e18;

    /// @notice The terminal-token fee each collection accrues on the ask.
    uint256 internal constant _TERMINAL_FEE = 4e18;

    // ─── Success: both sides accrue, both orders and native
    // ─────────────────────────────────────────────────────

    /// @notice Both fee sides accrue to the project when it is token0 against an ERC-20.
    function test_Accrues_ProjectToken0() public {
        _runAccrues({wantProjectToken0: true, useNative: false});
    }

    /// @notice Both fee sides accrue to the project when it is token1 against an ERC-20.
    function test_Accrues_ProjectToken1() public {
        _runAccrues({wantProjectToken0: false, useNative: false});
    }

    /// @notice Both fee sides accrue to the project when it is paired with native ETH.
    function test_Accrues_Native() public {
        _runAccrues({wantProjectToken0: false, useNative: true});
    }

    /// @notice The fee-project cut comes first; only the remainder accrues to the project.
    function test_CutFirst_RemainderAccrues() public {
        _wireDefault({wantProjectToken0: true, useNative: false});

        // The fee project accepts both fee currencies through the default terminal.
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: _term, term: address(terminal)});
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: address(_proj), term: address(terminal)});
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});

        // The fee project's cut of each side, at the hook's fee percent.
        uint256 projectCut = _PROJECT_FEE * FEE_PERCENT / 10_000;
        uint256 terminalCut = _TERMINAL_FEE * FEE_PERCENT / 10_000;
        Books memory b = _books();

        _collect();

        // The cuts reach the fee project as claims, and only the remainders accrue to the project.
        Books memory a = _books();
        assertEq(MockERC20(_term).balanceOf(address(terminal)), terminalCut, "terminal cut paid to the fee project");
        assertEq(_proj.balanceOf(address(terminal)), projectCut, "project cut paid to the fee project");
        assertEq(hook.claimableFeeTokens(_PID), projectCut + terminalCut, "both cuts credited as claims");
        assertEq(a.projTerminalHeld - b.projTerminalHeld, _TERMINAL_FEE - terminalCut, "terminal remainder added");
        assertEq(a.surplus - b.surplus, _TERMINAL_FEE - terminalCut, "surplus rose by the terminal remainder");
        assertEq(b.supply - a.supply, _PROJECT_FEE - projectCut, "project remainder burned");
        assertEq(a.projectLedger, b.projectLedger, "ask ledger unchanged");
        assertEq(a.terminalLedger, b.terminalLedger, "bid ledger unchanged");
    }

    /// @notice A recycle routes the fees before it prices the corridor, so the raised floor is already priced in and
    /// the re-minted ask holds only the principal and the ledger.
    function test_Recycle_RoutesFeesBeforeMinting() public {
        _wireDefault({wantProjectToken0: false, useNative: false});
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        // The recycle collects and routes the fees before minting.
        hook.addLiquidity({projectId: _PID, terminalToken: _term});

        // Both fees accrued and none of the terminal fee was left to fund a bid.
        Books memory a = _books();
        assertEq(a.projTerminalHeld - b.projTerminalHeld, _TERMINAL_FEE, "terminal fee added");
        assertEq(b.supply - a.supply, _PROJECT_FEE, "project fee burned");
        assertEq(hook.bidTokenIdOf({projectId: _PID, terminalToken: _term}), 0, "no terminal inventory, so no bid");
        assertEq(a.terminalLedger, 0, "nothing ledgered on the terminal side");
    }

    // ─── Fallbacks: each failing route keeps its side's fee in the ledger exactly, never blocking the other side
    // ─────────────────────────────────────────────────────

    /// @notice No primary terminal for the token: the terminal side falls back while the project side still burns.
    function test_Fallback_TerminalMissing() public {
        _wireDefault({wantProjectToken0: true, useNative: false});

        // Remove the project's primary terminal for its terminal token.
        _setDirectoryTerminal({projectId: _PID, token: _term, term: address(0)});
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        _assertRouted({booksBefore: b, terminalAccrued: false, projectAccrued: true});
    }

    /// @notice No primary terminal for native ETH: the terminal side falls back while the project side still burns.
    function test_Fallback_TerminalMissing_Native() public {
        _wireDefault({wantProjectToken0: false, useNative: true});

        // Remove the project's primary terminal for native ETH.
        _setDirectoryTerminal({projectId: _PID, token: _term, term: address(0)});
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        _assertRouted({booksBefore: b, terminalAccrued: false, projectAccrued: true});
    }

    /// @notice A primary terminal that rejects the deposit: the terminal side falls back, the project side burns.
    function test_Fallback_AddToBalanceReverts_ProjectToken0() public {
        _wireDefault({wantProjectToken0: true, useNative: false});

        // The project's terminal rejects every deposit.
        _projTerminal.setRevertOnAddToBalance(true);
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        _assertRouted({booksBefore: b, terminalAccrued: false, projectAccrued: true});
    }

    /// @notice A rejected deposit falls back the same way when the project is token1.
    function test_Fallback_AddToBalanceReverts_ProjectToken1() public {
        _wireDefault({wantProjectToken0: false, useNative: false});

        // The project's terminal rejects every deposit.
        _projTerminal.setRevertOnAddToBalance(true);
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        _assertRouted({booksBefore: b, terminalAccrued: false, projectAccrued: true});
    }

    /// @notice A rejected native deposit falls back the same way.
    function test_Fallback_AddToBalanceReverts_Native() public {
        _wireDefault({wantProjectToken0: false, useNative: true});

        // The project's terminal rejects every deposit.
        _projTerminal.setRevertOnAddToBalance(true);
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        _assertRouted({booksBefore: b, terminalAccrued: false, projectAccrued: true});
    }

    /// @notice A controller whose burn reverts: the project side falls back, the terminal side is still added.
    function test_Fallback_BurnReverts_ProjectToken0() public {
        _wireDefault({wantProjectToken0: true, useNative: false});

        // The project's controller rejects every burn.
        _swapController(MisbehavingBurnController.Mode.Revert);
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        _assertRouted({booksBefore: b, terminalAccrued: true, projectAccrued: false});
    }

    /// @notice A rejected burn falls back the same way when the project is token1.
    function test_Fallback_BurnReverts_ProjectToken1() public {
        _wireDefault({wantProjectToken0: false, useNative: false});

        // The project's controller rejects every burn.
        _swapController(MisbehavingBurnController.Mode.Revert);
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        _assertRouted({booksBefore: b, terminalAccrued: true, projectAccrued: false});
    }

    /// @notice A controller whose burn "succeeds" without burning: the burn is not exact, so it is forgiven.
    function test_Fallback_BurnBurnsNothing() public {
        _wireDefault({wantProjectToken0: false, useNative: true});

        // The project's controller accepts every burn but burns nothing.
        _swapController(MisbehavingBurnController.Mode.NoOp);
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        _assertRouted({booksBefore: b, terminalAccrued: true, projectAccrued: false});
    }

    /// @notice Core burns a holder's credits before its ERC-20, so credits on the hook would divert the burn. The hook
    /// first claims its own credits (accepted ones and ones a third party sent it) into the ask ledger, then burns
    /// exactly the fee remainder.
    function test_HookCredits_ClaimedAndLedgered_FeeStillBurned() public {
        _wireDefault({wantProjectToken0: true, useNative: false});

        // 2e18 accepted credits on the ledger, plus 5e18 a third party sent the hook.
        vm.store(address(hook), _mapSlot({slot: _SLOT_ACCUMULATED_PROJECT_CREDITS, key: _PID}), bytes32(uint256(2e18)));
        jbTokens.setCreditBalance({holder: address(hook), projectId: _PID, creditCount: 7e18});
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        // The burn took exactly the fee, after every hook credit was claimed into the ask ledger.
        Books memory a = _books();
        assertEq(controller.lastBurnAmount(), _PROJECT_FEE, "the burn was exactly the fee remainder");
        assertEq(a.supply, b.supply + 7e18 - _PROJECT_FEE, "the claim minted the credits, the burn took the fee");
        assertEq(jbTokens.creditBalanceOf({holder: address(hook), projectId: _PID}), 0, "every hook credit was claimed");
        assertEq(hook.accumulatedProjectCredits(_PID), 0, "the credit ledger moved to the ERC-20 ledger");
        assertEq(a.projectLedger, b.projectLedger + 7e18, "the claimed credits are ask inventory");
        assertEq(a.hookProject, b.hookProject + 7e18, "and held as ERC-20");
        assertEq(a.projTerminalHeld - b.projTerminalHeld, _TERMINAL_FEE, "the terminal side is still added");
    }

    // ─── Sender surcharge: a terminal token that debits the hook more than it sends falls back to the ledger
    // ─────────────────────────────────────────────────────

    /// @notice A surcharged fee add falls back to the bid ledger when the project is token0.
    function test_SurchargedAdd_FallsBack_ProjectToken0() public {
        _runSurchargedAdd(true);
    }

    /// @notice A surcharged fee add falls back to the bid ledger when the project is token1.
    function test_SurchargedAdd_FallsBack_ProjectToken1() public {
        _runSurchargedAdd(false);
    }

    /// @notice A surcharged fee-project cut is forgiven when the project is token0.
    function test_SurchargedCut_Forgiven_ProjectToken0() public {
        _runSurchargedCut(true);
    }

    /// @notice A surcharged fee-project cut is forgiven when the project is token1.
    function test_SurchargedCut_Forgiven_ProjectToken1() public {
        _runSurchargedCut(false);
    }

    /// @notice The fee project's token surcharges the hook on the claim's send: the debit would exceed the claim and
    /// take the rest from the fee project's own ask ledger on this clone, so the claim reverts and stays intact.
    function test_SurchargedFeeTokenClaim_RevertsAndOtherLedgerStaysBacked() public {
        _wireDefault({wantProjectToken0: true, useNative: false});

        // Route both cuts to the fee project so a fee-token claim accrues.
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: _term, term: address(terminal)});
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: address(_proj), term: address(terminal)});
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        _collect();
        uint256 claim = hook.claimableFeeTokens(_PID);
        assertGt(claim, 0, "precondition: a fee-token claim accrued");

        // The fee project also uses this clone: 1,000 of its own tokens back its ask ledger here.
        uint256 feeLedger = 1000e18;
        vm.store(
            address(hook), keccak256(abi.encode(FEE_PROJECT_ID, _SLOT_ACCUMULATED_PROJECT_TOKENS)), bytes32(feeLedger)
        );
        feeProjectToken.mint({to: address(hook), amount: feeLedger});

        // The hook reserves exactly the claim for the fee token, and holds enough to back both.
        bytes32 reserveSlot = keccak256(abi.encode(address(feeProjectToken), SLOT_OUTSTANDING_FEE_TOKEN_CLAIMS));
        uint256 reserve = uint256(vm.load(address(hook), reserveSlot));
        assertEq(reserve, claim, "precondition: the claim is reserved");
        assertEq(feeProjectToken.balanceOf(address(hook)), claim + feeLedger, "precondition: both fully backed");

        // Swap in a fee token that surcharges every send the hook makes by 10%.
        vm.etch(address(feeProjectToken), address(new SurchargeERC20()).code);
        SurchargeERC20(address(feeProjectToken)).setSurcharge({spender: address(hook), bps: 1000});

        // The claim's send is not exact, so the claim reverts.
        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TransferNotExact.selector);
        hook.claimFeeTokensFor({projectId: _PID, beneficiary: address(0xCAFE)});

        // The claim, its reserve and the fee project's ledger are all intact and backed.
        assertEq(hook.claimableFeeTokens(_PID), claim, "the claim is intact");
        assertEq(hook.claimableFeeTokenOf(_PID), address(feeProjectToken), "the claim token is intact");
        assertEq(uint256(vm.load(address(hook), reserveSlot)), reserve, "the reserve is intact");
        assertEq(hook.accumulatedProjectTokens(FEE_PROJECT_ID), feeLedger, "the fee project's ledger is untouched");
        assertEq(feeProjectToken.balanceOf(address(hook)), claim + feeLedger, "the hook still backs both");
        assertEq(feeProjectToken.balanceOf(address(0xCAFE)), 0, "nothing was sent");
    }

    /// @notice A controller that delivers a claim elsewhere gives the hook nothing, so the ledger gains nothing: it
    /// records only the ERC-20 this hook received, and every ledger stays backed.
    function test_MisroutedClaim_LedgersOnlyWhatArrived() public {
        _wireDefault({wantProjectToken0: true, useNative: false});

        // The hook holds 7e18 credits, but the controller sends every claim to another address.
        jbTokens.setCreditBalance({holder: address(hook), projectId: _PID, creditCount: 7e18});
        controller.setClaimRedirect(address(0xBEEF));
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        // The fee still burned exactly, and the ledger recorded nothing that did not arrive.
        Books memory a = _books();
        assertEq(controller.lastBurnAmount(), _PROJECT_FEE, "the burn was exactly the fee remainder");
        assertEq(a.projectLedger, b.projectLedger, "nothing arrived, so nothing was ledgered");
        assertEq(a.hookProject, b.hookProject, "the hook received none of the claim");
        assertLe(a.projectLedger, a.hookProject, "the project-token ledger stays backed");
    }

    /// @notice Fee-credit claims the hook owes (a fee project that holds claims from before it tokenized) are never
    /// claimed or burned: the burn would consume them first, so it is forgiven, and only the rest is claimed later.
    function test_OwedFeeCredits_NeverConsumed() public {
        _wireDefault({wantProjectToken0: true, useNative: false});

        // The hook owes 4e18 of its 9e18 credits to fee claimants.
        vm.store(
            address(hook), _mapSlot({slot: _SLOT_OUTSTANDING_FEE_CREDIT_CLAIMS, key: _PID}), bytes32(uint256(4e18))
        );
        jbTokens.setCreditBalance({holder: address(hook), projectId: _PID, creditCount: 9e18});
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        // The burn was forgiven and rolled its claim back, so every credit and the owed total are intact.
        _assertRouted({booksBefore: b, terminalAccrued: true, projectAccrued: false});
        assertEq(
            jbTokens.creditBalanceOf({holder: address(hook), projectId: _PID}),
            9e18,
            "the forgiven burn rolled its claim back"
        );
        assertEq(
            uint256(vm.load(address(hook), _mapSlot({slot: _SLOT_OUTSTANDING_FEE_CREDIT_CLAIMS, key: _PID}))),
            4e18,
            "the owed fee credits are untouched"
        );

        // A recycle claims only what is not owed.
        hook.addLiquidity({projectId: _PID, terminalToken: _term});
        assertEq(
            jbTokens.creditBalanceOf({holder: address(hook), projectId: _PID}), 4e18, "exactly the owed credits remain"
        );
    }

    /// @notice When both routes fail at once, both fees are ledgered and neither failed route leaves a trace.
    function test_Fallback_BothFail_BothLedgered() public {
        _wireDefault({wantProjectToken0: true, useNative: false});

        // Both the deposit and the burn are rejected.
        _projTerminal.setRevertOnAddToBalance(true);
        controller.setRevertOnBurn(true);
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        // Both fees fall back, and the rolled-back calls left no counters behind.
        _assertRouted({booksBefore: b, terminalAccrued: false, projectAccrued: false});
        assertEq(controller.burnCallCount(), 0, "the forgiven burn left no trace");
        assertEq(_projTerminal.addToBalanceCallCount(), 0, "the forgiven add left no trace");
    }

    // ─── Reentrancy: a route that re-enters cannot spend the fee in flight
    // ─────────────────────────────────────────────────────

    /// @notice A terminal that re-enters during an accepted ERC-20 add is rejected every time and the add lands once.
    function test_Reentrancy_TerminalAdd_Succeeds() public {
        _runReenteringTerminal({useNative: false, revertAfter: false});
    }

    /// @notice A terminal that re-enters and then rejects the ERC-20 add leaves the fee ledgered exactly once.
    function test_Reentrancy_TerminalAdd_Reverts_FeeLedgeredOnce() public {
        _runReenteringTerminal({useNative: false, revertAfter: true});
    }

    /// @notice A terminal that re-enters during an accepted native add is rejected every time and the add lands once.
    function test_Reentrancy_TerminalAdd_Native() public {
        _runReenteringTerminal({useNative: true, revertAfter: false});
    }

    /// @notice A terminal that re-enters and then rejects the native add leaves the fee ledgered exactly once.
    function test_Reentrancy_TerminalAdd_Native_Reverts_FeeLedgeredOnce() public {
        _runReenteringTerminal({useNative: true, revertAfter: true});
    }

    /// @notice A controller that re-enters during the burn: every re-entry is rejected and the fee is burned exactly
    /// once.
    function test_Reentrancy_Burn_RejectedAndBurnedOnce() public {
        _wireDefault({wantProjectToken0: true, useNative: false});

        // The project's controller re-enters the hook before it burns.
        MisbehavingBurnController c = _swapController(MisbehavingBurnController.Mode.Reenter);
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        // Both re-entries were rejected and both fees still accrued.
        assertEq(c.reentryAttempts(), 2, "both re-entries were attempted");
        assertEq(c.reentrySuccesses(), 0, "both re-entries were rejected");
        _assertRouted({booksBefore: b, terminalAccrued: true, projectAccrued: true});
    }

    /// @notice The route self-calls are reachable only from the hook itself.
    function test_RouteSelfCalls_RejectOutsiders() public {
        // An outside caller cannot burn through the hook's route.
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_Unauthorized.selector);
        hook.burnFeeRemainder({projectId: PROJECT_ID, projectToken: address(projectToken), count: 1});

        // An outside caller cannot send through the hook's route.
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_Unauthorized.selector);
        hook.sendToTerminal({
            terminal: address(terminal),
            projectId: PROJECT_ID,
            token: address(terminalToken),
            amount: 1,
            shouldPay: false
        });

        // The guard is solady's: a reentrant entry reverts with `Reentrancy()`.
        assertEq(ReentrancyGuard.Reentrancy.selector, bytes4(keccak256("Reentrancy()")), "solady guard selector");
    }

    // ─── Helpers
    // ─────────────────────────────────────────────────────

    /// @notice Accept a payout of `amount` from the project's terminal, intake only.
    /// @param amount The terminal-token payout to accept.
    function _acceptPayout(uint256 amount) internal {
        // Fund the project's terminal and let it pay the hook, with only enough gas for intake.
        MockERC20(_term).mint({to: address(_projTerminal), amount: amount});
        vm.startPrank(address(_projTerminal));
        MockERC20(_term).approve({spender: address(hook), amount: amount});
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: _PID, token: _term, amount: amount, groupId: uint256(uint160(_term))})
        );
        vm.stopPrank();
    }

    /// @notice Collect and route the harness project's LP fees.
    function _collect() internal {
        // Anyone can trigger the collection.
        hook.collectAndRouteLPFees({projectId: _PID, terminalToken: _term});
    }

    /// @notice Collect `_PROJECT_FEE`/`_TERMINAL_FEE` with no fee-project cut and assert both sides accrue to the
    /// originating project through its terminal and controller.
    /// @param wantProjectToken0 Whether the project token should sort as currency0.
    /// @param useNative Whether the terminal token is native ETH.
    function _runAccrues(bool wantProjectToken0, bool useNative) internal {
        _wireDefault({wantProjectToken0: wantProjectToken0, useNative: useNative});
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        Books memory b = _books();

        _collect();

        // Both sides accrued.
        _assertRouted({booksBefore: b, terminalAccrued: true, projectAccrued: true});

        // The add credits the originating project, carries value only for native, and returns no held fees.
        assertEq(_projTerminal.lastAddToBalanceProjectId(), _PID, "added to the originating project");
        assertEq(_projTerminal.lastAddToBalanceToken(), _term, "in the terminal token");
        assertEq(_projTerminal.lastAddToBalanceValue(), useNative ? _TERMINAL_FEE : 0, "value only for native");
        assertFalse(_projTerminal.lastAddToBalanceShouldReturnHeldFees(), "held fees are not returned");
        assertEq(bytes(_projTerminal.lastAddToBalanceMemo()).length, 0, "empty memo");
        assertEq(_projTerminal.lastAddToBalanceMetadata().length, 0, "empty metadata");

        // The burn takes exactly the project fee from the hook's own tokens.
        assertEq(controller.lastBurnHolder(), address(hook), "the hook burns its own tokens");
        assertEq(controller.lastBurnProjectId(), _PID, "of the originating project");
        assertEq(controller.lastBurnAmount(), _PROJECT_FEE, "exactly the project fee");
    }

    /// @notice Route the terminal fee through a terminal that re-enters every spending entry point, and assert every
    /// re-entry is rejected and the fee lands exactly once (added, or ledgered when the add reverts).
    /// @param useNative Whether the terminal token is native ETH.
    /// @param revertAfter Whether the terminal rejects the add after its re-entry attempts.
    function _runReenteringTerminal(bool useNative, bool revertAfter) internal {
        // Wire the project with the re-entering terminal as its primary terminal.
        ReenteringAddTerminal t = new ReenteringAddTerminal({hook: hook, projectId: _PID});
        _wire({wantProjectToken0: false, useNative: useNative, projectTerminal: t});
        t.setTerminalToken(_term);
        t.setRevertAfterReentry(revertAfter);

        // More inventory so a successful re-entrant recycle or add would visibly move tokens.
        _proj.mint({to: address(controller), amount: 10e18});
        vm.startPrank(address(controller));
        _proj.approve({spender: address(hook), amount: 10e18});
        JBSplitHookContext memory context =
            _buildContext({projectId: _PID, token: address(_proj), amount: 10e18, groupId: 1});
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();
        _setFees({projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
        uint256 askBefore = _askId();
        Books memory b = _books();

        _collect();

        // A reverting add rolls its own re-entry attempts back too, so only the accepted add leaves counters.
        assertEq(t.reentryAttempts(), revertAfter ? 0 : 7, "every re-entry was attempted");
        assertEq(t.reentrySuccesses(), 0, "every re-entry was rejected");
        assertEq(t.addCount(), revertAfter ? 0 : 1, "at most one add landed");
        assertEq(_askId(), askBefore, "no re-entrant recycle replaced the ask");

        // The terminal fee is added once or ledgered once, and the project fee burns either way.
        _assertRouted({booksBefore: b, terminalAccrued: !revertAfter, projectAccrued: true});
        if (!revertAfter) assertEq(t.lastAddAmount(), _TERMINAL_FEE, "the add received exactly the fee once");
    }

    /// @notice The project's terminal surcharges the hook on the fee add: the add would debit 110 for 100 sent and
    /// leave the payout ledger underbacked, so it is not exact, rolls back, and the whole fee joins the bid ledger.
    /// @param wantProjectToken0 Whether the project token should sort as currency0.
    function _runSurchargedAdd(bool wantProjectToken0) internal {
        _wireDefault({wantProjectToken0: wantProjectToken0, useNative: false});

        // The terminal token surcharges the project terminal's pulls, after a payout is ledgered.
        _surchargeTerminalToken(address(_projTerminal));
        _acceptPayout(_SURCHARGED_PAYOUT);
        _setFees({projectFee: 0, terminalFee: _SURCHARGED_FEE});
        Books memory b = _books();
        assertEq(b.terminalLedger, _SURCHARGED_PAYOUT, "precondition: the payout is ledgered");

        _collect();

        // The add rolled back, and the hook holds exactly the payout plus the fee in its ledger.
        Books memory a = _books();
        assertEq(a.projTerminalHeld, b.projTerminalHeld, "the surcharged add rolled back");
        assertEq(a.terminalLedger, _SURCHARGED_PAYOUT + _SURCHARGED_FEE, "the whole fee joins the bid ledger");
        assertEq(a.hookTerminal, a.terminalLedger, "the hook holds exactly its ledger");
        assertEq(
            MockERC20(_term).allowance({owner: address(hook), spender: address(_projTerminal)}), 0, "no allowance left"
        );
    }

    /// @notice The fee project's terminal surcharges the hook on the cut: the cut is not exact, so it is forgiven, and
    /// the whole fee is added to the project's balance through its own (exact) terminal.
    /// @param wantProjectToken0 Whether the project token should sort as currency0.
    function _runSurchargedCut(bool wantProjectToken0) internal {
        _wireDefault({wantProjectToken0: wantProjectToken0, useNative: false});

        // The fee project takes its cut through the default terminal, whose pulls the terminal token surcharges.
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: _term, term: address(terminal)});
        _surchargeTerminalToken(address(terminal));
        _acceptPayout(_SURCHARGED_PAYOUT);
        _setFees({projectFee: 0, terminalFee: _SURCHARGED_FEE});
        uint256 feeTerminalBefore = MockERC20(_term).balanceOf(address(terminal));
        uint256 claimsBefore = hook.claimableFeeTokens(_PID);
        Books memory b = _books();

        _collect();

        // The cut rolled back without a claim, and the whole fee reached the project instead.
        Books memory a = _books();
        assertEq(MockERC20(_term).balanceOf(address(terminal)), feeTerminalBefore, "the surcharged cut rolled back");
        assertEq(hook.claimableFeeTokens(_PID), claimsBefore, "no claim for a forgiven cut");
        assertEq(a.projTerminalHeld - b.projTerminalHeld, _SURCHARGED_FEE, "the whole fee is added to the project");
        assertEq(a.terminalLedger, b.terminalLedger, "bid ledger unchanged");
        assertEq(a.hookTerminal, a.terminalLedger, "the hook holds exactly its ledger");
        assertEq(MockERC20(_term).allowance({owner: address(hook), spender: address(terminal)}), 0, "no allowance left");
    }

    /// @notice Swap the terminal token's code for one that surcharges the sender 10% on `spender`'s pulls. Balances and
    /// allowances carry over (same storage layout).
    /// @param spender The caller whose transfers are surcharged.
    function _surchargeTerminalToken(address spender) internal {
        // Replace the code in place so every existing balance and allowance is kept.
        vm.etch(_term, address(new SurchargeERC20()).code);
        SurchargeERC20(_term).setSurcharge({spender: spender, bps: 1000});
    }

    /// @notice Make a misbehaving controller the harness project's controller.
    /// @param mode How the controller's burn behaves.
    /// @return c The installed controller.
    function _swapController(MisbehavingBurnController.Mode mode) internal returns (MisbehavingBurnController c) {
        // Deploy the stand-in and point the directory at it.
        c = new MisbehavingBurnController({hook: hook, tokens: jbTokens});
        c.setMode(mode);
        _setDirectoryController({projectId: _PID, ctrl: address(c)});
    }

    /// @notice After a collection of `_PROJECT_FEE`/`_TERMINAL_FEE` with no fee-project cut, each side either accrued
    /// to the project or fell back to its ledger exactly.
    /// @param booksBefore The snapshot taken before the collection.
    /// @param terminalAccrued Whether the terminal fee should have been added to the project's balance.
    /// @param projectAccrued Whether the project fee should have been burned.
    function _assertRouted(Books memory booksBefore, bool terminalAccrued, bool projectAccrued) internal view {
        Books memory a = _books();

        // The terminal side: added to the project's balance and surplus, or kept on the bid ledger.
        if (terminalAccrued) {
            assertEq(
                a.projTerminalHeld - booksBefore.projTerminalHeld,
                _TERMINAL_FEE,
                "terminal fee added to the project's balance"
            );
            assertEq(a.surplus - booksBefore.surplus, _TERMINAL_FEE, "surplus rose by exactly the terminal fee");
            assertEq(a.terminalLedger, booksBefore.terminalLedger, "bid ledger unchanged");
            assertEq(a.hookTerminal, booksBefore.hookTerminal, "no terminal fee left on the hook");
        } else {
            assertEq(a.projTerminalHeld, booksBefore.projTerminalHeld, "nothing added to the project's balance");
            assertEq(a.surplus, booksBefore.surplus, "surplus unchanged");
            assertEq(
                a.terminalLedger,
                booksBefore.terminalLedger + _TERMINAL_FEE,
                "the terminal fee falls back to the bid ledger"
            );
            assertEq(
                a.hookTerminal, booksBefore.hookTerminal + _TERMINAL_FEE, "the hook holds exactly the ledgered fee"
            );
        }

        // The project side: burned from supply, or kept on the ask ledger.
        if (projectAccrued) {
            assertEq(booksBefore.supply - a.supply, _PROJECT_FEE, "supply fell by exactly the project fee");
            assertEq(a.projectLedger, booksBefore.projectLedger, "ask ledger unchanged");
            assertEq(a.hookProject, booksBefore.hookProject, "no project fee left on the hook");
        } else {
            assertEq(a.supply, booksBefore.supply, "nothing burned");
            assertEq(
                a.projectLedger,
                booksBefore.projectLedger + _PROJECT_FEE,
                "the project fee falls back to the ask ledger"
            );
            assertEq(a.hookProject, booksBefore.hookProject + _PROJECT_FEE, "the hook holds exactly the ledgered fee");
        }

        // Neither route leaves an allowance behind.
        assertEq(
            _proj.allowance({owner: address(hook), spender: address(_projTerminal)}),
            0,
            "no project-token allowance left"
        );
        if (!_native) {
            assertEq(
                MockERC20(_term).allowance({owner: address(hook), spender: address(_projTerminal)}),
                0,
                "no allowance left"
            );
        }
    }

    /// @notice The storage slot of `key` in the mapping at `slot`.
    /// @param slot The mapping's storage slot.
    /// @param key The mapping key.
    /// @return location The key's storage slot.
    function _mapSlot(uint256 slot, uint256 key) internal pure returns (bytes32 location) {
        // Solidity stores `mapping[key]` at keccak256(key . slot).
        return keccak256(abi.encode(key, slot));
    }
}
