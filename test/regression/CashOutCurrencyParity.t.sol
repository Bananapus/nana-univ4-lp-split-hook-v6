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
/// to match issuance. Deriving the currency from `uint32(uint160(terminalToken))` would diverge from issuance
/// whenever a project's accounting context declares a different currency for the token (e.g. a USDC token configured
/// under a USD identity).
contract CashOutCurrencyParityTest is LPSplitHookV4TestBase {
    TestableHookForCurrencyParity public testableHook;

    MockERC20 public terminalTokenA;
    MockERC20 public projectTokenA;

    uint256 public constant TEST_PROJECT_ID = 42;

    /// @dev A currency identifier different from `uint32(uint160(terminalToken))`, so a cash-out rate that used the
    /// token-derived value instead of this declared currency from `accountingContextForTokenOf` would be caught.
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
    /// @notice The native-token sentinel, which sorts below both controlled project-token addresses.
    address internal constant _NATIVE = JBConstants.NATIVE_TOKEN;

    /// @notice A project-token address one above the ERC-20 terminal token, so the project sorts as token1.
    address internal _highProjectToken;

    /// @notice A project-token address one below the ERC-20 terminal token, so the project sorts as token0.
    address internal _lowProjectToken;

    /// @notice The second local terminal's own store, holding 900 terminal tokens of surplus.
    MockJBTerminalStore internal _secondStore;

    /// @notice A second local terminal backed by `_secondStore`.
    MockJBMultiTerminal internal _secondTerminal;

    /// @notice Splits the project's surplus across the primary terminal's store (100) and a second local terminal on
    /// its own store (900), at an issuance price of 2 terminal tokens per project token.
    function setUp() public override {
        super.setUp();
        // Controlled project-token addresses on both sides of the ERC-20 terminal token (the native sentinel sorts
        // below both, so a native pair always has the project as token1).
        _lowProjectToken = address(uint160(address(terminalToken)) - 1);
        _highProjectToken = address(uint160(address(terminalToken)) + 1);

        // Issuance price 2 terminal tokens per project token.
        controller.setWeight({projectId: PROJECT_ID, weight: 0.5e18});
        controller.setReservedPercent({projectId: PROJECT_ID, reservedPercent: 0});

        // The primary terminal also accepts native ETH.
        _setDirectoryTerminal({projectId: PROJECT_ID, token: _NATIVE, term: address(terminal)});
        terminal.setAccountingContext({
            projectId: PROJECT_ID,
            token: _NATIVE,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(_NATIVE)),
            decimals: 18
        });

        // The primary store previews reclaims from the surplus and supply the hook passes, as the real store does.
        store.setUseProvidedCashOutInputs(true);
        store.setSurplus({projectId: PROJECT_ID, surplus: 100e18});
        // What the primary store alone previews for a 1e18 burn: its own 100 of surplus over the 1000e18 supply.
        vm.mockCall(
            address(store),
            abi.encodeWithSelector(MockJBTerminalStore.currentTotalReclaimableSurplusOf.selector),
            abi.encode(uint256(0.1e18))
        );

        // A second local terminal on its own store holds the other 900.
        _secondStore = new MockJBTerminalStore();
        _secondStore.setSurplus({projectId: PROJECT_ID, surplus: 900e18});
        _secondTerminal = new MockJBMultiTerminal();
        _secondTerminal.setStore(address(_secondStore));
        _addDirectoryTerminal({projectId: PROJECT_ID, term: address(_secondTerminal)});
    }

    /// @notice With the project as token0, the floor and corridor count both terminals' surplus.
    function test_cashOutRate_countsEveryTerminal_ProjectToken0() public view {
        // The low project-token address sorts below the terminal token.
        _assertSettlementFloor({
            token: address(terminalToken), projectTokenAddr: _lowProjectToken, projectIsToken0: true
        });
    }

    /// @notice With the project as token1, the floor and corridor count both terminals' surplus.
    function test_cashOutRate_countsEveryTerminal_ProjectToken1() public view {
        // The high project-token address sorts above the terminal token.
        _assertSettlementFloor({
            token: address(terminalToken), projectTokenAddr: _highProjectToken, projectIsToken0: false
        });
    }

    /// @notice With native ETH as the terminal token, the floor and corridor count both terminals' surplus.
    function test_cashOutRate_countsEveryTerminal_NativeCurrency0() public view {
        // The native sentinel sorts below every project token, so the project is token1.
        _assertSettlementFloor({token: _NATIVE, projectTokenAddr: _highProjectToken, projectIsToken0: false});
    }

    /// @notice A failing surplus or reclaim preview reverts the bounds rather than reading as a zero floor: the
    /// recycle reverts, while a distribution's inline automation fails softly and keeps the intake.
    function test_failingPreview_revertsBounds_inlineKeepsIntake() public {
        // Deploy the pool, then make both of the primary store's reclaim previews revert.
        _accumulateAndDeploy({projectId: PROJECT_ID, amount: 100e18});
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

        // The rate read bubbles the preview's revert instead of returning a zero floor.
        vm.expectRevert(bytes("preview down"));
        this.rateOf(address(terminalToken));

        // A direct recycle reverts with the same reason.
        vm.expectRevert(bytes("preview down"));
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // A reserved-token distribution still accepts its intake and reports the automation failure.
        uint256 ledgerBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        projectToken.mint({to: address(controller), amount: 1e18});
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: 1e18});
        vm.expectEmit(true, false, false, false, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed(PROJECT_ID, bytes4(0), address(controller));
        hook.processSplitWith(_buildReservedContext({projectId: PROJECT_ID, amount: 1e18}));
        vm.stopPrank();
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), ledgerBefore + 1e18, "the intake is kept");
    }

    /// @notice A failing secondary-terminal surplus read reverts the ERC-20 pair's rate, bounds and recycle, while
    /// the inline automation keeps the intake.
    function test_failingSecondarySurplus_revertsBounds_inlineKeepsIntake() public {
        // Run the scenario against the ERC-20 terminal token.
        _runFailingSecondarySurplus(address(terminalToken));
    }

    /// @notice A failing secondary-terminal surplus read reverts the native pair's rate, bounds and recycle, while
    /// the inline automation keeps the intake.
    function test_failingSecondarySurplus_revertsBounds_inlineKeepsIntake_Native() public {
        // Run the scenario against native ETH.
        _runFailingSecondarySurplus(_NATIVE);
    }

    /// @notice With less than one whole token of supply, a preview whose scaled-up rate is representable scales
    /// exactly even when the plain product overflows: 1e60 reclaimed by a 1e17 supply is 1e61 per 1e18 tokens, though
    /// 1e60 * 1e18 exceeds 2^256.
    function test_partialSupplyPreview_scalesPastAnOverflowingProduct() public {
        // A supply of 0.1 tokens makes the hook scale the preview up by 10x.
        controller.setTotalTokenSupplyWithReservedTokensOf({projectId: PROJECT_ID, totalSupply: 1e17});
        vm.mockCall(
            address(store),
            abi.encodeWithSignature("currentReclaimableSurplusOf(uint256,uint256,uint256,uint256)"),
            abi.encode(uint256(1e60))
        );
        // The scaled rate is exact for both the ERC-20 and the native terminal token.
        assertEq(_rate(address(terminalToken)), 1e61, "the preview scales exactly");
        assertEq(_rate(_NATIVE), 1e61, "the preview scales exactly: native");
    }

    /// @notice A saturated floor empties the corridor with the project as token0.
    function test_partialSupplyPreview_saturates_ProjectToken0() public {
        // The low project-token address sorts below the terminal token.
        _runSaturation({token: address(terminalToken), projectTokenAddr: _lowProjectToken});
    }

    /// @notice A saturated floor empties the corridor with the project as token1.
    function test_partialSupplyPreview_saturates_ProjectToken1() public {
        // The high project-token address sorts above the terminal token.
        _runSaturation({token: address(terminalToken), projectTokenAddr: _highProjectToken});
    }

    /// @notice A saturated floor empties the corridor for a native terminal token.
    function test_partialSupplyPreview_saturates_Native() public {
        // The native sentinel sorts below every project token, so the project is token1.
        _runSaturation({token: _NATIVE, projectTokenAddr: _highProjectToken});
    }

    /// @notice External wrapper so `vm.expectRevert` can catch a library revert.
    /// @param token The terminal token the corridor is computed for.
    /// @param projectTokenAddr The project token the corridor is computed for.
    /// @return lower The corridor's lower tick.
    /// @return upper The corridor's upper tick.
    function boundsOf(address token, address projectTokenAddr) external view returns (int24 lower, int24 upper) {
        // Route through an external call so the revert surfaces at a depth `vm.expectRevert` sees.
        return _bounds({token: token, projectTokenAddr: projectTokenAddr});
    }

    /// @notice External wrapper so `vm.expectRevert` can catch a library revert.
    /// @param token The terminal token the cash-out rate is computed for.
    /// @return rate The cash-out rate, in terminal tokens per project token.
    function rateOf(address token) external view returns (uint256 rate) {
        // Route through an external call so the revert surfaces at a depth `vm.expectRevert` sees.
        return _rate(token);
    }

    /// @notice A failing surplus read on ANY local terminal reverts the rate and the bounds rather than counting that
    /// terminal as zero surplus, even while the primary terminal's surplus and the reclaim preview stay healthy. A
    /// recycle reverts and leaves the live position and both ledgers untouched, while a distribution's inline
    /// automation fails softly and keeps the intake.
    /// @param token The terminal token whose pair is exercised.
    function _runFailingSecondarySurplus(address token) internal {
        // A native pair needs its own accounting context and a native balance on the primary terminal.
        if (token == _NATIVE) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32 nativeCurrency = uint32(uint160(_NATIVE));
            terminal.addAccountingContext({
                projectId: PROJECT_ID,
                ctx: JBAccountingContext({token: _NATIVE, decimals: 18, currency: nativeCurrency})
            });
            store.setBalance({terminal: address(terminal), projectId: PROJECT_ID, token: _NATIVE, balance: 10e18});
            store.setBalance({
                terminal: address(terminal), projectId: PROJECT_ID, token: address(terminalToken), balance: 0
            });
        }
        // Deploy the pool and snapshot the live ask and both ledgers.
        _accumulateAndDeploy({projectId: PROJECT_ID, amount: 100e18});
        uint256 askId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: token});
        assertNotEq(askId, 0, "precondition: the deployed ask is live");
        uint128 liquidity = positionManager.getPositionLiquidity(askId);
        uint256 projectLedger = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 terminalLedger = hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: token});

        // Only the second terminal's surplus read fails.
        vm.mockCallRevert(
            address(_secondTerminal),
            abi.encodeWithSelector(IJBTerminal.currentSurplusOf.selector),
            bytes("surplus down")
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 currency = uint32(uint160(token));
        // The primary terminal still reports its surplus.
        assertEq(
            terminal.currentSurplusOf(PROJECT_ID, new address[](0), 18, currency),
            100e18,
            "precondition: the primary terminal's surplus is healthy"
        );

        // The rate, the bounds and a direct recycle all bubble the failure.
        vm.expectRevert(bytes("surplus down"));
        this.rateOf(token);
        vm.expectRevert(bytes("surplus down"));
        this.boundsOf({token: token, projectTokenAddr: address(projectToken)});
        vm.expectRevert(bytes("surplus down"));
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: token});

        // The reverted recycle leaves the ask, its liquidity and both ledgers untouched.
        assertEq(hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: token}), askId, "the ask is kept");
        assertEq(hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: token}), 0, "no bid appears");
        assertEq(positionManager.getPositionLiquidity(askId), liquidity, "the ask keeps its liquidity");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), projectLedger, "the project ledger is unchanged");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: token}),
            terminalLedger,
            "the terminal ledger is unchanged"
        );

        // A reserved-token distribution still accepts its intake and reports the automation failure.
        projectToken.mint({to: address(controller), amount: 1e18});
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: 1e18});
        vm.expectEmit(true, false, false, false, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed(PROJECT_ID, bytes4(0), address(controller));
        hook.processSplitWith(_buildReservedContext({projectId: PROJECT_ID, amount: 1e18}));
        vm.stopPrank();
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), projectLedger + 1e18, "the intake is kept");
        assertEq(hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: token}), askId, "the ask is still kept");
    }

    /// @notice With less than one whole token of supply, scaling the preview up to 1e18 tokens saturates instead of
    /// overflowing, and the saturated floor leaves an empty corridor rather than a revert, in either ordering and for
    /// a native terminal token.
    /// @param token The terminal token whose pair is exercised.
    /// @param projectTokenAddr The project token whose pair is exercised.
    function _runSaturation(address token, address projectTokenAddr) internal {
        // A one-wei supply scales the preview up by 1e18, so a preview just above max / 1e18 overflows.
        controller.setTotalTokenSupplyWithReservedTokensOf({projectId: PROJECT_ID, totalSupply: 1});
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
        // The rate saturates and the corridor comes back empty.
        assertEq(_rate(token), type(uint256).max, "the preview saturates");
        _assertEmpty({token: token, projectTokenAddr: projectTokenAddr});
    }

    /// @notice Asserts the corridor for the pair is empty.
    /// @param token The terminal token the corridor is computed for.
    /// @param projectTokenAddr The project token the corridor is computed for.
    function _assertEmpty(address token, address projectTokenAddr) internal view {
        // An empty corridor reads as both ticks at zero.
        (int24 lower, int24 upper) = _bounds({token: token, projectTokenAddr: projectTokenAddr});
        assertEq(lower, 0, "a saturated floor empties the corridor: lower");
        assertEq(upper, 0, "a saturated floor empties the corridor: upper");
    }

    /// @notice Asserts the rate and corridor reflect the settlement floor of 1 terminal token per project token.
    /// @param token The terminal token the floor is computed for.
    /// @param projectTokenAddr The project token the corridor is computed for.
    /// @param projectIsToken0 Whether the project token sorts as token0 in the pair.
    function _assertSettlementFloor(address token, address projectTokenAddr, bool projectIsToken0) internal view {
        // The floor sums both terminals' surplus: 1000 over a 1000e18 supply, so 1 per project token.
        assertEq(_rate(token), 1e18, "the floor counts every local terminal's surplus");
        // The corridor spans [floor, issuance] in project price, mirrored when the project is token1.
        (int24 lower, int24 upper) = _bounds({token: token, projectTokenAddr: projectTokenAddr});
        assertEq(lower, projectIsToken0 ? int24(200) : int24(-6800), "corridor lower");
        assertEq(upper, projectIsToken0 ? int24(6800) : int24(-200), "corridor upper");
    }

    /// @notice The corridor the math library computes for the pair under the project's current ruleset.
    /// @param token The terminal token the corridor is computed for.
    /// @param projectTokenAddr The project token the corridor is computed for.
    /// @return lower The corridor's lower tick.
    /// @return upper The corridor's upper tick.
    function _bounds(address token, address projectTokenAddr) internal view returns (int24 lower, int24 upper) {
        // Read the ruleset the hook would use, then compute the bounds with no sucker registry.
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

    /// @notice The cash-out rate the math library computes for the token under the project's current ruleset.
    /// @param token The terminal token the cash-out rate is computed for.
    /// @return rate The cash-out rate, in terminal tokens per project token.
    function _rate(address token) internal view returns (uint256 rate) {
        // Read the ruleset the hook would use, then compute the rate with no sucker registry.
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
}
