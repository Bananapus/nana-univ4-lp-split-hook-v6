// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {MockJBController} from "../mock/MockJBContracts.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

contract BurningController {
    address public pricesContract;

    mapping(uint256 projectId => uint256 weight) public weights;
    mapping(uint256 projectId => uint16 reservedPercent) public reservedPercents;
    mapping(uint256 projectId => uint32 baseCurrency) public baseCurrencies;
    mapping(uint256 projectId => address token) public tokens;

    function setPrices(address _prices) external {
        pricesContract = _prices;
    }

    function setWeight(uint256 projectId, uint256 weight) external {
        weights[projectId] = weight;
    }

    function setReservedPercent(uint256 projectId, uint16 reservedPercent) external {
        reservedPercents[projectId] = reservedPercent;
    }

    function setBaseCurrency(uint256 projectId, uint32 currency) external {
        baseCurrencies[projectId] = currency;
    }

    function setToken(uint256 projectId, address token) external {
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
        MockERC20(tokens[projectId]).burn(holder, amount);
    }
}

contract FeeProjectSelfBurnPoC is LPSplitHookV4TestBase {
    BurningController internal burningController;

    function setUp() public override {
        super.setUp();

        burningController = new BurningController();
        burningController.setPrices(address(prices));
        burningController.setWeight(PROJECT_ID, DEFAULT_WEIGHT);
        burningController.setWeight(FEE_PROJECT_ID, 100e18);
        burningController.setReservedPercent(PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        burningController.setReservedPercent(FEE_PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        burningController.setBaseCurrency(PROJECT_ID, 1);
        burningController.setBaseCurrency(FEE_PROJECT_ID, 1);
        burningController.setToken(PROJECT_ID, address(projectToken));
        burningController.setToken(FEE_PROJECT_ID, address(feeProjectToken));

        controller = MockJBController(address(burningController));
        _setDirectoryController(PROJECT_ID, address(burningController));
        _setDirectoryController(FEE_PROJECT_ID, address(burningController));
        store.setSurplus(FEE_PROJECT_ID, 0.5e18);
    }

    function _accumulateTokensFor(uint256 projectId, MockERC20 token, uint256 amount) internal {
        token.mint(address(hook), amount);

        JBSplitHookContext memory context = _buildContext(projectId, address(token), amount, 1);

        vm.prank(address(burningController));
        hook.processSplitWith(context);
    }

    /// @notice Verifies that _totalOutstandingFeeTokenClaims prevents the fee project's own pool
    /// deployment from consuming other projects' claimable fee tokens (H-2 fix).
    function test_FeeProjectPoolDeploymentDoesNotBurnOtherProjectsClaimableFeeTokens() public {
        uint256 feeProjectAccumulation = 100e18;

        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 projectOneTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        uint256 terminalFeeAmount = 100e18;

        if (terminalIsToken0) {
            positionManager.setCollectableFees(projectOneTokenId, terminalFeeAmount, 0);
        } else {
            positionManager.setCollectableFees(projectOneTokenId, 0, terminalFeeAmount);
        }
        terminalToken.mint(address(positionManager), terminalFeeAmount);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 projectOneClaimable = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(projectOneClaimable, 0, "precondition: project 1 should have claimable fee tokens");
        assertEq(
            feeProjectToken.balanceOf(address(hook)),
            projectOneClaimable,
            "precondition: hook should custody project 1 claimable fee tokens"
        );

        _accumulateTokensFor(FEE_PROJECT_ID, feeProjectToken, feeProjectAccumulation);

        vm.prank(owner);
        hook.deployPool(FEE_PROJECT_ID, address(terminalToken), 0);

        // _totalOutstandingFeeTokenClaims prevents the fee project deployment from touching
        // project 1's reserved fee tokens. The position manager should receive at most what
        // was accumulated for the fee project.
        uint256 positionManagerFeeTokenBalance = feeProjectToken.balanceOf(address(positionManager));
        assertLe(
            positionManagerFeeTokenBalance,
            feeProjectAccumulation,
            "fee project deployment must not consume more fee tokens than it accumulated"
        );

        // Project 1's claimable tokens should still be backed by actual hook balance.
        assertGe(
            feeProjectToken.balanceOf(address(hook)),
            projectOneClaimable,
            "hook must still hold project 1 claimable fee tokens after fee project deployment"
        );

        // Project 1 can still claim its fee tokens.
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);
        assertEq(feeProjectToken.balanceOf(user), projectOneClaimable, "user should receive claimed fee tokens");
    }
}
