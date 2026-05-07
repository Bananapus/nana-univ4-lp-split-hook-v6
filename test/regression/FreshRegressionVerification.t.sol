// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";

/// @notice Verify that fee collection reverts when the project's terminal has been removed.
contract RegressionFreshRegressionVerification is LPSplitHookV4TestBase {
    function test_collectFeesRevertsAfterProjectTerminalRemoval() public {
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        positionManager.setCollectableFees(tokenId, 100e18, 0);
        terminalToken.mint(address(positionManager), 100e18);

        _setDirectoryTerminal(PROJECT_ID, address(terminalToken), address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TerminalNotFound.selector,
                PROJECT_ID,
                address(terminalToken)
            )
        );
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));
    }
}
