// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

import {MockERC20} from "./mock/MockERC20.sol";
import {MockJBMultiTerminal} from "./mock/MockJBContracts.sol";
import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";

/// @notice One fresh project, `PID`, paired against a fresh terminal token in a chosen order (or native ETH), with its
/// own primary terminal so the hook's flows into it are exact.
abstract contract SingleProjectHarness is LPSplitHookV4TestBase {
    uint256 internal constant PID = 7;

    MockERC20 internal proj;
    address internal term;
    bool internal projectIsToken0;
    bool internal native;
    /// @notice The project's own primary terminal, separate from the fee project's, so each balance is exact.
    MockJBMultiTerminal internal projTerminal;

    // ─── Harness
    // ───────────────────────────────────────────────────────────

    /// @notice Wire project `PID` against a fresh terminal token (or native ETH) in the wanted order and accept 100e18
    /// reserved tokens for it, without deploying its pool.
    function _wireUndeployed(bool wantProjectToken0, bool useNative, MockJBMultiTerminal projectTerminal) internal {
        native = useNative;
        projTerminal = projectTerminal;
        proj = new MockERC20("Proj", "P", 18);
        term = useNative ? JBConstants.NATIVE_TOKEN : address(new MockERC20("Term", "T", 18));
        while (!useNative && (address(proj) < term) != wantProjectToken0) {
            proj = new MockERC20("Proj", "P", 18);
        }
        projectIsToken0 = !useNative && wantProjectToken0;

        controller.setWeight(PID, DEFAULT_WEIGHT);
        controller.setFirstWeight(PID, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(PID, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(PID, 1);
        _setDirectoryController(PID, address(controller));
        jbProjects.setOwner(PID, owner);
        jbTokens.setToken(PID, address(proj));

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 currency = uint32(uint160(term));
        projTerminal.setStore(address(store));
        projTerminal.setProjectToken(PID, address(proj));
        projTerminal.setAccountingContext(PID, term, currency, 18);
        projTerminal.addAccountingContext(PID, JBAccountingContext({token: term, decimals: 18, currency: currency}));
        _setDirectoryTerminal(PID, term, address(projTerminal));
        _addDirectoryTerminal(PID, address(projTerminal));
        store.setBalance(address(projTerminal), PID, term, 10e18);
        _setWideTaxedCurve(PID);
        // A real terminal's deposit raises the project's surplus, and so its cash-out floor.
        projTerminal.setBumpSurplusOnAddToBalance(true);

        proj.mint(address(controller), 100e18);
        vm.startPrank(address(controller));
        proj.approve(address(hook), 100e18);
        JBSplitHookContext memory context = _buildContext(PID, address(proj), 100e18, 1);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();
    }

    function _wire(bool wantProjectToken0, bool useNative, MockJBMultiTerminal projectTerminal) internal {
        _wireUndeployed(wantProjectToken0, useNative, projectTerminal);
        vm.prank(owner);
        hook.deployPool(PID);
    }

    function _wireDefault(bool wantProjectToken0, bool useNative) internal {
        _wire(wantProjectToken0, useNative, new MockJBMultiTerminal());
    }

    function _askId() internal view returns (uint256) {
        return hook.askTokenIdOf(PID, term);
    }

    function _termBalanceOf(address who) internal view returns (uint256) {
        return native ? who.balance : MockERC20(term).balanceOf(who);
    }

    /// @notice Put `projectFee` and `terminalFee` on the ask, funding the PositionManager for both.
    function _setFees(uint256 projectFee, uint256 terminalFee) internal {
        proj.mint(address(positionManager), projectFee);
        if (native) vm.deal(address(positionManager), address(positionManager).balance + terminalFee);
        else MockERC20(term).mint(address(positionManager), terminalFee);
        if (projectIsToken0) positionManager.setCollectableFees(_askId(), projectFee, terminalFee);
        else positionManager.setCollectableFees(_askId(), terminalFee, projectFee);
    }

    struct Books {
        uint256 projectLedger;
        uint256 terminalLedger;
        uint256 hookProject;
        uint256 hookTerminal;
        uint256 supply;
        uint256 projTerminalHeld;
        uint256 surplus;
    }

    function _books() internal view returns (Books memory b) {
        b.projectLedger = hook.accumulatedProjectTokens(PID);
        b.terminalLedger = hook.accumulatedTerminalTokens(PID, term);
        b.hookProject = proj.balanceOf(address(hook));
        b.hookTerminal = _termBalanceOf(address(hook));
        b.supply = proj.totalSupply();
        b.projTerminalHeld = _termBalanceOf(address(projTerminal));
        b.surplus = store.surplusPerToken(PID);
    }
}
