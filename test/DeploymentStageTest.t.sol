// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase, MockPermit2} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBUniswapV4LPSplitHook} from "../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

/// @notice Tests for JBUniswapV4LPSplitHook deployment stage behavior.
/// @dev Covers deployPool access control, processSplitWith accumulation/burning, leftovers, and revert conditions.
contract DeploymentStageTest is LPSplitHookV4TestBase {
    function setUp() public override {
        super.setUp();
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. deployPool — creates pool and sets tokenIdOf
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After accumulating tokens, the project owner calls deployPool which should create
    ///         the pool and set tokenIdOf to a nonzero value.
    function test_DeployPool_CreatesPool() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        uint256 tokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(tokenId, 0, "tokenIdOf should be nonzero after deployPool");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. deployPool — mints a single-sided ask from the full accumulated balance, no cash-out
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool mints a single-sided ask position from the accumulated project tokens. It never funds the
    ///         position with a cash-out — the entire accumulated balance is offered as project-token liquidity.
    function test_DeployPool_MintsSingleSidedAsk_NeverCashesOut() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        assertEq(terminal.cashOutCallCount(), 0, "deployPool must never call cashOutTokensOf");
        // The full accumulated balance funds the ask; only V4 rounding stays ledgered.
        _assertPlacedExactly(PROJECT_ID, address(projectToken), address(terminalToken), 100e18, 0);
    }

    /// @notice A nonzero cash-out tax rate no longer affects `deployPool`: the deploy path carries no funding
    /// cash-out at all (single-sided asks-only), so there is no cash-out-derived floor to net fees from.
    function test_DeployPool_NonzeroCashOutTax_NetsDerivedMinReturn() public {
        controller.setCashOutTaxRate(PROJECT_ID, 5000);
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        assertEq(terminal.cashOutCallCount(), 0, "a nonzero cash-out tax rate must not trigger a deploy cash-out");
        assertNotEq(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)), 0, "the single-sided position should mint");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. deployPool — mints LP position via PositionManager
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool should call PositionManager.modifyLiquidities to create the LP position.
    function test_DeployPool_MintsLPPosition() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        assertEq(positionManager.mintCallCount(), 1, "PositionManager mint should be called once");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. deployPool — sets tokenIdOf
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After deployment, tokenIdOf for the project/terminalToken should be nonzero.
    function test_DeployPool_SetsTokenId() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        uint256 tokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(tokenId, 0, "tokenIdOf should be nonzero after deployPool");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. deployPool — clears accumulatedProjectTokens
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After deployment, accumulatedProjectTokens should be reset to 0.
    function test_DeployPool_ClearsAccumulated() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        // The ledger keeps only what V4 rounding left unplaced.
        _assertPlacedExactly(PROJECT_ID, address(projectToken), address(terminalToken), 100e18, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. deployPool — emits ProjectDeployed event
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool should emit ProjectDeployed with the correct projectId and terminalToken.
    function test_DeployPool_EmitsEvent() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Check indexed params: projectId (topic1) and terminalToken (topic2)
        // The poolId (topic3) is unknown ahead of time, so we only check the first two indexed params.
        vm.expectEmit(true, true, false, false);
        emit IJBUniswapV4LPSplitHook.ProjectDeployed(PROJECT_ID, address(terminalToken), bytes32(0), owner);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. deployPool — reverts if no tokens accumulated
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts with NoTokensAccumulated when no tokens have been accumulated.
    function test_DeployPool_RevertsIf_NoTokens() public {
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoTokensAccumulated.selector);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. deployPool — reverts if pool already deployed (PoolAlreadyDeployed)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts with PoolAlreadyDeployed when called a second time for the
    ///         same project and terminal token.
    function test_DeployPool_RevertsIf_PoolAlreadyDeployed() public {
        // First deploy succeeds
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        // Accumulate more tokens so NoTokensAccumulated wouldn't fire
        _accumulateTokens(PROJECT_ID, 50e18);

        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_PoolAlreadyDeployed.selector);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
    }

    /// @notice Once any pool is deployed for a project, a second deploy attempt is rejected.
    ///         Auto-select picks the same terminal token (highest balance), hitting PoolAlreadyDeployed.
    function test_DeployPool_RevertsIf_SecondTerminalTokenRequested() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        address secondTerminalToken = makeAddr("secondTerminalToken");
        _setDirectoryTerminal(PROJECT_ID, secondTerminalToken, address(terminal));

        _accumulateTokens(PROJECT_ID, 50e18);

        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_PoolAlreadyDeployed.selector);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 9. deployPool — reverts if no terminal token has a balance
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts with NoTerminalTokenFound when no terminal token
    ///         has a non-zero balance in the store.
    function test_DeployPool_RevertsIf_NoTerminalTokenBalance() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Clear the balance that was set in the base setUp
        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 0);

        vm.expectPartialRevert(JBUniswapV4LPSplitHookMath.JBUniswapV4LPSplitHookMath_NoTerminalTokenFound.selector);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 10. processSplitWith — accumulates tokens when pool not yet deployed
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When processSplitWith is called before the pool has been deployed,
    ///         it should accumulate the tokens (no auto-deploy).
    function test_ProcessSplit_AccumulatesWhenNoPoolDeployed() public {
        uint256 amount = 100e18;
        projectToken.mint(address(controller), amount);

        vm.startPrank(address(controller));
        projectToken.approve(address(hook), amount);
        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, amount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();

        // Tokens should be accumulated
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID), amount, "accumulatedProjectTokens should equal the sent amount"
        );

        // Pool should NOT exist (no auto-deploy)
        uint256 tokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(tokenId, 0, "tokenIdOf should remain 0 -- no auto-deploy");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 11. processSplitWith — accumulates new tokens after pool deployed (no burn)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After the pool has been deployed, processSplitWith ACCUMULATES the newly received project tokens for a
    ///         later `addLiquidity` rather than burning them. The hook never burns.
    function test_ProcessSplit_AccumulatesNewTokensAfterDeploy() public {
        // Deploy pool first (as owner)
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 burnCountAfterDeploy = controller.burnCallCount();
        uint256 accumulatedAfterDeploy = hook.accumulatedProjectTokens(PROJECT_ID);

        // Send new tokens via controller
        uint256 newAmount = 50e18;
        projectToken.mint(address(controller), newAmount);

        vm.startPrank(address(controller));
        projectToken.approve(address(hook), newAmount);
        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();

        // The newly received tokens are accumulated, not burned.
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            accumulatedAfterDeploy + newAmount,
            "post-deploy inflow should accumulate"
        );
        assertEq(controller.burnCallCount(), burnCountAfterDeploy, "no burn should occur post-deploy");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 12. processSplitWith — accumulates even when accumulated was 0 at deploy time
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After pool is deployed, processSplitWith accumulates new tokens even when the accumulation ledger was
    ///         cleared to 0 at the time of deployment. Still no burn.
    function test_ProcessSplit_AccumulatesAfterDeploy_EvenFromZero() public {
        // Deploy pool with some tokens: the ledger keeps only what V4 rounding left unplaced.
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        _assertPlacedExactly(PROJECT_ID, address(projectToken), address(terminalToken), 100e18, 0);
        uint256 accumulatedAfterDeploy = hook.accumulatedProjectTokens(PROJECT_ID);

        uint256 burnCountAfterDeploy = controller.burnCallCount();

        // Send new tokens and process — should accumulate, not burn.
        uint256 newAmount = 10e18;
        projectToken.mint(address(controller), newAmount);

        vm.startPrank(address(controller));
        projectToken.approve(address(hook), newAmount);
        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();

        assertEq(controller.burnCallCount(), burnCountAfterDeploy, "no burn should occur post-deploy");
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            accumulatedAfterDeploy + newAmount,
            "new tokens should accumulate after deploy"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 13. deployPool — carries leftover tokens forward when PositionManager uses < 100%
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When V4's per-tick cap lets the ask place only part of the inventory (here 80% of its liquidity),
    ///         the leftover project tokens are carried forward into the accumulation ledger (never burned).
    function test_DeployPool_CarriesLeftoversForward() public {
        _accumulateTokens(PROJECT_ID, 100e18);
        uint128 room = _capNextAsk({deploy: true, bps: 8000});

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        uint256 askId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(positionManager.getPositionLiquidity(askId), room, "the ask is capped at the per-tick room");
        (uint256 cost0, uint256 cost1) = _mintCostAtSpot(askId);

        // The leftover project tokens are carried forward, not burned.
        assertEq(controller.burnCallCount(), 0, "no burn should occur on deploy");
        assertGt(
            hook.accumulatedProjectTokens(PROJECT_ID), 0, "leftover project tokens should be carried into accumulation"
        );
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            100e18 - (cost0 + cost1),
            "exactly what the capped ask did not cost is carried"
        );
    }

    function test_DeployPool_PartialMintClearsPermit2Approvals() public {
        _accumulateTokens(PROJECT_ID, 100e18);
        _capNextAsk({deploy: true, bps: 8000});

        address permit2 = address(hook.PERMIT2());

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        assertEq(projectToken.allowance(address(hook), permit2), 0, "project token ERC20 allowance cleared");
        assertEq(terminalToken.allowance(address(hook), permit2), 0, "terminal token ERC20 allowance cleared");
        assertEq(
            MockPermit2(permit2).allowances(address(hook), address(projectToken), address(positionManager)),
            0,
            "project token Permit2 allowance cleared"
        );
        assertEq(
            MockPermit2(permit2).expirations(address(hook), address(projectToken), address(positionManager)),
            1,
            "project token Permit2 allowance expired"
        );
        assertEq(
            MockPermit2(permit2).allowances(address(hook), address(terminalToken), address(positionManager)),
            0,
            "terminal token Permit2 allowance cleared"
        );
        assertEq(
            MockPermit2(permit2).expirations(address(hook), address(terminalToken), address(positionManager)),
            1,
            "terminal token Permit2 allowance expired"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 14. After pool deployed, processSplitWith only accumulates — no second pool
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After the pool has been deployed, calling processSplitWith again should NOT create a second pool. It
    ///         should only accumulate the newly received tokens (never burn).
    function test_DeployPool_PoolAlreadyExists_OnlyAccumulates() public {
        // Deploy pool as owner
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        // Record tokenId and mint count after first deploy
        uint256 firstTokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 mintCountAfterDeploy = positionManager.mintCallCount();
        uint256 burnCountAfterDeploy = controller.burnCallCount();
        uint256 accumulatedAfterDeploy = hook.accumulatedProjectTokens(PROJECT_ID);

        // Send new tokens and call processSplitWith
        uint256 newAmount = 25e18;
        projectToken.mint(address(controller), newAmount);

        vm.startPrank(address(controller));
        projectToken.approve(address(hook), newAmount);
        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();

        // tokenId should remain the same (no second pool created)
        uint256 tokenIdAfter = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(tokenIdAfter, firstTokenId, "tokenId should not change after second processSplitWith");

        // PositionManager.mint should NOT have been called again
        assertEq(
            positionManager.mintCallCount(), mintCountAfterDeploy, "PositionManager mint should not be called again"
        );

        // The new tokens accumulate; no burn.
        assertEq(controller.burnCallCount(), burnCountAfterDeploy, "no burn should occur post-deploy");
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            accumulatedAfterDeploy + newAmount,
            "new tokens should accumulate after deploy"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 15. deployPool — fully permissionless (no owner gate)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool is permissionless: a random caller who is neither the project owner nor a SET_BUYBACK_POOL
    ///         delegate can seed the pool. The old weight-decay owner gate has been removed; the only gate is the
    ///         economic spot-below-ceiling check applied inside the mint executor (a fresh seed at the corridor
    ///         midpoint trivially passes it).
    function test_DeployPool_Permissionless_AnyCallerCanSeed() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        hook.deployPool(PROJECT_ID);

        assertNotEq(
            hook.askTokenIdOf(PROJECT_ID, address(terminalToken)),
            0,
            "a permissionless caller must be able to seed the pool"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 16. deployPool — succeeds for permitted operator
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A user with SET_BUYBACK_POOL permission granted by the
    ///         project owner can successfully call deployPool.
    function test_DeployPool_SucceedsFor_PermittedOperator() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        address operator = makeAddr("operator");

        // Grant SET_BUYBACK_POOL permission to operator from owner for PROJECT_ID
        permissions.setPermission(operator, owner, PROJECT_ID, JBPermissionIds.SET_BUYBACK_POOL, true);

        vm.prank(operator);
        hook.deployPool(PROJECT_ID);

        uint256 tokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertNotEq(tokenId, 0, "tokenIdOf should be nonzero after deployPool by permitted operator");
    }
}
