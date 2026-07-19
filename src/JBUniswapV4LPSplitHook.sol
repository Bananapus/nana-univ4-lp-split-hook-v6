// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";

import {IJBUniswapV4LPSplitHook} from "./interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBLPSplitHookHelpers} from "./libraries/JBLPSplitHookHelpers.sol";
import {JBUniswapV4LPSplitHookMath} from "./libraries/JBUniswapV4LPSplitHookMath.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/// @notice A split hook that builds and manages a Uniswap V4 liquidity position for a Juicebox project, using the
/// project's reserved-token distributions as the seed capital. The lifecycle has two stages:
///
/// 1. Accumulation — Each time the project distributes reserved tokens, the hook's share is held in escrow. Anyone
/// can
/// trigger `deployPool`, which mints the accumulated tokens as a single-sided ask position — seeded purely from those
/// accumulated tokens, never from a cash-out — spanning from the pool's live price out to the project's
/// issuance/cash-out corridor.
///
/// 2. Grow-and-route — After the pool exists, further reserved tokens sent to the hook keep accumulating in escrow.
/// Anyone can later call `addLiquidity` to convert the accumulated tokens into more protocol-owned liquidity: it checks
/// the pool's spot price against the oracle TWAP to reject sandwiched adds, then mints another single-sided ask
/// position spanning from the pool's live price out to the project's issuance/cash-out corridor. LP trading fees are
/// collected
/// periodically from the project's currently tracked position and routed back to the project's terminal balance,
/// with an optional protocol fee split to a configurable fee project. The hook never burns project tokens:
/// supply-reducing burns are a protocol-layer split-routing decision, so every token this hook touches ends up as
/// liquidity.
///
/// The hook also supports `rebalanceLiquidity`, which re-centers the LP tick range around the project's current
/// issuance and cash-out prices when they drift from the original deployment parameters.
///
/// @dev Each clone manages exactly one Uniswap V4 pool per project (one terminal-token pairing). `deployPool`,
/// `addLiquidity`, `rebalanceLiquidity`, and `collectAndRouteLPFees` are permissionless — anyone may call them —
/// with
/// abuse bounded by economic gates (a seed/add reverts once spot reaches the issuance ceiling) and an oracle-TWAP
/// deviation guard. The pool uses a 1% fee tier, 200-tick spacing, and a shared oracle hook for TWAP observations.
/// @dev Every state-changing external entry point that can reach an external call (terminal `pay`/`addToBalanceOf`,
/// controller `claimTokensFor`/`transferCreditsFrom`, or the Uniswap V4 PositionManager) is guarded with
/// solady's `ReentrancyGuard.nonReentrant`. Guarded functions never call each other externally (via `this.`) —
/// they share internal `_`-prefixed helpers — so the guard cannot self-revert on a legitimate call path.
contract JBUniswapV4LPSplitHook is IJBUniswapV4LPSplitHook, IJBSplitHook, JBPermissioned, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when `initialize` is called on a clone whose chain-specific properties have already been set.
    error JBUniswapV4LPSplitHook_AlreadyInitialized();
    /// @notice Thrown when a token amount that must fit a Uniswap V4 `uint128` field exceeds `type(uint128).max`, so a
    /// silent truncation (which could disable a mint or shrink a burn slippage floor to near-zero) is rejected
    /// outright.
    error JBUniswapV4LPSplitHook_AmountExceedsUint128(uint256 amount);
    /// @notice Thrown when `addLiquidity` is called with less accumulated project-token balance than
    /// `_MIN_ADD_ACCUMULATION`, so a trivial (dust) accumulation cannot force a full fee-collect+burn+remint churn.
    error JBUniswapV4LPSplitHook_AccumulationBelowThreshold(uint256 projectId, uint256 accumulated, uint256 threshold);
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
    /// @notice Thrown when a permissionless rebalance is attempted but the freshly computed issuance/cash-out corridor
    /// is within `_MIN_REBALANCE_DRIFT_TICKS` of the corridor the live position was ranged against on BOTH bounds, so
    /// re-centering would churn the position for no meaningful re-ranging. The drift is measured on CORRIDOR movement
    /// (floor + ceiling), not on the adaptive lower/bid bound, so a terminal-only inflow cannot trigger churn.
    error JBUniswapV4LPSplitHook_DriftBelowThreshold(
        int24 currentTickLower, int24 currentTickUpper, int24 newTickLower, int24 newTickUpper
    );
    /// @notice Thrown when a seed/extend (deploy or add) — or a rebalance — is attempted while the pool's live spot
    /// has
    /// already reached or passed the project's issuance-price (ceiling) tick, so there is no live corridor below the
    /// ceiling for asks to fill and the adaptive ask range would be empty/inverted. Only seed/extend when asks below
    /// the ceiling are fillable.
    error JBUniswapV4LPSplitHook_SpotAboveCeilingAtSeed(int24 spotTick, int24 ceilingTick);
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
    /// @notice Thrown when the best-effort fee-cut payment helper is called by anyone other than this contract itself.
    error JBUniswapV4LPSplitHook_Unauthorized();
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

    /// @notice The minimum accumulated project-token balance `addLiquidity` requires before it will churn the position.
    /// @dev Below this, LP-fee dust (down to 1 wei of project-token fee carried into the accumulation ledger) would
    /// otherwise force a full fee-collect+burn+remint on every accrual. Trivial accumulation keeps accruing in the
    /// ledger until it crosses this floor, then deploys as liquidity — `deployPool` and the fee/credit accounting are
    /// unaffected.
    uint256 internal constant _MIN_ADD_ACCUMULATION = 1e15;

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

    /// @notice The buyback-hook registry configured for this clone.
    /// @dev Held as per-clone storage (set once via `initialize`) rather than an implementation immutable so different
    /// projects' clones can target different buyback registries and this implementation's CREATE2 inputs stay
    /// byte-identical on every chain. May be the zero address.
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

    /// @notice The terminal-token balance currently held for each project as protocol-owned bid-leg liquidity.
    /// @dev Mirrors `accumulatedProjectTokens` for the terminal side. Credited ONLY from this project's own
    /// LP-fee collections (the non-cut remainder of the terminal-token fee) and its own unconsumed mint leftovers.
    /// `_consolidateAndReMint` sizes the bid leg from this ledger plus the project's own burn-recovered terminal —
    /// never from the hook's raw token balance — so one project can never consume another's terminal or an outside
    /// donation.
    /// @custom:param projectId The ID of the project whose accumulated terminal-token bid liquidity to read.
    /// @custom:param terminalToken The terminal token paired with the project's token in its pool.
    mapping(uint256 projectId => mapping(address terminalToken => uint256)) public accumulatedTerminalTokens;

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
    /// @dev Snapshotted on first accumulation as an accumulation-era reference. `deployPool` and `addLiquidity` are
    /// permissionless and gated only by economic + oracle-TWAP guards, not by this weight.
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

    /// @notice The lower tick of the issuance/cash-out CORRIDOR the currently active position was ranged against.
    /// @dev Distinct from `activeTickLowerOf`: the active position's bounds include the ADAPTIVE bid bound (which moves
    /// with the hook's terminal balance, not real economic drift), whereas this records the economic corridor floor at
    /// mint time. `rebalanceLiquidity`'s drift guard compares the freshly recomputed corridor against these stored
    /// corridor bounds — not against the adaptive bounds — so a terminal-only inflow can never trigger churn while
    /// a
    /// genuine issuance-decay/surplus move can.
    /// @custom:param projectId The ID of the project.
    /// @custom:param terminalToken The terminal token paired with the project's token in the deployed pool.
    mapping(uint256 projectId => mapping(address terminalToken => int24 corridorLower)) public rangedCorridorLowerOf;

    /// @notice The upper tick of the issuance/cash-out CORRIDOR the currently active position was ranged against.
    /// @custom:param projectId The ID of the project.
    /// @custom:param terminalToken The terminal token paired with the project's token in the deployed pool.
    mapping(uint256 projectId => mapping(address terminalToken => int24 corridorUpper)) public rangedCorridorUpperOf;

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
    /// @param newBuybackHook The buyback-hook registry to configure for this clone. May be the zero address.
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

    /// @notice Accept ETH transfers (needed for V4 TAKE operations that return native ETH, and native-ETH terminal
    /// interactions).
    receive() external payable {}

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Convert the project's post-deployment accumulated reserved tokens into additional protocol-owned
    /// liquidity, minted as a single-sided ask position spanning from the pool's live price out to the project's
    /// issuance/cash-out corridor — the same executor `deployPool` uses. The add is rejected if the pool's spot price
    /// has deviated from the oracle TWAP, bounding sandwich/JIT manipulation of the mint range. Permissionless: anyone
    /// may call it. Abuse is bounded by the economic gate (the mint reverts once spot reaches the issuance ceiling) and
    /// the oracle-TWAP deviation guard.
    /// @param projectId The ID of the project whose accumulated tokens should be added as liquidity.
    /// @param terminalToken The terminal token paired with the project token in the deployed pool.
    function addLiquidity(uint256 projectId, address terminalToken) external nonReentrant {
        // Require a deployed pool for this project/terminal-token pair — `addLiquidity` only grows an existing pool.
        uint256 activeTokenId = tokenIdOf[projectId][terminalToken];
        if (activeTokenId == 0) {
            revert JBUniswapV4LPSplitHook_InvalidStageForAction({
                projectId: projectId, terminalToken: terminalToken, tokenId: activeTokenId
            });
        }

        // Fetch the controller and current ruleset once; both feed the corridor math. `addLiquidity` is fully
        // permissionless: the only gate is the economic one applied inside the mint executor (revert when the pool's
        // spot has already reached the issuance ceiling, so there is no live corridor for asks to fill).
        address controller = _controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        // Require a non-trivial accumulation so LP-fee dust (down to 1 wei carried into the ledger) cannot force a full
        // fee-collect+burn+remint churn on every accrual. Dust keeps accruing until it crosses the threshold.
        uint256 accumulated = accumulatedProjectTokens[projectId];
        if (accumulated < _MIN_ADD_ACCUMULATION) {
            revert JBUniswapV4LPSplitHook_AccumulationBelowThreshold({
                projectId: projectId, accumulated: accumulated, threshold: _MIN_ADD_ACCUMULATION
            });
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
    function claimFeeTokensFor(uint256 projectId, address beneficiary) external nonReentrant {
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

    /// @notice Collect accrued Uniswap LP trading fees for a project (from its single active position) and route them
    /// into the project's protocol-owned liquidity. A best-effort fee-project cut is taken on EACH side; the remaining
    /// project-token portion is carried into the ask-leg ledger and the remaining terminal-token portion into the
    /// bid-leg ledger, both becoming future liquidity (never burned, never deposited to the treasury). Callable by
    /// anyone.
    /// @param projectId The ID of the project whose LP fees to collect.
    /// @param terminalToken The terminal token paired with the project token in the pool.
    // forge-lint: disable-next-line(mixed-case-function)
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external nonReentrant {
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
    /// accumulated reserved tokens. Permissionless: anyone may seed the pool. Abuse is bounded by the economic gate
    /// (the seed reverts once spot reaches the issuance ceiling) and, for an already-initialized pool, the oracle-TWAP
    /// deviation guard.
    /// @param projectId The ID of the project whose accumulated tokens should be deployed as LP.
    function deployPool(uint256 projectId) external nonReentrant {
        // `deployPool` is fully permissionless: anyone may seed the pool. The only gate is the economic one applied
        // inside the mint executor — the seed reverts if the pool's live spot has already reached the project's
        // issuance ceiling, so a pool can only be seeded while there is a live corridor for asks to fill.
        address controller = _controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

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
    function processSplitWith(JBSplitHookContext calldata context) external payable nonReentrant {
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

        // Record the accumulation-era ruleset weight on first accumulation as a reference snapshot. Post-deployment
        // this is already set, so the branch is a no-op.
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
    function rebalanceLiquidity(uint256 projectId, address terminalToken) external nonReentrant {
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

        // Collect and route accrued LP trading fees BEFORE the burn so the terminal-fee remainder lands in this
        // project's bid-leg ledger and is folded into the re-minted position's bid (rather than compounding the burn's
        // principal read), and the project-fee remainder lands in the ask-leg ledger. The corridor itself is derived
        // from the project's rates/surplus, which fee routing leaves untouched: collected fees become protocol-owned
        // liquidity held in the hook, not treasury surplus.
        _collectAndRouteFees({
            projectId: projectId, projectToken: projectToken, terminalToken: terminalToken, tokenId: tokenId, key: key
        });

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

        // Drift guard: reject a rebalance that would not meaningfully re-range. The comparison is against the CORRIDOR
        // the live position was ranged against (floor + ceiling), NOT the active position's adaptive bounds — the
        // lower/bid bound moves with the hook's terminal balance rather than real economic drift, so comparing it would
        // let a pure terminal inflow churn the position. If the fresh corridor is within `_MIN_REBALANCE_DRIFT_TICKS`
        // of the ranged-against corridor on BOTH bounds, there is nothing worth churning for.
        int24 prevCorridorLower = rangedCorridorLowerOf[projectId][terminalToken];
        int24 prevCorridorUpper = rangedCorridorUpperOf[projectId][terminalToken];
        if (
            _absTickDiff({a: floorTick, b: prevCorridorLower}) <= _MIN_REBALANCE_DRIFT_TICKS
                && _absTickDiff({a: ceilingTick, b: prevCorridorUpper}) <= _MIN_REBALANCE_DRIFT_TICKS
        ) {
            revert JBUniswapV4LPSplitHook_DriftBelowThreshold({
                currentTickLower: prevCorridorLower,
                currentTickUpper: prevCorridorUpper,
                newTickLower: floorTick,
                newTickUpper: ceilingTick
            });
        }

        // Reject the rebalance while the pool's spot price is off the oracle TWAP. The burn and re-mint price against
        // the live spot, so a sandwiched/JIT-skewed spot would make the re-mint deploy at a manipulated ratio. Mirrors
        // `addLiquidity`'s guard (and, like it, reverts if the oracle TWAP has not warmed up yet).
        _requireSpotNearTwap({projectId: projectId, terminalToken: terminalToken, key: key});

        // Burn the live position and re-mint ONE adaptive position across the fresh corridor, folding in recovered
        // tokens and any hook-held credits. Asks (project) are anchored to the full project balance up to the ceiling;
        // the bid bound is solved from the recovered/accrued terminal (clamped at the corridor floor). The economic
        // spot-below-ceiling gate is applied inside `_consolidateAndReMint`, so an inverted corridor reverts here too.
        _consolidateAndReMint({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            corridorLower: floorTick,
            corridorUpper: ceilingTick,
            controller: controller
        });

        emit PermissionlessRebalanced({
            projectId: projectId,
            terminalToken: terminalToken,
            tickLower: activeTickLowerOf[projectId][terminalToken],
            tickUpper: activeTickUpperOf[projectId][terminalToken],
            caller: msg.sender
        });
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Whether this contract implements a given interface (ERC-165).
    /// @param interfaceId The ERC-165 interface identifier to check.
    /// @return supported True if `interfaceId` is the hook or split-hook interface.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool supported) {
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
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Absolute difference between two ticks, used for corridor-drift and TWAP-deviation comparisons.
    /// @param a The first tick.
    /// @param b The second tick.
    /// @return difference The non-negative distance between the two ticks.
    function _absTickDiff(int24 a, int24 b) internal pure returns (int24 difference) {
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

    /// @notice Compute the adaptive `[tickLower, tickUpper]` range and mintable liquidity for ONE position spanning the
    /// live spot, given the held project/terminal amounts. The ask leg (project-token-only, from spot out to the
    /// issuance ceiling) is anchored to the ENTIRE project balance, so asks are never starved by a scarce terminal.
    /// The bid leg (terminal-token-only, from spot toward the cash-out floor) is sized by solving for the bound at
    /// which the terminal balance exactly fills the leg at that same liquidity; if the terminal is so abundant that the
    /// solved bound would fall past the floor, the bound is pinned at the floor and `bidAmountForMint < terminalAmount`
    /// (the excess is routed to the project balance by the caller as a leftover, never stranded).
    /// @dev Branches on token ordering — Uniswap's below-range/above-range single-sided rule flips with which
    /// currency
    /// the project token is, so the ask leg is ABOVE spot when the project is token0 and BELOW spot when it is token1.
    /// The caller MUST have already rejected a spot at/past the issuance ceiling (`_requireSpotBelowCeiling`), which
    /// guarantees a non-empty ask leg here.
    /// @param projectIsToken0 Whether the project token sorts as Uniswap currency0.
    /// @param corridorLower The lower (raw-ascending) bound of the project's economic corridor.
    /// @param corridorUpper The upper (raw-ascending) bound of the project's economic corridor.
    /// @param sqrtSpotX96 The pool's live spot sqrt price.
    /// @param projectAmount The total project tokens to deploy as the ask leg.
    /// @param terminalAmount The total terminal tokens available to seed the bid leg.
    /// @return tickLower The lower tick of the adaptive position.
    /// @return tickUpper The upper tick of the adaptive position.
    /// @return bidAmountForMint The terminal amount actually paired into the mint (== `terminalAmount` unless the bid
    /// bound was pinned at the floor, in which case it is the floor-leg capacity and the remainder is a leftover).
    function _adaptiveRange(
        bool projectIsToken0,
        int24 corridorLower,
        int24 corridorUpper,
        uint160 sqrtSpotX96,
        uint256 projectAmount,
        uint256 terminalAmount
    )
        internal
        pure
        returns (int24 tickLower, int24 tickUpper, uint256 bidAmountForMint)
    {
        if (projectIsToken0) {
            // Project is token0: asks (token0) sit ABOVE spot, up to the issuance ceiling (the corridor's UPPER tick).
            // Bids (token1 = terminal) sit BELOW spot, down toward the cash-out floor (the corridor's LOWER tick).
            int24 ceilingTick = corridorUpper;
            int24 floorTick = corridorLower;
            uint160 sqrtCeiling = TickMath.getSqrtPriceAtTick(ceilingTick);
            uint160 sqrtFloor = TickMath.getSqrtPriceAtTick(floorTick);

            // Anchor liquidity to the ask leg so the ENTIRE project balance deploys across [spot, ceiling].
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0({
                sqrtPriceAX96: sqrtSpotX96, sqrtPriceBX96: sqrtCeiling, amount0: projectAmount
            });

            tickUpper = ceilingTick;

            // Terminal the full bid leg [floor, spot] can absorb at that liquidity.
            uint256 maxBid = liquidity == 0
                ? 0
                : SqrtPriceMath.getAmount1Delta({
                    sqrtPriceAX96: sqrtFloor, sqrtPriceBX96: sqrtSpotX96, liquidity: liquidity, roundUp: false
                });

            if (terminalAmount >= maxBid) {
                // Terminal is abundant: pin the bid bound at the floor; only `maxBid` is paired, the rest is a
                // leftover.
                tickLower = floorTick;
                bidAmountForMint = maxBid;
            } else {
                // Solve the bid bound X where the terminal exactly fills [X, spot]: sqrt(X) = sqrt(spot) - T/L.
                uint160 sqrtBid = SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown({
                    sqrtPX96: sqrtSpotX96, liquidity: liquidity, amount: terminalAmount, add: false
                });
                // Align the bid bound INWARD (up) so the paired range never demands more terminal than is held.
                tickLower = JBLPSplitHookHelpers.alignTickToSpacingCeil({
                    tick: TickMath.getTickAtSqrtPrice(sqrtBid), spacing: TICK_SPACING
                });
                if (tickLower < floorTick) tickLower = floorTick;
                bidAmountForMint = terminalAmount;
            }
        } else {
            // Project is token1: mirror image. Asks (token1) sit BELOW spot down to the issuance ceiling (the
            // corridor's LOWER tick). Bids (token0 = terminal) sit ABOVE spot, up toward the cash-out floor (the
            // corridor's UPPER tick).
            int24 ceilingTick = corridorLower;
            int24 floorTick = corridorUpper;
            uint160 sqrtCeiling = TickMath.getSqrtPriceAtTick(ceilingTick);
            uint160 sqrtFloor = TickMath.getSqrtPriceAtTick(floorTick);

            // Anchor liquidity to the ask leg so the ENTIRE project balance deploys across [ceiling, spot].
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1({
                sqrtPriceAX96: sqrtCeiling, sqrtPriceBX96: sqrtSpotX96, amount1: projectAmount
            });

            tickLower = ceilingTick;

            // Terminal the full bid leg [spot, floor] can absorb at that liquidity.
            uint256 maxBid = liquidity == 0
                ? 0
                : SqrtPriceMath.getAmount0Delta({
                    sqrtPriceAX96: sqrtSpotX96, sqrtPriceBX96: sqrtFloor, liquidity: liquidity, roundUp: false
                });

            if (terminalAmount >= maxBid) {
                // Terminal is abundant: pin the bid bound at the floor; only `maxBid` is paired, the rest is a
                // leftover.
                tickUpper = floorTick;
                bidAmountForMint = maxBid;
            } else {
                // Solve the bid bound Y where the terminal exactly fills [spot, Y] (removing token0 raises the price).
                uint160 sqrtBid = SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp({
                    sqrtPX96: sqrtSpotX96, liquidity: liquidity, amount: terminalAmount, add: false
                });
                // Align the bid bound INWARD (down) so the paired range never demands more terminal than is held.
                tickUpper = JBLPSplitHookHelpers.alignTickToSpacing({
                    tick: TickMath.getTickAtSqrtPrice(sqrtBid), spacing: TICK_SPACING
                });
                if (tickUpper > floorTick) tickUpper = floorTick;
                bidAmountForMint = terminalAmount;
            }
        }
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
        // Collect and route any accrued LP trading fees BEFORE the re-mint so the terminal-fee remainder lands in this
        // project's bid-leg ledger (folded into the re-mint's bid) and the project-fee remainder in the ask-leg ledger.
        // Skipped on a first deploy (no position yet). The burn inside `_consolidateAndReMint` then recovers only
        // principal.
        uint256 existingTokenId = tokenIdOf[projectId][terminalToken];
        if (existingTokenId != 0) {
            _collectAndRouteFees({
                projectId: projectId,
                projectToken: projectToken,
                terminalToken: terminalToken,
                tokenId: existingTokenId,
                key: poolKeysOf[projectId][terminalToken]
            });
        }

        // The project's economic corridor (cash-out floor to issuance ceiling), as a sorted ascending raw tick range.
        // The adaptive-range logic inside `_consolidateAndReMint` anchors asks to the full project balance up to the
        // ceiling and solves the bid bound from the terminal balance (clamped at the floor), spanning the live spot.
        (int24 corridorLower, int24 corridorUpper) = JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: IJBDirectory(DIRECTORY),
            suckerRegistry: SUCKER_REGISTRY,
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });

        _consolidateAndReMint({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            corridorLower: corridorLower,
            corridorUpper: corridorUpper,
            controller: controller
        });
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

    /// @notice Take a best-effort protocol fee cut of `amount` (in `feeToken`) for `projectId` by paying it to the
    /// configured fee project, and return the non-cut remainder. Symmetric across the terminal-token and project-token
    /// sides. The cut is forgiven — the full `amount` is returned — when there is no cut to take, when the fee
    /// project
    /// has no terminal accepting `feeToken`, or when the fee terminal's `pay` reverts; a forgiven cut never blocks the
    /// surrounding fee collection.
    /// @dev Fee routing uses zero slippage (minReturnedTokens = 0) by design: slippage protection is the fee project's
    /// responsibility (via its own data hook / buyback hook), not this contract's. The reentrancy-safe reserve dance
    /// (pre-increment `_totalOutstandingFeeTokenClaims`/`_inflightFeeRoutingCount` before the external pay, reconcile
    /// after) is preserved, and fully rolled back on the forgive (catch) path.
    /// @param projectId The project whose LP fees are being cut.
    /// @param feeToken The token the fee is denominated in (the terminal token or the project token).
    /// @param amount The pre-cut fee amount to split.
    /// @return remainder The portion of `amount` left after the cut (== `amount` when the cut is forgiven).
    function _attemptFeeProjectCut(
        uint256 projectId,
        address feeToken,
        uint256 amount
    )
        internal
        returns (uint256 remainder)
    {
        uint256 cut = (amount * feePercent) / BPS;
        address feeTerminal = cut == 0 ? address(0) : _primaryTerminalOf({projectId: feeProjectId, token: feeToken});

        // Forgive when there is nothing to cut or no fee terminal accepts `feeToken`: the whole amount flows to LP.
        if (feeTerminal == address(0)) {
            emit LPFeesRouted({
                projectId: projectId,
                token: feeToken,
                totalAmount: amount,
                feeAmount: 0,
                remainingAmount: amount,
                feeTokensMinted: 0,
                caller: msg.sender
            });
            return amount;
        }

        // Look up the fee project's ERC-20 BEFORE the pay so the reserve can be pre-incremented, keeping any reentrant
        // collection/accumulation from treating in-flight fee tokens as free balance.
        address feeProjectToken = _tokenOf(feeProjectId);

        // If this project already has unclaimed ERC-20 fee tokens, keep using that snapshotted token address; a
        // fee-project token migration must not strand the earlier claim behind a new token contract.
        address claimToken = claimableFeeTokenOf[projectId];
        if (claimToken != address(0) && claimToken != feeProjectToken) {
            revert JBUniswapV4LPSplitHook_UnclaimedFeeTokenChanged({
                previousToken: claimToken, nextToken: feeProjectToken
            });
        }

        // Pre-increment with `cut` as a conservative estimate; reconciled to the actual received amount after the pay.
        uint256 feeProjectTokenBalanceBefore;
        if (feeProjectToken != address(0)) {
            feeProjectTokenBalanceBefore = IERC20(feeProjectToken).balanceOf(address(this));
            _totalOutstandingFeeTokenClaims[feeProjectToken] += cut;
            _inflightFeeRoutingCount[feeProjectToken] += 1;
        }

        uint256 received;
        // Pay the cut best-effort. The pay (plus its ERC-20 approve + allowance-consumption check) runs inside an
        // external self-call so a revert on ANY of them is caught here and forgiven rather than bubbling up and
        // blocking the collection. The self-call target is unguarded (so the surrounding `nonReentrant` guard is not
        // self-tripped) and restricted to `address(this)`.
        try this.payFeeProjectCut({feeTerminal: feeTerminal, feeToken: feeToken, amount: cut}) returns (
            uint256 payReturn
        ) {
            if (feeProjectToken != address(0)) {
                // Prefer the observed balance delta over the terminal return value so fee-on-transfer or nonstandard
                // token behavior cannot overstate what this hook actually received.
                uint256 expectedBalanceWithoutFeeTokens = feeProjectTokenBalanceBefore;
                // If the cut is paid in the fee-project ERC-20 itself, the pay first transfers `cut` out of this hook;
                // subtract it from the baseline so the later balance delta does not hide freshly minted fee tokens.
                if (feeToken == feeProjectToken) expectedBalanceWithoutFeeTokens -= cut;
                uint256 feeProjectTokenBalanceAfter = IERC20(feeProjectToken).balanceOf(address(this));
                received = feeProjectTokenBalanceAfter > expectedBalanceWithoutFeeTokens
                    ? feeProjectTokenBalanceAfter - expectedBalanceWithoutFeeTokens
                    : 0;
                // Remove the conservative estimate and reserve the reconciled token amount for later claiming.
                _totalOutstandingFeeTokenClaims[feeProjectToken] =
                    _totalOutstandingFeeTokenClaims[feeProjectToken] - cut + received;
                _inflightFeeRoutingCount[feeProjectToken] -= 1;
            } else {
                received = payReturn;
            }

            // Track fee proceeds for later claiming: ERC-20s via `claimableFeeTokens`, else fee-project credits.
            if (received > 0) {
                if (feeProjectToken != address(0)) {
                    claimableFeeTokenOf[projectId] = feeProjectToken;
                    claimableFeeTokens[projectId] += received;
                } else {
                    claimableFeeCredits[projectId] += received;
                    _totalOutstandingFeeCreditClaims[feeProjectId] += received;
                }
            }

            remainder = amount - cut;
        } catch {
            // Forgive the cut: fully roll back the pre-incremented reserve and return the whole amount to LP.
            if (feeProjectToken != address(0)) {
                _totalOutstandingFeeTokenClaims[feeProjectToken] -= cut;
                _inflightFeeRoutingCount[feeProjectToken] -= 1;
            }
            cut = 0;
            remainder = amount;
        }

        emit LPFeesRouted({
            projectId: projectId,
            token: feeToken,
            totalAmount: amount,
            feeAmount: cut,
            remainingAmount: remainder,
            feeTokensMinted: received,
            caller: msg.sender
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

        // Position principal is bounded by pooled token balances, so the discounted floor normally fits in uint128;
        // reject the pathological case rather than let a wraparound shrink the floor and accept a bad unwind.
        min0 = _toUint128((amount0 * _BURN_SLIPPAGE_BPS) / BPS);
        min1 = _toUint128((amount1 * _BURN_SLIPPAGE_BPS) / BPS);
    }

    /// @notice Carry leftover tokens after an LP add forward, never burning. Project-token dust returns to the
    /// accumulation ledger and terminal-token dust returns to the terminal ledger — both becoming this project's
    /// protocol-owned liquidity on the next mint. Neither side is deposited into the project's treasury.
    /// @dev Uses balance-delta measurement so fee-on-transfer behavior and V4 SWEEP dust cannot mis-account leftovers,
    /// and `+=` on each ledger so a reentrant `processSplitWith` inflow is preserved.
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
        if (termLeftover > 0) accumulatedTerminalTokens[projectId][terminalToken] += termLeftover;
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
    /// @dev Each side takes a best-effort fee-project cut; the terminal-token remainder is carried into the bid-leg
    /// ledger (`accumulatedTerminalTokens`) and the project-token remainder into the ask-leg ledger
    /// (`accumulatedProjectTokens`), both becoming future liquidity. The hook never burns. There is at most one
    /// position per project/terminal-token pair (re-ranging burns the old one and re-mints), so a single collection
    /// covers all of the project's LP fees.
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

    /// @notice Burn the project's live position (if any), fold in its recovered PRINCIPAL, the accumulation ledger, and
    /// any hook-held project-token credits, and re-mint them as EXACTLY ONE position across `[tickLower, tickUpper]` at
    /// the live spot. Leftovers are carried forward (project → the accumulation ledger; terminal → the project
    /// balance), never burned. This is the single lifecycle primitive behind deploy, add, and rebalance; setting
    /// `tokenIdOf` to the fresh mint AFTER burning the prior id is what enforces the one-position-per-pair invariant.
    /// @dev The mint is single-sided (project-only) when the range sits on one side of the spot, and two-sided when the
    /// range spans it — determined purely by `[tickLower, tickUpper]` vs. spot, so the caller controls single vs. two
    /// sided by choosing the range. The burn slippage floor is always contract-derived (a fraction of a pre-burn
    /// principal read at the live spot); callers never supply burn minimums. Before burning an existing position, any
    /// accrued LP trading fees are collected and routed via `_collectAndRouteFees` (each side net of its best-effort
    /// fee-project cut, the terminal remainder carried into the bid-leg ledger and the project remainder into the
    /// ask-leg ledger) so the burn recovers only principal — trading fees are never re-folded into LP as untaxed
    /// principal.
    /// @param projectId The ID of the project.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param corridorLower The lower (raw-ascending) bound of the project's economic corridor.
    /// @param corridorUpper The upper (raw-ascending) bound of the project's economic corridor.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    function _consolidateAndReMint(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        int24 corridorLower,
        int24 corridorUpper,
        address controller
    )
        internal
    {
        PoolKey memory key = poolKeysOf[projectId][terminalToken];

        // Fold hook-held project-token credits into transferable ERC-20 so they are included in the mint, not stranded.
        uint256 claimedCredits = _claimHookCreditsFor({projectId: projectId, controller: controller});

        // Burn the live position (if any), recovering only its PRINCIPAL with a contract-derived slippage floor.
        // Snapshot the balances AFTER claiming credits so the recovered-deltas exclude them (counted separately below).
        // LP trading fees are collected and routed by the CALLER before this runs (so the corridor reflects post-fee
        // surplus), leaving the burn to recover only principal.
        uint256 existingTokenId = tokenIdOf[projectId][terminalToken];
        uint256 recoveredProject;
        uint256 recoveredTerminal;
        if (existingTokenId != 0) {
            uint256 projBalBeforeBurn = IERC20(projectToken).balanceOf(address(this));
            uint256 termBalBeforeBurn = _getTerminalTokenBalance(terminalToken);
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
            recoveredTerminal = _getTerminalTokenBalance(terminalToken) - termBalBeforeBurn;
        }

        // Held amounts to re-mint. Project side = ledger + recovered-from-burn + freshly claimed credits (all now in
        // this hook's transferable balance). Terminal side = ONLY the terminal recovered from burning THIS project's
        // position PLUS this project's own terminal ledger (its collected terminal-fee remainders and prior mint
        // leftovers) — both funded exclusively by this project's own inflows. The shared clone's raw terminal balance
        // may include other projects' recovered terminal, donations, or another project's tokens set as this one's
        // terminal; spending that balance would let one project capture another's — so it is never read for sizing.
        uint256 projectAmount = accumulatedProjectTokens[projectId] + recoveredProject + claimedCredits;
        uint256 terminalAmount = recoveredTerminal + accumulatedTerminalTokens[projectId][terminalToken];

        // Resolve token ordering once; it flips both the economic gate and the adaptive ask/bid geometry.
        (address token0,) = _sortTokens({tokenA: projectToken, tokenB: Currency.unwrap(_toCurrency(terminalToken))});
        bool projectIsToken0 = projectToken == token0;

        // Economic gate: only seed/extend/rebalance while the spot sits below the issuance ceiling, so asks below the
        // ceiling are fillable. A spot at/past the ceiling would make the adaptive ask leg empty/inverted.
        uint160 sqrtPriceX96 = _getSqrtPriceX96(key);
        int24 spotTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        _requireSpotBelowCeiling({
            projectIsToken0: projectIsToken0,
            corridorLower: corridorLower,
            corridorUpper: corridorUpper,
            spotTick: spotTick
        });

        // Compute the adaptive position: asks anchored to the full project balance up to the ceiling, bid bound solved
        // from the terminal balance (clamped at the floor). `bidAmountForMint` is the terminal actually paired; any
        // excess (when the bid bound pins at the floor) stays a leftover carried to the project balance below.
        (int24 tickLower, int24 tickUpper, uint256 bidAmountForMint) = _adaptiveRange({
            projectIsToken0: projectIsToken0,
            corridorLower: corridorLower,
            corridorUpper: corridorUpper,
            sqrtSpotX96: sqrtPriceX96,
            projectAmount: projectAmount,
            terminalAmount: terminalAmount
        });

        // The terminal amount paired into the mint (caps + liquidity) is the solved/clamped bid `bidAmountForMint`, not
        // the full held terminal — so a floor-pinned excess is left over and carried back to the terminal ledger
        // rather
        // than over-minted.
        uint256 amount0 = projectIsToken0 ? projectAmount : bidAmountForMint;
        uint256 amount1 = projectIsToken0 ? bidAmountForMint : projectAmount;

        // A degenerate range (corridor collapsed to a single spacing) leaves no room to mint.
        if (tickLower >= tickUpper) revert JBUniswapV4LPSplitHook_ZeroLiquidity({amount0: amount0, amount1: amount1});

        // Derive the mintable liquidity from the paired amounts at the live spot across the adaptive range. Passing the
        // paired amounts as both the liquidity basis AND the settle caps guarantees the mint never demands more than is
        // held (the canonical `getLiquidityForAmounts` contract), and — because the project side is the binding
        // constraint by construction — the entire project balance is deployed as asks.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts({
            sqrtPriceX96: sqrtPriceX96,
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(tickUpper),
            amount0: amount0,
            amount1: amount1
        });
        if (liquidity == 0) revert JBUniswapV4LPSplitHook_ZeroLiquidity({amount0: amount0, amount1: amount1});

        // CEI: clear BOTH ledgers before the external mint; any unconsumed remainder on either side is carried back
        // below (never burned, never deposited to the treasury). Record the corridor this position is ranged against
        // (drift-guard basis; independent of the adaptive bounds) here too — it does not depend on the mint result,
        // and
        // writing it pre-mint keeps `corridorLower`/`corridorUpper` off the stack across the (inlined) mint.
        accumulatedProjectTokens[projectId] = 0;
        accumulatedTerminalTokens[projectId][terminalToken] = 0;
        rangedCorridorLowerOf[projectId][terminalToken] = corridorLower;
        rangedCorridorUpperOf[projectId][terminalToken] = corridorUpper;

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

        // Carry leftovers against the FULL held terminal (not the paired `bidAmountForMint`): the floor-pinned excess
        // terminal, plus any alignment dust, is carried back to the terminal bid-leg ledger — never stranded, never
        // burned, never deposited to the treasury. Project-token dust returns to the accumulation ledger.
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

    /// @notice Create and initialize Uniswap V4 pool.
    /// @param projectId The ID of the project.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return key The pool key identifying the newly created Uniswap V4 pool.
    /// @return wasAlreadyInitialized Whether the pool already had a live price before this call (i.e. someone else
    /// initialized it), as opposed to being initialized here for the first time.
    function _createAndInitializePool(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        address controller,
        JBRuleset memory ruleset
    )
        internal
        returns (PoolKey memory key, bool wasAlreadyInitialized)
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
        wasAlreadyInitialized = existingSqrtPriceX96 != 0;
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
    /// @return balance This hook's balance of `currency`.
    function _currencyBalance(Currency currency) internal view returns (uint256 balance) {
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
            (PoolKey memory key, bool wasAlreadyInitialized) = _createAndInitializePool({
                projectId: projectId,
                projectToken: projectToken,
                terminalToken: terminalToken,
                controller: controller,
                ruleset: ruleset
            });

            // For a pool that was ALREADY initialized before this deploy (the revnet norm — a buyback pool already
            // exists), validate the live spot against the oracle TWAP before minting, mirroring `addLiquidity`, so a
            // deploy cannot be sandwiched into minting at a manipulated price. A pool this hook initializes itself in
            // the same transaction has no TWAP history, so the guard is skipped (it would revert on cold start).
            if (wasAlreadyInitialized) {
                _requireSpotNearTwap({projectId: projectId, terminalToken: terminalToken, key: key});
            }
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
            // Settle caps must fit Uniswap V4's uint128 fields; reject rather than truncate an out-of-range amount.
            _toUint128(amount0),
            _toUint128(amount1),
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

    /// @notice Pay a fee-project cut of `amount` in `feeToken` to `feeTerminal`, returning the terminal's reported
    /// beneficiary token count. Callable only via this contract's own best-effort `_attemptFeeProjectCut` so its revert
    /// (from the terminal `pay` or the ERC-20 allowance-consumption check) can be caught and forgiven.
    /// @dev This target is intentionally NOT `nonReentrant`: it is reached through an internal `this.` self-call while
    /// the surrounding entry point still holds the reentrancy lock, so guarding it would self-revert. A genuine
    /// reentrant call into any guarded entry point during the fee `pay` is still rejected by that outer lock, and the
    /// `msg.sender == address(this)` gate blocks any direct external call.
    /// @param feeTerminal The fee project's terminal accepting `feeToken`.
    /// @param feeToken The token to pay the cut in (native sentinel or ERC-20).
    /// @param amount The cut amount to pay.
    /// @return beneficiaryTokenCount The fee-project token/credit count the terminal reports minting to this hook.
    function payFeeProjectCut(
        address feeTerminal,
        address feeToken,
        uint256 amount
    )
        external
        returns (uint256 beneficiaryTokenCount)
    {
        if (msg.sender != address(this)) revert JBUniswapV4LPSplitHook_Unauthorized();

        // Native ETH is forwarded as value; ERC-20 is pulled by the terminal via an exact-use approval that must be
        // fully consumed (a leftover allowance is live spend authority and reverts — caught upstream as a forgive).
        if (_isNativeToken(feeToken)) {
            beneficiaryTokenCount = IJBMultiTerminal(feeTerminal).pay{value: amount}({
                projectId: feeProjectId,
                token: feeToken,
                amount: amount,
                beneficiary: address(this),
                minReturnedTokens: 0,
                memo: "LP Fee",
                metadata: ""
            });
        } else {
            IERC20(feeToken).forceApprove({spender: feeTerminal, value: amount});
            beneficiaryTokenCount = IJBMultiTerminal(feeTerminal)
                .pay({
                projectId: feeProjectId,
                token: feeToken,
                amount: amount,
                beneficiary: address(this),
                minReturnedTokens: 0,
                memo: "LP Fee",
                metadata: ""
            });
            _requireTemporaryAllowanceConsumed({token: feeToken, spender: feeTerminal});
        }
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

    /// @notice Revert if the pool's live spot has reached or passed the project's issuance-price (ceiling) tick, so the
    /// adaptive ask leg would be empty/inverted. Ordering-aware: the ceiling is the corridor's UPPER tick when the
    /// project is token0 and its LOWER tick when the project is token1.
    /// @param projectIsToken0 Whether the project token sorts as Uniswap currency0.
    /// @param corridorLower The lower (raw-ascending) bound of the project's economic corridor.
    /// @param corridorUpper The upper (raw-ascending) bound of the project's economic corridor.
    /// @param spotTick The pool's live spot tick.
    function _requireSpotBelowCeiling(
        bool projectIsToken0,
        int24 corridorLower,
        int24 corridorUpper,
        int24 spotTick
    )
        internal
        pure
    {
        // Project is token0: asks fill upward toward `corridorUpper`; a spot at/above it leaves no room for asks.
        // Project is token1: asks fill downward toward `corridorLower`; a spot at/below it leaves no room for asks.
        if (projectIsToken0) {
            if (spotTick >= corridorUpper) {
                revert JBUniswapV4LPSplitHook_SpotAboveCeilingAtSeed({spotTick: spotTick, ceilingTick: corridorUpper});
            }
        } else if (spotTick <= corridorLower) {
            revert JBUniswapV4LPSplitHook_SpotAboveCeilingAtSeed({spotTick: spotTick, ceilingTick: corridorLower});
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

    /// @notice Split collected LP fees into their terminal-token and project-token sides, take a best-effort
    /// fee-project cut on EACH side, and route every non-cut token into the originating project's protocol-owned
    /// liquidity: the project-token remainder into `accumulatedProjectTokens` (ask leg) and the terminal-token
    /// remainder into `accumulatedTerminalTokens` (bid leg). The hook never burns and never deposits fee tokens into
    /// the project's treasury.
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

        // Attempt the fee-project cut on the project-token side, then carry the remainder into the ask-leg ledger.
        if (projectFee > 0) {
            accumulatedProjectTokens[
                projectId
            ] += _attemptFeeProjectCut({projectId: projectId, feeToken: projectToken, amount: projectFee});
        }

        // Attempt the fee-project cut on the terminal-token side, then carry the remainder into the bid-leg ledger
        // (protocol-owned liquidity), NOT into the project's treasury.
        if (terminalFee > 0) {
            accumulatedTerminalTokens[
                projectId
            ][
                terminalToken
            ] += _attemptFeeProjectCut({projectId: projectId, feeToken: terminalToken, amount: terminalFee});
        }
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
    /// @return currency The matching Uniswap V4 `Currency` (address(0) for native ETH, else the ERC-20).
    function _toCurrency(address terminalToken) internal pure returns (Currency currency) {
        // Delegate to the shared pure library so the native-sentinel → address(0) mapping is applied consistently.
        return JBLPSplitHookHelpers.toCurrency(terminalToken);
    }

    /// @notice Narrow a `uint256` token amount to the `uint128` Uniswap V4 uses for settle caps and burn floors,
    /// reverting instead of silently truncating when the amount exceeds `type(uint128).max`.
    /// @param value The amount to narrow.
    /// @return narrowed The amount as a `uint128`.
    function _toUint128(uint256 value) internal pure returns (uint128 narrowed) {
        if (value > type(uint128).max) revert JBUniswapV4LPSplitHook_AmountExceedsUint128({amount: value});
        // The bound check above guarantees `value` fits `uint128`, so the narrowing cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Look up the controller address for a project.
    /// @param projectId The ID of the project.
    /// @return controller The project's current controller (address(0) if none is set).
    function _controllerOf(uint256 projectId) internal view returns (address controller) {
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
    /// @return tokenId The position manager's next-to-be-assigned NFT token id.
    function _nextTokenId() internal view returns (uint256 tokenId) {
        return positionManager.nextTokenId();
    }

    /// @notice Look up the owner of a project.
    /// @param projectId The ID of the project.
    /// @return owner The project's current owner (used as the permission account for `SET_BUYBACK_POOL` gates).
    function _ownerOf(uint256 projectId) internal view returns (address owner) {
        return PROJECTS.ownerOf(projectId);
    }

    /// @notice Look up the primary terminal for a project/token pair.
    /// @param projectId The ID of the project.
    /// @param token The token whose primary terminal to resolve.
    /// @return terminal The project's primary terminal for `token` (address(0) if none is set).
    function _primaryTerminalOf(uint256 projectId, address token) internal view returns (address terminal) {
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

    /// @notice Look up the ERC-20 token address for a project.
    /// @param projectId The ID of the project.
    /// @return token The project's deployed ERC-20 (address(0) if the project is credits-only with no ERC-20).
    function _tokenOf(uint256 projectId) internal view returns (address token) {
        return address(IJBTokens(TOKENS).tokenOf(projectId));
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
}
