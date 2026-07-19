// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice A terminal stand-in whose `pay` always reverts, used to prove the fee-project cut is best-effort: a
/// reverting fee terminal forgives the cut (collection still succeeds) instead of blocking it.
contract RevertingPayTerminal {
    error PayReverted();

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        revert PayReverted();
    }

    receive() external payable {}
}

/// @notice Tests for the symmetric, best-effort fee-project cut and the terminal-token bid-leg ledger.
/// @dev The cut is attempted on BOTH the terminal-token side and the project-token side; every non-cut fee token is
/// routed into the originating project's protocol-owned liquidity (project → `accumulatedProjectTokens`,
/// terminal → `accumulatedTerminalTokens`). The mint never reads the hook's raw balance for sizing.
contract FeeSymmetricTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Slots from `forge inspect ... storage-layout`.
    uint256 internal constant _SLOT_INFLIGHT_COUNT = 19;
    uint256 internal constant _SLOT_OUTSTANDING_TOKEN_CLAIMS = 21;

    uint256 internal constant PROJECT_B = 7;
    MockERC20 internal projectTokenB;

    address internal constant NATIVE = address(0x000000000000000000000000000000000000EEEe);

    bool internal terminalTokenIsToken0;

    function setUp() public override {
        super.setUp();
        terminalTokenIsToken0 = address(terminalToken) < address(projectToken);
    }

    // ─── Helpers
    // ───────────────────────────────────────────────────────────

    function _deployA() internal returns (uint256 tokenId) {
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
    }

    function _corridorA() internal view returns (int24 floorTick, int24 ceilingTick) {
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(PROJECT_ID);
        (floorTick, ceilingTick) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(directory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: PROJECT_ID,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });
    }

    function _poolKeyA() internal view returns (PoolKey memory key) {
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
    }

    /// @dev Deploy A's asks-only position (small project ask leg) into a pool PRE-INITIALIZED at mid-corridor, so the
    /// live spot sits above the cash-out floor and a later mint has room to seed a comparable terminal bid leg below
    /// spot. Uses a realistic taxed cash-out curve so the corridor is well-formed.
    function _deployAAtMid(uint256 projectAmount) internal returns (uint256 tokenId) {
        store.setTaxedCashOutCurve({projectId: PROJECT_ID, surplus: 100e18, supply: 2e18, taxRate: 4000});
        (int24 floorTick, int24 ceilingTick) = _corridorA();
        positionManager.initializePool(
            _poolKeyA(), TickMath.getSqrtPriceAtTick(floorTick + (ceilingTick - floorTick) / 2)
        );
        _accumulateTokens(PROJECT_ID, projectAmount);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
    }

    /// @dev Sets the terminal-token side of a pool's collectable fees, ordering-aware against `projectTok` (which pool
    /// the position belongs to determines token0/token1).
    function _setTerminalFeesFor(uint256 tokenId, address projectTok, uint256 amount) internal {
        if (address(terminalToken) < projectTok) {
            positionManager.setCollectableFees(tokenId, amount, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, amount);
        }
        terminalToken.mint(address(positionManager), amount);
    }

    function _setTerminalFees(uint256 tokenId, uint256 amount) internal {
        _setTerminalFeesFor(tokenId, address(projectToken), amount);
    }

    function _setProjectFees(uint256 tokenId, uint256 amount) internal {
        if (address(terminalToken) < address(projectToken)) {
            positionManager.setCollectableFees(tokenId, 0, amount);
        } else {
            positionManager.setCollectableFees(tokenId, amount, 0);
        }
        projectToken.mint(address(positionManager), amount);
    }

    function _lockedSides(uint256 tokenId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        (,,,, uint256 amount0Locked, uint256 amount1Locked,) = positionManager._positions(tokenId);
        (projectSide, terminalSide) =
            terminalTokenIsToken0 ? (amount1Locked, amount0Locked) : (amount0Locked, amount1Locked);
    }

    function _outstandingTokenClaims(address token) internal view returns (uint256) {
        return uint256(vm.load(address(hook), keccak256(abi.encode(token, _SLOT_OUTSTANDING_TOKEN_CLAIMS))));
    }

    function _inflightCount(address token) internal view returns (uint256) {
        return uint256(vm.load(address(hook), keccak256(abi.encode(token, _SLOT_INFLIGHT_COUNT))));
    }

    function _setupProjectB() internal {
        projectTokenB = new MockERC20("Project B", "PROJB", 18);
        controller.setWeight(PROJECT_B, DEFAULT_WEIGHT);
        controller.setFirstWeight(PROJECT_B, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(PROJECT_B, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(PROJECT_B, 1);
        _setDirectoryController(PROJECT_B, address(controller));
        _setDirectoryTerminal(PROJECT_B, address(terminalToken), address(terminal));
        jbProjects.setOwner(PROJECT_B, owner);
        terminal.setProjectToken(PROJECT_B, address(projectTokenB));
        terminal.setAccountingContext(PROJECT_B, address(terminalToken), uint32(uint160(address(terminalToken))), 18);
        terminal.addAccountingContext(
            PROJECT_B,
            JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        );
        jbTokens.setToken(PROJECT_B, address(projectTokenB));
        store.setSurplus(PROJECT_B, 0.5e18);
        store.setBalance(address(terminal), PROJECT_B, address(terminalToken), 10e18);
        _addDirectoryTerminal(PROJECT_B, address(terminal));
    }

    function _accumulateAndDeployB(uint256 amount) internal returns (uint256 tokenId) {
        projectTokenB.mint(address(controller), amount);
        vm.startPrank(address(controller));
        projectTokenB.approve(address(hook), amount);
        hook.processSplitWith(_buildContext(PROJECT_B, address(projectTokenB), amount, 1));
        vm.stopPrank();
        vm.prank(owner);
        hook.deployPool(PROJECT_B);
        tokenId = hook.tokenIdOf(PROJECT_B, address(terminalToken));
    }

    // ─── Project-token side
    // ─────────────────────────────────────────────────

    /// @notice When the fee project has a terminal accepting the PROJECT token, the project-token side takes a cut and
    /// only the remainder is carried into the accumulation ledger.
    function test_ProjectSide_CutPaid_RemainderAccumulates() public {
        uint256 tokenId = _deployA();
        // Give the fee project a terminal that accepts the project token.
        _setDirectoryTerminal(FEE_PROJECT_ID, address(projectToken), address(terminal));

        uint256 projFee = 500e18;
        _setProjectFees(tokenId, projFee);

        uint256 accBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 claimBefore = hook.claimableFeeTokens(PROJECT_ID);
        uint256 payBefore = terminal.payCallCount();

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 cut = (projFee * FEE_PERCENT) / 10_000;
        assertGt(terminal.payCallCount(), payBefore, "project-token cut must be paid");
        assertEq(terminal.lastPayProjectId(), FEE_PROJECT_ID, "cut routed to fee project");
        assertEq(terminal.lastPayAmount(), cut, "cut is feePercent of the project fee");
        assertEq(hook.claimableFeeTokens(PROJECT_ID) - claimBefore, cut, "cut tracked as claimable fee tokens");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID) - accBefore, projFee - cut, "only the remainder accumulates");
    }

    /// @notice When the fee project has NO terminal for the project token, the whole project-token fee is forgiven and
    /// carried into the accumulation ledger.
    function test_ProjectSide_Forgiven_FullAmountAccumulates() public {
        uint256 tokenId = _deployA();

        uint256 projFee = 500e18;
        _setProjectFees(tokenId, projFee);

        uint256 accBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 payBefore = terminal.payCallCount();

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertEq(terminal.payCallCount(), payBefore, "no cut without a project-token fee terminal");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID) - accBefore, projFee, "full project fee accumulates");
    }

    // ─── Terminal-token side
    // ────────────────────────────────────────────────

    /// @notice The non-cut terminal remainder is routed into the per-project terminal ledger, NOT deposited into the
    /// project's treasury via `addToBalanceOf`.
    function test_TerminalSide_RemainderToLedger_NotTreasury() public {
        uint256 tokenId = _deployA();

        uint256 termFee = 1000e18;
        _setTerminalFees(tokenId, termFee);

        uint256 addBefore = terminal.addToBalanceCallCount();
        uint256 ledgerBefore = hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken));

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 cut = (termFee * FEE_PERCENT) / 10_000;
        assertEq(terminal.addToBalanceCallCount(), addBefore, "terminal remainder no longer deposited to treasury");
        assertEq(
            hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)) - ledgerBefore,
            termFee - cut,
            "terminal remainder routed into the bid-leg ledger"
        );
    }

    /// @notice A forgiven terminal cut routes the whole terminal fee into the ledger, and a subsequent mint consumes
    /// that ledger into the position's bid leg.
    function test_TerminalSide_Forgiven_FundsBidOnNextMint() public {
        uint256 tokenId = _deployAAtMid(0.5e18);
        // Forgive the terminal cut by removing the fee project's terminal for the terminal token.
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(0));

        uint256 termFee = 1e18;
        _setTerminalFees(tokenId, termFee);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertEq(
            hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)),
            termFee,
            "forgiven terminal fee fully ledgered"
        );

        _accumulateTokens(PROJECT_ID, 0.5e18);

        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        assertLt(
            hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)),
            termFee,
            "the terminal ledger is drawn down into the mint"
        );
        (, uint256 terminalSide) = _lockedSides(hook.tokenIdOf(PROJECT_ID, address(terminalToken)));
        assertGt(terminalSide, 0, "the bid leg is funded from the terminal ledger");
    }

    // ─── Best-effort (try/catch)
    // ─────────────────────────────────────────────

    /// @notice A fee terminal whose `pay` reverts forgives the terminal cut: collection succeeds, the whole fee lands
    /// in the ledger, no claim is tracked, and the reentrancy reserve counters are fully rolled back.
    function test_TryCatch_TerminalPayReverts_CutForgiven() public {
        uint256 tokenId = _deployA();
        RevertingPayTerminal rt = new RevertingPayTerminal();
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(rt));

        uint256 termFee = 10e18;
        _setTerminalFees(tokenId, termFee);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertEq(
            hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)),
            termFee,
            "forgiven cut routes the whole terminal fee into the ledger"
        );
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "no claim tracked when the cut is forgiven");
        assertEq(_outstandingTokenClaims(address(feeProjectToken)), 0, "outstanding token claims fully rolled back");
        assertEq(_inflightCount(address(feeProjectToken)), 0, "inflight routing count fully rolled back");
    }

    /// @notice A reverting fee terminal on the PROJECT-token side is likewise forgiven: the whole project fee is
    /// carried into the accumulation ledger and reserve counters are rolled back.
    function test_TryCatch_ProjectPayReverts_CutForgiven() public {
        uint256 tokenId = _deployA();
        RevertingPayTerminal rt = new RevertingPayTerminal();
        _setDirectoryTerminal(FEE_PROJECT_ID, address(projectToken), address(rt));

        uint256 projFee = 400e18;
        _setProjectFees(tokenId, projFee);

        uint256 accBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID) - accBefore, projFee, "forgiven project cut accumulates in full"
        );
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "no claim tracked when the project cut is forgiven");
        assertEq(_outstandingTokenClaims(address(feeProjectToken)), 0, "outstanding token claims fully rolled back");
        assertEq(_inflightCount(address(feeProjectToken)), 0, "inflight routing count fully rolled back");
    }

    // ─── Native ETH terminal
    // ─────────────────────────────────────────────────

    /// @dev Deploy a native-ETH-terminal pool for PROJECT_ID (native auto-selected as the highest-value terminal).
    function _deployNativePool() internal returns (uint256 tokenId) {
        _setDirectoryTerminal(PROJECT_ID, NATIVE, address(terminal));
        _addDirectoryTerminal(PROJECT_ID, address(terminal));
        terminal.setAccountingContext(PROJECT_ID, NATIVE, uint32(uint160(NATIVE)), 18);
        terminal.addAccountingContext(
            PROJECT_ID, JBAccountingContext({token: NATIVE, decimals: 18, currency: uint32(uint160(NATIVE))})
        );
        store.setBalance(address(terminal), PROJECT_ID, NATIVE, 100e18);
        vm.deal(address(terminal), 100 ether);

        _accumulateTokens(PROJECT_ID, 100e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        tokenId = hook.tokenIdOf(PROJECT_ID, NATIVE);
    }

    /// @notice A PAID native-terminal cut is forwarded with msg.value and the non-cut remainder is carried into the
    /// native bid-leg ledger `accumulatedTerminalTokens[project][NATIVE]`.
    function test_Native_CutPaidWithValue_RemainderLedgered() public {
        uint256 tokenId = _deployNativePool();
        // Give the fee project a terminal that accepts native ETH so the native cut is actually paid.
        _setDirectoryTerminal(FEE_PROJECT_ID, NATIVE, address(terminal));
        terminal.setAccountingContext(FEE_PROJECT_ID, NATIVE, uint32(uint160(NATIVE)), 18);

        // Native sorts as currency0 (address(0)); set the native-side collectable fee and fund the PM with ETH.
        uint256 fee = 1e18;
        positionManager.setCollectableFees(tokenId, fee, 0);
        vm.deal(address(positionManager), fee);

        uint256 payBefore = terminal.payCallCount();
        uint256 claimBefore = hook.claimableFeeTokens(PROJECT_ID);

        hook.collectAndRouteLPFees(PROJECT_ID, NATIVE);

        uint256 cut = (fee * FEE_PERCENT) / 10_000;
        assertGt(terminal.payCallCount(), payBefore, "native cut must be paid");
        assertEq(terminal.lastPayProjectId(), FEE_PROJECT_ID, "native cut routed to fee project");
        assertEq(terminal.lastPayAmount(), cut, "native cut forwarded as value");
        assertEq(hook.claimableFeeTokens(PROJECT_ID) - claimBefore, cut, "cut tracked as claimable fee tokens");
        assertEq(
            hook.accumulatedTerminalTokens(PROJECT_ID, NATIVE), fee - cut, "native remainder to native bid-leg ledger"
        );
    }

    /// @notice A forgiven native-terminal cut routes the whole native fee into the native bid-leg ledger.
    function test_Native_ForgivenFee_FullyLedgered() public {
        uint256 tokenId = _deployNativePool();
        // The fee project has no native terminal → the native cut is forgiven.
        uint256 fee = 1e18;
        positionManager.setCollectableFees(tokenId, fee, 0);
        vm.deal(address(positionManager), fee);

        hook.collectAndRouteLPFees(PROJECT_ID, NATIVE);

        assertEq(hook.accumulatedTerminalTokens(PROJECT_ID, NATIVE), fee, "forgiven native fee fully ledgered");
    }

    // ─── Isolation (regression of the Critical)
    // ──────────────────────────────

    /// @notice A project's mint sizes its terminal leg ONLY from its own recovered terminal plus its own ledger —
    /// never
    /// from another project's ledger or an outside donation sitting in the shared clone's raw balance.
    function test_Isolation_MintNeverConsumesOtherLedgerOrDonation() public {
        _deployA(); // asks-only: A has zero recovered terminal and an empty terminal ledger.
        _setupProjectB();
        uint256 bTokenId = _accumulateAndDeployB(100e18);

        // Fund B's terminal ledger via a forgiven terminal-fee collection.
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(0));
        _setTerminalFeesFor(bTokenId, address(projectTokenB), 4e18);
        hook.collectAndRouteLPFees(PROJECT_B, address(terminalToken));
        uint256 ledgerB = hook.accumulatedTerminalTokens(PROJECT_B, address(terminalToken));
        assertEq(ledgerB, 4e18, "precondition: B's terminal ledger is funded");

        // Donate raw terminal tokens directly to the shared hook.
        uint256 donation = 250e18;
        terminalToken.mint(address(hook), donation);

        // A adds liquidity: its terminal amount is recovered(0) + ledger(0) == 0, so it mints asks-only.
        _accumulateTokens(PROJECT_ID, 10e18);
        vm.prank(owner);
        hook.addLiquidity(PROJECT_ID, address(terminalToken));

        (, uint256 aTerminalSide) = _lockedSides(hook.tokenIdOf(PROJECT_ID, address(terminalToken)));
        assertEq(aTerminalSide, 0, "A consumed zero terminal: neither B's ledger nor the donation was swept");
        assertEq(
            hook.accumulatedTerminalTokens(PROJECT_ID, address(terminalToken)),
            0,
            "A never absorbed B's ledger or the donation into its own ledger"
        );
        assertEq(hook.accumulatedTerminalTokens(PROJECT_B, address(terminalToken)), ledgerB, "B's ledger is untouched");
        assertGe(terminalToken.balanceOf(address(hook)), ledgerB + donation, "B's ledger and the donation remain");
    }
}
