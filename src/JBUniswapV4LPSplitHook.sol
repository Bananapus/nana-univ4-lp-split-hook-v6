// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
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
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";

import {IJBUniswapV4LPSplitHook} from "./interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBLPSplitHookHelpers} from "./libraries/JBLPSplitHookHelpers.sol";
import {JBUniswapV4LPSplitHookMath} from "./libraries/JBUniswapV4LPSplitHookMath.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/// @notice A split hook that builds and manages a Uniswap V4 liquidity position for a Juicebox project, using the
/// project's reserved-token distributions as the seed capital. The lifecycle has two stages:
///
/// 1. Accumulation — Each time the project distributes reserved tokens, the hook's share is held in escrow. Once the
/// project owner (or anyone, after sufficient weight decay) triggers `deployPool`, the accumulated tokens are minted as
/// a single-sided ask position (no funding cash-out) spanning from the pool's live price out to the project's
/// issuance/cash-out corridor.
///
/// 2. Grow-and-route — After the pool exists, further reserved tokens sent to the hook keep accumulating in escrow.
/// Anyone can later call `addLiquidity` (permissionless once the weight has decayed 10x, otherwise owner-gated) to
/// convert the accumulated tokens into more protocol-owned liquidity: it checks the pool's spot price against the
/// oracle TWAP to reject sandwiched adds, then mints another single-sided ask position (no funding cash-out)
/// spanning from the pool's live price out to the project's issuance/cash-out corridor. LP trading fees are collected
/// periodically from the project's currently tracked position and routed back to the project's terminal balance,
/// with an optional protocol fee split to a configurable fee project. The hook never burns project tokens:
/// supply-reducing burns are a protocol-layer split-routing decision, so every token this hook touches ends up as
/// liquidity.
///
/// The hook also supports `rebalanceLiquidity`, which re-centers the LP tick range around the project's current
/// issuance and cash-out prices when they drift from the original deployment parameters.
///
/// @dev Each clone manages exactly one Uniswap V4 pool per project (one terminal-token pairing). Pool deployment
/// requires `SET_BUYBACK_POOL` permission. The pool uses a 1% fee tier, 200-tick spacing, and a shared oracle hook
/// for TWAP observations.
contract JBUniswapV4LPSplitHook is IJBUniswapV4LPSplitHook, IJBSplitHook, JBPermissioned {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when `initialize` is called on a clone whose chain-specific properties have already been set.
    error JBUniswapV4LPSplitHook_AlreadyInitialized();
    /// @notice Thrown when a pre-initialized pool's price falls outside the project's economic tick range.
    /// @dev This prevents frontrunning attacks where an attacker initializes the pool at an extreme price.
    error JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds(
        uint160 existingPrice, uint160 lowerBound, uint160 upperBound
    );
    /// @notice Thrown when a non-zero fee percent is configured without a fee project to route the fee to.
    error JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject(uint256 feePercent, uint256 feeProjectId);
    /// @notice Thrown when the hook's held balance of a token is less than the amount an operation requires.
    error JBUniswapV4LPSplitHook_InsufficientBalance(uint256 available, uint256 required);
    /// @notice Thrown when the liquidity computed for a position is too low to mint a valid LP position.
    error JBUniswapV4LPSplitHook_InsufficientLiquidity(uint128 liquidity);
    /// @notice Thrown when the configured fee percent exceeds the maximum the hook allows.
    error JBUniswapV4LPSplitHook_InvalidFeePercent(uint256 feePercent, uint256 maxFeePercent);
    /// @notice Thrown when a project's controller or token cannot be resolved, so the project is not usable by the
    /// hook.
    error JBUniswapV4LPSplitHook_InvalidProjectId(uint256 projectId, address controller, address projectToken);
    /// @notice Thrown when an action is attempted in a lifecycle stage that does not permit it (e.g. growing a pool
    /// that does not exist yet).
    error JBUniswapV4LPSplitHook_InvalidStageForAction(uint256 projectId, address terminalToken, uint256 tokenId);
    /// @notice Thrown when the terminal token supplied for an operation is not the one this clone's pool is paired
    /// against.
    error JBUniswapV4LPSplitHook_InvalidTerminalToken(uint256 projectId, address terminalToken);
    /// @notice Thrown when an operation that requires accumulated project tokens finds none held for the project.
    error JBUniswapV4LPSplitHook_NoTokensAccumulated(uint256 projectId);
    /// @notice Thrown when the split hook context names a hook other than this one, so the split was not routed here.
    error JBUniswapV4LPSplitHook_NotHookSpecifiedInContext(address expectedHook, address actualHook);
    /// @notice Thrown when a project routes more than one terminal token to the hook, which it cannot pair into a
    /// single pool.
    error JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported(uint256 projectId, address terminalToken);
    /// @notice Thrown when an amount to approve through Permit2 exceeds the maximum a Permit2 allowance can hold.
    error JBUniswapV4LPSplitHook_Permit2AmountOverflow(address token, uint256 amount, uint256 maxAmount);
    /// @notice Thrown when a permissionless rebalance is attempted but the freshly computed corridor is within
    /// `_MIN_REBALANCE_DRIFT_TICKS` of the live position on BOTH bounds, so re-centering would churn the position for
    /// no meaningful re-ranging.
    error JBUniswapV4LPSplitHook_DriftBelowThreshold(
        int24 currentTickLower, int24 currentTickUpper, int24 newTickLower, int24 newTickUpper
    );
    /// @notice Thrown when pool deployment is attempted for a project that already has a deployed pool.
    error JBUniswapV4LPSplitHook_PoolAlreadyDeployed(uint256 projectId, address terminalToken, uint256 tokenId);
    /// @notice Thrown when the pool's current price has deviated too far from the oracle TWAP, which would let a
    /// sandwich/JIT attacker make the hook add liquidity at a manipulated ratio.
    error JBUniswapV4LPSplitHook_PriceDeviationTooHigh(int24 spotTick, int24 twapTick, int24 maxDeviationTicks);
    /// @notice Thrown when a reserved-token split is sent from an address that is neither the project's controller nor
    /// a valid terminal, so it cannot be trusted as a genuine distribution.
    error JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal(
        uint256 projectId, address sender, address controller
    );
    /// @notice Thrown when a temporary Permit2 allowance granted for an operation is not fully consumed by it.
    error JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed(address token, address spender, uint256 allowance);
    /// @notice Thrown when no terminal accepting the given token can be found for the project.
    error JBUniswapV4LPSplitHook_TerminalNotFound(uint256 projectId, address token);
    /// @notice Thrown when a split is routed to the hook under a group ID other than the one reserved for terminal
    /// tokens.
    error JBUniswapV4LPSplitHook_TerminalTokensNotAllowed(uint256 groupId, uint256 requiredGroupId);
    /// @notice Thrown when the oracle TWAP cannot be read (e.g. the pool oracle has not warmed up yet), so the pool
    /// price cannot be validated and liquidity must not be added.
    error JBUniswapV4LPSplitHook_TwapUnavailable(uint256 projectId, address terminalToken);
    /// @notice Thrown when the token backing a project's unclaimed fee balance changes, so the prior balance can no
    /// longer be safely settled in the new token.
    error JBUniswapV4LPSplitHook_UnclaimedFeeTokenChanged(address previousToken, address nextToken);
    /// @notice Thrown when the token amounts paired for a position yield zero liquidity.
    error JBUniswapV4LPSplitHook_ZeroLiquidity(uint256 amount0, uint256 amount1);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The basis-points denominator (10_000 = 100%).
    uint256 public constant BPS = 10_000;

    /// @notice The Uniswap V4 pool fee tier this hook deploys into (10_000 = 1%).
    uint24 public constant POOL_FEE = 10_000;

    /// @notice The tick spacing of the 1% fee tier the hook uses (200).
    int24 public constant TICK_SPACING = 200;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

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

    /// @notice The minimum corridor drift (in ticks) a permissionless rebalance must clear on at least one bound.
    /// @dev Defaults to one pool `tickSpacing`. If the freshly recomputed `[floor, ceiling]` sits within this distance
    /// of the live position on BOTH bounds, `rebalanceLiquidity` reverts — cheap churn that would burn and re-mint
    /// the
    /// same effective range (paying gas + realizing burn slippage) for no re-centering benefit is rejected.
    int24 internal constant _MIN_REBALANCE_DRIFT_TICKS = TICK_SPACING;

    /// @notice The slippage floor, out of `BPS`, applied to a burned position's contract-derived principal read.
    /// @dev When consolidating, the hook computes the position's current token amounts from its on-chain liquidity and
    /// the live pool price, then requires the BURN to return at least this fraction of that read. The floor is always
    /// contract-derived — callers never supply burn minimums — so a sandwiched spot cannot make the hook accept an
    /// arbitrarily bad unwind.
    uint256 internal constant _BURN_SLIPPAGE_BPS = 9500;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The JBDirectory used to resolve a project's controller and terminals.
    address public immutable DIRECTORY;

    /// @notice The Permit2 utility used to approve tokens for PositionManager.
    IAllowanceTransfer public immutable PERMIT2;

    /// @notice The JBProjects registry used to resolve project owners.
    IJBProjects public immutable PROJECTS;

    /// @notice The sucker registry for querying remote cross-chain surplus and supply.
    IJBSuckerRegistry public immutable SUCKER_REGISTRY;

    /// @notice The JBTokens registry used to resolve a project's ERC-20.
    address public immutable TOKENS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The buyback-hook registry this clone targets for force-direct cash-outs.
    /// @dev When a funding cash-out runs, the hook attaches the buyback hook's `cashOut` skip metadata keyed to this
    /// registry so the cash-out is routed DIRECTLY through the bonding curve (never through an AMM). Held as per-clone
    /// storage (set once via `initialize`) rather than an implementation immutable so different projects' clones can
    /// target different buyback registries. May be the zero address, in which case no force-direct metadata is attached
    /// and the terminal's own `minTokensReclaimed` floor still applies.
    IJBBuybackHookRegistry public buybackHook;

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

    /// @notice The project ID that receives the LP-fee cut.
    uint256 public feeProjectId;

    /// @notice The percentage of LP fees routed to the fee project, in basis points (e.g. 3800 = 38%).
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
    /// @custom:param token The token whose in-flight fee route count is being tracked.
    mapping(address token => uint256 count) internal _inflightFeeRoutingCount;

    /// @notice Fee project ID => total outstanding fee-credit claims across all projects.
    /// @dev Tracks credit-only fee proceeds held on behalf of projects that routed LP fees before the fee project had
    /// an ERC-20. Those reserved credits must stay out of principal if the fee project later deploys LP on the same
    /// clone.
    /// @custom:param feeProjectId The fee project whose internal credits are reserved for beneficiary claims.
    mapping(uint256 feeProjectId => uint256 totalClaims) internal _totalOutstandingFeeCreditClaims;

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
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IAllowanceTransfer permit2,
        IJBSuckerRegistry suckerRegistry
    )
        JBPermissioned(permissions)
    {
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
    /// @param newBuybackHook The buyback-hook registry this clone targets for force-direct cash-outs. May be the zero
    /// address, in which case no force-direct metadata is attached.
    function initialize(
        uint256 initialFeeProjectId,
        uint256 initialFeePercent,
        IPoolManager newPoolManager,
        IPositionManager newPositionManager,
        IHooks newOracleHook,
        IJBBuybackHookRegistry newBuybackHook
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
        buybackHook = newBuybackHook;
    }

    /// @notice Accept ETH transfers (needed for cashOut with native ETH and V4 TAKE operations).
    receive() external payable {}

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Whether this contract implements a given interface (ERC-165).
    /// @param interfaceId The ERC-165 interface identifier to check.
    /// @return True if `interfaceId` is the hook or split-hook interface.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        // Advertise both the hook's own interface and the split-hook interface the controller calls into.
        return interfaceId == type(IJBUniswapV4LPSplitHook).interfaceId || interfaceId == type(IJBSplitHook).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Whether a Uniswap V4 LP position has been minted for a project's terminal-token pair.
    /// @param projectId The ID of the project to check.
    /// @param terminalToken The terminal token paired with the project token.
    /// @return deployed True once a position exists for the pair.
    function isPoolDeployed(uint256 projectId, address terminalToken) public view returns (bool deployed) {
        // A nonzero position token id is the marker that the pool was deployed and seeded.
        return tokenIdOf[projectId][terminalToken] != 0;
    }

    /// @notice The Uniswap V4 pool key (currency pair, fee, tick spacing, and hook) for a project's deployed pool.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token paired with the project token.
    /// @return key The stored pool key (zero-valued if no pool has been deployed for the pair).
    function poolKeyOf(uint256 projectId, address terminalToken) public view returns (PoolKey memory key) {
        return poolKeysOf[projectId][terminalToken];
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Look up the controller address for a project.
    /// @param projectId The ID of the project.
    /// @return The project's current controller (address(0) if none is set).
    function _controllerOf(uint256 projectId) internal view returns (address) {
        // The directory is the canonical source of a project's active controller.
        return address(IJBDirectory(DIRECTORY).controllerOf(projectId));
    }

    /// @notice Look up the current spot sqrt price of a pool.
    /// @param key The pool key identifying the Uniswap V4 pool.
    /// @return sqrtPriceX96 The pool's current `sqrtPriceX96` from Slot0 (0 if the pool is uninitialized).
    function _getSqrtPriceX96(PoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        // Read only Slot0's price field via StateLibrary; the tick/fee fields are unused here.
        (sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
    }

    /// @notice Get the terminal token balance currently held by this hook.
    /// @param terminalToken The terminal token to read.
    /// @return balance This hook's native ETH or ERC-20 balance for `terminalToken`.
    function _getTerminalTokenBalance(address terminalToken) internal view returns (uint256 balance) {
        // Native ETH is held as the contract's ether balance, not an ERC-20 balance.
        if (_isNativeToken(terminalToken)) return address(this).balance;
        // Otherwise read the ERC-20 balance held by this hook.
        return IERC20(terminalToken).balanceOf(address(this));
    }

    /// @notice Whether `terminalToken` is Juicebox's native-token sentinel.
    /// @param terminalToken The terminal token to check.
    /// @return isNative True if `terminalToken` represents native ETH.
    function _isNativeToken(address terminalToken) internal pure returns (bool isNative) {
        return JBLPSplitHookHelpers.isNativeToken(terminalToken);
    }

    /// @notice Look up the next token ID the position manager will mint.
    /// @dev Read immediately after a MINT to recover the just-minted id as `_nextTokenId() - 1`.
    /// @return The position manager's next-to-be-assigned NFT token id.
    function _nextTokenId() internal view returns (uint256) {
        return positionManager.nextTokenId();
    }

    /// @notice Look up the owner of a project.
    /// @param projectId The ID of the project.
    /// @return The project's current owner (used as the permission account for `SET_BUYBACK_POOL` gates).
    function _ownerOf(uint256 projectId) internal view returns (address) {
        return PROJECTS.ownerOf(projectId);
    }

    /// @notice Look up the primary terminal for a project/token pair.
    /// @param projectId The ID of the project.
    /// @param token The token whose primary terminal to resolve.
    /// @return The project's primary terminal for `token` (address(0) if none is set).
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
        // Otherwise only the already-recorded outstanding claims are off-limits; the rest of the balance is free.
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
    /// @param projectId The ID of the project.
    /// @return The project's deployed ERC-20 (address(0) if the project is credits-only with no ERC-20).
    function _tokenOf(uint256 projectId) internal view returns (address) {
        return address(IJBTokens(TOKENS).tokenOf(projectId));
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Convert the project's post-deployment accumulated reserved tokens into additional protocol-owned
    /// liquidity, minted as a single-sided ask position (no funding cash-out) spanning from the pool's live price out
    /// to the project's issuance/cash-out corridor — the same executor `deployPool` uses. The add is rejected if the
    /// pool's spot price has deviated from the oracle TWAP, bounding sandwich/JIT manipulation of the mint range.
    /// Permissionless once the ruleset weight has decayed 10x from when accumulation began; otherwise requires
    /// `SET_BUYBACK_POOL` from the project owner. Safe for anyone to call.
    /// @param projectId The ID of the project whose accumulated tokens should be added as liquidity.
    /// @param terminalToken The terminal token paired with the project token in the deployed pool.
    function addLiquidity(uint256 projectId, address terminalToken) external {
        // Require a deployed pool for this project/terminal-token pair — `addLiquidity` only grows an existing pool.
        uint256 activeTokenId = tokenIdOf[projectId][terminalToken];
        if (activeTokenId == 0) {
            revert JBUniswapV4LPSplitHook_InvalidStageForAction({
                projectId: projectId, terminalToken: terminalToken, tokenId: activeTokenId
            });
        }

        // Fetch the controller and current ruleset once; both feed the auth gate and the corridor math.
        address controller = _controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        // Same authorization model as `deployPool`: permissionless once the weight has decayed 10x, else
        // SET_BUYBACK_POOL from the owner.
        _requireDeployOrAddAuth({projectId: projectId, ruleset: ruleset});

        // Nothing to add if no reserved tokens have accumulated since the last add.
        if (accumulatedProjectTokens[projectId] == 0) {
            revert JBUniswapV4LPSplitHook_NoTokensAccumulated({projectId: projectId});
        }

        // Resolve the project's ERC-20 and the pool key once for the TWAP guard and the mint below.
        address projectToken = _tokenOf(projectId);
        PoolKey memory key = poolKeysOf[projectId][terminalToken];

        // Reject the add while the pool's spot price is off the oracle TWAP. Stops a JIT/sandwich attacker from
        // shoving the pool price right before our add to make us mint at a manipulated range.
        _requireSpotNearTwap({projectId: projectId, terminalToken: terminalToken, key: key});

        // Mint another single-sided ask position from the accumulated project tokens — no funding cash-out.
        _addSingleSidedLiquidity({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            controller: controller,
            ruleset: ruleset
        });

        // Surface the resulting position id.
        emit LiquidityAdded({
            projectId: projectId,
            terminalToken: terminalToken,
            tokenId: tokenIdOf[projectId][terminalToken],
            isNewPosition: true,
            caller: msg.sender
        });
    }

    /// @notice Claims accumulated fee proceeds for `projectId` and sends them to `beneficiary`.
    /// @dev Requires `SET_BUYBACK_POOL` permission from the project's owner.
    /// @dev ERC-20 fee tokens are claimed first, followed by any fee credits that were accrued while the fee project
    /// had no ERC-20. Credit claims are best-effort: if the downstream controller rejects the transfer, the pending
    /// credit balance is restored so it can be retried later without blocking the ERC-20 claim path.
    /// @param projectId The project to claim accumulated fee proceeds for.
    /// @param beneficiary The address that should receive any claimed fee proceeds.
    function claimFeeTokensFor(uint256 projectId, address beneficiary) external {
        // Only the project owner (or a SET_BUYBACK_POOL delegate) may direct where this project's fee proceeds go.
        _requirePermissionFrom({
            account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        // Claim any ERC-20 fee tokens first (the common case once the fee project has a token).
        uint256 tokenAmount = claimableFeeTokens[projectId];
        if (tokenAmount > 0) {
            _claimFeeTokens({projectId: projectId, beneficiary: beneficiary, tokenAmount: tokenAmount});
        }

        // Then claim any fee-project credits accrued while the fee project had no ERC-20 (best-effort; see `_dev`).
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
            // Keep the reserve through the external call so reentrant deploy/add cannot spend the pending credits.
            _totalOutstandingFeeCreditClaims[feeProjectId] -= creditAmount;

            emit FeeTokensClaimed({
                projectId: projectId, beneficiary: beneficiary, amount: creditAmount, caller: msg.sender
            });
        } catch {
            // Restore the pending credits so the project owner can retry once the fee-project controller is usable.
            claimableFeeCredits[projectId] = creditAmount;
        }
    }

    /// @notice Collect accrued Uniswap LP trading fees for a project (from its single active position) and route them
    /// back to its terminal balance. The terminal-token portion is deposited (minus an optional fee-project cut); the
    /// project-token portion is carried into the accumulation ledger to become future liquidity (never burned).
    /// Callable by anyone.
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

    /// @notice Create the Uniswap V4 pool and mint the initial LP position as a single-sided ask of the project's
    /// accumulated reserved tokens — no funding cash-out. Permissionless once the ruleset weight has decayed to 10%
    /// of
    /// what it was when accumulation began; otherwise requires `SET_BUYBACK_POOL` permission from the project owner.
    /// @param projectId The ID of the project whose accumulated tokens should be deployed as LP.
    function deployPool(uint256 projectId) external {
        // Allow anyone to deploy if the current ruleset's weight has decayed 10x from the initial weight.
        // Otherwise, require SET_BUYBACK_POOL permission from the project owner.
        address controller = _controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        _requireDeployOrAddAuth({projectId: projectId, ruleset: ruleset});

        // Auto-select the terminal token with the highest ETH-denominated value.
        address terminalToken = JBUniswapV4LPSplitHookMath.findHighestValueTerminalTokenOf({
            directory: IJBDirectory(DIRECTORY), projectId: projectId, controller: controller
        });

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

    /// @notice Burn the project's single LP position and re-mint it, re-centered on the project's freshly recomputed
    /// issuance/cash-out corridor. Useful when issuance/cash-out rate changes have shifted the economic band away from
    /// the live position. Permissionless: anyone may call it. Two guards bound abuse: the fresh corridor must have
    /// drifted at least `_MIN_REBALANCE_DRIFT_TICKS` from the live position on at least one bound (so a caller cannot
    /// churn the position for gas/slippage with no re-ranging), and the pool's spot must be near the oracle TWAP (so a
    /// sandwiched spot cannot skew the re-mint ratio). The terminal tokens recovered from the burn become the bid side
    /// of the re-centered two-sided position.
    /// @param projectId The ID of the project whose LP position should be rebalanced.
    /// @param terminalToken The terminal token paired with the project token in the pool.
    function rebalanceLiquidity(uint256 projectId, address terminalToken) external {
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
        address controller = _controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        // Recompute the project's economic corridor from its current rates.
        (int24 floorTick, int24 ceilingTick) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(DIRECTORY),
            suckerRegistry: SUCKER_REGISTRY,
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });

        // Drift guard: reject a rebalance that would not meaningfully re-range. If the fresh corridor is within
        // `_MIN_REBALANCE_DRIFT_TICKS` of the live position on BOTH bounds, there is nothing worth churning for.
        int24 currentLower = activeTickLowerOf[projectId][terminalToken];
        int24 currentUpper = activeTickUpperOf[projectId][terminalToken];
        if (
            _absTickDiff({a: floorTick, b: currentLower}) <= _MIN_REBALANCE_DRIFT_TICKS
                && _absTickDiff({a: ceilingTick, b: currentUpper}) <= _MIN_REBALANCE_DRIFT_TICKS
        ) {
            revert JBUniswapV4LPSplitHook_DriftBelowThreshold({
                currentTickLower: currentLower,
                currentTickUpper: currentUpper,
                newTickLower: floorTick,
                newTickUpper: ceilingTick
            });
        }

        // Reject the rebalance while the pool's spot price is off the oracle TWAP. The burn and re-mint price against
        // the live spot, so a sandwiched/JIT-skewed spot would make the re-mint deploy at a manipulated ratio. Mirrors
        // `addLiquidity`'s guard (and, like it, reverts if the oracle TWAP has not warmed up yet).
        _requireSpotNearTwap({projectId: projectId, terminalToken: terminalToken, key: key});

        // Burn the live position and re-mint one position across the fresh corridor, folding in recovered tokens and
        // any hook-held credits. Two-sided: the corridor spans the live spot, so recovered terminal seeds the bid side.
        _consolidateAndReMint({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            tickLower: floorTick,
            tickUpper: ceilingTick,
            controller: controller
        });

        emit PermissionlessRebalanced({
            projectId: projectId,
            terminalToken: terminalToken,
            tickLower: floorTick,
            tickUpper: ceilingTick,
            caller: msg.sender
        });
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Absolute difference between two ticks, used for corridor-drift and TWAP-deviation comparisons.
    /// @param a The first tick.
    /// @param b The second tick.
    /// @return The non-negative distance between the two ticks.
    function _absTickDiff(int24 a, int24 b) internal pure returns (int24) {
        // Order the subtraction so the result is always non-negative regardless of which tick is larger.
        return a >= b ? a - b : b - a;
    }

    /// @notice Record incoming project tokens in the accumulation ledger (the hook's single inflow sink).
    /// @param projectId The ID of the project to credit.
    /// @param amount The project-token amount to add to the ledger.
    function _accumulateTokens(uint256 projectId, uint256 amount) internal {
        // `+=`: accumulation is additive across every reserved-token distribution, pre- and post-deployment.
        accumulatedProjectTokens[projectId] += amount;
    }

    /// @notice Deposit tokens into a project's primary terminal balance via `addToBalanceOf`.
    /// @param projectId The ID of the project to credit.
    /// @param token The token to deposit (native sentinel or ERC-20).
    /// @param amount The amount to deposit.
    /// @param isNative Whether `token` is the native-ETH sentinel (sent as msg.value) vs. an ERC-20 (pulled via
    /// approve).
    function _addToProjectBalance(uint256 projectId, address token, uint256 amount, bool isNative) internal {
        // Nothing to deposit — avoid a no-op external call.
        if (amount == 0) return;

        // Route to the project's primary terminal for this token; revert if it has none (the deposit has no home).
        address terminal = _primaryTerminalOf({projectId: projectId, token: token});
        if (terminal == address(0)) {
            revert JBUniswapV4LPSplitHook_TerminalNotFound({projectId: projectId, token: token});
        }

        // ERC-20 deposits are pulled by the terminal, so grant an exact-use approval first; native ETH is sent inline.
        if (!isNative) {
            IERC20(token).forceApprove({spender: terminal, value: amount});
        }

        // Add the tokens to the project's terminal balance. `shouldReturnHeldFees: false` — this is a plain top-up.
        IJBMultiTerminal(terminal).addToBalanceOf{value: isNative ? amount : 0}({
            projectId: projectId, token: token, amount: amount, shouldReturnHeldFees: false, memo: "", metadata: ""
        });

        // The terminal must have consumed the full approval; a leftover allowance is live spend authority and reverts.
        if (!isNative) _requireTemporaryAllowanceConsumed({token: token, spender: terminal});
    }

    /// @notice Grant the PositionManager a time-limited Permit2 allowance so it can pull tokens during SETTLE.
    /// @dev Permit2 is a two-layer approval: the ERC-20 must approve Permit2, and Permit2 must approve the spender.
    /// @param token The ERC-20 to approve for the PositionManager to pull.
    /// @param amount The exact amount to authorize (cleared again after the mint via `_clearPermit2Approval`).
    function _approveViaPermit2(address token, uint256 amount) internal {
        // Layer 1: let Permit2 pull this token from the hook.
        IERC20(token).forceApprove({spender: address(PERMIT2), value: amount});
        // Permit2 stores allowances as uint160; reject any amount that would silently truncate.
        if (amount > type(uint160).max) {
            revert JBUniswapV4LPSplitHook_Permit2AmountOverflow({
                token: token, amount: amount, maxAmount: type(uint160).max
            });
        }
        // Layer 2: authorize the PositionManager to pull `amount` from the hook via Permit2, expiring shortly so a
        // leftover approval cannot be exploited later.
        PERMIT2.approve({
            token: token,
            spender: address(positionManager),
            // Safe: bounded by the `> type(uint160).max` check above.
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint160(amount),
            // Short-lived expiration so the grant only covers this single SETTLE.
            // forge-lint: disable-next-line(unsafe-typecast)
            expiration: uint48(block.timestamp + _DEADLINE_SECONDS)
        });
    }

    /// @notice Burn an existing LP position via `BURN_POSITION` + `TAKE_PAIR` and recover its principal (plus any
    /// accrued fees the burn collects). The recovered tokens remain in this contract for the subsequent re-mint.
    /// @dev Called only by `_consolidateAndReMint`, which derives the min amounts from a live-price principal read
    /// (`_burnSlippageFloor`) — the min amounts are always contract-derived, never caller-supplied.
    /// @param tokenId The Uniswap V4 position NFT token ID to burn.
    /// @param key The pool key identifying the Uniswap V4 pool.
    /// @param decreaseAmount0Min Minimum amount of token0 to receive (contract-derived slippage floor).
    /// @param decreaseAmount1Min Minimum amount of token1 to receive (contract-derived slippage floor).
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
        // Min amounts are the contract-derived slippage floor; PositionManager accepts uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        burnParams[0] = abi.encode(tokenId, uint128(decreaseAmount0Min), uint128(decreaseAmount1Min), "");
        // TAKE_PAIR params: (currency0, currency1, recipient).
        burnParams[1] = abi.encode(key.currency0, key.currency1, address(this));

        _modifyLiquidities({unlockData: abi.encode(burnActions, burnParams), value: 0});
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

    /// @notice Converts this hook's internal project-token credits into the registered ERC-20.
    /// @dev Core burns holder credits before ERC-20 balances during cash-out. Normalizing first keeps LP sizing and
    /// post-add dust accounting scoped to transferable project tokens already visible to Uniswap V4.
    /// @param projectId The Juicebox project whose credits are being normalized.
    /// @param controller The project's controller.
    /// @return creditCount The number of credits claimed into ERC-20 project tokens.
    function _claimHookCreditsFor(uint256 projectId, address controller) internal returns (uint256 creditCount) {
        uint256 creditBalance = IJBTokens(TOKENS).creditBalanceOf({holder: address(this), projectId: projectId});
        uint256 unavailableCredits = _totalOutstandingFeeCreditClaims[projectId];

        // Fee-credit claims are denominated in the fee project's credits. If that same project later deploys LP through
        // this clone, only credits not already owed to fee claimants can be normalized into ERC-20 LP principal.
        if (creditBalance <= unavailableCredits) return 0;

        creditCount = creditBalance - unavailableCredits;

        IJBController(controller)
            .claimTokensFor({
            holder: address(this), projectId: projectId, tokenCount: creditCount, beneficiary: address(this)
        });

        return creditCount;
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
        uint160 sqrtPriceX96 = JBUniswapV4LPSplitHookMath.computeInitialSqrtPrice({
            directory: IJBDirectory(DIRECTORY),
            suckerRegistry: SUCKER_REGISTRY,
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
            (int24 tickLower, int24 tickUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
                directory: IJBDirectory(DIRECTORY),
                suckerRegistry: SUCKER_REGISTRY,
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
    /// @param currency The Uniswap V4 currency (address(0) for native ETH) to read.
    /// @return This hook's balance of `currency`.
    function _currencyBalance(Currency currency) internal view returns (uint256) {
        // Uniswap V4 represents native ETH as the zero-address currency; read the ether balance for it.
        if (currency.isAddressZero()) {
            return address(this).balance;
        }
        // Otherwise read the ERC-20 balance held by this hook.
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /// @notice Deploy pool and add liquidity using accumulated tokens.
    /// @param projectId The ID of the project.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    function _deployPoolAndAddLiquidity(
        uint256 projectId,
        address projectToken,
        address terminalToken,
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

        // Mint a single-sided ask position from the accumulated project tokens — no funding cash-out.
        _addSingleSidedLiquidity({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            controller: controller,
            ruleset: ruleset
        });
    }

    /// @notice Consolidate the project's holdings into ONE single-sided (asks-only) position spanning from the pool's
    /// live spot out to the project's issuance/cash-out ceiling — no funding cash-out. Used by both `deployPool` (no
    /// prior position to burn) and `addLiquidity` (burns + refolds the prior position so the hook never fragments into
    /// multiple untracked NFTs). The position holds only project tokens and only trades once buyers push spot into it.
    /// @dev Assumes the pool is already initialized (the revnet norm) — `_deployPoolAndAddLiquidity` calls
    /// `_createAndInitializePool` immediately before this, which best-effort initializes an uninitialized pool or
    /// accepts an already-initialized one's live price.
    /// @param projectId The ID of the project.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    function _addSingleSidedLiquidity(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        address controller,
        JBRuleset memory ruleset
    )
        internal
    {
        PoolKey memory key = poolKeysOf[projectId][terminalToken];

        // The project's economic corridor (cash-out floor to issuance ceiling), as a sorted ascending raw tick range.
        (int24 corridorLower, int24 corridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(DIRECTORY),
            suckerRegistry: SUCKER_REGISTRY,
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });

        // Clamp the corridor to the live spot so the minted range is project-token-only (an ask above the spot).
        int24 spotTick = TickMath.getTickAtSqrtPrice(_getSqrtPriceX96(key));
        (int24 tickLower, int24 tickUpper) = _singleSidedTicks({
            projectToken: projectToken,
            terminalToken: terminalToken,
            corridorLower: corridorLower,
            corridorUpper: corridorUpper,
            spotTick: spotTick
        });

        _consolidateAndReMint({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            tickLower: tickLower,
            tickUpper: tickUpper,
            controller: controller
        });
    }

    /// @notice The asks-only tick range: the project's corridor clamped to the live spot so the position holds only
    /// project tokens. Branches on token ordering — Uniswap's below-range/above-range single-sided rule flips with
    /// which currency the project token is.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param corridorLower The lower bound of the project's economic corridor (sorted ascending).
    /// @param corridorUpper The upper bound of the project's economic corridor (sorted ascending).
    /// @param spotTick The pool's current spot tick.
    /// @return tickLower The lower tick of the asks-only range.
    /// @return tickUpper The upper tick of the asks-only range.
    function _singleSidedTicks(
        address projectToken,
        address terminalToken,
        int24 corridorLower,
        int24 corridorUpper,
        int24 spotTick
    )
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        (address token0,) = _sortTokens({tokenA: projectToken, tokenB: Currency.unwrap(_toCurrency(terminalToken))});
        if (projectToken == token0) {
            // Project is token0: a position entirely ABOVE spot is 100% token0. Anchor the lower bound at (at least)
            // the live spot, reaching up to the corridor ceiling.
            int24 rawLower = spotTick > corridorLower ? spotTick : corridorLower;
            tickLower = JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: rawLower, spacing: TICK_SPACING});
            tickUpper = corridorUpper;
        } else {
            // Project is token1: mirror image — a position entirely BELOW spot is 100% token1. Anchor the upper bound
            // at (at most) the live spot, floored at the corridor.
            int24 rawUpper = spotTick < corridorUpper ? spotTick : corridorUpper;
            tickUpper = JBLPSplitHookHelpers.alignTickToSpacing({tick: rawUpper, spacing: TICK_SPACING});
            tickLower = corridorLower;
        }
    }

    /// @notice Burn the project's live position (if any), fold in its recovered tokens, the accumulation ledger, and
    /// any hook-held project-token credits, and re-mint them as EXACTLY ONE position across `[tickLower, tickUpper]` at
    /// the live spot. Leftovers are carried forward (project → the accumulation ledger; terminal → the project
    /// balance), never burned. This is the single lifecycle primitive behind deploy, add, and rebalance; setting
    /// `tokenIdOf` to the fresh mint AFTER burning the prior id is what enforces the one-position-per-pair invariant.
    /// @dev The mint is single-sided (project-only) when the range sits on one side of the spot, and two-sided when the
    /// range spans it — determined purely by `[tickLower, tickUpper]` vs. spot, so the caller controls single vs. two
    /// sided by choosing the range. The burn slippage floor is always contract-derived (a fraction of a pre-burn
    /// principal read at the live spot); callers never supply burn minimums.
    /// @param projectId The ID of the project.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param tickLower The lower tick of the position to mint.
    /// @param tickUpper The upper tick of the position to mint.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    function _consolidateAndReMint(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        int24 tickLower,
        int24 tickUpper,
        address controller
    )
        internal
    {
        PoolKey memory key = poolKeysOf[projectId][terminalToken];

        // Fold hook-held project-token credits into transferable ERC-20 so they are included in the mint, not stranded.
        uint256 claimedCredits = _claimHookCreditsFor({projectId: projectId, controller: controller});

        // Burn the live position (if any), recovering both its tokens with a contract-derived slippage floor. Snapshot
        // the project balance AFTER claiming credits so the recovered-delta excludes them (counted separately below).
        uint256 existingTokenId = tokenIdOf[projectId][terminalToken];
        uint256 projBalBeforeBurn = IERC20(projectToken).balanceOf(address(this));
        uint256 recoveredProject;
        if (existingTokenId != 0) {
            (uint128 min0, uint128 min1) = _burnSlippageFloor({
                tokenId: existingTokenId,
                tickLower: activeTickLowerOf[projectId][terminalToken],
                tickUpper: activeTickUpperOf[projectId][terminalToken],
                key: key
            });
            _burnExistingPosition({
                tokenId: existingTokenId, key: key, decreaseAmount0Min: min0, decreaseAmount1Min: min1
            });
            recoveredProject = IERC20(projectToken).balanceOf(address(this)) - projBalBeforeBurn;
        }

        // Held amounts to re-mint. Project side = ledger + recovered-from-burn + freshly claimed credits (all now in
        // this hook's transferable balance). Terminal side = the spendable terminal balance (the burn's recovered
        // terminal, minus any balance already reserved for fee-token claims) — never caller-supplied.
        uint256 projectAmount = accumulatedProjectTokens[projectId] + recoveredProject + claimedCredits;
        uint256 terminalAmount = _spendableTerminalTokenBalance(terminalToken);

        // Map the held amounts onto the pool's currency ordering.
        (address token0,) = _sortTokens({tokenA: projectToken, tokenB: Currency.unwrap(_toCurrency(terminalToken))});
        bool projectIsToken0 = projectToken == token0;
        uint256 amount0 = projectIsToken0 ? projectAmount : terminalAmount;
        uint256 amount1 = projectIsToken0 ? terminalAmount : projectAmount;

        // A degenerate range (spot at/past the corridor edge) leaves no room to mint.
        if (tickLower >= tickUpper) revert JBUniswapV4LPSplitHook_ZeroLiquidity({amount0: amount0, amount1: amount1});

        // Derive the mintable liquidity from the held amounts at the live spot across the target range.
        uint160 sqrtPriceX96 = _getSqrtPriceX96(key);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts({
            sqrtPriceX96: sqrtPriceX96,
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(tickUpper),
            amount0: amount0,
            amount1: amount1
        });
        if (liquidity == 0) revert JBUniswapV4LPSplitHook_ZeroLiquidity({amount0: amount0, amount1: amount1});

        // CEI: clear the ledger before the external mint; any unconsumed remainder is carried back below (never
        // burned).
        accumulatedProjectTokens[projectId] = 0;

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

        // nextTokenId was incremented by MINT_POSITION, so (nextTokenId - 1) is the freshly minted ID. Setting
        // tokenIdOf here — after burning the prior id above — is what maintains the single-position invariant.
        tokenIdOf[projectId][terminalToken] = _nextTokenId() - 1;
        activeTickLowerOf[projectId][terminalToken] = tickLower;
        activeTickUpperOf[projectId][terminalToken] = tickUpper;

        _carryLeftovers({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            intendedProjectAmount: projectAmount,
            intendedTerminalAmount: terminalAmount,
            projBalBefore: projBalBeforeMint,
            termBalBefore: termBalBeforeMint
        });
    }

    /// @notice The contract-derived burn slippage floor for `tokenId`: `_BURN_SLIPPAGE_BPS`/`BPS` of the position's
    /// principal computed from its on-chain liquidity and the live pool price. Returned in (currency0, currency1) order
    /// to match `BURN_POSITION`. Callers never supply burn minimums, so a sandwiched spot cannot force a bad unwind.
    /// @param tokenId The position NFT token ID to be burned.
    /// @param tickLower The lower tick of the live position.
    /// @param tickUpper The upper tick of the live position.
    /// @param key The pool key identifying the Uniswap V4 pool.
    /// @return min0 The minimum currency0 the burn must return.
    /// @return min1 The minimum currency1 the burn must return.
    function _burnSlippageFloor(
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        PoolKey memory key
    )
        internal
        view
        returns (uint128 min0, uint128 min1)
    {
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        if (liquidity == 0) return (0, 0);

        (uint256 amount0, uint256 amount1) = _positionPrincipal({
            sqrtPriceX96: _getSqrtPriceX96(key), tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity
        });

        // Position principal is bounded by pooled token balances, so the discounted floor fits in uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        min0 = uint128((amount0 * _BURN_SLIPPAGE_BPS) / BPS);
        // forge-lint: disable-next-line(unsafe-typecast)
        min1 = uint128((amount1 * _BURN_SLIPPAGE_BPS) / BPS);
    }

    /// @notice The token0/token1 amounts a position of `liquidity` across `[tickLower, tickUpper]` holds at
    /// `sqrtPriceX96` — the canonical `getAmountsForLiquidity`, implemented via `SqrtPriceMath` because
    /// v4-periphery's
    /// `LiquidityAmounts` exposes only the inverse `getLiquidityForAmounts`. Rounds down.
    /// @param sqrtPriceX96 The pool's current sqrt price.
    /// @param tickLower The lower tick of the position.
    /// @param tickUpper The upper tick of the position.
    /// @param liquidity The position's liquidity.
    /// @return amount0 The token0 amount the position holds at the current price.
    /// @return amount1 The token1 amount the position holds at the current price.
    function _positionPrincipal(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta({
                sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
            });
        } else if (sqrtPriceX96 < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta({
                sqrtPriceAX96: sqrtPriceX96, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
            });
            amount1 = SqrtPriceMath.getAmount1Delta({
                sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtPriceX96, liquidity: liquidity, roundUp: false
            });
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta({
                sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
            });
        }
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

    /// @notice Execute a batched position-manager action (mint, increase, burn, decrease, etc.) with a short deadline.
    /// @param unlockData The ABI-encoded `(actions, params)` for the PositionManager to execute under its unlock.
    /// @param value The native ETH to forward (nonzero only when settling a native-ETH currency side).
    function _modifyLiquidities(bytes memory unlockData, uint256 value) internal {
        // Bound every batched action with a short deadline so a long-pending tx cannot execute at a stale price.
        positionManager.modifyLiquidities{value: value}({
            unlockData: unlockData, deadline: block.timestamp + _DEADLINE_SECONDS
        });
    }

    /// @notice Authorize a deploy/add: permissionless once the ruleset weight has decayed 10x from when accumulation
    /// began, otherwise require `SET_BUYBACK_POOL` from the project owner.
    /// @param projectId The ID of the project being acted on.
    /// @param ruleset The project's current ruleset (its `weight` is compared against the snapshotted initial weight).
    function _requireDeployOrAddAuth(uint256 projectId, JBRuleset memory ruleset) internal view {
        // Snapshot taken at first accumulation; the basis for the permissionless threshold.
        uint256 initialWeight = initialWeightOf[projectId];
        // Require owner permission until the weight has decayed to <= 10% of the initial (i.e. weight*10 <= initial).
        // `initialWeight == 0` (no accumulation recorded) also requires permission — there is nothing to gate
        // against.
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
                        // No ERC-20: track as claimable credits and reserve those fee-project credits from any later LP
                        // principal normalization on this clone.
                        claimableFeeCredits[projectId] += beneficiaryTokenCount;
                        _totalOutstandingFeeCreditClaims[feeProjectId] += beneficiaryTokenCount;
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
    /// @param tokenA One token address.
    /// @param tokenB The other token address.
    /// @return token0 The lower of the two addresses.
    /// @return token1 The higher of the two addresses.
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        // Delegate to the shared pure library so pool-key construction and amount mapping order tokens identically.
        return JBLPSplitHookHelpers.sortTokens({tokenA: tokenA, tokenB: tokenB});
    }

    /// @notice Convert a Juicebox terminal-token address to the equivalent Uniswap V4 `Currency`.
    /// @dev Juicebox uses the sentinel `JBConstants.NATIVE_TOKEN` for ETH; Uniswap V4 uses `address(0)`.
    /// @param terminalToken The Juicebox terminal token (native sentinel or ERC-20).
    /// @return The matching Uniswap V4 `Currency` (address(0) for native ETH, else the ERC-20).
    function _toCurrency(address terminalToken) internal pure returns (Currency) {
        // Delegate to the shared pure library so the native-sentinel → address(0) mapping is applied consistently.
        return JBLPSplitHookHelpers.toCurrency(terminalToken);
    }
}
