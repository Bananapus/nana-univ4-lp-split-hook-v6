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

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

contract M45SwapHelper is IUnlockCallback {
    using CurrencyLibrary for Currency;
    IPoolManager public immutable poolManager;

    struct SwapCallbackData {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        address sender;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }
    receive() external payable {}

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external payable {
        poolManager.unlock(abi.encode(SwapCallbackData(key, zeroForOne, amountSpecified, msg.sender)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only pool manager");
        SwapCallbackData memory params = abi.decode(data, (SwapCallbackData));
        BalanceDelta delta = poolManager.swap(
            params.key,
            SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        if (delta0 < 0) {
            uint256 amountOwed = uint256(uint128(-delta0));
            if (params.key.currency0.isAddressZero()) {
                poolManager.settle{value: amountOwed}();
            } else {
                poolManager.sync(params.key.currency0);
                IERC20(Currency.unwrap(params.key.currency0))
                    .transferFrom(params.sender, address(poolManager), amountOwed);
                poolManager.settle();
            }
        } else if (delta0 > 0) {
            poolManager.take(params.key.currency0, params.sender, uint256(uint128(delta0)));
        }
        if (delta1 < 0) {
            uint256 amountOwed = uint256(uint128(-delta1));
            if (params.key.currency1.isAddressZero()) {
                poolManager.settle{value: amountOwed}();
            } else {
                poolManager.sync(params.key.currency1);
                IERC20(Currency.unwrap(params.key.currency1))
                    .transferFrom(params.sender, address(poolManager), amountOwed);
                poolManager.settle();
            }
        } else if (delta1 > 0) {
            poolManager.take(params.key.currency1, params.sender, uint256(uint128(delta1)));
        }
        return "";
    }
}

contract M45_PriceRatioFork is ForkDeployHelper {
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
        feeProjectId = _launchProject({cashOutTaxRate: 0, weight: 1_000_000e18});
        require(feeProjectId == 1, "fee project must be #1");
        vm.prank(multisig);
        jbController.deployERC20For(feeProjectId, "Fee Token", "FEE", bytes32(0));
        _payProject(feeProjectId, 10 ether);
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

    function test_fork_m45_balancedLP_swapsBothDirections() public {
        uint256 pid = _launchProject({cashOutTaxRate: 5000, weight: 1_000_000e18});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Balanced Token", "BAL", bytes32(0));
        _payProject(pid, 50 ether);
        _accumulateTokens(pid, address(pToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);
        uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Position should have liquidity");
        emit log_named_uint("  position liquidity", posLiq);
        PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
        M45SwapHelper swapHelper = new M45SwapHelper(V4_POOL_MANAGER);
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(pToken);
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: 10_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });
        IERC20(address(pToken)).approve(address(swapHelper), type(uint256).max);
        uint256 ethBefore = address(this).balance;
        swapHelper.swap(key, projIsToken0, -int256(5000e18));
        uint256 ethReceived = address(this).balance - ethBefore;
        assertTrue(ethReceived > 0, "Should receive ETH when selling project tokens");
        emit log_named_uint("  ETH received from selling 5k project tokens", ethReceived);
        uint256 projBefore = IERC20(address(pToken)).balanceOf(address(this));
        vm.deal(address(this), 1000 ether);
        swapHelper.swap{value: projIsToken0 ? 0 : 1 ether}(key, !projIsToken0, -int256(1 ether));
        uint256 projReceived = IERC20(address(pToken)).balanceOf(address(this)) - projBefore;
        assertTrue(projReceived > 0, "Should receive project tokens when buying with ETH");
        emit log_named_uint("  Project tokens received from 1 ETH", projReceived);
    }

    function test_fork_m45_highTaxRate_swapsBothDirections() public {
        uint256 pid = _launchProject({cashOutTaxRate: 9000, weight: 1_000_000e18});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "High Tax Token", "HTX", bytes32(0));
        _payProject(pid, 50 ether);
        _accumulateTokens(pid, address(pToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);
        uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Position should have liquidity with 90% tax rate");
        emit log_named_uint("  position liquidity (90% tax)", posLiq);
        PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
        M45SwapHelper swapHelper = new M45SwapHelper(V4_POOL_MANAGER);
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(pToken);
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: 10_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });
        IERC20(address(pToken)).approve(address(swapHelper), type(uint256).max);
        uint256 ethBefore = address(this).balance;
        swapHelper.swap(key, projIsToken0, -int256(5000e18));
        assertTrue(address(this).balance > ethBefore, "Should receive ETH (90% tax rate)");
        uint256 projBefore = IERC20(address(pToken)).balanceOf(address(this));
        vm.deal(address(this), 1000 ether);
        swapHelper.swap{value: projIsToken0 ? 0 : 1 ether}(key, !projIsToken0, -int256(1 ether));
        assertTrue(
            IERC20(address(pToken)).balanceOf(address(this)) > projBefore, "Should receive tokens (90% tax rate)"
        );
    }

    function test_fork_m45_lowTaxRate_swapsBothDirections() public {
        uint256 pid = _launchProject({cashOutTaxRate: 1000, weight: 1_000_000e18});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Low Tax Token", "LTX", bytes32(0));
        _payProject(pid, 50 ether);
        _accumulateTokens(pid, address(pToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);
        uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Position should have liquidity with 10% tax rate");
        emit log_named_uint("  position liquidity (10% tax)", posLiq);
        PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
        M45SwapHelper swapHelper = new M45SwapHelper(V4_POOL_MANAGER);
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(pToken);
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: 10_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });
        IERC20(address(pToken)).approve(address(swapHelper), type(uint256).max);
        uint256 ethBefore = address(this).balance;
        swapHelper.swap(key, projIsToken0, -int256(5000e18));
        assertTrue(address(this).balance > ethBefore, "Should receive ETH (10% tax rate)");
        uint256 projBefore = IERC20(address(pToken)).balanceOf(address(this));
        vm.deal(address(this), 1000 ether);
        swapHelper.swap{value: projIsToken0 ? 0 : 1 ether}(key, !projIsToken0, -int256(1 ether));
        assertTrue(
            IERC20(address(pToken)).balanceOf(address(this)) > projBefore, "Should receive tokens (10% tax rate)"
        );
    }

    function _launchProject(uint16 cashOutTaxRate, uint112 weight) internal returns (uint256 id) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 1000,
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
