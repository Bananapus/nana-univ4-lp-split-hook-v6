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
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

contract H30_ZeroRateFork is ForkDeployHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    JBUniswapV4LPSplitHook hook;
    uint256 feeProjectId;
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);
        require(address(V4_POOL_MANAGER).code.length > 0, "PoolManager not deployed");
        require(address(V4_POSITION_MANAGER).code.length > 0, "PositionManager not deployed");
        _deployJBCore();
        feeProjectId = _launchProject({reservedPercent: 0, cashOutTaxRate: 0, weight: 1_000_000e18});
        require(feeProjectId == 1, "fee project must be #1");
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

    function test_fork_h30_zeroIssuance_100pctReserved_ethTerminal() public {
        uint256 pid = _launchProject({reservedPercent: 10_000, cashOutTaxRate: 5000, weight: 1_000_000e18});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Reserved Token", "RSV", bytes32(0));
        _payProject(pid, 50 ether);
        _accumulateTokens(pid, address(pToken), 100_000e18);
        assertTrue(uint160(JBConstants.NATIVE_TOKEN) < uint160(address(pToken)), "ETH must be token0 (lower address)");
        vm.prank(multisig);
        hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);
        assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "Pool should deploy with 100% reserved");
        uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        assertTrue(tokenId != 0, "Position NFT should exist");
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Position should have liquidity");
        PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
        (uint160 sqrtPriceX96, int24 currentTick,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        assertTrue(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE, "sqrtPrice > MIN");
        assertTrue(sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "sqrtPrice < MAX");
        assertTrue(currentTick >= TickMath.MIN_TICK, "tick >= MIN_TICK");
        assertTrue(currentTick <= TickMath.MAX_TICK, "tick <= MAX_TICK");
        emit log_named_uint("  position liquidity", posLiq);
        emit log_named_int("  current tick", currentTick);
        emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
    }

    function test_fork_h30_zeroIssuance_weightZero_ethTerminal() public {
        uint256 pid = _launchProject({reservedPercent: 1000, cashOutTaxRate: 0, weight: 0});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Zero Weight Token", "ZWT", bytes32(0));
        _payProject(pid, 50 ether);
        _accumulateTokens(pid, address(pToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);
        assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "Pool should deploy with weight=0");
        uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Position should have liquidity with weight=0");
        PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
        (uint160 sqrtPriceX96, int24 currentTick,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        assertTrue(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE, "sqrtPrice > MIN");
        assertTrue(sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "sqrtPrice < MAX");
        emit log_named_uint("  position liquidity", posLiq);
        emit log_named_int("  current tick", currentTick);
        emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
    }

    function test_fork_h30_zeroCashOut_zeroIssuance_revertsZeroLiquidity() public {
        uint256 pid = _launchProject({reservedPercent: 10_000, cashOutTaxRate: 5000, weight: 1_000_000e18});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Full Range Token", "FRT", bytes32(0));
        _accumulateTokens(pid, address(pToken), 100_000e18);
        assertTrue(uint160(JBConstants.NATIVE_TOKEN) < uint160(address(pToken)), "ETH must be token0 (lower address)");
        vm.prank(multisig);
        try hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0) {
            revert("Expected ZeroLiquidity revert");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ZeroLiquidity.selector);
        }
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
