// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {JBLPSplitHookHelpers} from "../src/libraries/JBLPSplitHookHelpers.sol";

/// @notice `addLiquidity` recycles the project's ask through the same `_recycle` executor `deployPool` uses: it burns
/// the live ask and re-mints a single-sided ask from the recovered principal plus the post-deployment accumulation,
/// with no funding cash-out. Covers the primary path: pool deployed, spot moved by trading, more tokens accumulated,
/// then `addLiquidity` mints the ask on the project-only side of the (new) live spot, bounded by the corridor.
contract SingleSided_AddLiquidityTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;

    /// @notice Directly overwrite the pool's Slot0 tick/price in the mock PoolManager, simulating that organic
    /// trading against the deployed ask position pushed the pool's spot price to `tick`. Mirrors the packing
    /// `MockPositionManager._syncSlot0` uses so `StateLibrary.getSlot0` (and the spot-tracking base oracle, which
    /// reads live from the same PoolManager) both observe the moved price.
    function _setSpotTick(PoolKey memory key, int24 tick) internal {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        bytes32 poolId = PoolId.unwrap(key.toId());
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        uint24 lpFee = key.fee;
        // Pack: lpFee (24) | protocolFee (24) | tick (24) | sqrtPriceX96 (160) — same layout as the real
        // PoolManager's
        // Slot0 and `MockPositionManager._syncSlot0`.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 packed = bytes32((uint256(lpFee) << 208) | (uint256(uint24(tick)) << 160) | uint256(sqrtPriceX96));
        poolManager.writeSlot(stateSlot, packed);
    }

    /// @notice After a deploy and a spot move, `addLiquidity` burns the first ask and re-mints one project-only ask on
    /// the project side of the moved spot from the recovered principal plus the ledger, without cashing out.
    function test_AddLiquidity_MintsAnotherSingleSidedAsk_NoCashOut() public {
        // Realistic corridor via the mock store's taxed-curve model (nonzero cashOutTaxRate), matching
        // SingleSided_DeployTest so the pre-set spot is guaranteed to land strictly inside [floor, ceiling].
        _setWideTaxedCurve(PROJECT_ID);

        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (int24 corridorLower, int24 corridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
        assertLt(corridorLower, corridorUpper, "precondition: corridor must be non-degenerate");

        // Initialize the pool a quarter of the way up the corridor, leaving room both for the initial deploy's ask
        // AND for a second, higher-spot ask after the simulated buy.
        int24 initialTick = corridorLower + (corridorUpper - corridorLower) / 4;
        uint160 initialSqrtPrice = TickMath.getSqrtPriceAtTick(initialTick);

        // Build the hook's pool key with currencies sorted by address, as V4 requires.
        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
        positionManager.initializePool({key: key, sqrtPriceX96: initialSqrtPrice});

        // Deploy: accumulate + deployPool mints the FIRST single-sided ask at the initial spot.
        _accumulateTokens({projectId: PROJECT_ID, amount: 0.5e18});
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        uint256 firstTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(firstTokenId, 0, "deployPool should have minted the first position");

        // Simulate a buy that lifts the pool's spot price roughly halfway between the initial spot and the
        // corridor ceiling — as if buyers traded through part of the first ask position.
        int24 liftedTick = initialTick + (corridorUpper - initialTick) / 2;
        assertLt(liftedTick, corridorUpper, "precondition: lifted spot must still leave room below the ceiling");
        _setSpotTick({key: key, tick: liftedTick});

        // More reserved tokens accumulate after the deploy, as the "grow-and-route" stage describes.
        _accumulateTokens({projectId: PROJECT_ID, amount: 0.3e18});

        // Snapshot cash-outs and the ledger so the assertions isolate the add.
        uint256 cashOutCallsBefore = terminal.cashOutCallCount();
        uint256 accumulatedBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        // The ledger carries whatever the first ask's mint did not place, plus the new accumulation.
        (,,,, uint256 deployed0, uint256 deployed1,) = positionManager._positions(firstTokenId);
        assertEq(
            accumulatedBefore,
            0.5e18 - (deployed0 + deployed1) + 0.3e18,
            "ledger holds the deploy's rounding plus the new accumulation"
        );
        // Price what the burn will recover at the moved spot.
        (uint256 recovered0, uint256 recovered1) = _principalAtSpot(firstTokenId);

        vm.prank(owner);
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // (a) A (second) position is tracked, minted above the lifted spot; the first is BURNED, not orphaned — the
        // recycle burns the old ask, and with no terminal held there is no bid.
        uint256 secondTokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(secondTokenId, 0, "tokenIdOf should be nonzero after addLiquidity");
        assertNotEq(secondTokenId, firstTokenId, "addLiquidity should mint a fresh ask, not overwrite in place");
        assertEq(
            positionManager.getPositionLiquidity(firstTokenId), 0, "the first position must be burned, not orphaned"
        );

        // (b) The new position holds ZERO terminal tokens (asks-only) and folds BOTH the burned first position's
        // recovered project tokens AND the ledger (the post-deploy 0.3e18 plus the deploy's rounding) into a single
        // ask, leaving only V4 rounding in the ledger.
        _assertPlacedExactly(
            PROJECT_ID, address(projectToken), address(terminalToken), recovered0 + recovered1 + accumulatedBefore, 0
        );

        // (c) The new ask's range sits exactly on the project-only side of the moved spot, bounded by the corridor.
        // In RAW tick terms that is `[spotCeil, corridorUpper]` when the project token is currency0, or the
        // mirror `[corridorLower, spotFloor]` when it is currency1 (raw ticks price token1 in terms of token0).
        _assertAskOnly({spotTick: liftedTick, corridorLower: corridorLower, corridorUpper: corridorUpper});

        // (d) The hook never cashed out to fund the add.
        assertEq(terminal.cashOutCallCount(), cashOutCallsBefore, "addLiquidity must never call cashOutTokensOf");

        // (e) Every project token is either in the pool or in the hook's ledger: nothing is stranded elsewhere.
        assertEq(
            projectToken.balanceOf(address(positionManager)) + hook.accumulatedProjectTokens(PROJECT_ID),
            0.8e18,
            "the pool and the ledger hold every project token"
        );
        assertEq(
            projectToken.balanceOf(address(hook)),
            hook.accumulatedProjectTokens(PROJECT_ID),
            "the hook holds exactly its ledger"
        );
    }

    /// @notice Assert the project holds no bid and its ask sits exactly on the recycle geometry for `spotTick`.
    /// @param spotTick The pool's spot tick the recycle priced against.
    /// @param corridorLower The corridor's lower tick.
    /// @param corridorUpper The corridor's upper tick.
    function _assertAskOnly(int24 spotTick, int24 corridorLower, int24 corridorUpper) internal view {
        // With no terminal held, the recycle mints no bid.
        assertEq(
            hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "no bid without terminal tokens"
        );
        // Align the spot down to the tick spacing, matching how the hook bounds positions around spot.
        int24 spotFloor = JBLPSplitHookHelpers.alignTickToSpacing({tick: spotTick, spacing: hook.TICK_SPACING()});
        (, int24 tickLower, int24 tickUpper,,,,) = positionManager._positions(
            hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)})
        );
        // A token1 project's ask sits below spot; a token0 project's ask sits above it.
        if (address(terminalToken) < address(projectToken)) {
            assertEq(tickLower, corridorLower, "project=token1: the ask starts at the corridor lower bound");
            assertEq(tickUpper, spotFloor, "project=token1: the ask ends at the aligned spot");
        } else {
            // The token0 range starts at the spot when it is aligned, else one spacing above.
            int24 spotCeil = spotTick == spotFloor ? spotFloor : spotFloor + hook.TICK_SPACING();
            assertEq(tickLower, spotCeil, "project=token0: the ask starts at the first aligned tick at or above spot");
            assertEq(tickUpper, corridorUpper, "project=token0: the ask ends at the corridor upper bound");
        }
    }

    /// @notice Initialize the pool a fifth of the way up a realistic corridor and return the pool key plus the
    /// corridor bounds, so the fragmentation/credit tests can drive spot moves that stay strictly inside the band.
    function _initPoolAtLowerFifth() internal returns (PoolKey memory key, int24 corridorLower, int24 corridorUpper) {
        _setWideTaxedCurve(PROJECT_ID);
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (corridorLower, corridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
        assertLt(corridorLower, corridorUpper, "precondition: corridor must be non-degenerate");

        int24 initialTick = corridorLower + (corridorUpper - corridorLower) / 5;
        Currency terminalCurrency = Currency.wrap(address(terminalToken));
        Currency projectCurrency = Currency.wrap(address(projectToken));
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
        positionManager.initializePool(key, TickMath.getSqrtPriceAtTick(initialTick));
    }

    /// @notice No fragmentation: after a deploy and two subsequent adds (each following a spot move), the hook tracks
    /// EXACTLY ONE live position — the previously tracked ids are burned, not orphaned — and
    /// `collectAndRouteLPFees`
    /// can still collect from the tracked position. The hook never calls `cashOutTokensOf`.
    function test_AddLiquidity_NoFragmentation_OneLivePositionAfterRepeatedAdds() public {
        (PoolKey memory key, int24 corridorLower, int24 corridorUpper) = _initPoolAtLowerFifth();
        // Recompute the tick `_initPoolAtLowerFifth` initialized the pool at.
        int24 initialTick = corridorLower + (corridorUpper - corridorLower) / 5;

        // Snapshot cash-outs so the final assertion covers the whole lifecycle.
        uint256 cashOutCallsBefore = terminal.cashOutCallCount();

        // Deploy: mint the first ask.
        _accumulateTokens({projectId: PROJECT_ID, amount: 0.5e18});
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        uint256 t1 = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Buy #1 lifts spot; more tokens accumulate; add recycles (burns t1, mints t2).
        int24 lift1 = initialTick + (corridorUpper - initialTick) / 3;
        _setSpotTick({key: key, tick: lift1});
        _accumulateTokens({projectId: PROJECT_ID, amount: 0.3e18});
        vm.prank(owner);
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        uint256 t2 = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Buy #2 lifts spot again; add recycles (burns t2, mints t3).
        int24 lift2 = lift1 + (corridorUpper - lift1) / 3;
        _setSpotTick({key: key, tick: lift2});
        _accumulateTokens({projectId: PROJECT_ID, amount: 0.2e18});
        // The unfilled ask holds only project tokens, so both principal sides sum to the recovered project amount.
        (uint256 recovered0, uint256 recovered1) = _principalAtSpot(t2);
        uint256 projectIn = recovered0 + recovered1 + hook.accumulatedProjectTokens(PROJECT_ID);
        vm.prank(owner);
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        uint256 t3 = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Asks-only throughout: no bid exists and the ask sits on the exact geometry for the final spot.
        _assertAskOnly({spotTick: lift2, corridorLower: corridorLower, corridorUpper: corridorUpper});

        // Exactly one live position: each add re-mints a distinct id; the prior ids are burned.
        assertTrue(t1 != t2 && t2 != t3 && t1 != t3, "each recycle should mint a distinct id");
        assertEq(positionManager.getPositionLiquidity(t1), 0, "first position must be burned, not orphaned");
        assertEq(positionManager.getPositionLiquidity(t2), 0, "second position must be burned, not orphaned");
        assertGt(positionManager.getPositionLiquidity(t3), 0, "the tracked position must be live");

        // The tracked position folds every accumulation (0.5 + 0.3 + 0.2 = 1.0e18) into one ask — nothing stranded:
        // it holds all it recovered plus the ledger but V4 rounding, and every token is in the pool or the ledger.
        _assertPlacedExactly(PROJECT_ID, address(projectToken), address(terminalToken), projectIn, 0);
        assertEq(
            projectToken.balanceOf(address(positionManager)) + hook.accumulatedProjectTokens(PROJECT_ID),
            1e18,
            "the pool and the ledger hold the full 1.0e18 of accumulated project tokens"
        );
        // Record the fee on whichever currency slot the terminal token sorts to.
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);

        // `collectAndRouteLPFees` still collects from the tracked position (proving no value is stranded on burned
        // ids).
        positionManager.setCollectableFees({
            tokenId: t3, amount0: terminalIsToken0 ? 0.01e18 : 0, amount1: terminalIsToken0 ? 0 : 0.01e18
        });
        // Back the collectable fee with real balance so the collect can transfer it.
        terminalToken.mint({to: address(positionManager), amount: 0.01e18});
        uint256 decreaseCallsBefore = positionManager.decreaseLiquidityCallCount();
        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertEq(
            positionManager.decreaseLiquidityCallCount(),
            decreaseCallsBefore + 1,
            "collectAndRouteLPFees must collect from the live tracked position"
        );

        // The hook never cashed out across the whole lifecycle.
        assertEq(terminal.cashOutCallCount(), cashOutCallsBefore, "no cashOutTokensOf calls during deploy/add cycle");
    }

    /// @notice Credit sweep: project-token credits ACCOUNTED by the hook (accepted through the credits intake path
    /// before the project tokenized) are folded into the minted position (claimed into ERC-20 and added as
    /// principal), not silently stranded.
    function test_Deploy_FoldsHookHeldProjectTokenCredits() public {
        _initPoolAtLowerFifth();

        // Accumulate ERC-20 reserved tokens, and separately account project-token CREDITS through the intake path
        // (a reserved distribution that landed as credits before the project tokenized).
        _accumulateTokens({projectId: PROJECT_ID, amount: 0.5e18});
        // Unset the project's ERC-20 so the split arrives as credits the hook holds.
        jbTokens.setToken({projectId: PROJECT_ID, token: address(0)});
        jbTokens.setCreditBalance({holder: address(hook), projectId: PROJECT_ID, creditCount: 0.2e18});
        // Cap gas below the inline-automation floor so the split only records intake.
        vm.prank(address(controller));
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: PROJECT_ID, token: address(0), amount: 0.2e18, groupId: 1})
        );
        // Tokenize the project again so the deploy can claim the credits into ERC-20.
        jbTokens.setToken({projectId: PROJECT_ID, token: address(projectToken)});
        assertEq(hook.accumulatedProjectCredits(PROJECT_ID), 0.2e18, "credits should be accounted by intake");

        vm.prank(owner);
        hook.deployPool(PROJECT_ID);

        uint256 tokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
        assertNotEq(tokenId, 0, "deployPool should have minted a position");

        // The position folds accumulated ERC-20 (0.5e18) + claimed credits (0.2e18) = 0.7e18 into its project side,
        // leaving only V4 rounding in the ledger.
        _assertPlacedExactly(PROJECT_ID, address(projectToken), address(terminalToken), 0.7e18, 0);

        // The hook's credit balance was swept to zero.
        assertEq(
            jbTokens.creditBalanceOf({holder: address(hook), projectId: PROJECT_ID}),
            0,
            "hook credits should be claimed into the position"
        );
    }
}
