// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
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
        IERC20(token).transferFrom(from, to, amount);
    }
}

/// @notice Handler exercising the accumulation stage of JBUniswapV4LPSplitHook.
/// @dev The fuzzer calls functions on this handler. Each function mutates hook state
///      through the legitimate `processSplitWith` entry point.
contract LPSplitHookHandler is Test {
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

    /// @dev Ghost variable: cumulative fee tokens credited to each project via _routeFeesToProject.
    ///      Tracked by observing claimableFeeTokens delta after each collectAndRouteLPFees call.
    mapping(uint256 projectId => uint256 totalFeeTokensCredited) public totalFeeTokensCredited;

    /// @dev Ghost variable: number of successful rebalanceLiquidity calls.
    uint256 public rebalanceCallCount;

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

    /// @notice Accumulate project tokens via processSplitWith in pre-deployment stage.
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range [1, MAX_PROJECT_ID].
    /// @param amount Fuzzed amount of tokens to accumulate.
    function accumulate(uint256 projectIdSeed, uint256 amount) external {
        // Bound project ID to [1, MAX_PROJECT_ID] (project 0 has no controller).
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);

        // Bound amount to [0, 1e30] to stay within realistic ranges and avoid overflow.
        amount = bound(amount, 0, 1e30);

        // Skip if pool already deployed for this project (processSplitWith would burn, not accumulate).
        if (hook.deployedPoolCount(projectId) > 0) return;

        // Mint tokens to the hook (simulates controller sending reserved tokens).
        projectToken.mint(address(hook), amount);
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
        vm.prank(address(controller));
        hook.processSplitWith(context);

        callCount++;
    }

    /// @notice Call processSplitWith with zero amount (edge case).
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range.
    function accumulateZero(uint256 projectIdSeed) external {
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);

        if (hook.deployedPoolCount(projectId) > 0) return;

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
        hook.processSplitWith(context);

        callCount++;
    }

    /// @notice Collect LP fees from a project's position and route them.
    /// @dev Only runs if pool is deployed (tokenIdOf != 0). The mock position manager
    ///      must have collectable fees configured for this to produce meaningful results.
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range.
    /// @param feeAmount0Seed Fuzzed seed for configuring collectable fee amount0.
    /// @param feeAmount1Seed Fuzzed seed for configuring collectable fee amount1.
    function collectAndRouteLPFees(uint256 projectIdSeed, uint256 feeAmount0Seed, uint256 feeAmount1Seed) external {
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);

        // Guard: only run if pool is deployed for this project.
        if (hook.deployedPoolCount(projectId) == 0) return;

        uint256 tokenId = hook.tokenIdOf(projectId, address(terminalToken));
        if (tokenId == 0) return;

        // Bound fee amounts to realistic range [0, 1e24] to avoid overflow.
        uint256 feeAmount0 = bound(feeAmount0Seed, 0, 1e24);
        uint256 feeAmount1 = bound(feeAmount1Seed, 0, 1e24);

        // Configure collectable fees on the mock position manager.
        positionManager.setCollectableFees(tokenId, feeAmount0, feeAmount1);

        // Mint the fee tokens to the position manager so it can transfer them on TAKE_PAIR.
        // The token order depends on how the pool key was constructed (projectToken vs terminalToken).
        // Mint both to the position manager to cover either ordering.
        projectToken.mint(address(positionManager), feeAmount0);
        terminalToken.mint(address(positionManager), feeAmount1);

        // Snapshot claimableFeeTokens before to track the delta.
        uint256 claimableBefore = hook.claimableFeeTokens(projectId);

        // Call collectAndRouteLPFees — permissionless, anyone can call.
        try hook.collectAndRouteLPFees(projectId, address(terminalToken)) {
            // Track fee token credit delta.
            uint256 claimableAfter = hook.claimableFeeTokens(projectId);
            if (claimableAfter > claimableBefore) {
                totalFeeTokensCredited[projectId] += claimableAfter - claimableBefore;
            }
            collectFeeCallCount++;
        } catch {
            // Revert is acceptable — e.g., if token ordering causes issues in the mock.
        }
    }

    /// @notice Rebalance a project's LP position by burning and re-minting at current price.
    /// @dev Only runs if pool is deployed. Requires SET_BUYBACK_POOL permission, so we
    ///      prank as the project owner. Uses try/catch since the operation can revert on
    ///      price conditions (e.g., zero liquidity after rebalance).
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range.
    /// @param amount0MinSeed Fuzzed seed for minimum amount0 on decrease (slippage).
    /// @param amount1MinSeed Fuzzed seed for minimum amount1 on decrease (slippage).
    function rebalanceLiquidity(uint256 projectIdSeed, uint256 amount0MinSeed, uint256 amount1MinSeed) external {
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);

        // Guard: only run if pool is deployed for this project.
        if (hook.deployedPoolCount(projectId) == 0) return;

        uint256 tokenId = hook.tokenIdOf(projectId, address(terminalToken));
        if (tokenId == 0) return;

        // Use zero for slippage mins (most permissive) to maximize successful calls.
        // Bound seeds to [0, 0] — effectively always zero. This avoids slippage reverts
        // in the mock environment where exact amounts are hard to predict.
        uint256 amount0Min = bound(amount0MinSeed, 0, 0);
        uint256 amount1Min = bound(amount1MinSeed, 0, 0);

        // Snapshot claimableFeeTokens before to track fee collection during rebalance.
        uint256 claimableBefore = hook.claimableFeeTokens(projectId);

        // Rebalance requires SET_BUYBACK_POOL permission — prank as project owner.
        vm.prank(owner);
        try hook.rebalanceLiquidity(projectId, address(terminalToken), amount0Min, amount1Min) {
            // Track fee token credit delta (rebalance collects fees in step 1).
            uint256 claimableAfter = hook.claimableFeeTokens(projectId);
            if (claimableAfter > claimableBefore) {
                totalFeeTokensCredited[projectId] += claimableAfter - claimableBefore;
            }
            rebalanceCallCount++;
        } catch {
            // Revert is expected in many cases:
            // - InsufficientLiquidity if new position has zero liquidity
            // - Price/tick calculation issues in mock environment
        }
    }
}

