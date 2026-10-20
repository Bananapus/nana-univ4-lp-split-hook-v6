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
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockGeomeanOracle} from "../mock/MockGeomeanOracle.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {DEFAULT_SURPLUS_PER_TOKEN} from "../TestBaseV4.sol";
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
    using PoolIdLibrary for PoolKey;

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

    /// @dev Ghost variable: gross LP fees injected into each project's live positions and not yet collected.
    mapping(uint256 projectId => uint256 amount) public uncollectedFees;

    /// @dev Ghost: what V4's rounding left in the pool when a recycle burned the project's positions (each burn returns
    /// its principal at the spot rounded down, below the rounded-up cost the pool holds), by side.
    mapping(uint256 projectId => uint256 amount) public projectBurnRounding;
    mapping(uint256 projectId => uint256 amount) public terminalBurnRounding;

    /// @dev Ghost variables: successful collections / recycles that collected a nonzero injected fee.
    uint256 public feeCollectionCount;
    uint256 public feeRecycleCount;

    /// @dev Failure latch: every caught revert a handler cannot justify under a checked precondition is counted here
    /// (with its revert data), and `invariant_noUnexpectedFailures` fails the campaign on the first one.
    uint256 public unexpectedFailures;
    bytes public lastUnexpectedFailure;

    /// @dev Below this many accumulated tokens a fresh single-sided ask may round to zero liquidity.
    uint256 public constant DUST = 1e6;

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
        // Intake from the authorized controller never reverts.
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), amount);
        try hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context) {
            totalMintedToHook[projectId] += amount;
            callCount++;
        } catch (bytes memory reason) {
            _latch(reason);
        }
        vm.stopPrank();
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
        try hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context) {
            callCount++;
        } catch (bytes memory reason) {
            _latch(reason);
        }
    }

    /// @notice Deploy a project's pool from its accumulated tokens. Permissionless.
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range.
    function deployPool(uint256 projectIdSeed) external {
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);
        if (hook.hasDeployedPool(projectId)) return;

        uint256 accumulated = hook.accumulatedProjectTokens(projectId);
        try hook.deployPool(projectId) {
            deployCallCount++;
        } catch (bytes memory reason) {
            // Justified only when nothing is accumulated, or when a dust accumulation rounds to zero liquidity (the
            // corridor and spot never move in this campaign, so nothing else can make a deploy fail).
            bytes4 selector = _selectorOf(reason);
            if (
                accumulated == 0
                    && selector == JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoTokensAccumulated.selector
            ) {
                return;
            }
            if (
                accumulated < DUST
                    && selector == JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector
            ) {
                return;
            }
            _latch(reason);
        }
    }

    function _latch(bytes memory reason) internal {
        unexpectedFailures++;
        lastUnexpectedFailure = reason;
    }

    function _selectorOf(bytes memory reason) internal pure returns (bytes4 selector) {
        // Keeping only the leading 4-byte selector is the point.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (reason.length >= 4) selector = bytes4(reason);
    }

    /// @notice A deployed project chosen by `seed` (project 1 is always deployed by the seed activity).
    function _deployedProject(uint256 seed) internal view returns (uint256) {
        uint256[MAX_PROJECT_ID] memory deployed;
        uint256 count;
        for (uint256 i = 1; i <= MAX_PROJECT_ID; i++) {
            if (hook.hasDeployedPool(i)) deployed[count++] = i;
        }
        return deployed[seed % count];
    }

    /// @notice Give every live position of `projectId` that holds no uncollected fee a distinct nonzero fee on both
    /// sides, derived from `seed`.
    function _injectNonzeroFees(uint256 projectId, uint256 seed) internal {
        uint256[2] memory ids = [
            hook.askTokenIdOf(projectId, address(terminalToken)), hook.bidTokenIdOf(projectId, address(terminalToken))
        ];
        for (uint256 j; j < 2; j++) {
            _injectFee({
                projectId: projectId,
                tokenId: ids[j],
                fee0Seed: uint256(keccak256(abi.encode(seed, j, 0))),
                fee1Seed: uint256(keccak256(abi.encode(seed, j, 1))),
                minFee: 1
            });
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
        _injectFee(projectId, hook.askTokenIdOf(projectId, address(terminalToken)), askFee0Seed, askFee1Seed, 0);
        _injectFee(projectId, hook.bidTokenIdOf(projectId, address(terminalToken)), bidFee0Seed, bidFee1Seed, 0);
    }

    function _injectFee(
        uint256 projectId,
        uint256 tokenId,
        uint256 fee0Seed,
        uint256 fee1Seed,
        uint256 minFee
    )
        internal
    {
        if (tokenId == 0) return;
        if (positionManager.collectableAmount0(tokenId) != 0 || positionManager.collectableAmount1(tokenId) != 0) {
            return;
        }
        // Bound fee amounts to realistic range [minFee, 1e24] to avoid overflow.
        uint256 fee0 = bound(fee0Seed, minFee, 1e24);
        uint256 fee1 = bound(fee1Seed, minFee, 1e24);
        positionManager.setCollectableFees(tokenId, fee0, fee1);

        // Fund the position manager in each pool currency so it can pay the fees on TAKE_PAIR.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        (uint256 projectFee, uint256 terminalFee) = projectIsToken0 ? (fee0, fee1) : (fee1, fee0);
        projectToken.mint(address(positionManager), projectFee);
        terminalToken.mint(address(positionManager), terminalFee);
        projectFeesInjected[projectId] += projectFee;
        terminalFeesInjected[projectId] += terminalFee;
        pendingExpectedClaims[projectId] += (terminalFee * FEE_PERCENT) / BPS;
        uncollectedFees[projectId] += projectFee + terminalFee;
    }

    /// @notice What burning `projectId`'s live ask and bid leaves in the pool, by side: each position's reserves minus
    /// the principal V4 returns for its liquidity at the live spot (rounded down).
    function _burnRounding(uint256 projectId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        uint256[2] memory ids = [
            hook.askTokenIdOf(projectId, address(terminalToken)), hook.bidTokenIdOf(projectId, address(terminalToken))
        ];
        for (uint256 j; j < 2; j++) {
            if (ids[j] == 0) continue;
            (PoolKey memory key, int24 lower, int24 upper, uint128 liquidity, uint256 locked0, uint256 locked1,) =
                positionManager._positions(ids[j]);
            (uint160 sqrtP,,,) = StateLibrary.getSlot0(IPoolManager(address(positionManager.poolManager())), key.toId());
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
            sqrtP = sqrtP < sqrtA ? sqrtA : sqrtP > sqrtB ? sqrtB : sqrtP;
            uint256 rounding0 = locked0 - SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, false);
            uint256 rounding1 = locked1 - SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, false);
            projectSide += projectIsToken0 ? rounding0 : rounding1;
            terminalSide += projectIsToken0 ? rounding1 : rounding0;
        }
    }

    /// @notice A successful collection or recycle collected every live position's injected fees.
    /// @return collectedFees Whether a nonzero injected fee was collected.
    function _settleCollectedFees(uint256 projectId) internal returns (bool collectedFees) {
        collectedFees = uncollectedFees[projectId] != 0;
        uncollectedFees[projectId] = 0;
        expectedClaims[projectId] += pendingExpectedClaims[projectId];
        pendingExpectedClaims[projectId] = 0;
    }

    /// @notice Collect LP fees from a deployed project's live ask and bid and route them. Permissionless.
    /// @dev Every live position without uncollected fees first gets a nonzero fee, so each collection moves real
    /// fees. A deployed project always holds a live position and the PositionManager is funded for every injected
    /// fee, so no revert is justified.
    /// @param projectIdSeed Fuzzed seed, reduced to a deployed project.
    /// @param feeSeed Fuzzed seed for the injected fees.
    // forge-lint: disable-next-line(mixed-case-function)
    function collectAndRouteLPFees(uint256 projectIdSeed, uint256 feeSeed) external {
        uint256 projectId = _deployedProject(projectIdSeed);
        _injectNonzeroFees(projectId, feeSeed);

        try hook.collectAndRouteLPFees(projectId, address(terminalToken)) {
            if (_settleCollectedFees(projectId)) feeCollectionCount++;
            collectFeeCallCount++;
        } catch (bytes memory reason) {
            _latch(reason);
        }
    }

    /// @notice Recycle a deployed project's positions (collect fees, burn ask and bid, re-mint both single-sided).
    /// @dev Permissionless. Every live position without uncollected fees first gets a nonzero fee. The spot, TWAP and
    /// corridor never move in this campaign and the retired principal can always be re-minted, so no revert is
    /// justified.
    /// @param projectIdSeed Fuzzed seed, reduced to a deployed project.
    /// @param feeSeed Fuzzed seed for the injected fees.
    function addLiquidity(uint256 projectIdSeed, uint256 feeSeed) external {
        uint256 projectId = _deployedProject(projectIdSeed);
        _injectNonzeroFees(projectId, feeSeed);
        (uint256 projectRounding, uint256 terminalRounding) = _burnRounding(projectId);

        try hook.addLiquidity(projectId, address(terminalToken)) {
            // The recycle collected both positions' fees before burning them.
            if (_settleCollectedFees(projectId)) feeRecycleCount++;
            recycleCallCount++;
            projectBurnRounding[projectId] += projectRounding;
            terminalBurnRounding[projectId] += terminalRounding;
        } catch (bytes memory reason) {
            _latch(reason);
        }
    }
}

