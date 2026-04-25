// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// JB core -- deploy fresh within fork.
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBRulesets} from "@bananapus/core-v6/src/JBRulesets.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";
import {JBSplits} from "@bananapus/core-v6/src/JBSplits.sol";
import {JBPrices} from "@bananapus/core-v6/src/JBPrices.sol";
import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBFundAccessLimits} from "@bananapus/core-v6/src/JBFundAccessLimits.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

// Uniswap V4.
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// Hook under test.
import {LibClone} from "solady/src/utils/LibClone.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ──────────────────────────────────────────────────────────────────────────────
// SwapHelper: performs swaps inside V4 PoolManager via unlock callback
// ──────────────────────────────────────────────────────────────────────────────

contract M45SwapHelper is IUnlockCallback {
    using CurrencyLibrary for Currency;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
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
        // forge-lint: disable-next-line(named-struct-fields)
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
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountOwed = uint256(uint128(-delta0));
            if (params.key.currency0.isAddressZero()) {
                poolManager.settle{value: amountOwed}();
            } else {
                poolManager.sync(params.key.currency0);
                // forgefmt: disable-next-item
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                IERC20(Currency.unwrap(params.key.currency0)).transferFrom(params.sender, address(poolManager), amountOwed);
                poolManager.settle();
            }
        } else if (delta0 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.take(params.key.currency0, params.sender, uint256(uint128(delta0)));
        }

        if (delta1 < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountOwed = uint256(uint128(-delta1));
            if (params.key.currency1.isAddressZero()) {
                poolManager.settle{value: amountOwed}();
            } else {
                poolManager.sync(params.key.currency1);
                // forgefmt: disable-next-item
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                IERC20(Currency.unwrap(params.key.currency1)).transferFrom(params.sender, address(poolManager), amountOwed);
                poolManager.settle();
            }
        } else if (delta1 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.take(params.key.currency1, params.sender, uint256(uint128(delta1)));
        }

        return "";
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Fork tests: M-45 optimal cash-out ratio fix
// ──────────────────────────────────────────────────────────────────────────────

