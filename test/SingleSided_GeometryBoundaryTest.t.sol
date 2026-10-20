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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/// @notice Exact recycle geometry at the price boundaries, in BOTH Uniswap currency orderings (a fresh ERC-20 pair is
/// wired with the project token sorted as token0 or token1). Covers:
///   - the ceiling and floor edges: the side with no range is skipped and its inventory carried in its ledger while
///     the other side mints corridor-bounded; zero-project bid-only inventory; a nonzero amount that rounds to zero
///     liquidity; and redeployment of the carried inventory with fresh ids once the geometry is restored;
///   - the exact-price matrix: a spot exactly on an aligned tick `k` (both positions touch `k`), one wei above it, and
///     one wei below the next aligned tick, for negative and positive `k`;
///   - the MIN_TICK partial spacing: a recycle at `MIN_SQRT_PRICE` and `MIN_SQRT_PRICE + 1` mints token0 clamped to
///     the corridor and skips token1 without an out-of-range TickMath call;
///   - the inverted corridor: once the cash-out value exceeds the issuance price the corridor is empty, a recycle
///     retires both live positions and holds every token in the ledgers, a recycle or deploy with nothing to retire
///     reverts `InvertedCorridor`, and fresh positions redeploy once the economics are normal again.
/// @dev Spot moves go through `_swapTo`, which re-marks every live position to exactly the principal its liquidity
/// holds at the new price (the shared `TwoPositionFixture` helpers keep the PositionManager's balances backing it), so
/// burns always recover real principal and satisfy contract-derived burn minimums. The mocked TWAP tracks the spot.
contract SingleSided_GeometryBoundaryTest is TwoPositionFixture {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant PID = 7;
    int24 internal constant SPACING = 200;

    MockERC20 internal proj;
    MockERC20 internal term;
    PoolKey internal key;
    bool internal projectIsToken0;

    // ─── Harness
    // ───────────────────────────────────────────────────────────

    /// @notice Wire project `PID` against a fresh ERC-20 terminal token, with the project token sorted as requested.
    function _wire(bool wantProjectToken0) internal {
        proj = new MockERC20("Proj", "P", 18);
        term = new MockERC20("Term", "T", 18);
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
        terminal.setAccountingContext(PID, address(term), uint32(uint160(address(term))), 18);
        terminal.addAccountingContext(
            PID, JBAccountingContext({token: address(term), decimals: 18, currency: uint32(uint160(address(term)))})
        );
        jbTokens.setToken(PID, address(proj));
        // A non-inverted corridor: the cash-out floor sits genuinely below the issuance ceiling.
        _setWideTaxedCurve(PID);
        store.setBalance(address(terminal), PID, address(term), 10e18);
        _addDirectoryTerminal(PID, address(terminal));

        (address c0, address c1) = wantProjectToken0 ? (address(proj), address(term)) : (address(term), address(proj));
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
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
        term.mint(address(positionManager), amount);
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
        assertEq(term.balanceOf(address(hook)), _termLedger(), "terminal ledger equals the hook's terminal balance");
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

    // ─── Inverted corridor lifecycle (both orderings)
    // ────────────────────────────────────────────────

    /// @notice Cash-out value above the issuance price: one terminal token per project token against an issuance
    /// price of 1/900 terminal tokens.
    function _invertEconomics() internal {
        store.setTaxedCashOutCurve({projectId: PID, surplus: 1_000_000e18, supply: 1_000_000e18, taxRate: 0});
    }

    /// @notice The `_wire` economics: the cash-out floor genuinely below the issuance ceiling.
    function _restoreEconomics() internal {
        _setWideTaxedCurve(PID);
    }

    function _assertCorridorEmpty() internal view {
        (int24 lower, int24 upper) = _corridor();
        assertEq(lower, 0, "inverted corridor: lower is 0");
        assertEq(upper, 0, "inverted corridor: upper is 0");
    }

    function _assertRetired(uint256 tokenId, string memory label) internal view {
        (,,,,,, bool exists) = positionManager._positions(tokenId);
        assertFalse(exists, label);
    }

    /// @notice Live ask and bid, then the economics invert: the recycle retires both, mints nothing and holds every
    /// token (principal, forgiven fee, new reserved tokens) exactly in the ledgers. A second recycle has nothing to
    /// retire and reverts. Normal economics redeploy everything into fresh positions.
    function _runInvertedRecycle(bool wantProjectToken0) internal {
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

        _invertEconomics();
        _assertCorridorEmpty();

        uint256 nextId = positionManager.nextTokenId();
        vm.expectEmit(true, true, true, true, address(hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAdded({
            projectId: PID, terminalToken: address(term), askTokenId: 0, bidTokenId: 0, caller: user
        });
        _recycle();

        assertEq(_askId(), 0, "inverted: no ask");
        assertEq(_bidId(), 0, "inverted: no bid");
        assertEq(positionManager.nextTokenId(), nextId, "inverted: nothing minted");
        _assertRetired(oldAsk, "inverted: the old ask is burned");
        _assertRetired(oldBid, "inverted: the old bid is burned");
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
            term.balanceOf(address(positionManager)),
            positionManager.poolLocked(address(term)),
            "the PositionManager holds only pool reserves"
        );
        assertLe(
            proj.balanceOf(address(positionManager)), positionManager.burnCallCount(), "project rounding in the pool"
        );
        assertLe(
            term.balanceOf(address(positionManager)), positionManager.burnCallCount(), "terminal rounding in the pool"
        );

        // Nothing left to retire: the recycle refuses and changes nothing.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvertedCorridor.selector, PID, address(term)
            )
        );
        _recycle();

        // The economics normalize: the held inventory redeploys around the unchanged mid-corridor spot.
        _restoreEconomics();
        (int24 restoredLower, int24 restoredUpper) = _corridor();
        assertEq(restoredLower, lower, "restored corridor lower");
        assertEq(restoredUpper, upper, "restored corridor upper");
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

    function test_InvertedCorridor_RecycleRetiresAndHolds_ProjectToken0() public {
        _runInvertedRecycle(true);
    }

    function test_InvertedCorridor_RecycleRetiresAndHolds_ProjectToken1() public {
        _runInvertedRecycle(false);
    }

    /// @notice A first deploy under inverted economics has nothing to retire: it reverts, leaving the pool undeployed
    /// and the reserved tokens ledgered. Normal economics then deploy them.
    function _runInvertedDeploy(bool wantProjectToken0) internal {
        _wire(wantProjectToken0);
        _invertEconomics();
        _assertCorridorEmpty();
        _accumulate(1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvertedCorridor.selector, PID, address(term)
            )
        );
        vm.prank(user);
        hook.deployPool(PID);
        assertFalse(hook.isPoolDeployed(PID, address(term)), "inverted: the pool is not deployed");
        assertEq(_projLedger(), 1e18, "inverted: the reserved tokens stay ledgered");
        assertEq(proj.balanceOf(address(hook)), 1e18, "inverted: the hook still holds them");

        _restoreEconomics();
        vm.prank(user);
        hook.deployPool(PID);
        // Normal economics: the ask holds every reserved token but V4 rounding, which stays ledgered, and no terminal.
        assertEq(_bidId(), 0, "normal economics: nothing to bid with");
        _assertPlacedExactly(PID, address(proj), address(term), 1e18, 0);
        _assertLedgersBacked();
    }

    function test_InvertedCorridor_DeployReverts_ProjectToken0() public {
        _runInvertedDeploy(true);
    }

    function test_InvertedCorridor_DeployReverts_ProjectToken1() public {
        _runInvertedDeploy(false);
    }
}