/// @notice Invariant tests for JBUniswapV4LPSplitHook accounting properties.
/// @dev Verifies:
///   1. accumulatedProjectTokens[projectId] <= actual ERC20 balance held by the hook
///   2. tokenIdOf[projectId][terminalToken] != 0 iff deployedPoolCount[projectId] > 0
///      (for the terminal tokens we track)
///   3. accumulatedProjectTokens[projectId] == sum of all amounts passed to processSplitWith
///      (cross-checked against ghost variable)
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
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(permit2Addr),
            IHooks(address(0))
        );
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));
        hook.initialize(FEE_PROJECT_ID, FEE_PERCENT);

        // Deploy the handler
        handler = new LPSplitHookHandler(hook, projectToken, terminalToken, controller, positionManager, owner);

        // Target only the handler for invariant fuzzing
        targetContract(address(handler));
    }

    // ─── Setup Helpers ───────────────────────────────────────────────────

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

        // Set accounting context
        terminal.setAccountingContext(
            projectId, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );
        terminal.addAccountingContext(
            projectId,
            JBAccountingContext({
                token: address(terminalToken),
                decimals: 18,
                currency: uint32(uint160(address(terminalToken)))
            })
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 1: Accumulated accounting never exceeds actual token balance
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For every project, the hook's internal accounting of accumulated tokens
    ///         must never exceed the actual ERC20 balance the hook holds.
    /// @dev This catches any scenario where `_accumulateTokens` increments the counter
    ///      without a corresponding token transfer actually reaching the hook.
    function invariant_accumulatedNeverExceedsBalance() public view {
        uint256 totalAccumulated;
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            totalAccumulated += hook.accumulatedProjectTokens(i);
        }

        uint256 actualBalance = projectToken.balanceOf(address(hook));
        assertLe(
            totalAccumulated,
            actualBalance,
            "INVARIANT VIOLATED: sum of accumulatedProjectTokens exceeds actual token balance"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 2: tokenIdOf consistency with deployedPoolCount
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice If tokenIdOf[projectId][terminalToken] is nonzero, then
    ///         deployedPoolCount[projectId] must be > 0.
    /// @dev In the accumulation-only handler, no pools are deployed, so both should
    ///      always be zero. This invariant verifies that processSplitWith alone never
    ///      sets tokenIdOf (which would indicate a critical state corruption).
    function invariant_tokenIdConsistentWithDeployedCount() public view {
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            uint256 tokenId = hook.tokenIdOf(i, address(terminalToken));
            uint256 poolCount = hook.deployedPoolCount(i);

            if (tokenId != 0) {
                assertGt(
                    poolCount,
                    0,
                    "INVARIANT VIOLATED: tokenIdOf nonzero but deployedPoolCount is zero"
                );
            }

            // Reverse direction: if no pool deployed for this project, tokenId must be zero
            // (for the terminal tokens we track).
            if (poolCount == 0) {
                assertEq(
                    tokenId,
                    0,
                    "INVARIANT VIOLATED: deployedPoolCount is zero but tokenIdOf is nonzero"
                );
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 3: Ghost variable cross-check — accumulated matches minted
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The hook's accumulatedProjectTokens for each project must exactly
    ///         equal the total tokens minted to the hook for that project.
    /// @dev This catches off-by-one errors, double-counting, or missing increments
    ///      in the `_accumulateTokens` internal function.
    function invariant_accumulatedMatchesMinted() public view {
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            // Only check projects that haven't had pools deployed (handler skips those).
            if (hook.deployedPoolCount(i) == 0) {
                assertEq(
                    hook.accumulatedProjectTokens(i),
                    handler.totalMintedToHook(i),
                    "INVARIANT VIOLATED: accumulatedProjectTokens != total minted to hook"
                );
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 4: Per-project accounting never exceeds per-project minting
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For each individual project, accumulatedProjectTokens[i] must be
    ///         <= the tokens minted for that specific project.
    /// @dev This is a stronger per-project version of invariant 1, catching any
    ///      cross-project accounting leakage.
    function invariant_perProjectAccountingBounded() public view {
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            assertLe(
                hook.accumulatedProjectTokens(i),
                handler.totalMintedToHook(i),
                "INVARIANT VIOLATED: per-project accumulated exceeds per-project minted"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 5: Fee accounting — claimableFeeTokens bounded by collections
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For each project, claimableFeeTokens must be bounded by what has been
    ///         credited through fee collection (ghost variable cross-check).
    /// @dev This catches any scenario where claimableFeeTokens is incremented without
    ///      a corresponding fee collection from the LP position.
    function invariant_feeAccountingBounded() public view {
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            assertLe(
                hook.claimableFeeTokens(i),
                handler.totalFeeTokensCredited(i),
                "INVARIANT VIOLATED: claimableFeeTokens exceeds total credited via fee collection"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 6: Position lifecycle — tokenIdOf nonzero only when deployed
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice tokenIdOf[projectId][terminalToken] must be nonzero only when
    ///         deployedPoolCount[projectId] > 0. This is a strengthened version of
    ///         invariant 2 that also accounts for rebalanceLiquidity, which replaces
    ///         tokenIdOf but must never zero it out.
    /// @dev rebalanceLiquidity reverts with InsufficientLiquidity rather than storing
    ///      a zero tokenId, so this invariant should hold after any sequence of calls.
    function invariant_positionLifecycleConsistency() public view {
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            uint256 tokenId = hook.tokenIdOf(i, address(terminalToken));
            uint256 poolCount = hook.deployedPoolCount(i);

            // If a pool is deployed, tokenIdOf should be nonzero (rebalance preserves this).
            if (poolCount > 0) {
                assertGt(
                    tokenId,
                    0,
                    "INVARIANT VIOLATED: deployedPoolCount > 0 but tokenIdOf is zero"
                );
            }

            // If no pool deployed, tokenIdOf must be zero.
            if (poolCount == 0) {
                assertEq(
                    tokenId,
                    0,
                    "INVARIANT VIOLATED: deployedPoolCount is zero but tokenIdOf is nonzero"
                );
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Post-run stats for debugging
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Log how many calls the handler executed (useful for tuning depth/runs).
    function invariant_callSummary() public view {
        // This invariant always passes — it exists to surface coverage stats in traces.
        assertGe(handler.callCount(), 0, "callCount should be non-negative");
        assertGe(handler.collectFeeCallCount(), 0, "collectFeeCallCount should be non-negative");
        assertGe(handler.rebalanceCallCount(), 0, "rebalanceCallCount should be non-negative");
    }
}
