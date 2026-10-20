// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {LPSplitHookV4TestBase, DEFAULT_SURPLUS_PER_TOKEN} from "./TestBaseV4.sol";
import {MockERC20} from "./mock/MockERC20.sol";

/// @notice Oracle stand-in whose every call reverts with a 1MB revert-data bomb, exercising the hook's bounded
/// failure capture.
contract BombOracle {
    fallback() external {
        assembly {
            revert(0, 0x100000)
        }
    }
}

/// @notice Permit2 stand-in that attempts to reenter the hook on `approve` (which the hook calls mid-automation),
/// records the rejection, and otherwise behaves like the plain mock so the mint completes.
contract ReenteringPermit2 {
    JBUniswapV4LPSplitHook public hook;
    uint256 public reentryProjectId;
    bool public attempted;
    bytes4 public reentrySelector;

    function configure(JBUniswapV4LPSplitHook newHook, uint256 projectId) external {
        hook = newHook;
        reentryProjectId = projectId;
    }

    function approve(address, address, uint160, uint48) external {
        if (attempted || address(hook) == address(0)) return;
        attempted = true;
        // Reenter a guarded entry point while the outer `processSplitWith` lock is held across the automation
        // self-call. The solady guard must reject it.
        try hook.deployPool(reentryProjectId) {
            reentrySelector = bytes4(0);
        } catch (bytes memory reason) {
            reentrySelector = bytes4(reason);
        }
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        // Test mock: return value not checked intentionally.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        MockERC20(token).transferFrom(from, to, amount);
    }
}

