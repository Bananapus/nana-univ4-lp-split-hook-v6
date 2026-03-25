// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice Wrapper contract that exposes internal native-ETH helper functions for testing.
contract TestableHookForETH is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(
            _directory, _permissions, _tokens, _poolManager, _positionManager, _permit2, IHooks(address(0))
        )
    {}

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_isNativeToken(address token) external pure returns (bool) {
        return _isNativeToken(token);
    }
}

/// @notice Tests for native ETH handling in JBUniswapV4LPSplitHook.
/// @dev In V4, native ETH uses Currency.wrap(address(0)) instead of WETH.
///      No WETH wrapping/unwrapping is needed.
contract NativeETHTest is LPSplitHookV4TestBase {
    TestableHookForETH public testableHook;
    address constant NATIVE_TOKEN = address(0x000000000000000000000000000000000000EEEe);

    function setUp() public override {
        super.setUp();

        testableHook = new TestableHookForETH(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(1)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(0))
        );
        testableHook.initialize(FEE_PROJECT_ID, FEE_PERCENT);
    }

    // -----------------------------------------------------------------------
    // 1. _isNativeToken returns true for JBConstants.NATIVE_TOKEN
    // -----------------------------------------------------------------------

    /// @notice NATIVE_TOKEN sentinel value must be recognized as native.
    function test_IsNativeToken_Correct() public view {
        assertTrue(testableHook.exposed_isNativeToken(NATIVE_TOKEN), "NATIVE_TOKEN should be identified as native");
    }

    // -----------------------------------------------------------------------
    // 2. _isNativeToken returns false for other addresses
    // -----------------------------------------------------------------------

    /// @notice Non-native addresses (including address(0), address(1), and real ERC20s) must return false.
    function test_IsNativeToken_OtherAddress() public view {
        assertFalse(testableHook.exposed_isNativeToken(address(terminalToken)), "ERC20 address should not be native");
        assertFalse(testableHook.exposed_isNativeToken(address(0)), "address(0) should not be native");
        assertFalse(testableHook.exposed_isNativeToken(address(1)), "address(1) should not be native");
    }

    // -----------------------------------------------------------------------
    // 3. JBConstants.NATIVE_TOKEN has the expected sentinel value
    // -----------------------------------------------------------------------

    /// @notice Guard against accidental changes to the sentinel constant.
    function test_NativeToken_ConstantValue() public pure {
        assertEq(
            JBConstants.NATIVE_TOKEN,
            address(0x000000000000000000000000000000000000EEEe),
            "JBConstants.NATIVE_TOKEN must be 0x...EEEe"
        );
    }

    // -----------------------------------------------------------------------
    // 4. Hook contract accepts direct ETH transfers (receive function)
    // -----------------------------------------------------------------------

    /// @notice The hook must have a payable receive() so that terminal cashOuts
    ///         can send ETH to the contract.
    function test_HookAcceptsETH() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertTrue(success, "Hook should accept ETH via receive()");
        assertEq(address(hook).balance, 1 ether, "Hook balance should reflect received ETH");
    }

    // -----------------------------------------------------------------------
    // 5. Full native-ETH deployment setup (accounting + accumulation)
    // -----------------------------------------------------------------------

    /// @notice Validate that a project configured with NATIVE_TOKEN as the
    ///         terminal token can wire up directory, accounting contexts,
    ///         accumulate tokens, and verify it is still pre-deployment.
    function test_DeployPool_WithNativeETH_Setup() public {
        // --- Wire the directory for NATIVE_TOKEN ---
        _setDirectoryTerminal(PROJECT_ID, NATIVE_TOKEN, address(terminal));

        // --- Add an accounting context for NATIVE_TOKEN (18 decimals, currency = sentinel) ---
        // Safe: NATIVE_TOKEN sentinel address is a known constant that fits in uint32.
        // forge-lint: disable-next-line(unsafe-typecast)
        terminal.setAccountingContext(PROJECT_ID, NATIVE_TOKEN, uint32(uint160(NATIVE_TOKEN)), 18);
        terminal.addAccountingContext(
            PROJECT_ID,
            // forge-lint: disable-next-line(unsafe-typecast)
            JBAccountingContext({token: NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(NATIVE_TOKEN))})
        );

        // --- Accumulate project tokens (simulates reserved-token split) ---
        uint256 accAmount = 100e18;
        projectToken.mint(address(hook), accAmount);

        // Build a split-hook context for reserved tokens (groupId = 1)
        // with the project token as the token field.
        vm.prank(address(controller));
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, accAmount));

        // Verify accumulation was recorded
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), accAmount, "Accumulated tokens should match minted amount");

        // Verify the project has not been deployed yet (no pool exists)
        assertFalse(
            hook.isPoolDeployed(PROJECT_ID, NATIVE_TOKEN), "Project should not be deployed yet (no deployPool called)"
        );
        assertFalse(hook.isPoolDeployed(PROJECT_ID, NATIVE_TOKEN), "No pool should exist for NATIVE_TOKEN yet");
    }

    // -----------------------------------------------------------------------
    // 6. Full native-ETH deployPool end-to-end
    // -----------------------------------------------------------------------

    /// @notice Full e2e: accumulate project tokens, then deployPool with NATIVE_TOKEN
    ///         as the terminal token. In V4, native ETH uses Currency.wrap(address(0))
    ///         so no WETH wrapping is needed.
    function test_DeployPool_NativeETH_EndToEnd() public {
        // Wire directory for NATIVE_TOKEN
        _setDirectoryTerminal(PROJECT_ID, NATIVE_TOKEN, address(terminal));
        _addDirectoryTerminal(PROJECT_ID, address(terminal));

        // Add accounting context for NATIVE_TOKEN
        // Safe: NATIVE_TOKEN sentinel address is a known constant that fits in uint32.
        // forge-lint: disable-next-line(unsafe-typecast)
        terminal.setAccountingContext(PROJECT_ID, NATIVE_TOKEN, uint32(uint160(NATIVE_TOKEN)), 18);
        terminal.addAccountingContext(
            PROJECT_ID,
            // forge-lint: disable-next-line(unsafe-typecast)
            JBAccountingContext({token: NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(NATIVE_TOKEN))})
        );

        // Set NATIVE_TOKEN as the terminal token for cash-outs
        terminal.setProjectToken(PROJECT_ID, address(projectToken));

        // Accumulate project tokens
        uint256 accAmount = 100e18;
        projectToken.mint(address(hook), accAmount);

        vm.prank(address(controller));
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, accAmount));

        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), accAmount);

        // Fund the mock terminal with ETH so cash-out can send native ETH
        vm.deal(address(terminal), 100 ether);

        // Deploy pool with NATIVE_TOKEN (owner required)
        // In V4, the hook uses Currency.wrap(address(0)) for native ETH
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, NATIVE_TOKEN, 0);

        // Verify pool was created (tokenId is nonzero)
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, NATIVE_TOKEN);
        assertTrue(tokenId != 0, "tokenIdOf should be nonzero after deploy");

        // Verify PositionManager was called
        assertEq(positionManager.mintCallCount(), 1, "PositionManager mint should be called once");

        // Verify accumulated tokens were cleared
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "Accumulated should be 0 after deploy");

        // Verify project is marked deployed
        assertTrue(hook.isPoolDeployed(PROJECT_ID, NATIVE_TOKEN), "projectDeployed should be true after deploy");
    }
}
