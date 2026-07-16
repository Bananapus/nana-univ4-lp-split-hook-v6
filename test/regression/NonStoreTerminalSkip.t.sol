// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";

/// @notice Test harness exposing the internal terminal-selection helper.
contract FindHighestValueHarness is JBUniswapV4LPSplitHook {
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IAllowanceTransfer permit2
    )
        JBUniswapV4LPSplitHook(directory, permissions, tokens, permit2, IJBSuckerRegistry(address(0)))
    {}

    function findHighestValueTerminalTokenOf(uint256 projectId, address controller) external view returns (address) {
        return
            JBUniswapV4LPSplitHookMath.findHighestValueTerminalTokenOf(IJBDirectory(DIRECTORY), projectId, controller);
    }
}

/// @notice A terminal that holds no balances of its own and reverts on `STORE()` — mirrors the
///         `JBRouterTerminalRegistry`, which forwards to per-token terminals and is registered in many projects'
///         terminal sets. Any call reverts with empty data via the reverting fallback.
contract NonStoreTerminal {
    fallback() external payable {
        revert();
    }
}

/// @title Non-store terminals in a project's terminal set must be skipped, not fatal
/// @notice Regression for the DoS where `findHighestValueTerminalTokenOf` cast every terminal to
///         `IJBMultiTerminal` and called `STORE()` unguarded. A single terminal without a store (e.g. the router
///         terminal registry) reverted the whole call, permanently bricking `deployPool` / `addLiquidity` for any
///         project that had one registered. Verified against Base Sepolia project #11, whose terminal set was
///         `[JBMultiTerminal, JBRouterTerminalRegistry]`.
contract NonStoreTerminalSkipTest is LPSplitHookV4TestBase {
    FindHighestValueHarness internal harness;
    NonStoreTerminal internal routerLikeTerminal;

    function setUp() public override {
        super.setUp();

        // The base already registers the real `terminal` (holding `terminalToken`) as the project's terminal and
        // gives it a 10e18 balance. Give `terminalToken` a 1:1 ETH price so it is a valid, priced candidate.
        uint32 terminalTokenCurrency = uint32(uint160(address(terminalToken)));
        uint32 ethCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));
        prices.setPrice(PROJECT_ID, terminalTokenCurrency, ethCurrency, 1e18);

        // Register a second, store-less terminal in the project's terminal set — exactly the shape that DoS'd the
        // hook in production (the router terminal registry sitting beside the real multi-terminal).
        routerLikeTerminal = new NonStoreTerminal();
        _addDirectoryTerminal(PROJECT_ID, address(routerLikeTerminal));

        FindHighestValueHarness harnessImpl = new FindHighestValueHarness(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(address(0x000000000022D473030F116dDEE9F6B43aC78BA3))
        );
        harness = FindHighestValueHarness(payable(LibClone.clone(address(harnessImpl))));
        harness.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });
    }

    /// @notice Selection succeeds and returns the real terminal's token even though a store-less terminal sits in
    ///         the project's terminal set. Before the fix this call reverted (empty data), DoSing pool deployment.
    function test_nonStoreTerminalIsSkipped() public view {
        address winner = harness.findHighestValueTerminalTokenOf(PROJECT_ID, address(controller));
        assertEq(winner, address(terminalToken), "must skip the store-less terminal and pick the real one");
    }
}
