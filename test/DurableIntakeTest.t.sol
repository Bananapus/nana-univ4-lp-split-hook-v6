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
    /// @notice Revert every call with 1MB of revert data.
    fallback() external {
        // Revert with 0x100000 bytes of memory as the revert data.
        assembly {
            revert(0, 0x100000)
        }
    }
}

/// @notice Permit2 stand-in that attempts to reenter the hook on `approve` (which the hook calls mid-automation),
/// records the rejection, and otherwise behaves like the plain mock so the mint completes.
contract ReenteringPermit2 {
    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Whether the reentry was attempted.
    bool public attempted;

    /// @notice The hook to reenter.
    JBUniswapV4LPSplitHook public hook;

    /// @notice The project whose pool the reentry tries to deploy.
    uint256 public reentryProjectId;

    /// @notice The selector the reentry reverted with (0 if it succeeded).
    bytes4 public reentrySelector;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Attempt one reentry into the hook, then accept the approval like the plain mock.
    function approve(address, address, uint160, uint48) external {
        // Attempt only once, and only after `configure`.
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

    /// @notice Set the hook and project the reentry targets.
    /// @param newHook The hook to reenter.
    /// @param projectId The project whose pool the reentry tries to deploy.
    function configure(JBUniswapV4LPSplitHook newHook, uint256 projectId) external {
        hook = newHook;
        reentryProjectId = projectId;
    }

    /// @notice Pull `amount` of `token` from `from` to `to`, like the plain Permit2 mock.
    /// @param from The holder the tokens are pulled from.
    /// @param to The recipient.
    /// @param amount The amount to move.
    /// @param token The token to move.
    function transferFrom(address from, address to, uint160 amount, address token) external {
        // Test mock: return value not checked intentionally.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        MockERC20(token).transferFrom({from: from, to: to, amount: amount});
    }
}

/// @notice `processSplitWith` accepts and accounts for a reserved-token split first (ERC-20 or credits), then only
/// best-effort attempts pool deployment / liquidity addition. Any post-intake failure leaves the accepted inventory
/// retryable through the permissionless `deployPool` / `addLiquidity` entry points.
contract DurableIntakeTest is LPSplitHookV4TestBase {
    /// @notice A project that only has credits (no ERC-20 deployed).
    uint256 internal constant _CREDITS_PROJECT_ID = 77;

    /// @notice A project with an ERC-20 but no wired terminal, so inline automation fails after intake.
    uint256 internal constant _NO_TERMINAL_PROJECT_ID = 88;

    /// @notice Storage slot of the hook's owed fee-credit total, `_totalOutstandingFeeCreditClaims`.
    uint256 internal constant _SLOT_OUTSTANDING_FEE_CREDIT_CLAIMS = 19;

    /// @notice The ERC-20 of the no-terminal project.
    MockERC20 internal _noTerminalProjectToken;

    /// @notice Set up the base suite plus a credits-only project and an ERC-20 project with no terminal.
    function setUp() public override {
        super.setUp();

        // Credits-only project: a controller but no ERC-20 in JBTokens.
        _setDirectoryController({projectId: _CREDITS_PROJECT_ID, ctrl: address(controller)});
        jbProjects.setOwner({tokenId: _CREDITS_PROJECT_ID, owner: owner});

        // ERC-20 project with no terminal wired, so the inline deploy attempt fails after intake.
        _noTerminalProjectToken = new MockERC20("No Terminal", "NOTERM", 18);
        _setDirectoryController({projectId: _NO_TERMINAL_PROJECT_ID, ctrl: address(controller)});
        jbProjects.setOwner({tokenId: _NO_TERMINAL_PROJECT_ID, owner: owner});
        jbTokens.setToken({projectId: _NO_TERMINAL_PROJECT_ID, token: address(_noTerminalProjectToken)});
        controller.setWeight({projectId: _NO_TERMINAL_PROJECT_ID, weight: DEFAULT_WEIGHT});
        controller.setFirstWeight({projectId: _NO_TERMINAL_PROJECT_ID, weight: DEFAULT_FIRST_WEIGHT});
        controller.setBaseCurrency({projectId: _NO_TERMINAL_PROJECT_ID, currency: 1});
    }

    // ─── Intake validation
    // ──────────────────────────────────────────────

    /// @notice Reserved project tokens are never a terminal token, so no native value may ride along.
    function test_ProcessSplit_RevertsIf_MsgValue() public {
        JBSplitHookContext memory context = _buildReservedContext({projectId: PROJECT_ID, amount: 1e18});

        // The controller sends a single wei with the reserved split.
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
        jbTokens.setCreditBalance({holder: address(hook), projectId: _CREDITS_PROJECT_ID, creditCount: amount});

        // The controller delivers the split with no ERC-20.
        vm.prank(address(controller));
        hook.processSplitWith(
            _buildContext({projectId: _CREDITS_PROJECT_ID, token: address(0), amount: amount, groupId: 1})
        );

        // The credits are ledgered and nothing else happens.
        assertEq(hook.accumulatedProjectCredits(_CREDITS_PROJECT_ID), amount, "credits should be accounted");
        assertEq(hook.accumulatedProjectTokens(_CREDITS_PROJECT_ID), 0, "no ERC-20 accumulation for credits");
        assertFalse(hook.hasDeployedPool(_CREDITS_PROJECT_ID), "no Uniswap work without an ERC-20");
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
        hook.processSplitWith(
            _buildContext({projectId: _CREDITS_PROJECT_ID, token: address(0), amount: amount, groupId: 1})
        );
    }

    /// @notice Credits keep accumulating across distributions.
    function test_CreditsIntake_Accumulates() public {
        // A first distribution of 3e18 credits.
        jbTokens.setCreditBalance({holder: address(hook), projectId: _CREDITS_PROJECT_ID, creditCount: 3e18});
        vm.prank(address(controller));
        hook.processSplitWith(
            _buildContext({projectId: _CREDITS_PROJECT_ID, token: address(0), amount: 3e18, groupId: 1})
        );

        // A second distribution of 4e18 credits, bringing the hook's balance to 7e18.
        jbTokens.setCreditBalance({holder: address(hook), projectId: _CREDITS_PROJECT_ID, creditCount: 7e18});
        vm.prank(address(controller));
        hook.processSplitWith(
            _buildContext({projectId: _CREDITS_PROJECT_ID, token: address(0), amount: 4e18, groupId: 1})
        );

        // The ledger holds both.
        assertEq(hook.accumulatedProjectCredits(_CREDITS_PROJECT_ID), 7e18, "credits should accumulate");
    }

    /// @notice Once the project tokenizes, the permissionless deploy claims exactly the accounted LP credits into
    /// ERC-20s and deploys them.
    function test_CreditsThenTokenize_DeployClaimsExactCredits() public {
        // The hook accepts 5e18 credits.
        uint256 amount = 5e18;
        jbTokens.setCreditBalance({holder: address(hook), projectId: _CREDITS_PROJECT_ID, creditCount: amount});
        vm.prank(address(controller));
        hook.processSplitWith(
            _buildContext({projectId: _CREDITS_PROJECT_ID, token: address(0), amount: amount, groupId: 1})
        );

        // The project deploys an ERC-20 and gets a ruleset.
        MockERC20 newProjectToken = new MockERC20("Tokenized", "TOK", 18);
        jbTokens.setToken({projectId: _CREDITS_PROJECT_ID, token: address(newProjectToken)});
        controller.setWeight({projectId: _CREDITS_PROJECT_ID, weight: DEFAULT_WEIGHT});
        controller.setFirstWeight({projectId: _CREDITS_PROJECT_ID, weight: DEFAULT_FIRST_WEIGHT});
        controller.setBaseCurrency({projectId: _CREDITS_PROJECT_ID, currency: 1});

        // The project wires a terminal with an accounting context, a surplus and a balance.
        _setDirectoryTerminal({projectId: _CREDITS_PROJECT_ID, token: address(terminalToken), term: address(terminal)});
        _addDirectoryTerminal({projectId: _CREDITS_PROJECT_ID, term: address(terminal)});
        terminal.setProjectToken({projectId: _CREDITS_PROJECT_ID, token: address(newProjectToken)});
        terminal.setAccountingContext({
            projectId: _CREDITS_PROJECT_ID,
            token: address(terminalToken),
            currency: uint32(uint160(address(terminalToken))),
            decimals: 18
        });
        terminal.addAccountingContext({
            projectId: _CREDITS_PROJECT_ID,
            ctx: JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        });
        store.setSurplus({projectId: _CREDITS_PROJECT_ID, surplus: DEFAULT_SURPLUS_PER_TOKEN});
        store.setBalance({
            terminal: address(terminal), projectId: _CREDITS_PROJECT_ID, token: address(terminalToken), balance: 10e18
        });

        // Anyone can deploy from the claimed credits.
        hook.deployPool(_CREDITS_PROJECT_ID);

        // The pool deployed and every LP credit was claimed exactly.
        assertTrue(hook.hasDeployedPool(_CREDITS_PROJECT_ID), "pool should deploy from claimed credits");
        assertEq(hook.accumulatedProjectCredits(_CREDITS_PROJECT_ID), 0, "credit ledger should be consumed");
        assertEq(
            jbTokens.creditBalanceOf({holder: address(hook), projectId: _CREDITS_PROJECT_ID}),
            0,
            "hook credits should be claimed exactly"
        );
    }

    // ─── Inline automation
    // ──────────────────────────────────────────────

    /// @notice With enough gas and a fully wired project, the first sufficient accumulation deploys the pool
    /// inline — no separate `deployPool` call needed.
    function test_InlineAutomation_DeploysPool() public {
        // The controller sends 100e18 reserved tokens with full gas.
        uint256 amount = 100e18;
        projectToken.mint({to: address(controller), amount: amount});
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: amount});
        hook.processSplitWith(_buildReservedContext({projectId: PROJECT_ID, amount: amount}));
        vm.stopPrank();

        // The pool and its first position exist.
        assertTrue(hook.hasDeployedPool(PROJECT_ID), "pool should deploy inline");
        assertEq(hook.deployedTerminalTokenOf(PROJECT_ID), address(terminalToken), "terminal token should be recorded");
        assertTrue(
            hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}) != 0,
            "a position should exist"
        );
    }

    /// @notice After the pool exists, a later sufficient accumulation converts into more liquidity inline.
    function test_InlineAutomation_AddsLiquidityPostDeploy() public {
        // Deploy inline first.
        test_InlineAutomation_DeploysPool();
        uint256 tokenIdBefore = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // A second distribution of 50e18 with full gas.
        uint256 amount = 50e18;
        projectToken.mint({to: address(controller), amount: amount});
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: amount});
        hook.processSplitWith(_buildReservedContext({projectId: PROJECT_ID, amount: amount}));
        vm.stopPrank();

        // The ask was re-minted with the new inventory.
        assertTrue(
            hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}) != tokenIdBefore,
            "the position should have been re-minted with the new accumulation"
        );
        assertLt(hook.accumulatedProjectTokens(PROJECT_ID), amount, "accumulation should be consumed by the add");
    }

    /// @notice Accumulation below the add threshold skips automation successfully and retains the inventory.
    function test_InlineAutomation_SkipsBelowThreshold() public {
        // A distribution below `_MIN_ADD_ACCUMULATION` (1e15), with full gas.
        uint256 amount = 1e14;
        projectToken.mint({to: address(controller), amount: amount});
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: amount});
        hook.processSplitWith(_buildReservedContext({projectId: PROJECT_ID, amount: amount}));
        vm.stopPrank();

        // Nothing deployed and the inventory stays on the ledger.
        assertFalse(hook.hasDeployedPool(PROJECT_ID), "no deploy below the threshold");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), amount, "inventory should be retained");
    }

    /// @notice A failed inline attempt (here: no terminal wired) cannot touch the accepted inventory; the failure
    /// is surfaced through a bounded event and the inventory stays retryable.
    function test_InlineAutomation_FailureRetainsInventory() public {
        // The controller sends 100e18 of the no-terminal project's tokens with full gas.
        uint256 amount = 100e18;
        _noTerminalProjectToken.mint({to: address(controller), amount: amount});
        vm.startPrank(address(controller));
        _noTerminalProjectToken.approve({spender: address(hook), amount: amount});

        // The failed attempt is reported and intake still completes.
        vm.expectEmit(true, false, false, false, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed({
            projectId: _NO_TERMINAL_PROJECT_ID, reasonSelector: bytes4(0), caller: address(controller)
        });
        hook.processSplitWith(_buildNoTerminalReservedContext(amount));
        vm.stopPrank();

        // Nothing deployed and the inventory is retained.
        assertFalse(hook.hasDeployedPool(_NO_TERMINAL_PROJECT_ID), "deploy should have failed");
        assertEq(hook.accumulatedProjectTokens(_NO_TERMINAL_PROJECT_ID), amount, "inventory must be retained");

        // Repair the condition: wire a terminal, then the permissionless retry deploys the retained inventory.
        _setDirectoryTerminal({
            projectId: _NO_TERMINAL_PROJECT_ID, token: address(terminalToken), term: address(terminal)
        });
        _addDirectoryTerminal({projectId: _NO_TERMINAL_PROJECT_ID, term: address(terminal)});
        terminal.setProjectToken({projectId: _NO_TERMINAL_PROJECT_ID, token: address(_noTerminalProjectToken)});
        terminal.setAccountingContext({
            projectId: _NO_TERMINAL_PROJECT_ID,
            token: address(terminalToken),
            currency: uint32(uint160(address(terminalToken))),
            decimals: 18
        });
        terminal.addAccountingContext({
            projectId: _NO_TERMINAL_PROJECT_ID,
            ctx: JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        });
        store.setSurplus({projectId: _NO_TERMINAL_PROJECT_ID, surplus: DEFAULT_SURPLUS_PER_TOKEN});
        store.setBalance({
            terminal: address(terminal),
            projectId: _NO_TERMINAL_PROJECT_ID,
            token: address(terminalToken),
            balance: 10e18
        });

        // The retry deploys from the retained inventory.
        hook.deployPool(_NO_TERMINAL_PROJECT_ID);
        assertTrue(hook.hasDeployedPool(_NO_TERMINAL_PROJECT_ID), "retry should deploy the retained inventory");
    }

    /// @notice A gas-capped distribution completes intake and skips automation rather than reverting.
    function test_GasCapped_IntakeSucceedsAutomationSkipped() public {
        // The controller sends 100e18 reserved tokens with only enough gas for intake.
        uint256 amount = 100e18;
        projectToken.mint({to: address(controller), amount: amount});
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: amount});
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildReservedContext({projectId: PROJECT_ID, amount: amount}));
        vm.stopPrank();

        // Intake completed and automation was skipped.
        assertFalse(hook.hasDeployedPool(PROJECT_ID), "automation should be skipped under the gas cap");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), amount, "intake must have completed");
    }

    /// @notice The self-call automation executor rejects everyone but the hook itself.
    function test_ExecuteAutomationFor_RevertsIf_NotSelf() public {
        // An outside caller is rejected.
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
        positionManager.initializePool({key: _poolKeyWithHooks(bombOracle), sqrtPriceX96: _midCorridorSqrtPrice()});

        // The controller sends 100e18 reserved tokens with full gas.
        uint256 amount = 100e18;
        projectToken.mint({to: address(controller), amount: amount});
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: amount});

        // The failure is reported as just the TWAP selector, not the bomb's revert data.
        vm.expectEmit(true, true, true, true, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed({
            projectId: PROJECT_ID,
            reasonSelector: JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_TwapUnavailable.selector,
            caller: address(controller)
        });
        hook.processSplitWith(_buildReservedContext({projectId: PROJECT_ID, amount: amount}));
        vm.stopPrank();

        // Nothing deployed and the inventory is retained.
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
        ReenteringPermit2(permit2Addr).configure({newHook: hook, projectId: PROJECT_ID});

        // The controller sends 100e18 reserved tokens with full gas, so automation runs and calls Permit2.
        uint256 amount = 100e18;
        projectToken.mint({to: address(controller), amount: amount});
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: amount});
        hook.processSplitWith(_buildReservedContext({projectId: PROJECT_ID, amount: amount}));
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

        // The inventory is credited exactly once: the ask plus the rounding left in the ledger is the whole amount.
        _assertPlacedExactly({
            projectId: PROJECT_ID,
            projectTokenAddr: address(projectToken),
            terminalTokenAddr: address(terminalToken),
            projectIn: amount,
            terminalIn: 0
        });
    }

    /// @notice Credits and fee-credit liabilities coexisting on one project: the backing check counts both, and
    /// deployment claims only the LP credits — never the credits reserved for fee claimants.
    function test_CreditsAndFeeCreditLiability_Coexist() public {
        // The fee project itself uses the hook for LP while it has no ERC-20 and carries a fee-credit liability.
        jbTokens.setToken({projectId: FEE_PROJECT_ID, token: address(0)});

        // Seed a 3e18 fee-credit liability (backed by credits at the hook), as fee routing would have.
        vm.store(
            address(hook),
            keccak256(abi.encode(FEE_PROJECT_ID, _SLOT_OUTSTANDING_FEE_CREDIT_CLAIMS)),
            bytes32(uint256(3e18))
        );
        jbTokens.setCreditBalance({holder: address(hook), projectId: FEE_PROJECT_ID, creditCount: 4e18});

        // Intake of 2e18 LP credits must NOT pass while the balance (4e18) cannot back liability (3e18) + new (2e18).
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InsufficientBalance.selector, 4e18, 5e18
            )
        );
        vm.prank(address(controller));
        hook.processSplitWith(_buildContext({projectId: FEE_PROJECT_ID, token: address(0), amount: 2e18, groupId: 1}));

        // With full backing the intake lands.
        jbTokens.setCreditBalance({holder: address(hook), projectId: FEE_PROJECT_ID, creditCount: 5e18});
        vm.prank(address(controller));
        hook.processSplitWith(_buildContext({projectId: FEE_PROJECT_ID, token: address(0), amount: 2e18, groupId: 1}));
        assertEq(hook.accumulatedProjectCredits(FEE_PROJECT_ID), 2e18, "LP credits should be accounted");

        // The fee project tokenizes and wires a terminal; deployment claims ONLY the 2e18 LP credits.
        jbTokens.setToken({projectId: FEE_PROJECT_ID, token: address(feeProjectToken)});
        controller.setBaseCurrency({projectId: FEE_PROJECT_ID, currency: 1});
        controller.setReservedPercent({projectId: FEE_PROJECT_ID, reservedPercent: DEFAULT_RESERVED_PERCENT});
        _addDirectoryTerminal({projectId: FEE_PROJECT_ID, term: address(terminal)});
        terminal.setAccountingContext({
            projectId: FEE_PROJECT_ID,
            token: address(terminalToken),
            currency: uint32(uint160(address(terminalToken))),
            decimals: 18
        });
        terminal.addAccountingContext({
            projectId: FEE_PROJECT_ID,
            ctx: JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        });
        store.setSurplus({projectId: FEE_PROJECT_ID, surplus: DEFAULT_SURPLUS_PER_TOKEN});
        store.setBalance({
            terminal: address(terminal), projectId: FEE_PROJECT_ID, token: address(terminalToken), balance: 10e18
        });

        // Anyone can deploy the fee project's pool.
        hook.deployPool(FEE_PROJECT_ID);

        // The LP credits were consumed and the fee claimants' credits were left alone.
        assertTrue(hook.hasDeployedPool(FEE_PROJECT_ID), "the fee project's own pool should deploy");
        assertEq(hook.accumulatedProjectCredits(FEE_PROJECT_ID), 0, "the LP credit ledger should be consumed");
        assertEq(
            jbTokens.creditBalanceOf({holder: address(hook), projectId: FEE_PROJECT_ID}),
            3e18,
            "the credits reserved for fee claimants must remain untouched"
        );
    }

    // ─── Helpers
    // ────────────────────────────────────────────────────────

    /// @notice A reserved-token context for the no-terminal project, carrying its own project token.
    /// @param amount The amount the context carries.
    /// @return context The context.
    function _buildNoTerminalReservedContext(uint256 amount) internal view returns (JBSplitHookContext memory context) {
        // Group 1 is the reserved-token group.
        return _buildContext({
            projectId: _NO_TERMINAL_PROJECT_ID, token: address(_noTerminalProjectToken), amount: amount, groupId: 1
        });
    }

    /// @notice A sqrt price in the middle of PROJECT_ID's economic corridor (always inside the band).
    /// @return sqrtPriceX96 The mid-corridor sqrt price.
    function _midCorridorSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        // Compute the corridor's tick bounds from the project's live ruleset.
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

        // The midpoint tick sits inside the corridor.
        return TickMath.getSqrtPriceAtTick((lower + upper) / 2);
    }

    /// @notice The pool key the hook would build for PROJECT_ID with a given oracle hook address.
    /// @param hooks The oracle hook address the key names.
    /// @return key The pool key.
    function _poolKeyWithHooks(address hooks) internal view returns (PoolKey memory key) {
        // Sort the two currencies the way V4 requires.
        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);

        // Use the hook's own fee and tick spacing.
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(hooks)
        });
    }
}
