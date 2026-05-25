// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

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

    //*********************************************************************//
    // ------------------------ public properties ------------------------ //
    //*********************************************************************//

    /// @notice The hook implementation that all clones delegate to. Set once by `_DEPLOYER` after construction via
    /// `setChainSpecificConstants` and never changed thereafter.
    /// @dev Held as public storage (rather than immutable) so the constructor inputs are byte-identical on every chain.
    /// The chain-specific hook implementation is supplied by `_DEPLOYER` in a one-shot call to
    /// `setChainSpecificConstants`. This mirrors the chain-identical CREATE2 pattern used by `JBBuybackHook` and
    /// `JBOptimismSuckerDeployer`, keeping this deployer's address unified across chains.
    JBUniswapV4LPSplitHook public override hookImplementation;

    /// @notice The Uniswap V4 oracle hook clones should use, set once by `_DEPLOYER` via `setChainSpecificConstants`.
    /// @dev Passed into each freshly cloned hook's `setChainSpecificConstants` inside `deployHookFor`.
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
    /// @param deployer The address authorized to call `setChainSpecificConstants` exactly once.
    constructor(IJBAddressRegistry addressRegistry, address deployer) {
        ADDRESS_REGISTRY = addressRegistry;
        _DEPLOYER = deployer;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploy a new `JBUniswapV4LPSplitHook` clone with the caller as its initial owner.
    /// @param feeProjectId The Juicebox project ID that receives a share of LP fees.
    /// @param feePercent The percentage of LP fees routed to the fee project, out of `BPS` (e.g. 3800 = 38%).
    /// @param salt An optional salt for deterministic CREATE2 deployment. Pass `bytes32(0)` for a plain CREATE.
    /// @return hook The newly deployed hook.
    function deployHookFor(
        uint256 feeProjectId,
        uint256 feePercent,
        bytes32 salt
    )
        external
        override
        returns (IJBUniswapV4LPSplitHook hook)
    {
        hook = IJBUniswapV4LPSplitHook(
            salt == bytes32(0)
                ? LibClone.clone(address(hookImplementation))
                : LibClone.cloneDeterministic({
                    implementation: address(hookImplementation), salt: keccak256(abi.encode(msg.sender, salt))
                })
        );

        // Initialize the clone atomically with project + chain-specific config so no one can frontrun the values.
        hook.initialize({
            initialFeeProjectId: feeProjectId,
            initialFeePercent: feePercent,
            newPoolManager: poolManager,
            newPositionManager: positionManager,
            newOracleHook: oracleHook
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
                bytecode: LibClone.initCode(address(hookImplementation))
            });
    }

    /// @notice One-shot setter for the chain-specific hook implementation + Uniswap V4 addresses.
    /// @dev Callable only by `_DEPLOYER` and only once (when `hookImplementation` is still `address(0)`). After this
    /// call all four values are effectively immutable for the contract's lifetime. Mirrors the
    /// `JBOptimismSuckerDeployer` pattern so the contract's CREATE2 inputs stay byte-identical across chains and its
    /// deployed address is unified. The stored V4 addresses are passed into every freshly cloned hook by
    /// `deployHookFor`.
    /// @param newHookImplementation The chain-specific `JBUniswapV4LPSplitHook` implementation.
    /// @param newPoolManager The Uniswap V4 PoolManager on this chain.
    /// @param newPositionManager The Uniswap V4 PositionManager on this chain.
    /// @param newOracleHook The Uniswap V4 oracle hook deployed against `newPoolManager` on this chain.
    function setChainSpecificConstants(
        JBUniswapV4LPSplitHook newHookImplementation,
        IPoolManager newPoolManager,
        IPositionManager newPositionManager,
        IHooks newOracleHook
    )
        external
        override
    {
        if (msg.sender != _DEPLOYER) revert JBUniswapV4LPSplitHookDeployer_Unauthorized({caller: msg.sender});
        if (address(hookImplementation) != address(0)) revert JBUniswapV4LPSplitHookDeployer_AlreadyConfigured();
        hookImplementation = newHookImplementation;
        poolManager = newPoolManager;
        positionManager = newPositionManager;
        oracleHook = newOracleHook;
    }
}
