// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {MockERC20} from "../mock/MockERC20.sol";

/// @notice Wrapper that exposes _getCashOutRate so the test can verify it queries the terminal store with the
/// declared accounting-context currency, not the token-derived `uint32(uint160(token))`.
contract TestableHookForCurrencyParity is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IAllowanceTransfer _permit2
    )
        JBUniswapV4LPSplitHook(_directory, _permissions, _tokens, _permit2, IJBSuckerRegistry(address(0)))
    {}

    function _fetchControllerAndRuleset(uint256 projectId)
        internal
        view
        returns (address controller, JBRuleset memory ruleset)
    {
        controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (ruleset,) = IJBController(controller).currentRulesetOf(projectId);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getCashOutRate(uint256 projectId, address terminalToken) external view returns (uint256) {
        (address controller, JBRuleset memory ruleset) = _fetchControllerAndRuleset(projectId);
        return
            _getCashOutRate({
                projectId: projectId, terminalToken: terminalToken, controller: controller, ruleset: ruleset
            });
    }
}

/// @notice Regression test: cash-out rate must read the terminal's declared `accountingContextForTokenOf.currency`
/// to match issuance. Previously `_getCashOutRate` used `uint32(uint160(terminalToken))` directly, which diverged
/// from issuance whenever a project's accounting context declared a different currency for the token (e.g. a
/// USDC token configured under a USD identity).
contract CashOutCurrencyParityTest is LPSplitHookV4TestBase {
    TestableHookForCurrencyParity public testableHook;

    MockERC20 public terminalTokenA;
    MockERC20 public projectTokenA;

    uint256 public constant TEST_PROJECT_ID = 42;

    /// @dev A currency identifier different from `uint32(uint160(terminalToken))`. Pre-fix `_getCashOutRate` used
    /// the token-derived value; the fix now reads this declared currency from `accountingContextForTokenOf`.
    uint32 internal constant DECLARED_CURRENCY = 0xCAFEBEEF;

    function setUp() public override {
        super.setUp();

        testableHook = new TestableHookForCurrencyParity({
            _directory: address(directory),
            _permissions: IJBPermissions(address(permissions)),
            _tokens: address(jbTokens),
            _permit2: IAllowanceTransfer(address(0))
        });
        testableHook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(1)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0))
        });

        terminalTokenA = new MockERC20("TerminalA", "TKA", 18);
        projectTokenA = new MockERC20("ProjectA", "PJA", 18);

        _setDirectoryController({projectId: TEST_PROJECT_ID, ctrl: address(controller)});
        controller.setWeight(TEST_PROJECT_ID, DEFAULT_WEIGHT);
        controller.setFirstWeight(TEST_PROJECT_ID, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(TEST_PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(TEST_PROJECT_ID, DECLARED_CURRENCY);

        jbProjects.setOwner({tokenId: TEST_PROJECT_ID, owner: owner});
        jbTokens.setToken({projectId: TEST_PROJECT_ID, token: address(projectTokenA)});

        _setDirectoryTerminal({projectId: TEST_PROJECT_ID, token: address(terminalTokenA), term: address(terminal)});
        _addDirectoryTerminal({projectId: TEST_PROJECT_ID, term: address(terminal)});

        // Declare a currency that is INTENTIONALLY different from `uint32(uint160(terminalTokenA))`.
        terminal.setAccountingContext({
            projectId: TEST_PROJECT_ID, token: address(terminalTokenA), currency: DECLARED_CURRENCY, decimals: 18
        });
        terminal.addAccountingContext({
            projectId: TEST_PROJECT_ID,
            ctx: JBAccountingContext({token: address(terminalTokenA), decimals: 18, currency: DECLARED_CURRENCY})
        });

        store.setSurplus({projectId: TEST_PROJECT_ID, surplus: 0.5e18});
        store.setBalance({
            terminal: address(terminal), projectId: TEST_PROJECT_ID, token: address(terminalTokenA), balance: 10e18
        });
    }

    /// @notice `_getCashOutRate` must call the terminal store with the project's declared currency, not the
    /// token-derived value. We use `vm.expectCall` to assert the precise arguments.
    function test_cashOutRate_queriesStoreWithAccountingContextCurrency() public {
        // The hook reads the project's accounting context, then calls
        // store.currentTotalReclaimableSurplusOf(projectId, _WAD, decimals=18, currency=DECLARED_CURRENCY).
        // (scopeCashOutsToLocalBalances defaults to true in MockJBRulesets — see TestBaseV4 setup.)
        vm.expectCall({
            callee: address(store),
            data: abi.encodeWithSignature(
                "currentTotalReclaimableSurplusOf(uint256,uint256,uint256,uint256)",
                TEST_PROJECT_ID,
                uint256(1e18),
                uint256(18),
                uint256(DECLARED_CURRENCY)
            )
        });
        testableHook.exposed_getCashOutRate({projectId: TEST_PROJECT_ID, terminalToken: address(terminalTokenA)});
    }
}
