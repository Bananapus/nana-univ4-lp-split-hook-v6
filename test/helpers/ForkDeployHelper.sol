// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// JB core contracts.
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

// JB core types used by fork tests.
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

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";
import {MockGeomeanOracle} from "../mock/MockGeomeanOracle.sol";

/// @notice Shared base contract for fork tests that deploy JB core from source.
/// Eliminates the 18-way duplication of `_deployJBCore()` across fork test files.
abstract contract ForkDeployHelper is Test {
    // ─── Canonical addresses
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address multisig = address(0xBEEF);
    address trustedForwarder = address(0);

    // ─── JB core (deployed fresh by _deployJBCore)
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

    /// @notice Deploy all JB core contracts from source.
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
            IPermit2(address(PERMIT2)),
            trustedForwarder
        );

        vm.deal(address(this), 10_000 ether);
    }

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Deploy a passive `MockGeomeanOracle` hook at a mined, flag-valid address so fork pools can embed it as
    /// their `hooks` (an arbitrary address would fail Uniswap V4's hook-permission validation at pool init).
    /// @dev Uses ONLY `AFTER_INITIALIZE_FLAG` so the hook has no swap callbacks — it never intercepts swaps, unlike
    /// the
    /// production routing oracle, so fork swap helpers keep working. The LP split hook still calls `observe` on it
    /// directly (force the TWAP via `_mockOracleTwapEqualsSpot`). Mirrors the HookMiner pattern in the router deploy.
    function _deployGeomeanOracleHook(IPoolManager) internal returns (IHooks oracle) {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG);
        (address addr, bytes32 salt) = HookMiner.find({
            deployer: address(this),
            flags: flags,
            creationCode: type(MockGeomeanOracle).creationCode,
            constructorArgs: ""
        });
        MockGeomeanOracle oracle_ = new MockGeomeanOracle{salt: salt}();
        require(address(oracle_) == addr, "ForkDeployHelper: hook addr mismatch");
        return IHooks(address(oracle_));
    }

    /// @notice Force the oracle's `observe` to report a TWAP equal to the pool's current spot tick, so the LP hook's
    /// spot-vs-TWAP guard passes deterministically without seeding 30 minutes of real observation history.
    /// @dev Call immediately before a guarded `rebalanceLiquidity`/`addLiquidity`. The real oracle still runs its V4
    /// callbacks during pool init/swaps; only the TWAP read is mocked.
    function _mockOracleTwapEqualsSpot(IHooks oracle, IPoolManager pm, PoolKey memory key) internal {
        (uint160 sqrtPriceX96,,,) = pm.getSlot0(key.toId());
        int24 spot = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // The LP hook observes a 30-minute (1800s) window; return cumulatives whose mean recovers `spot` exactly.
        int56[] memory cums = new int56[](2);
        cums[1] = int56(spot) * int56(uint56(1800));
        uint160[] memory spl = new uint160[](2);
        spl[1] = uint160(1800);
        vm.mockCall(address(oracle), abi.encodeWithSelector(IGeomeanOracle.observe.selector), abi.encode(cums, spl));
    }
}
