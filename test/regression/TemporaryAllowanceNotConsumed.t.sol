// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {TwoPositionFixture} from "./TwoPositionFixture.sol";

/// @notice A fee terminal whose `pay` returns normally after pulling only part of its approval, and still mints the
/// payer fee-project tokens as if it had been paid in full.
contract PartialPullTerminal {
    MockERC20 internal immutable _FEE_PROJECT_TOKEN;
    uint256 public pullBps;

    constructor(MockERC20 feeProjectToken) {
        _FEE_PROJECT_TOKEN = feeProjectToken;
    }

    function setPullBps(uint256 bps) external {
        pullBps = bps;
    }

    function pay(
        uint256,
        address token,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        uint256 pulled = amount * pullBps / 10_000;
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        if (pulled > 0) IERC20(token).transferFrom(msg.sender, address(this), pulled);
        _FEE_PROJECT_TOKEN.mint(beneficiary, amount);
        return amount;
    }
}

/// @notice A fee terminal that returns from `pay` without consuming its whole temporary approval leaves live spend
/// authority behind. The hook must reject that payment (`TemporaryAllowanceNotConsumed`), roll the payment subcall
/// back, and forgive the cut: the whole fee stays protocol-owned liquidity and no fee-project claim is credited.
contract TemporaryAllowanceNotConsumedTest is TwoPositionFixture {
    uint256 internal constant PROJECT_FEE = 10e18;
    uint256 internal constant TERMINAL_FEE = 4e18;

    PartialPullTerminal internal feeTerminal;
    uint256 internal askId;

    function setUp() public override {
        super.setUp();
        feeTerminal = new PartialPullTerminal(feeProjectToken);
        // The fee project accepts both fee currencies through the partially-pulling terminal.
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(feeTerminal));
        _setDirectoryTerminal(FEE_PROJECT_ID, address(projectToken), address(feeTerminal));

        _accumulateAndDeploy(PROJECT_ID, 100e18);
        askId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        _setFees(askId, PROJECT_FEE, TERMINAL_FEE);
    }

    function test_zeroPull_forgivesBothCuts() public {
        _assertBothCutsForgiven(0);
    }

    function test_halfPull_forgivesBothCuts() public {
        _assertBothCutsForgiven(5000);
    }

    function testFuzz_partialPull_forgivesBothCuts(uint256 bps) public {
        _assertBothCutsForgiven(bound(bps, 0, 9999));
    }

    /// @notice Control: the same terminal pulling its full approval is paid, so the checks above are what forgive.
    function test_fullPull_takesBothCuts() public {
        feeTerminal.setPullBps(10_000);
        uint256 projectCut = PROJECT_FEE * FEE_PERCENT / 10_000;
        uint256 terminalCut = TERMINAL_FEE * FEE_PERCENT / 10_000;
        uint256 projectLedgerBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 terminalLedgerBefore = hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken));

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertEq(projectToken.balanceOf(address(feeTerminal)), projectCut, "project-token cut paid");
        assertEq(terminalToken.balanceOf(address(feeTerminal)), terminalCut, "terminal-token cut paid");
        assertEq(hook.claimableFeeTokens(PROJECT_ID), projectCut + terminalCut, "both cuts credited");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), projectLedgerBefore + PROJECT_FEE - projectCut);
        assertEq(
            hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)),
            terminalLedgerBefore + TERMINAL_FEE - terminalCut
        );
    }

    /// @notice The payment target itself reverts with the exact leftover allowance, in both fee currencies.
    function test_payFeeProjectCut_revertsWithLeftoverAllowance() public {
        _assertPayReverts(address(terminalToken), 0);
        _assertPayReverts(address(terminalToken), 5000);
        _assertPayReverts(address(projectToken), 0);
        _assertPayReverts(address(projectToken), 5000);
    }

    function _assertPayReverts(address token, uint256 bps) internal {
        feeTerminal.setPullBps(bps);
        uint256 amount = 1e18;
        MockERC20(token).mint(address(hook), amount);
        uint256 leftover = amount - amount * bps / 10_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed.selector,
                token,
                address(feeTerminal),
                leftover
            )
        );
        vm.prank(address(hook));
        hook.payFeeProjectCut({feeTerminal: address(feeTerminal), feeToken: token, amount: amount});
    }

    function _assertBothCutsForgiven(uint256 bps) internal {
        feeTerminal.setPullBps(bps);
        uint256 projectLedgerBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 terminalLedgerBefore = hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken));
        uint256 projectBalanceBefore = projectToken.balanceOf(address(hook));
        uint256 terminalBalanceBefore = terminalToken.balanceOf(address(hook));

        // Each side (project token first, then terminal token) reports a forgiven cut: nothing paid, the whole fee
        // remains, no fee tokens minted.
        for (uint256 i; i < 2; i++) {
            bool projectSide = i == 0;
            vm.expectEmit(true, true, false, true, address(hook));
            emit IJBUniswapV4LPSplitHook.LPFeesRouted({
                projectId: PROJECT_ID,
                token: projectSide ? address(projectToken) : address(terminalToken),
                totalAmount: projectSide ? PROJECT_FEE : TERMINAL_FEE,
                feeAmount: 0,
                remainingAmount: projectSide ? PROJECT_FEE : TERMINAL_FEE,
                feeTokensMinted: 0,
                caller: address(this)
            });
        }
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // The payment subcall rolled back: no pull, no mint, no lingering approval.
        assertEq(projectToken.balanceOf(address(feeTerminal)), 0, "project-token pull rolled back");
        assertEq(terminalToken.balanceOf(address(feeTerminal)), 0, "terminal-token pull rolled back");
        assertEq(projectToken.allowance(address(hook), address(feeTerminal)), 0, "project-token approval cleared");
        assertEq(terminalToken.allowance(address(hook), address(feeTerminal)), 0, "terminal-token approval cleared");
        assertEq(feeProjectToken.balanceOf(address(hook)), 0, "fee-project mint rolled back");

        // The entire fee stays with the LP.
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), projectLedgerBefore + PROJECT_FEE, "project fee kept");
        assertEq(
            hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)),
            terminalLedgerBefore + TERMINAL_FEE,
            "terminal fee kept"
        );
        assertEq(projectToken.balanceOf(address(hook)), projectBalanceBefore + PROJECT_FEE, "project fee held");
        assertEq(terminalToken.balanceOf(address(hook)), terminalBalanceBefore + TERMINAL_FEE, "terminal fee held");

        // No claim or reserve credit.
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "no fee-token claim");
        assertEq(hook.claimableFeeTokenOf(PROJECT_ID), address(0), "no claim token snapshot");
        assertEq(hook.claimableFeeCredits(PROJECT_ID), 0, "no fee-credit claim");
        assertEq(_outstandingFeeTokenClaims(), 0, "no outstanding reserve");
        assertEq(_inflightFeeRoutingCount(), 0, "no routing left in flight");
    }

    function _outstandingFeeTokenClaims() internal view returns (uint256) {
        return uint256(
            vm.load(
                address(hook),
                keccak256(abi.encode(address(feeProjectToken), uint256(SLOT_OUTSTANDING_FEE_TOKEN_CLAIMS)))
            )
        );
    }

    function _inflightFeeRoutingCount() internal view returns (uint256) {
        return uint256(
            vm.load(
                address(hook), keccak256(abi.encode(address(feeProjectToken), uint256(SLOT_INFLIGHT_FEE_ROUTING_COUNT)))
            )
        );
    }
}
