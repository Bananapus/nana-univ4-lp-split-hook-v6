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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
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
    // Lets the callback check whether a currency is native ETH.
    using CurrencyLibrary for Currency;

    /// @notice The real Uniswap V4 PoolManager the helper swaps through.
    IPoolManager public immutable poolManager;

    /// @custom:member key The pool to swap in.
    /// @custom:member zeroForOne Whether the swap sells currency0 for currency1.
    /// @custom:member amountSpecified The exact input (negative) or exact output (positive) amount.
    /// @custom:member sqrtPriceLimitX96 The price the swap stops at, or 0 for the unbounded limit in the swap
    /// direction.
    /// @custom:member sender The account that pays the swap's input and receives its output.
    struct SwapCallbackData {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        address sender;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    receive() external payable {}

    /// @notice Swaps `amountSpecified` with no price limit, paying from and paying out to the caller.
    /// @param key The pool to swap in.
    /// @param zeroForOne Whether the swap sells currency0 for currency1.
    /// @param amountSpecified The exact input (negative) or exact output (positive) amount.
    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external payable {
        // A zero price limit tells the callback to use the unbounded limit in the swap direction.
        poolManager.unlock(
            abi.encode(
                SwapCallbackData({
                    key: key,
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: 0,
                    sender: msg.sender
                })
            )
        );
    }

    /// @notice Swaps until `sqrtPriceLimitX96` (or `amountSpecified`) is reached and refunds unspent ETH.
    /// @param key The pool to swap in.
    /// @param zeroForOne Whether the swap sells currency0 for currency1.
    /// @param amountSpecified The exact input (negative) or exact output (positive) amount.
    /// @param sqrtPriceLimitX96 The price the swap stops at.
    function swapTo(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    )
        external
        payable
    {
        // Run the swap inside an unlock so the callback settles both currencies.
        poolManager.unlock(
            abi.encode(
                SwapCallbackData({
                    key: key,
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: sqrtPriceLimitX96,
                    sender: msg.sender
                })
            )
        );
        // The price limit can stop the swap before the sent ETH is spent, so return whatever is left to the caller.
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok, "refund failed");
    }

    /// @notice Executes the swap described by `data` and settles both currency deltas with `sender`.
    /// @param data The ABI-encoded `SwapCallbackData`.
    /// @return result Empty bytes, since the caller reads nothing back.
    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == address(poolManager), "only pool manager");
        SwapCallbackData memory params = abi.decode(data, (SwapCallbackData));
        BalanceDelta delta = poolManager.swap(
            params.key,
            SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                // Use the requested limit when one is given, else the widest limit in the swap direction.
                sqrtPriceLimitX96: params.sqrtPriceLimitX96 != 0
                    ? params.sqrtPriceLimitX96
                    : params.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
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
}

