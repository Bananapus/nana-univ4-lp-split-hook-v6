// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkDeployHelper} from "../helpers/ForkDeployHelper.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

contract Integration_BurnPathCrossProject is ForkDeployHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    JBUniswapV4LPSplitHook hook;
    uint256 feeProjectId;
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);
        _deployJBCore();
        feeProjectId = _launchProject({reservedPercent: 0, cashOutTaxRate: 0, weight: 1_000_000e18});
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

    function test_fork_integration_burnPathCrossProject() public {
        uint256 pidA = _launchProject({reservedPercent: 0, cashOutTaxRate: 5000, weight: 1_000_000e18});
        vm.prank(multisig);
        IJBToken pTokenA = jbController.deployERC20For(pidA, "Project A Token", "TKA", bytes32(0));
        _payProject(pidA, 50 ether);
        _accumulateTokens(pidA, address(pTokenA), 100_000e18);
        uint256 pidB = _launchProject({reservedPercent: 0, cashOutTaxRate: 5000, weight: 500_000e18});
        vm.prank(multisig);
        IJBToken pTokenB = jbController.deployERC20For(pidB, "Project B Token", "TKB", bytes32(0));
        _payProject(pidB, 30 ether);
        _accumulateTokens(pidB, address(pTokenB), 80_000e18);
        vm.prank(multisig);
        hook.deployPool(pidA, 0);
        assertTrue(hook.isPoolDeployed(pidA, JBConstants.NATIVE_TOKEN), "A deployed");
        uint256 bAccBefore = hook.accumulatedProjectTokens(pidB);
        uint256 bBalBefore = IERC20(address(pTokenB)).balanceOf(address(hook));
        uint256 burnAmount = 50_000e18;
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pidA,
            tokenCount: burnAmount,
            beneficiary: address(jbController),
            memo: "",
            useReservedPercent: false
        });
        JBSplitHookContext memory burnCtx = JBSplitHookContext({
            token: address(pTokenA),
            amount: burnAmount,
            decimals: 18,
            projectId: pidA,
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
        IERC20(address(pTokenA)).approve(address(hook), burnAmount);
        hook.processSplitWith(burnCtx);
        vm.stopPrank();
        assertEq(hook.accumulatedProjectTokens(pidA), 0, "A accumulated stays 0 after burn");
        assertEq(hook.accumulatedProjectTokens(pidB), bAccBefore, "B accumulated unchanged");
        assertEq(IERC20(address(pTokenB)).balanceOf(address(hook)), bBalBefore, "B token balance unchanged");
        vm.prank(multisig);
        hook.deployPool(pidB, 0);
        assertTrue(hook.isPoolDeployed(pidB, JBConstants.NATIVE_TOKEN), "B deployed");
        uint256 bTokenId = hook.tokenIdOf(pidB, JBConstants.NATIVE_TOKEN);
        uint128 bLiq = V4_POSITION_MANAGER.getPositionLiquidity(bTokenId);
        assertTrue(bLiq > 0, "B has liquidity");
        assertEq(hook.accumulatedProjectTokens(pidB), 0, "B accumulated cleared after deploy");
        emit log_named_uint("  B liquidity", bLiq);
    }

    function _launchProject(
        uint16 reservedPercent,
        uint16 cashOutTaxRate,
        uint112 weight
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
        hook.processSplitWith(context);
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
