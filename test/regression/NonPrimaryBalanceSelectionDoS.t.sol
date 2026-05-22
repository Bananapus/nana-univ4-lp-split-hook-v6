// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";

interface IStoreLike {
    function balanceOf(address terminal, uint256 projectId, address token) external view returns (uint256);
}

contract HighestValueSelectionHarness is JBUniswapV4LPSplitHook {
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IAllowanceTransfer permit2
    )
        JBUniswapV4LPSplitHook(directory, permissions, tokens, permit2, IJBSuckerRegistry(address(0)))
    {}

    function findHighestValueTerminalTokenOf(uint256 projectId, address controller) external view returns (address) {
        return _findHighestValueTerminalTokenOf(projectId, controller);
    }
}

contract StoreBackedCashOutTerminal {
    address public immutable ACCEPTED_TOKEN;
    address public immutable STORE_ADDRESS;

    constructor(address acceptedToken, address storeAddress) {
        ACCEPTED_TOKEN = acceptedToken;
        STORE_ADDRESS = storeAddress;
    }

    function STORE() external view returns (address) {
        return STORE_ADDRESS;
    }

    function accountingContextForTokenOf(uint256, address token) external pure returns (JBAccountingContext memory) {
        // Test terminals use the token address as the mock currency identifier.
        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: ACCEPTED_TOKEN, decimals: 18, currency: uint32(uint160(ACCEPTED_TOKEN))});
    }

    function cashOutTokensOf(
        address,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata,
        uint256 /* referralProjectId */
    )
        external
        returns (uint256 reclaimAmount)
    {
        uint256 available = IStoreLike(STORE_ADDRESS).balanceOf(address(this), projectId, tokenToReclaim);
        require(available != 0, "NO_BALANCE");

        reclaimAmount = cashOutCount / 2;
        if (reclaimAmount > available) reclaimAmount = available;

        MockERC20(tokenToReclaim).mint(beneficiary, reclaimAmount);
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

contract NonPrimaryBalanceSelectionDoSTest is LPSplitHookV4TestBase {
    uint256 internal constant PROJECT_B = 3;

    MockERC20 internal tokenB;
    StoreBackedCashOutTerminal internal primaryA;
    StoreBackedCashOutTerminal internal secondaryA;
    StoreBackedCashOutTerminal internal primaryB;
    HighestValueSelectionHarness internal harness;

    function setUp() public override {
        super.setUp();

        tokenB = new MockERC20("Token B", "TOKB", 18);

        primaryA = new StoreBackedCashOutTerminal(address(terminalToken), address(store));
        secondaryA = new StoreBackedCashOutTerminal(address(terminalToken), address(store));
        primaryB = new StoreBackedCashOutTerminal(address(tokenB), address(store));

        // The default mock terminal remains in the directory list from TestBase, so zero out its balance.
        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 0);

        _setDirectoryTerminal(PROJECT_ID, address(terminalToken), address(primaryA));
        _setDirectoryTerminal(PROJECT_ID, address(tokenB), address(primaryB));
        _addDirectoryTerminal(PROJECT_ID, address(primaryA));
        _addDirectoryTerminal(PROJECT_ID, address(secondaryA));
        _addDirectoryTerminal(PROJECT_ID, address(primaryB));

        // Same priced token on a non-primary terminal has the highest observed balance.
        store.setBalance(address(primaryA), PROJECT_ID, address(terminalToken), 0);
        store.setBalance(address(secondaryA), PROJECT_ID, address(terminalToken), 100e18);
        store.setBalance(address(primaryB), PROJECT_ID, address(tokenB), 10e18);

        HighestValueSelectionHarness harnessImpl = new HighestValueSelectionHarness(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(address(0x000000000022D473030F116dDEE9F6B43aC78BA3))
        );
        harness = HighestValueSelectionHarness(payable(LibClone.clone(address(harnessImpl))));
        harness.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0))
        });
    }

    function test_nonPrimaryBalancesDoNotOutrankUsablePrimaryBalances() public {
        address selected = harness.findHighestValueTerminalTokenOf(PROJECT_ID, address(controller));
        assertEq(selected, address(tokenB), "selection should ignore larger balances on non-primary terminals");

        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        assertTrue(hook.tokenIdOf(PROJECT_ID, address(tokenB)) != 0, "deploy should use the selected primary token");
    }
}
