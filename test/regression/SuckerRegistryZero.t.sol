// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

contract CashOutRateHarness is JBUniswapV4LPSplitHook {
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IAllowanceTransfer permit2,
        IJBSuckerRegistry suckerRegistry
    )
        JBUniswapV4LPSplitHook(directory, permissions, tokens, permit2, suckerRegistry)
    {}

    function exposedGetCashOutRate(
        uint256 projectId,
        address terminalToken,
        address controller,
        JBRuleset memory ruleset
    )
        external
        view
        returns (uint256)
    {
        return JBUniswapV4LPSplitHookMath.getCashOutRate(
            IJBDirectory(DIRECTORY), SUCKER_REGISTRY, projectId, terminalToken, controller, ruleset
        );
    }
}

contract SuckerRegistryZeroTest is LPSplitHookV4TestBase {
    CashOutRateHarness internal zeroRegistryHook;

    function setUp() public override {
        super.setUp();

        zeroRegistryHook = new CashOutRateHarness({
            directory: address(directory),
            permissions: IJBPermissions(address(permissions)),
            tokens: address(jbTokens),
            permit2: IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3),
            suckerRegistry: IJBSuckerRegistry(address(0))
        });
        zeroRegistryHook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });

        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.totalTokenSupplyWithReservedTokensOf.selector, PROJECT_ID),
            abi.encode(uint256(1000e18))
        );
    }

    function test_unscopedCashOutRateRevertsWhenSuckerRegistryIsZero() public {
        JBRuleset memory unscopedRuleset = _rulesetWithScope(false);

        vm.expectRevert();
        zeroRegistryHook.exposedGetCashOutRate({
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            controller: address(controller),
            ruleset: unscopedRuleset
        });
    }

    function _rulesetWithScope(bool scopeCashOutsToLocalBalances) internal view returns (JBRuleset memory) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 5000,
            baseCurrency: 1,
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
            scopeCashOutsToLocalBalances: scopeCashOutsToLocalBalances,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        return JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            // Safe: DEFAULT_WEIGHT is the shared test fixture issuance weight and fits in JBRuleset.weight.
            // forge-lint: disable-next-line(unsafe-typecast)
            weight: uint112(DEFAULT_WEIGHT),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadataResolver.packRulesetMetadata(metadata)
        });
    }
}
