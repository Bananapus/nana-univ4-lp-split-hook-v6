// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {JBUniswapV4LPSplitHook} from "./JBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHook} from "./interfaces/IJBUniswapV4LPSplitHook.sol";
import {IJBUniswapV4LPSplitHookDeployer} from "./interfaces/IJBUniswapV4LPSplitHookDeployer.sol";

/// @notice Factory that deploys lightweight `JBUniswapV4LPSplitHook` clones. Each clone shares the same logic
/// implementation but gets its own storage, allowing many projects to run independent LP split hooks from a single
/// deployment. Anyone can deploy a hook by specifying a fee project and fee percentage; deterministic CREATE2 addresses
/// are supported via an optional salt.
contract JBUniswapV4LPSplitHookDeployer is IJBUniswapV4LPSplitHookDeployer {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBUniswapV4LPSplitHookDeployer_AlreadyConfigured();
    error JBUniswapV4LPSplitHookDeployer_NotConfigured();
    error JBUniswapV4LPSplitHookDeployer_Unauthorized(address caller);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice A registry which stores references to contracts and their deployers.
    IJBAddressRegistry public immutable override ADDRESS_REGISTRY;

    //*********************************************************************//
    // -------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    /// @notice The address authorized to call `setChainSpecificConstants` exactly once.
    /// @dev Held immutable so the constructor inputs are byte-identical across chains and the CREATE2 address is
    /// unified. Mirrors the `JBOptimismSuckerDeployer.setChainSpecificConstants` pattern in nana-suckers-v6.
    address internal immutable _DEPLOYER;

    /// @notice The hook implementation that all clones delegate to.
    /// @dev This implementation is deployed from chain-same constructor inputs and a fixed salt, so keeping it
    /// immutable does not disturb this deployer's cross-chain CREATE2 address.
    JBUniswapV4LPSplitHook internal immutable _HOOK_IMPLEMENTATION;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The Uniswap V4 oracle hook clones should use, set once by `_DEPLOYER` via `setChainSpecificConstants`.
    /// @dev Passed into each freshly cloned hook's `initialize` inside `deployHookFor`.
    IHooks public override oracleHook;

    /// @notice The Uniswap V4 PoolManager clones should use, set once by `_DEPLOYER` via `setChainSpecificConstants`.
    IPoolManager public override poolManager;

    /// @notice The Uniswap V4 PositionManager clones should use, set once by `_DEPLOYER` via
    /// `setChainSpecificConstants`.
    IPositionManager public override positionManager;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice This contract's current nonce, used for the Juicebox address registry.
    uint256 internal _nonce;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param addressRegistry A registry which stores references to contracts and their deployers.
    /// @param newHookImplementation The chain-same `JBUniswapV4LPSplitHook` implementation clones should use.
    /// @param deployer The address authorized to call `setChainSpecificConstants` exactly once.
    constructor(IJBAddressRegistry addressRegistry, JBUniswapV4LPSplitHook newHookImplementation, address deployer) {
        ADDRESS_REGISTRY = addressRegistry;
        _DEPLOYER = deployer;
        _HOOK_IMPLEMENTATION = newHookImplementation;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploy a new `JBUniswapV4LPSplitHook` clone with the caller as its initial owner.
    /// @param feeProjectId The Juicebox project ID that receives a share of LP fees.
    /// @param feePercent The percentage of LP fees routed to the fee project, out of `BPS` (e.g. 3800 = 38%).
    /// @param buybackHook The buyback-hook registry this clone targets for force-direct cash-outs. Pass the zero
    /// address for none. Per-deploy so different projects can use different buyback hooks.
    /// @param salt An optional salt for deterministic CREATE2 deployment. Pass `bytes32(0)` for a plain CREATE.
    /// @return hook The newly deployed hook.
    function deployHookFor(
        uint256 feeProjectId,
        uint256 feePercent,
        IJBBuybackHookRegistry buybackHook,
        bytes32 salt
    )
        external
        override
        returns (IJBUniswapV4LPSplitHook hook)
    {
        if (address(poolManager) == address(0)) revert JBUniswapV4LPSplitHookDeployer_NotConfigured();

        hook = IJBUniswapV4LPSplitHook(
            salt == bytes32(0)
                ? LibClone.clone(address(_HOOK_IMPLEMENTATION))
                : LibClone.cloneDeterministic({
                    implementation: address(_HOOK_IMPLEMENTATION), salt: keccak256(abi.encode(msg.sender, salt))
                })
        );

        // Initialize the clone atomically with project + chain-specific config so no one can frontrun the values.
        hook.initialize({
            initialFeeProjectId: feeProjectId,
            initialFeePercent: feePercent,
            newPoolManager: poolManager,
            newPositionManager: positionManager,
            newOracleHook: oracleHook,
            newBuybackHook: buybackHook
        });

        emit HookDeployed({feeProjectId: feeProjectId, feePercent: feePercent, hook: hook, caller: msg.sender});

        // Increment the nonce. Both CREATE and CREATE2 opcodes increment the deployer's EVM nonce,
        // so _nonce must advance for both paths to stay in sync with the EVM nonce.
        ++_nonce;

        // Add the hook to the address registry. This contract's nonce starts at 1.
        salt == bytes32(0)
            ? ADDRESS_REGISTRY.registerAddress({deployer: address(this), nonce: _nonce})
            : ADDRESS_REGISTRY.registerAddress({
                deployer: address(this),
                salt: keccak256(abi.encode(msg.sender, salt)),
                bytecode: LibClone.initCode(address(_HOOK_IMPLEMENTATION))
            });
    }

    /// @notice One-shot setter for chain-specific Uniswap V4 addresses.
    /// @dev Callable only by `_DEPLOYER` and only once (when `poolManager` is still `address(0)`). After this call the
    /// stored V4 addresses are effectively immutable for the contract's lifetime. They are passed into every freshly
    /// cloned hook by `deployHookFor`.
    /// @param newPoolManager The Uniswap V4 PoolManager on this chain.
    /// @param newPositionManager The Uniswap V4 PositionManager on this chain.
    /// @param newOracleHook The Uniswap V4 oracle hook deployed against `newPoolManager` on this chain.
    function setChainSpecificConstants(
        IPoolManager newPoolManager,
        IPositionManager newPositionManager,
        IHooks newOracleHook
    )
        external
        override
    {
        if (msg.sender != _DEPLOYER) revert JBUniswapV4LPSplitHookDeployer_Unauthorized({caller: msg.sender});
        if (address(poolManager) != address(0)) revert JBUniswapV4LPSplitHookDeployer_AlreadyConfigured();
        poolManager = newPoolManager;
        positionManager = newPositionManager;
        oracleHook = newOracleHook;
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The implementation contract used as the base for clones.
    /// @return The hook implementation contract.
    function hookImplementation() external view override returns (JBUniswapV4LPSplitHook) {
        return _HOOK_IMPLEMENTATION;
    }
}
