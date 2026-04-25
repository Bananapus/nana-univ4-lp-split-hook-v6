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
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// Hook under test.
import {LibClone} from "solady/src/utils/LibClone.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork tests proving H-30 fix: token-order-aware zero-rate fallback prices work
///         with real Uniswap V4 contracts.
///
/// The H-30 fix changes `_getIssuanceRateSqrtPriceX96` and `_getCashOutRateSqrtPriceX96`
/// to return token-order-aware extreme prices when rates are zero. These tests verify the
/// fixed code initializes real V4 pools correctly and produces valid LP positions.
///
/// Key scenario: Native ETH (0x...EEEe) is always token0. When issuance rate is 0,
/// the old code returned MAX_SQRT_PRICE (wrong for token0-terminal), while the fix
/// returns MIN_SQRT_PRICE (correct: PT/TT -> 0 as PT becomes unmintable).
contract H30_ZeroRateFork is Test {
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

        // Fee project (project 1) -- required by hook initialization.
        feeProjectId = _launchProject({reservedPercent: 0, cashOutTaxRate: 0, weight: 1_000_000e18});
        require(feeProjectId == 1, "fee project must be #1");

        vm.prank(multisig);
        jbController.deployERC20For(feeProjectId, "Fee Token", "FEE", bytes32(0));

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
    // H-30: Zero issuance rate (100% reserved) with ETH terminal (token0)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deploy pool when issuance rate = 0 (100% reserved) and terminal is token0 (ETH).
    ///         This is the exact case H-30 fixes: the old code returned MAX_SQRT_PRICE for
    ///         the issuance fallback regardless of ordering, but ETH pools need MIN_SQRT_PRICE
    ///         because sqrtPriceX96 = sqrt(PT/TT) and PT is worthless when unmintable.
    ///
    ///         With the fix, _calculateTickBounds handles cashOutRate=0 by centering around
    ///         the issuance tick. Since issuanceRate is also 0, it produces a full-range LP.
    function test_fork_h30_zeroIssuance_100pctReserved_ethTerminal() public {
        // Launch project with 100% reserved (issuanceRate = 0) and surplus.
        uint256 pid = _launchProject({reservedPercent: 10_000, cashOutTaxRate: 5000, weight: 1_000_000e18});

        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Reserved Token", "RSV", bytes32(0));

        // Pay ETH to build surplus (cashOutRate > 0).
        _payProject(pid, 50 ether);

        // Mint tokens directly to hook (bypasses issuance weight).
        _accumulateTokens(pid, address(pToken), 100_000e18);

        // Confirm precondition: ETH is token0.
        assertTrue(uint160(JBConstants.NATIVE_TOKEN) < uint160(address(pToken)), "ETH must be token0 (lower address)");

        // Deploy pool -- exercises the H-30 fixed fallback.
        vm.prank(multisig);
        hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);

        // Verify pool deployed successfully.
        assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "Pool should deploy with 100% reserved");

        // Verify position has liquidity.
        uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        assertTrue(tokenId != 0, "Position NFT should exist");
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Position should have liquidity");

        // Verify pool price is valid.
        PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
        (uint160 sqrtPriceX96, int24 currentTick,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        assertTrue(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE, "sqrtPrice > MIN");
        assertTrue(sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "sqrtPrice < MAX");
        assertTrue(currentTick >= TickMath.MIN_TICK, "tick >= MIN_TICK");
        assertTrue(currentTick <= TickMath.MAX_TICK, "tick <= MAX_TICK");

        emit log_named_uint("  position liquidity", posLiq);
        emit log_named_int("  current tick", currentTick);
        emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // H-30: Zero issuance rate (weight=0) with ETH terminal (token0)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deploy pool when weight=0 (zero issuance) with surplus and ETH terminal.
    ///         With weight=0 and surplus > 0, cashOutRate > 0 but issuanceRate = 0.
    ///         The H-30 fix makes _getIssuanceRateSqrtPriceX96 return MIN_SQRT_PRICE
    ///         (correct for token0-terminal), placing the initial price at a valid midpoint.
    function test_fork_h30_zeroIssuance_weightZero_ethTerminal() public {
        // Launch project with weight=0 but surplus from payments.
        uint256 pid = _launchProject({reservedPercent: 1000, cashOutTaxRate: 0, weight: 0});

        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Zero Weight Token", "ZWT", bytes32(0));

        // Pay ETH to build surplus.
        _payProject(pid, 50 ether);

        // Mint tokens to hook via owner minting (weight doesn't affect owner mints).
        _accumulateTokens(pid, address(pToken), 100_000e18);

        // Deploy pool.
        vm.prank(multisig);
        hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);

        assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "Pool should deploy with weight=0");

        uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
        uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(posLiq > 0, "Position should have liquidity with weight=0");

        PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
        (uint160 sqrtPriceX96, int24 currentTick,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        assertTrue(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE, "sqrtPrice > MIN");
        assertTrue(sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "sqrtPrice < MAX");

        emit log_named_uint("  position liquidity", posLiq);
        emit log_named_int("  current tick", currentTick);
        emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // H-30: Zero surplus (cashOutRate=0) + zero issuance = full-range LP
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When both cashOutRate and issuanceRate are 0, the H-30 fix correctly sets the
    ///         initial price to MIN_SQRT_PRICE (for ETH as token0). This means the position
    ///         requires only ETH (token0) to seed, but the hook holds only project tokens,
    ///         so deployment correctly reverts with ZeroLiquidity.
    ///
    ///         Before the H-30 fix, the issuance fallback wrongly returned MAX_SQRT_PRICE,
    ///         which placed the price at the upper extreme and allowed the position to be
    ///         seeded with only project tokens. The fix exposes that this scenario truly has
    ///         no valid LP deployment: there is no surplus to pair with project tokens.
    function test_fork_h30_zeroCashOut_zeroIssuance_revertsZeroLiquidity() public {
        // Launch project with 100% reserved and NO surplus payments.
        uint256 pid = _launchProject({reservedPercent: 10_000, cashOutTaxRate: 5000, weight: 1_000_000e18});

        vm.prank(multisig);
        IJBToken pToken = jbController.deployERC20For(pid, "Full Range Token", "FRT", bytes32(0));

        // Do NOT pay into project -- no surplus, cashOutRate = 0.
        // Mint tokens directly to hook.
        _accumulateTokens(pid, address(pToken), 100_000e18);

        // Confirm precondition: ETH is token0.
        assertTrue(uint160(JBConstants.NATIVE_TOKEN) < uint160(address(pToken)), "ETH must be token0 (lower address)");

        // Deploy pool -- both rates are 0. With the H-30 fix, the initial price is at
        // MIN_SQRT_PRICE (correct for token0-terminal). The position needs ETH (token0)
        // but the hook has none, so it correctly reverts with ZeroLiquidity.
        vm.prank(multisig);
        try hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0) {
            revert("Expected ZeroLiquidity revert");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_ZeroLiquidity.selector);
        }
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
