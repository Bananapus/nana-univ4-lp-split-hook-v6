// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockERC20} from "./mock/MockERC20.sol";
import {SingleProjectHarness} from "./SingleProjectHarness.sol";
import {SurchargeERC20} from "./FeeAccretionTest.t.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";

/// @notice A terminal token that charges the sender on top of a Permit2 mint pull must not spend balances that back
/// another project's ledger on the same clone.
contract MintSurchargeTest is SingleProjectHarness {
    address internal constant _PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function test_SurchargedMint_RevertsAndOtherLedgerStaysBacked() public {
        _wireDefault(false, false);

        // A payout of 1,000 into this project's bid ledger (intake only).
        MockERC20(term).mint(address(projTerminal), 1000e18);
        vm.startPrank(address(projTerminal));
        MockERC20(term).approve(address(hook), 1000e18);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildContext(PID, term, 1000e18, uint256(uint160(term))));
        vm.stopPrank();

        // Another project on the same clone holds 500 of the same terminal token in its ledger.
        bytes32 slot = keccak256(abi.encode(term, keccak256(abi.encode(uint256(99), uint256(2)))));
        vm.store(address(hook), slot, bytes32(uint256(500e18)));
        MockERC20(term).mint(address(hook), 500e18);

        // Permit2's pulls are surcharged 10% on top.
        vm.etch(term, address(new SurchargeERC20()).code);
        SurchargeERC20(term).setSurcharge(_PERMIT2, 1000);

        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TransferNotExact.selector);
        hook.addLiquidity(PID, term);

        assertEq(hook.accumulatedTerminalTokens(PID, term), 1000e18, "this project's ledger is untouched");
        assertEq(hook.accumulatedTerminalTokens(99, term), 500e18, "the other project's ledger is untouched");
        assertEq(MockERC20(term).balanceOf(address(hook)), 1500e18, "the hook still backs both ledgers");
    }
}
