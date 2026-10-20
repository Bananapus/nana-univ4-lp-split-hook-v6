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
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
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
/// Exercises the two-position lifecycle end-to-end, with every hook call made by a random non-owner:
///   1. A revnet-shaped project accumulates reserved tokens; its pool is pre-initialized mid-corridor.
///   2. `deployPool` seeds a single-sided ask (project tokens below the spot, ETH being currency0).
///   3. A real buyer partly fills the ask through the live pool, so it holds terminal token.
///   4. The next distribution's recycle burns it and re-mints a project-only ask and a terminal-only bid.
///   5. The buyer sells back into the bid, so it holds project tokens.
///   6. The next recycle moves those project tokens back into the ask and keeps the rest of the bid.
///   Throughout, both positions stay inside the corridor and the project's terminal balance never decreases.
contract Integration_SingleSidedRevnet is ForkDeployHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    JBUniswapV4LPSplitHook hook;
    uint256 feeProjectId;

    // Non-owner callers used to prove every entry point exercised here is permissionless.
    address randomDeployer = address(0xD00D);
    address randomRecycler = address(0xBEEF2);
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

    function test_fork_twoPositionRecycle_buySellRecycle_noCashOut() public {
        // ── 1. A revnet-shaped project (reserved %, cash-out tax) with real surplus, accumulating reserved tokens.
        uint256 pid =
            _launchProject({reservedPercent: 3000, cashOutTaxRate: 4000, weight: 1_000_000e18, duration: 1 days});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Revnet Token", "RVNT", bytes32(0));
        uint256 balAfterPay = _payProjectAndSnapshot(pid, 50 ether);
        _accumulateTokens(pid, address(pToken), 500_000e18);

        // ── 2. Pre-initialize the pool mid-corridor (the revnet norm: the pool exists before the hook allocates).
        // Native ETH always sorts as currency0, so the project token is currency1: its asks rest BELOW the spot down
        // to `ascLower` (the issuance ceiling) and the hook's bids rest ABOVE the spot up to `ascUpper` (the floor).
        (int24 ascLower, int24 ascUpper) = _corridorOf(pid, address(pToken));
        int24 tickSpacing = hook.TICK_SPACING();
        assertTrue(ascUpper - ascLower > 4 * tickSpacing, "corridor too narrow for this test's tick offsets");
        int24 initTick =
            JBLPSplitHookHelpers.alignTickToSpacing({tick: ascLower + (ascUpper - ascLower) / 2, spacing: tickSpacing});

        PoolKey memory key = PoolKey({
            currency0: JBLPSplitHookHelpers.toCurrency(JBConstants.NATIVE_TOKEN),
            currency1: Currency.wrap(address(pToken)),
            fee: hook.POOL_FEE(),
            tickSpacing: tickSpacing,
            hooks: hook.oracleHook()
        });
        V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(initTick));

        // ── 3. Permissionless deploy seeds the ask only: the hook holds no terminal tokens yet.
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        vm.prank(randomDeployer);
        hook.deployPool(pid);

        uint256 seedAskId = hook.askTokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        assertTrue(seedAskId != 0, "seed ask must exist");
        assertEq(hook.bidTokenIdOf(pid, JBConstants.NATIVE_TOKEN), 0, "no bid without terminal tokens");
        (uint256 seedAsk0, uint256 seedAsk1) = _principalOf(seedAskId, key);
        assertEq(seedAsk0, 0, "seed ask holds no terminal");
        assertTrue(seedAsk1 > 0, "seed ask holds project tokens");
        _assertAskBelowSpot(seedAskId, key, ascLower, ascUpper);

        uint256 balAfterDeploy = jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, JBConstants.NATIVE_TOKEN);
        assertGe(balAfterDeploy, balAfterPay, "deployPool must never reduce the project's terminal balance");

        // ── 4. A real buyer fills part of the ask through the live pool: the ask now holds terminal tokens.
        BuySwapHelper swapHelper = new BuySwapHelper(V4_POOL_MANAGER);
        {
            (int24 askLower, int24 askUpper) = _ticksOf(seedAskId);
            uint256 buyAmountIn = SqrtPriceMath.getAmount0Delta({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(askLower),
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(askUpper),
                liquidity: V4_POSITION_MANAGER.getPositionLiquidity(seedAskId),
                roundUp: true
            }) / 4;
            vm.deal(realBuyer, buyAmountIn);
            vm.prank(realBuyer);
            // forge-lint: disable-next-line(unsafe-typecast)
            swapHelper.swap{value: buyAmountIn}({key: key, zeroForOne: true, amountSpecified: -int256(buyAmountIn)});
        }
        (uint256 filledAsk0,) = _principalOf(seedAskId, key);
        assertTrue(filledAsk0 > 0, "the partly filled ask must hold terminal tokens");

        // ── 5. The next reserved distribution recycles both sides from a random caller: the ask's terminal moves
        // into a fresh bid above the spot, every project token into a fresh ask below it.
        _accumulateTokens(pid, address(pToken), 100_000e18);
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        vm.prank(randomRecycler);
        hook.addLiquidity(pid, JBConstants.NATIVE_TOKEN);

        uint256 askId = hook.askTokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        uint256 bidId = hook.bidTokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        assertEq(V4_POSITION_MANAGER.getPositionLiquidity(seedAskId), 0, "the seed ask must be burned");
        assertTrue(askId != 0 && bidId != 0, "both positions must exist after recycling a filled ask");
        (uint256 ask0, uint256 ask1) = _principalOf(askId, key);
        (uint256 bid0, uint256 bid1) = _principalOf(bidId, key);
        assertEq(ask0, 0, "the ask is single-sided project tokens");
        assertEq(bid1, 0, "the bid is single-sided terminal tokens");
        assertApproxEqRel(bid0, filledAsk0, 0.01e18, "the bid carries the ask's filled terminal (+ fee remainder)");
        assertTrue(ask1 > 100_000e18, "the ask carries the unfilled seed plus the new distribution");
        // Minting reserved tokens grows supply, which moves the cash-out floor, so compare against the live corridor.
        (ascLower, ascUpper) = _corridorOf(pid, address(pToken));
        _assertAskBelowSpot(askId, key, ascLower, ascUpper);
        _assertBidAboveSpot(bidId, key, ascLower, ascUpper);

        // ── 6. The buyer sells back into the hook's bid: the bid now holds project tokens.
        {
            uint256 sellAmount = IERC20(address(pToken)).balanceOf(realBuyer) / 2;
            vm.startPrank(realBuyer);
            IERC20(address(pToken)).approve(address(swapHelper), sellAmount);
            // forge-lint: disable-next-line(unsafe-typecast)
            swapHelper.swap({key: key, zeroForOne: false, amountSpecified: -int256(sellAmount)});
            vm.stopPrank();
        }
        (, uint256 filledBid1) = _principalOf(bidId, key);
        assertTrue(filledBid1 > 0, "the partly filled bid must hold project tokens");

        // ── 7. The next distribution recycles again: the project tokens the bid bought go back into the ask.
        _accumulateTokens(pid, address(pToken), 100_000e18);
        _mockOracleTwapEqualsSpot(hook.oracleHook(), V4_POOL_MANAGER, key);
        uint256 gasBefore = gasleft();
        vm.prank(randomRecycler);
        hook.addLiquidity(pid, JBConstants.NATIVE_TOKEN);
        emit log_named_uint("  full two-position recycle gas", gasBefore - gasleft());

        uint256 askId2 = hook.askTokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        uint256 bidId2 = hook.bidTokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        (uint256 ask0After, uint256 ask1After) = _principalOf(askId2, key);
        (uint256 bid0After, uint256 bid1After) = _principalOf(bidId2, key);
        assertEq(ask0After, 0, "the ask stays single-sided");
        assertEq(bid1After, 0, "the bid stays single-sided");
        assertTrue(bid0After > 0, "the bid keeps its unfilled terminal");
        assertApproxEqRel(
            ask1After, ask1 + 100_000e18 + filledBid1, 0.01e18, "the ask absorbs the bid's fills and the distribution"
        );
        (ascLower, ascUpper) = _corridorOf(pid, address(pToken));
        _assertAskBelowSpot(askId2, key, ascLower, ascUpper);
        _assertBidAboveSpot(bidId2, key, ascLower, ascUpper);

        // Ledgers only hold rounding dust, and the hook never drained the treasury.
        assertLt(hook.accumulatedProjectTokens(pid), 1e12, "project ledger must be (near) empty after a recycle");
        assertLt(hook.accumulatedTerminalTokens(pid, JBConstants.NATIVE_TOKEN), 1e9, "terminal ledger near empty");
        assertGe(
            jbTerminalStore.balanceOf(address(jbMultiTerminal), pid, JBConstants.NATIVE_TOKEN),
            balAfterDeploy,
            "recycling must never reduce the project's terminal balance"
        );
    }

    /// @notice The project's live corridor, computed with the same linked math the hook uses.
    function _corridorOf(uint256 pid, address pToken) internal view returns (int24 ascLower, int24 ascUpper) {
        (JBRuleset memory ruleset,) = jbController.currentRulesetOf(pid);
        return JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: jbDirectory,
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: pid,
            terminalToken: JBConstants.NATIVE_TOKEN,
            projectToken: pToken,
            controller: address(jbController),
            ruleset: ruleset
        });
    }

    /// @notice The live tick range of a hook position, read from the PositionManager.
    function _ticksOf(uint256 tokenId) internal view returns (int24 tickLower, int24 tickUpper) {
        (, PositionInfo info) = V4_POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        return (info.tickLower(), info.tickUpper());
    }

    /// @notice A hook position's principal at the live spot.
    function _principalOf(uint256 tokenId, PoolKey memory key) internal view returns (uint256, uint256) {
        (int24 tickLower, int24 tickUpper) = _ticksOf(tokenId);
        (uint160 spot,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        return _positionPrincipal({
            sqrtPriceX96: spot,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: V4_POSITION_MANAGER.getPositionLiquidity(tokenId)
        });
    }

    /// @notice The ask (project = currency1) rests at or below the spot and never past the cash-out floor.
    function _assertAskBelowSpot(uint256 tokenId, PoolKey memory key, int24 ascLower, int24 ascUpper) internal view {
        (int24 tickLower, int24 tickUpper) = _ticksOf(tokenId);
        (, int24 spotTick,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        assertLe(tickUpper, spotTick, "ask must rest at or below the spot");
        assertGe(tickLower, ascLower, "ask must not reach past the issuance ceiling");
        assertLe(tickUpper, ascUpper, "ask must not sell below the cash-out floor");
    }

    /// @notice The bid (terminal = currency0) rests above the spot and never past the issuance ceiling.
    function _assertBidAboveSpot(uint256 tokenId, PoolKey memory key, int24 ascLower, int24 ascUpper) internal view {
        (int24 tickLower, int24 tickUpper) = _ticksOf(tokenId);
        (, int24 spotTick,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        assertGt(tickLower, spotTick, "bid must rest above the spot");
        assertGe(tickLower, ascLower, "bid must not buy above the issuance ceiling");
        assertLe(tickUpper, ascUpper, "bid must not reach past the cash-out floor");
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
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
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
