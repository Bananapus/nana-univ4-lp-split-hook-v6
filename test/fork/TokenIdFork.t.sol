// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkDeployHelper} from "../helpers/ForkDeployHelper.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";

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
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

contract TokenIdSwapHelper is IUnlockCallback {
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

    function _amountOwedToPool(int128 delta) private pure returns (uint256 amount) {
        // Negative BalanceDelta values mean the swapper owes tokens to the pool.
        // forge-lint: disable-next-line(unsafe-typecast)
        amount = uint256(uint128(-delta));
    }

    function _amountOwedToSender(int128 delta) private pure returns (uint256 amount) {
        // Positive BalanceDelta values mean the pool owes tokens to the swapper.
        // forge-lint: disable-next-line(unsafe-typecast)
        amount = uint256(uint128(delta));
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
            uint256 amountOwed = _amountOwedToPool(delta0);
            if (params.key.currency0.isAddressZero()) {
                poolManager.settle{value: amountOwed}();
            } else {
                poolManager.sync(params.key.currency0);
                require(
                    IERC20(Currency.unwrap(params.key.currency0))
                        .transferFrom(params.sender, address(poolManager), amountOwed),
                    "TRANSFER_FROM_FAILED"
                );
                poolManager.settle();
            }
        } else if (delta0 > 0) {
            poolManager.take(params.key.currency0, params.sender, _amountOwedToSender(delta0));
        }
        if (delta1 < 0) {
            uint256 amountOwed = _amountOwedToPool(delta1);
            if (params.key.currency1.isAddressZero()) {
                poolManager.settle{value: amountOwed}();
            } else {
                poolManager.sync(params.key.currency1);
                require(
                    IERC20(Currency.unwrap(params.key.currency1))
                        .transferFrom(params.sender, address(poolManager), amountOwed),
                    "TRANSFER_FROM_FAILED"
                );
                poolManager.settle();
            }
        } else if (delta1 > 0) {
            poolManager.take(params.key.currency1, params.sender, _amountOwedToSender(delta1));
        }
        return "";
    }
}

