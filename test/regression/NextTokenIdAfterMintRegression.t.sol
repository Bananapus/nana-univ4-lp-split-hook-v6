// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {TwoPositionFixture} from "./TwoPositionFixture.sol";

/// @notice Tests proving the TOCTOU fix: reading nextTokenId() AFTER minting
///         instead of BEFORE, so the stored askTokenIdOf/bidTokenIdOf always match the actual minted positions.
contract NextTokenIdAfterMintRegression is TwoPositionFixture {
    using PoolIdLibrary for PoolKey;

    // ─── Test: Basic correctness — tokenIdOf matches the actual minted position ───

    function test_deployPool_storesCorrectTokenId() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        uint256 nextIdBefore = positionManager.nextTokenId();
        assertEq(nextIdBefore, 1, "nextTokenId should start at 1");

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        uint256 storedTokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
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
        hook.deployPool(PROJECT_ID);

        uint256 storedTokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
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
        hook.deployPool(PROJECT_ID);

        uint256 storedTokenId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(storedTokenId, 1000, "should store position ID 1000");
        assertEq(positionManager.nextTokenId(), 1001, "nextTokenId should be 1001");
        assertEq(storedTokenId, positionManager.lastMintTokenId(), "should match mock tracking");
    }

    // ─── Recycle helpers ───

    /// @notice Simulate buyers filling part of the live ask (moving the spot into the ask's range and leaving
    /// terminal tokens as its principal) and a new reserved distribution, so the next recycle re-mints BOTH an ask and
    /// a bid. The seed price sits one spacing inside the cash-out floor, where the bid range is empty, so the spot has
    /// to move before a bid can exist.
    function _prepareTwoSidedRecycle() internal {
        uint256 askId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        (PoolKey memory key, int24 askLower, int24 askUpper,,,,) = positionManager._positions(askId);
        int24 spotTick = (askLower + askUpper) / 2 / key.tickSpacing * key.tickSpacing;
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 packed = bytes32(
            (uint256(key.fee) << 208) | (uint256(uint24(spotTick)) << 160)
                | uint256(TickMath.getSqrtPriceAtTick(spotTick))
        );
        poolManager.writeSlot(stateSlot, packed);

        // The ask now holds exactly what its liquidity holds at the new spot (terminal tokens below it).
        _markToSpot(askId);
        _accumulateTokens(PROJECT_ID, 10e18);
    }

    /// @notice Assert the stored ask and bid IDs are the two positions the last recycle minted, that each holds its
    /// own side, and that neither reuses a retired ID.
    function _assertFreshAskAndBid(uint256 oldAskId, uint256 oldBidId, string memory label) internal view {
        uint256 askId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 bidId = hook.bidTokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 nextId = positionManager.nextTokenId();

        // The recycle minted exactly the ask and the bid, as the two most recent positions.
        assertTrue(askId != 0 && bidId != 0, string.concat(label, ": both sides minted"));
        assertTrue(askId != bidId, string.concat(label, ": ask and bid are distinct"));
        assertTrue(askId == nextId - 1 || askId == nextId - 2, string.concat(label, ": ask is a fresh mint"));
        assertTrue(bidId == nextId - 1 || bidId == nextId - 2, string.concat(label, ": bid is a fresh mint"));
        assertEq(askId > bidId ? askId : bidId, positionManager.lastMintTokenId(), string.concat(label, ": last mint"));

        // Neither stored ID points at a retired position.
        assertTrue(askId != oldAskId && askId != oldBidId, string.concat(label, ": ask ID not reused"));
        assertTrue(bidId != oldAskId && bidId != oldBidId, string.concat(label, ": bid ID not reused"));

        // Each ID resolves to the position holding its own side (ask = project token, bid = terminal token).
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        (,,,, uint256 ask0, uint256 ask1,) = positionManager._positions(askId);
        (,,,, uint256 bid0, uint256 bid1,) = positionManager._positions(bidId);
        assertGt(terminalIsToken0 ? ask1 : ask0, 0, string.concat(label, ": ask holds project tokens"));
        assertEq(terminalIsToken0 ? ask0 : ask1, 0, string.concat(label, ": ask holds no terminal tokens"));
        assertGt(terminalIsToken0 ? bid0 : bid1, 0, string.concat(label, ": bid holds terminal tokens"));
        assertEq(terminalIsToken0 ? bid1 : bid0, 0, string.concat(label, ": bid holds no project tokens"));
    }

    // ─── Test: Recycle stores the freshly minted ask AND bid IDs ───

    function test_recycle_storesFreshAskAndBidTokenIds() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 firstAskId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        assertEq(firstAskId, 1, "first position should be ID 1");
        assertEq(hook.bidTokenIdOf(PROJECT_ID, address(terminalToken)), 0, "no bid without terminal tokens");

        _prepareTwoSidedRecycle();
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        _assertFreshAskAndBid(firstAskId, 0, "recycle");
    }

    // ─── Test: Recycle with pre-bumped nextTokenId ───

    function test_recycle_afterPriorMints_storesFreshTokenIds() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 firstAskId = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));

        // Simulate external mints between deploy and recycle.
        uint256 currentNext = positionManager.nextTokenId();
        vm.store(address(positionManager), bytes32(uint256(0)), bytes32(currentNext + 10));

        _prepareTwoSidedRecycle();
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        _assertFreshAskAndBid(firstAskId, 0, "recycle after external mints");
        assertGt(
            hook.bidTokenIdOf(PROJECT_ID, address(terminalToken)),
            firstAskId + 10,
            "new IDs account for the 10 external mints"
        );
    }

    // ─── Test: Invariant — stored IDs always track the fresh mints across multiple operations ───

    function test_invariant_tokenIds_alwaysMatchFreshMints() public {
        // Deploy
        _accumulateTokens(PROJECT_ID, 200e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        assertEq(
            hook.askTokenIdOf(PROJECT_ID, address(terminalToken)),
            positionManager.lastMintTokenId(),
            "invariant: deploy"
        );

        // Recycle 1
        uint256 oldAsk = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 oldBid = hook.bidTokenIdOf(PROJECT_ID, address(terminalToken));
        _prepareTwoSidedRecycle();
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
        _assertFreshAskAndBid(oldAsk, oldBid, "invariant: recycle 1");

        // Bump nextTokenId externally
        vm.store(address(positionManager), bytes32(uint256(0)), bytes32(positionManager.nextTokenId() + 5));

        // Recycle 2: both live positions are retired and replaced.
        oldAsk = hook.askTokenIdOf(PROJECT_ID, address(terminalToken));
        oldBid = hook.bidTokenIdOf(PROJECT_ID, address(terminalToken));
        _prepareTwoSidedRecycle();
        hook.addLiquidity(PROJECT_ID, address(terminalToken));
        _assertFreshAskAndBid(oldAsk, oldBid, "invariant: recycle 2 after external bump");
    }
}
