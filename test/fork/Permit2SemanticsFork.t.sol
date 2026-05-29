// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Fork tests that verify Permit2's allowance/expiration semantics against the live canonical contract.
/// @dev These pin the behavior behind a real-bytecode assertion: a clearer reader doesn't have to trust the
/// `MockPermit2` in `DeploymentStageTest.t.sol` to behave the same way as the deployed Permit2.
contract Permit2SemanticsFork is Test {
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address internal owner;
    address internal spender;

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);
        owner = makeAddr("owner");
        spender = makeAddr("spender");
    }

    /// @notice Confirms that `expiration: 0` is rewritten to `block.timestamp` by Permit2.
    /// @dev Allowance.updateAmountAndExpiration: `expiration == 0 ? uint48(block.timestamp) : expiration`.
    function testFork_expirationZero_storedAsBlockTimestamp() public {
        vm.startPrank(owner);
        PERMIT2.approve({token: USDC, spender: spender, amount: 100, expiration: 0});
        vm.stopPrank();

        (uint160 amount, uint48 expiration,) = PERMIT2.allowance(owner, USDC, spender);
        assertEq(amount, 100, "amount stored as-is");
        assertEq(expiration, uint48(block.timestamp), "expiration: 0 is rewritten to block.timestamp");
    }

    /// @notice Demonstrates the at-risk window: with `expiration: 0`, Permit2's expiry check (`block.timestamp >
    /// allowed.expiration`) is false within the same block — the allowance is still usable.
    function testFork_expirationZero_allowanceIsLiveSameBlock() public {
        vm.startPrank(owner);
        PERMIT2.approve({token: USDC, spender: spender, amount: 100, expiration: 0});
        vm.stopPrank();

        (, uint48 expiration,) = PERMIT2.allowance(owner, USDC, spender);
        // The transfer guard inside Permit2 is `block.timestamp > expiration` — equal is NOT expired.
        assertFalse(block.timestamp > expiration, "expiration:0 leaves the allowance usable for the rest of the block");
    }

    /// @notice The hook's actual revocation pattern: `expiration: 1` is a past timestamp, so Permit2's guard fires.
    /// @dev This is the post-fix behavior from commit 456cb35.
    function testFork_expirationOne_storedAsExpired() public {
        vm.startPrank(owner);
        PERMIT2.approve({token: USDC, spender: spender, amount: 0, expiration: 1});
        vm.stopPrank();

        (uint160 amount, uint48 expiration,) = PERMIT2.allowance(owner, USDC, spender);
        assertEq(amount, 0, "amount cleared");
        assertEq(expiration, 1, "expiration stored verbatim - past timestamp = immediately expired");
        assertTrue(block.timestamp > expiration, "Permit2's transfer guard treats this as expired");
    }

    /// @notice The boundary case: Permit2's `_transfer` guard is `block.timestamp > expiration` (strict). At
    /// equality, the allowance is still LIVE. This pins that boundary so a regression that flips the guard to
    /// `>=` would surface here. Combined with `testFork_expirationZero_*` it locks why the hook's call site
    /// must use `expiration: 1` (a past timestamp) rather than `expiration: 0` (which gets rewritten to
    /// `block.timestamp` — i.e., this exact equality case).
    function testFork_sameBlockExpiration_isStillLive() public {
        vm.startPrank(owner);
        PERMIT2.approve({token: USDC, spender: spender, amount: 100, expiration: uint48(block.timestamp)});
        vm.stopPrank();

        (, uint48 expiration,) = PERMIT2.allowance(owner, USDC, spender);
        assertEq(expiration, uint48(block.timestamp), "expiration stored as current timestamp");
        assertFalse(block.timestamp > expiration, "strict > means equal-timestamp is NOT expired");
    }

    /// @notice An allowance approved with a future expiration is honored across blocks; warp past it expires.
    function testFork_futureExpiration_lapsesAfterWarp() public {
        uint48 future = uint48(block.timestamp + 3600);

        vm.startPrank(owner);
        PERMIT2.approve({token: USDC, spender: spender, amount: 100, expiration: future});
        vm.stopPrank();

        (, uint48 expirationBefore,) = PERMIT2.allowance(owner, USDC, spender);
        assertEq(expirationBefore, future, "stored verbatim");
        assertFalse(block.timestamp > expirationBefore, "live before warp");

        vm.warp(future + 1);

        (, uint48 expirationAfter,) = PERMIT2.allowance(owner, USDC, spender);
        assertEq(expirationAfter, future, "stored value unchanged by warp");
        assertTrue(block.timestamp > expirationAfter, "expired after warp");
    }
}
