// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
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
import {MockERC20} from "../mock/MockERC20.sol";

/// @notice Test harness that exposes the internal `_findHighestValueTerminalTokenOf` function.
contract FindHighestValueHarness is JBUniswapV4LPSplitHook {
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IAllowanceTransfer permit2
    )
        JBUniswapV4LPSplitHook(directory, permissions, tokens, permit2, IJBSuckerRegistry(address(0)))
    {}

    /// @notice Public wrapper around the internal function for testing.
    function findHighestValueTerminalTokenOf(uint256 projectId, address controller) external view returns (address) {
        return
            JBUniswapV4LPSplitHookMath.findHighestValueTerminalTokenOf(IJBDirectory(DIRECTORY), projectId, controller);
    }
}

/// @title Unpriced tokens should be skipped, not compared by raw balance
/// @notice Proves that a token without a price feed must not win the highest-value
///         comparison just because it has a large raw balance.
contract UnpricedTokenSkipTest is LPSplitHookV4TestBase {
    MockERC20 internal tokenB;
    MockERC20 internal sixDecimalToken;
    FindHighestValueHarness internal harness;

    uint32 internal tokenBCurrency;
    uint32 internal sixDecimalTokenCurrency;

    function setUp() public override {
        super.setUp();

        // --- Deploy tokenB (an ERC-20 with no price feed) ---------------
        tokenB = new MockERC20("Token B", "TOKB", 18);
        tokenBCurrency = uint32(uint160(address(tokenB)));

        sixDecimalToken = new MockERC20("Six Decimal Token", "SIX", 6);
        sixDecimalTokenCurrency = uint32(uint160(address(sixDecimalToken)));

        // Register tokenB as an accounting context on the existing terminal.
        terminal.setAccountingContext(PROJECT_ID, address(tokenB), tokenBCurrency, 18);
        terminal.addAccountingContext(
            PROJECT_ID, JBAccountingContext({token: address(tokenB), decimals: 18, currency: tokenBCurrency})
        );
        terminal.setAccountingContext(PROJECT_ID, address(sixDecimalToken), sixDecimalTokenCurrency, 6);
        terminal.addAccountingContext(
            PROJECT_ID,
            JBAccountingContext({token: address(sixDecimalToken), decimals: 6, currency: sixDecimalTokenCurrency})
        );
        _setDirectoryTerminal(PROJECT_ID, address(tokenB), address(terminal));
        _setDirectoryTerminal(PROJECT_ID, address(sixDecimalToken), address(terminal));

        // --- Set balances ------------------------------------------------
        // tokenA (terminalToken): small balance = 1 ETH worth.
        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 1e18);

        // tokenB: very large raw balance = 1000 units (no price feed, so
        // it must still lose to any token with a real price feed).
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

    /// @notice Priced tokens win over unpriced tokens even when the unpriced token has a larger raw balance.
    function test_unpricedTokenIsSkipped() public view {
        address winner = harness.findHighestValueTerminalTokenOf(PROJECT_ID, address(controller));

        assertEq(
            winner,
            address(terminalToken),
            "priced token (terminalToken) must win over unpriced token with large raw balance"
        );
    }

    /// @notice If every candidate is unpriced, the fallback compares token balances after decimal normalization.
    function test_unpricedFallbackNormalizesTokenDecimals() public {
        uint32 ethCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));
        uint32 terminalTokenCurrency = uint32(uint160(address(terminalToken)));

        bytes memory terminalTokenCall = abi.encodeWithSignature(
            "pricePerUnitOf(uint256,uint256,uint256,uint256)",
            PROJECT_ID,
            uint256(terminalTokenCurrency),
            uint256(ethCurrency),
            uint256(18)
        );
        vm.mockCallRevert(address(prices), terminalTokenCall, "NO_FEED");

        bytes memory tokenBCall = abi.encodeWithSignature(
            "pricePerUnitOf(uint256,uint256,uint256,uint256)",
            PROJECT_ID,
            uint256(tokenBCurrency),
            uint256(ethCurrency),
            uint256(18)
        );
        vm.mockCallRevert(address(prices), tokenBCall, "NO_FEED");

        bytes memory sixDecimalTokenCall = abi.encodeWithSignature(
            "pricePerUnitOf(uint256,uint256,uint256,uint256)",
            PROJECT_ID,
            uint256(sixDecimalTokenCurrency),
            uint256(ethCurrency),
            uint256(6)
        );
        vm.mockCallRevert(address(prices), sixDecimalTokenCall, "NO_FEED");

        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 1e18);
        store.setBalance(address(terminal), PROJECT_ID, address(tokenB), 2e18);
        store.setBalance(address(terminal), PROJECT_ID, address(sixDecimalToken), 1000e6);

        address winner = harness.findHighestValueTerminalTokenOf(PROJECT_ID, address(controller));

        assertEq(
            winner,
            address(sixDecimalToken),
            "six-decimal token should win by normalized units, not lose by raw balance"
        );
    }
}
