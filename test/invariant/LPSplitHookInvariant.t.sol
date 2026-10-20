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
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockGeomeanOracle} from "../mock/MockGeomeanOracle.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBLPSplitHookHelpers} from "../../src/libraries/JBLPSplitHookHelpers.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
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
    // Derives a pool's ID from its key when reading the pool's spot.
    using PoolIdLibrary for PoolKey;

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The basis the fee percent is expressed in.
    uint256 public constant BPS = 10_000;

    /// @notice The fee percent the hook is initialized with, out of `BPS`.
    uint256 public constant FEE_PERCENT = 3800;

    /// @notice The highest project ID the handler exercises.
    /// @dev A small set (1-3) keeps the invariant checker tractable while covering multi-project interactions.
    uint256 public constant MAX_PROJECT_ID = 3;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Gas cap that covers intake but sits below the hook's inline-automation attempt floor, keeping the
    /// handler's accumulate actions accumulate-only (automation skips, exactly like a distribution arriving without
    /// enough gas for it), so the invariants keep exercising the explicit deploy/add paths.
    uint256 internal constant _INTAKE_ONLY_GAS = 300_000;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Whether the project's terminal currently rejects `addToBalanceOf`.
    /// @dev While set, collected terminal-token fee remainders stay in the project's books.
    bool public addToBalanceFails;

    /// @notice Whether the controller currently rejects `burnTokensOf`.
    /// @dev While set, collected project-token fees stay in the project's books instead of burning.
    bool public burnFails;

    /// @notice Ghost variable: the number of successful `processSplitWith` accumulations.
    uint256 public callCount;

    /// @notice Ghost variable: the number of successful `collectAndRouteLPFees` calls.
    uint256 public collectFeeCallCount;

    /// @notice The mock controller that sends reserved tokens to the hook and burns collected project-token fees.
    MockJBController public controller;

    /// @notice Ghost variable: the number of successful `deployPool` calls.
    uint256 public deployCallCount;

    /// @notice Ghost variable: the fee-project claims each project must hold, derived only from the fees the handler
    /// injected.
    /// @dev Every collected terminal-side fee pays a cut of `fee * FEE_PERCENT / BPS` to the fee project's terminal,
    /// whose mock `pay` mints the beneficiary 1:1. The project-side cut is always forgiven (the fee project has no
    /// terminal for the project token here). Never read back from the hook's own claim ledger.
    /// @custom:param projectId The project the claims are owed to.
    mapping(uint256 projectId => uint256 amount) public expectedClaims;

    /// @notice Ghost variable: successful collections that collected a nonzero injected fee.
    uint256 public feeCollectionCount;

    /// @notice Ghost variable: successful recycles that collected a nonzero injected fee.
    uint256 public feeRecycleCount;

    /// @notice The hook under test.
    JBUniswapV4LPSplitHook public hook;

    /// @notice The mock token registry the projects are wired to.
    MockJBTokens public jbTokens;

    /// @notice The revert data of the most recent unexpected failure, reported when the latch trips.
    bytes public lastUnexpectedFailure;

    /// @notice The owner of every project in the campaign.
    address public owner;

    /// @notice Ghost variable: payouts the hook accepted into a bid ledger.
    uint256 public payoutCount;

    /// @notice Ghost variable: payouts the hook rejected because the project's pool was not deployed yet.
    uint256 public payoutRejectedCount;

    /// @notice Ghost variable: expected claims from injected fees not yet collected.
    /// @dev Moved into `expectedClaims` by the next successful collection or recycle of the project, which collects
    /// every live position.
    /// @custom:param projectId The project whose fees are pending.
    mapping(uint256 projectId => uint256 amount) public pendingExpectedClaims;

    /// @notice Ghost variable: project-token fees injected into a project's positions and not yet collected.
    /// @dev Settled by the next successful collection or recycle of the project.
    /// @custom:param projectId The project whose fees are pending.
    mapping(uint256 projectId => uint256 amount) public pendingProjectFees;

    /// @notice Ghost variable: terminal-token fees injected into a project's positions and not yet collected.
    /// @dev Settled by the next successful collection or recycle of the project.
    /// @custom:param projectId The project whose fees are pending.
    mapping(uint256 projectId => uint256 amount) public pendingTerminalFees;

    /// @notice The mock PositionManager holding every position the hook mints.
    MockPositionManager public positionManager;

    /// @notice Ghost variable: the project tokens V4's rounding left in the pool when recycles burned the project's
    /// positions.
    /// @dev Each burn returns its principal at the spot rounded down, below the rounded-up cost the pool holds.
    /// @custom:param projectId The project whose positions were burned.
    mapping(uint256 projectId => uint256 amount) public projectBurnRounding;

    /// @notice Ghost variable: collected project-token fees burned for a project.
    /// @dev The project-side cut is always forgiven here, so the whole collected fee burns unless the burn route
    /// fails, in which case it stays in the project's books.
    /// @custom:param projectId The project whose fees were burned.
    mapping(uint256 projectId => uint256 amount) public projectFeesBurned;

    /// @notice Ghost variable: gross project-token LP fees injected into a project's positions.
    /// @custom:param projectId The project whose positions received the fees.
    mapping(uint256 projectId => uint256 amount) public projectFeesInjected;

    /// @notice The project token every project in the campaign uses.
    MockERC20 public projectToken;

    /// @notice Ghost variable: every project token the handler minted (reserved intake and injected fees).
    uint256 public projectTokensMinted;

    /// @notice Ghost variable: the number of successful `addLiquidity` (recycle) calls.
    uint256 public recycleCallCount;

    /// @notice The mock terminal that pays out to the hook and receives its fee flows.
    MockJBMultiTerminal public terminal;

    /// @notice Ghost variable: the terminal tokens V4's rounding left in the pool when recycles burned the project's
    /// positions.
    /// @dev Each burn returns its principal at the spot rounded down, below the rounded-up cost the pool holds.
    /// @custom:param projectId The project whose positions were burned.
    mapping(uint256 projectId => uint256 amount) public terminalBurnRounding;

    /// @notice Ghost variable: collected terminal-token fee remainders added to a project's balance.
    /// @dev A remainder collected while the deposit route fails stays in the project's books instead.
    /// @custom:param projectId The project whose balance received the remainders.
    mapping(uint256 projectId => uint256 amount) public terminalFeesAddedToBalance;

    /// @notice Ghost variable: gross terminal-token LP fees injected into a project's positions.
    /// @custom:param projectId The project whose positions received the fees.
    mapping(uint256 projectId => uint256 amount) public terminalFeesInjected;

    /// @notice Ghost variable: terminal tokens accepted from payout splits into a project's bid ledger.
    /// @custom:param projectId The project whose bid ledger received the payouts.
    mapping(uint256 projectId => uint256 amount) public terminalPayouts;

    /// @notice The terminal token every project in the campaign pairs with.
    MockERC20 public terminalToken;

    /// @notice Ghost variable: the cumulative project tokens accumulated into the hook per project.
    /// @dev Tracked independently of the hook so the accumulation invariant can cross-check its ledger.
    /// @custom:param projectId The project the tokens were accumulated for.
    mapping(uint256 projectId => uint256 totalMinted) public totalMintedToHook;

    /// @notice Ghost variable: gross LP fees injected into a project's live positions and not yet collected.
    /// @custom:param projectId The project whose positions hold the fees.
    mapping(uint256 projectId => uint256 amount) public uncollectedFees;

    /// @notice Failure latch: every caught revert a handler cannot justify under a checked precondition.
    /// @dev `invariant_noUnexpectedFailures` fails the campaign on the first one, reporting `lastUnexpectedFailure`.
    uint256 public unexpectedFailures;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param targetHook The hook under test.
    /// @param targetProjectToken The project token every project uses.
    /// @param targetTerminalToken The terminal token every project pairs with.
    /// @param targetController The mock controller wired to every project.
    /// @param targetPositionManager The mock PositionManager the hook mints through.
    /// @param targetTerminal The mock terminal wired to every project.
    /// @param targetJbTokens The mock token registry the projects are wired to.
    /// @param projectOwner The owner of every project.
    constructor(
        JBUniswapV4LPSplitHook targetHook,
        MockERC20 targetProjectToken,
        MockERC20 targetTerminalToken,
        MockJBController targetController,
        MockPositionManager targetPositionManager,
        MockJBMultiTerminal targetTerminal,
        MockJBTokens targetJbTokens,
        address projectOwner
    ) {
        // Keep the campaign's contracts so every handler action reaches the same deployment.
        hook = targetHook;
        projectToken = targetProjectToken;
        terminalToken = targetTerminalToken;
        controller = targetController;
        positionManager = targetPositionManager;
        terminal = targetTerminal;
        jbTokens = targetJbTokens;
        owner = projectOwner;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accumulate project tokens via processSplitWith (before or after deployment; the hook never burns).
    /// @dev The call runs under `_INTAKE_ONLY_GAS`, so the hook takes the tokens without attempting inline
    /// automation.
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range [1, MAX_PROJECT_ID].
    /// @param amount Fuzzed amount of tokens to accumulate.
    function accumulate(uint256 projectIdSeed, uint256 amount) external {
        // Bound project ID to [1, MAX_PROJECT_ID] (project 0 has no controller).
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);

        // Bound amount to [0, 1e30] to stay within realistic ranges and avoid overflow.
        amount = bound(amount, 0, 1e30);

        // Mint the tokens to the controller, which hands them to the hook, and count them toward the supply ghost.
        projectToken.mint({to: address(controller), amount: amount});
        projectTokensMinted += amount;

        // Build the context of a reserved-token split that routes the whole amount to the hook.
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

        // Act as the controller (the authorized caller) and approve the hook to pull the tokens.
        vm.startPrank(address(controller));
        projectToken.approve({spender: address(hook), amount: amount});
        try hook.processSplitWith{gas: _INTAKE_ONLY_GAS}(context) {
            // Record the accepted amount for the accumulation cross-check and the activity invariant.
            totalMintedToHook[projectId] += amount;
            callCount++;
        } catch (bytes memory reason) {
            // Intake from the authorized controller never reverts, so any revert is unjustified.
            _latch(reason);
        }
        vm.stopPrank();
    }

    /// @notice Call processSplitWith with zero amount (edge case).
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range.
    function accumulateZero(uint256 projectIdSeed) external {
        // Bound project ID to [1, MAX_PROJECT_ID] (project 0 has no controller).
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);

        // Build the context of a reserved-token split that routes nothing to the hook.
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

        // Deliver the empty split as the controller (the authorized caller).
        vm.prank(address(controller));
        try hook.processSplitWith{gas: _INTAKE_ONLY_GAS}(context) {
            // Count the success for the activity invariant.
            callCount++;
        } catch (bytes memory reason) {
            // A zero-amount intake from the authorized controller never reverts, so any revert is unjustified.
            _latch(reason);
        }
    }

    /// @notice Recycle a deployed project's positions (collect fees, burn ask and bid, re-mint both single-sided).
    /// @dev Permissionless. Every live position without uncollected fees first gets a nonzero fee. The spot, TWAP and
    /// corridor never move in this campaign, so the only justified revert is an inventory that buys zero liquidity on
    /// both ranges once the positions burn.
    /// @param projectIdSeed Fuzzed seed, reduced to a deployed project.
    /// @param feeSeed Fuzzed seed for the injected fees.
    function addLiquidity(uint256 projectIdSeed, uint256 feeSeed) external {
        // Pick a deployed project and give its live positions fees, so the recycle collects real fees.
        uint256 projectId = _deployedProject(projectIdSeed);
        _injectNonzeroFees({projectId: projectId, seed: feeSeed});
        // What the burns will leave in the pool, and what the hook will hold to re-mint, both priced before the call.
        (uint256 projectRounding, uint256 terminalRounding) = _burnRounding(projectId);
        (uint256 projectInventory, uint256 terminalInventory) = _recycleInventory(projectId);

        try hook.addLiquidity({projectId: projectId, terminalToken: address(terminalToken)}) {
            // The recycle collected both positions' fees before burning them.
            if (_settleCollectedFees(projectId)) feeRecycleCount++;
            // Count the success for the activity invariant.
            recycleCallCount++;
            // Record what the burns left in the pool, which the conservation invariants net out.
            projectBurnRounding[projectId] += projectRounding;
            terminalBurnRounding[projectId] += terminalRounding;
        } catch (bytes memory reason) {
            // A position burns back to less than its mint cost (the burn rounds down), so a dust inventory can buy no
            // liquidity on either range: the hook reverts and leaves the positions up. Accept only exactly that.
            if (isZeroLiquidityRevert({
                    reason: reason,
                    projectId: projectId,
                    projectInventory: projectInventory,
                    terminalInventory: terminalInventory
                })) {
                return;
            }
            // Any other revert is unjustified under the campaign's frozen spot and corridor.
            _latch(reason);
        }
    }

    /// @notice Collect LP fees from a deployed project's live ask and bid and route them. Permissionless.
    /// @dev Every live position without uncollected fees first gets a nonzero fee, so each collection moves real
    /// fees. A deployed project always holds a live position and the PositionManager is funded for every injected
    /// fee, so no revert is justified.
    /// @param projectIdSeed Fuzzed seed, reduced to a deployed project.
    /// @param feeSeed Fuzzed seed for the injected fees.
    // forge-lint: disable-next-line(mixed-case-function)
    function collectAndRouteLPFees(uint256 projectIdSeed, uint256 feeSeed) external {
        // Pick a deployed project and give its live positions fees, so the collection moves real fees.
        uint256 projectId = _deployedProject(projectIdSeed);
        _injectNonzeroFees({projectId: projectId, seed: feeSeed});

        try hook.collectAndRouteLPFees({projectId: projectId, terminalToken: address(terminalToken)}) {
            // Settle the collected fees into the ghosts and count the success for the activity invariants.
            if (_settleCollectedFees(projectId)) feeCollectionCount++;
            collectFeeCallCount++;
        } catch (bytes memory reason) {
            // No revert is justified for a deployed project with funded fees.
            _latch(reason);
        }
    }

    /// @notice Deploy a project's pool from its accumulated tokens. Permissionless.
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range.
    function deployPool(uint256 projectIdSeed) external {
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);
        if (hook.hasDeployedPool(projectId)) return;

        // The deploy mints from exactly the ledgers it starts with (the campaign never credits the hook).
        uint256 accumulated = hook.accumulatedProjectTokens(projectId);
        uint256 terminalAccumulated =
            hook.accumulatedTerminalTokens({projectId: projectId, terminalToken: address(terminalToken)});
        try hook.deployPool(projectId) {
            // Count the success for the activity invariant.
            deployCallCount++;
        } catch (bytes memory reason) {
            // Justified only when nothing is accumulated, or when the accumulation buys zero liquidity on both ranges
            // (the corridor and spot never move in this campaign, so nothing else can make a deploy fail).
            if (
                accumulated == 0
                    && _selectorOf(reason) == JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoTokensAccumulated.selector
            ) {
                return;
            }
            if (isZeroLiquidityRevert({
                    reason: reason,
                    projectId: projectId,
                    projectInventory: accumulated,
                    terminalInventory: terminalAccumulated
                })) {
                return;
            }
            // Any other revert is unjustified under the campaign's frozen spot and corridor.
            _latch(reason);
        }
    }

    /// @notice Inject distinct collectable LP fees into a project's live ask AND bid (each position skipped while it
    /// still holds uncollected fees, so the ghosts stay exact per position).
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range.
    /// @param askFee0Seed Fuzzed seed for the ask's token0 fee.
    /// @param askFee1Seed Fuzzed seed for the ask's token1 fee.
    /// @param bidFee0Seed Fuzzed seed for the bid's token0 fee.
    /// @param bidFee1Seed Fuzzed seed for the bid's token1 fee.
    function injectFees(
        uint256 projectIdSeed,
        uint256 askFee0Seed,
        uint256 askFee1Seed,
        uint256 bidFee0Seed,
        uint256 bidFee1Seed
    )
        external
    {
        // Bound project ID to [1, MAX_PROJECT_ID]; a project without positions gets no fees.
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);
        // Give the live ask its fees, allowing a zero fee on either side.
        _injectFee({
            projectId: projectId,
            tokenId: hook.askTokenIdOf({projectId: projectId, terminalToken: address(terminalToken)}),
            fee0Seed: askFee0Seed,
            fee1Seed: askFee1Seed,
            minFee: 0
        });
        // Give the live bid its fees, allowing a zero fee on either side.
        _injectFee({
            projectId: projectId,
            tokenId: hook.bidTokenIdOf({projectId: projectId, terminalToken: address(terminalToken)}),
            fee0Seed: bidFee0Seed,
            fee1Seed: bidFee1Seed,
            minFee: 0
        });
    }

    /// @notice Pay out terminal tokens to the hook from the project's terminal, the way Core's payout path does
    /// (an allowance for the net amount, the token's payout group). Accepted once the pool is deployed, rejected
    /// before; a rejection moves nothing, so the terminal keeps (here: burns back) what it offered.
    /// @param projectIdSeed Fuzzed seed, reduced to valid project ID range [1, MAX_PROJECT_ID].
    /// @param amount Fuzzed amount of terminal tokens to pay out.
    function payout(uint256 projectIdSeed, uint256 amount) external {
        // Bound the project and the amount to the campaign's ranges.
        uint256 projectId = bound(projectIdSeed, 1, MAX_PROJECT_ID);
        amount = bound(amount, 0, 1e24);
        // Whether the pool exists decides whether the hook may accept the payout.
        bool deployed = hook.hasDeployedPool(projectId);

        // Fund the terminal with the payout, remembering what it held so an untaken remainder can be removed.
        uint256 heldBefore = terminalToken.balanceOf(address(terminal));
        terminalToken.mint({to: address(terminal), amount: amount});
        // Build the context of a payout split in the terminal token's payout group.
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(terminalToken),
            amount: amount,
            decimals: 18,
            projectId: projectId,
            groupId: uint256(uint160(address(terminalToken))),
            split: JBSplit({
                percent: 1_000_000,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(hook))
            })
        });

        // Act as the terminal and grant the hook an allowance for the payout.
        vm.startPrank(address(terminal));
        terminalToken.approve({spender: address(hook), amount: amount});
        try hook.processSplitWith{gas: _INTAKE_ONLY_GAS}(context) {
            // Acceptance before deploy is unjustified; an accepted payout lands in the project's bid ledger.
            if (!deployed) _latch("payout accepted before deploy");
            terminalPayouts[projectId] += amount;
            payoutCount++;
        } catch (bytes memory reason) {
            // Only the pre-deploy stage rejection is justified.
            if (
                deployed
                    || _selectorOf(reason)
                        != JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InvalidStageForAction.selector
            ) {
                _latch(reason);
            }
            payoutRejectedCount++;
        }
        // Clear any allowance the hook did not use, so it cannot pull the tokens later.
        terminalToken.approve({spender: address(hook), amount: 0});
        vm.stopPrank();
        // Core refunds a rejected payout to the project's balance; the campaign's terminal only holds fee flows, so
        // whatever was not taken is removed again.
        uint256 untaken = terminalToken.balanceOf(address(terminal)) - heldBefore;
        if (untaken > 0) terminalToken.burn({from: address(terminal), amount: untaken});
    }

    /// @notice Make the LP-fee routes fail or succeed: the project's terminal rejecting deposits (a paused terminal),
    /// and the controller rejecting burns (a paused controller).
    /// @param addFails Whether the terminal rejects `addToBalanceOf`.
    /// @param burnsFail Whether the controller rejects `burnTokensOf`.
    function setRouteFailures(bool addFails, bool burnsFail) external {
        // Record the routes in force so the ghosts settle collected fees where the hook sends them.
        addToBalanceFails = addFails;
        burnFails = burnsFail;
        // Apply the routes to the mocks the hook calls.
        terminal.setRevertOnAddToBalance(addFails);
        controller.setRevertOnBurn(burnsFail);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Whether `reason` is a justified `NoDeployableLiquidityAtSpot`: its decoded amounts equal the inventory
    /// the handler derived independently, and that inventory buys zero liquidity on both ranges the hook mints.
    /// @dev The liquidity comes from `remintLiquidity`, which applies the hook library's own per-range rule, so an
    /// amount that is small but still mintable is never accepted.
    /// @param reason The revert data the hook returned.
    /// @param projectId The project whose deploy or recycle reverted.
    /// @param projectInventory The project tokens the handler expects the hook to have tried to deploy.
    /// @param terminalInventory The terminal tokens the handler expects the hook to have tried to deploy.
    /// @return justified Whether the revert is the expected zero-liquidity outcome.
    function isZeroLiquidityRevert(
        bytes memory reason,
        uint256 projectId,
        uint256 projectInventory,
        uint256 terminalInventory
    )
        public
        view
        returns (bool justified)
    {
        // The error is a selector plus four static words; anything else is a different revert.
        if (
            reason.length != 132
                || _selectorOf(reason)
                    != JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector
        ) return false;

        // Decode the third and fourth words: the project and terminal amounts the hook tried to deploy.
        uint256 projectAmount;
        uint256 terminalAmount;
        assembly {
            projectAmount := mload(add(reason, 100))
            terminalAmount := mload(add(reason, 132))
        }

        // The hook must have tried to deploy exactly the inventory the handler expects.
        if (projectAmount != projectInventory || terminalAmount != terminalInventory) return false;

        // And that inventory must buy nothing on either range.
        (uint128 token0Liquidity, uint128 token1Liquidity) =
            remintLiquidity({projectId: projectId, projectAmount: projectAmount, terminalAmount: terminalAmount});
        justified = token0Liquidity == 0 && token1Liquidity == 0;
    }

    /// @notice The principal V4 returns when live position `tokenId` burns at the live spot, per currency.
    /// @dev Mirrors the PositionManager's burn: each side's amount for the position's liquidity, with the spot clamped
    /// into the range, rounded down.
    /// @param tokenId The live position to price.
    /// @return principal0 The token0 the burn returns.
    /// @return principal1 The token1 the burn returns.
    function positionPrincipal(uint256 tokenId) public view returns (uint256 principal0, uint256 principal1) {
        // The position's pool, range and liquidity.
        (PoolKey memory key, int24 lower, int24 upper, uint128 liquidity,,,) = positionManager._positions(tokenId);
        // The live spot of that pool.
        (uint160 sqrtP,,,) =
            StateLibrary.getSlot0({manager: IPoolManager(address(positionManager.poolManager())), poolId: key.toId()});
        // The range's bounds as sqrt prices.
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        // A spot outside the range holds the whole position in one currency, so clamp it to the nearer bound.
        sqrtP = sqrtP < sqrtA ? sqrtA : sqrtP > sqrtB ? sqrtB : sqrtP;
        // Token0 sits above the spot and token1 below it; a burn rounds both down.
        principal0 = SqrtPriceMath.getAmount0Delta({
            sqrtPriceAX96: sqrtP, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
        });
        principal1 = SqrtPriceMath.getAmount1Delta({
            sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtP, liquidity: liquidity, roundUp: false
        });
    }

    /// @notice What burning live position `tokenId` leaves in the pool, per currency: its reserves minus the principal
    /// V4 returns for its liquidity at the live spot (rounded down).
    /// @param tokenId The live position to price.
    /// @return rounding0 The token0 the burn leaves in the pool.
    /// @return rounding1 The token1 the burn leaves in the pool.
    function positionRounding(uint256 tokenId) public view returns (uint256 rounding0, uint256 rounding1) {
        // What the mint locked in the pool for this position.
        (,,,, uint256 locked0, uint256 locked1,) = positionManager._positions(tokenId);
        // What the burn returns of it.
        (uint256 principal0, uint256 principal1) = positionPrincipal(tokenId);
        // The difference stays in the pool.
        rounding0 = locked0 - principal0;
        rounding1 = locked1 - principal1;
    }

    /// @notice The liquidity the hook's two single-sided mints buy from the given amounts at the live spot.
    /// @dev Derives the ranges the way the hook does: the corridor from the hook library, the token0 range from the
    /// aligned tick at or above the spot up to the corridor's upper bound, the token1 range from the corridor's lower
    /// bound up to the aligned tick at or below the spot. The anchor is the spot (the oracle tracks the frozen spot).
    /// Each range's liquidity is the hook library's `cappedSingleSidedLiquidity`.
    /// @param projectId The project to price.
    /// @param projectAmount The project tokens to deploy.
    /// @param terminalAmount The terminal tokens to deploy.
    /// @return token0Liquidity The liquidity the token0 range above the spot buys.
    /// @return token1Liquidity The liquidity the token1 range below the spot buys.
    function remintLiquidity(
        uint256 projectId,
        uint256 projectAmount,
        uint256 terminalAmount
    )
        public
        view
        returns (uint128 token0Liquidity, uint128 token1Liquidity)
    {
        // Every project pairs the same two tokens, so they share one pool; the address order picks token0.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(projectIsToken0 ? address(projectToken) : address(terminalToken)),
            currency1: Currency.wrap(projectIsToken0 ? address(terminalToken) : address(projectToken)),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });

        // The project's corridor, from the same library call the hook makes.
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(projectId);
        (int24 corridorLower, int24 corridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(hook.DIRECTORY()),
            suckerRegistry: hook.SUCKER_REGISTRY(),
            projectId: projectId,
            terminalToken: address(terminalToken),
            projectToken: address(projectToken),
            controller: address(controller),
            ruleset: ruleset
        });

        // The aligned ticks at or below and at or above the live spot (project 1's seed initializes the pool).
        IPoolManager manager = hook.poolManager();
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0({manager: manager, poolId: key.toId()});
        int24 spotFloor = JBLPSplitHookHelpers.alignTickToSpacing({
            tick: TickMath.getTickAtSqrtPrice(sqrtPriceX96), spacing: key.tickSpacing
        });
        int24 spotCeil =
            TickMath.getSqrtPriceAtTick(spotFloor) == sqrtPriceX96 ? spotFloor : spotFloor + key.tickSpacing;

        // Token0 above the spot, clamped up to the corridor's lower bound.
        token0Liquidity = _rangeLiquidity({
            manager: manager,
            key: key,
            tickLower: spotCeil > corridorLower ? spotCeil : corridorLower,
            tickUpper: corridorUpper,
            amount0: projectIsToken0 ? projectAmount : terminalAmount,
            amount1: 0
        });
        // Token1 below the spot, clamped down to the corridor's upper bound.
        token1Liquidity = _rangeLiquidity({
            manager: manager,
            key: key,
            tickLower: corridorLower,
            tickUpper: spotFloor < corridorUpper ? spotFloor : corridorUpper,
            amount0: 0,
            amount1: projectIsToken0 ? terminalAmount : projectAmount
        });
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Give live position `tokenId` of `projectId` a collectable fee on both sides and record it in the
    /// ghosts.
    /// @dev Skips a missing position and one that still holds uncollected fees, so the ghosts stay exact per
    /// position.
    /// @param projectId The project the position belongs to.
    /// @param tokenId The position to give fees, or zero for none.
    /// @param fee0Seed Fuzzed seed for the token0 fee.
    /// @param fee1Seed Fuzzed seed for the token1 fee.
    /// @param minFee The smallest fee to inject on each side.
    function _injectFee(
        uint256 projectId,
        uint256 tokenId,
        uint256 fee0Seed,
        uint256 fee1Seed,
        uint256 minFee
    )
        internal
    {
        // A side with no live position has nothing to give fees.
        if (tokenId == 0) return;
        // A position still holding uncollected fees keeps them, so its pending ghosts stay exact.
        if (positionManager.collectableAmount0(tokenId) != 0 || positionManager.collectableAmount1(tokenId) != 0) {
            return;
        }
        // Bound fee amounts to realistic range [minFee, 1e24] to avoid overflow.
        uint256 fee0 = bound(fee0Seed, minFee, 1e24);
        uint256 fee1 = bound(fee1Seed, minFee, 1e24);
        positionManager.setCollectableFees({tokenId: tokenId, amount0: fee0, amount1: fee1});

        // Fund the position manager in each pool currency so it can pay the fees on TAKE_PAIR.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        (uint256 projectFee, uint256 terminalFee) = projectIsToken0 ? (fee0, fee1) : (fee1, fee0);
        projectToken.mint({to: address(positionManager), amount: projectFee});
        terminalToken.mint({to: address(positionManager), amount: terminalFee});
        // Record the fees in the supply, injected, pending and uncollected ghosts, including the fee project's cut
        // of the terminal side.
        projectTokensMinted += projectFee;
        projectFeesInjected[projectId] += projectFee;
        terminalFeesInjected[projectId] += terminalFee;
        pendingProjectFees[projectId] += projectFee;
        pendingTerminalFees[projectId] += terminalFee;
        pendingExpectedClaims[projectId] += (terminalFee * FEE_PERCENT) / BPS;
        uncollectedFees[projectId] += projectFee + terminalFee;
    }

    /// @notice Give every live position of `projectId` that holds no uncollected fee a distinct nonzero fee on both
    /// sides, derived from `seed`.
    /// @param projectId The project whose positions get fees.
    /// @param seed Fuzzed seed the per-position fee seeds derive from.
    function _injectNonzeroFees(uint256 projectId, uint256 seed) internal {
        // The project's live ask and bid, zero where a side holds no position.
        uint256[2] memory ids = [
            hook.askTokenIdOf({projectId: projectId, terminalToken: address(terminalToken)}),
            hook.bidTokenIdOf({projectId: projectId, terminalToken: address(terminalToken)})
        ];
        for (uint256 j; j < 2; j++) {
            // Derive distinct seeds per position and side, with a floor of one unit so every fee is nonzero.
            _injectFee({
                projectId: projectId,
                tokenId: ids[j],
                fee0Seed: uint256(keccak256(abi.encode(seed, j, 0))),
                fee1Seed: uint256(keccak256(abi.encode(seed, j, 1))),
                minFee: 1
            });
        }
    }

    /// @notice Record an unjustified revert so `invariant_noUnexpectedFailures` fails the campaign.
    /// @param reason The revert data to report.
    function _latch(bytes memory reason) internal {
        // Count the failure and keep its data for the failure message.
        unexpectedFailures++;
        lastUnexpectedFailure = reason;
    }

    /// @notice A successful collection or recycle collected every live position's injected fees.
    /// @dev The remainders go where the routes in force at collection send them: burned / added to the balance, or
    /// (when that route fails) left in the project's books.
    /// @param projectId The project whose fees were collected.
    /// @return collectedFees Whether a nonzero injected fee was collected.
    function _settleCollectedFees(uint256 projectId) internal returns (bool collectedFees) {
        // Every live position's fees were collected, so nothing stays uncollected.
        collectedFees = uncollectedFees[projectId] != 0;
        uncollectedFees[projectId] = 0;
        // Project-side fees burn in full (the cut is forgiven) unless the burn route fails.
        if (!burnFails) projectFeesBurned[projectId] += pendingProjectFees[projectId];
        // Terminal-side remainders, net of the fee project's cut, reach the balance unless the deposit route fails.
        if (!addToBalanceFails) {
            terminalFeesAddedToBalance[projectId] += pendingTerminalFees[projectId] - pendingExpectedClaims[projectId];
        }
        // Clear the pending fees and move their cuts into the claims the project must hold.
        pendingProjectFees[projectId] = 0;
        pendingTerminalFees[projectId] = 0;
        expectedClaims[projectId] += pendingExpectedClaims[projectId];
        pendingExpectedClaims[projectId] = 0;
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice What burning `projectId`'s live ask and bid leaves in the pool, by side: each position's reserves minus
    /// the principal V4 returns for its liquidity at the live spot (rounded down).
    /// @param projectId The project to price.
    /// @return projectSide The project tokens the burns leave in the pool.
    /// @return terminalSide The terminal tokens the burns leave in the pool.
    function _burnRounding(uint256 projectId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        // The address order picks which pool currency is the project token.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        // The project's live ask and bid, zero where a side holds no position.
        uint256[2] memory ids = [
            hook.askTokenIdOf({projectId: projectId, terminalToken: address(terminalToken)}),
            hook.bidTokenIdOf({projectId: projectId, terminalToken: address(terminalToken)})
        ];
        for (uint256 j; j < 2; j++) {
            // A side with no live position has nothing to burn.
            if (ids[j] == 0) continue;
            // Sort the position's rounding from pool currencies into project and terminal sides.
            (uint256 rounding0, uint256 rounding1) = positionRounding(ids[j]);
            projectSide += projectIsToken0 ? rounding0 : rounding1;
            terminalSide += projectIsToken0 ? rounding1 : rounding0;
        }
    }

    /// @notice A deployed project chosen by `seed` (project 1 is always deployed by the seed activity).
    /// @param seed Fuzzed seed picking among the deployed projects.
    /// @return projectId The chosen deployed project.
    function _deployedProject(uint256 seed) internal view returns (uint256 projectId) {
        // Collect the deployed projects in ID order.
        uint256[MAX_PROJECT_ID] memory deployed;
        uint256 count;
        for (uint256 i = 1; i <= MAX_PROJECT_ID; i++) {
            if (hook.hasDeployedPool(i)) deployed[count++] = i;
        }
        // The seed activity deploys project 1, so `count` is never zero.
        projectId = deployed[seed % count];
    }

    /// @notice The liquidity one single-sided mint buys over `[tickLower, tickUpper]`, or zero when the hook skips it.
    /// @param manager The pool manager holding the pool.
    /// @param key The pool key.
    /// @param tickLower The range's lower tick.
    /// @param tickUpper The range's upper tick.
    /// @param amount0 The token0 funding the range, or zero.
    /// @param amount1 The token1 funding the range, or zero.
    /// @return liquidity The liquidity the mint buys.
    function _rangeLiquidity(
        IPoolManager manager,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    )
        internal
        view
        returns (uint128 liquidity)
    {
        // The hook skips an empty or inverted range, and a range with nothing to fund it.
        if (tickLower >= tickUpper || (amount0 == 0 && amount1 == 0)) return 0;
        // Otherwise it mints what the library's capped single-sided rule buys.
        liquidity = JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
            poolManager: manager,
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0: amount0,
            amount1: amount1
        });
    }

    /// @notice What a recycle of `projectId` holds to re-mint once it burns the live positions, by side.
    /// @dev The ledgers, plus each live position's burn principal at the frozen spot, plus the collected fee
    /// remainders whose route fails (the hook carries those into the ledgers). The campaign never credits the hook.
    /// @param projectId The project to price.
    /// @return projectInventory The project tokens the recycle tries to deploy.
    /// @return terminalInventory The terminal tokens the recycle tries to deploy.
    function _recycleInventory(uint256 projectId)
        internal
        view
        returns (uint256 projectInventory, uint256 terminalInventory)
    {
        // Start from the ledgers.
        projectInventory = hook.accumulatedProjectTokens(projectId);
        terminalInventory =
            hook.accumulatedTerminalTokens({projectId: projectId, terminalToken: address(terminalToken)});

        // Add what burning the live ask and bid returns, sorted from pool currencies into project and terminal sides.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        uint256[2] memory ids = [
            hook.askTokenIdOf({projectId: projectId, terminalToken: address(terminalToken)}),
            hook.bidTokenIdOf({projectId: projectId, terminalToken: address(terminalToken)})
        ];
        for (uint256 j; j < 2; j++) {
            // A side with no live position has nothing to burn.
            if (ids[j] == 0) continue;
            (uint256 principal0, uint256 principal1) = positionPrincipal(ids[j]);
            projectInventory += projectIsToken0 ? principal0 : principal1;
            terminalInventory += projectIsToken0 ? principal1 : principal0;
        }

        // A failing burn route keeps the collected project-token fees in the books.
        if (burnFails) projectInventory += pendingProjectFees[projectId];
        // A failing deposit route keeps the terminal-token remainders (the fee project's cut still goes out).
        if (addToBalanceFails) terminalInventory += pendingTerminalFees[projectId] - pendingExpectedClaims[projectId];
    }

    /// @notice The 4-byte selector leading `reason`, or zero when the data is too short to hold one.
    /// @param reason The revert data to read.
    /// @return selector The revert's selector.
    function _selectorOf(bytes memory reason) internal pure returns (bytes4 selector) {
        // Keeping only the leading 4-byte selector is the point.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (reason.length >= 4) selector = bytes4(reason);
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
///   6. at most two positions per project are alive, every live position is a tracked ask or bid, and each holds at
///      most one unit per currency beyond the principal its burn returns (fresh mints at the frozen price)
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

    /// @notice The fee-moving collections the seed activity performed, which `afterInvariant` requires the run to
    /// exceed.
    uint256 public seedFeeCollections;

    /// @notice The fee-moving recycles the seed activity performed, which `afterInvariant` requires the run to exceed.
    uint256 public seedFeeRecycles;

    /// @notice Deploys the mocks, the hook and the handler, seeds real activity, and targets the handler.
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
        controller.setTokens(address(jbTokens));
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
        handler = new LPSplitHookHandler({
            targetHook: hook,
            targetProjectToken: projectToken,
            targetTerminalToken: terminalToken,
            targetController: controller,
            targetPositionManager: positionManager,
            targetTerminal: terminal,
            targetJbTokens: jbTokens,
            projectOwner: owner
        });

        // Seed one successful deploy, fee collection and recycle so every campaign starts from real activity (and a
        // live ask plus bid), and so the activity invariant can require it.
        _seedActivity();

        // Target only the handler for invariant fuzzing
        targetContract(address(handler));
    }

    // ─── Setup Helpers
    // ───────────────────────────────────────────────────

    /// @notice Project 1: accumulate, deploy, inject fees on the ask, collect them while the project's terminal
    /// rejects deposits (so the terminal remainder falls back to the bid ledger), and recycle into a live ask and bid.
    function _seedActivity() internal {
        // Accumulate into project 1 and deploy its pool from that inventory.
        handler.accumulate({projectIdSeed: 1, amount: 10e18});
        handler.deployPool(1);
        assertEq(handler.deployCallCount(), 1, "seed: deploy must succeed");
        // Give the ask fees and collect them while deposits fail, then restore the routes.
        handler.injectFees({projectIdSeed: 1, askFee0Seed: 3e18, askFee1Seed: 5e18, bidFee0Seed: 0, bidFee1Seed: 0});
        handler.setRouteFailures({addFails: true, burnsFail: false});
        handler.collectAndRouteLPFees({projectIdSeed: 1, feeSeed: 0});
        handler.setRouteFailures({addFails: false, burnsFail: false});
        assertEq(handler.collectFeeCallCount(), 1, "seed: fee collection must succeed");
        // Recycle project 1 into a fresh ask and bid.
        handler.addLiquidity({projectIdSeed: 1, feeSeed: 0});
        assertEq(handler.recycleCallCount(), 1, "seed: recycle must succeed");
        // A payout to the undeployed project 2 is rejected, and one to the deployed project 1 is accepted.
        handler.payout({projectIdSeed: 2, amount: 1e18});
        assertEq(handler.payoutRejectedCount(), 1, "seed: a payout before deploy is rejected");
        handler.payout({projectIdSeed: 1, amount: 1e18});
        assertEq(handler.payoutCount(), 1, "seed: a payout after deploy is accepted");
        // Record the seed's fee-moving counts so `afterInvariant` can require more.
        seedFeeCollections = handler.feeCollectionCount();
        seedFeeRecycles = handler.feeRecycleCount();
        // The campaign starts from a live ask and bid.
        assertNotEq(hook.askTokenIdOf({projectId: 1, terminalToken: address(terminalToken)}), 0, "seed: ask live");
        assertNotEq(hook.bidTokenIdOf({projectId: 1, terminalToken: address(terminalToken)}), 0, "seed: bid live");
    }

    /// @notice Wires `projectId` into the mock directory, terminal, token registry and store.
    /// @param projectId The project to wire.
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
        store.setSurplus({projectId: projectId, surplus: DEFAULT_SURPLUS_PER_TOKEN});
        // Give the project a terminal balance so `deployPool` can select its terminal token.
        store.setBalance({
            terminal: address(terminal), projectId: projectId, token: address(terminalToken), balance: 10e18
        });

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
    // Deterministic: the zero-liquidity allowance accepts only inventories that mint nothing
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice A 13-wei accumulation buys zero liquidity on both ranges at the campaign's spot, so the deploy's
    /// `NoDeployableLiquidityAtSpot` is accepted; the same error naming amounts other than the inventory is not.
    function test_zeroLiquidityAllowance_acceptsDustThatMintsNothing() public {
        // Accumulate an amount too small to buy one unit of liquidity on the project's ask range.
        handler.accumulate({projectIdSeed: 2, amount: 13});
        (uint128 token0Liquidity, uint128 token1Liquidity) =
            handler.remintLiquidity({projectId: 2, projectAmount: 13, terminalAmount: 0});
        assertEq(token0Liquidity + token1Liquidity, 0, "13 wei buys no liquidity on either range");

        // The deploy reverts, and the handler accepts it without latching a failure.
        handler.deployPool(2);
        assertFalse(hook.hasDeployedPool(2), "nothing was deployable");
        assertEq(handler.unexpectedFailures(), 0, "the zero-liquidity revert is accepted");

        // The same error is rejected when its amounts differ from the inventory the handler derived.
        bytes memory mismatched = abi.encodeWithSelector(
            JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector, 0, 0, 12, 0
        );
        assertFalse(
            handler.isZeroLiquidityRevert({
                reason: mismatched, projectId: 2, projectInventory: 13, terminalInventory: 0
            }),
            "amounts must equal the derived inventory"
        );
    }

    /// @notice 1,000 wei is far below any size-only dust bound yet buys liquidity on the project's ask range, so a
    /// `NoDeployableLiquidityAtSpot` for it is not accepted, and the hook does mint it.
    function test_zeroLiquidityAllowance_rejectsMintableAmountBelowDustBound() public {
        // Accumulate a small amount that still buys liquidity.
        handler.accumulate({projectIdSeed: 2, amount: 1000});
        (uint128 token0Liquidity, uint128 token1Liquidity) =
            handler.remintLiquidity({projectId: 2, projectAmount: 1000, terminalAmount: 0});
        assertGt(token0Liquidity + token1Liquidity, 0, "1,000 wei buys liquidity");

        // A skipped mint reporting this inventory would be a real failure, so the allowance refuses it.
        bytes memory skipped = abi.encodeWithSelector(
            JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot.selector, 0, 0, 1000, 0
        );
        assertFalse(
            handler.isZeroLiquidityRevert({
                reason: skipped, projectId: 2, projectInventory: 1000, terminalInventory: 0
            }),
            "a mintable amount is never an accepted zero-liquidity revert"
        );

        // The hook mints it.
        handler.deployPool(2);
        assertTrue(hook.hasDeployedPool(2), "the small amount deploys");
        assertEq(handler.unexpectedFailures(), 0, "no failure latched");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Deterministic: fees on BOTH live positions, collected standalone and by a recycle
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Distinct fees on the live ask and bid are each cut exactly (terminal side paid, project side forgiven)
    ///         by a standalone collection that leaves both positions' principal and both ledgers untouched: the
    ///         project-side fees are burned and the terminal remainders added to the project's balance. A second round
    ///         of distinct fees is then collected by a recycle with zero new accumulation, which routes them the same
    ///         way and re-mints exactly both positions' principal plus the ledgers. Claims stay exactly backed.
    function test_bothPositionsFees_collectThenRecycleWithoutNewTokens() public {
        // The seeded ask and bid, with the principal each holds by side.
        uint256 askId = hook.askTokenIdOf({projectId: 1, terminalToken: address(terminalToken)});
        uint256 bidId = hook.bidTokenIdOf({projectId: 1, terminalToken: address(terminalToken)});
        (uint256 askProject, uint256 askTerminal) = _sides(askId);
        (uint256 bidProject, uint256 bidTerminal) = _sides(bidId);
        assertGt(askProject, 0, "precondition: the ask holds project principal");
        assertGt(bidTerminal, 0, "precondition: the bid holds terminal principal");
        // The ledgers and claims before any fee moves.
        uint256 projectLedger = hook.accumulatedProjectTokens(1);
        uint256 terminalLedger = hook.accumulatedTerminalTokens({projectId: 1, terminalToken: address(terminalToken)});
        uint256 claims = hook.claimableFeeTokens(1);

        // Round 1: distinct fees on both ids, collected standalone.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        uint256[4] memory fees = [uint256(1.1e18), 2.3e18, 0.7e18, 4.9e18]; // ask project, ask terminal, bid ...
        handler.injectFees({
            projectIdSeed: 1,
            askFee0Seed: projectIsToken0 ? fees[0] : fees[1],
            askFee1Seed: projectIsToken0 ? fees[1] : fees[0],
            bidFee0Seed: projectIsToken0 ? fees[2] : fees[3],
            bidFee1Seed: projectIsToken0 ? fees[3] : fees[2]
        });
        // Snapshot the fee terminal and the supply so the collection's flows can be measured.
        uint256 payCalls = terminal.payCallCount();
        uint256 terminalHeld = terminalToken.balanceOf(address(terminal));
        uint256 supply = projectToken.totalSupply();
        handler.collectAndRouteLPFees({projectIdSeed: 1, feeSeed: 0});
        assertEq(handler.collectFeeCallCount(), 2, "standalone collection succeeded");

        // Each position's terminal-side fee pays exactly one cut, credited to the project's claims.
        assertEq(terminal.payCallCount(), payCalls + 2, "one terminal-side cut paid per position");
        uint256 cuts = _cut(fees[1]) + _cut(fees[3]);
        assertEq(hook.claimableFeeTokens(1), claims + cuts, "claims equal the two terminal-side cuts");
        // The claims are minted in the project token here (the fee project shares it), so supply nets them out.
        assertEq(supply + cuts - projectToken.totalSupply(), fees[0] + fees[2], "project fees burned in full");
        assertEq(
            terminalToken.balanceOf(address(terminal)) - terminalHeld,
            fees[1] + fees[3],
            "the terminal received the cuts and the remainders"
        );
        // A standalone collection leaves the ledgers, the position ids and their principal untouched.
        assertEq(hook.accumulatedProjectTokens(1), projectLedger, "the ask ledger is unchanged");
        assertEq(
            hook.accumulatedTerminalTokens({projectId: 1, terminalToken: address(terminalToken)}),
            terminalLedger,
            "the bid ledger unchanged"
        );
        assertEq(
            hook.askTokenIdOf({projectId: 1, terminalToken: address(terminalToken)}), askId, "collection keeps the ask"
        );
        assertEq(
            hook.bidTokenIdOf({projectId: 1, terminalToken: address(terminalToken)}), bidId, "collection keeps the bid"
        );
        (uint256 p, uint256 t) = _sides(askId);
        assertEq(p + t, askProject + askTerminal, "ask principal untouched");
        (p, t) = _sides(bidId);
        assertEq(p + t, bidProject + bidTerminal, "bid principal untouched");

        // Round 2: new distinct fees, collected by a recycle with no new reserved tokens.
        uint256[4] memory fees2 = [uint256(0.3e18), 1.9e18, 2.2e18, 0.6e18];
        handler.injectFees({
            projectIdSeed: 1,
            askFee0Seed: projectIsToken0 ? fees2[0] : fees2[1],
            askFee1Seed: projectIsToken0 ? fees2[1] : fees2[0],
            bidFee0Seed: projectIsToken0 ? fees2[2] : fees2[3],
            bidFee1Seed: projectIsToken0 ? fees2[3] : fees2[2]
        });
        // Snapshot the ledgers, flows and rounding ghosts so the recycle's effects can be measured.
        uint256 accumulatedBefore = hook.accumulatedProjectTokens(1);
        uint256 terminalBefore = hook.accumulatedTerminalTokens({projectId: 1, terminalToken: address(terminalToken)});
        uint256 cuts2 = _cut(fees2[1]) + _cut(fees2[3]);
        uint256 supply2 = projectToken.totalSupply();
        uint256 terminalHeld2 = terminalToken.balanceOf(address(terminal));
        uint256 projectRoundingBefore = handler.projectBurnRounding(1);
        uint256 terminalRoundingBefore = handler.terminalBurnRounding(1);
        handler.addLiquidity({projectIdSeed: 1, feeSeed: 0});
        assertEq(handler.recycleCallCount(), 2, "the zero-accumulation recycle succeeded");
        // The burns return the principal less V4's rounding, which stays in the pool.
        uint256 projectRounding = handler.projectBurnRounding(1) - projectRoundingBefore;
        uint256 terminalRounding = handler.terminalBurnRounding(1) - terminalRoundingBefore;

        // The recycle cuts both positions' fees and replaces both ids with fresh single-sided positions.
        assertEq(hook.claimableFeeTokens(1), claims + cuts + cuts2, "the recycle cut both positions' fees exactly");
        uint256 newAsk = hook.askTokenIdOf({projectId: 1, terminalToken: address(terminalToken)});
        uint256 newBid = hook.bidTokenIdOf({projectId: 1, terminalToken: address(terminalToken)});
        assertTrue(newAsk != askId && newAsk != bidId && newAsk != 0, "fresh ask");
        assertTrue(newBid != askId && newBid != bidId && newBid != 0 && newBid != newAsk, "fresh bid");
        (uint256 newAskProject, uint256 newAskTerminal) = _sides(newAsk);
        (uint256 newBidProject, uint256 newBidTerminal) = _sides(newBid);
        assertEq(newAskTerminal, 0, "the ask holds no terminal");
        assertEq(newBidProject, 0, "the bid holds no project token");
        // Every burned token, less the rounding left in the pool, is re-minted or back in its ledger.
        assertEq(
            newAskProject + hook.accumulatedProjectTokens(1),
            askProject + bidProject - projectRounding + accumulatedBefore,
            "every project token (principal + ledger) is in the ask or its ledger"
        );
        assertEq(
            newBidTerminal + hook.accumulatedTerminalTokens({projectId: 1, terminalToken: address(terminalToken)}),
            askTerminal + bidTerminal - terminalRounding + terminalBefore,
            "every terminal token (principal + ledger) is in the bid or its ledger"
        );
        // The recycle routes the second round's fees the same way as the standalone collection.
        assertEq(
            supply2 + cuts2 - projectToken.totalSupply(), fees2[0] + fees2[2], "the recycle burned the project fees"
        );
        assertEq(
            terminalToken.balanceOf(address(terminal)) - terminalHeld2,
            fees2[1] + fees2[3],
            "the recycle sent the cuts and remainders to the terminal"
        );

        // Claim backing and segregation: the hook holds exactly its ledgers plus the fee-token claims.
        uint256 projectBooks;
        uint256 terminalBooks;
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            projectBooks += hook.accumulatedProjectTokens(i) + hook.claimableFeeTokens(i);
            terminalBooks += hook.accumulatedTerminalTokens({projectId: i, terminalToken: address(terminalToken)});
        }
        assertEq(projectToken.balanceOf(address(hook)), projectBooks, "project ledgers plus claims exactly backed");
        assertEq(terminalToken.balanceOf(address(hook)), terminalBooks, "terminal ledgers exactly backed");
        assertEq(handler.expectedClaims(1), hook.claimableFeeTokens(1), "handler ghost agrees");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Invariant 1: Exact global backing per currency
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Nothing is donated in this campaign, so every balance is exactly its books: the hook holds its ledgers
    ///         plus the fee tokens it owes (which share the project token here), the PositionManager holds the live
    ///         principal plus uncollected fees plus the rounding past burns left in the pool, the shared terminal holds
    ///         exactly the independently computed cuts plus the fee remainders added to the projects' balances, and
    ///         the project token's supply is exactly what was minted less the fee remainders burned.
    /// @dev Catches tokens credited without arriving, ledgers erased while their tokens strand, and cuts that are
    ///      over- or under-paid.
    function invariant_exactGlobalBacking() public view {
        // The hook's books: every project's ledgers plus the fee-token claims it owes.
        uint256 hookProjectBooks;
        uint256 hookTerminalBooks;
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            hookProjectBooks += hook.accumulatedProjectTokens(i) + hook.claimableFeeTokens(i);
            hookTerminalBooks += hook.accumulatedTerminalTokens({projectId: i, terminalToken: address(terminalToken)});
        }
        // The PositionManager's books: live principal plus uncollected fees.
        (uint256 pmProjectBooks, uint256 pmTerminalBooks) = _positionManagerBooks();
        // Burns leave V4's rounding in the pool.
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            pmProjectBooks += handler.projectBurnRounding(i);
            pmTerminalBooks += handler.terminalBurnRounding(i);
        }

        // Each holder's balance equals its books exactly.
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
        // The fee flows that left the hook, summed from the handler's independent ghosts.
        (uint256 cuts, uint256 added, uint256 burned) = _feeOutflows();
        assertEq(
            terminalToken.balanceOf(address(terminal)),
            cuts + added,
            "INVARIANT VIOLATED: the terminal holds the cuts plus the added remainders"
        );
        // The fee project's claims are minted in the project token here (by the mock terminal's `pay`).
        assertEq(
            projectToken.totalSupply(),
            handler.projectTokensMinted() + cuts - burned,
            "INVARIANT VIOLATED: project token supply differs from mints less burned fees"
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
            // Nonzero when either the ask or the bid is set.
            uint256 tokenId = hook.askTokenIdOf({projectId: i, terminalToken: address(terminalToken)})
                | hook.bidTokenIdOf({projectId: i, terminalToken: address(terminalToken)});
            bool poolDeployed = hook.hasDeployedPool(i);

            // A set position id implies a deployed pool.
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
    ///         exactly what entered its books less what left them: every reserved token minted for it plus every
    ///         project-side fee injected, less the collected project-side fees burned (the cut is forgiven); and every
    ///         terminal-side fee injected, less the cuts and the remainders added to its balance.
    /// @dev Follows tokens through deploy, collection and recycle, catching any loss, cross-project leakage or value
    ///      creation (recycled principal is credited back exactly once).
    function invariant_exactPerProjectConservation() public view {
        // The address order picks which pool currency is the project token.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            // Start from the project's ledgers.
            uint256 projectBooks = hook.accumulatedProjectTokens(i);
            uint256 terminalBooks =
                hook.accumulatedTerminalTokens({projectId: i, terminalToken: address(terminalToken)});
            // Add each live position's principal and uncollected fees, sorted into project and terminal sides.
            uint256[2] memory ids = [
                hook.askTokenIdOf({projectId: i, terminalToken: address(terminalToken)}),
                hook.bidTokenIdOf({projectId: i, terminalToken: address(terminalToken)})
            ];
            for (uint256 j; j < 2; j++) {
                if (ids[j] == 0) continue;
                (,,,, uint256 locked0, uint256 locked1,) = positionManager._positions(ids[j]);
                uint256 amount0 = locked0 + positionManager.collectableAmount0(ids[j]);
                uint256 amount1 = locked1 + positionManager.collectableAmount1(ids[j]);
                projectBooks += projectIsToken0 ? amount0 : amount1;
                terminalBooks += projectIsToken0 ? amount1 : amount0;
            }
            // What a project's burns left in the pool as V4 rounding is still its tokens, though it cannot be
            // withdrawn.
            projectBooks += handler.projectBurnRounding(i);
            terminalBooks += handler.terminalBurnRounding(i);
            // Each side's books equal what entered them less what the fee routes sent out.
            assertEq(
                projectBooks,
                handler.totalMintedToHook(i) + handler.projectFeesInjected(i) - handler.projectFeesBurned(i),
                "INVARIANT VIOLATED: per-project project-token books differ from what entered them"
            );
            assertEq(
                terminalBooks,
                handler.terminalFeesInjected(i) + handler.terminalPayouts(i) - handler.expectedClaims(i)
                    - handler.terminalFeesAddedToBalance(i),
                "INVARIANT VIOLATED: per-project terminal-token books differ from payouts and fees net of cuts and adds"
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
            // The hook's claim ledger matches the handler's independent derivation exactly.
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
            uint256 askId = hook.askTokenIdOf({projectId: i, terminalToken: address(terminalToken)});
            uint256 bidId = hook.bidTokenIdOf({projectId: i, terminalToken: address(terminalToken)});

            // A deployed project holds at least one position, and an undeployed one holds none.
            if (hook.hasDeployedPool(i)) {
                assertTrue(askId != 0 || bidId != 0, "INVARIANT VIOLATED: deployed project holds no position");
            } else {
                assertEq(askId | bidId, 0, "INVARIANT VIOLATED: hasDeployedPool is false but a position id is set");
            }
            // A tracked ask is distinct from the bid, alive, and within one unit of rounding per currency.
            if (askId != 0) {
                assertNotEq(askId, bidId, "INVARIANT VIOLATED: ask and bid share an id");
                (,,,,,, bool askExists) = positionManager._positions(askId);
                assertTrue(askExists, "INVARIANT VIOLATED: tracked ask is not alive");
                _assertRoundingAtMostOne(askId);
                trackedLive++;
            }
            // A tracked bid is alive and within one unit of rounding per currency.
            if (bidId != 0) {
                (,,,,,, bool bidExists) = positionManager._positions(bidId);
                assertTrue(bidExists, "INVARIANT VIOLATED: tracked bid is not alive");
                _assertRoundingAtMostOne(bidId);
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
        // Each handler stage succeeded at least once.
        assertGt(handler.callCount(), 0, "no successful accumulation");
        assertGt(handler.collectFeeCallCount(), 0, "no successful fee collection");
        assertGt(handler.deployCallCount(), 0, "no successful deploy");
        assertGt(handler.recycleCallCount(), 0, "no successful recycle");
    }

    /// @notice No handler call failed without a justified error under a checked precondition.
    function invariant_noUnexpectedFailures() public view {
        // The latch stays at zero; on a failure the message is the revert data the handler kept.
        assertEq(handler.unexpectedFailures(), 0, vm.toString(handler.lastUnexpectedFailure()));
    }

    /// @notice Each run, beyond the seed, collects and recycles real (nonzero) injected fees successfully.
    function afterInvariant() public view {
        // The fuzzed calls add fee-moving collections and recycles beyond the seed's.
        assertGt(handler.feeCollectionCount(), seedFeeCollections, "no post-seed collection of nonzero fees");
        assertGt(handler.feeRecycleCount(), seedFeeRecycles, "no post-seed recycle of nonzero fees");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice A fresh mint at the frozen price locks its rounded-up cost and a burn returns its rounded-down
    /// principal, so each position's rounding is at most one unit per currency: anything larger is a ledger or model
    /// discrepancy, not rounding.
    /// @param tokenId The live position to check.
    function _assertRoundingAtMostOne(uint256 tokenId) internal view {
        // What burning the position at the live spot would leave in the pool, per currency.
        (uint256 rounding0, uint256 rounding1) = handler.positionRounding(tokenId);
        assertLe(rounding0, 1, "INVARIANT VIOLATED: token0 rounding above one unit");
        assertLe(rounding1, 1, "INVARIANT VIOLATED: token1 rounding above one unit");
    }

    /// @notice The fee project's cut of a terminal-side fee.
    /// @param amount The gross terminal-side fee.
    /// @return cut The part the fee project receives.
    function _cut(uint256 amount) internal pure returns (uint256 cut) {
        // The cut is the fee percent of the fee, out of 10,000, rounded down.
        cut = (amount * FEE_PERCENT) / 10_000;
    }

    /// @notice The fee-project cuts, terminal remainders added to balances, and project-side fees burned, summed.
    /// @return cuts The fee-project cuts across every project.
    /// @return added The terminal-token remainders added to every project's balance.
    /// @return burned The project-token fees burned across every project.
    function _feeOutflows() internal view returns (uint256 cuts, uint256 added, uint256 burned) {
        // Sum the handler's independent ghosts across the campaign's projects.
        for (uint256 i = 1; i <= handler.MAX_PROJECT_ID(); i++) {
            cuts += handler.expectedClaims(i);
            added += handler.terminalFeesAddedToBalance(i);
            burned += handler.projectFeesBurned(i);
        }
    }

    /// @notice The live principal and uncollected fees of every position the PositionManager holds, by side.
    /// @return projectSide The project tokens the live positions hold.
    /// @return terminalSide The terminal tokens the live positions hold.
    function _positionManagerBooks() internal view returns (uint256 projectSide, uint256 terminalSide) {
        // The address order picks which pool currency is the project token.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        for (uint256 id = 1; id < positionManager.nextTokenId(); id++) {
            // A burned position holds nothing.
            (,,,, uint256 locked0, uint256 locked1, bool exists) = positionManager._positions(id);
            if (!exists) continue;
            // Add its principal and uncollected fees, sorted into project and terminal sides.
            uint256 amount0 = locked0 + positionManager.collectableAmount0(id);
            uint256 amount1 = locked1 + positionManager.collectableAmount1(id);
            projectSide += projectIsToken0 ? amount0 : amount1;
            terminalSide += projectIsToken0 ? amount1 : amount0;
        }
    }

    /// @notice The principal position `tokenId` locked in the pool, sorted into project and terminal sides.
    /// @param tokenId The position to read.
    /// @return projectSide The project tokens the position locked.
    /// @return terminalSide The terminal tokens the position locked.
    function _sides(uint256 tokenId) internal view returns (uint256 projectSide, uint256 terminalSide) {
        // What the mint locked, per pool currency.
        (,,,, uint256 locked0, uint256 locked1,) = positionManager._positions(tokenId);
        // The address order picks which pool currency is the project token.
        (projectSide, terminalSide) =
            address(projectToken) < address(terminalToken) ? (locked0, locked1) : (locked1, locked0);
    }
}
