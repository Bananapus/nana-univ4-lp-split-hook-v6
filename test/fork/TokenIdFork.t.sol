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
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
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
    using PositionInfoLibrary for PositionInfo;
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
        // The hook stores the ask it just minted.
        uint256 storedTokenId = hook.askTokenIdOf({projectId: projectId, terminalToken: JBConstants.NATIVE_TOKEN});
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

    /// @notice A real buy (leaving ETH in the ask) and a real ruleset weight change, then more reserved tokens and a
    /// permissionless `addLiquidity` recycle: both stored ids must point at the freshly minted positions. ETH is
    /// currency0, so the bid (token0) mints first and the ask (token1) second.
    function test_fork_h31_tokenId_updatesAfterRecycle() public {
        // Seed the hook with inventory and deploy the pool with its first ask.
        _accumulateTokens({pid: projectId, tokenAddr: address(projectToken), amount: 100_000e18});
        vm.prank(multisig);
        hook.deployPool(projectId);

        // Record the first ask and the pool key the swaps trade against.
        uint256 oldTokenId = hook.askTokenIdOf({projectId: projectId, terminalToken: JBConstants.NATIVE_TOKEN});
        uint128 oldLiq = V4_POSITION_MANAGER.getPositionLiquidity(oldTokenId);
        PoolKey memory key = hook.poolKeyOf({projectId: projectId, terminalToken: JBConstants.NATIVE_TOKEN});

        // Fund a swap helper with project tokens and approve it to trade them.
        TokenIdSwapHelper swapHelper = new TokenIdSwapHelper(V4_POOL_MANAGER);
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId, tokenCount: 50_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });
        IERC20(address(projectToken)).approve(address(swapHelper), type(uint256).max);

        // The swap direction depends on which side of the pair the project token sorts to.
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(projectToken);

        // A real buy (give ETH, receive project token) pushes spot into the single-sided ask band, sized off the
        // seed position's own tick bounds so it lands inside the band instead of rocketing to the tick-space
        // extreme (there is no interposing liquidity beyond this single position).
        (, PositionInfo seedInfo) = V4_POSITION_MANAGER.getPoolAndPositionInfo(oldTokenId);
        int24 seedTickLower = seedInfo.tickLower();
        int24 seedTickUpper = seedInfo.tickUpper();
        uint256 costToFullyCrossAsk = SqrtPriceMath.getAmount0Delta({
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(seedTickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(seedTickUpper),
            liquidity: oldLiq,
            roundUp: true
        });
        uint256 buyAmountIn = (costToFullyCrossAsk * 90) / 100;
        vm.deal(address(this), buyAmountIn + 1 ether);
        swapHelper.swap{value: projIsToken0 ? 0 : buyAmountIn}({
            key: key, zeroForOne: !projIsToken0, amountSpecified: -int256(buyAmountIn)
        });

        // More reserved tokens arrive, so the recycle has fresh inventory for the ask.
        _accumulateTokens({pid: projectId, tokenAddr: address(projectToken), amount: 50_000e18});

        // Move the economic corridor with a real ruleset weight change (a genuine rate change, not incidental
        // trading).
        _queueHalvedWeightRuleset({pid: projectId, cashOutTaxRate: 5000});

        // Snapshot the next id so the recycle's mints can be located exactly.
        uint256 nextTokenIdBeforeRecycle = V4_POSITION_MANAGER.nextTokenId();

        // Pin the TWAP to the spot so the hook's spot-vs-TWAP guard passes.
        _mockOracleTwapEqualsSpot({
            oracle: hook.oracleHook(),
            pm: V4_POOL_MANAGER,
            key: hook.poolKeyOf({projectId: projectId, terminalToken: JBConstants.NATIVE_TOKEN})
        });

        // Permissionless: any non-owner stranger may recycle.
        vm.prank(address(0xB0BB1E));
        hook.addLiquidity({projectId: projectId, terminalToken: JBConstants.NATIVE_TOKEN});

        // Read both stored ids and the PositionManager's counter after the recycle.
        uint256 newTokenId = hook.askTokenIdOf({projectId: projectId, terminalToken: JBConstants.NATIVE_TOKEN});
        uint256 bidTokenId = hook.bidTokenIdOf({projectId: projectId, terminalToken: JBConstants.NATIVE_TOKEN});
        uint256 nextTokenIdAfterRecycle = V4_POSITION_MANAGER.nextTokenId();

        // The recycle minted the bid then the ask as two consecutive fresh ids.
        assertTrue(newTokenId != oldTokenId, "Ask token ID should change after recycle");
        assertEq(bidTokenId, nextTokenIdBeforeRecycle, "Bid (token0) should be the first id minted by the recycle");
        assertEq(newTokenId, nextTokenIdBeforeRecycle + 1, "Ask (token1) should be the second id minted");
        assertEq(nextTokenIdAfterRecycle, nextTokenIdBeforeRecycle + 2, "Recycle should mint exactly two positions");

        // The old ask is empty and both fresh positions hold liquidity.
        assertEq(V4_POSITION_MANAGER.getPositionLiquidity(oldTokenId), 0, "Old ask should be burned");
        uint128 newLiq = V4_POSITION_MANAGER.getPositionLiquidity(newTokenId);
        assertTrue(newLiq > 0, "New ask should have liquidity after recycle");
        assertTrue(V4_POSITION_MANAGER.getPositionLiquidity(bidTokenId) > 0, "Bid should have liquidity");

        // Log the ids and liquidity for inspection.
        emit log_named_uint("  old tokenId", oldTokenId);
        emit log_named_uint("  new tokenId", newTokenId);
        emit log_named_uint("  new position liquidity", newLiq);
    }

    /// @notice Queue a real ruleset with a halved weight, effective immediately (the base ruleset's `duration` is
    /// 0, so `JBRulesets.deriveStartFrom` starts the next cycle at `mustStartAtOrAfter` == `block.timestamp`). Used
    /// to genuinely shift the project's issuance/cash-out corridor.
    /// @param pid The ID of the project to queue the ruleset for.
    /// @param cashOutTaxRate The cash-out tax rate for the queued ruleset.
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
