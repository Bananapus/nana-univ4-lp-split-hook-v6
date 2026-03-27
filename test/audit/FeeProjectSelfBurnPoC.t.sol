// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {MockJBController} from "../mock/MockJBContracts.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DrainingAddToBalanceTerminal {
    address public storeAddress;
    mapping(uint256 projectId => mapping(address token => JBAccountingContext)) public contexts;
    mapping(uint256 projectId => address token) public projectTokens;
    uint256 public addToBalanceCallCount;
    uint256 public lastAddedAmount;
    address public lastAddedToken;

    function setStore(address store) external {
        storeAddress = store;
    }

    function setProjectToken(uint256 projectId, address token) external {
        projectTokens[projectId] = token;
    }

    function setAccountingContext(uint256 projectId, address token, uint32 currency, uint8 decimals) external {
        contexts[projectId][token] = JBAccountingContext({token: token, decimals: decimals, currency: currency});
    }

    function STORE() external view returns (address) {
        return storeAddress;
    }

    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        returns (JBAccountingContext memory)
    {
        return contexts[projectId][token];
    }

    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        ++addToBalanceCallCount;
        lastAddedAmount = amount;
        lastAddedToken = token;

        if (token != address(0x000000000000000000000000000000000000EEEe) && amount > 0) {
            IERC20(token).transferFrom(msg.sender, address(this), amount);
        }
    }

    function cashOutTokensOf(
        address,
        uint256,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256 reclaimAmount)
    {
        reclaimAmount = cashOutCount / 2;
        if (reclaimAmount > 0) {
            MockERC20(tokenToReclaim).mint(beneficiary, reclaimAmount);
        }
    }
}

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
    DrainingAddToBalanceTerminal internal drainingTerminal;
    uint256 internal constant PROJECT_B = 3;

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

        drainingTerminal = new DrainingAddToBalanceTerminal();
        drainingTerminal.setStore(address(store));
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

    /// @notice After claiming fee tokens, _totalOutstandingFeeTokenClaims is decremented.
    ///         A subsequent collectAndRouteLPFees (which calls _burnReceivedTokens) must not
    ///         underflow on the subtraction `balanceOf(this) - _totalOutstandingFeeTokenClaims`.
    function test_ClaimThenBurn_NoUnderflow() public {
        // Deploy pool and generate fee tokens for PROJECT_ID.
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);

        // First fee collection: generates claimable fee tokens.
        uint256 feeAmount = 50e18;
        if (terminalIsToken0) {
            positionManager.setCollectableFees(tokenId, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, feeAmount);
        }
        terminalToken.mint(address(positionManager), feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 claimable = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimable, 0, "precondition: should have claimable fee tokens");

        // Claim all fee tokens — this decrements _totalOutstandingFeeTokenClaims.
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "claimable should be zero after claim");

        // Second fee collection: _burnReceivedTokens subtracts _totalOutstandingFeeTokenClaims
        // (now 0) from balanceOf(this). Must not underflow.
        uint256 feeAmount2 = 30e18;
        if (terminalIsToken0) {
            positionManager.setCollectableFees(tokenId, feeAmount2, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, feeAmount2);
        }
        terminalToken.mint(address(positionManager), feeAmount2);

        // This must not revert from arithmetic underflow.
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));
    }

    /// @notice Two projects generate fee tokens independently. Claiming for one project
    ///         must not affect the other project's claimable balance or cause burns to
    ///         underflow.
    function test_MultiProjectFeeTokenIndependence() public {
        // Set up a second user project (ID 3) that shares the same hook clone.
        // forge-lint: disable-next-line(mixed-case-variable)
        burningController.setWeight(PROJECT_B, DEFAULT_WEIGHT);
        burningController.setReservedPercent(PROJECT_B, DEFAULT_RESERVED_PERCENT);
        burningController.setBaseCurrency(PROJECT_B, 1);
        burningController.setToken(PROJECT_B, address(projectToken));
        _setDirectoryController(PROJECT_B, address(burningController));
        _setDirectoryTerminal(PROJECT_B, address(terminalToken), address(terminal));
        _addDirectoryTerminal(PROJECT_B, address(terminal));
        jbProjects.setOwner(PROJECT_B, owner);
        jbTokens.setToken(PROJECT_B, address(projectToken));
        terminal.setProjectToken(PROJECT_B, address(projectToken));
        store.setSurplus(PROJECT_B, 0.5e18);

        // Deploy pools for both projects.
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        _accumulateTokens(PROJECT_B, 100e18);
        vm.prank(owner);
        hook.deployPool(PROJECT_B, address(terminalToken), 0);

        bool terminalIsToken0 = address(terminalToken) < address(projectToken);

        // Generate fee tokens for PROJECT_ID.
        uint256 tokenIdA = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        uint256 feeA = 60e18;
        if (terminalIsToken0) {
            positionManager.setCollectableFees(tokenIdA, feeA, 0);
        } else {
            positionManager.setCollectableFees(tokenIdA, 0, feeA);
        }
        terminalToken.mint(address(positionManager), feeA);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Generate fee tokens for PROJECT_B.
        uint256 tokenIdB = hook.tokenIdOf(PROJECT_B, address(terminalToken));
        uint256 feeB = 40e18;
        if (terminalIsToken0) {
            positionManager.setCollectableFees(tokenIdB, feeB, 0);
        } else {
            positionManager.setCollectableFees(tokenIdB, 0, feeB);
        }
        terminalToken.mint(address(positionManager), feeB);
        hook.collectAndRouteLPFees(PROJECT_B, address(terminalToken));

        uint256 claimableA = hook.claimableFeeTokens(PROJECT_ID);
        uint256 claimableB = hook.claimableFeeTokens(PROJECT_B);
        assertGt(claimableA, 0, "project A should have claimable fee tokens");
        assertGt(claimableB, 0, "project B should have claimable fee tokens");

        // Hook should hold the combined fee tokens.
        assertEq(
            feeProjectToken.balanceOf(address(hook)),
            claimableA + claimableB,
            "hook should custody both projects' fee tokens"
        );

        // Claim for PROJECT_ID only.
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);

        // PROJECT_B's claimable must be unaffected.
        assertEq(hook.claimableFeeTokens(PROJECT_B), claimableB, "project B claimable unchanged after A claims");

        // Hook should still hold PROJECT_B's fee tokens.
        assertGe(feeProjectToken.balanceOf(address(hook)), claimableB, "hook must still custody project B's fee tokens");

        // PROJECT_B can still claim.
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_B, owner);
        assertEq(feeProjectToken.balanceOf(owner), claimableB, "project B owner should receive claimed fee tokens");
    }

    /// @notice If a later deployment uses the fee project token as its terminal token, `_handleLeftoverTokens`
    ///         sweeps all leftover terminal tokens without excluding `_totalOutstandingFeeTokenClaims`.
    ///         This lets project B consume project A's reserved fee-token claims.
    function test_TerminalTokenLeftoverSweepStealsOutstandingFeeClaims() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        uint256 tokenIdA = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);
        uint256 feeAmount = 100e18;

        if (terminalIsToken0) {
            positionManager.setCollectableFees(tokenIdA, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(tokenIdA, 0, feeAmount);
        }
        terminalToken.mint(address(positionManager), feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 claimableA = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimableA, 0, "precondition: project A should have claimable fee tokens");
        assertEq(
            feeProjectToken.balanceOf(address(hook)),
            claimableA,
            "precondition: hook should custody project A fee claims"
        );

        burningController.setWeight(PROJECT_B, DEFAULT_WEIGHT);
        burningController.setReservedPercent(PROJECT_B, DEFAULT_RESERVED_PERCENT);
        burningController.setBaseCurrency(PROJECT_B, uint32(uint160(address(feeProjectToken))));
        burningController.setToken(PROJECT_B, address(projectToken));
        _setDirectoryController(PROJECT_B, address(burningController));
        _setDirectoryTerminal(PROJECT_B, address(feeProjectToken), address(drainingTerminal));
        jbProjects.setOwner(PROJECT_B, owner);
        jbTokens.setToken(PROJECT_B, address(projectToken));
        drainingTerminal.setProjectToken(PROJECT_B, address(projectToken));
        drainingTerminal.setAccountingContext(
            PROJECT_B, address(feeProjectToken), uint32(uint160(address(feeProjectToken))), 18
        );
        store.setSurplus(PROJECT_B, 0.5e18);

        _accumulateTokensFor(PROJECT_B, projectToken, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_B, address(feeProjectToken), 0);

        assertEq(
            drainingTerminal.lastAddedToken(),
            address(feeProjectToken),
            "leftover sweep should route the fee token as terminal-token dust"
        );
        assertGe(
            drainingTerminal.lastAddedAmount(),
            claimableA,
            "project B should receive at least project A's reserved fee-token balance"
        );
        assertLt(
            feeProjectToken.balanceOf(address(hook)),
            claimableA,
            "hook no longer fully backs project A's claimable fee tokens"
        );
        assertEq(
            hook.claimableFeeTokens(PROJECT_ID),
            claimableA,
            "claimable accounting stays stale even after the backing tokens are moved out"
        );

        vm.prank(owner);
        vm.expectRevert();
        hook.claimFeeTokensFor(PROJECT_ID, user);
    }

    /// @notice _burnReceivedTokens must only burn project tokens that are NOT reserved
    ///         as fee token claims. After fee routing generates fee tokens, a subsequent
    ///         burn (triggered by collectAndRouteLPFees) must leave the reserved fee tokens intact.
    function test_BurnExcludesReservedFeeTokens() public {
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        bool terminalIsToken0 = address(terminalToken) < address(projectToken);

        // Generate fee tokens via LP fee collection.
        uint256 feeAmount = 80e18;
        if (terminalIsToken0) {
            positionManager.setCollectableFees(tokenId, feeAmount, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, feeAmount);
        }
        terminalToken.mint(address(positionManager), feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 claimable = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimable, 0, "precondition: should have claimable fee tokens");
        uint256 hookFeeBalance = feeProjectToken.balanceOf(address(hook));
        assertEq(hookFeeBalance, claimable, "precondition: hook holds exactly the claimable amount");

        // Now do another fee collection with project-token-side fees only.
        // This triggers _burnReceivedTokens, which must NOT burn the reserved fee tokens.
        bool projectIsToken0 = address(projectToken) < address(terminalToken);
        uint256 projFeeAmount = 25e18;
        if (projectIsToken0) {
            positionManager.setCollectableFees(tokenId, projFeeAmount, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, projFeeAmount);
        }
        projectToken.mint(address(positionManager), projFeeAmount);

        // This must not revert (no underflow) and must not burn fee tokens.
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Fee tokens should still be intact.
        assertGe(feeProjectToken.balanceOf(address(hook)), claimable, "fee tokens must survive burn of project tokens");

        // Claim should still work for the full amount.
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);
        assertEq(feeProjectToken.balanceOf(user), claimable, "user should receive all fee tokens after burn");
    }
}
