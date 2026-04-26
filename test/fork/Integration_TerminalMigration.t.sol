// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

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
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";

/// @notice Integration fork test: deploy pool on terminal 1, migrate balance to terminal 2,
///         then rebalance. Verifies the LP split hook resolves the terminal dynamically via
///         `primaryTerminalOf()` and works correctly after terminal migration.
contract Integration_TerminalMigration is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

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
    JBMultiTerminal jbMultiTerminal2;

    JBUniswapV4LPSplitHook hook;
    uint256 feeProjectId;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);
        _deployJBCore();

        feeProjectId = _launchFeeProject();
        vm.prank(multisig);
        jbController.deployERC20For(feeProjectId, "Fee Token", "FEE", bytes32(0));

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
        hook.initialize(feeProjectId, 3800);
    }

    /// @notice Deploy pool on terminal 1, migrate balance to terminal 2, pay via terminal 2,
    ///         rebalance. The hook should resolve the new terminal via `primaryTerminalOf()`.
    function test_fork_integration_terminalMigration_rebalanceAfterMigration() public {
        // 1. Launch project with both terminals and migration-friendly metadata.
        uint256 pid =
            _launchProjectWithMigration({reservedPercent: 0, cashOutTaxRate: 5000, weight: 1_000_000e18, duration: 0});

        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Migration Token", "MIG", bytes32(0));

        // 2. Pay 50 ETH via the first terminal and accumulate tokens for the hook.
        _payProject(pid, 50 ether);
        _accumulateTokens(pid, address(pToken), 100_000e18);

        // 3. Deploy pool on the first terminal.
        vm.prank(multisig);
        hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);
        assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "Pool deployed");

        uint256 initialTokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        uint128 initialLiq = V4_POSITION_MANAGER.getPositionLiquidity(initialTokenId);
        assertTrue(initialLiq > 0, "Initial position has liquidity");

        // 4. Verify the primary terminal is terminal 1 (first in the array from launch).
        IJBTerminal primaryBefore = jbDirectory.primaryTerminalOf(pid, JBConstants.NATIVE_TOKEN);
        assertEq(address(primaryBefore), address(jbMultiTerminal), "Primary terminal is terminal 1 before migration");

        // 5. Snapshot balance before migration.
        uint256 balanceBefore = jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, JBConstants.NATIVE_TOKEN);
        assertGt(balanceBefore, 0, "Terminal 1 should hold project balance before migration");

        // 6. Migrate balance from terminal 1 to terminal 2.
        vm.prank(multisig);
        jbMultiTerminal.migrateBalanceOf(pid, JBConstants.NATIVE_TOKEN, IJBTerminal(address(jbMultiTerminal2)));

        // 7. Verify old terminal balance is zero and new terminal received the funds.
        uint256 oldBalance = jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, JBConstants.NATIVE_TOKEN);
        uint256 newBalance = jbTerminalStore.balanceOf(address(jbMultiTerminal2), pid, JBConstants.NATIVE_TOKEN);
        assertEq(oldBalance, 0, "Old terminal balance should be zero after migration");
        assertGt(newBalance, 0, "New terminal should hold migrated balance");

        // 9. Set only terminal 2 as the project's terminal, making it the primary.
        IJBTerminal[] memory newTerminals = new IJBTerminal[](1);
        newTerminals[0] = IJBTerminal(address(jbMultiTerminal2));
        vm.prank(multisig);
        jbDirectory.setTerminalsOf(pid, newTerminals);

        // 10. Verify the primary terminal is now terminal 2.
        IJBTerminal primaryAfter = jbDirectory.primaryTerminalOf(pid, JBConstants.NATIVE_TOKEN);
        assertEq(address(primaryAfter), address(jbMultiTerminal2), "Primary terminal is terminal 2 after migration");

        // 11. Pay 10 ETH via the new terminal.
        jbMultiTerminal2.pay{value: 10 ether}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // 12. Rebalance — hook resolves terminal dynamically via primaryTerminalOf().
        vm.prank(multisig);
        hook.rebalanceLiquidity({
            projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN, decreaseAmount0Min: 0, decreaseAmount1Min: 0
        });

        // 13. Verify the rebalanced position has liquidity.
        uint256 newTokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        assertTrue(newTokenId > 0, "New tokenId exists");
        uint128 newLiq = V4_POSITION_MANAGER.getPositionLiquidity(newTokenId);
        assertTrue(newLiq > 0, "Rebalanced position has liquidity after terminal migration");

        emit log_named_uint("  Initial tokenId", initialTokenId);
        emit log_named_uint("  Initial liquidity", initialLiq);
        emit log_named_uint("  New tokenId", newTokenId);
        emit log_named_uint("  New liquidity", newLiq);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _deployJBCore() internal {
        jbPermissions = new JBPermissions(trustedForwarder);
        jbProjects = new JBProjects(multisig, address(0), trustedForwarder);
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        JBERC20 jbErc20 = new JBERC20(jbPermissions, jbProjects);
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

        jbMultiTerminal2 = new JBMultiTerminal(
            jbFeelessAddresses,
            jbPermissions,
            jbProjects,
            jbSplits,
            jbTerminalStore,
            jbTokens,
            PERMIT2,
            trustedForwarder
        );

        vm.deal(address(this), 10_000 ether);
    }

    /// @dev Launch a simple fee project (no migration flags needed).
    function _launchFeeProject() internal returns (uint256 id) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
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

    /// @dev Launch a project with both terminals and migration-friendly metadata.
    function _launchProjectWithMigration(
        uint16 reservedPercent,
        uint16 cashOutTaxRate,
        uint112 weight,
        uint32 duration
    )
        internal
        returns (uint256 id)
    {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: cashOutTaxRate,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: true,
            allowSetTerminals: true,
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
        rulesetConfigs[0].duration = duration;
        rulesetConfigs[0].weight = weight;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Include both terminals so both have accounting contexts from the start.
        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](2);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});
        terminalConfigs[1] = JBTerminalConfig({terminal: jbMultiTerminal2, accountingContextsToAccept: tokensToAccept});

        id = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    function _accumulateTokens(uint256 pid, address tokenAddr, uint256 amount) internal {
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: amount, beneficiary: address(hook), memo: "", useReservedPercent: false
        });

        JBSplitHookContext memory context = JBSplitHookContext({
            token: tokenAddr,
            amount: amount,
            decimals: 18,
            projectId: pid,
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
    }

    function _payProject(uint256 pid, uint256 amount) internal {
        jbMultiTerminal.pay{value: amount}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }
}
