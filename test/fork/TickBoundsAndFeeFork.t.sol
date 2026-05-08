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

contract SwapHelper is IUnlockCallback {
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

contract TickBoundsAndFeeForkTest is ForkDeployHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    JBUniswapV4LPSplitHook hook;
    uint256 feeProjectId;
    uint256 projectId;
    IJBToken projectToken;
    IJBToken feeProjectToken;
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);
        require(address(V4_POOL_MANAGER).code.length > 0, "PoolManager not deployed");
        require(address(V4_POSITION_MANAGER).code.length > 0, "PositionManager not deployed");
        _deployJBCore();
        feeProjectId = _launchProject({withOwnerMinting: true, cashOutTaxRate: 0, weight: 1_000_000e18});
        require(feeProjectId == 1, "fee project must be #1");
        vm.prank(multisig);
        feeProjectToken = jbController.deployERC20For(feeProjectId, "Fee Token", "FEE", bytes32(0));
        projectId = _launchProject({withOwnerMinting: true, cashOutTaxRate: 5000, weight: 1_000_000e18});
        vm.prank(multisig);
        projectToken = jbController.deployERC20For(projectId, "Test Token", "TST", bytes32(0));
        jbMultiTerminal.pay{value: 10 ether}({
            projectId: feeProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
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
            V4_POOL_MANAGER,
            V4_POSITION_MANAGER,
            IAllowanceTransfer(address(PERMIT2)),
            IHooks(address(0))
        );
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));
        hook.initialize(feeProjectId, 3800);
    }

    function test_fork_ethPool_tickBoundsCorrect_whenTerminalIsToken0() public {
        assertTrue(
            uint160(JBConstants.NATIVE_TOKEN) < uint160(address(projectToken)),
            "Native ETH should be token0 (lower address than project token)"
        );
        _accumulateTokens(projectId, address(projectToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(projectId, 0);
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "Pool should be deployed");
        uint256 tokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        assertTrue(tokenId != 0, "Position NFT should exist");
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Position should have liquidity");
        PoolKey memory key = hook.poolKeyOf(projectId, JBConstants.NATIVE_TOKEN);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = V4_POOL_MANAGER.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "Pool should have nonzero price");
        assertTrue(currentTick >= TickMath.MIN_TICK, "Tick should be >= MIN_TICK");
        assertTrue(currentTick <= TickMath.MAX_TICK, "Tick should be <= MAX_TICK");
        emit log_named_uint("  position liquidity", posLiq);
        emit log_named_int("  current tick", currentTick);
        emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
    }

    function test_fork_ethPool_tickBoundsCorrect_varyingCashOutTaxRates() public {
        uint16[] memory taxRates = new uint16[](4);
        taxRates[0] = 0;
        taxRates[1] = 2500;
        taxRates[2] = 5000;
        taxRates[3] = 9000;
        for (uint256 i; i < taxRates.length; i++) {
            uint256 pid = _launchProject({withOwnerMinting: true, cashOutTaxRate: taxRates[i], weight: 1_000_000e18});
            vm.prank(multisig);
            IJBToken pToken = jbController.deployERC20For(pid, "Rate Token", "RTK", bytes32(0));
            _payProject(pid, 20 ether);
            _accumulateTokens(pid, address(pToken), 100_000e18);
            vm.prank(multisig);
            hook.deployPool(pid, 0);
            assertTrue(
                hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN),
                string.concat("Pool not deployed for taxRate ", vm.toString(uint256(taxRates[i])))
            );
            uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
            uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
            assertTrue(posLiq > 0, string.concat("Zero liquidity for taxRate ", vm.toString(uint256(taxRates[i]))));
            PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96, int24 tick,,) = V4_POOL_MANAGER.getSlot0(poolId);
            assertTrue(sqrtPriceX96 > 0, "Pool should have nonzero price");
            emit log_named_uint("  cashOutTaxRate", taxRates[i]);
            emit log_named_uint("  position liquidity", posLiq);
            emit log_named_int("  current tick", tick);
        }
    }

    function test_fork_feeRouting_collectAndClaim() public {
        _accumulateTokens(projectId, address(projectToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(projectId, 0);
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "Pool should be deployed");
        PoolKey memory key = hook.poolKeyOf(projectId, JBConstants.NATIVE_TOKEN);
        SwapHelper swapHelper = new SwapHelper(V4_POOL_MANAGER);
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId, tokenCount: 50_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });
        IERC20(address(projectToken)).approve(address(swapHelper), type(uint256).max);
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(projectToken);
        swapHelper.swap{value: projIsToken0 ? 0 : 0}(key, projIsToken0, -int256(10_000e18));
        vm.deal(address(this), 1000 ether);
        swapHelper.swap{value: projIsToken0 ? 0 : 1 ether}(key, !projIsToken0, -int256(1 ether));
        swapHelper.swap(key, projIsToken0, -int256(5000e18));
        uint256 feeProjectBalanceBefore =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), feeProjectId, JBConstants.NATIVE_TOKEN);
        uint256 claimableBefore = hook.claimableFeeTokens(projectId);
        assertEq(claimableBefore, 0, "No claimable tokens before fee collection");
        hook.collectAndRouteLPFees(projectId, JBConstants.NATIVE_TOKEN);
        uint256 feeProjectBalanceAfter =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), feeProjectId, JBConstants.NATIVE_TOKEN);
        assertTrue(
            feeProjectBalanceAfter > feeProjectBalanceBefore, "Fee project balance should increase after fee routing"
        );
        uint256 claimableAfter = hook.claimableFeeTokens(projectId);
        assertTrue(claimableAfter > 0, "Claimable fee tokens should be > 0 after fee collection");
        emit log_named_uint("  fee project balance increase", feeProjectBalanceAfter - feeProjectBalanceBefore);
        emit log_named_uint("  claimable fee tokens", claimableAfter);
        address beneficiary = makeAddr("feeBeneficiary");
        uint256 beneficiaryBalanceBefore = IERC20(address(feeProjectToken)).balanceOf(beneficiary);
        vm.prank(multisig);
        hook.claimFeeTokensFor(projectId, beneficiary);
        uint256 beneficiaryBalanceAfter = IERC20(address(feeProjectToken)).balanceOf(beneficiary);
        assertTrue(
            beneficiaryBalanceAfter > beneficiaryBalanceBefore,
            "Beneficiary should receive fee project tokens after claiming"
        );
        assertEq(
            beneficiaryBalanceAfter - beneficiaryBalanceBefore,
            claimableAfter,
            "Beneficiary should receive exactly the claimable amount"
        );
        assertEq(hook.claimableFeeTokens(projectId), 0, "Claimable tokens should be 0 after claiming");
        emit log_named_uint("  beneficiary received", beneficiaryBalanceAfter - beneficiaryBalanceBefore);
    }

    function test_fork_feeRouting_multipleCollectionsThenClaim() public {
        _accumulateTokens(projectId, address(projectToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(projectId, 0);
        PoolKey memory key = hook.poolKeyOf(projectId, JBConstants.NATIVE_TOKEN);
        SwapHelper swapHelper = new SwapHelper(V4_POOL_MANAGER);
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId,
            tokenCount: 100_000e18,
            beneficiary: address(this),
            memo: "",
            useReservedPercent: false
        });
        IERC20(address(projectToken)).approve(address(swapHelper), type(uint256).max);
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(projectToken);
        swapHelper.swap(key, projIsToken0, -int256(10_000e18));
        vm.deal(address(this), 1000 ether);
        swapHelper.swap{value: projIsToken0 ? 0 : 1 ether}(key, !projIsToken0, -int256(1 ether));
        hook.collectAndRouteLPFees(projectId, JBConstants.NATIVE_TOKEN);
        uint256 claimableAfterFirst = hook.claimableFeeTokens(projectId);
        swapHelper.swap(key, projIsToken0, -int256(5000e18));
        swapHelper.swap{value: projIsToken0 ? 0 : 0.5 ether}(key, !projIsToken0, -int256(0.5 ether));
        hook.collectAndRouteLPFees(projectId, JBConstants.NATIVE_TOKEN);
        uint256 claimableAfterSecond = hook.claimableFeeTokens(projectId);
        assertTrue(
            claimableAfterSecond > claimableAfterFirst, "Claimable should accumulate across multiple collections"
        );
        address beneficiary = makeAddr("multiClaimBeneficiary");
        vm.prank(multisig);
        hook.claimFeeTokensFor(projectId, beneficiary);
        uint256 received = IERC20(address(feeProjectToken)).balanceOf(beneficiary);
        assertEq(received, claimableAfterSecond, "Should receive total accumulated amount");
        assertEq(hook.claimableFeeTokens(projectId), 0, "Claimable should be 0 after full claim");
        emit log_named_uint("  claimable after first collection", claimableAfterFirst);
        emit log_named_uint("  claimable after second collection", claimableAfterSecond);
        emit log_named_uint("  total claimed", received);
    }

    function test_fork_ethPool_swapBothDirections() public {
        _accumulateTokens(projectId, address(projectToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(projectId, 0);
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "Pool should be deployed");
        PoolKey memory key = hook.poolKeyOf(projectId, JBConstants.NATIVE_TOKEN);
        SwapHelper swapHelper = new SwapHelper(V4_POOL_MANAGER);
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId, tokenCount: 50_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });
        IERC20(address(projectToken)).approve(address(swapHelper), type(uint256).max);
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(projectToken);
        uint256 ethBefore = address(this).balance;
        uint256 projBefore = IERC20(address(projectToken)).balanceOf(address(this));
        swapHelper.swap(key, projIsToken0, -int256(10_000e18));
        uint256 ethAfter = address(this).balance;
        uint256 projAfter = IERC20(address(projectToken)).balanceOf(address(this));
        assertTrue(projAfter < projBefore, "Should have spent project tokens");
        assertTrue(ethAfter > ethBefore, "Should have received ETH from selling project tokens");
        uint256 ethReceived = ethAfter - ethBefore;
        emit log_named_uint("  ETH received from selling project tokens", ethReceived);
        vm.deal(address(this), 1000 ether);
        ethBefore = address(this).balance;
        projBefore = IERC20(address(projectToken)).balanceOf(address(this));
        swapHelper.swap{value: projIsToken0 ? 0 : 1 ether}(key, !projIsToken0, -int256(1 ether));
        ethAfter = address(this).balance;
        projAfter = IERC20(address(projectToken)).balanceOf(address(this));
        assertTrue(ethAfter < ethBefore, "Should have spent ETH");
        assertTrue(projAfter > projBefore, "Should have received project tokens from buying");
        uint256 projReceived = projAfter - projBefore;
        emit log_named_uint("  Project tokens received from buying with ETH", projReceived);
        uint256 tokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Pool should still have liquidity after both swaps");
        emit log_named_uint("  Remaining position liquidity", posLiq);
    }

    function test_fork_ethPool_rebalanceAfterPriceMovement() public {
        _accumulateTokens(projectId, address(projectToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(projectId, 0);
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "Pool should be deployed");
        PoolKey memory key = hook.poolKeyOf(projectId, JBConstants.NATIVE_TOKEN);
        PoolId poolId = key.toId();
        SwapHelper swapHelper = new SwapHelper(V4_POOL_MANAGER);
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId, tokenCount: 50_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });
        IERC20(address(projectToken)).approve(address(swapHelper), type(uint256).max);
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(projectToken);
        (, int24 tickBefore,,) = V4_POOL_MANAGER.getSlot0(poolId);
        emit log_named_int("  Tick before swaps", tickBefore);
        swapHelper.swap(key, projIsToken0, -int256(20_000e18));
        vm.deal(address(this), 1000 ether);
        swapHelper.swap{value: projIsToken0 ? 0 : 2 ether}(key, !projIsToken0, -int256(2 ether));
        swapHelper.swap(key, projIsToken0, -int256(15_000e18));
        (, int24 tickAfterSwaps,,) = V4_POOL_MANAGER.getSlot0(poolId);
        emit log_named_int("  Tick after swaps", tickAfterSwaps);
        _accumulateTokens(projectId, address(projectToken), 50_000e18);
        uint256 oldTokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        uint128 oldLiq = V4_POSITION_MANAGER.getPositionLiquidity(oldTokenId);
        emit log_named_uint("  Old position liquidity", oldLiq);
        vm.prank(multisig);
        hook.rebalanceLiquidity({
            projectId: projectId, terminalToken: JBConstants.NATIVE_TOKEN, decreaseAmount0Min: 0, decreaseAmount1Min: 0
        });
        uint256 newTokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        assertTrue(newTokenId != oldTokenId, "Token ID should change after rebalance");
        uint128 newLiq = V4_POSITION_MANAGER.getPositionLiquidity(newTokenId);
        assertTrue(newLiq > 0, "New position should have liquidity after rebalance");
        emit log_named_uint("  New position liquidity", newLiq);
        uint256 projBefore = IERC20(address(projectToken)).balanceOf(address(this));
        swapHelper.swap(key, projIsToken0, -int256(1000e18));
        uint256 projAfter = IERC20(address(projectToken)).balanceOf(address(this));
        assertTrue(projAfter < projBefore, "Should still be able to swap after rebalance");
        (, int24 tickFinal,,) = V4_POOL_MANAGER.getSlot0(poolId);
        emit log_named_int("  Tick after rebalance swap", tickFinal);
    }

    function test_fork_ethPool_extremeTaxRate_swapsSucceed() public {
        uint256 extremeProjectId = _launchProject({withOwnerMinting: true, cashOutTaxRate: 9500, weight: 1_000_000e18});
        vm.prank(multisig);
        IJBToken extremeToken = jbController.deployERC20For(extremeProjectId, "Extreme Token", "XTR", bytes32(0));
        _payProject(extremeProjectId, 30 ether);
        _accumulateTokens(extremeProjectId, address(extremeToken), 100_000e18);
        vm.prank(multisig);
        hook.deployPool(extremeProjectId, 0);
        assertTrue(
            hook.isPoolDeployed(extremeProjectId, JBConstants.NATIVE_TOKEN),
            "Pool should be deployed with 95% cashOutTaxRate"
        );
        PoolKey memory key = hook.poolKeyOf(extremeProjectId, JBConstants.NATIVE_TOKEN);
        PoolId poolId = key.toId();
        uint256 tokenId = hook.tokenIdOf(extremeProjectId, JBConstants.NATIVE_TOKEN);
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Position should have liquidity at 95% tax rate");
        (uint160 sqrtPriceX96, int24 currentTick,,) = V4_POOL_MANAGER.getSlot0(poolId);
        emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
        emit log_named_int("  current tick", currentTick);
        emit log_named_uint("  position liquidity", posLiq);
        SwapHelper swapHelper = new SwapHelper(V4_POOL_MANAGER);
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: extremeProjectId,
            tokenCount: 50_000e18,
            beneficiary: address(this),
            memo: "",
            useReservedPercent: false
        });
        IERC20(address(extremeToken)).approve(address(swapHelper), type(uint256).max);
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(extremeToken);
        uint256 ethBefore = address(this).balance;
        swapHelper.swap(key, projIsToken0, -int256(5000e18));
        uint256 ethAfter = address(this).balance;
        assertTrue(ethAfter > ethBefore, "Should receive ETH from selling tokens (95% tax rate)");
        emit log_named_uint("  ETH received from sell", ethAfter - ethBefore);
        vm.deal(address(this), 1000 ether);
        uint256 projBefore = IERC20(address(extremeToken)).balanceOf(address(this));
        swapHelper.swap{value: projIsToken0 ? 0 : 0.5 ether}(key, !projIsToken0, -int256(0.5 ether));
        uint256 projAfter = IERC20(address(extremeToken)).balanceOf(address(this));
        assertTrue(projAfter > projBefore, "Should receive project tokens from buying (95% tax rate)");
        emit log_named_uint("  Tokens received from buy", projAfter - projBefore);
        uint128 finalLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(finalLiq > 0, "Pool should still have liquidity after extreme tax rate swaps");
        emit log_named_uint("  Final position liquidity", finalLiq);
    }

    function _launchProject(bool withOwnerMinting, uint16 cashOutTaxRate, uint112 weight)
        internal
        returns (uint256 id)
    {
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
