// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkDeployHelper} from "../helpers/ForkDeployHelper.sol";
import {Vm} from "forge-std/Vm.sol";
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
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4Hook} from "@bananapus/univ4-router-v6/src/JBUniswapV4Hook.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";

/// @notice A swap helper that routes through the PoolManager (and therefore through any hooks on the pool key),
/// honoring a caller-supplied `sqrtPriceLimitX96` and passing `hookData` (the JBUniswapV4Hook requires the first
/// 32 bytes to encode `amountOutMin`). Settles whichever side it owes; takes whatever it is owed.
contract RoutingSwapHelper is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    struct SwapCallbackData {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
        address sender;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    receive() external payable {}

    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData
    )
        external
        payable
        returns (BalanceDelta delta)
    {
        bytes memory res = poolManager.unlock(
            abi.encode(SwapCallbackData(key, zeroForOne, amountSpecified, sqrtPriceLimitX96, hookData, msg.sender))
        );
        delta = abi.decode(res, (BalanceDelta));
        // Refund any ETH the swap did not consume so the caller's net cost reflects only the real spend (gas aside).
        if (address(this).balance > 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "refund failed");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only pool manager");
        SwapCallbackData memory p = abi.decode(data, (SwapCallbackData));
        BalanceDelta delta = poolManager.swap(
            p.key,
            SwapParams({
                zeroForOne: p.zeroForOne, amountSpecified: p.amountSpecified, sqrtPriceLimitX96: p.sqrtPriceLimitX96
            }),
            p.hookData
        );

        _settleOrTake(p.key.currency0, delta.amount0(), p.sender);
        _settleOrTake(p.key.currency1, delta.amount1(), p.sender);

        return abi.encode(delta);
    }

    function _settleOrTake(Currency currency, int128 amount, address sender) private {
        if (amount < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(currency);
                require(
                    IERC20(Currency.unwrap(currency)).transferFrom(sender, address(poolManager), owed),
                    "TRANSFER_FROM_FAILED"
                );
                poolManager.settle();
            }
        } else if (amount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owedToUs = uint256(uint128(amount));
            poolManager.take(currency, sender, owedToUs);
        }
    }
}

