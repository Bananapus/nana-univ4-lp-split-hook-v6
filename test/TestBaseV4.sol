// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockPositionManager} from "./mock/MockPositionManager.sol";
import {MockPoolManager} from "./mock/MockPoolManager.sol";
import {MockGeomeanOracle} from "./mock/MockGeomeanOracle.sol";
import {
    MockJBDirectory,
    MockJBController,
    MockJBMultiTerminal,
    MockJBTokens,
    MockJBPrices,
    MockJBTerminalStore,
    MockJBProjects,
    MockJBPermissions
} from "./mock/MockJBContracts.sol";

// Terminal tokens reclaimable per 1e18 project tokens in the shared fixtures. Below the issuance price (1e18 /
// 900 after the 10% reserve), so the corridor is not inverted: about 7,980 ticks (39 spacings) from floor to ceiling.
uint256 constant DEFAULT_SURPLUS_PER_TOKEN = 0.0005e18;

/// @notice Minimal mock so the hook can call PERMIT2.approve() in unit tests.
contract MockPermit2 {
    mapping(address owner => mapping(address token => mapping(address spender => uint256))) public allowances;
    mapping(address owner => mapping(address token => mapping(address spender => uint48))) public expirations;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowances[msg.sender][token][spender] = amount;
        expirations[msg.sender][token][spender] = expiration;
    }

    /// @dev Like `AllowanceTransfer._transfer`, pulls with solmate's `safeTransferFrom`: a `false` return reverts
    /// `TRANSFER_FROM_FAILED` and an empty return is accepted.
    function transferFrom(address from, address to, uint160 amount, address token) external {
        allowances[from][token][msg.sender] -= amount;
        SafeTransferLib.safeTransferFrom(ERC20(token), from, to, amount);
    }
}

