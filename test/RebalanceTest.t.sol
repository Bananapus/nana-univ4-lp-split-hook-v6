// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {MockERC20} from "./mock/MockERC20.sol";

/// @notice Tests for JBUniswapV4LPSplitHook.rebalanceLiquidity function.
/// @dev Covers revert conditions, PositionManager interactions (modifyLiquidities with
///      DECREASE_LIQUIDITY, BURN_POSITION, MINT_POSITION, TAKE_PAIR, SETTLE, SWEEP), and access control.
contract RebalanceTest is LPSplitHookV4TestBase {
    uint256 poolTokenId;

    function setUp() public override {
        super.setUp();

        // Deploy a pool so we have a position to rebalance
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        poolTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Ensure PositionManager has tokens so that collect can transfer them to the hook
        // after decreaseLiquidity makes them collectable
        projectToken.mint(address(positionManager), 50e18);
        terminalToken.mint(address(positionManager), 50e18);
    }

    // -----------------------------------------------------------------------
    // 1. rebalanceLiquidity -- reverts when no pool exists
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity reverts with InvalidStageForAction when no pool
    ///         has been deployed for the project/token pair.
    function test_Rebalance_RevertsIfNoPoolDeployed() public {
        // Use a separate project that has no pool deployed
        uint256 newProjectId = 3;
        controller.setWeight(newProjectId, DEFAULT_WEIGHT);
        controller.setFirstWeight(newProjectId, DEFAULT_FIRST_WEIGHT);
        _setDirectoryController(newProjectId, address(controller));
        _setDirectoryTerminal(newProjectId, address(terminalToken), address(terminal));
        jbProjects.setOwner(newProjectId, owner);

        vm.prank(owner);
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidStageForAction.selector);
        hook.rebalanceLiquidity(newProjectId, address(terminalToken), 0, 0);
    }

    // -----------------------------------------------------------------------
    // 2. rebalanceLiquidity -- reverts if no pool exists for token pair
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity reverts with InvalidStageForAction when there is no pool
    ///         for the given projectId/terminalToken pair.
    function test_Rebalance_RevertsIfNoPool() public {
        // Use a different terminal token that has a primary terminal but no pool deployed
        MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
        _setDirectoryTerminal(PROJECT_ID, address(otherToken), address(terminal));

        // Set accounting context for the other token
        terminal.setAccountingContext(PROJECT_ID, address(otherToken), uint32(uint160(address(otherToken))), 18);

        vm.prank(owner);
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidStageForAction.selector);
        hook.rebalanceLiquidity(PROJECT_ID, address(otherToken), 0, 0);
    }

    // -----------------------------------------------------------------------
    // 3. rebalanceLiquidity -- reverts if terminal token is invalid
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity reverts with InvalidTerminalToken when the terminal token
    ///         has no primary terminal configured in the directory.
    function test_Rebalance_RevertsIfInvalidTerminal() public {
        address randomToken = makeAddr("randomToken");

        vm.prank(owner);
        vm.expectRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidTerminalToken.selector);
        hook.rebalanceLiquidity(PROJECT_ID, randomToken, 0, 0);
    }

    // -----------------------------------------------------------------------
    // 4. rebalanceLiquidity -- removes all liquidity
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity calls PositionManager.modifyLiquidities which includes
    ///         BURN_POSITION to remove all liquidity and burn the old position NFT.
    function test_Rebalance_RemovesAllLiquidity() public {
        uint256 burnCountBefore = positionManager.burnCallCount();

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        assertEq(
            positionManager.burnCallCount(),
            burnCountBefore + 1,
            "PositionManager burn (which removes all liquidity) should be called exactly once"
        );
    }

    // -----------------------------------------------------------------------
    // 5. rebalanceLiquidity -- burns old NFT
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity calls PositionManager with BURN_POSITION to remove the old
    ///         position NFT before minting a new one.
    function test_Rebalance_BurnsOldNFT() public {
        uint256 burnCountBefore = positionManager.burnCallCount();

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        assertEq(
            positionManager.burnCallCount(), burnCountBefore + 1, "PositionManager burn should be called exactly once"
        );
    }

    // -----------------------------------------------------------------------
    // 6. rebalanceLiquidity -- mints new position
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity calls PositionManager with MINT_POSITION to create a new LP
    ///         position with updated tick bounds.
    function test_Rebalance_MintsNewPosition() public {
        uint256 mintCountBefore = positionManager.mintCallCount();
        // mintCountBefore should be 1 (from the initial _accumulateAndDeploy)

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        assertEq(
            positionManager.mintCallCount(),
            mintCountBefore + 1,
            "PositionManager mint should be called once more for the new position"
        );
    }

    // -----------------------------------------------------------------------
    // 7. rebalanceLiquidity -- updates tokenIdOf
    // -----------------------------------------------------------------------

    /// @notice After rebalance, the tokenIdOf mapping should point to a new tokenId
    ///         (different from the original one created during deployPool).
    function test_Rebalance_UpdatesTokenId() public {
        uint256 originalTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(originalTokenId != 0, "original tokenId should be nonzero");

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertTrue(newTokenId != 0, "new tokenId should be nonzero");
        assertTrue(newTokenId != originalTokenId, "tokenIdOf should change after rebalance");
    }

    // -----------------------------------------------------------------------
    // 8. rebalanceLiquidity -- requires authorization
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity requires SET_BUYBACK_POOL permission. A random user
    ///         without permission should be rejected.
    function test_Rebalance_RequiresAuthorization() public {
        address randomUser = makeAddr("randomRebalancer");

        vm.prank(randomUser);
        vm.expectRevert();
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);
    }

    // -----------------------------------------------------------------------
    // 9. rebalanceLiquidity -- routes collected fees
    // -----------------------------------------------------------------------

    /// @notice When the position has accrued fees, rebalanceLiquidity collects them and
    ///         routes terminal token fees to the project (via pay for fee project or addToBalance).
    function test_Rebalance_HandlesFees() public {
        // Pre-configure collectable fees on the position
        // We need to figure out token ordering: the mock PositionManager stores token0/token1 in the position
        // The fees need to include terminal token fees to trigger routing
        (address token0,) = _sortTokens(address(projectToken), address(terminalToken));

        uint256 feeAmount0;
        uint256 feeAmount1;
        if (token0 == address(terminalToken)) {
            feeAmount0 = 5e18;
            feeAmount1 = 0;
        } else {
            feeAmount0 = 0;
            feeAmount1 = 5e18;
        }

        positionManager.setCollectableFees(poolTokenId, feeAmount0, feeAmount1);

        // Ensure PositionManager has enough terminal tokens for the fee transfer
        terminalToken.mint(address(positionManager), 5e18);

        // Set up fee project terminal
        terminal.setAccountingContext(
            FEE_PROJECT_ID, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );

        uint256 payCountBefore = terminal.payCallCount();
        uint256 addToBalanceCountBefore = terminal.addToBalanceCallCount();

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        // Fees should have been routed: either pay (for fee project) or addToBalance (for original project)
        bool feesRouted =
            (terminal.payCallCount() > payCountBefore) || (terminal.addToBalanceCallCount() > addToBalanceCountBefore);
        assertTrue(feesRouted, "Collected fees should be routed via pay or addToBalance");
    }

    // --- Helper ------------------------------------------------------------

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
