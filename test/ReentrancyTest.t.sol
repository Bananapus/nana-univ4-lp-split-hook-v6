// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockJBController} from "./mock/MockJBContracts.sol";

// ═══════════════════════════════════════════════════════════════════════
// Malicious Contracts
// ═══════════════════════════════════════════════════════════════════════

/// @notice Combined controller + terminal that re-enters processSplitWith during cashOutTokensOf.
/// @dev When the hook calls cashOutTokensOf during deployPool, this contract calls back into
///      processSplitWith. Since it IS the registered controller, the msg.sender check passes.
///      The deployedPoolCount defense ensures re-entry routes to burn, not accumulation.
contract ReentrantControllerTerminal is MockJBController {
    JBUniswapV4LPSplitHook public hook;
    MockERC20 public _projectToken;
    MockERC20 public _terminalToken;
    address public storeAddr;
    uint256 public targetProjectId;

    bool public shouldReenterOnCashOut;
    bool public reentrancyAttempted;
    bool public reentrancySucceeded;
    uint256 public accumulatedDuringReentry;

    mapping(uint256 projectId => mapping(address token => JBAccountingContext)) public _contexts;

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
        shouldReenterOnCashOut = true;
    }

    // ─── Terminal interface ──────────────────────────────────────────────

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
        _contexts[pid][token] = JBAccountingContext({token: token, decimals: decimals, currency: currency});
    }

    function cashOutTokensOf(
        address, /* holder */
        uint256, /* projectId */
        uint256 cashOutCount,
        address, /* tokenToReclaim */
        uint256, /* minTokensReclaimed */
        address payable beneficiary,
        bytes calldata /* metadata */
    )
        external
        returns (uint256)
    {
        if (shouldReenterOnCashOut) {
            shouldReenterOnCashOut = false; // prevent infinite recursion
            reentrancyAttempted = true;

            // Mint project tokens to hook for the re-entrant processSplitWith call
            uint256 reentryAmount = 10e18;
            _projectToken.mint(address(hook), reentryAmount);

            // Build processSplitWith context
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

            // RE-ENTER: this contract IS the controller (registered in directory),
            // so the msg.sender == controller check passes.
            // If deployedPoolCount defense works, this goes to burn path, not accumulation.
            try hook.processSplitWith(ctx) {
                reentrancySucceeded = true;
            } catch {
                reentrancySucceeded = false;
            }

            accumulatedDuringReentry = hook.accumulatedProjectTokens(targetProjectId);
        }

        // Complete cashout normally: mint terminal tokens to beneficiary
        uint256 reclaimAmount = cashOutCount / 2;
        if (reclaimAmount > 0) {
            _terminalToken.mint(beneficiary, reclaimAmount);
        }
        return reclaimAmount;
    }

    function addToBalanceOf(
        uint256,
        address,
        uint256,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {}

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        return 0;
    }

    receive() external payable {}
}

