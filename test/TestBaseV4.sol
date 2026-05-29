// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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

/// @notice Minimal mock so the hook can call PERMIT2.approve() in unit tests.
contract MockPermit2 {
    mapping(address owner => mapping(address token => mapping(address spender => uint256))) public allowances;
    mapping(address owner => mapping(address token => mapping(address spender => uint48))) public expirations;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowances[msg.sender][token][spender] = amount;
        expirations[msg.sender][token][spender] = expiration;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        allowances[from][token][msg.sender] -= amount;
        // Test mock: return value not checked intentionally.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token).transferFrom(from, to, amount);
    }
}

/// @notice Shared test harness for JBUniswapV4LPSplitHook tests
contract LPSplitHookV4TestBase is Test {
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
    /// (it tracks the base `poolManager`) so the spot-vs-TWAP guard on addLiquidity/rebalanceLiquidity passes.
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
    /// @notice Stand-in buyback-hook registry the hook holds as `BUYBACK_HOOK` (force-direct cash-out target).
    address public constant BUYBACK_REGISTRY = address(0xB0B);

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
        store.setSurplus(PROJECT_ID, 0.5e18);

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
            IJBSuckerRegistry(address(0)),
            BUYBACK_REGISTRY
        );
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));

        // Wire a spot-tracking oracle so the hook's spot-vs-TWAP guard (on addLiquidity AND rebalanceLiquidity) passes
        // by default: it reports a TWAP equal to the pool's live spot tick. Tests that exercise TWAP deviation or an
        // un-warmed oracle override `oracleHook` (slot 0) with their own fixed-tick MockGeomeanOracle.
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
            newOracleHook: IHooks(address(baseOracleHook))
        });
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

    function _accumulateTokens(uint256 projectId, uint256 amount) internal {
        // Mint to controller and approve the hook — processSplitWith pulls via transferFrom.
        projectToken.mint(address(controller), amount);
        vm.startPrank(address(controller));
        projectToken.approve(address(hook), amount);

        JBSplitHookContext memory context = _buildReservedContext(projectId, amount);
        hook.processSplitWith(context);
        vm.stopPrank();
    }

    function _accumulateAndDeploy(uint256 projectId, uint256 amount) internal {
        _accumulateTokens(projectId, amount);

        // Deploy pool as owner.
        // MockPositionManager automatically syncs Slot0 into MockPoolManager during
        // initializePool, so StateLibrary.getSlot0 works in _addUniswapLiquidity.
        vm.prank(owner);
        hook.deployPool(projectId, 0);
    }
}