contract TokenIdFork is ForkDeployHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    JBUniswapV4LPSplitHook hook;
    uint256 feeProjectId;
    uint256 projectId;
    IJBToken projectToken;
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
        projectId = _launchProject({cashOutTaxRate: 5000, weight: 1_000_000e18});
        vm.prank(multisig);
        projectToken = jbController.deployERC20For(projectId, "Test Token", "TST", bytes32(0));
        _payProject(feeProjectId, 10 ether);
        _payProject(projectId, 50 ether);
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

    function test_fork_h31_tokenId_matchesAfterDeploy() public {
        _accumulateTokens(projectId, address(projectToken), 100_000e18);
        uint256 nextTokenIdBefore = V4_POSITION_MANAGER.nextTokenId();
        emit log_named_uint("  nextTokenId before deploy", nextTokenIdBefore);
        vm.prank(multisig);
        hook.deployPool(projectId);
        uint256 storedTokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        uint256 nextTokenIdAfter = V4_POSITION_MANAGER.nextTokenId();
        assertEq(storedTokenId, nextTokenIdBefore, "tokenIdOf should equal pre-mint nextTokenId");
        assertEq(storedTokenId, nextTokenIdAfter - 1, "tokenIdOf should equal post-mint nextTokenId - 1");
        assertEq(nextTokenIdAfter, nextTokenIdBefore + 1, "nextTokenId should increment by exactly 1");
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(storedTokenId);
        assertTrue(posLiq > 0, "Position at stored tokenId should have liquidity");
        emit log_named_uint("  storedTokenId", storedTokenId);
        emit log_named_uint("  nextTokenId after deploy", nextTokenIdAfter);
        emit log_named_uint("  position liquidity", posLiq);
    }

    /// @notice `rebalanceLiquidity`'s drift guard is gated on CORRIDOR movement (a genuine issuance-rate change),
    /// not on raw trading activity — a swap alone leaves the corridor untouched. A real buy is still exercised first
    /// (proving the tokenId bookkeeping this test targets survives organic trading), then a real ruleset weight
    /// change genuinely shifts the corridor so the rebalance clears the guard.
    function test_fork_h31_tokenId_updatesAfterRebalance() public {
        _accumulateTokens(projectId, address(projectToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(projectId);
        uint256 oldTokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        uint128 oldLiq = V4_POSITION_MANAGER.getPositionLiquidity(oldTokenId);
        PoolKey memory key = hook.poolKeyOf(projectId, JBConstants.NATIVE_TOKEN);
        TokenIdSwapHelper swapHelper = new TokenIdSwapHelper(V4_POOL_MANAGER);
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId, tokenCount: 50_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });
        IERC20(address(projectToken)).approve(address(swapHelper), type(uint256).max);
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(projectToken);
        // A real buy (give ETH, receive project token) pushes spot into the single-sided ask band, sized off the
        // seed position's own tick bounds so it lands inside the band instead of rocketing to the tick-space
        // extreme (there is no interposing liquidity beyond this single position).
        int24 seedTickLower = hook.activeTickLowerOf(projectId, JBConstants.NATIVE_TOKEN);
        int24 seedTickUpper = hook.activeTickUpperOf(projectId, JBConstants.NATIVE_TOKEN);
        uint256 costToFullyCrossAsk = SqrtPriceMath.getAmount0Delta({
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(seedTickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(seedTickUpper),
            liquidity: oldLiq,
            roundUp: true
        });
        uint256 buyAmountIn = (costToFullyCrossAsk * 90) / 100;
        vm.deal(address(this), buyAmountIn + 1 ether);
        swapHelper.swap{value: projIsToken0 ? 0 : buyAmountIn}(key, !projIsToken0, -int256(buyAmountIn));
        _accumulateTokens(projectId, address(projectToken), 50_000e18);

        // Move the economic corridor with a real ruleset weight change (a genuine rate change, not incidental
        // trading).
        _queueHalvedWeightRuleset(projectId, 5000);

        uint256 nextTokenIdBeforeRebalance = V4_POSITION_MANAGER.nextTokenId();
        _mockOracleTwapEqualsSpot(
            hook.oracleHook(), V4_POOL_MANAGER, hook.poolKeyOf(projectId, JBConstants.NATIVE_TOKEN)
        );
        // Permissionless: any non-owner stranger may rebalance once the corridor has genuinely drifted.
        vm.prank(address(0xB0BB1E));
        hook.rebalanceLiquidity({projectId: projectId, terminalToken: JBConstants.NATIVE_TOKEN});
        uint256 newTokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        uint256 nextTokenIdAfterRebalance = V4_POSITION_MANAGER.nextTokenId();
        assertTrue(newTokenId != oldTokenId, "Token ID should change after rebalance");
        assertEq(newTokenId, nextTokenIdBeforeRebalance, "New tokenId should equal pre-rebalance nextTokenId");
        assertEq(newTokenId, nextTokenIdAfterRebalance - 1, "New tokenId should equal post-rebalance nextTokenId - 1");
        uint128 newLiq = V4_POSITION_MANAGER.getPositionLiquidity(newTokenId);
        assertTrue(newLiq > 0, "New position should have liquidity after rebalance");
        emit log_named_uint("  old tokenId", oldTokenId);
        emit log_named_uint("  new tokenId", newTokenId);
        emit log_named_uint("  new position liquidity", newLiq);
    }

    /// @notice Queue a real ruleset with a halved weight, effective immediately (the base ruleset's `duration` is
    /// 0, so `JBRulesets.deriveStartFrom` starts the next cycle at `mustStartAtOrAfter` == `block.timestamp`). Used
    /// to genuinely shift the project's issuance/cash-out corridor so `rebalanceLiquidity`'s drift guard clears.
    function _queueHalvedWeightRuleset(uint256 pid, uint16 cashOutTaxRate) internal {
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
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0].mustStartAtOrAfter = 0;
        configs[0].duration = 0;
        configs[0].weight = 500_000e18;
        configs[0].weightCutPercent = 0;
        configs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        configs[0].metadata = metadata;
        configs[0].splitGroups = new JBSplitGroup[](0);
        configs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);
        vm.prank(multisig);
        jbController.queueRulesetsOf({projectId: pid, rulesetConfigurations: configs, memo: ""});
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
            scopeCashOutsToLocalBalances: true,
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
