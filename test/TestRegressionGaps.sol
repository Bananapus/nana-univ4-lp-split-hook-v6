// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TwoPositionFixture} from "./regression/TwoPositionFixture.sol";
import {DEFAULT_SURPLUS_PER_TOKEN} from "./TestBaseV4.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {MockERC20} from "./mock/MockERC20.sol";

/// @notice Regression gap tests: MEV/sandwich simulation on the `addLiquidity` recycle and extreme price scenarios.
/// @dev These tests verify that the recycle (collect, burn both positions, re-mint both single-sided) is resistant to
///      sandwich-like value extraction and that the contract behaves correctly at extreme price ratios.
contract TestRegressionGaps is TwoPositionFixture {
    /// @notice The ask position `setUp` deploys for `PROJECT_ID`.
    uint256 poolTokenId;

    /// @notice Deploys `PROJECT_ID`'s pool with a seed ask to recycle.
    function setUp() public override {
        super.setUp();

        // Deploy a pool so we have a position to work with
        _accumulateAndDeploy({projectId: PROJECT_ID, amount: 100e18});
        poolTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        // No spare PositionManager funding: it holds exactly the principal it records, and each test funds only the
        // fees or principal it configures, so a missing or misrouted token cannot be papered over.
    }

    // =========================================================================
    // MEV / Sandwich Simulation on the Recycle
    // =========================================================================

    // -----------------------------------------------------------------------
    // 1. Recycle conserves value: no tokens are created from thin air
    // -----------------------------------------------------------------------

    /// @notice A fee-free recycle neither creates nor loses tokens: hook plus PositionManager balances are exactly
    ///         unchanged, the PositionManager holds exactly the principal it records, and the hook holds exactly its
    ///         ledgers.
    function test_Recycle_ConservesTokenBalances() public {
        // Add fresh inventory so the recycle has something to place.
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});

        // Snapshot the combined hook and PositionManager holdings of each token.
        uint256 totalProjectBefore =
            projectToken.balanceOf(address(hook)) + projectToken.balanceOf(address(positionManager));
        uint256 totalTerminalBefore =
            terminalToken.balanceOf(address(hook)) + terminalToken.balanceOf(address(positionManager));

        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Nothing entered or left the hook and PositionManager together.
        assertEq(
            projectToken.balanceOf(address(hook)) + projectToken.balanceOf(address(positionManager)),
            totalProjectBefore,
            "project tokens exactly conserved"
        );
        assertEq(
            terminalToken.balanceOf(address(hook)) + terminalToken.balanceOf(address(positionManager)),
            totalTerminalBefore,
            "terminal tokens exactly conserved"
        );
        _assertBalancesBackedExactly();
    }

    /// @notice Across a recycle of BOTH positions with fees on both, each currency reconciles exactly: recovered
    ///         principal plus ledgers equals the new positions plus ledgers, and the fees all leave: the terminal-side
    ///         cuts to the fee project (credited as claims), the terminal-side remainders to the project's balance, and
    ///         the project-side fees (cut forgiven) burned.
    function test_Recycle_TwoPositions_ReconcilesPrincipalAndLedgersExactly() public {
        // Grow a live ask and bid, add inventory, and accrue fees on both positions.
        (uint256 askId, uint256 bidId) = _recycleIntoTwoPositions();
        _accumulateTokens({projectId: PROJECT_ID, amount: 7e18});
        _setFees({tokenId: askId, projectFee: 3e18, terminalFee: 2e18});
        _setFees({tokenId: bidId, projectFee: 1e18, terminalFee: 5e18});

        // Let the fee project accept the terminal token, so the terminal-side cuts route to it.
        terminal.setAccountingContext({
            projectId: FEE_PROJECT_ID,
            token: address(terminalToken),
            currency: uint32(uint160(address(terminalToken))),
            decimals: 18
        });

        // Snapshot what the recycle recovers and where the fees should land.
        (uint256 projectBefore, uint256 terminalBefore) = _recoverable({askId: askId, bidId: bidId});
        uint256 cuts = 2e18 * FEE_PERCENT / 10_000 + 5e18 * FEE_PERCENT / 10_000;
        uint256 feeTerminalBefore = terminalToken.balanceOf(address(terminal));
        uint256 supplyBefore = projectToken.totalSupply();
        uint256 addsBefore = terminal.addToBalanceCallCount();

        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Both positions were replaced.
        uint256 newAsk = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        uint256 newBid = hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertTrue(newAsk != askId && newAsk != bidId && newBid != askId && newBid != bidId, "both recycled");
        (uint256 projectAfter, uint256 terminalAfter) = _inventory({askId: newAsk, bidId: newBid});
        // Project-token fee cuts are forgiven (no fee terminal accepts project tokens), so both fees burn in full.
        assertEq(projectAfter, projectBefore, "project principal + ledgers reconcile");
        assertEq(supplyBefore - projectToken.totalSupply(), 3e18 + 1e18, "the project-side fees are burned");
        assertEq(terminalAfter, terminalBefore, "terminal principal + ledgers reconcile");
        // The fee project and the project share this terminal: it receives the cuts and both remainders.
        assertEq(terminal.addToBalanceCallCount(), addsBefore + 2, "one remainder added per position");
        assertEq(terminalToken.balanceOf(address(terminal)), feeTerminalBefore + 2e18 + 5e18, "every terminal fee left");
        assertEq(hook.claimableFeeTokens(PROJECT_ID), cuts, "cuts credited 1:1 as fee-token claims");
        _assertBalancesBackedExactly();
    }

    // -----------------------------------------------------------------------
    // 2. Recycle updates the position NFTs atomically
    // -----------------------------------------------------------------------

    /// @notice The recycle must burn the old NFT and mint its replacement in a single transaction.
    ///         A sandwich attacker cannot interfere between these steps since they happen
    ///         within one tx. Verify the position ID changes, the old NFT is gone, and both operations occur.
    function test_Recycle_AtomicNFTSwap() public {
        // The deploy holds only an ask.
        uint256 originalTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertEq(
            hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "asks-only deploy holds no bid"
        );
        uint256 burnCountBefore = positionManager.burnCallCount();
        uint256 mintCountBefore = positionManager.mintCallCount();

        // Recycle with fresh inventory.
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        uint256 newTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The single live position is burned and exactly one replacement is minted (no terminal to bid with).
        assertEq(positionManager.burnCallCount(), burnCountBefore + 1, "Burn must occur exactly once");
        assertEq(positionManager.mintCallCount(), mintCountBefore + 1, "Mint must occur exactly once");
        (,,,,,, bool oldExists) = positionManager._positions(originalTokenId);
        assertFalse(oldExists, "The old NFT must be burned, not orphaned");

        // The new token ID must differ from the old one
        assertNotEq(newTokenId, originalTokenId, "Token ID must change after a recycle");
        assertNotEq(newTokenId, 0, "New token ID must be nonzero");
        assertEq(
            hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "no bid without terminal tokens"
        );
    }

    // -----------------------------------------------------------------------
    // 3. Recycle with accrued fees: fees are routed before new positions
    // -----------------------------------------------------------------------

    /// @notice When fees are accrued, the recycle should collect and route them
    ///         before creating the new positions. A sandwich attacker cannot
    ///         front-run fee collection because it happens within the same tx.
    function test_Recycle_FeesRoutedBeforeNewPosition() public {
        // Configure collectable fees
        (address token0,) = _sortTokens({tokenA: address(projectToken), tokenB: address(terminalToken)});

        // Accrue the fee on whichever side the terminal token sorts to, and fund it.
        uint256 feeAmount = 10e18;
        if (token0 == address(terminalToken)) {
            positionManager.setCollectableFees({tokenId: poolTokenId, amount0: feeAmount, amount1: 0});
        } else {
            positionManager.setCollectableFees({tokenId: poolTokenId, amount0: 0, amount1: feeAmount});
        }
        terminalToken.mint({to: address(positionManager), amount: feeAmount});

        // Set up fee project terminal
        terminal.setAccountingContext({
            projectId: FEE_PROJECT_ID,
            token: address(terminalToken),
            currency: uint32(uint160(address(terminalToken))),
            decimals: 18
        });

        uint256 payCountBefore = terminal.payCallCount();

        // Recycle with fresh inventory.
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Verify the fee-project cut was paid out of the collected fees.
        assertEq(terminal.payCallCount(), payCountBefore + 1, "Fees should be collected and routed during a recycle");

        // Verify a new position was still minted after fee routing
        uint256 newTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(newTokenId, 0, "New position should be minted after fee routing");
        assertNotEq(newTokenId, poolTokenId, "New token ID should differ from original");
    }

    // -----------------------------------------------------------------------
    // 4. Consecutive recycles produce consistent state
    // -----------------------------------------------------------------------

    /// @notice Two consecutive recycles should both succeed and produce valid
    ///         state, ensuring no residual state corruption from the first.
    function test_Recycle_ConsecutiveRecyclesSucceed() public {
        // First recycle
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        uint256 tokenIdAfterFirst = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(tokenIdAfterFirst, 0, "Token ID should be nonzero after first recycle");

        // Second recycle
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The second recycle replaces the first recycle's ask.
        uint256 tokenIdAfterSecond = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(tokenIdAfterSecond, 0, "Token ID should be nonzero after second recycle");
        assertNotEq(tokenIdAfterSecond, tokenIdAfterFirst, "Token ID should differ between consecutive recycles");
        (,,,,,, bool firstExists) = positionManager._positions(tokenIdAfterFirst);
        assertFalse(firstExists, "The first recycle's ask must be burned by the second");
    }

    // -----------------------------------------------------------------------
    // 5. Recycle with zero fees: no spurious fee routing
    // -----------------------------------------------------------------------

    /// @notice When no fees have accrued, the recycle should still succeed and the fee
    ///         routing path (pay to fee project) should NOT be triggered: the recovered
    ///         principal is never cut.
    function test_Recycle_ZeroFees_NoFeePayRouting() public {
        // Ensure no fees are set (default is 0)
        positionManager.setCollectableFees({tokenId: poolTokenId, amount0: 0, amount1: 0});

        uint256 payCountBefore = terminal.payCallCount();

        // Recycle with fresh inventory.
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // No fee routing via pay should have occurred (pay is only for fee project)
        assertEq(terminal.payCallCount(), payCountBefore, "No pay calls when zero fees");

        // Position should still be updated
        uint256 newTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(newTokenId, poolTokenId, "Position should still be recycled with zero fees");
    }

    // -----------------------------------------------------------------------
    // 6. Recycle with partial usage: leftover tokens handled correctly
    // -----------------------------------------------------------------------

    /// @notice When V4's per-tick cap lets the re-minted ask place only half its liquidity, project-token leftovers
    ///         are carried back into the accumulation ledger (the hook never burns and never routes them to the
    ///         treasury).
    function test_Recycle_PartialUsage_LeftoversHandled() public {
        uint256 addToBalanceBefore = terminal.addToBalanceCallCount();

        // The recycle re-mints the recovered ask principal plus the 1e18 newly accumulated.
        uint256 oldAsk = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        (uint256 old0, uint256 old1) = _principalAtSpot(oldAsk);
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        uint256 projectIn = old0 + old1 + hook.accumulatedProjectTokens(PROJECT_ID);

        // Leave tick room for only half of the ask the recycle would mint.
        uint128 room = _capNextAsk({deploy: false, bps: 5000});
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The ask is capped at the room left.
        uint256 askId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertEq(positionManager.getPositionLiquidity(askId), room, "the ask is capped at half its liquidity");
        (uint256 cost0, uint256 cost1) = _mintCostAtSpot(askId);

        // Exactly the unconsumed part is carried back to the ledger; nothing is routed to the project balance.
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            projectIn - (cost0 + cost1),
            "Unconsumed project tokens return to the ledger"
        );
        assertEq(terminal.addToBalanceCallCount(), addToBalanceBefore, "Leftovers are never added to balance");

        // Position should still be valid
        uint256 newTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(newTokenId, 0, "Position should exist after partial-usage recycle");
    }

    // =========================================================================
    // Extreme Price Scenarios
    // =========================================================================

    // -----------------------------------------------------------------------
    // 8. Deploy with very high weight (extreme issuance rate)
    // -----------------------------------------------------------------------

    /// @notice A very high weight produces an extreme price ratio but should still deploy
    ///         successfully when no pre-initialized pool exists at a conflicting price.
    function test_ExtremePrice_VeryHighWeight() public {
        uint256 highWeightProject = 3;
        _setupProject(highWeightProject);

        // A fresh project token, so this project's pool is not the one setUp already initialized.
        MockERC20 freshToken = new MockERC20("Fresh", "FRESH", 18);
        jbTokens.setToken({projectId: highWeightProject, token: address(freshToken)});
        terminal.setProjectToken({projectId: highWeightProject, token: address(freshToken)});

        // Set a very high weight: 1e30 project tokens per terminal token (issuance price ~1.1e-12 terminal tokens
        // after the 10% reserve), with a cash-out value an order of magnitude below it (1e-13).
        uint256 extremeWeight = 1e30;
        controller.setWeight({projectId: highWeightProject, weight: extremeWeight});
        controller.setFirstWeight({projectId: highWeightProject, weight: extremeWeight});
        store.setSurplus({projectId: highWeightProject, surplus: 1e5});

        // Accumulate the fresh token as reserved tokens, capped so inline automation skips.
        freshToken.mint({to: address(controller), amount: 1000e18});
        vm.startPrank(address(controller));
        freshToken.approve({spender: address(hook), amount: 1000e18});
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: highWeightProject, token: address(freshToken), amount: 1000e18, groupId: 1})
        );
        vm.stopPrank();

        // The deploy succeeds at the extreme price.
        vm.prank(owner);
        hook.deployPool(highWeightProject);
        assertTrue(hook.hasDeployedPool(highWeightProject), "high weight project should deploy successfully");
    }

    // -----------------------------------------------------------------------
    // 9. Deploy with very low weight (extreme price floor)
    // -----------------------------------------------------------------------

    /// @notice With a very low weight, deployment reverts because the pre-existing pool
    ///         (initialized during setUp) is at a price outside this project's economic bounds.
    function test_ExtremePrice_VeryLowWeight_RevertsOutOfBounds() public {
        uint256 lowWeightProject = 4;
        _setupProject(lowWeightProject);

        // Set a very low weight: mulDiv(1e18, 1, 1e18) = 0 tokens per terminal token
        uint256 lowWeight = 1;
        controller.setWeight({projectId: lowWeightProject, weight: lowWeight});
        controller.setFirstWeight({projectId: lowWeightProject, weight: lowWeight});

        _accumulateTokensForProject({projectId: lowWeightProject, amount: 1000e18});

        // Move the corridor's floor above the existing pool's spot.
        _raiseFloorAboveExistingSpot(lowWeightProject);

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds.selector);
        hook.deployPool(lowWeightProject);
    }

    // -----------------------------------------------------------------------
    // 9b. Deploy with moderately low weight (nonzero issuance)
    // -----------------------------------------------------------------------

    /// @notice A low but nonzero issuance rate is blocked because the pre-existing pool
    ///         (initialized during setUp) is at a price outside this project's economic bounds.
    function test_ExtremePrice_LowButViableWeight_RevertsOutOfBounds() public {
        uint256 lowWeightProject = 40;
        _setupProject(lowWeightProject);

        // Set weight=100: mulDiv(1e18, 100, 1e18) = 100 tokens per terminal token
        // This is low but still produces a valid nonzero price.
        controller.setWeight({projectId: lowWeightProject, weight: 100});
        controller.setFirstWeight({projectId: lowWeightProject, weight: 100});

        _accumulateTokensForProject({projectId: lowWeightProject, amount: 1000e18});

        // Move the corridor's floor above the existing pool's spot.
        _raiseFloorAboveExistingSpot(lowWeightProject);

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds.selector);
        hook.deployPool(lowWeightProject);
    }

    // -----------------------------------------------------------------------
    // 10. Deploy with zero surplus (cash out rate = 0)
    // -----------------------------------------------------------------------

    /// @notice When the surplus is 0, deployment fails because the pair's existing pool is already initialized at a
    ///         different price, and no position is minted.
    function test_ExtremePrice_ZeroSurplus_CashOutRateZero() public {
        uint256 zeroSurplusProject = 5;
        _setupProject(zeroSurplusProject);

        // Ensure zero surplus
        store.setSurplus({projectId: zeroSurplusProject, surplus: 0});

        // Accumulate tokens
        _accumulateTokensForProject({projectId: zeroSurplusProject, amount: 500e18});

        vm.prank(owner);
        vm.expectRevert();
        hook.deployPool(zeroSurplusProject);
        assertEq(
            hook.askTokenIdOf({projectId: zeroSurplusProject, terminalToken: address(terminalToken)}),
            0,
            "no position should be minted"
        );
    }

    // -----------------------------------------------------------------------
    // 10b. Deploy with zero surplus AND zero issuance (full range LP)
    // -----------------------------------------------------------------------

    /// @notice With no cash-out rate and no issuance rate, `calculateTickBounds` falls back to a full [MIN, MAX]
    /// corridor. The single-sided deploy path needs no funding cash-out to size a terminal-token side, so it mints a
    /// (fully single-sided) ask spanning that corridor.
    function test_ExtremePrice_ZeroCashOutAndZeroIssuance_FullRange() public {
        uint256 fullRangeProject = 50;
        _setupProject(fullRangeProject);

        // Zero surplus → cashOutRate = 0
        store.setSurplus({projectId: fullRangeProject, surplus: 0});
        // Zero weight → issuanceRate = 0
        controller.setWeight({projectId: fullRangeProject, weight: 0});
        controller.setFirstWeight({projectId: fullRangeProject, weight: 0});

        _accumulateTokensForProject({projectId: fullRangeProject, amount: 500e18});

        vm.prank(owner);
        hook.deployPool(fullRangeProject);

        // An ask mints without any cash-out.
        assertNotEq(
            hook.askTokenIdOf({projectId: fullRangeProject, terminalToken: address(terminalToken)}),
            0,
            "a single-sided position should mint"
        );
        assertEq(terminal.cashOutCallCount(), 0, "deployPool must never call cashOutTokensOf");
    }

    // -----------------------------------------------------------------------
    // 11. Deploy with very high surplus (extreme cash out rate)
    // -----------------------------------------------------------------------

    /// @notice A surplus so high that the cash-out value (1 terminal token per project token) exceeds the issuance
    /// price (1/900) leaves no price inside the corridor: `deployPool` refuses with `EmptyCorridor`, never calls
    /// `cashOutTokensOf`, and keeps the reserved tokens ledgered.
    function test_ExtremePrice_HighSurplus() public {
        uint256 highSurplusProject = 6;
        _setupProject(highSurplusProject);

        // Set a very high surplus: 1e18 terminal tokens per project token cashed out.
        store.setSurplus({projectId: highSurplusProject, surplus: 1e18});

        _accumulateTokensForProject({projectId: highSurplusProject, amount: 500e18});

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_EmptyCorridor.selector,
                highSurplusProject,
                address(terminalToken)
            )
        );
        hook.deployPool(highSurplusProject);

        // Nothing deployed, nothing cashed out, and the tokens stay ledgered.
        assertFalse(hook.hasDeployedPool(highSurplusProject), "an inverted corridor does not deploy");
        assertEq(hook.accumulatedProjectTokens(highSurplusProject), 500e18, "the reserved tokens stay ledgered");
        assertEq(terminal.cashOutCallCount(), 0, "deployPool must never call cashOutTokensOf");
    }

    // -----------------------------------------------------------------------
    // 12. Deploy with weight equal to 1 (minimal issuance)
    // -----------------------------------------------------------------------

    /// @notice Weight=1 (minimal issuance) produces an extreme price. Deployment reverts because
    ///         the pre-existing pool (initialized during setUp) is at a price outside this project's bounds.
    function test_ExtremePrice_WeightEqualOne_RevertsOutOfBounds() public {
        uint256 minWeightProject = 7;
        _setupProject(minWeightProject);

        // Minimal issuance.
        controller.setWeight({projectId: minWeightProject, weight: 1});
        controller.setFirstWeight({projectId: minWeightProject, weight: 1});

        _accumulateTokensForProject({projectId: minWeightProject, amount: 500e18});

        // Move the corridor's floor above the existing pool's spot.
        _raiseFloorAboveExistingSpot(minWeightProject);

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds.selector);
        hook.deployPool(minWeightProject);
    }

    // -----------------------------------------------------------------------
    // 13. Deploy with max reserved percent
    // -----------------------------------------------------------------------

    /// @notice With maximum reserved percent, deployment reverts because the pre-existing pool
    ///         (initialized during setUp) is at a price outside this project's economic bounds.
    function test_ExtremePrice_MaxReservedPercent_RevertsOutOfBounds() public {
        uint256 maxReservedProject = 8;
        _setupProject(maxReservedProject);

        // 10000 = 100% reserved
        controller.setReservedPercent({projectId: maxReservedProject, reservedPercent: 10_000});

        _accumulateTokensForProject({projectId: maxReservedProject, amount: 500e18});

        // Move the corridor's floor above the existing pool's spot.
        _raiseFloorAboveExistingSpot(maxReservedProject);

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds.selector);
        hook.deployPool(maxReservedProject);
    }

    // -----------------------------------------------------------------------
    // 13b. Deploy with high (but not max) reserved percent
    // -----------------------------------------------------------------------

    /// @notice With 99% reserved, deployment reverts because the pre-existing pool
    ///         (initialized during setUp) is at a price outside this project's economic bounds.
    function test_ExtremePrice_HighReservedPercent_RevertsOutOfBounds() public {
        uint256 highReservedProject = 80;
        _setupProject(highReservedProject);

        // 9900 = 99% reserved (1% goes to non-reserved)
        controller.setReservedPercent({projectId: highReservedProject, reservedPercent: 9900});

        _accumulateTokensForProject({projectId: highReservedProject, amount: 500e18});

        // Move the corridor's floor above the existing pool's spot.
        _raiseFloorAboveExistingSpot(highReservedProject);

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds.selector);
        hook.deployPool(highReservedProject);
    }

    // -----------------------------------------------------------------------
    // 14. Recycle after extreme weight change (price shift)
    // -----------------------------------------------------------------------

    /// @notice After deployment at one weight, changing the weight drastically
    ///         and recycling should succeed. This simulates a project that
    ///         has gone through many ruleset cycles with weight decay.
    function test_ExtremePrice_RecycleAfterWeightChange() public {
        // The pool was deployed at DEFAULT_WEIGHT (1000e18) in setUp.
        // Change weight to something very different.
        controller.setWeight({projectId: PROJECT_ID, weight: 1e18});

        // Recycle with fresh inventory.
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The recycle replaced the ask.
        uint256 newTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(newTokenId, 0, "Recycle should succeed after weight change");
        assertNotEq(newTokenId, poolTokenId, "Token ID should change after a recycle");
    }

    // -----------------------------------------------------------------------
    // 15. Deploy with very small token amount (dust amounts)
    // -----------------------------------------------------------------------

    /// @notice Deploying a 1-wei accumulation mints zero liquidity, so it fails with the hook's own
    ///         NoDeployableLiquidityAtSpot (never an arithmetic `Panic`) and rolls back completely: no pool marked
    ///         deployed, no position, the wei still in the ledger.
    function test_ExtremePrice_DustAmount() public {
        uint256 dustProject = 9;
        _setupProject(dustProject);
        _accumulateTokensForProject({projectId: dustProject, amount: 1});

        // Catch the revert to inspect which error it is.
        try hook.deployPool(dustProject) {
            assertTrue(false, "a 1-wei deploy must not succeed");
        } catch (bytes memory reason) {
            // The revert data starts with its 4-byte selector; keeping only those bytes is the point.
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes4 selector = bytes4(reason);
            assertNotEq(selector, bytes4(keccak256("Panic(uint256)")), "dust must not panic");
            assertEq(
                selector,
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector,
                "dust fails with the hook's no-deployable-liquidity error"
            );
        }

        // The failed deploy left no trace.
        assertFalse(hook.hasDeployedPool(dustProject), "dust deploy rolled back");
        assertEq(hook.askTokenIdOf({projectId: dustProject, terminalToken: address(terminalToken)}), 0, "no ask minted");
        assertEq(hook.bidTokenIdOf({projectId: dustProject, terminalToken: address(terminalToken)}), 0, "no bid minted");
        assertEq(hook.accumulatedProjectTokens(dustProject), 1, "the wei stays in the ledger");
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
        _accumulateTokensForProject({projectId: largeProject, amount: largeAmount});

        vm.prank(owner);
        hook.deployPool(largeProject);

        // An ask was minted.
        uint256 tokenId = hook.askTokenIdOf({projectId: largeProject, terminalToken: address(terminalToken)});
        assertNotEq(tokenId, 0, "Pool should deploy with large token amount");
    }

    // -----------------------------------------------------------------------
    // 17. Recycle with very high surplus (tick bounds close together)
    // -----------------------------------------------------------------------

    /// @notice With the cash-out value within one spacing of the issuance price, no aligned band fits between them:
    ///         the corridor is empty, so the recycle retires the live ask and holds every token in the ledger, and
    ///         the next recycle after the spread widens redeploys it.
    function test_ExtremePrice_NarrowTickRange_RecycleHolds() public {
        // Set the cash-out value just below the issuance price (a narrow spread). The issuance rate at weight=1000e18
        // with a 10% reserve is 900 tokens per terminal token, a price of 1/900 ~= 0.001111e18 terminal tokens; a
        // surplus of 0.0011e18 per token puts the cash-out value about 100 ticks (half a spacing) below it.
        store.setSurplus({projectId: PROJECT_ID, surplus: 0.0011e18});

        // Recycle with fresh inventory into the empty corridor.
        _accumulateTokens({projectId: PROJECT_ID, amount: 1e18});
        (uint256 projectTotal,) = _recoverable({askId: poolTokenId, bidId: 0});
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // No positions remain and every project token is ledgered.
        assertEq(
            hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "no ask in an empty corridor"
        );
        assertEq(
            hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "no bid in an empty corridor"
        );
        (,,,,,, bool exists) = positionManager._positions(poolTokenId);
        assertFalse(exists, "the live ask is retired");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), projectTotal, "every project token is held");
        _assertBalancesBackedExactly();

        // The spread widens again: the held tokens redeploy as a fresh ask.
        store.setSurplus({projectId: PROJECT_ID, surplus: DEFAULT_SURPLUS_PER_TOKEN});
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        uint256 newTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertGt(newTokenId, poolTokenId, "the ask redeploys under a fresh id");
        _assertPlacedExactly({
            projectId: PROJECT_ID,
            projectTokenAddr: address(projectToken),
            terminalTokenAddr: address(terminalToken),
            projectIn: projectTotal,
            terminalIn: 0
        });
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    /// @notice The PositionManager holds exactly its recorded principal and the hook exactly its ledgers.
    function _assertBalancesBackedExactly() internal view {
        // The PositionManager holds no loose tokens beyond the pool's reserves.
        assertEq(
            projectToken.balanceOf(address(positionManager)),
            positionManager.poolLocked(address(projectToken)),
            "PM project balance is exactly locked principal"
        );
        assertEq(
            terminalToken.balanceOf(address(positionManager)),
            positionManager.poolLocked(address(terminalToken)),
            "PM terminal balance is exactly locked principal"
        );

        // The hook holds exactly what its ledgers record.
        assertEq(
            projectToken.balanceOf(address(hook)), hook.accumulatedProjectTokens(PROJECT_ID), "hook project = ledger"
        );
        assertEq(
            terminalToken.balanceOf(address(hook)),
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            "hook terminal = ledger"
        );
    }

    /// @notice Recorded principal of both positions plus the project's ledgers, per currency.
    /// @param askId The ask position's token ID.
    /// @param bidId The bid position's token ID.
    /// @return projectAmount The project tokens the positions and the ledger hold.
    /// @return terminalAmount The terminal tokens the positions and the ledger hold.
    function _inventory(
        uint256 askId,
        uint256 bidId
    )
        internal
        view
        returns (uint256 projectAmount, uint256 terminalAmount)
    {
        // Sum each side's recorded principal across both positions, plus the ledgers.
        (uint256 askProject, uint256 askTerminal) = _sides(askId);
        (uint256 bidProject, uint256 bidTerminal) = _sides(bidId);
        projectAmount = askProject + bidProject + hook.accumulatedProjectTokens(PROJECT_ID);
        terminalAmount = askTerminal + bidTerminal
            + hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
    }

    /// @notice What burning both positions returns at the live spot plus the project's ledgers, per currency.
    /// @param askId The ask position's token ID.
    /// @param bidId The bid position's token ID, or 0 for none.
    /// @return projectAmount The project tokens a recycle recovers into its inventory.
    /// @return terminalAmount The terminal tokens a recycle recovers into its inventory.
    function _recoverable(
        uint256 askId,
        uint256 bidId
    )
        internal
        view
        returns (uint256 projectAmount, uint256 terminalAmount)
    {
        // Price both positions' principal at the live spot, rounded down like a burn.
        (uint256 ask0, uint256 ask1) = _principalAtSpot(askId);
        (uint256 bid0, uint256 bid1) = _principalAtSpot(bidId);
        (uint256 amount0, uint256 amount1) = (ask0 + bid0, ask1 + bid1);

        // Map token0/token1 onto the project/terminal sides, then add the ledgers.
        (projectAmount, terminalAmount) = _projectIsToken0() ? (amount0, amount1) : (amount1, amount0);
        projectAmount += hook.accumulatedProjectTokens(PROJECT_ID);
        terminalAmount += hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
    }

    /// @notice Put `projectId`'s cash-out floor (0.05 terminal tokens per project token) 100x above the spot of the
    /// pool setUp initialized (one spacing inside PROJECT_ID's 0.0005 floor), so that pool's price sits outside its
    /// corridor without inverting it.
    /// @param projectId The ID of the project whose floor is raised.
    function _raiseFloorAboveExistingSpot(uint256 projectId) internal {
        // 0.05 terminal tokens per project token of surplus sets the floor.
        store.setSurplus({projectId: projectId, surplus: 0.05e18});
    }

    /// @notice Set up a new project with all the required mock wiring.
    /// @param projectId The ID of the project to wire.
    function _setupProject(uint256 projectId) internal {
        // Issuance, reserved percent and base currency match `PROJECT_ID`'s defaults.
        controller.setWeight({projectId: projectId, weight: DEFAULT_WEIGHT});
        controller.setFirstWeight({projectId: projectId, weight: DEFAULT_FIRST_WEIGHT});
        controller.setReservedPercent({projectId: projectId, reservedPercent: DEFAULT_RESERVED_PERCENT});
        controller.setBaseCurrency({projectId: projectId, currency: 1});

        // Route the project to the shared controller and terminal.
        _setDirectoryController({projectId: projectId, ctrl: address(controller)});
        _setDirectoryTerminal({projectId: projectId, token: address(terminalToken), term: address(terminal)});
        _addDirectoryTerminal({projectId: projectId, term: address(terminal)});

        // Give the project an owner and the shared project token.
        jbProjects.setOwner({tokenId: projectId, owner: owner});
        jbTokens.setToken({projectId: projectId, token: address(projectToken)});
        terminal.setProjectToken({projectId: projectId, token: address(projectToken)});

        // Let the terminal accept the terminal token for the project.
        terminal.setAccountingContext({
            projectId: projectId,
            token: address(terminalToken),
            currency: uint32(uint160(address(terminalToken))),
            decimals: 18
        });
        terminal.addAccountingContext({
            projectId: projectId,
            ctx: JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        });

        // Default surplus and terminal balance, as `PROJECT_ID` has.
        store.setSurplus({projectId: projectId, surplus: DEFAULT_SURPLUS_PER_TOKEN});
        store.setBalance({
            terminal: address(terminal), projectId: projectId, token: address(terminalToken), balance: 10e18
        });
    }

    /// @notice Accumulate tokens for a specific project via processSplitWith.
    /// @param projectId The ID of the project receiving the reserved tokens.
    /// @param amount The project tokens to accumulate.
    function _accumulateTokensForProject(uint256 projectId, uint256 amount) internal {
        // Fund the controller, which the hook pulls the reserved tokens from.
        projectToken.mint({to: address(controller), amount: amount});

        // Process the split as the controller, capped so inline automation skips.
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: amount});
        JBSplitHookContext memory context = _buildReservedContext({projectId: projectId, amount: amount});
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();
    }

    /// @notice Sort tokens (mirrors hook's _sortTokens).
    /// @param tokenA One token.
    /// @param tokenB The other token.
    /// @return token0 The lower address.
    /// @return token1 The higher address.
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        // The lower address is token0, as V4 orders currencies.
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
