// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

/// @notice Wrapper contract that exposes internal native-ETH helper functions for testing.
contract TestableHookForETH is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(_directory, _permissions, _tokens, _permit2, IJBSuckerRegistry(address(0)))
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
            address(directory), IJBPermissions(address(permissions)), address(jbTokens), IAllowanceTransfer(address(0))
        );
        testableHook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(1)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });
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
        projectToken.mint(address(controller), accAmount);

        // Build a split-hook context for reserved tokens (groupId = 1)
        // with the project token as the token field.
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), accAmount);
        // Deliver with intake-only gas so the hook runs intake and skips inline automation.
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildReservedContext({projectId: PROJECT_ID, amount: accAmount}));
        vm.stopPrank();

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
        // Make native ETH the project's highest-value terminal token so deployPool auto-selects it.
        _wireNativeTerminal();

        // Mint the project tokens the controller distributes as a reserved split.
        uint256 accAmount = 100e18;
        projectToken.mint({to: address(controller), amount: accAmount});

        // The controller approves and delivers the split; the deploy below stays an explicit call.
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: accAmount});
        // Deliver with intake-only gas so the hook runs intake and skips inline automation.
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildReservedContext({projectId: PROJECT_ID, amount: accAmount}));
        vm.stopPrank();

        // The whole delivery is ledgered before any deploy.
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), accAmount);

        // Fund the mock terminal with ETH so a native cash-out could pay out.
        vm.deal(address(terminal), 100 ether);

        // Deploy the pool; the hook pairs the project token with Currency.wrap(address(0)) for native ETH.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // The deploy mints a native ask position.
        uint256 tokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: NATIVE_TOKEN});
        assertNotEq(tokenId, 0, "tokenIdOf should be nonzero after deploy");

        // Exactly one PositionManager mint funds the ask.
        assertEq(positionManager.mintCallCount(), 1, "PositionManager mint should be called once");

        // The accumulated tokens are placed: only V4 rounding stays ledgered.
        _assertPlacedExactly({
            projectId: PROJECT_ID,
            projectTokenAddr: address(projectToken),
            terminalTokenAddr: NATIVE_TOKEN,
            projectIn: accAmount,
            terminalIn: 0
        });

        // The project records native ETH as its deployed pairing.
        assertTrue(
            hook.isPoolDeployed({projectId: PROJECT_ID, terminalToken: NATIVE_TOKEN}),
            "projectDeployed should be true after deploy"
        );
    }

    // -----------------------------------------------------------------------
    // 7. A native recycle sweeps the PositionManager's loose ETH back to the hook
    // -----------------------------------------------------------------------

    /// @notice Like V4's, the PositionManager's native SWEEP returns its whole loose ETH balance (here a balance left
    /// on it plus whatever the bid's settle did not use) to the hook; the PositionManager keeps only pool reserves. The
    /// loose balance is kept below the bid's cost, so the hook's balance-delta accounting ledgers all of it.
    function test_Recycle_NativeSweepReturnsLooseEth() public {
        // Deploy a native ask from accumulated project tokens.
        _wireNativeTerminal();
        _accumulateTokens({projectId: PROJECT_ID, amount: 100e18});
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // Buyers fill part of the ask with ETH, which the recycle recovers and re-mints as a native bid.
        (uint256 recoveredEth,) = _fillHalfOf(hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: NATIVE_TOKEN}));

        // Leave loose ETH on the PositionManager, below the bid's cost, for the sweep to return.
        uint256 looseEth = recoveredEth / 4;
        vm.deal(address(positionManager), address(positionManager).balance + looseEth);
        uint256 hookEthBefore = address(hook).balance;

        // Recycle: burn the filled ask, then re-mint the recovered ETH as a bid.
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: NATIVE_TOKEN});

        // The recovered ETH funds a native bid whose exact cost is read at the live spot.
        uint256 bidId = hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: NATIVE_TOKEN});
        assertNotEq(bidId, 0, "the recovered ETH mints a native bid");
        (uint256 bidCost,) = _mintCostAtSpot(bidId);

        // Source: the PositionManager keeps only the pool's reserves.
        assertEq(
            address(positionManager).balance,
            positionManager.poolLocked(address(0)),
            "the PositionManager keeps no loose ETH"
        );

        // Destination: the hook gets back everything but the bid's exact cost, plus the swept loose ETH.
        assertEq(
            address(hook).balance,
            hookEthBefore + recoveredEth - bidCost + looseEth,
            "the hook received the unused bid ETH and the swept balance"
        );

        // The terminal ledger carries every unplaced wei, including the swept balance.
        assertEq(
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: NATIVE_TOKEN}),
            recoveredEth - bidCost + looseEth,
            "the swept ETH is carried in the terminal ledger"
        );
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// @notice Make native ETH `PROJECT_ID`'s highest-value terminal token.
    function _wireNativeTerminal() internal {
        // Route NATIVE_TOKEN payments for the project to the mock terminal.
        _setDirectoryTerminal({projectId: PROJECT_ID, token: NATIVE_TOKEN, term: address(terminal)});
        _addDirectoryTerminal({projectId: PROJECT_ID, term: address(terminal)});

        // Give the terminal an 18-decimal NATIVE_TOKEN accounting context whose currency is the sentinel address.
        // The truncating casts are intended: a token's JB currency is the low 32 bits of its address.
        terminal.setAccountingContext({
            projectId: PROJECT_ID,
            token: NATIVE_TOKEN,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(NATIVE_TOKEN)),
            decimals: 18
        });
        terminal.addAccountingContext({
            projectId: PROJECT_ID,
            // forge-lint: disable-next-line(unsafe-typecast)
            ctx: JBAccountingContext({token: NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(NATIVE_TOKEN))})
        });

        // Tell the terminal which project token its cash-outs burn.
        terminal.setProjectToken({projectId: PROJECT_ID, token: address(projectToken)});

        // Give NATIVE_TOKEN the larger balance so auto-select picks it over the base terminalToken.
        store.setBalance({terminal: address(terminal), projectId: PROJECT_ID, token: NATIVE_TOKEN, balance: 100e18});
    }
}
