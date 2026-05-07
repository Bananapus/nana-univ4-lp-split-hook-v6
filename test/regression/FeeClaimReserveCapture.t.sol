// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PullingFeeTerminal {
    address public storeAddress;

    mapping(uint256 projectId => mapping(address token => JBAccountingContext)) public contexts;
    mapping(uint256 projectId => JBAccountingContext[]) internal _contextsList;
    mapping(uint256 projectId => address token) public projectTokens;

    function setStore(address store) external {
        storeAddress = store;
    }

    function setProjectToken(uint256 projectId, address token) external {
        projectTokens[projectId] = token;
    }

    function setAccountingContext(uint256 projectId, address token, uint32 currency, uint8 decimals) external {
        JBAccountingContext memory ctx = JBAccountingContext({token: token, decimals: decimals, currency: currency});
        contexts[projectId][token] = ctx;
        _contextsList[projectId].push(ctx);
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

    function accountingContextsOf(uint256 projectId) external view returns (JBAccountingContext[] memory) {
        return _contextsList[projectId];
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 beneficiaryTokenCount)
    {
        if (token != address(0x000000000000000000000000000000000000EEEe) && amount > 0) {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }

        beneficiaryTokenCount = amount;

        address projectToken = projectTokens[projectId];
        if (projectToken != address(0) && beneficiaryTokenCount > 0) {
            MockERC20(projectToken).mint(beneficiary, beneficiaryTokenCount);
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
        if (token != address(0x000000000000000000000000000000000000EEEe) && amount > 0) {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }
    }
}

contract OverreportingCashOutTerminal {
    address public storeAddress;

    mapping(uint256 projectId => mapping(address token => JBAccountingContext)) public contexts;
    mapping(uint256 projectId => JBAccountingContext[]) internal _contextsList;

    uint256 public reportedCashOutAmount;
    uint256 public actualCashOutAmount;

    function setStore(address store) external {
        storeAddress = store;
    }

    function setAccountingContext(uint256 projectId, address token, uint32 currency, uint8 decimals) external {
        JBAccountingContext memory ctx = JBAccountingContext({token: token, decimals: decimals, currency: currency});
        contexts[projectId][token] = ctx;
        _contextsList[projectId].push(ctx);
    }

    function setCashOutAmounts(uint256 reportedAmount, uint256 actualAmount) external {
        reportedCashOutAmount = reportedAmount;
        actualCashOutAmount = actualAmount;
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

    function accountingContextsOf(uint256 projectId) external view returns (JBAccountingContext[] memory) {
        return _contextsList[projectId];
    }

    function cashOutTokensOf(
        address,
        uint256,
        uint256,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256 reclaimAmount)
    {
        reclaimAmount = reportedCashOutAmount;

        if (actualCashOutAmount > 0) {
            MockERC20(tokenToReclaim).mint(beneficiary, actualCashOutAmount);
        }
    }
}

contract FeeClaimReserveCaptureRegression is LPSplitHookV4TestBase {
    uint256 internal constant PROJECT_B = 3;

    PullingFeeTerminal internal pullingTerminal;
    OverreportingCashOutTerminal internal maliciousTerminal;
    MockERC20 internal projectTokenB;

    function setUp() public override {
        super.setUp();

        pullingTerminal = new PullingFeeTerminal();
        pullingTerminal.setStore(address(store));
        pullingTerminal.setProjectToken(PROJECT_ID, address(projectToken));
        pullingTerminal.setProjectToken(FEE_PROJECT_ID, address(feeProjectToken));
        pullingTerminal.setAccountingContext(
            PROJECT_ID, address(feeProjectToken), uint32(uint160(address(feeProjectToken))), 18
        );
        pullingTerminal.setAccountingContext(
            FEE_PROJECT_ID, address(feeProjectToken), uint32(uint160(address(feeProjectToken))), 18
        );

        _setDirectoryTerminal(PROJECT_ID, address(feeProjectToken), address(pullingTerminal));
        _setDirectoryTerminal(FEE_PROJECT_ID, address(feeProjectToken), address(pullingTerminal));
        _addDirectoryTerminal(PROJECT_ID, address(pullingTerminal));
        _addDirectoryTerminal(FEE_PROJECT_ID, address(pullingTerminal));

        store.setBalance(address(terminal), PROJECT_ID, address(terminalToken), 0);
        store.setBalance(address(pullingTerminal), PROJECT_ID, address(feeProjectToken), 100e18);

        projectTokenB = new MockERC20("Project B", "PRJB", 18);
        jbTokens.setToken(PROJECT_B, address(projectTokenB));
        jbProjects.setOwner(PROJECT_B, owner);
        _setDirectoryController(PROJECT_B, address(controller));
        controller.setWeight(PROJECT_B, DEFAULT_WEIGHT);
        controller.setFirstWeight(PROJECT_B, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(PROJECT_B, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(PROJECT_B, 1);
        store.setSurplus(PROJECT_B, 0.5e18);

        maliciousTerminal = new OverreportingCashOutTerminal();
        maliciousTerminal.setStore(address(store));
        maliciousTerminal.setAccountingContext(
            PROJECT_B, address(feeProjectToken), uint32(uint160(address(feeProjectToken))), 18
        );

        _setDirectoryTerminal(PROJECT_B, address(feeProjectToken), address(maliciousTerminal));
        _addDirectoryTerminal(PROJECT_B, address(maliciousTerminal));
        store.setBalance(address(maliciousTerminal), PROJECT_B, address(feeProjectToken), 100e18);
    }

    function test_overreportedCashOutCannotConsumeOtherProjectsFeeClaims() public {
        projectToken.mint(address(hook), 100e18);

        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(PROJECT_ID, address(projectToken), 100e18, 1));

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, 0);

        uint256 tokenId = hook.tokenIdOf(PROJECT_ID, address(feeProjectToken));
        bool feeTokenIsToken0 = address(feeProjectToken) < address(projectToken);

        if (feeTokenIsToken0) {
            positionManager.setCollectableFees(tokenId, 100e18, 0);
        } else {
            positionManager.setCollectableFees(tokenId, 0, 100e18);
        }
        feeProjectToken.mint(address(positionManager), 100e18);

        hook.collectAndRouteLPFees(PROJECT_ID, address(feeProjectToken));

        uint256 claimableFeeTokens = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimableFeeTokens, 0, "precondition: project A should have claimable fee tokens");
        assertEq(
            feeProjectToken.balanceOf(address(hook)),
            claimableFeeTokens,
            "hook should currently hold project A's reserved fee tokens"
        );

        maliciousTerminal.setCashOutAmounts(claimableFeeTokens, 0);

        projectTokenB.mint(address(hook), 100e18);

        vm.prank(address(controller));
        hook.processSplitWith(_buildContext(PROJECT_B, address(projectTokenB), 100e18, 1));

        vm.prank(owner);
        vm.expectPartialRevert(JBUniswapV4LPSplitHook.JBUniswapV4LPSplitHook_InsufficientBalance.selector);
        hook.deployPool(PROJECT_B, 0);

        assertEq(
            feeProjectToken.balanceOf(address(hook)),
            claimableFeeTokens,
            "project B deployment must not consume project A's reserved fee tokens"
        );

        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);
        assertEq(feeProjectToken.balanceOf(user), claimableFeeTokens, "project A can still claim its fee tokens");
    }
}
