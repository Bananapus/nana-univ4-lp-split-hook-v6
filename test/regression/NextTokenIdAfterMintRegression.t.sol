// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";

/// @notice Tests proving the TOCTOU fix: reading nextTokenId() AFTER minting
///         instead of BEFORE, so the stored tokenIdOf always matches the actual minted position.
contract NextTokenIdAfterMintRegression is LPSplitHookV4TestBase {
    // ─── Test: Basic correctness — tokenIdOf matches the actual minted position ───

    function test_deployPool_storesCorrectTokenId() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        uint256 nextIdBefore = positionManager.nextTokenId();
        assertEq(nextIdBefore, 1, "nextTokenId should start at 1");

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        uint256 storedTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 nextIdAfter = positionManager.nextTokenId();

        // The mint assigned ID 1 then incremented to 2.
        assertEq(nextIdAfter, 2, "nextTokenId should be 2 after one mint");
        assertEq(storedTokenId, 1, "tokenIdOf should be 1 (the minted position)");
        assertEq(storedTokenId, positionManager.lastMintTokenId(), "should match mock's lastMintTokenId");
        assertEq(storedTokenId, nextIdAfter - 1, "should equal nextTokenId() - 1");
    }

    // ─── Test: tokenIdOf correct when nextTokenId starts at a higher value ───
    //
    // Simulates the scenario where other positions were minted before our deploy.

    function test_deployPool_storesCorrectTokenId_afterPriorMints() public {
        // Bump nextTokenId to 6 by storing directly (slot 0 of MockPositionManager).
        vm.store(address(positionManager), bytes32(uint256(0)), bytes32(uint256(6)));
        assertEq(positionManager.nextTokenId(), 6, "nextTokenId should be 6 after setup");

        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        uint256 storedTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(storedTokenId, 6, "tokenIdOf should be 6 (the minted position)");
        assertEq(storedTokenId, positionManager.lastMintTokenId(), "should match mock's tracking");
        assertEq(positionManager.nextTokenId(), 7, "nextTokenId should have incremented to 7");
    }

    // ─── Test: Prove the old pattern's vulnerability mathematically ───
    //
    // The old code read nextTokenId BEFORE calling modifyLiquidities.
    // If a front-runner's mint is processed between the read and our mint:
    //
    //   t0: old_code reads nextTokenId() = 1
    //   t1: front-runner mints → nextTokenId becomes 2 (front-runner gets ID 1)
    //   t2: our mint → nextTokenId becomes 3 (we get ID 2)
    //   t3: old_code stores tokenIdOf = 1 ← WRONG (points to front-runner's position)
    //
    // The fix reads AFTER:
    //   t0: our mint → nextTokenId becomes 3
    //   t1: fix reads nextTokenId() - 1 = 2 ← CORRECT

    function test_frontRun_oldPatternVsNewPattern_mathematical() public pure {
        // Starting state
        uint256 initialNextId = 1;

        // --- Simulate front-run scenario ---
        uint256 frontRunnerPositionId = initialNextId; // 1
        uint256 nextIdAfterFrontRun = initialNextId + 1; // 2
        uint256 ourPositionId = nextIdAfterFrontRun; // 2
        uint256 nextIdAfterOurMint = nextIdAfterFrontRun + 1; // 3

        // Old pattern: read before, store that value
        uint256 oldPatternStored = initialNextId; // Read before anything happened
        assertNotEq(oldPatternStored, ourPositionId, "BUG: old pattern stores 1, but our position is 2");
        assertEq(
            oldPatternStored, frontRunnerPositionId, "BUG: old pattern accidentally points to front-runner's position"
        );

        // New pattern: read after, subtract 1
        uint256 newPatternStored = nextIdAfterOurMint - 1;
        assertEq(newPatternStored, ourPositionId, "FIX: new pattern correctly stores our position ID");
    }

    // ─── Test: Multiple front-runs — old pattern off by N ───

    function test_frontRun_multipleAttackers_oldPatternOffByN() public pure {
        uint256 initialNextId = 1;
        uint256 numFrontRunners = 5;

        uint256 nextIdAfterFrontRuns = initialNextId + numFrontRunners; // 6
        uint256 ourPositionId = nextIdAfterFrontRuns; // 6
        uint256 nextIdAfterOurMint = nextIdAfterFrontRuns + 1; // 7

        // Old pattern: off by 5
        uint256 oldPatternStored = initialNextId; // 1
        assertEq(ourPositionId - oldPatternStored, numFrontRunners, "old pattern off by number of front-runners");

        // New pattern: always correct
        uint256 newPatternStored = nextIdAfterOurMint - 1; // 6
        assertEq(newPatternStored, ourPositionId, "new pattern always correct regardless of front-runs");
    }

    // ─── Test: Verify fix with high starting nextTokenId ───

    function test_deployPool_highStartingNextTokenId() public {
        // Set nextTokenId to a large value (simulating many prior mints).
        vm.store(address(positionManager), bytes32(uint256(0)), bytes32(uint256(1000)));
        assertEq(positionManager.nextTokenId(), 1000);

        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        uint256 storedTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(storedTokenId, 1000, "should store position ID 1000");
        assertEq(positionManager.nextTokenId(), 1001, "nextTokenId should be 1001");
        assertEq(storedTokenId, positionManager.lastMintTokenId(), "should match mock tracking");
    }

    // ─── Test: Rebalance also uses the fix correctly ───

    function test_rebalance_storesCorrectTokenId() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 firstTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(firstTokenId, 1, "first position should be ID 1");

        // Change weight to trigger rebalance.
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT * 2);

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertGt(newTokenId, firstTokenId, "rebalance should create a new position with higher ID");
        assertEq(newTokenId, positionManager.lastMintTokenId(), "rebalance tokenIdOf should match actual minted ID");
        assertEq(newTokenId, positionManager.nextTokenId() - 1, "should equal nextTokenId() - 1 after rebalance");
    }

    // ─── Test: Rebalance with pre-bumped nextTokenId ───

    function test_rebalance_afterPriorMints_storesCorrectTokenId() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 firstTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Simulate external mints between deploy and rebalance.
        uint256 currentNext = positionManager.nextTokenId();
        vm.store(address(positionManager), bytes32(uint256(0)), bytes32(currentNext + 10));

        // Change weight to trigger rebalance.
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT * 3);

        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);

        uint256 newTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(newTokenId, positionManager.lastMintTokenId(), "rebalance after external mints: correct ID");
        assertEq(newTokenId, positionManager.nextTokenId() - 1, "equals nextTokenId() - 1");
        assertGt(newTokenId, firstTokenId + 10, "new ID accounts for the 10 external mints");
    }

    // ─── Test: Invariant — tokenIdOf always equals lastMintTokenId across multiple operations ───

    function test_invariant_tokenIdOf_alwaysMatchesLastMint() public {
        // Deploy
        _accumulateTokens(PROJECT_ID, 200e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);
        assertEq(
            hook.tokenIdOf(PROJECT_ID, address(terminalToken)), positionManager.lastMintTokenId(), "invariant: deploy"
        );

        // Rebalance 1
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT * 2);
        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);
        assertEq(
            hook.tokenIdOf(PROJECT_ID, address(terminalToken)),
            positionManager.lastMintTokenId(),
            "invariant: rebalance 1"
        );

        // Bump nextTokenId externally
        vm.store(address(positionManager), bytes32(uint256(0)), bytes32(positionManager.nextTokenId() + 5));

        // Rebalance 2
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT * 4);
        vm.prank(owner);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0);
        assertEq(
            hook.tokenIdOf(PROJECT_ID, address(terminalToken)),
            positionManager.lastMintTokenId(),
            "invariant: rebalance 2 after external bump"
        );
    }
}
