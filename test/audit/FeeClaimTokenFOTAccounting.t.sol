// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LPSplitHookV4TestBase} from "../TestBaseV4.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FeeOnTransferFeeToken is ERC20 {
    uint256 internal constant FEE_BPS = 500;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    constructor() ERC20("Fee On Transfer Fee Token", "FOTF") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value * FEE_BPS / BPS_DENOMINATOR;
        uint256 net = value - fee;
        super._update(from, address(0xBEEF), fee);
        super._update(from, to, net);
    }
}

contract FOTFeeProjectTerminal {
    FeeOnTransferFeeToken internal immutable TOKEN;

    constructor(FeeOnTransferFeeToken token) {
        TOKEN = token;
    }

    function STORE() external pure returns (address) {
        return address(0);
    }

    function accountingContextForTokenOf(uint256, address token) external view returns (JBAccountingContext memory) {
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](0);
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
        payable
        returns (uint256 beneficiaryTokenCount)
    {
        if (token != address(0x000000000000000000000000000000000000EEEe) && amount > 0) {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }

        beneficiaryTokenCount = amount;

        TOKEN.mint(address(this), amount);
        TOKEN.transfer(beneficiary, amount);
    }
}

contract ConsumingProjectTerminal {
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

contract FeeClaimTokenFOTAccountingTest is LPSplitHookV4TestBase {
    FeeOnTransferFeeToken internal fotFeeToken;
    FOTFeeProjectTerminal internal fotFeeTerminal;
    ConsumingProjectTerminal internal consumingProjectTerminal;

    uint256 internal poolTokenId;
    bool internal terminalTokenIsToken0;

    function setUp() public override {
        super.setUp();

        _accumulateAndDeploy(PROJECT_ID, 100e18);
        poolTokenId = hook.tokenIdOf(PROJECT_ID, address(terminalToken));
        terminalTokenIsToken0 = address(terminalToken) < address(projectToken);

        fotFeeToken = new FeeOnTransferFeeToken();
        fotFeeTerminal = new FOTFeeProjectTerminal(fotFeeToken);
        consumingProjectTerminal = new ConsumingProjectTerminal();

        jbTokens.setToken(FEE_PROJECT_ID, address(fotFeeToken));
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(fotFeeTerminal));
        _setDirectoryTerminal(PROJECT_ID, address(terminalToken), address(consumingProjectTerminal));
    }

    function _setTerminalTokenFees(uint256 amount) internal {
        if (terminalTokenIsToken0) {
            positionManager.setCollectableFees(poolTokenId, amount, 0);
        } else {
            positionManager.setCollectableFees(poolTokenId, 0, amount);
        }

        terminalToken.mint(address(positionManager), amount);
    }

    function test_feeClaimAccountingUsesActualReceivedBalance() public {
        uint256 feeAmount = 100e18;
        _setTerminalTokenFees(feeAmount);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 claimable = hook.claimableFeeTokens(PROJECT_ID);
        uint256 actualBalance = fotFeeToken.balanceOf(address(hook));

        assertGt(claimable, 0, "claimable fee tokens should accrue");
        assertEq(claimable, actualBalance, "claim accounting should only credit tokens actually received");

        uint256 userBalanceBefore = fotFeeToken.balanceOf(user);
        vm.prank(owner);
        hook.claimFeeTokensFor(PROJECT_ID, user);

        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "claim should clear fee-token accounting");
        assertEq(fotFeeToken.balanceOf(address(hook)), 0, "claim should transfer all accounted fee tokens");
        assertEq(
            fotFeeToken.balanceOf(user) - userBalanceBefore,
            claimable * 9500 / 10_000,
            "beneficiary should receive the token's fee-on-transfer net amount"
        );
    }
}
