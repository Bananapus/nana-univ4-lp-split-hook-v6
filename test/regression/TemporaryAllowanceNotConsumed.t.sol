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
    /// @notice The fee-project token minted to every payer.
    MockERC20 internal immutable _FEE_PROJECT_TOKEN;

    /// @notice The share of each payment's approval `pay` pulls, out of 10_000.
    uint256 public pullBps;

    /// @notice Binds the fee-project token this terminal mints to payers.
    /// @param feeProjectToken The fee-project token minted to every payer.
    constructor(MockERC20 feeProjectToken) {
        _FEE_PROJECT_TOKEN = feeProjectToken;
    }

    /// @notice Sets the share of each payment's approval `pay` pulls.
    /// @param bps The share to pull, out of 10_000.
    function setPullBps(uint256 bps) external {
        // Read by `pay` on every payment.
        pullBps = bps;
    }

    /// @notice Pulls `pullBps` of `amount` from the payer and mints the beneficiary `amount` fee-project tokens.
    /// @param token The token being paid.
    /// @param amount The amount the payer approved and reports paying.
    /// @param beneficiary The recipient of the minted fee-project tokens.
    /// @return beneficiaryTokenCount The fee-project tokens minted, always `amount`.
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
        returns (uint256 beneficiaryTokenCount)
    {
        // Pull only part of the approval, leaving the rest of it live on the payer.
        uint256 pulled = amount * pullBps / 10_000;
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        if (pulled > 0) IERC20(token).transferFrom(msg.sender, address(this), pulled);
        // Mint as if the full amount were paid, so only the leftover approval reveals the shortfall.
        _FEE_PROJECT_TOKEN.mint({to: beneficiary, amount: amount});
        return amount;
    }
}

