// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

import {MockERC20} from "./mock/MockERC20.sol";
import {MockJBMultiTerminal} from "./mock/MockJBContracts.sol";
import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";

/// @notice One fresh project, `_PID`, paired against a fresh terminal token in a chosen order (or native ETH), with its
/// own primary terminal so the hook's flows into it are exact.
abstract contract SingleProjectHarness is LPSplitHookV4TestBase {
    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The ID of the harness project, distinct from the base suite's project and fee project.
    uint256 internal constant _PID = 7;

    //*********************************************************************//
    // ----------------------------- structs ----------------------------- //
    //*********************************************************************//

    /// @custom:member projectLedger The hook's ask ledger of the harness project's tokens.
    /// @custom:member terminalLedger The hook's bid ledger of the harness project's terminal tokens.
    /// @custom:member hookProject The project tokens the hook holds.
    /// @custom:member hookTerminal The terminal tokens (or ETH) the hook holds.
    /// @custom:member supply The project token's total supply.
    /// @custom:member projTerminalHeld The terminal tokens (or ETH) the project's own terminal holds.
    /// @custom:member surplus The project's surplus per token in the mock store.
    struct Books {
        uint256 projectLedger;
        uint256 terminalLedger;
        uint256 hookProject;
        uint256 hookTerminal;
        uint256 supply;
        uint256 projTerminalHeld;
        uint256 surplus;
    }

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Whether the harness project's terminal token is native ETH.
    bool internal _native;

    /// @notice The harness project's ERC-20 token.
    MockERC20 internal _proj;

    /// @notice Whether the project token sorts as currency0 of the pool (always false for native ETH).
    bool internal _projectIsToken0;

    /// @notice The project's own primary terminal, separate from the fee project's, so each balance is exact.
    MockJBMultiTerminal internal _projTerminal;

    /// @notice The harness project's terminal token (`JBConstants.NATIVE_TOKEN` for native ETH).
    address internal _term;

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Put `projectFee` and `terminalFee` on the ask, funding the PositionManager for both.
    /// @param projectFee The project-token fee the ask accrues.
    /// @param terminalFee The terminal-token fee the ask accrues.
    function _setFees(uint256 projectFee, uint256 terminalFee) internal {
        // Fund the PositionManager so the collection it pays out is backed.
        _proj.mint({to: address(positionManager), amount: projectFee});
        if (_native) vm.deal(address(positionManager), address(positionManager).balance + terminalFee);
        else MockERC20(_term).mint({to: address(positionManager), amount: terminalFee});

        // Record the fees in the pool's currency order, which depends on how the project token sorts.
        if (_projectIsToken0) {
            positionManager.setCollectableFees({tokenId: _askId(), amount0: projectFee, amount1: terminalFee});
        } else {
            positionManager.setCollectableFees({tokenId: _askId(), amount0: terminalFee, amount1: projectFee});
        }
    }

    /// @notice Wire project `_PID`, accept its reserved tokens, and deploy its pool.
    /// @param wantProjectToken0 Whether the project token should sort as currency0.
    /// @param useNative Whether the terminal token is native ETH.
    /// @param projectTerminal The project's primary terminal.
    function _wire(bool wantProjectToken0, bool useNative, MockJBMultiTerminal projectTerminal) internal {
        // Wire the project and accept its reserved tokens without deploying.
        _wireUndeployed({wantProjectToken0: wantProjectToken0, useNative: useNative, projectTerminal: projectTerminal});

        // The owner deploys the pool from the accepted inventory.
        vm.prank(owner);
        hook.deployPool(_PID);
    }

    /// @notice Wire and deploy project `_PID` with a fresh plain mock terminal as its primary terminal.
    /// @param wantProjectToken0 Whether the project token should sort as currency0.
    /// @param useNative Whether the terminal token is native ETH.
    function _wireDefault(bool wantProjectToken0, bool useNative) internal {
        // A fresh terminal keeps this project's balances separate from every other project's.
        _wire({wantProjectToken0: wantProjectToken0, useNative: useNative, projectTerminal: new MockJBMultiTerminal()});
    }

    /// @notice Wire project `_PID` against a fresh terminal token (or native ETH) in the wanted order and accept 100e18
    /// reserved tokens for it, without deploying its pool.
    /// @param wantProjectToken0 Whether the project token should sort as currency0.
    /// @param useNative Whether the terminal token is native ETH.
    /// @param projectTerminal The project's primary terminal.
    function _wireUndeployed(bool wantProjectToken0, bool useNative, MockJBMultiTerminal projectTerminal) internal {
        // Record the configuration the other helpers read.
        _native = useNative;
        _projTerminal = projectTerminal;

        // Create the tokens, re-creating the project token until it sorts on the wanted side of the terminal token.
        _proj = new MockERC20("Proj", "P", 18);
        _term = useNative ? JBConstants.NATIVE_TOKEN : address(new MockERC20("Term", "T", 18));
        while (!useNative && (address(_proj) < _term) != wantProjectToken0) {
            _proj = new MockERC20("Proj", "P", 18);
        }
        _projectIsToken0 = !useNative && wantProjectToken0;

        // Give the project a ruleset, a controller, an owner and its ERC-20.
        controller.setWeight({projectId: _PID, weight: DEFAULT_WEIGHT});
        controller.setFirstWeight({projectId: _PID, weight: DEFAULT_FIRST_WEIGHT});
        controller.setReservedPercent({projectId: _PID, reservedPercent: DEFAULT_RESERVED_PERCENT});
        controller.setBaseCurrency({projectId: _PID, currency: 1});
        _setDirectoryController({projectId: _PID, ctrl: address(controller)});
        jbProjects.setOwner({tokenId: _PID, owner: owner});
        jbTokens.setToken({projectId: _PID, token: address(_proj)});

        // The terminal token's currency is its address truncated to 32 bits, as Core derives it.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 currency = uint32(uint160(_term));

        // Make the project's terminal its primary terminal for the token, with a 10e18 balance and a taxed curve.
        _projTerminal.setStore(address(store));
        _projTerminal.setProjectToken({projectId: _PID, token: address(_proj)});
        _projTerminal.setAccountingContext({projectId: _PID, token: _term, currency: currency, decimals: 18});
        _projTerminal.addAccountingContext({
            projectId: _PID, ctx: JBAccountingContext({token: _term, decimals: 18, currency: currency})
        });
        _setDirectoryTerminal({projectId: _PID, token: _term, term: address(_projTerminal)});
        _addDirectoryTerminal({projectId: _PID, term: address(_projTerminal)});
        store.setBalance({terminal: address(_projTerminal), projectId: _PID, token: _term, balance: 10e18});
        _setWideTaxedCurve(_PID);

        // A real terminal's deposit raises the project's surplus, and so its cash-out floor.
        _projTerminal.setBumpSurplusOnAddToBalance(true);

        // The controller sends 100e18 reserved tokens, with only enough gas for intake so no pool is deployed.
        _proj.mint({to: address(controller), amount: 100e18});
        vm.startPrank(address(controller));
        _proj.approve({spender: address(hook), amount: 100e18});
        JBSplitHookContext memory context =
            _buildContext({projectId: _PID, token: address(_proj), amount: 100e18, groupId: 1});
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice The harness project's live ask position.
    /// @return tokenId The ask position's token ID.
    function _askId() internal view returns (uint256 tokenId) {
        // Read the hook's record of the ask for the harness pair.
        return hook.askTokenIdOf({projectId: _PID, terminalToken: _term});
    }

    /// @notice A snapshot of every balance and ledger the harness tests compare.
    /// @return b The snapshot.
    function _books() internal view returns (Books memory b) {
        // The hook's ledgers for the harness pair.
        b.projectLedger = hook.accumulatedProjectTokens(_PID);
        b.terminalLedger = hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term});

        // What the hook actually holds, and the project token's supply.
        b.hookProject = _proj.balanceOf(address(hook));
        b.hookTerminal = _termBalanceOf(address(hook));
        b.supply = _proj.totalSupply();

        // The project's terminal balance and surplus, which fee accretion raises.
        b.projTerminalHeld = _termBalanceOf(address(_projTerminal));
        b.surplus = store.surplusPerToken(_PID);
    }

    /// @notice How much of the harness terminal token (or ETH) an address holds.
    /// @param who The address to read.
    /// @return balance The address's terminal-token balance.
    function _termBalanceOf(address who) internal view returns (uint256 balance) {
        // Native ETH lives in the account balance; an ERC-20 in the token's ledger.
        return _native ? who.balance : MockERC20(_term).balanceOf(who);
    }
}
