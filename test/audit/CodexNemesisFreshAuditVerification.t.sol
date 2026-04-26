// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract PullingPayTerminal {
    function pay(
        uint256,
        address token,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        if (token != address(0x000000000000000000000000000000000000EEEe) && amount != 0) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }
        return 0;
    }

    receive() external payable {}
}

contract CodexNemesisFreshAuditVerification is LPSplitHookV4TestBase {
    function test_collectFeesAfterProjectTerminalRemovalStrandsProjectShare() public {
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        PullingPayTerminal feeTerminal = new PullingPayTerminal();
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(feeTerminal));

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        positionManager.setCollectableFees(tokenId, 100e18, 0);
        terminalToken.mint(address(positionManager), 100e18);

        _setDirectoryTerminal(PROJECT_ID, address(terminalToken), address(0));

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 projectShare = 100e18 - (100e18 * FEE_PERCENT) / hook.BPS();
        assertEq(
            terminalToken.balanceOf(address(hook)),
            projectShare,
            "project fee share remains on the hook when the project terminal is absent"
        );
        assertEq(terminalToken.balanceOf(address(feeTerminal)), 100e18 - projectShare, "fee share was pulled");
        assertEq(terminal.addToBalanceCallCount(), 0, "project balance was not credited");
    }
}
