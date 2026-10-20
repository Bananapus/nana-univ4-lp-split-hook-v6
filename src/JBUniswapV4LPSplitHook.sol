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
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
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
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";

import {IJBUniswapV4LPSplitHook} from "./interfaces/IJBUniswapV4LPSplitHook.sol";
import {JBLPSplitHookHelpers} from "./libraries/JBLPSplitHookHelpers.sol";
import {JBUniswapV4LPSplitHookMath} from "./libraries/JBUniswapV4LPSplitHookMath.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/// @notice A split hook that turns a Juicebox project's reserved-token distributions, and payouts sent to it once its
/// pool is deployed, into protocol-owned Uniswap V4 liquidity, held as at most TWO single-sided positions per project:
///
/// - The ASK holds project tokens from just past the pool's live price out to the issuance ceiling (never below the
/// cash-out floor).
/// - The BID holds terminal tokens from just past the live price back to the cash-out floor (never past the issuance
/// ceiling).
///
/// Trading converts each position toward the other token. Every recycle (inline on each reserved-token distribution
/// or payout, or the permissionless `deployPool`/`addLiquidity` retries) collects and routes fees, burns both
/// positions, and re-mints them single-sided around the new spot: every project token held (new reserved tokens,
/// recovered principal) goes into the ask, and every terminal token held (payouts, recovered principal) goes into the
/// bid. Collected LP fees take an optional
/// cut for a configurable fee project; the rest accrues to the project and raises its cash-out floor: terminal-token
/// fees are added to the project's balance in its primary terminal (more surplus), and project-token fees are burned
/// (less supply). A side whose add or burn fails is kept as liquidity instead. Reserved tokens are never burned:
/// supply-reducing burns of reserved tokens are a protocol-layer split-routing decision.
///
/// @dev Each clone manages exactly one Uniswap V4 pool per project (one terminal-token pairing). `deployPool`,
/// `addLiquidity`, and `collectAndRouteLPFees` are permissionless, with abuse bounded by the economic gates above and
/// an oracle-TWAP deviation guard. The pool uses a 1% fee tier, 200-tick spacing, and a shared oracle hook for TWAP
/// observations.
/// @dev Every state-changing external entry point that can reach an external call (terminal `pay`/`addToBalanceOf`,
/// controller `claimTokensFor`/`transferCreditsFrom`/`burnTokensOf`, or the Uniswap V4 PositionManager) is guarded with
/// solady's `ReentrancyGuard.nonReentrant`. Guarded functions never call each other externally (via `this.`) —
/// they share internal `_`-prefixed helpers — so the guard cannot self-revert on a legitimate call path.
contract JBUniswapV4LPSplitHook is IJBUniswapV4LPSplitHook, IJBSplitHook, JBPermissioned, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using PositionInfoLibrary for PositionInfo;
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

    /// @notice Thrown when a pre-initialized pool's price sits at or past the CASH-OUT FLOOR side of the project's
    /// economic tick range.
    /// @dev This prevents frontrunning attacks where an attacker initializes the pool at an extreme price and the
    /// hook's asks would sell the project's tokens into it. The issuance-ceiling side is accepted instead: the
    /// position minted there is bid-only and capped at the ceiling, and rejecting it would strand the pair forever.
    error JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds(
        uint160 existingPrice, uint160 lowerBound, uint160 upperBound
    );

    /// @notice Thrown when burning an LP-fee remainder did not remove exactly `count` of the hook's project ERC-20, or
    /// touched its project credits. Caught by `_routeCollectedFees`, which then keeps the remainder in the ask ledger.
    error JBUniswapV4LPSplitHook_FeeBurnNotExact(uint256 projectId, uint256 count);

    /// @notice Thrown when a non-zero fee percent is configured without a fee project to route the fee to.
    error JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject(uint256 feePercent, uint256 feeProjectId);

    /// @notice Thrown when the hook's held balance of a token is less than the amount an operation requires.
    error JBUniswapV4LPSplitHook_InsufficientBalance(uint256 available, uint256 required);

    /// @notice Thrown when the configured fee percent exceeds the maximum the hook allows.
    error JBUniswapV4LPSplitHook_InvalidFeePercent(uint256 feePercent, uint256 maxFeePercent);

    /// @notice Thrown when a project's controller or token cannot be resolved, so the project is not usable by the
    /// hook.
    error JBUniswapV4LPSplitHook_InvalidProjectId(uint256 projectId, address controller, address projectToken);

    /// @notice Thrown when a split arrives under a group ID that matches neither reserved tokens (1) nor a payout of
    /// its token (`uint256(uint160(token))`).
    error JBUniswapV4LPSplitHook_InvalidSplitGroup(uint256 groupId, address token);

    /// @notice Thrown when an action is attempted in a lifecycle stage that does not permit it (e.g. growing a pool
    /// that does not exist yet).
    error JBUniswapV4LPSplitHook_InvalidStageForAction(uint256 projectId, address terminalToken, uint256 tokenId);

    /// @notice Thrown when the terminal token supplied for an operation is not the one this clone's pool is paired
    /// against.
    error JBUniswapV4LPSplitHook_InvalidTerminalToken(uint256 projectId, address terminalToken);

    /// @notice Thrown when a project's corridor is empty and the hook holds no live position to retire: the cash-out
    /// value per token reaches the issuance price, or no pair of distinct aligned ticks fits between them, so no
    /// quotable range is both at or above the cash-out value and at or below the issuance price.
    error JBUniswapV4LPSplitHook_EmptyCorridor(uint256 projectId, address terminalToken);

    /// @notice Thrown when the pool's live spot leaves nothing for the hook to deploy: no aligned ask range between the
    /// spot and the issuance ceiling (or no project tokens to fill one), AND no terminal tokens to offer as bids
    /// between the spot and the cash-out floor (or no aligned bid range for them).
    /// @dev This is EXPECTED behavior, not a failure to repair. The hook never offers project tokens below the
    /// issuance price, so a spot at or past the issuance ceiling correctly leaves the accumulated project tokens
    /// undeployed. They stay in `accumulatedProjectTokens` and deploy on a later call, once the issuance price rises
    /// (the ceiling moves up) or the pool's spot falls back into the corridor.
    error JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot(
        int24 spotTick, int24 ceilingTick, uint256 projectAmount, uint256 terminalAmount
    );

    /// @notice Thrown when the split hook context names a hook other than this one, so the split was not routed here.
    error JBUniswapV4LPSplitHook_NotHookSpecifiedInContext(address expectedHook, address actualHook);

    /// @notice Thrown when an operation that requires accumulated project tokens finds none held for the project.
    error JBUniswapV4LPSplitHook_NoTokensAccumulated(uint256 projectId);

    /// @notice Thrown when a project routes more than one terminal token to the hook, which it cannot pair into a
    /// single pool.
    error JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported(uint256 projectId, address terminalToken);

    /// @notice Thrown when an amount to approve through Permit2 exceeds the maximum a Permit2 allowance can hold.
    error JBUniswapV4LPSplitHook_Permit2AmountOverflow(address token, uint256 amount, uint256 maxAmount);

    /// @notice Thrown when pool deployment is attempted for a project that already has a deployed pool.
    error JBUniswapV4LPSplitHook_PoolAlreadyDeployed(uint256 projectId, address terminalToken, uint256 tokenId);

    /// @notice Thrown when the pool's current price has deviated too far from the oracle TWAP, which would let a
    /// sandwich/JIT attacker make the hook add liquidity at a manipulated ratio.
    error JBUniswapV4LPSplitHook_PriceDeviationTooHigh(int24 spotTick, int24 twapTick, int24 maxDeviationTicks);

    /// @notice Thrown when a split is sent from an address that cannot deliver it: a reserved-token split from anyone
    /// but the project's controller, or a payout split from anyone but one of the project's terminals.
    error JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal(
        uint256 projectId, address sender, address controller
    );

    /// @notice Thrown when a temporary Permit2 allowance granted for an operation is not fully consumed by it.
    error JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed(address token, address spender, uint256 allowance);

    /// @notice Thrown when the oracle TWAP cannot be read (e.g. the pool oracle has not warmed up yet), so the pool
    /// price cannot be validated and liquidity must not be added.
    error JBUniswapV4LPSplitHook_TwapUnavailable(uint256 projectId, address terminalToken);

    /// @notice Thrown when sending `amount` of `token` (to a terminal, a fee claimant, or a mint) debited this hook by
    /// more than `amount`.
    error JBUniswapV4LPSplitHook_TransferNotExact(address token, uint256 amount);

    /// @notice Thrown when the best-effort fee-cut payment helper is called by anyone other than this contract itself.
    error JBUniswapV4LPSplitHook_Unauthorized();

    /// @notice Thrown when the token backing a project's unclaimed fee balance changes, so the prior balance can no
    /// longer be safely settled in the new token.
    error JBUniswapV4LPSplitHook_UnclaimedFeeTokenChanged(address previousToken, address nextToken);

    /// @notice Thrown when a split's native value does not match what it delivers: a native-token payout must carry
    /// exactly its amount, and a reserved-token or ERC-20 payout split must carry none.
    error JBUniswapV4LPSplitHook_UnexpectedMsgValue(uint256 value);

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

    /// @notice The gas an inline automation attempt starts with and may use: the minimum below which
    /// `processSplitWith` skips automation, and the cap it forwards, so a failing attempt never costs the caller more.
    /// @dev A cold full two-position recycle through real Core (two fee collections with fee-project payments, the fee
    /// adds and burns with their credit claim, the surplus read, two position burns, corridor math, oracle reads, and
    /// two mints) measured ~1.28M gas with one terminal, ~1.37M with four, ~1.43M with six, and ~1.49M with eight; the
    /// surplus read adds ~30k per terminal, so the budget covers about 20 terminals. A first deploy costs less. An
    /// attempt that still runs out of gas inside the self-call is reported like any failed attempt and keeps the
    /// intake. Capping the attempt keeps the caller's own work after the split (the terminal's remaining payout
    /// recipients, the controller's remaining reserved splits) safe: a caller that supplies this budget plus the
    /// reserve plus its own needs always finishes. The permissionless `deployPool`/`addLiquidity` retries are NOT bound
    /// by this budget.
    uint256 internal constant _AUTOMATION_GAS_BUDGET = 2_000_000;

    /// @notice The gas reserved for `processSplitWith` to finish (emit the failure event and return to the
    /// Controller) after an inline automation attempt, successful or not.
    /// @dev The attempt starts only with at least `_AUTOMATION_GAS_BUDGET + _AUTOMATION_GAS_RESERVE` left and is given
    /// at most the budget, so even an attempt that burns its whole budget (an out-of-gas revert) leaves this frame the
    /// reserve to log `LiquidityAutomationFailed` and return.
    uint256 internal constant _AUTOMATION_GAS_RESERVE = 64_000;

    /// @notice The slippage floor, out of `BPS`, applied to a burned position's contract-derived principal read.
    /// @dev When retiring a position, the hook computes the position's current token amounts from its on-chain
    /// liquidity and the live pool price, then requires the BURN to return at least this fraction of that read. The
    /// floor is always
    /// contract-derived — callers never supply burn minimums — so a sandwiched spot cannot make the hook accept an
    /// arbitrarily bad unwind.
    uint256 internal constant _BURN_SLIPPAGE_BPS = 9500;

    /// @notice Deadline window (in seconds) for PositionManager and Permit2 operations.
    uint256 internal constant _DEADLINE_SECONDS = 60;

    /// @notice The maximum allowed deviation (in ticks) between the pool's spot price and the oracle TWAP when adding
    /// liquidity. ~200 ticks ≈ 2.0% on the 1% fee tier; an add whose spot is further than this from the TWAP reverts,
    /// bounding how badly a sandwich/JIT attacker can skew the mint ratio.
    int24 internal constant _MAX_TWAP_DEVIATION_TICKS = 200;

    /// @notice The minimum accumulated project-token balance that makes a reserved-token intake attempt an inline
    /// deploy or recycle.
    /// @dev Below this, a dust distribution keeps accruing in the ledger instead of spending the caller's gas on a full
    /// recycle. The permissionless `deployPool`/`addLiquidity` entry points are not bound by it.
    uint256 internal constant _MIN_ADD_ACCUMULATION = 1e15;

    /// @notice The TWAP observation window (in seconds) used to validate the pool's spot price before adding liquidity.
    /// @dev Matches the buyback hook's expected oracle warmup. `addLiquidity` reverts until the pool oracle has at
    /// least this much history; accumulation continues safely in the meantime.
    uint32 internal constant _TWAP_WINDOW = 30 minutes;

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

    /// @notice The credit balance (project tokens with no ERC-20 deployed yet) currently accounted for each project.
    /// @dev Core transfers reserved credits to the hook BEFORE invoking it, so `processSplitWith` accepts and
    /// accounts them here rather than reverting (which would strand the already-transferred credits with no ledger).
    /// No Uniswap work happens until the project deploys an ERC-20; `deployPool`/`addLiquidity` then normalize this
    /// ledger into transferable tokens via `_claimHookCreditsFor` and deploy them as liquidity.
    /// @custom:param projectId The ID of the project to get the currently accounted LP credit balance of.
    mapping(uint256 projectId => uint256 accumulatedProjectCredits) public accumulatedProjectCredits;

    /// @notice The project-token balance held for each project outside its positions, waiting for the next ask.
    /// @dev Credited by `processSplitWith` (before and after deployment), principal recovered from burning the
    /// project's own positions, unconsumed mint leftovers, and project-token LP-fee remainders whose burn failed. Each
    /// recycle mints the whole ledger as the ask.
    /// @custom:param projectId The ID of the project to get the held project-token balance of.
    mapping(uint256 projectId => uint256 accumulatedProjectTokens) public accumulatedProjectTokens;

    /// @notice The terminal-token balance held for each project outside its positions, waiting for the next bid.
    /// @dev Mirrors `accumulatedProjectTokens` for the terminal side. Credited ONLY from the principal recovered from
    /// burning this project's own positions, unconsumed mint leftovers, this project's own terminal-token LP-fee
    /// remainders whose add to the project's balance failed, and payouts this project's terminals sent to the hook.
    /// The bid is sized from this ledger, never from the hook's raw token balance, so one project can never consume
    /// another's terminal or an outside donation.
    /// @custom:param projectId The ID of the project whose held terminal tokens to read.
    /// @custom:param terminalToken The terminal token paired with the project's token in its pool.
    mapping(uint256 projectId => mapping(address terminalToken => uint256)) public accumulatedTerminalTokens;

    /// @notice The PositionManager token ID of each project's ask position (project tokens, spot to ceiling).
    /// @dev Zero when the project has no live ask (before deployment, or when the last recycle left no ask range).
    /// @custom:param projectId The ID of the project.
    /// @custom:param terminalToken The terminal token paired with the project's token in the deployed pool.
    mapping(uint256 projectId => mapping(address terminalToken => uint256 tokenId)) public askTokenIdOf;

    /// @notice The PositionManager token ID of each project's bid position (terminal tokens, spot to floor).
    /// @dev Zero when the project has no live bid (no terminal tokens held, or no bid range at the last recycle).
    /// @custom:param projectId The ID of the project.
    /// @custom:param terminalToken The terminal token paired with the project's token in the deployed pool.
    mapping(uint256 projectId => mapping(address terminalToken => uint256 tokenId)) public bidTokenIdOf;

    /// @notice The buyback-hook registry configured for this clone.
    /// @dev Held as per-clone storage (set once via `initialize`) rather than an implementation immutable so different
    /// projects' clones can target different buyback registries and this implementation's CREATE2 inputs stay
    /// byte-identical on every chain. May be the zero address.
    IJBBuybackHookRegistry public buybackHook;

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

    /// @notice The terminal token the project's one supported pool was deployed against.
    /// @dev Set once, after the pool deployment succeeds, so post-deployment inline automation can resolve the pool
    /// pairing without re-running the terminal-token auto-selection. Never cleared: `hasDeployedPool` marks a one-way
    /// transition and no lifecycle replaces the pool.
    /// @custom:param projectId The ID of the project to get the deployed pool's terminal token of.
    mapping(uint256 projectId => address terminalToken) public deployedTerminalTokenOf;

    /// @notice The percentage of LP fees routed to the fee project, in basis points (e.g. 3800 = 38%).
    uint256 public feePercent;

    /// @notice The project ID that receives the LP-fee cut.
    uint256 public feeProjectId;

    /// @notice Whether each project has already deployed its single supported Uniswap V4 pool.
    /// @dev This is a boolean because the hook intentionally supports only one deployed terminal-token pool per
    /// project. It marks the one-way transition from "deployPool consumes the accumulation" to "addLiquidity recycles
    /// the positions with continued accumulation"; reserved tokens keep accumulating in both phases (the hook never
    /// burns them).
    /// @custom:param projectId The ID of the project to check deployment status for.
    mapping(uint256 projectId => bool hasDeployedPool) public hasDeployedPool;

    /// @notice The ruleset weight recorded when the hook first starts accumulating project tokens for each project.
    /// @dev Snapshotted on first accumulation as an accumulation-era reference. `deployPool` and `addLiquidity` are
    /// permissionless and gated only by economic + oracle-TWAP guards, not by this weight.
    /// @custom:param projectId The ID of the project to get the initial accumulation-era ruleset weight of.
    mapping(uint256 projectId => uint256 weight) public initialWeightOf;

    /// @notice The oracle hook used for configured Uniswap V4 pools (provides TWAP via observe()).
    /// @dev Set once per clone via `initialize` (alongside `feeProjectId` + `feePercent`). Held as storage rather
    /// than immutable because `JBUniswapV4Hook` is chain-different by design (inherits Uniswap's
    /// `BaseHook → ImmutableState`). Keeping it out of the constructor lets this implementation's CREATE2 inputs be
    /// byte-identical on every chain.
    IHooks public oracleHook;

    /// @notice The Uniswap V4 pool key configured for each project and terminal-token pair.
    /// @dev A project can only deploy one terminal-token pool, but the pool key still needs the terminal token as part
    /// of the lookup because deployment-time and fee-routing logic are keyed by that pair.
    /// @custom:param projectId The ID of the project to get a configured pool key for.
    /// @custom:param terminalToken The terminal token paired with the project's token in the configured pool.
    mapping(uint256 projectId => mapping(address terminalToken => PoolKey)) public poolKeysOf;

    /// @notice The Uniswap V4 pool manager contract that coordinates all pool operations.
    /// @dev Set once per clone via `initialize`. Held as storage rather than immutable so the implementation's
    /// constructor inputs are byte-identical on every chain (the V4 PoolManager varies per chain).
    IPoolManager public poolManager;

    /// @notice The Uniswap V4 position manager contract that handles liquidity position NFTs.
    /// @dev Set once per clone via `initialize`. Held as storage rather than immutable so the implementation's
    /// constructor inputs are byte-identical on every chain (the V4 PositionManager varies per chain).
    IPositionManager public positionManager;

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
    /// interactions). Native payouts arrive through `processSplitWith`, not here.
    receive() external payable {}

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Recycle the project's positions with its post-deployment accumulated reserved tokens: route both
    /// positions' fees, burn both, and re-mint the ask and bid single-sided around the live spot — the same executor
    /// `deployPool` uses. Callable at any time, with or without new tokens; rejected when the pool's spot has
    /// deviated from the oracle TWAP. Permissionless: abuse is bounded by the economic caps (the ask never sells below
    /// the cash-out floor, the bid never buys above the issuance ceiling) and the oracle-TWAP deviation guard.
    /// @param projectId The ID of the project whose accumulated tokens should be added as liquidity.
    /// @param terminalToken The terminal token paired with the project token in the deployed pool.
    function addLiquidity(uint256 projectId, address terminalToken) external nonReentrant {
        _addLiquidity({projectId: projectId, terminalToken: terminalToken});
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

    /// @notice Collect accrued Uniswap LP trading fees from a project's ask and bid positions and route them to the
    /// project. A best-effort fee-project cut is taken on EACH side; the remaining terminal-token portion is added to
    /// the project's balance in its primary terminal and the remaining project-token portion is burned, both raising
    /// the project's cash-out floor. A side whose add or burn fails is carried into its ledger instead (the bid or the
    /// ask), becoming liquidity at the next recycle. The positions themselves are not moved. Callable by anyone.
    /// @param projectId The ID of the project whose LP fees to collect.
    /// @param terminalToken The terminal token paired with the project token in the pool.
    // forge-lint: disable-next-line(mixed-case-function)
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external nonReentrant {
        uint256 askTokenId = askTokenIdOf[projectId][terminalToken];
        uint256 bidTokenId = bidTokenIdOf[projectId][terminalToken];

        // Ensure the project has at least one live position for this pair.
        if (askTokenId == 0 && bidTokenId == 0) {
            revert JBUniswapV4LPSplitHook_InvalidStageForAction({
                projectId: projectId, terminalToken: terminalToken, tokenId: 0
            });
        }

        // Resolve the project's ERC-20 token and pool key for fee collection.
        address projectToken = _tokenOf(projectId);
        PoolKey memory key = poolKeysOf[projectId][terminalToken];

        if (askTokenId != 0) {
            _collectAndRouteFees({
                projectId: projectId,
                projectToken: projectToken,
                terminalToken: terminalToken,
                tokenId: askTokenId,
                key: key
            });
        }
        if (bidTokenId != 0) {
            _collectAndRouteFees({
                projectId: projectId,
                projectToken: projectToken,
                terminalToken: terminalToken,
                tokenId: bidTokenId,
                key: key
            });
        }
    }

    /// @notice Create the Uniswap V4 pool and mint the initial LP position as a single-sided ask of the project's
    /// accumulated reserved tokens. Permissionless: anyone may seed the pool. Abuse is bounded by the economic gate
    /// (asks only reach up to the issuance ceiling, bids only down to the cash-out floor) and, for an
    /// already-initialized pool, the oracle-TWAP deviation guard.
    /// @param projectId The ID of the project whose accumulated tokens should be deployed as LP.
    function deployPool(uint256 projectId) external nonReentrant {
        _deployPool(projectId);
    }

    /// @notice Called by the Juicebox controller when reserved tokens are distributed to this hook's split, or by one
    /// of the project's terminals when a payout is sent to it. The hook FIRST durably accepts and accounts for the
    /// allocation, then best-effort attempts pool deployment or liquidity addition if enough gas remains. A failed
    /// attempt cannot touch the accepted inventory: it stays in the ledgers, retryable through the permissionless
    /// `deployPool`/`addLiquidity` entry points. The hook never burns what it is sent.
    /// @dev Reserved tokens (groupId == 1) come from the project's controller as the project's ERC-20, or as credits
    /// while the project has no ERC-20, and feed the ask. A payout (groupId == `uint256(uint160(token))`) comes from a
    /// terminal of the project in the deployed pool's terminal token, and feeds the bid. The order matters: validate
    /// the caller and context, account the tokens, THEN try to put them to work. Every check that can revert runs
    /// before the ledger write; a revert makes Core return the allocation to the project. Once intake has accounted
    /// the allocation, nothing in this frame reverts: automation runs behind a gas-bounded self-call whose failure is
    /// reported through `LiquidityAutomationFailed` (selector only, revert data is never copied unbounded).
    function processSplitWith(JBSplitHookContext calldata context) external payable nonReentrant {
        if (address(context.split.hook) != address(this)) {
            revert JBUniswapV4LPSplitHook_NotHookSpecifiedInContext({
                expectedHook: address(this), actualHook: address(context.split.hook)
            });
        }

        // Anything but a reserved-token distribution must be a payout of `context.token`.
        if (context.groupId != 1) {
            _acceptPayout(context);
            return;
        }

        // Reserved project tokens are either credits or the project's ERC-20, never a terminal token, so no native
        // value should ever accompany them.
        if (msg.value != 0) revert JBUniswapV4LPSplitHook_UnexpectedMsgValue({value: msg.value});

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

        // The canonical project token is the asset authority — `context.token` is never trusted for resolution.
        address projectToken = _tokenOf(context.projectId);

        // Credits-only project: Core transferred the credits to this hook BEFORE this call, so rejecting them would
        // strand them here with no ledger. Account them instead; they normalize into ERC-20 LP principal once the
        // project tokenizes. No Uniswap work is possible until then, so automation is skipped successfully.
        if (projectToken == address(0)) {
            // Only grow the ledger when the hook's actual credit balance backs the prior LP credits, the new
            // amount, AND any outstanding fee-credit liabilities for this project — a lying controller cannot
            // inflate the ledger past what was really delivered.
            uint256 creditBalance =
                IJBTokens(TOKENS).creditBalanceOf({holder: address(this), projectId: context.projectId});
            uint256 required = accumulatedProjectCredits[context.projectId] + context.amount
                + _totalOutstandingFeeCreditClaims[context.projectId];
            if (creditBalance < required) {
                revert JBUniswapV4LPSplitHook_InsufficientBalance({available: creditBalance, required: required});
            }

            accumulatedProjectCredits[context.projectId] += context.amount;
            return;
        }

        // Pull the allocated tokens from the controller via the granted allowance.
        // Use balance delta to handle fee-on-transfer tokens correctly.
        uint256 received;
        if (context.amount > 0) {
            uint256 balanceBefore = IERC20(projectToken).balanceOf(address(this));
            IERC20(projectToken).safeTransferFrom({from: msg.sender, to: address(this), value: context.amount});
            received = IERC20(projectToken).balanceOf(address(this)) - balanceBefore;
        }

        // Accumulate the received project tokens. This is the hook's only sink for reserved-token inflow, both before
        // AND after pool deployment — the hook never burns reserved tokens. Pre-deployment, `deployPool` consumes the
        // accumulation; post-deployment, `addLiquidity` does. Burning is a protocol-layer split-routing decision (route
        // a split to
        // {projectId:0, hook:0, beneficiary:0xdead}), not this hook's job.
        _accumulateTokens({projectId: context.projectId, amount: received});

        // Intake is complete: the allocation is durably represented in the ledger. Everything below is best-effort
        // and must not be able to revert this frame. Below the churn threshold a recycle is not worth the
        // distributor's gas, so a dust distribution keeps accruing instead.
        if (accumulatedProjectTokens[context.projectId] >= _MIN_ADD_ACCUMULATION) {
            _attemptAutomation(context.projectId);
        }
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
    /// @return deployed True once the project's pool was deployed against this terminal token.
    function isPoolDeployed(uint256 projectId, address terminalToken) public view returns (bool deployed) {
        // The pool pairing is recorded once the deployment (pool + first recycle) has succeeded.
        return hasDeployedPool[projectId] && deployedTerminalTokenOf[projectId] == terminalToken;
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

    /// @notice Absolute difference between two ticks, used for the TWAP-deviation comparison.
    /// @param a The first tick.
    /// @param b The second tick.
    /// @return difference The non-negative distance between the two ticks.
    function _absTickDiff(int24 a, int24 b) internal pure returns (int24 difference) {
        // Order the subtraction so the result is always non-negative regardless of which tick is larger.
        return a >= b ? a - b : b - a;
    }

    /// @notice Accept a payout split from one of the project's terminals into the bid's ledger, then best-effort put
    /// it to work.
    /// @dev Core's payout path (`JBPayoutSplitGroupLib.invokeSplitHookWithPartial`, delegatecalled by the terminal)
    /// sends `context.amount` (the net payout) of `context.token`: native ETH as `msg.value`, an ERC-20 as an
    /// allowance to pull. Every rejection below reverts, which makes the terminal return the whole payout to the
    /// project's balance. Payouts are only accepted once the pool is deployed and only in its terminal token, so a
    /// payout can only ever fund that pool's bid. The ledger grows by what was actually received, and automation runs
    /// at any size (no `_MIN_ADD_ACCUMULATION` gate): a payout is terminal-token inventory, not dust project tokens.
    /// @param context The split hook context Core built for the payout.
    function _acceptPayout(JBSplitHookContext calldata context) internal {
        // Core files a token's payout splits under the token's address.
        if (context.groupId != uint256(uint160(context.token))) {
            revert JBUniswapV4LPSplitHook_InvalidSplitGroup({groupId: context.groupId, token: context.token});
        }

        // Only a terminal of the project can pay out its funds.
        if (!IJBDirectory(DIRECTORY).isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})) {
            revert JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal({
                projectId: context.projectId, sender: msg.sender, controller: _controllerOf(context.projectId)
            });
        }

        // Terminal tokens can only fund the deployed pool's bid: before deployment there is no bid to fund, and any
        // other token has no pool here.
        if (!hasDeployedPool[context.projectId]) {
            revert JBUniswapV4LPSplitHook_InvalidStageForAction({
                projectId: context.projectId, terminalToken: context.token, tokenId: 0
            });
        }
        if (context.token != deployedTerminalTokenOf[context.projectId]) {
            revert JBUniswapV4LPSplitHook_InvalidTerminalToken({
                projectId: context.projectId, terminalToken: context.token
            });
        }

        uint256 received;
        if (_isNativeToken(context.token)) {
            // Native ETH arrives as exactly the payout's value.
            if (msg.value != context.amount) revert JBUniswapV4LPSplitHook_UnexpectedMsgValue({value: msg.value});
            received = msg.value;
        } else {
            if (msg.value != 0) revert JBUniswapV4LPSplitHook_UnexpectedMsgValue({value: msg.value});
            if (context.amount > 0) {
                // Pull the whole offered allowance; the balance delta handles fee-on-transfer tokens.
                uint256 balanceBefore = IERC20(context.token).balanceOf(address(this));
                IERC20(context.token).safeTransferFrom({from: msg.sender, to: address(this), value: context.amount});
                received = IERC20(context.token).balanceOf(address(this)) - balanceBefore;
            }
        }

        accumulatedTerminalTokens[context.projectId][context.token] += received;

        emit PayoutAccepted({
            projectId: context.projectId, terminalToken: context.token, amount: received, caller: msg.sender
        });

        // Intake is complete; the attempt below cannot revert this frame.
        _attemptAutomation(context.projectId);
    }

    /// @notice Record incoming project tokens in the accumulation ledger (the hook's single inflow sink).
    /// @param projectId The ID of the project to credit.
    /// @param amount The project-token amount to add to the ledger.
    function _accumulateTokens(uint256 projectId, uint256 amount) internal {
        // `+=`: accumulation is additive across every reserved-token distribution, pre- and post-deployment.
        accumulatedProjectTokens[projectId] += amount;
    }

    /// @notice Recycle the project's positions on its deployed pool, folding in the accumulated reserved tokens. Shared
    /// executor behind the permissionless `addLiquidity` entry point and the best-effort inline automation self-call.
    /// @param projectId The ID of the project whose positions should be recycled.
    /// @param terminalToken The terminal token paired with the project token in the deployed pool.
    function _addLiquidity(uint256 projectId, address terminalToken) internal {
        // Require the deployed pool for this exact pairing — `addLiquidity` only recycles an existing pool.
        if (!isPoolDeployed({projectId: projectId, terminalToken: terminalToken})) {
            revert JBUniswapV4LPSplitHook_InvalidStageForAction({
                projectId: projectId, terminalToken: terminalToken, tokenId: 0
            });
        }

        // Fetch the controller and current ruleset once; both feed the corridor math.
        address controller = _controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        // Record the ruleset weight as a processing-era reference on the first successful attempt, now that intake
        // no longer reads rulesets.
        if (initialWeightOf[projectId] == 0) initialWeightOf[projectId] = ruleset.weight;

        // Recycling is allowed at any time, with or without new tokens, so idle ledgered inventory and a moved corridor
        // are always picked up. The caller pays the gas; the TWAP guard below bounds the price it can recycle at.
        uint256 accumulated = accumulatedProjectTokens[projectId];

        // Resolve the project's ERC-20 and the pool key once for the TWAP guard and the recycle below.
        address projectToken = _tokenOf(projectId);
        PoolKey memory key = poolKeysOf[projectId][terminalToken];

        // Verify the actual ERC-20 balance (minus outstanding fee token claims) covers the accumulated total before
        // deploying it. Guards against accounting drift from custom controllers; checked here — not during intake —
        // so a pre-existing inconsistency cannot cause a newly delivered allocation to be burned by Core.
        uint256 spendable = IERC20(projectToken).balanceOf(address(this)) - _unavailableFeeTokenBalance(projectToken);
        if (spendable < accumulated) {
            revert JBUniswapV4LPSplitHook_InsufficientBalance({available: spendable, required: accumulated});
        }

        // Reject the recycle while the pool's spot price is off the oracle TWAP. The burns and re-mints price against
        // the live spot, so a sandwiched/JIT-skewed spot would re-center both positions around a manipulated price.
        int24 twapTick = _requireSpotNearTwap({projectId: projectId, terminalToken: terminalToken, key: key});

        _recycle({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            controller: controller,
            ruleset: ruleset,
            anchorTick: twapTick
        });

        emit LiquidityAdded({
            projectId: projectId,
            terminalToken: terminalToken,
            askTokenId: askTokenIdOf[projectId][terminalToken],
            bidTokenId: bidTokenIdOf[projectId][terminalToken],
            caller: msg.sender
        });
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

    /// @notice Best-effort attempt to convert a project's freshly accepted inventory into liquidity inline: deploy
    /// the pool if none exists yet, otherwise grow the deployed pool's position. Never reverts — the attempt runs
    /// behind a gas-bounded external self-call so any failure rolls back the attempt's state while the caller's
    /// accepted inventory remains intact and retryable through the permissionless `deployPool`/`addLiquidity`.
    /// @param projectId The ID of the project to attempt automation for.
    function _attemptAutomation(uint256 projectId) internal {
        // Post-deployment automation needs the recorded pool pairing; without it there is nothing to grow safely.
        if (hasDeployedPool[projectId] && deployedTerminalTokenOf[projectId] == address(0)) return;

        // Skip when the remaining gas cannot cover a meaningful attempt plus the reserve this frame needs to finish
        // and return to the Controller. The permissionless retries are not bound by this floor.
        if (gasleft() < _AUTOMATION_GAS_BUDGET + _AUTOMATION_GAS_RESERVE) return;

        // The external self-call is the rollback boundary: a revert inside the attempt rolls back the attempt's
        // state changes while this frame's accepted inventory stays intact. Only the error selector is captured, so
        // a revert-data bomb downstream cannot blow up this frame's memory.
        (bool success, bytes4 reasonSelector) = _boundedSelfCall({
            data: abi.encodeCall(this.executeAutomationFor, (projectId)), gasLimit: _AUTOMATION_GAS_BUDGET
        });

        if (!success) {
            emit LiquidityAutomationFailed({projectId: projectId, reasonSelector: reasonSelector, caller: msg.sender});
        }
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

        // Forgive when there is nothing to cut or no fee terminal accepts `feeToken`: the whole amount is the
        // remainder.
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
        try this.sendToTerminal({
            terminal: feeTerminal, projectId: feeProjectId, token: feeToken, amount: cut, shouldPay: true
        }) returns (
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
            // Forgive the cut: fully roll back the pre-incremented reserve and return the whole amount as the
            // remainder.
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

    /// @notice Call this contract itself with a bounded gas budget, capturing at most the revert selector.
    /// @dev Mirrors the Router Terminal Gateway's `_boundedCall`: the returndata is never copied beyond four bytes,
    /// so a revert-data bomb from a downstream dependency cannot force unbounded memory expansion in this frame.
    /// @param data The calldata for the self-call.
    /// @param gasLimit The gas budget to forward (EIP-150 may forward less).
    /// @return success Whether the self-call succeeded.
    /// @return reasonSelector The first four bytes of the revert data (zero when none was returned).
    function _boundedSelfCall(
        bytes memory data,
        uint256 gasLimit
    )
        internal
        returns (bool success, bytes4 reasonSelector)
    {
        assembly ("memory-safe") {
            success := call(gasLimit, address(), 0, add(data, 0x20), mload(data), 0, 0)
            if iszero(success) {
                if gt(returndatasize(), 3) {
                    // Scratch space: zero the word, lay the selector into its top bytes, and read it back.
                    mstore(0, 0)
                    returndatacopy(0, 0, 4)
                    reasonSelector := mload(0)
                }
            }
        }
    }

    /// @notice Burn an existing LP position via `BURN_POSITION` + `TAKE_PAIR` and recover its principal (plus any
    /// accrued fees the burn collects). The recovered tokens are credited to the project's ledgers by the caller.
    /// @dev Called only by `_retirePosition`, which derives the min amounts from a live-price principal read
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

    /// @notice Burn `count` of this hook's project ERC-20 through the project's controller, lowering the project's
    /// supply. Callable only via this contract's own best-effort `_routeCollectedFees` so its revert can be caught and
    /// the remainder kept in the ask ledger instead.
    /// @dev The hook burns its own tokens (`holder == msg.sender`), so the controller needs no permission grant. Core
    /// burns a holder's credits BEFORE its ERC-20, so the hook first claims its own credits of this project into the
    /// ERC-20 and adds them to the ask ledger (`_claimHookCreditsFor`, the same step a recycle runs); credits sent to
    /// the hook from outside therefore cannot divert the burn. Fee-credit claims the hook owes (only when this project
    /// is a fee project with claims from before it tokenized) stay credits, and the burn would consume them first, so
    /// the burn is accepted only when exactly `count` ERC-20 left the hook and its credit balance is unchanged;
    /// anything else reverts (undoing the claim) and is forgiven by the caller.
    /// @dev This target is intentionally NOT `nonReentrant`: it is reached through an internal `this.` self-call while
    /// the surrounding entry point still holds the reentrancy lock, so guarding it would self-revert. A genuine
    /// reentrant call into any guarded entry point during the burn is still rejected by that outer lock, and the
    /// `msg.sender == address(this)` gate blocks any direct external call.
    /// @param projectId The ID of the project whose tokens to burn.
    /// @param projectToken The project's ERC-20, whose hook balance must fall by exactly `count`.
    /// @param count The number of project tokens to burn.
    function burnFeeRemainder(uint256 projectId, address projectToken, uint256 count) external {
        if (msg.sender != address(this)) revert JBUniswapV4LPSplitHook_Unauthorized();

        // A missing controller (no code) reverts the call, which the caller forgives like any other failure.
        address controller = _controllerOf(projectId);

        // Clear the hook's own credits out of the way of Core's credits-first burn.
        accumulatedProjectTokens[projectId] += _claimHookCreditsFor({projectId: projectId, controller: controller});

        uint256 creditsBefore = IJBTokens(TOKENS).creditBalanceOf({holder: address(this), projectId: projectId});
        uint256 balanceBefore = IERC20(projectToken).balanceOf(address(this));

        IJBController(controller).burnTokensOf({
            holder: address(this), projectId: projectId, tokenCount: count, memo: ""
        });

        // A balance that rose instead of falling underflows and reverts, which is forgiven the same way.
        if (
            IJBTokens(TOKENS).creditBalanceOf({holder: address(this), projectId: projectId}) != creditsBefore
                || balanceBefore - IERC20(projectToken).balanceOf(address(this)) != count
        ) revert JBUniswapV4LPSplitHook_FeeBurnNotExact({projectId: projectId, count: count});
    }

    /// @notice The contract-derived burn slippage floor for `tokenId`: `_BURN_SLIPPAGE_BPS`/`BPS` of the position's
    /// principal computed from its on-chain liquidity and range at the live pool price. Returned in (currency0,
    /// currency1) order to match `BURN_POSITION`. Callers never supply burn minimums.
    /// @param tokenId The position NFT token ID to be burned.
    /// @param key The pool key identifying the Uniswap V4 pool.
    /// @return min0 The minimum currency0 the burn must return.
    /// @return min1 The minimum currency1 the burn must return.
    function _burnSlippageFloor(uint256 tokenId, PoolKey memory key)
        internal
        view
        returns (uint128 min0, uint128 min1)
    {
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        if (liquidity == 0) return (0, 0);

        (, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        (uint256 amount0, uint256 amount1) = _positionPrincipal({
            sqrtPriceX96: _getSqrtPriceX96(key),
            tickLower: info.tickLower(),
            tickUpper: info.tickUpper(),
            liquidity: liquidity
        });

        // Position principal is bounded by pooled token balances, so the discounted floor normally fits in uint128;
        // reject the pathological case rather than let a wraparound shrink the floor and accept a bad unwind.
        min0 = _toUint128((amount0 * _BURN_SLIPPAGE_BPS) / BPS);
        min1 = _toUint128((amount1 * _BURN_SLIPPAGE_BPS) / BPS);
    }

    /// @notice Carry leftover tokens after an LP add forward. Project-token leftovers return to the accumulation ledger
    /// and terminal-token leftovers return to the terminal ledger, both becoming this project's liquidity on the next
    /// mint.
    /// @dev The caller zeroed both ledgers and snapshotted the hook's balances before minting. Here, consumed = what
    /// left the hook (balance before minus balance after) and leftover = what was intended minus what was consumed;
    /// the leftover goes back on the ledger. Measuring from balances rather than from the mint math means a mint that
    /// took less (the per-tick cap, rounding, a skipped side) or V4 SWEEP dust can never mis-account. The `+=` adds to,
    /// rather than overwrites, anything already on the ledgers.
    /// @param projectId The ID of the project whose ledgers receive the leftovers.
    /// @param projectToken The project's ERC-20.
    /// @param terminalToken The terminal token paired in the pool.
    /// @param intendedProjectAmount The project-token amount the mints were offered.
    /// @param intendedTerminalAmount The terminal-token amount the mints were offered.
    /// @param projBalBefore The hook's project-token balance before the mints.
    /// @param termBalBefore The hook's terminal-token balance before the mints.
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

        // The mints cap each settle at the offered amount, so losing more than that means the token charged the sender
        // on top of the transfer. That extra would come out of another project's balance on a shared clone: revert.
        if (projConsumed > intendedProjectAmount) {
            revert JBUniswapV4LPSplitHook_TransferNotExact({token: projectToken, amount: intendedProjectAmount});
        }
        if (termConsumed > intendedTerminalAmount) {
            revert JBUniswapV4LPSplitHook_TransferNotExact({token: terminalToken, amount: intendedTerminalAmount});
        }

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
        try IJBController(_controllerOf(feeProjectId)).transferCreditsFrom({
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
        // A token that charges the sender on top of the transfer would take the extra from balances backing other
        // claims or ledgers on this clone: measure the debit and revert, restoring the claim.
        uint256 balanceBefore = IERC20(feeProjectToken).balanceOf(address(this));
        IERC20(feeProjectToken).safeTransfer({to: beneficiary, value: tokenAmount});
        if (balanceBefore - IERC20(feeProjectToken).balanceOf(address(this)) > tokenAmount) {
            revert JBUniswapV4LPSplitHook_TransferNotExact({token: feeProjectToken, amount: tokenAmount});
        }
    }

    /// @notice Converts every credit this hook holds for a project, except the fee-credit claims it owes, into the
    /// registered ERC-20. The caller adds the returned count to the project's ask ledger.
    /// @dev The claimed credits are the ones accepted through `processSplitWith` (`accumulatedProjectCredits`) plus
    /// any credits sent to the hook from outside, which become the project's LP inventory like a token donation would.
    /// Credits owed to fee-claim holders (`_totalOutstandingFeeCreditClaims`, nonzero only when this project is a fee
    /// project) are never claimed. Only called once every fee cut has reconciled its reserves, so no fee proceeds are
    /// in flight. The credit ledger is cleared before the external claim; a revert restores it atomically with the
    /// rest of the frame.
    /// @param projectId The Juicebox project whose credits are being normalized.
    /// @param controller The project's controller.
    /// @return creditCount The ERC-20 project tokens this hook received for its claimed credits.
    function _claimHookCreditsFor(uint256 projectId, address controller) internal returns (uint256 creditCount) {
        uint256 held = IJBTokens(TOKENS).creditBalanceOf({holder: address(this), projectId: projectId});
        uint256 owed = _totalOutstandingFeeCreditClaims[projectId];
        creditCount = held > owed ? held - owed : 0;

        accumulatedProjectCredits[projectId] = 0;
        if (creditCount == 0) return 0;

        // The hook is the holder, so no external permission is needed for this claim. The controller is the
        // project's own and could deliver the ERC-20 elsewhere, so the ledger takes only what this hook received.
        IERC20 projectToken = IERC20(_tokenOf(projectId));
        uint256 balanceBefore = projectToken.balanceOf(address(this));
        IJBController(controller).claimTokensFor({
            holder: address(this), projectId: projectId, tokenCount: creditCount, beneficiary: address(this)
        });
        return projectToken.balanceOf(address(this)) - balanceBefore;
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

    /// @notice Collect one position's accrued Uniswap LP trading fees, then route them.
    /// @dev Fees are measured as the balance delta across the collection, then handed to `_routeCollectedFees`: a
    /// best-effort fee-project cut on each side, then the terminal-token remainder to the project's balance and the
    /// project-token remainder burned (each falling back to its ledger on failure).
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
        // An empty corridor (a zero seed) has no price that respects both bounds, so there is no pool to seed or
        // accept.
        if (sqrtPriceX96 == 0) {
            revert JBUniswapV4LPSplitHook_EmptyCorridor({projectId: projectId, terminalToken: terminalToken});
        }
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

            // Reject an existing price at or beyond the CASH-OUT FLOOR side of the band, where an LP sited at the
            // extreme would sell the project's tokens into a manipulated price. The ISSUANCE-CEILING side is accepted:
            // a price at or past the issuance price is where the corridor naturally ends up once the asks have filled,
            // and the position the hook then mints is bid-only and capped at the ceiling, so it can never be sited
            // outside the economic band. Rejecting that side instead would permanently strand the pair — with no
            // liquidity in the pool, nothing can trade the price back into the band, so the rejection never resolves.
            // Ordering-aware: the issuance ceiling is the band's UPPER bound when the project is token0 and its LOWER
            // bound when it is token1.
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);
            bool outsideFloor = projectCurrency == currency0
                ? existingSqrtPriceX96 <= sqrtPriceLower
                : existingSqrtPriceX96 >= sqrtPriceUpper;
            if (outsideFloor) {
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

    /// @notice Create the Uniswap V4 pool and mint the initial LP position from the project's accumulated reserved
    /// tokens (and any accounted credits, normalized into the project's ERC-20). Shared executor behind the
    /// permissionless `deployPool` entry point and the best-effort inline automation self-call.
    /// @param projectId The ID of the project whose accumulated tokens should be deployed as LP.
    function _deployPool(uint256 projectId) internal {
        // `deployPool` is fully permissionless: anyone may seed the pool. The only gate is the economic one applied
        // inside the recycle: the ask never sells below the cash-out floor and never past the issuance ceiling, so a
        // spot that leaves no ask range keeps the accumulation in its ledger (and reverts if nothing else can mint).
        address controller = _controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        // Record the ruleset weight as a processing-era reference on the first successful attempt, now that intake
        // no longer reads rulesets.
        if (initialWeightOf[projectId] == 0) initialWeightOf[projectId] = ruleset.weight;

        // Auto-select the terminal token with the highest ETH-denominated value.
        address terminalToken = JBUniswapV4LPSplitHookMath.findHighestValueTerminalTokenOf({
            directory: IJBDirectory(DIRECTORY), projectId: projectId, controller: controller
        });

        if (hasDeployedPool[projectId]) {
            if (deployedTerminalTokenOf[projectId] == terminalToken) {
                revert JBUniswapV4LPSplitHook_PoolAlreadyDeployed({
                    projectId: projectId, terminalToken: terminalToken, tokenId: askTokenIdOf[projectId][terminalToken]
                });
            }
            revert JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported({
                projectId: projectId, terminalToken: terminalToken
            });
        }

        address projectToken = _tokenOf(projectId);

        // Credits cannot be paired as LP — deployment waits until the project has an ERC-20 to normalize them into.
        if (projectToken == address(0)) {
            revert JBUniswapV4LPSplitHook_InvalidProjectId({
                projectId: projectId, controller: controller, projectToken: projectToken
            });
        }

        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];

        // Accounted credits count as deployable inventory: `_recycle` normalizes them into the ERC-20
        // via `_claimHookCreditsFor` before sizing the mint.
        if (projectTokenBalance == 0 && accumulatedProjectCredits[projectId] == 0) {
            revert JBUniswapV4LPSplitHook_NoTokensAccumulated({projectId: projectId});
        }

        // Verify the actual ERC-20 balance (minus outstanding fee token claims) covers the accumulated total before
        // deploying it. Guards against accounting drift from custom controllers; checked here — not during intake —
        // so a pre-existing inconsistency cannot cause a newly delivered allocation to be burned by Core.
        uint256 spendable = IERC20(projectToken).balanceOf(address(this)) - _unavailableFeeTokenBalance(projectToken);
        if (spendable < projectTokenBalance) {
            revert JBUniswapV4LPSplitHook_InsufficientBalance({available: spendable, required: projectTokenBalance});
        }

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

        // Remember the pool's terminal-token pairing so post-deployment inline automation can resolve the position
        // without re-running the auto-selection. Recorded only once the deployment has succeeded.
        deployedTerminalTokenOf[projectId] = terminalToken;

        emit ProjectDeployed({
            projectId: projectId,
            terminalToken: terminalToken,
            poolId: PoolId.unwrap(poolKeysOf[projectId][terminalToken].toId()),
            caller: msg.sender
        });
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
        // the same transaction has no TWAP history, so the guard is skipped (it would revert on cold start) and its own
        // initial price anchors the ranges: nobody else can have moved it yet.
        int24 anchorTick = wasAlreadyInitialized
            ? _requireSpotNearTwap({projectId: projectId, terminalToken: terminalToken, key: key})
            : TickMath.getTickAtSqrtPrice(_getSqrtPriceX96(key));

        // Mint the first ask (and a bid, if the hook already holds terminal tokens for this project).
        _recycle({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            controller: controller,
            ruleset: ruleset,
            anchorTick: anchorTick
        });
    }

    /// @notice Execute an inline automation attempt for a project: deploy the pool if none exists yet, otherwise add
    /// the accumulated inventory to the deployed pool's position. Callable only via this contract's own best-effort
    /// `_attemptAutomation` so a revert anywhere in the flow can be caught and forgiven while the parent frame's
    /// accepted inventory stays intact.
    /// @dev This target is intentionally NOT `nonReentrant`: it is reached through an internal `this.` self-call
    /// while `processSplitWith` still holds the reentrancy lock, so guarding it would self-revert. A genuine
    /// reentrant call into any guarded entry point during the attempt is still rejected by that outer lock, and the
    /// `msg.sender == address(this)` gate blocks any direct external call.
    /// @param projectId The ID of the project to attempt automation for.
    function executeAutomationFor(uint256 projectId) external {
        if (msg.sender != address(this)) revert JBUniswapV4LPSplitHook_Unauthorized();

        if (hasDeployedPool[projectId]) {
            _addLiquidity({projectId: projectId, terminalToken: deployedTerminalTokenOf[projectId]});
        } else {
            _deployPool(projectId);
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

    /// @notice Mint a single-sided position of `amount0` OR `amount1` across `[tickLower, tickUpper]`, returning its
    /// token ID, or zero (minting nothing) when the range is empty or the amount yields no liquidity.
    /// @dev The caller places the range entirely on the side of the spot where only the supplied currency is needed.
    /// @param key The pool key identifying the Uniswap V4 pool.
    /// @param tickLower The lower tick of the range.
    /// @param tickUpper The upper tick of the range.
    /// @param amount0 The currency0 amount to deploy (zero when deploying currency1).
    /// @param amount1 The currency1 amount to deploy (zero when deploying currency0).
    /// @return tokenId The minted position's token ID, or zero if nothing was minted.
    function _mintSingleSided(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    )
        internal
        returns (uint256 tokenId)
    {
        // An empty or inverted range (the spot or anchor sits past this side's corridor end) or nothing to deploy:
        // skip.
        if (tickLower >= tickUpper || (amount0 == 0 && amount1 == 0)) return 0;

        // The liquidity the amount buys over this range, capped at the pool's per-tick capacity: what does not fit
        // stays in the ledgers through `_carryLeftovers`.
        uint128 liquidity = JBUniswapV4LPSplitHookMath.cappedSingleSidedLiquidity({
            poolManager: poolManager,
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0: amount0,
            amount1: amount1
        });
        // Too little to mint one unit of liquidity, or no room left at a bound: skip rather than mint an empty
        // position.
        if (liquidity == 0) return 0;

        // The full amount is offered as the settle cap; the PositionManager pulls only what `liquidity` needs.
        _mintPosition({
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            amount0: amount0,
            amount1: amount1
        });

        // MINT_POSITION incremented nextTokenId, so the fresh mint is the one before it.
        tokenId = _nextTokenId() - 1;
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

    /// @notice Burn the project's ask and bid, then re-mint both single-sided around the live spot from everything the
    /// hook holds for the project: every project token (new reserved tokens, recovered principal, claimed credits, fee
    /// remainders whose burn failed) goes into the ask and every terminal token into the bid. This is the single
    /// lifecycle primitive behind deploy and add.
    /// @dev The steps, in order:
    ///
    /// 1. Retire both live positions: route their fees, burn them, and credit the recovered principal to the ledgers.
    /// 2. Claim any hook-held credits into the ERC-20 so they can be minted.
    /// 3. Price the corridor. This runs after step 1 on purpose, so the floor reflects what fee routing just did.
    /// 4. If the corridor is empty, stop with everything held in the ledgers.
    /// 5. Pick the ranges from the spot and the anchor, clear both ledgers, and mint each side single-sided.
    /// 6. Return whatever the mints did not consume to the ledgers (`_carryLeftovers`).
    ///
    /// Token0 always rests above the spot and token1 below it. With `spotFloor` and `spotCeil` the aligned ticks
    /// at or below and at or above the spot, `[.., spotFloor]` holds only token1 and `[spotCeil, ..]` only token0, so
    /// both mints are single-sided; the spot sits in the gap between them, or on their shared bound when it is exactly
    /// on an aligned tick. Both ranges also stay on the far side of `anchorTick` (the validated TWAP): a spot pushed
    /// inside the TWAP band cannot pull the ask below the TWAP or the bid above it, so a caller who buys from the ask
    /// and sells into the bid across repeated same-block recycles always does so at a loss. Both ranges stay inside
    /// the corridor: the ask never sells below the cash-out floor and the bid never buys above the issuance ceiling. A
    /// side whose range is empty (spot past the ceiling for the ask, past the floor for the bid) stays in its ledger
    /// for a later recycle; if neither side can be minted the whole recycle reverts and the live positions are kept.
    /// @param projectId The ID of the project.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @param anchorTick The validated TWAP tick (or, for a pool this hook just initialized, its initial tick).
    function _recycle(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        address controller,
        JBRuleset memory ruleset,
        int24 anchorTick
    )
        internal
    {
        PoolKey memory key = poolKeysOf[projectId][terminalToken];
        bool hadPositions = askTokenIdOf[projectId][terminalToken] != 0 || bidTokenIdOf[projectId][terminalToken] != 0;

        // Retire both live positions; their fees are routed and their principal joins the ledgers.
        _retirePosition({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            tokenId: askTokenIdOf[projectId][terminalToken],
            key: key
        });
        _retirePosition({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            tokenId: bidTokenIdOf[projectId][terminalToken],
            key: key
        });
        delete askTokenIdOf[projectId][terminalToken];
        delete bidTokenIdOf[projectId][terminalToken];

        // Fold hook-held project-token credits into the ERC-20 ledger so they are minted, not stranded.
        accumulatedProjectTokens[projectId] += _claimHookCreditsFor({projectId: projectId, controller: controller});

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

        // An empty corridor leaves no pair of distinct aligned ticks between the cash-out value and the issuance price:
        // any ask would sell below the cash-out value or any bid would buy above the issuance price. Hold: keep
        // everything ledgered until the corridor reopens (a later recycle mints it). Pulling stale positions out of an
        // empty corridor is useful work in itself, so a recycle that retired something succeeds; only a recycle with
        // nothing to retire reverts.
        if (corridorLower == corridorUpper) {
            if (!hadPositions) {
                revert JBUniswapV4LPSplitHook_EmptyCorridor({projectId: projectId, terminalToken: terminalToken});
            }
            return;
        }

        // The live spot, and the aligned tick at or below it. `getTickAtSqrtPrice` rounds down, so the spot price is at
        // or above `spotFloor`'s price.
        uint160 sqrtPriceX96 = _getSqrtPriceX96(key);
        int24 spotTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 spotFloor = JBLPSplitHookHelpers.alignTickToSpacing({tick: spotTick, spacing: TICK_SPACING});

        // The lowest aligned tick at or above the spot: `spotFloor` itself when the spot sits exactly on it.
        // `spotFloor` can sit below `TickMath.MIN_TICK` in the lowest partial spacing, where the spot cannot be on it.
        int24 spotCeil = spotFloor >= TickMath.MIN_TICK && TickMath.getSqrtPriceAtTick(spotFloor) == sqrtPriceX96
            ? spotFloor
            : spotFloor + TICK_SPACING;

        // Keep both ranges on the far side of the anchor as well as the spot. The anchor is the TWAP the caller
        // validated (within `_MAX_TWAP_DEVIATION_TICKS` of the spot). Widening the gap to cover both means a spot
        // nudged away from the TWAP cannot drag either position across it: the token0 range starts at or above both,
        // the
        // token1 range ends at or below both, so the hook's quotes stay anchored to the time-averaged price.
        {
            int24 anchorCeil = JBLPSplitHookHelpers.alignTickToSpacingCeil({tick: anchorTick, spacing: TICK_SPACING});
            int24 anchorFloor = JBLPSplitHookHelpers.alignTickToSpacing({tick: anchorTick, spacing: TICK_SPACING});
            if (anchorCeil > spotCeil) spotCeil = anchorCeil;
            if (anchorFloor < spotFloor) spotFloor = anchorFloor;
        }
        // Everything the hook holds for the project goes out: all project tokens on the ask, all terminal tokens on the
        // bid. Which of the two is token0 decides which side of the spot each one rests on.
        bool projectIsToken0 = projectToken == Currency.unwrap(key.currency0);
        uint256 projectAmount = accumulatedProjectTokens[projectId];
        uint256 terminalAmount = accumulatedTerminalTokens[projectId][terminalToken];

        // CEI: clear both ledgers before the external mints; `_carryLeftovers` returns whatever they do not consume.
        // The balance snapshots let it measure consumption from what actually left the hook, not from mint math.
        accumulatedProjectTokens[projectId] = 0;
        accumulatedTerminalTokens[projectId][terminalToken] = 0;
        uint256 projBalBefore = IERC20(projectToken).balanceOf(address(this));
        uint256 termBalBefore = _getTerminalTokenBalance(terminalToken);

        // Token0 above the spot, clamped up to the corridor's lower bound. For a token0 project this is the ask
        // (selling project tokens as the price rises toward the ceiling); for a token1 project it is the bid.
        uint256 token0PositionId = _mintSingleSided({
            key: key,
            tickLower: spotCeil > corridorLower ? spotCeil : corridorLower,
            tickUpper: corridorUpper,
            amount0: projectIsToken0 ? projectAmount : terminalAmount,
            amount1: 0
        });

        // Token1 below the spot, clamped down to the corridor's upper bound. For a token0 project this is the bid
        // (buying project tokens back as the price falls toward the floor); for a token1 project it is the ask. When
        // the spot sits past a corridor end, the clamp inverts that side's range and `_mintSingleSided` skips it.
        uint256 token1PositionId = _mintSingleSided({
            key: key,
            tickLower: corridorLower,
            tickUpper: spotFloor < corridorUpper ? spotFloor : corridorUpper,
            amount0: 0,
            amount1: projectIsToken0 ? terminalAmount : projectAmount
        });

        // Minting neither side means nothing changed hands. Revert (rolling back the retires too) so the live positions
        // stay up rather than being pulled with nothing to replace them.
        if (token0PositionId == 0 && token1PositionId == 0) {
            revert JBUniswapV4LPSplitHook_NoDeployableLiquidityAtSpot({
                spotTick: spotTick,
                ceilingTick: projectIsToken0 ? corridorUpper : corridorLower,
                projectAmount: projectAmount,
                terminalAmount: terminalAmount
            });
        }

        // Record the new positions by role. A side that minted nothing records 0 (no live position).
        askTokenIdOf[projectId][terminalToken] = projectIsToken0 ? token0PositionId : token1PositionId;
        bidTokenIdOf[projectId][terminalToken] = projectIsToken0 ? token1PositionId : token0PositionId;

        // Whatever a skipped side, the per-tick liquidity cap, or mint rounding left unconsumed returns to its ledger.
        _carryLeftovers({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            intendedProjectAmount: projectAmount,
            intendedTerminalAmount: terminalAmount,
            projBalBefore: projBalBefore,
            termBalBefore: termBalBefore
        });
    }

    /// @notice Revert if the pool's spot price has deviated from the oracle TWAP by more than
    /// `_MAX_TWAP_DEVIATION_TICKS`, or if the TWAP cannot be read. Prevents a JIT/sandwich attacker from skewing the
    /// add ratio by moving the pool price right before the add.
    /// @dev The TWAP is the arithmetic mean tick over the last `_TWAP_WINDOW` from the oracle hook's cumulative tick
    /// counter: `(cumulative now - cumulative then) / window`. Moving it takes holding the spot away for much of the
    /// window, which a single-transaction sandwich cannot do.
    /// @param projectId The ID of the project (for the revert data).
    /// @param terminalToken The pool's terminal token (for the revert data).
    /// @param key The pool key to read the oracle and spot for.
    /// @return twapTick The validated TWAP tick, which also anchors the recycle's ranges.
    function _requireSpotNearTwap(
        uint256 projectId,
        address terminalToken,
        PoolKey memory key
    )
        internal
        view
        returns (int24 twapTick)
    {
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
        twapTick = int24(tickCumulativesDelta / window);
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % window != 0)) twapTick--;

        int24 spotTick = TickMath.getTickAtSqrtPrice(_getSqrtPriceX96(key));
        if (_absTickDiff({a: spotTick, b: twapTick}) > _MAX_TWAP_DEVIATION_TICKS) {
            revert JBUniswapV4LPSplitHook_PriceDeviationTooHigh({
                spotTick: spotTick, twapTick: twapTick, maxDeviationTicks: _MAX_TWAP_DEVIATION_TICKS
            });
        }
    }

    /// @notice Collect and route a position's fees, then burn it and credit its recovered principal to the project's
    /// ledgers. No-op for a zero token ID.
    /// @dev Fees are routed first so the fee-project cut applies to trading fees only, never to principal.
    /// @param projectId The ID of the project that owns the position.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param tokenId The position NFT token ID to retire.
    /// @param key The pool key identifying the Uniswap V4 pool.
    function _retirePosition(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 tokenId,
        PoolKey memory key
    )
        internal
    {
        if (tokenId == 0) return;

        _collectAndRouteFees({
            projectId: projectId, projectToken: projectToken, terminalToken: terminalToken, tokenId: tokenId, key: key
        });

        (uint128 min0, uint128 min1) = _burnSlippageFloor({tokenId: tokenId, key: key});
        uint256 projBalBefore = IERC20(projectToken).balanceOf(address(this));
        uint256 termBalBefore = _getTerminalTokenBalance(terminalToken);

        _burnExistingPosition({tokenId: tokenId, key: key, decreaseAmount0Min: min0, decreaseAmount1Min: min1});

        accumulatedProjectTokens[projectId] += IERC20(projectToken).balanceOf(address(this)) - projBalBefore;
        accumulatedTerminalTokens[projectId][terminalToken] += _getTerminalTokenBalance(terminalToken) - termBalBefore;
    }

    /// @notice Split collected LP fees into their terminal-token and project-token sides, take a best-effort
    /// fee-project cut on EACH side, and route every non-cut token to the originating project so it raises the
    /// project's cash-out floor: the terminal-token remainder is added to the project's balance in its primary terminal
    /// for that token (more surplus), and the project-token remainder is burned (less supply).
    /// @dev Neither route may block the collection. Each runs behind a self-call (`sendToTerminal`,
    /// `burnFeeRemainder`) whose revert is caught, and a forgiven side is carried into its ledger instead:
    /// `accumulatedTerminalTokens` (the bid) or `accumulatedProjectTokens` (the ask). The remainder is in no ledger
    /// while the external call runs, and every entry point that could spend hook balances holds the reentrancy lock,
    /// so a reentrant call can neither spend it nor double-count it. On success it has left the hook; on failure the
    /// self-call's revert undoes any approval and transfer, so the ledger credit matches tokens the hook still holds.
    /// @param projectId The ID of the project whose fees are being routed.
    /// @param projectToken The project's ERC-20.
    /// @param terminalToken The terminal token paired in the pool.
    /// @param amount0 The collected currency0 fees.
    /// @param amount1 The collected currency1 fees.
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

        // Project-token side: take the fee-project cut, then burn the remainder. Fewer tokens against the same surplus
        // raises every remaining token's cash-out value. A burn that fails is forgiven: the remainder joins the ask.
        if (projectFee > 0) {
            uint256 remainder =
                _attemptFeeProjectCut({projectId: projectId, feeToken: projectToken, amount: projectFee});
            if (remainder > 0) {
                try this.burnFeeRemainder({projectId: projectId, projectToken: projectToken, count: remainder}) {}
                catch {
                    accumulatedProjectTokens[projectId] += remainder;
                }
            }
        }

        // Terminal-token side: take the fee-project cut, then add the remainder to the project's balance in its
        // primary terminal for the token. More surplus against the same supply raises the cash-out value. A missing
        // terminal or a failed add is forgiven: the remainder joins the bid.
        if (terminalFee > 0) {
            uint256 remainder =
                _attemptFeeProjectCut({projectId: projectId, feeToken: terminalToken, amount: terminalFee});
            if (remainder > 0) {
                try this.sendToTerminal({
                    terminal: _primaryTerminalOf({projectId: projectId, token: terminalToken}),
                    projectId: projectId,
                    token: terminalToken,
                    amount: remainder,
                    shouldPay: false
                }) {}
                catch {
                    accumulatedTerminalTokens[projectId][terminalToken] += remainder;
                }
            }
        }
    }

    /// @notice Send `amount` of `token` to `terminal` for `projectId`: `pay` it (the fee-project cut, minting
    /// fee-project tokens to this hook) or `addToBalanceOf` it (an LP-fee remainder returned to the project's own
    /// treasury). Callable only via this contract's own best-effort self-calls so its revert (from the terminal or the
    /// ERC-20 allowance-consumption check) can be caught and forgiven.
    /// @dev This target is intentionally NOT `nonReentrant`: it is reached through an internal `this.` self-call while
    /// the surrounding entry point still holds the reentrancy lock, so guarding it would self-revert. A genuine
    /// reentrant call into any guarded entry point during the terminal call is still rejected by that outer lock, and
    /// the `msg.sender == address(this)` gate blocks any direct external call.
    /// @param terminal The terminal to send to. A terminal with no code reverts the call.
    /// @param projectId The project to pay or add to the balance of.
    /// @param token The token to send (native sentinel or ERC-20).
    /// @param amount The amount to send.
    /// @param shouldPay Whether to `pay` (minting project tokens to this hook) rather than `addToBalanceOf`.
    /// @return beneficiaryTokenCount The token/credit count the terminal reports minting to this hook (0 when adding to
    /// balance).
    function sendToTerminal(
        address terminal,
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldPay
    )
        external
        returns (uint256 beneficiaryTokenCount)
    {
        if (msg.sender != address(this)) revert JBUniswapV4LPSplitHook_Unauthorized();

        // Native ETH is forwarded as value; ERC-20 is pulled by the terminal via an exact-use approval that must be
        // fully consumed (a leftover allowance is live spend authority and reverts — caught upstream as a forgive).
        bool isNative = _isNativeToken(token);
        uint256 value = isNative ? amount : 0;
        uint256 balanceBefore = _getTerminalTokenBalance(token);
        if (!isNative) IERC20(token).forceApprove({spender: terminal, value: amount});

        if (shouldPay) {
            beneficiaryTokenCount = IJBMultiTerminal(terminal).pay{value: value}({
                projectId: projectId,
                token: token,
                amount: amount,
                beneficiary: address(this),
                minReturnedTokens: 0,
                memo: "LP Fee",
                metadata: ""
            });
        } else {
            IJBMultiTerminal(terminal).addToBalanceOf{value: value}({
                projectId: projectId, token: token, amount: amount, shouldReturnHeldFees: false, memo: "", metadata: ""
            });
        }

        if (!isNative) _requireTemporaryAllowanceConsumed({token: token, spender: terminal});

        // A token that charges the sender on top of the transfer would debit more than `amount` and underback the
        // other ledgers; revert so the caller's catch keeps the whole amount ledgered instead.
        uint256 balanceAfter = _getTerminalTokenBalance(token);
        if (balanceBefore > balanceAfter && balanceBefore - balanceAfter > amount) {
            revert JBUniswapV4LPSplitHook_TransferNotExact({token: token, amount: amount});
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
