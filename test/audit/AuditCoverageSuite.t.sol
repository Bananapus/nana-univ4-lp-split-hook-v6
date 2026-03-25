// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─── Test base and imports
// ────────────────────────────────────────────
import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {MockJBController} from "../mock/MockJBContracts.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

// ═══════════════════════════════════════════════════════════════════════
// TotalSurplusController — like MockJBController but supports the
// `useTotalSurplusForCashOuts` metadata flag.
// ═══════════════════════════════════════════════════════════════════════

contract TotalSurplusController {
    // ─── Prices reference
    // ────────────────────────────────────
    address public pricesContract;

    // ─── Per-project config
    // ──────────────────────────────────
    mapping(uint256 projectId => uint256 weight) public weights;
    mapping(uint256 projectId => uint16 reservedPercent) public reservedPercents;
    mapping(uint256 projectId => uint32 baseCurrency) public baseCurrencies;
    mapping(uint256 projectId => address token) public tokens;

    // ─── Toggle for useTotalSurplusForCashOuts ───────────────
    mapping(uint256 projectId => bool flag) public useTotalSurplus;

    // ─── Setters
    // ─────────────────────────────────────────────
    function setPrices(address _prices) external {
        pricesContract = _prices;
    }

    function setWeight(uint256 projectId, uint256 weight) external {
        weights[projectId] = weight;
    }

    function setReservedPercent(uint256 projectId, uint16 reservedPercent) external {
        reservedPercents[projectId] = reservedPercent;
    }

    function setBaseCurrency(uint256 projectId, uint32 currency) external {
        baseCurrencies[projectId] = currency;
    }

    function setToken(uint256 projectId, address token) external {
        tokens[projectId] = token;
    }

    function setUseTotalSurplus(uint256 projectId, bool _flag) external {
        useTotalSurplus[projectId] = _flag;
    }

    // ─── View shims
    // ──────────────────────────────────────────

    // solhint-disable-next-line func-name-mixedcase
    function PRICES() external view returns (address) {
        return pricesContract;
    }

    /// @dev Returns a ruleset whose packed metadata includes `useTotalSurplusForCashOuts`.
    function currentRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        // Default base currency to ETH (1) if not explicitly set.
        uint32 baseCurr = baseCurrencies[projectId];
        if (baseCurr == 0) baseCurr = 1;

        // Build metadata with the per-project useTotalSurplus flag.
        metadata = JBRulesetMetadata({
            reservedPercent: reservedPercents[projectId],
            cashOutTaxRate: 0,
            baseCurrency: baseCurr,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: useTotalSurplus[projectId],
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        // Pack metadata bits into the ruleset so JBRulesetMetadataResolver works.
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: uint112(weights[projectId]),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadataResolver.packRulesetMetadata(metadata)
        });
    }

    /// @dev Burn shim — burns the project's ERC-20 token.
    function burnTokensOf(address holder, uint256 projectId, uint256 amount, string calldata) external {
        // Burn the token from the holder (tests must set the token via setToken).
        MockERC20(tokens[projectId]).burn(holder, amount);
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Test 1: `useTotalSurplusForCashOuts = true` branch
// ═══════════════════════════════════════════════════════════════════════

/// @title UseTotalSurplusCashOutTest
/// @notice Verifies that `_getCashOutRate` uses `currentTotalReclaimableSurplusOf`
///         when the project's ruleset has `useTotalSurplusForCashOuts: true`.
contract UseTotalSurplusCashOutTest is LPSplitHookV4TestBase {
    // Custom controller that supports the total-surplus flag.
    TotalSurplusController internal tsController;

    function setUp() public override {
        // Run base setup (creates directory, tokens, mocks, hook clone).
        super.setUp();

        // Deploy the custom controller that can flip the metadata flag.
        tsController = new TotalSurplusController();

        // Mirror the default config from the base setup.
        tsController.setPrices(address(prices));
        tsController.setWeight(PROJECT_ID, DEFAULT_WEIGHT);
        tsController.setReservedPercent(PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        tsController.setBaseCurrency(PROJECT_ID, 1);
        tsController.setToken(PROJECT_ID, address(projectToken));

        // Wire fee project so fee routing does not revert.
        tsController.setWeight(FEE_PROJECT_ID, 100e18);
        tsController.setReservedPercent(FEE_PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        tsController.setBaseCurrency(FEE_PROJECT_ID, 1);
        tsController.setToken(FEE_PROJECT_ID, address(feeProjectToken));

        // Point both projects at the new controller.
        _setDirectoryController(PROJECT_ID, address(tsController));
        _setDirectoryController(FEE_PROJECT_ID, address(tsController));

        // Set a non-zero total surplus so the cashout rate is non-zero.
        store.setSurplus(PROJECT_ID, 0.5e18);
    }

    // ─── Helper: accumulate tokens via the custom controller ─

    function _accumulateViaController(uint256 projectId, uint256 amount) internal {
        // Mint project tokens to the hook.
        projectToken.mint(address(hook), amount);

        // Build a reserved-token split context (groupId = 1).
        JBSplitHookContext memory context = _buildReservedContext(projectId, amount);

        // The controller calls processSplitWith.
        vm.prank(address(tsController));
        hook.processSplitWith(context);
    }

    /// @notice Deploy a project with `useTotalSurplusForCashOuts: true` and verify
    ///         that the pool deploys correctly (proving that `_getCashOutRate` used
    ///         the total-surplus code path without reverting).
    function test_DeployPool_WithUseTotalSurplusForCashOuts() public {
        // Enable the flag on the project's ruleset metadata.
        tsController.setUseTotalSurplus(PROJECT_ID, true);

        // Accumulate project tokens.
        uint256 amount = 100e18;
        _accumulateViaController(PROJECT_ID, amount);

        // Deploy the pool — this internally calls _getCashOutRate which branches
        // on `ruleset.useTotalSurplusForCashOuts()`.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        // The pool should now exist (tokenIdOf != 0).
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertGt(tokenId, 0, "pool should be deployed with useTotalSurplusForCashOuts=true");

        // Accumulated project tokens should be cleared after deployment.
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "accumulated tokens should be zero after deploy");
    }

    /// @notice Compare behaviour: deploy with `useTotalSurplusForCashOuts = false`
    ///         (local surplus path) and `true` (total surplus path). Both must succeed.
    function test_LocalVsTotalSurplus_BothPathsSucceed() public {
        // ── Path A: local surplus (default, flag is false) ──
        // Already false by default. Accumulate and deploy.
        _accumulateViaController(PROJECT_ID, 100e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);
        uint256 tokenIdLocal = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertGt(tokenIdLocal, 0, "local surplus path should deploy successfully");

        // ── Path B: total surplus (flag is true) ──
        // Use a different project (project 3) so that we get a fresh state.
        uint256 projectB = 3;

        // Wire up project B with the same token set.
        tsController.setWeight(projectB, DEFAULT_WEIGHT);
        tsController.setReservedPercent(projectB, DEFAULT_RESERVED_PERCENT);
        tsController.setBaseCurrency(projectB, 1);
        tsController.setToken(projectB, address(projectToken));
        tsController.setUseTotalSurplus(projectB, true);

        _setDirectoryController(projectB, address(tsController));
        _setDirectoryTerminal(projectB, address(terminalToken), address(terminal));
        _addDirectoryTerminal(projectB, address(terminal));
        jbProjects.setOwner(projectB, owner);
        jbTokens.setToken(projectB, address(projectToken));
        terminal.setProjectToken(projectB, address(projectToken));
        store.setSurplus(projectB, 0.5e18);

        // Accumulate and deploy.
        projectToken.mint(address(hook), 100e18);
        JBSplitHookContext memory ctxB = _buildContext(projectB, address(projectToken), 100e18, 1);
        vm.prank(address(tsController));
        hook.processSplitWith(ctxB);

        vm.prank(owner);
        hook.deployPool(projectB, address(terminalToken), 0);
        uint256 tokenIdTotal = hook.tokenIdOf(projectB, address(terminalToken));
        assertGt(tokenIdTotal, 0, "total surplus path should deploy successfully");
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Test 2: Fee token claims excluded from rebalance
// ═══════════════════════════════════════════════════════════════════════

/// @title FeeTokensExcludedFromRebalanceTest
/// @notice After LP fees generate claimable fee tokens, a rebalance must NOT
///         consume those reserved fee tokens in the new LP position.
contract FeeTokensExcludedFromRebalanceTest is LPSplitHookV4TestBase {
    // Custom controller that can actually burn tokens.
    TotalSurplusController internal burnController;

    function setUp() public override {
        super.setUp();

        // We need a controller that can actually burn tokens so rebalance works.
        burnController = new TotalSurplusController();
        burnController.setPrices(address(prices));
        burnController.setWeight(PROJECT_ID, DEFAULT_WEIGHT);
        burnController.setReservedPercent(PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        burnController.setBaseCurrency(PROJECT_ID, 1);
        burnController.setToken(PROJECT_ID, address(projectToken));
        burnController.setWeight(FEE_PROJECT_ID, 100e18);
        burnController.setReservedPercent(FEE_PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        burnController.setBaseCurrency(FEE_PROJECT_ID, 1);
        burnController.setToken(FEE_PROJECT_ID, address(feeProjectToken));

        // Point directory at the burning controller.
        controller = MockJBController(address(burnController));
        _setDirectoryController(PROJECT_ID, address(burnController));
        _setDirectoryController(FEE_PROJECT_ID, address(burnController));

        // Set surplus for fee project so fee token routing works.
        store.setSurplus(FEE_PROJECT_ID, 0.5e18);
    }

    /// @notice Helper: accumulate with the burning controller as caller.
    function _accumulateForProject(uint256 projectId, uint256 amount) internal {
        projectToken.mint(address(hook), amount);
        JBSplitHookContext memory ctx = _buildReservedContext(projectId, amount);
        vm.prank(address(burnController));
        hook.processSplitWith(ctx);
    }

    /// @notice Deploy a pool, generate LP fee tokens, then rebalance. The reserved
    ///         fee tokens must still be claimable after the rebalance.
    function test_RebalanceDoesNotConsumeFeeTokens() public {
        // Step 1: accumulate and deploy a pool.
        _accumulateForProject(PROJECT_ID, 100e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        // Step 2: generate LP fees and collect them.
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        uint256 feeAmount = 50e18;

        // Set collectable fees on the terminal-token side.
        if (terminalIsToken0) {
            positionManager.setCollectableFees(tokenId, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, feeAmount);
        }
        // Mint terminal tokens to the position manager so collection works.
        terminalToken.mint(address(positionManager), feeAmount);

        // Collect fees — this generates claimable fee tokens.
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Record the claimable amount before rebalance.
        uint256 claimableBefore = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimableBefore, 0, "precondition: should have claimable fee tokens");

        // Step 3: rebalance the LP position.
        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        // Step 4: verify fee tokens are intact after rebalance.
        uint256 claimableAfter = hook.claimableFeeTokens(PROJECT_ID);
        assertEq(claimableAfter, claimableBefore, "claimable fee tokens must be unchanged after rebalance");

        // The hook must still hold at least the claimable amount of fee tokens.
        uint256 feeBalanceAfter = feeProjectToken.balanceOf(address(hook));
        assertGe(feeBalanceAfter, claimableAfter, "hook must still hold fee tokens after rebalance");

        // Step 5: verify claiming still works.
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);
        assertEq(
            feeProjectToken.balanceOf(user),
            claimableBefore,
            "user should receive all claimable fee tokens after rebalance"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Test 3: Fee token claims excluded from processSplitWith balance check
// ═══════════════════════════════════════════════════════════════════════

/// @title FeeTokensExcludedFromSplitBalanceCheckTest
/// @notice When `processSplitWith` is called during accumulation, the balance
///         guard subtracts `_totalOutstandingFeeTokenClaims` so that reserved
///         fee tokens do not cause a false `InsufficientBalance` revert.
contract FeeTokensExcludedFromSplitBalanceCheckTest is LPSplitHookV4TestBase {
    // Custom controller that can burn tokens.
    TotalSurplusController internal burnController;

    function setUp() public override {
        super.setUp();

        burnController = new TotalSurplusController();
        burnController.setPrices(address(prices));
        burnController.setWeight(PROJECT_ID, DEFAULT_WEIGHT);
        burnController.setReservedPercent(PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        burnController.setBaseCurrency(PROJECT_ID, 1);
        burnController.setToken(PROJECT_ID, address(projectToken));
        burnController.setWeight(FEE_PROJECT_ID, 100e18);
        burnController.setReservedPercent(FEE_PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        burnController.setBaseCurrency(FEE_PROJECT_ID, 1);
        burnController.setToken(FEE_PROJECT_ID, address(feeProjectToken));

        controller = MockJBController(address(burnController));
        _setDirectoryController(PROJECT_ID, address(burnController));
        _setDirectoryController(FEE_PROJECT_ID, address(burnController));
        store.setSurplus(FEE_PROJECT_ID, 0.5e18);
    }

    /// @notice Set up a second project (project 3) that shares the same hook clone
    ///         and whose project token IS the fee project token. After project 1
    ///         generates fee token claims, project 3 should still be able to
    ///         accumulate project tokens via processSplitWith without the balance
    ///         guard reverting.
    function test_ProcessSplitWith_BalanceCheckExcludesFeeTokenClaims() public {
        // ── Step 1: Deploy project 1's pool and generate fee tokens. ──

        // Accumulate and deploy for project 1.
        projectToken.mint(address(hook), 100e18);
        JBSplitHookContext memory ctx1 = _buildReservedContext(PROJECT_ID, 100e18);
        vm.prank(address(burnController));
        hook.processSplitWith(ctx1);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0);

        // Generate LP fees for project 1 so that claimableFeeTokens > 0.
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        uint256 feeAmount = 80e18;
        if (terminalIsToken0) {
            positionManager.setCollectableFees(tokenId, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, feeAmount);
        }
        terminalToken.mint(address(positionManager), feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Confirm fee tokens were generated.
        uint256 claimable = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimable, 0, "precondition: project 1 should have claimable fee tokens");

        // The fee tokens (feeProjectToken) are now held by the hook.
        uint256 hookFeeBalance = feeProjectToken.balanceOf(address(hook));
        assertGe(hookFeeBalance, claimable, "precondition: hook holds fee tokens");

        // ── Step 2: Set up project 3 whose project token IS the fee token. ──

        uint256 projectB = 3;
        burnController.setWeight(projectB, DEFAULT_WEIGHT);
        burnController.setReservedPercent(projectB, DEFAULT_RESERVED_PERCENT);
        burnController.setBaseCurrency(projectB, 1);
        // Project 3 uses feeProjectToken as its project token.
        burnController.setToken(projectB, address(feeProjectToken));

        _setDirectoryController(projectB, address(burnController));
        _setDirectoryTerminal(projectB, address(terminalToken), address(terminal));
        _addDirectoryTerminal(projectB, address(terminal));
        jbProjects.setOwner(projectB, owner);
        // JBTokens maps project 3 to the fee project token.
        jbTokens.setToken(projectB, address(feeProjectToken));
        terminal.setProjectToken(projectB, address(feeProjectToken));
        store.setSurplus(projectB, 0.5e18);

        // ── Step 3: Accumulate project tokens for project 3. ──

        // Mint fee-project tokens to the hook (simulating the controller transfer).
        uint256 accumAmount = 50e18;
        feeProjectToken.mint(address(hook), accumAmount);

        // Build context: project 3, token = feeProjectToken, groupId = 1.
        JBSplitHookContext memory ctx3 = _buildContext(projectB, address(feeProjectToken), accumAmount, 1);

        // The balance guard in processSplitWith checks:
        //   balanceOf(this) - _totalOutstandingFeeTokenClaims >= accumulatedProjectTokens
        // Without the subtraction, this would revert because balanceOf includes
        // project 1's reserved fee tokens that do not belong to project 3.
        vm.prank(address(burnController));
        hook.processSplitWith(ctx3);

        // ── Step 4: Verify accumulation succeeded. ──
        assertEq(
            hook.accumulatedProjectTokens(projectB),
            accumAmount,
            "project 3 should have accumulated tokens despite outstanding fee claims"
        );

        // Project 1's claimable fee tokens are unaffected.
        assertEq(hook.claimableFeeTokens(PROJECT_ID), claimable, "project 1 claimable fee tokens should be unchanged");
    }
}
