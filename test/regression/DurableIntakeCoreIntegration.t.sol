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
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {MockGeomeanOracle} from "../mock/MockGeomeanOracle.sol";
import {MockPoolManager} from "../mock/MockPoolManager.sol";
import {MockPositionManager} from "../mock/MockPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal Permit2 stand-in so the hook's Permit2 approvals work against the mock PositionManager.
contract IntegrationMockPermit2 {
    function approve(address, address, uint160, uint48) external {}

    function transferFrom(address from, address to, uint160 amount, address token) external {
        // Test mock: return value not checked intentionally.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token).transferFrom(from, to, amount);
    }
}

/// @notice Durable-intake regressions driven through the REAL `JBController.sendReservedTokensToSplitsOf` — the
/// production entry point whose try/catch (and pre-transfer of credits) motivated the durable-intake design.
contract DurableIntakeCoreIntegration is ForkDeployHelper {
    JBUniswapV4LPSplitHook hook;
    MockPoolManager poolManager;
    MockPositionManager positionManager;
    MockGeomeanOracle oracle;
    uint256 feeProjectId;

    receive() external payable {}

    function setUp() public {
        _deployJBCore();

        // Mock Uniswap V4 + Permit2 infra: these tests exercise the Core<->hook boundary, not Uniswap.
        poolManager = new MockPoolManager();
        positionManager = new MockPositionManager();
        positionManager.setPoolManager(poolManager);
        oracle = new MockGeomeanOracle();
        oracle.enableSpotTracking(IPoolManager(address(poolManager)));
        vm.etch(address(PERMIT2), address(new IntegrationMockPermit2()).code);

        feeProjectId = _launchProject({reservedPercent: 0, withHookSplit: false});
        vm.prank(multisig);
        jbController.deployERC20For(feeProjectId, "Fee Token", "FEE", bytes32(0));

        JBUniswapV4LPSplitHook hookImpl = new JBUniswapV4LPSplitHook(
            address(jbDirectory),
            IJBPermissions(address(jbPermissions)),
            address(jbTokens),
            IAllowanceTransfer(address(PERMIT2)),
            IJBSuckerRegistry(address(0))
        );
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));
        hook.initialize({
            initialFeeProjectId: feeProjectId,
            initialFeePercent: 3800,
            newPoolManager: IPoolManager(address(poolManager)),
            newPositionManager: IPositionManager(address(positionManager)),
            newOracleHook: IHooks(address(oracle)),
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

        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: 100e18, beneficiary: multisig, memo: "", useReservedPercent: true
        });
        assertEq(jbController.pendingReservedTokenBalanceOf(pid), 50e18, "precondition: pending reserves");

        jbController.sendReservedTokensToSplitsOf(pid);

        assertEq(jbController.pendingReservedTokenBalanceOf(pid), 0, "pending reserves must clear");
        assertEq(jbTokens.creditBalanceOf(address(hook), pid), 50e18, "the credits sit at the hook");
        assertEq(hook.accumulatedProjectCredits(pid), 50e18, "the ledger must represent the credits");
    }

    /// @notice The accounted credits stay claimable: once the project tokenizes and gets paid, the permissionless
    /// deploy claims exactly the accounted credits into ERC-20s and deploys them.
    function test_realCore_creditsThenTokenize_deployClaimsCredits() public {
        uint256 pid = _launchProject({reservedPercent: 5000, withHookSplit: true});
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: 100e18, beneficiary: multisig, memo: "", useReservedPercent: true
        });
        jbController.sendReservedTokensToSplitsOf(pid);
        assertEq(hook.accumulatedProjectCredits(pid), 50e18, "precondition: accounted credits");

        vm.prank(multisig);
        jbController.deployERC20For(pid, "Project Token", "TOK", bytes32(0));
        _payProject(pid, 10 ether);

        hook.deployPool(pid);

        assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "the pool should deploy from claimed credits");
        assertEq(hook.accumulatedProjectCredits(pid), 0, "the credit ledger should be consumed");
        assertEq(jbTokens.creditBalanceOf(address(hook), pid), 0, "the credits should be claimed exactly");
    }

    // ─── ERC-20 intake + inline automation through the real Controller ──

    /// @notice With a wired project and enough gas, the real reserved distribution deploys the pool inline.
    function test_realCore_inlineAutomation_deploysPool() public {
        (uint256 pid,) = _launchTokenizedProject();
        _mintReserved(pid, 100e18);

        jbController.sendReservedTokensToSplitsOf(pid);

        assertEq(jbController.pendingReservedTokenBalanceOf(pid), 0, "pending reserves must clear");
        assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "the pool should deploy inline");
        assertEq(hook.deployedTerminalTokenOf(pid), JBConstants.NATIVE_TOKEN, "the pairing should be recorded");
        assertTrue(hook.askTokenIdOf(pid, JBConstants.NATIVE_TOKEN) != 0, "a position should exist");
    }

    /// @notice A downstream failure (un-warmed TWAP on a pre-initialized pool) cannot touch the accepted inventory:
    /// the real distribution succeeds, the exact ERC-20 amount stays at the hook, and the permissionless retry
    /// deploys the retained amount once the oracle warms up.
    function test_realCore_twapFailure_retainsAndRetries() public {
        (uint256 pid, IJBToken token) = _launchTokenizedProject();

        // Pre-initialize the pool at a mid-corridor price so the deploy attempt runs the TWAP guard, and make the
        // oracle report insufficient history.
        positionManager.initializePool(_poolKey(pid, address(token)), _midCorridorSqrtPrice(pid, address(token)));
        oracle.setShouldRevert(true);

        _mintReserved(pid, 100e18);
        // The pay in `_launchTokenizedProject` also accrued pending reserves; the whole pending amount distributes.
        uint256 reservedAmount = jbController.pendingReservedTokenBalanceOf(pid);
        jbController.sendReservedTokensToSplitsOf(pid);

        assertEq(jbController.pendingReservedTokenBalanceOf(pid), 0, "the distribution must succeed");
        assertFalse(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "the inline attempt must have failed");
        assertEq(hook.accumulatedProjectTokens(pid), reservedAmount, "the exact ERC-20 amount must be retained");
        assertEq(IERC20(address(token)).balanceOf(address(hook)), reservedAmount, "the tokens must sit at the hook");

        // Repair the downstream condition, then anyone can process the retained inventory — exactly once.
        oracle.setShouldRevert(false);
        hook.deployPool(pid);
        assertTrue(hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN), "the retry should deploy");
        assertEq(hook.accumulatedProjectTokens(pid), 0, "the retained amount should be deployed");
    }

    // ─── Gas starvation
    // ─────────────────────────────────────────────────

    /// @notice Property from the durable-intake design: there is NO gas budget at which the real
    /// `sendReservedTokensToSplitsOf` succeeds while a healthy hook's split is reflected in neither the hook ledger
    /// nor an LP position. Sweeps coarsely, binary-searches the all-revert/success boundary, then checks every gas
    /// value around it. The numeric boundary is harness-specific; only the property is asserted.
    function test_realCore_gasStarvation_noSilentSkipBand() public {
        (uint256 pid,) = _launchTokenizedProject();
        _mintReserved(pid, 100e18);
        uint256 reservedAmount = jbController.pendingReservedTokenBalanceOf(pid);

        // Coarse sweep up to 5M gas.
        uint256 lastRevert = 50_000;
        uint256 firstSuccess = 0;
        for (uint256 gasBudget = 50_000; gasBudget <= 5_000_000; gasBudget += 50_000) {
            bool ok = _tryDistribute(pid, gasBudget, reservedAmount);
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
            if (_tryDistribute(pid, mid, reservedAmount)) hi = mid;
            else lo = mid;
        }

        // Inspect every gas value around the boundary.
        uint256 from = hi > 64 ? hi - 64 : 1;
        for (uint256 gasBudget = from; gasBudget <= hi + 64; gasBudget++) {
            _tryDistribute(pid, gasBudget, reservedAmount);
        }
        emit log_named_uint("all-revert/success gas boundary", hi);
    }

    /// @notice Run one distribution attempt at `gasBudget` on a snapshot, asserting the durable-intake property:
    /// either the whole call reverts, or the pending reserves cleared AND the split is represented (ledger or LP
    /// position). Returns whether the call succeeded.
    function _tryDistribute(uint256 pid, uint256 gasBudget, uint256 reservedAmount) internal returns (bool ok) {
        uint256 snapshot = vm.snapshotState();

        (ok,) = address(jbController).call{gas: gasBudget}(
            abi.encodeCall(jbController.sendReservedTokensToSplitsOf, (pid))
        );

        if (ok) {
            assertEq(jbController.pendingReservedTokenBalanceOf(pid), 0, "success must clear pending reserves");
            bool represented = hook.accumulatedProjectTokens(pid) == reservedAmount
                || hook.askTokenIdOf(pid, JBConstants.NATIVE_TOKEN) != 0;
            assertTrue(represented, "success must leave the split represented in the ledger or an LP position");
        }

        vm.revertToState(snapshot);
    }

    // ─── Helpers
    // ────────────────────────────────────────────────────────

    /// @notice Launch a project accepting native ETH, optionally routing 100% of its reserved group to the hook.
    function _launchProject(uint16 reservedPercent, bool withHookSplit) internal returns (uint256 id) {
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

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 1_000_000e18;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        if (withHookSplit) {
            JBSplit[] memory splits = new JBSplit[](1);
            splits[0] = JBSplit({
                percent: JBConstants.SPLITS_TOTAL_PERCENT,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(hook))
            });
            JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
            splitGroups[0] = JBSplitGroup({groupId: 1, splits: splits});
            rulesetConfigs[0].splitGroups = splitGroups;
        } else {
            rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        }

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        id = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @notice Launch a hook-split project, deploy its ERC-20, and fund its terminal.
    function _launchTokenizedProject() internal returns (uint256 pid, IJBToken token) {
        pid = _launchProject({reservedPercent: 5000, withHookSplit: true});
        vm.prank(multisig);
        token = jbController.deployERC20For(pid, "Project Token", "TOK", bytes32(0));
        _payProject(pid, 10 ether);
    }

    /// @notice Mint `amount` with the reserved percent applied, leaving half as pending reserves.
    function _mintReserved(uint256 pid, uint256 amount) internal {
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: amount, beneficiary: multisig, memo: "", useReservedPercent: true
        });
    }

    function _payProject(uint256 pid, uint256 amount) internal {
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

    /// @notice The pool key the hook would build for a project's native-ETH pool.
    function _poolKey(uint256, address projectToken) internal view returns (PoolKey memory key) {
        Currency terminalCurrency = Currency.wrap(address(0)); // native sentinel maps to address(0)
        Currency projectCurrency = Currency.wrap(projectToken);
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: IHooks(address(oracle))
        });
    }

    /// @notice A sqrt price in the middle of the project's economic corridor (always inside the band).
    function _midCorridorSqrtPrice(uint256 pid, address projectToken) internal view returns (uint160 sqrtPriceX96) {
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
        return TickMath.getSqrtPriceAtTick((lower + upper) / 2);
    }
}
