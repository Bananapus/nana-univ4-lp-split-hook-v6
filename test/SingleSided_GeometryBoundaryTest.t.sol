// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {TwoPositionFixture} from "./regression/TwoPositionFixture.sol";

/// @notice Exact recycle geometry at the price boundaries, in BOTH Uniswap currency orderings (a fresh ERC-20 pair is
/// wired with the project token sorted as token0 or token1) and, for the corridor-construction and narrow-band cases,
/// with a native terminal token (pool currency0 = address(0), the project always token1). Covers:
///   - the ceiling and floor edges: the side with no range is skipped and its inventory carried in its ledger while
///     the other side mints corridor-bounded; zero-project bid-only inventory; a nonzero amount that rounds to zero
///     liquidity; and redeployment of the carried inventory with fresh ids once the geometry is restored;
///   - the exact-price matrix: a spot exactly on an aligned tick `k` (both positions touch `k`), one wei above it, and
///     one wei below the next aligned tick, for negative and positive `k`;
///   - the MIN_TICK partial spacing: a recycle at `MIN_SQRT_PRICE` and `MIN_SQRT_PRICE + 1` mints token0 clamped to
///     the corridor and skips token1 without an out-of-range TickMath call;
///   - corridor construction: bounds round inward against the exact cash-out and issuance prices, a corridor exactly
///     one spacing wide deploys, and tiny rates keep their price precision;
///   - the empty corridor: once the cash-out value reaches the issuance price (even by less than one tick) or no
///     aligned spacing fits between the bounds, the corridor is empty, a recycle retires both live positions and
///     holds every token in the ledgers, a recycle or deploy with nothing to retire reverts `EmptyCorridor` before any
///     pool is seeded, and fresh positions redeploy once the corridor reopens.
/// @dev Spot moves go through `_swapTo`, which re-marks every live position to exactly the principal its liquidity
/// holds at the new price (the shared `TwoPositionFixture` helpers keep the PositionManager's balances backing it), so
/// burns always recover real principal and satisfy contract-derived burn minimums. The mocked TWAP tracks the spot.
contract SingleSided_GeometryBoundaryTest is TwoPositionFixture {
    // Derives a pool's id from its key, to locate its slot0 in the PoolManager's storage.
    using PoolIdLibrary for PoolKey;

    /// @notice How a test empties the corridor.
    enum Empty {
        // Cash-out value 1 terminal token per project token against an issuance price of 1/900.
        Inverted,
        // Cash-out value 0.001111122222222222, about 0.001% above the 1/900 issuance price: both share one tick.
        SubTickInverted,
        // Cash-out value and issuance price both exactly 1.
        Equal,
        // Cash-out value 0.0011, about 100 ticks under the 1/900 issuance price: no aligned spacing fits between.
        Narrow
    }

    /// @notice The exact-price matrix kind with the spot one wei below the next aligned tick.
    uint8 internal constant _BELOW_NEXT = 2;

    /// @notice The exact-price matrix kind with the spot exactly on the aligned tick.
    uint8 internal constant _EXACT = 0;

    /// @notice The project every test wires and recycles.
    uint256 internal constant _PID = 7;

    /// @notice The exact-price matrix kind with the spot one wei above the aligned tick.
    uint8 internal constant _PLUS_ONE = 1;

    /// @notice The hook's tick spacing, which every corridor bound and position tick aligns to.
    int24 internal constant _SPACING = 200;

    /// @notice Whether the project token sorts as the pool's token0 in the current wiring.
    bool internal _isProjectToken0;

    /// @notice Set before `_wire` to wire the native terminal token instead of an ERC-20.
    bool internal _nativeTerminal;

    /// @notice The project's pool key, with the hook's fee, spacing and oracle hook.
    PoolKey internal _poolKey;

    /// @notice The project token.
    MockERC20 internal _proj;

    /// @notice The terminal token: a fresh ERC-20, or `JBConstants.NATIVE_TOKEN` when `_nativeTerminal` is set.
    address internal _term;

    // ─── Ceiling and floor edges (both orderings) ───

    /// @notice Spot at (`beyond == 0`) or past the issuance ceiling with project AND terminal inventory: the ask has
    /// no range, so its id is zero and every project token is carried; the bid is live, bounded by the corridor, and
    /// holds every terminal token. Restoring the spot redeploys the carried inventory into fresh ids.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    /// @param beyond How many ticks past the ceiling the spot moves.
    /// @param newProjectTokens Reserved project tokens accumulated after the spot moves.
    function _runCeiling(bool wantProjectToken0, int24 beyond, uint256 newProjectTokens) internal {
        // Start with both an ask and a bid live at mid-corridor.
        _wire(wantProjectToken0);
        int24 mid = _deployBothAtMid({projectAmount: 1e18, terminalAmount: 0.5e18});
        (int24 lower, int24 upper) = _corridor();
        (int24 ceiling,) = _ceilingAndFloor();

        // Buyers take every ask: the spot reaches (or passes) the issuance ceiling.
        _swapTo(TickMath.getSqrtPriceAtTick(_isProjectToken0 ? ceiling + beyond : ceiling - beyond));
        // New reserved tokens arrive while the spot sits at the ceiling.
        if (newProjectTokens != 0) _accumulate(newProjectTokens);
        // The filled positions hold only terminal tokens, so all project inventory is in the ledger.
        (uint256 projectHeld,) = _livePrincipal();
        assertEq(projectHeld, 0, "precondition: the filled positions hold only terminal");
        (uint256 projectIn, uint256 terminalIn) = _inventory();
        assertGe(projectIn, newProjectTokens, "precondition: the new project tokens are ledgered");
        uint256 idsBefore = _maxId();

        _recycle();

        // No ask is minted; the bid spans the corridor and holds the terminal inventory in a fresh id.
        assertEq(_askId(), 0, "no ask range at or past the ceiling");
        (, uint256 bidPlaced) = _assertPosition({
            tokenId: _bidId(),
            lower: lower,
            upper: upper,
            projectIn: 0,
            terminalIn: terminalIn,
            label: "corridor-bounded bid"
        });
        assertGt(_bidId(), idsBefore, "the bid is a fresh id");
        // Every project token is carried, and only V4 rounding of the terminal side stays ledgered.
        assertEq(_projLedger(), projectIn, "every project token is carried in the ask ledger");
        assertEq(_termLedger(), terminalIn - bidPlaced, "the bid consumed every terminal token but V4 rounding");
        // The ask is intentionally unmintable here: no range at or past the ceiling.
        _assertPlacedExactly({
            projectId: _PID,
            projectTokenAddr: address(_proj),
            terminalTokenAddr: _term,
            projectIn: projectIn,
            terminalIn: terminalIn,
            askLive: false,
            bidLive: true
        });
        _assertLedgersBacked();

        // Restore the geometry: the spot trades back to mid-corridor and the carried inventory redeploys.
        _swapTo(TickMath.getSqrtPriceAtTick(mid));
        (projectIn, terminalIn) = _inventory();
        idsBefore = _maxId();
        _recycle();
        // Each side rests on its own side of the restored spot.
        (int24 bidLower, int24 bidUpper) = _isProjectToken0 ? (lower, mid) : (mid, upper);
        (int24 askLower, int24 askUpper) = _isProjectToken0 ? (mid, upper) : (lower, mid);
        (uint256 askPlaced,) = _assertPosition({
            tokenId: _askId(),
            lower: askLower,
            upper: askUpper,
            projectIn: projectIn,
            terminalIn: 0,
            label: "restored ask"
        });
        (, bidPlaced) = _assertPosition({
            tokenId: _bidId(),
            lower: bidLower,
            upper: bidUpper,
            projectIn: 0,
            terminalIn: terminalIn,
            label: "restored bid"
        });
        // Both are fresh ids, and only V4 rounding stays ledgered on either side.
        assertGt(_askId(), idsBefore, "restored ask is a fresh id");
        assertGt(_bidId(), idsBefore, "restored bid is a fresh id");
        assertEq(_projLedger(), projectIn - askPlaced, "the carried project tokens redeployed");
        assertEq(_termLedger(), terminalIn - bidPlaced, "the terminal redeployed");
        _assertLedgersBacked();
    }

    /// @notice With the project as token0 and the spot exactly at the ceiling, the ask is skipped and carried, the bid
    /// spans the corridor, and the restored spot redeploys both.
    function test_Ceiling_At_ProjectToken0() public {
        // Exactly at the ceiling, with 0.3e18 new reserved tokens to carry.
        _runCeiling({wantProjectToken0: true, beyond: 0, newProjectTokens: 0.3e18});
    }

    /// @notice With the project as token1 and the spot exactly at the ceiling, the ask is skipped and carried, the bid
    /// spans the corridor, and the restored spot redeploys both.
    function test_Ceiling_At_ProjectToken1() public {
        // Exactly at the ceiling, with 0.3e18 new reserved tokens to carry.
        _runCeiling({wantProjectToken0: false, beyond: 0, newProjectTokens: 0.3e18});
    }

    /// @notice With the project as token0 and the spot past the ceiling, the ask is skipped and carried, the bid spans
    /// the corridor, and the restored spot redeploys both.
    function test_Ceiling_Beyond_ProjectToken0() public {
        // 1050 ticks past the ceiling, with 0.3e18 new reserved tokens to carry.
        _runCeiling({wantProjectToken0: true, beyond: 1050, newProjectTokens: 0.3e18});
    }

    /// @notice With the project as token1 and the spot past the ceiling, the ask is skipped and carried, the bid spans
    /// the corridor, and the restored spot redeploys both.
    function test_Ceiling_Beyond_ProjectToken1() public {
        // 1050 ticks past the ceiling, with 0.3e18 new reserved tokens to carry.
        _runCeiling({wantProjectToken0: false, beyond: 1050, newProjectTokens: 0.3e18});
    }

    /// @notice Zero-project inventory (every ask filled, no new reserved tokens): the recycle deploys bid-only.
    function test_Ceiling_ZeroProject_BidOnly_ProjectToken0() public {
        // Exactly at the ceiling with no new reserved tokens, project as token0.
        _runCeiling({wantProjectToken0: true, beyond: 0, newProjectTokens: 0});
    }

    /// @notice Zero-project inventory (every ask filled, no new reserved tokens) with the project as token1: the
    /// recycle deploys bid-only.
    function test_Ceiling_ZeroProject_BidOnly_ProjectToken1() public {
        // Exactly at the ceiling with no new reserved tokens, project as token1.
        _runCeiling({wantProjectToken0: false, beyond: 0, newProjectTokens: 0});
    }

    /// @notice Spot at (`beyond == 0`) or past the cash-out floor with project AND terminal inventory: the bid has no
    /// range, so its id is zero and every terminal token stays ledgered; the ask is live across the whole corridor.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    /// @param beyond How many ticks past the floor the spot moves.
    function _runFloor(bool wantProjectToken0, int24 beyond) internal {
        // Start with both an ask and a bid live at mid-corridor.
        _wire(wantProjectToken0);
        int24 mid = _deployBothAtMid({projectAmount: 1e18, terminalAmount: 0.5e18});
        (int24 lower, int24 upper) = _corridor();
        (, int24 floor) = _ceilingAndFloor();

        // Sellers take every bid: the spot reaches (or passes) the cash-out floor. A forgiven terminal fee then gives
        // the project terminal inventory that has nowhere to rest.
        _swapTo(TickMath.getSqrtPriceAtTick(_isProjectToken0 ? floor - beyond : floor + beyond));
        uint256 fee = 0.2e18;
        _addTerminalFee({tokenId: _askId(), amount: fee});
        // The filled positions hold only project tokens.
        (, uint256 terminalHeld) = _livePrincipal();
        assertEq(terminalHeld, 0, "precondition: the filled positions hold only project tokens");
        (uint256 projectIn, uint256 terminalIn) = _inventory();
        // The forgiven fee is collected by the recycle, joining the terminal inventory.
        terminalIn += fee;

        _recycle();

        // No bid is minted; the ask spans the corridor and every terminal token stays ledgered.
        assertEq(_bidId(), 0, "no bid range at or past the floor");
        (uint256 askPlaced,) = _assertPosition({
            tokenId: _askId(),
            lower: lower,
            upper: upper,
            projectIn: projectIn,
            terminalIn: 0,
            label: "corridor-bounded ask"
        });
        assertEq(_termLedger(), terminalIn, "every terminal token stays in the bid ledger");
        assertEq(_projLedger(), projectIn - askPlaced, "the ask consumed every project token but V4 rounding");
        // The bid is intentionally unmintable here: no range at or past the floor.
        _assertPlacedExactly({
            projectId: _PID,
            projectTokenAddr: address(_proj),
            terminalTokenAddr: _term,
            projectIn: projectIn,
            terminalIn: terminalIn,
            askLive: true,
            bidLive: false
        });
        _assertLedgersBacked();

        // Restore the geometry: the carried terminal redeploys as a fresh bid.
        _swapTo(TickMath.getSqrtPriceAtTick(mid));
        (projectIn, terminalIn) = _inventory();
        assertGe(terminalIn, fee, "precondition: the carried fee is in the terminal inventory");
        uint256 idsBefore = _maxId();
        _recycle();
        // Each side rests on its own side of the restored spot.
        (int24 bidLower, int24 bidUpper) = _isProjectToken0 ? (lower, mid) : (mid, upper);
        (int24 askLower, int24 askUpper) = _isProjectToken0 ? (mid, upper) : (lower, mid);
        (askPlaced,) = _assertPosition({
            tokenId: _askId(),
            lower: askLower,
            upper: askUpper,
            projectIn: projectIn,
            terminalIn: 0,
            label: "restored ask"
        });
        (, uint256 bidPlaced) = _assertPosition({
            tokenId: _bidId(),
            lower: bidLower,
            upper: bidUpper,
            projectIn: 0,
            terminalIn: terminalIn,
            label: "restored bid"
        });
        // Both are fresh ids, and only V4 rounding stays ledgered on either side.
        assertGt(_askId(), idsBefore, "restored ask is a fresh id");
        assertGt(_bidId(), idsBefore, "restored bid is a fresh id");
        assertEq(_termLedger(), terminalIn - bidPlaced, "the carried terminal redeployed");
        assertEq(_projLedger(), projectIn - askPlaced, "the project tokens redeployed");
        _assertLedgersBacked();
    }

    /// @notice With the project as token0 and the spot exactly at the floor, the bid is skipped and carried, the ask
    /// spans the corridor, and the restored spot redeploys both.
    function test_Floor_At_ProjectToken0() public {
        // Exactly at the floor, project as token0.
        _runFloor({wantProjectToken0: true, beyond: 0});
    }

    /// @notice With the project as token1 and the spot exactly at the floor, the bid is skipped and carried, the ask
    /// spans the corridor, and the restored spot redeploys both.
    function test_Floor_At_ProjectToken1() public {
        // Exactly at the floor, project as token1.
        _runFloor({wantProjectToken0: false, beyond: 0});
    }

    /// @notice With the project as token0 and the spot past the floor, the bid is skipped and carried, the ask spans
    /// the corridor, and the restored spot redeploys both.
    function test_Floor_Beyond_ProjectToken0() public {
        // 1050 ticks past the floor, project as token0.
        _runFloor({wantProjectToken0: true, beyond: 1050});
    }

    /// @notice With the project as token1 and the spot past the floor, the bid is skipped and carried, the ask spans
    /// the corridor, and the restored spot redeploys both.
    function test_Floor_Beyond_ProjectToken1() public {
        // 1050 ticks past the floor, project as token1.
        _runFloor({wantProjectToken0: false, beyond: 1050});
    }

    /// @notice A nonzero terminal amount too small to yield any liquidity across the bid range is skipped and carried,
    /// while the ask still mints; a later recycle with enough terminal redeploys it. A pricier issuance widens the
    /// corridor and the spot sits two spacings inside the ceiling, so the bid range spans enough price that one wei
    /// rounds to zero liquidity in either ordering.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runDustBid(bool wantProjectToken0) internal {
        // Widen the corridor and deploy with the spot two spacings inside the ceiling.
        _wire(wantProjectToken0);
        controller.setWeight({projectId: _PID, weight: 1e15});
        (int24 ceiling,) = _ceilingAndFloor();
        int24 spotTick = _isProjectToken0 ? ceiling - 2 * _SPACING : ceiling + 2 * _SPACING;
        _deployAt({sqrtPriceX96: TickMath.getSqrtPriceAtTick(spotTick), amount: 1e18});
        (int24 lower, int24 upper) = _corridor();
        (int24 bidLower, int24 bidUpper) = _isProjectToken0 ? (lower, spotTick) : (spotTick, upper);
        (int24 askLower, int24 askUpper) = _isProjectToken0 ? (spotTick, upper) : (lower, spotTick);

        // One wei of the terminal currency buys no liquidity across the whole bid range.
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(bidLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(bidUpper);
        uint128 dustLiquidity = _isProjectToken0
            ? LiquidityAmounts.getLiquidityForAmount1({sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtB, amount1: 1})
            : LiquidityAmounts.getLiquidityForAmount0({sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtB, amount0: 1});
        assertEq(dustLiquidity, 0, "precondition: one wei of terminal yields zero bid liquidity");

        // A one-wei forgiven fee is the only terminal inventory.
        _addTerminalFee({tokenId: _askId(), amount: 1});
        (uint256 projectIn, uint256 terminalIn) = _inventory();
        assertEq(terminalIn, 0, "precondition: no terminal before the dust fee");
        _recycle();

        // The bid is skipped and the dust is carried, while the ask still mints.
        assertEq(_bidId(), 0, "a zero-liquidity bid is skipped");
        _assertPosition({
            tokenId: _askId(), lower: askLower, upper: askUpper, projectIn: projectIn, terminalIn: 0, label: "ask"
        });
        assertEq(_termLedger(), 1, "the dust terminal is carried, not lost");
        // The bid is intentionally unmintable here: one wei rounds to zero liquidity.
        _assertPlacedExactly({
            projectId: _PID,
            projectTokenAddr: address(_proj),
            terminalTokenAddr: _term,
            projectIn: projectIn,
            terminalIn: 1,
            askLive: true,
            bidLive: false
        });
        _assertLedgersBacked();

        // A larger forgiven fee joins the carried dust, and the next recycle mints a bid with both.
        _addTerminalFee({tokenId: _askId(), amount: 0.1e18});
        (, terminalIn) = _inventory();
        assertEq(terminalIn, 1, "precondition: the carried dust is the terminal ledger");
        terminalIn += 0.1e18;
        uint256 idsBefore = _maxId();
        _recycle();
        (, uint256 bidPlaced) = _assertPosition({
            tokenId: _bidId(),
            lower: bidLower,
            upper: bidUpper,
            projectIn: 0,
            terminalIn: terminalIn,
            label: "bid with the carried dust"
        });
        assertGt(_bidId(), idsBefore, "fresh bid id");
        assertEq(_termLedger(), terminalIn - bidPlaced, "the carried dust redeployed but V4 rounding");
    }

    /// @notice With the project as token0, a one-wei terminal amount that rounds to zero bid liquidity is carried and
    /// later redeployed.
    function test_DustBidRoundsToZeroLiquidity_ProjectToken0() public {
        // Project as token0.
        _runDustBid(true);
    }

    /// @notice With the project as token1, a one-wei terminal amount that rounds to zero bid liquidity is carried and
    /// later redeployed.
    function test_DustBidRoundsToZeroLiquidity_ProjectToken1() public {
        // Project as token1.
        _runDustBid(false);
    }

    // ─── Exact-price boundary matrix (both orderings, negative and positive k) ───

    /// @notice Recycle with the spot at `sqrtAtTick(k)`, one wei above it, or one wei below `sqrtAtTick(k + spacing)`
    /// (`k` aligned). Exactly on `k`, both positions touch `k`; otherwise token1 ends at `k` and token0 starts at
    /// `k + spacing`. Each position holds only its own currency.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    /// @param k The aligned tick the spot sits on or next to.
    /// @param kind `_EXACT`, `_PLUS_ONE` or `_BELOW_NEXT`.
    function _runMatrix(bool wantProjectToken0, int24 k, uint8 kind) internal {
        _wire(wantProjectToken0);
        // A pricier issuance widens the corridor across tick zero in both orderings, so negative and positive `k` fit.
        controller.setWeight({projectId: _PID, weight: 1e15});
        (int24 lower, int24 upper) = _corridor();
        assertEq(k % _SPACING, 0, "precondition: k aligned");
        assertGt(k, lower, "precondition: k above corridor lower");
        assertLt(k + _SPACING, upper, "precondition: k below corridor upper");

        // Pick the spot for this kind and confirm the tick it rounds to.
        uint160 sqrtPriceX96 = kind == _EXACT
            ? TickMath.getSqrtPriceAtTick(k)
            : kind == _PLUS_ONE ? TickMath.getSqrtPriceAtTick(k) + 1 : TickMath.getSqrtPriceAtTick(k + _SPACING) - 1;
        assertEq(
            TickMath.getTickAtSqrtPrice(sqrtPriceX96),
            kind == _BELOW_NEXT ? k + _SPACING - 1 : k,
            "precondition: spot tick"
        );

        // Deploy at that spot, then give the project a forgiven terminal fee to bid with.
        uint256 projectAmount = 1e18;
        uint256 terminalAmount = 0.5e18;
        _deployAt({sqrtPriceX96: sqrtPriceX96, amount: projectAmount});
        _addTerminalFee({tokenId: _askId(), amount: terminalAmount});
        (uint256 projectIn, uint256 terminalIn) = _inventory();
        assertEq(terminalIn, 0, "precondition: the only terminal is the fee");
        terminalIn = terminalAmount;
        _recycle();
        assertEq(_spot(), sqrtPriceX96, "the spot never moved");

        // Token0 starts at `k` only when the spot is exactly on it; token1 always ends at `k`.
        int24 token0Lower = kind == _EXACT ? k : k + _SPACING;
        uint256 askPlaced;
        uint256 bidPlaced;
        if (_isProjectToken0) {
            (askPlaced,) = _assertPosition({
                tokenId: _askId(),
                lower: token0Lower,
                upper: upper,
                projectIn: projectIn,
                terminalIn: 0,
                label: "token0 ask"
            });
            (, bidPlaced) = _assertPosition({
                tokenId: _bidId(), lower: lower, upper: k, projectIn: 0, terminalIn: terminalIn, label: "token1 bid"
            });
        } else {
            (askPlaced,) = _assertPosition({
                tokenId: _askId(), lower: lower, upper: k, projectIn: projectIn, terminalIn: 0, label: "token1 ask"
            });
            (, bidPlaced) = _assertPosition({
                tokenId: _bidId(),
                lower: token0Lower,
                upper: upper,
                projectIn: 0,
                terminalIn: terminalIn,
                label: "token0 bid"
            });
        }
        // Only V4 rounding stays ledgered on either side.
        assertEq(_projLedger(), projectIn - askPlaced, "no project carry beyond V4 rounding");
        assertEq(_termLedger(), terminalIn - bidPlaced, "no terminal carry beyond V4 rounding");
    }

    /// @notice Project as token0, spot exactly on a negative aligned tick: both positions touch it.
    function test_Matrix_ProjectToken0_NegativeK_Exact() public {
        // k = -2000, exactly on it.
        _runMatrix({wantProjectToken0: true, k: -2000, kind: _EXACT});
    }

    /// @notice Project as token0, spot one wei above a negative aligned tick: token0 starts one spacing up.
    function test_Matrix_ProjectToken0_NegativeK_PlusOne() public {
        // k = -2000, one wei above it.
        _runMatrix({wantProjectToken0: true, k: -2000, kind: _PLUS_ONE});
    }

    /// @notice Project as token0, spot one wei below the next aligned tick above a negative one: token0 starts at the
    /// next tick.
    function test_Matrix_ProjectToken0_NegativeK_BelowNext() public {
        // k = -2000, one wei below k + spacing.
        _runMatrix({wantProjectToken0: true, k: -2000, kind: _BELOW_NEXT});
    }

    /// @notice Project as token0, spot exactly on a positive aligned tick: both positions touch it.
    function test_Matrix_ProjectToken0_PositiveK_Exact() public {
        // k = 2000, exactly on it.
        _runMatrix({wantProjectToken0: true, k: 2000, kind: _EXACT});
    }

    /// @notice Project as token0, spot one wei above a positive aligned tick: token0 starts one spacing up.
    function test_Matrix_ProjectToken0_PositiveK_PlusOne() public {
        // k = 2000, one wei above it.
        _runMatrix({wantProjectToken0: true, k: 2000, kind: _PLUS_ONE});
    }

    /// @notice Project as token0, spot one wei below the next aligned tick above a positive one: token0 starts at the
    /// next tick.
    function test_Matrix_ProjectToken0_PositiveK_BelowNext() public {
        // k = 2000, one wei below k + spacing.
        _runMatrix({wantProjectToken0: true, k: 2000, kind: _BELOW_NEXT});
    }

    /// @notice Project as token1, spot exactly on a negative aligned tick: both positions touch it.
    function test_Matrix_ProjectToken1_NegativeK_Exact() public {
        // k = -2000, exactly on it.
        _runMatrix({wantProjectToken0: false, k: -2000, kind: _EXACT});
    }

    /// @notice Project as token1, spot one wei above a negative aligned tick: token0 starts one spacing up.
    function test_Matrix_ProjectToken1_NegativeK_PlusOne() public {
        // k = -2000, one wei above it.
        _runMatrix({wantProjectToken0: false, k: -2000, kind: _PLUS_ONE});
    }

    /// @notice Project as token1, spot one wei below the next aligned tick above a negative one: token0 starts at the
    /// next tick.
    function test_Matrix_ProjectToken1_NegativeK_BelowNext() public {
        // k = -2000, one wei below k + spacing.
        _runMatrix({wantProjectToken0: false, k: -2000, kind: _BELOW_NEXT});
    }

    /// @notice Project as token1, spot exactly on a positive aligned tick: both positions touch it.
    function test_Matrix_ProjectToken1_PositiveK_Exact() public {
        // k = 2000, exactly on it.
        _runMatrix({wantProjectToken0: false, k: 2000, kind: _EXACT});
    }

    /// @notice Project as token1, spot one wei above a positive aligned tick: token0 starts one spacing up.
    function test_Matrix_ProjectToken1_PositiveK_PlusOne() public {
        // k = 2000, one wei above it.
        _runMatrix({wantProjectToken0: false, k: 2000, kind: _PLUS_ONE});
    }

    /// @notice Project as token1, spot one wei below the next aligned tick above a positive one: token0 starts at the
    /// next tick.
    function test_Matrix_ProjectToken1_PositiveK_BelowNext() public {
        // k = 2000, one wei below k + spacing.
        _runMatrix({wantProjectToken0: false, k: 2000, kind: _BELOW_NEXT});
    }

    // ─── MIN_TICK partial spacing (successful recycle) ───

    /// @notice Deploy, then recycle permissionlessly with the spot (and TWAP) at `sqrtPriceX96` in the lowest partial
    /// spacing, where the aligned floor (-887400) sits below `MIN_TICK`. Token0 mints clamped to the corridor, token1
    /// is skipped with its inventory carried, and no out-of-range tick reaches TickMath.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    /// @param sqrtPriceX96 The spot to recycle at, inside tick `MIN_TICK`.
    function _runMinPrice(bool wantProjectToken0, uint160 sqrtPriceX96) internal {
        // Start with both an ask and a bid live at mid-corridor.
        _wire(wantProjectToken0);
        _deployBothAtMid({projectAmount: 1e18, terminalAmount: 0.5e18});
        (int24 lower, int24 upper) = _corridor();

        // Trade the spot down into the lowest partial spacing.
        _swapTo(sqrtPriceX96);
        assertEq(TickMath.getTickAtSqrtPrice(sqrtPriceX96), TickMath.MIN_TICK, "precondition: spot tick is MIN_TICK");

        // Token1 inventory that cannot rest below the spot: new reserved tokens when the project is token1, a
        // forgiven terminal fee when the terminal is token1.
        uint256 token1Inventory = 0.2e18;
        if (_isProjectToken0) _addTerminalFee({tokenId: _askId(), amount: token1Inventory});
        else _accumulate(token1Inventory);
        (uint256 projectHeld, uint256 terminalHeld) = _livePrincipal();
        assertEq(_isProjectToken0 ? terminalHeld : projectHeld, 0, "precondition: every position is all token0");
        (uint256 projectIn, uint256 terminalIn) = _inventory();
        // A forgiven terminal fee is collected by the recycle, joining the terminal inventory.
        if (_isProjectToken0) terminalIn += token1Inventory;
        assertGe(_isProjectToken0 ? terminalIn : projectIn, token1Inventory, "precondition: token1 inventory");

        _recycle();

        // Whichever side is token0 spans the corridor; the token1 side is skipped and carried.
        if (_isProjectToken0) {
            (uint256 askPlaced,) = _assertPosition({
                tokenId: _askId(),
                lower: lower,
                upper: upper,
                projectIn: projectIn,
                terminalIn: 0,
                label: "token0 ask clamped to the corridor"
            });
            assertEq(_bidId(), 0, "token1 bid skipped");
            assertEq(_termLedger(), terminalIn, "token1 terminal carried");
            assertEq(_projLedger(), projectIn - askPlaced, "token0 fully deployed but V4 rounding");
        } else {
            (, uint256 bidPlaced) = _assertPosition({
                tokenId: _bidId(),
                lower: lower,
                upper: upper,
                projectIn: 0,
                terminalIn: terminalIn,
                label: "token0 bid clamped to the corridor"
            });
            assertEq(_askId(), 0, "token1 ask skipped");
            assertEq(_projLedger(), projectIn, "token1 project carried");
            assertEq(_termLedger(), terminalIn - bidPlaced, "token0 fully deployed but V4 rounding");
        }
        _assertLedgersBacked();
    }

    /// @notice Project as token0, recycle at exactly `MIN_SQRT_PRICE`: the token0 ask spans the corridor and the
    /// token1 bid is carried.
    function test_MinSqrtPrice_ProjectToken0() public {
        // The lowest representable price.
        _runMinPrice({wantProjectToken0: true, sqrtPriceX96: TickMath.MIN_SQRT_PRICE});
    }

    /// @notice Project as token0, recycle one wei above `MIN_SQRT_PRICE`: the token0 ask spans the corridor and the
    /// token1 bid is carried.
    function test_MinSqrtPricePlusOne_ProjectToken0() public {
        // One wei above the lowest representable price, still inside MIN_TICK.
        _runMinPrice({wantProjectToken0: true, sqrtPriceX96: TickMath.MIN_SQRT_PRICE + 1});
    }

    /// @notice Project as token1, recycle at exactly `MIN_SQRT_PRICE`: the token0 bid spans the corridor and the
    /// token1 ask is carried.
    function test_MinSqrtPrice_ProjectToken1() public {
        // The lowest representable price.
        _runMinPrice({wantProjectToken0: false, sqrtPriceX96: TickMath.MIN_SQRT_PRICE});
    }

    /// @notice Project as token1, recycle one wei above `MIN_SQRT_PRICE`: the token0 bid spans the corridor and the
    /// token1 ask is carried.
    function test_MinSqrtPricePlusOne_ProjectToken1() public {
        // One wei above the lowest representable price, still inside MIN_TICK.
        _runMinPrice({wantProjectToken0: false, sqrtPriceX96: TickMath.MIN_SQRT_PRICE + 1});
    }

    // ─── Corridor construction (both orderings) ───

    /// @notice A first deploy with an empty corridor has nothing to retire: it reverts `EmptyCorridor` before seeding
    /// or accepting a pool price, so nothing is initialized or minted and the reserved tokens stay ledgered. Normal
    /// economics then deploy them, at the pre-initialized price when there is one.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    /// @param kind How the corridor is emptied.
    /// @param preInitialized Whether the pool is initialized at mid-corridor before the deploy.
    function _runEmptyDeploy(bool wantProjectToken0, Empty kind, bool preInitialized) internal {
        // Optionally pre-initialize at the normal mid-corridor price, then empty the corridor.
        _wire(wantProjectToken0);
        uint160 existing = TickMath.getSqrtPriceAtTick(_midTick());
        if (preInitialized) positionManager.initializePool({key: _poolKey, sqrtPriceX96: existing});
        _emptyAndCheck(kind);
        assertEq(_seed(), 0, "an empty corridor has no seed price");
        // Ledger reserved tokens and note the next position id.
        _accumulate(1e18);
        uint256 nextId = positionManager.nextTokenId();

        // The deploy refuses before touching the pool.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_EmptyCorridor.selector, _PID, address(_term)
            )
        );
        vm.prank(user);
        hook.deployPool(_PID);
        // Nothing was deployed, priced or minted, and the reserved tokens stay with the hook.
        assertFalse(
            hook.isPoolDeployed({projectId: _PID, terminalToken: address(_term)}), "empty: the pool is not deployed"
        );
        assertEq(_spot(), preInitialized ? existing : 0, "empty: the pool price is untouched");
        assertEq(positionManager.nextTokenId(), nextId, "empty: nothing minted");
        assertEq(_projLedger(), 1e18, "empty: the reserved tokens stay ledgered");
        assertEq(_proj.balanceOf(address(hook)), 1e18, "empty: the hook still holds them");

        // Normal economics reopen the corridor and the same deploy succeeds.
        _restoreEconomics();
        vm.prank(user);
        hook.deployPool(_PID);
        if (preInitialized) assertEq(_spot(), existing, "the pre-initialized price is kept");
        // Normal economics: the ask holds every reserved token but V4 rounding, which stays ledgered, and no terminal.
        assertEq(_bidId(), 0, "normal economics: nothing to bid with");
        _assertPlacedExactly({
            projectId: _PID,
            projectTokenAddr: address(_proj),
            terminalTokenAddr: address(_term),
            projectIn: 1e18,
            terminalIn: 0
        });
        _assertLedgersBacked();
    }

    /// @notice Project as token0: a first deploy into an inverted corridor reverts `EmptyCorridor`, then deploys once
    /// the economics are normal.
    function test_EmptyCorridor_DeployReverts_ProjectToken0() public {
        // Inverted corridor, uninitialized pool.
        _runEmptyDeploy({wantProjectToken0: true, kind: Empty.Inverted, preInitialized: false});
    }

    /// @notice Project as token1: a first deploy into an inverted corridor reverts `EmptyCorridor`, then deploys once
    /// the economics are normal.
    function test_EmptyCorridor_DeployReverts_ProjectToken1() public {
        // Inverted corridor, uninitialized pool.
        _runEmptyDeploy({wantProjectToken0: false, kind: Empty.Inverted, preInitialized: false});
    }

    /// @notice Project as token0: a first deploy into an inverted corridor on a pre-initialized pool reverts and keeps
    /// the pool price, then deploys at that price.
    function test_EmptyCorridor_DeployReverts_PreInitialized_ProjectToken0() public {
        // Inverted corridor, pool pre-initialized at mid-corridor.
        _runEmptyDeploy({wantProjectToken0: true, kind: Empty.Inverted, preInitialized: true});
    }

    /// @notice Project as token1: a first deploy into an inverted corridor on a pre-initialized pool reverts and keeps
    /// the pool price, then deploys at that price.
    function test_EmptyCorridor_DeployReverts_PreInitialized_ProjectToken1() public {
        // Inverted corridor, pool pre-initialized at mid-corridor.
        _runEmptyDeploy({wantProjectToken0: false, kind: Empty.Inverted, preInitialized: true});
    }

    /// @notice Project as token0: a cash-out value above the issuance price by less than one tick still empties the
    /// corridor and the first deploy reverts.
    function test_EmptyCorridor_SubTickInversion_DeployReverts_ProjectToken0() public {
        // Sub-tick inversion, uninitialized pool.
        _runEmptyDeploy({wantProjectToken0: true, kind: Empty.SubTickInverted, preInitialized: false});
    }

    /// @notice Project as token1: a cash-out value above the issuance price by less than one tick still empties the
    /// corridor and the first deploy reverts.
    function test_EmptyCorridor_SubTickInversion_DeployReverts_ProjectToken1() public {
        // Sub-tick inversion, uninitialized pool.
        _runEmptyDeploy({wantProjectToken0: false, kind: Empty.SubTickInverted, preInitialized: false});
    }

    /// @notice Project as token0: a sub-tick inversion on a pre-initialized pool reverts the first deploy and keeps
    /// the pool price.
    function test_EmptyCorridor_SubTickInversion_DeployReverts_PreInitialized_ProjectToken0() public {
        // Sub-tick inversion, pool pre-initialized at mid-corridor.
        _runEmptyDeploy({wantProjectToken0: true, kind: Empty.SubTickInverted, preInitialized: true});
    }

    /// @notice Project as token1: a sub-tick inversion on a pre-initialized pool reverts the first deploy and keeps
    /// the pool price.
    function test_EmptyCorridor_SubTickInversion_DeployReverts_PreInitialized_ProjectToken1() public {
        // Sub-tick inversion, pool pre-initialized at mid-corridor.
        _runEmptyDeploy({wantProjectToken0: false, kind: Empty.SubTickInverted, preInitialized: true});
    }

    /// @notice Project as token0: equal cash-out and issuance prices empty the corridor and the first deploy reverts.
    function test_EmptyCorridor_EqualPrices_DeployReverts_ProjectToken0() public {
        // Equal prices, uninitialized pool.
        _runEmptyDeploy({wantProjectToken0: true, kind: Empty.Equal, preInitialized: false});
    }

    /// @notice Project as token1: equal cash-out and issuance prices empty the corridor and the first deploy reverts.
    function test_EmptyCorridor_EqualPrices_DeployReverts_ProjectToken1() public {
        // Equal prices, uninitialized pool.
        _runEmptyDeploy({wantProjectToken0: false, kind: Empty.Equal, preInitialized: false});
    }

    /// @notice Project as token0: a band too narrow for one aligned spacing empties the corridor and the first deploy
    /// reverts.
    function test_EmptyCorridor_NarrowBand_DeployReverts_ProjectToken0() public {
        // Narrow band, uninitialized pool.
        _runEmptyDeploy({wantProjectToken0: true, kind: Empty.Narrow, preInitialized: false});
    }

    /// @notice Project as token1: a band too narrow for one aligned spacing empties the corridor and the first deploy
    /// reverts.
    function test_EmptyCorridor_NarrowBand_DeployReverts_ProjectToken1() public {
        // Narrow band, uninitialized pool.
        _runEmptyDeploy({wantProjectToken0: false, kind: Empty.Narrow, preInitialized: false});
    }

    /// @notice Native terminal token: a band too narrow for one aligned spacing empties the corridor and the first
    /// deploy reverts.
    function test_EmptyCorridor_NarrowBand_DeployReverts_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runEmptyDeploy({wantProjectToken0: false, kind: Empty.Narrow, preInitialized: false});
    }

    /// @notice A cash-out value of 0.98 against an issuance price of 1/0.99 leaves exactly one aligned spacing between
    /// them, which stays a valid corridor: the seed folds onto the floor bound and the ask fills the whole spacing.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runOneSpacing(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        _setPrices({cashOutValue: 0.98e18, issuanceRate: 0.99e18});
        // Project token0: cash-out tick -203 rounds inward to -200, issuance tick 100 to 0. Project token1: issuance
        // tick -101 rounds inward to 0, cash-out tick 202 to 200.
        (int24 lower, int24 upper) = _isProjectToken0 ? (int24(-200), int24(0)) : (int24(0), int24(200));
        _assertCorridor({expectedLower: lower, expectedUpper: upper});
        _accumulate(1e18);

        // Deploy permissionlessly into the one-spacing corridor.
        vm.prank(user);
        hook.deployPool(_PID);

        // The seed sits on the floor bound and one ask fills the whole corridor.
        (, int24 floor) = _ceilingAndFloor();
        assertEq(_spot(), TickMath.getSqrtPriceAtTick(floor), "the seed folds onto the floor bound");
        _assertPosition({
            tokenId: _askId(), lower: lower, upper: upper, projectIn: 1e18, terminalIn: 0, label: "one-spacing ask"
        });
        assertEq(_bidId(), 0, "nothing to bid with");
        _assertPlacedExactly({
            projectId: _PID,
            projectTokenAddr: address(_proj),
            terminalTokenAddr: address(_term),
            projectIn: 1e18,
            terminalIn: 0
        });
        _assertLedgersBacked();
    }

    /// @notice Project as token0: a corridor exactly one spacing wide deploys a full-width ask.
    function test_Corridor_OneSpacingWide_Deploys_ProjectToken0() public {
        // Project as token0.
        _runOneSpacing(true);
    }

    /// @notice Project as token1: a corridor exactly one spacing wide deploys a full-width ask.
    function test_Corridor_OneSpacingWide_Deploys_ProjectToken1() public {
        // Project as token1.
        _runOneSpacing(false);
    }

    /// @notice The lower bound rounds inward against its exact price. Its exact price sits half a tick above tick 0
    /// (1.00005 in pool terms), so the first aligned tick at or above it is 200, not 0: project token0 bounds a
    /// cash-out value of 1.00005 against an issuance price of 2; project token1 bounds an issuance price of 1/1.00005
    /// against a cash-out value of 0.5. Once the spot reaches the floor, the ask spans exactly that corridor.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runInwardLower(bool wantProjectToken0) internal {
        // Put the exact lower price half a tick above tick 0 in either ordering.
        _wire(wantProjectToken0);
        if (wantProjectToken0) _setPrices({cashOutValue: 1.00005e18, issuanceRate: 0.5e18});
        else _setPrices({cashOutValue: 0.5e18, issuanceRate: 1.00005e18});
        (uint160 cashOutSqrtPrice, uint160 issuanceSqrtPrice) = _exactPrices();
        uint160 exactLower = _isProjectToken0 ? cashOutSqrtPrice : issuanceSqrtPrice;
        assertGt(exactLower, TickMath.getSqrtPriceAtTick(0), "precondition: the exact lower price is above tick 0");
        assertLt(exactLower, TickMath.getSqrtPriceAtTick(1), "precondition: and below tick 1");
        // Upper: the exact price 2 is tick 6931, aligned down to 6800.
        _assertCorridor({expectedLower: 200, expectedUpper: 6800});

        // Deploy mid-corridor, trade to the floor and recycle: the ask spans the whole inward-rounded corridor.
        _deployAt({sqrtPriceX96: TickMath.getSqrtPriceAtTick(_midTick()), amount: 1e18});
        (, int24 floor) = _ceilingAndFloor();
        _swapTo(TickMath.getSqrtPriceAtTick(floor));
        (uint256 projectIn,) = _inventory();
        _recycle();
        _assertPosition({
            tokenId: _askId(), lower: 200, upper: 6800, projectIn: projectIn, terminalIn: 0, label: "corridor-wide ask"
        });
        assertGe(TickMath.getSqrtPriceAtTick(200), exactLower, "no ask reaches past the exact lower price");
        _assertLedgersBacked();
    }

    /// @notice Project as token0: the corridor's lower bound rounds inward to tick 200 against an exact price just
    /// above tick 0.
    function test_Corridor_LowerBoundRoundsInward_ProjectToken0() public {
        // Project as token0.
        _runInwardLower(true);
    }

    /// @notice Project as token1: the corridor's lower bound rounds inward to tick 200 against an exact price just
    /// above tick 0.
    function test_Corridor_LowerBoundRoundsInward_ProjectToken1() public {
        // Project as token1.
        _runInwardLower(false);
    }

    /// @notice Native terminal token: the corridor's lower bound rounds inward to tick 200 against an exact price just
    /// above tick 0.
    function test_Corridor_LowerBoundRoundsInward_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runInwardLower(false);
    }

    /// @notice With no cash-out value, project token1's lower bound is the issuance ceiling and rounds inward too: an
    /// issuance price of 1/1.00005 (half a tick above tick 0) gives [200, 600], never an ask at tick 0 above it.
    function test_Corridor_ZeroCashOut_LowerBoundRoundsInward_ProjectToken1() public {
        // No cash-out value, issuance half a tick above tick 0.
        _wire(false);
        _setPrices({cashOutValue: 0, issuanceRate: 1.00005e18});
        // The ceiling rounds inward to 200, with the two-spacing floor gap above it.
        _assertCorridor({expectedLower: 200, expectedUpper: 600});
    }

    /// @notice Native terminal token: with no cash-out value the issuance-ceiling lower bound rounds inward to 200.
    function test_Corridor_ZeroCashOut_LowerBoundRoundsInward_Native() public {
        // Same case as the ERC-20 project-token1 test, against the native terminal token.
        _nativeTerminal = true;
        test_Corridor_ZeroCashOut_LowerBoundRoundsInward_ProjectToken1();
    }

    /// @notice Corridor prices keep their precision at tiny rates. A weight of 2 project-token wei per terminal token
    /// (no cash-out value) bounds the ceiling at 3 wei (the gross rate plus one), 1/3e18 terminal tokens per project
    /// token: tick 403,499 in project-token0 terms, aligned down to 403,400 with the floor gap below it. A weight of 1
    /// bounds it at 2 wei: [407,000, 407,400]. Scaling before taking the root keeps the two weights' ceilings
    /// distinct.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runTinyIssuance(bool wantProjectToken0) internal {
        // A weight of 2 wei: ceiling bound 3 wei.
        _wire(wantProjectToken0);
        _setPrices({cashOutValue: 0, issuanceRate: 2});
        if (_isProjectToken0) _assertCorridor({expectedLower: 403_000, expectedUpper: 403_400});
        else _assertCorridor({expectedLower: -403_400, expectedUpper: -403_000});
        // A weight of 1 wei: ceiling bound 2 wei, a distinct corridor.
        _setPrices({cashOutValue: 0, issuanceRate: 1});
        if (_isProjectToken0) _assertCorridor({expectedLower: 407_000, expectedUpper: 407_400});
        else _assertCorridor({expectedLower: -407_400, expectedUpper: -407_000});
    }

    /// @notice Project as token0: tiny issuance rates keep their price precision in the corridor.
    function test_Corridor_TinyIssuanceRate_KeepsPrecision_ProjectToken0() public {
        // Project as token0.
        _runTinyIssuance(true);
    }

    /// @notice Project as token1: tiny issuance rates keep their price precision in the corridor.
    function test_Corridor_TinyIssuanceRate_KeepsPrecision_ProjectToken1() public {
        // Project as token1.
        _runTinyIssuance(false);
    }

    /// @notice Native terminal token: tiny issuance rates keep their price precision in the corridor.
    function test_Corridor_TinyIssuanceRate_KeepsPrecision_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runTinyIssuance(false);
    }

    /// @notice A cash-out value previewed at 2 wei per project token against an issuance rate of 1e33: the floor uses
    /// the preview's bound, 4e-18 terminal tokens per project token (tick -400,623 rounded inward to -400,600 in
    /// project-token0 terms), never -414,400, the tick a root taken before scaling yields.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runTinyCashOut(bool wantProjectToken0) internal {
        // A 2-wei cash-out preview against a huge issuance rate.
        _wire(wantProjectToken0);
        _setPrices({cashOutValue: 2, issuanceRate: 1e33});
        // The floor bound keeps the 4-wei precision in either ordering.
        if (_isProjectToken0) _assertCorridor({expectedLower: -400_600, expectedUpper: -345_600});
        else _assertCorridor({expectedLower: 345_600, expectedUpper: 400_600});
    }

    /// @notice Project as token0: a tiny cash-out value keeps its price precision in the floor bound.
    function test_Corridor_TinyCashOutValue_KeepsPrecision_ProjectToken0() public {
        // Project as token0.
        _runTinyCashOut(true);
    }

    /// @notice Project as token1: a tiny cash-out value keeps its price precision in the floor bound.
    function test_Corridor_TinyCashOutValue_KeepsPrecision_ProjectToken1() public {
        // Project as token1.
        _runTinyCashOut(false);
    }

    /// @notice Native terminal token: a tiny cash-out value keeps its price precision in the floor bound.
    function test_Corridor_TinyCashOutValue_KeepsPrecision_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runTinyCashOut(false);
    }

    /// @notice The floor is never below what a cash-out realizes. With no tax, a supply of 100e18 and a surplus of 250
    /// wei, the 1-token preview truncates 2.5 to 2 wei, but burning 2e18 tokens returns 5 (2.5 per token). The floor
    /// encodes the preview plus two, so the corridor's floor bound sits at or above 2.5e-18 terminal tokens per project
    /// token.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runFloorAboveRealized(bool wantProjectToken0) internal {
        // A surplus whose per-token preview truncates below what a larger cash-out realizes.
        _wire(wantProjectToken0);
        _setPrices({cashOutValue: 0, issuanceRate: 1e33});
        store.setTaxedCashOutCurve({projectId: _PID, surplus: 250, supply: 100e18, taxRate: 0});
        (uint256 cashOutPreview,) = _previews();
        assertEq(cashOutPreview, 2, "precondition: the preview truncates to 2");
        assertEq(store.currentTotalReclaimableSurplusOf(_PID, 2e18, 18, 0), 5, "precondition: 2e18 tokens reclaim 5");

        // The floor bound's price is at or above the realized 5 / 2e18 in either ordering.
        (int24 lower, int24 upper) = _corridor();
        if (_isProjectToken0) {
            assertEq(lower, -400_600, "floor bound");
            // Pool price is terminal per project: the floor bound's price is at least 5 / 2e18.
            assertGe(
                _cmpSquare({root: TickMath.getSqrtPriceAtTick(lower), amount0: 2e18, amount1: 5}),
                0,
                "floor at or above 2.5e-18"
            );
        } else {
            assertEq(upper, 400_600, "floor bound");
            // Pool price is project per terminal: the floor bound's price is at most 2e18 / 5.
            assertLe(
                _cmpSquare({root: TickMath.getSqrtPriceAtTick(upper), amount0: 5, amount1: 2e18}),
                0,
                "floor at or above 2.5e-18"
            );
        }
    }

    /// @notice Project as token0: the floor bound is at or above the price a cash-out actually realizes.
    function test_Corridor_FloorAtOrAboveRealizedCashOut_ProjectToken0() public {
        // Project as token0.
        _runFloorAboveRealized(true);
    }

    /// @notice Project as token1: the floor bound is at or above the price a cash-out actually realizes.
    function test_Corridor_FloorAtOrAboveRealizedCashOut_ProjectToken1() public {
        // Project as token1.
        _runFloorAboveRealized(false);
    }

    /// @notice The ceiling is never above what a payer mints at. A weight of 3 with a 10% reserve previews 2 (2.7
    /// truncated), but paying 10e18 terminal tokens mints 27 for the payer, a price of 10e18 / 27 terminal tokens per
    /// project token. The ceiling encodes (gross + 1) * 90% rounded up, 4, so the ceiling bound sits at or below it.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runCeilingBelowPayer(bool wantProjectToken0) internal {
        // A tiny weight with a 10% reserve, whose per-WAD preview truncates.
        _wire(wantProjectToken0);
        _setPrices({cashOutValue: 0, issuanceRate: 3});
        controller.setReservedPercent({projectId: _PID, reservedPercent: 1000});
        (, uint256 issuancePreview) = _previews();
        assertEq(issuancePreview, 2, "precondition: the preview truncates to 2");
        // A 10e18 payment mints 27 for the payer once the reserve is taken out.
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(_PID);
        uint256 gross = JBUniswapV4LPSplitHookMath.getProjectTokensOutForTerminalTokensIn({
            directory: IJBDirectory(address(directory)),
            projectId: _PID,
            terminalToken: address(_term),
            terminalTokenInAmount: 10e18,
            controller: address(controller),
            ruleset: ruleset
        });
        assertEq(gross * 9000 / 10_000, 27, "precondition: paying 10e18 mints 27 for the payer");

        // The ceiling bound's price is at or below the payer's 10e18 / 27 in either ordering.
        (int24 lower, int24 upper) = _corridor();
        if (_isProjectToken0) {
            assertEq(upper, 400_600, "ceiling bound");
            // Pool price is terminal per project: the ceiling bound's price is at most 10e18 / 27.
            assertLe(
                _cmpSquare({root: TickMath.getSqrtPriceAtTick(upper), amount0: 27, amount1: 10e18}),
                0,
                "ceiling at or below the payer"
            );
        } else {
            assertEq(lower, -400_600, "ceiling bound");
            // Pool price is project per terminal: the ceiling bound's price is at least 27 / 10e18.
            assertGe(
                _cmpSquare({root: TickMath.getSqrtPriceAtTick(lower), amount0: 10e18, amount1: 27}),
                0,
                "ceiling at or below the payer"
            );
        }
    }

    /// @notice Project as token0: the ceiling bound is at or below the price a payer actually mints at.
    function test_Corridor_CeilingAtOrBelowPayerPrice_ProjectToken0() public {
        // Project as token0.
        _runCeilingBelowPayer(true);
    }

    /// @notice Project as token1: the ceiling bound is at or below the price a payer actually mints at.
    function test_Corridor_CeilingAtOrBelowPayerPrice_ProjectToken1() public {
        // Project as token1.
        _runCeilingBelowPayer(false);
    }

    /// @notice Native terminal token: the ceiling bound is at or below the price a payer actually mints at.
    function test_Corridor_CeilingAtOrBelowPayerPrice_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runCeilingBelowPayer(false);
    }

    /// @notice Under a cash-out tax the 1-token preview truncates twice, so the floor bound is the preview plus two. A
    /// 21% tax, a supply of 1000e18 and a surplus of 5900 wei preview 3 per token, yet burning 0.7e18 tokens returns 3
    /// (about 4.29 per token), above a bound of 4. The floor encodes 5 (tick -398,4xx, rounded inward to -398,200).
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runTaxedFloor(bool wantProjectToken0) internal {
        // A taxed curve whose per-token preview truncates below what a smaller cash-out realizes.
        _wire(wantProjectToken0);
        _setPrices({cashOutValue: 0, issuanceRate: 1e33});
        store.setTaxedCashOutCurve({projectId: _PID, surplus: 5900, supply: 1000e18, taxRate: 2100});
        (uint256 cashOutPreview,) = _previews();
        assertEq(cashOutPreview, 3, "precondition: the preview truncates to 3");
        assertEq(
            store.currentTotalReclaimableSurplusOf(_PID, 0.7e18, 18, 0), 3, "precondition: 0.7e18 tokens reclaim 3"
        );

        // The floor bound's price is at or above the realized 3 / 0.7e18 in either ordering.
        (int24 lower, int24 upper) = _corridor();
        if (_isProjectToken0) {
            assertEq(lower, -398_200, "floor bound");
            // Pool price is terminal per project: the floor bound's price is at least 3 / 0.7e18.
            assertGe(
                _cmpSquare({root: TickMath.getSqrtPriceAtTick(lower), amount0: 0.7e18, amount1: 3}),
                0,
                "floor at or above 3 / 0.7e18"
            );
        } else {
            assertEq(upper, 398_200, "floor bound");
            // Pool price is project per terminal: the floor bound's price is at most 0.7e18 / 3.
            assertLe(
                _cmpSquare({root: TickMath.getSqrtPriceAtTick(upper), amount0: 3, amount1: 0.7e18}),
                0,
                "floor at or above 3 / 0.7e18"
            );
        }
    }

    /// @notice Project as token0: under a cash-out tax the floor bound is at or above the realized cash-out price.
    function test_Corridor_TaxedFloorAtOrAboveRealizedCashOut_ProjectToken0() public {
        // Project as token0.
        _runTaxedFloor(true);
    }

    /// @notice Project as token1: under a cash-out tax the floor bound is at or above the realized cash-out price.
    function test_Corridor_TaxedFloorAtOrAboveRealizedCashOut_ProjectToken1() public {
        // Project as token1.
        _runTaxedFloor(false);
    }

    /// @notice Native terminal token: under a cash-out tax the floor bound is at or above the realized cash-out price.
    function test_Corridor_TaxedFloorAtOrAboveRealizedCashOut_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runTaxedFloor(false);
    }

    /// @notice A nonzero weight always issues something at some payment size, even when the 1-WAD sample rounds to 0.
    /// A weight of 1 wei with a 10% reserve previews 0, yet paying 10e18 mints 9 wei for the payer. The ceiling is the
    /// bound ceil((1 + 1) * 90%) = 2 (tick 407,554 aligned down to 407,400 in project-token0 terms), at or below the
    /// payer's 10e18 / 9, not the full range of a project with no issuance.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runRoundedZeroIssuance(bool wantProjectToken0) internal {
        // A 1-wei weight with a 10% reserve previews zero issuance per WAD.
        _wire(wantProjectToken0);
        _setPrices({cashOutValue: 0, issuanceRate: 1});
        controller.setReservedPercent({projectId: _PID, reservedPercent: 1000});
        (, uint256 issuancePreview) = _previews();
        assertEq(issuancePreview, 0, "precondition: the preview rounds to 0");
        // A 10e18 payment still mints 9 for the payer once the reserve is taken out.
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(_PID);
        uint256 gross = JBUniswapV4LPSplitHookMath.getProjectTokensOutForTerminalTokensIn({
            directory: IJBDirectory(address(directory)),
            projectId: _PID,
            terminalToken: address(_term),
            terminalTokenInAmount: 10e18,
            controller: address(controller),
            ruleset: ruleset
        });
        assertEq(gross * 9000 / 10_000, 9, "precondition: paying 10e18 mints 9 for the payer");

        // The corridor is finite and its ceiling bound sits at or below the payer's 10e18 / 9.
        (int24 lower, int24 upper) = _corridor();
        if (_isProjectToken0) {
            assertEq(lower, 407_000, "corridor lower");
            assertEq(upper, 407_400, "ceiling bound");
            assertLe(
                _cmpSquare({root: TickMath.getSqrtPriceAtTick(upper), amount0: 9, amount1: 10e18}),
                0,
                "ceiling at or below the payer"
            );
        } else {
            assertEq(lower, -407_400, "ceiling bound");
            assertEq(upper, -407_000, "corridor upper");
            assertGe(
                _cmpSquare({root: TickMath.getSqrtPriceAtTick(lower), amount0: 10e18, amount1: 9}),
                0,
                "ceiling at or below the payer"
            );
        }
    }

    /// @notice Project as token0: a weight whose reserved-net preview rounds to zero still bounds the ceiling.
    function test_Corridor_RoundedZeroIssuanceIsBounded_ProjectToken0() public {
        // Project as token0.
        _runRoundedZeroIssuance(true);
    }

    /// @notice Project as token1: a weight whose reserved-net preview rounds to zero still bounds the ceiling.
    function test_Corridor_RoundedZeroIssuanceIsBounded_ProjectToken1() public {
        // Project as token1.
        _runRoundedZeroIssuance(false);
    }

    /// @notice Native terminal token: a weight whose reserved-net preview rounds to zero still bounds the ceiling.
    function test_Corridor_RoundedZeroIssuanceIsBounded_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runRoundedZeroIssuance(false);
    }

    /// @notice A nonzero weight whose 1-WAD sample itself rounds to 0 is not structurally zero: a weight of 1 against a
    /// conversion price of 1e19 previews 0 gross, yet paying 10e18 terminal tokens mints 1. The ceiling is the finite
    /// bound ceil((0 + 1) * 100%) = 1 project wei per terminal token, a pool price of 1e18 terminal per project (tick
    /// 414,486 aligned down to 414,400 in project-token0 terms) at or below the payer's 10e18, with the two-spacing
    /// floor gap; never the extreme price of a project with no issuance.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runGrossZeroIssuance(bool wantProjectToken0) internal {
        // A 1-wei weight priced through a 1e19 conversion: the gross 1-WAD sample rounds to zero.
        _wire(wantProjectToken0);
        _setPrices({cashOutValue: 0, issuanceRate: 1});
        prices.setPrice({projectId: _PID, pricingCurrency: _termCurrencyId(), unitCurrency: 1, price: 1e19});
        (, uint256 issuancePreview) = _previews();
        assertEq(issuancePreview, 0, "precondition: the preview rounds to 0");
        assertEq(_grossOut(1e18), 0, "precondition: the gross 1-WAD sample rounds to 0");
        assertEq(_grossOut(10e18), 1, "precondition: paying 10e18 mints 1");

        // The corridor is finite and its ceiling bound sits at or below the payer's 10e18 / 1.
        (int24 lower, int24 upper) = _corridor();
        if (_isProjectToken0) {
            assertEq(lower, 414_000, "corridor lower");
            assertEq(upper, 414_400, "ceiling bound");
            assertLe(
                _cmpSquare({root: TickMath.getSqrtPriceAtTick(upper), amount0: 1, amount1: 10e18}),
                0,
                "ceiling at or below the payer"
            );
        } else {
            assertEq(lower, -414_400, "ceiling bound");
            assertEq(upper, -414_000, "corridor upper");
            assertGe(
                _cmpSquare({root: TickMath.getSqrtPriceAtTick(lower), amount0: 10e18, amount1: 1}),
                0,
                "ceiling at or below the payer"
            );
        }
    }

    /// @notice Project as token0: a weight whose gross 1-WAD sample rounds to zero still bounds the ceiling.
    function test_Corridor_GrossZeroIssuanceIsBounded_ProjectToken0() public {
        // Project as token0.
        _runGrossZeroIssuance(true);
    }

    /// @notice Project as token1: a weight whose gross 1-WAD sample rounds to zero still bounds the ceiling.
    function test_Corridor_GrossZeroIssuanceIsBounded_ProjectToken1() public {
        // Project as token1.
        _runGrossZeroIssuance(false);
    }

    /// @notice Native terminal token: a weight whose gross 1-WAD sample rounds to zero still bounds the ceiling.
    function test_Corridor_GrossZeroIssuanceIsBounded_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runGrossZeroIssuance(false);
    }

    /// @notice With genuinely no issuance and no cash-out value, the range is full on the ceiling side but its floor
    /// side still stops at the cash-out bound of 2 wei per project token (tick -407,4xx rounded inward to -407,400 in
    /// project-token0 terms). Issuance is structurally zero for either cause: a zero weight, or a nonzero weight with
    /// every minted token reserved.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    /// @param allReserved Whether issuance is zeroed by a full reserve (otherwise by a zero weight).
    function _runNoIssuance(bool wantProjectToken0, bool allReserved) internal {
        // Zero issuance, either from a zero weight or from reserving every minted token.
        _wire(wantProjectToken0);
        _setPrices({cashOutValue: 0, issuanceRate: allReserved ? DEFAULT_WEIGHT : 0});
        if (allReserved) {
            controller.setReservedPercent({projectId: _PID, reservedPercent: uint16(JBConstants.MAX_RESERVED_PERCENT)});
        }
        // The ceiling side reaches the aligned TickMath limit; the floor side stops at the cash-out bound.
        if (_isProjectToken0) _assertCorridor({expectedLower: -407_400, expectedUpper: 887_000});
        else _assertCorridor({expectedLower: -887_200, expectedUpper: 407_400});
    }

    /// @notice Project as token0 with a zero weight: the floor side still stops at the cash-out bound.
    function test_Corridor_NoIssuance_FloorStopsAtCashOutBound_ProjectToken0() public {
        // Zero weight, project as token0.
        _runNoIssuance({wantProjectToken0: true, allReserved: false});
    }

    /// @notice Project as token1 with a zero weight: the floor side still stops at the cash-out bound.
    function test_Corridor_NoIssuance_FloorStopsAtCashOutBound_ProjectToken1() public {
        // Zero weight, project as token1.
        _runNoIssuance({wantProjectToken0: false, allReserved: false});
    }

    /// @notice Native terminal token with a zero weight: the floor side still stops at the cash-out bound.
    function test_Corridor_NoIssuance_FloorStopsAtCashOutBound_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runNoIssuance({wantProjectToken0: false, allReserved: false});
    }

    /// @notice Project as token0 with every minted token reserved: the floor side still stops at the cash-out bound.
    function test_Corridor_AllReserved_FloorStopsAtCashOutBound_ProjectToken0() public {
        // Full reserve, project as token0.
        _runNoIssuance({wantProjectToken0: true, allReserved: true});
    }

    /// @notice Project as token1 with every minted token reserved: the floor side still stops at the cash-out bound.
    function test_Corridor_AllReserved_FloorStopsAtCashOutBound_ProjectToken1() public {
        // Full reserve, project as token1.
        _runNoIssuance({wantProjectToken0: false, allReserved: true});
    }

    /// @notice Native terminal token with every minted token reserved: the floor side still stops at the cash-out
    /// bound.
    function test_Corridor_AllReserved_FloorStopsAtCashOutBound_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runNoIssuance({wantProjectToken0: false, allReserved: true});
    }

    /// @notice A cash-out preview of 0 still bounds the floor, and the floor wins over the zero-cash-out geometry. A
    /// six-decimal terminal in the base currency at weight 2e24 issues at 0.5 raw units per project token, while a
    /// surplus of 99 raw units over a supply of 100e18 previews 0 yet realizes 0.99 per token when the supply burns.
    /// The cash-out bound (2 raw units) is above the issuance price, so the corridor is empty and has no seed.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runZeroPreviewFloor(bool wantProjectToken0) internal {
        // A six-decimal terminal token that is the project's base currency.
        _wire(wantProjectToken0);
        uint32 currency = _termCurrencyId();
        terminal.setAccountingContext({projectId: _PID, token: address(_term), currency: currency, decimals: 6});
        controller.setBaseCurrency({projectId: _PID, currency: currency});
        // Issuance of 0.5 raw units per token, and a surplus whose per-token preview truncates to zero.
        _setPrices({cashOutValue: 0, issuanceRate: 2e24});
        store.setTaxedCashOutCurve({projectId: _PID, surplus: 99, supply: 100e18, taxRate: 0});
        (uint256 cashOutPreview, uint256 issuancePreview) = _previews();
        assertEq(cashOutPreview, 0, "precondition: the cash-out preview rounds to 0");
        assertEq(issuancePreview, 2e36, "precondition: 2e36 project wei per 1e18 raw units (0.5 per token)");
        assertEq(store.currentTotalReclaimableSurplusOf(_PID, 100e18, 6, 0), 99, "precondition: the supply reclaims 99");

        // The 2-raw-unit floor bound crosses the issuance price, so the corridor is empty and unseeded.
        _assertCorridorEmpty();
        assertEq(_seed(), 0, "no seed price");
    }

    /// @notice Project as token0: a zero cash-out preview still bounds the floor, which empties the corridor.
    function test_Corridor_ZeroCashOutPreview_FloorEmptiesCorridor_ProjectToken0() public {
        // Project as token0.
        _runZeroPreviewFloor(true);
    }

    /// @notice Project as token1: a zero cash-out preview still bounds the floor, which empties the corridor.
    function test_Corridor_ZeroCashOutPreview_FloorEmptiesCorridor_ProjectToken1() public {
        // Project as token1.
        _runZeroPreviewFloor(false);
    }

    /// @notice Native terminal token: a zero cash-out preview still bounds the floor, which empties the corridor.
    function test_Corridor_ZeroCashOutPreview_FloorEmptiesCorridor_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runZeroPreviewFloor(false);
    }

    /// @notice For an ordinary 18-decimal project with no surplus (weights 1e18 to 1e24 per terminal token), the
    /// cash-out bound sits hundreds of thousands of ticks below the issuance price, so the floor lift never binds: the
    /// corridor is exactly the two-spacing gap below the aligned issuance ceiling.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    /// @param weight The issuance weight, bounded to [1e18, 1e24].
    /// @param reservedPercent The reserved percent, bounded to [0, 9000].
    function testFuzz_Corridor_ZeroSurplus_FloorLiftNeverBinds(
        bool wantProjectToken0,
        uint256 weight,
        uint16 reservedPercent
    )
        public
    {
        // No cash-out value, an ordinary weight and reserve.
        _wire(wantProjectToken0);
        _setPrices({cashOutValue: 0, issuanceRate: bound(weight, 1e18, 1e24)});
        controller.setReservedPercent({projectId: _PID, reservedPercent: uint16(bound(reservedPercent, 0, 9000))});
        (, uint160 ceilingSqrtPrice) = _exactPrices();
        int24 ceilingTick = TickMath.getTickAtSqrtPrice(ceilingSqrtPrice);
        if (_isProjectToken0) {
            // The ceiling is the upper bound, aligned down, with the two-spacing gap below it.
            int24 upper = _alignDown(ceilingTick);
            _assertCorridor({expectedLower: upper - 2 * _SPACING, expectedUpper: upper});
        } else {
            // The ceiling is the lower bound: round its tick up, align it up, and expect the gap above it.
            if (TickMath.getSqrtPriceAtTick(ceilingTick) < ceilingSqrtPrice) ceilingTick++;
            int24 lower = -_alignDown(-ceilingTick);
            _assertCorridor({expectedLower: lower, expectedUpper: lower + 2 * _SPACING});
        }
    }

    /// @notice For realistic rates the conservative bounds move each price by less than one tick from its preview:
    /// the floor at most a factor 1.0001 above the cash-out preview and the ceiling at most that factor below the
    /// issuance preview (in project price), so each aligned bound moves by at most the one-spacing tick rounding.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    /// @param cashOutValue The cash-out value per project token, bounded to [1e9, 1e30].
    /// @param weight The issuance weight, bounded to [1e18, 1e30].
    /// @param reservedPercent The reserved percent, bounded to [0, 9000].
    function testFuzz_Corridor_RealisticRates_MoveLessThanOneTick(
        bool wantProjectToken0,
        uint256 cashOutValue,
        uint256 weight,
        uint16 reservedPercent
    )
        public
    {
        // Realistic cash-out value, weight and reserve.
        _wire(wantProjectToken0);
        weight = bound(weight, 1e18, 1e30);
        reservedPercent = uint16(bound(reservedPercent, 0, 9000));
        _setPrices({cashOutValue: bound(cashOutValue, 1e9, 1e30), issuanceRate: weight});
        controller.setReservedPercent({projectId: _PID, reservedPercent: reservedPercent});
        // Compare the encoded prices against the previews, and against the previews moved by one tick (1.0001).
        (uint256 cashOut, uint256 issuance) = _previews();
        (uint160 floorSqrtPrice, uint160 ceilingSqrtPrice) = _exactPrices();
        if (_isProjectToken0) {
            // Pool price is terminal per project.
            assertGe(
                _cmpSquare({root: floorSqrtPrice, amount0: 1e18, amount1: cashOut}), 0, "floor at or above the preview"
            );
            assertLe(
                _cmpSquare({root: floorSqrtPrice, amount0: 1e22, amount1: cashOut * 10_001}), 0, "floor within one tick"
            );
            assertLe(
                _cmpSquare({root: ceilingSqrtPrice, amount0: issuance, amount1: 1e18}),
                0,
                "ceiling at or below the preview"
            );
            assertGe(
                _cmpSquare({root: ceilingSqrtPrice, amount0: issuance * 10_001, amount1: 1e22}),
                0,
                "ceiling within one tick"
            );
        } else {
            // Pool price is project per terminal.
            assertLe(
                _cmpSquare({root: floorSqrtPrice, amount0: cashOut, amount1: 1e18}), 0, "floor at or above the preview"
            );
            assertGe(
                _cmpSquare({root: floorSqrtPrice, amount0: cashOut * 10_001, amount1: 1e22}), 0, "floor within one tick"
            );
            assertGe(
                _cmpSquare({root: ceilingSqrtPrice, amount0: 1e18, amount1: issuance}),
                0,
                "ceiling at or below the preview"
            );
            assertLe(
                _cmpSquare({root: ceilingSqrtPrice, amount0: 1e22, amount1: issuance * 10_001}),
                0,
                "ceiling within one tick"
            );
        }
    }

    /// @notice Each corridor price encodes conservatively and tightly: the cash-out floor at or above its bound (the
    /// preview plus two) in project price, the issuance ceiling at or below its bound (the gross rate plus one, no
    /// reserve here), each within one unit of root precision (one, or 2^64 when the ratio is at least 2^64 and the
    /// root is shifted), and clamped to TickMath's limits only when the exact price lies past them.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    /// @param cashOutValue The cash-out value per project token, bounded so the bound (value plus two) cannot overflow.
    /// @param issuanceRate The issuance rate, bounded to [1, type(uint112).max].
    function testFuzz_Encoder_FloorAtOrAboveCeilingAtOrBelow(
        bool wantProjectToken0,
        uint256 cashOutValue,
        uint256 issuanceRate
    )
        public
    {
        // Any cash-out value whose bound fits, and any nonzero weight the ruleset can hold.
        cashOutValue = bound(cashOutValue, 0, type(uint256).max - 2);
        issuanceRate = bound(issuanceRate, 1, type(uint112).max);
        _wire(wantProjectToken0);
        _setPrices({cashOutValue: cashOutValue, issuanceRate: issuanceRate});
        (uint160 cashOutSqrtPrice, uint160 issuanceSqrtPrice) = _exactPrices();
        // Pool price is token1 per token0. A higher project price is a higher pool price for project token0 (round
        // up) and a lower one for project token1 (round down); the ceiling rounds the other way.
        if (_isProjectToken0) {
            _assertEncodes({sqrtPriceX96: cashOutSqrtPrice, amount1: cashOutValue + 2, amount0: 1e18, roundUp: true});
            _assertEncodes({sqrtPriceX96: issuanceSqrtPrice, amount1: 1e18, amount0: issuanceRate + 1, roundUp: false});
        } else {
            _assertEncodes({sqrtPriceX96: cashOutSqrtPrice, amount1: 1e18, amount0: cashOutValue + 2, roundUp: false});
            _assertEncodes({sqrtPriceX96: issuanceSqrtPrice, amount1: issuanceRate + 1, amount0: 1e18, roundUp: true});
        }
    }

    /// @notice Deterministic encodings around every scaling and clamping threshold of project token0's cash-out floor
    /// (pool price (rate + 2) / 1e18, rounded up): the 2^64 and 2^128 ratio thresholds and MAX_SQRT_PRICE.
    /// Representable prices on either side of each threshold encode unclamped; only prices past the limit clamp to it.
    function test_Encoder_ClampsOnlyPastTheLimits_ProjectToken0() public {
        // The bound whose exact price is MAX_SQRT_PRICE - 1.
        uint256 maxPrice = TickMath.MAX_SQRT_PRICE - 1;
        uint256 atMax = mulDiv({x: maxPrice, y: maxPrice * 1e18, denominator: 2 ** 192});
        _wire(true);
        // Around the 2^64 ratio threshold and well below the limit, nothing clamps.
        _assertFloorEncodes({cashOutBound: 2 ** 64 * 1e18 - 1, clamped: false});
        _assertFloorEncodes({cashOutBound: 2 ** 64 * 1e18, clamped: false});
        _assertFloorEncodes({cashOutBound: 2 ** 64 * 1e18 + 1, clamped: false});
        _assertFloorEncodes({cashOutBound: 2 ** 100 * 1e18, clamped: false});
        _assertFloorEncodes({cashOutBound: atMax - 2 ** 100, clamped: false});
        // The exact price is just under the limit, but rounding up at 2^64 precision lands on or past it.
        _assertFloorEncodes({cashOutBound: atMax, clamped: true});
        // Past the limit, through the 2^128 ratio threshold and up to saturation, every encoding clamps.
        _assertFloorEncodes({cashOutBound: atMax + 2 ** 100, clamped: true});
        _assertFloorEncodes({cashOutBound: 2 ** 128 * 1e18 - 1, clamped: true});
        _assertFloorEncodes({cashOutBound: 2 ** 128 * 1e18, clamped: true});
        _assertFloorEncodes({cashOutBound: type(uint256).max, clamped: true});
        // A saturated floor empties the corridor.
        _assertCorridorEmpty();
    }

    /// @notice Project token1's cash-out floor (pool price 1e18 / (rate + 2), rounded down) reaches MIN_SQRT_PRICE:
    /// a price just above it encodes unclamped, one just below it clamps.
    function test_Encoder_ClampsOnlyPastTheLimits_ProjectToken1() public {
        // The bound whose exact price is MIN_SQRT_PRICE.
        uint256 atMin =
            mulDiv({x: 1e18, y: 2 ** 192, denominator: uint256(TickMath.MIN_SQRT_PRICE) * TickMath.MIN_SQRT_PRICE});
        _wire(false);
        // A smaller bound is a higher pool price, above the limit; a larger one is past it.
        _assertFloorEncodes({cashOutBound: atMin - 2 ** 160, clamped: false});
        _assertFloorEncodes({cashOutBound: atMin + 2 ** 160, clamped: true});
        _assertFloorEncodes({cashOutBound: type(uint256).max, clamped: true});
        // A saturated floor empties the corridor.
        _assertCorridorEmpty();
    }

    /// @notice An empty corridor has no seed price, however it went empty.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    function _runNoSeed(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        // Try every way of emptying the corridor.
        for (uint8 kind; kind <= uint8(Empty.Narrow); kind++) {
            _emptyEconomics(Empty(kind));
            assertEq(_seed(), 0, "no seed price");
        }
    }

    /// @notice Project as token0: every kind of empty corridor has no seed price.
    function test_EmptyCorridor_NoSeedPrice_ProjectToken0() public {
        // Project as token0.
        _runNoSeed(true);
    }

    /// @notice Project as token1: every kind of empty corridor has no seed price.
    function test_EmptyCorridor_NoSeedPrice_ProjectToken1() public {
        // Project as token1.
        _runNoSeed(false);
    }

    // ─── Empty corridor lifecycle (both orderings) ───

    /// @notice Live ask and bid, then the corridor goes empty: the recycle retires both, mints nothing and holds every
    /// token (principal, forgiven fee, new reserved tokens) exactly in the ledgers. A second recycle has nothing to
    /// retire and reverts. Normal economics redeploy everything into fresh positions.
    /// @param wantProjectToken0 Whether the project token sorts as token0.
    /// @param kind How the corridor is emptied.
    function _runEmptyRecycle(bool wantProjectToken0, Empty kind) internal {
        // Start with both an ask and a bid live at mid-corridor, each holding principal.
        _wire(wantProjectToken0);
        int24 mid = _deployBothAtMid({projectAmount: 1e18, terminalAmount: 0.5e18});
        (int24 lower, int24 upper) = _corridor();
        uint256 oldAsk = _askId();
        uint256 oldBid = _bidId();
        (uint256 projectHeld, uint256 terminalHeld) = _livePrincipal();
        assertGt(projectHeld, 0, "precondition: the ask holds project principal");
        assertGt(terminalHeld, 0, "precondition: the bid holds terminal principal");
        // Record the ledgers, then add a forgiven fee and new reserved tokens for the recycle to hold.
        uint256 projectLedger = _projLedger();
        uint256 terminalLedger = _termLedger();
        uint256 fee = 0.05e18;
        uint256 newTokens = 0.2e18;
        _addTerminalFee({tokenId: oldAsk, amount: fee});
        _accumulate(newTokens);

        _emptyAndCheck(kind);

        // The recycle reports no live positions.
        uint256 nextId = positionManager.nextTokenId();
        vm.expectEmit(true, true, true, true, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAdded({
            projectId: _PID, terminalToken: address(_term), askTokenId: 0, bidTokenId: 0, caller: user
        });
        _recycle();

        // Both old positions are burned, nothing is minted, and the pool stays deployed.
        assertEq(_askId(), 0, "empty: no ask");
        assertEq(_bidId(), 0, "empty: no bid");
        assertEq(positionManager.nextTokenId(), nextId, "empty: nothing minted");
        _assertRetired({tokenId: oldAsk, label: "empty: the old ask is burned"});
        _assertRetired({tokenId: oldBid, label: "empty: the old bid is burned"});
        assertTrue(hook.isPoolDeployed({projectId: _PID, terminalToken: address(_term)}), "the pool stays deployed");
        // Every token, principal, fee and new reserved tokens alike, sits in the ledgers.
        assertEq(_projLedger(), projectLedger + projectHeld + newTokens, "every project token is ledgered");
        assertEq(_termLedger(), terminalLedger + terminalHeld + fee, "every terminal token is ledgered");
        _assertLedgersBacked();
        // Only V4's rounding (at most one unit per burned position) stays in the pool; nothing else is left.
        assertEq(
            _proj.balanceOf(address(positionManager)),
            positionManager.poolLocked(address(_proj)),
            "the PositionManager holds only pool reserves"
        );
        assertEq(
            _termBalanceOf(address(positionManager)),
            positionManager.poolLocked(Currency.unwrap(_termCurrency())),
            "the PositionManager holds only pool reserves"
        );
        assertLe(
            _proj.balanceOf(address(positionManager)), positionManager.burnCallCount(), "project rounding in the pool"
        );
        assertLe(
            _termBalanceOf(address(positionManager)), positionManager.burnCallCount(), "terminal rounding in the pool"
        );

        // Nothing left to retire: the recycle refuses and changes nothing.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_EmptyCorridor.selector, _PID, address(_term)
            )
        );
        _recycle();

        // The corridor reopens: the held inventory redeploys around the unchanged mid-corridor spot.
        _restoreEconomics();
        _assertCorridor({expectedLower: lower, expectedUpper: upper});
        uint256 projectTotal = _projLedger();
        uint256 terminalTotal = _termLedger();
        _recycle();
        // Each side rests on its own side of the spot, in fresh ids, with only V4 rounding left ledgered.
        (int24 bidLower, int24 bidUpper) = _isProjectToken0 ? (lower, mid) : (mid, upper);
        (int24 askLower, int24 askUpper) = _isProjectToken0 ? (mid, upper) : (lower, mid);
        (uint256 askPlaced,) = _assertPosition({
            tokenId: _askId(),
            lower: askLower,
            upper: askUpper,
            projectIn: projectTotal,
            terminalIn: 0,
            label: "redeployed ask"
        });
        (, uint256 bidPlaced) = _assertPosition({
            tokenId: _bidId(),
            lower: bidLower,
            upper: bidUpper,
            projectIn: 0,
            terminalIn: terminalTotal,
            label: "redeployed bid"
        });
        assertGe(_askId(), nextId, "redeployed ask is a fresh id");
        assertGe(_bidId(), nextId, "redeployed bid is a fresh id");
        assertEq(_projLedger(), projectTotal - askPlaced, "the held project tokens redeployed");
        assertEq(_termLedger(), terminalTotal - bidPlaced, "the held terminal tokens redeployed");
        _assertLedgersBacked();
    }

    /// @notice Project as token0: an inverted corridor retires both live positions into the ledgers, refuses a second
    /// recycle, and redeploys once it reopens.
    function test_EmptyCorridor_RecycleRetiresAndHolds_ProjectToken0() public {
        // Inverted corridor, project as token0.
        _runEmptyRecycle({wantProjectToken0: true, kind: Empty.Inverted});
    }

    /// @notice Project as token1: an inverted corridor retires both live positions into the ledgers, refuses a second
    /// recycle, and redeploys once it reopens.
    function test_EmptyCorridor_RecycleRetiresAndHolds_ProjectToken1() public {
        // Inverted corridor, project as token1.
        _runEmptyRecycle({wantProjectToken0: false, kind: Empty.Inverted});
    }

    /// @notice Project as token0: a too-narrow band retires both live positions into the ledgers, refuses a second
    /// recycle, and redeploys once it reopens.
    function test_EmptyCorridor_NarrowBand_RecycleRetiresAndHolds_ProjectToken0() public {
        // Narrow band, project as token0.
        _runEmptyRecycle({wantProjectToken0: true, kind: Empty.Narrow});
    }

    /// @notice Project as token1: a too-narrow band retires both live positions into the ledgers, refuses a second
    /// recycle, and redeploys once it reopens.
    function test_EmptyCorridor_NarrowBand_RecycleRetiresAndHolds_ProjectToken1() public {
        // Narrow band, project as token1.
        _runEmptyRecycle({wantProjectToken0: false, kind: Empty.Narrow});
    }

    /// @notice Native terminal token: a too-narrow band retires both live positions into the ledgers, refuses a second
    /// recycle, and redeploys once it reopens.
    function test_EmptyCorridor_NarrowBand_RecycleRetiresAndHolds_Native() public {
        // The native terminal always sorts the project as token1.
        _nativeTerminal = true;
        _runEmptyRecycle({wantProjectToken0: false, kind: Empty.Narrow});
    }

    // ─── Harness ───

    /// @notice Deliver `amount` reserved project tokens to the hook (accumulate only).
    /// @param amount The project tokens delivered.
    function _accumulate(uint256 amount) internal {
        // The controller mints and approves the tokens, as a reserved-token distribution does.
        _proj.mint({to: address(controller), amount: amount});
        vm.startPrank(address(controller));
        _proj.approve({spender: address(hook), amount: amount});
        // Capped gas keeps the call to intake only, so nothing deploys or recycles inline.
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: _PID, token: address(_proj), amount: amount, groupId: 1})
        );
        vm.stopPrank();
    }

    /// @notice Give a live position a collectable terminal-side LP fee that lands whole in the bid ledger, funding the
    /// PositionManager for it: the cut is forgiven (the fee project has no terminal for this fresh terminal token) and
    /// the project's terminal rejects the remainder, so it falls back to the ledger.
    /// @param tokenId The position that earns the fee.
    /// @param amount The terminal-token fee.
    function _addTerminalFee(uint256 tokenId, uint256 amount) internal {
        // A rejected add-to-balance sends the fee into the bid ledger.
        terminal.setRevertOnAddToBalance(true);
        // Book the fee on whichever side of the pool is the terminal token.
        if (_isProjectToken0) positionManager.setCollectableFees({tokenId: tokenId, amount0: 0, amount1: amount});
        else positionManager.setCollectableFees({tokenId: tokenId, amount0: amount, amount1: 0});
        // Back the fee with real tokens so the collect pays it.
        _fundTerm({to: address(positionManager), amount: amount});
    }

    /// @notice `tick` rounded down to the spacing grid.
    /// @param tick The tick to align.
    /// @return aligned The largest multiple of `_SPACING` at or below `tick`.
    function _alignDown(int24 tick) internal pure returns (int24 aligned) {
        // Intentionally divide before multiplying to align to the spacing grid.
        // forge-lint: disable-next-line(divide-before-multiply)
        aligned = (tick / _SPACING) * _SPACING;
        // Solidity division truncates toward zero, so a negative tick needs one more spacing down.
        return aligned > tick ? aligned - _SPACING : aligned;
    }

    /// @notice The project's live ask position id.
    /// @return tokenId The ask id, or 0 when no ask is live.
    function _askId() internal view returns (uint256 tokenId) {
        // Read the hook's ask mapping for this project and terminal token.
        return hook.askTokenIdOf({projectId: _PID, terminalToken: address(_term)});
    }

    /// @notice Assert the corridor is exactly [`expectedLower`, `expectedUpper`].
    /// @param expectedLower The expected lower tick.
    /// @param expectedUpper The expected upper tick.
    function _assertCorridor(int24 expectedLower, int24 expectedUpper) internal view {
        // Compare both bounds of the hook-math corridor.
        (int24 lower, int24 upper) = _corridor();
        assertEq(lower, expectedLower, "corridor lower");
        assertEq(upper, expectedUpper, "corridor upper");
    }

    /// @notice Assert the corridor is empty, which the hook math reports as [0, 0].
    function _assertCorridorEmpty() internal view {
        // Both bounds are zero for an empty corridor.
        (int24 lower, int24 upper) = _corridor();
        assertEq(lower, 0, "empty corridor: lower is 0");
        assertEq(upper, 0, "empty corridor: upper is 0");
    }

    /// @notice `sqrtPriceX96` is sqrt(amount1 / amount0) * 2^96 rounded up (or down), to `step` precision, then clamped
    /// to [MIN_SQRT_PRICE, MAX_SQRT_PRICE - 1]. A result on either limit is accepted only when the exact price puts the
    /// rounded encoding itself on or past that limit, so a clamp of a representable price fails.
    /// @param sqrtPriceX96 The encoded sqrt price under test.
    /// @param amount1 The price numerator (token1 amount).
    /// @param amount0 The price denominator (token0 amount).
    /// @param roundUp Whether the encoding rounds up (otherwise down).
    function _assertEncodes(uint160 sqrtPriceX96, uint256 amount1, uint256 amount0, bool roundUp) internal pure {
        // Ratios of at least 2^64 have their root shifted, so their precision is 2^64 instead of one.
        uint256 step = amount1 / amount0 < 2 ** 64 ? 1 : 2 ** 64;
        uint256 maxPrice = TickMath.MAX_SQRT_PRICE - 1;
        uint256 minPrice = TickMath.MIN_SQRT_PRICE;
        // On the upper limit, the exact price must put the rounded encoding at or past it.
        if (sqrtPriceX96 == maxPrice) {
            // Rounded up, the encoding exceeds the exact root by under one step; rounded down, it never exceeds it.
            if (roundUp) {
                assertLt(
                    _cmpSquare({root: maxPrice - step, amount0: amount0, amount1: amount1}),
                    0,
                    "max clamp: exact above max - step"
                );
            } else {
                assertLe(
                    _cmpSquare({root: maxPrice, amount0: amount0, amount1: amount1}),
                    0,
                    "max clamp: exact at or above max"
                );
            }
            return;
        }
        // On the lower limit, the exact price must put the rounded encoding at or below it.
        if (sqrtPriceX96 == minPrice) {
            if (roundUp) {
                assertGe(
                    _cmpSquare({root: minPrice, amount0: amount0, amount1: amount1}),
                    0,
                    "min clamp: exact at or below min"
                );
            } else {
                assertGt(
                    _cmpSquare({root: minPrice + step, amount0: amount0, amount1: amount1}),
                    0,
                    "min clamp: exact below min + step"
                );
            }
            return;
        }
        // Unclamped, the encoding sits on the conservative side of the exact root and within one step of it.
        if (roundUp) {
            assertGe(
                _cmpSquare({root: sqrtPriceX96, amount0: amount0, amount1: amount1}),
                0,
                "rounded up: at or above the exact price"
            );
            assertLt(
                _cmpSquare({root: sqrtPriceX96 - step, amount0: amount0, amount1: amount1}),
                0,
                "rounded up: within one step"
            );
        } else {
            assertLe(
                _cmpSquare({root: sqrtPriceX96, amount0: amount0, amount1: amount1}),
                0,
                "rounded down: at or below the exact price"
            );
            assertGt(
                _cmpSquare({root: sqrtPriceX96 + step, amount0: amount0, amount1: amount1}),
                0,
                "rounded down: within one step"
            );
        }
    }

    /// @notice Set the cash-out floor's bound to `cashOutBound` (the preview plus two, saturating) and check its
    /// encoding: conservative, tight, and on the TickMath limit exactly when `clamped`.
    /// @param cashOutBound The floor bound to produce, which is the cash-out preview plus two (or saturated).
    /// @param clamped Whether the encoding must sit on the TickMath limit.
    function _assertFloorEncodes(uint256 cashOutBound, bool clamped) internal {
        // A saturated bound comes from a saturated preview; otherwise the preview is the bound minus two.
        _setPrices({cashOutValue: cashOutBound == type(uint256).max ? cashOutBound : cashOutBound - 2, issuanceRate: 1});
        (uint160 cashOutSqrtPrice,) = _exactPrices();
        if (_isProjectToken0) {
            // Project token0: the floor is (bound) / 1e18 rounded up, clamped at the maximum.
            _assertEncodes({sqrtPriceX96: cashOutSqrtPrice, amount1: cashOutBound, amount0: 1e18, roundUp: true});
            if (clamped) assertEq(cashOutSqrtPrice, TickMath.MAX_SQRT_PRICE - 1, "clamped to the maximum");
            else assertLt(cashOutSqrtPrice, TickMath.MAX_SQRT_PRICE - 1, "representable: not clamped");
        } else {
            // Project token1: the floor is 1e18 / (bound) rounded down, clamped at the minimum.
            _assertEncodes({sqrtPriceX96: cashOutSqrtPrice, amount1: 1e18, amount0: cashOutBound, roundUp: false});
            if (clamped) assertEq(cashOutSqrtPrice, TickMath.MIN_SQRT_PRICE, "clamped to the minimum");
            else assertGt(cashOutSqrtPrice, TickMath.MIN_SQRT_PRICE, "representable: not clamped");
        }
    }

    /// @notice The hook holds exactly the project's ledgers (no fee claims, no other project uses these tokens).
    function _assertLedgersBacked() internal view {
        // Each ledger equals the hook's balance of that token.
        assertEq(_proj.balanceOf(address(hook)), _projLedger(), "project ledger equals the hook's project balance");
        assertEq(_termBalanceOf(address(hook)), _termLedger(), "terminal ledger equals the hook's terminal balance");
    }

    /// @notice Assert `tokenId` is live on exactly `[lower, upper]`, holding only the currency it was offered
    /// (`projectIn` or `terminalIn`) at exactly its liquidity's cost, and as much liquidity as that inventory pays for:
    /// only V4 rounding of the offered inventory is left unplaced.
    /// @param tokenId The position to check.
    /// @param lower The expected lower tick.
    /// @param upper The expected upper tick.
    /// @param projectIn The project inventory offered to the position.
    /// @param terminalIn The terminal inventory offered to the position.
    /// @param label A prefix for the assertion messages.
    /// @return projectPlaced The project tokens the position holds.
    /// @return terminalPlaced The terminal tokens the position holds.
    function _assertPosition(
        uint256 tokenId,
        int24 lower,
        int24 upper,
        uint256 projectIn,
        uint256 terminalIn,
        string memory label
    )
        internal
        view
        returns (uint256 projectPlaced, uint256 terminalPlaced)
    {
        // The position is live with liquidity on exactly the expected, aligned ticks.
        assertNotEq(tokenId, 0, string.concat(label, ": live"));
        (int24 l, int24 u, uint128 liquidity,,) = _position(tokenId);
        assertGt(liquidity, 0, string.concat(label, ": liquidity"));
        assertEq(l, lower, string.concat(label, ": tickLower"));
        assertEq(u, upper, string.concat(label, ": tickUpper"));
        assertEq(l % _SPACING, 0, string.concat(label, ": tickLower aligned"));
        assertEq(u % _SPACING, 0, string.concat(label, ": tickUpper aligned"));
        // It holds only the offered currency, within the offered inventory.
        (projectPlaced, terminalPlaced) = _costSidesOf({tokenId: tokenId, projectTokenAddr: address(_proj)});
        if (projectIn == 0) assertEq(projectPlaced, 0, string.concat(label, ": no project side"));
        if (terminalIn == 0) assertEq(terminalPlaced, 0, string.concat(label, ": no terminal side"));
        assertLe(projectPlaced, projectIn, string.concat(label, ": project side within inventory"));
        assertLe(terminalPlaced, terminalIn, string.concat(label, ": terminal side within inventory"));
        // Its liquidity is the most the offered inventory pays for.
        _assertMaximalLiquidity({tokenId: tokenId, available: projectIn + terminalIn});
    }

    /// @notice Assert `tokenId` does not exist in the PositionManager (it was burned).
    /// @param tokenId The position expected to be burned.
    /// @param label The assertion message.
    function _assertRetired(uint256 tokenId, string memory label) internal view {
        // A burned position's `exists` flag is cleared.
        (,,,,,, bool exists) = positionManager._positions(tokenId);
        assertFalse(exists, label);
    }

    /// @notice The project's live bid position id.
    /// @return tokenId The bid id, or 0 when no bid is live.
    function _bidId() internal view returns (uint256 tokenId) {
        // Read the hook's bid mapping for this project and terminal token.
        return hook.bidTokenIdOf({projectId: _PID, terminalToken: address(_term)});
    }

    /// @notice The issuance-ceiling tick and the cash-out-floor tick of the corridor, ordering-aware.
    /// @return ceiling The corridor bound at the issuance price.
    /// @return floor The corridor bound at the cash-out price.
    function _ceilingAndFloor() internal view returns (int24 ceiling, int24 floor) {
        // With the project as token0 the pool price rises with the project price, so the ceiling is the upper bound.
        (int24 lower, int24 upper) = _corridor();
        (ceiling, floor) = _isProjectToken0 ? (upper, lower) : (lower, upper);
    }

    /// @notice Compare `root^2 * amount0` with `amount1 * 2^192` exactly in 768 bits (-1, 0 or 1), for any 256-bit
    /// inputs.
    /// @param root The sqrt price to square.
    /// @param amount0 The multiplier of the square.
    /// @param amount1 The multiplier of 2^192.
    /// @return comparison 1 when the left side is larger, -1 when it is smaller, 0 when they are equal.
    function _cmpSquare(uint256 root, uint256 amount0, uint256 amount1) internal pure returns (int256 comparison) {
        // Square the root into two words, then multiply both words by `amount0` into three words (w2, w1, w0).
        (uint256 squareHi, uint256 squareLo) = _mul512({a: root, b: root});
        (uint256 carry, uint256 w0) = _mul512({a: squareLo, b: amount0});
        (uint256 w2, uint256 mid) = _mul512({a: squareHi, b: amount0});
        uint256 w1;
        // Add the low product's carry into the middle word, carrying an overflow into the top word.
        unchecked {
            w1 = mid + carry;
            if (w1 < mid) w2++;
        }
        // The target is (0, amount1 >> 64, amount1 << 192) in 256-bit words.
        if (w2 != 0) return 1;
        if (w1 != amount1 >> 64) return w1 > amount1 >> 64 ? int256(1) : int256(-1);
        if (w0 != amount1 << 192) return w0 > amount1 << 192 ? int256(1) : int256(-1);
        return 0;
    }

    /// @notice The project's corridor, as the hook math computes it.
    /// @return lower The corridor's lower tick.
    /// @return upper The corridor's upper tick.
    function _corridor() internal view returns (int24 lower, int24 upper) {
        // Use the current ruleset, with no sucker registry so only local supply and surplus count.
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(_PID);
        (lower, upper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: _PID,
            terminalToken: address(_term),
            projectToken: address(_proj),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    /// @notice Pre-initialize the pool at `sqrtPriceX96` and permissionlessly deploy `amount` project tokens.
    /// @param sqrtPriceX96 The pool's initial sqrt price.
    /// @param amount The reserved project tokens to deploy.
    function _deployAt(uint160 sqrtPriceX96, uint256 amount) internal {
        // Initializing first makes the deploy accept this price instead of seeding its own.
        positionManager.initializePool({key: _poolKey, sqrtPriceX96: sqrtPriceX96});
        _accumulate(amount);
        // Any caller may deploy the pool.
        vm.prank(user);
        hook.deployPool(_PID);
    }

    /// @notice Deploy `projectAmount` at mid-corridor, then fold a ledgered terminal-side LP fee into a recycle at
    /// the same spot so both an ask and a bid are live.
    /// @param projectAmount The reserved project tokens to deploy.
    /// @param terminalAmount The terminal-token fee the recycle bids with.
    /// @return mid The mid-corridor tick the pool sits at.
    function _deployBothAtMid(uint256 projectAmount, uint256 terminalAmount) internal returns (int24 mid) {
        // The first deploy has only project tokens, so it mints an ask alone.
        mid = _midTick();
        _deployAt({sqrtPriceX96: TickMath.getSqrtPriceAtTick(mid), amount: projectAmount});
        assertEq(_bidId(), 0, "precondition: deploy is asks-only");
        // A ledgered terminal fee gives the next recycle something to bid with.
        _addTerminalFee({tokenId: _askId(), amount: terminalAmount});
        _recycle();
        assertNotEq(_askId(), 0, "precondition: ask live");
        assertNotEq(_bidId(), 0, "precondition: bid live");
    }

    /// @notice Empty the corridor and check the sub-tick case really is hidden by tick rounding.
    /// @param kind How the corridor is emptied.
    function _emptyAndCheck(Empty kind) internal {
        _emptyEconomics(kind);
        // The sub-tick inversion must round both prices to one tick while the cash-out value stays strictly above.
        if (kind == Empty.SubTickInverted) {
            (uint160 cashOutSqrtPrice, uint160 issuanceSqrtPrice) = _exactPrices();
            assertEq(
                TickMath.getTickAtSqrtPrice(cashOutSqrtPrice),
                TickMath.getTickAtSqrtPrice(issuanceSqrtPrice),
                "precondition: both prices round to one tick"
            );
            assertTrue(
                _isProjectToken0 ? cashOutSqrtPrice > issuanceSqrtPrice : cashOutSqrtPrice < issuanceSqrtPrice,
                "precondition: the cash-out value is above the issuance price"
            );
        }
        // Every kind leaves the corridor empty.
        _assertCorridorEmpty();
    }

    /// @notice Set the economics that empty the corridor in the way `kind` names.
    /// @param kind How the corridor is emptied.
    function _emptyEconomics(Empty kind) internal {
        // Each kind's cash-out value and issuance rate, as described on `Empty`.
        if (kind == Empty.Inverted) {
            _setPrices({cashOutValue: 1e18, issuanceRate: 900e18});
        } else if (kind == Empty.SubTickInverted) {
            _setPrices({cashOutValue: 0.001111122222222222e18, issuanceRate: 900e18});
        } else if (kind == Empty.Equal) {
            _setPrices({cashOutValue: 1e18, issuanceRate: 1e18});
        } else {
            _setPrices({cashOutValue: 0.0011e18, issuanceRate: 900e18});
        }
    }

    /// @notice The exact cash-out and issuance prices as pool sqrt prices, before any tick rounding.
    /// @return cashOutSqrtPrice The cash-out floor's sqrt price.
    /// @return issuanceSqrtPrice The issuance ceiling's sqrt price.
    function _exactPrices() internal view returns (uint160 cashOutSqrtPrice, uint160 issuanceSqrtPrice) {
        // Encode both prices from the current ruleset, with no sucker registry.
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(_PID);
        cashOutSqrtPrice = JBUniswapV4LPSplitHookMath.getCashOutRateSqrtPriceX96({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: _PID,
            terminalToken: address(_term),
            projectToken: address(_proj),
            controller: address(controller),
            ruleset: ruleset
        });
        issuanceSqrtPrice = JBUniswapV4LPSplitHookMath.getIssuanceRateSqrtPriceX96({
            directory: IJBDirectory(address(directory)),
            projectId: _PID,
            terminalToken: address(_term),
            projectToken: address(_proj),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    /// @notice Give `to` `amount` terminal tokens, native or ERC-20.
    /// @param to The account funded.
    /// @param amount The terminal tokens added.
    function _fundTerm(address to, uint256 amount) internal {
        // Native balances are topped up; ERC-20 balances are minted.
        if (_nativeTerminal) vm.deal(to, to.balance + amount);
        else MockERC20(_term).mint({to: to, amount: amount});
    }

    /// @notice The gross project tokens a payment of `amount` terminal tokens mints, before reserves.
    /// @param amount The terminal tokens paid.
    /// @return projectTokens The gross project tokens minted.
    function _grossOut(uint256 amount) internal view returns (uint256 projectTokens) {
        // Price the payment with the current ruleset.
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(_PID);
        return JBUniswapV4LPSplitHookMath.getProjectTokensOutForTerminalTokensIn({
            directory: IJBDirectory(address(directory)),
            projectId: _PID,
            terminalToken: _term,
            terminalTokenInAmount: amount,
            controller: address(controller),
            ruleset: ruleset
        });
    }

    /// @notice The project and terminal inventory a recycle has to place at the current spot: the ledgers plus what
    /// burning the live positions returns.
    /// @return projectIn The project inventory.
    /// @return terminalIn The terminal inventory.
    function _inventory() internal view returns (uint256 projectIn, uint256 terminalIn) {
        // Add the live principal to each ledger.
        (uint256 projectHeld, uint256 terminalHeld) = _livePrincipal();
        return (_projLedger() + projectHeld, _termLedger() + terminalHeld);
    }

    /// @notice The terminal and project principal both live positions hold at the live spot (what their burns
    /// return).
    /// @return projectSide The project principal across both positions.
    /// @return terminalSide The terminal principal across both positions.
    function _livePrincipal() internal view returns (uint256 projectSide, uint256 terminalSide) {
        // Sum the ask and the bid, skipping whichever is not live.
        uint256[2] memory ids = [_askId(), _bidId()];
        for (uint256 i; i < 2; i++) {
            if (ids[i] == 0) continue;
            // Map the pool's token0/token1 principal onto the project and terminal sides.
            (uint256 amount0, uint256 amount1) = _principalAtSpot(ids[i]);
            (uint256 p, uint256 t) = _isProjectToken0 ? (amount0, amount1) : (amount1, amount0);
            projectSide += p;
            terminalSide += t;
        }
    }

    /// @notice The larger of the live ask and bid ids, so later mints can be checked as fresh.
    /// @return tokenId The larger live id, or 0 when neither is live.
    function _maxId() internal view returns (uint256 tokenId) {
        // Ids increase with each mint, so the larger id is the most recent.
        return _askId() > _bidId() ? _askId() : _bidId();
    }

    /// @notice A spacing-aligned tick in the middle of the corridor.
    /// @return mid The aligned midpoint tick.
    function _midTick() internal view returns (int24 mid) {
        (int24 lower, int24 upper) = _corridor();
        // Intentionally divide before multiplying to align the midpoint to the spacing grid.
        // forge-lint: disable-next-line(divide-before-multiply)
        mid = ((lower + (upper - lower) / 2) / _SPACING) * _SPACING;
    }

    /// @notice The full 512-bit product of `a` and `b`.
    /// @param a The first factor.
    /// @param b The second factor.
    /// @return hi The high 256 bits of the product.
    /// @return lo The low 256 bits of the product.
    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        // The product mod 2^256 - 1 and mod 2^256 differ by the high word (with a borrow), the standard 512-bit trick.
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    /// @notice A position's ticks, liquidity and principal, mapped onto the project and terminal sides.
    /// @param tokenId The position to read.
    /// @return lower The position's lower tick.
    /// @return upper The position's upper tick.
    /// @return liquidity The position's liquidity.
    /// @return projectSide The project principal the mock records for it.
    /// @return terminalSide The terminal principal the mock records for it.
    function _position(uint256 tokenId)
        internal
        view
        returns (int24 lower, int24 upper, uint128 liquidity, uint256 projectSide, uint256 terminalSide)
    {
        // Read the mock's stored position, then map token0/token1 onto the project and terminal sides.
        uint256 amount0;
        uint256 amount1;
        (, lower, upper, liquidity, amount0, amount1,) = positionManager._positions(tokenId);
        (projectSide, terminalSide) = _isProjectToken0 ? (amount0, amount1) : (amount1, amount0);
    }

    /// @notice The cash-out and issuance previews (per-WAD rates, truncated).
    /// @return cashOutValue The terminal tokens one project token cashes out for.
    /// @return issuanceRate The project tokens one terminal token mints for the payer.
    function _previews() internal view returns (uint256 cashOutValue, uint256 issuanceRate) {
        // Read both previews from the current ruleset, with no sucker registry.
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(_PID);
        cashOutValue = JBUniswapV4LPSplitHookMath.getCashOutRate({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: _PID,
            terminalToken: address(_term),
            controller: address(controller),
            ruleset: ruleset
        });
        issuanceRate = JBUniswapV4LPSplitHookMath.getIssuanceRate({
            directory: IJBDirectory(address(directory)),
            projectId: _PID,
            terminalToken: address(_term),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    /// @notice The project-token ledger the hook holds for the project.
    /// @return amount The ledgered project tokens.
    function _projLedger() internal view returns (uint256 amount) {
        // Read the hook's project-token ledger.
        return hook.accumulatedProjectTokens(_PID);
    }

    /// @notice Recycle the project's liquidity as a permissionless caller.
    function _recycle() internal {
        // Any caller may recycle.
        vm.prank(user);
        hook.addLiquidity({projectId: _PID, terminalToken: address(_term)});
    }

    /// @notice Re-mark `tokenId` to exactly the principal its liquidity holds at `sqrtPriceX96`.
    /// @param tokenId The position to re-mark; 0 is skipped.
    /// @param sqrtPriceX96 The price to mark it at.
    function _reprice(uint256 tokenId, uint160 sqrtPriceX96) internal {
        // A side that is not live has nothing to re-mark.
        if (tokenId == 0) return;
        // Compute the principal at the new price and write it back with matching balances.
        (, int24 lower, int24 upper, uint128 liquidity,,,) = positionManager._positions(tokenId);
        (uint256 amount0, uint256 amount1) =
            _principalAt({sqrtPriceX96: sqrtPriceX96, lower: lower, upper: upper, liquidity: liquidity});
        _setPrincipal({tokenId: tokenId, amount0: amount0, amount1: amount1});
    }

    /// @notice The `_wire` economics: the cash-out floor genuinely below the issuance ceiling.
    function _restoreEconomics() internal {
        // Reapply the default weight, reserve and taxed curve.
        controller.setWeight({projectId: _PID, weight: DEFAULT_WEIGHT});
        controller.setReservedPercent({projectId: _PID, reservedPercent: DEFAULT_RESERVED_PERCENT});
        _setWideTaxedCurve(_PID);
    }

    /// @notice The price a first deploy would seed the pool at.
    /// @return sqrtPriceX96 The seed sqrt price, or 0 when the corridor is empty.
    function _seed() internal view returns (uint160 sqrtPriceX96) {
        // Compute the seed from the current ruleset, with no sucker registry.
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(_PID);
        sqrtPriceX96 = JBUniswapV4LPSplitHookMath.computeInitialSqrtPrice({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: _PID,
            terminalToken: address(_term),
            projectToken: address(_proj),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    /// @notice Set exact economics: the cash-out value per project token (18 decimals) and the issuance rate (project
    /// tokens per terminal token, no reserved share).
    /// @param cashOutValue The terminal tokens one project token cashes out for.
    /// @param issuanceRate The weight: project tokens minted per terminal token.
    function _setPrices(uint256 cashOutValue, uint256 issuanceRate) internal {
        // The weight is the issuance rate once nothing is reserved.
        controller.setWeight({projectId: _PID, weight: issuanceRate});
        controller.setReservedPercent({projectId: _PID, reservedPercent: 0});
        // An untaxed curve over a 1e18 supply makes the surplus the per-token cash-out value.
        store.setTaxedCashOutCurve({projectId: _PID, surplus: cashOutValue, supply: 1e18, taxRate: 0});
    }

    /// @notice Write the pool's slot0 to an exact sqrt price (tick derived the way the PoolManager derives it).
    /// @param sqrtPriceX96 The sqrt price to write.
    function _setSpot(uint160 sqrtPriceX96) internal {
        // The pool's state lives at keccak256(poolId, 6) in the PoolManager's `_pools` mapping.
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(_poolKey.toId()), bytes32(uint256(6))));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // Pack slot0 as (lpFee << 208) | (tick << 160) | sqrtPriceX96, with the tick in two's complement.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 packed = (uint256(_poolKey.fee) << 208) | (uint256(uint24(tick)) << 160) | uint256(sqrtPriceX96);
        poolManager.writeSlot({slot: stateSlot, value: bytes32(packed)});
    }

    /// @notice The pool's current sqrt price.
    /// @return sqrtPriceX96 The sqrt price in slot0, or 0 when the pool is uninitialized.
    function _spot() internal view returns (uint160 sqrtPriceX96) {
        // Read slot0 and keep its low 160 bits.
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(_poolKey.toId()), bytes32(uint256(6))));
        sqrtPriceX96 = uint160(uint256(poolManager.extsload(stateSlot)));
    }

    /// @notice Move the spot to `sqrtPriceX96` as a trade would: every live position of `_PID` is re-marked to exactly
    /// the principal its liquidity holds at the new price.
    /// @param sqrtPriceX96 The new spot.
    function _swapTo(uint160 sqrtPriceX96) internal {
        // Re-mark both positions before moving the spot, so their principal matches the new price.
        _reprice({tokenId: _askId(), sqrtPriceX96: sqrtPriceX96});
        _reprice({tokenId: _bidId(), sqrtPriceX96: sqrtPriceX96});
        _setSpot(sqrtPriceX96);
    }

    /// @notice The terminal-token balance of `who`, native or ERC-20.
    /// @param who The account whose balance is read.
    /// @return balance The terminal-token balance.
    function _termBalanceOf(address who) internal view returns (uint256 balance) {
        // Native balances come from the account itself; ERC-20 balances from the token.
        return _nativeTerminal ? who.balance : MockERC20(_term).balanceOf(who);
    }

    /// @notice The terminal token's pool currency: address(0) for native.
    /// @return currency The pool currency.
    function _termCurrency() internal view returns (Currency currency) {
        // V4 represents native ETH as the zero address.
        return Currency.wrap(_nativeTerminal ? address(0) : _term);
    }

    /// @notice The terminal token's accounting currency (its address, truncated as Juicebox does).
    /// @return currencyId The accounting currency id.
    function _termCurrencyId() internal view returns (uint32 currencyId) {
        // Juicebox derives a token's currency id from the low 32 bits of its address.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(uint160(_term));
    }

    /// @notice The terminal-token ledger the hook holds for the project.
    /// @return amount The ledgered terminal tokens.
    function _termLedger() internal view returns (uint256 amount) {
        // Read the hook's terminal-token ledger for this terminal token.
        return hook.accumulatedTerminalTokens({projectId: _PID, terminalToken: address(_term)});
    }

    /// @notice Wire project `_PID` against a fresh ERC-20 terminal token, with the project token sorted as requested,
    /// or against the native terminal token when `_nativeTerminal` is set (which always sorts the project as token1).
    /// @param wantProjectToken0 Whether the project token must sort as token0.
    function _wire(bool wantProjectToken0) internal {
        // Deploy the project token and pick the terminal token.
        _proj = new MockERC20("Proj", "P", 18);
        if (_nativeTerminal) {
            require(!wantProjectToken0, "native: the project is always token1");
            _term = JBConstants.NATIVE_TOKEN;
        } else {
            _term = address(new MockERC20("Term", "T", 18));
        }
        // Redeploy the project token until its address sorts on the requested side.
        while ((address(_proj) < address(_term)) != wantProjectToken0) {
            _proj = new MockERC20("Proj", "P", 18);
        }
        _isProjectToken0 = wantProjectToken0;

        // Default issuance and the project's base currency.
        controller.setWeight({projectId: _PID, weight: DEFAULT_WEIGHT});
        controller.setFirstWeight({projectId: _PID, weight: DEFAULT_FIRST_WEIGHT});
        controller.setReservedPercent({projectId: _PID, reservedPercent: DEFAULT_RESERVED_PERCENT});
        controller.setBaseCurrency({projectId: _PID, currency: 1});
        // Register the controller, terminal, owner, tokens and accounting context.
        _setDirectoryController({projectId: _PID, ctrl: address(controller)});
        _setDirectoryTerminal({projectId: _PID, token: address(_term), term: address(terminal)});
        jbProjects.setOwner({tokenId: _PID, owner: owner});
        terminal.setProjectToken({projectId: _PID, token: address(_proj)});
        terminal.setAccountingContext({
            projectId: _PID, token: address(_term), currency: _termCurrencyId(), decimals: 18
        });
        terminal.addAccountingContext({
            projectId: _PID,
            ctx: JBAccountingContext({token: address(_term), decimals: 18, currency: _termCurrencyId()})
        });
        jbTokens.setToken({projectId: _PID, token: address(_proj)});
        // A non-inverted corridor: the cash-out floor sits genuinely below the issuance ceiling.
        _setWideTaxedCurve(_PID);
        store.setBalance({terminal: address(terminal), projectId: _PID, token: address(_term), balance: 10e18});
        _addDirectoryTerminal({projectId: _PID, term: address(terminal)});

        // The pool key, sorted for the requested ordering, with the hook's fee, spacing and oracle hook.
        address termCurrency = Currency.unwrap(_termCurrency());
        (address c0, address c1) = wantProjectToken0 ? (address(_proj), termCurrency) : (termCurrency, address(_proj));
        _poolKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
    }
}