/// @notice Fork-integration proof for the single-sided, permissionless LP split hook, run against the REAL mainnet
/// Uniswap V4 `PoolManager`/`PositionManager` (not the mock used by the rest of the suite) plus a from-source
/// `JBMultiTerminal`/`JBTerminalStore`.
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
    // Reads pool slot0 and tick liquidity from the PoolManager.
    using StateLibrary for IPoolManager;
    // Derives a pool's ID from its key.
    using PoolIdLibrary for PoolKey;
    // Unpacks a position's tick range from its packed info.
    using PositionInfoLibrary for PositionInfo;

    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    /// @notice The LP split hook clone under test, wired to the real V4 PoolManager and PositionManager.
    JBUniswapV4LPSplitHook hook;

    /// @notice The project that receives the hook's fee share.
    uint256 feeProjectId;

    // Non-owner callers used to prove every entry point exercised here is permissionless.
    address randomDeployer = address(0xD00D);
    address randomRecycler = address(0xBEEF2);
    address realBuyer = address(0xB0B);

    receive() external payable {}

    /// @notice Forks mainnet, deploys JB core and a fee project, and initializes a hook clone on the real V4 contracts.
    function setUp() public {
        // Pin the fork block so the canonical V4 deployments exist and every run sees the same state.
        vm.createSelectFork("ethereum", 21_700_000);
        require(address(V4_POOL_MANAGER).code.length > 0, "PoolManager not deployed");
        require(address(V4_POSITION_MANAGER).code.length > 0, "PositionManager not deployed");
        _deployJBCore();

        // The fee project needs an ERC-20 so the hook can route its fee share into fee-project tokens.
        feeProjectId = _launchProject({reservedPercent: 0, cashOutTaxRate: 0, weight: 1_000_000e18, duration: 0});
        vm.prank(multisig);
        jbController.deployERC20For({projectId: feeProjectId, name: "Fee Token", symbol: "FEE", salt: bytes32(0)});

        // Deploy the implementation, clone it and initialize the clone with the real V4 contracts and a passive oracle.
        JBUniswapV4LPSplitHook hookImpl = new JBUniswapV4LPSplitHook({
            directory: address(jbDirectory),
            permissions: IJBPermissions(address(jbPermissions)),
            tokens: address(jbTokens),
            permit2: IAllowanceTransfer(address(PERMIT2)),
            suckerRegistry: IJBSuckerRegistry(address(0))
        });
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

    /// @notice Proves a full deploy, buy, recycle, sell, recycle lifecycle keeps the ask project-only below the spot,
    /// the bid terminal-only above it, both inside the corridor, and never reduces the project's terminal balance.
    function test_fork_twoPositionRecycle_buySellRecycle_noCashOut() public {
        // ── 1. A revnet-shaped project (reserved %, cash-out tax) with real surplus, accumulating reserved tokens.
        uint256 pid =
            _launchProject({reservedPercent: 3000, cashOutTaxRate: 4000, weight: 1_000_000e18, duration: 1 days});
        vm.prank(multisig);
        IJBToken pToken =
            jbController.deployERC20For({projectId: pid, name: "Revnet Token", symbol: "RVNT", salt: bytes32(0)});
        uint256 balAfterPay = _payProjectAndSnapshot({pid: pid, amount: 50 ether});
        _accumulateTokens({pid: pid, tokenAddr: address(pToken), amount: 500_000e18});

        // ── 2. Pre-initialize the pool mid-corridor (the revnet norm: the pool exists before the hook allocates).
        // Native ETH always sorts as currency0, so the project token is currency1: its asks rest BELOW the spot down
        // to `ascLower` (the issuance ceiling) and the hook's bids rest ABOVE the spot up to `ascUpper` (the floor).
        (int24 ascLower, int24 ascUpper) = _corridorOf({pid: pid, pToken: address(pToken)});
        int24 tickSpacing = hook.TICK_SPACING();
        assertTrue(ascUpper - ascLower > 4 * tickSpacing, "corridor too narrow for this test's tick offsets");
        int24 initTick =
            JBLPSplitHookHelpers.alignTickToSpacing({tick: ascLower + (ascUpper - ascLower) / 2, spacing: tickSpacing});

        // Build the exact pool key the hook derives, so the pre-initialized pool is the one it adopts.
        PoolKey memory key = PoolKey({
            currency0: JBLPSplitHookHelpers.toCurrency(JBConstants.NATIVE_TOKEN),
            currency1: Currency.wrap(address(pToken)),
            fee: hook.POOL_FEE(),
            tickSpacing: tickSpacing,
            hooks: hook.oracleHook()
        });
        V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(initTick));

        // ── 3. Permissionless deploy seeds the ask only: the hook holds no terminal tokens yet.
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: V4_POOL_MANAGER, key: key});
        vm.prank(randomDeployer);
        hook.deployPool(pid);

        // The seed ask holds only project tokens and sits below the spot inside the corridor.
        uint256 seedAskId = hook.askTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
        assertTrue(seedAskId != 0, "seed ask must exist");
        assertEq(
            hook.bidTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}),
            0,
            "no bid without terminal tokens"
        );
        (uint256 seedAsk0, uint256 seedAsk1) = _principalOf({tokenId: seedAskId, key: key});
        assertEq(seedAsk0, 0, "seed ask holds no terminal");
        assertTrue(seedAsk1 > 0, "seed ask holds project tokens");
        _assertAskBelowSpot({tokenId: seedAskId, key: key, ascLower: ascLower, ascUpper: ascUpper});

        // Deploying the pool must not take ETH out of the project's terminal.
        uint256 balAfterDeploy = jbTerminalStore.balanceOf({
            terminal: address(jbMultiTerminal), projectId: pid, token: JBConstants.NATIVE_TOKEN
        });
        assertGe(balAfterDeploy, balAfterPay, "deployPool must never reduce the project's terminal balance");

        // ── 4. A real buyer fills part of the ask through the live pool, so the ask holds terminal tokens.
        BuySwapHelper swapHelper = new BuySwapHelper(V4_POOL_MANAGER);
        {
            // Spend a quarter of the ETH that would buy out the whole ask, so it is only partly filled.
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
        (uint256 filledAsk0,) = _principalOf({tokenId: seedAskId, key: key});
        assertTrue(filledAsk0 > 0, "the partly filled ask must hold terminal tokens");

        // ── 5. The next reserved distribution recycles both sides from a random caller: the ask's terminal moves
        // into a fresh bid above the spot, every project token into a fresh ask below it.
        _accumulateTokens({pid: pid, tokenAddr: address(pToken), amount: 100_000e18});
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: V4_POOL_MANAGER, key: key});
        vm.prank(randomRecycler);
        hook.addLiquidity({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});

        // The seed ask is burned and replaced by a single-sided ask and a single-sided bid.
        uint256 askId = hook.askTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
        uint256 bidId = hook.bidTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
        assertEq(V4_POSITION_MANAGER.getPositionLiquidity(seedAskId), 0, "the seed ask must be burned");
        assertTrue(askId != 0 && bidId != 0, "both positions must exist after recycling a filled ask");
        (uint256 ask0, uint256 ask1) = _principalOf({tokenId: askId, key: key});
        (uint256 bid0, uint256 bid1) = _principalOf({tokenId: bidId, key: key});
        assertEq(ask0, 0, "the ask is single-sided project tokens");
        assertEq(bid1, 0, "the bid is single-sided terminal tokens");
        assertApproxEqRel(bid0, filledAsk0, 0.01e18, "the bid carries the ask's filled terminal (+ fee remainder)");
        assertTrue(ask1 > 100_000e18, "the ask carries the unfilled seed plus the new distribution");
        // Minting reserved tokens grows supply, which moves the cash-out floor, so compare against the live corridor.
        (ascLower, ascUpper) = _corridorOf({pid: pid, pToken: address(pToken)});
        _assertAskBelowSpot({tokenId: askId, key: key, ascLower: ascLower, ascUpper: ascUpper});
        _assertBidAboveSpot({tokenId: bidId, key: key, ascLower: ascLower, ascUpper: ascUpper});

        // ── 6. The buyer sells back into the hook's bid, so the bid holds project tokens.
        {
            // Sell half of what the buyer bought, so the bid is only partly filled.
            uint256 sellAmount = IERC20(address(pToken)).balanceOf(realBuyer) / 2;
            vm.startPrank(realBuyer);
            IERC20(address(pToken)).approve(address(swapHelper), sellAmount);
            // forge-lint: disable-next-line(unsafe-typecast)
            swapHelper.swap({key: key, zeroForOne: false, amountSpecified: -int256(sellAmount)});
            vm.stopPrank();
        }
        (, uint256 filledBid1) = _principalOf({tokenId: bidId, key: key});
        assertTrue(filledBid1 > 0, "the partly filled bid must hold project tokens");

        // ── 7. The next distribution recycles again: the project tokens the bid bought go back into the ask.
        _accumulateTokens({pid: pid, tokenAddr: address(pToken), amount: 100_000e18});
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: V4_POOL_MANAGER, key: key});
        // Log the gas of a recycle that burns and re-mints both positions.
        uint256 gasBefore = gasleft();
        vm.prank(randomRecycler);
        hook.addLiquidity({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
        emit log_named_uint("  full two-position recycle gas", gasBefore - gasleft());

        // Both fresh positions stay single-sided, and the ask absorbs the bid's fills plus the new distribution.
        uint256 askId2 = hook.askTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
        uint256 bidId2 = hook.bidTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
        (uint256 ask0After, uint256 ask1After) = _principalOf({tokenId: askId2, key: key});
        (uint256 bid0After, uint256 bid1After) = _principalOf({tokenId: bidId2, key: key});
        assertEq(ask0After, 0, "the ask stays single-sided");
        assertEq(bid1After, 0, "the bid stays single-sided");
        assertTrue(bid0After > 0, "the bid keeps its unfilled terminal");
        assertApproxEqRel(
            ask1After, ask1 + 100_000e18 + filledBid1, 0.01e18, "the ask absorbs the bid's fills and the distribution"
        );
        // The corridor moved with the new reserved mint, so re-read it before checking the bounds.
        (ascLower, ascUpper) = _corridorOf({pid: pid, pToken: address(pToken)});
        _assertAskBelowSpot({tokenId: askId2, key: key, ascLower: ascLower, ascUpper: ascUpper});
        _assertBidAboveSpot({tokenId: bidId2, key: key, ascLower: ascLower, ascUpper: ascUpper});

        // Ledgers only hold rounding dust, and the hook never drained the treasury.
        assertLt(hook.accumulatedProjectTokens(pid), 1e12, "project ledger must be (near) empty after a recycle");
        assertLt(
            hook.accumulatedTerminalTokens({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}),
            1e9,
            "terminal ledger near empty"
        );
        assertGe(
            jbTerminalStore.balanceOf({
                terminal: address(jbMultiTerminal), projectId: pid, token: JBConstants.NATIVE_TOKEN
            }),
            balAfterDeploy,
            "recycling must never reduce the project's terminal balance"
        );
    }

    /// @notice Proves band-edge cycling does not profit: with the TWAP pinned, an attacker sweeps the spot between
    /// both edges of the deviation band and recycles at each edge, trying to buy project tokens from the ask on one
    /// side of the TWAP and sell them into the bid on the other. Both quotes are anchored to the TWAP, so the attacker
    /// buys at or above the TWAP price and sells at or below it, and the round trips can only lose swap fees.
    function test_fork_twoPositionRecycle_bandEdgeCycling_notProfitable() public {
        _runBandEdgeCycle({anchorOffset: 0});
    }

    /// @notice Proves the same cycle does not profit with the TWAP off the tick-spacing grid, so each quote's anchor
    /// bound rounds away from the TWAP rather than landing on it.
    function test_fork_twoPositionRecycle_bandEdgeCycling_unalignedTwap_notProfitable() public {
        _runBandEdgeCycle({anchorOffset: 77});
    }

    /// @notice Delivers `amount` freshly minted project tokens to the hook as a reserved-token split, intake only.
    /// @param pid The project whose tokens are minted and delivered.
    /// @param tokenAddr The project's ERC-20.
    /// @param amount The number of project tokens to deliver.
    function _accumulateTokens(uint256 pid, address tokenAddr, uint256 amount) internal {
        // Mint to the controller, which is the account that hands split tokens to a split hook.
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: amount, beneficiary: address(jbController), memo: "", useReservedPercent: false
        });
        // A 100% reserved split pointing at the hook, as the controller would build it.
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
        // Approve and deliver as the controller, with a gas cap that skips the hook's inline automation.
        vm.startPrank(address(jbController));
        IERC20(tokenAddr).approve(address(hook), amount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();
    }

    /// @notice Launches a native-ETH project with one ruleset, local cash-out scope and owner minting.
    /// @param reservedPercent The ruleset's reserved percent.
    /// @param cashOutTaxRate The ruleset's cash-out tax rate.
    /// @param weight The ruleset's issuance weight.
    /// @param duration The ruleset's duration in seconds, 0 for none.
    /// @return id The launched project's ID.
    function _launchProject(
        uint16 reservedPercent,
        uint16 cashOutTaxRate,
        uint112 weight,
        uint32 duration
    )
        internal
        returns (uint256 id)
    {
        // Owner minting lets the test mint reserved tokens on demand; local scope keeps cash-outs on this chain.
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
        // One ruleset with no weight cut, approval hook, splits or payout limits.
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = duration;
        rulesetConfigs[0].weight = weight;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);
        // The multi terminal accepts native ETH only.
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});
        // The multisig owns the project so it can mint and deploy the ERC-20.
        id = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @notice Pays `amount` of ETH into the project and returns its terminal balance after the payment.
    /// @param pid The project to pay.
    /// @param amount The ETH amount to pay.
    /// @return balAfter The project's native balance in the multi terminal after the payment.
    function _payProjectAndSnapshot(uint256 pid, uint256 amount) internal returns (uint256 balAfter) {
        // The payment gives the project real surplus, which sets the corridor's cash-out floor.
        jbMultiTerminal.pay{value: amount}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        // Snapshot the balance so later steps can prove the hook never reduces it.
        balAfter = jbTerminalStore.balanceOf({
            terminal: address(jbMultiTerminal), projectId: pid, token: JBConstants.NATIVE_TOKEN
        });
    }

    /// @notice Runs the gap-walk cycle with the TWAP pinned `anchorOffset` ticks above an aligned tick.
    /// @param anchorOffset How many ticks above an aligned tick the pinned TWAP sits.
    function _runBandEdgeCycle(int24 anchorOffset) internal {
        // A revnet-shaped project with real surplus, plus an attacker holding ETH and project tokens.
        uint256 pid =
            _launchProject({reservedPercent: 3000, cashOutTaxRate: 4000, weight: 1_000_000e18, duration: 1 days});
        vm.prank(multisig);
        IJBToken pToken =
            jbController.deployERC20For({projectId: pid, name: "Revnet Token", symbol: "RVNT", salt: bytes32(0)});
        _payProjectAndSnapshot({pid: pid, amount: 50 ether});
        address attacker = address(0xA77AC4);
        vm.deal(attacker, 10_000 ether);
        vm.prank(attacker);
        jbMultiTerminal.pay{value: 100 ether}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: 100 ether,
            beneficiary: attacker,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        _accumulateTokens({pid: pid, tokenAddr: address(pToken), amount: 500_000e18});

        // Build the exact pool key the hook derives.
        (int24 ascLower, int24 ascUpper) = _corridorOf({pid: pid, pToken: address(pToken)});
        int24 tickSpacing = hook.TICK_SPACING();
        PoolKey memory key = PoolKey({
            currency0: JBLPSplitHookHelpers.toCurrency(JBConstants.NATIVE_TOKEN),
            currency1: Currency.wrap(address(pToken)),
            fee: hook.POOL_FEE(),
            tickSpacing: tickSpacing,
            hooks: hook.oracleHook()
        });
        // An unaligned start, so the spot's own spacing gap is not the TWAP's.
        V4_POSITION_MANAGER.initializePool(
            key,
            TickMath.getSqrtPriceAtTick(
                JBLPSplitHookHelpers.alignTickToSpacing({
                        tick: ascLower + (ascUpper - ascLower) / 2, spacing: tickSpacing
                    }) + 77
            )
        );
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: V4_POOL_MANAGER, key: key});
        vm.prank(randomDeployer);
        hook.deployPool(pid);

        // The attacker approves the swap helper once for every sell in the cycle.
        BuySwapHelper swapHelper = new BuySwapHelper(V4_POOL_MANAGER);
        vm.prank(attacker);
        IERC20(address(pToken)).approve(address(swapHelper), type(uint256).max);

        // Give the hook both sides: a buyer partly fills the ask (the TWAP is pinned inside the filled part, so the ask
        // holds ETH principal; LP fees route out of the hook), then a recycle at the pinned TWAP opens the bid.
        int24 twapTick = _spotTick(key) - 100;
        _swapTo({swapHelper: swapHelper, key: key, trader: attacker, targetTick: twapTick});
        twapTick = JBLPSplitHookHelpers.alignTickToSpacing({tick: twapTick, spacing: tickSpacing}) + anchorOffset;
        _swapTo({swapHelper: swapHelper, key: key, trader: attacker, targetTick: twapTick});
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: V4_POOL_MANAGER, key: key});
        vm.prank(attacker);
        hook.addLiquidity({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
        assertTrue(
            hook.bidTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}) != 0,
            "the cycle needs a live bid"
        );

        // The TWAP stays pinned at `twapTick` for the whole attack: same-block swaps do not move it.
        uint160 twapSqrt = TickMath.getSqrtPriceAtTick(twapTick);
        uint256 valueBefore = _valueAt({who: attacker, pToken: address(pToken), sqrtPriceX96: twapSqrt});
        for (uint256 i; i < 3; i++) {
            // Walk to the band's top edge, where the project token is cheapest, and buy from the ask there.
            _walkTo({swapHelper: swapHelper, key: key, trader: attacker, pid: pid, targetTick: twapTick + 200});
            _swapTo({swapHelper: swapHelper, key: key, trader: attacker, targetTick: twapTick + 100});
            vm.prank(attacker);
            hook.addLiquidity({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
            // Walk to the bottom edge, where the project token is dearest, and sell into the bid there.
            _walkTo({swapHelper: swapHelper, key: key, trader: attacker, pid: pid, targetTick: twapTick - 200});
            _swapTo({swapHelper: swapHelper, key: key, trader: attacker, targetTick: twapTick - 100});
            vm.prank(attacker);
            hook.addLiquidity({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
        }
        // Return the spot to the TWAP before valuing the attacker's holdings.
        _walkTo({swapHelper: swapHelper, key: key, trader: attacker, pid: pid, targetTick: twapTick});

        // Valued at the TWAP, the attacker ends with no more than it started with.
        uint256 valueAfter = _valueAt({who: attacker, pToken: address(pToken), sqrtPriceX96: twapSqrt});
        emit log_named_int("  attacker P&L at TWAP (wei)", int256(valueAfter) - int256(valueBefore));
        assertLe(valueAfter, valueBefore, "cycling recycles across the TWAP band must not profit the attacker");
    }

    /// @notice Moves the spot to exactly `targetTick` with an unbounded exact-input swap capped by the price limit.
    /// @param swapHelper The helper that executes the swap.
    /// @param key The pool to swap in.
    /// @param trader The account that pays for and receives the swap.
    /// @param targetTick The tick the spot ends on.
    function _swapTo(BuySwapHelper swapHelper, PoolKey memory key, address trader, int24 targetTick) internal {
        // Nothing to do when the spot already sits on the target.
        int24 spotTick = _spotTick(key);
        if (spotTick == targetTick) return;
        // Selling ETH lowers the tick, selling project tokens raises it.
        bool zeroForOne = targetTick < spotTick;
        vm.prank(trader);
        // The input amount is far larger than any range needs, so the price limit is what stops the swap.
        swapHelper.swapTo{value: zeroForOne ? 1000 ether : 0}({
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: zeroForOne ? -int256(1000 ether) : -int256(1e30),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick)
        });
    }

    /// @notice Moves the spot to `targetTick` one spacing at a time: each step trades one tick past the next aligned
    /// boundary and recycles, which re-opens an empty gap the spot then crosses for free.
    /// @param swapHelper The helper that executes the swaps.
    /// @param key The pool to swap in.
    /// @param trader The account that swaps and recycles.
    /// @param pid The project whose positions are recycled after each step.
    /// @param targetTick The tick the spot ends on.
    function _walkTo(
        BuySwapHelper swapHelper,
        PoolKey memory key,
        address trader,
        uint256 pid,
        int24 targetTick
    )
        internal
    {
        int24 spacing = hook.TICK_SPACING();
        while (true) {
            // Stop stepping once the target sits inside the spot's own spacing.
            int24 spotFloor = JBLPSplitHookHelpers.alignTickToSpacing({tick: _spotTick(key), spacing: spacing});
            if (targetTick >= spotFloor && targetTick <= spotFloor + spacing) break;
            // Step one tick past the next boundary toward the target, then recycle around the new spot.
            _swapTo({
                swapHelper: swapHelper,
                key: key,
                trader: trader,
                targetTick: targetTick > spotFloor ? spotFloor + spacing + 1 : spotFloor - 1
            });
            vm.prank(trader);
            hook.addLiquidity({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
        }
        // Land on the target and recycle there.
        _swapTo({swapHelper: swapHelper, key: key, trader: trader, targetTick: targetTick});
        vm.prank(trader);
        hook.addLiquidity({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN});
    }

    /// @notice Asserts the ask (project = currency1) rests at or below the spot and never past the cash-out floor. Its
    /// upper bound may equal the spot price exactly (a spot exactly on an aligned tick), where it still holds only
    /// currency1.
    /// @param tokenId The ask position's token ID.
    /// @param key The pool the position belongs to.
    /// @param ascLower The corridor's lower tick (the issuance ceiling).
    /// @param ascUpper The corridor's upper tick (the cash-out floor).
    function _assertAskBelowSpot(uint256 tokenId, PoolKey memory key, int24 ascLower, int24 ascUpper) internal view {
        // Compare the range against the live spot and the corridor.
        (int24 tickLower, int24 tickUpper) = _ticksOf(tokenId);
        (uint160 spot,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        assertLe(TickMath.getSqrtPriceAtTick(tickUpper), spot, "ask must rest at or below the spot");
        assertGe(tickLower, ascLower, "ask must not reach past the issuance ceiling");
        assertLe(tickUpper, ascUpper, "ask must not sell below the cash-out floor");
    }

    /// @notice Asserts the bid (terminal = currency0) rests at or above the spot and never past the issuance ceiling.
    /// Its lower bound may equal the spot price exactly (a spot exactly on an aligned tick, where the ask touches the
    /// same tick), where it still holds only currency0.
    /// @param tokenId The bid position's token ID.
    /// @param key The pool the position belongs to.
    /// @param ascLower The corridor's lower tick (the issuance ceiling).
    /// @param ascUpper The corridor's upper tick (the cash-out floor).
    function _assertBidAboveSpot(uint256 tokenId, PoolKey memory key, int24 ascLower, int24 ascUpper) internal view {
        // Compare the range against the live spot and the corridor.
        (int24 tickLower, int24 tickUpper) = _ticksOf(tokenId);
        (uint160 spot,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        assertGe(TickMath.getSqrtPriceAtTick(tickLower), spot, "bid must rest at or above the spot");
        assertGe(tickLower, ascLower, "bid must not buy above the issuance ceiling");
        assertLe(tickUpper, ascUpper, "bid must not reach past the cash-out floor");
    }

    /// @notice The project's live corridor, computed with the same linked math the hook uses.
    /// @param pid The project whose corridor is read.
    /// @param pToken The project's ERC-20.
    /// @return ascLower The corridor's lower tick (the issuance ceiling).
    /// @return ascUpper The corridor's upper tick (the cash-out floor).
    function _corridorOf(uint256 pid, address pToken) internal view returns (int24 ascLower, int24 ascUpper) {
        // Read the current ruleset, which sets the issuance price and the cash-out tax.
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

    /// @notice The token0/token1 amounts a position of `liquidity` across `[tickLower, tickUpper]` holds at
    /// `sqrtPriceX96`. Mirrors `JBUniswapV4LPSplitHook._positionPrincipal` exactly (v4-periphery's `LiquidityAmounts`
    /// only exposes the inverse `getLiquidityForAmounts`), so this test derives the SAME principal reading the hook
    /// itself uses for its burn-slippage floor.
    /// @param sqrtPriceX96 The price to value the position at.
    /// @param tickLower The position's lower tick.
    /// @param tickUpper The position's upper tick.
    /// @param liquidity The position's liquidity.
    /// @return amount0 The currency0 the position holds, rounded down.
    /// @return amount1 The currency1 the position holds, rounded down.
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
            // At or below the range, the position is all currency0.
            amount0 = SqrtPriceMath.getAmount0Delta({
                sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
            });
        } else if (sqrtPriceX96 < sqrtB) {
            // Inside the range, currency0 covers the part above the price and currency1 the part below.
            amount0 = SqrtPriceMath.getAmount0Delta({
                sqrtPriceAX96: sqrtPriceX96, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
            });
            amount1 = SqrtPriceMath.getAmount1Delta({
                sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtPriceX96, liquidity: liquidity, roundUp: false
            });
        } else {
            // At or above the range, the position is all currency1.
            amount1 = SqrtPriceMath.getAmount1Delta({
                sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
            });
        }
    }

    /// @notice A hook position's principal at the live spot.
    /// @param tokenId The position's token ID.
    /// @param key The pool the position belongs to.
    /// @return amount0 The currency0 the position holds at the spot.
    /// @return amount1 The currency1 the position holds at the spot.
    function _principalOf(uint256 tokenId, PoolKey memory key)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        // Value the position's live range and liquidity at the live spot.
        (int24 tickLower, int24 tickUpper) = _ticksOf(tokenId);
        (uint160 spot,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        return _positionPrincipal({
            sqrtPriceX96: spot,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: V4_POSITION_MANAGER.getPositionLiquidity(tokenId)
        });
    }

    /// @notice The spot tick exactly as the hook reads it (from the sqrt price, not slot0's crossing-adjusted tick).
    /// @param key The pool to read.
    /// @return tick The tick at the pool's current sqrt price.
    function _spotTick(PoolKey memory key) internal view returns (int24 tick) {
        // Derive the tick from the sqrt price so a spot sitting exactly on a boundary reads the same as in the hook.
        (uint160 sqrtPriceX96,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice The live tick range of a hook position, read from the PositionManager.
    /// @param tokenId The position's token ID.
    /// @return tickLower The position's lower tick.
    /// @return tickUpper The position's upper tick.
    function _ticksOf(uint256 tokenId) internal view returns (int24 tickLower, int24 tickUpper) {
        // The PositionManager packs the range into the position's info word.
        (, PositionInfo info) = V4_POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        return (info.tickLower(), info.tickUpper());
    }

    /// @notice `who`'s ETH plus project tokens valued in ETH at `sqrtPriceX96` (project = currency1).
    /// @param who The account to value.
    /// @param pToken The project's ERC-20.
    /// @param sqrtPriceX96 The price, in currency1 per currency0, to value the project tokens at.
    /// @return value The account's total value in wei.
    function _valueAt(address who, address pToken, uint160 sqrtPriceX96) internal view returns (uint256 value) {
        // Divide the token count by the price (sqrtPrice squared, in Q96) to convert it to ETH.
        uint256 tokens = IERC20(pToken).balanceOf(who);
        return who.balance + FullMath.mulDiv(FullMath.mulDiv(tokens, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }
}
