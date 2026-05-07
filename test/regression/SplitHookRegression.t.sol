// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract PausingCreditController {
    bool public paused;

    function setPaused(bool value) external {
        paused = value;
    }

    function transferCreditsFrom(address, uint256, address, uint256) external view {
        require(!paused, "CREDITS_PAUSED");
    }
}

contract BurningController {
    address public pricesContract;

    mapping(uint256 projectId => uint256 weight) public weights;
    mapping(uint256 projectId => uint16 reservedPercent) public reservedPercents;
    mapping(uint256 projectId => uint32 baseCurrency) public baseCurrencies;
    mapping(uint256 projectId => MockERC20 token) public tokens;

    function setPrices(address value) external {
        pricesContract = value;
    }

    function setWeight(uint256 projectId, uint256 value) external {
        weights[projectId] = value;
    }

    function setReservedPercent(uint256 projectId, uint16 value) external {
        reservedPercents[projectId] = value;
    }

    function setBaseCurrency(uint256 projectId, uint32 value) external {
        baseCurrencies[projectId] = value;
    }

    function setProjectToken(uint256 projectId, MockERC20 token) external {
        tokens[projectId] = token;
    }

    function PRICES() external view returns (address) {
        return pricesContract;
    }

    function currentRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        uint32 baseCurr = baseCurrencies[projectId];
        if (baseCurr == 0) baseCurr = 1;

        metadata = JBRulesetMetadata({
            reservedPercent: reservedPercents[projectId],
            cashOutTaxRate: 0,
            baseCurrency: baseCurr,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: uint112(weights[projectId]),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadataResolver.packRulesetMetadata(metadata)
        });
    }

    function burnTokensOf(address holder, uint256 projectId, uint256 amount, string calldata) external {
        MockERC20 token = tokens[projectId];
        if (address(token) != address(0) && amount != 0) token.burn(holder, amount);
    }
}