/// @notice Fee terminal that re-enters hook functions during pay().
/// @dev Supports two re-entry modes:
///      - REBALANCE: tries to re-enter rebalanceLiquidity (blocked by permission check)
///      - COLLECT_FEES: tries to re-enter collectAndRouteLPFees (succeeds but collects 0)
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
    uint256 public payCallCount;

    constructor(
        JBUniswapV4LPSplitHook _hook,
        MockERC20 _feeProjectToken,
        uint256 _projectId,
        address _terminalToken
    ) {
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
        address, /* token */
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

        if (!reentering && reentryMode != ReentryMode.NONE) {
            reentering = true;
            reentrancyAttempted = true;

            if (reentryMode == ReentryMode.COLLECT_FEES) {
                // Re-enter collectAndRouteLPFees. Second call should collect 0 fees.
                try hook.collectAndRouteLPFees(projectId, terminalTokenAddr) {
                    // Succeeded — but collected 0 fees (already taken by outer call)
                } catch {
                    reentryReverted = true;
                }
            } else if (reentryMode == ReentryMode.REBALANCE) {
                // Re-enter rebalanceLiquidity. Should fail (no permission).
                try hook.rebalanceLiquidity(projectId, terminalTokenAddr, 0, 0) {
                    // Should NOT reach here
                } catch {
                    reentryReverted = true;
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
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}

    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════
// Test Contract
// ═══════════════════════════════════════════════════════════════════════

/// @notice Reentrancy safety tests for JBUniswapV4LPSplitHook.
/// @dev Proves that state ordering (deployedPoolCount++ before external calls),
///      access controls (SET_BUYBACK_POOL permission), and fee collection idempotency
///      prevent reentrancy from causing double-accumulation, unauthorized rebalancing,
///      or double-fee-collection.
contract ReentrancyTest is LPSplitHookV4TestBase {
    // ─────────────────────────────────────────────────────────────────────
    // Test 1: deployPool re-entry via processSplitWith
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A malicious controller+terminal re-enters processSplitWith during deployPool's
    ///         cashOutTokensOf call. The re-entry hits deployedPoolCount > 0 and routes to the
    ///         burn path instead of accumulating. No double-accumulation.
    function test_reentrancy_deployPool_cannotDoubleAccumulate() public {
        // 1. Create malicious controller+terminal
        ReentrantControllerTerminal malicious = new ReentrantControllerTerminal(
            hook, projectToken, terminalToken, address(store), PROJECT_ID
        );

        // 2. Register it as both controller and terminal for PROJECT_ID
        _setDirectoryController(PROJECT_ID, address(malicious));
        _setDirectoryTerminal(PROJECT_ID, address(terminalToken), address(malicious));

        // 3. Set up controller state (weights, prices, etc.)
        malicious.setWeight(PROJECT_ID, DEFAULT_WEIGHT);
        malicious.setFirstWeight(PROJECT_ID, DEFAULT_FIRST_WEIGHT);
        malicious.setReservedPercent(PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        malicious.setBaseCurrency(PROJECT_ID, 1);
        malicious.setPrices(address(prices));
        malicious.setTerminalAccountingContext(
            PROJECT_ID, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );

        // 4. Accumulate tokens through the malicious controller
        uint256 accumulateAmount = 1000e18;
        projectToken.mint(address(hook), accumulateAmount);

        JBSplitHookContext memory accCtx = _buildReservedContext(PROJECT_ID, accumulateAmount);
        vm.prank(address(malicious)); // malicious IS the controller
        hook.processSplitWith(accCtx);

        uint256 accBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        assertEq(accBefore, accumulateAmount, "Pre-condition: tokens accumulated");

        // 5. Enable re-entry and deploy pool
        malicious.enableReentry();

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        // 6. Verify re-entry was attempted and succeeded (via burn path)
        assertTrue(malicious.reentrancyAttempted(), "Re-entry should have been attempted during cashOutTokensOf");
        assertTrue(
            malicious.reentrancySucceeded(),
            "Re-entry should succeed (burn path, not revert) - deployedPoolCount > 0"
        );

        // 7. Verify: accumulatedProjectTokens was NOT inflated by re-entry
        // During re-entry, deployedPoolCount > 0 routes to burn path.
        // After deployPool completes, accumulatedProjectTokens is cleared to 0.
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            0,
            "No double-accumulation: tokens burned during re-entry, accumulated cleared by deploy"
        );

        // 8. Verify: during re-entry, accumulated balance was unchanged
        // (burn path does not modify accumulatedProjectTokens)
        assertEq(
            malicious.accumulatedDuringReentry(),
            accBefore,
            "Re-entry should NOT increase accumulated balance (burn path taken)"
        );

        // 9. Verify: pool deployed successfully despite re-entry
        assertTrue(
            hook.isPoolDeployed(PROJECT_ID, address(terminalToken)),
            "Pool should deploy successfully despite re-entry attempt"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test 2: rebalanceLiquidity re-entry blocked by permission
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A malicious fee terminal re-enters rebalanceLiquidity during the fee routing
    ///         pay() call. Re-entry is blocked by the SET_BUYBACK_POOL permission check —
    ///         the fee terminal is not authorized to rebalance.
    function test_reentrancy_rebalance_cannotReenter() public {
        // 1. Deploy pool normally
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        // 2. Create malicious fee terminal
        ReentrantFeeTerminal malFeeTerminal =
            new ReentrantFeeTerminal(hook, feeProjectToken, PROJECT_ID, address(terminalToken));

        // 3. Register it as the fee terminal for FEE_PROJECT_ID
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(malFeeTerminal));

        // 4. Set up LP fees to collect
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        (address token0,) = _sortForTest(address(projectToken), address(terminalToken));

        uint256 feeAmount = 50e18;
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees(tokenId, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, feeAmount);
        }
        terminalToken.mint(address(positionManager), feeAmount);

        // 5. Enable re-entry mode: try to re-enter rebalanceLiquidity
        malFeeTerminal.setReentryMode(ReentrantFeeTerminal.ReentryMode.REBALANCE);

        // 6. Call rebalanceLiquidity (owner has implicit SET_BUYBACK_POOL permission)
        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        // 7. Verify: re-entry was attempted but blocked by permission check
        assertTrue(malFeeTerminal.reentrancyAttempted(), "Re-entry should have been attempted during pay()");
        assertTrue(malFeeTerminal.reentryReverted(), "Re-entry should revert (fee terminal lacks SET_BUYBACK_POOL)");

        // 8. Verify: position still exists (rebalance completed successfully)
        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != 0, "Position should exist after successful rebalance");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Test 3: collectAndRouteLPFees idempotent under re-entry
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A malicious fee terminal re-enters collectAndRouteLPFees during the fee routing
    ///         pay() call. The second call collects 0 fees (already taken from PositionManager).
    ///         No double-counting of LP fees.
    function test_reentrancy_collectFees_idempotent() public {
        // 1. Deploy pool normally
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        // 2. Create malicious fee terminal
        ReentrantFeeTerminal malFeeTerminal =
            new ReentrantFeeTerminal(hook, feeProjectToken, PROJECT_ID, address(terminalToken));

        // 3. Register it as the fee terminal for FEE_PROJECT_ID
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(malFeeTerminal));

        // 4. Set up LP fees to collect
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        (address token0,) = _sortForTest(address(projectToken), address(terminalToken));

        uint256 feeAmount = 50e18;
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees(tokenId, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, feeAmount);
        }
        terminalToken.mint(address(positionManager), feeAmount);

        // 5. Enable re-entry mode: re-enter collectAndRouteLPFees during pay()
        malFeeTerminal.setReentryMode(ReentrantFeeTerminal.ReentryMode.COLLECT_FEES);

        // 6. Record state before
        uint256 claimableBefore = hook.claimableFeeTokens(PROJECT_ID);

        // 7. Call collectAndRouteLPFees (permissionless)
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // 8. Verify: re-entry was attempted
        assertTrue(malFeeTerminal.reentrancyAttempted(), "Re-entry should have been attempted during pay()");

        // 9. Verify: fees were collected (claimable increased)
        uint256 claimableAfter = hook.claimableFeeTokens(PROJECT_ID);
        assertTrue(claimableAfter > claimableBefore, "LP fees should have been collected and routed");

        // 10. Verify: PositionManager fees fully drained (no leftover for double-collection)
        uint256 feesLeft0 = positionManager.collectableAmount0(tokenId);
        uint256 feesLeft1 = positionManager.collectableAmount1(tokenId);
        assertEq(feesLeft0, 0, "All token0 fees should be collected after single collection");
        assertEq(feesLeft1, 0, "All token1 fees should be collected after single collection");

        // 11. Verify: calling collectAndRouteLPFees again collects nothing more
        uint256 claimableBeforeSecond = hook.claimableFeeTokens(PROJECT_ID);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));
        uint256 claimableAfterSecond = hook.claimableFeeTokens(PROJECT_ID);
        assertEq(
            claimableAfterSecond,
            claimableBeforeSecond,
            "Second collection should yield 0 additional fees (idempotent)"
        );
    }

    // ─── Internal helpers ────────────────────────────────────────────────

    function _sortForTest(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
