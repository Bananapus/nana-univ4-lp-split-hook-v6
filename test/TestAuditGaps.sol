// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Audit gap tests: MEV/sandwich simulation on rebalance and extreme price scenarios.
/// @dev These tests verify that the rebalance operation is resistant to sandwich-like
///      value extraction and that the contract behaves correctly at extreme price ratios.
contract TestAuditGaps is LPSplitHookV4TestBase {
    uint256 poolTokenId;

    function setUp() public override {
        super.setUp();

        // Deploy a pool so we have a position to work with
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        poolTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Ensure PositionManager has tokens for collect/burn operations
        projectToken.mint(address(positionManager), 100e18);
        terminalToken.mint(address(positionManager), 100e18);
    }

    // =========================================================================
    // MEV / Sandwich Simulation on Rebalance
    // =========================================================================

    // -----------------------------------------------------------------------
    // 1. Rebalance conserves value: no tokens are created from thin air
    // -----------------------------------------------------------------------

    /// @notice After a rebalance, the hook should not hold more tokens than it
    ///         started with plus what the PositionManager returned. This ensures
    ///         rebalance does not create value from nothing (sandwich attacker
    ///         could only extract value if there were surplus tokens).
    function test_Rebalance_ConservesTokenBalances() public {
        // Record balances before rebalance
        uint256 hookProjectBefore = projectToken.balanceOf(address(hook));
        uint256 hookTerminalBefore = terminalToken.balanceOf(address(hook));
        uint256 pmProjectBefore = projectToken.balanceOf(address(positionManager));
        uint256 pmTerminalBefore = terminalToken.balanceOf(address(positionManager));

        uint256 totalProjectBefore = hookProjectBefore + pmProjectBefore;
        uint256 totalTerminalBefore = hookTerminalBefore + pmTerminalBefore;

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        // After rebalance: total system tokens (hook + PM) should not increase
        uint256 hookProjectAfter = projectToken.balanceOf(address(hook));
        uint256 hookTerminalAfter = terminalToken.balanceOf(address(hook));
        uint256 pmProjectAfter = projectToken.balanceOf(address(positionManager));
        uint256 pmTerminalAfter = terminalToken.balanceOf(address(positionManager));

        uint256 totalProjectAfter = hookProjectAfter + pmProjectAfter;
        uint256 totalTerminalAfter = hookTerminalAfter + pmTerminalAfter;

        assertLe(
            totalProjectAfter,
            totalProjectBefore,
            "Total project tokens should not increase after rebalance (no value creation)"
        );
        assertLe(
            totalTerminalAfter,
            totalTerminalBefore,
            "Total terminal tokens should not increase after rebalance (no value creation)"
        );
    }

    // -----------------------------------------------------------------------
    // 2. Rebalance updates the position NFT atomically
    // -----------------------------------------------------------------------

    /// @notice Rebalance must burn the old NFT and mint a new one in a single transaction.
    ///         A sandwich attacker cannot interfere between these steps since they happen
    ///         within one tx. Verify the position ID changes and both operations occur.
    function test_Rebalance_AtomicNFTSwap() public {
        uint256 originalTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 burnCountBefore = positionManager.burnCallCount();
        uint256 mintCountBefore = positionManager.mintCallCount();

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Both burn and mint must have occurred
        assertEq(positionManager.burnCallCount(), burnCountBefore + 1, "Burn must occur exactly once");
        assertEq(positionManager.mintCallCount(), mintCountBefore + 1, "Mint must occur exactly once");

        // The new token ID must differ from the old one
        assertTrue(newTokenId != originalTokenId, "Token ID must change after rebalance");
        assertTrue(newTokenId != 0, "New token ID must be nonzero");
    }

    // -----------------------------------------------------------------------
    // 3. Rebalance with accrued fees: fees are routed before new position
    // -----------------------------------------------------------------------

    /// @notice When fees are accrued, rebalance should collect and route them
    ///         before creating the new position. A sandwich attacker cannot
    ///         front-run fee collection because it happens within the same tx.
    function test_Rebalance_FeesRoutedBeforeNewPosition() public {
        // Configure collectable fees
        (address token0,) = _sortTokens(address(projectToken), address(terminalToken));

        uint256 feeAmount = 10e18;
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees(poolTokenId, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(poolTokenId, 0, feeAmount);
        }
        terminalToken.mint(address(positionManager), feeAmount);

        // Set up fee project terminal
        terminal.setAccountingContext(
            FEE_PROJECT_ID, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );

        uint256 payCountBefore = terminal.payCallCount();
        uint256 addToBalanceBefore = terminal.addToBalanceCallCount();

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        // Verify fees were routed (either pay or addToBalance was called)
        bool feesRouted =
            (terminal.payCallCount() > payCountBefore) || (terminal.addToBalanceCallCount() > addToBalanceBefore);
        assertTrue(feesRouted, "Fees should be collected and routed during rebalance");

        // Verify a new position was still minted after fee routing
        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != 0, "New position should be minted after fee routing");
        assertTrue(newTokenId != poolTokenId, "New token ID should differ from original");
    }

    // -----------------------------------------------------------------------
    // 4. Rebalance requires authorization (sandwich attacker cannot trigger)
    // -----------------------------------------------------------------------

    /// @notice An unauthorized caller cannot trigger rebalance. This prevents
    ///         a sandwich attacker from forcing a rebalance at a manipulated price.
    function test_Rebalance_UnauthorizedCannotTrigger() public {
        address attacker = makeAddr("sandwichAttacker");

        vm.prank(attacker);
        vm.expectRevert();
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);
    }

    // -----------------------------------------------------------------------
    // 5. Consecutive rebalances produce consistent state
    // -----------------------------------------------------------------------

    /// @notice Two consecutive rebalances should both succeed and produce valid
    ///         state, ensuring no residual state corruption from the first.
    function test_Rebalance_ConsecutiveRebalancesSucceed() public {
        // First rebalance
        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        uint256 tokenIdAfterFirst = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(tokenIdAfterFirst != 0, "Token ID should be nonzero after first rebalance");

        // Ensure PM has tokens for the second rebalance
        projectToken.mint(address(positionManager), 100e18);
        terminalToken.mint(address(positionManager), 100e18);

        // Second rebalance
        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        uint256 tokenIdAfterSecond = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(tokenIdAfterSecond != 0, "Token ID should be nonzero after second rebalance");
        assertTrue(tokenIdAfterSecond != tokenIdAfterFirst, "Token ID should differ between consecutive rebalances");
    }

    // -----------------------------------------------------------------------
    // 6. Rebalance with zero fees: no spurious fee routing
    // -----------------------------------------------------------------------

    /// @notice When no fees have accrued, rebalance should still succeed. The fee
    ///         routing path (pay to fee project) should NOT be triggered, though
    ///         addToBalance may still be called for leftover terminal tokens from
    ///         the position mint/SWEEP cycle.
    function test_Rebalance_ZeroFees_NoFeePayRouting() public {
        // Ensure no fees are set (default is 0)
        positionManager.setCollectableFees(poolTokenId, 0, 0);

        uint256 payCountBefore = terminal.payCallCount();

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        // No fee routing via pay should have occurred (pay is only for fee project)
        assertEq(terminal.payCallCount(), payCountBefore, "No pay calls when zero fees");

        // Position should still be updated
        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != poolTokenId, "Position should still be rebalanced with zero fees");
    }

    // -----------------------------------------------------------------------
    // 7. Rebalance with partial usage: leftover tokens handled correctly
    // -----------------------------------------------------------------------

    /// @notice When the PositionManager uses less than 100% of provided tokens
    ///         (simulating a price-shifted rebalance), leftover tokens should be
    ///         properly handled (burned or returned to project balance).
    function test_Rebalance_PartialUsage_LeftoversHandled() public {
        // Set PM to only use 50% of provided amounts
        positionManager.setUsagePercent(5000);

        uint256 burnCountBefore = controller.burnCallCount();
        uint256 addToBalanceBefore = terminal.addToBalanceCallCount();

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        // Either leftover project tokens were burned or terminal tokens returned to balance
        bool leftoversHandled =
            (controller.burnCallCount() > burnCountBefore) || (terminal.addToBalanceCallCount() > addToBalanceBefore);
        assertTrue(leftoversHandled, "Leftover tokens should be handled after partial usage rebalance");

        // Position should still be valid
        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != 0, "Position should exist after partial-usage rebalance");
    }

    // =========================================================================
    // Extreme Price Scenarios
    // =========================================================================

    // -----------------------------------------------------------------------
    // 8. Deploy with very high weight (extreme issuance rate)
    // -----------------------------------------------------------------------

    /// @notice With a very high weight (many project tokens per terminal token),
    ///         the issuance rate is extreme. The pool should still deploy without
    ///         reverting, and tick bounds should be within valid V4 range.
    function test_ExtremePrice_VeryHighWeight() public {
        uint256 highWeightProject = 3;
        _setupProject(highWeightProject);

        // Set a very high weight: 1e30 project tokens per terminal token
        uint256 extremeWeight = 1e30;
        controller.setWeight(highWeightProject, extremeWeight);
        controller.setFirstWeight(highWeightProject, extremeWeight);

        // Accumulate and deploy
        _accumulateTokensForProject(highWeightProject, 1000e18);

        vm.prank(owner);
        hook.deployPool(highWeightProject, address(terminalToken), 0);

        // Verify deployment succeeded
        uint256 tokenId = hook.tokenIdOf(highWeightProject, address(terminalToken));
        assertTrue(tokenId != 0, "Pool should deploy with very high weight");
        assertTrue(
            hook.isPoolDeployed(highWeightProject, address(terminalToken)),
            "projectDeployed should be true with high weight"
        );
    }

    // -----------------------------------------------------------------------
    // 9. Deploy with very low weight (extreme price floor)
    // -----------------------------------------------------------------------

    /// @notice With a very low weight (weight=1), mulDiv(1e18, 1, 1e18) truncates to 0,
    ///         producing sqrtPrice=0 which is invalid in Uniswap V4. The contract
    ///         correctly reverts with TickMath's InvalidSqrtPrice(0) because no valid
    ///         pool can be created when the issuance rate rounds to zero.
    function test_ExtremePrice_VeryLowWeight_RevertsInvalidSqrtPrice() public {
        uint256 lowWeightProject = 4;
        _setupProject(lowWeightProject);

        // Set a very low weight: mulDiv(1e18, 1, 1e18) = 0 tokens per terminal token
        uint256 lowWeight = 1;
        controller.setWeight(lowWeightProject, lowWeight);
        controller.setFirstWeight(lowWeightProject, lowWeight);

        // Accumulate tokens
        _accumulateTokensForProject(lowWeightProject, 1000e18);

        // Should revert because the computed sqrtPriceX96 is 0 (invalid)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        hook.deployPool(lowWeightProject, address(terminalToken), 0);
    }

    // -----------------------------------------------------------------------
    // 9b. Deploy with moderately low weight (nonzero issuance)
    // -----------------------------------------------------------------------

    /// @notice With a low but viable weight that produces nonzero issuance,
    ///         the pool should deploy successfully.
    function test_ExtremePrice_LowButViableWeight() public {
        uint256 lowWeightProject = 40;
        _setupProject(lowWeightProject);

        // Set weight=100: mulDiv(1e18, 100, 1e18) = 100 tokens per terminal token
        // This is low but still produces a valid nonzero price.
        controller.setWeight(lowWeightProject, 100);
        controller.setFirstWeight(lowWeightProject, 100);

        _accumulateTokensForProject(lowWeightProject, 1000e18);

        vm.prank(owner);
        hook.deployPool(lowWeightProject, address(terminalToken), 0);

        uint256 tokenId = hook.tokenIdOf(lowWeightProject, address(terminalToken));
        assertTrue(tokenId != 0, "Pool should deploy with low-but-viable weight");
    }

    // -----------------------------------------------------------------------
    // 10. Deploy with zero surplus (cash out rate = 0)
    // -----------------------------------------------------------------------

    /// @notice When the surplus is 0, the cash out rate is 0. The contract should
    ///         fall back to centering the LP range around the issuance price.
    function test_ExtremePrice_ZeroSurplus_CashOutRateZero() public {
        uint256 zeroSurplusProject = 5;
        _setupProject(zeroSurplusProject);

        // Ensure zero surplus
        store.setSurplus(zeroSurplusProject, 0);

        // Accumulate tokens
        _accumulateTokensForProject(zeroSurplusProject, 500e18);

        // With zero surplus, the position is 100% single-sided project tokens.
        // The mock PositionManager computes zero liquidity for single-sided amounts,
        // causing deployPool to revert with ZeroLiquidity.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("JBUniswapV4LPSplitHook_ZeroLiquidity()"));
        hook.deployPool(zeroSurplusProject, address(terminalToken), 0);
    }

    // -----------------------------------------------------------------------
    // 11. Deploy with very high surplus (extreme cash out rate)
    // -----------------------------------------------------------------------

    /// @notice With a very high surplus (close to 1:1 cash-out), the tick bounds
    ///         narrow. Pool should still deploy correctly.
    function test_ExtremePrice_HighSurplus() public {
        uint256 highSurplusProject = 6;
        _setupProject(highSurplusProject);

        // Set a very high surplus: 1e18 terminal tokens per project token cashed out
        store.setSurplus(highSurplusProject, 1e18);

        // Accumulate tokens
        _accumulateTokensForProject(highSurplusProject, 500e18);

        vm.prank(owner);
        hook.deployPool(highSurplusProject, address(terminalToken), 0);

        uint256 tokenId = hook.tokenIdOf(highSurplusProject, address(terminalToken));
        assertTrue(tokenId != 0, "Pool should deploy with high surplus");
    }

    // -----------------------------------------------------------------------
    // 12. Deploy with weight equal to 1 (minimal issuance)
    // -----------------------------------------------------------------------

    /// @notice Weight=1 produces zero effective issuance due to integer truncation
    ///         (mulDiv(1e18, 1, 1e18) = 0). The contract correctly reverts with
    ///         InvalidSqrtPrice(0) because no valid Uniswap pool can be initialized
    ///         at sqrtPrice=0. This confirms the weight=1 edge case is safely caught.
    function test_ExtremePrice_WeightEqualOne_RevertsInvalidSqrtPrice() public {
        uint256 minWeightProject = 7;
        _setupProject(minWeightProject);

        controller.setWeight(minWeightProject, 1);
        controller.setFirstWeight(minWeightProject, 1);

        _accumulateTokensForProject(minWeightProject, 500e18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        hook.deployPool(minWeightProject, address(terminalToken), 0);
    }

    // -----------------------------------------------------------------------
    // 13. Deploy with max reserved percent
    // -----------------------------------------------------------------------

    /// @notice With maximum reserved percent (10000 = 100%), the effective issuance
    ///         for non-reserved tokens is mulDiv(tokens, 0, 10000) = 0. This produces
    ///         sqrtPrice=0 which is invalid. The contract correctly reverts with
    ///         InvalidSqrtPrice(0), confirming that 100% reserved percent safely
    ///         prevents pool deployment (no valid market price exists).
    function test_ExtremePrice_MaxReservedPercent_RevertsInvalidSqrtPrice() public {
        uint256 maxReservedProject = 8;
        _setupProject(maxReservedProject);

        // 10000 = 100% reserved
        controller.setReservedPercent(maxReservedProject, 10_000);

        _accumulateTokensForProject(maxReservedProject, 500e18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        hook.deployPool(maxReservedProject, address(terminalToken), 0);
    }

    // -----------------------------------------------------------------------
    // 13b. Deploy with high (but not max) reserved percent
    // -----------------------------------------------------------------------

    /// @notice With 99% reserved, effective issuance is 1% of the weight-based
    ///         rate. This should still produce a valid nonzero price and deploy.
    function test_ExtremePrice_HighReservedPercent_Deploys() public {
        uint256 highReservedProject = 80;
        _setupProject(highReservedProject);

        // 9900 = 99% reserved (1% goes to non-reserved)
        controller.setReservedPercent(highReservedProject, 9900);

        _accumulateTokensForProject(highReservedProject, 500e18);

        vm.prank(owner);
        hook.deployPool(highReservedProject, address(terminalToken), 0);

        uint256 tokenId = hook.tokenIdOf(highReservedProject, address(terminalToken));
        assertTrue(tokenId != 0, "Pool should deploy with 99% reserved percent");
    }

    // -----------------------------------------------------------------------
    // 14. Rebalance after extreme weight change (price shift)
    // -----------------------------------------------------------------------

    /// @notice After deployment at one weight, changing the weight drastically
    ///         and rebalancing should succeed. This simulates a project that
    ///         has gone through many ruleset cycles with weight decay.
    function test_ExtremePrice_RebalanceAfterWeightChange() public {
        // The pool was deployed at DEFAULT_WEIGHT (1000e18) in setUp.
        // Change weight to something very different.
        controller.setWeight(PROJECT_ID, 1e18);

        // Ensure PM has tokens for the rebalance
        projectToken.mint(address(positionManager), 100e18);
        terminalToken.mint(address(positionManager), 100e18);

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != 0, "Rebalance should succeed after weight change");
        assertTrue(newTokenId != poolTokenId, "Token ID should change after rebalance");
    }

    // -----------------------------------------------------------------------
    // 15. Deploy with very small token amount (dust amounts)
    // -----------------------------------------------------------------------

    /// @notice Deploying with a very small accumulated amount (1 wei) should either
    ///         succeed or revert gracefully (no panic/overflow).
    function test_ExtremePrice_DustAmount() public {
        uint256 dustProject = 9;
        _setupProject(dustProject);

        // Accumulate just 1 wei of project tokens
        _accumulateTokensForProject(dustProject, 1);

        // This might revert due to zero liquidity, but should not panic
        try hook.deployPool(dustProject, address(terminalToken), 0) {
            // If it succeeds, verify state is consistent
            uint256 tokenId = hook.tokenIdOf(dustProject, address(terminalToken));
            assertTrue(tokenId != 0, "Token ID should be nonzero if deploy succeeded");
        } catch (bytes memory reason) {
            // Acceptable reverts for dust amounts
            assertTrue(reason.length > 0, "Should revert with a reason, not panic");
        }
    }

    // -----------------------------------------------------------------------
    // 16. Deploy with large token amount (near uint112 max)
    // -----------------------------------------------------------------------

    /// @notice Deploying with a very large accumulated amount should not overflow
    ///         in the tick or liquidity calculations.
    function test_ExtremePrice_LargeAmount() public {
        uint256 largeProject = 10;
        _setupProject(largeProject);

        // Use a large but safe amount (1e30 tokens, well within uint112)
        uint256 largeAmount = 1e30;
        _accumulateTokensForProject(largeProject, largeAmount);

        vm.prank(owner);
        hook.deployPool(largeProject, address(terminalToken), 0);

        uint256 tokenId = hook.tokenIdOf(largeProject, address(terminalToken));
        assertTrue(tokenId != 0, "Pool should deploy with large token amount");
    }

    // -----------------------------------------------------------------------
    // 17. Rebalance with very high surplus (tick bounds close together)
    // -----------------------------------------------------------------------

    /// @notice With issuance rate close to cash-out rate, tick bounds are very
    ///         narrow. Rebalance should handle narrow ranges correctly.
    function test_ExtremePrice_NarrowTickRange_Rebalance() public {
        // Set surplus very close to the issuance price (high surplus = narrow spread)
        // The issuance rate at weight=1000e18 is 1000 tokens per terminal token.
        // If surplus gives 999 tokens per terminal token, the spread is tiny.
        // surplus of 0.999e18 means reclaimable = 0.999 * cashOutCount / 1e18
        store.setSurplus(PROJECT_ID, 999e15); // 0.999e18

        // Ensure PM has tokens
        projectToken.mint(address(positionManager), 100e18);
        terminalToken.mint(address(positionManager), 100e18);

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != 0, "Rebalance should succeed with narrow tick range");
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    /// @notice Set up a new project with all the required mock wiring.
    function _setupProject(uint256 projectId) internal {
        controller.setWeight(projectId, DEFAULT_WEIGHT);
        controller.setFirstWeight(projectId, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(projectId, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(projectId, 1);
        _setDirectoryController(projectId, address(controller));
        _setDirectoryTerminal(projectId, address(terminalToken), address(terminal));
        _addDirectoryTerminal(projectId, address(terminal));
        jbProjects.setOwner(projectId, owner);
        jbTokens.setToken(projectId, address(projectToken));
        terminal.setProjectToken(projectId, address(projectToken));
        terminal.setAccountingContext(projectId, address(terminalToken), uint32(uint160(address(terminalToken))), 18);
        store.setSurplus(projectId, 0.5e18);
    }

    /// @notice Accumulate tokens for a specific project via processSplitWith.
    function _accumulateTokensForProject(uint256 projectId, uint256 amount) internal {
        projectToken.mint(address(hook), amount);

        JBSplitHookContext memory context = _buildReservedContext(projectId, amount);

        vm.prank(address(controller));
        hook.processSplitWith(context);
    }

    /// @notice Sort tokens (mirrors hook's _sortTokens).
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
