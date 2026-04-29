// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";

/// @notice Test harness that exposes the internal `_findHighestValueTerminalTokenOf` function.
contract FindHighestValueHarness is JBUniswapV4LPSplitHook {
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IPoolManager poolManager,
        IPositionManager positionManager,
        IAllowanceTransfer permit2,
        IHooks oracleHook
    )
        JBUniswapV4LPSplitHook(directory, permissions, tokens, poolManager, positionManager, permit2, oracleHook)
    {}

    /// @notice Public wrapper around the internal function for testing.
    function findHighestValueTerminalTokenOf(uint256 projectId, address controller) external view returns (address) {
        return _findHighestValueTerminalTokenOf(projectId, controller);
    }
}

/// @title Unpriced tokens should be skipped, not compared by raw balance
/// @notice Proves that a token without a price feed must not win the highest-value
///         comparison just because it has a large raw balance.
contract UnpricedTokenSkipTest is LPSplitHookV4TestBase {
    MockERC20 internal tokenB;
    FindHighestValueHarness internal harness;

    uint32 internal tokenBCurrency;

    function setUp() public override {
        super.setUp();

        // --- Deploy tokenB (an ERC-20 with no price feed) ---------------
        tokenB = new MockERC20("Token B", "TOKB", 18);
        tokenBCurrency = uint32(uint160(address(tokenB)));

        // Register tokenB as an accounting context on the existing terminal.
        terminal.setAccountingContext(PROJECT_ID, address(tokenB), tokenBCurrency, 18);
        terminal.addAccountingContext(
            PROJECT_ID, JBAccountingContext({token: address(tokenB), decimals: 18, currency: tokenBCurrency})
        );

        // --- Set balances ------------------------------------------------
        // tokenA (terminalToken): small balance = 1 ETH worth.
        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 1e18);

        // tokenB: very large raw balance = 1000 units (no price feed, so
        // under the old code this raw balance is used directly and wins).
        store.setBalance(address(terminal), PROJECT_ID, address(tokenB), 1000e18);

        // --- Configure price feeds ---------------------------------------
        // terminalToken has a valid 1:1 price vs ETH.
        uint32 terminalTokenCurrency = uint32(uint160(address(terminalToken)));
        uint32 ethCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));
        prices.setPrice(PROJECT_ID, terminalTokenCurrency, ethCurrency, 1e18);

        // Make MockJBPrices.pricePerUnitOf REVERT when called for tokenB's
        // currency. This simulates "no price feed available".
        bytes memory revertSelector = abi.encodeWithSignature(
            "pricePerUnitOf(uint256,uint256,uint256,uint256)",
            PROJECT_ID,
            uint256(tokenBCurrency),
            uint256(ethCurrency),
            uint256(18)
        );
        vm.mockCallRevert(address(prices), revertSelector, "NO_FEED");

        // --- Deploy the harness ------------------------------------------
        FindHighestValueHarness harnessImpl = new FindHighestValueHarness(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(address(0x000000000022D473030F116dDEE9F6B43aC78BA3)),
            IHooks(address(0))
        );
        harness = FindHighestValueHarness(payable(LibClone.clone(address(harnessImpl))));
        harness.initialize(FEE_PROJECT_ID, FEE_PERCENT);
    }

    /// @notice Before the fix: tokenB (1000e18 raw) wins over tokenA (1e18 priced).
    ///         After the fix:  tokenB is skipped; tokenA wins.
    function test_unpricedTokenIsSkipped() public view {
        address winner = harness.findHighestValueTerminalTokenOf(PROJECT_ID, address(controller));

        assertEq(
            winner,
            address(terminalToken),
            "priced token (terminalToken) must win over unpriced token with large raw balance"
        );
    }
}
