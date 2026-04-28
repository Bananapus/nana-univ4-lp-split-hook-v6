// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkDeployHelper} from "./helpers/ForkDeployHelper.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

contract ExposedJBUniswapV4LPSplitHook is JBUniswapV4LPSplitHook {
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IPoolManager poolManager,
        IPositionManager positionManager,
        IAllowanceTransfer permit2,
        IHooks oracleHook
    )
        JBUniswapV4LPSplitHook(directory, permissions, tokens, poolManager, positionManager, permit2, oracleHook)
    {}
    function exposed_calculateTickBounds(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        address controller,
        JBRuleset memory ruleset
    )
        external
        view
        returns (int24, int24)
    {
        return _calculateTickBounds(projectId, terminalToken, projectToken, controller, ruleset);
    }
    function exposed_computeInitialSqrtPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        address controller,
        JBRuleset memory ruleset
    )
        external
        view
        returns (uint160)
    {
        return _computeInitialSqrtPrice(projectId, terminalToken, projectToken, controller, ruleset);
    }
}
contract LPSplitHookForkTest is ForkDeployHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    JBUniswapV4LPSplitHook hook;
    uint256 feeProjectId; // Project 1 (fee recipient).
    uint256 projectId; // Project 2 (test project with LP split hook).
    IJBToken projectToken;
    receive() external payable {}
    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);
        require(address(V4_POOL_MANAGER).code.length > 0, "PoolManager not deployed");
        require(address(V4_POSITION_MANAGER).code.length > 0, "PositionManager not deployed");
        _deployJBCore();
        feeProjectId = _launchProject(false);
        require(feeProjectId == 1, "fee project must be #1");
        projectId = _launchProject(true);
        vm.prank(multisig);
        projectToken = jbController.deployERC20For(projectId, "Test Token", "TST", bytes32(0));
        jbMultiTerminal.pay{value: 10 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        ExposedJBUniswapV4LPSplitHook hookImpl = new ExposedJBUniswapV4LPSplitHook(
            address(jbDirectory),
            IJBPermissions(address(jbPermissions)),
            address(jbTokens),
            V4_POOL_MANAGER,
            V4_POSITION_MANAGER,
            IAllowanceTransfer(address(PERMIT2)),
            IHooks(address(0))
        );
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));
        hook.initialize(feeProjectId, 3800); // 38% fee to fee project.
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId,
            tokenCount: 100_000e18,
            beneficiary: address(hook),
            memo: "",
            useReservedPercent: false
        });
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(projectToken),
            amount: 100_000e18,
            decimals: 18,
            projectId: projectId,
            groupId: 1, // reserved token group
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
    function test_fork_tokensAccumulated() public view {
        assertEq(hook.accumulatedProjectTokens(projectId), 100_000e18, "should have accumulated 100k tokens");
        assertFalse(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "should not be deployed yet");
    }
    function test_fork_deployPool_createsRealV4Pool() public {
        vm.prank(multisig);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "project should be deployed");
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "pool should be deployed");
        uint256 tokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        assertTrue(tokenId != 0, "should hold a position NFT");
        assertEq(hook.accumulatedProjectTokens(projectId), 0, "accumulated should be 0 after deploy");
        PoolKey memory key = hook.poolKeyOf(projectId, JBConstants.NATIVE_TOKEN);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = V4_POOL_MANAGER.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "pool should be initialized with nonzero price");
        uint128 positionLiquidity = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(positionLiquidity > 0, "position should have liquidity");
    }
    function test_fork_burnAfterDeploy() public {
        vm.prank(multisig);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId, tokenCount: 50_000e18, beneficiary: address(hook), memo: "", useReservedPercent: false
        });
        uint256 supplyBefore = IERC20(address(projectToken)).totalSupply();
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(projectToken),
            amount: 50_000e18,
            decimals: 18,
            projectId: projectId,
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
        assertEq(hook.accumulatedProjectTokens(projectId), 0, "should not accumulate after deploy");
        uint256 supplyAfter = IERC20(address(projectToken)).totalSupply();
        assertLt(supplyAfter, supplyBefore, "total supply should decrease from burn");
    }
    function test_fork_deployPool_usesPermit2NotDirectApproval() public {
        address token = address(projectToken);
        assertEq(
            IERC20(token).allowance(address(hook), address(V4_POSITION_MANAGER)),
            0,
            "hook should have no direct allowance to PM before deploy"
        );
        assertEq(
            IERC20(token).allowance(address(hook), address(PERMIT2)),
            0,
            "hook should have no allowance to Permit2 before deploy"
        );
        vm.prank(multisig);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);
        assertEq(
            IERC20(token).allowance(address(hook), address(V4_POSITION_MANAGER)),
            0,
            "hook should never directly approve PositionManager"
        );
        uint256 tokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        uint128 liq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        assertTrue(liq > 0, "position should have liquidity via Permit2 flow");
    }
    function _launchProject(bool withOwnerMinting) internal returns (uint256 id) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: withOwnerMinting ? 1000 : 0,
            cashOutTaxRate: 0,
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
    function test_fork_deployPool_existingPoolOutsideBand_succeeds() public {
        address projToken = address(projectToken);
        Currency termCurrency = Currency.wrap(address(0)); // native ETH
        Currency projCurrency = Currency.wrap(projToken);
        (Currency currency0, Currency currency1) =
            termCurrency < projCurrency ? (termCurrency, projCurrency) : (projCurrency, termCurrency);
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
        uint160 externalSqrtPrice = TickMath.getSqrtPriceAtTick(int24(88_000));
        V4_POSITION_MANAGER.initializePool(key, externalSqrtPrice);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceBefore,,,) = V4_POOL_MANAGER.getSlot0(poolId);
        assertEq(sqrtPriceBefore, externalSqrtPrice, "pool should be at external price");
        vm.prank(multisig);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "pool should be deployed");
        assertGt(hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN), 0, "position NFT should be minted");
    }
    function test_fork_deployPool_existingPoolWithinBand_succeeds() public {
        address projToken = address(projectToken);
        Currency termCurrency = Currency.wrap(address(0)); // native ETH
        Currency projCurrency = Currency.wrap(projToken);
        (Currency currency0, Currency currency1) =
            termCurrency < projCurrency ? (termCurrency, projCurrency) : (projCurrency, termCurrency);
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
        address controller = address(jbDirectory.controllerOf(projectId));
        (JBRuleset memory ruleset,) = JBController(controller).currentRulesetOf(projectId);
        ExposedJBUniswapV4LPSplitHook exposedHook = ExposedJBUniswapV4LPSplitHook(payable(address(hook)));
        (int24 tickLower,) =
            exposedHook.exposed_calculateTickBounds(projectId, JBConstants.NATIVE_TOKEN, projToken, controller, ruleset);
        uint160 midpointSqrtPrice = exposedHook.exposed_computeInitialSqrtPrice(
            projectId, JBConstants.NATIVE_TOKEN, projToken, controller, ruleset
        );
        uint160 externalSqrtPrice = TickMath.getSqrtPriceAtTick(tickLower + hook.TICK_SPACING());
        assertTrue(externalSqrtPrice != midpointSqrtPrice, "precondition: use a non-midpoint in-band price");
        V4_POSITION_MANAGER.initializePool(key, externalSqrtPrice);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceBefore,,,) = V4_POOL_MANAGER.getSlot0(poolId);
        assertEq(sqrtPriceBefore, externalSqrtPrice, "pool should be at external price");
        vm.prank(multisig);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "pool should deploy successfully");
        assertGt(hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN), 0, "position NFT should be minted");
        assertEq(hook.accumulatedProjectTokens(projectId), 0, "accumulated tokens should be consumed");
        (uint160 sqrtPriceAfter,,,) = V4_POOL_MANAGER.getSlot0(poolId);
        assertEq(sqrtPriceAfter, sqrtPriceBefore, "existing in-band pool price should be reused");
    }
    function test_fork_deployPool_permissionlessAfterWeightDecay() public {
        JBRulesetMetadata memory newMeta = JBRulesetMetadata({
            reservedPercent: 1000,
            cashOutTaxRate: 0,
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
        JBRulesetConfig[] memory newConfigs = new JBRulesetConfig[](1);
        newConfigs[0].mustStartAtOrAfter = 0;
        newConfigs[0].duration = 1 days;
        newConfigs[0].weight = 1_000_000e18;
        newConfigs[0].weightCutPercent = 800_000_000; // 80% cut per cycle
        newConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        newConfigs[0].metadata = newMeta;
        newConfigs[0].splitGroups = new JBSplitGroup[](0);
        newConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);
        vm.prank(multisig);
        jbController.queueRulesetsOf(projectId, newConfigs, "");
        vm.warp(block.timestamp + 3 days);
        uint256 initialWeight = hook.initialWeightOf(projectId);
        assertTrue(initialWeight > 0, "initialWeightOf should be set from setUp accumulation");
        (JBRuleset memory currentRuleset,) = jbController.currentRulesetOf(projectId);
        assertTrue(currentRuleset.weight * 10 <= initialWeight, "weight should have decayed >= 10x");
        address randomUser = makeAddr("randomDeployer");
        vm.prank(randomUser);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);
        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "pool should be deployed by random user");
        uint256 tokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        assertTrue(tokenId != 0, "should hold a position NFT");
    }
    function test_fork_deployPool_requiresPermissionBeforeDecay() public {
        address randomUser = makeAddr("randomDeployer");
        vm.prank(randomUser);
        vm.expectRevert();
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);
    }
}