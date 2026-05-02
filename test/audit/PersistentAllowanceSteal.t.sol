// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {
    MockJBDirectory,
    MockJBMultiTerminal,
    MockJBPermissions,
    MockJBProjects,
    MockJBTokens
} from "../mock/MockJBContracts.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract AllowanceHarness is JBUniswapV4LPSplitHook {
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IPoolManager poolManager,
        IPositionManager positionManager,
        IAllowanceTransfer permit2
    )
        JBUniswapV4LPSplitHook(
            directory, permissions, tokens, poolManager, positionManager, permit2, IHooks(address(0))
        )
    {}

    function exposed_addToProjectBalance(uint256 projectId, address token, uint256 amount, bool isNative) external {
        _addToProjectBalance(projectId, token, amount, isNative);
    }
}

contract PersistentAllowanceStealTest is Test {
    uint256 internal constant PROJECT_ID = 1;

    AllowanceHarness internal hook;
    MockJBDirectory internal directory;
    MockJBProjects internal projects;
    MockJBPermissions internal permissions;
    MockJBMultiTerminal internal terminal;
    MockJBTokens internal tokens;
    MockERC20 internal terminalToken;

    function setUp() public {
        directory = new MockJBDirectory();
        projects = new MockJBProjects();
        permissions = new MockJBPermissions();
        terminal = new MockJBMultiTerminal();
        tokens = new MockJBTokens();
        terminalToken = new MockERC20("Terminal", "TERM", 18);

        directory.setProjects(address(projects));
        directory.setTerminal(PROJECT_ID, address(terminalToken), address(terminal));
        projects.setOwner(PROJECT_ID, makeAddr("owner"));

        hook = new AllowanceHarness(
            address(directory),
            IJBPermissions(address(permissions)),
            address(tokens),
            IPoolManager(address(0xBEEF)),
            IPositionManager(address(0xCAFE)),
            IAllowanceTransfer(address(0xF00D))
        );
    }

    function test_revertsIfTerminalKeepsTemporaryAllowance() public {
        uint256 forwardedAmount = 100e18;
        terminalToken.mint(address(hook), forwardedAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed.selector,
                address(terminalToken),
                address(terminal),
                forwardedAmount
            )
        );
        hook.exposed_addToProjectBalance(PROJECT_ID, address(terminalToken), forwardedAmount, false);

        assertEq(terminalToken.allowance(address(hook), address(terminal)), 0, "revert unwinds temporary allowance");
    }
}
