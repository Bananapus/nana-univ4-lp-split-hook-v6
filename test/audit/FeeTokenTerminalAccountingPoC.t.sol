// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";

contract PullingTerminal {
    address public storeAddress;
    mapping(uint256 projectId => mapping(address token => JBAccountingContext)) public contexts;
    mapping(uint256 projectId => JBAccountingContext[]) public contextsList;
    mapping(uint256 projectId => address token) public projectTokens;

    function setStore(address store) external {
        storeAddress = store;
    }

    function setProjectToken(uint256 projectId, address token) external {
        projectTokens[projectId] = token;
    }

    function setAccountingContext(uint256 projectId, address token, uint32 currency, uint8 decimals) external {
        JBAccountingContext memory context = JBAccountingContext({token: token, decimals: decimals, currency: currency});
        contexts[projectId][token] = context;
        contextsList[projectId].push(context);
    }

    function STORE() external view returns (address) {
        return storeAddress;
    }

    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        returns (JBAccountingContext memory)
    {
        return contexts[projectId][token];
    }

    function accountingContextsOf(uint256 projectId) external view returns (JBAccountingContext[] memory) {
        return contextsList[projectId];
    }

    function pay(
        uint256 projectId,
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
        if (token != address(0x000000000000000000000000000000000000EEEe) && amount > 0) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }

        beneficiaryTokenCount = amount;

        address projectToken = projectTokens[projectId];
        if (projectToken != address(0) && beneficiaryTokenCount > 0) {
            MockERC20(projectToken).mint(beneficiary, beneficiaryTokenCount);
        }
    }

    function cashOutTokensOf(
        address,
        uint256,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256 reclaimAmount)
    {
        reclaimAmount = cashOutCount / 2;

        if (reclaimAmount > 0) {
            MockERC20(tokenToReclaim).mint(beneficiary, reclaimAmount);
        }
    }

    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        if (token != address(0x000000000000000000000000000000000000EEEe) && amount > 0) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }
    }
}

/// @notice Verifies that fee token accounting works correctly when the terminal token IS the fee
/// project token (e.g., a project whose terminal token is JBX). The pre-increment pattern in
/// _routeFeesToProject prevents the burn logic from consuming the freshly minted fee tokens.
contract FeeTokenTerminalAccountingPoC is LPSplitHookV4TestBase {
    PullingTerminal internal pullingTerminal;

    function setUp() public override {
        super.setUp();

        pullingTerminal = new PullingTerminal();
        pullingTerminal.setStore(address(store));
        pullingTerminal.setProjectToken(PROJECT_ID, address(projectToken));
        pullingTerminal.setProjectToken(FEE_PROJECT_ID, address(feeProjectToken));
        pullingTerminal.setAccountingContext(
            PROJECT_ID, address(feeProjectToken), uint32(uint160(address(feeProjectToken))), 18
        );
        pullingTerminal.setAccountingContext(
            FEE_PROJECT_ID, address(feeProjectToken), uint32(uint160(address(feeProjectToken))), 18
        );

        _setDirectoryTerminal(PROJECT_ID, address(feeProjectToken), address(pullingTerminal));
        _setDirectoryTerminal(FEE_PROJECT_ID, address(feeProjectToken), address(pullingTerminal));
        terminal.setProjectToken(PROJECT_ID, address(projectToken));
        terminal.setProjectToken(FEE_PROJECT_ID, address(feeProjectToken));

        // Wire feeProjectToken for auto-select: add accounting context and set balance higher
        // than terminalToken so auto-select picks feeProjectToken as the terminal token.
        _addDirectoryTerminal(PROJECT_ID, address(pullingTerminal));
        store.setBalance(address(pullingTerminal), PROJECT_ID, address(feeProjectToken), 100e18);
        // Clear terminalToken balance so auto-select doesn't pick it
        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 0);
    }

    function test_FeeClaimsAreTrackedWhenTerminalTokenEqualsFeeProjectToken() public {
        projectToken.mint(address(hook), 100e18);

        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(PROJECT_ID, address(projectToken), 100e18, 1));

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(feeProjectToken));
        bool terminalIsToken0 = address(feeProjectToken) < address(projectToken);
        uint256 terminalFeeAmount = 100e18;

        if (terminalIsToken0) {
            positionManager.setCollectableFees(tokenId, terminalFeeAmount, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, terminalFeeAmount);
        }
        feeProjectToken.mint(address(positionManager), terminalFeeAmount);

        hook.collectAndRouteLPFees(PROJECT_ID, address(feeProjectToken));

        // Fee tokens should be properly tracked even when terminal token == fee project token.
        uint256 expectedFeeShare = (terminalFeeAmount * FEE_PERCENT) / hook.BPS();
        uint256 claimable = hook.claimableFeeTokens(PROJECT_ID);
        assertEq(claimable, expectedFeeShare, "fee tokens should be tracked correctly");

        // User can claim the fee tokens.
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);

        assertEq(feeProjectToken.balanceOf(user), expectedFeeShare, "user should receive the fee tokens");
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "claimable should be zeroed after claim");
    }
}
