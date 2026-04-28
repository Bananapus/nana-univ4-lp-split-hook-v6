// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract PullingTerminal {
    uint256 public lastAddProjectId;
    address public lastAddToken;
    uint256 public lastAddAmount;

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
    {
        lastAddProjectId = projectId;
        lastAddToken = token;
        lastAddAmount = amount;

        if (token != address(0x000000000000000000000000000000000000EEEe) && amount > 0) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }
    }

    receive() external payable {}
}

contract CodexNemesisFreshRound is LPSplitHookV4TestBase {
    function test_feeRouting_missingFeeTerminalFallsBackToProjectBalance() public {
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        PullingTerminal pullingTerminal = new PullingTerminal();
        _setDirectoryTerminal(PROJECT_ID, address(terminalToken), address(pullingTerminal));
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(0));

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        positionManager.setCollectableFees(tokenId, 100e18, 100e18);

        // Fund the mock PM with terminal tokens to cover the collectable fees.
        // In production, swap revenue accumulates in the PoolManager; in the mock,
        // we mint the fee amount so TAKE_PAIR has enough balance to transfer.
        terminalToken.mint(address(positionManager), 100e18);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 expectedTerminalFees = 100e18;

        assertEq(
            pullingTerminal.lastAddProjectId(),
            PROJECT_ID,
            "the full amount should still be routed to the project terminal"
        );
        assertEq(pullingTerminal.lastAddToken(), address(terminalToken), "terminal token should be routed");
        assertEq(pullingTerminal.lastAddAmount(), expectedTerminalFees, "missing fee terminal should not strand funds");

        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "no fee-token claim should be created without a fee terminal");
        assertEq(terminalToken.balanceOf(address(hook)), 0, "no terminal tokens should remain stranded on the hook");
    }

    function test_claimsUseSnapshottedFeeTokenAfterMigration() public {
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        positionManager.setCollectableFees(tokenId, 100e18, 100e18);
        // Fund mock with terminal tokens to cover fees (simulates swap revenue).
        terminalToken.mint(address(positionManager), 100e18);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 claimableBeforeMigration = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimableBeforeMigration, 0, "precondition: fee tokens must accrue before the token migration");

        MockERC20 newFeeProjectToken = new MockERC20("New Fee Project Token", "NEWFEE", 18);
        jbTokens.setToken(FEE_PROJECT_ID, address(newFeeProjectToken));
        terminal.setProjectToken(FEE_PROJECT_ID, address(newFeeProjectToken));

        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);

        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "the claim should be fully cleared after a successful claim");
        assertEq(address(hook.claimableFeeTokenOf(PROJECT_ID)), address(0), "claim token snapshot should clear");
        assertEq(
            feeProjectToken.balanceOf(user),
            claimableBeforeMigration,
            "the beneficiary should receive the originally accrued fee token"
        );
        assertEq(feeProjectToken.balanceOf(address(hook)), 0, "the old fee-project tokens should not remain trapped");
        assertEq(newFeeProjectToken.balanceOf(user), 0, "the migrated fee token should not be used for old claims");
    }
}
