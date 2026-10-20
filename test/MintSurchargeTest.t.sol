// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockERC20} from "./mock/MockERC20.sol";
import {SingleProjectHarness} from "./SingleProjectHarness.sol";
import {SurchargeERC20} from "./FeeAccretionTest.t.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";

/// @notice A terminal token that charges the sender on top of a Permit2 mint pull must not spend balances that back
/// another project's ledger on the same clone.
contract MintSurchargeTest is SingleProjectHarness {
    /// @notice The canonical Permit2 address, which pulls the hook's tokens during a mint.
    address internal constant _PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice A mint whose Permit2 pull debits the hook more than it moves reverts, so every project's ledger on the
    /// clone stays untouched and fully backed.
    function test_SurchargedMint_RevertsAndOtherLedgerStaysBacked() public {
        // Wire and deploy the harness project, its token as currency1 against an ERC-20 terminal token.
        _wireDefault({wantProjectToken0: false, useNative: false});

        // A payout of 1,000 into this project's bid ledger (intake only).
        MockERC20(_term).mint({to: address(_projTerminal), amount: 1000e18});
        vm.startPrank(address(_projTerminal));
        MockERC20(_term).approve({spender: address(hook), amount: 1000e18});
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: _PID, token: _term, amount: 1000e18, groupId: uint256(uint160(_term))})
        );
        vm.stopPrank();

        // Another project on the same clone holds 500 of the same terminal token in its ledger (slot 2 is
        // `accumulatedTerminalTokens`, keyed by project 99 then the token).
        bytes32 slot = keccak256(abi.encode(_term, keccak256(abi.encode(uint256(99), uint256(2)))));
        vm.store(address(hook), slot, bytes32(uint256(500e18)));
        MockERC20(_term).mint({to: address(hook), amount: 500e18});

        // Permit2's pulls are surcharged 10% on top.
        vm.etch(_term, address(new SurchargeERC20()).code);
        SurchargeERC20(_term).setSurcharge({spender: _PERMIT2, bps: 1000});

        // The recycle's mint detects the surcharged pull and reverts.
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TransferNotExact.selector);
        hook.addLiquidity({projectId: _PID, terminalToken: _term});

        // Both ledgers and their backing are unchanged.
        assertEq(
            hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: _term}),
            1000e18,
            "this project's ledger is untouched"
        );
        assertEq(
            hook.accumulatedTerminalTokens({projectId: 99, terminalToken: _term}),
            500e18,
            "the other project's ledger is untouched"
        );
        assertEq(MockERC20(_term).balanceOf(address(hook)), 1500e18, "the hook still backs both ledgers");
    }
}