/// @notice A fee terminal that returns from `pay` without consuming its whole temporary approval leaves live spend
/// authority behind. The hook must reject that payment (`TemporaryAllowanceNotConsumed`), roll the payment subcall
/// back, and forgive the cut: the whole fee accrues to the project (terminal side added to its balance, project side
/// burned) and no fee-project claim is credited.
contract TemporaryAllowanceNotConsumedTest is TwoPositionFixture {
    /// @notice The project-token fee collectable on the ask.
    uint256 internal constant _PROJECT_FEE = 10e18;

    /// @notice The terminal-token fee collectable on the ask.
    uint256 internal constant _TERMINAL_FEE = 4e18;

    /// @notice The live ask position the fees accrue on.
    uint256 internal _askId;

    /// @notice The fee project's partially-pulling terminal.
    PartialPullTerminal internal _feeTerminal;

    /// @notice Routes both fee currencies to a partially-pulling terminal and accrues fees on a deployed ask.
    function setUp() public override {
        super.setUp();
        _feeTerminal = new PartialPullTerminal(feeProjectToken);
        // The fee project accepts both fee currencies through the partially-pulling terminal.
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: address(terminalToken), term: address(_feeTerminal)});
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: address(projectToken), term: address(_feeTerminal)});

        // Deploy the pool and make fees collectable on its ask in both currencies.
        _accumulateAndDeploy({projectId: PROJECT_ID, amount: 100e18});
        _askId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        _setFees({tokenId: _askId, projectFee: _PROJECT_FEE, terminalFee: _TERMINAL_FEE});
    }

    /// @notice A terminal that pulls nothing has both cuts forgiven.
    function test_zeroPull_forgivesBothCuts() public {
        // Leave the whole approval unspent.
        _assertBothCutsForgiven(0);
    }

    /// @notice A terminal that pulls half its approval has both cuts forgiven.
    function test_halfPull_forgivesBothCuts() public {
        // Leave half of the approval unspent.
        _assertBothCutsForgiven(5000);
    }

    /// @notice A terminal that pulls any share short of its full approval has both cuts forgiven.
    /// @param bps The share of the approval the terminal pulls, bounded below 10_000.
    function testFuzz_partialPull_forgivesBothCuts(uint256 bps) public {
        // Any pull short of the full approval leaves some of it unspent.
        _assertBothCutsForgiven(bound(bps, 0, 9999));
    }

    /// @notice Control: the same terminal pulling its full approval is paid, so the checks above are what forgive.
    function test_fullPull_takesBothCuts() public {
        // Pull the whole approval, and snapshot the ledgers, supply and project terminal balance.
        _feeTerminal.setPullBps(10_000);
        uint256 projectCut = _PROJECT_FEE * FEE_PERCENT / 10_000;
        uint256 terminalCut = _TERMINAL_FEE * FEE_PERCENT / 10_000;
        uint256 projectLedgerBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 terminalLedgerBefore =
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        uint256 supplyBefore = projectToken.totalSupply();
        uint256 projectTerminalBefore = terminalToken.balanceOf(address(terminal));

        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Both cuts reach the fee terminal and are credited as claimable fee tokens.
        assertEq(projectToken.balanceOf(address(_feeTerminal)), projectCut, "project-token cut paid");
        assertEq(terminalToken.balanceOf(address(_feeTerminal)), terminalCut, "terminal-token cut paid");
        assertEq(hook.claimableFeeTokens(PROJECT_ID), projectCut + terminalCut, "both cuts credited");
        // The remainders accrue to the project: the project side burned, the terminal side added to its balance.
        assertEq(supplyBefore - projectToken.totalSupply(), _PROJECT_FEE - projectCut, "project remainder burned");
        assertEq(
            terminalToken.balanceOf(address(terminal)) - projectTerminalBefore,
            _TERMINAL_FEE - terminalCut,
            "terminal remainder added to the project's balance"
        );
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), projectLedgerBefore, "ask ledger unchanged");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            terminalLedgerBefore,
            "bid ledger unchanged"
        );
    }

    /// @notice The payment target itself reverts with the exact leftover allowance, in both fee currencies.
    function test_sendToTerminal_revertsWithLeftoverAllowance() public {
        // Check a zero pull and a half pull in each fee currency.
        _assertPayReverts({token: address(terminalToken), bps: 0});
        _assertPayReverts({token: address(terminalToken), bps: 5000});
        _assertPayReverts({token: address(projectToken), bps: 0});
        _assertPayReverts({token: address(projectToken), bps: 5000});
    }

    /// @notice Asserts that a fee payment leaving part of its approval unspent reverts the whole collection, forgives
    /// both cuts, and credits no claim.
    /// @param bps The share of the approval the fee terminal pulls, out of 10_000.
    function _assertBothCutsForgiven(uint256 bps) internal {
        // Set the pull share, and snapshot the ledgers, hook balances, supply and project terminal balance.
        _feeTerminal.setPullBps(bps);
        uint256 projectLedgerBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 terminalLedgerBefore =
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        uint256 projectBalanceBefore = projectToken.balanceOf(address(hook));
        uint256 terminalBalanceBefore = terminalToken.balanceOf(address(hook));
        uint256 supplyBefore = projectToken.totalSupply();
        uint256 projectTerminalBefore = terminalToken.balanceOf(address(terminal));

        // Each side (project token first, then terminal token) reports a forgiven cut: nothing paid, the whole fee
        // remains, no fee tokens minted.
        for (uint256 i; i < 2; i++) {
            bool projectSide = i == 0;
            vm.expectEmit(true, true, false, true, address(hook));
            emit IJBUniswapV4LPSplitHook.LPFeesRouted({
                projectId: PROJECT_ID,
                token: projectSide ? address(projectToken) : address(terminalToken),
                totalAmount: projectSide ? _PROJECT_FEE : _TERMINAL_FEE,
                feeAmount: 0,
                remainingAmount: projectSide ? _PROJECT_FEE : _TERMINAL_FEE,
                feeTokensMinted: 0,
                caller: address(this)
            });
        }
        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The payment subcall rolled back: no pull, no mint, no lingering approval.
        assertEq(projectToken.balanceOf(address(_feeTerminal)), 0, "project-token pull rolled back");
        assertEq(terminalToken.balanceOf(address(_feeTerminal)), 0, "terminal-token pull rolled back");
        assertEq(
            projectToken.allowance({owner: address(hook), spender: address(_feeTerminal)}),
            0,
            "project-token approval cleared"
        );
        assertEq(
            terminalToken.allowance({owner: address(hook), spender: address(_feeTerminal)}),
            0,
            "terminal-token approval cleared"
        );
        assertEq(feeProjectToken.balanceOf(address(hook)), 0, "fee-project mint rolled back");

        // The entire fee accrues to the project: the project side burned, the terminal side added to its balance.
        assertEq(supplyBefore - projectToken.totalSupply(), _PROJECT_FEE, "project fee burned");
        assertEq(
            terminalToken.balanceOf(address(terminal)) - projectTerminalBefore,
            _TERMINAL_FEE,
            "terminal fee added to the project's balance"
        );
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), projectLedgerBefore, "ask ledger unchanged");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            terminalLedgerBefore,
            "bid ledger unchanged"
        );
        assertEq(projectToken.balanceOf(address(hook)), projectBalanceBefore, "no project fee left on the hook");
        assertEq(terminalToken.balanceOf(address(hook)), terminalBalanceBefore, "no terminal fee left on the hook");

        // No claim or reserve credit.
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "no fee-token claim");
        assertEq(hook.claimableFeeTokenOf(PROJECT_ID), address(0), "no claim token snapshot");
        assertEq(hook.claimableFeeCredits(PROJECT_ID), 0, "no fee-credit claim");
        assertEq(_outstandingFeeTokenClaims(), 0, "no outstanding reserve");
        assertEq(_inflightFeeRoutingCount(), 0, "no routing left in flight");
    }

    /// @notice Asserts that paying the fee terminal directly reverts with the exact leftover allowance.
    /// @param token The fee currency paid.
    /// @param bps The share of the approval the fee terminal pulls, out of 10_000.
    function _assertPayReverts(address token, uint256 bps) internal {
        // Fund the hook with the payment and compute the approval the terminal leaves unspent.
        _feeTerminal.setPullBps(bps);
        uint256 amount = 1e18;
        MockERC20(token).mint({to: address(hook), amount: amount});
        uint256 leftover = amount - amount * bps / 10_000;

        // The hook's self-call payment path rejects the leftover approval.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed.selector,
                token,
                address(_feeTerminal),
                leftover
            )
        );
        vm.prank(address(hook));
        hook.sendToTerminal({
            terminal: address(_feeTerminal), projectId: FEE_PROJECT_ID, token: token, amount: amount, shouldPay: true
        });
    }

    /// @notice The hook's in-flight fee-routing count for the fee-project token, read from storage.
    /// @return count The number of fee routings in flight.
    function _inflightFeeRoutingCount() internal view returns (uint256 count) {
        // The counter is internal, so read its mapping slot keyed by the fee-project token.
        return uint256(
            vm.load(
                address(hook), keccak256(abi.encode(address(feeProjectToken), uint256(SLOT_INFLIGHT_FEE_ROUTING_COUNT)))
            )
        );
    }

    /// @notice The hook's outstanding fee-token claims for the fee-project token, read from storage.
    /// @return outstanding The fee tokens reserved for claims.
    function _outstandingFeeTokenClaims() internal view returns (uint256 outstanding) {
        // The total is internal, so read its mapping slot keyed by the fee-project token.
        return uint256(
            vm.load(
                address(hook),
                keccak256(abi.encode(address(feeProjectToken), uint256(SLOT_OUTSTANDING_FEE_TOKEN_CLAIMS)))
            )
        );
    }
}