/// @notice Definitively answers: can a permissionless "reprice" swap move an out-of-band squatted LP-split-hook pool
/// back INTO the project's [cashOutFloor, issuance] band so that `deployPool` then succeeds — on the REAL Uniswap V4
/// PoolManager + the REAL JBUniswapV4Hook routing oracle?
contract SquatRepriceFork is ForkDeployHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    JBUniswapV4LPSplitHook hook;
    IHooks realOracleHook;
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

        // Deploy the REAL routing oracle hook (JBUniswapV4Hook) at a flag-valid mined address. This is the contract
        // whose `_beforeSwap` decides V4-vs-Juicebox routing — the crux of the hypothesis. (The other fork harnesses
        // use a passive MockGeomeanOracle that NEVER intercepts swaps, which would not exercise routing.)
        realOracleHook = _deployRealOracleHook();

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
            newOracleHook: realOracleHook,
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });
    }

    /// @notice Squat ABOVE the issuance ceiling, then reprice DOWN into the band; deployPool must then succeed.
    function test_fork_squatAboveIssuance_repriceDownThenDeploy() public {
        _runSquatRepriceCase({squatAbove: true});
    }

    /// @notice Squat BELOW the cash-out floor, then reprice UP into the band; deployPool must then succeed.
    function test_fork_squatBelowFloor_repriceUpThenDeploy() public {
        _runSquatRepriceCase({squatAbove: false});
    }

    function _runSquatRepriceCase(bool squatAbove) internal {
        // A project with reserved tokens (10%) + real ETH surplus so the band is a finite [cashOut, issuance] corridor.
        uint256 pid = _launchProject({reservedPercent: 1000, cashOutTaxRate: 2500, weight: 1_000_000e18});
        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Squat Token", "SQT", bytes32(0));
        address projectToken = address(pToken);
        _payProject(pid, 50 ether);
        _accumulateTokens(pid, projectToken, 200_000e18);

        // --- Compute the project's economic band from the live LP-hook math (same call deployPool validates against).
        address controller = address(jbDirectory.controllerOf(pid));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(pid);
        (int24 tickLower, int24 tickUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(jbDirectory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: pid,
            terminalToken: JBConstants.NATIVE_TOKEN,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        emit log_named_int("band tickLower", tickLower);
        emit log_named_int("band tickUpper", tickUpper);
        emit log_named_uint("band sqrtPriceLower", sqrtPriceLower);
        emit log_named_uint("band sqrtPriceUpper", sqrtPriceUpper);

        // --- Build the deterministic PoolKey exactly as the LP hook will (fee=POOL_FEE, tickSpacing=TICK_SPACING,
        // hooks=realOracleHook), with V4 currency sorting (native ETH == Currency address(0)).
        Currency terminalCurrency = Currency.wrap(address(0)); // native ETH for V4
        Currency projectCurrency = Currency.wrap(projectToken);
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: realOracleHook
        });
        PoolId poolId = key.toId();
        bool ethIsToken0 = Currency.unwrap(currency0) == address(0);
        emit log_named_string("eth is token0", ethIsToken0 ? "true" : "false");

        // --- SQUAT: initialize the deterministic pool out of band.
        // Pick a squat tick one full spacing OUTSIDE the band on the requested side and initialize there.
        int24 spacing = hook.TICK_SPACING();
        int24 squatTick = squatAbove ? (tickUpper + spacing * 2) : (tickLower - spacing * 2);
        // Clamp to V4's valid tick range (align to spacing; divide-before-multiply is the intended flooring).
        // forge-lint: disable-next-line(divide-before-multiply)
        if (squatTick > TickMath.MAX_TICK) squatTick = (TickMath.MAX_TICK / spacing) * spacing;
        // forge-lint: disable-next-line(divide-before-multiply)
        if (squatTick < TickMath.MIN_TICK) squatTick = (TickMath.MIN_TICK / spacing) * spacing;
        uint160 squatSqrtPrice = TickMath.getSqrtPriceAtTick(squatTick);

        address squatter = makeAddr("squatter");
        vm.prank(squatter);
        V4_POSITION_MANAGER.initializePool({key: key, sqrtPriceX96: squatSqrtPrice});

        (uint160 spotBefore, int24 tickBefore,,) = V4_POOL_MANAGER.getSlot0(poolId);
        emit log_named_uint("squat sqrtPrice (spot before reprice)", spotBefore);
        emit log_named_int("squat tick (before reprice)", tickBefore);
        require(spotBefore != 0, "squat init failed");
        // Confirm it really is out of band on the requested side.
        if (squatAbove) {
            require(spotBefore >= sqrtPriceUpper, "squat not above band");
        } else {
            require(spotBefore <= sqrtPriceLower, "squat not below band");
        }

        // --- deployPool must REVERT now (out-of-band squat).
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds.selector,
                spotBefore,
                sqrtPriceLower,
                sqrtPriceUpper
            )
        );
        hook.deployPool(pid, 0);

        // --- REPRICE: a fresh keeper/attacker performs the toward-band swap with amountOutMin=0 and a sqrtPriceLimit
        // set to a mid-band target. We choose direction so the swap moves price toward the band:
        //   - to LOWER price → zeroForOne = true  (input token0)
        //   - to RAISE price → zeroForOne = false (input token1)
        // squatAbove means spot >= sqrtPriceUpper, so we need price to DECREASE → zeroForOne = true.
        // squatBelow means spot <= sqrtPriceLower, so we need price to INCREASE → zeroForOne = false.
        bool zeroForOne = squatAbove; // decrease price when squatted above; increase when squatted below

        // Mid-band sqrt price target as the swap's price limit.
        uint160 midBandSqrtPrice = uint160((uint256(sqrtPriceLower) + uint256(sqrtPriceUpper)) / 2);

        address keeper = makeAddr("keeper");
        RoutingSwapHelper swapHelper = new RoutingSwapHelper(V4_POOL_MANAGER);

        // Fund the keeper with the INPUT token and record balances to measure net cost.
        // Input token is token0 when zeroForOne, else token1.
        Currency inputCurrency = zeroForOne ? currency0 : currency1;
        bool inputIsEth = inputCurrency.isAddressZero();

        uint256 keeperEthBefore;
        uint256 keeperProjBefore;
        uint256 fundAmount = 10_000e18; // generous input cap; a price-limited swap on an empty pool consumes ~0

        if (inputIsEth) {
            vm.deal(keeper, 100 ether);
            fundAmount = 100 ether;
        } else {
            // Input is the project token. Mint it to the keeper (simulates an attacker who holds project tokens).
            vm.prank(multisig);
            jbController.mintTokensOf({
                projectId: pid, tokenCount: fundAmount, beneficiary: keeper, memo: "", useReservedPercent: false
            });
        }
        keeperEthBefore = keeper.balance;
        keeperProjBefore = IERC20(projectToken).balanceOf(keeper);

        // Keeper approves the helper to pull the input token (for the settle path).
        vm.prank(keeper);
        IERC20(projectToken).approve(address(swapHelper), type(uint256).max);

        // hookData: first 32 bytes = amountOutMin = 0 (the routing oracle requires >=32 bytes of hookData).
        bytes memory hookData = abi.encode(uint256(0));

        // Perform the reprice swap as the keeper. Exact-input (negative amountSpecified), full fund amount, but the
        // sqrtPriceLimit caps how far the price can move (mid-band), so on an empty pool the swap consumes ~0.
        vm.recordLogs();
        vm.prank(keeper);
        BalanceDelta delta = swapHelper.swap{value: inputIsEth ? fundAmount : 0}({
            key: key,
            zeroForOne: zeroForOne,
            // fundAmount is a small bounded test constant, well within int256 range.
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(fundAmount),
            sqrtPriceLimitX96: midBandSqrtPrice,
            hookData: hookData
        });
        emit log_named_int("swap delta amount0", delta.amount0());
        emit log_named_int("swap delta amount1", delta.amount1());

        // --- PROVE the swap actually ran through the REAL routing oracle and the oracle chose the V4 curve (not JB).
        // The oracle's `_beforeSwap` emits BestRouteSelected(poolId, routeType, expectedTokens, caller); routeType==0
        // means V4 was selected. If routing had gone to Juicebox, the pool spot would NOT move (JB bypasses the AMM).
        bool sawV4Route = _assertOracleChoseV4(poolId);
        assertTrue(sawV4Route, "oracle hook did not emit a V4 route decision (routing did not run as expected)");

        // --- Inspect the post-reprice spot.
        (uint160 spotAfter, int24 tickAfter,,) = V4_POOL_MANAGER.getSlot0(poolId);
        emit log_named_uint("spot AFTER reprice", spotAfter);
        emit log_named_int("tick AFTER reprice", tickAfter);

        // Assert the spot is now STRICTLY inside the band.
        assertGt(spotAfter, sqrtPriceLower, "spot not strictly above lower bound after reprice");
        assertLt(spotAfter, sqrtPriceUpper, "spot not strictly below upper bound after reprice");

        // --- Measure net token cost to the keeper (should be ~0 = gas-only).
        uint256 keeperEthAfter = keeper.balance;
        uint256 keeperProjAfter = IERC20(projectToken).balanceOf(keeper);
        emit log_named_uint("keeper ETH before", keeperEthBefore);
        emit log_named_uint("keeper ETH after", keeperEthAfter);
        emit log_named_uint("keeper PROJ before", keeperProjBefore);
        emit log_named_uint("keeper PROJ after", keeperProjAfter);

        // --- The reprice must be ~gas-only: the keeper's net token spend on either side is dust (sub-1-unit).
        // (A price-limited swap on an empty pool fills nothing — no liquidity to trade against — so deltas are 0.)
        uint256 ethSpent = keeperEthBefore > keeperEthAfter ? keeperEthBefore - keeperEthAfter : 0;
        uint256 projSpent = keeperProjBefore > keeperProjAfter ? keeperProjBefore - keeperProjAfter : 0;
        assertLe(ethSpent, 1, "keeper spent more than dust ETH on reprice");
        assertLe(projSpent, 1, "keeper spent more than dust project tokens on reprice");

        // --- deployPool must now SUCCEED.
        vm.prank(multisig);
        hook.deployPool(pid, 0);
        assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "pool should deploy after reprice");
        uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        assertTrue(tokenId != 0, "no LP position NFT after reprice + deploy");
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        emit log_named_uint("deployed LP position liquidity", posLiq);
        assertTrue(posLiq > 0, "deployed position has zero liquidity");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Scan recorded logs for the oracle hook's BestRouteSelected event for `poolId` and assert routeType==0
    /// (the oracle chose the real V4 curve, not the Juicebox bypass). Returns true if such an event was found.
    function _assertOracleChoseV4(PoolId poolId) internal returns (bool) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("BestRouteSelected(bytes32,uint8,uint256,address)");
        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter != address(realOracleHook)) continue;
            if (entries[i].topics.length < 2) continue;
            if (entries[i].topics[0] != sig) continue;
            if (entries[i].topics[1] != bytes32(PoolId.unwrap(poolId))) continue;
            // Non-indexed: (uint8 routeType, uint256 expectedTokens, address caller)
            (uint8 routeType,,) = abi.decode(entries[i].data, (uint8, uint256, address));
            emit log_named_uint("oracle BestRouteSelected routeType (0=V4,1=JB)", routeType);
            assertEq(routeType, 0, "oracle selected Juicebox, not V4: would not move the pool spot");
            found = true;
        }
        return found;
    }

    /// @notice Deploy the production JBUniswapV4Hook (routing oracle) at a flag-valid mined address.
    function _deployRealOracleHook() internal returns (IHooks) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            IPoolManager(V4_POOL_MANAGER),
            IJBTokens(address(jbTokens)),
            IJBDirectory(address(jbDirectory)),
            IJBPrices(address(jbPrices))
        );
        (address addr, bytes32 salt) = HookMiner.find({
            deployer: address(this),
            flags: flags,
            creationCode: type(JBUniswapV4Hook).creationCode,
            constructorArgs: constructorArgs
        });
        JBUniswapV4Hook deployed = new JBUniswapV4Hook{salt: salt}({
            poolManager: IPoolManager(V4_POOL_MANAGER),
            tokens: IJBTokens(address(jbTokens)),
            directory: IJBDirectory(address(jbDirectory)),
            prices: IJBPrices(address(jbPrices))
        });
        require(address(deployed) == addr, "oracle hook addr mismatch");
        return IHooks(address(deployed));
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
