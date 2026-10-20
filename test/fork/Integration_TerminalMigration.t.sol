// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkDeployHelper} from "../helpers/ForkDeployHelper.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

contract Integration_TerminalMigration is ForkDeployHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    JBMultiTerminal jbMultiTerminal2;
    JBUniswapV4LPSplitHook hook;
    uint256 feeProjectId;
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);
        _deployJBCore();

        // Deploy a second terminal for migration tests.
        jbMultiTerminal2 = new JBMultiTerminal(
            jbFeelessAddresses,
            jbPermissions,
            jbProjects,
            jbSplits,
            jbTerminalStore,
            jbTokens,
            IPermit2(address(PERMIT2)),
            trustedForwarder
        );

        feeProjectId = _launchFeeProject();
        vm.prank(multisig);
        jbController.deployERC20For(feeProjectId, "Fee Token", "FEE", bytes32(0));
        JBUniswapV4LPSplitHook hookImpl = new JBUniswapV4LPSplitHook(
            address(jbDirectory),
            IJBPermissions(address(jbPermissions)),
            address(jbTokens),
            IAllowanceTransfer(address(PERMIT2)),
            IJBSuckerRegistry(address(0))
        );
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));
        hook.initialize({
            initialFeeProjectId: feeProjectId,
            initialFeePercent: 3800,
            newPoolManager: V4_POOL_MANAGER,
            newPositionManager: V4_POSITION_MANAGER,
            newOracleHook: _deployGeomeanOracleHook(V4_POOL_MANAGER),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });
    }

    /// @notice A project whose balance migrates to a second terminal still recycles: after the migration and a fresh
    /// reserved-token distribution, a permissionless `addLiquidity` re-mints the ask with liquidity.
    function test_fork_integration_terminalMigration_recycleAfterMigration() public {
        // Launch a migratable project with a 50% cash-out tax so the corridor depends on the terminal's surplus.
        uint256 pid =
            _launchProjectWithMigration({reservedPercent: 0, cashOutTaxRate: 5000, weight: 1_000_000e18, duration: 0});

        // Give the project an ERC-20 so the hook can pair it in a pool.
        vm.prank(multisig);
        IJBToken pToken =
            jbController.deployERC20For({projectId: pid, name: "Migration Token", symbol: "MIG", salt: bytes32(0)});

        // Fund the first terminal and hand the hook inventory, then deploy the pool and its first ask.
        _payProject({pid: pid, amount: 50 ether});
        _accumulateTokens({pid: pid, tokenAddr: address(pToken), amount: 100_000e18});
        vm.prank(multisig);
        hook.deployPool(pid);
        assertTrue(hook.isPoolDeployed({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}), "Pool deployed");

        // Record the first ask so the recycle can be compared against it.
        uint256 initialTokenId = hook.askTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
        uint128 initialLiq = V4_POSITION_MANAGER.getPositionLiquidity(initialTokenId);
        assertTrue(initialLiq > 0, "Initial position has liquidity");

        // Before migration the first terminal is primary and holds the project's balance.
        IJBTerminal primaryBefore = jbDirectory.primaryTerminalOf({projectId: pid, token: JBConstants.NATIVE_TOKEN});
        assertEq(address(primaryBefore), address(jbMultiTerminal), "Primary terminal is terminal 1 before migration");
        uint256 balanceBefore = jbTerminalStore.balanceOf({
            terminal: address(jbMultiTerminal), projectId: pid, token: JBConstants.NATIVE_TOKEN
        });
        assertGt(balanceBefore, 0, "Terminal 1 should hold project balance before migration");

        // Move the whole native balance to the second terminal.
        vm.prank(multisig);
        jbMultiTerminal.migrateBalanceOf({
            projectId: pid, token: JBConstants.NATIVE_TOKEN, to: IJBTerminal(address(jbMultiTerminal2))
        });

        // The balance left the first terminal and landed in the second.
        uint256 oldBalance = jbTerminalStore.balanceOf({
            terminal: address(jbMultiTerminal), projectId: pid, token: JBConstants.NATIVE_TOKEN
        });
        uint256 newBalance = jbTerminalStore.balanceOf({
            terminal: address(jbMultiTerminal2), projectId: pid, token: JBConstants.NATIVE_TOKEN
        });
        assertEq(oldBalance, 0, "Old terminal balance should be zero after migration");
        assertGt(newBalance, 0, "New terminal should hold migrated balance");

        // Make the second terminal the project's only terminal, so it becomes primary.
        IJBTerminal[] memory newTerminals = new IJBTerminal[](1);
        newTerminals[0] = IJBTerminal(address(jbMultiTerminal2));
        vm.prank(multisig);
        jbDirectory.setTerminalsOf({projectId: pid, terminals: newTerminals});
        IJBTerminal primaryAfter = jbDirectory.primaryTerminalOf({projectId: pid, token: JBConstants.NATIVE_TOKEN});
        assertEq(address(primaryAfter), address(jbMultiTerminal2), "Primary terminal is terminal 2 after migration");

        // Pay through the second terminal so it holds fresh surplus of its own.
        jbMultiTerminal2.pay{value: 10 ether}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // More reserved tokens arrive after the migration; the recycle reads the corridor through the new terminal.
        _accumulateTokens({pid: pid, tokenAddr: address(pToken), amount: 10_000e18});

        // Pin the TWAP to the spot so the hook's spot-vs-TWAP guard passes.
        _mockOracleTwapEqualsSpot({
            oracle: hook.oracleHook(),
            pm: V4_POOL_MANAGER,
            key: hook.poolKeyOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN})
        });

        // Permissionless: any non-owner stranger may recycle.
        vm.prank(address(0xB0BB1E));
        hook.addLiquidity({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});

        // The recycle minted an ask that holds liquidity.
        uint256 newTokenId = hook.askTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
        assertTrue(newTokenId > 0, "New tokenId exists");
        uint128 newLiq = V4_POSITION_MANAGER.getPositionLiquidity(newTokenId);
        assertTrue(newLiq > 0, "Recycled ask has liquidity after terminal migration");

        // Log the before and after positions for inspection.
        emit log_named_uint("  Initial tokenId", initialTokenId);
        emit log_named_uint("  Initial liquidity", initialLiq);
        emit log_named_uint("  New tokenId", newTokenId);
        emit log_named_uint("  New liquidity", newLiq);
    }

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
            scopeCashOutsToLocalBalances: true,
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
            scopeCashOutsToLocalBalances: true,
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
            projectId: pid, tokenCount: amount, beneficiary: address(jbController), memo: "", useReservedPercent: false
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
        vm.startPrank(address(jbController));
        IERC20(tokenAddr).approve(address(hook), amount);
        // Cap the gas below the automation floor so the hook records the intake and skips inline automation.
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();
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
