// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TwoPositionFixture} from "./regression/TwoPositionFixture.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

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
    using PoolIdLibrary for PoolKey;

    uint256 internal constant PID = 7;
    int24 internal constant SPACING = 200;

    MockERC20 internal proj;
    /// @notice The terminal token: a fresh ERC-20, or `JBConstants.NATIVE_TOKEN` when `nativeTerminal` is set.
    address internal term;
    PoolKey internal key;
    bool internal projectIsToken0;
    /// @notice Set before `_wire` to wire the native terminal token instead of an ERC-20.
    bool internal nativeTerminal;

    // ─── Harness
    // ───────────────────────────────────────────────────────────

    /// @notice Wire project `PID` against a fresh ERC-20 terminal token, with the project token sorted as requested, or
    /// against the native terminal token when `nativeTerminal` is set (which always sorts the project as token1).
    function _wire(bool wantProjectToken0) internal {
        proj = new MockERC20("Proj", "P", 18);
        if (nativeTerminal) {
            require(!wantProjectToken0, "native: the project is always token1");
            term = JBConstants.NATIVE_TOKEN;
        } else {
            term = address(new MockERC20("Term", "T", 18));
        }
        while ((address(proj) < address(term)) != wantProjectToken0) {
            proj = new MockERC20("Proj", "P", 18);
        }
        projectIsToken0 = wantProjectToken0;

        controller.setWeight(PID, DEFAULT_WEIGHT);
        controller.setFirstWeight(PID, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(PID, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(PID, 1);
        _setDirectoryController(PID, address(controller));
        _setDirectoryTerminal(PID, address(term), address(terminal));
        jbProjects.setOwner(PID, owner);
        terminal.setProjectToken(PID, address(proj));
        terminal.setAccountingContext(PID, address(term), _termCurrencyId(), 18);
        terminal.addAccountingContext(
            PID, JBAccountingContext({token: address(term), decimals: 18, currency: _termCurrencyId()})
        );
        jbTokens.setToken(PID, address(proj));
        // A non-inverted corridor: the cash-out floor sits genuinely below the issuance ceiling.
        _setWideTaxedCurve(PID);
        store.setBalance(address(terminal), PID, address(term), 10e18);
        _addDirectoryTerminal(PID, address(terminal));

        address termCurrency = Currency.unwrap(_termCurrency());
        (address c0, address c1) = wantProjectToken0 ? (address(proj), termCurrency) : (termCurrency, address(proj));
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
    }

    /// @notice The terminal token's pool currency: address(0) for native.
    function _termCurrency() internal view returns (Currency) {
        return Currency.wrap(nativeTerminal ? address(0) : term);
    }

    /// @notice The terminal token's accounting currency (its address, truncated as Juicebox does).
    function _termCurrencyId() internal view returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(uint160(term));
    }

    function _termBalanceOf(address who) internal view returns (uint256) {
        return nativeTerminal ? who.balance : MockERC20(term).balanceOf(who);
    }

    function _fundTerm(address to, uint256 amount) internal {
        if (nativeTerminal) vm.deal(to, to.balance + amount);
        else MockERC20(term).mint(to, amount);
    }

    function _corridor() internal view returns (int24 lower, int24 upper) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PID);
        (lower, upper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PID,
            terminalToken: address(term),
            projectToken: address(proj),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    /// @notice The issuance-ceiling tick and the cash-out-floor tick of the corridor, ordering-aware.
    function _ceilingAndFloor() internal view returns (int24 ceiling, int24 floor) {
        (int24 lower, int24 upper) = _corridor();
        (ceiling, floor) = projectIsToken0 ? (upper, lower) : (lower, upper);
    }

    /// @notice A spacing-aligned tick in the middle of the corridor.
    function _midTick() internal view returns (int24 mid) {
        (int24 lower, int24 upper) = _corridor();
        // Intentionally divide before multiplying to align the midpoint to the spacing grid.
        // forge-lint: disable-next-line(divide-before-multiply)
        mid = ((lower + (upper - lower) / 2) / SPACING) * SPACING;
    }

    /// @notice Write the pool's slot0 to an exact sqrt price (tick derived the way the PoolManager derives it).
    function _setSpot(uint160 sqrtPriceX96) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 packed = (uint256(key.fee) << 208) | (uint256(uint24(tick)) << 160) | uint256(sqrtPriceX96);
        poolManager.writeSlot(stateSlot, bytes32(packed));
    }

    function _spot() internal view returns (uint160 sqrtPriceX96) {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        sqrtPriceX96 = uint160(uint256(poolManager.extsload(stateSlot)));
    }

    /// @notice Deliver `amount` reserved project tokens to the hook (accumulate only).
    function _accumulate(uint256 amount) internal {
        proj.mint(address(controller), amount);
        vm.startPrank(address(controller));
        proj.approve(address(hook), amount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(_buildContext(PID, address(proj), amount, 1));
        vm.stopPrank();
    }

    /// @notice Pre-initialize the pool at `sqrtPriceX96` and permissionlessly deploy `amount` project tokens.
    function _deployAt(uint160 sqrtPriceX96, uint256 amount) internal {
        positionManager.initializePool(key, sqrtPriceX96);
        _accumulate(amount);
        vm.prank(user);
        hook.deployPool(PID);
    }

    function _recycle() internal {
        vm.prank(user);
        hook.addLiquidity(PID, address(term));
    }

    function _askId() internal view returns (uint256) {
        return hook.askTokenIdOf(PID, address(term));
    }

    function _bidId() internal view returns (uint256) {
        return hook.bidTokenIdOf(PID, address(term));
    }

    function _projLedger() internal view returns (uint256) {
        return hook.accumulatedProjectTokens(PID);
    }

    function _termLedger() internal view returns (uint256) {
        return hook.accumulatedTerminalTokens(PID, address(term));
    }

    function _position(uint256 tokenId)
        internal
        view
        returns (int24 lower, int24 upper, uint128 liquidity, uint256 projectSide, uint256 terminalSide)
    {
        uint256 amount0;
        uint256 amount1;
        (, lower, upper, liquidity, amount0, amount1,) = positionManager._positions(tokenId);
        (projectSide, terminalSide) = projectIsToken0 ? (amount0, amount1) : (amount1, amount0);
    }

    /// @notice Give a live position a collectable terminal-side LP fee (forgiven in full: the fee project has no
    /// terminal for this fresh terminal token), funding the PositionManager for it.
    function _addTerminalFee(uint256 tokenId, uint256 amount) internal {
        if (projectIsToken0) positionManager.setCollectableFees(tokenId, 0, amount);
        else positionManager.setCollectableFees(tokenId, amount, 0);
        _fundTerm(address(positionManager), amount);
    }

    /// @notice Move the spot to `sqrtPriceX96` as a trade would: every live position of `PID` is re-marked to exactly
    /// the principal its liquidity holds at the new price.
    function _swapTo(uint160 sqrtPriceX96) internal {
        _reprice(_askId(), sqrtPriceX96);
        _reprice(_bidId(), sqrtPriceX96);
        _setSpot(sqrtPriceX96);
    }

    function _reprice(uint256 tokenId, uint160 sqrtPriceX96) internal {
        if (tokenId == 0) return;
        (, int24 lower, int24 upper, uint128 liquidity,,,) = positionManager._positions(tokenId);
        (uint256 amount0, uint256 amount1) = _principalAt(sqrtPriceX96, lower, upper, liquidity);
        _setPrincipal(tokenId, amount0, amount1);
    }

    /// @notice Assert `tokenId` is live on exactly `[lower, upper]`, holding only the currency it was offered
    /// (`projectIn` or `terminalIn`) at exactly its liquidity's cost, and as much liquidity as that inventory pays for:
    /// only V4 rounding of the offered inventory is left unplaced.
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
        assertNotEq(tokenId, 0, string.concat(label, ": live"));
        (int24 l, int24 u, uint128 liquidity,,) = _position(tokenId);
        assertGt(liquidity, 0, string.concat(label, ": liquidity"));
        assertEq(l, lower, string.concat(label, ": tickLower"));
        assertEq(u, upper, string.concat(label, ": tickUpper"));
        assertEq(l % SPACING, 0, string.concat(label, ": tickLower aligned"));
        assertEq(u % SPACING, 0, string.concat(label, ": tickUpper aligned"));
        (projectPlaced, terminalPlaced) = _costSidesOf(tokenId, address(proj));
        if (projectIn == 0) assertEq(projectPlaced, 0, string.concat(label, ": no project side"));
        if (terminalIn == 0) assertEq(terminalPlaced, 0, string.concat(label, ": no terminal side"));
        assertLe(projectPlaced, projectIn, string.concat(label, ": project side within inventory"));
        assertLe(terminalPlaced, terminalIn, string.concat(label, ": terminal side within inventory"));
        _assertMaximalLiquidity(tokenId, projectIn + terminalIn);
    }

    /// @notice The hook holds exactly the project's ledgers (no fee claims, no other project uses these tokens).
    function _assertLedgersBacked() internal view {
        assertEq(proj.balanceOf(address(hook)), _projLedger(), "project ledger equals the hook's project balance");
        assertEq(_termBalanceOf(address(hook)), _termLedger(), "terminal ledger equals the hook's terminal balance");
    }

    /// @notice Deploy `projectAmount` at mid-corridor, then fold a forgiven terminal-side LP fee into a recycle at
    /// the same spot so both an ask and a bid are live.
    function _deployBothAtMid(uint256 projectAmount, uint256 terminalAmount) internal returns (int24 mid) {
        mid = _midTick();
        _deployAt(TickMath.getSqrtPriceAtTick(mid), projectAmount);
        assertEq(_bidId(), 0, "precondition: deploy is asks-only");
        _addTerminalFee(_askId(), terminalAmount);
        _recycle();
        assertNotEq(_askId(), 0, "precondition: ask live");
        assertNotEq(_bidId(), 0, "precondition: bid live");
    }

    /// @notice The terminal and project principal both live positions hold at the live spot (what their burns
    /// return).
    function _livePrincipal() internal view returns (uint256 projectSide, uint256 terminalSide) {
        uint256[2] memory ids = [_askId(), _bidId()];
        for (uint256 i; i < 2; i++) {
            if (ids[i] == 0) continue;
            (uint256 amount0, uint256 amount1) = _principalAtSpot(ids[i]);
            (uint256 p, uint256 t) = projectIsToken0 ? (amount0, amount1) : (amount1, amount0);
            projectSide += p;
            terminalSide += t;
        }
    }

    /// @notice The project and terminal inventory a recycle has to place right now: the ledgers plus what burning the
    /// live positions returns.
    function _inventory() internal view returns (uint256 projectIn, uint256 terminalIn) {
        (uint256 projectHeld, uint256 terminalHeld) = _livePrincipal();
        return (_projLedger() + projectHeld, _termLedger() + terminalHeld);
    }

    function _maxId() internal view returns (uint256) {
        return _askId() > _bidId() ? _askId() : _bidId();
    }

    // ─── Ceiling and floor edges (both orderings)
    // ────────────────────────────────────────────────

    /// @notice Spot at (`beyond == 0`) or past the issuance ceiling with project AND terminal inventory: the ask has
    /// no range, so its id is zero and every project token is carried; the bid is live, bounded by the corridor, and
    /// holds every terminal token. Restoring the spot redeploys the carried inventory into fresh ids.
    function _runCeiling(bool wantProjectToken0, int24 beyond, uint256 newProjectTokens) internal {
        _wire(wantProjectToken0);
        int24 mid = _deployBothAtMid(1e18, 0.5e18);
        (int24 lower, int24 upper) = _corridor();
        (int24 ceiling,) = _ceilingAndFloor();

        // Buyers take every ask: the spot reaches (or passes) the issuance ceiling.
        _swapTo(TickMath.getSqrtPriceAtTick(projectIsToken0 ? ceiling + beyond : ceiling - beyond));
        if (newProjectTokens != 0) _accumulate(newProjectTokens);
        (uint256 projectHeld,) = _livePrincipal();
        assertEq(projectHeld, 0, "precondition: the filled positions hold only terminal");
        (uint256 projectIn, uint256 terminalIn) = _inventory();
        assertGe(projectIn, newProjectTokens, "precondition: the new project tokens are ledgered");
        uint256 idsBefore = _maxId();

        _recycle();

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
        assertEq(_projLedger(), projectIn, "every project token is carried in the ask ledger");
        assertEq(_termLedger(), terminalIn - bidPlaced, "the bid consumed every terminal token but V4 rounding");
        // The ask is intentionally unmintable here: no range at or past the ceiling.
        _assertPlacedExactly(PID, address(proj), term, projectIn, terminalIn, false, true);
        _assertLedgersBacked();

        // Restore the geometry: the spot trades back to mid-corridor and the carried inventory redeploys.
        _swapTo(TickMath.getSqrtPriceAtTick(mid));
        (projectIn, terminalIn) = _inventory();
        idsBefore = _maxId();
        _recycle();
        (int24 bidLower, int24 bidUpper) = projectIsToken0 ? (lower, mid) : (mid, upper);
        (int24 askLower, int24 askUpper) = projectIsToken0 ? (mid, upper) : (lower, mid);
        (uint256 askPlaced,) = _assertPosition(_askId(), askLower, askUpper, projectIn, 0, "restored ask");
        (, bidPlaced) = _assertPosition(_bidId(), bidLower, bidUpper, 0, terminalIn, "restored bid");
        assertGt(_askId(), idsBefore, "restored ask is a fresh id");
        assertGt(_bidId(), idsBefore, "restored bid is a fresh id");
        assertEq(_projLedger(), projectIn - askPlaced, "the carried project tokens redeployed");
        assertEq(_termLedger(), terminalIn - bidPlaced, "the terminal redeployed");
        _assertLedgersBacked();
    }

    function test_Ceiling_At_ProjectToken0() public {
        _runCeiling(true, 0, 0.3e18);
    }

    function test_Ceiling_At_ProjectToken1() public {
        _runCeiling(false, 0, 0.3e18);
    }

    function test_Ceiling_Beyond_ProjectToken0() public {
        _runCeiling(true, 1050, 0.3e18);
    }

    function test_Ceiling_Beyond_ProjectToken1() public {
        _runCeiling(false, 1050, 0.3e18);
    }

    /// @notice Zero-project inventory (every ask filled, no new reserved tokens): the recycle deploys bid-only.
    function test_Ceiling_ZeroProject_BidOnly_ProjectToken0() public {
        _runCeiling(true, 0, 0);
    }

    function test_Ceiling_ZeroProject_BidOnly_ProjectToken1() public {
        _runCeiling(false, 0, 0);
    }

    /// @notice Spot at (`beyond == 0`) or past the cash-out floor with project AND terminal inventory: the bid has no
    /// range, so its id is zero and every terminal token stays ledgered; the ask is live across the whole corridor.
    function _runFloor(bool wantProjectToken0, int24 beyond) internal {
        _wire(wantProjectToken0);
        int24 mid = _deployBothAtMid(1e18, 0.5e18);
        (int24 lower, int24 upper) = _corridor();
        (, int24 floor) = _ceilingAndFloor();

        // Sellers take every bid: the spot reaches (or passes) the cash-out floor. A forgiven terminal fee then gives
        // the project terminal inventory that has nowhere to rest.
        _swapTo(TickMath.getSqrtPriceAtTick(projectIsToken0 ? floor - beyond : floor + beyond));
        uint256 fee = 0.2e18;
        _addTerminalFee(_askId(), fee);
        (, uint256 terminalHeld) = _livePrincipal();
        assertEq(terminalHeld, 0, "precondition: the filled positions hold only project tokens");
        (uint256 projectIn, uint256 terminalIn) = _inventory();
        // The forgiven fee is collected by the recycle, joining the terminal inventory.
        terminalIn += fee;

        _recycle();

        assertEq(_bidId(), 0, "no bid range at or past the floor");
        (uint256 askPlaced,) = _assertPosition(_askId(), lower, upper, projectIn, 0, "corridor-bounded ask");
        assertEq(_termLedger(), terminalIn, "every terminal token stays in the bid ledger");
        assertEq(_projLedger(), projectIn - askPlaced, "the ask consumed every project token but V4 rounding");
        // The bid is intentionally unmintable here: no range at or past the floor.
        _assertPlacedExactly(PID, address(proj), term, projectIn, terminalIn, true, false);
        _assertLedgersBacked();

        // Restore the geometry: the carried terminal redeploys as a fresh bid.
        _swapTo(TickMath.getSqrtPriceAtTick(mid));
        (projectIn, terminalIn) = _inventory();
        assertGe(terminalIn, fee, "precondition: the carried fee is in the terminal inventory");
        uint256 idsBefore = _maxId();
        _recycle();
        (int24 bidLower, int24 bidUpper) = projectIsToken0 ? (lower, mid) : (mid, upper);
        (int24 askLower, int24 askUpper) = projectIsToken0 ? (mid, upper) : (lower, mid);
        (askPlaced,) = _assertPosition(_askId(), askLower, askUpper, projectIn, 0, "restored ask");
        (, uint256 bidPlaced) = _assertPosition(_bidId(), bidLower, bidUpper, 0, terminalIn, "restored bid");
        assertGt(_askId(), idsBefore, "restored ask is a fresh id");
        assertGt(_bidId(), idsBefore, "restored bid is a fresh id");
        assertEq(_termLedger(), terminalIn - bidPlaced, "the carried terminal redeployed");
        assertEq(_projLedger(), projectIn - askPlaced, "the project tokens redeployed");
        _assertLedgersBacked();
    }

    function test_Floor_At_ProjectToken0() public {
        _runFloor(true, 0);
    }

    function test_Floor_At_ProjectToken1() public {
        _runFloor(false, 0);
    }

    function test_Floor_Beyond_ProjectToken0() public {
        _runFloor(true, 1050);
    }

    function test_Floor_Beyond_ProjectToken1() public {
        _runFloor(false, 1050);
    }

    /// @notice A nonzero terminal amount too small to yield any liquidity across the bid range is skipped and carried,
    /// while the ask still mints; a later recycle with enough terminal redeploys it. A pricier issuance widens the
    /// corridor and the spot sits two spacings inside the ceiling, so the bid range spans enough price that one wei
    /// rounds to zero liquidity in either ordering.
    function _runDustBid(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        controller.setWeight(PID, 1e15);
        (int24 ceiling,) = _ceilingAndFloor();
        int24 spotTick = projectIsToken0 ? ceiling - 2 * SPACING : ceiling + 2 * SPACING;
        _deployAt(TickMath.getSqrtPriceAtTick(spotTick), 1e18);
        (int24 lower, int24 upper) = _corridor();
        (int24 bidLower, int24 bidUpper) = projectIsToken0 ? (lower, spotTick) : (spotTick, upper);
        (int24 askLower, int24 askUpper) = projectIsToken0 ? (spotTick, upper) : (lower, spotTick);

        uint160 sqrtA = TickMath.getSqrtPriceAtTick(bidLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(bidUpper);
        uint128 dustLiquidity = projectIsToken0
            ? LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, 1)
            : LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, 1);
        assertEq(dustLiquidity, 0, "precondition: one wei of terminal yields zero bid liquidity");

        _addTerminalFee(_askId(), 1);
        (uint256 projectIn, uint256 terminalIn) = _inventory();
        assertEq(terminalIn, 0, "precondition: no terminal before the dust fee");
        _recycle();

        assertEq(_bidId(), 0, "a zero-liquidity bid is skipped");
        _assertPosition(_askId(), askLower, askUpper, projectIn, 0, "ask");
        assertEq(_termLedger(), 1, "the dust terminal is carried, not lost");
        // The bid is intentionally unmintable here: one wei rounds to zero liquidity.
        _assertPlacedExactly(PID, address(proj), term, projectIn, 1, true, false);
        _assertLedgersBacked();

        _addTerminalFee(_askId(), 0.1e18);
        (, terminalIn) = _inventory();
        assertEq(terminalIn, 1, "precondition: the carried dust is the terminal ledger");
        terminalIn += 0.1e18;
        uint256 idsBefore = _maxId();
        _recycle();
        (, uint256 bidPlaced) =
            _assertPosition(_bidId(), bidLower, bidUpper, 0, terminalIn, "bid with the carried dust");
        assertGt(_bidId(), idsBefore, "fresh bid id");
        assertEq(_termLedger(), terminalIn - bidPlaced, "the carried dust redeployed but V4 rounding");
    }

    function test_DustBidRoundsToZeroLiquidity_ProjectToken0() public {
        _runDustBid(true);
    }

    function test_DustBidRoundsToZeroLiquidity_ProjectToken1() public {
        _runDustBid(false);
    }

    // ─── Exact-price boundary matrix (both orderings, negative and positive k)
    // ────────────────────────────────────────────────

    uint8 internal constant EXACT = 0;
    uint8 internal constant PLUS_ONE = 1;
    uint8 internal constant BELOW_NEXT = 2;

    /// @notice Recycle with the spot at `sqrtAtTick(k)`, one wei above it, or one wei below `sqrtAtTick(k + spacing)`
    /// (`k` aligned). Exactly on `k`, both positions touch `k`; otherwise token1 ends at `k` and token0 starts at
    /// `k + spacing`. Each position holds only its own currency.
    function _runMatrix(bool wantProjectToken0, int24 k, uint8 kind) internal {
        _wire(wantProjectToken0);
        // A pricier issuance widens the corridor across tick zero in both orderings, so negative and positive `k` fit.
        controller.setWeight(PID, 1e15);
        (int24 lower, int24 upper) = _corridor();
        assertEq(k % SPACING, 0, "precondition: k aligned");
        assertGt(k, lower, "precondition: k above corridor lower");
        assertLt(k + SPACING, upper, "precondition: k below corridor upper");

        uint160 sqrtPriceX96 = kind == EXACT
            ? TickMath.getSqrtPriceAtTick(k)
            : kind == PLUS_ONE ? TickMath.getSqrtPriceAtTick(k) + 1 : TickMath.getSqrtPriceAtTick(k + SPACING) - 1;
        assertEq(
            TickMath.getTickAtSqrtPrice(sqrtPriceX96),
            kind == BELOW_NEXT ? k + SPACING - 1 : k,
            "precondition: spot tick"
        );

        uint256 projectAmount = 1e18;
        uint256 terminalAmount = 0.5e18;
        _deployAt(sqrtPriceX96, projectAmount);
        _addTerminalFee(_askId(), terminalAmount);
        (uint256 projectIn, uint256 terminalIn) = _inventory();
        assertEq(terminalIn, 0, "precondition: the only terminal is the fee");
        terminalIn = terminalAmount;
        _recycle();
        assertEq(_spot(), sqrtPriceX96, "the spot never moved");

        int24 token0Lower = kind == EXACT ? k : k + SPACING;
        uint256 askPlaced;
        uint256 bidPlaced;
        if (projectIsToken0) {
            (askPlaced,) = _assertPosition(_askId(), token0Lower, upper, projectIn, 0, "token0 ask");
            (, bidPlaced) = _assertPosition(_bidId(), lower, k, 0, terminalIn, "token1 bid");
        } else {
            (askPlaced,) = _assertPosition(_askId(), lower, k, projectIn, 0, "token1 ask");
            (, bidPlaced) = _assertPosition(_bidId(), token0Lower, upper, 0, terminalIn, "token0 bid");
        }
        assertEq(_projLedger(), projectIn - askPlaced, "no project carry beyond V4 rounding");
        assertEq(_termLedger(), terminalIn - bidPlaced, "no terminal carry beyond V4 rounding");
    }

    function test_Matrix_ProjectToken0_NegativeK_Exact() public {
        _runMatrix(true, -2000, EXACT);
    }

    function test_Matrix_ProjectToken0_NegativeK_PlusOne() public {
        _runMatrix(true, -2000, PLUS_ONE);
    }

    function test_Matrix_ProjectToken0_NegativeK_BelowNext() public {
        _runMatrix(true, -2000, BELOW_NEXT);
    }

    function test_Matrix_ProjectToken0_PositiveK_Exact() public {
        _runMatrix(true, 2000, EXACT);
    }

    function test_Matrix_ProjectToken0_PositiveK_PlusOne() public {
        _runMatrix(true, 2000, PLUS_ONE);
    }

    function test_Matrix_ProjectToken0_PositiveK_BelowNext() public {
        _runMatrix(true, 2000, BELOW_NEXT);
    }

    function test_Matrix_ProjectToken1_NegativeK_Exact() public {
        _runMatrix(false, -2000, EXACT);
    }

    function test_Matrix_ProjectToken1_NegativeK_PlusOne() public {
        _runMatrix(false, -2000, PLUS_ONE);
    }

    function test_Matrix_ProjectToken1_NegativeK_BelowNext() public {
        _runMatrix(false, -2000, BELOW_NEXT);
    }

    function test_Matrix_ProjectToken1_PositiveK_Exact() public {
        _runMatrix(false, 2000, EXACT);
    }

    function test_Matrix_ProjectToken1_PositiveK_PlusOne() public {
        _runMatrix(false, 2000, PLUS_ONE);
    }

    function test_Matrix_ProjectToken1_PositiveK_BelowNext() public {
        _runMatrix(false, 2000, BELOW_NEXT);
    }

    // ─── MIN_TICK partial spacing (successful recycle)
    // ────────────────────────────────────────────────

    /// @notice Deploy, then recycle permissionlessly with the spot (and TWAP) at `sqrtPriceX96` in the lowest partial
    /// spacing, where the aligned floor (-887400) sits below `MIN_TICK`. Token0 mints clamped to the corridor, token1
    /// is skipped with its inventory carried, and no out-of-range tick reaches TickMath.
    function _runMinPrice(bool wantProjectToken0, uint160 sqrtPriceX96) internal {
        _wire(wantProjectToken0);
        _deployBothAtMid(1e18, 0.5e18);
        (int24 lower, int24 upper) = _corridor();

        _swapTo(sqrtPriceX96);
        assertEq(TickMath.getTickAtSqrtPrice(sqrtPriceX96), TickMath.MIN_TICK, "precondition: spot tick is MIN_TICK");

        // Token1 inventory that cannot rest below the spot: new reserved tokens when the project is token1, a
        // forgiven terminal fee when the terminal is token1.
        uint256 token1Inventory = 0.2e18;
        if (projectIsToken0) _addTerminalFee(_askId(), token1Inventory);
        else _accumulate(token1Inventory);
        (uint256 projectHeld, uint256 terminalHeld) = _livePrincipal();
        assertEq(projectIsToken0 ? terminalHeld : projectHeld, 0, "precondition: every position is all token0");
        (uint256 projectIn, uint256 terminalIn) = _inventory();
        // A forgiven terminal fee is collected by the recycle, joining the terminal inventory.
        if (projectIsToken0) terminalIn += token1Inventory;
        assertGe(projectIsToken0 ? terminalIn : projectIn, token1Inventory, "precondition: token1 inventory");

        _recycle();

        if (projectIsToken0) {
            (uint256 askPlaced,) =
                _assertPosition(_askId(), lower, upper, projectIn, 0, "token0 ask clamped to the corridor");
            assertEq(_bidId(), 0, "token1 bid skipped");
            assertEq(_termLedger(), terminalIn, "token1 terminal carried");
            assertEq(_projLedger(), projectIn - askPlaced, "token0 fully deployed but V4 rounding");
        } else {
            (, uint256 bidPlaced) =
                _assertPosition(_bidId(), lower, upper, 0, terminalIn, "token0 bid clamped to the corridor");
            assertEq(_askId(), 0, "token1 ask skipped");
            assertEq(_projLedger(), projectIn, "token1 project carried");
            assertEq(_termLedger(), terminalIn - bidPlaced, "token0 fully deployed but V4 rounding");
        }
        _assertLedgersBacked();
    }

    function test_MinSqrtPrice_ProjectToken0() public {
        _runMinPrice(true, TickMath.MIN_SQRT_PRICE);
    }

    function test_MinSqrtPricePlusOne_ProjectToken0() public {
        _runMinPrice(true, TickMath.MIN_SQRT_PRICE + 1);
    }

    function test_MinSqrtPrice_ProjectToken1() public {
        _runMinPrice(false, TickMath.MIN_SQRT_PRICE);
    }

    function test_MinSqrtPricePlusOne_ProjectToken1() public {
        _runMinPrice(false, TickMath.MIN_SQRT_PRICE + 1);
    }

    // ─── Corridor construction (both orderings)
    // ────────────────────────────────────────────────

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

    /// @notice Set exact economics: the cash-out value per project token (18 decimals) and the issuance rate (project
    /// tokens per terminal token, no reserved share).
    function _setPrices(uint256 cashOutValue, uint256 issuanceRate) internal {
        controller.setWeight(PID, issuanceRate);
        controller.setReservedPercent(PID, 0);
        store.setTaxedCashOutCurve({projectId: PID, surplus: cashOutValue, supply: 1e18, taxRate: 0});
    }

    function _emptyEconomics(Empty kind) internal {
        if (kind == Empty.Inverted) _setPrices(1e18, 900e18);
        else if (kind == Empty.SubTickInverted) _setPrices(0.001111122222222222e18, 900e18);
        else if (kind == Empty.Equal) _setPrices(1e18, 1e18);
        else _setPrices(0.0011e18, 900e18);
    }

    /// @notice The `_wire` economics: the cash-out floor genuinely below the issuance ceiling.
    function _restoreEconomics() internal {
        controller.setWeight(PID, DEFAULT_WEIGHT);
        controller.setReservedPercent(PID, DEFAULT_RESERVED_PERCENT);
        _setWideTaxedCurve(PID);
    }

    /// @notice The exact cash-out and issuance prices as pool sqrt prices, before any tick rounding.
    function _exactPrices() internal view returns (uint160 cashOutSqrtPrice, uint160 issuanceSqrtPrice) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PID);
        cashOutSqrtPrice = JBUniswapV4LPSplitHookMath.getCashOutRateSqrtPriceX96({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PID,
            terminalToken: address(term),
            projectToken: address(proj),
            controller: address(controller),
            ruleset: ruleset
        });
        issuanceSqrtPrice = JBUniswapV4LPSplitHookMath.getIssuanceRateSqrtPriceX96({
            directory: IJBDirectory(address(directory)),
            projectId: PID,
            terminalToken: address(term),
            projectToken: address(proj),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    function _seed() internal view returns (uint160 sqrtPriceX96) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PID);
        sqrtPriceX96 = JBUniswapV4LPSplitHookMath.computeInitialSqrtPrice({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PID,
            terminalToken: address(term),
            projectToken: address(proj),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    function _assertCorridor(int24 expectedLower, int24 expectedUpper) internal view {
        (int24 lower, int24 upper) = _corridor();
        assertEq(lower, expectedLower, "corridor lower");
        assertEq(upper, expectedUpper, "corridor upper");
    }

    function _assertCorridorEmpty() internal view {
        (int24 lower, int24 upper) = _corridor();
        assertEq(lower, 0, "empty corridor: lower is 0");
        assertEq(upper, 0, "empty corridor: upper is 0");
    }

    function _assertRetired(uint256 tokenId, string memory label) internal view {
        (,,,,,, bool exists) = positionManager._positions(tokenId);
        assertFalse(exists, label);
    }

    /// @notice Empty the corridor and check the sub-tick case really is hidden by tick rounding.
    function _emptyAndCheck(Empty kind) internal {
        _emptyEconomics(kind);
        if (kind == Empty.SubTickInverted) {
            (uint160 cashOutSqrtPrice, uint160 issuanceSqrtPrice) = _exactPrices();
            assertEq(
                TickMath.getTickAtSqrtPrice(cashOutSqrtPrice),
                TickMath.getTickAtSqrtPrice(issuanceSqrtPrice),
                "precondition: both prices round to one tick"
            );
            assertTrue(
                projectIsToken0 ? cashOutSqrtPrice > issuanceSqrtPrice : cashOutSqrtPrice < issuanceSqrtPrice,
                "precondition: the cash-out value is above the issuance price"
            );
        }
        _assertCorridorEmpty();
    }

    /// @notice A first deploy with an empty corridor has nothing to retire: it reverts `EmptyCorridor` before seeding
    /// or accepting a pool price, so nothing is initialized or minted and the reserved tokens stay ledgered. Normal
    /// economics then deploy them, at the pre-initialized price when there is one.
    function _runEmptyDeploy(bool wantProjectToken0, Empty kind, bool preInitialized) internal {
        _wire(wantProjectToken0);
        uint160 existing = TickMath.getSqrtPriceAtTick(_midTick());
        if (preInitialized) positionManager.initializePool(key, existing);
        _emptyAndCheck(kind);
        assertEq(_seed(), 0, "an empty corridor has no seed price");
        _accumulate(1e18);
        uint256 nextId = positionManager.nextTokenId();

        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_EmptyCorridor.selector, PID, address(term)
            )
        );
        vm.prank(user);
        hook.deployPool(PID);
        assertFalse(hook.isPoolDeployed(PID, address(term)), "empty: the pool is not deployed");
        assertEq(_spot(), preInitialized ? existing : 0, "empty: the pool price is untouched");
        assertEq(positionManager.nextTokenId(), nextId, "empty: nothing minted");
        assertEq(_projLedger(), 1e18, "empty: the reserved tokens stay ledgered");
        assertEq(proj.balanceOf(address(hook)), 1e18, "empty: the hook still holds them");

        _restoreEconomics();
        vm.prank(user);
        hook.deployPool(PID);
        if (preInitialized) assertEq(_spot(), existing, "the pre-initialized price is kept");
        // Normal economics: the ask holds every reserved token but V4 rounding, which stays ledgered, and no terminal.
        assertEq(_bidId(), 0, "normal economics: nothing to bid with");
        _assertPlacedExactly(PID, address(proj), address(term), 1e18, 0);
        _assertLedgersBacked();
    }

    function test_EmptyCorridor_DeployReverts_ProjectToken0() public {
        _runEmptyDeploy(true, Empty.Inverted, false);
    }

    function test_EmptyCorridor_DeployReverts_ProjectToken1() public {
        _runEmptyDeploy(false, Empty.Inverted, false);
    }

    function test_EmptyCorridor_DeployReverts_PreInitialized_ProjectToken0() public {
        _runEmptyDeploy(true, Empty.Inverted, true);
    }

    function test_EmptyCorridor_DeployReverts_PreInitialized_ProjectToken1() public {
        _runEmptyDeploy(false, Empty.Inverted, true);
    }

    function test_EmptyCorridor_SubTickInversion_DeployReverts_ProjectToken0() public {
        _runEmptyDeploy(true, Empty.SubTickInverted, false);
    }

    function test_EmptyCorridor_SubTickInversion_DeployReverts_ProjectToken1() public {
        _runEmptyDeploy(false, Empty.SubTickInverted, false);
    }

    function test_EmptyCorridor_SubTickInversion_DeployReverts_PreInitialized_ProjectToken0() public {
        _runEmptyDeploy(true, Empty.SubTickInverted, true);
    }

    function test_EmptyCorridor_SubTickInversion_DeployReverts_PreInitialized_ProjectToken1() public {
        _runEmptyDeploy(false, Empty.SubTickInverted, true);
    }

    function test_EmptyCorridor_EqualPrices_DeployReverts_ProjectToken0() public {
        _runEmptyDeploy(true, Empty.Equal, false);
    }

    function test_EmptyCorridor_EqualPrices_DeployReverts_ProjectToken1() public {
        _runEmptyDeploy(false, Empty.Equal, false);
    }

    function test_EmptyCorridor_NarrowBand_DeployReverts_ProjectToken0() public {
        _runEmptyDeploy(true, Empty.Narrow, false);
    }

    function test_EmptyCorridor_NarrowBand_DeployReverts_ProjectToken1() public {
        _runEmptyDeploy(false, Empty.Narrow, false);
    }

    function test_EmptyCorridor_NarrowBand_DeployReverts_Native() public {
        nativeTerminal = true;
        _runEmptyDeploy(false, Empty.Narrow, false);
    }

    /// @notice A cash-out value of 0.98 against an issuance price of 1/0.99 leaves exactly one aligned spacing between
    /// them, which stays a valid corridor: the seed folds onto the floor bound and the ask fills the whole spacing.
    function _runOneSpacing(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        _setPrices(0.98e18, 0.99e18);
        // Project token0: cash-out tick -203 rounds inward to -200, issuance tick 100 to 0. Project token1: issuance
        // tick -101 rounds inward to 0, cash-out tick 202 to 200.
        (int24 lower, int24 upper) = projectIsToken0 ? (int24(-200), int24(0)) : (int24(0), int24(200));
        _assertCorridor(lower, upper);
        _accumulate(1e18);

        vm.prank(user);
        hook.deployPool(PID);

        (, int24 floor) = _ceilingAndFloor();
        assertEq(_spot(), TickMath.getSqrtPriceAtTick(floor), "the seed folds onto the floor bound");
        _assertPosition(_askId(), lower, upper, 1e18, 0, "one-spacing ask");
        assertEq(_bidId(), 0, "nothing to bid with");
        _assertPlacedExactly(PID, address(proj), address(term), 1e18, 0);
        _assertLedgersBacked();
    }

    function test_Corridor_OneSpacingWide_Deploys_ProjectToken0() public {
        _runOneSpacing(true);
    }

    function test_Corridor_OneSpacingWide_Deploys_ProjectToken1() public {
        _runOneSpacing(false);
    }

    /// @notice The lower bound rounds inward against its exact price. Its exact price sits half a tick above tick 0
    /// (1.00005 in pool terms), so the first aligned tick at or above it is 200, not 0: project token0 bounds a
    /// cash-out value of 1.00005 against an issuance price of 2; project token1 bounds an issuance price of 1/1.00005
    /// against a cash-out value of 0.5. Once the spot reaches the floor, the ask spans exactly that corridor.
    function _runInwardLower(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        if (wantProjectToken0) _setPrices(1.00005e18, 0.5e18);
        else _setPrices(0.5e18, 1.00005e18);
        (uint160 cashOutSqrtPrice, uint160 issuanceSqrtPrice) = _exactPrices();
        uint160 exactLower = projectIsToken0 ? cashOutSqrtPrice : issuanceSqrtPrice;
        assertGt(exactLower, TickMath.getSqrtPriceAtTick(0), "precondition: the exact lower price is above tick 0");
        assertLt(exactLower, TickMath.getSqrtPriceAtTick(1), "precondition: and below tick 1");
        // Upper: the exact price 2 is tick 6931, aligned down to 6800.
        _assertCorridor(200, 6800);

        _deployAt(TickMath.getSqrtPriceAtTick(_midTick()), 1e18);
        (, int24 floor) = _ceilingAndFloor();
        _swapTo(TickMath.getSqrtPriceAtTick(floor));
        (uint256 projectIn,) = _inventory();
        _recycle();
        _assertPosition(_askId(), 200, 6800, projectIn, 0, "corridor-wide ask");
        assertGe(TickMath.getSqrtPriceAtTick(200), exactLower, "no ask reaches past the exact lower price");
        _assertLedgersBacked();
    }

    function test_Corridor_LowerBoundRoundsInward_ProjectToken0() public {
        _runInwardLower(true);
    }

    function test_Corridor_LowerBoundRoundsInward_ProjectToken1() public {
        _runInwardLower(false);
    }

    function test_Corridor_LowerBoundRoundsInward_Native() public {
        nativeTerminal = true;
        _runInwardLower(false);
    }

    /// @notice With no cash-out value, project token1's lower bound is the issuance ceiling and rounds inward too: an
    /// issuance price of 1/1.00005 (half a tick above tick 0) gives [200, 600], never an ask at tick 0 above it.
    function test_Corridor_ZeroCashOut_LowerBoundRoundsInward_ProjectToken1() public {
        _wire(false);
        _setPrices(0, 1.00005e18);
        _assertCorridor(200, 600);
    }

    function test_Corridor_ZeroCashOut_LowerBoundRoundsInward_Native() public {
        nativeTerminal = true;
        test_Corridor_ZeroCashOut_LowerBoundRoundsInward_ProjectToken1();
    }

    /// @notice Corridor prices keep their precision at tiny rates. A weight of 2 project-token wei per terminal token
    /// (no cash-out value) bounds the ceiling at 3 wei (the gross rate plus one), 1/3e18 terminal tokens per project
    /// token: tick 403,499 in project-token0 terms, aligned down to 403,400 with the floor gap below it. A weight of 1
    /// bounds it at 2 wei: [407,000, 407,400]. Taking the root before scaling encoded both like a rate of 1.
    function _runTinyIssuance(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        _setPrices(0, 2);
        if (projectIsToken0) _assertCorridor(403_000, 403_400);
        else _assertCorridor(-403_400, -403_000);
        _setPrices(0, 1);
        if (projectIsToken0) _assertCorridor(407_000, 407_400);
        else _assertCorridor(-407_400, -407_000);
    }

    function test_Corridor_TinyIssuanceRate_KeepsPrecision_ProjectToken0() public {
        _runTinyIssuance(true);
    }

    function test_Corridor_TinyIssuanceRate_KeepsPrecision_ProjectToken1() public {
        _runTinyIssuance(false);
    }

    function test_Corridor_TinyIssuanceRate_KeepsPrecision_Native() public {
        nativeTerminal = true;
        _runTinyIssuance(false);
    }

    /// @notice A cash-out value previewed at 2 wei per project token against an issuance rate of 1e33: the floor uses
    /// the preview's bound, 4e-18 terminal tokens per project token (tick -400,623 rounded inward to -400,600 in
    /// project-token0 terms), never the -414,400 that taking the root before scaling gave.
    function _runTinyCashOut(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        _setPrices(2, 1e33);
        if (projectIsToken0) _assertCorridor(-400_600, -345_600);
        else _assertCorridor(345_600, 400_600);
    }

    function test_Corridor_TinyCashOutValue_KeepsPrecision_ProjectToken0() public {
        _runTinyCashOut(true);
    }

    function test_Corridor_TinyCashOutValue_KeepsPrecision_ProjectToken1() public {
        _runTinyCashOut(false);
    }

    function test_Corridor_TinyCashOutValue_KeepsPrecision_Native() public {
        nativeTerminal = true;
        _runTinyCashOut(false);
    }

    /// @notice The floor is never below what a cash-out realizes. With no tax, a supply of 100e18 and a surplus of 250
    /// wei, the 1-token preview truncates 2.5 to 2 wei, but burning 2e18 tokens returns 5 (2.5 per token). The floor
    /// encodes the preview plus two, so the corridor's floor bound sits at or above 2.5e-18 terminal tokens per project
    /// token.
    function _runFloorAboveRealized(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        _setPrices(0, 1e33);
        store.setTaxedCashOutCurve({projectId: PID, surplus: 250, supply: 100e18, taxRate: 0});
        (uint256 cashOutPreview,) = _previews();
        assertEq(cashOutPreview, 2, "precondition: the preview truncates to 2");
        assertEq(store.currentTotalReclaimableSurplusOf(PID, 2e18, 18, 0), 5, "precondition: 2e18 tokens reclaim 5");

        (int24 lower, int24 upper) = _corridor();
        if (projectIsToken0) {
            assertEq(lower, -400_600, "floor bound");
            // Pool price is terminal per project: the floor bound's price is at least 5 / 2e18.
            assertGe(_cmpSquare(TickMath.getSqrtPriceAtTick(lower), 2e18, 5), 0, "floor at or above 2.5e-18");
        } else {
            assertEq(upper, 400_600, "floor bound");
            // Pool price is project per terminal: the floor bound's price is at most 2e18 / 5.
            assertLe(_cmpSquare(TickMath.getSqrtPriceAtTick(upper), 5, 2e18), 0, "floor at or above 2.5e-18");
        }
    }

    function test_Corridor_FloorAtOrAboveRealizedCashOut_ProjectToken0() public {
        _runFloorAboveRealized(true);
    }

    function test_Corridor_FloorAtOrAboveRealizedCashOut_ProjectToken1() public {
        _runFloorAboveRealized(false);
    }

    /// @notice The ceiling is never above what a payer mints at. A weight of 3 with a 10% reserve previews 2 (2.7
    /// truncated), but paying 10e18 terminal tokens mints 27 for the payer, a price of 10e18 / 27 terminal tokens per
    /// project token. The ceiling encodes (gross + 1) * 90% rounded up, 4, so the ceiling bound sits at or below it.
    function _runCeilingBelowPayer(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        _setPrices(0, 3);
        controller.setReservedPercent(PID, 1000);
        (, uint256 issuancePreview) = _previews();
        assertEq(issuancePreview, 2, "precondition: the preview truncates to 2");
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PID);
        uint256 gross = JBUniswapV4LPSplitHookMath.getProjectTokensOutForTerminalTokensIn({
            directory: IJBDirectory(address(directory)),
            projectId: PID,
            terminalToken: address(term),
            terminalTokenInAmount: 10e18,
            controller: address(controller),
            ruleset: ruleset
        });
        assertEq(gross * 9000 / 10_000, 27, "precondition: paying 10e18 mints 27 for the payer");

        (int24 lower, int24 upper) = _corridor();
        if (projectIsToken0) {
            assertEq(upper, 400_600, "ceiling bound");
            // Pool price is terminal per project: the ceiling bound's price is at most 10e18 / 27.
            assertLe(_cmpSquare(TickMath.getSqrtPriceAtTick(upper), 27, 10e18), 0, "ceiling at or below the payer");
        } else {
            assertEq(lower, -400_600, "ceiling bound");
            // Pool price is project per terminal: the ceiling bound's price is at least 27 / 10e18.
            assertGe(_cmpSquare(TickMath.getSqrtPriceAtTick(lower), 10e18, 27), 0, "ceiling at or below the payer");
        }
    }

    function test_Corridor_CeilingAtOrBelowPayerPrice_ProjectToken0() public {
        _runCeilingBelowPayer(true);
    }

    function test_Corridor_CeilingAtOrBelowPayerPrice_ProjectToken1() public {
        _runCeilingBelowPayer(false);
    }

    /// @notice Under a cash-out tax the 1-token preview truncates twice, so the floor bound is the preview plus two. A
    /// 21% tax, a supply of 1000e18 and a surplus of 5900 wei preview 3 per token, yet burning 0.7e18 tokens returns 3
    /// (about 4.29 per token), above a bound of 4. The floor encodes 5 (tick -398,4xx, rounded inward to -398,200).
    function _runTaxedFloor(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        _setPrices(0, 1e33);
        store.setTaxedCashOutCurve({projectId: PID, surplus: 5900, supply: 1000e18, taxRate: 2100});
        (uint256 cashOutPreview,) = _previews();
        assertEq(cashOutPreview, 3, "precondition: the preview truncates to 3");
        assertEq(store.currentTotalReclaimableSurplusOf(PID, 0.7e18, 18, 0), 3, "precondition: 0.7e18 tokens reclaim 3");

        (int24 lower, int24 upper) = _corridor();
        if (projectIsToken0) {
            assertEq(lower, -398_200, "floor bound");
            // Pool price is terminal per project: the floor bound's price is at least 3 / 0.7e18.
            assertGe(_cmpSquare(TickMath.getSqrtPriceAtTick(lower), 0.7e18, 3), 0, "floor at or above 3 / 0.7e18");
        } else {
            assertEq(upper, 398_200, "floor bound");
            // Pool price is project per terminal: the floor bound's price is at most 0.7e18 / 3.
            assertLe(_cmpSquare(TickMath.getSqrtPriceAtTick(upper), 3, 0.7e18), 0, "floor at or above 3 / 0.7e18");
        }
    }

    function test_Corridor_TaxedFloorAtOrAboveRealizedCashOut_ProjectToken0() public {
        _runTaxedFloor(true);
    }

    function test_Corridor_TaxedFloorAtOrAboveRealizedCashOut_ProjectToken1() public {
        _runTaxedFloor(false);
    }

    function test_Corridor_TaxedFloorAtOrAboveRealizedCashOut_Native() public {
        nativeTerminal = true;
        _runTaxedFloor(false);
    }

    /// @notice A nonzero weight always issues something at some payment size, even when the 1-WAD sample rounds to 0.
    /// A weight of 1 wei with a 10% reserve previews 0, yet paying 10e18 mints 9 wei for the payer. The ceiling is the
    /// bound ceil((1 + 1) * 90%) = 2 (tick 407,554 aligned down to 407,400 in project-token0 terms), at or below the
    /// payer's 10e18 / 9, not the full range of a project with no issuance.
    function _runRoundedZeroIssuance(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        _setPrices(0, 1);
        controller.setReservedPercent(PID, 1000);
        (, uint256 issuancePreview) = _previews();
        assertEq(issuancePreview, 0, "precondition: the preview rounds to 0");
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PID);
        uint256 gross = JBUniswapV4LPSplitHookMath.getProjectTokensOutForTerminalTokensIn({
            directory: IJBDirectory(address(directory)),
            projectId: PID,
            terminalToken: address(term),
            terminalTokenInAmount: 10e18,
            controller: address(controller),
            ruleset: ruleset
        });
        assertEq(gross * 9000 / 10_000, 9, "precondition: paying 10e18 mints 9 for the payer");

        (int24 lower, int24 upper) = _corridor();
        if (projectIsToken0) {
            assertEq(lower, 407_000, "corridor lower");
            assertEq(upper, 407_400, "ceiling bound");
            assertLe(_cmpSquare(TickMath.getSqrtPriceAtTick(upper), 9, 10e18), 0, "ceiling at or below the payer");
        } else {
            assertEq(lower, -407_400, "ceiling bound");
            assertEq(upper, -407_000, "corridor upper");
            assertGe(_cmpSquare(TickMath.getSqrtPriceAtTick(lower), 10e18, 9), 0, "ceiling at or below the payer");
        }
    }

    function test_Corridor_RoundedZeroIssuanceIsBounded_ProjectToken0() public {
        _runRoundedZeroIssuance(true);
    }

    function test_Corridor_RoundedZeroIssuanceIsBounded_ProjectToken1() public {
        _runRoundedZeroIssuance(false);
    }

    /// @notice A nonzero weight whose 1-WAD sample itself rounds to 0 is not structurally zero: a weight of 1 against a
    /// conversion price of 1e19 previews 0 gross, yet paying 10e18 terminal tokens mints 1. The ceiling is the finite
    /// bound ceil((0 + 1) * 100%) = 1 project wei per terminal token, a pool price of 1e18 terminal per project (tick
    /// 414,486 aligned down to 414,400 in project-token0 terms) at or below the payer's 10e18, with the two-spacing
    /// floor gap; never the extreme price of a project with no issuance.
    function _runGrossZeroIssuance(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        _setPrices(0, 1);
        prices.setPrice(PID, _termCurrencyId(), 1, 1e19);
        (, uint256 issuancePreview) = _previews();
        assertEq(issuancePreview, 0, "precondition: the preview rounds to 0");
        assertEq(_grossOut(1e18), 0, "precondition: the gross 1-WAD sample rounds to 0");
        assertEq(_grossOut(10e18), 1, "precondition: paying 10e18 mints 1");

        (int24 lower, int24 upper) = _corridor();
        if (projectIsToken0) {
            assertEq(lower, 414_000, "corridor lower");
            assertEq(upper, 414_400, "ceiling bound");
            assertLe(_cmpSquare(TickMath.getSqrtPriceAtTick(upper), 1, 10e18), 0, "ceiling at or below the payer");
        } else {
            assertEq(lower, -414_400, "ceiling bound");
            assertEq(upper, -414_000, "corridor upper");
            assertGe(_cmpSquare(TickMath.getSqrtPriceAtTick(lower), 10e18, 1), 0, "ceiling at or below the payer");
        }
    }

    /// @notice The gross project tokens a payment of `amount` terminal tokens mints, before reserves.
    function _grossOut(uint256 amount) internal view returns (uint256) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PID);
        return JBUniswapV4LPSplitHookMath.getProjectTokensOutForTerminalTokensIn({
            directory: IJBDirectory(address(directory)),
            projectId: PID,
            terminalToken: term,
            terminalTokenInAmount: amount,
            controller: address(controller),
            ruleset: ruleset
        });
    }

    function test_Corridor_GrossZeroIssuanceIsBounded_ProjectToken0() public {
        _runGrossZeroIssuance(true);
    }

    function test_Corridor_GrossZeroIssuanceIsBounded_ProjectToken1() public {
        _runGrossZeroIssuance(false);
    }

    function test_Corridor_GrossZeroIssuanceIsBounded_Native() public {
        nativeTerminal = true;
        _runGrossZeroIssuance(false);
    }

    /// @notice With genuinely no issuance and no cash-out value, the range is full on the ceiling side but its floor
    /// side still stops at the cash-out bound of 2 wei per project token (tick -407,4xx rounded inward to -407,400 in
    /// project-token0 terms). Issuance is structurally zero for either cause: a zero weight, or a nonzero weight with
    /// every minted token reserved.
    function _runNoIssuance(bool wantProjectToken0, bool allReserved) internal {
        _wire(wantProjectToken0);
        _setPrices(0, allReserved ? DEFAULT_WEIGHT : 0);
        if (allReserved) controller.setReservedPercent(PID, uint16(JBConstants.MAX_RESERVED_PERCENT));
        if (projectIsToken0) _assertCorridor(-407_400, 887_000);
        else _assertCorridor(-887_200, 407_400);
    }

    function test_Corridor_NoIssuance_FloorStopsAtCashOutBound_ProjectToken0() public {
        _runNoIssuance(true, false);
    }

    function test_Corridor_NoIssuance_FloorStopsAtCashOutBound_ProjectToken1() public {
        _runNoIssuance(false, false);
    }

    function test_Corridor_NoIssuance_FloorStopsAtCashOutBound_Native() public {
        nativeTerminal = true;
        _runNoIssuance(false, false);
    }

    function test_Corridor_AllReserved_FloorStopsAtCashOutBound_ProjectToken0() public {
        _runNoIssuance(true, true);
    }

    function test_Corridor_AllReserved_FloorStopsAtCashOutBound_ProjectToken1() public {
        _runNoIssuance(false, true);
    }

    function test_Corridor_AllReserved_FloorStopsAtCashOutBound_Native() public {
        nativeTerminal = true;
        _runNoIssuance(false, true);
    }

    /// @notice A cash-out preview of 0 still bounds the floor, and the floor wins over the zero-cash-out geometry. A
    /// six-decimal terminal in the base currency at weight 2e24 issues at 0.5 raw units per project token, while a
    /// surplus of 99 raw units over a supply of 100e18 previews 0 yet realizes 0.99 per token when the supply burns.
    /// The cash-out bound (2 raw units) is above the issuance price, so the corridor is empty and has no seed.
    function _runZeroPreviewFloor(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        uint32 currency = _termCurrencyId();
        terminal.setAccountingContext(PID, address(term), currency, 6);
        controller.setBaseCurrency(PID, currency);
        _setPrices(0, 2e24);
        store.setTaxedCashOutCurve({projectId: PID, surplus: 99, supply: 100e18, taxRate: 0});
        (uint256 cashOutPreview, uint256 issuancePreview) = _previews();
        assertEq(cashOutPreview, 0, "precondition: the cash-out preview rounds to 0");
        assertEq(issuancePreview, 2e36, "precondition: 2e36 project wei per 1e18 raw units (0.5 per token)");
        assertEq(store.currentTotalReclaimableSurplusOf(PID, 100e18, 6, 0), 99, "precondition: the supply reclaims 99");

        _assertCorridorEmpty();
        assertEq(_seed(), 0, "no seed price");
    }

    function test_Corridor_ZeroCashOutPreview_FloorEmptiesCorridor_ProjectToken0() public {
        _runZeroPreviewFloor(true);
    }

    function test_Corridor_ZeroCashOutPreview_FloorEmptiesCorridor_ProjectToken1() public {
        _runZeroPreviewFloor(false);
    }

    function test_Corridor_ZeroCashOutPreview_FloorEmptiesCorridor_Native() public {
        nativeTerminal = true;
        _runZeroPreviewFloor(false);
    }

    /// @notice For an ordinary 18-decimal project with no surplus (weights 1e18 to 1e24 per terminal token), the
    /// cash-out bound sits hundreds of thousands of ticks below the issuance price, so the floor lift never binds: the
    /// corridor is exactly the two-spacing gap below the aligned issuance ceiling.
    function testFuzz_Corridor_ZeroSurplus_FloorLiftNeverBinds(
        bool wantProjectToken0,
        uint256 weight,
        uint16 reservedPercent
    )
        public
    {
        _wire(wantProjectToken0);
        _setPrices(0, bound(weight, 1e18, 1e24));
        controller.setReservedPercent(PID, uint16(bound(reservedPercent, 0, 9000)));
        (, uint160 ceilingSqrtPrice) = _exactPrices();
        int24 ceilingTick = TickMath.getTickAtSqrtPrice(ceilingSqrtPrice);
        if (projectIsToken0) {
            int24 upper = _alignDown(ceilingTick);
            _assertCorridor(upper - 2 * SPACING, upper);
        } else {
            if (TickMath.getSqrtPriceAtTick(ceilingTick) < ceilingSqrtPrice) ceilingTick++;
            int24 lower = -_alignDown(-ceilingTick);
            _assertCorridor(lower, lower + 2 * SPACING);
        }
    }

    /// @notice `tick` rounded down to the spacing grid.
    function _alignDown(int24 tick) internal pure returns (int24) {
        // Intentionally divide before multiplying to align to the spacing grid.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 aligned = (tick / SPACING) * SPACING;
        return aligned > tick ? aligned - SPACING : aligned;
    }

    /// @notice The cash-out and issuance previews (per-WAD rates, truncated).
    function _previews() internal view returns (uint256 cashOutValue, uint256 issuanceRate) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PID);
        cashOutValue = JBUniswapV4LPSplitHookMath.getCashOutRate({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PID,
            terminalToken: address(term),
            controller: address(controller),
            ruleset: ruleset
        });
        issuanceRate = JBUniswapV4LPSplitHookMath.getIssuanceRate({
            directory: IJBDirectory(address(directory)),
            projectId: PID,
            terminalToken: address(term),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    /// @notice For realistic rates the conservative bounds move each price by less than one tick from its preview:
    /// the floor at most a factor 1.0001 above the cash-out preview and the ceiling at most that factor below the
    /// issuance preview (in project price), so each aligned bound moves by at most the one-spacing tick rounding.
    function testFuzz_Corridor_RealisticRates_MoveLessThanOneTick(
        bool wantProjectToken0,
        uint256 cashOutValue,
        uint256 weight,
        uint16 reservedPercent
    )
        public
    {
        _wire(wantProjectToken0);
        weight = bound(weight, 1e18, 1e30);
        reservedPercent = uint16(bound(reservedPercent, 0, 9000));
        _setPrices(bound(cashOutValue, 1e9, 1e30), weight);
        controller.setReservedPercent(PID, reservedPercent);
        (uint256 cashOut, uint256 issuance) = _previews();
        (uint160 floorSqrtPrice, uint160 ceilingSqrtPrice) = _exactPrices();
        if (projectIsToken0) {
            // Pool price is terminal per project.
            assertGe(_cmpSquare(floorSqrtPrice, 1e18, cashOut), 0, "floor at or above the preview");
            assertLe(_cmpSquare(floorSqrtPrice, 1e22, cashOut * 10_001), 0, "floor within one tick");
            assertLe(_cmpSquare(ceilingSqrtPrice, issuance, 1e18), 0, "ceiling at or below the preview");
            assertGe(_cmpSquare(ceilingSqrtPrice, issuance * 10_001, 1e22), 0, "ceiling within one tick");
        } else {
            // Pool price is project per terminal.
            assertLe(_cmpSquare(floorSqrtPrice, cashOut, 1e18), 0, "floor at or above the preview");
            assertGe(_cmpSquare(floorSqrtPrice, cashOut * 10_001, 1e22), 0, "floor within one tick");
            assertGe(_cmpSquare(ceilingSqrtPrice, 1e18, issuance), 0, "ceiling at or below the preview");
            assertLe(_cmpSquare(ceilingSqrtPrice, 1e22, issuance * 10_001), 0, "ceiling within one tick");
        }
    }

    /// @notice Each corridor price encodes conservatively and tightly: the cash-out floor at or above its bound (the
    /// preview plus two) in project price, the issuance ceiling at or below its bound (the gross rate plus one, no
    /// reserve here), each within one unit of root precision (one, or 2^64 when the ratio is at least 2^64 and the
    /// root is shifted), and clamped to TickMath's limits only when the exact price lies past them.
    function testFuzz_Encoder_FloorAtOrAboveCeilingAtOrBelow(
        bool wantProjectToken0,
        uint256 cashOutValue,
        uint256 issuanceRate
    )
        public
    {
        cashOutValue = bound(cashOutValue, 0, type(uint256).max - 2);
        issuanceRate = bound(issuanceRate, 1, type(uint112).max);
        _wire(wantProjectToken0);
        _setPrices(cashOutValue, issuanceRate);
        (uint160 cashOutSqrtPrice, uint160 issuanceSqrtPrice) = _exactPrices();
        // Pool price is token1 per token0. A higher project price is a higher pool price for project token0 (round
        // up) and a lower one for project token1 (round down); the ceiling rounds the other way.
        if (projectIsToken0) {
            _assertEncodes(cashOutSqrtPrice, cashOutValue + 2, 1e18, true);
            _assertEncodes(issuanceSqrtPrice, 1e18, issuanceRate + 1, false);
        } else {
            _assertEncodes(cashOutSqrtPrice, 1e18, cashOutValue + 2, false);
            _assertEncodes(issuanceSqrtPrice, issuanceRate + 1, 1e18, true);
        }
    }

    /// @notice `sqrtPriceX96` is sqrt(amount1 / amount0) * 2^96 rounded up (or down), to `step` precision, then clamped
    /// to [MIN_SQRT_PRICE, MAX_SQRT_PRICE - 1]. A result on either limit is accepted only when the exact price puts the
    /// rounded encoding itself on or past that limit, so a clamp of a representable price fails.
    function _assertEncodes(uint160 sqrtPriceX96, uint256 amount1, uint256 amount0, bool roundUp) internal pure {
        uint256 step = amount1 / amount0 < 2 ** 64 ? 1 : 2 ** 64;
        uint256 maxPrice = TickMath.MAX_SQRT_PRICE - 1;
        uint256 minPrice = TickMath.MIN_SQRT_PRICE;
        if (sqrtPriceX96 == maxPrice) {
            // Rounded up, the encoding exceeds the exact root by under one step; rounded down, it never exceeds it.
            if (roundUp) {
                assertLt(_cmpSquare(maxPrice - step, amount0, amount1), 0, "max clamp: exact above max - step");
            } else {
                assertLe(_cmpSquare(maxPrice, amount0, amount1), 0, "max clamp: exact at or above max");
            }
            return;
        }
        if (sqrtPriceX96 == minPrice) {
            if (roundUp) assertGe(_cmpSquare(minPrice, amount0, amount1), 0, "min clamp: exact at or below min");
            else assertGt(_cmpSquare(minPrice + step, amount0, amount1), 0, "min clamp: exact below min + step");
            return;
        }
        if (roundUp) {
            assertGe(_cmpSquare(sqrtPriceX96, amount0, amount1), 0, "rounded up: at or above the exact price");
            assertLt(_cmpSquare(sqrtPriceX96 - step, amount0, amount1), 0, "rounded up: within one step");
        } else {
            assertLe(_cmpSquare(sqrtPriceX96, amount0, amount1), 0, "rounded down: at or below the exact price");
            assertGt(_cmpSquare(sqrtPriceX96 + step, amount0, amount1), 0, "rounded down: within one step");
        }
    }

    /// @notice Compare `root^2 * amount0` with `amount1 * 2^192` exactly in 768 bits (-1, 0 or 1), for any 256-bit
    /// inputs.
    function _cmpSquare(uint256 root, uint256 amount0, uint256 amount1) internal pure returns (int256) {
        (uint256 squareHi, uint256 squareLo) = _mul512(root, root);
        (uint256 carry, uint256 w0) = _mul512(squareLo, amount0);
        (uint256 w2, uint256 mid) = _mul512(squareHi, amount0);
        uint256 w1;
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

    /// @notice Deterministic encodings around every scaling and clamping threshold of project token0's cash-out floor
    /// (pool price (rate + 2) / 1e18, rounded up): the 2^64 and 2^128 ratio thresholds and MAX_SQRT_PRICE.
    /// Representable prices on either side of each threshold encode unclamped; only prices past the limit clamp to it.
    function test_Encoder_ClampsOnlyPastTheLimits_ProjectToken0() public {
        // The bound whose exact price is MAX_SQRT_PRICE - 1.
        uint256 maxPrice = TickMath.MAX_SQRT_PRICE - 1;
        uint256 atMax = mulDiv(maxPrice, maxPrice * 1e18, 2 ** 192);
        _wire(true);
        _assertFloorEncodes(2 ** 64 * 1e18 - 1, false);
        _assertFloorEncodes(2 ** 64 * 1e18, false);
        _assertFloorEncodes(2 ** 64 * 1e18 + 1, false);
        _assertFloorEncodes(2 ** 100 * 1e18, false);
        _assertFloorEncodes(atMax - 2 ** 100, false);
        // The exact price is just under the limit, but rounding up at 2^64 precision lands on or past it.
        _assertFloorEncodes(atMax, true);
        _assertFloorEncodes(atMax + 2 ** 100, true);
        _assertFloorEncodes(2 ** 128 * 1e18 - 1, true);
        _assertFloorEncodes(2 ** 128 * 1e18, true);
        _assertFloorEncodes(type(uint256).max, true);
        // A saturated floor empties the corridor.
        _assertCorridorEmpty();
    }

    /// @notice Project token1's cash-out floor (pool price 1e18 / (rate + 2), rounded down) reaches MIN_SQRT_PRICE:
    /// a price just above it encodes unclamped, one just below it clamps.
    function test_Encoder_ClampsOnlyPastTheLimits_ProjectToken1() public {
        // The bound whose exact price is MIN_SQRT_PRICE.
        uint256 atMin = mulDiv(1e18, 2 ** 192, uint256(TickMath.MIN_SQRT_PRICE) * TickMath.MIN_SQRT_PRICE);
        _wire(false);
        _assertFloorEncodes(atMin - 2 ** 160, false);
        _assertFloorEncodes(atMin + 2 ** 160, true);
        _assertFloorEncodes(type(uint256).max, true);
        // A saturated floor empties the corridor.
        _assertCorridorEmpty();
    }

    /// @notice Set the cash-out floor's bound to `bound` (the preview plus two, saturating) and check its encoding:
    /// conservative, tight, and on the TickMath limit exactly when `clamped`.
    function _assertFloorEncodes(uint256 bound_, bool clamped) internal {
        _setPrices(bound_ == type(uint256).max ? bound_ : bound_ - 2, 1);
        (uint160 cashOutSqrtPrice,) = _exactPrices();
        if (projectIsToken0) {
            _assertEncodes(cashOutSqrtPrice, bound_, 1e18, true);
            if (clamped) assertEq(cashOutSqrtPrice, TickMath.MAX_SQRT_PRICE - 1, "clamped to the maximum");
            else assertLt(cashOutSqrtPrice, TickMath.MAX_SQRT_PRICE - 1, "representable: not clamped");
        } else {
            _assertEncodes(cashOutSqrtPrice, 1e18, bound_, false);
            if (clamped) assertEq(cashOutSqrtPrice, TickMath.MIN_SQRT_PRICE, "clamped to the minimum");
            else assertGt(cashOutSqrtPrice, TickMath.MIN_SQRT_PRICE, "representable: not clamped");
        }
    }

    /// @notice The full 512-bit product of `a` and `b`.
    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    /// @notice An empty corridor has no seed price, however it went empty.
    function _runNoSeed(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        for (uint8 kind; kind <= uint8(Empty.Narrow); kind++) {
            _emptyEconomics(Empty(kind));
            assertEq(_seed(), 0, "no seed price");
        }
    }

    function test_EmptyCorridor_NoSeedPrice_ProjectToken0() public {
        _runNoSeed(true);
    }

    function test_EmptyCorridor_NoSeedPrice_ProjectToken1() public {
        _runNoSeed(false);
    }

    // ─── Empty corridor lifecycle (both orderings)
    // ────────────────────────────────────────────────

    /// @notice Live ask and bid, then the corridor goes empty: the recycle retires both, mints nothing and holds every
    /// token (principal, forgiven fee, new reserved tokens) exactly in the ledgers. A second recycle has nothing to
    /// retire and reverts. Normal economics redeploy everything into fresh positions.
    function _runEmptyRecycle(bool wantProjectToken0, Empty kind) internal {
        _wire(wantProjectToken0);
        int24 mid = _deployBothAtMid(1e18, 0.5e18);
        (int24 lower, int24 upper) = _corridor();
        uint256 oldAsk = _askId();
        uint256 oldBid = _bidId();
        (uint256 projectHeld, uint256 terminalHeld) = _livePrincipal();
        assertGt(projectHeld, 0, "precondition: the ask holds project principal");
        assertGt(terminalHeld, 0, "precondition: the bid holds terminal principal");
        uint256 projectLedger = _projLedger();
        uint256 terminalLedger = _termLedger();
        uint256 fee = 0.05e18;
        uint256 newTokens = 0.2e18;
        _addTerminalFee(oldAsk, fee);
        _accumulate(newTokens);

        _emptyAndCheck(kind);

        uint256 nextId = positionManager.nextTokenId();
        vm.expectEmit(true, true, true, true, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAdded({
            projectId: PID, terminalToken: address(term), askTokenId: 0, bidTokenId: 0, caller: user
        });
        _recycle();

        assertEq(_askId(), 0, "empty: no ask");
        assertEq(_bidId(), 0, "empty: no bid");
        assertEq(positionManager.nextTokenId(), nextId, "empty: nothing minted");
        _assertRetired(oldAsk, "empty: the old ask is burned");
        _assertRetired(oldBid, "empty: the old bid is burned");
        assertTrue(hook.isPoolDeployed(PID, address(term)), "the pool stays deployed");
        assertEq(_projLedger(), projectLedger + projectHeld + newTokens, "every project token is ledgered");
        assertEq(_termLedger(), terminalLedger + terminalHeld + fee, "every terminal token is ledgered");
        _assertLedgersBacked();
        // Only V4's rounding (at most one unit per burned position) stays in the pool; nothing else is left.
        assertEq(
            proj.balanceOf(address(positionManager)),
            positionManager.poolLocked(address(proj)),
            "the PositionManager holds only pool reserves"
        );
        assertEq(
            _termBalanceOf(address(positionManager)),
            positionManager.poolLocked(Currency.unwrap(_termCurrency())),
            "the PositionManager holds only pool reserves"
        );
        assertLe(
            proj.balanceOf(address(positionManager)), positionManager.burnCallCount(), "project rounding in the pool"
        );
        assertLe(
            _termBalanceOf(address(positionManager)), positionManager.burnCallCount(), "terminal rounding in the pool"
        );

        // Nothing left to retire: the recycle refuses and changes nothing.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_EmptyCorridor.selector, PID, address(term)
            )
        );
        _recycle();

        // The corridor reopens: the held inventory redeploys around the unchanged mid-corridor spot.
        _restoreEconomics();
        _assertCorridor(lower, upper);
        uint256 projectTotal = _projLedger();
        uint256 terminalTotal = _termLedger();
        _recycle();
        (int24 bidLower, int24 bidUpper) = projectIsToken0 ? (lower, mid) : (mid, upper);
        (int24 askLower, int24 askUpper) = projectIsToken0 ? (mid, upper) : (lower, mid);
        (uint256 askPlaced,) = _assertPosition(_askId(), askLower, askUpper, projectTotal, 0, "redeployed ask");
        (, uint256 bidPlaced) = _assertPosition(_bidId(), bidLower, bidUpper, 0, terminalTotal, "redeployed bid");
        assertGe(_askId(), nextId, "redeployed ask is a fresh id");
        assertGe(_bidId(), nextId, "redeployed bid is a fresh id");
        assertEq(_projLedger(), projectTotal - askPlaced, "the held project tokens redeployed");
        assertEq(_termLedger(), terminalTotal - bidPlaced, "the held terminal tokens redeployed");
        _assertLedgersBacked();
    }

    function test_EmptyCorridor_RecycleRetiresAndHolds_ProjectToken0() public {
        _runEmptyRecycle(true, Empty.Inverted);
    }

    function test_EmptyCorridor_RecycleRetiresAndHolds_ProjectToken1() public {
        _runEmptyRecycle(false, Empty.Inverted);
    }

    function test_EmptyCorridor_NarrowBand_RecycleRetiresAndHolds_ProjectToken0() public {
        _runEmptyRecycle(true, Empty.Narrow);
    }

    function test_EmptyCorridor_NarrowBand_RecycleRetiresAndHolds_ProjectToken1() public {
        _runEmptyRecycle(false, Empty.Narrow);
    }

    function test_EmptyCorridor_NarrowBand_RecycleRetiresAndHolds_Native() public {
        nativeTerminal = true;
        _runEmptyRecycle(false, Empty.Narrow);
    }
}
