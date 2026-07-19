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
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
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
import {IJBUniswapV4LPSplitHook} from "../../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBLPSplitHookHelpers} from "../../src/libraries/JBLPSplitHookHelpers.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

/// @notice Minimal real-`PoolManager` swap helper (mirrors `GeomeanSwapHelper`/`PriceRatioSwapHelper` from the
/// sibling fork tests) used here to simulate genuine buyer flow (terminal token in, project token out) through the
/// hook's deployed pool — never through the hook itself.
contract BuySwapHelper is IUnlockCallback {
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

/// @notice Fork-integration proof for the redesigned single-sided/permissionless LP split hook, run against the
/// REAL mainnet Uniswap V4 `PoolManager`/`PositionManager` (not the mock used by the rest of the suite) plus a
/// from-source `JBMultiTerminal`/`JBTerminalStore`.
///
/// Exercises the full revnet-shaped lifecycle end-to-end:
///   1. A revnet-shaped project (non-zero `reservedPercent`, non-zero `cashOutTaxRate`) accumulates reserved tokens
///      in the hook.
///   2. The Uniswap V4 pool is pre-initialized (mimicking the revnet norm where the pool already exists) at a
///      mid-corridor spot near the issuance ceiling — NOT at the cash-out floor, and NOT via the hook's own
///      geometric-midpoint bootstrap price.
///   3. A random, non-owner address permissionlessly calls `deployPool`, seeding a single-sided (project-token-only)
///      ask position.
///   4. A real buyer swaps terminal token for project token directly through the live pool (never through the hook),
///      sized (via the position's own liquidity/tick math) to fully cross the ask band, so the position now holds
///      terminal token as principal.
///   5. After a real ruleset-weight-decay cycle shifts the project's issuance/cash-out corridor, a different random,
///      non-owner address permissionlessly calls `rebalanceLiquidity`, which burns the exhausted ask position and
///      re-mints a two-sided position bidding with the recovered terminal token.
///   6. Throughout, the project's `JBTerminalStore` balance is snapshotted before/after every hook call and is
///      asserted to never decrease — the hook never cashes out or otherwise drains the project's terminal balance;
///      the only terminal-balance movement is LP-fee routing adding to it.
contract Integration_SingleSidedRevnet is ForkDeployHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    JBUniswapV4LPSplitHook hook;
    uint256 feeProjectId;

    // Non-owner callers used to prove every entry point exercised here is permissionless.
    address randomDeployer = address(0xD00D);
    address randomRebalancer = address(0xBEEF2);
    address realBuyer = address(0xB0B);

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);
        require(address(V4_POOL_MANAGER).code.length > 0, "PoolManager not deployed");
        require(address(V4_POSITION_MANAGER).code.length > 0, "PositionManager not deployed");
        _deployJBCore();

        feeProjectId = _launchProject({reservedPercent: 0, cashOutTaxRate: 0, weight: 1_000_000e18, duration: 0});
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

    function test_fork_singleSidedRevnet_seedBuyRebalance_noCashOut() public {
        // ── 1. Launch a revnet-shaped project: non-zero reserved%, non-zero cash-out tax, and a ruleset that will
        // decay (a second, halved-weight cycle is queued below to genuinely shift the issuance/cash-out corridor).
        uint256 pid =
            _launchProject({reservedPercent: 3000, cashOutTaxRate: 4000, weight: 1_000_000e18, duration: 1 days});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Revnet Token", "RVNT", bytes32(0));

        // Seed real surplus so the bonding-curve cash-out floor is non-trivial (not the zero-surplus fallback).
        uint256 balAfterPay = _payProjectAndSnapshot(pid, 50 ether);

        // Route reserved tokens to the hook (pre-deployment accumulation).
        _accumulateTokens(pid, address(pToken), 500_000e18);

        // ── 2. Pre-initialize the pool at a mid-corridor spot near the issuance ceiling — mimicking the revnet
        // norm
        // where the pool already exists before the hook ever allocates — rather than letting `deployPool` bootstrap
        // it at its own geometric-midpoint default. Compute the project's live economic corridor with the SAME
        // linked math library the hook uses, at this exact moment (right before `deployPool`, so nothing else
        // changes state in between and the preview matches what the hook itself will recompute).
        (JBRuleset memory ruleset,) = jbController.currentRulesetOf(pid);
        (int24 ascLower, int24 ascUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: jbDirectory,
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: pid,
            terminalToken: JBConstants.NATIVE_TOKEN,
            projectToken: address(pToken),
            controller: address(jbController),
            ruleset: ruleset
        });
        int24 tickSpacing = hook.TICK_SPACING();
        assertTrue(ascUpper - ascLower > 2 * tickSpacing, "corridor too narrow for this test's tick offsets");

        // The native terminal token always sorts as currency0 (its Uniswap-mapped address(0) is always the lowest
        // address), so the project token is always currency1 for every ETH-paired pool this hook deploys. That
        // means `ascLower` (the ascending-sorted lower bound from `calculateTickBounds`) is the ECONOMIC ISSUANCE
        // CEILING (see `_adaptiveRange`'s "project is token1" branch), and `ascUpper` is the economic cash-out
        // floor. Initialize one spacing INSIDE from the ceiling — deep in the corridor, nowhere near the floor.
        int24 initTick = ascLower + tickSpacing;
        uint160 initSqrtPrice = TickMath.getSqrtPriceAtTick(initTick);

        Currency terminalCurrency = JBLPSplitHookHelpers.toCurrency(JBConstants.NATIVE_TOKEN);
        Currency projectCurrency = Currency.wrap(address(pToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: tickSpacing,
            hooks: hook.oracleHook()
        });
        V4_POSITION_MANAGER.initializePool(key, initSqrtPrice);
        (uint160 preexistingSpot,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        assertEq(preexistingSpot, initSqrtPrice, "pool must read back the pre-initialized spot");

        // ── 3. Permissionless deploy: a random, non-owner address seeds the pool from the accumulated tokens.
        // Deploying onto a pre-initialized pool now validates spot against the oracle TWAP; force TWAP == spot so the
        // guard passes deterministically without seeding 30 minutes of observation history.
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        vm.prank(randomDeployer);
        hook.deployPool(pid);

        assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "pool should be deployed");
        uint256 seedTokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        assertTrue(seedTokenId != 0, "seed position must exist");
        uint128 seedLiquidity = V4_POSITION_MANAGER.getPositionLiquidity(seedTokenId);
        assertTrue(seedLiquidity > 0, "seed position must have liquidity");

        int24 seedTickLower = hook.activeTickLowerOf(pid, JBConstants.NATIVE_TOKEN);
        int24 seedTickUpper = hook.activeTickUpperOf(pid, JBConstants.NATIVE_TOKEN);
        (uint160 seedSpot,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        (uint256 seedAmount0, uint256 seedAmount1) = _positionPrincipal({
            sqrtPriceX96: seedSpot, tickLower: seedTickLower, tickUpper: seedTickUpper, liquidity: seedLiquidity
        });
        // Terminal (native ETH) is always currency0 for these ETH-paired pools; a single-sided ask position at seed
        // holds (~)zero of it.
        assertEq(seedAmount0, 0, "seed position must hold zero terminal token (single-sided ask)");
        assertTrue(seedAmount1 > 0, "seed position must hold project tokens (the ask side)");

        uint256 balAfterDeploy = jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, JBConstants.NATIVE_TOKEN);
        assertGe(balAfterDeploy, balAfterPay, "deployPool must never reduce the project's terminal balance");

        // ── 4. Simulate a real buy: a genuine buyer swaps terminal token for project token THROUGH THE LIVE POOL
        // (never through the hook), sized off the position's own liquidity/tick math to fully cross the thin ask
        // band and leave the position holding terminal token as principal.
        uint256 costToFullyCrossAsk = SqrtPriceMath.getAmount0Delta({
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(seedTickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(seedTickUpper),
            liquidity: seedLiquidity,
            roundUp: true
        });
        // Deliberately UNDER, not over, the full crossing cost: this pool has zero liquidity outside the seed
        // position's thin ask band, so any swap that fully exhausts it sends the spot rocketing to the tick-space
        // extreme (no interposing liquidity to absorb the remainder) instead of settling near the band's edge. 90%
        // of the crossing cost lands spot just inside the band, near its floor, with the position already holding
        // real accrued terminal token — a realistic partial buy, not a liquidity-draining edge case.
        uint256 buyAmountIn = (costToFullyCrossAsk * 90) / 100;
        vm.deal(realBuyer, buyAmountIn + 1 ether);

        BuySwapHelper swapHelper = new BuySwapHelper(V4_POOL_MANAGER);
        vm.prank(realBuyer);
        // zeroForOne = true: sell terminal (currency0), buy project token (currency1) — a real buy.
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap{value: buyAmountIn}({key: key, zeroForOne: true, amountSpecified: -int256(buyAmountIn)});

        (uint160 spotAfterBuy,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        assertTrue(spotAfterBuy < seedSpot, "a real buy of the project token must push spot down (toward the floor)");

        (uint256 postBuyAmount0,) = _positionPrincipal({
            sqrtPriceX96: spotAfterBuy, tickLower: seedTickLower, tickUpper: seedTickUpper, liquidity: seedLiquidity
        });
        assertTrue(postBuyAmount0 > 0, "position must now hold terminal token accrued from the real buy");

        // A real Uniswap swap never touches the JB terminal — the project's terminal balance is untouched.
        uint256 balAfterBuy = jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, JBConstants.NATIVE_TOKEN);
        assertEq(balAfterBuy, balAfterDeploy, "a real AMM swap must never move the project's terminal balance");

        // ── 5. Shift the economic corridor with a genuine ruleset-weight-decay cycle (revnet norm), then
        // permissionlessly rebalance from a DIFFERENT non-owner address.
        _queueHalvedWeightRuleset(pid);
        vm.warp(block.timestamp + 1 days + 1);
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);

        vm.expectEmit({
            checkTopic1: true, checkTopic2: true, checkTopic3: false, checkData: false, emitter: address(hook)
        });
        emit IJBUniswapV4LPSplitHook.PermissionlessRebalanced({
            projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN, tickLower: 0, tickUpper: 0, caller: address(0)
        });
        vm.prank(randomRebalancer);
        hook.rebalanceLiquidity(pid, JBConstants.NATIVE_TOKEN);

        // ── 6. Assert: single tracked position (old NFT retired, exactly one new tokenId tracked), two-sided
        // (now holds terminal as a bid), non-zero liquidity, and the terminal balance was never drained (only ever
        // added to, from routed LP fees).
        uint256 rebalancedTokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        assertTrue(rebalancedTokenId != 0, "rebalanced position must exist");
        assertTrue(rebalancedTokenId != seedTokenId, "rebalance must burn-and-re-mint a fresh tokenId");
        assertEq(V4_POSITION_MANAGER.getPositionLiquidity(seedTokenId), 0, "the old seed position must be fully burned");

        uint128 rebalancedLiquidity = V4_POSITION_MANAGER.getPositionLiquidity(rebalancedTokenId);
        assertTrue(rebalancedLiquidity > 0, "rebalanced position must have liquidity");

        int24 newTickLower = hook.activeTickLowerOf(pid, JBConstants.NATIVE_TOKEN);
        int24 newTickUpper = hook.activeTickUpperOf(pid, JBConstants.NATIVE_TOKEN);
        (uint160 spotAfterRebalance,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        (uint256 rebalancedAmount0, uint256 rebalancedAmount1) = _positionPrincipal({
            sqrtPriceX96: spotAfterRebalance,
            tickLower: newTickLower,
            tickUpper: newTickUpper,
            liquidity: rebalancedLiquidity
        });
        assertTrue(rebalancedAmount0 > 0, "rebalanced position must hold terminal token as a bid (two-sided)");
        assertTrue(rebalancedAmount1 > 0, "rebalanced position must still hold project token as an ask (two-sided)");

        uint256 balAfterRebalance = jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, JBConstants.NATIVE_TOKEN);
        assertGe(
            balAfterRebalance,
            balAfterBuy,
            "rebalanceLiquidity must never reduce the project's terminal balance (only routed LP fees may add to it)"
        );

        // Full monotonic chain across the whole lifecycle, restated for clarity.
        assertGe(balAfterDeploy, balAfterPay, "deploy: never drains");
        assertGe(balAfterBuy, balAfterDeploy, "real swap: never drains (unchanged)");
        assertGe(balAfterRebalance, balAfterBuy, "rebalance: never drains (fees may add)");

        emit log_named_int("  seed tickLower", seedTickLower);
        emit log_named_int("  seed tickUpper", seedTickUpper);
        emit log_named_uint("  seed liquidity", seedLiquidity);
        emit log_named_uint("  spot before buy", seedSpot);
        emit log_named_uint("  spot after buy", spotAfterBuy);
        emit log_named_uint("  buy amount in (wei)", buyAmountIn);
        emit log_named_int("  rebalanced tickLower", newTickLower);
        emit log_named_int("  rebalanced tickUpper", newTickUpper);
        emit log_named_uint("  rebalanced liquidity", rebalancedLiquidity);
        emit log_named_uint("  terminal balance after pay", balAfterPay);
        emit log_named_uint("  terminal balance after deploy", balAfterDeploy);
        emit log_named_uint("  terminal balance after buy", balAfterBuy);
        emit log_named_uint("  terminal balance after rebalance", balAfterRebalance);
    }

    /// @notice The token0/token1 amounts a position of `liquidity` across `[tickLower, tickUpper]` holds at
    /// `sqrtPriceX96`. Mirrors `JBUniswapV4LPSplitHook._positionPrincipal` exactly (v4-periphery's `LiquidityAmounts`
    /// only exposes the inverse `getLiquidityForAmounts`), so this test derives the SAME principal reading the hook
    /// itself uses for its burn-slippage floor.
    function _positionPrincipal(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta({
                sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
            });
        } else if (sqrtPriceX96 < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta({
                sqrtPriceAX96: sqrtPriceX96, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
            });
            amount1 = SqrtPriceMath.getAmount1Delta({
                sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtPriceX96, liquidity: liquidity, roundUp: false
            });
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta({
                sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
            });
        }
    }

    /// @notice Queue a second ruleset cycle with a halved weight (a real revnet-style decay), starting right after
    /// the first cycle's 1-day duration elapses. Used to genuinely shift the issuance/cash-out corridor so
    /// `rebalanceLiquidity`'s anti-churn drift guard clears.
    function _queueHalvedWeightRuleset(uint256 pid) internal {
        JBRulesetMetadata memory newMeta = JBRulesetMetadata({
            reservedPercent: 3000,
            cashOutTaxRate: 4000,
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
        JBRulesetConfig[] memory newConfigs = new JBRulesetConfig[](1);
        newConfigs[0].mustStartAtOrAfter = 0;
        newConfigs[0].duration = 1 days;
        newConfigs[0].weight = 500_000e18;
        newConfigs[0].weightCutPercent = 0;
        newConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        newConfigs[0].metadata = newMeta;
        newConfigs[0].splitGroups = new JBSplitGroup[](0);
        newConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);
        vm.prank(multisig);
        jbController.queueRulesetsOf({projectId: pid, rulesetConfigurations: newConfigs, memo: ""});
    }

    function _launchProject(
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

    function _payProjectAndSnapshot(uint256 pid, uint256 amount) internal returns (uint256 balAfter) {
        jbMultiTerminal.pay{value: amount}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        balAfter = jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, JBConstants.NATIVE_TOKEN);
    }
}
