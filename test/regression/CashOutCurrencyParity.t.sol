// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
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
import {MockJBMultiTerminal, MockJBTerminalStore} from "../mock/MockJBContracts.sol";
import {IJBUniswapV4LPSplitHook} from "../../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

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
        return JBUniswapV4LPSplitHookMath.getCashOutRate({
            directory: IJBDirectory(DIRECTORY),
            suckerRegistry: SUCKER_REGISTRY,
            projectId: projectId,
            terminalToken: terminalToken,
            controller: controller,
            ruleset: ruleset
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
            newOracleHook: IHooks(address(0)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
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

    /// @notice `_getCashOutRate` must ask each of the project's terminals for its surplus in the project's declared
    /// currency, not the token-derived value. We use `vm.expectCall` to assert the precise arguments.
    function test_cashOutRate_queriesStoreWithAccountingContextCurrency() public {
        // The hook reads the project's accounting context, then sums
        // terminal.currentSurplusOf(projectId, [], decimals=18, currency=DECLARED_CURRENCY) across its terminals.
        vm.expectCall({
            callee: address(terminal),
            data: abi.encodeCall(
                IJBTerminal.currentSurplusOf,
                (TEST_PROJECT_ID, new address[](0), uint256(18), uint256(DECLARED_CURRENCY))
            )
        });
        testableHook.exposed_getCashOutRate({projectId: TEST_PROJECT_ID, terminalToken: address(terminalTokenA)});
    }
}

/// @notice Regression: the cash-out floor counts surplus across all of the project's local terminals, the way the
/// terminal store sums it at settlement, so terminals backed by different stores all count. Previewing only the
/// primary terminal's store undercounts the floor and lets asks sell below what a cash-out settles for.
/// @dev The primary store holds 100 terminal tokens of surplus and a second local terminal, on its own store, holds
/// 900, against a supply of 1000e18 and no tax: a 1e18 burn settles for 1 terminal token, while the primary store
/// alone previews 0.1. The issuance price is 2 terminal tokens per project token, so the corridor is
/// [1 + 2e-18, 2] in project price: [200, 6800] with the project as token0, [-6800, -200] as token1.
contract CashOutAllTerminalsTest is LPSplitHookV4TestBase {
    address internal constant NATIVE = JBConstants.NATIVE_TOKEN;

    // Controlled project-token addresses on both sides of the ERC-20 terminal token (the native sentinel sorts below
    // both, so a native pair always has the project as token1).
    address internal lowProjectToken;
    address internal highProjectToken;
    MockJBTerminalStore internal secondStore;
    MockJBMultiTerminal internal secondTerminal;

    function setUp() public override {
        super.setUp();
        lowProjectToken = address(uint160(address(terminalToken)) - 1);
        highProjectToken = address(uint160(address(terminalToken)) + 1);

        // Issuance price 2 terminal tokens per project token.
        controller.setWeight(PROJECT_ID, 0.5e18);
        controller.setReservedPercent(PROJECT_ID, 0);

        // The primary terminal also accepts native ETH.
        _setDirectoryTerminal(PROJECT_ID, NATIVE, address(terminal));
        // forge-lint: disable-next-line(unsafe-typecast)
        terminal.setAccountingContext(PROJECT_ID, NATIVE, uint32(uint160(NATIVE)), 18);

        // The primary store previews reclaims from the surplus and supply the hook passes, as the real store does.
        store.setUseProvidedCashOutInputs(true);
        store.setSurplus(PROJECT_ID, 100e18);
        // What the primary store alone previews for a 1e18 burn: its own 100 of surplus over the 1000e18 supply.
        vm.mockCall(
            address(store),
            abi.encodeWithSelector(MockJBTerminalStore.currentTotalReclaimableSurplusOf.selector),
            abi.encode(uint256(0.1e18))
        );

        // A second local terminal on its own store holds the other 900.
        secondStore = new MockJBTerminalStore();
        secondStore.setSurplus(PROJECT_ID, 900e18);
        secondTerminal = new MockJBMultiTerminal();
        secondTerminal.setStore(address(secondStore));
        _addDirectoryTerminal(PROJECT_ID, address(secondTerminal));
    }

    function _rate(address token) internal view returns (uint256) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        return JBUniswapV4LPSplitHookMath.getCashOutRate({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: token,
            controller: address(controller),
            ruleset: ruleset
        });
    }

    function _bounds(address token, address projectTokenAddr) internal view returns (int24, int24) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        return JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: token,
            projectToken: projectTokenAddr,
            controller: address(controller),
            ruleset: ruleset
        });
    }

    function _assertSettlementFloor(address token, address projectTokenAddr, bool projectIsToken0) internal view {
        assertEq(_rate(token), 1e18, "the floor counts every local terminal's surplus");
        (int24 lower, int24 upper) = _bounds(token, projectTokenAddr);
        assertEq(lower, projectIsToken0 ? int24(200) : int24(-6800), "corridor lower");
        assertEq(upper, projectIsToken0 ? int24(6800) : int24(-200), "corridor upper");
    }

    function test_cashOutRate_countsEveryTerminal_ProjectToken0() public view {
        _assertSettlementFloor(address(terminalToken), lowProjectToken, true);
    }

    function test_cashOutRate_countsEveryTerminal_ProjectToken1() public view {
        _assertSettlementFloor(address(terminalToken), highProjectToken, false);
    }

    function test_cashOutRate_countsEveryTerminal_NativeCurrency0() public view {
        _assertSettlementFloor(NATIVE, highProjectToken, false);
    }

    /// @notice A failing surplus or reclaim preview reverts the bounds rather than reading as a zero floor: the
    /// recycle reverts, while a distribution's inline automation fails softly and keeps the intake.
    function test_failingPreview_revertsBounds_inlineKeepsIntake() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        vm.mockCallRevert(
            address(store),
            abi.encodeWithSelector(MockJBTerminalStore.currentTotalReclaimableSurplusOf.selector),
            bytes("preview down")
        );
        vm.mockCallRevert(
            address(store),
            abi.encodeWithSignature("currentReclaimableSurplusOf(uint256,uint256,uint256,uint256)"),
            bytes("preview down")
        );

        vm.expectRevert(bytes("preview down"));
        this.rateOf(address(terminalToken));

        vm.expectRevert(bytes("preview down"));
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        uint256 ledgerBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        projectToken.mint(address(controller), 1e18);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), 1e18);
        vm.expectEmit(true, false, false, false, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed(PROJECT_ID, bytes4(0), address(controller));
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, 1e18));
        vm.stopPrank();
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), ledgerBefore + 1e18, "the intake is kept");
    }

    /// @notice A failing surplus read on ANY local terminal reverts the rate and the bounds rather than counting that
    /// terminal as zero surplus, even while the primary terminal's surplus and the reclaim preview stay healthy. A
    /// recycle reverts and leaves the live position and both ledgers untouched, while a distribution's inline
    /// automation fails softly and keeps the intake.
    function _runFailingSecondarySurplus(address token) internal {
        if (token == NATIVE) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32 nativeCurrency = uint32(uint160(NATIVE));
            terminal.addAccountingContext(
                PROJECT_ID, JBAccountingContext({token: NATIVE, decimals: 18, currency: nativeCurrency})
            );
            store.setBalance(address(terminal), PROJECT_ID, NATIVE, 10e18);
            store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 0);
        }
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        uint256 askId = hook.askTokenIdOf(PROJECT_ID, token);
        assertNotEq(askId, 0, "precondition: the deployed ask is live");
        uint128 liquidity = positionManager.getPositionLiquidity(askId);
        uint256 projectLedger = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 terminalLedger = hook.accumulatedTerminalTokens(PROJECT_ID, token);

        vm.mockCallRevert(
            address(secondTerminal),
            abi.encodeWithSelector(IJBTerminal.currentSurplusOf.selector),
            bytes("surplus down")
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 currency = uint32(uint160(token));
        assertEq(
            terminal.currentSurplusOf(PROJECT_ID, new address[](0), 18, currency),
            100e18,
            "precondition: the primary terminal's surplus is healthy"
        );

        vm.expectRevert(bytes("surplus down"));
        this.rateOf(token);
        vm.expectRevert(bytes("surplus down"));
        this.boundsOf(token, address(projectToken));
        vm.expectRevert(bytes("surplus down"));
        hook.addLiquidity(PROJECT_ID, token);

        assertEq(hook.askTokenIdOf(PROJECT_ID, token), askId, "the ask is kept");
        assertEq(hook.bidTokenIdOf(PROJECT_ID, token), 0, "no bid appears");
        assertEq(positionManager.getPositionLiquidity(askId), liquidity, "the ask keeps its liquidity");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), projectLedger, "the project ledger is unchanged");
        assertEq(hook.accumulatedTerminalTokens(PROJECT_ID, token), terminalLedger, "the terminal ledger is unchanged");

        projectToken.mint(address(controller), 1e18);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), 1e18);
        vm.expectEmit(true, false, false, false, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed(PROJECT_ID, bytes4(0), address(controller));
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, 1e18));
        vm.stopPrank();
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), projectLedger + 1e18, "the intake is kept");
        assertEq(hook.askTokenIdOf(PROJECT_ID, token), askId, "the ask is still kept");
    }

    function test_failingSecondarySurplus_revertsBounds_inlineKeepsIntake() public {
        _runFailingSecondarySurplus(address(terminalToken));
    }

    function test_failingSecondarySurplus_revertsBounds_inlineKeepsIntake_Native() public {
        _runFailingSecondarySurplus(NATIVE);
    }

    /// @notice External wrapper so `vm.expectRevert` can catch a library revert.
    function rateOf(address token) external view returns (uint256) {
        return _rate(token);
    }

    /// @notice External wrapper so `vm.expectRevert` can catch a library revert.
    function boundsOf(address token, address projectTokenAddr) external view returns (int24, int24) {
        return _bounds(token, projectTokenAddr);
    }

    /// @notice With less than one whole token of supply, a preview whose scaled-up rate is representable scales
    /// exactly even when the plain product overflows: 1e60 reclaimed by a 1e17 supply is 1e61 per 1e18 tokens, though
    /// 1e60 * 1e18 exceeds 2^256.
    function test_partialSupplyPreview_scalesPastAnOverflowingProduct() public {
        controller.setTotalTokenSupplyWithReservedTokensOf(PROJECT_ID, 1e17);
        vm.mockCall(
            address(store),
            abi.encodeWithSignature("currentReclaimableSurplusOf(uint256,uint256,uint256,uint256)"),
            abi.encode(uint256(1e60))
        );
        assertEq(_rate(address(terminalToken)), 1e61, "the preview scales exactly");
        assertEq(_rate(NATIVE), 1e61, "the preview scales exactly: native");
    }

    /// @notice With less than one whole token of supply, scaling the preview up to 1e18 tokens saturates instead of
    /// overflowing, and the saturated floor leaves an empty corridor rather than a revert, in either ordering and for
    /// a native terminal token.
    function _runSaturation(address token, address projectTokenAddr) internal {
        controller.setTotalTokenSupplyWithReservedTokensOf(PROJECT_ID, 1);
        vm.mockCall(
            address(store),
            abi.encodeWithSignature("currentReclaimableSurplusOf(uint256,uint256,uint256,uint256)"),
            abi.encode(type(uint256).max / 1e18 + 1)
        );
        vm.mockCall(
            address(store),
            abi.encodeWithSelector(MockJBTerminalStore.currentTotalSurplusOf.selector),
            abi.encode(type(uint256).max / 1e18 + 1)
        );
        assertEq(_rate(token), type(uint256).max, "the preview saturates");
        _assertEmpty(token, projectTokenAddr);
    }

    function test_partialSupplyPreview_saturates_ProjectToken0() public {
        _runSaturation(address(terminalToken), lowProjectToken);
    }

    function test_partialSupplyPreview_saturates_ProjectToken1() public {
        _runSaturation(address(terminalToken), highProjectToken);
    }

    function test_partialSupplyPreview_saturates_Native() public {
        _runSaturation(NATIVE, highProjectToken);
    }

    function _assertEmpty(address token, address projectTokenAddr) internal view {
        (int24 lower, int24 upper) = _bounds(token, projectTokenAddr);
        assertEq(lower, 0, "a saturated floor empties the corridor: lower");
        assertEq(upper, 0, "a saturated floor empties the corridor: upper");
    }
}
