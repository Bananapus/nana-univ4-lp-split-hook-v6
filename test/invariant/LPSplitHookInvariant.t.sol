// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockGeomeanOracle} from "../mock/MockGeomeanOracle.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {MockPositionManager} from "../mock/MockPositionManager.sol";
import {MockPoolManager} from "../mock/MockPoolManager.sol";
import {
    MockJBDirectory,
    MockJBController,
    MockJBMultiTerminal,
    MockJBTokens,
    MockJBPrices,
    MockJBTerminalStore,
    MockJBProjects,
    MockJBPermissions
} from "../mock/MockJBContracts.sol";

/// @notice Minimal mock so the hook can call PERMIT2.approve() in invariant tests.
contract InvariantMockPermit2 {
    mapping(address owner => mapping(address token => mapping(address spender => uint256))) public allowances;

    function approve(address token, address spender, uint160 amount, uint48) external {
        allowances[msg.sender][token][spender] = amount;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        allowances[from][token][msg.sender] -= amount;
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token).transferFrom(from, to, amount);
    }
}

/// @notice Handler exercising the accumulation, deploy, fee-collection and recycle stages of JBUniswapV4LPSplitHook.
/// @dev The fuzzer calls functions on this handler. Each function mutates hook state through a legitimate entry point.
contract LPSplitHookHandler is Test {
    /// @notice Gas cap that covers intake but sits below the hook's inline-automation attempt floor, keeping the
    /// handler's accumulate actions accumulate-only (automation skips, exactly like a distribution arriving without
    /// enough gas for it), so the invariants keep exercising the explicit deploy/add paths.
    uint256 internal constant INTAKE_ONLY_GAS = 300_000;

    JBUniswapV4LPSplitHook public hook;
    MockERC20 public projectToken;
    MockERC20 public terminalToken;
    MockJBController public controller;
    MockPositionManager public positionManager;
    address public owner;

    /// @dev Project IDs the handler exercises. Using a small set (1-3) keeps the
    ///      invariant checker tractable while covering multi-project interactions.
    uint256 public constant MAX_PROJECT_ID = 3;

    /// @dev Tracks cumulative tokens minted to the hook per project so we can
    ///      independently verify the accounting invariant.
    mapping(uint256 projectId => uint256 totalMinted) public totalMintedToHook;

    /// @dev Ghost variable: number of successful processSplitWith calls.
    uint256 public callCount;

    /// @dev Ghost variable: number of successful collectAndRouteLPFees calls.
    uint256 public collectFeeCallCount;

    /// @dev The fee percent the hook is initialized with, and its basis.
    uint256 public constant FEE_PERCENT = 3800;
    uint256 public constant BPS = 10_000;

    /// @dev Ghost variable: fee-project claims each project must hold, derived ONLY from the fees the handler injected:
    ///      every collected terminal-side fee pays a cut of `fee * FEE_PERCENT / BPS` to the fee project's terminal,
    ///      whose mock `pay` mints the beneficiary 1:1. The project-side cut is always forgiven (the fee project has no
    ///      terminal for the project token here). Never read back from the hook's own claim ledger.
    mapping(uint256 projectId => uint256 amount) public expectedClaims;

    /// @dev Ghost variable: expected claims from injected fees not yet collected (moved into `expectedClaims` by the
    ///      next successful collection or recycle of the project, which collects every live position).
    mapping(uint256 projectId => uint256 amount) public pendingExpectedClaims;

    /// @dev Ghost variable: gross project-token / terminal-token LP fees injected into each project's positions.
    mapping(uint256 projectId => uint256 amount) public projectFeesInjected;
    mapping(uint256 projectId => uint256 amount) public terminalFeesInjected;

    /// @dev Ghost variable: number of successful deployPool calls.
    uint256 public deployCallCount;

    /// @dev Ghost variable: number of successful addLiquidity (recycle) calls.
    uint256 public recycleCallCount;

    constructor(
        JBUniswapV4LPSplitHook _hook,
        MockERC20 _projectToken,
        MockERC20 _terminalToken,
        MockJBController _controller,
        MockPositionManager _positionManager,
        address _owner
    ) {
        hook = _hook;
        projectToken = _projectToken;
        terminalToken = _terminalToken;
        controller = _controller;
        positionManager = _positionManager;
        owner = _owner;
    }

    /// @notice Accumulate project tokens via processSplitWith (before or after deployment; the hook never burns).
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range [1, MAX_PROJECT_ID].
    /// @param amount Fuzzed amount of tokens to accumulate.
    function accumulate(uint256 projectIdSeed, uint256 amount) external {
        // Bound project ID to [1, MAX_PROJECT_ID] (project 0 has no controller).
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);

        // Bound amount to [0, 1e30] to stay within realistic ranges and avoid overflow.
        amount = bound(amount, 0, 1e30);

        // Mint tokens to the controller and approve the hook.
        projectToken.mint(address(controller), amount);
        totalMintedToHook[projectId] += amount;

        // Build the split hook context.
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(projectToken),
            amount: amount,
            decimals: 18,
            projectId: projectId,
            groupId: 1,
            split: JBSplit({
                percent: 1_000_000,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(hook))
            })
        });

        // Call processSplitWith as the controller (the authorized caller).
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), amount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();

        callCount++;
    }

    /// @notice Call processSplitWith with zero amount (edge case).
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range.
    function accumulateZero(uint256 projectIdSeed) external {
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);

        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(projectToken),
            amount: 0,
            decimals: 18,
            projectId: projectId,
            groupId: 1,
            split: JBSplit({
                percent: 1_000_000,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(hook))
            })
        });

        vm.prank(address(controller));
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);

        callCount++;
    }

    /// @notice Deploy a project's pool from its accumulated tokens. Permissionless.
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range.
    function deployPool(uint256 projectIdSeed) external {
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);
        if (hook.hasDeployedPool(projectId)) return;

        try hook.deployPool(projectId) {
            deployCallCount++;
        } catch {
            // Revert is acceptable — e.g. nothing accumulated yet, or no deployable liquidity at spot.
        }
    }

    /// @notice Inject distinct collectable LP fees into a project's live ask AND bid (each position skipped while it
    /// still holds uncollected fees, so the ghosts stay exact per position).
    function injectFees(
        uint256 projectIdSeed,
        uint256 askFee0Seed,
        uint256 askFee1Seed,
        uint256 bidFee0Seed,
        uint256 bidFee1Seed
    )
        external
    {
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);
        _injectFee(projectId, hook.askTokenIdOf(projectId, address(terminalToken)), askFee0Seed, askFee1Seed);
        _injectFee(projectId, hook.bidTokenIdOf(projectId, address(terminalToken)), bidFee0Seed, bidFee1Seed);
    }

    function _injectFee(uint256 projectId, uint256 tokenId, uint256 fee0Seed, uint256 fee1Seed) internal {
        if (tokenId == 0) return;
        if (positionManager.collectableAmount0(tokenId) != 0 || positionManager.collectableAmount1(tokenId) != 0) {
            return;
        }
        // Bound fee amounts to realistic range [0, 1e24] to avoid overflow.
        uint256 fee0 = bound(fee0Seed, 0, 1e24);
        uint256 fee1 = bound(fee1Seed, 0, 1e24);
        positionManager.setCollectableFees(tokenId, fee0, fee1);

        // Fund the position manager in each pool currency so it can pay the fees on TAKE_PAIR.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        (uint256 projectFee, uint256 terminalFee) = projectIsToken0 ? (fee0, fee1) : (fee1, fee0);
        projectToken.mint(address(positionManager), projectFee);
        terminalToken.mint(address(positionManager), terminalFee);
        projectFeesInjected[projectId] += projectFee;
        terminalFeesInjected[projectId] += terminalFee;
        pendingExpectedClaims[projectId] += (terminalFee * FEE_PERCENT) / BPS;
    }

    /// @notice A successful collection or recycle collected every live position's injected fees.
    function _settleCollectedFees(uint256 projectId) internal {
        expectedClaims[projectId] += pendingExpectedClaims[projectId];
        pendingExpectedClaims[projectId] = 0;
    }

    /// @notice Collect LP fees from a project's live ask and bid and route them. Permissionless.
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range.
    // forge-lint: disable-next-line(mixed-case-function)
    function collectAndRouteLPFees(uint256 projectIdSeed) external {
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);
        if (hook.askTokenIdOf(projectId, address(terminalToken)) == 0) {
            if (hook.bidTokenIdOf(projectId, address(terminalToken)) == 0) return;
        }

        try hook.collectAndRouteLPFees(projectId, address(terminalToken)) {
            _settleCollectedFees(projectId);
            collectFeeCallCount++;
        } catch {
            // Revert is acceptable here; the injected fees stay collectable for a later call.
        }
    }

    /// @notice Recycle a project's positions (collect fees, burn ask and bid, re-mint both single-sided).
    /// @dev Permissionless. Uses try/catch since the recycle can revert (e.g. NoDeployableLiquidityAtSpot).
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range.
    function addLiquidity(uint256 projectIdSeed) external {
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);
        if (!hook.hasDeployedPool(projectId)) return;

        try hook.addLiquidity(projectId, address(terminalToken)) {
            // The recycle collected both positions' fees before burning them.
            _settleCollectedFees(projectId);
            recycleCallCount++;
        } catch {
            // Revert is expected in some cases, e.g. NoDeployableLiquidityAtSpot or a TWAP deviation.
        }
    }
}

