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

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract GeomeanSwapHelper is IUnlockCallback {
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
            uint256 amountOwedToUs = _amountOwedToSender(delta0);
            poolManager.take(params.key.currency0, params.sender, amountOwedToUs);
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
            uint256 amountOwedToUs = _amountOwedToSender(delta1);
            poolManager.take(params.key.currency1, params.sender, amountOwedToUs);
        }
        return "";
    }
}

contract GeomeanLPForkTest is ForkDeployHelper {
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
        feeProjectId = _launchProject(false, 0);
        require(feeProjectId == 1, "fee project must be #1");
        projectId = _launchProject(true, 0);
        vm.prank(multisig);
        projectToken = jbController.deployERC20For(projectId, "Test Token", "TST", bytes32(0));
        jbMultiTerminal.pay{value: 50 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 50 ether,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
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
            newOracleHook: IHooks(address(0))
        });
    }

    function test_fork_ethPool_varyingAccumulation() public {
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1000e18;
        amounts[1] = 10_000e18;
        amounts[2] = 100_000e18;
        amounts[3] = 1_000_000e18;
        for (uint256 i; i < amounts.length; i++) {
            uint256 pid = _launchProject(true, 0);
            vm.prank(multisig);
            IJBToken pToken = jbController.deployERC20For(pid, "Iter Token", "ITR", bytes32(0));
            jbMultiTerminal.pay{value: 20 ether}({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 20 ether,
                beneficiary: multisig,
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            });
            _accumulateTokens(pid, address(pToken), amounts[i]);
            assertEq(
                hook.accumulatedProjectTokens(pid),
                amounts[i],
                string.concat("accumulated mismatch at index ", vm.toString(i))
            );
            vm.prank(multisig);
            hook.deployPool(pid, 0);
            assertTrue(
                hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN),
                string.concat("pool not deployed at index ", vm.toString(i))
            );
            uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
            assertTrue(tokenId != 0, string.concat("no position NFT at index ", vm.toString(i)));
            uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
            assertTrue(posLiq > 0, string.concat("zero liquidity at index ", vm.toString(i)));
            assertEq(
                hook.accumulatedProjectTokens(pid),
                0,
                string.concat("accumulated not cleared at index ", vm.toString(i))
            );
            PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,,,) = V4_POOL_MANAGER.getSlot0(poolId);
            emit log_named_uint("  accumulation amount", amounts[i]);
            emit log_named_uint("  position liquidity", posLiq);
            emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
        }
    }

    function test_fork_ethPool_varyingPaymentSizes() public {
        uint256[] memory ethAmounts = new uint256[](4);
        ethAmounts[0] = 0.1 ether;
        ethAmounts[1] = 1 ether;
        ethAmounts[2] = 10 ether;
        ethAmounts[3] = 100 ether;
        for (uint256 i; i < ethAmounts.length; i++) {
            uint256 pid = _launchProject(true, 0);
            vm.prank(multisig);
            IJBToken pToken = jbController.deployERC20For(pid, "Pay Token", "PAY", bytes32(0));
            _payProject(pid, ethAmounts[i]);
            _accumulateTokens(pid, address(pToken), 50_000e18);
            vm.prank(multisig);
            hook.deployPool(pid, 0);
            assertTrue(
                hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN),
                string.concat("pool not deployed for ETH amount ", vm.toString(ethAmounts[i]))
            );
            PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,,,) = V4_POOL_MANAGER.getSlot0(poolId);
            assertTrue(sqrtPriceX96 > 0, "pool should have nonzero price");
            uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
            uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
            assertTrue(posLiq > 0, "position should have liquidity");
            emit log_named_uint("  ETH paid", ethAmounts[i]);
            emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
            emit log_named_uint("  position liquidity", posLiq);
        }
    }

    function test_fork_ethPool_rebalanceAfterPriceMovement() public {
        _accumulateTokens(projectId, address(projectToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(projectId, 0);
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "pool should be deployed");
        uint256 originalTokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        uint128 originalLiq = V4_POSITION_MANAGER.getPositionLiquidity(originalTokenId);
        assertTrue(originalLiq > 0, "original position should have liquidity");
        PoolKey memory key = hook.poolKeyOf(projectId, JBConstants.NATIVE_TOKEN);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceBefore,,,) = V4_POOL_MANAGER.getSlot0(poolId);
        GeomeanSwapHelper swapHelper = new GeomeanSwapHelper(V4_POOL_MANAGER);
        address projTokenAddr = address(projectToken);
        bool projIsToken0 = Currency.unwrap(key.currency0) == projTokenAddr;
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId, tokenCount: 10_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });
        IERC20(projTokenAddr).approve(address(swapHelper), type(uint256).max);
        bool zeroForOne = projIsToken0;
        swapHelper.swap{value: projIsToken0 ? 0 : 0}(key, zeroForOne, -int256(5000e18));
        (uint160 sqrtPriceAfterSwap,,,) = V4_POOL_MANAGER.getSlot0(poolId);
        assertTrue(sqrtPriceAfterSwap != sqrtPriceBefore, "swap should have moved the price");
        vm.prank(multisig);
        hook.rebalanceLiquidity(projectId, JBConstants.NATIVE_TOKEN, 0, 0);
        uint256 newTokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        assertTrue(newTokenId != 0, "new position should exist after rebalance");
        assertTrue(newTokenId != originalTokenId, "tokenId should change after rebalance");
        uint128 newLiq = V4_POSITION_MANAGER.getPositionLiquidity(newTokenId);
        assertTrue(newLiq > 0, "rebalanced position should have liquidity");
        emit log_named_uint("  sqrtPrice before swap", sqrtPriceBefore);
        emit log_named_uint("  sqrtPrice after swap", sqrtPriceAfterSwap);
        emit log_named_uint("  original liquidity", originalLiq);
        emit log_named_uint("  rebalanced liquidity", newLiq);
    }

    function test_fork_usdcPool_deployAndVerify() public {
        uint256[] memory usdcAmounts = new uint256[](3);
        usdcAmounts[0] = 1000e6;
        usdcAmounts[1] = 10_000e6;
        usdcAmounts[2] = 100_000e6;
        for (uint256 i; i < usdcAmounts.length; i++) {
            MockUSDC usdc = new MockUSDC();
            uint256 pid = _launchProjectWithUSDC(usdc);
            vm.prank(multisig);
            IJBToken pToken = jbController.deployERC20For(pid, "USDC Token", "UPT", bytes32(0));
            _payProjectUSDC(pid, usdc, usdcAmounts[i]);
            _accumulateTokens(pid, address(pToken), 50_000e18);
            vm.prank(multisig);
            hook.deployPool(pid, 0);
            assertTrue(
                hook.isPoolDeployed(pid, address(usdc)),
                string.concat("USDC pool not deployed at index ", vm.toString(i))
            );
            uint256 tokenId = hook.tokenIdOf(pid, address(usdc));
            assertTrue(tokenId != 0, string.concat("no USDC position NFT at index ", vm.toString(i)));
            uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
            assertTrue(posLiq > 0, string.concat("zero USDC liquidity at index ", vm.toString(i)));
            assertEq(
                hook.accumulatedProjectTokens(pid),
                0,
                string.concat("USDC accumulated not cleared at index ", vm.toString(i))
            );
            emit log_named_uint("  USDC amount", usdcAmounts[i]);
            emit log_named_uint("  position liquidity", posLiq);
        }
    }

    function test_fork_usdcPool_varyingLiquidity() public {
        uint256[] memory usdcAmounts = new uint256[](3);
        usdcAmounts[0] = 1000e6;
        usdcAmounts[1] = 10_000e6;
        usdcAmounts[2] = 100_000e6;
        uint128[] memory liquidities = new uint128[](3);
        for (uint256 i; i < usdcAmounts.length; i++) {
            MockUSDC usdc = new MockUSDC();
            uint256 pid = _launchProjectWithUSDC(usdc);
            vm.prank(multisig);
            IJBToken pToken = jbController.deployERC20For(pid, "VL Token", "VLT", bytes32(0));
            _payProjectUSDC(pid, usdc, usdcAmounts[i]);
            uint256 tokenAmount = (usdcAmounts[i] * 5000e18) / 1000e6;
            _accumulateTokens(pid, address(pToken), tokenAmount);
            vm.prank(multisig);
            hook.deployPool(pid, 0);
            uint256 tokenId = hook.tokenIdOf(pid, address(usdc));
            assertTrue(tokenId != 0, "position should exist");
            liquidities[i] = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
            assertTrue(liquidities[i] > 0, "position should have liquidity");
            emit log_named_uint("  USDC amount", usdcAmounts[i]);
            emit log_named_uint("  token accumulation", tokenAmount);
            emit log_named_uint("  position liquidity", liquidities[i]);
        }
        assertTrue(liquidities[1] > liquidities[0] * 2, "10x USDC should yield at least 2x liquidity vs 1x");
        assertTrue(liquidities[2] > liquidities[1] * 2, "100x USDC should yield at least 2x liquidity vs 10x");
    }

    function test_fork_poolDeployment_tickBounds() public {
        uint112[] memory weights = new uint112[](3);
        weights[0] = 500_000e18;
        weights[1] = 1_000_000e18;
        weights[2] = 5_000_000e18;
        uint16[] memory cashOutTaxRates = new uint16[](3);
        cashOutTaxRates[0] = 0;
        cashOutTaxRates[1] = 2500;
        cashOutTaxRates[2] = 5000;
        for (uint256 i; i < weights.length; i++) {
            uint256 pid = _launchProjectWithConfig(weights[i], cashOutTaxRates[i]);
            vm.prank(multisig);
            IJBToken pToken = jbController.deployERC20For(pid, "TB Token", "TBT", bytes32(0));
            _payProject(pid, 10 ether);
            _accumulateTokens(pid, address(pToken), 100_000e18);
            vm.prank(multisig);
            hook.deployPool(pid, 0);
            assertTrue(
                hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN),
                string.concat("pool not deployed at config ", vm.toString(i))
            );
            PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96, int24 currentTick,,) = V4_POOL_MANAGER.getSlot0(poolId);
            assertTrue(sqrtPriceX96 > 0, "pool should be initialized");
            assertTrue(currentTick >= TickMath.MIN_TICK, "tick below MIN_TICK");
            assertTrue(currentTick <= TickMath.MAX_TICK, "tick above MAX_TICK");
            uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
            uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
            assertTrue(posLiq > 0, "position should have liquidity");
            emit log_named_uint("  weight", weights[i]);
            emit log_named_uint("  cashOutTaxRate", cashOutTaxRates[i]);
            emit log_named_int("  currentTick", currentTick);
            emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
            emit log_named_uint("  position liquidity", posLiq);
        }
    }

    function _launchProject(bool withOwnerMinting, uint16 cashOutTaxRate) internal returns (uint256 id) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: withOwnerMinting ? 1000 : 0,
            cashOutTaxRate: cashOutTaxRate,
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
            scopeCashOutsToLocalBalances: true,
            pauseCrossProjectFeeFreeInflows: false,
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

    function _launchProjectWithConfig(uint112 weight, uint16 cashOutTaxRate) internal returns (uint256 id) {
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
            pauseCrossProjectFeeFreeInflows: false,
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

    function _launchProjectWithUSDC(MockUSDC usdc) internal returns (uint256 id) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 1000,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(usdc))),
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
            pauseCrossProjectFeeFreeInflows: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 1000e18;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] =
            JBAccountingContext({token: address(usdc), decimals: 6, currency: uint32(uint160(address(usdc)))});
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

    function _payProjectUSDC(uint256 pid, MockUSDC usdc, uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(PERMIT2), type(uint256).max);
        require(amount <= type(uint160).max, "PERMIT_AMOUNT_TOO_LARGE");
        // Permit2 allowance amounts are uint160; this fork helper only pays bounded mock USDC amounts.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 permitAmount = uint160(amount);
        IPermit2(address(PERMIT2))
            .approve(address(usdc), address(jbMultiTerminal), permitAmount, uint48(block.timestamp + 3600));
        jbMultiTerminal.pay({
            projectId: pid,
            token: address(usdc),
            amount: amount,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }
}
