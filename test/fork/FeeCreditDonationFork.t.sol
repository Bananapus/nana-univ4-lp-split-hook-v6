// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized)
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// Local: test helpers
import {BuySwapHelper} from "./Integration_SingleSidedRevnet.t.sol";
import {TwoPositionForkBase} from "./TwoPositionForkBase.sol";

/// @notice Real Core burns a holder's credits before its ERC-20. A third party who sends the hook project credits must
/// not be able to divert the burn of collected project-token LP fees: the hook claims the credits into its ask ledger
/// first, then burns exactly the fees. Also measures a full inline-sized recycle that includes the credit claim.
contract FeeCreditDonationFork is TwoPositionForkBase {
    /// @notice The trader whose swaps earn the positions fees.
    address buyer = address(0xB0B);

    /// @notice The third party that holds project credits and sends them to the hook.
    address donor = address(0xD0D0);

    /// @notice Donated credits are claimed into the ask ledger, and collected project-token fees are still burned in
    /// full.
    function test_fork_donatedCredits_claimedAndLedgered_feesStillBurned() public {
        uint256 pid = _launchProject({reservedPercent: 5000, weight: 1_000_000e18});

        // The donor pays before the project has an ERC-20, so it holds credits.
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        jbMultiTerminal.pay{value: 1 ether}({
            projectId: pid,
            token: _NATIVE,
            amount: 1 ether,
            beneficiary: donor,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        uint256 donated = jbTokens.creditBalanceOf({holder: donor, projectId: pid});
        assertGt(donated, 0, "the donor holds credits");

        // Deploy the ERC-20, fund the surplus and give the hook ask inventory.
        vm.prank(multisig);
        IJBToken pToken =
            jbController.deployERC20For({projectId: pid, name: "Revnet Token", symbol: "RVNT", salt: bytes32(0)});
        _pay({pid: pid, amount: 10 ether});
        _accumulateTokens({pid: pid, pToken: address(pToken), amount: 5_000_000e18});

        // Initialize the pool off-grid at the corridor's midpoint, then deploy the hook's positions there.
        PoolKey memory key = _keyOf(address(pToken));
        {
            (int24 lo, int24 hi) = _corridorOf({pid: pid, pToken: address(pToken)});
            _V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(_offGrid(lo + (hi - lo) / 2)));
        }
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: _V4_POOL_MANAGER, key: key});
        hook.deployPool(pid);
        uint256 askId = hook.askTokenIdOf({projectId: pid, terminalToken: _NATIVE});

        // Trade through the ask both ways so it earns project-token fees.
        BuySwapHelper swapHelper = new BuySwapHelper(_V4_POOL_MANAGER);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        // An exact-input swap is a negative amount; 1 ether fits in an int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap{value: 1 ether}({key: key, zeroForOne: true, amountSpecified: -int256(1 ether)});
        uint256 sellAmount = IERC20(address(pToken)).balanceOf(buyer) / 2;
        vm.startPrank(buyer);
        IERC20(address(pToken)).approve(address(swapHelper), sellAmount);
        // The buyer's token balance fits in an int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap({key: key, zeroForOne: false, amountSpecified: -int256(sellAmount)});
        vm.stopPrank();
        (, uint256 projectFee) = _feesOf({tokenId: askId, key: key});
        assertGt(projectFee, 0, "the ask earned project-token fees");

        // A third party sends its credits to the hook.
        vm.prank(donor);
        jbController.transferCreditsFrom({
            holder: donor, projectId: pid, recipient: address(hook), creditCount: donated
        });
        assertEq(
            jbTokens.creditBalanceOf({holder: address(hook), projectId: pid}),
            donated,
            "the hook holds the donated credits"
        );

        // Snapshot supply, ledger and the hook's ERC-20 balance before the fee collection.
        uint256 supplyBefore = IERC20(address(pToken)).totalSupply();
        uint256 ledgerBefore = hook.accumulatedProjectTokens(pid);
        uint256 heldBefore = IERC20(address(pToken)).balanceOf(address(hook));

        // Collecting fees claims the donated credits first, then burns the project-token fees.
        hook.collectAndRouteLPFees({projectId: pid, terminalToken: _NATIVE});

        // The credits became ledgered ERC-20 inventory, and the burn took exactly the collected fees.
        assertEq(
            jbTokens.creditBalanceOf({holder: address(hook), projectId: pid}), 0, "the donated credits were claimed"
        );
        assertEq(hook.accumulatedProjectTokens(pid), ledgerBefore + donated, "and ledgered as ask inventory");
        assertEq(
            IERC20(address(pToken)).balanceOf(address(hook)), heldBefore + donated, "held as ERC-20, fees all burned"
        );
        assertEq(
            IERC20(address(pToken)).totalSupply(),
            supplyBefore + donated - projectFee,
            "the claim minted the credits and the burn took exactly the fees"
        );
    }

    /// @notice Gas of a full recycle with both positions earning fees on both sides, fee routing (cut, add, burn) and a
    /// credit claim, as inline automation would run it.
    function test_fork_fullRecycleWithCreditClaim_gas() public {
        uint256 pid = _launchProject({reservedPercent: 5000, weight: 1_000_000e18});

        // The donor pays before the project has an ERC-20, so it holds credits.
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        jbMultiTerminal.pay{value: 1 ether}({
            projectId: pid,
            token: _NATIVE,
            amount: 1 ether,
            beneficiary: donor,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Deploy the ERC-20, fund the surplus and give the hook ask inventory.
        vm.prank(multisig);
        IJBToken pToken =
            jbController.deployERC20For({projectId: pid, name: "Revnet Token", symbol: "RVNT", salt: bytes32(0)});
        _pay({pid: pid, amount: 10 ether});
        _accumulateTokens({pid: pid, pToken: address(pToken), amount: 5_000_000e18});

        // Initialize the pool off-grid at the corridor's midpoint, then deploy the hook's positions there.
        PoolKey memory key = _keyOf(address(pToken));
        {
            (int24 lo, int24 hi) = _corridorOf({pid: pid, pToken: address(pToken)});
            _V4_POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(_offGrid(lo + (hi - lo) / 2)));
        }
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: _V4_POOL_MANAGER, key: key});
        hook.deployPool(pid);

        // Open a bid, then trade through both positions so each earns fees on both sides.
        BuySwapHelper swapHelper = new BuySwapHelper(_V4_POOL_MANAGER);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        // An exact-input swap is a negative amount; 2 ether fits in an int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap{value: 2 ether}({key: key, zeroForOne: true, amountSpecified: -int256(2 ether)});
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: _V4_POOL_MANAGER, key: key});
        hook.addLiquidity({projectId: pid, terminalToken: _NATIVE});
        assertTrue(hook.bidTokenIdOf({projectId: pid, terminalToken: _NATIVE}) != 0, "a live bid");
        vm.prank(buyer);
        // An exact-input swap is a negative amount; 0.2 ether fits in an int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap{value: 0.2 ether}({key: key, zeroForOne: true, amountSpecified: -int256(0.2 ether)});
        uint256 sellAmount = IERC20(address(pToken)).balanceOf(buyer) / 2;
        vm.startPrank(buyer);
        IERC20(address(pToken)).approve(address(swapHelper), sellAmount);
        // The buyer's token balance fits in an int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap({key: key, zeroForOne: false, amountSpecified: -int256(sellAmount)});
        vm.stopPrank();

        // The donor sends its credits to the hook, so the recycle also claims them.
        uint256 donated = jbTokens.creditBalanceOf({holder: donor, projectId: pid});
        vm.prank(donor);
        jbController.transferCreditsFrom({
            holder: donor, projectId: pid, recipient: address(hook), creditCount: donated
        });

        // Measure the recycle's gas: fee routing, credit claim, burns and re-mints.
        _mockOracleTwapEqualsSpot({oracle: hook.oracleHook(), pm: _V4_POOL_MANAGER, key: key});
        uint256 gasBefore = gasleft();
        hook.addLiquidity({projectId: pid, terminalToken: _NATIVE});
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("  full recycle with fee routing and credit claim (gas)", used);

        // Both positions were re-minted and the credits were claimed.
        assertTrue(
            hook.askTokenIdOf({projectId: pid, terminalToken: _NATIVE}) != 0
                && hook.bidTokenIdOf({projectId: pid, terminalToken: _NATIVE}) != 0,
            "both re-minted"
        );
        assertEq(jbTokens.creditBalanceOf({holder: address(hook), projectId: pid}), 0, "credits claimed");
    }
}
