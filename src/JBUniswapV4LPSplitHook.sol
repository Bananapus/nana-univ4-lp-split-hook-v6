// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv, sqrt} from "@prb/math/src/Common.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IGeomeanOracle} from "@bananapus/suckers-v6/src/interfaces/IGeomeanOracle.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";

import {IJBUniswapV4LPSplitHook} from "./interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBLPSplitHookHelpers} from "./libraries/JBLPSplitHookHelpers.sol";
import {AddLiquidityParams} from "./structs/AddLiquidityParams.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/// @notice A split hook that builds and manages a Uniswap V4 liquidity position for a Juicebox project, using the
/// project's reserved-token distributions as the seed capital. The lifecycle has two stages:
///
/// 1. Accumulation — Each time the project distributes reserved tokens, the hook's share is held in escrow. Once the
/// project owner (or anyone, after sufficient weight decay) triggers `deployPool`, the accumulated tokens are paired
/// with terminal tokens obtained via a proportional cash-out, and the resulting Uniswap V4 LP position is minted.
///
/// 2. Grow-and-route — After the pool exists, any further reserved tokens sent to the hook keep accumulating in
/// escrow.
/// Anyone can later call `addLiquidity` (permissionless once the weight has decayed 10x, otherwise owner-gated) to
/// convert the accumulated tokens into more protocol-owned liquidity: it cashes out the optimal fraction DIRECTLY at
/// the bonding-curve floor (never through the AMM it is feeding), checks the pool price against the oracle TWAP to
/// reject sandwiched adds, then either tops up the active position or — once the live cash-out/issuance corridor has
/// drifted past a threshold — mints a fresh position at the current corridor (retiring the prior one). LP trading
/// fees
/// are collected periodically (from the active position and every retired one) and routed back to the project's
/// terminal balance, with an optional protocol fee split to a configurable fee project. The hook never burns: burning
/// is a split-routing decision handled at the protocol layer, so every token this hook touches ends up as liquidity.
///
/// The hook also supports `rebalanceLiquidity`, which re-centers the LP tick range around the project's current
/// issuance and cash-out prices when they drift from the original deployment parameters.
///
/// @dev Each clone manages exactly one Uniswap V4 pool per project (one terminal-token pairing). Pool deployment
/// requires `SET_BUYBACK_POOL` permission. The pool uses a 1% fee tier, 200-tick spacing, and a shared oracle hook
/// for TWAP observations.
contract JBUniswapV4LPSplitHook is IJBUniswapV4LPSplitHook, IJBSplitHook, JBPermissioned {
    using JBRulesetMetadataResolver for JBRuleset;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBUniswapV4LPSplitHook_AlreadyInitialized();
    /// @notice Thrown when a pre-initialized pool's price falls outside the project's economic tick range.
    /// @dev This prevents frontrunning attacks where an attacker initializes the pool at an extreme price.
    error JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds(
        uint160 existingPrice, uint160 lowerBound, uint160 upperBound
    );
    error JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject(uint256 feePercent, uint256 feeProjectId);
    error JBUniswapV4LPSplitHook_InsufficientBalance(uint256 available, uint256 required);
    error JBUniswapV4LPSplitHook_InsufficientLiquidity(uint128 liquidity);
    error JBUniswapV4LPSplitHook_InvalidFeePercent(uint256 feePercent, uint256 maxFeePercent);
    error JBUniswapV4LPSplitHook_InvalidProjectId(uint256 projectId, address controller, address projectToken);
    error JBUniswapV4LPSplitHook_InvalidStageForAction(uint256 projectId, address terminalToken, uint256 tokenId);
    error JBUniswapV4LPSplitHook_InvalidTerminalToken(uint256 projectId, address terminalToken);
    error JBUniswapV4LPSplitHook_InvalidTickBounds(int24 tickLower, int24 tickUpper);
    error JBUniswapV4LPSplitHook_NoTerminalTokenFound(uint256 projectId);
    error JBUniswapV4LPSplitHook_NoTokensAccumulated(uint256 projectId);
    error JBUniswapV4LPSplitHook_NotHookSpecifiedInContext(address expectedHook, address actualHook);
    error JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported(uint256 projectId, address terminalToken);
    error JBUniswapV4LPSplitHook_Permit2AmountOverflow(address token, uint256 amount, uint256 maxAmount);
    error JBUniswapV4LPSplitHook_PoolAlreadyDeployed(uint256 projectId, address terminalToken, uint256 tokenId);
    /// @notice Thrown when the pool's current price has deviated too far from the oracle TWAP, which would let a
    /// sandbox/JIT attacker make the hook add liquidity at a manipulated ratio.
    error JBUniswapV4LPSplitHook_PriceDeviationTooHigh(int24 spotTick, int24 twapTick, int24 maxDeviationTicks);
    error JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal(
        uint256 projectId, address sender, address controller
    );
    error JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed(address token, address spender, uint256 allowance);
    error JBUniswapV4LPSplitHook_TerminalNotFound(uint256 projectId, address token);
    error JBUniswapV4LPSplitHook_TerminalTokensNotAllowed(uint256 groupId, uint256 requiredGroupId);
    /// @notice Thrown when the oracle TWAP cannot be read (e.g. the pool oracle has not warmed up yet), so the pool
    /// price cannot be validated and liquidity must not be added.
    error JBUniswapV4LPSplitHook_TwapUnavailable(uint256 projectId, address terminalToken);
    error JBUniswapV4LPSplitHook_UnclaimedFeeTokenChanged(address previousToken, address nextToken);
    error JBUniswapV4LPSplitHook_ZeroLiquidity(uint256 amount0, uint256 amount1);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice Basis points constant (10000 = 100%)
    uint256 public constant BPS = 10_000;

    /// @notice Uniswap V4 pool fee (10000 = 1% fee tier)
    uint24 public constant POOL_FEE = 10_000;

    /// @notice Tick spacing for 1% fee tier (200 ticks)
    int24 public constant TICK_SPACING = 200;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Default minimum cash-out return as a fraction of expected return (97/100 = 3% slippage tolerance).
    /// @dev Widened from 1% to 3% because the linear cash-out estimate diverges from the bonding curve
    ///      at higher cashOutTaxRates, especially with the corrected (wider) LP tick bounds.
    uint256 internal constant _CASH_OUT_SLIPPAGE_DENOMINATOR = 100;

    /// @notice Default minimum cash-out return numerator (97 out of 100 = 3% slippage tolerance).
    uint256 internal constant _CASH_OUT_SLIPPAGE_NUMERATOR = 97;

    /// @notice Deadline window (in seconds) for PositionManager and Permit2 operations.
    uint256 internal constant _DEADLINE_SECONDS = 60;

    /// @notice The TWAP observation window (in seconds) used to validate the pool's spot price before adding liquidity.
    /// @dev Matches the buyback hook's expected oracle warmup. `addLiquidity` reverts until the pool oracle has at
    /// least this much history; accumulation continues safely in the meantime.
    uint32 internal constant _TWAP_WINDOW = 30 minutes;

    /// @notice The maximum allowed deviation (in ticks) between the pool's spot price and the oracle TWAP when adding
    /// liquidity. ~200 ticks ≈ 2.0% on the 1% fee tier; an add whose spot is further than this from the TWAP reverts,
    /// bounding how badly a sandwich/JIT attacker can skew the mint ratio.
    int24 internal constant _MAX_TWAP_DEVIATION_TICKS = 200;

    /// @notice How far (in ticks) the live cash-out/issuance corridor must drift from the active position's stored
    /// ticks before `addLiquidity` mints a fresh position at the current corridor instead of topping up the active one.
    /// ~400 ticks ≈ 4.0%. Keeps the retired-position set small while still tracking a maturing project's band.
    int24 internal constant _RERANGE_THRESHOLD_TICKS = 400;

    /// @notice Uniswap V4 Q96 fixed-point scale factor for sqrtPriceX96 values.
    uint256 internal constant _Q96 = 2 ** 96;

    /// @notice 1e18 scale factor used as a unit amount in rate calculations.
    uint256 internal constant _WAD = 10 ** 18;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The buyback-hook registry, used to target the force-direct cash-out flag.
    /// @dev When `addLiquidity` cashes out to fund the terminal side, it attaches the buyback hook's
    /// `cashOutMinReclaimed` skip metadata keyed to this registry so the cash-out is routed DIRECTLY through the
    /// bonding curve (never through an AMM). Held as an immutable strong reference because the registry is chain-same
    /// (one
    /// canonical CREATE2 address per chain) — this contract does not resolve it per-call from a project's data hook,
    /// so
    /// it is decoupled from revnets / REVOwner. May be the zero address, in which case no force-direct metadata is
    /// attached and the terminal's own `minTokensReclaimed` floor still applies.
    IJBBuybackHookRegistry public immutable BUYBACK_HOOK;

    /// @notice JBDirectory (to find important control contracts for given projectId)
    address public immutable DIRECTORY;

    /// @notice The Permit2 utility used to approve tokens for PositionManager.
    IAllowanceTransfer public immutable PERMIT2;

    /// @notice JBProjects (to find project owners)
    IJBProjects public immutable PROJECTS;

    /// @notice The sucker registry for querying remote cross-chain surplus and supply.
    IJBSuckerRegistry public immutable SUCKER_REGISTRY;

    /// @notice JBTokens (to find project tokens)
    address public immutable TOKENS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The oracle hook used for configured Uniswap V4 pools (provides TWAP via observe()).
    /// @dev Set once per clone via `initialize` (alongside `feeProjectId` + `feePercent`). Held as storage rather
    /// than immutable because `JBUniswapV4Hook` is chain-different by design (inherits Uniswap's
    /// `BaseHook → ImmutableState`). Keeping it out of the constructor lets this implementation's CREATE2 inputs be
    /// byte-identical on every chain.
    IHooks public oracleHook;

    /// @notice The Uniswap V4 pool manager contract that coordinates all pool operations.
    /// @dev Set once per clone via `initialize`. Held as storage rather than immutable so the implementation's
    /// constructor inputs are byte-identical on every chain (the V4 PoolManager varies per chain).
    IPoolManager public poolManager;

    /// @notice The Uniswap V4 position manager contract that handles liquidity position NFTs.
    /// @dev Set once per clone via `initialize`. Held as storage rather than immutable so the implementation's
    /// constructor inputs are byte-identical on every chain (the V4 PositionManager varies per chain).
    IPositionManager public positionManager;

    /// @notice Project ID to receive LP fees
    uint256 public feeProjectId;

    /// @notice Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    uint256 public feePercent;

    /// @notice The accumulated project-token balance currently held for each project before its first pool deployment.
    /// @dev `processSplitWith` accumulates project tokens here while the project is still in pre-deployment mode.
    /// Once a pool is deployed for a project, the project permanently transitions out of this accumulation path.
    /// @custom:param projectId The ID of the project to get the currently accumulated pre-deployment project-token
    /// balance of.
    mapping(uint256 projectId => uint256 accumulatedProjectTokens) public accumulatedProjectTokens;

    /// @notice The fee-project credits, rather than ERC-20s, currently claimable by each project.
    /// @dev These credits accrue when fee routing reaches `terminal.pay()` while the fee project has no ERC-20.
    /// They are later claimed through `controller.transferCreditsFrom()`.
    /// @custom:param projectId The ID of the project to get the currently claimable fee-credit balance of.
    mapping(uint256 projectId => uint256 claimableFeeCredits) public claimableFeeCredits;

    /// @notice The fee-project ERC-20 currently backing each project's `claimableFeeTokens` balance.
    /// @dev When fee routing mints ERC-20s instead of credits, the token address is recorded here alongside the
    /// amount in `claimableFeeTokens` so claim processing can transfer the correct asset later.
    /// @custom:param projectId The ID of the project to get the ERC-20 currently backing that project's fee-token claim
    /// for.
    mapping(uint256 projectId => address claimToken) public claimableFeeTokenOf;

    /// @notice The amount of fee-project ERC-20 tokens claimable by each project.
    /// @dev This balance is denominated in the token stored in `claimableFeeTokenOf[projectId]`.
    /// @custom:param projectId The ID of the project to get the currently claimable fee-token balance of.
    mapping(uint256 projectId => uint256 claimableFeeTokens) public claimableFeeTokens;

    /// @notice Whether each project has already deployed its single supported Uniswap V4 pool.
    /// @dev This is a boolean because the hook intentionally supports only one deployed terminal-token pool per
    /// project. It marks the one-way transition from "deployPool consumes the accumulation" to "addLiquidity grows the
    /// position from continued accumulation"; reserved tokens keep accumulating in both phases (the hook never burns).
    /// @custom:param projectId The ID of the project to check deployment status for.
    mapping(uint256 projectId => bool hasDeployedPool) public hasDeployedPool;

    /// @notice The ruleset weight recorded when the hook first starts accumulating project tokens for each project.
    /// @dev This snapshot is later used to decide whether permissionless deployment is allowed after sufficient weight
    /// decay from the original accumulation-era ruleset.
    /// @custom:param projectId The ID of the project to get the initial accumulation-era ruleset weight of.
    mapping(uint256 projectId => uint256 weight) public initialWeightOf;

    /// @notice The Uniswap V4 pool key configured for each project and terminal-token pair.
    /// @dev A project can only deploy one terminal-token pool, but the pool key still needs the terminal token as part
    /// of the lookup because deployment-time and fee-routing logic are keyed by that pair.
    /// @custom:param projectId The ID of the project to get a configured pool key for.
    /// @custom:param terminalToken The terminal token paired with the project's token in the configured pool.
    mapping(uint256 projectId => mapping(address terminalToken => PoolKey)) public poolKeysOf;

    /// @notice The Uniswap V4 PositionManager token ID for each deployed project and terminal-token pair.
    /// @dev This is zero before deployment and nonzero after the first successful position mint.
    /// @custom:param projectId The ID of the project to get an LP position token ID for.
    /// @custom:param terminalToken The terminal token paired with the project's token in the deployed pool.
    mapping(uint256 projectId => mapping(address terminalToken => uint256 tokenId)) public tokenIdOf;

    /// @notice The lower tick of the currently active LP position for each project and terminal-token pair.
    /// @dev Recorded when a position is minted. `addLiquidity` compares the live corridor against these stored ticks to
    /// decide whether to top up the active position or re-range into a new one.
    /// @custom:param projectId The ID of the project.
    /// @custom:param terminalToken The terminal token paired with the project's token in the deployed pool.
    mapping(uint256 projectId => mapping(address terminalToken => int24 tickLower)) public activeTickLowerOf;

    /// @notice The upper tick of the currently active LP position for each project and terminal-token pair.
    /// @custom:param projectId The ID of the project.
    /// @custom:param terminalToken The terminal token paired with the project's token in the deployed pool.
    mapping(uint256 projectId => mapping(address terminalToken => int24 tickUpper)) public activeTickUpperOf;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Token address => number of in-flight fee routes currently finalizing claims for that token.
    mapping(address token => uint256 count) internal _inflightFeeRoutingCount;

    /// @notice Token address => total outstanding fee token claims across all projects.
    /// @dev Tracks fee tokens (e.g. JBX from project ID 1) held on behalf of projects that routed LP fees.
    ///      When multiple projects share a single hook clone, fee tokens accumulate in one contract.
    ///      Without this segregation, the accumulation / LP-funding paths would read raw balanceOf(this) and could
    ///      spend fee tokens reserved for other projects' unclaimed fee balances.
    /// @custom:param token The fee project's ERC-20 token address.
    mapping(address token => uint256 totalClaims) internal _totalOutstandingFeeTokenClaims;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory JBDirectory address.
    /// @param permissions JBPermissions address.
    /// @param tokens JBTokens address.
    /// @param permit2 The Permit2 utility.
    /// @param suckerRegistry The sucker registry for cross-chain surplus/supply queries.
    /// @param buybackHook The buyback-hook registry to target for force-direct cash-outs (chain-same; may be zero).
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IAllowanceTransfer permit2,
        IJBSuckerRegistry suckerRegistry,
        address buybackHook
    )
        JBPermissioned(permissions)
    {
        BUYBACK_HOOK = IJBBuybackHookRegistry(buybackHook);
        DIRECTORY = directory;
        PERMIT2 = permit2;
        PROJECTS = IJBDirectory(directory).PROJECTS();
        SUCKER_REGISTRY = suckerRegistry;
        TOKENS = tokens;
    }

    /// @notice Initialize per-instance config + chain-specific Uniswap V4 addresses on a clone. Callable once.
    /// @dev The implementation contract can be initialized by anyone, but this is harmless — each clone gets its own
    /// storage, so the implementation's state is never used. In normal production use, the deployer factory's
    /// `deployHookFor` atomically clones + initializes in the same transaction, so the call site for `initialize`
    /// is uncontested.
    /// @param initialFeeProjectId Project ID to receive LP fees.
    /// @param initialFeePercent Percentage of LP fees to route to fee project, out of `BPS` (e.g., 3800 = 38%).
    /// @param newPoolManager The Uniswap V4 PoolManager on this chain.
    /// @param newPositionManager The Uniswap V4 PositionManager on this chain.
    /// @param newOracleHook The Uniswap V4 oracle hook deployed against `newPoolManager` on this chain.
    function initialize(
        uint256 initialFeeProjectId,
        uint256 initialFeePercent,
        IPoolManager newPoolManager,
        IPositionManager newPositionManager,
        IHooks newOracleHook
    )
        external
    {
        // poolManager doubles as the "already initialized" sentinel: every legitimate initialize sets it non-zero.
        // Reject a zero poolManager up front so callers cannot accidentally leave the sentinel uninitialized and
        // re-enter `initialize` with different fee settings on the same clone.
        // Reject a second initialization: a non-zero `poolManager` means this clone was already configured.
        if (address(poolManager) != address(0)) revert JBUniswapV4LPSplitHook_AlreadyInitialized();
        // Reject a zero `poolManager` up front so the "already initialized" sentinel is never left unset, which would
        // let `initialize` be re-entered with different fee settings on the same clone.
        if (address(newPoolManager) == address(0)) revert JBUniswapV4LPSplitHook_AlreadyInitialized();

        // Fee percent is a fraction of `BPS` (10000 = 100%); a value above that is nonsensical and would over-route.
        if (initialFeePercent > BPS) {
            revert JBUniswapV4LPSplitHook_InvalidFeePercent({feePercent: initialFeePercent, maxFeePercent: BPS});
        }

        // If fees are configured, a valid fee project must be specified — otherwise fee tokens get stuck
        // because primaryTerminalOf(0, token) returns address(0).
        if (initialFeePercent > 0 && initialFeeProjectId == 0) {
            revert JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject({
                feePercent: initialFeePercent, feeProjectId: initialFeeProjectId
            });
        }

        // Validate the configured fee project actually exists (has a controller) so routed fees have a real
        // destination; a non-existent fee project would silently strand every fee collection.
        if (initialFeeProjectId != 0) {
            address feeController = _controllerOf(initialFeeProjectId);
            if (feeController == address(0)) {
                revert JBUniswapV4LPSplitHook_InvalidProjectId({
                    projectId: initialFeeProjectId, controller: feeController, projectToken: address(0)
                });
            }
        }

        // Persist the per-clone fee config and chain-specific Uniswap V4 wiring. These are write-once (the sentinel
        // check above guarantees this body runs at most once per clone), so they are effectively immutable thereafter.
        feeProjectId = initialFeeProjectId;
        feePercent = initialFeePercent;
        poolManager = newPoolManager;
        positionManager = newPositionManager;
        oracleHook = newOracleHook;
    }

    /// @notice Accept ETH transfers (needed for cashOut with native ETH and V4 TAKE operations).
    receive() external payable {}

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Whether this contract implements a given interface (ERC-165).
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBUniswapV4LPSplitHook).interfaceId || interfaceId == type(IJBSplitHook).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Whether a Uniswap V4 LP position has been minted for a project's terminal-token pair.
    function isPoolDeployed(uint256 projectId, address terminalToken) public view returns (bool deployed) {
        return tokenIdOf[projectId][terminalToken] != 0;
    }

    /// @notice The Uniswap V4 pool key (currency pair, fee, tick spacing, and hook) for a project's deployed pool.
    function poolKeyOf(uint256 projectId, address terminalToken) public view returns (PoolKey memory key) {
        return poolKeysOf[projectId][terminalToken];
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Look up the controller address for a project.
    function _controllerOf(uint256 projectId) internal view returns (address) {
        return address(IJBDirectory(DIRECTORY).controllerOf(projectId));
    }

    /// @notice Find the primary terminal token with the highest ETH-denominated value across the project's terminals.
    /// @dev Converts each token's balance to 18-decimal ETH using price feeds. Falls back to raw balance comparison
    /// when no price feed exists.
    /// @param projectId The ID of the project.
    /// @param controller The project's controller address.
    /// @return highestToken The token address with the highest ETH-denominated balance.
    function _findHighestValueTerminalTokenOf(
        uint256 projectId,
        address controller
    )
        internal
        view
        returns (address highestToken)
    {
        // Fetch all terminals registered for this project.
        IJBTerminal[] memory terminals = IJBDirectory(DIRECTORY).terminalsOf(projectId);

        // Track the highest ETH-denominated value found so far.
        uint256 highestValue;

        // Fallback tracking for tokens without a price feed.
        address highestUnpricedToken;
        uint256 highestUnpricedBalance;

        // The ETH currency identifier used for price normalization.
        uint32 ethCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));

        // Cache terminal count for gas-efficient iteration.
        uint256 terminalCount = terminals.length;

        // Iterate over each terminal to inspect its token balances.
        for (uint256 i; i < terminalCount; i++) {
            // Cast to IJBMultiTerminal to access store and accounting context methods.
            IJBMultiTerminal term = IJBMultiTerminal(address(terminals[i]));

            // Get the terminal's store for balance lookups.
            IJBTerminalStore termStore = term.STORE();

            // Get all accounting contexts (one per accepted token) for this project on this terminal.
            JBAccountingContext[] memory contexts = term.accountingContextsOf(projectId);

            // Cache context count for gas-efficient iteration.
            uint256 contextCount = contexts.length;

            // Iterate over each token accepted by this terminal.
            for (uint256 j; j < contextCount; j++) {
                // Load the accounting context for this token.
                JBAccountingContext memory context = contexts[j];

                // This hook keys each LP by terminal token and, when it operates, cashes out through the project's
                // primary terminal for that token. Holders may still cash out directly from same-token secondary
                // terminals, but those balances are not available to this hook's primary-terminal path.
                address primaryTerminal = _primaryTerminalOf({projectId: projectId, token: context.token});
                if (primaryTerminal == address(0) || primaryTerminal != address(term)) continue;

                // Look up how much of this token the terminal holds for the project.
                uint256 balance =
                    termStore.balanceOf({terminal: address(term), projectId: projectId, token: context.token});

                // Skip tokens with zero balance — they can't be the highest value.
                if (balance == 0) continue;

                // Convert the balance to an 18-decimal ETH-denominated value for apples-to-apples comparison.
                uint256 ethValue;

                if (context.currency == ethCurrency) {
                    // Native ETH: balance is already denominated in 18-decimal ETH.
                    ethValue = balance;
                } else {
                    // For non-ETH tokens, use the price feed to normalize to ETH.
                    // pricePerUnit = how many of `context.currency` per 1 ETH at `context.decimals` precision.
                    // ethValue (18-decimal) = balance * 10^18 / pricePerUnit.
                    try IJBController(controller).PRICES()
                        .pricePerUnitOf({
                        projectId: projectId,
                        pricingCurrency: context.currency,
                        unitCurrency: ethCurrency,
                        decimals: context.decimals
                    }) returns (
                        uint256 pricePerUnit
                    ) {
                        // Normalize the balance to 18-decimal ETH using the price feed result.
                        ethValue = mulDiv({x: balance, y: 10 ** 18, denominator: pricePerUnit});
                    } catch {
                        // No price feed available — skip this token so its raw balance
                        // cannot incorrectly win. If NO token has a price feed,
                        // the fallback below selects the highest raw balance instead.
                        if (balance > highestUnpricedBalance) {
                            highestUnpricedBalance = balance;
                            highestUnpricedToken = context.token;
                        }
                        continue;
                    }
                }

                // Update the highest value and corresponding token if this one exceeds the current best.
                if (ethValue > highestValue) {
                    highestValue = ethValue;
                    highestToken = context.token;
                }
            }
        }

        // If no priced token was found, fall back to the highest-balance unpriced token.
        if (highestToken == address(0)) highestToken = highestUnpricedToken;

        // Revert if no token with a non-zero balance was found across any terminal.
        if (highestToken == address(0)) revert JBUniswapV4LPSplitHook_NoTerminalTokenFound({projectId: projectId});
    }

    /// @notice Calculate the cash out rate (price floor).
    /// @dev Uses total on-chain surplus across all terminals (matching JBTerminalStore._computeCashOutFrom).
    /// When `scopeCashOutsToLocalBalances` is false, also includes remote cross-chain surplus and supply
    /// from the sucker registry for accurate omnichain pricing.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return terminalTokensPerProjectToken Terminal tokens returned per project token burned (18-decimal
    /// fixed-point).
    function _getCashOutRate(
        uint256 projectId,
        address terminalToken,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        view
        returns (uint256 terminalTokensPerProjectToken)
    {
        // Resolve the project's primary terminal for this token.
        IJBMultiTerminal terminal = IJBMultiTerminal(_primaryTerminalOf({projectId: projectId, token: terminalToken}));

        // Get the store for surplus queries.
        IJBTerminalStore store = terminal.STORE();

        // Read the terminal's declared currency for this token. Using `uint32(uint160(terminalToken))` here would
        // diverge from `_getIssuanceRate`, which reads the accounting context directly. The two paths must agree on
        // the same currency identifier so issuance and cash-out price the LP bounds against a consistent reference.
        JBAccountingContext memory accountingContext =
            terminal.accountingContextForTokenOf({projectId: projectId, token: terminalToken});
        uint256 decimals = accountingContext.decimals;
        uint256 currency = uint256(accountingContext.currency);

        // If the project doesn't scope cash outs to local balances, include remote cross-chain
        // surplus and supply in the bonding curve calculation.
        if (!ruleset.scopeCashOutsToLocalBalances()) {
            // Get on-chain total surplus across all terminals.
            try store.currentTotalSurplusOf({projectId: projectId, decimals: decimals, currency: currency}) returns (
                uint256 surplus
            ) {
                // Get on-chain total supply including pending reserved tokens.
                uint256 totalSupply = IJBController(controller).totalTokenSupplyWithReservedTokensOf(projectId);

                // Add remote cross-chain surplus and supply.
                surplus += SUCKER_REGISTRY.remoteSurplusOf({
                    projectId: projectId, decimals: decimals, currency: currency
                });
                totalSupply += SUCKER_REGISTRY.remoteTotalSupplyOf(projectId);

                // Apply the bonding curve with the combined on-chain + remote values.
                try store.currentReclaimableSurplusOf({
                    projectId: projectId, cashOutCount: _WAD, totalSupply: totalSupply, surplus: surplus
                }) returns (
                    uint256 reclaimableAmount
                ) {
                    terminalTokensPerProjectToken = reclaimableAmount;
                } catch {
                    terminalTokensPerProjectToken = 0;
                }
            } catch {
                terminalTokensPerProjectToken = 0;
            }
        } else {
            // Scoped to local balances — use total on-chain surplus directly.
            try store.currentTotalReclaimableSurplusOf({
                projectId: projectId, cashOutCount: _WAD, decimals: decimals, currency: currency
            }) returns (
                uint256 reclaimableAmount
            ) {
                terminalTokensPerProjectToken = reclaimableAmount;
            } catch {
                terminalTokensPerProjectToken = 0;
            }
        }
    }

    /// @notice Convert cash out rate to sqrtPriceX96 (price floor).
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return sqrtPriceX96 The cash-out-derived price encoded as a Uniswap V4 sqrtPriceX96.
    function _getCashOutRateSqrtPriceX96(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        // Sort tokens to determine which is token0 (lower address) for the Uniswap pair.
        (address token0,) = _sortTokens({tokenA: terminalToken, tokenB: projectToken});

        // Query the bonding curve cash out rate — terminal tokens received per project token burned.
        uint256 terminalTokensPerProjectToken = _getCashOutRate({
            projectId: projectId, terminalToken: terminalToken, controller: controller, ruleset: ruleset
        });

        // If the cash out rate is 0 (no surplus or negligible surplus), return an extreme price.
        // The correct extreme depends on token ordering since sqrtPriceX96 = sqrt(token1/token0):
        // - terminalToken is token0: token1(PT)/token0(TT) → ∞ as PT becomes worthless → MAX
        // - projectToken is token0: token1(TT)/token0(PT) → 0 as PT becomes worthless → MIN
        if (terminalTokensPerProjectToken == 0) {
            return token0 == terminalToken ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE;
        }

        // Use 1 WAD of token0 as the reference amount for price computation.
        uint256 token0Amount = _WAD;
        uint256 token1Amount;

        // Map the cash out rate to token0/token1 amounts depending on which side is the terminal token.
        if (token0 == terminalToken) {
            // terminal is token0: invert the rate to get projectTokens per terminalToken.
            token1Amount = mulDiv({x: token0Amount, y: _WAD, denominator: terminalTokensPerProjectToken});
        } else {
            // terminal is token1: the rate directly gives token1 per token0.
            token1Amount = terminalTokensPerProjectToken;
        }

        // Encode as sqrtPriceX96: sqrt(token1/token0) × 2^96.
        return uint160(mulDiv({x: sqrt(token1Amount), y: _Q96, denominator: sqrt(token0Amount)}));
    }

    /// @notice Calculate the issuance rate (price ceiling).
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return projectTokensPerTerminalToken Project tokens minted (after reserves) per terminal token (18-decimal).
    function _getIssuanceRate(
        uint256 projectId,
        address terminalToken,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        view
        returns (uint256 projectTokensPerTerminalToken)
    {
        // Extract the reserved token percentage from the ruleset metadata.
        uint16 reservedPercent = JBRulesetMetadataResolver.reservedPercent(ruleset);

        // Compute the raw mint output for 1 WAD of terminal tokens at the current weight.
        uint256 tokensPerTerminalToken = _getProjectTokensOutForTerminalTokensIn({
            projectId: projectId,
            terminalToken: terminalToken,
            terminalTokenInAmount: _WAD,
            controller: controller,
            ruleset: ruleset
        });

        // Subtract the reserved portion — only the non-reserved fraction trades on the open market.
        if (reservedPercent > 0) {
            projectTokensPerTerminalToken = mulDiv({
                x: tokensPerTerminalToken,
                y: uint256(JBConstants.MAX_RESERVED_PERCENT - reservedPercent),
                denominator: uint256(JBConstants.MAX_RESERVED_PERCENT)
            });
        } else {
            projectTokensPerTerminalToken = tokensPerTerminalToken;
        }
    }

    /// @notice Convert issuance rate to sqrtPriceX96 (price ceiling).
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return sqrtPriceX96 The issuance-derived price encoded as a Uniswap V4 sqrtPriceX96.
    function _getIssuanceRateSqrtPriceX96(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        // Sort tokens to determine which is token0 (lower address) for the Uniswap pair.
        (address token0,) = _sortTokens({tokenA: terminalToken, tokenB: projectToken});

        // Query the net issuance rate — project tokens minted (after reserves) per terminal token.
        uint256 projectTokensPerTerminalToken = _getIssuanceRate({
            projectId: projectId, terminalToken: terminalToken, controller: controller, ruleset: ruleset
        });

        // If the issuance rate is 0 (e.g. 100% reserved rate or zero weight), return an extreme price.
        // The correct extreme depends on token ordering since sqrtPriceX96 = sqrt(token1/token0):
        // - terminalToken is token0: token1(PT)/token0(TT) → 0 as PT becomes unmintable → MIN
        // - projectToken is token0: token1(TT)/token0(PT) → ∞ as PT becomes unmintable → MAX
        if (projectTokensPerTerminalToken == 0) {
            return token0 == terminalToken ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE - 1;
        }

        // Compute sqrtPriceX96 directly from the rate to avoid intermediate division
        // that rounds to 0 when projectTokensPerTerminalToken > 1e36.
        uint256 result;
        if (token0 == terminalToken) {
            // terminal is token0: sqrtPrice = sqrt(PT/TT) × 2^96 = sqrt(rate) × 2^96 / sqrt(WAD).
            result = mulDiv({x: sqrt(projectTokensPerTerminalToken), y: _Q96, denominator: sqrt(_WAD)});
        } else {
            // project is token0: sqrtPrice = sqrt(TT/PT) × 2^96 = sqrt(WAD) × 2^96 / sqrt(rate).
            result = mulDiv({x: sqrt(_WAD), y: _Q96, denominator: sqrt(projectTokensPerTerminalToken)});
        }

        // Clamp to valid Uniswap V4 sqrt price range.
        if (result < uint256(TickMath.MIN_SQRT_PRICE)) return TickMath.MIN_SQRT_PRICE;
        if (result > uint256(TickMath.MAX_SQRT_PRICE - 1)) return TickMath.MAX_SQRT_PRICE - 1;
        // The value was clamped into the uint160 Uniswap sqrt-price range above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(result);
    }

    /// @notice For given terminalToken amount, compute equivalent projectToken amount at current JuiceboxV4 price.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param terminalTokenInAmount The amount of terminal tokens to convert.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return projectTokenOutAmount The equivalent project token amount at the current issuance weight.
    function _getProjectTokensOutForTerminalTokensIn(
        uint256 projectId,
        address terminalToken,
        uint256 terminalTokenInAmount,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        view
        returns (uint256 projectTokenOutAmount)
    {
        // Look up the project's primary terminal for this token.
        address terminal = _primaryTerminalOf({projectId: projectId, token: terminalToken});
        // Fetch the terminal's accounting context (decimals, currency) for this project/token pair.
        JBAccountingContext memory context =
            IJBMultiTerminal(terminal).accountingContextForTokenOf({projectId: projectId, token: terminalToken});

        // Read the base currency from the ruleset (e.g. ETH=1, USD=2).
        uint32 baseCurrency = ruleset.baseCurrency();

        // Compute the weight ratio: if the terminal currency matches the base currency, use 10^decimals
        // directly; otherwise, convert via the price oracle.
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES()
                .pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });

        // Apply the ruleset weight to convert terminal tokens → project tokens at the current rate.
        projectTokenOutAmount = mulDiv({x: terminalTokenInAmount, y: ruleset.weight, denominator: weightRatio});
    }

    /// @notice Look up the current sqrt price of a pool.
    function _getSqrtPriceX96(PoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
    }

    /// @notice Compute Uniswap SqrtPriceX96 for current JuiceboxV4 price.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return sqrtPriceX96 The current Juicebox issuance price encoded as a Uniswap V4 sqrtPriceX96.
    function _getSqrtPriceX96ForCurrentJuiceboxPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        // Sort tokens to determine which is token0 (lower address) for the Uniswap pair.
        (address token0,) = _sortTokens({tokenA: terminalToken, tokenB: projectToken});

        // Use the net issuance rate (after reserved% deduction) so the fallback price
        // reflects the tokens a payer actually receives, not the gross weight.
        uint256 issuanceRate = _getIssuanceRate({
            projectId: projectId, terminalToken: terminalToken, controller: controller, ruleset: ruleset
        });

        // Guard against zero issuance (e.g. 100% reserved or weight=0) — return an extreme price
        // matching the token ordering convention used by _getIssuanceRateSqrtPriceX96.
        if (issuanceRate == 0) {
            return token0 == terminalToken ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE - 1;
        }

        // Compute sqrtPriceX96 directly from the rate, then clamp once to Uniswap's valid sqrt-price range.
        uint256 result;
        if (token0 == terminalToken) {
            result = mulDiv({x: sqrt(issuanceRate), y: _Q96, denominator: sqrt(_WAD)});
        } else {
            result = mulDiv({x: sqrt(_WAD), y: _Q96, denominator: sqrt(issuanceRate)});
        }

        // Clamp to valid Uniswap V4 sqrt price range.
        if (result < uint256(TickMath.MIN_SQRT_PRICE)) return TickMath.MIN_SQRT_PRICE;
        if (result > uint256(TickMath.MAX_SQRT_PRICE - 1)) return TickMath.MAX_SQRT_PRICE - 1;
        // The value was clamped into the uint160 Uniswap sqrt-price range above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(result);
    }

    /// @notice Get the terminal token balance currently held by this hook.
    /// @param terminalToken The terminal token to read.
    /// @return balance This hook's native ETH or ERC-20 balance for `terminalToken`.
    function _getTerminalTokenBalance(address terminalToken) internal view returns (uint256 balance) {
        if (_isNativeToken(terminalToken)) return address(this).balance;
        return IERC20(terminalToken).balanceOf(address(this));
    }

    /// @notice Whether `terminalToken` is Juicebox's native-token sentinel.
    /// @param terminalToken The terminal token to check.
    /// @return isNative True if `terminalToken` represents native ETH.
    function _isNativeToken(address terminalToken) internal pure returns (bool isNative) {
        return JBLPSplitHookHelpers.isNativeToken(terminalToken);
    }

    /// @notice Look up the next token ID from the position manager.
    function _nextTokenId() internal view returns (uint256) {
        return positionManager.nextTokenId();
    }

    /// @notice Look up the owner of a project.
    function _ownerOf(uint256 projectId) internal view returns (address) {
        return PROJECTS.ownerOf(projectId);
    }

    /// @notice Look up the primary terminal for a project/token pair.
    function _primaryTerminalOf(uint256 projectId, address token) internal view returns (address) {
        return address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: token}));
    }

    /// @notice Revert if `spender` still has any temporary ERC-20 allowance from this hook.
    /// @dev The hook grants exact-use allowances before external terminal calls. A leftover allowance means the
    /// downstream contract did not consume the approval as expected, leaving token spend authority live.
    /// @param token The ERC-20 token whose allowance was temporarily granted.
    /// @param spender The contract that was expected to consume the allowance.
    function _requireTemporaryAllowanceConsumed(address token, address spender) internal view {
        // Check after the external call returns, when a well-behaved terminal should have spent the full allowance.
        uint256 allowance = IERC20(token).allowance({owner: address(this), spender: spender});
        if (allowance != 0) {
            revert JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed({
                token: token, spender: spender, allowance: allowance
            });
        }
    }

    /// @notice Returns the portion of this contract's balance of `token` that is already committed to fee claims.
    /// @dev When no fee route is in flight, this is the total ERC-20 balance already promised to project beneficiaries
    /// through `claimableFeeTokens`.
    /// @dev While fee routing for `token` is mid-flight, reentrant code must conservatively treat the full current
    /// balance as unavailable because the final claim bookkeeping has not been written yet.
    /// @param token The ERC-20 token whose committed fee-claim balance should be returned.
    /// @return unavailableBalance The amount of `token` balance that callers must treat as unavailable.
    function _unavailableFeeTokenBalance(address token) internal view returns (uint256 unavailableBalance) {
        // During fee routing, the contract may already be holding freshly minted fee tokens that have not yet been
        // reflected in `_totalOutstandingFeeTokenClaims`. Treat the whole balance as unavailable until routing
        // finishes.
        if (_inflightFeeRoutingCount[token] != 0) return IERC20(token).balanceOf(address(this));
        return _totalOutstandingFeeTokenClaims[token];
    }

    /// @notice Get the terminal-token balance this hook can spend for LP operations.
    /// @dev ERC-20 balances can include fee-project tokens that already belong to claimants. Those unavailable tokens
    /// must not be used as cash-out proceeds or LP principal.
    /// @param terminalToken The terminal token to inspect.
    /// @return spendableBalance The balance available after excluding committed fee-token claims.
    function _spendableTerminalTokenBalance(address terminalToken) internal view returns (uint256 spendableBalance) {
        uint256 balance = _getTerminalTokenBalance(terminalToken);

        // Native fee proceeds are tracked as credits, not as claimable ERC-20 balances, so the whole balance is free.
        if (_isNativeToken(terminalToken)) return balance;

        // Keep claimable fee ERC-20s out of LP accounting so they cannot be spent before beneficiaries claim them.
        uint256 unavailable = _unavailableFeeTokenBalance(terminalToken);
        return balance > unavailable ? balance - unavailable : 0;
    }

    /// @notice Look up the ERC-20 token address for a project.
    function _tokenOf(uint256 projectId) internal view returns (address) {
        return address(IJBTokens(TOKENS).tokenOf(projectId));
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Convert the project's post-deployment accumulated reserved tokens into additional protocol-owned
    /// liquidity. Tops up the active position while the live cash-out/issuance corridor still matches the active
    /// position's ticks; once the corridor has drifted past `_RERANGE_THRESHOLD_TICKS`, BURNS the stale position to
    /// recover its principal and re-mints a single fresh position at the current corridor (folding in the new
    /// accumulation) — so all allocated funds stay in one maximally-efficient position rather than fragmenting across
    /// stale bands. The funding cash-out is forced DIRECTLY through the bonding curve (never the AMM this hook feeds),
    /// and the add is rejected if the pool's spot price has deviated from the oracle TWAP — bounding sandwich/JIT
    /// manipulation. Permissionless once the ruleset weight has decayed 10x from when accumulation began; otherwise
    /// requires `SET_BUYBACK_POOL` from the project owner. Safe for anyone to call.
    /// @param projectId The ID of the project whose accumulated tokens should be added as liquidity.
    /// @param terminalToken The terminal token paired with the project token in the deployed pool.
    /// @param minCashOutReturn Minimum terminal tokens to accept from the funding cash-out (slippage protection). Pass
    /// 0 to use the hook's default tolerance derived from the current cash-out rate.
    function addLiquidity(uint256 projectId, address terminalToken, uint256 minCashOutReturn) external {
        // Require a deployed pool for this project/terminal-token pair — `addLiquidity` only grows an existing pool.
        uint256 activeTokenId = tokenIdOf[projectId][terminalToken];
        if (activeTokenId == 0) {
            revert JBUniswapV4LPSplitHook_InvalidStageForAction({
                projectId: projectId, terminalToken: terminalToken, tokenId: activeTokenId
            });
        }

        // Fetch the controller and current ruleset once; both feed the auth gate, corridor math, and cash-out pricing.
        address controller = _controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        // Same authorization model as `deployPool`: permissionless once the weight has decayed 10x, else
        // SET_BUYBACK_POOL from the owner.
        _requireDeployOrAddAuth({projectId: projectId, ruleset: ruleset});

        // Nothing to deploy if no reserved tokens have accumulated since the last add.
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];
        if (projectTokenBalance == 0) revert JBUniswapV4LPSplitHook_NoTokensAccumulated({projectId: projectId});

        // Resolve the project's ERC-20 and the pool key once for the corridor math and the mint/burn calls below.
        address projectToken = _tokenOf(projectId);
        PoolKey memory key = poolKeysOf[projectId][terminalToken];

        // Reject the add while the pool's spot price is off the oracle TWAP. Stops a JIT/sandwich attacker from shoving
        // the pool price right before our add to make us mint (or burn) at a manipulated ratio.
        _requireSpotNearTwap({projectId: projectId, terminalToken: terminalToken, key: key});

        // Compute the live corridor and decide between topping up the active position and re-ranging into a new one.
        (int24 liveLower, int24 liveUpper) = _calculateTickBounds({
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });

        // Re-range once the live corridor has drifted past the threshold from the active position's stored ticks on
        // either side; below the threshold, topping up the existing position keeps gas down.
        bool rerange = _absTickDiff({a: liveLower, b: activeTickLowerOf[projectId][terminalToken]})
                > _RERANGE_THRESHOLD_TICKS
            || _absTickDiff({a: liveUpper, b: activeTickUpperOf[projectId][terminalToken]}) > _RERANGE_THRESHOLD_TICKS;

        // On re-range, burn the stale position so its principal can be redeployed into the live corridor. `preHeld` is
        // the terminal-token principal recovered from that burn, which the re-mint folds in (reducing the cash-out).
        uint256 preHeldTerminal;
        if (rerange) {
            (projectTokenBalance, preHeldTerminal) = _retireActivePosition({
                projectId: projectId,
                projectToken: projectToken,
                terminalToken: terminalToken,
                tokenId: activeTokenId,
                key: key
            });
        }

        _executeAddToPosition(
            AddLiquidityParams({
                projectId: projectId,
                projectToken: projectToken,
                terminalToken: terminalToken,
                key: key,
                tickLower: rerange ? liveLower : activeTickLowerOf[projectId][terminalToken],
                tickUpper: rerange ? liveUpper : activeTickUpperOf[projectId][terminalToken],
                projectTokenBalance: projectTokenBalance,
                minCashOutReturn: minCashOutReturn,
                forceDirectCashOut: true,
                preHeldTerminalTokens: preHeldTerminal,
                isNewPosition: rerange,
                existingTokenId: rerange ? 0 : activeTokenId,
                controller: controller,
                ruleset: ruleset
            })
        );

        // Surface the resulting position id and whether this add re-ranged (minted new) or topped up the active one.
        emit LiquidityAdded({
            projectId: projectId,
            terminalToken: terminalToken,
            tokenId: tokenIdOf[projectId][terminalToken],
            isNewPosition: rerange,
            caller: msg.sender
        });
    }

    /// @notice Collect the active position's accrued fees (so the fee project still gets its cut), then burn it to
    /// recover its principal back into this hook — the first half of a re-range.
    /// @dev Burn slippage bounds are 0: the caller already validated the spot price against the oracle TWAP, so burning
    /// at the current price is not manipulable. Recovered project tokens are folded into the project pool returned to
    /// the caller; recovered terminal tokens are returned so the re-mint can fold them in.
    /// @param projectId The ID of the project being re-ranged.
    /// @param projectToken The project's ERC-20 token address.
    /// @param terminalToken The terminal token paired with the project token.
    /// @param tokenId The active position to collect from and burn.
    /// @param key The pool key identifying the Uniswap V4 pool.
    /// @return projectTokenBalance The combined project tokens to redeploy: the accumulation ledger (which now includes
    /// any project-token fees the collect just carried in) plus the burned position's recovered project-token
    /// principal.
    /// @return preHeldTerminal The terminal-token principal recovered from the burn, to fold into the re-mint.
    function _retireActivePosition(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 tokenId,
        PoolKey memory key
    )
        internal
        returns (uint256 projectTokenBalance, uint256 preHeldTerminal)
    {
        // Collect + route accrued fees BEFORE burning so the fee project still receives its cut (the project-token side
        // is carried into the accumulation ledger), matching `rebalanceLiquidity`'s ordering.
        _collectAndRouteFees({
            projectId: projectId, projectToken: projectToken, terminalToken: terminalToken, tokenId: tokenId, key: key
        });

        // Snapshot balances so the post-burn deltas measure exactly the recovered principal for THIS project/token.
        uint256 projBefore = IERC20(projectToken).balanceOf(address(this));
        uint256 termBefore = _getTerminalTokenBalance(terminalToken);

        // Burn the stale position; its two-sided principal lands back in this hook (no AMM swap, so no swap slippage).
        _burnExistingPosition({tokenId: tokenId, key: key, decreaseAmount0Min: 0, decreaseAmount1Min: 0});

        // The project pool to redeploy = the accumulation ledger (re-read post-collect, so it includes any
        // project-token fees just carried in) plus the recovered project-token principal.
        projectTokenBalance =
            accumulatedProjectTokens[projectId] + (IERC20(projectToken).balanceOf(address(this)) - projBefore);
        // Hold the recovered terminal principal for the re-mint to fold in.
        preHeldTerminal = _getTerminalTokenBalance(terminalToken) - termBefore;
    }

    /// @notice Claims accumulated fee proceeds for `projectId` and sends them to `beneficiary`.
    /// @dev Requires `SET_BUYBACK_POOL` permission from the project's owner.
    /// @dev ERC-20 fee tokens are claimed first, followed by any fee credits that were accrued while the fee project
    /// had no ERC-20. Credit claims are best-effort: if the downstream controller rejects the transfer, the pending
    /// credit balance is restored so it can be retried later without blocking the ERC-20 claim path.
    /// @param projectId The project to claim accumulated fee proceeds for.
    /// @param beneficiary The address that should receive any claimed fee proceeds.
    function claimFeeTokensFor(uint256 projectId, address beneficiary) external {
        _requirePermissionFrom({
            account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        uint256 tokenAmount = claimableFeeTokens[projectId];
        if (tokenAmount > 0) {
            _claimFeeTokens({projectId: projectId, beneficiary: beneficiary, tokenAmount: tokenAmount});
        }

        uint256 creditAmount = claimableFeeCredits[projectId];
        if (creditAmount > 0) {
            _claimFeeCredits({projectId: projectId, beneficiary: beneficiary, creditAmount: creditAmount});
        }
    }

    /// @notice Claims ERC-20 fee tokens that have accrued for `projectId`.
    /// @dev State is cleared before the transfer so any revert from the ERC-20 send restores both bookkeeping and the
    /// event in the same frame.
    /// @param projectId The project whose fee-token claim to process.
    /// @param beneficiary The address that should receive the claimed ERC-20 fee tokens.
    /// @param tokenAmount The number of ERC-20 fee tokens to transfer.
    function _claimFeeTokens(uint256 projectId, address beneficiary, uint256 tokenAmount) internal {
        // Snapshot the token currently backing this project's fee claim before clearing storage.
        address feeProjectToken = claimableFeeTokenOf[projectId];

        // Clear the project's claim state first so a reverting transfer restores both storage and logs atomically.
        claimableFeeTokens[projectId] = 0;
        claimableFeeTokenOf[projectId] = address(0);
        // Release the reserved-balance accounting for the tokens that are about to leave the hook.
        _totalOutstandingFeeTokenClaims[feeProjectToken] -= tokenAmount;

        // Emit the claim after bookkeeping so the event only survives if the downstream transfer does too.
        emit FeeTokensClaimed({projectId: projectId, beneficiary: beneficiary, amount: tokenAmount, caller: msg.sender});
        IERC20(feeProjectToken).safeTransfer({to: beneficiary, value: tokenAmount});
    }

    /// @notice Claims fee proceeds that were accrued as fee-project credits for `projectId`.
    /// @dev Credits are optimistically cleared before the controller call. If the downstream controller rejects the
    /// transfer, the credit balance is restored so a paused or misconfigured fee project does not block ERC-20 claims.
    /// @param projectId The project whose fee-credit claim to process.
    /// @param beneficiary The address that should receive the claimed fee-project credits.
    /// @param creditAmount The number of fee-project credits to transfer.
    function _claimFeeCredits(uint256 projectId, address beneficiary, uint256 creditAmount) internal {
        // Optimistically clear the credit claim before the external call so reentrant reads cannot double-spend it.
        claimableFeeCredits[projectId] = 0;

        // Try the credit transfer directly. If the fee-project controller is paused or misconfigured, restore the
        // pending credits instead of unwinding an ERC-20 fee-token claim that already succeeded earlier in the frame.
        try IJBController(_controllerOf(feeProjectId))
            .transferCreditsFrom({
            holder: address(this), projectId: feeProjectId, recipient: beneficiary, creditCount: creditAmount
        }) {
            emit FeeTokensClaimed({
                projectId: projectId, beneficiary: beneficiary, amount: creditAmount, caller: msg.sender
            });
        } catch {
            // Restore the pending credits so the project owner can retry once the fee-project controller is usable.
            claimableFeeCredits[projectId] = creditAmount;
        }
    }

    /// @notice Collect accrued Uniswap LP trading fees for a project (from the active and every retired position) and
    /// route them back to its terminal balance. The terminal-token portion is deposited (minus an optional fee-project
    /// cut); the project-token portion is carried into the accumulation ledger to become future liquidity (never
    /// burned). Callable by anyone.
    /// @param projectId The ID of the project whose LP fees to collect.
    /// @param terminalToken The terminal token paired with the project token in the pool.
    // forge-lint: disable-next-line(mixed-case-function)
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external {
        // Ensure a pool has been deployed for this project/token pair.
        uint256 tokenId = tokenIdOf[projectId][terminalToken];
        if (tokenId == 0) {
            revert JBUniswapV4LPSplitHook_InvalidStageForAction({
                projectId: projectId, terminalToken: terminalToken, tokenId: tokenId
            });
        }

        // Resolve the project's ERC-20 token and pool key for fee collection.
        address projectToken = _tokenOf(projectId);
        PoolKey memory key = poolKeysOf[projectId][terminalToken];

        // Collect LP fees and route them to the project's terminal balance.
        _collectAndRouteFees({
            projectId: projectId, projectToken: projectToken, terminalToken: terminalToken, tokenId: tokenId, key: key
        });
    }

    /// @notice Create the Uniswap V4 pool and mint the initial LP position using the project's accumulated reserved
    /// tokens. A portion of those tokens is cashed out for terminal tokens so the position is two-sided. Permissionless
    /// once the ruleset weight has decayed to 10% of what it was when accumulation began; otherwise requires
    /// `SET_BUYBACK_POOL` permission from the project owner.
    /// @param projectId The ID of the project whose accumulated tokens should be deployed as LP.
    /// @param minCashOutReturn Minimum terminal tokens to accept from the cash-out (slippage protection). Pass 0 to use
    /// the hook's default 3% tolerance derived from the current cash-out rate.
    function deployPool(uint256 projectId, uint256 minCashOutReturn) external {
        // Allow anyone to deploy if the current ruleset's weight has decayed 10x from the initial weight.
        // Otherwise, require SET_BUYBACK_POOL permission from the project owner.
        address controller = _controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        _requireDeployOrAddAuth({projectId: projectId, ruleset: ruleset});

        // Auto-select the terminal token with the highest ETH-denominated value.
        address terminalToken = _findHighestValueTerminalTokenOf({projectId: projectId, controller: controller});

        if (tokenIdOf[projectId][terminalToken] != 0) {
            revert JBUniswapV4LPSplitHook_PoolAlreadyDeployed({
                projectId: projectId, terminalToken: terminalToken, tokenId: tokenIdOf[projectId][terminalToken]
            });
        }
        if (hasDeployedPool[projectId]) {
            revert JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported({
                projectId: projectId, terminalToken: terminalToken
            });
        }

        address projectToken = _tokenOf(projectId);
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];

        if (projectTokenBalance == 0) revert JBUniswapV4LPSplitHook_NoTokensAccumulated({projectId: projectId});

        address terminal = _primaryTerminalOf({projectId: projectId, token: terminalToken});
        if (terminal == address(0)) {
            revert JBUniswapV4LPSplitHook_InvalidTerminalToken({projectId: projectId, terminalToken: terminalToken});
        }

        // Mark the project deployed before any external calls so a reentrant deployPool reverts (already deployed) and
        // post-deploy inflows route to addLiquidity rather than re-entering this one-shot deploy path.
        hasDeployedPool[projectId] = true;

        _deployPoolAndAddLiquidity({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            minCashOutReturn: minCashOutReturn,
            controller: controller,
            ruleset: ruleset
        });

        emit ProjectDeployed({
            projectId: projectId,
            terminalToken: terminalToken,
            poolId: PoolId.unwrap(poolKeysOf[projectId][terminalToken].toId()),
            caller: msg.sender
        });
    }

    /// @notice Called by the Juicebox controller when reserved tokens are distributed to this hook's split. Tokens are
    /// accumulated in escrow both before AND after pool deployment: pre-deploy, `deployPool` consumes the accumulation;
    /// post-deploy, `addLiquidity` converts it into more liquidity. The hook never burns.
    /// @dev Only accepts reserved-token splits (groupId == 1). Reverts if the sender is not the project's controller or
    /// if the project has no ERC-20 token deployed.
    function processSplitWith(JBSplitHookContext calldata context) external payable {
        if (address(context.split.hook) != address(this)) {
            revert JBUniswapV4LPSplitHook_NotHookSpecifiedInContext({
                expectedHook: address(this), actualHook: address(context.split.hook)
            });
        }

        address controller = _controllerOf(context.projectId);
        if (controller == address(0)) {
            revert JBUniswapV4LPSplitHook_InvalidProjectId({
                projectId: context.projectId, controller: controller, projectToken: address(0)
            });
        }
        if (controller != msg.sender) {
            revert JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal({
                projectId: context.projectId, sender: msg.sender, controller: controller
            });
        }

        if (context.groupId != 1) {
            revert JBUniswapV4LPSplitHook_TerminalTokensNotAllowed({groupId: context.groupId, requiredGroupId: 1});
        }

        address projectToken = _tokenOf(context.projectId);

        // This hook requires an ERC-20 project token — credits cannot be paired as LP. Check before pulling tokens so
        // internal accounting stays clean on revert.
        if (projectToken == address(0)) {
            revert JBUniswapV4LPSplitHook_InvalidProjectId({
                projectId: context.projectId, controller: controller, projectToken: projectToken
            });
        }

        // Pull the allocated tokens from the controller via the granted allowance.
        // Use balance delta to handle fee-on-transfer tokens correctly.
        uint256 received;
        if (context.amount > 0) {
            uint256 balanceBefore = IERC20(projectToken).balanceOf(address(this));
            IERC20(projectToken).safeTransferFrom({from: msg.sender, to: address(this), value: context.amount});
            received = IERC20(projectToken).balanceOf(address(this)) - balanceBefore;
        }

        // Record the initial weight on first accumulation. Used later to gate permissionless deploy/add after the
        // weight has decayed 10x. Post-deployment this is already set, so the branch is a no-op.
        if (initialWeightOf[context.projectId] == 0) {
            (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(context.projectId);
            initialWeightOf[context.projectId] = ruleset.weight;
        }

        // Accumulate the received project tokens. This is the hook's only sink for reserved-token inflow, both before
        // AND after pool deployment — the hook never burns. Pre-deployment, `deployPool` consumes the accumulation;
        // post-deployment, `addLiquidity` does. Burning is a protocol-layer split-routing decision (route a split to
        // {projectId:0, hook:0, beneficiary:0xdead}), not this hook's job.
        _accumulateTokens({projectId: context.projectId, amount: received});

        // Defense-in-depth: verify the actual ERC-20 balance (minus outstanding fee token claims) covers the
        // accumulated total. Guards against accounting drift from custom controllers.
        uint256 spendable = IERC20(projectToken).balanceOf(address(this)) - _unavailableFeeTokenBalance(projectToken);
        if (spendable < accumulatedProjectTokens[context.projectId]) {
            revert JBUniswapV4LPSplitHook_InsufficientBalance({
                available: spendable, required: accumulatedProjectTokens[context.projectId]
            });
        }
    }

    /// @notice Burn the existing LP position and re-mint it with tick bounds recalculated from the project's current
    /// issuance and cash-out rates. Useful when rate changes have shifted the price range away from the active
    /// position. Requires `SET_BUYBACK_POOL` permission from the project owner.
    /// @param projectId The ID of the project whose LP position should be rebalanced.
    /// @param terminalToken The terminal token paired with the project token in the pool.
    /// @param decreaseAmount0Min Minimum amount of token0 to recover from the burned position (slippage protection).
    /// @param decreaseAmount1Min Minimum amount of token1 to recover from the burned position (slippage protection).
    function rebalanceLiquidity(
        uint256 projectId,
        address terminalToken,
        uint256 decreaseAmount0Min,
        uint256 decreaseAmount1Min
    )
        external
    {
        _requirePermissionFrom({
            account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        address terminal = _primaryTerminalOf({projectId: projectId, token: terminalToken});
        if (terminal == address(0)) {
            revert JBUniswapV4LPSplitHook_InvalidTerminalToken({projectId: projectId, terminalToken: terminalToken});
        }

        uint256 tokenId = tokenIdOf[projectId][terminalToken];
        if (tokenId == 0) {
            revert JBUniswapV4LPSplitHook_InvalidStageForAction({
                projectId: projectId, terminalToken: terminalToken, tokenId: tokenId
            });
        }

        address projectToken = _tokenOf(projectId);
        PoolKey memory key = poolKeysOf[projectId][terminalToken];

        _collectAndRouteFees({
            projectId: projectId, projectToken: projectToken, terminalToken: terminalToken, tokenId: tokenId, key: key
        });

        // Snapshot balances before burn to isolate recovered amounts created by this project's rebalance.
        uint256 projBalBefore = IERC20(projectToken).balanceOf(address(this));
        uint256 termBalBefore = _getTerminalTokenBalance(terminalToken);

        _burnExistingPosition({
            tokenId: tokenId, key: key, decreaseAmount0Min: decreaseAmount0Min, decreaseAmount1Min: decreaseAmount1Min
        });

        uint256 recoveredProjectTokens = IERC20(projectToken).balanceOf(address(this)) - projBalBefore;
        uint256 recoveredTerminalTokens = _getTerminalTokenBalance(terminalToken) - termBalBefore;

        // Cache controller and ruleset once for _mintRebalancedPosition and its callees.
        address controller = _controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        _mintRebalancedPosition({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            key: key,
            controller: controller,
            ruleset: ruleset,
            projectTokenBalance: recoveredProjectTokens,
            terminalTokenBalance: recoveredTerminalTokens
        });
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Absolute difference between two ticks, used for corridor-drift and TWAP-deviation comparisons.
    function _absTickDiff(int24 a, int24 b) internal pure returns (int24) {
        return a >= b ? a - b : b - a;
    }

    /// @notice Record incoming project tokens in the pre-deployment accumulation ledger.
    function _accumulateTokens(uint256 projectId, uint256 amount) internal {
        accumulatedProjectTokens[projectId] += amount;
    }

    /// @notice Deposit tokens into a project's primary terminal balance via `addToBalanceOf`.
    function _addToProjectBalance(uint256 projectId, address token, uint256 amount, bool isNative) internal {
        if (amount == 0) return;

        address terminal = _primaryTerminalOf({projectId: projectId, token: token});
        if (terminal == address(0)) {
            revert JBUniswapV4LPSplitHook_TerminalNotFound({projectId: projectId, token: token});
        }

        if (!isNative) {
            IERC20(token).forceApprove({spender: terminal, value: amount});
        }

        IJBMultiTerminal(terminal).addToBalanceOf{value: isNative ? amount : 0}({
            projectId: projectId, token: token, amount: amount, shouldReturnHeldFees: false, memo: "", metadata: ""
        });

        if (!isNative) _requireTemporaryAllowanceConsumed({token: token, spender: terminal});
    }

    /// @notice Add liquidity to a project's Uniswap V4 pool using its accumulated project tokens, by minting a fresh
    /// position at the current cash-out/issuance corridor. Used by the deploy path; `addLiquidity` reuses the same
    /// shared executor.
    /// @param projectId The ID of the project.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param minCashOutReturn Minimum cash out return (slippage protection).
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    function _addUniswapLiquidity(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 minCashOutReturn,
        address controller,
        JBRuleset memory ruleset
    )
        internal
    {
        // Nothing to add if the accumulation ledger is empty.
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];
        if (projectTokenBalance == 0) return;

        // Compute the LP position's tick bounds from the current issuance and cash out rates.
        (int24 tickLower, int24 tickUpper) = _calculateTickBounds({
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });

        // Mint the initial position. The deploy path does not force-direct the cash-out (pool is freshly initialized,
        // so there is no AMM to self-route through) — preserving the established deploy behavior.
        _executeAddToPosition(
            AddLiquidityParams({
                projectId: projectId,
                projectToken: projectToken,
                terminalToken: terminalToken,
                key: poolKeysOf[projectId][terminalToken],
                tickLower: tickLower,
                tickUpper: tickUpper,
                projectTokenBalance: projectTokenBalance,
                minCashOutReturn: minCashOutReturn,
                forceDirectCashOut: false,
                preHeldTerminalTokens: 0,
                isNewPosition: true,
                existingTokenId: 0,
                controller: controller,
                ruleset: ruleset
            })
        );
    }

    /// @notice Align tick down to the nearest spacing boundary (floor semantics).
    /// @dev Used for `tickUpper` so the LP range contracts toward the intended inner band on the upper side.
    function _alignTickToSpacing(int24 tick, int24 spacing) internal pure returns (int24 alignedTick) {
        return JBLPSplitHookHelpers.alignTickToSpacing({tick: tick, spacing: spacing});
    }

    /// @notice Align tick up to the nearest spacing boundary (ceiling semantics).
    /// @dev Used for `tickLower` so the LP range contracts toward the intended inner band on the lower side.
    /// Without this, flooring tickLower would expand the LP range downward by up to one spacing interval,
    /// exposing project liquidity at prices the bonding curve never sanctioned.
    function _alignTickToSpacingCeil(int24 tick, int24 spacing) internal pure returns (int24 alignedTick) {
        return JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: tick, spacing: spacing});
    }

    /// @notice Grant the PositionManager a time-limited Permit2 allowance so it can pull tokens during SETTLE.
    function _approveViaPermit2(address token, uint256 amount) internal {
        IERC20(token).forceApprove({spender: address(PERMIT2), value: amount});
        if (amount > type(uint160).max) {
            revert JBUniswapV4LPSplitHook_Permit2AmountOverflow({
                token: token, amount: amount, maxAmount: type(uint160).max
            });
        }
        PERMIT2.approve({
            token: token,
            spender: address(positionManager),
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint160(amount),
            // forge-lint: disable-next-line(unsafe-typecast)
            expiration: uint48(block.timestamp + _DEADLINE_SECONDS)
        });
    }

    /// @notice Burn an existing LP position via `BURN_POSITION` + `TAKE_PAIR` and recover its principal.
    /// @dev Called during rebalancing after fees have already been collected. The recovered tokens remain in
    /// this contract for the subsequent `_mintRebalancedPosition` call.
    /// @param tokenId The Uniswap V4 position NFT token ID to burn.
    /// @param key The pool key identifying the Uniswap V4 pool.
    /// @param decreaseAmount0Min Minimum amount of token0 to receive (slippage protection).
    /// @param decreaseAmount1Min Minimum amount of token1 to receive (slippage protection).
    function _burnExistingPosition(
        uint256 tokenId,
        PoolKey memory key,
        uint256 decreaseAmount0Min,
        uint256 decreaseAmount1Min
    )
        internal
    {
        // BURN_POSITION removes all remaining liquidity and destroys the NFT.
        // TAKE_PAIR transfers the recovered token0 and token1 to this contract.
        bytes memory burnActions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));

        bytes[] memory burnParams = new bytes[](2);
        // BURN_POSITION params: (tokenId, minAmount0, minAmount1, hookData).
        // Min amounts are caller-supplied slippage bounds; PositionManager accepts uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        burnParams[0] = abi.encode(tokenId, uint128(decreaseAmount0Min), uint128(decreaseAmount1Min), "");
        // TAKE_PAIR params: (currency0, currency1, recipient).
        burnParams[1] = abi.encode(key.currency0, key.currency1, address(this));

        _modifyLiquidities({unlockData: abi.encode(burnActions, burnParams), value: 0});
    }

    /// @notice Calculate tick bounds for liquidity position based on issuance and cash out rates.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return tickLower The lower tick bound of the LP position.
    /// @return tickUpper The upper tick bound of the LP position.
    function _calculateTickBounds(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        // Check if the cash out rate can be computed (may round to 0 with low-decimal tokens like USDC).
        uint256 cashOutRate = _getCashOutRate({
            projectId: projectId, terminalToken: terminalToken, controller: controller, ruleset: ruleset
        });

        if (cashOutRate == 0) {
            uint256 issuanceRate = _getIssuanceRate({
                projectId: projectId, terminalToken: terminalToken, controller: controller, ruleset: ruleset
            });

            if (issuanceRate == 0) {
                // No floor and no ceiling — full range LP. The project has no economic anchor (no surplus to set a
                // floor, no issuance to set a ceiling) so any market-set price is acceptable. Liquidity is intended
                // to track the prevailing market in this state rather than enforce a project-defined band.
                tickLower = _alignTickToSpacing({tick: TickMath.MIN_TICK, spacing: TICK_SPACING}) + TICK_SPACING;
                tickUpper = _alignTickToSpacing({tick: TickMath.MAX_TICK, spacing: TICK_SPACING}) - TICK_SPACING;
                return (tickLower, tickUpper);
            }

            // Cash out rate rounds to 0 due to precision loss (e.g. 6-decimal USDC with large token supply).
            // Center the LP range around the issuance price with minimal width.
            int24 issuanceTick = TickMath.getTickAtSqrtPrice(
                _getIssuanceRateSqrtPriceX96({
                    projectId: projectId,
                    terminalToken: terminalToken,
                    projectToken: projectToken,
                    controller: controller,
                    ruleset: ruleset
                })
            );
            issuanceTick = _alignTickToSpacing({tick: issuanceTick, spacing: TICK_SPACING});
            tickLower = issuanceTick - TICK_SPACING;
            tickUpper = issuanceTick + TICK_SPACING;

            // The zero-cash-out fallback builds a one-spacing band around the issuance tick. If that
            // issuance tick is near a TickMath edge, the band can spill outside V4's valid tick range.
            // Clamp to aligned ticks that stay inside the boundary and still leave room for a non-empty range.
            int24 zeroCashOutMinUsable =
                _alignTickToSpacing({tick: TickMath.MIN_TICK, spacing: TICK_SPACING}) + TICK_SPACING;
            int24 zeroCashOutMaxUsable =
                _alignTickToSpacing({tick: TickMath.MAX_TICK, spacing: TICK_SPACING}) - TICK_SPACING;
            if (tickLower < zeroCashOutMinUsable) tickLower = zeroCashOutMinUsable;
            if (tickUpper > zeroCashOutMaxUsable) tickUpper = zeroCashOutMaxUsable;
            // If both sides collapsed to one tick after clamping, widen the upper side by one spacing.
            if (tickLower >= tickUpper) tickUpper = tickLower + TICK_SPACING;
            return (tickLower, tickUpper);
        }

        int24 rawTickA = TickMath.getTickAtSqrtPrice(
            _getCashOutRateSqrtPriceX96({
                projectId: projectId,
                terminalToken: terminalToken,
                projectToken: projectToken,
                controller: controller,
                ruleset: ruleset
            })
        );
        int24 rawTickB = TickMath.getTickAtSqrtPrice(
            _getIssuanceRateSqrtPriceX96({
                projectId: projectId,
                terminalToken: terminalToken,
                projectToken: projectToken,
                controller: controller,
                ruleset: ruleset
            })
        );

        // Sort ticks so tickLower <= tickUpper regardless of token ordering.
        // Without sorting, pools where terminalToken is token0 (e.g. native ETH)
        // would have cashOut tick > issuance tick, collapsing into the narrow fallback.
        tickLower = rawTickA < rawTickB ? rawTickA : rawTickB;
        tickUpper = rawTickA < rawTickB ? rawTickB : rawTickA;

        // Align ASYMMETRICALLY: tickLower up, tickUpper down. Both moves contract the LP range toward the
        // intended price band. Flooring both ticks would expand the lower side by up to one spacing interval,
        // exposing project liquidity at prices below what the bonding curve sanctioned.
        tickLower = _alignTickToSpacingCeil({tick: tickLower, spacing: TICK_SPACING});
        tickUpper = _alignTickToSpacing({tick: tickUpper, spacing: TICK_SPACING});

        // Clamp to valid V4 tick range after alignment.
        int24 minUsable = _alignTickToSpacing({tick: TickMath.MIN_TICK, spacing: TICK_SPACING}) + TICK_SPACING;
        int24 maxUsable = _alignTickToSpacing({tick: TickMath.MAX_TICK, spacing: TICK_SPACING}) - TICK_SPACING;
        if (tickLower < minUsable) tickLower = minUsable;
        if (tickUpper > maxUsable) tickUpper = maxUsable;

        if (tickLower >= tickUpper) {
            uint160 currentSqrtPrice = _getSqrtPriceX96ForCurrentJuiceboxPrice({
                projectId: projectId,
                terminalToken: terminalToken,
                projectToken: projectToken,
                controller: controller,
                ruleset: ruleset
            });
            int24 currentTick = TickMath.getTickAtSqrtPrice(currentSqrtPrice);
            currentTick = _alignTickToSpacing({tick: currentTick, spacing: TICK_SPACING});
            tickLower = currentTick - TICK_SPACING;
            tickUpper = currentTick + TICK_SPACING;

            // Re-clamp to valid range — the fallback ticks may exceed boundaries when currentTick is near extremes.
            if (tickLower < minUsable) tickLower = minUsable;
            if (tickUpper > maxUsable) tickUpper = maxUsable;

            // Final validation: if clamping collapsed the range, revert rather than create an invalid position.
            if (tickLower >= tickUpper) {
                revert JBUniswapV4LPSplitHook_InvalidTickBounds({tickLower: tickLower, tickUpper: tickUpper});
            }
        }
    }

    /// @notice Carry leftover tokens after an LP add forward, never burning. Project-token dust returns to the
    /// accumulation ledger (becoming future liquidity); terminal-token dust is deposited into the project's terminal
    /// balance.
    /// @dev Uses balance-delta measurement so fee-on-transfer behavior and V4 SWEEP dust cannot mis-account leftovers,
    /// and `+=` on the ledger so a reentrant `processSplitWith` inflow during the (later) terminal deposit is
    /// preserved.
    function _carryLeftovers(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 intendedProjectAmount,
        uint256 intendedTerminalAmount,
        uint256 projBalBefore,
        uint256 termBalBefore
    )
        internal
    {
        uint256 postProjBal = IERC20(projectToken).balanceOf(address(this));
        uint256 postTermBal = _getTerminalTokenBalance(terminalToken);
        uint256 projConsumed = projBalBefore > postProjBal ? projBalBefore - postProjBal : 0;
        uint256 termConsumed = termBalBefore > postTermBal ? termBalBefore - postTermBal : 0;
        uint256 projLeftover = intendedProjectAmount > projConsumed ? intendedProjectAmount - projConsumed : 0;
        uint256 termLeftover = intendedTerminalAmount > termConsumed ? intendedTerminalAmount - termConsumed : 0;

        if (projLeftover > 0) accumulatedProjectTokens[projectId] += projLeftover;
        if (termLeftover > 0) {
            _addToProjectBalance({
                projectId: projectId,
                token: terminalToken,
                amount: termLeftover,
                isNative: _isNativeToken(terminalToken)
            });
        }
    }

    /// @notice Clear both Permit2's internal spender allowance and the ERC-20 allowance granted to Permit2.
    /// @dev V4 mints can consume less than the max amount approved for SETTLE, so clean up any residual authority
    /// after the position manager returns.
    /// @param token The ERC-20 token whose allowances should be revoked.
    function _clearPermit2Approval(address token) internal {
        // Permit2 treats `expiration: 0` as "valid until the end of this block", so use a nonzero timestamp in the
        // past while zeroing the amount. The amount blocks value pulls; the expired timestamp makes the revocation
        // explicit for any zero-value or edge-case allowance reads.
        PERMIT2.approve({token: token, spender: address(positionManager), amount: 0, expiration: 1});

        // Drop the ERC-20 approval to Permit2 as well, so the hook leaves no pull authority behind on either layer.
        IERC20(token).forceApprove({spender: address(PERMIT2), value: 0});
    }

    /// @notice Collect the active position's accrued Uniswap LP trading fees, then route them.
    /// @dev Terminal-token fees are added to the project's balance (minus an optional fee-project cut); project-token
    /// fees are carried back into the accumulation ledger to become future liquidity. The hook never burns. There is at
    /// most one position per project/terminal-token pair (re-ranging burns the old one and re-mints), so a single
    /// collection covers all of the project's LP fees.
    /// @param projectId The ID of the Juicebox project whose LP fees to collect.
    /// @param projectToken The project's ERC-20 token address.
    /// @param terminalToken The terminal token (e.g. ETH or USDC) paired with the project token.
    /// @param tokenId The active Uniswap V4 position NFT token ID.
    /// @param key The pool key identifying the Uniswap V4 pool.
    function _collectAndRouteFees(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 tokenId,
        PoolKey memory key
    )
        internal
    {
        // Snapshot balances before collection so the post-collection delta measures exactly the collected fees, not any
        // pre-existing balance (e.g. accumulated project tokens or another project's fee-token reserve).
        uint256 bal0Before = _currencyBalance(key.currency0);
        uint256 bal1Before = _currencyBalance(key.currency1);

        // `DECREASE_LIQUIDITY(0)` collects fees without removing principal; `TAKE_PAIR` transfers both currencies here.
        bytes memory feeActions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory feeParams = new bytes[](2);
        // DECREASE_LIQUIDITY params: (tokenId, liquidity=0, minAmount0=0, minAmount1=0, hookData).
        feeParams[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), "");
        // TAKE_PAIR params: (currency0, currency1, recipient).
        feeParams[1] = abi.encode(key.currency0, key.currency1, address(this));
        _modifyLiquidities({unlockData: abi.encode(feeActions, feeParams), value: 0});

        // Diff balances to determine exactly how much was collected as fees.
        uint256 feeAmount0 = _currencyBalance(key.currency0) - bal0Before;
        uint256 feeAmount1 = _currencyBalance(key.currency1) - bal1Before;

        // Carry the project-token side back to the accumulation ledger and route the terminal-token side. The carry
        // (a state write) happens before the external terminal route, so a reentrant collect/add sees consistent state.
        _routeCollectedFees({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            amount0: feeAmount0,
            amount1: feeAmount1
        });
    }

    /// @notice Compute the initial sqrtPriceX96 for pool initialization.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return sqrtPriceX96 The geometric midpoint between cash-out and issuance prices, as sqrtPriceX96.
    function _computeInitialSqrtPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        // Query the cash out rate (price floor) for fallback logic.
        uint256 cashOutRate = _getCashOutRate({
            projectId: projectId, terminalToken: terminalToken, controller: controller, ruleset: ruleset
        });

        // No surplus: initialize at the issuance price (price ceiling) since there's no floor.
        if (cashOutRate == 0) {
            return _getIssuanceRateSqrtPriceX96({
                projectId: projectId,
                terminalToken: terminalToken,
                projectToken: projectToken,
                controller: controller,
                ruleset: ruleset
            });
        }

        // Compute both price boundaries as sqrtPriceX96 values.
        uint160 sqrtPriceCashOut = _getCashOutRateSqrtPriceX96({
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });
        uint160 sqrtPriceIssuance = _getIssuanceRateSqrtPriceX96({
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });

        // Convert both prices to tick space for geometric midpoint calculation.
        int24 tickCashOut = TickMath.getTickAtSqrtPrice(sqrtPriceCashOut);
        int24 tickIssuance = TickMath.getTickAtSqrtPrice(sqrtPriceIssuance);

        // Sort ticks so tickLower ≤ tickUpper regardless of token ordering.
        int24 tickLower = tickCashOut < tickIssuance ? tickCashOut : tickIssuance;
        int24 tickUpper = tickCashOut < tickIssuance ? tickIssuance : tickCashOut;

        // If both ticks are equal, the midpoint is trivial — use the issuance price directly.
        if (tickLower == tickUpper) {
            return sqrtPriceIssuance;
        }

        // Place the initial price at the geometric midpoint of the floor and ceiling.
        int24 tickMid = _alignTickToSpacing({tick: (tickLower + tickUpper) / 2, spacing: TICK_SPACING});

        // Keep the midpoint inside TickMath's valid range before converting it back to sqrtPriceX96.
        int24 minTick = TickMath.MIN_TICK;
        int24 maxTick = TickMath.MAX_TICK;
        if (tickMid < minTick) tickMid = _alignTickToSpacing({tick: minTick, spacing: TICK_SPACING}) + TICK_SPACING;
        if (tickMid > maxTick) tickMid = _alignTickToSpacing({tick: maxTick, spacing: TICK_SPACING}) - TICK_SPACING;

        // Convert the midpoint tick back to sqrtPriceX96.
        return TickMath.getSqrtPriceAtTick(tickMid);
    }

    /// @notice Compute optimal cash-out amount based on LP position geometry.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param projectToken The project token address.
    /// @param totalProjectTokens Total project tokens available for the LP position.
    /// @param sqrtPriceInit The initial sqrt price of the pool.
    /// @param tickLower The lower tick bound of the LP position.
    /// @param tickUpper The upper tick bound of the LP position.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return cashOutAmount The number of project tokens to cash out for optimal terminal-token pairing.
    function _computeOptimalCashOutAmount(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        uint256 totalProjectTokens,
        uint160 sqrtPriceInit,
        int24 tickLower,
        int24 tickUpper,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        view
        returns (uint256 cashOutAmount)
    {
        uint256 cashOutRate = _getCashOutRate({
            projectId: projectId, terminalToken: terminalToken, controller: controller, ruleset: ruleset
        });

        if (cashOutRate == 0) return 0;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        Currency terminalCurrency = _toCurrency(terminalToken);
        bool terminalIsToken0 = Currency.unwrap(terminalCurrency) < projectToken;

        uint256 numerator;
        uint256 denominator;

        if (uint160(sqrtPriceInit) <= sqrtPriceA) {
            return terminalIsToken0 ? totalProjectTokens : 0;
        }
        if (uint160(sqrtPriceInit) >= sqrtPriceB) {
            return terminalIsToken0 ? 0 : totalProjectTokens;
        }

        uint256 diffPriceInitA = uint256(sqrtPriceInit) - uint256(sqrtPriceA);
        uint256 diffBPriceInit = uint256(sqrtPriceB) - uint256(sqrtPriceInit);

        if (terminalIsToken0) {
            // Correct ratio: amount0/amount1 = Q96² × (√Pb − √P) / (√P × √Pb × (√P − √Pa))
            // Computed step-by-step to avoid overflow.
            uint256 step1 = mulDiv({x: _Q96, y: diffBPriceInit, denominator: uint256(sqrtPriceInit)});
            numerator = mulDiv({x: step1, y: _Q96, denominator: uint256(sqrtPriceB)});
            denominator = diffPriceInitA;
        } else {
            // Correct ratio: amount1/amount0 = √P × √Pb × (√P − √Pa) / (Q96² × (√Pb − √P))
            uint256 step1 = mulDiv({x: uint256(sqrtPriceInit), y: uint256(sqrtPriceB), denominator: _Q96});
            numerator = mulDiv({x: step1, y: diffPriceInitA, denominator: _Q96});
            denominator = diffBPriceInit;
        }

        uint256 ratioE18 = mulDiv({x: numerator, y: _WAD, denominator: denominator});

        if (ratioE18 == 0) return 0;

        uint256 denom = cashOutRate + ratioE18;
        if (denom == 0) return 0;

        cashOutAmount = mulDiv({x: totalProjectTokens, y: ratioE18, denominator: denom});
    }

    /// @notice Create and initialize Uniswap V4 pool.
    /// @param projectId The ID of the project.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return key The pool key identifying the newly created Uniswap V4 pool.
    function _createAndInitializePool(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        returns (PoolKey memory key)
    {
        Currency terminalCurrency = _toCurrency(terminalToken);
        Currency projectCurrency = Currency.wrap(projectToken);

        // Sort currencies for V4 (currency0 < currency1)
        (Currency currency0, Currency currency1) = terminalCurrency < projectCurrency
            ? (terminalCurrency, projectCurrency)
            : (projectCurrency, terminalCurrency);

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: oracleHook
        });

        // Compute initial price at geometric mean of [cashOutRate, issuanceRate]
        uint160 sqrtPriceX96 = _computeInitialSqrtPrice({
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });

        // If the pool was already initialized (e.g. by an attacker or another deployer), validate that
        // the existing price falls within the project's economic tick range before accepting it.
        // This prevents frontrunning attacks where an attacker initializes the pool at an extreme
        // price, which would cause either a DoS (zero liquidity) or value extraction (single-sided
        // position at a manipulated price).
        uint160 existingSqrtPriceX96 = _getSqrtPriceX96(key);
        if (existingSqrtPriceX96 != 0) {
            // Compute the project's economic tick bounds (cashout floor to issuance ceiling).
            (int24 tickLower, int24 tickUpper) = _calculateTickBounds({
                projectId: projectId,
                terminalToken: terminalToken,
                projectToken: projectToken,
                controller: controller,
                ruleset: ruleset
            });

            // Reject existing prices outside or AT the boundary of the project's valid range. Boundary equality is
            // treated as out-of-bounds because a preinitialization at exactly `sqrtPriceAtTick(tickLower)` or
            // `sqrtPriceAtTick(tickUpper)` is the cheapest manipulation that still passes a loose comparison and
            // sites the LP at the extreme of the economic band, single-siding the initial liquidity.
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);
            if (existingSqrtPriceX96 <= sqrtPriceLower || existingSqrtPriceX96 >= sqrtPriceUpper) {
                revert JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds({
                    existingPrice: existingSqrtPriceX96, lowerBound: sqrtPriceLower, upperBound: sqrtPriceUpper
                });
            }

            // Use the existing pool price for downstream liquidity calculations.
            sqrtPriceX96 = existingSqrtPriceX96;
        }

        // Best-effort initialize the pool. Uniswap's PositionManager swallows initialize reverts and returns
        // `type(int24).max`, so this call is still required for uninitialized pools but non-fatal for initialized ones.
        positionManager.initializePool({key: key, sqrtPriceX96: sqrtPriceX96});

        // Store the pool key
        poolKeysOf[projectId][terminalToken] = key;
    }

    /// @notice The native ETH or ERC-20 balance this contract holds for a given Uniswap V4 currency.
    function _currencyBalance(Currency currency) internal view returns (uint256) {
        if (currency.isAddressZero()) {
            return address(this).balance;
        }
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /// @notice Deploy pool and add liquidity using accumulated tokens.
    /// @param projectId The ID of the project.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param minCashOutReturn Minimum cash out return (slippage protection).
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    function _deployPoolAndAddLiquidity(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 minCashOutReturn,
        address controller,
        JBRuleset memory ruleset
    )
        internal
    {
        // Initialize the pool if it hasn't been created yet.
        if (tokenIdOf[projectId][terminalToken] == 0) {
            _createAndInitializePool({
                projectId: projectId,
                projectToken: projectToken,
                terminalToken: terminalToken,
                controller: controller,
                ruleset: ruleset
            });
        }

        // Add liquidity using the accumulated project tokens.
        _addUniswapLiquidity({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            minCashOutReturn: minCashOutReturn,
            controller: controller,
            ruleset: ruleset
        });
    }

    /// @notice Shared cash-out-and-mint/increase core used by both the deploy path and `addLiquidity`.
    /// @dev Cashes out the optimal fraction of `projectTokenBalance` for terminal tokens, then either mints a new
    /// position (`isNewPosition`) or tops up `existingTokenId` via `INCREASE_LIQUIDITY`, at the pool's current price
    /// within `[tickLower, tickUpper]`. CEI: the accumulation ledger is zeroed before any external call so a reentrant
    /// add/deploy finds nothing to spend; leftovers are carried forward afterwards (never burned).
    function _executeAddToPosition(AddLiquidityParams memory p) internal {
        // CEI: clear the accumulation ledger before any external call. A reentrant `addLiquidity` then reverts
        // (NoTokensAccumulated) and a reentrant `deployPool` reverts (already deployed). Leftovers are re-added below.
        accumulatedProjectTokens[p.projectId] = 0;

        // Read the pool's actual current price. It may have been initialized by another party (e.g. REVDeployer) or
        // moved by trading since the last add.
        uint160 sqrtPriceInit = _getSqrtPriceX96(p.key);

        // Determine the optimal fraction of project tokens to cash out for terminal-token pairing within these ticks.
        uint256 cashOutAmount = _computeOptimalCashOutAmount({
            projectId: p.projectId,
            terminalToken: p.terminalToken,
            projectToken: p.projectToken,
            totalProjectTokens: p.projectTokenBalance,
            sqrtPriceInit: sqrtPriceInit,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            controller: p.controller,
            ruleset: p.ruleset
        });

        // If terminal tokens are already held (recovered from a re-range burn), cash out less project: each held
        // terminal token substitutes for ~ (1 / cashOutRate) project tokens. This keeps funds deployed and minimizes
        // both the burned-project amount and the leftover, rather than cashing out fresh and stranding the recovered
        // terminal.
        if (p.preHeldTerminalTokens > 0 && cashOutAmount > 0) {
            uint256 cashOutRate = _getCashOutRate({
                projectId: p.projectId, terminalToken: p.terminalToken, controller: p.controller, ruleset: p.ruleset
            });
            if (cashOutRate > 0) {
                uint256 reduction = mulDiv({x: p.preHeldTerminalTokens, y: _WAD, denominator: cashOutRate});
                cashOutAmount = cashOutAmount > reduction ? cashOutAmount - reduction : 0;
            }
        }

        // Fund the terminal-token side via a cash-out (optionally forced directly through the bonding curve), then add
        // any pre-held terminal tokens so the full terminal side is deployed into the position.
        uint256 terminalTokenAmount = p.preHeldTerminalTokens
            + _fundTerminalTokenSide({
                projectId: p.projectId,
                terminalToken: p.terminalToken,
                cashOutAmount: cashOutAmount,
                minCashOutReturn: p.minCashOutReturn,
                forceDirectCashOut: p.forceDirectCashOut,
                controller: p.controller,
                ruleset: p.ruleset
            });

        // The project-token side is whatever was not cashed out.
        uint256 projectTokenAmount = p.projectTokenBalance - cashOutAmount;

        // Map amounts to (amount0, amount1) by currency ordering.
        (address token0,) = _sortTokens({tokenA: p.projectToken, tokenB: Currency.unwrap(_toCurrency(p.terminalToken))});
        uint256 amount0 = p.projectToken == token0 ? projectTokenAmount : terminalTokenAmount;
        uint256 amount1 = p.projectToken == token0 ? terminalTokenAmount : projectTokenAmount;

        // Derive liquidity from the amounts at the pool's current price within the chosen ticks.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts({
            sqrtPriceX96: sqrtPriceInit,
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(p.tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(p.tickUpper),
            amount0: amount0,
            amount1: amount1
        });

        // Revert if the computed liquidity is zero — minting/increasing with no liquidity would waste gas.
        if (liquidity == 0) revert JBUniswapV4LPSplitHook_ZeroLiquidity({amount0: amount0, amount1: amount1});

        // Snapshot balances before settling to isolate this add's leftover from other projects' balances.
        uint256 projBalBefore = IERC20(p.projectToken).balanceOf(address(this));
        uint256 termBalBefore = _getTerminalTokenBalance(p.terminalToken);

        if (p.isNewPosition) {
            _mintPosition({
                key: p.key,
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidity: liquidity,
                amount0: amount0,
                amount1: amount1
            });
            // nextTokenId was incremented by MINT_POSITION, so (nextTokenId - 1) is the freshly minted ID.
            tokenIdOf[p.projectId][p.terminalToken] = _nextTokenId() - 1;
            activeTickLowerOf[p.projectId][p.terminalToken] = p.tickLower;
            activeTickUpperOf[p.projectId][p.terminalToken] = p.tickUpper;
        } else {
            _increaseLiquidity({
                tokenId: p.existingTokenId, key: p.key, liquidity: liquidity, amount0: amount0, amount1: amount1
            });
        }

        // Carry leftovers forward; never burn.
        _carryLeftovers({
            projectId: p.projectId,
            projectToken: p.projectToken,
            terminalToken: p.terminalToken,
            intendedProjectAmount: projectTokenAmount,
            intendedTerminalAmount: terminalTokenAmount,
            projBalBefore: projBalBefore,
            termBalBefore: termBalBefore
        });
    }

    /// @notice Build the buyback hook's `cashOutMinReclaimed` "skip" metadata that forces a cash-out directly through
    /// the bonding curve (skipping the AMM). Keyed to this hook's strong `BUYBACK_HOOK` registry reference — the
    /// contract that reads and re-keys this entry to the project's resolved buyback hook. Returns empty metadata when
    /// `BUYBACK_HOOK` is unset; the terminal's own `minTokensReclaimed` floor still applies.
    function _forceDirectCashOutMetadata() internal view returns (bytes memory) {
        if (address(BUYBACK_HOOK) == address(0)) return bytes("");

        return JBMetadataResolver.addToMetadata({
            originalMetadata: bytes(""),
            idToAdd: JBMetadataResolver.getId({purpose: "cashOutMinReclaimed", target: address(BUYBACK_HOOK)}),
            // (minimumSwapAmountOut = 0, skip = true): force the direct bonding-curve cash-out. The terminal's own
            // `minTokensReclaimed` floor enforces slippage, so no hook-level minimum is needed here.
            dataToAdd: abi.encode(uint256(0), true)
        });
    }

    /// @notice Cash out `cashOutAmount` project tokens for terminal tokens to fund one side of an LP add.
    /// @dev Enforces a rate-derived slippage floor (a caller minimum can only raise it) and reconciles the terminal's
    /// reported amount against the actual spendable balance delta (fee-on-transfer / fee-token-segregation safe). When
    /// `forceDirectCashOut` is set, attaches the buyback hook's `cashOutMinReclaimed` skip flag so the cash-out is
    /// routed DIRECTLY through the bonding curve, never through the AMM this hook is feeding.
    /// @return terminalTokenAmount The reconciled terminal-token amount obtained for LP pairing.
    function _fundTerminalTokenSide(
        uint256 projectId,
        address terminalToken,
        uint256 cashOutAmount,
        uint256 minCashOutReturn,
        bool forceDirectCashOut,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        returns (uint256 terminalTokenAmount)
    {
        address terminal = _primaryTerminalOf({projectId: projectId, token: terminalToken});
        if (terminal == address(0) || cashOutAmount == 0) return 0;

        // Snapshot only the balance not reserved for fee-token claims so the post-cash-out delta does not count ERC-20s
        // already owed to other projects' unclaimed routed LP fees.
        uint256 spendableBefore = _spendableTerminalTokenBalance(terminalToken);

        // The LP size and ticks derive from the current cash-out rate, so this funding cash-out must not settle below
        // that same rate floor. A caller-supplied minimum can only raise this floor; it cannot lower it.
        uint256 effectiveMinReturn = minCashOutReturn;
        uint256 cashOutRate = _getCashOutRate({
            projectId: projectId, terminalToken: terminalToken, controller: controller, ruleset: ruleset
        });
        if (cashOutRate > 0) {
            uint256 expectedReturn = mulDiv({x: cashOutAmount, y: cashOutRate, denominator: _WAD});
            uint256 derivedMinReturn = mulDiv({
                x: expectedReturn, y: _CASH_OUT_SLIPPAGE_NUMERATOR, denominator: _CASH_OUT_SLIPPAGE_DENOMINATOR
            });
            if (derivedMinReturn > effectiveMinReturn) effectiveMinReturn = derivedMinReturn;
        }

        // Optionally force the cash-out directly through the bonding curve (skip the AMM). Empty metadata falls back to
        // the project's normal cash-out path; the terminal still enforces `effectiveMinReturn`.
        bytes memory metadata = forceDirectCashOut ? _forceDirectCashOutMetadata() : bytes("");

        // Ask the terminal to cash out. The reported amount is the optimistic upper bound for what to credit to LP.
        uint256 reportedTerminalTokenAmount = IJBMultiTerminal(terminal)
            .cashOutTokensOf({
            holder: address(this),
            projectId: projectId,
            cashOutCount: cashOutAmount,
            tokenToReclaim: terminalToken,
            minTokensReclaimed: effectiveMinReturn,
            beneficiary: payable(address(this)),
            metadata: metadata,
            referralProjectId: 0
        });

        // Reconcile the terminal report with the actual spendable balance delta.
        uint256 spendableAfter = _spendableTerminalTokenBalance(terminalToken);
        uint256 actualTerminalTokenAmount = spendableAfter > spendableBefore ? spendableAfter - spendableBefore : 0;

        // Use the smaller value so LP funding never spends tokens that did not arrive, and never captures unrelated
        // balance already sitting in the hook.
        terminalTokenAmount = reportedTerminalTokenAmount < actualTerminalTokenAmount
            ? reportedTerminalTokenAmount
            : actualTerminalTokenAmount;

        // The derived or caller-provided minimum is enforced against the reconciled spendable amount.
        if (terminalTokenAmount < effectiveMinReturn) {
            revert JBUniswapV4LPSplitHook_InsufficientBalance({
                available: terminalTokenAmount, required: effectiveMinReturn
            });
        }
    }

    /// @notice Increase liquidity on an existing Uniswap V4 position via `INCREASE_LIQUIDITY`, settling both currencies
    /// and sweeping any unconsumed dust back to this contract. Mirrors `_mintPosition`'s settle/sweep + Permit2 dance.
    /// @param tokenId The existing position NFT to top up.
    /// @param key The pool key identifying the Uniswap V4 pool.
    /// @param liquidity The additional liquidity to add.
    /// @param amount0 The maximum amount of currency0 to spend.
    /// @param amount1 The maximum amount of currency1 to spend.
    function _increaseLiquidity(
        uint256 tokenId,
        PoolKey memory key,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    )
        internal
    {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        uint256 ethValue = 0;

        if (token0 == address(0)) {
            ethValue = amount0;
        } else if (amount0 > 0) {
            _approveViaPermit2({token: token0, amount: amount0});
        }

        if (token1 == address(0)) {
            ethValue = amount1;
        } else if (amount1 > 0) {
            _approveViaPermit2({token: token1, amount: amount1});
        }

        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](5);
        // INCREASE_LIQUIDITY params: (tokenId, liquidity, amount0Max, amount1Max, hookData).
        // Safe: amount0/amount1 are bounded by token balances which fit in uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(amount0), uint128(amount1), "");
        // SETTLE currency0: payerIsUser=true means PositionManager pulls from this contract via Permit2.
        params[1] = abi.encode(key.currency0, uint256(0), true);
        // SETTLE currency1.
        params[2] = abi.encode(key.currency1, uint256(0), true);
        // SWEEP leftover currency0 back to this contract.
        params[3] = abi.encode(key.currency0, address(this));
        // SWEEP leftover currency1 back to this contract.
        params[4] = abi.encode(key.currency1, address(this));

        _modifyLiquidities({unlockData: abi.encode(actions, params), value: ethValue});

        // Drop Permit2 allowances after PositionManager has pulled what it needs.
        if (token0 != address(0)) _clearPermit2Approval(token0);
        if (token1 != address(0) && token1 != token0) _clearPermit2Approval(token1);
    }

    /// @notice Mint a new concentrated-liquidity position via the Uniswap V4 PositionManager, settling both currencies
    /// and sweeping any unconsumed dust back to this contract.
    function _mintPosition(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    )
        internal
    {
        // Transfer ERC20 tokens to PositionManager (it will pull them during settle)
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        uint256 ethValue = 0;

        if (token0 == address(0)) {
            // currency0 is native ETH
            ethValue = amount0;
        } else if (amount0 > 0) {
            _approveViaPermit2({token: token0, amount: amount0});
        }

        if (token1 == address(0)) {
            // currency1 is native ETH (shouldn't happen since ETH is always currency0)
            ethValue = amount1;
        } else if (amount1 > 0) {
            _approveViaPermit2({token: token1, amount: amount1});
        }

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            // Safe: amount0/amount1 are bounded by token balances which fit in uint128.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(amount0),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(amount1),
            address(this),
            ""
        );
        // SETTLE currency0: payerIsUser=true means PositionManager pulls from msg.sender (this contract) via approve
        params[1] = abi.encode(key.currency0, uint256(0), true);
        // SETTLE currency1
        params[2] = abi.encode(key.currency1, uint256(0), true);
        // SWEEP leftover currency0 back to this contract
        params[3] = abi.encode(key.currency0, address(this));
        // SWEEP leftover currency1 back to this contract
        params[4] = abi.encode(key.currency1, address(this));

        _modifyLiquidities({unlockData: abi.encode(actions, params), value: ethValue});

        // Drop Permit2 allowance for currency0 after PositionManager has pulled what it needs.
        if (token0 != address(0)) _clearPermit2Approval(token0);
        // Drop currency1 separately only when it is an ERC-20 distinct from currency0; native ETH has no Permit2
        // allowance, and equal token addresses should not pay the extra clear call twice.
        if (token1 != address(0) && token1 != token0) _clearPermit2Approval(token1);
    }

    /// @notice Mint a new LP position with tick bounds recalculated from current issuance and cash-out rates.
    /// @dev Called after `_burnExistingPosition` has recovered the old position's principal. Computes liquidity from
    /// this contract's current token balances and the pool's live `sqrtPriceX96`. Reverts with
    /// `JBUniswapV4LPSplitHook_InsufficientLiquidity` if the resulting liquidity is zero (e.g. price moved entirely
    /// outside the new tick range), preventing `tokenIdOf` from being left stale. Any leftover tokens after minting
    /// are routed back to the project via per-project snapshot-delta leftover handling.
    /// @param projectId The ID of the Juicebox project to rebalance.
    /// @param projectToken The project's ERC-20 token address.
    /// @param terminalToken The terminal token paired with the project token.
    /// @param key The pool key identifying the Uniswap V4 pool.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    function _mintRebalancedPosition(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        PoolKey memory key,
        address controller,
        JBRuleset memory ruleset,
        uint256 projectTokenBalance,
        uint256 terminalTokenBalance
    )
        internal
    {
        (int24 tickLower, int24 tickUpper) = _calculateTickBounds({
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });

        // Use the actual pool price for liquidity calculation so the target matches the pool's
        // current state. Using JB issuance price here would produce suboptimal liquidity when the
        // pool price has diverged.
        uint160 sqrtPriceX96 = _getSqrtPriceX96(key);
        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // Map token balances to (amount0, amount1) matching the pool's currency ordering.
        Currency terminalCurrency = _toCurrency(terminalToken);
        (address token0,) = _sortTokens({tokenA: projectToken, tokenB: Currency.unwrap(terminalCurrency)});
        uint256 amount0 = projectToken == token0 ? projectTokenBalance : terminalTokenBalance;
        uint256 amount1 = projectToken == token0 ? terminalTokenBalance : projectTokenBalance;

        // Derive the maximum liquidity mintable from our balances at the current pool price.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts({
            sqrtPriceX96: sqrtPriceX96,
            sqrtPriceAX96: sqrtPriceA,
            sqrtPriceBX96: sqrtPriceB,
            amount0: amount0,
            amount1: amount1
        });

        if (liquidity > 0) {
            // Snapshot balances before minting to isolate leftovers created by this project's rebalance.
            uint256 projBalBeforeMint = IERC20(projectToken).balanceOf(address(this));
            uint256 termBalBeforeMint = _getTerminalTokenBalance(terminalToken);

            _mintPosition({
                key: key,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                amount0: amount0,
                amount1: amount1
            });

            // Read the token ID after minting — nextTokenId was incremented by the MINT_POSITION action
            // inside modifyLiquidities, so (nextTokenId - 1) is the ID that was just minted.
            tokenIdOf[projectId][terminalToken] = _nextTokenId() - 1;
            // Record the rebalanced position's ticks so `addLiquidity`'s drift comparison uses the live band.
            activeTickLowerOf[projectId][terminalToken] = tickLower;
            activeTickUpperOf[projectId][terminalToken] = tickUpper;

            // Carry leftovers forward; never burn. Project-token dust returns to the accumulation ledger,
            // terminal-token dust is deposited into the project's terminal balance.
            _carryLeftovers({
                projectId: projectId,
                projectToken: projectToken,
                terminalToken: terminalToken,
                intendedProjectAmount: projectTokenBalance,
                intendedTerminalAmount: terminalTokenBalance,
                projBalBefore: projBalBeforeMint,
                termBalBefore: termBalBeforeMint
            });
        } else {
            // Zero liquidity means the position cannot be re-created (e.g., price moved
            // outside tick range making the position single-sided with zero on one side).
            // Revert to prevent bricking the project's LP — the old position was already
            // burned by the BURN_POSITION action above, so this protects the invariant
            // that tokenIdOf is always nonzero for deployed projects.
            revert JBUniswapV4LPSplitHook_InsufficientLiquidity({liquidity: liquidity});
        }
    }

    /// @notice Execute a batched position-manager action (mint, burn, decrease, etc.) with a short deadline.
    function _modifyLiquidities(bytes memory unlockData, uint256 value) internal {
        positionManager.modifyLiquidities{value: value}({
            unlockData: unlockData, deadline: block.timestamp + _DEADLINE_SECONDS
        });
    }

    /// @notice Authorize a deploy/add: permissionless once the ruleset weight has decayed 10x from when accumulation
    /// began, otherwise require `SET_BUYBACK_POOL` from the project owner.
    function _requireDeployOrAddAuth(uint256 projectId, JBRuleset memory ruleset) internal view {
        uint256 initialWeight = initialWeightOf[projectId];
        if (initialWeight == 0 || ruleset.weight * 10 > initialWeight) {
            _requirePermissionFrom({
                account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_POOL
            });
        }
    }

    /// @notice Revert if the pool's spot price has deviated from the oracle TWAP by more than
    /// `_MAX_TWAP_DEVIATION_TICKS`, or if the TWAP cannot be read. Prevents a JIT/sandwich attacker from skewing the
    /// add ratio by moving the pool price right before the add.
    function _requireSpotNearTwap(uint256 projectId, address terminalToken, PoolKey memory key) internal view {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = _TWAP_WINDOW;
        secondsAgos[1] = 0;

        int56[] memory tickCumulatives;
        // The oracle reverts when it has not accrued enough history yet. In that case the spot price cannot be
        // validated, so refuse the add (tokens keep accumulating safely; retry once the oracle warms up). Never fall
        // back to spot — that is exactly the value being validated.
        try IGeomeanOracle(address(oracleHook)).observe({key: key, secondsAgos: secondsAgos}) returns (
            int56[] memory cumulatives, uint160[] memory
        ) {
            tickCumulatives = cumulatives;
        } catch {
            revert JBUniswapV4LPSplitHook_TwapUnavailable({projectId: projectId, terminalToken: terminalToken});
        }

        if (tickCumulatives.length < 2) {
            revert JBUniswapV4LPSplitHook_TwapUnavailable({projectId: projectId, terminalToken: terminalToken});
        }

        // Arithmetic-mean tick over the window, rounding toward negative infinity (canonical V3 TWAP computation).
        // `_TWAP_WINDOW` is a small positive constant (1800), so the cast to a signed window cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        int56 window = int56(uint56(_TWAP_WINDOW));
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        // The mean of in-range cumulative ticks is itself a valid tick, well within int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 twapTick = int24(tickCumulativesDelta / window);
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % window != 0)) twapTick--;

        int24 spotTick = TickMath.getTickAtSqrtPrice(_getSqrtPriceX96(key));
        if (_absTickDiff({a: spotTick, b: twapTick}) > _MAX_TWAP_DEVIATION_TICKS) {
            revert JBUniswapV4LPSplitHook_PriceDeviationTooHigh({
                spotTick: spotTick, twapTick: twapTick, maxDeviationTicks: _MAX_TWAP_DEVIATION_TICKS
            });
        }
    }

    /// @notice Split collected LP fees into their terminal-token and project-token sides: route the terminal-token side
    /// to the project (minus an optional fee-project cut), and carry the project-token side into the accumulation
    /// ledger to become future liquidity. The hook never burns.
    function _routeCollectedFees(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 amount0,
        uint256 amount1
    )
        internal
    {
        if (amount0 == 0 && amount1 == 0) return;

        Currency terminalCurrency = _toCurrency(terminalToken);
        (address token0,) = _sortTokens({tokenA: projectToken, tokenB: Currency.unwrap(terminalCurrency)});

        bool terminalIsToken0 = token0 == Currency.unwrap(terminalCurrency);
        uint256 terminalFee = terminalIsToken0 ? amount0 : amount1;
        uint256 projectFee = terminalIsToken0 ? amount1 : amount0;

        // Carry the project-token side back to the accumulation ledger (a pure state write, done BEFORE the external
        // terminal route below for CEI safety) so it is added as liquidity by the next `addLiquidity` instead of
        // burned.
        if (projectFee > 0) accumulatedProjectTokens[projectId] += projectFee;

        // Route the terminal-token side to the project's balance.
        if (terminalFee > 0) {
            _routeFeesToProject({projectId: projectId, terminalToken: terminalToken, amount: terminalFee});
        }
    }

    /// @notice Route fees back to the project.
    /// @dev Fee routing uses zero slippage (minReturnedTokens = 0) by design. Slippage protection
    /// is the responsibility of the fee project's pay hook (e.g., its buyback hook). An alternative
    /// approach — calling `previewPayFor` and using the result as a minimum — was considered but
    /// deemed unnecessary given the existing hook-level protection. Fees are small amounts routed
    /// to the protocol fee project; MEV extraction is economically insignificant relative to gas costs.
    function _routeFeesToProject(uint256 projectId, address terminalToken, uint256 amount) internal {
        if (amount == 0) return;

        uint256 feeAmount = (amount * feePercent) / BPS;
        uint256 remainingAmount = amount - feeAmount;

        uint256 beneficiaryTokenCount = 0;
        if (feeAmount > 0) {
            address feeTerminal = _primaryTerminalOf({projectId: feeProjectId, token: terminalToken});
            if (feeTerminal == address(0)) {
                // If no fee terminal is configured, the fee project simply misses this collection and the full amount
                // stays in the project's normal split-hook flow.
                feeAmount = 0;
                remainingAmount = amount;
            } else {
                // Look up the fee project's ERC-20 BEFORE the pay() call so we can pre-increment
                // _totalOutstandingFeeTokenClaims. This prevents a reentrancy through terminal.pay()
                // → pay hooks → collectAndRouteLPFees() from seeing stale claims and double-counting
                // fee tokens in the accumulation / leftover-handling paths.
                address feeProjectToken = _tokenOf(feeProjectId);

                // If this project already has unclaimed ERC-20 fee tokens, keep using that snapshotted token address.
                // Otherwise a fee-project token migration could strand the earlier claim behind a new token contract.
                address claimToken = claimableFeeTokenOf[projectId];
                // Reject mixing outstanding claims across different fee-project ERC-20s in the same project bucket.
                if (claimToken != address(0) && claimToken != feeProjectToken) {
                    revert JBUniswapV4LPSplitHook_UnclaimedFeeTokenChanged({
                        previousToken: claimToken, nextToken: feeProjectToken
                    });
                }

                // Only ERC-20 fee projects need a token-balance snapshot. Credit-only fee projects use the
                // terminal's returned credit count and skip the balance reconciliation below.
                uint256 feeProjectTokenBalanceBefore;

                // Pre-increment with feeAmount as a conservative estimate. The actual token count
                // may differ, but any re-entrant call during pay() will see an inflated reserve,
                // which safely prevents over-spending. We reconcile after pay() returns.
                if (feeProjectToken != address(0)) {
                    // Snapshot before `pay()` so the post-pay delta measures only newly minted fee-project ERC-20s.
                    feeProjectTokenBalanceBefore = IERC20(feeProjectToken).balanceOf(address(this));

                    // Reserve conservatively during the external call. This prevents reentrant LP-fee collection or
                    // accumulation paths from treating in-flight fee tokens as free project-token balance.
                    _totalOutstandingFeeTokenClaims[feeProjectToken] += feeAmount;
                    _inflightFeeRoutingCount[feeProjectToken] += 1;
                }

                // Fee terminal revert blocks fee collection — accepted since the fee project is
                // protocol-controlled and expected to maintain a functioning terminal.
                // minReturnedTokens is 0 by design: slippage protection is the fee project's
                // responsibility (via its own data hook / buyback hook), not this contract's.
                // Setting a floor here would risk reverting on small fee amounts where
                // mulDiv rounding yields 0 tokens, and any non-trivial floor would require
                // an oracle dependency that doesn't belong in the LP split hook.
                //
                // Use the ERC-20 balance actually received by this hook instead of trusting pay()'s return value.
                // If the terminal token is also the fee-project token, subtract the fee payment from the pre-call
                // balance before measuring freshly received tokens.
                if (_isNativeToken(terminalToken)) {
                    beneficiaryTokenCount = IJBMultiTerminal(feeTerminal).pay{value: feeAmount}({
                        projectId: feeProjectId,
                        token: terminalToken,
                        amount: feeAmount,
                        beneficiary: address(this),
                        minReturnedTokens: 0,
                        memo: "LP Fee",
                        metadata: ""
                    });
                } else {
                    IERC20(terminalToken).forceApprove({spender: feeTerminal, value: feeAmount});
                    beneficiaryTokenCount = IJBMultiTerminal(feeTerminal)
                        .pay({
                        projectId: feeProjectId,
                        token: terminalToken,
                        amount: feeAmount,
                        beneficiary: address(this),
                        minReturnedTokens: 0,
                        memo: "LP Fee",
                        metadata: ""
                    });

                    _requireTemporaryAllowanceConsumed({token: terminalToken, spender: feeTerminal});
                }

                // Reconcile the pre-incremented reserve with the actual ERC-20s received by this hook.
                if (feeProjectToken != address(0)) {
                    // Start from the pre-pay balance. Any increase above this baseline is newly claimable fee tokens.
                    uint256 expectedBalanceWithoutFeeTokens = feeProjectTokenBalanceBefore;

                    // If fees are paid in the fee-project ERC-20 itself, the `pay()` call first transfers `feeAmount`
                    // out of this hook. Subtract it from the baseline so the later balance delta does not hide freshly
                    // minted fee-project tokens. A successful pay implies the pre-pay balance covered `feeAmount`.
                    if (terminalToken == feeProjectToken) expectedBalanceWithoutFeeTokens -= feeAmount;

                    // Prefer the observed balance delta over the terminal return value so fee-on-transfer or
                    // nonstandard token behavior cannot overstate what this hook actually received.
                    uint256 feeProjectTokenBalanceAfter = IERC20(feeProjectToken).balanceOf(address(this));
                    beneficiaryTokenCount = feeProjectTokenBalanceAfter > expectedBalanceWithoutFeeTokens
                        ? feeProjectTokenBalanceAfter - expectedBalanceWithoutFeeTokens
                        : 0;

                    // Remove the conservative estimate and reserve the reconciled token amount for later claiming.
                    _totalOutstandingFeeTokenClaims[feeProjectToken] =
                        _totalOutstandingFeeTokenClaims[feeProjectToken] - feeAmount + beneficiaryTokenCount;
                    _inflightFeeRoutingCount[feeProjectToken] -= 1;
                }

                // Track fee tokens for later claiming. Route to the correct tracker based on
                // whether the fee project has an ERC-20 deployed (claimable via safeTransfer)
                // or uses internal credits only (claimable via controller.transferCreditsFrom).
                if (beneficiaryTokenCount > 0) {
                    if (feeProjectToken != address(0)) {
                        // ERC-20 exists: track as claimable ERC-20 tokens.
                        claimableFeeTokenOf[projectId] = feeProjectToken;
                        claimableFeeTokens[projectId] += beneficiaryTokenCount;
                    } else {
                        // No ERC-20: track as claimable credits.
                        claimableFeeCredits[projectId] += beneficiaryTokenCount;
                    }
                }
            }
        }

        if (remainingAmount > 0) {
            _addToProjectBalance({
                projectId: projectId,
                token: terminalToken,
                amount: remainingAmount,
                isNative: _isNativeToken(terminalToken)
            });
        }

        emit LPFeesRouted({
            projectId: projectId,
            terminalToken: terminalToken,
            totalAmount: amount,
            feeAmount: feeAmount,
            remainingAmount: remainingAmount,
            feeTokensMinted: beneficiaryTokenCount,
            caller: msg.sender
        });
    }

    /// @notice Sort two token addresses into the canonical Uniswap V4 ordering (lower address = token0).
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return JBLPSplitHookHelpers.sortTokens({tokenA: tokenA, tokenB: tokenB});
    }

    /// @notice Convert a Juicebox terminal-token address to the equivalent Uniswap V4 `Currency`.
    /// @dev Juicebox uses the sentinel `JBConstants.NATIVE_TOKEN` for ETH; Uniswap V4 uses `address(0)`.
    function _toCurrency(address terminalToken) internal pure returns (Currency) {
        return JBLPSplitHookHelpers.toCurrency(terminalToken);
    }
}