/// @notice Regression suite for the durable-intake refactor: `processSplitWith` must accept and account for a
/// reserved-token split FIRST (ERC-20 or credits), then only best-effort attempt pool deployment / liquidity
/// addition. Any post-intake failure must leave the accepted inventory retryable through the permissionless
/// `deployPool` / `addLiquidity` entry points.
contract DurableIntakeTest is LPSplitHookV4TestBase {
    /// @notice A project that only has credits (no ERC-20 deployed).
    uint256 internal constant CREDITS_PROJECT_ID = 77;

    /// @notice A project with an ERC-20 but no wired terminal, so inline automation fails after intake.
    uint256 internal constant NO_TERMINAL_PROJECT_ID = 88;

    MockERC20 internal noTerminalProjectToken;

    function setUp() public override {
        super.setUp();

        // Credits-only project: a controller but no ERC-20 in JBTokens.
        _setDirectoryController(CREDITS_PROJECT_ID, address(controller));
        jbProjects.setOwner(CREDITS_PROJECT_ID, owner);

        // ERC-20 project with no terminal wired, so the inline deploy attempt fails after intake.
        noTerminalProjectToken = new MockERC20("No Terminal", "NOTERM", 18);
        _setDirectoryController(NO_TERMINAL_PROJECT_ID, address(controller));
        jbProjects.setOwner(NO_TERMINAL_PROJECT_ID, owner);
        jbTokens.setToken(NO_TERMINAL_PROJECT_ID, address(noTerminalProjectToken));
        controller.setWeight(NO_TERMINAL_PROJECT_ID, DEFAULT_WEIGHT);
        controller.setFirstWeight(NO_TERMINAL_PROJECT_ID, DEFAULT_FIRST_WEIGHT);
        controller.setBaseCurrency(NO_TERMINAL_PROJECT_ID, 1);
    }

    // ─── Intake validation
    // ──────────────────────────────────────────────

    /// @notice Reserved project tokens are never a terminal token, so no native value may ride along.
    function test_ProcessSplit_RevertsIf_MsgValue() public {
        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, 1e18);

        vm.deal(address(controller), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_UnexpectedMsgValue.selector, 1)
        );
        vm.prank(address(controller));
        hook.processSplitWith{value: 1}(context);
    }

    // ─── Credits intake
    // ─────────────────────────────────────────────────

    /// @notice Core transfers credits to the hook BEFORE calling it, so a credits-only project must be accepted
    /// and accounted — not rejected (which would strand the already-transferred credits at the hook).
    function test_CreditsIntake_AccountsCredits() public {
        uint256 amount = 5e18;

        // Mirror Core: the credits are already at the hook when `processSplitWith` runs.
        jbTokens.setCreditBalance(address(hook), CREDITS_PROJECT_ID, amount);

        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(CREDITS_PROJECT_ID, address(0), amount, 1));

        assertEq(hook.accumulatedProjectCredits(CREDITS_PROJECT_ID), amount, "credits should be accounted");
        assertEq(hook.accumulatedProjectTokens(CREDITS_PROJECT_ID), 0, "no ERC-20 accumulation for credits");
        assertFalse(hook.hasDeployedPool(CREDITS_PROJECT_ID), "no Uniswap work without an ERC-20");
    }

    /// @notice The credit ledger only grows when the hook's actual credit balance backs prior LP credits, the new
    /// amount, and any outstanding fee-credit liabilities — a lying controller cannot inflate the ledger.
    function test_CreditsIntake_RevertsIf_NotBacked() public {
        uint256 amount = 5e18;

        // No credits were actually transferred to the hook.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InsufficientBalance.selector, 0, amount
            )
        );
        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(CREDITS_PROJECT_ID, address(0), amount, 1));
    }

    /// @notice Credits keep accumulating across distributions.
    function test_CreditsIntake_Accumulates() public {
        jbTokens.setCreditBalance(address(hook), CREDITS_PROJECT_ID, 3e18);
        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(CREDITS_PROJECT_ID, address(0), 3e18, 1));

        jbTokens.setCreditBalance(address(hook), CREDITS_PROJECT_ID, 7e18);
        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(CREDITS_PROJECT_ID, address(0), 4e18, 1));

        assertEq(hook.accumulatedProjectCredits(CREDITS_PROJECT_ID), 7e18, "credits should accumulate");
    }

    /// @notice Once the project tokenizes, the permissionless deploy claims exactly the accounted LP credits into
    /// ERC-20s and deploys them.
    function test_CreditsThenTokenize_DeployClaimsExactCredits() public {
        uint256 amount = 5e18;
        jbTokens.setCreditBalance(address(hook), CREDITS_PROJECT_ID, amount);
        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(CREDITS_PROJECT_ID, address(0), amount, 1));

        // The project deploys an ERC-20 and wires a terminal.
        MockERC20 newProjectToken = new MockERC20("Tokenized", "TOK", 18);
        jbTokens.setToken(CREDITS_PROJECT_ID, address(newProjectToken));
        controller.setWeight(CREDITS_PROJECT_ID, DEFAULT_WEIGHT);
        controller.setFirstWeight(CREDITS_PROJECT_ID, DEFAULT_FIRST_WEIGHT);
        controller.setBaseCurrency(CREDITS_PROJECT_ID, 1);
        _setDirectoryTerminal(CREDITS_PROJECT_ID, address(terminalToken), address(terminal));
        _addDirectoryTerminal(CREDITS_PROJECT_ID, address(terminal));
        terminal.setProjectToken(CREDITS_PROJECT_ID, address(newProjectToken));
        terminal.setAccountingContext(
            CREDITS_PROJECT_ID, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );
        terminal.addAccountingContext(
            CREDITS_PROJECT_ID,
            JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        );
        store.setSurplus(CREDITS_PROJECT_ID, DEFAULT_SURPLUS_PER_TOKEN);
        store.setBalance(address(terminal), CREDITS_PROJECT_ID, address(terminalToken), 10e18);

        hook.deployPool(CREDITS_PROJECT_ID);

        assertTrue(hook.hasDeployedPool(CREDITS_PROJECT_ID), "pool should deploy from claimed credits");
        assertEq(hook.accumulatedProjectCredits(CREDITS_PROJECT_ID), 0, "credit ledger should be consumed");
        assertEq(
            jbTokens.creditBalanceOf(address(hook), CREDITS_PROJECT_ID), 0, "hook credits should be claimed exactly"
        );
    }

    // ─── Inline automation
    // ──────────────────────────────────────────────

    /// @notice With enough gas and a fully wired project, the first sufficient accumulation deploys the pool
    /// inline — no separate `deployPool` call needed.
    function test_InlineAutomation_DeploysPool() public {
        uint256 amount = 100e18;
        projectToken.mint(address(controller), amount);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), amount);
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, amount));
        vm.stopPrank();

        assertTrue(hook.hasDeployedPool(PROJECT_ID), "pool should deploy inline");
        assertEq(hook.deployedTerminalTokenOf(PROJECT_ID), address(terminalToken), "terminal token should be recorded");
        assertTrue(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)) != 0, "a position should exist");
    }

    /// @notice After the pool exists, a later sufficient accumulation converts into more liquidity inline.
    function test_InlineAutomation_AddsLiquidityPostDeploy() public {
        test_InlineAutomation_DeploysPool();
        uint256 tokenIdBefore = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));

        uint256 amount = 50e18;
        projectToken.mint(address(controller), amount);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), amount);
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, amount));
        vm.stopPrank();

        assertTrue(
            hook.askTokenIdOf(PROJECT_ID, address(terminalToken)) != tokenIdBefore,
            "the position should have been re-minted with the new accumulation"
        );
        assertLt(hook.accumulatedProjectTokens(PROJECT_ID), amount, "accumulation should be consumed by the add");
    }

    /// @notice Accumulation below the add threshold skips automation successfully and retains the inventory.
    function test_InlineAutomation_SkipsBelowThreshold() public {
        uint256 amount = 1e14; // below _MIN_ADD_ACCUMULATION (1e15)
        projectToken.mint(address(controller), amount);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), amount);
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, amount));
        vm.stopPrank();

        assertFalse(hook.hasDeployedPool(PROJECT_ID), "no deploy below the threshold");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), amount, "inventory should be retained");
    }

    /// @notice A failed inline attempt (here: no terminal wired) cannot touch the accepted inventory; the failure
    /// is surfaced through a bounded event and the inventory stays retryable.
    function test_InlineAutomation_FailureRetainsInventory() public {
        uint256 amount = 100e18;
        noTerminalProjectToken.mint(address(controller), amount);
        vm.startPrank(address(controller));
        noTerminalProjectToken.approve(address(hook), amount);

        vm.expectEmit(true, false, false, false, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed(NO_TERMINAL_PROJECT_ID, bytes4(0), address(controller));
        hook.processSplitWith(_buildReservedContext2(NO_TERMINAL_PROJECT_ID, amount));
        vm.stopPrank();

        assertFalse(hook.hasDeployedPool(NO_TERMINAL_PROJECT_ID), "deploy should have failed");
        assertEq(hook.accumulatedProjectTokens(NO_TERMINAL_PROJECT_ID), amount, "inventory must be retained");

        // Repair the condition: wire a terminal, then the permissionless retry deploys the retained inventory.
        _setDirectoryTerminal(NO_TERMINAL_PROJECT_ID, address(terminalToken), address(terminal));
        _addDirectoryTerminal(NO_TERMINAL_PROJECT_ID, address(terminal));
        terminal.setProjectToken(NO_TERMINAL_PROJECT_ID, address(noTerminalProjectToken));
        terminal.setAccountingContext(
            NO_TERMINAL_PROJECT_ID, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );
        terminal.addAccountingContext(
            NO_TERMINAL_PROJECT_ID,
            JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        );
        store.setSurplus(NO_TERMINAL_PROJECT_ID, DEFAULT_SURPLUS_PER_TOKEN);
        store.setBalance(address(terminal), NO_TERMINAL_PROJECT_ID, address(terminalToken), 10e18);

        hook.deployPool(NO_TERMINAL_PROJECT_ID);
        assertTrue(hook.hasDeployedPool(NO_TERMINAL_PROJECT_ID), "retry should deploy the retained inventory");
    }

    /// @notice A gas-capped distribution completes intake and skips automation rather than reverting.
    function test_GasCapped_IntakeSucceedsAutomationSkipped() public {
        uint256 amount = 100e18;
        projectToken.mint(address(controller), amount);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), amount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildReservedContext(PROJECT_ID, amount));
        vm.stopPrank();

        assertFalse(hook.hasDeployedPool(PROJECT_ID), "automation should be skipped under the gas cap");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), amount, "intake must have completed");
    }

    /// @notice The self-call automation executor rejects everyone but the hook itself.
    function test_ExecuteAutomationFor_RevertsIf_NotSelf() public {
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_Unauthorized.selector);
        hook.executeAutomationFor(PROJECT_ID);
    }

    /// @notice A revert-data bomb from a downstream dependency (here: the oracle behind the TWAP guard) cannot
    /// affect intake — failure reporting stays bounded to the error selector and the inventory stays retryable.
    function test_RevertDataBomb_IntakeSucceedsBoundedFailure() public {
        // Pre-initialize the pool at a mid-corridor price so the deploy attempt runs the TWAP guard (a pool the hook
        // initializes itself skips it), with a bomb oracle behind `observe`.
        address bombOracle = address(new BombOracle());
        _overrideOracleHook(bombOracle);
        positionManager.initializePool(_poolKeyWithHooks(bombOracle), _midCorridorSqrtPrice());

        uint256 amount = 100e18;
        projectToken.mint(address(controller), amount);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), amount);

        vm.expectEmit(true, true, true, true, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed(
            PROJECT_ID, JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TwapUnavailable.selector, address(controller)
        );
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, amount));
        vm.stopPrank();

        assertFalse(hook.hasDeployedPool(PROJECT_ID), "the bombed attempt must have failed");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), amount, "inventory must be retained");

        // Repair: restore the healthy spot-tracking oracle; the permissionless retry then deploys (a fresh pool key,
        // so the hook initializes it itself and the TWAP guard is skipped).
        _overrideOracleHook(address(baseOracleHook));
        hook.deployPool(PROJECT_ID);
        assertTrue(hook.hasDeployedPool(PROJECT_ID), "retry should deploy the retained inventory");
    }

    /// @notice Reentrancy during automation: a guarded entry point called back mid-automation (from the Permit2
    /// approve the mint performs) is rejected by the outer lock, and the accepted inventory is credited exactly once.
    function test_ReentrancyDuringAutomation_Blocked() public {
        // Swap the canonical Permit2 for the reentering variant (same address the hook already uses).
        address permit2Addr = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        vm.etch(permit2Addr, address(new ReenteringPermit2()).code);
        ReenteringPermit2(permit2Addr).configure(hook, PROJECT_ID);

        uint256 amount = 100e18;
        projectToken.mint(address(controller), amount);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), amount);
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, amount));
        vm.stopPrank();

        // The reentry was attempted and rejected by the reentrancy guard (solady `Reentrancy()`).
        assertTrue(ReenteringPermit2(permit2Addr).attempted(), "the reentry must have been attempted");
        assertEq(
            ReenteringPermit2(permit2Addr).reentrySelector(),
            bytes4(keccak256("Reentrancy()")),
            "the reentry must be rejected by the guard"
        );

        // The automation itself completed exactly once with no double credit.
        assertTrue(hook.hasDeployedPool(PROJECT_ID), "the outer automation should still complete");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "the inventory must be credited exactly once");
    }

    /// @notice Credits and fee-credit liabilities coexisting on one project: the backing check counts both, and
    /// deployment claims only the LP credits — never the credits reserved for fee claimants.
    function test_CreditsAndFeeCreditLiability_Coexist() public {
        // The fee project itself uses the hook for LP while it has no ERC-20 and carries a fee-credit liability.
        jbTokens.setToken(FEE_PROJECT_ID, address(0));

        // Seed a 3e18 fee-credit liability (backed by credits at the hook), as fee routing would have.
        vm.store(
            address(hook),
            keccak256(abi.encode(FEE_PROJECT_ID, uint256(19))), // _totalOutstandingFeeCreditClaims, slot 19
            bytes32(uint256(3e18))
        );
        jbTokens.setCreditBalance(address(hook), FEE_PROJECT_ID, 4e18);

        // Intake of 2e18 LP credits must NOT pass while the balance (4e18) cannot back liability (3e18) + new (2e18).
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InsufficientBalance.selector, 4e18, 5e18
            )
        );
        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(FEE_PROJECT_ID, address(0), 2e18, 1));

        // With full backing the intake lands.
        jbTokens.setCreditBalance(address(hook), FEE_PROJECT_ID, 5e18);
        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(FEE_PROJECT_ID, address(0), 2e18, 1));
        assertEq(hook.accumulatedProjectCredits(FEE_PROJECT_ID), 2e18, "LP credits should be accounted");

        // The fee project tokenizes and wires a terminal; deployment claims ONLY the 2e18 LP credits.
        jbTokens.setToken(FEE_PROJECT_ID, address(feeProjectToken));
        controller.setBaseCurrency(FEE_PROJECT_ID, 1);
        controller.setReservedPercent(FEE_PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        _addDirectoryTerminal(FEE_PROJECT_ID, address(terminal));
        terminal.setAccountingContext(
            FEE_PROJECT_ID, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );
        terminal.addAccountingContext(
            FEE_PROJECT_ID,
            JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        );
        store.setSurplus(FEE_PROJECT_ID, DEFAULT_SURPLUS_PER_TOKEN);
        store.setBalance(address(terminal), FEE_PROJECT_ID, address(terminalToken), 10e18);

        hook.deployPool(FEE_PROJECT_ID);

        assertTrue(hook.hasDeployedPool(FEE_PROJECT_ID), "the fee project's own pool should deploy");
        assertEq(hook.accumulatedProjectCredits(FEE_PROJECT_ID), 0, "the LP credit ledger should be consumed");
        assertEq(
            jbTokens.creditBalanceOf(address(hook), FEE_PROJECT_ID),
            3e18,
            "the credits reserved for fee claimants must remain untouched"
        );
    }

    // ─── Helpers
    // ────────────────────────────────────────────────────────

    /// @notice The pool key the hook would build for PROJECT_ID with a given oracle hook address.
    function _poolKeyWithHooks(address hooks) internal view returns (PoolKey memory key) {
        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(hooks)
        });
    }

    /// @notice A sqrt price in the middle of PROJECT_ID's economic corridor (always inside the band).
    function _midCorridorSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (int24 lower, int24 upper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
        return TickMath.getSqrtPriceAtTick((lower + upper) / 2);
    }

    /// @notice Context builder for the no-terminal project (its own project token).
    function _buildReservedContext2(
        uint256 projectId,
        uint256 amount
    )
        internal
        view
        returns (JBSplitHookContext memory)
    {
        return _buildContext(projectId, address(noTerminalProjectToken), amount, 1);
    }
}