/// @notice Fork tests proving the M-45 fix: _computeOptimalCashOutAmount uses
///         correct Uniswap V4 amount0/amount1 ratio formulas to produce balanced
///         LP positions where both token sides are well-utilized.
///
///         The old formula was missing Q96^2 scaling, resulting in lopsided positions
///         where one token side dominated and the other was wasted. The fix applies
///         the correct getLiquidityForAmount0/getLiquidityForAmount1 derivation.
///
///         These fork tests verify with real V4 contracts that:
///         1. Deployed LP positions have non-trivial liquidity (formula works on-chain)
///         2. Swaps work in BOTH directions (proving both token sides have liquidity)
///         3. The formula works across different cashOutTaxRate configurations
contract M45_PriceRatioFork is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // Mainnet addresses.
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // JB core (deployed fresh).
    address multisig = address(0xBEEF);
    address trustedForwarder = address(0);

    JBPermissions jbPermissions;
    JBProjects jbProjects;
    JBDirectory jbDirectory;
    JBRulesets jbRulesets;
    JBTokens jbTokens;
    JBSplits jbSplits;
    JBPrices jbPrices;
    JBFundAccessLimits jbFundAccessLimits;
    JBFeelessAddresses jbFeelessAddresses;
    JBController jbController;
    JBTerminalStore jbTerminalStore;
    JBMultiTerminal jbMultiTerminal;

    // Hook under test.
    JBUniswapV4LPSplitHook hook;

    // Project state.
    uint256 feeProjectId;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);

        require(address(V4_POOL_MANAGER).code.length > 0, "PoolManager not deployed");
        require(address(V4_POSITION_MANAGER).code.length > 0, "PositionManager not deployed");

        _deployJBCore();

        // Fee project (project 1).
        feeProjectId = _launchProject({cashOutTaxRate: 0, weight: 1_000_000e18});
        require(feeProjectId == 1, "fee project must be #1");

        vm.prank(multisig);
        jbController.deployERC20For(feeProjectId, "Fee Token", "FEE", bytes32(0));

        // Pay into fee project.
        _payProject(feeProjectId, 10 ether);

        // Deploy hook.
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

    // ═══════════════════════════════════════════════════════════════════════
    // M-45: Balanced LP — swaps work in both directions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deploy pool with 50% cashOutTaxRate and verify swaps work in BOTH
    ///         directions. A balanced ratio means both token0 and token1 have liquidity
    ///         at the current price, so swapping in either direction produces non-trivial
    ///         output. An imbalanced ratio (old formula) would make one direction fail
    ///         or produce negligible output.
    function test_fork_m45_balancedLP_swapsBothDirections() public {
        uint256 pid = _launchProject({cashOutTaxRate: 5000, weight: 1_000_000e18});

        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Balanced Token", "BAL", bytes32(0));

        _payProject(pid, 50 ether);
        _accumulateTokens(pid, address(pToken), 100_000e18);

        vm.prank(multisig);
        hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);

        // Verify position has liquidity.
        uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Position should have liquidity");
        emit log_named_uint("  position liquidity", posLiq);

        // Set up swap helper.
        PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
        M45SwapHelper swapHelper = new M45SwapHelper(V4_POOL_MANAGER);

        bool projIsToken0 = Currency.unwrap(key.currency0) == address(pToken);

        // Swap 1: sell project tokens for ETH.
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

        // Swap 2: buy project tokens with ETH.
        uint256 projBefore = IERC20(address(pToken)).balanceOf(address(this));
        vm.deal(address(this), 1000 ether);
        swapHelper.swap{value: projIsToken0 ? 0 : 1 ether}(key, !projIsToken0, -int256(1 ether));
        uint256 projReceived = IERC20(address(pToken)).balanceOf(address(this)) - projBefore;
        assertTrue(projReceived > 0, "Should receive project tokens when buying with ETH");
        emit log_named_uint("  Project tokens received from 1 ETH", projReceived);
    }

    /// @notice Deploy pool with high cashOutTaxRate (90%) and verify the fixed
    ///         formula still produces a balanced LP where swaps work both directions.
    ///         High tax rates create wide tick ranges, amplifying any ratio imbalance.
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

        // Verify both swap directions work.
        PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
        M45SwapHelper swapHelper = new M45SwapHelper(V4_POOL_MANAGER);
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(pToken);

        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: 10_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });
        IERC20(address(pToken)).approve(address(swapHelper), type(uint256).max);

        // Sell project tokens.
        uint256 ethBefore = address(this).balance;
        swapHelper.swap(key, projIsToken0, -int256(5000e18));
        assertTrue(address(this).balance > ethBefore, "Should receive ETH (90% tax rate)");

        // Buy project tokens.
        uint256 projBefore = IERC20(address(pToken)).balanceOf(address(this));
        vm.deal(address(this), 1000 ether);
        swapHelper.swap{value: projIsToken0 ? 0 : 1 ether}(key, !projIsToken0, -int256(1 ether));
        assertTrue(
            IERC20(address(pToken)).balanceOf(address(this)) > projBefore, "Should receive tokens (90% tax rate)"
        );
    }

    /// @notice Deploy pool with low cashOutTaxRate (10%) and verify balanced LP.
    ///         Low tax rates create narrow tick ranges, making the position more
    ///         sensitive to ratio accuracy.
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

        // Verify both swap directions work.
        PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
        M45SwapHelper swapHelper = new M45SwapHelper(V4_POOL_MANAGER);
        bool projIsToken0 = Currency.unwrap(key.currency0) == address(pToken);

        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: 10_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });
        IERC20(address(pToken)).approve(address(swapHelper), type(uint256).max);

        // Sell project tokens.
        uint256 ethBefore = address(this).balance;
        swapHelper.swap(key, projIsToken0, -int256(5000e18));
        assertTrue(address(this).balance > ethBefore, "Should receive ETH (10% tax rate)");

        // Buy project tokens.
        uint256 projBefore = IERC20(address(pToken)).balanceOf(address(this));
        vm.deal(address(this), 1000 ether);
        swapHelper.swap{value: projIsToken0 ? 0 : 1 ether}(key, !projIsToken0, -int256(1 ether));
        assertTrue(
            IERC20(address(pToken)).balanceOf(address(this)) > projBefore, "Should receive tokens (10% tax rate)"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INTERNAL DEPLOYMENT HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _deployJBCore() internal {
        jbPermissions = new JBPermissions(trustedForwarder);
        jbProjects = new JBProjects(multisig, address(0), trustedForwarder);
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        JBERC20 jbErc20 = new JBERC20(jbPermissions, jbProjects);
        jbTokens = new JBTokens(jbDirectory, jbErc20);
        jbRulesets = new JBRulesets(jbDirectory);
        jbPrices = new JBPrices(jbDirectory, jbPermissions, jbProjects, multisig, trustedForwarder);
        jbSplits = new JBSplits(jbDirectory);
        jbFundAccessLimits = new JBFundAccessLimits(jbDirectory);
        jbFeelessAddresses = new JBFeelessAddresses(multisig);

        jbController = new JBController(
            jbDirectory,
            jbFundAccessLimits,
            jbPermissions,
            jbPrices,
            jbProjects,
            jbRulesets,
            jbSplits,
            jbTokens,
            address(0),
            trustedForwarder
        );

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);

        jbTerminalStore = new JBTerminalStore(jbDirectory, jbPrices, jbRulesets);

        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses,
            jbPermissions,
            jbProjects,
            jbSplits,
            jbTerminalStore,
            jbTokens,
            PERMIT2,
            trustedForwarder
        );

        vm.deal(address(this), 10_000 ether);
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