/// @notice Invariant tests for JBUniswapV4LPSplitHook accounting properties.
/// @dev Verifies:
///   1. exact global backing per currency (no donations in this campaign): the hook holds exactly its ledgers plus
///      claimable fee tokens, the PositionManager exactly the live principal plus uncollected fees, and the fee
///      terminal exactly the independently computed cuts
///   2. a project has a live ask or bid iff hasDeployedPool[projectId] is true
///   3. accumulatedProjectTokens[projectId] == sum of all amounts passed to processSplitWith before deployment
///      (cross-checked against ghost variable)
///   4. exact per-project conservation per currency: ledgers plus live principal plus uncollected fees equal what
///      entered the project's books, net of the independently computed cuts
///   5. claimableFeeTokens equals the claims derived independently from the injected fees (cut and payout)
///   6. at most two positions per project are alive, and every live position is a tracked ask or bid
///   7. every campaign includes a successful deploy, fee collection and recycle (seeded in setUp), no handler call
///      fails without a justified error under a checked precondition, and every run ends with post-seed
///      collections and recycles of nonzero fees
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

    /// @dev Fee-moving collections and recycles performed by the seed activity.
    uint256 public seedFeeCollections;
    uint256 public seedFeeRecycles;

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
        handler.collectAndRouteLPFees(1, 0);
        assertEq(handler.collectFeeCallCount(), 1, "seed: fee collection must succeed");
        handler.addLiquidity(1, 0);
        assertEq(handler.recycleCallCount(), 1, "seed: recycle must succeed");
        seedFeeCollections = handler.feeCollectionCount();
        seedFeeRecycles = handler.feeRecycleCount();
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

        // Set surplus for a cash-out rate below the issuance price (a non-inverted corridor).
        store.setSurplus(projectId, DEFAULT_SURPLUS_PER_TOKEN);
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
        handler.collectAndRouteLPFees(1, 0);
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
        uint256 projectRoundingBefore = handler.projectBurnRounding(1);
        uint256 terminalRoundingBefore = handler.terminalBurnRounding(1);
        handler.addLiquidity(1, 0);
        assertEq(handler.recycleCallCount(), 2, "the zero-accumulation recycle succeeded");
        // The burns return the principal less V4's rounding, which stays in the pool.
        uint256 projectRounding = handler.projectBurnRounding(1) - projectRoundingBefore;
        uint256 terminalRounding = handler.terminalBurnRounding(1) - terminalRoundingBefore;

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
            askProject + bidProject - projectRounding + accumulatedBefore + fees2[0] + fees2[2],
            "every project token (principal + ledger + forgiven fees) is in the ask or its ledger"
        );
        assertEq(
            newBidTerminal + hook.accumulatedTerminalTokens(1, address(terminalToken)),
            askTerminal + bidTerminal - terminalRounding + terminalBefore + fees2[1] + fees2[3] - cuts2,
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
    // Invariant 1: Exact global backing per currency
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The live principal and uncollected fees of every position the PositionManager holds, by side.
    function _positionManagerBooks() internal view returns (uint256 projectSide, uint256 terminalSide) {
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        for (uint256 id = 1; id < positionManager.nextTokenId(); id++) {
            (,,,, uint256 locked0, uint256 locked1, bool exists) = positionManager._positions(id);
            if (!exists) continue;
            uint256 amount0 = locked0 + positionManager.collectableAmount0(id);
            uint256 amount1 = locked1 + positionManager.collectableAmount1(id);
            projectSide += projectIsToken0 ? amount0 : amount1;
            terminalSide += projectIsToken0 ? amount1 : amount0;
        }
    }

    /// @notice Nothing is donated in this campaign, so every balance is exactly its books: the hook holds its ledgers
    ///         plus the fee tokens it owes (which share the project token here), the PositionManager holds the live
    ///         principal plus uncollected fees plus the rounding past burns left in the pool, and the fee terminal
    ///         holds exactly the independently computed cuts.
    /// @dev Catches tokens credited without arriving, ledgers erased while their tokens strand, and cuts that are
    ///      over- or under-paid.
    function invariant_exactGlobalBacking() public view {
        uint256 hookProjectBooks;
        uint256 hookTerminalBooks;
        uint256 cuts;
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            hookProjectBooks += hook.accumulatedProjectTokens(i) + hook.claimableFeeTokens(i);
            hookTerminalBooks += hook.accumulatedTerminalTokens(i, address(terminalToken));
            cuts += handler.expectedClaims(i);
        }
        (uint256 pmProjectBooks, uint256 pmTerminalBooks) = _positionManagerBooks();
        // Burns leave V4's rounding in the pool.
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            pmProjectBooks += handler.projectBurnRounding(i);
            pmTerminalBooks += handler.terminalBurnRounding(i);
        }

        assertEq(projectToken.balanceOf(address(hook)), hookProjectBooks, "INVARIANT VIOLATED: hook project backing");
        assertEq(terminalToken.balanceOf(address(hook)), hookTerminalBooks, "INVARIANT VIOLATED: hook terminal backing");
        assertEq(
            projectToken.balanceOf(address(positionManager)),
            pmProjectBooks,
            "INVARIANT VIOLATED: PositionManager project backing"
        );
        assertEq(
            terminalToken.balanceOf(address(positionManager)),
            pmTerminalBooks,
            "INVARIANT VIOLATED: PositionManager terminal backing"
        );
        assertEq(terminalToken.balanceOf(address(terminal)), cuts, "INVARIANT VIOLATED: fee terminal holds the cuts");
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
    // Invariant 4: Exact per-project conservation per currency
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For each project, its ledgers plus the principal and uncollected fees of its live ask and bid equal
    ///         exactly what entered its books: every reserved token minted for it plus every project-side fee
    ///         injected (the project-side cut is forgiven), and every terminal-side fee injected minus the cuts
    ///         computed independently from the collected fees.
    /// @dev Follows tokens through deploy, collection and recycle, catching any loss, cross-project leakage or value
    ///      creation (recycled principal is credited back exactly once).
    function invariant_exactPerProjectConservation() public view {
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            uint256 projectBooks = hook.accumulatedProjectTokens(i);
            uint256 terminalBooks = hook.accumulatedTerminalTokens(i, address(terminalToken));
            uint256[2] memory ids =
                [hook.askTokenIdOf(i, address(terminalToken)), hook.bidTokenIdOf(i, address(terminalToken))];
            for (uint256 j; j < 2; j++) {
                if (ids[j] == 0) continue;
                (,,,, uint256 locked0, uint256 locked1,) = positionManager._positions(ids[j]);
                uint256 amount0 = locked0 + positionManager.collectableAmount0(ids[j]);
                uint256 amount1 = locked1 + positionManager.collectableAmount1(ids[j]);
                projectBooks += projectIsToken0 ? amount0 : amount1;
                terminalBooks += projectIsToken0 ? amount1 : amount0;
            }
            // What a project's burns left in the pool as V4 rounding is still its tokens, just no longer withdrawable.
            projectBooks += handler.projectBurnRounding(i);
            terminalBooks += handler.terminalBurnRounding(i);
            assertEq(
                projectBooks,
                handler.totalMintedToHook(i) + handler.projectFeesInjected(i),
                "INVARIANT VIOLATED: per-project project-token books differ from what entered them"
            );
            assertEq(
                terminalBooks,
                handler.terminalFeesInjected(i) - handler.expectedClaims(i),
                "INVARIANT VIOLATED: per-project terminal-token books differ from fees injected net of paid cuts"
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
    ///      always keeps at least one live position. (Only an empty corridor retires both into the ledgers; the
    ///      economics never change in this campaign.)
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

    /// @notice No handler call failed without a justified error under a checked precondition.
    function invariant_noUnexpectedFailures() public view {
        assertEq(handler.unexpectedFailures(), 0, vm.toString(handler.lastUnexpectedFailure()));
    }

    /// @notice Each run, beyond the seed, collects and recycles real (nonzero) injected fees successfully.
    function afterInvariant() public view {
        assertGt(handler.feeCollectionCount(), seedFeeCollections, "no post-seed collection of nonzero fees");
        assertGt(handler.feeRecycleCount(), seedFeeRecycles, "no post-seed recycle of nonzero fees");
    }
}