/// @notice Shared test harness for JBUniswapV4LPSplitHook tests
contract LPSplitHookV4TestBase is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── Contracts Under Test
    JBUniswapV4LPSplitHook public hook;

    // ─── Mock Infrastructure
    MockJBDirectory public directory;
    MockJBController public controller;
    MockJBMultiTerminal public terminal;
    MockJBTokens public jbTokens;
    MockJBPrices public prices;
    MockJBTerminalStore public store;
    MockPositionManager public positionManager;
    MockPoolManager public poolManager;
    /// @notice Spot-tracking oracle wired into the base `hook`. Subclasses that re-deploy the hook should reuse this
    /// (it tracks the base `poolManager`) so the spot-vs-TWAP guard on addLiquidity passes.
    MockGeomeanOracle public baseOracleHook;
    MockJBProjects public jbProjects;
    MockJBPermissions public permissions;

    // ─── Test Tokens
    MockERC20 public projectToken;
    MockERC20 public terminalToken;
    MockERC20 public feeProjectToken;

    // ─── Test Constants
    uint256 public constant PROJECT_ID = 1;
    uint256 public constant FEE_PROJECT_ID = 2;
    uint256 public constant FEE_PERCENT = 3800; // 38%
    uint256 public constant DEFAULT_WEIGHT = 1000e18;
    uint256 public constant DEFAULT_FIRST_WEIGHT = 1000e18;
    uint16 public constant DEFAULT_RESERVED_PERCENT = 1000; // 10%
    /// @notice Stand-in buyback-hook registry the hook holds as `buybackHook` (force-direct cash-out target).
    address public constant BUYBACK_REGISTRY = address(0xB0B);

    // ─── Hook Storage Slots
    // `JBUniswapV4LPSplitHook` declares its stored properties alphabetically (STYLE_GUIDE) and none of them pack, so
    // each occupies one slot in declaration order. Verified against `forge inspect ... storageLayout`:
    //   0 accumulatedProjectCredits   7 claimableFeeTokenOf      14 oracleHook
    //   1 accumulatedProjectTokens    8 claimableFeeTokens       15 poolKeysOf
    //   2 accumulatedTerminalTokens   9 deployedTerminalTokenOf  16 poolManager
    //   3 askTokenIdOf               10 feePercent               17 positionManager
    //   4 bidTokenIdOf               11 feeProjectId             18 _inflightFeeRoutingCount
    //   5 buybackHook                12 hasDeployedPool          19 _totalOutstandingFeeCreditClaims
    //   6 claimableFeeCredits        13 initialWeightOf          20 _totalOutstandingFeeTokenClaims

    /// @notice Storage slot of the hook's `oracleHook`.
    uint256 internal constant SLOT_ORACLE_HOOK = 14;

    /// @notice Storage slot of the hook's `askTokenIdOf` mapping.
    uint256 internal constant SLOT_ASK_TOKEN_ID_OF = 3;

    /// @notice Storage slot of the hook's `_inflightFeeRoutingCount` mapping.
    uint256 internal constant SLOT_INFLIGHT_FEE_ROUTING_COUNT = 18;

    /// @notice Storage slot of the hook's `_totalOutstandingFeeTokenClaims` mapping.
    uint256 internal constant SLOT_OUTSTANDING_FEE_TOKEN_CLAIMS = 20;

    address public owner;
    address public user;

    // Accept ETH
    receive() external payable {}

    function setUp() public virtual {
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Deploy mock tokens
        projectToken = new MockERC20("Project Token", "PROJ", 18);
        terminalToken = new MockERC20("Terminal Token", "TERM", 18);
        feeProjectToken = new MockERC20("Fee Project Token", "FEE", 18);

        // Deploy mock JB contracts
        directory = new MockJBDirectory();
        controller = new MockJBController();
        terminal = new MockJBMultiTerminal();
        jbTokens = new MockJBTokens();
        prices = new MockJBPrices();
        store = new MockJBTerminalStore();
        jbProjects = new MockJBProjects();
        permissions = new MockJBPermissions();

        // Deploy mock V4 contracts
        poolManager = new MockPoolManager();
        positionManager = new MockPositionManager();
        positionManager.setPoolManager(poolManager);

        // Wire JB contracts
        controller.setPrices(address(prices));
        controller.setTokens(address(jbTokens));
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT);
        controller.setFirstWeight(PROJECT_ID, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(PROJECT_ID, 1); // ETH

        // Set up fee project
        controller.setWeight(FEE_PROJECT_ID, 100e18);
        controller.setFirstWeight(FEE_PROJECT_ID, 100e18);

        // Wire directory
        directory.setProjects(address(jbProjects));
        _setDirectoryController(PROJECT_ID, address(controller));
        _setDirectoryController(FEE_PROJECT_ID, address(controller));
        _setDirectoryTerminal(PROJECT_ID, address(terminalToken), address(terminal));
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(terminal));

        // Wire project ownership
        jbProjects.setOwner(PROJECT_ID, owner);
        jbProjects.setOwner(FEE_PROJECT_ID, owner);

        // Wire terminal
        terminal.setStore(address(store));
        terminal.setProjectToken(PROJECT_ID, address(projectToken));
        terminal.setProjectToken(FEE_PROJECT_ID, address(feeProjectToken));

        // Set accounting context
        terminal.setAccountingContext(PROJECT_ID, address(terminalToken), uint32(uint160(address(terminalToken))), 18);
        terminal.addAccountingContext(
            PROJECT_ID,
            JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        );

        // Wire JB tokens
        jbTokens.setToken(PROJECT_ID, address(projectToken));
        jbTokens.setToken(FEE_PROJECT_ID, address(feeProjectToken));

        // Set surplus for cash out rate
        store.setSurplus(PROJECT_ID, DEFAULT_SURPLUS_PER_TOKEN);

        // Set a default terminal balance (needed for permissionless auto-select)
        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 10e18);

        // Add terminal to directory's terminal list
        _addDirectoryTerminal(PROJECT_ID, address(terminal));

        // Deploy mock Permit2 at canonical address (used by hook's _approveViaPermit2)
        address permit2Addr = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        vm.etch(permit2Addr, address(new MockPermit2()).code);

        // Deploy the chain-identical implementation, then clone + initialize. The clone's storage (project + chain
        // specific) is set atomically inside `initialize`.
        JBUniswapV4LPSplitHook hookImpl = new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(permit2Addr),
            IJBSuckerRegistry(address(0))
        );
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));

        // Wire a spot-tracking oracle so the hook's spot-vs-TWAP guard (on addLiquidity) passes
        // by default: it reports a TWAP equal to the pool's live spot tick. Tests that exercise TWAP deviation or an
        // un-warmed oracle override `oracleHook` (see `_overrideOracleHook`) with their own fixed-tick
        // MockGeomeanOracle.
        //
        // Etch it at a fixed address via deployCodeTo (NOT `new`): a fresh CREATE here would advance the deployment
        // nonce and shift every contract address that subclasses deploy after super.setUp(), flipping token0/token1
        // ordering in the pre-initialized-pool / frontrun tests. deployCodeTo consumes no nonce, keeping setUp neutral.
        address baseOracleAddr = address(uint160(uint256(keccak256("jb.univ4-lp-split.test.baseOracle"))));
        deployCodeTo("MockGeomeanOracle.sol", baseOracleAddr);
        baseOracleHook = MockGeomeanOracle(baseOracleAddr);
        baseOracleHook.enableSpotTracking(IPoolManager(address(poolManager)));

        hook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(baseOracleHook)),
            newBuybackHook: IJBBuybackHookRegistry(BUYBACK_REGISTRY)
        });
    }

    // ─── Hook Storage Helpers

    /// @notice Repoint the hook's `oracleHook` at a test-controlled oracle.
    /// @dev `initialize` is one-shot, so tests that need a fixed-tick or reverting oracle write the slot directly.
    /// @param newOracle The oracle to install as the hook's `oracleHook`.
    function _overrideOracleHook(address newOracle) internal {
        vm.store(address(hook), bytes32(SLOT_ORACLE_HOOK), bytes32(uint256(uint160(newOracle))));
    }

    /// @notice Give `projectId` a convex (40% cash-out tax) curve whose cash-out value per token sits far below the
    /// issuance price: a wide, non-inverted corridor.
    function _setWideTaxedCurve(uint256 projectId) internal {
        store.setTaxedCashOutCurve({projectId: projectId, surplus: 1e18, supply: 1_000_000e18, taxRate: 4000});
    }

    // ─── Directory Helpers (write to fallback-based mock) ───────────────

    function _setDirectoryController(uint256 projectId, address ctrl) internal {
        directory._controllers(projectId);
        bytes32 slot = keccak256(abi.encode(projectId, uint256(1)));
        vm.store(address(directory), slot, bytes32(uint256(uint160(ctrl))));
    }

    function _setDirectoryTerminal(uint256 projectId, address token, address term) internal {
        bytes32 innerSlot = keccak256(abi.encode(projectId, uint256(2)));
        bytes32 slot = keccak256(abi.encode(token, innerSlot));
        vm.store(address(directory), slot, bytes32(uint256(uint160(term))));
    }

    function _addDirectoryTerminal(uint256 projectId, address term) internal {
        bytes32 arraySlot = keccak256(abi.encode(projectId, uint256(3)));
        uint256 currentLen = uint256(vm.load(address(directory), arraySlot));
        vm.store(address(directory), arraySlot, bytes32(currentLen + 1));
        bytes32 elementSlot = bytes32(uint256(keccak256(abi.encode(arraySlot))) + currentLen);
        vm.store(address(directory), elementSlot, bytes32(uint256(uint160(term))));
    }

    // ─── Context Builder

    function _buildContext(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 groupId
    )
        internal
        view
        returns (JBSplitHookContext memory)
    {
        return JBSplitHookContext({
            token: token,
            amount: amount,
            decimals: 18,
            projectId: projectId,
            groupId: groupId,
            split: JBSplit({
                percent: 1_000_000,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(hook))
            })
        });
    }

    function _buildReservedContext(uint256 projectId, uint256 amount)
        internal
        view
        returns (JBSplitHookContext memory)
    {
        return _buildContext(projectId, address(projectToken), amount, 1);
    }

    // ─── Accumulation & Deployment Helpers

    /// @notice Gas cap that covers intake but sits below the hook's inline-automation attempt floor
    /// (`_AUTOMATION_GAS_BUDGET` + `_AUTOMATION_GAS_RESERVE`), so the accumulate helpers keep their
    /// accumulate-only semantics: intake completes and automation skips, exactly like a distribution that arrives
    /// without enough gas for inline automation. Tests that want inline automation call `processSplitWith` with full
    /// gas themselves (see DurableIntakeTest).
    uint256 internal constant INTAKE_ONLY_GAS = 300_000;

    function _accumulateTokens(uint256 projectId, uint256 amount) internal {
        // Mint to controller and approve the hook — processSplitWith pulls via transferFrom.
        projectToken.mint(address(controller), amount);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), amount);

        JBSplitHookContext memory context = _buildReservedContext(projectId, amount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();
    }

    function _accumulateAndDeploy(uint256 projectId, uint256 amount) internal {
        _accumulateTokens(projectId, amount);

        // Deploy pool as owner.
        // MockPositionManager automatically syncs Slot0 into MockPoolManager during
        // initializePool, so StateLibrary.getSlot0 works in _addUniswapLiquidity.
        vm.prank(owner);
        hook.deployPool(projectId);
    }

    // ─── V4 Liquidity Helpers
    // ───────────────────────────────────────────

    /// @notice The token0/token1 amounts `liquidity` over `[lower, upper]` spans at `sqrtPriceX96`.
    /// @dev Independent of the hook and the mock: the canonical V4 amount formulas. A mint pays them rounded up, a burn
    /// returns them rounded down.
    function _amountsForLiquidity(
        uint160 sqrtPriceX96,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        bool roundUp
    )
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        uint160 sqrtP = sqrtPriceX96 < sqrtA ? sqrtA : sqrtPriceX96 > sqrtB ? sqrtB : sqrtPriceX96;
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, roundUp);
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, roundUp);
    }

    /// @notice What minting `tokenId`'s liquidity over its range costs at its pool's live price.
    function _mintCostAtSpot(uint256 tokenId) internal view returns (uint256 amount0, uint256 amount1) {
        (PoolKey memory key, int24 lower, int24 upper, uint128 liquidity,,,) = positionManager._positions(tokenId);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), key.toId());
        return _amountsForLiquidity(sqrtPriceX96, lower, upper, liquidity, true);
    }

    /// @notice Other LPs hold all of V4's per-tick liquidity cap at both ends of `[lower, upper]` except `room`. The
    /// hook's own liquidity already there is left free on top, because a recycle burns it before minting. A mint over
    /// the range is then capped at `room` and the inventory it cannot place stays with the hook.
    function _limitTickRoom(PoolKey memory key, int24 lower, int24 upper, uint128 room) internal {
        uint128 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(key.tickSpacing);
        for (uint256 i; i < 2; i++) {
            int24 tick = i == 0 ? lower : upper;
            (uint128 held,) = StateLibrary.getTickLiquidity(IPoolManager(address(poolManager)), key.toId(), tick);
            positionManager.setTickLiquidityGross(key, tick, maxPerTick - room + held);
        }
    }

    /// @notice Dry-run the next deploy (or recycle) of `PROJECT_ID` to learn the ask it mints, undo it, then leave
    /// per-tick room for only `bps` of that ask's liquidity (see `_limitTickRoom`).
    /// @return room The liquidity the capped ask will hold.
    function _capNextAsk(bool deploy, uint256 bps) internal returns (uint128 room) {
        uint256 snapshot = vm.snapshotState();
        if (deploy) {
            vm.prank(owner);
            hook.deployPool(PROJECT_ID);
        } else {
            hook.addLiquidity(PROJECT_ID, address(terminalToken));
        }
        (PoolKey memory key, int24 lower, int24 upper, uint128 liquidity,,,) =
            positionManager._positions(hook.askTokenIdOf(PROJECT_ID, address(terminalToken)));
        vm.revertToState(snapshot);

        // forge-lint: disable-next-line(unsafe-typecast)
        room = uint128(uint256(liquidity) * bps / 10_000);
        _limitTickRoom(key, lower, upper, room);
    }

    /// @notice Write `key`'s spot price into the mock PoolManager's Slot0, as swaps moving the price would.
    function _writeSpot(PoolKey memory key, uint160 sqrtPriceX96) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 packed = bytes32((uint256(key.fee) << 208) | (uint256(uint24(tick)) << 160) | uint256(sqrtPriceX96));
        poolManager.writeSlot(stateSlot, packed);
    }

    /// @notice The principal of a live mock position at its own pool's live spot, rounded down (what a burn returns).
    function _principalAtSpot(uint256 tokenId) internal view returns (uint256 amount0, uint256 amount1) {
        (PoolKey memory key, int24 lower, int24 upper, uint128 liquidity,,,) = positionManager._positions(tokenId);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), key.toId());
        return _amountsForLiquidity(sqrtPriceX96, lower, upper, liquidity, false);
    }

    /// @notice Set the pool reserves the mock holds for `tokenId`, minting or removing the difference from the
    /// PositionManager so its balances keep backing exactly what it records.
    function _setPrincipal(uint256 tokenId, uint256 amount0, uint256 amount1) internal {
        (PoolKey memory key,,,, uint256 old0, uint256 old1,) = positionManager._positions(tokenId);
        _rebalance(key.currency0, old0, amount0);
        _rebalance(key.currency1, old1, amount1);
        positionManager.setPositionPrincipal(tokenId, amount0, amount1);
    }

    /// @notice Re-mark `tokenId`'s reserves to what its liquidity holds at the live spot, as if swaps had moved the
    /// price through it (the swappers' tokens enter the pool and the tokens they bought leave it).
    function _markToSpot(uint256 tokenId) internal {
        (uint256 amount0, uint256 amount1) = _principalAtSpot(tokenId);
        _setPrincipal(tokenId, amount0, amount1);
    }

    function _rebalance(Currency currency, uint256 oldAmount, uint256 newAmount) private {
        address pm = address(positionManager);
        if (currency.isAddressZero()) {
            vm.deal(pm, pm.balance + newAmount - oldAmount);
        } else if (newAmount > oldAmount) {
            MockERC20(Currency.unwrap(currency)).mint(pm, newAmount - oldAmount);
        } else if (oldAmount > newAmount) {
            MockERC20(Currency.unwrap(currency)).burn(pm, oldAmount - newAmount);
        }
    }

    /// @notice Buyers fill part of `tokenId`: the spot moves to the aligned middle of its range and the position is
    /// marked to it, so a burn recovers both currencies (the base oracle tracks spot, so the TWAP guard still passes).
    /// @return amount0 The token0 the position now holds.
    /// @return amount1 The token1 the position now holds.
    function _fillHalfOf(uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        (PoolKey memory key, int24 lower, int24 upper,,,,) = positionManager._positions(tokenId);
        _writeSpot(key, TickMath.getSqrtPriceAtTick((lower + upper) / 2 / key.tickSpacing * key.tickSpacing));
        _markToSpot(tokenId);
        (amount0, amount1) = _principalAtSpot(tokenId);
        require(amount0 > 0 && amount1 > 0, "fixture: the filled position holds both currencies");
    }

    /// @notice `projectId`'s live ask and bid each hold exactly what their liquidity costs at the live spot (the ask
    /// only project tokens, the bid only terminal tokens), and together with the hook's ledgers they account for
    /// exactly `projectIn` project and `terminalIn` terminal tokens. What stays ledgered is only V4 rounding: each
    /// position holds the most liquidity its inventory pays for. Every funded side must be live; a caller whose side
    /// is intentionally unmintable says so with the overload below.
    function _assertPlacedExactly(
        uint256 projectId,
        address projectTokenAddr,
        address terminalTokenAddr,
        uint256 projectIn,
        uint256 terminalIn
    )
        internal
        view
    {
        _assertPlacedExactly({
            projectId: projectId,
            projectTokenAddr: projectTokenAddr,
            terminalTokenAddr: terminalTokenAddr,
            projectIn: projectIn,
            terminalIn: terminalIn,
            askLive: projectIn != 0,
            bidLive: terminalIn != 0
        });
    }

    /// @notice `_assertPlacedExactly` with each side's expected liveness explicit: `askLive`/`bidLive` false asserts
    /// that side holds no position (its inventory, if any, stays ledgered whole).
    function _assertPlacedExactly(
        uint256 projectId,
        address projectTokenAddr,
        address terminalTokenAddr,
        uint256 projectIn,
        uint256 terminalIn,
        bool askLive,
        bool bidLive
    )
        internal
        view
    {
        uint256 askId = hook.askTokenIdOf(projectId, terminalTokenAddr);
        uint256 bidId = hook.bidTokenIdOf(projectId, terminalTokenAddr);
        if (askLive) assertNotEq(askId, 0, "the ask is live");
        else assertEq(askId, 0, "no ask");
        if (bidLive) assertNotEq(bidId, 0, "the bid is live");
        else assertEq(bidId, 0, "no bid");
        (uint256 askProject, uint256 askTerminal) = _costSidesOf(askId, projectTokenAddr);
        (uint256 bidProject, uint256 bidTerminal) = _costSidesOf(bidId, projectTokenAddr);
        assertEq(askTerminal, 0, "the ask holds no terminal");
        assertEq(bidProject, 0, "the bid holds no project token");
        assertEq(
            askProject + hook.accumulatedProjectTokens(projectId), projectIn, "the ask plus the ledger hold the project"
        );
        assertEq(
            bidTerminal + hook.accumulatedTerminalTokens(projectId, terminalTokenAddr),
            terminalIn,
            "the bid plus the ledger hold the terminal"
        );
        _assertMaximalLiquidity(askId, projectIn);
        _assertMaximalLiquidity(bidId, terminalIn);
    }

    /// @notice One more unit of `tokenId`'s liquidity would cost more than `available` at the live spot.
    function _assertMaximalLiquidity(uint256 tokenId, uint256 available) internal view {
        if (tokenId == 0) return;
        (PoolKey memory key, int24 lower, int24 upper, uint128 liquidity,,,) = positionManager._positions(tokenId);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), key.toId());
        (uint256 amount0, uint256 amount1) = _amountsForLiquidity(sqrtPriceX96, lower, upper, liquidity + 1, true);
        assertGt(amount0 + amount1, available, "only V4 rounding is left unplaced");
    }

    /// @notice A live position's (project, terminal) reserves, each asserted equal to its liquidity's cost at spot.
    function _costSidesOf(
        uint256 tokenId,
        address projectTokenAddr
    )
        internal
        view
        returns (uint256 projectSide, uint256 terminalSide)
    {
        if (tokenId == 0) return (0, 0);
        (PoolKey memory key,,,, uint256 locked0, uint256 locked1,) = positionManager._positions(tokenId);
        (uint256 cost0, uint256 cost1) = _mintCostAtSpot(tokenId);
        assertEq(locked0, cost0, "a position's token0 is exactly its liquidity's cost");
        assertEq(locked1, cost1, "a position's token1 is exactly its liquidity's cost");
        return Currency.unwrap(key.currency0) == projectTokenAddr ? (locked0, locked1) : (locked1, locked0);
    }

    /// @notice Every one of the `total` project tokens is in the pool's reserves or the hook's ledger, and each of
    /// them holds exactly what it records: nothing is stranded or leaked.
    function _assertPoolAndLedgerHold(uint256 total) internal view {
        uint256 ledger = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 pooled = projectToken.balanceOf(address(positionManager));
        assertEq(pooled, positionManager.poolLocked(address(projectToken)), "the PositionManager holds only reserves");
        assertEq(projectToken.balanceOf(address(hook)), ledger, "the hook holds exactly its ledger");
        assertEq(pooled + ledger, total, "the pool and the ledger hold every project token");
    }
}