contract MintThenReenterFeeTerminal {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    JBUniswapV4LPSplitHook public immutable hook;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    MockERC20 public immutable feeProjectToken;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable reentryProjectId;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable terminalToken;

    bool internal _entered;

    constructor(
        JBUniswapV4LPSplitHook _hook,
        MockERC20 _feeProjectToken,
        uint256 _reentryProjectId,
        address _terminalToken
    ) {
        hook = _hook;
        feeProjectToken = _feeProjectToken;
        reentryProjectId = _reentryProjectId;
        terminalToken = _terminalToken;
    }

    function pay(
        uint256,
        address token,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        returns (uint256 beneficiaryTokenCount)
    {
        if (amount > 0 && token != address(0x000000000000000000000000000000000000EEEe)) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }

        beneficiaryTokenCount = amount;
        if (beneficiaryTokenCount != 0) feeProjectToken.mint(beneficiary, beneficiaryTokenCount);

        if (!_entered) {
            _entered = true;
            hook.collectAndRouteLPFees(reentryProjectId, terminalToken);
            _entered = false;
        }
    }

    function accountingContextForTokenOf(uint256, address token) external pure returns (JBAccountingContext memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

contract RegressionRegression is LPSplitHookV4TestBase {
    /// @notice Verifies that a paused credit controller does NOT block ERC-20 fee token claims.
    /// The independent try-catch blocks allow each claim path to succeed or fail independently.
    function test_regression_claimFeeTokens_pausedCreditsDoNotBlockERC20Claims() public {
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));

        // Phase 1: accumulate credits (fee project has no ERC-20).
        jbTokens.setToken(FEE_PROJECT_ID, address(0));
        terminal.setProjectToken(FEE_PROJECT_ID, address(0));

        positionManager.setCollectableFees(tokenId, 100e18, 100e18);
        projectToken.mint(address(positionManager), 100e18);
        terminalToken.mint(address(positionManager), 100e18);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 creditClaim = hook.claimableFeeCredits(PROJECT_ID);
        assertGt(creditClaim, 0, "precondition: credits should accrue when fee project has no ERC20");

        // Phase 2: accumulate ERC-20 fee tokens (fee project now has ERC-20).
        jbTokens.setToken(FEE_PROJECT_ID, address(feeProjectToken));
        terminal.setProjectToken(FEE_PROJECT_ID, address(feeProjectToken));

        positionManager.setCollectableFees(tokenId, 100e18, 100e18);
        projectToken.mint(address(positionManager), 100e18);
        terminalToken.mint(address(positionManager), 100e18);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 tokenClaim = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(tokenClaim, 0, "precondition: ERC20 claims should accrue after fee token exists");

        // Pause credits — this should NOT block ERC-20 claims.
        PausingCreditController pausing = new PausingCreditController();
        pausing.setPaused(true);
        _setDirectoryController(FEE_PROJECT_ID, address(pausing));

        // Claim should succeed (ERC-20 portion) without reverting.
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);

        // ERC-20 tokens were claimed successfully.
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "ERC-20 claims should be zeroed after claim");
        assertEq(feeProjectToken.balanceOf(user), tokenClaim, "user should receive ERC-20 fee tokens");

        // Credits remain unclaimed (credit controller is paused, caught by try-catch).
        assertEq(hook.claimableFeeCredits(PROJECT_ID), creditClaim, "credits should remain claimable for retry");
    }

    /// @notice Verifies that the pre-increment pattern in _routeFeesToProject protects freshly minted
    /// fee tokens from being burned by a re-entrant collectAndRouteLPFees call.
    function test_regression_feePayReentrancy_preIncrementProtectsFeeTokens() public {
        BurningController burning = new BurningController();
        burning.setPrices(address(prices));
        burning.setWeight(PROJECT_ID, DEFAULT_WEIGHT);
        burning.setWeight(FEE_PROJECT_ID, 100e18);
        burning.setReservedPercent(PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        burning.setBaseCurrency(PROJECT_ID, 1);
        burning.setBaseCurrency(FEE_PROJECT_ID, 1);
        burning.setProjectToken(PROJECT_ID, projectToken);
        burning.setProjectToken(FEE_PROJECT_ID, feeProjectToken);
        store.setSurplus(FEE_PROJECT_ID, 0.5e18);

        _setDirectoryController(PROJECT_ID, address(burning));
        _setDirectoryController(FEE_PROJECT_ID, address(burning));

        terminal.setAccountingContext(
            FEE_PROJECT_ID, address(terminalToken), uint32(uint160(address(terminalToken))), 18
        );
        terminal.addAccountingContext(
            FEE_PROJECT_ID,
            JBAccountingContext({
                token: address(terminalToken), decimals: 18, currency: uint32(uint160(address(terminalToken)))
            })
        );

        // Wire FEE_PROJECT_ID for auto-select: add terminal to terminalsOf and set balance.
        _addDirectoryTerminal(FEE_PROJECT_ID, address(terminal));
        store.setBalance(address(terminal), FEE_PROJECT_ID, address(terminalToken), 10e18);

        _accumulateWith(address(burning), PROJECT_ID, projectToken, 1000e18);
        _accumulateWith(address(burning), FEE_PROJECT_ID, feeProjectToken, 1000e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);
        vm.prank(owner);
        hook.deployPool(FEE_PROJECT_ID, 0);

        // Set up a re-entering fee terminal that mints fee tokens then re-enters collectAndRouteLPFees.
        MintThenReenterFeeTerminal feeTerminal =
            new MintThenReenterFeeTerminal(hook, feeProjectToken, FEE_PROJECT_ID, address(terminalToken));
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(feeTerminal));

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        positionManager.setCollectableFees(tokenId, 100e18, 100e18);
        projectToken.mint(address(positionManager), 100e18);
        terminalToken.mint(address(positionManager), 100e18);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 claimable = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimable, 0, "outer call should track fee tokens for claiming");

        // The pre-increment protected fee tokens from being burned by the re-entrant call.
        assertGt(
            feeProjectToken.balanceOf(address(hook)), 0, "pre-increment should protect fee tokens from re-entrant burn"
        );

        // The user can actually claim the fee tokens.
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);
        assertEq(feeProjectToken.balanceOf(user), claimable, "user should receive the claimed fee tokens");
    }

    function _accumulateWith(address sender, uint256 projectId, MockERC20 token, uint256 amount) internal {
        token.mint(address(hook), amount);

        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(token),
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

        vm.prank(sender);
        hook.processSplitWith(context);
    }
}
