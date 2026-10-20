// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase, DEFAULT_SURPLUS_PER_TOKEN} from "./TestBaseV4.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";

/// @notice `deployPool` is fully permissionless: no weight-decay or owner gate applies. `initialWeightOf` is an
/// informational per-project snapshot, recorded lazily on the first successful deploy/add processing attempt (intake
/// never reads rulesets), and it gates nothing: any caller can seed the pool at any weight. The economic
/// spot-below-ceiling gate (covered by `SingleSided_PermissionlessGateTest`) is the only gate.
contract WeightDecayDeployTest is LPSplitHookV4TestBase {
    address internal randomUser;

    function setUp() public override {
        super.setUp();
        randomUser = makeAddr("randomUser");
    }

    // ─── initialWeightOf snapshot (recorded lazily)
    // ──────────────────────────────────────────────

    /// @notice initialWeightOf is not read during intake (intake must not touch rulesets); it is recorded on the
    /// first successful deploy/add processing attempt.
    function test_initialWeightOf_recordedOnFirstProcessingAttempt() public {
        // No snapshot exists before any activity.
        assertEq(hook.initialWeightOf(PROJECT_ID), 0, "should be 0 before any accumulation");

        // Intake alone leaves the snapshot unset because it never reads rulesets.
        _accumulateTokens({projectId: PROJECT_ID, amount: 100e18});
        assertEq(hook.initialWeightOf(PROJECT_ID), 0, "intake should NOT read rulesets");

        // The first deploy reads the ruleset and records its weight.
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        assertEq(hook.initialWeightOf(PROJECT_ID), DEFAULT_WEIGHT, "should record weight on first processing");
    }

    /// @notice initialWeightOf is NOT overwritten by later processing attempts.
    function test_initialWeightOf_notOverwrittenOnSubsequentProcessing() public {
        // The first deploy records the default weight.
        _accumulateTokens({projectId: PROJECT_ID, amount: 100e18});
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        assertEq(hook.initialWeightOf(PROJECT_ID), DEFAULT_WEIGHT);

        // Halve the weight, then process again through addLiquidity: the first snapshot must survive.
        controller.setWeight({projectId: PROJECT_ID, weight: DEFAULT_WEIGHT / 2});
        _accumulateTokens({projectId: PROJECT_ID, amount: 50e18});
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertEq(hook.initialWeightOf(PROJECT_ID), DEFAULT_WEIGHT, "should NOT overwrite initial weight");
    }

    // ─── deployPool is permissionless regardless of weight
    // ──────────────────────────────────────

    /// @notice A random caller can deploy at the undecayed default weight (the old owner gate is gone).
    function test_deployPool_permissionless_atUndecayedWeight() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(randomUser);
        hook.deployPool(PROJECT_ID);

        assertNotEq(
            hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "random user seeds pool at any weight"
        );
    }

    /// @notice A random caller can also deploy after the weight has decayed — the behavior is identical
    /// (permissionless
    /// in both cases), confirming the decay threshold no longer changes access.
    function test_deployPool_permissionless_afterDecay() public {
        _accumulateTokens(PROJECT_ID, 100e18);
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT / 100);

        vm.prank(randomUser);
        hook.deployPool(PROJECT_ID);

        assertNotEq(
            hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "random user seeds pool after decay too"
        );
    }

    /// @notice A random caller can deploy even with no initialWeightOf snapshot (deploy without a prior accumulation is
    /// still gated only by needing accumulated tokens, not by permission).
    function test_deployPool_permissionless_worksAcrossProjectsIndependently() public {
        uint256 projectB = 3;
        _setDirectoryController(projectB, address(controller));
        controller.setWeight(projectB, DEFAULT_WEIGHT);
        controller.setFirstWeight(projectB, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(projectB, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(projectB, 1);
        _setDirectoryTerminal(projectB, address(terminalToken), address(terminal));
        _addDirectoryTerminal(projectB, address(terminal));
        jbTokens.setToken(projectB, address(projectToken));
        jbProjects.setOwner(projectB, owner);
        terminal.setAccountingContext(projectB, address(terminalToken), uint32(uint160(address(terminalToken))), 18);
        terminal.addAccountingContext(
            projectB,
            JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        );
        store.setSurplus({projectId: projectB, surplus: DEFAULT_SURPLUS_PER_TOKEN});
        store.setBalance(address(terminal), projectB, address(terminalToken), 10e18);

        _accumulateTokens(PROJECT_ID, 100e18);
        _accumulateTokens(projectB, 100e18);

        // Seeding project A does not seed project B; each is independently, permissionlessly deployable.
        vm.prank(randomUser);
        hook.deployPool(PROJECT_ID);
        assertNotEq(hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}), 0, "A seeded");
        assertEq(
            hook.askTokenIdOf({projectId: projectB, terminalToken: address(terminalToken)}),
            0,
            "B not seeded by A's deploy"
        );

        vm.prank(randomUser);
        hook.deployPool(projectB);
        assertNotEq(
            hook.askTokenIdOf({projectId: projectB, terminalToken: address(terminalToken)}), 0, "B independently seeded"
        );
    }
}
