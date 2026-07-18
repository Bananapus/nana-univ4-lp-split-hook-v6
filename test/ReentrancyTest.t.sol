// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockJBController} from "./mock/MockJBContracts.sol";

// ═══════════════════════════════════════════════════════════════════════
// Malicious Contracts
// ═══════════════════════════════════════════════════════════════════════

/// @notice Combined controller + terminal that re-enters `processSplitWith` during `addToBalanceOf`.
/// @dev Registered as BOTH the project's controller and its terminal, so the `msg.sender == controller` check in
///      `processSplitWith` passes on the nested call. The reentry point is `addToBalanceOf`: the hook's
///      single-sided (asks-only) mint always leaves the full terminal-token side uninvested, so
///      `_consolidateAndReMint` -> `_carryLeftovers` -> `_addToProjectBalance` always calls back into whatever
///      terminal is registered — a genuine, reachable external call inside `deployPool`'s own call graph (unlike
///      the removed cash-out path, which no longer exists in the single-sided design).
contract ReentrantControllerTerminal is MockJBController {
    JBUniswapV4LPSplitHook public hook;
    MockERC20 public _projectToken;
    MockERC20 public _terminalToken;
    address public storeAddr;
    uint256 public targetProjectId;

    bool public shouldReenterOnAddToBalance;
    bool public reentrancyAttempted;
    bool public reentrancySucceeded;
    bytes4 public reentryRevertSelector;
    uint256 public accumulatedDuringReentry;

    mapping(uint256 projectId => mapping(address token => JBAccountingContext)) public _contexts;
    mapping(uint256 projectId => JBAccountingContext[]) public _contextsList;

    constructor(
        JBUniswapV4LPSplitHook _hook,
        MockERC20 projToken,
        MockERC20 termToken,
        address _store,
        uint256 _projectId
    ) {
        hook = _hook;
        _projectToken = projToken;
        _terminalToken = termToken;
        storeAddr = _store;
        targetProjectId = _projectId;
    }

    function enableReentry() external {
        shouldReenterOnAddToBalance = true;
    }

    // ─── Terminal interface
    // ──────────────────────────────────────────────

    function STORE() external view returns (address) {
        return storeAddr;
    }

    function accountingContextForTokenOf(uint256 pid, address token)
        external
        view
        returns (JBAccountingContext memory)
    {
        return _contexts[pid][token];
    }

    function setTerminalAccountingContext(uint256 pid, address token, uint32 currency, uint8 decimals) external {
        JBAccountingContext memory context = JBAccountingContext({token: token, decimals: decimals, currency: currency});
        _contexts[pid][token] = context;
        _contextsList[pid].push(context);
    }

    function accountingContextsOf(uint256 pid) external view returns (JBAccountingContext[] memory) {
        return _contextsList[pid];
    }

    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        if (amount > 0 && token != address(0x000000000000000000000000000000000000EEEe)) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }

        if (shouldReenterOnAddToBalance) {
            shouldReenterOnAddToBalance = false; // prevent infinite recursion
            reentrancyAttempted = true;

            // Mint project tokens to this contract (the controller) and approve the hook.
            uint256 reentryAmount = 10e18;
            _projectToken.mint(address(this), reentryAmount);
            _projectToken.approve(address(hook), reentryAmount);

            JBSplitHookContext memory ctx = JBSplitHookContext({
                token: address(_projectToken),
                amount: reentryAmount,
                decimals: 18,
                projectId: targetProjectId,
                groupId: 1,
                split: JBSplit({
                    percent: 1_000_000,
                    projectId: 0,
                    beneficiary: payable(address(0)),
                    preferAddToBalance: false,
                    lockedUntil: 0,
                    hook: IJBSplitHook(address(hook))
                })
            });

            // RE-ENTER mid-`deployPool`: this contract IS the registered controller, so the msg.sender ==
            // controller check inside `processSplitWith` passes. The `nonReentrant` guard is what must block
            // this — not an incidental accounting revert.
            try hook.processSplitWith(ctx) {
                reentrancySucceeded = true;
            } catch (bytes memory reason) {
                reentrancySucceeded = false;
                reentryRevertSelector = _extractSelector(reason);
            }

            accumulatedDuringReentry = hook.accumulatedProjectTokens(targetProjectId);
        }
    }

    function pay(
        uint256,
        address token,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        if (amount > 0 && token != address(0x000000000000000000000000000000000000EEEe)) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }
        return 0;
    }

    function _extractSelector(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        // forge-lint: disable-next-line(unsafe-typecast)
        assembly {
            selector := mload(add(reason, 32))
        }
    }

    receive() external payable {}
}

