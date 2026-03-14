// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

// JB core — deploy fresh within fork.
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBRulesets} from "@bananapus/core-v6/src/JBRulesets.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";
import {JBSplits} from "@bananapus/core-v6/src/JBSplits.sol";
import {JBPrices} from "@bananapus/core-v6/src/JBPrices.sol";
import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBFundAccessLimits} from "@bananapus/core-v6/src/JBFundAccessLimits.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

// Uniswap V4.
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// Hook under test.
import {LibClone} from "solady/src/utils/LibClone.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork tests for JBUniswapV4LPSplitHook with real V4 PoolManager + PositionManager
///         and real JB core. Exercises the full lifecycle: accumulate → deploy pool → verify V4 state.
contract LPSplitHookForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ───────────────────────── Mainnet addresses
    // ──────────────────────────

    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // ───────────────────────── JB core (deployed fresh)
    // ───────────────────

    address multisig = address(0xBEEF);
    address trustedForwarder = address(0);

    JBPermissions jbPermissions;
    JBProjects jbProjects;
    JBDirectory jbDirectory;
    JBRulesets jbRulesets;
    JBTokens jbTokens;
    JBSplits jbSplits;
    JBPrices jbPrices;
    JBFundAccessLimits jbFundAccessLimits;
    JBFeelessAddresses jbFeelessAddresses;
    JBController jbController;
    JBTerminalStore jbTerminalStore;
    JBMultiTerminal jbMultiTerminal;

    // ───────────────────────── Hook under test
    // ────────────────────────────

    JBUniswapV4LPSplitHook hook;

    // ───────────────────────── Project state
    // ──────────────────────────────

    uint256 feeProjectId; // Project 1 (fee recipient).
    uint256 projectId; // Project 2 (test project with LP split hook).
    IJBToken projectToken;

    // Accept ETH for cashout returns.
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);

        // Verify V4 contracts exist on this fork.
        require(address(V4_POOL_MANAGER).code.length > 0, "PoolManager not deployed");
        require(address(V4_POSITION_MANAGER).code.length > 0, "PositionManager not deployed");

        // Deploy all JB core contracts fresh.
        _deployJBCore();

        // Launch fee project (project 1) — accepts ETH.
        feeProjectId = _launchProject(false);
        require(feeProjectId == 1, "fee project must be #1");

        // Launch test project (project 2) — accepts ETH, with reserved percent + owner minting.
        projectId = _launchProject(true);

        // Deploy ERC-20 for the test project.
        vm.prank(multisig);
        projectToken = jbController.deployERC20For(projectId, "Test Token", "TST", bytes32(0));

        // Pay ETH into the project to build surplus (needed for cashout during pool deployment).
        jbMultiTerminal.pay{value: 10 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Deploy the hook with real V4 contracts.
        JBUniswapV4LPSplitHook hookImpl = new JBUniswapV4LPSplitHook(
            address(jbDirectory),
            IJBPermissions(address(jbPermissions)),
            address(jbTokens),
            V4_POOL_MANAGER,
            V4_POSITION_MANAGER,
            IAllowanceTransfer(address(PERMIT2)),
            IHooks(address(0))
        );
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));
        hook.initialize(feeProjectId, 3800); // 38% fee to fee project.

        // Mint project tokens to the hook (simulating reserved token split distribution).
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId,
            tokenCount: 100_000e18,
            beneficiary: address(hook),
            memo: "",
            useReservedPercent: false
        });

        // Simulate the controller calling processSplitWith to trigger accumulation.
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(projectToken),
            amount: 100_000e18,
            decimals: 18,
            projectId: projectId,
            groupId: 1, // reserved token group
            split: JBSplit({
                percent: 1_000_000,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(hook))
            })
        });

        vm.prank(address(jbController));
        hook.processSplitWith(context);
    }

    // ───────────────────────── Tests
    // ──────────────────────────────────────

    /// @notice Verify tokens were accumulated after processSplitWith.
    function test_fork_tokensAccumulated() public view {
        assertEq(hook.accumulatedProjectTokens(projectId), 100_000e18, "should have accumulated 100k tokens");
        assertFalse(hook.projectDeployed(projectId, JBConstants.NATIVE_TOKEN), "should not be deployed yet");
    }

    /// @notice Deploy a real V4 pool via the hook — the core integration test.
    function test_fork_deployPool_createsRealV4Pool() public {
        // Deploy the pool. The hook will:
        //   1. Compute tick bounds from JB issuance/cashout rates
        //   2. Cash out some project tokens via the real terminal to get ETH
        //   3. Initialize a real V4 pool via PositionManager
        //   4. Mint a real LP position NFT
        vm.prank(multisig);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);

        // Verify pool was deployed.
        assertTrue(hook.projectDeployed(projectId, JBConstants.NATIVE_TOKEN), "project should be deployed");
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "pool should be deployed");

        // Verify the hook holds a real PositionManager NFT.
        uint256 tokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        assertTrue(tokenId != 0, "should hold a position NFT");

        // Verify accumulated tokens were cleared.
        assertEq(hook.accumulatedProjectTokens(projectId), 0, "accumulated should be 0 after deploy");

        // Verify the V4 pool actually has liquidity by checking pool state.
        PoolKey memory key = hook.poolKeyOf(projectId, JBConstants.NATIVE_TOKEN);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = V4_POOL_MANAGER.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "pool should be initialized with nonzero price");

        // Check position-level liquidity (getLiquidity checks active tick which may be outside range).
        uint128 positionLiquidity = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(positionLiquidity > 0, "position should have liquidity");
    }

    /// @notice After pool deployment, new tokens sent via processSplitWith should be burned.
    function test_fork_burnAfterDeploy() public {
        // Deploy pool first.
        vm.prank(multisig);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);

        // Mint more tokens to the hook.
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId, tokenCount: 50_000e18, beneficiary: address(hook), memo: "", useReservedPercent: false
        });

        uint256 supplyBefore = IERC20(address(projectToken)).totalSupply();

        // Process split — should burn, not accumulate.
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(projectToken),
            amount: 50_000e18,
            decimals: 18,
            projectId: projectId,
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

        vm.prank(address(jbController));
        hook.processSplitWith(context);

        // Accumulated should still be 0 (tokens burned, not accumulated).
        assertEq(hook.accumulatedProjectTokens(projectId), 0, "should not accumulate after deploy");

        // Total supply should have decreased (tokens burned).
        uint256 supplyAfter = IERC20(address(projectToken)).totalSupply();
        assertLt(supplyAfter, supplyBefore, "total supply should decrease from burn");
    }

    /// @notice Verify that deployPool uses Permit2 (not direct ERC20 approval) to settle
    ///         tokens with the real PositionManager. Without the Permit2 fix, this would
    ///         revert with AllowanceExpired(0) because PositionManager's SETTLE action
    ///         pulls tokens via Permit2, not via ERC20.transferFrom.
    function test_fork_deployPool_usesPermit2NotDirectApproval() public {
        address token = address(projectToken);

        // Before deploy: hook has zero ERC20 allowance to both PositionManager and Permit2.
        assertEq(
            IERC20(token).allowance(address(hook), address(V4_POSITION_MANAGER)),
            0,
            "hook should have no direct allowance to PM before deploy"
        );
        assertEq(
            IERC20(token).allowance(address(hook), address(PERMIT2)),
            0,
            "hook should have no allowance to Permit2 before deploy"
        );

        // Deploy succeeds — this is the proof the Permit2 flow works.
        // With the old forceApprove(POSITION_MANAGER) approach, this would revert
        // because the real PositionManager uses Permit2.transferFrom, not ERC20.transferFrom.
        vm.prank(multisig);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);

        // After deploy: hook should still have zero DIRECT allowance to PositionManager.
        // This proves the hook routes approvals through Permit2, not directly.
        assertEq(
            IERC20(token).allowance(address(hook), address(V4_POSITION_MANAGER)),
            0,
            "hook should never directly approve PositionManager"
        );

        // Pool should be fully functional.
        uint256 tokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        uint128 liq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(liq > 0, "position should have liquidity via Permit2 flow");
    }

    // ───────────────────────── Internal deployment helpers
    // ────────────────

    // forge-lint: disable-next-line(mixed-case-function)
    function _deployJBCore() internal {
        jbPermissions = new JBPermissions(trustedForwarder);
        jbProjects = new JBProjects(multisig, address(0), trustedForwarder);
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        JBERC20 jbErc20 = new JBERC20();
        jbTokens = new JBTokens(jbDirectory, jbErc20);
        jbRulesets = new JBRulesets(jbDirectory);
        jbPrices = new JBPrices(jbDirectory, jbPermissions, jbProjects, multisig, trustedForwarder);
        jbSplits = new JBSplits(jbDirectory);
        jbFundAccessLimits = new JBFundAccessLimits(jbDirectory);
        jbFeelessAddresses = new JBFeelessAddresses(multisig);

        jbController = new JBController(
            jbDirectory,
            jbFundAccessLimits,
            jbPermissions,
            jbPrices,
            jbProjects,
            jbRulesets,
            jbSplits,
            jbTokens,
            address(0),
            trustedForwarder
        );

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);

        jbTerminalStore = new JBTerminalStore(jbDirectory, jbPrices, jbRulesets);

        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses,
            jbPermissions,
            jbProjects,
            jbSplits,
            jbTerminalStore,
            jbTokens,
            PERMIT2,
            trustedForwarder
        );

        vm.deal(address(this), 100 ether);
    }

    function _launchProject(bool withOwnerMinting) internal returns (uint256 id) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: withOwnerMinting ? 1000 : 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: withOwnerMinting,
            allowSetCustomToken: withOwnerMinting,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 1_000_000e18;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        id = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    // ───────────────────────── Existing Pool (pre-initialized)
    // ─────────────

    /// @notice When the pool was already initialized by another party (e.g. REVDeployer)
    ///         at a different sqrtPrice than _computeInitialSqrtPrice would return,
    ///         deployPool should still succeed by reading the pool's actual price via getSlot0.
    function test_fork_deployPool_existingPool_addsLiquidity() public {
        // Build the same pool key the hook will use.
        address projToken = address(projectToken);
        Currency termCurrency = Currency.wrap(address(0)); // native ETH
        Currency projCurrency = Currency.wrap(projToken);

        (Currency currency0, Currency currency1) =
            termCurrency < projCurrency ? (termCurrency, projCurrency) : (projCurrency, termCurrency);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        // Initialize the pool externally at the issuance rate price (different from the
        // geometric mean that _computeInitialSqrtPrice would compute).
        // Use a price that's clearly different from the midpoint.
        uint160 externalSqrtPrice = TickMath.getSqrtPriceAtTick(int24(69_000));
        V4_POSITION_MANAGER.initializePool(key, externalSqrtPrice);

        // Verify pool is initialized with our external price.
        PoolId poolId = key.toId();
        (uint160 sqrtPriceBefore,,,) = V4_POOL_MANAGER.getSlot0(poolId);
        assertEq(sqrtPriceBefore, externalSqrtPrice, "pool should be at external price");

        // Now deploy via the hook — it should detect the existing pool and use its actual price.
        vm.prank(multisig);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);

        // Verify deployment succeeded.
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "pool should be deployed");
        uint256 tokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        assertTrue(tokenId != 0, "should hold a position NFT");

        // Verify position has liquidity.
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "position should have liquidity in existing pool");

        // Verify the pool price didn't change (adding liquidity doesn't move the price).
        (uint160 sqrtPriceAfter,,,) = V4_POOL_MANAGER.getSlot0(poolId);
        assertEq(sqrtPriceAfter, sqrtPriceBefore, "pool price should not change from liquidity add");

        // Accumulated tokens should be cleared.
        assertEq(hook.accumulatedProjectTokens(projectId), 0, "accumulated should be 0 after deploy");
    }

    // ───────────────────────── Weight Decay Permissionless Deploy
    // ──────

    /// @notice Deploy pool as a random user after weight has decayed 10x via ruleset cycling.
    function test_fork_deployPool_permissionlessAfterWeightDecay() public {
        // The setUp already launched the project with weight=1_000_000e18, duration=0, weightCutPercent=0.
        // Queue a new ruleset with duration and weight cut so weight decays over time.
        JBRulesetMetadata memory newMeta = JBRulesetMetadata({
            reservedPercent: 1000,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory newConfigs = new JBRulesetConfig[](1);
        newConfigs[0].mustStartAtOrAfter = 0;
        newConfigs[0].duration = 1 days;
        newConfigs[0].weight = 1_000_000e18;
        newConfigs[0].weightCutPercent = 800_000_000; // 80% cut per cycle
        newConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        newConfigs[0].metadata = newMeta;
        newConfigs[0].splitGroups = new JBSplitGroup[](0);
        newConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        vm.prank(multisig);
        jbController.queueRulesetsOf(projectId, newConfigs, "");

        // Warp 3 days: cycle0=1M, cycle1=200k (5x), cycle2=40k (25x > 10x threshold)
        vm.warp(block.timestamp + 3 days);

        // Verify initial weight was recorded during setUp's processSplitWith
        uint256 initialWeight = hook.initialWeightOf(projectId);
        assertTrue(initialWeight > 0, "initialWeightOf should be set from setUp accumulation");

        // Verify current weight has decayed sufficiently
        (JBRuleset memory currentRuleset,) = jbController.currentRulesetOf(projectId);
        assertTrue(currentRuleset.weight * 10 <= initialWeight, "weight should have decayed >= 10x");

        // Random user should be able to deploy permissionlessly
        address randomUser = makeAddr("randomDeployer");
        vm.prank(randomUser);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);

        // Verify pool was deployed
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "pool should be deployed by random user");
        uint256 tokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        assertTrue(tokenId != 0, "should hold a position NFT");
    }

    /// @notice Random user cannot deploy when weight hasn't decayed enough.
    function test_fork_deployPool_requiresPermissionBeforeDecay() public {
        // The setUp launched with weight=1_000_000e18, no decay.
        // initialWeightOf was set to 1_000_000e18 during processSplitWith.
        // Current weight == initial weight, so permission is required.

        address randomUser = makeAddr("randomDeployer");
        vm.prank(randomUser);
        vm.expectRevert();
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);
    }
}
