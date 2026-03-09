// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

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

// Uniswap V4.
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// Hook under test.
import {LibClone} from "solady/src/utils/LibClone.sol";
import {UniV4DeploymentSplitHook} from "../src/UniV4DeploymentSplitHook.sol";
import {IJBPermissions} from "@bananapus/core/interfaces/IJBPermissions.sol";
import {IJBSplitHook} from "@bananapus/core/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core/structs/JBSplitHookContext.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork tests for UniV4DeploymentSplitHook with real V4 PoolManager + PositionManager
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

    UniV4DeploymentSplitHook hook;

    // ───────────────────────── Project state
    // ──────────────────────────────

    uint256 feeProjectId; // Project 1 (fee recipient).
    uint256 projectId; // Project 2 (test project with LP split hook).
    IJBToken projectToken;

    // Accept ETH for cashout returns.
    receive() external payable {}

    function setUp() public {
        // Skip fork tests when the RPC URL is not available.
        string memory rpcUrl = vm.envOr("RPC_ETHEREUM_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpcUrl);

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
        UniV4DeploymentSplitHook hookImpl = new UniV4DeploymentSplitHook(
            address(jbDirectory),
            IJBPermissions(address(jbPermissions)),
            address(jbTokens),
            V4_POOL_MANAGER,
            V4_POSITION_MANAGER
        );
        hook = UniV4DeploymentSplitHook(payable(LibClone.clone(address(hookImpl))));
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
        assertFalse(hook.projectDeployed(projectId), "should not be deployed yet");
    }

    /// @notice Deploy a real V4 pool via the hook — the core integration test.
    function test_fork_deployPool_createsRealV4Pool() public {
        // Deploy the pool. The hook will:
        //   1. Compute tick bounds from JB issuance/cashout rates
        //   2. Cash out some project tokens via the real terminal to get ETH
        //   3. Initialize a real V4 pool via PositionManager
        //   4. Mint a real LP position NFT
        vm.prank(multisig);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0, 0, 0);

        // Verify pool was deployed.
        assertTrue(hook.projectDeployed(projectId), "project should be deployed");
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
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0, 0, 0);

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

    // ───────────────────────── Internal deployment helpers
    // ────────────────

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
            reservedPercent: withOwnerMinting ? 1000 : 0, // 10% reserved for test project.
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
        rulesetConfigs[0].weight = 1_000_000e18; // 1M tokens per ETH.
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
}