/// @notice Fee terminal that re-enters hook functions during `pay()`.
/// @dev Supports two re-entry modes:
///      - REBALANCE: re-enters `rebalanceLiquidity` (permissionless — must now be blocked by the `nonReentrant`
///        guard, since no permission check exists to save it anymore).
///      - COLLECT_FEES: re-enters `collectAndRouteLPFees` (also guarded; the outer call still completes and
///        collects fees exactly once).
contract ReentrantFeeTerminal {
    JBUniswapV4LPSplitHook public hook;
    MockERC20 public feeProjectToken;
    uint256 public projectId;
    address public terminalTokenAddr;

    enum ReentryMode {
        NONE,
        COLLECT_FEES,
        REBALANCE
    }

    ReentryMode public reentryMode;
    bool public reentering;
    bool public reentrancyAttempted;
    bool public reentryReverted;
    bytes4 public reentryRevertSelector;
    uint256 public payCallCount;

    constructor(JBUniswapV4LPSplitHook _hook, MockERC20 _feeProjectToken, uint256 _projectId, address _terminalToken) {
        hook = _hook;
        feeProjectToken = _feeProjectToken;
        projectId = _projectId;
        terminalTokenAddr = _terminalToken;
    }

    function setReentryMode(ReentryMode mode) external {
        reentryMode = mode;
    }

    function pay(
        uint256, /* projectId */
        address token,
        uint256 amount,
        address beneficiary,
        uint256, /* minReturnedTokens */
        string calldata, /* memo */
        bytes calldata /* metadata */
    )
        external
        payable
        returns (uint256)
    {
        payCallCount++;

        if (amount > 0 && token != address(0x000000000000000000000000000000000000EEEe)) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }

        if (!reentering && reentryMode != ReentryMode.NONE) {
            reentering = true;
            reentrancyAttempted = true;

            if (reentryMode == ReentryMode.COLLECT_FEES) {
                // Re-enter collectAndRouteLPFees. Blocked by the `nonReentrant` guard.
                try hook.collectAndRouteLPFees(projectId, terminalTokenAddr) {
                // Should NOT reach here.
                }
                catch (bytes memory reason) {
                    reentryReverted = true;
                    reentryRevertSelector = _extractSelector(reason);
                }
            } else if (reentryMode == ReentryMode.REBALANCE) {
                // Re-enter rebalanceLiquidity. `rebalanceLiquidity` is permissionless, so only the `nonReentrant`
                // guard can stop this now.
                try hook.rebalanceLiquidity(projectId, terminalTokenAddr) {
                // Should NOT reach here.
                }
                catch (bytes memory reason) {
                    reentryReverted = true;
                    reentryRevertSelector = _extractSelector(reason);
                }
            }

            reentering = false;
        }

        // Mint fee project tokens to beneficiary (simulate payment)
        if (amount > 0 && beneficiary != address(0)) {
            feeProjectToken.mint(beneficiary, amount);
        }

        return amount;
    }

    function accountingContextForTokenOf(uint256, address token) external pure returns (JBAccountingContext memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}

    function _extractSelector(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        // forge-lint: disable-next-line(unsafe-typecast)
        assembly {
            selector := mload(add(reason, 32))
        }
    }

    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════
// Test Contract
// ═══════════════════════════════════════════════════════════════════════

