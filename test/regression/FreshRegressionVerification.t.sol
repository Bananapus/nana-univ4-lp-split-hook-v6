// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";

/// @notice Verify that fee collection no longer depends on the collecting project's own terminal: the terminal-fee
/// remainder is carried into the bid-leg ledger (protocol-owned liquidity), not deposited into the project's treasury,
/// so removing the project's terminal cannot block collection.
contract RegressionFreshRegressionVerification is LPSplitHookV4TestBase {
    function test_collectFeesSucceedsAfterProjectTerminalRemoval() public {
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 fee = 100e18;
        if (address(terminalToken) < address(projectToken)) {
            positionManager.setCollectableFees(tokenId, fee, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, fee);
        }
        terminalToken.mint(address(positionManager), fee);

        // Remove the collecting project's own terminal; the fee cut still routes to the FEE project and the remainder
        // is ledgered, so collection succeeds without touching the (now-absent) project terminal.
        _setDirectoryTerminal(PROJECT_ID, address(terminalToken), address(0));

        uint256 ledgerBefore = hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken));
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 cut = (fee * FEE_PERCENT) / 10_000;
        assertEq(
            hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)) - ledgerBefore,
            fee - cut,
            "terminal remainder is ledgered even without a project terminal"
        );
    }
}
