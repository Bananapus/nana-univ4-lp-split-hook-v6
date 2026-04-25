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
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";

/// @notice Fork test proving M-46 fix: tick bounds are clamped on all code paths,
///         including the cashOutRate==0 early-return path.
contract M46_TickBoundsFork is Test {
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

    /// @notice Deploy pool with extreme issuance rate that pushes the issuance tick near boundaries.
    ///         The cashOutRate==0 path must clamp tickLower/tickUpper to valid V4 range.
    ///         Without the M-46 fix, the unclamped tick could violate TickMath bounds.
    function test_fork_m46_extremeIssuanceRate_ticksClamped() public {
        // Use very high weight so issuance tick is pushed near boundaries.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint112 extremeWeight = uint112(1e28);
        uint256 pid = _launchProject({reservedPercent: 0, cashOutTaxRate: 0, weight: extremeWeight});

        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Extreme Tick Token", "ETT", bytes32(0));

        // No surplus → cashOutRate == 0, takes the early-return path.
        _accumulateTokens(pid, address(pToken), 100_000e18);

        // Deploy pool — exercises the M-46 clamped early-return path.
        vm.prank(multisig);
        // This may revert with ZeroLiquidity (since no terminal tokens to pair),
        // but should NOT revert with TickMath errors. Either success or ZeroLiquidity is valid.
        try hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0) {
            assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "Pool should deploy");

            PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
            (uint160 sqrtPriceX96,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
            assertTrue(sqrtPriceX96 >= TickMath.MIN_SQRT_PRICE, "sqrtPrice >= MIN");
            assertTrue(sqrtPriceX96 <= TickMath.MAX_SQRT_PRICE, "sqrtPrice <= MAX");

            emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
        } catch (bytes memory reason) {
            // ZeroLiquidity is acceptable when there's no surplus to pair.
            assertEq(
                bytes4(reason),
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ZeroLiquidity.selector,
                "Should only revert with ZeroLiquidity"
            );
        }
    }

    /// @notice Deploy pool with very low weight (weight=1) and surplus. The issuance tick will be
    ///         near MIN_TICK boundaries. Verifies the position has valid tick bounds.
    function test_fork_m46_lowWeight_validTickBounds() public {
        uint256 pid = _launchProject({reservedPercent: 0, cashOutTaxRate: 5000, weight: 1});

        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Low Weight Token", "LWT", bytes32(0));

        _payProject(pid, 50 ether);
        _accumulateTokens(pid, address(pToken), 100_000e18);

        // Deploy pool — exercises tick clamping with near-boundary ticks.
        vm.prank(multisig);
        hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);

        assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "Pool should deploy with low weight");

        uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Position should have liquidity");

        emit log_named_uint("  position liquidity", posLiq);
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
            jbDirectory, jbFundAccessLimits, jbPermissions, jbPrices, jbProjects,
            jbRulesets, jbSplits, jbTokens, address(0), trustedForwarder
        );

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);

        jbTerminalStore = new JBTerminalStore(jbDirectory, jbPrices, jbRulesets);

        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses, jbPermissions, jbProjects, jbSplits,
            jbTerminalStore, jbTokens, PERMIT2, trustedForwarder
        );

        vm.deal(address(this), 10_000 ether);
    }

    function _launchProject(uint16 reservedPercent, uint16 cashOutTaxRate, uint112 weight)
        internal
        returns (uint256 id)
    {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: reservedPercent, cashOutTaxRate: cashOutTaxRate,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false, pauseCreditTransfers: false, allowOwnerMinting: true,
            allowSetCustomToken: true, allowTerminalMigration: false, allowSetTerminals: false,
            allowSetController: false, allowAddAccountingContext: false, allowAddPriceFeed: false,
            ownerMustSendPayouts: false, holdFees: false, useTotalSurplusForCashOuts: false,
            useDataHookForPay: false, useDataHookForCashOut: false, dataHook: address(0), metadata: 0
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
            owner: multisig, projectUri: "", rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs, memo: ""
        });
    }

    function _accumulateTokens(uint256 pid, address tokenAddr, uint256 amount) internal {
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: amount, beneficiary: address(hook), memo: "", useReservedPercent: false
        });

        JBSplitHookContext memory context = JBSplitHookContext({
            token: tokenAddr, amount: amount, decimals: 18, projectId: pid, groupId: 1,
            split: JBSplit({
                percent: 1_000_000, projectId: 0, beneficiary: payable(address(0)),
                preferAddToBalance: false, lockedUntil: 0, hook: IJBSplitHook(address(hook))
            })
        });

        vm.prank(address(jbController));
        hook.processSplitWith(context);
    }

    function _payProject(uint256 pid, uint256 amount) internal {
        jbMultiTerminal.pay{value: amount}({
            projectId: pid, token: JBConstants.NATIVE_TOKEN, amount: amount,
            beneficiary: multisig, minReturnedTokens: 0, memo: "", metadata: ""
        });
    }
}