/// @notice Invariant tests for JBUniswapV4LPSplitHook accounting properties.
/// @dev Verifies:
///   1. the project-token ledgers plus claimable fee tokens never exceed the hook's actual ERC20 balance
///   2. a project has a live ask or bid iff hasDeployedPool[projectId] is true
///   3. accumulatedProjectTokens[projectId] == sum of all amounts passed to processSplitWith before deployment
///      (cross-checked against ghost variable)
///   4. each project's ledgers plus its positions' principal never exceed what entered its books
///   5. claimableFeeTokens equals the claims derived independently from the injected fees (cut and payout)
///   6. at most two positions per project are alive, and every live position is a tracked ask or bid
///   7. every campaign includes a successful deploy, fee collection and recycle (seeded in setUp)
contract LPSplitHookInvariantTest is StdInvariant, Test {
    JBUniswapV4LPSplitHook public hook;
    LPSplitHookHandler public handler;

    // Mock infrastructure
    MockJBDirectory public directory;
    MockJBController public controller;
    MockJBMultiTerminal public terminal;
    MockJBTokens public jbTokens;
    MockJBPrices public prices;
    MockJBTerminalStore public store;
    MockPositionManager public positionManager;
    MockPoolManager public poolManager;
    MockJBProjects public jbProjects;
    MockJBPermissions public permissions;

    MockERC20 public projectToken;
    MockERC20 public terminalToken;
    MockERC20 public feeProjectToken;

    uint256 public constant FEE_PROJECT_ID = 10;
    uint256 public constant FEE_PERCENT = 3800;
    uint256 public constant DEFAULT_WEIGHT = 1000e18;

    address public owner;

    function setUp() public {
        owner = makeAddr("owner");

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

        // Wire JB infrastructure for project IDs 1-3 and fee project
        controller.setPrices(address(prices));
        directory.setProjects(address(jbProjects));

        // Set up fee project
        _setupProject(FEE_PROJECT_ID);
        controller.setWeight(FEE_PROJECT_ID, 100e18);
        controller.setFirstWeight(FEE_PROJECT_ID, 100e18);

        // Set up test projects 1-3
        for (uint256 i = 1; i <= 3; i++) {
            _setupProject(i);
            controller.setWeight(i, DEFAULT_WEIGHT);
            controller.setFirstWeight(i, DEFAULT_WEIGHT);
            controller.setReservedPercent(i, 1000); // 10%
            controller.setBaseCurrency(i, 1); // ETH
        }

        // Deploy mock Permit2 at canonical address
        address permit2Addr = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        vm.etch(permit2Addr, address(new InvariantMockPermit2()).code);

        // Deploy the hook (implementation + clone + initialize)
        JBUniswapV4LPSplitHook hookImpl = new JBUniswapV4LPSplitHook(
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            IAllowanceTransfer(permit2Addr),
            IJBSuckerRegistry(address(0))
        );
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));

        // Spot-tracking oracle so the spot-vs-TWAP guard on addLiquidity (exercised by the handler) passes.
        // Etched (no CREATE) so it doesn't shift this setUp's deployment nonces / token ordering.
        address invOracleAddr = address(uint160(uint256(keccak256("jb.univ4-lp-split.invariant.oracle"))));
        deployCodeTo("MockGeomeanOracle.sol", invOracleAddr);
        MockGeomeanOracle invOracle = MockGeomeanOracle(invOracleAddr);
        invOracle.enableSpotTracking(IPoolManager(address(poolManager)));

        hook.initialize({
            initialFeeProjectId: FEE_PROJECT_ID,
            initialFeePercent: FEE_PERCENT,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(invOracle)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });

        // Deploy the handler
        handler = new LPSplitHookHandler(hook, projectToken, terminalToken, controller, positionManager, owner);

        // Seed one successful deploy, fee collection and recycle so every campaign starts from real activity (and a
        // live ask plus bid), and so the activity invariant can require it.
        _seedActivity();

        // Target only the handler for invariant fuzzing
        targetContract(address(handler));
    }

    /// @notice Project 1: accumulate, deploy, inject fees on the ask, collect them (the terminal remainder funds the
    /// bid ledger), and recycle into a live ask and bid.
    function _seedActivity() internal {
        handler.accumulate(1, 10e18);
        handler.deployPool(1);
        assertEq(handler.deployCallCount(), 1, "seed: deploy must succeed");
        handler.injectFees(1, 3e18, 5e18, 0, 0);
        handler.collectAndRouteLPFees(1);
        assertEq(handler.collectFeeCallCount(), 1, "seed: fee collection must succeed");
        handler.addLiquidity(1);
        assertEq(handler.recycleCallCount(), 1, "seed: recycle must succeed");
        assertNotEq(hook.askTokenIdOf(1, address(terminalToken)), 0, "seed: ask live");
        assertNotEq(hook.bidTokenIdOf(1, address(terminalToken)), 0, "seed: bid live");
    }

    // ─── Setup Helpers
    // ───────────────────────────────────────────────────

    function _setupProject(uint256 projectId) internal {
        // Set directory controller via vm.store (fallback-based mock)
        bytes32 slot = keccak256(abi.encode(projectId, uint256(1)));
        vm.store(address(directory), slot, bytes32(uint256(uint160(address(controller)))));

        // Set directory terminal for terminalToken
        bytes32 innerSlot = keccak256(abi.encode(projectId, uint256(2)));
        bytes32 termSlot = keccak256(abi.encode(address(terminalToken), innerSlot));
        vm.store(address(directory), termSlot, bytes32(uint256(uint160(address(terminal)))));

        // Add terminal to directory's terminal list
        bytes32 arraySlot = keccak256(abi.encode(projectId, uint256(3)));
        uint256 currentLen = uint256(vm.load(address(directory), arraySlot));
        vm.store(address(directory), arraySlot, bytes32(currentLen + 1));
        bytes32 elementSlot = bytes32(uint256(keccak256(abi.encode(arraySlot))) + currentLen);
        vm.store(address(directory), elementSlot, bytes32(uint256(uint160(address(terminal)))));

        // Wire project ownership
        jbProjects.setOwner(projectId, owner);

        // Wire terminal
        terminal.setStore(address(store));
        terminal.setProjectToken(projectId, address(projectToken));

        // Wire JB tokens
        jbTokens.setToken(projectId, address(projectToken));

        // Set surplus for cash out rate
        store.setSurplus(projectId, 0.5e18);
        // Give the project a terminal balance so `deployPool` can select its terminal token.
        store.setBalance(address(terminal), projectId, address(terminalToken), 10e18);

        // Set accounting context
        terminal.setAccountingContext(projectId, address(terminalToken), uint32(uint160(address(terminalToken))), 18);
        terminal.addAccountingContext(
            projectId,
            JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Deterministic: fees on BOTH live positions, collected standalone and by a recycle
    // ═══════════════════════════════════════════════════════════════════════

    function _sides(uint256 tokenId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        (,,,, uint256 locked0, uint256 locked1,) = positionManager._positions(tokenId);
        (projectSide, terminalSide) =
            address(projectToken) < address(terminalToken) ? (locked0, locked1) : (locked1, locked0);
    }

    function _cut(uint256 amount) internal pure returns (uint256) {
        return (amount * FEE_PERCENT) / 10_000;
    }

    /// @notice Distinct fees on the live ask and bid are each cut exactly (terminal side paid, project side forgiven)
    ///         by a standalone collection that leaves both positions' principal untouched; a second round of distinct
    ///         fees is then collected by a recycle with zero new accumulation, which folds every remainder and both
    ///         positions' principal into the fresh ask and bid. Claims stay exactly backed throughout.
    function test_bothPositionsFees_collectThenRecycleWithoutNewTokens() public {
        uint256 askId = hook.askTokenIdOf(1, address(terminalToken));
        uint256 bidId = hook.bidTokenIdOf(1, address(terminalToken));
        (uint256 askProject, uint256 askTerminal) = _sides(askId);
        (uint256 bidProject, uint256 bidTerminal) = _sides(bidId);
        assertGt(askProject, 0, "precondition: the ask holds project principal");
        assertGt(bidTerminal, 0, "precondition: the bid holds terminal principal");
        uint256 projectLedger = hook.accumulatedProjectTokens(1);
        uint256 terminalLedger = hook.accumulatedTerminalTokens(1, address(terminalToken));
        uint256 claims = hook.claimableFeeTokens(1);

        // Round 1: distinct fees on both ids, collected standalone.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        uint256[4] memory fees = [uint256(1.1e18), 2.3e18, 0.7e18, 4.9e18]; // ask project, ask terminal, bid ...
        handler.injectFees(
            1,
            projectIsToken0 ? fees[0] : fees[1],
            projectIsToken0 ? fees[1] : fees[0],
            projectIsToken0 ? fees[2] : fees[3],
            projectIsToken0 ? fees[3] : fees[2]
        );
        uint256 payCalls = terminal.payCallCount();
        handler.collectAndRouteLPFees(1);
        assertEq(handler.collectFeeCallCount(), 2, "standalone collection succeeded");

        assertEq(terminal.payCallCount(), payCalls + 2, "one terminal-side cut paid per position");
        uint256 cuts = _cut(fees[1]) + _cut(fees[3]);
        assertEq(hook.claimableFeeTokens(1), claims + cuts, "claims equal the two terminal-side cuts");
        assertEq(hook.accumulatedProjectTokens(1), projectLedger + fees[0] + fees[2], "project fees forgiven in full");
        assertEq(
            hook.accumulatedTerminalTokens(1, address(terminalToken)),
            terminalLedger + fees[1] + fees[3] - cuts,
            "terminal remainders ledgered"
        );
        assertEq(hook.askTokenIdOf(1, address(terminalToken)), askId, "collection keeps the ask");
        assertEq(hook.bidTokenIdOf(1, address(terminalToken)), bidId, "collection keeps the bid");
        (uint256 p, uint256 t) = _sides(askId);
        assertEq(p + t, askProject + askTerminal, "ask principal untouched");
        (p, t) = _sides(bidId);
        assertEq(p + t, bidProject + bidTerminal, "bid principal untouched");

        // Round 2: new distinct fees, collected by a recycle with no new reserved tokens.
        uint256[4] memory fees2 = [uint256(0.3e18), 1.9e18, 2.2e18, 0.6e18];
        handler.injectFees(
            1,
            projectIsToken0 ? fees2[0] : fees2[1],
            projectIsToken0 ? fees2[1] : fees2[0],
            projectIsToken0 ? fees2[2] : fees2[3],
            projectIsToken0 ? fees2[3] : fees2[2]
        );
        uint256 accumulatedBefore = hook.accumulatedProjectTokens(1);
        uint256 terminalBefore = hook.accumulatedTerminalTokens(1, address(terminalToken));
        uint256 cuts2 = _cut(fees2[1]) + _cut(fees2[3]);
        handler.addLiquidity(1);
        assertEq(handler.recycleCallCount(), 2, "the zero-accumulation recycle succeeded");

        assertEq(hook.claimableFeeTokens(1), claims + cuts + cuts2, "the recycle cut both positions' fees exactly");
        uint256 newAsk = hook.askTokenIdOf(1, address(terminalToken));
        uint256 newBid = hook.bidTokenIdOf(1, address(terminalToken));
        assertTrue(newAsk != askId && newAsk != bidId && newAsk != 0, "fresh ask");
        assertTrue(newBid != askId && newBid != bidId && newBid != 0 && newBid != newAsk, "fresh bid");
        (uint256 newAskProject, uint256 newAskTerminal) = _sides(newAsk);
        (uint256 newBidProject, uint256 newBidTerminal) = _sides(newBid);
        assertEq(newAskTerminal, 0, "the ask holds no terminal");
        assertEq(newBidProject, 0, "the bid holds no project token");
        assertEq(
            newAskProject + hook.accumulatedProjectTokens(1),
            askProject + bidProject + accumulatedBefore + fees2[0] + fees2[2],
            "every project token (principal + ledger + forgiven fees) is in the ask or its ledger"
        );
        assertEq(
            newBidTerminal + hook.accumulatedTerminalTokens(1, address(terminalToken)),
            askTerminal + bidTerminal + terminalBefore + fees2[1] + fees2[3] - cuts2,
            "every terminal token (principal + ledger + fee remainders) is in the bid or its ledger"
        );

        // Claim backing and segregation: the hook holds exactly its ledgers plus the fee-token claims.
        uint256 projectBooks;
        uint256 terminalBooks;
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            projectBooks += hook.accumulatedProjectTokens(i) + hook.claimableFeeTokens(i);
            terminalBooks += hook.accumulatedTerminalTokens(i, address(terminalToken));
        }
        assertEq(projectToken.balanceOf(address(hook)), projectBooks, "project ledgers plus claims exactly backed");
        assertEq(terminalToken.balanceOf(address(hook)), terminalBooks, "terminal ledgers exactly backed");
        assertEq(handler.expectedClaims(1), hook.claimableFeeTokens(1), "handler ghost agrees");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 1: Accumulated accounting never exceeds actual token balance
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For every project, the hook's internal accounting of accumulated tokens (plus the fee tokens it holds
    ///         for claims, which share the project token here) must never exceed the actual ERC20 balances it holds.
    /// @dev This catches any scenario where `_accumulateTokens` increments the counter
    ///      without a corresponding token transfer actually reaching the hook.
    function invariant_accumulatedNeverExceedsBalance() public view {
        uint256 totalAccumulated;
        uint256 totalTerminalAccumulated;
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            totalAccumulated += hook.accumulatedProjectTokens(i) + hook.claimableFeeTokens(i);
            totalTerminalAccumulated += hook.accumulatedTerminalTokens(i, address(terminalToken));
        }

        assertLe(
            totalAccumulated,
            projectToken.balanceOf(address(hook)),
            "INVARIANT VIOLATED: sum of accumulatedProjectTokens exceeds actual token balance"
        );
        assertLe(
            totalTerminalAccumulated,
            terminalToken.balanceOf(address(hook)),
            "INVARIANT VIOLATED: sum of accumulatedTerminalTokens exceeds actual token balance"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 2: position-id consistency with hasDeployedPool
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice If a project's ask or bid id is nonzero, then hasDeployedPool[projectId] must be true.
    /// @dev Verifies that processSplitWith alone never sets a position id (which would indicate a critical state
    ///      corruption).
    function invariant_tokenIdConsistentWithDeployedCount() public view {
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            uint256 tokenId =
                hook.askTokenIdOf(i, address(terminalToken)) | hook.bidTokenIdOf(i, address(terminalToken));
            bool poolDeployed = hook.hasDeployedPool(i);

            if (tokenId != 0) {
                assertTrue(poolDeployed, "INVARIANT VIOLATED: position id nonzero but hasDeployedPool is false");
            }

            // Reverse direction: if no pool deployed for this project, tokenId must be zero
            // (for the terminal tokens we track).
            if (!poolDeployed) {
                assertEq(tokenId, 0, "INVARIANT VIOLATED: hasDeployedPool is false but a position id is nonzero");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 3: Ghost variable cross-check — accumulated matches minted
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Before deployment, the hook's accumulatedProjectTokens for each project must exactly
    ///         equal the total tokens minted to the hook for that project.
    /// @dev This catches off-by-one errors, double-counting, or missing increments
    ///      in the `_accumulateTokens` internal function.
    function invariant_accumulatedMatchesMinted() public view {
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            // Only check projects that haven't had pools deployed (handler skips those).
            if (!hook.hasDeployedPool(i)) {
                assertEq(
                    hook.accumulatedProjectTokens(i),
                    handler.totalMintedToHook(i),
                    "INVARIANT VIOLATED: accumulatedProjectTokens != total minted to hook"
                );
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 4: Per-project books never exceed what entered them
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For each individual project, its ledgers plus the principal locked in its live ask and bid must be
    ///         <= the reserved tokens minted for it plus the gross LP fees injected into its positions.
    /// @dev A per-project version of invariant 1 that follows tokens through deploy and recycle, catching any
    ///      cross-project leakage or value creation (recycled principal is credited back exactly once).
    function invariant_perProjectAccountingBounded() public view {
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            uint256 projectBooks = hook.accumulatedProjectTokens(i);
            uint256 terminalBooks = hook.accumulatedTerminalTokens(i, address(terminalToken));
            uint256[2] memory ids =
                [hook.askTokenIdOf(i, address(terminalToken)), hook.bidTokenIdOf(i, address(terminalToken))];
            for (uint256 j; j < 2; j++) {
                (,,,, uint256 locked0, uint256 locked1,) = positionManager._positions(ids[j]);
                projectBooks += projectIsToken0 ? locked0 : locked1;
                terminalBooks += projectIsToken0 ? locked1 : locked0;
            }
            assertLe(
                projectBooks,
                handler.totalMintedToHook(i) + handler.projectFeesInjected(i),
                "INVARIANT VIOLATED: per-project project-token books exceed what entered them"
            );
            // Every expected claim was minted 1:1 for a terminal-side cut that left the project's books.
            assertLe(
                terminalBooks,
                handler.terminalFeesInjected(i) - handler.expectedClaims(i),
                "INVARIANT VIOLATED: per-project terminal-token books exceed fees injected net of paid cuts"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 5: Fee accounting — claimableFeeTokens equals the derived claims
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For each project, claimableFeeTokens must equal the claims derived independently from the injected
    ///         fees: `terminalFee * FEE_PERCENT / BPS` per collected terminal-side fee, minted 1:1 by the mock fee
    ///         terminal, and nothing for the (forgiven) project side.
    /// @dev Catches over- and under-crediting during collection, and any claim credited without a collected fee.
    function invariant_feeClaimsMatchInjectedFees() public view {
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            assertEq(
                hook.claimableFeeTokens(i),
                handler.expectedClaims(i),
                "INVARIANT VIOLATED: claimableFeeTokens differs from the claims the collected fees justify"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 6: At most two live positions per project, no orphaned NFTs
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Every live position NFT is exactly one project's tracked ask or bid: a deployed project has one or two
    ///         live positions, recycles burn the ids they replace, and no NFT is ever left orphaned.
    /// @dev A recycle reverts (`NoDeployableLiquidityAtSpot`) rather than storing two zero ids, so a deployed project
    ///      always keeps at least one live position.
    function invariant_positionLifecycleConsistency() public view {
        uint256 trackedLive;
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            uint256 askId = hook.askTokenIdOf(i, address(terminalToken));
            uint256 bidId = hook.bidTokenIdOf(i, address(terminalToken));

            if (hook.hasDeployedPool(i)) {
                assertTrue(askId != 0 || bidId != 0, "INVARIANT VIOLATED: deployed project holds no position");
            } else {
                assertEq(askId | bidId, 0, "INVARIANT VIOLATED: hasDeployedPool is false but a position id is set");
            }
            if (askId != 0) {
                assertNotEq(askId, bidId, "INVARIANT VIOLATED: ask and bid share an id");
                (,,,,,, bool askExists) = positionManager._positions(askId);
                assertTrue(askExists, "INVARIANT VIOLATED: tracked ask is not alive");
                trackedLive++;
            }
            if (bidId != 0) {
                (,,,,,, bool bidExists) = positionManager._positions(bidId);
                assertTrue(bidExists, "INVARIANT VIOLATED: tracked bid is not alive");
                trackedLive++;
            }
        }

        // Every position the PositionManager still holds must be one of the tracked ids (old ids burned).
        uint256 live;
        for (uint256 id = 1; id < positionManager.nextTokenId(); id++) {
            (,,,,,, bool exists) = positionManager._positions(id);
            if (exists) live++;
        }
        assertEq(live, trackedLive, "INVARIANT VIOLATED: orphaned position NFT (replaced id not burned)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 7: Real successful activity
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Every campaign has real successful activity: the seeded deploy, collection and recycle (handler
    ///         counters only count calls that did not revert), so the other invariants never pass vacuously.
    function invariant_successfulActivity() public view {
        assertGt(handler.callCount(), 0, "no successful accumulation");
        assertGt(handler.collectFeeCallCount(), 0, "no successful fee collection");
        assertGt(handler.deployCallCount(), 0, "no successful deploy");
        assertGt(handler.recycleCallCount(), 0, "no successful recycle");
    }
}