/// @notice Reentrancy safety tests for JBUniswapV4LPSplitHook.
/// @dev The hook's six external state-changing entry points (`deployPool`, `addLiquidity`, `rebalanceLiquidity`,
///      `collectAndRouteLPFees`, `claimFeeTokensFor`, `processSplitWith`) are all guarded by solady's
///      `ReentrancyGuard.nonReentrant`. These tests prove that a malicious controller/terminal/fee-terminal that
///      re-enters the hook mid-call is blocked deterministically by the guard — not by an incidental
///      accounting revert or a permission check that happens to still apply.
contract ReentrancyTest is LPSplitHookV4TestBase {
    // ─────────────────────────────────────────────────────────────────────
    // Test 1: deployPool re-entry via addToBalanceOf is blocked by the guard
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A malicious controller+terminal re-enters `processSplitWith` during `deployPool`'s
    ///         `addToBalanceOf` call (triggered by uninvested terminal-token dust from the single-sided mint).
    ///         The `nonReentrant` guard on `processSplitWith` blocks the nested call deterministically; the
    ///         outer `deployPool` call still completes successfully.
    function test_reentrancy_deployPool_reentryAccumulatesSafely() public {
        // 1. Create malicious controller+terminal.
        ReentrantControllerTerminal malicious =
            new ReentrantControllerTerminal(hook, projectToken, terminalToken, address(store), PROJECT_ID);

        // 2. Register it as both controller and terminal for PROJECT_ID.
        _setDirectoryController(PROJECT_ID, address(malicious));
        _setDirectoryTerminal(PROJECT_ID, address(terminalToken), address(malicious));
        _addDirectoryTerminal(PROJECT_ID, address(malicious));

        // 3. Set up controller state (weights, prices, etc.).
        malicious.setWeight(PROJECT_ID, DEFAULT_WEIGHT);
        malicious.setFirstWeight(PROJECT_ID, DEFAULT_FIRST_WEIGHT);
        malicious.setReservedPercent(PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        malicious.setBaseCurrency(PROJECT_ID, 1);
        malicious.setPrices(address(prices));
        malicious.setTerminalAccountingContext(
            PROJECT_ID, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );
        store.setBalance(address(malicious), PROJECT_ID, address(terminalToken), 10e18);

        // 4. Fund the hook with real terminal-token dust, and configure the mock PositionManager to only use 80% of
        // the amounts offered to MINT_POSITION (matching the pattern other tests use to exercise leftover-carry
        // behavior). The unconsumed 20% is carried forward through `_addToProjectBalance` -> `addToBalanceOf` — a
        // genuine external call reachable inside `deployPool`.
        terminalToken.mint(address(hook), 10e18);
        positionManager.setUsagePercent(8000);

        // 5. Accumulate tokens through the malicious controller.
        uint256 accumulateAmount = 1000e18;
        projectToken.mint(address(malicious), accumulateAmount);

        vm.startPrank(address(malicious)); // malicious IS the controller
        projectToken.approve(address(hook), accumulateAmount);
        JBSplitHookContext memory accCtx = _buildReservedContext(PROJECT_ID, accumulateAmount);
        hook.processSplitWith(accCtx);
        vm.stopPrank();

        uint256 accBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        assertEq(accBefore, accumulateAmount, "Pre-condition: tokens accumulated");

        // 6. Enable re-entry and deploy the pool.
        malicious.enableReentry();

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // 7. The reentrant call into `processSplitWith` was attempted from inside `addToBalanceOf`, and the
        // `nonReentrant` guard blocked it deterministically.
        assertTrue(malicious.reentrancyAttempted(), "Re-entry should have been attempted during addToBalanceOf");
        assertFalse(malicious.reentrancySucceeded(), "Re-entrant processSplitWith must be blocked by the guard");
        assertEq(
            malicious.reentryRevertSelector(),
            ReentrancyGuard.Reentrancy.selector,
            "Blocked re-entry must revert specifically via the nonReentrant guard, not some other error"
        );

        // 8. Because the guard reverts before the callee's body runs, the blocked re-entry adds nothing beyond the
        // 20% project-token leftover the legitimate mint (at 80% usage) already carried back into the ledger —
        // reading the ledger from inside the blocked callback proves the re-entry itself contributed zero.
        uint256 legitimateLeftover = 200e18; // 20% of the 1000e18 deploy amount, per positionManager.setUsagePercent
        assertEq(
            malicious.accumulatedDuringReentry(),
            legitimateLeftover,
            "Blocked re-entry must not add anything beyond the legitimate carried-forward leftover"
        );
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            legitimateLeftover,
            "Ledger holds only the legitimate leftover; nothing from the blocked re-entry"
        );
        assertEq(malicious.burnCallCount(), 0, "no burn should occur on a first deployment");

        // 9. Verify: pool deployed successfully despite the blocked re-entry attempt.
        assertTrue(
            hook.isPoolDeployed(PROJECT_ID, address(terminalToken)),
            "Pool should deploy successfully despite re-entry attempt"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test 2: rebalanceLiquidity re-entry is blocked by the guard (not by a permission check)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A malicious fee terminal re-enters `rebalanceLiquidity` during the fee-routing `pay()` call.
    ///         `rebalanceLiquidity` is permissionless, so nothing but the `nonReentrant` guard can stop this —
    ///         proving the fix replaces an incidental (and fragile) underflow revert with a deterministic one.
    function test_reentrancy_rebalance_cannotReenter() public {
        // 1. Deploy pool normally.
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        // Move the economic corridor (drop issuance ~10%) so the rebalance clears its corridor-drift guard and reaches
        // the pre-burn fee-routing `pay()` that triggers the re-entry under test.
        controller.setWeight(PROJECT_ID, 900e18);

        // 2. Create malicious fee terminal.
        ReentrantFeeTerminal malFeeTerminal =
            new ReentrantFeeTerminal(hook, feeProjectToken, PROJECT_ID, address(terminalToken));

        // 3. Register it as the fee terminal for FEE_PROJECT_ID.
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(malFeeTerminal));

        // 4. Set up LP fees to collect.
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        (address token0,) = _sortForTest(address(projectToken), address(terminalToken));

        uint256 feeAmount = 50e18;
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees(tokenId, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, feeAmount);
        }
        terminalToken.mint(address(positionManager), feeAmount);

        // The prior `deployPool` minted a single-sided (100% project-token) position, so burning it recovers no
        // terminal-token principal, and every collected LP fee (terminal-token side) is routed straight out to the
        // fee terminal / project balance before the re-mint. Fund the hook with independent terminal-token
        // principal (e.g. dust from an earlier partial add) so the re-centered two-sided re-mint has a non-zero
        // terminal-token side to work with — otherwise the re-mint degenerates to zero liquidity for reasons
        // unrelated to reentrancy, masking the guard assertions below.
        terminalToken.mint(address(hook), 100e18);

        // 5. Enable re-entry mode: try to re-enter rebalanceLiquidity.
        malFeeTerminal.setReentryMode(ReentrantFeeTerminal.ReentryMode.REBALANCE);

        // 6. Call rebalanceLiquidity as an arbitrary, unpermissioned caller — it's permissionless by design.
        vm.prank(user);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken));

        // 7. Verify: re-entry was attempted, and specifically blocked by the `nonReentrant` guard — the old
        // "no permission" defense no longer exists (rebalanceLiquidity is permissionless), so the guard is the
        // only thing standing between this and the arithmetic-underflow footgun the fix removes.
        assertTrue(malFeeTerminal.reentrancyAttempted(), "Re-entry should have been attempted during pay()");
        assertTrue(malFeeTerminal.reentryReverted(), "Re-entry must revert");
        assertEq(
            malFeeTerminal.reentryRevertSelector(),
            ReentrancyGuard.Reentrancy.selector,
            "Re-entry must revert specifically via the nonReentrant guard, not an incidental underflow"
        );

        // 8. Verify: position still exists (rebalance completed successfully) despite the blocked re-entry.
        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(newTokenId, 0, "Position should exist after successful rebalance");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test 3: collectAndRouteLPFees idempotent under re-entry
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A malicious fee terminal re-enters collectAndRouteLPFees during the fee routing
    ///         pay() call. The nested call is blocked by the `nonReentrant` guard, so it collects nothing
    ///         (rather than succeeding with zero effect) — either way, no double-counting of LP fees.
    function test_reentrancy_collectFees_idempotent() public {
        // 1. Deploy pool normally.
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        // 2. Create malicious fee terminal.
        ReentrantFeeTerminal malFeeTerminal =
            new ReentrantFeeTerminal(hook, feeProjectToken, PROJECT_ID, address(terminalToken));

        // 3. Register it as the fee terminal for FEE_PROJECT_ID.
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(malFeeTerminal));

        // 4. Set up LP fees to collect.
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        (address token0,) = _sortForTest(address(projectToken), address(terminalToken));

        uint256 feeAmount = 50e18;
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees(tokenId, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, feeAmount);
        }
        terminalToken.mint(address(positionManager), feeAmount);

        // 5. Enable re-entry mode: re-enter collectAndRouteLPFees during pay().
        malFeeTerminal.setReentryMode(ReentrantFeeTerminal.ReentryMode.COLLECT_FEES);

        // 6. Record state before.
        uint256 claimableBefore = hook.claimableFeeTokens(PROJECT_ID);

        // 7. Call collectAndRouteLPFees (permissionless).
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // 8. Verify: re-entry was attempted, and blocked by the guard.
        assertTrue(malFeeTerminal.reentrancyAttempted(), "Re-entry should have been attempted during pay()");
        assertTrue(malFeeTerminal.reentryReverted(), "Nested collectAndRouteLPFees must be blocked by the guard");

        // 9. Verify: fees were collected (claimable increased) by the OUTER call.
        uint256 claimableAfter = hook.claimableFeeTokens(PROJECT_ID);
        assertTrue(claimableAfter > claimableBefore, "LP fees should have been collected and routed");

        // 10. Verify: PositionManager fees fully drained (no leftover for double-collection).
        uint256 feesLeft0 = positionManager.collectableAmount0(tokenId);
        uint256 feesLeft1 = positionManager.collectableAmount1(tokenId);
        assertEq(feesLeft0, 0, "All token0 fees should be collected after single collection");
        assertEq(feesLeft1, 0, "All token1 fees should be collected after single collection");

        // 11. Verify: calling collectAndRouteLPFees again collects nothing more.
        uint256 claimableBeforeSecond = hook.claimableFeeTokens(PROJECT_ID);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));
        uint256 claimableAfterSecond = hook.claimableFeeTokens(PROJECT_ID);
        assertEq(
            claimableAfterSecond, claimableBeforeSecond, "Second collection should yield 0 additional fees (idempotent)"
        );
    }

    // ─── Internal helpers
    // ────────────────────────────────────────────────

    function _sortForTest(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
