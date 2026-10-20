// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkDeployHelper} from "../helpers/ForkDeployHelper.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "../../src/interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {MockGeomeanOracle} from "../mock/MockGeomeanOracle.sol";
import {MockPoolManager} from "../mock/MockPoolManager.sol";
import {MockPositionManager} from "../mock/MockPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal Permit2 stand-in so the hook's Permit2 approvals work against the mock PositionManager.
contract IntegrationMockPermit2 {
    /// @notice Accepts any approval without recording it.
    /// @dev `transferFrom` spends the ERC-20 allowance the holder granted this contract, so approvals need no
    /// bookkeeping.
    function approve(address, address, uint160, uint48) external {}

    /// @notice Moves `amount` of `token` from `from` to `to`, spending the ERC-20 allowance `from` granted this
    /// contract.
    /// @param from The holder the tokens are pulled from.
    /// @param to The recipient of the tokens.
    /// @param amount The amount to move.
    /// @param token The token to move.
    function transferFrom(address from, address to, uint160 amount, address token) external {
        // Test mock: return value not checked intentionally.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token).transferFrom(from, to, amount);
    }
}

/// @notice Durable-intake regressions driven through the REAL `JBController.sendReservedTokensToSplitsOf`, the
/// production entry point whose try/catch (and pre-transfer of credits) motivated the durable-intake design.
contract DurableIntakeCoreIntegration is ForkDeployHelper {
    /// @notice The project that receives the hook's fee share.
    uint256 internal _feeProjectId;

    /// @notice The hook under test, a clone of a freshly deployed implementation.
    JBUniswapV4LPSplitHook internal _hook;

    /// @notice The spot-tracking oracle the hook's pools use.
    MockGeomeanOracle internal _oracle;

    /// @notice The mock Uniswap V4 PoolManager.
    MockPoolManager internal _poolManager;

    /// @notice The mock Uniswap V4 PositionManager.
    MockPositionManager internal _positionManager;

    /// @notice Accepts ETH sent to the test contract.
    receive() external payable {}

    /// @notice Deploys real JB core, mock Uniswap V4 and Permit2 infrastructure, a fee project, and the hook.
    function setUp() public {
        _deployJBCore();

        // Mock Uniswap V4 + Permit2 infra: these tests exercise the Core<->hook boundary, not Uniswap.
        _poolManager = new MockPoolManager();
        _positionManager = new MockPositionManager();
        _positionManager.setPoolManager(_poolManager);
        _oracle = new MockGeomeanOracle();
        _oracle.enableSpotTracking(IPoolManager(address(_poolManager)));
        vm.etch(address(PERMIT2), address(new IntegrationMockPermit2()).code);

        // The fee project gets an ERC-20 so payments to it mint claimable tokens.
        _feeProjectId = _launchProject({reservedPercent: 0, withHookSplit: false});
        vm.prank(multisig);
        jbController.deployERC20For({projectId: _feeProjectId, name: "Fee Token", symbol: "FEE", salt: bytes32(0)});

        // Deploy the implementation, clone it, and initialize the clone against the mocks.
        JBUniswapV4LPSplitHook hookImpl = new JBUniswapV4LPSplitHook({
            directory: address(jbDirectory),
            permissions: IJBPermissions(address(jbPermissions)),
            tokens: address(jbTokens),
            permit2: IAllowanceTransfer(address(PERMIT2)),
            suckerRegistry: IJBSuckerRegistry(address(0))
        });
        _hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));
        _hook.initialize({
            initialFeeProjectId: _feeProjectId,
            initialFeePercent: 3800,
            newPoolManager: IPoolManager(address(_poolManager)),
            newPositionManager: IPositionManager(address(_positionManager)),
            newOracleHook: IHooks(address(_oracle)),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });
    }

    // ─── Credits intake through the real Controller
    // ─────────────────────

    /// @notice Core transfers reserved CREDITS to the hook before the caught `processSplitWith` call. The hook must
    /// accept and account them: pending reserves clear, the credits sit at the hook, and the ledger represents them.
    function test_realCore_creditsIntake_accountsCredits() public {
        uint256 pid = _launchProject({reservedPercent: 5000, withHookSplit: true});
        // No ERC-20 is deployed: the reserved distribution lands as credits.

        // Mint with the reserved percent so half the mint is pending reserves.
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: 100e18, beneficiary: multisig, memo: "", useReservedPercent: true
        });
        assertEq(jbController.pendingReservedTokenBalanceOf(pid), 50e18, "precondition: pending reserves");

        // Distribute the reserves through the real controller.
        jbController.sendReservedTokensToSplitsOf(pid);

        // The credits leave the controller's pending balance, sit at the hook, and are ledgered.
        assertEq(jbController.pendingReservedTokenBalanceOf(pid), 0, "pending reserves must clear");
        assertEq(
            jbTokens.creditBalanceOf({holder: address(_hook), projectId: pid}), 50e18, "the credits sit at the hook"
        );
        assertEq(_hook.accumulatedProjectCredits(pid), 50e18, "the ledger must represent the credits");
    }

    /// @notice The accounted credits stay claimable: once the project tokenizes and gets paid, the permissionless
    /// deploy claims exactly the accounted credits into ERC-20s and deploys them.
    function test_realCore_creditsThenTokenize_deployClaimsCredits() public {
        // Land the reserved distribution at the hook as credits.
        uint256 pid = _launchProject({reservedPercent: 5000, withHookSplit: true});
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: 100e18, beneficiary: multisig, memo: "", useReservedPercent: true
        });
        jbController.sendReservedTokensToSplitsOf(pid);
        assertEq(_hook.accumulatedProjectCredits(pid), 50e18, "precondition: accounted credits");

        // Tokenize the project and fund its terminal so a pool can deploy.
        vm.prank(multisig);
        jbController.deployERC20For({projectId: pid, name: "Project Token", symbol: "TOK", salt: bytes32(0)});
        _payProject({pid: pid, amount: 10 ether});

        // Anyone can deploy the pool, which claims the credits first.
        _hook.deployPool(pid);

        // The pool deploys and the credit ledger and balance are both fully consumed.
        assertTrue(
            _hook.isPoolDeployed({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}),
            "the pool should deploy from claimed credits"
        );
        assertEq(_hook.accumulatedProjectCredits(pid), 0, "the credit ledger should be consumed");
        assertEq(
            jbTokens.creditBalanceOf({holder: address(_hook), projectId: pid}),
            0,
            "the credits should be claimed exactly"
        );
    }

    // ─── ERC-20 intake + inline automation through the real Controller ──

    /// @notice With a wired project and enough gas, the real reserved distribution deploys the pool inline.
    function test_realCore_inlineAutomation_deploysPool() public {
        // Accrue pending reserves on a tokenized hook-split project.
        (uint256 pid,) = _launchTokenizedProject();
        _mintReserved({pid: pid, amount: 100e18});

        // The distribution reaches the hook with enough gas for the inline deploy.
        jbController.sendReservedTokensToSplitsOf(pid);

        // The pool, its pairing and its first position all exist after the distribution.
        assertEq(jbController.pendingReservedTokenBalanceOf(pid), 0, "pending reserves must clear");
        assertTrue(
            _hook.isPoolDeployed({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}),
            "the pool should deploy inline"
        );
        assertEq(_hook.deployedTerminalTokenOf(pid), JBConstants.NATIVE_TOKEN, "the pairing should be recorded");
        assertTrue(
            _hook.askTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}) != 0,
            "a position should exist"
        );
    }

    /// @notice A downstream failure (un-warmed TWAP on a pre-initialized pool) cannot touch the accepted inventory:
    /// the real distribution succeeds, the exact ERC-20 amount stays at the hook, and the permissionless retry
    /// deploys the retained amount once the oracle warms up.
    function test_realCore_twapFailure_retainsAndRetries() public {
        (uint256 pid, IJBToken token) = _launchTokenizedProject();

        // Pre-initialize the pool at a mid-corridor price so the deploy attempt runs the TWAP guard, and make the
        // oracle report insufficient history.
        _positionManager.initializePool({
            key: _poolKey(pid, address(token)),
            sqrtPriceX96: _midCorridorSqrtPrice({pid: pid, projectToken: address(token)})
        });
        _oracle.setShouldRevert(true);

        _mintReserved({pid: pid, amount: 100e18});
        // The pay in `_launchTokenizedProject` also accrued pending reserves; the whole pending amount distributes.
        uint256 reservedAmount = jbController.pendingReservedTokenBalanceOf(pid);
        jbController.sendReservedTokensToSplitsOf(pid);

        // The distribution succeeds while the inline deploy fails, and the hook keeps the exact amount it accepted.
        assertEq(jbController.pendingReservedTokenBalanceOf(pid), 0, "the distribution must succeed");
        assertFalse(
            _hook.isPoolDeployed({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}),
            "the inline attempt must have failed"
        );
        assertEq(_hook.accumulatedProjectTokens(pid), reservedAmount, "the exact ERC-20 amount must be retained");
        assertEq(IERC20(address(token)).balanceOf(address(_hook)), reservedAmount, "the tokens must sit at the hook");

        // Repair the downstream condition, then anyone can process the retained inventory, exactly once.
        _oracle.setShouldRevert(false);
        _hook.deployPool(pid);
        assertTrue(
            _hook.isPoolDeployed({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}), "the retry should deploy"
        );
        // The retained amount is deployed exactly once: the ask holds it all but V4 rounding, which stays ledgered.
        (,,,, uint256 askEth, uint256 askProject,) =
            _positionManager._positions(_hook.askTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}));
        uint256 ledger = _hook.accumulatedProjectTokens(pid);
        assertEq(askEth, 0, "the ask holds no ETH");
        assertEq(askProject + ledger, reservedAmount, "the retained amount should be deployed");
        assertEq(IERC20(address(token)).balanceOf(address(_hook)), ledger, "the hook holds only the ledgered rounding");
    }

    // ─── Gas starvation
    // ─────────────────────────────────────────────────

    /// @notice Property from the durable-intake design: there is NO gas budget at which the real
    /// `sendReservedTokensToSplitsOf` succeeds while a healthy hook's split is reflected in neither the hook ledger
    /// nor an LP position. Sweeps coarsely, binary-searches the all-revert/success boundary, then checks every gas
    /// value around it. The numeric boundary is harness-specific; only the property is asserted.
    function test_realCore_gasStarvation_noSilentSkipBand() public {
        // Accrue pending reserves and record the amount the hook must represent on any success.
        (uint256 pid,) = _launchTokenizedProject();
        _mintReserved({pid: pid, amount: 100e18});
        uint256 reservedAmount = jbController.pendingReservedTokenBalanceOf(pid);

        // Coarse sweep up to 5M gas.
        uint256 lastRevert = 50_000;
        uint256 firstSuccess = 0;
        for (uint256 gasBudget = 50_000; gasBudget <= 5_000_000; gasBudget += 50_000) {
            bool ok = _tryDistribute({pid: pid, gasBudget: gasBudget, reservedAmount: reservedAmount});
            // Track the first succeeding budget, and require that no revert appears above it.
            if (ok && firstSuccess == 0) firstSuccess = gasBudget;
            if (!ok) {
                assertEq(firstSuccess, 0, "no revert budget above a success budget in the coarse sweep");
                lastRevert = gasBudget;
            }
        }
        assertTrue(firstSuccess != 0, "the sweep must find a succeeding budget");

        // Binary-search the exact boundary between `lastRevert` and `firstSuccess`.
        uint256 lo = lastRevert;
        uint256 hi = firstSuccess;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_tryDistribute({pid: pid, gasBudget: mid, reservedAmount: reservedAmount})) hi = mid;
            else lo = mid;
        }

        // Inspect every gas value around the boundary.
        uint256 from = hi > 64 ? hi - 64 : 1;
        for (uint256 gasBudget = from; gasBudget <= hi + 64; gasBudget++) {
            _tryDistribute({pid: pid, gasBudget: gasBudget, reservedAmount: reservedAmount});
        }
        // Log the boundary for diagnosis; it is not asserted.
        emit log_named_uint("all-revert/success gas boundary", hi);
    }

    // ─── Automation budget
    // ─────────────────────────────────────────────────

    /// @notice The real reserved distribution with the hook first and 20 ordinary recipients after it, where the
    /// hook's inline attempt exhausts its budget: with the budget plus the controller's own needs, the distribution
    /// finishes, every later recipient is minted its share, and the hook keeps its accepted tokens.
    function test_realCore_automationBudget_laterReservedRecipientsPaid() public {
        // Split the reserved group evenly: the hook first, then 20 plain beneficiaries.
        uint256 count = 21;
        uint32 percent = JBConstants.SPLITS_TOTAL_PERCENT / 21;
        JBSplit[] memory splits = new JBSplit[](count);
        splits[0] = _hookSplit(percent);
        for (uint256 i = 1; i < count; i++) {
            splits[i] = JBSplit({
                percent: percent,
                projectId: 0,
                beneficiary: payable(vm.addr(0xB0B0000 + i)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            });
        }
        // Launch, tokenize and fund the project.
        uint256 pid = _launchProjectWithSplits({reservedPercent: 5000, splits: splits});
        vm.prank(multisig);
        IJBToken token =
            jbController.deployERC20For({projectId: pid, name: "Project Token", symbol: "TOK", salt: bytes32(0)});
        _payProject({pid: pid, amount: 10 ether});

        // Pre-initialize the pool so the deploy attempt reads the TWAP, and make that read burn all its gas.
        _positionManager.initializePool({
            key: _poolKey(pid, address(token)),
            sqrtPriceX96: _midCorridorSqrtPrice({pid: pid, projectToken: address(token)})
        });
        _oracle.setBurnGas(true);
        _mintReserved({pid: pid, amount: 100e18});

        // The hook reports the failed inline attempt, and the distribution still finishes within the gas cap.
        vm.expectEmit(true, false, false, false, address(_hook));
        emit IJBUniswapV4LPSplitHook.LiquidityAutomationFailed({
            projectId: pid, reasonSelector: bytes4(0), caller: address(jbController)
        });
        jbController.sendReservedTokensToSplitsOf{gas: 3_500_000}(pid);

        // The distribution clears, the hook keeps its tokens, and every later recipient is paid.
        assertEq(jbController.pendingReservedTokenBalanceOf(pid), 0, "the distribution finished");
        assertFalse(
            _hook.isPoolDeployed({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}), "the attempt failed"
        );
        assertGt(_hook.accumulatedProjectTokens(pid), 0, "the hook keeps its accepted tokens");
        for (uint256 i = 1; i < count; i++) {
            assertGt(IERC20(address(token)).balanceOf(splits[i].beneficiary), 0, "every later recipient is paid");
        }
    }

    // ─── Internal transactions
    // ──────────────────────────────────────────────

    /// @notice Launch a project accepting native ETH, optionally routing 100% of its reserved group to the hook.
    /// @param reservedPercent The ruleset's reserved percent.
    /// @param withHookSplit Whether the reserved group routes entirely to the hook.
    /// @return id The launched project's ID.
    function _launchProject(uint16 reservedPercent, bool withHookSplit) internal returns (uint256 id) {
        // An empty split array launches the project with no reserved group.
        JBSplit[] memory splits;
        if (withHookSplit) {
            splits = new JBSplit[](1);
            splits[0] = _hookSplit(JBConstants.SPLITS_TOTAL_PERCENT);
        }
        id = _launchProjectWithSplits({reservedPercent: reservedPercent, splits: splits});
    }

    /// @notice Launch a project accepting native ETH whose reserved group is `splits` (none when empty).
    /// @param reservedPercent The ruleset's reserved percent.
    /// @param splits The reserved group's splits.
    /// @return id The launched project's ID.
    function _launchProjectWithSplits(uint16 reservedPercent, JBSplit[] memory splits) internal returns (uint256 id) {
        // A taxed, owner-mintable ruleset priced in ETH, so tests can mint reserves and the hook can price a corridor.
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: 4000,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        // One open-ended ruleset with a fixed weight and no fund access limits.
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 1_000_000e18;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        // Group 1 is the reserved-token group; leave it empty when no splits are given.
        if (splits.length != 0) {
            JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
            splitGroups[0] = JBSplitGroup({groupId: 1, splits: splits});
            rulesetConfigs[0].splitGroups = splitGroups;
        } else {
            rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        }

        // The real multi-terminal accepts native ETH.
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        // The multisig owns the project so it can mint and deploy the ERC-20.
        id = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @notice Launch a hook-split project, deploy its ERC-20, and fund its terminal.
    /// @return pid The launched project's ID.
    /// @return token The project's ERC-20.
    function _launchTokenizedProject() internal returns (uint256 pid, IJBToken token) {
        // Half of every mint is reserved, and all of the reserves route to the hook.
        pid = _launchProject({reservedPercent: 5000, withHookSplit: true});
        vm.prank(multisig);
        token = jbController.deployERC20For({projectId: pid, name: "Project Token", symbol: "TOK", salt: bytes32(0)});
        // Fund the terminal so the project has surplus behind its cash-out floor.
        _payProject({pid: pid, amount: 10 ether});
    }

    /// @notice Mint `amount` with the reserved percent applied, leaving half as pending reserves.
    /// @param pid The project to mint for.
    /// @param amount The total token count to mint, including the reserved share.
    function _mintReserved(uint256 pid, uint256 amount) internal {
        // The owner mints so the reserved percent splits off the pending reserves.
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: amount, beneficiary: multisig, memo: "", useReservedPercent: true
        });
    }

    /// @notice Pay `amount` of native ETH into the project's terminal.
    /// @param pid The project to pay.
    /// @param amount The ETH amount to pay.
    function _payProject(uint256 pid, uint256 amount) internal {
        // Pay from the test contract with the multisig as the token beneficiary.
        jbMultiTerminal.pay{value: amount}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    /// @notice Run one distribution attempt at `gasBudget` on a snapshot, asserting the durable-intake property:
    /// either the whole call reverts, or the pending reserves cleared AND the split is represented (ledger or LP
    /// position). Returns whether the call succeeded.
    /// @param pid The project whose reserves are distributed.
    /// @param gasBudget The gas forwarded to the distribution.
    /// @param reservedAmount The pending reserve amount the hook's ledger must hold if no position was made.
    /// @return ok Whether the distribution call succeeded.
    function _tryDistribute(uint256 pid, uint256 gasBudget, uint256 reservedAmount) internal returns (bool ok) {
        // Each attempt starts from the same state.
        uint256 snapshot = vm.snapshotState();

        // A low-level call lets an out-of-gas revert surface as `ok == false` instead of failing the test.
        (ok,) = address(jbController).call{gas: gasBudget}(
            abi.encodeCall(jbController.sendReservedTokensToSplitsOf, (pid))
        );

        // A success must clear the reserves and leave the split in the ledger or in a position.
        if (ok) {
            assertEq(jbController.pendingReservedTokenBalanceOf(pid), 0, "success must clear pending reserves");
            bool represented = _hook.accumulatedProjectTokens(pid) == reservedAmount
                || _hook.askTokenIdOf({projectId: pid, terminalToken: JBConstants.NATIVE_TOKEN}) != 0;
            assertTrue(represented, "success must leave the split represented in the ledger or an LP position");
        }

        vm.revertToState(snapshot);
    }

    // ─── Internal views
    // ─────────────────────────────────────────────────────

    /// @notice A reserved split to the hook for `percent`.
    /// @param percent The split's share of the reserved group.
    /// @return split The split routing that share to the hook.
    function _hookSplit(uint32 percent) internal view returns (JBSplit memory split) {
        // A split with a hook routes its share to the hook's `processSplitWith`.
        return JBSplit({
            percent: percent,
            projectId: 0,
            beneficiary: payable(address(0)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(_hook))
        });
    }

    /// @notice A sqrt price in the middle of the project's economic corridor (always inside the band).
    /// @param pid The project whose corridor is computed.
    /// @param projectToken The project's ERC-20.
    /// @return sqrtPriceX96 The corridor's midpoint sqrt price, as a Q64.96 fixed point number.
    function _midCorridorSqrtPrice(uint256 pid, address projectToken) internal view returns (uint160 sqrtPriceX96) {
        // Compute the corridor the hook would use for the native pair under the current ruleset.
        (JBRuleset memory ruleset,) = jbController.currentRulesetOf(pid);
        (int24 lower, int24 upper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(address(jbDirectory)),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: pid,
            terminalToken: JBConstants.NATIVE_TOKEN,
            projectToken: projectToken,
            controller: address(jbController),
            ruleset: ruleset
        });
        // The tick midway between the bounds is inside the corridor.
        return TickMath.getSqrtPriceAtTick((lower + upper) / 2);
    }

    /// @notice The pool key the hook would build for a project's native-ETH pool.
    /// @param projectToken The project's ERC-20.
    /// @return key The pool key, with currencies ordered by address.
    function _poolKey(uint256, address projectToken) internal view returns (PoolKey memory key) {
        Currency terminalCurrency = Currency.wrap(address(0)); // native sentinel maps to address(0)
        Currency projectCurrency = Currency.wrap(projectToken);
        // Uniswap V4 orders currencies by address.
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);
        // Match the hook's fee, spacing and oracle so the key identifies the hook's pool.
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: _hook.POOL_FEE(),
            tickSpacing: _hook.TICK_SPACING(),
            hooks: IHooks(address(_oracle))
        });
    }
}
