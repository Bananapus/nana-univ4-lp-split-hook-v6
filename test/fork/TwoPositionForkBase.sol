// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkDeployHelper} from "../helpers/ForkDeployHelper.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
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

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBLPSplitHookHelpers} from "../../src/libraries/JBLPSplitHookHelpers.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

/// @notice A third-party LP that adds liquidity straight through the PoolManager and settles both currencies from its
/// own balances (native ETH or an ERC-20 it holds), so it can occupy a range on either side of the spot.
contract ThirdPartyLP is IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    receive() external payable {}

    function add(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) external {
        poolManager.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only pool manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint256));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: int256(liquidity),
                salt: 0
            }),
            ""
        );
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount >= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-amount));
        if (Currency.unwrap(currency) == address(0)) {
            poolManager.settle{value: owed}();
        } else {
            poolManager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(poolManager), owed), "transfer failed");
            poolManager.settle();
        }
    }
}

/// @notice Shared real-mainnet setup for two-position LP split hook fork tests: JB core from source, a fee project, a
/// hook clone wired to the real Uniswap V4 PoolManager/PositionManager and a passive oracle hook whose TWAP read is
/// mocked to the spot. Holds only helpers; tests live in the inheriting contracts.
abstract contract TwoPositionForkBase is ForkDeployHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    address constant NATIVE = JBConstants.NATIVE_TOKEN;

    JBUniswapV4LPSplitHook hook;
    uint256 feeProjectId;

    receive() external payable {}

    function setUp() public virtual {
        vm.createSelectFork("ethereum", 21_700_000);
        _deployJBCore();

        feeProjectId = _launchProject({reservedPercent: 0, weight: 1_000_000e18});
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

    /// @notice The hook's pool key for a native-ETH pair (ETH always sorts as currency0).
    function _keyOf(address pToken) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(pToken),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
    }

    /// @notice The spot tick exactly as the hook reads it (from the sqrt price).
    function _spotTick(PoolKey memory key) internal view returns (int24) {
        (uint160 sqrtPriceX96,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice The project's live corridor, computed with the same linked math the hook uses.
    function _corridorOf(uint256 pid, address pToken) internal view returns (int24, int24) {
        (JBRuleset memory ruleset,) = jbController.currentRulesetOf(pid);
        return JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: jbDirectory,
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: pid,
            terminalToken: NATIVE,
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

    /// @notice The fees a position has accrued but not collected, exactly as `Pool` computes them on its next touch.
    function _feesOf(uint256 tokenId, PoolKey memory key) internal view returns (uint256 fee0, uint256 fee1) {
        (int24 tickLower, int24 tickUpper) = _ticksOf(tokenId);
        (uint128 liquidity, uint256 last0, uint256 last1) = V4_POOL_MANAGER.getPositionInfo(
            key.toId(), address(V4_POSITION_MANAGER), tickLower, tickUpper, bytes32(tokenId)
        );
        (uint256 inside0, uint256 inside1) = V4_POOL_MANAGER.getFeeGrowthInside(key.toId(), tickLower, tickUpper);
        unchecked {
            fee0 = FullMath.mulDiv(inside0 - last0, liquidity, 1 << 128);
            fee1 = FullMath.mulDiv(inside1 - last1, liquidity, 1 << 128);
        }
    }

    /// @notice What burning a position returns at the live spot: `Pool.modifyLiquidity` rounds a removal down.
    function _principalOf(uint256 tokenId, PoolKey memory key)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (int24 tickLower, int24 tickUpper) = _ticksOf(tokenId);
        (uint160 spot,,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
        uint160 sqrtLow = spot < sqrtA ? sqrtA : spot > sqrtB ? sqrtB : spot;
        amount0 = SqrtPriceMath.getAmount0Delta({
            sqrtPriceAX96: sqrtLow, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
        });
        amount1 = SqrtPriceMath.getAmount1Delta({
            sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtLow, liquidity: liquidity, roundUp: false
        });
    }

    /// @notice Launch a native-ETH project with zero cash-out tax, local cash-out scope and owner minting.
    function _launchProject(uint16 reservedPercent, uint112 weight) internal returns (uint256 id) {
        return _launchProjectWith({
            reservedPercent: reservedPercent,
            weight: weight,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });
    }

    /// @notice `_launchProject` with the given split groups and fund access limits.
    function _launchProjectWith(
        uint16 reservedPercent,
        uint112 weight,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        internal
        returns (uint256 id)
    {
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = jbMultiTerminal;
        return _launchProjectOn({
            reservedPercent: reservedPercent,
            weight: weight,
            splitGroups: splitGroups,
            fundAccessLimitGroups: fundAccessLimitGroups,
            terminals: terminals
        });
    }

    /// @notice `_launchProjectWith` on the given terminals, each accepting native ETH.
    function _launchProjectOn(
        uint16 reservedPercent,
        uint112 weight,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups,
        IJBTerminal[] memory terminals
    )
        internal
        returns (uint256 id)
    {
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].weight = weight;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            baseCurrency: uint32(uint160(NATIVE)),
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
        rulesetConfigs[0].splitGroups = splitGroups;
        rulesetConfigs[0].fundAccessLimitGroups = fundAccessLimitGroups;
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        tokensToAccept[0] = JBAccountingContext({token: NATIVE, decimals: 18, currency: uint32(uint160(NATIVE))});
        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](terminals.length);
        for (uint256 i; i < terminals.length; i++) {
            terminalConfigs[i] = JBTerminalConfig({terminal: terminals[i], accountingContextsToAccept: tokensToAccept});
        }
        id = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @notice Deliver `amount` freshly minted project tokens to the hook as a reserved-token split, intake only.
    function _accumulateTokens(uint256 pid, address pToken, uint256 amount) internal {
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: amount, beneficiary: address(jbController), memo: "", useReservedPercent: false
        });
        JBSplitHookContext memory context = JBSplitHookContext({
            token: pToken,
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
        IERC20(pToken).approve(address(hook), amount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();
    }

    function _pay(uint256 pid, uint256 amount) internal {
        jbMultiTerminal.pay{value: amount}({
            projectId: pid,
            token: NATIVE,
            amount: amount,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    /// @notice `tick` aligned down to the spacing, then 77 ticks off the grid so a spot set there never sits on a
    /// bound.
    function _offGrid(int24 tick) internal view returns (int24) {
        return JBLPSplitHookHelpers.alignTickToSpacing({tick: tick, spacing: hook.TICK_SPACING()}) + 77;
    }
}
