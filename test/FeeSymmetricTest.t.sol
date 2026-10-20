// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase, DEFAULT_SURPLUS_PER_TOKEN} from "./TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {JBLPSplitHookHelpers} from "../src/libraries/JBLPSplitHookHelpers.sol";
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

/// @notice Tests for the symmetric, best-effort fee-project cut and where the remainder goes.
/// @dev The cut is attempted on BOTH the terminal-token side and the project-token side; every non-cut fee token
/// accrues to the originating project (terminal → `addToBalanceOf` its primary terminal, project → burned), falling
/// back to that side's ledger only when the route fails. The mint never reads the hook's raw balance for sizing.
contract FeeSymmetricTest is LPSplitHookV4TestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

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
        tokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
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
        _setWideTaxedCurve(PROJECT_ID);
        (int24 floorTick, int24 ceilingTick) = _corridorA();
        positionManager.initializePool(
            _poolKeyA(), TickMath.getSqrtPriceAtTick(floorTick + (ceilingTick - floorTick) / 2)
        );
        _accumulateTokens(PROJECT_ID, projectAmount);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID);
        tokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)});
    }

    /// @notice Asserts A's live spot leaves a non-empty terminal-token (bid) range inside A's corridor, so a zero bid
    /// id proves A had no terminal inventory rather than that the geometry forbade a bid.
    function _assertBidRangeNonEmptyA() internal view {
        // Read A's corridor and live spot, the same inputs the hook bounds a bid with.
        (int24 lower, int24 upper) = _corridorA();
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(_poolKeyA().toId());
        int24 spacing = hook.TICK_SPACING();
        // Align the spot down to the tick spacing, matching how the hook bounds positions around spot.
        int24 spotFloor = JBLPSplitHookHelpers.alignTickToSpacing({
            tick: TickMath.getTickAtSqrtPrice(sqrtPriceX96), spacing: spacing
        });
        // A token0 bid sits above spot and a token1 bid below it, so check the side the terminal token occupies.
        if (terminalTokenIsToken0) {
            assertLt(spotFloor + spacing, upper, "precondition: a terminal-token0 bid range exists above the spot");
        } else {
            assertGt(spotFloor, lower, "precondition: a terminal-token1 bid range exists below the spot");
        }
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
        return uint256(vm.load(address(hook), keccak256(abi.encode(token, SLOT_OUTSTANDING_FEE_TOKEN_CLAIMS))));
    }

    function _inflightCount(address token) internal view returns (uint256) {
        return uint256(vm.load(address(hook), keccak256(abi.encode(token, SLOT_INFLIGHT_FEE_ROUTING_COUNT))));
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
        // Give B the same cash-out value per token as the base project.
        store.setSurplus({projectId: PROJECT_B, surplus: DEFAULT_SURPLUS_PER_TOKEN});
        store.setBalance(address(terminal), PROJECT_B, address(terminalToken), 10e18);
        _addDirectoryTerminal(PROJECT_B, address(terminal));
    }

    function _accumulateAndDeployB(uint256 amount) internal returns (uint256 tokenId) {
        projectTokenB.mint(address(controller), amount);
        vm.startPrank(address(controller));
        projectTokenB.approve(address(hook), amount);
        // Cap gas below the inline-automation floor so the split only records intake.
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(
            _buildContext({projectId: PROJECT_B, token: address(projectTokenB), amount: amount, groupId: 1})
        );
        vm.stopPrank();
        vm.prank(owner);
        hook.deployPool(PROJECT_B);
        tokenId = hook.askTokenIdOf({projectId: PROJECT_B, terminalToken: address(terminalToken)});
    }

    // ─── Project-token side
    // ─────────────────────────────────────────────────

    /// @notice When the fee project has a terminal accepting the PROJECT token, the project-token side takes a cut and
    /// only the remainder is burned; the accumulation ledger is unchanged.
    function test_ProjectSide_CutPaid_RemainderBurned() public {
        uint256 tokenId = _deployA();
        // Give the fee project a terminal that accepts the project token.
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: address(projectToken), term: address(terminal)});

        // Accrue a project-token fee on A's ask.
        uint256 projFee = 500e18;
        _setProjectFees({tokenId: tokenId, amount: projFee});

        // Snapshot the ledger, claims, payments and supply so the assertions isolate the collection.
        uint256 accBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 claimBefore = hook.claimableFeeTokens(PROJECT_ID);
        uint256 payBefore = terminal.payCallCount();
        uint256 supplyBefore = projectToken.totalSupply();

        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The fee project is paid its percentage of the fee and the rest is burned.
        uint256 cut = (projFee * FEE_PERCENT) / 10_000;
        assertGt(terminal.payCallCount(), payBefore, "project-token cut must be paid");
        assertEq(terminal.lastPayProjectId(), FEE_PROJECT_ID, "cut routed to fee project");
        assertEq(terminal.lastPayAmount(), cut, "cut is feePercent of the project fee");
        assertEq(hook.claimableFeeTokens(PROJECT_ID) - claimBefore, cut, "cut tracked as claimable fee tokens");
        assertEq(controller.lastBurnAmount(), projFee - cut, "only the remainder is burned");
        assertEq(supplyBefore - projectToken.totalSupply(), projFee - cut, "supply fell by exactly the remainder");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), accBefore, "the accumulation ledger is unchanged");
    }

    /// @notice When the fee project has NO terminal for the project token, the cut is forgiven and the whole
    /// project-token fee is burned.
    function test_ProjectSide_Forgiven_FullAmountBurned() public {
        // The fee project has no project-token terminal, so the cut is forgiven.
        uint256 tokenId = _deployA();

        // Accrue a project-token fee on A's ask.
        uint256 projFee = 500e18;
        _setProjectFees({tokenId: tokenId, amount: projFee});

        // Snapshot the ledger, payments and supply so the assertions isolate the collection.
        uint256 accBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 payBefore = terminal.payCallCount();
        uint256 supplyBefore = projectToken.totalSupply();

        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // Nothing is paid and the whole fee is burned.
        assertEq(terminal.payCallCount(), payBefore, "no cut without a project-token fee terminal");
        assertEq(supplyBefore - projectToken.totalSupply(), projFee, "full project fee burned");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), accBefore, "the accumulation ledger is unchanged");
    }

    // ─── Terminal-token side
    // ────────────────────────────────────────────────

    /// @notice The non-cut terminal remainder is added to the project's balance in its primary terminal via
    /// `addToBalanceOf`; the per-project terminal ledger is unchanged.
    function test_TerminalSide_RemainderToTreasury() public {
        uint256 tokenId = _deployA();

        // Accrue a terminal-token fee on A's ask.
        uint256 termFee = 1000e18;
        _setTerminalFees({tokenId: tokenId, amount: termFee});

        // Snapshot balance additions and the ledger so the assertions isolate the collection.
        uint256 addBefore = terminal.addToBalanceCallCount();
        uint256 ledgerBefore =
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // The remainder after the fee project's cut is added to A's balance.
        uint256 cut = (termFee * FEE_PERCENT) / 10_000;
        assertEq(terminal.addToBalanceCallCount(), addBefore + 1, "terminal remainder added to the balance");
        assertEq(terminal.lastAddToBalanceProjectId(), PROJECT_ID, "of the originating project");
        assertEq(terminal.lastAddToBalanceAmount(), termFee - cut, "exactly the remainder");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            ledgerBefore,
            "the bid-leg ledger is unchanged"
        );
    }

    /// @notice A terminal remainder whose add to the project's balance is rejected lands in the ledger, and a
    /// subsequent recycle consumes that ledger into the bid position.
    function test_TerminalSide_RouteForgiven_FundsBidOnNextMint() public {
        uint256 tokenId = _deployAAtMid(0.5e18);
        // Forgive the terminal cut by removing the fee project's terminal for the terminal token, and have the
        // project's terminal reject the remainder so it falls back to the ledger.
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: address(terminalToken), term: address(0)});
        terminal.setRevertOnAddToBalance(true);

        // Accrue and collect a terminal-token fee; with both routes refused, the whole fee is ledgered.
        uint256 termFee = 1e18;
        _setTerminalFees({tokenId: tokenId, amount: termFee});
        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        assertEq(
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            termFee,
            "forgiven terminal fee fully ledgered"
        );

        // Accumulate fresh inventory and recycle, which spends the ledgered terminal on a bid.
        _accumulateTokens({projectId: PROJECT_ID, amount: 0.5e18});

        vm.prank(owner);
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        assertLt(
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            termFee,
            "the terminal ledger is drawn down into the mint"
        );
        // The bid holds the terminal drawn from the ledger.
        (, uint256 terminalSide) =
            _lockedSides(hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}));
        assertGt(terminalSide, 0, "the bid position is funded from the terminal ledger");
    }

    // ─── Best-effort (try/catch)
    // ─────────────────────────────────────────────

    /// @notice A fee terminal whose `pay` reverts forgives the terminal cut: collection succeeds, the whole fee is
    /// added to the project's balance, no claim is tracked, and the reentrancy reserve counters are fully rolled back.
    function test_TryCatch_TerminalPayReverts_CutForgiven() public {
        uint256 tokenId = _deployA();
        RevertingPayTerminal rt = new RevertingPayTerminal();
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: address(terminalToken), term: address(rt)});

        uint256 termFee = 10e18;
        _setTerminalFees({tokenId: tokenId, amount: termFee});

        // Snapshot the project terminal's balance so the assertion isolates what the collection adds.
        uint256 terminalBalanceBefore = terminalToken.balanceOf(address(terminal));
        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        assertEq(
            terminalToken.balanceOf(address(terminal)) - terminalBalanceBefore,
            termFee,
            "forgiven cut adds the whole terminal fee to the project's balance"
        );
        assertEq(terminal.lastAddToBalanceAmount(), termFee, "the whole fee is the remainder");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "nothing ledgered"
        );
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "no claim tracked when the cut is forgiven");
        assertEq(_outstandingTokenClaims(address(feeProjectToken)), 0, "outstanding token claims fully rolled back");
        assertEq(_inflightCount(address(feeProjectToken)), 0, "inflight routing count fully rolled back");
    }

    /// @notice A reverting fee terminal on the PROJECT-token side is likewise forgiven: the whole project fee is burned
    /// and reserve counters are rolled back.
    function test_TryCatch_ProjectPayReverts_CutForgiven() public {
        uint256 tokenId = _deployA();
        RevertingPayTerminal rt = new RevertingPayTerminal();
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: address(projectToken), term: address(rt)});

        uint256 projFee = 400e18;
        _setProjectFees({tokenId: tokenId, amount: projFee});

        // Snapshot the ledger and supply so the assertions isolate the collection.
        uint256 accBefore = hook.accumulatedProjectTokens(PROJECT_ID);
        uint256 supplyBefore = projectToken.totalSupply();
        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        assertEq(supplyBefore - projectToken.totalSupply(), projFee, "forgiven project cut: the whole fee is burned");
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), accBefore, "the accumulation ledger is unchanged");
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
        tokenId = hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: NATIVE});
    }

    /// @notice A PAID native-terminal cut is forwarded with msg.value and the non-cut remainder is added to the
    /// project's native balance, also with msg.value; the native bid-leg ledger is unchanged.
    function test_Native_CutPaidWithValue_RemainderToTreasury() public {
        uint256 tokenId = _deployNativePool();
        // Give the fee project a terminal that accepts native ETH so the native cut is actually paid.
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: NATIVE, term: address(terminal)});
        terminal.setAccountingContext({
            projectId: FEE_PROJECT_ID, token: NATIVE, currency: uint32(uint160(NATIVE)), decimals: 18
        });

        // Native sorts as currency0 (address(0)); set the native-side collectable fee and fund the PM with ETH.
        uint256 fee = 1e18;
        positionManager.setCollectableFees({tokenId: tokenId, amount0: fee, amount1: 0});
        vm.deal(address(positionManager), fee);

        // Snapshot payments, claims and the terminal's ETH so the assertions isolate the collection.
        uint256 payBefore = terminal.payCallCount();
        uint256 claimBefore = hook.claimableFeeTokens(PROJECT_ID);
        uint256 terminalEthBefore = address(terminal).balance;

        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: NATIVE});

        // The fee project is paid its percentage in ETH and the remainder is added to the project's balance in ETH.
        uint256 cut = (fee * FEE_PERCENT) / 10_000;
        assertGt(terminal.payCallCount(), payBefore, "native cut must be paid");
        assertEq(terminal.lastPayProjectId(), FEE_PROJECT_ID, "native cut routed to fee project");
        assertEq(terminal.lastPayAmount(), cut, "native cut forwarded as value");
        assertEq(hook.claimableFeeTokens(PROJECT_ID) - claimBefore, cut, "cut tracked as claimable fee tokens");
        assertEq(terminal.lastAddToBalanceProjectId(), PROJECT_ID, "native remainder added to the project");
        assertEq(terminal.lastAddToBalanceToken(), NATIVE, "in the native token");
        assertEq(terminal.lastAddToBalanceAmount(), fee - cut, "exactly the remainder");
        assertEq(terminal.lastAddToBalanceValue(), fee - cut, "forwarded as value");
        assertEq(address(terminal).balance - terminalEthBefore, fee, "the terminal received the cut and the remainder");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: NATIVE}),
            0,
            "the native bid-leg ledger is unchanged"
        );
    }

    /// @notice A forgiven native-terminal cut adds the whole native fee to the project's balance.
    function test_Native_ForgivenFee_FullyToTreasury() public {
        uint256 tokenId = _deployNativePool();
        // The fee project has no native terminal → the native cut is forgiven.
        // Native sorts as currency0, so the fee goes in the token0 slot; fund the PM with the ETH to pay it.
        uint256 fee = 1e18;
        positionManager.setCollectableFees({tokenId: tokenId, amount0: fee, amount1: 0});
        vm.deal(address(positionManager), fee);
        // Snapshot the terminal's ETH so the assertion isolates what the collection adds.
        uint256 terminalEthBefore = address(terminal).balance;

        hook.collectAndRouteLPFees({projectId: PROJECT_ID, terminalToken: NATIVE});

        // The whole fee reaches the project's balance as value and nothing is ledgered.
        assertEq(address(terminal).balance - terminalEthBefore, fee, "forgiven native fee fully added to the balance");
        assertEq(terminal.lastAddToBalanceValue(), fee, "forwarded as value");
        assertEq(hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: NATIVE}), 0, "nothing ledgered");
    }

    // ─── Isolation (regression of the Critical)
    // ──────────────────────────────

    /// @notice A project's mint sizes its terminal leg ONLY from its own recovered terminal plus its own ledger —
    /// never
    /// from another project's ledger or an outside donation sitting in the shared clone's raw balance.
    function test_Isolation_MintNeverConsumesOtherLedgerOrDonation() public {
        // Asks-only at a mid-corridor spot: A has zero recovered terminal and an empty terminal ledger, yet the spot
        // leaves a non-empty bid range, so a bid WOULD mint if A's terminal amount captured any foreign inventory.
        _deployAAtMid(0.5e18);
        _assertBidRangeNonEmptyA();
        // Deploy B on the same clone so its ledger shares the hook's raw balance with A.
        _setupProjectB();
        uint256 bTokenId = _accumulateAndDeployB(100e18);

        // Fund B's terminal ledger via a terminal-fee collection whose cut and route are both forgiven.
        _setDirectoryTerminal({projectId: FEE_PROJECT_ID, token: address(terminalToken), term: address(0)});
        _setTerminalFeesFor({tokenId: bTokenId, projectTok: address(projectTokenB), amount: 4e18});
        // Refuse the balance addition only for B's collection, then restore the terminal for A's recycle.
        terminal.setRevertOnAddToBalance(true);
        hook.collectAndRouteLPFees({projectId: PROJECT_B, terminalToken: address(terminalToken)});
        terminal.setRevertOnAddToBalance(false);
        uint256 ledgerB = hook.accumulatedTerminalTokens({projectId: PROJECT_B, terminalToken: address(terminalToken)});
        assertEq(ledgerB, 4e18, "precondition: B's terminal ledger is funded");

        // Donate raw terminal tokens directly to the shared hook.
        uint256 donation = 250e18;
        terminalToken.mint({to: address(hook), amount: donation});

        // A adds liquidity: its terminal amount is recovered(0) + ledger(0) == 0, so it mints asks-only.
        _accumulateTokens({projectId: PROJECT_ID, amount: 10e18});
        vm.prank(owner);
        hook.addLiquidity({projectId: PROJECT_ID, terminalToken: address(terminalToken)});

        // A's positions and ledger hold no terminal, and B's ledger and the donation are left on the hook.
        (, uint256 aTerminalSide) =
            _lockedSides(hook.askTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}));
        assertEq(aTerminalSide, 0, "A's ask holds zero terminal");
        assertEq(
            hook.bidTokenIdOf({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "A minted no bid: neither B's ledger nor the donation was captured as A's terminal inventory"
        );
        assertEq(
            hook.accumulatedTerminalTokens({projectId: PROJECT_ID, terminalToken: address(terminalToken)}),
            0,
            "A never absorbed B's ledger or the donation into its own ledger"
        );
        assertEq(
            hook.accumulatedTerminalTokens({projectId: PROJECT_B, terminalToken: address(terminalToken)}),
            ledgerB,
            "B's ledger is untouched"
        );
        assertEq(terminalToken.balanceOf(address(hook)), ledgerB + donation, "B's ledger and the donation remain");
    }
}
