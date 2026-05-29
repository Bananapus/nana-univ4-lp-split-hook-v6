// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

/// @notice Harness that exposes `_getCashOutRate` for direct testing.
contract CashOutRateHook is JBUniswapV4LPSplitHook {
    constructor(
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        IAllowanceTransfer _permit2,
        IJBSuckerRegistry _suckerRegistry
    )
        JBUniswapV4LPSplitHook(_directory, _permissions, _tokens, _permit2, _suckerRegistry, address(0))
    {}

    // forge-lint: disable-next-line(mixed-case-function)
    function exposed_getCashOutRate(
        uint256 projectId,
        address terminalToken,
        address controller_,
        JBRuleset memory ruleset
    )
        external
        view
        returns (uint256)
    {
        return JBUniswapV4LPSplitHookMath.getCashOutRate(
            IJBDirectory(DIRECTORY), SUCKER_REGISTRY, projectId, terminalToken, controller_, ruleset
        );
    }
}

/// @notice Regression test for `scopeCashOutsToLocalBalances` in JBUniswapV4LPSplitHook (Consumer 4).
/// @dev References TEST_IMPROVEMENT_PLAN.md Section 8.2, Consumer 4.
///      When scopeCashOutsToLocalBalances=true, `_getCashOutRate` uses `currentTotalReclaimableSurplusOf`
///      (local-only path). When false, it manually aggregates remote surplus via SUCKER_REGISTRY.
contract ScopeCashOutsLPHookTest is LPSplitHookV4TestBase {
    CashOutRateHook internal cashOutHook;

    address constant SUCKER_REGISTRY_ADDR = address(0xABCD);
    uint256 constant REMOTE_SUPPLY = 500e18;
    uint256 constant REMOTE_SURPLUS = 10e18;

    function setUp() public override {
        super.setUp();

        vm.etch(SUCKER_REGISTRY_ADDR, hex"00");

        cashOutHook = new CashOutRateHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3),
            IJBSuckerRegistry(SUCKER_REGISTRY_ADDR)
        );
        cashOutHook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(0))
        });

        // Mock controller.totalTokenSupplyWithReservedTokensOf (needed for unscoped path)
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.totalTokenSupplyWithReservedTokensOf.selector, PROJECT_ID),
            abi.encode(uint256(1000e18))
        );

        // Mock sucker registry remote values
        vm.mockCall(
            SUCKER_REGISTRY_ADDR,
            abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, PROJECT_ID),
            abi.encode(REMOTE_SUPPLY)
        );
        vm.mockCall(
            SUCKER_REGISTRY_ADDR,
            abi.encodeWithSelector(IJBSuckerRegistry.remoteSurplusOf.selector),
            abi.encode(REMOTE_SURPLUS)
        );
    }

    /// @notice Build a JBRuleset with the given scope flag.
    function _buildRuleset(bool scopeToLocal) internal view returns (JBRuleset memory) {
        // Pack metadata: cashOutTaxRate = 5000 (50%), scopeCashOutsToLocalBalances = scopeToLocal
        uint256 metadata;
        // reservedPercent (16 bits) = 0, cashOutTaxRate (16 bits) = 5000, baseCurrency (32 bits) = 1
        metadata = 5000 << 16; // cashOutTaxRate at bits 16-31
        metadata |= uint256(1) << 32; // baseCurrency at bits 32-63
        if (scopeToLocal) {
            metadata |= uint256(1) << 79; // scopeCashOutsToLocalBalances at bit 79
        }

        return JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata
        });
    }

    /// @notice Unscoped path calls sucker registry for remote values.
    function test_unscopedPath_callsSuckerRegistry() public {
        JBRuleset memory rulesetUnscoped = _buildRuleset(false);

        // Expect the unscoped path to call remoteTotalSupplyOf and remoteSurplusOf
        vm.expectCall(
            SUCKER_REGISTRY_ADDR, abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, PROJECT_ID)
        );

        uint256 rate = cashOutHook.exposed_getCashOutRate(
            PROJECT_ID, address(terminalToken), address(controller), rulesetUnscoped
        );

        assertGt(rate, 0, "unscoped rate should be non-zero");
    }

    /// @notice Scoped path does NOT call sucker registry — uses local-only surplus.
    function test_scopedPath_doesNotCallSuckerRegistry() public {
        JBRuleset memory rulesetScoped = _buildRuleset(true);

        // Clear any sucker registry mocks — if the scoped path tries to call them, it will revert
        vm.mockCallRevert(
            SUCKER_REGISTRY_ADDR,
            abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, PROJECT_ID),
            "should not call remoteTotalSupplyOf in scoped path"
        );

        // Scoped path should succeed without touching the sucker registry
        uint256 rate =
            cashOutHook.exposed_getCashOutRate(PROJECT_ID, address(terminalToken), address(controller), rulesetScoped);

        assertGt(rate, 0, "scoped rate should be non-zero");
    }

    /// @notice When no suckers exist (remote = 0), both flag states produce the same rate.
    function test_noSuckers_flagDoesNotAffectRate() public {
        // Override remote values to zero
        vm.mockCall(
            SUCKER_REGISTRY_ADDR,
            abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, PROJECT_ID),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            SUCKER_REGISTRY_ADDR,
            abi.encodeWithSelector(IJBSuckerRegistry.remoteSurplusOf.selector),
            abi.encode(uint256(0))
        );

        JBRuleset memory rulesetScoped = _buildRuleset(true);
        JBRuleset memory rulesetUnscoped = _buildRuleset(false);

        uint256 rateScoped =
            cashOutHook.exposed_getCashOutRate(PROJECT_ID, address(terminalToken), address(controller), rulesetScoped);
        uint256 rateUnscoped = cashOutHook.exposed_getCashOutRate(
            PROJECT_ID, address(terminalToken), address(controller), rulesetUnscoped
        );

        assertEq(rateScoped, rateUnscoped, "no suckers: both flag states should produce identical rates");
    }
}
