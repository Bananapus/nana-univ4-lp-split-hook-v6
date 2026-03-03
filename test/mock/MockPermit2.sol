// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Permit2 for testing UniV4DeploymentSplitHook
/// @dev Simulates the approve + transferFrom pattern used by PositionManager
contract MockPermit2 {
    // owner => token => spender => allowance
    struct Allowance {
        uint160 amount;
        uint48 expiration;
    }
    mapping(address => mapping(address => mapping(address => Allowance))) public allowances;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowances[msg.sender][token][spender] = Allowance({
            amount: amount,
            expiration: expiration
        });
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage allowance = allowances[from][token][msg.sender];
        require(allowance.amount >= amount, "Permit2: insufficient allowance");
        require(allowance.expiration >= block.timestamp, "Permit2: expired");

        allowance.amount -= amount;

        IERC20(token).transferFrom(from, to, amount);
    }
}
