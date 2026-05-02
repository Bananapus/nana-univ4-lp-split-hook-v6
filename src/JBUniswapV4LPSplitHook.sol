// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";

import {IJBUniswapV4LPSplitHook} from "./interfaces/IJBUniswapV4LPSplitHook.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/**
 * @title JBUniswapV4LPSplitHook
 * @notice JuiceboxV4 IJBSplitHook contract that manages a two-stage deployment process:
 *
 * Before pool deployment:
 * - Accumulate project tokens received via reserved token splits
 * - Pool deployment is triggered manually by the project owner or authorized operator
 *
 * After pool deployment:
 * - Burn any newly received project tokens
 * - Route LP fees back to the project (with configurable fee split)
 * - Support liquidity rebalancing as rates change
 *
 * @dev This contract is the creator of the projectToken/terminalToken Uniswap V4 pool.
 * @dev Any tokens held by the contract can be added to a Uniswap V4 LP position.
 * @dev For any given Uniswap V4 pool, the contract will control a single LP position.
 * @dev Pool deployment requires SET_BUYBACK_POOL permission from the project owner.
 */
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
    error JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject();
    error JBUniswapV4LPSplitHook_InsufficientBalance();
    error JBUniswapV4LPSplitHook_InsufficientLiquidity();
    error JBUniswapV4LPSplitHook_InvalidFeePercent();
    error JBUniswapV4LPSplitHook_InvalidProjectId();
    error JBUniswapV4LPSplitHook_InvalidStageForAction();
    error JBUniswapV4LPSplitHook_InvalidTerminalToken();
    error JBUniswapV4LPSplitHook_InvalidTickBounds();
    error JBUniswapV4LPSplitHook_NoTerminalTokenFound();
    error JBUniswapV4LPSplitHook_NoTokensAccumulated();
    error JBUniswapV4LPSplitHook_NotHookSpecifiedInContext();
    error JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported();
    error JBUniswapV4LPSplitHook_Permit2AmountOverflow();
    error JBUniswapV4LPSplitHook_PoolAlreadyDeployed();
    error JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal();
    error JBUniswapV4LPSplitHook_TerminalNotFound(uint256 projectId, address token);
    error JBUniswapV4LPSplitHook_TerminalTokensNotAllowed();
    error JBUniswapV4LPSplitHook_UnauthorizedCaller();
    error JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed(address token, address spender, uint256 allowance);
    error JBUniswapV4LPSplitHook_UnclaimedFeeTokenChanged(address previousToken, address nextToken);
    error JBUniswapV4LPSplitHook_ZeroAddressNotAllowed();
    error JBUniswapV4LPSplitHook_ZeroLiquidity();

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

    /// @notice Uniswap V4 Q96 fixed-point scale factor for sqrtPriceX96 values.
    uint256 internal constant _Q96 = 2 ** 96;

    /// @notice 1e18 scale factor used as a unit amount in rate calculations.
    uint256 internal constant _WAD = 10 ** 18;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice JBDirectory (to find important control contracts for given projectId)
    address public immutable DIRECTORY;

    /// @notice The oracle hook used for all JB V4 pools (provides TWAP via observe()).
    IHooks public immutable ORACLE_HOOK;

    /// @notice The Permit2 utility used to approve tokens for PositionManager.
    IAllowanceTransfer public immutable PERMIT2;

    /// @notice Uniswap V4 PoolManager address
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Uniswap V4 PositionManager address
    IPositionManager public immutable POSITION_MANAGER;

    /// @notice JBProjects (to find project owners)
    IJBProjects public immutable PROJECTS;

    /// @notice JBTokens (to find project tokens)
    address public immutable TOKENS;

    /// @notice Project ID to receive LP fees
    uint256 public FEE_PROJECT_ID;

    /// @notice Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    uint256 public FEE_PERCENT;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

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
    /// project. `processSplitWith` only receives project tokens, so once a pool exists the project permanently flips
    /// from accumulation mode into burn-and-route mode.
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

    /// @notice Whether this clone instance has been initialized.
    bool public initialized;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Token address => number of in-flight fee routes currently finalizing claims for that token.
    mapping(address token => uint256 count) internal _inflightFeeRoutingCount;

    /// @notice Token address => total outstanding fee token claims across all projects.
    /// @dev Tracks fee tokens (e.g. JBX from project ID 1) held on behalf of projects that routed LP fees.
    ///      When multiple projects share a single hook clone, fee tokens accumulate in one contract.
    ///      Without this segregation, _burnReceivedTokens would read raw balanceOf(this) and could
    ///      burn fee tokens reserved for other projects' unclaimed fee balances.
    /// @custom:param token The fee project's ERC-20 token address.
    mapping(address token => uint256 totalClaims) internal _totalOutstandingFeeTokenClaims;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory JBDirectory address
    /// @param permissions JBPermissions address
    /// @param tokens JBTokens address
    /// @param poolManager Uniswap V4 PoolManager address
    /// @param positionManager Uniswap V4 PositionManager address
    /// @param permit2 The Permit2 utility.
    /// @param oracleHook The oracle hook for all JB V4 pools (provides TWAP via observe()).
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IPoolManager poolManager,
        IPositionManager positionManager,
        IAllowanceTransfer permit2,
        IHooks oracleHook
    )
        JBPermissioned(permissions)
    {
        if (directory == address(0)) revert JBUniswapV4LPSplitHook_ZeroAddressNotAllowed();
        if (tokens == address(0)) revert JBUniswapV4LPSplitHook_ZeroAddressNotAllowed();
        if (address(poolManager) == address(0)) revert JBUniswapV4LPSplitHook_ZeroAddressNotAllowed();
        if (address(positionManager) == address(0)) revert JBUniswapV4LPSplitHook_ZeroAddressNotAllowed();

        DIRECTORY = directory;
        ORACLE_HOOK = oracleHook;
        PERMIT2 = permit2;
        POOL_MANAGER = poolManager;
        POSITION_MANAGER = positionManager;
        PROJECTS = IJBDirectory(directory).PROJECTS();
        TOKENS = tokens;
    }

    /// @notice Initialize per-instance config on a clone. Can only be called once.
    /// @dev The implementation contract can be initialized by anyone, but this is harmless —
    ///      each clone gets its own storage, so the implementation's state is never used.
    /// @param feeProjectId Project ID to receive LP fees.
    /// @param feePercent Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%).
    function initialize(uint256 feeProjectId, uint256 feePercent) external {
        if (initialized) revert JBUniswapV4LPSplitHook_AlreadyInitialized();

        if (feePercent > BPS) revert JBUniswapV4LPSplitHook_InvalidFeePercent();

        // If fees are configured, a valid fee project must be specified — otherwise fee tokens get stuck
        // because primaryTerminalOf(0, token) returns address(0).
        if (feePercent > 0 && feeProjectId == 0) revert JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject();

        if (feeProjectId != 0) {
            address feeController = _controllerOf(feeProjectId);
            if (feeController == address(0)) revert JBUniswapV4LPSplitHook_InvalidProjectId();
        }

        initialized = true;
        FEE_PROJECT_ID = feeProjectId;
        FEE_PERCENT = feePercent;
    }

    /// @notice Accept ETH transfers (needed for cashOut with native ETH and V4 TAKE operations).
    receive() external payable {}

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBUniswapV4LPSplitHook).interfaceId || interfaceId == type(IJBSplitHook).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Check if a pool has been deployed for a project/terminal token pair
    function isPoolDeployed(uint256 projectId, address terminalToken) public view returns (bool deployed) {
        return tokenIdOf[projectId][terminalToken] != 0;
    }

    /// @notice Get the PoolKey for a deployed project/terminal token pair
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

                // Deployment cashes out through the primary terminal for the selected token, so ignore balances on
                // secondary terminals that cannot satisfy the later cash-out.
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
                        ethValue = mulDiv(balance, 10 ** 18, pricePerUnit);
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
        if (highestToken == address(0)) revert JBUniswapV4LPSplitHook_NoTerminalTokenFound();
    }

    /// @notice Calculate the cash out rate (price floor).
    /// @dev Uses total surplus when the project's `useTotalSurplusForCashOuts` flag is set,
    /// otherwise uses local (single-terminal) surplus to match the actual cashout behavior.
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
        // Silence "unused parameter" warning — controller is required by callers for interface consistency.
        controller;
        // Resolve the project's primary terminal for this token.
        IJBMultiTerminal terminal = IJBMultiTerminal(_primaryTerminalOf(projectId, terminalToken));

        // Get the store for surplus queries.
        IJBTerminalStore store = terminal.STORE();

        if (ruleset.useTotalSurplusForCashOuts()) {
            // Use total surplus across all terminals.
            try store.currentTotalReclaimableSurplusOf({
                projectId: projectId,
                cashOutCount: _WAD,
                decimals: _getTokenDecimals(terminalToken),
                // Safe: truncation to uint32 is the standard Juicebox currency encoding.
                // forge-lint: disable-next-line(unsafe-typecast)
                currency: uint256(uint32(uint160(terminalToken)))
            }) returns (
                uint256 reclaimableAmount
            ) {
                terminalTokensPerProjectToken = reclaimableAmount;
            } catch {
                terminalTokensPerProjectToken = 0;
            }
        } else {
            // Build single-element arrays to query only the primary terminal's local surplus.
            IJBTerminal[] memory terminals = new IJBTerminal[](1);
            terminals[0] = IJBTerminal(address(terminal));
            address[] memory tokens = new address[](1);
            tokens[0] = terminalToken;

            // Use local surplus from only the primary terminal.
            try store.currentReclaimableSurplusOf({
                projectId: projectId,
                cashOutCount: _WAD,
                terminals: terminals,
                tokens: tokens,
                decimals: _getTokenDecimals(terminalToken),
                // Safe: truncation to uint32 is the standard Juicebox currency encoding.
                // forge-lint: disable-next-line(unsafe-typecast)
                currency: uint256(uint32(uint160(terminalToken)))
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
    // slither-disable-next-line unused-return
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
        return uint160(result);
    }

    /// @notice For given terminalToken amount, compute equivalent projectToken amount at current JuiceboxV4 price.
    /// @param projectId The ID of the project.
    /// @param terminalToken The terminal token address.
    /// @param terminalTokenInAmount The amount of terminal tokens to convert.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    /// @return projectTokenOutAmount The equivalent project token amount at the current issuance weight.
    // slither-disable-next-line unused-return
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
        address terminal = _primaryTerminalOf(projectId, terminalToken);
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
        // slither-disable-next-line unused-return
        (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
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

        // Compute sqrtPriceX96 directly from the rate, matching the M-50 pattern.
        uint256 result;
        if (token0 == terminalToken) {
            result = mulDiv({x: sqrt(issuanceRate), y: _Q96, denominator: sqrt(_WAD)});
        } else {
            result = mulDiv({x: sqrt(_WAD), y: _Q96, denominator: sqrt(issuanceRate)});
        }

        // Clamp to valid Uniswap V4 sqrt price range.
        if (result < uint256(TickMath.MIN_SQRT_PRICE)) return TickMath.MIN_SQRT_PRICE;
        if (result > uint256(TickMath.MAX_SQRT_PRICE - 1)) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(result);
    }

    /// @notice Get token decimals, defaulting to 18 if unavailable.
    /// @param token The token address to query decimals for.
    /// @return decimals The token's decimal count (defaults to 18 for native ETH or non-compliant tokens).
    function _getTokenDecimals(address token) internal view returns (uint8 decimals) {
        // Native ETH always has 18 decimals.
        if (_isNativeToken(token)) {
            return 18;
        }
        // Try the ERC-20 decimals() call; fall back to 18 if the token doesn't implement it.
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            return 18;
        }
    }

    /// @notice Look up the next token ID from the position manager.
    function _nextTokenId() internal view returns (uint256) {
        return POSITION_MANAGER.nextTokenId();
    }

    /// @notice Look up the owner of a project.
    function _ownerOf(uint256 projectId) internal view returns (address) {
        return PROJECTS.ownerOf(projectId);
    }

    /// @notice Look up the primary terminal for a project/token pair.
    function _primaryTerminalOf(uint256 projectId, address token) internal view returns (address) {
        return address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: token}));
    }

    /// @notice Look up the ERC-20 token address for a project.
    function _tokenOf(uint256 projectId) internal view returns (address) {
        return address(IJBTokens(TOKENS).tokenOf(projectId));
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Claims accumulated fee proceeds for `projectId` and sends them to `beneficiary`.
    /// @dev Requires `SET_BUYBACK_POOL` permission from the project's owner.
    /// @dev ERC-20 fee tokens are claimed first, followed by any fee credits that were accrued while the fee project
    /// had no ERC-20. Credit claims are best-effort: if the downstream controller rejects the transfer, the pending
    /// credit balance is restored so it can be retried later without blocking the ERC-20 claim path.
    /// @param projectId The project whose accumulated fee proceeds are being claimed.
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
    /// @param projectId The project whose fee-token claim is being processed.
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
        emit FeeTokensClaimed(projectId, beneficiary, tokenAmount);
        // slither-disable-next-line reentrancy-no-eth,reentrancy-events
        IERC20(feeProjectToken).safeTransfer({to: beneficiary, value: tokenAmount});
    }

    /// @notice Claims fee proceeds that were accrued as fee-project credits for `projectId`.
    /// @dev Credits are optimistically cleared before the controller call. If the downstream controller rejects the
    /// transfer, the credit balance is restored so a paused or misconfigured fee project does not block ERC-20 claims.
    /// @param projectId The project whose fee-credit claim is being processed.
    /// @param beneficiary The address that should receive the claimed fee-project credits.
    /// @param creditAmount The number of fee-project credits to transfer.
    function _claimFeeCredits(uint256 projectId, address beneficiary, uint256 creditAmount) internal {
        // Optimistically clear the credit claim before the external call so reentrant reads cannot double-spend it.
        claimableFeeCredits[projectId] = 0;

        // Try the credit transfer directly. If the fee-project controller is paused or misconfigured, restore the
        // pending credits instead of unwinding an ERC-20 fee-token claim that already succeeded earlier in the frame.
        try IJBController(_controllerOf(FEE_PROJECT_ID))
            .transferCreditsFrom({
            holder: address(this), projectId: FEE_PROJECT_ID, recipient: beneficiary, creditCount: creditAmount
        }) {
            // slither-disable-next-line reentrancy-events
            emit FeeTokensClaimed(projectId, beneficiary, creditAmount);
        } catch {
            // Restore the pending credits so the project owner can retry once the fee-project controller is usable.
            // slither-disable-next-line reentrancy-no-eth,reentrancy-events,reentrancy-benign
            claimableFeeCredits[projectId] = creditAmount;
        }
    }

    /// @notice Collect LP fees and route them back to the project.
    /// @param projectId The ID of the project whose LP fees to collect.
    /// @param terminalToken The terminal token paired with the project token in the pool.
    // forge-lint: disable-next-line(mixed-case-function)
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external {
        // Ensure a pool has been deployed for this project/token pair.
        uint256 tokenId = tokenIdOf[projectId][terminalToken];
        if (tokenId == 0) revert JBUniswapV4LPSplitHook_InvalidStageForAction();

        // Resolve the project's ERC-20 token and pool key for fee collection.
        address projectToken = _tokenOf(projectId);
        PoolKey memory key = poolKeysOf[projectId][terminalToken];

        // Collect LP fees and route them to the project's terminal balance.
        _collectAndRouteFees({
            projectId: projectId, projectToken: projectToken, terminalToken: terminalToken, tokenId: tokenId, key: key
        });
    }

    /// @notice Deploy a Uniswap V4 pool for a project using accumulated tokens
    // slither-disable-next-line reentrancy-benign,reentrancy-events,unused-return
    function deployPool(uint256 projectId, uint256 minCashOutReturn) external {
        // Allow anyone to deploy if the current ruleset's weight has decayed 10x from the initial weight.
        // Otherwise, require SET_BUYBACK_POOL permission from the project owner.
        address controller = _controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        uint256 initialWeight = initialWeightOf[projectId];

        if (initialWeight == 0 || ruleset.weight * 10 > initialWeight) {
            _requirePermissionFrom({
                account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_BUYBACK_POOL
            });
        }

        // Auto-select the terminal token with the highest ETH-denominated value.
        address terminalToken = _findHighestValueTerminalTokenOf({projectId: projectId, controller: controller});

        if (tokenIdOf[projectId][terminalToken] != 0) revert JBUniswapV4LPSplitHook_PoolAlreadyDeployed();
        if (hasDeployedPool[projectId]) revert JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported();

        address projectToken = _tokenOf(projectId);
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];

        if (projectTokenBalance == 0) revert JBUniswapV4LPSplitHook_NoTokensAccumulated();

        address terminal = _primaryTerminalOf(projectId, terminalToken);
        if (terminal == address(0)) revert JBUniswapV4LPSplitHook_InvalidTerminalToken();

        // Flip the project into post-deploy burn mode before any external calls so reentrancy cannot
        // observe the project as still being in accumulation mode.
        hasDeployedPool[projectId] = true;

        _deployPoolAndAddLiquidity({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            minCashOutReturn: minCashOutReturn,
            controller: controller,
            ruleset: ruleset
        });

        emit ProjectDeployed(projectId, terminalToken, PoolId.unwrap(poolKeysOf[projectId][terminalToken].toId()));
    }

    /// @notice IJBSplitHook: called by JuiceboxV4 controller when sending funds to designated split hook
    // slither-disable-next-line unused-return
    function processSplitWith(JBSplitHookContext calldata context) external payable {
        if (address(context.split.hook) != address(this)) revert JBUniswapV4LPSplitHook_NotHookSpecifiedInContext();

        address controller = _controllerOf(context.projectId);
        if (controller == address(0)) revert JBUniswapV4LPSplitHook_InvalidProjectId();
        if (controller != msg.sender) revert JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal();

        if (context.groupId != 1) revert JBUniswapV4LPSplitHook_TerminalTokensNotAllowed();

        address projectToken = _tokenOf(context.projectId);

        if (!hasDeployedPool[context.projectId]) {
            // This hook requires an ERC-20 project token — credits cannot be paired as LP.
            // Check BEFORE accumulating to keep internal accounting clean on revert.
            if (projectToken == address(0)) revert JBUniswapV4LPSplitHook_InvalidProjectId();

            // Record the initial weight on first accumulation.
            if (initialWeightOf[context.projectId] == 0) {
                (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(context.projectId);
                initialWeightOf[context.projectId] = ruleset.weight;
            }
            _accumulateTokens({projectId: context.projectId, amount: context.amount});

            // Defense-in-depth: verify actual ERC-20 balance (minus outstanding fee token claims)
            // covers accumulated total. The standard controller transfers tokens before calling
            // processSplitWith, but custom controllers may not — this guards against accounting drift.
            if (
                IERC20(projectToken).balanceOf(address(this)) - _reservedTokenBalance(projectToken)
                    < accumulatedProjectTokens[context.projectId]
            ) {
                revert JBUniswapV4LPSplitHook_InsufficientBalance();
            }
        } else {
            _burnReceivedTokens({projectId: context.projectId, projectToken: projectToken});
        }
    }

    /// @notice Rebalance LP position to match current issuance and cash out rates
    /// @dev Requires SET_BUYBACK_POOL permission from the project owner.
    // slither-disable-next-line reentrancy-eth,reentrancy-benign,reentrancy-events
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

        address terminal = _primaryTerminalOf(projectId, terminalToken);
        if (terminal == address(0)) revert JBUniswapV4LPSplitHook_InvalidTerminalToken();

        uint256 tokenId = tokenIdOf[projectId][terminalToken];
        if (tokenId == 0) revert JBUniswapV4LPSplitHook_InvalidStageForAction();

        address projectToken = _tokenOf(projectId);
        PoolKey memory key = poolKeysOf[projectId][terminalToken];

        _collectAndRouteFees({
            projectId: projectId, projectToken: projectToken, terminalToken: terminalToken, tokenId: tokenId, key: key
        });

        // Snapshot balances before burn to isolate per-project recovered amounts (H-32).
        uint256 projBalBefore = IERC20(projectToken).balanceOf(address(this));
        uint256 termBalBefore = _getTerminalTokenBalance(terminalToken);

        _burnExistingPosition({
            tokenId: tokenId, key: key, decreaseAmount0Min: decreaseAmount0Min, decreaseAmount1Min: decreaseAmount1Min
        });

        uint256 recoveredProjectTokens = IERC20(projectToken).balanceOf(address(this)) - projBalBefore;
        uint256 recoveredTerminalTokens = _getTerminalTokenBalance(terminalToken) - termBalBefore;

        // Cache controller and ruleset once for _mintRebalancedPosition and its callees.
        address controller = _controllerOf(projectId);
        // slither-disable-next-line unused-return
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

    /// @notice Accumulate project tokens in accumulation stage
    function _accumulateTokens(uint256 projectId, uint256 amount) internal {
        accumulatedProjectTokens[projectId] += amount;
    }

    /// @notice Add tokens to project balance via terminal
    // slither-disable-next-line arbitrary-send-eth,incorrect-equality
    function _addToProjectBalance(uint256 projectId, address token, uint256 amount, bool isNative) internal {
        if (amount == 0) return;

        address terminal = _primaryTerminalOf(projectId, token);
        if (terminal == address(0)) revert JBUniswapV4LPSplitHook_TerminalNotFound(projectId, token);

        if (!isNative) {
            IERC20(token).forceApprove({spender: terminal, value: amount});
        }

        IJBMultiTerminal(terminal).addToBalanceOf{value: isNative ? amount : 0}({
            projectId: projectId, token: token, amount: amount, shouldReturnHeldFees: false, memo: "", metadata: ""
        });

        if (!isNative) _requireTemporaryAllowanceConsumed({token: token, spender: terminal});
    }

    /// @notice Add liquidity to a Uniswap V4 pool using accumulated tokens
    /// @param projectId The ID of the project.
    /// @param projectToken The project token address.
    /// @param terminalToken The terminal token address.
    /// @param minCashOutReturn Minimum cash out return (slippage protection).
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    // slither-disable-next-line reentrancy-eth,reentrancy-benign,reentrancy-events,unused-return
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
        // Check the project's accumulated token balance — nothing to add if empty.
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

        // Read the pool's actual current price. The pool may have been initialized by another party
        // (e.g. REVDeployer) at a different price than _computeInitialSqrtPrice would return.
        PoolKey memory key = poolKeysOf[projectId][terminalToken];
        uint160 sqrtPriceInit = _getSqrtPriceX96(key);

        // Determine the optimal fraction of project tokens to cash out for terminal-token pairing.
        uint256 cashOutAmount = _computeOptimalCashOutAmount({
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            totalProjectTokens: projectTokenBalance,
            sqrtPriceInit: sqrtPriceInit,
            tickLower: tickLower,
            tickUpper: tickUpper,
            controller: controller,
            ruleset: ruleset
        });

        // Cash out the computed fraction to get terminal tokens for pairing.
        // Use the explicit return value instead of balance-delta to prevent cross-project token capture.
        address terminal = _primaryTerminalOf(projectId, terminalToken);

        uint256 terminalTokenAmount;

        if (terminal != address(0) && cashOutAmount > 0) {
            uint256 spendableTerminalTokenBefore = _spendableTerminalTokenBalance(terminalToken);
            uint256 effectiveMinReturn = minCashOutReturn;
            if (effectiveMinReturn == 0 && cashOutAmount > 0) {
                uint256 cashOutRate = _getCashOutRate({
                    projectId: projectId, terminalToken: terminalToken, controller: controller, ruleset: ruleset
                });
                if (cashOutRate > 0) {
                    uint256 expectedReturn = mulDiv({x: cashOutAmount, y: cashOutRate, denominator: _WAD});
                    effectiveMinReturn = mulDiv({
                        x: expectedReturn, y: _CASH_OUT_SLIPPAGE_NUMERATOR, denominator: _CASH_OUT_SLIPPAGE_DENOMINATOR
                    });
                }
            }

            uint256 reportedTerminalTokenAmount = IJBMultiTerminal(terminal)
                .cashOutTokensOf({
                holder: address(this),
                projectId: projectId,
                cashOutCount: cashOutAmount,
                tokenToReclaim: terminalToken,
                minTokensReclaimed: effectiveMinReturn,
                beneficiary: payable(address(this)),
                metadata: ""
            });

            uint256 spendableTerminalTokenAfter = _spendableTerminalTokenBalance(terminalToken);
            uint256 actualTerminalTokenAmount = spendableTerminalTokenAfter > spendableTerminalTokenBefore
                ? spendableTerminalTokenAfter - spendableTerminalTokenBefore
                : 0;
            terminalTokenAmount = reportedTerminalTokenAmount < actualTerminalTokenAmount
                ? reportedTerminalTokenAmount
                : actualTerminalTokenAmount;
            if (terminalTokenAmount < effectiveMinReturn) revert JBUniswapV4LPSplitHook_InsufficientBalance();
        }

        uint256 projectTokenAmount = projectTokenBalance - cashOutAmount;

        // Sort amounts by currency order
        Currency terminalCurrency = _toCurrency(terminalToken);
        (address token0,) = _sortTokens({tokenA: projectToken, tokenB: Currency.unwrap(terminalCurrency)});
        uint256 amount0 = projectToken == token0 ? projectTokenAmount : terminalTokenAmount;
        uint256 amount1 = projectToken == token0 ? terminalTokenAmount : projectTokenAmount;

        // Calculate liquidity from amounts
        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts({
            sqrtPriceX96: sqrtPriceInit,
            sqrtPriceAX96: sqrtPriceA,
            sqrtPriceBX96: sqrtPriceB,
            amount0: amount0,
            amount1: amount1
        });

        // Revert if the computed liquidity is zero — minting a position with no liquidity would
        // waste gas and leave the project in a deployed state with a useless (empty) LP position.
        // slither-disable-next-line incorrect-equality
        if (liquidity == 0) revert JBUniswapV4LPSplitHook_ZeroLiquidity();

        // Snapshot balances before minting to isolate per-project leftovers (H-32).
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

        // Per-project leftover handling via snapshot-delta (H-32).
        // Safe subtraction: V4 SWEEP may return dust beyond what was settled.
        uint256 postProjBal = IERC20(projectToken).balanceOf(address(this));
        uint256 postTermBal = _getTerminalTokenBalance(terminalToken);
        uint256 projConsumed = projBalBeforeMint > postProjBal ? projBalBeforeMint - postProjBal : 0;
        uint256 termConsumed = termBalBeforeMint > postTermBal ? termBalBeforeMint - postTermBal : 0;
        uint256 projLeftover = projectTokenAmount > projConsumed ? projectTokenAmount - projConsumed : 0;
        uint256 termLeftover = terminalTokenAmount > termConsumed ? terminalTokenAmount - termConsumed : 0;

        if (projLeftover > 0) {
            _burnProjectTokens({
                projectId: projectId,
                projectToken: projectToken,
                amount: projLeftover,
                memo: "Burning leftover project tokens"
            });
        }
        if (termLeftover > 0) {
            _addToProjectBalance({
                projectId: projectId,
                token: terminalToken,
                amount: termLeftover,
                isNative: _isNativeToken(terminalToken)
            });
        }

        // Clear accumulated balances after successful LP creation.
        accumulatedProjectTokens[projectId] = 0;
    }

    /// @notice Align tick to tick spacing using proper floor semantics for negative ticks
    // slither-disable-next-line divide-before-multiply
    function _alignTickToSpacing(int24 tick, int24 spacing) internal pure returns (int24 alignedTick) {
        // Intentional: rounding tick down to nearest spacing boundary
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 rounded = (tick / spacing) * spacing;
        if (tick < 0 && rounded > tick) {
            rounded -= spacing;
        }
        return rounded;
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

        _modifyLiquidities(abi.encode(burnActions, burnParams), 0);
    }

    /// @dev Reverts if a terminal kept any portion of a temporary ERC-20 allowance.
    function _requireTemporaryAllowanceConsumed(address token, address spender) internal view {
        uint256 allowance = IERC20(token).allowance({owner: address(this), spender: spender});
        if (allowance != 0) revert JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed(token, spender, allowance);
    }

    /// @notice Burn project tokens using the controller
    // slither-disable-next-line incorrect-equality,reentrancy-events
    function _burnProjectTokens(uint256 projectId, address projectToken, uint256 amount, string memory memo) internal {
        if (amount == 0) return;

        address controller = _controllerOf(projectId);
        if (controller != address(0)) {
            IJBController(controller)
                .burnTokensOf({holder: address(this), projectId: projectId, tokenCount: amount, memo: memo});
            emit TokensBurned(projectId, projectToken, amount);
        }
    }

    /// @notice Burn received project tokens in deployment stage
    function _burnReceivedTokens(uint256 projectId, address projectToken) internal {
        // Get this contract's balance of the project token, minus any fee tokens reserved
        // for other projects. Without this subtraction, fee tokens (e.g. JBX) held on behalf
        // of projects that routed LP fees would be incorrectly burned.
        uint256 projectTokenBalance =
            IERC20(projectToken).balanceOf(address(this)) - _reservedTokenBalance(projectToken);

        if (projectTokenBalance > 0) {
            // Burn the project tokens to reduce circulating supply.
            _burnProjectTokens({
                projectId: projectId,
                projectToken: projectToken,
                amount: projectTokenBalance,
                memo: "Burning additional tokens"
            });
        }
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
                // No floor and no ceiling — full range LP.
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

            // Clamp to valid V4 tick range (M-46).
            int24 minUsable = _alignTickToSpacing({tick: TickMath.MIN_TICK, spacing: TICK_SPACING}) + TICK_SPACING;
            int24 maxUsable = _alignTickToSpacing({tick: TickMath.MAX_TICK, spacing: TICK_SPACING}) - TICK_SPACING;
            if (tickLower < minUsable) tickLower = minUsable;
            if (tickUpper > maxUsable) tickUpper = maxUsable;
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

        tickLower = _alignTickToSpacing({tick: tickLower, spacing: TICK_SPACING});
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
            if (tickLower >= tickUpper) revert JBUniswapV4LPSplitHook_InvalidTickBounds();
        }
    }

    /// @notice Collect accrued Uniswap LP trading fees and route them to the project's terminal balance.
    /// @dev Uses `DECREASE_LIQUIDITY(0)` to trigger fee collection without removing any principal, followed by
    /// `TAKE_PAIR` to transfer the fees to this contract. Terminal-token fees are added to the project's balance;
    /// project-token fees are burned to avoid inflating supply.
    /// @param projectId The ID of the Juicebox project whose LP fees are being collected.
    /// @param projectToken The project's ERC-20 token address.
    /// @param terminalToken The terminal token (e.g. ETH or USDC) paired with the project token.
    /// @param tokenId The Uniswap V4 position NFT token ID to collect fees from.
    /// @param key The pool key identifying the Uniswap V4 pool.
    // slither-disable-next-line reentrancy-eth,reentrancy-benign,reentrancy-events
    function _collectAndRouteFees(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 tokenId,
        PoolKey memory key
    )
        internal
    {
        // Snapshot balances before collection to isolate fee amounts from any existing balance.
        uint256 bal0Before = _currencyBalance(key.currency0);
        uint256 bal1Before = _currencyBalance(key.currency1);

        // DECREASE_LIQUIDITY with amount=0 triggers fee collection without removing principal.
        // TAKE_PAIR transfers the collected fees (both currencies) to this contract.
        bytes memory feeActions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));

        bytes[] memory feeParams = new bytes[](2);
        // DECREASE_LIQUIDITY params: (tokenId, liquidity=0, minAmount0=0, minAmount1=0, hookData).
        feeParams[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), "");
        // TAKE_PAIR params: (currency0, currency1, recipient).
        feeParams[1] = abi.encode(key.currency0, key.currency1, address(this));

        _modifyLiquidities(abi.encode(feeActions, feeParams), 0);

        // Diff balances to determine exactly how much was collected as fees.
        uint256 feeAmount0 = _currencyBalance(key.currency0) - bal0Before;
        uint256 feeAmount1 = _currencyBalance(key.currency1) - bal1Before;

        // Burn project tokens BEFORE routing terminal token fees. This ordering prevents reentrancy:
        // _routeCollectedFees → terminal.pay() can trigger pay hooks; burning first ensures a
        // re-entrant _burnReceivedTokens finds zero burnable balance.
        _burnReceivedTokens({projectId: projectId, projectToken: projectToken});

        // Route terminal-token fees to the project's balance (may call terminal.pay() externally).
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

        // Clamp to valid V4 tick range.
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

        uint256 diffPriceInit_A = uint256(sqrtPriceInit) - uint256(sqrtPriceA);
        uint256 diffB_PriceInit = uint256(sqrtPriceB) - uint256(sqrtPriceInit);

        if (terminalIsToken0) {
            // Correct ratio: amount0/amount1 = Q96² × (√Pb − √P) / (√P × √Pb × (√P − √Pa))
            // Computed step-by-step to avoid overflow.
            uint256 step1 = mulDiv({x: _Q96, y: diffB_PriceInit, denominator: uint256(sqrtPriceInit)});
            numerator = mulDiv({x: step1, y: _Q96, denominator: uint256(sqrtPriceB)});
            denominator = diffPriceInit_A;
        } else {
            // Correct ratio: amount1/amount0 = √P × √Pb × (√P − √Pa) / (Q96² × (√Pb − √P))
            uint256 step1 = mulDiv({x: uint256(sqrtPriceInit), y: uint256(sqrtPriceB), denominator: _Q96});
            numerator = mulDiv({x: step1, y: diffPriceInit_A, denominator: _Q96});
            denominator = diffB_PriceInit;
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
    // slither-disable-next-line reentrancy-benign,reentrancy-events,unused-return
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
            currency0: currency0, currency1: currency1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: ORACLE_HOOK
        });

        // Compute initial price at geometric mean of [cashOutRate, issuanceRate]
        uint160 sqrtPriceX96 = _computeInitialSqrtPrice({
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            controller: controller,
            ruleset: ruleset
        });

        // If the pool was already initialized (e.g. by an attacker or another deployer), accept the
        // existing price and proceed. Liquidity will be added within the hook's configured tick bounds
        // regardless of the current pool price — if the price is out of band the position will be
        // single-sided and arbitrageurs will quickly move the price back into range.
        uint160 existingSqrtPriceX96 = _getSqrtPriceX96(key);
        if (existingSqrtPriceX96 != 0) {
            // Use the existing pool price for downstream liquidity calculations.
            sqrtPriceX96 = existingSqrtPriceX96;
        }

        // Best-effort initialize the pool. Uniswap's PositionManager swallows initialize reverts and returns
        // `type(int24).max`, so this call is still required for uninitialized pools but non-fatal for initialized ones.
        POSITION_MANAGER.initializePool({key: key, sqrtPriceX96: sqrtPriceX96});

        // Store the pool key
        poolKeysOf[projectId][terminalToken] = key;
    }

    /// @notice Get balance of a currency held by this contract
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
    // slither-disable-next-line reentrancy-events
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

    /// @notice Get terminal token balance held by this contract.
    function _getTerminalTokenBalance(address terminalToken) internal view returns (uint256) {
        if (_isNativeToken(terminalToken)) {
            return address(this).balance;
        }
        return IERC20(terminalToken).balanceOf(address(this));
    }

    /// @notice Get terminal token balance not reserved for fee-token claims.
    function _spendableTerminalTokenBalance(address terminalToken) internal view returns (uint256) {
        uint256 balance = _getTerminalTokenBalance(terminalToken);
        if (_isNativeToken(terminalToken)) return balance;

        uint256 reserved = _reservedTokenBalance(terminalToken);
        return balance > reserved ? balance - reserved : 0;
    }

    /// @notice Check if terminal token is native ETH
    function _isNativeToken(address terminalToken) internal pure returns (bool isNative) {
        return terminalToken == JBConstants.NATIVE_TOKEN;
    }

    /// @notice Mint a V4 position via PositionManager
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

        _modifyLiquidities(abi.encode(actions, params), ethValue);
    }

    /// @notice Mint a new LP position with tick bounds recalculated from current issuance and cash-out rates.
    /// @dev Called after `_burnExistingPosition` has recovered the old position's principal. Computes liquidity from
    /// this contract's current token balances and the pool's live `sqrtPriceX96`. Reverts with
    /// `JBUniswapV4LPSplitHook_InsufficientLiquidity` if the resulting liquidity is zero (e.g. price moved entirely
    /// outside the new tick range), preventing `tokenIdOf` from being left stale. Any leftover tokens after minting
    /// are routed back to the project via per-project snapshot-delta leftover handling.
    /// @param projectId The ID of the Juicebox project being rebalanced.
    /// @param projectToken The project's ERC-20 token address.
    /// @param terminalToken The terminal token paired with the project token.
    /// @param key The pool key identifying the Uniswap V4 pool.
    /// @param controller The project's controller address (pre-fetched to avoid redundant lookups).
    /// @param ruleset The project's current ruleset (pre-fetched to avoid redundant lookups).
    // slither-disable-next-line reentrancy-eth,reentrancy-benign,reentrancy-events
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
            // Snapshot balances before minting to isolate per-project leftovers (H-32).
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

            // Per-project leftover handling via snapshot-delta (H-32).
            // Safe subtraction: V4 SWEEP may return dust beyond what was settled.
            uint256 postProjBal = IERC20(projectToken).balanceOf(address(this));
            uint256 postTermBal = _getTerminalTokenBalance(terminalToken);
            uint256 projConsumed = projBalBeforeMint > postProjBal ? projBalBeforeMint - postProjBal : 0;
            uint256 termConsumed = termBalBeforeMint > postTermBal ? termBalBeforeMint - postTermBal : 0;
            uint256 projLeftover = projectTokenBalance > projConsumed ? projectTokenBalance - projConsumed : 0;
            uint256 termLeftover = terminalTokenBalance > termConsumed ? terminalTokenBalance - termConsumed : 0;

            if (projLeftover > 0) {
                _burnProjectTokens({
                    projectId: projectId,
                    projectToken: projectToken,
                    amount: projLeftover,
                    memo: "Burning leftover project tokens"
                });
            }
            if (termLeftover > 0) {
                _addToProjectBalance({
                    projectId: projectId,
                    token: terminalToken,
                    amount: termLeftover,
                    isNative: _isNativeToken(terminalToken)
                });
            }
        } else {
            // Zero liquidity means the position cannot be re-created (e.g., price moved
            // outside tick range making the position single-sided with zero on one side).
            // Revert to prevent bricking the project's LP — the old position was already
            // burned by the BURN_POSITION action above, so this protects the invariant
            // that tokenIdOf is always nonzero for deployed projects.
            revert JBUniswapV4LPSplitHook_InsufficientLiquidity();
        }
    }

    /// @notice Forward a modifyLiquidities call to the position manager.
    function _modifyLiquidities(bytes memory unlockData, uint256 value) internal {
        POSITION_MANAGER.modifyLiquidities{value: value}({
            unlockData: unlockData, deadline: block.timestamp + _DEADLINE_SECONDS
        });
    }

    /// @notice Approve an ERC20 token via Permit2 so PositionManager can pull it during SETTLE.
    function _approveViaPermit2(address token, uint256 amount) internal {
        IERC20(token).forceApprove({spender: address(PERMIT2), value: amount});
        if (amount > type(uint160).max) revert JBUniswapV4LPSplitHook_Permit2AmountOverflow();
        PERMIT2.approve({
            token: token,
            spender: address(POSITION_MANAGER),
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint160(amount),
            // forge-lint: disable-next-line(unsafe-typecast)
            expiration: uint48(block.timestamp + _DEADLINE_SECONDS)
        });
    }

    /// @notice Route collected fees from Uniswap position to project
    // slither-disable-next-line reentrancy-eth,reentrancy-events,incorrect-equality
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

        // Route terminal token fees
        if (amount0 > 0 && token0 == Currency.unwrap(terminalCurrency)) {
            _routeFeesToProject({projectId: projectId, terminalToken: terminalToken, amount: amount0});
        }
        if (amount1 > 0 && token0 != Currency.unwrap(terminalCurrency)) {
            _routeFeesToProject({projectId: projectId, terminalToken: terminalToken, amount: amount1});
        }
    }

    /// @notice Route fees back to the project.
    /// @dev Fee routing uses zero slippage (minReturnedTokens = 0) by design. Slippage protection
    /// is the responsibility of the fee project's pay hook (e.g., its buyback hook). An alternative
    /// approach — calling `previewPayFor` and using the result as a minimum — was considered but
    /// deemed unnecessary given the existing hook-level protection. Fees are small amounts routed
    /// to the protocol fee project; MEV extraction is economically insignificant relative to gas costs.
    // slither-disable-next-line arbitrary-send-eth,reentrancy-eth,reentrancy-benign,reentrancy-events,incorrect-equality,unused-return
    function _routeFeesToProject(uint256 projectId, address terminalToken, uint256 amount) internal {
        if (amount == 0) return;

        uint256 feeAmount = (amount * FEE_PERCENT) / BPS;
        uint256 remainingAmount = amount - feeAmount;

        uint256 beneficiaryTokenCount = 0;
        if (feeAmount > 0) {
            address feeTerminal = _primaryTerminalOf(FEE_PROJECT_ID, terminalToken);
            // If no fee terminal is configured, the fee project simply misses this collection and the full amount
            // stays in the project's normal split-hook flow.
            if (feeTerminal == address(0)) {
                feeAmount = 0;
                remainingAmount = amount;
            } else {
                // Look up the fee project's ERC-20 BEFORE the pay() call so we can pre-increment
                // _totalOutstandingFeeTokenClaims. This prevents a reentrancy through terminal.pay()
                // → pay hooks → collectAndRouteLPFees() from seeing stale claims and double-counting
                // fee tokens in _burnReceivedTokens or leftover handling.
                address feeProjectToken = _tokenOf(FEE_PROJECT_ID);

                // If this project already has unclaimed ERC-20 fee tokens, keep using that snapshotted token address.
                // Otherwise a fee-project token migration could strand the earlier claim behind a new token contract.
                address claimToken = claimableFeeTokenOf[projectId];
                // Reject mixing outstanding claims across different fee-project ERC-20s in the same project bucket.
                if (claimToken != address(0) && claimToken != feeProjectToken) {
                    revert JBUniswapV4LPSplitHook_UnclaimedFeeTokenChanged(claimToken, feeProjectToken);
                }

                uint256 feeProjectTokenBalanceBefore;

                // Pre-increment with feeAmount as a conservative estimate. The actual token count
                // may differ, but any re-entrant call during pay() will see an inflated reserve,
                // which safely prevents over-burning. We reconcile after pay() returns.
                if (feeProjectToken != address(0)) {
                    feeProjectTokenBalanceBefore = IERC20(feeProjectToken).balanceOf(address(this));
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
                        projectId: FEE_PROJECT_ID,
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
                        projectId: FEE_PROJECT_ID,
                        token: terminalToken,
                        amount: feeAmount,
                        beneficiary: address(this),
                        minReturnedTokens: 0,
                        memo: "LP Fee",
                        metadata: ""
                    });

                    _requireTemporaryAllowanceConsumed({token: terminalToken, spender: feeTerminal});
                }

                // Reconcile the pre-incremented estimate with the actual token count received.
                if (feeProjectToken != address(0)) {
                    uint256 expectedBalanceWithoutFeeTokens = feeProjectTokenBalanceBefore;
                    if (terminalToken == feeProjectToken) expectedBalanceWithoutFeeTokens -= feeAmount;

                    uint256 feeProjectTokenBalanceAfter = IERC20(feeProjectToken).balanceOf(address(this));
                    beneficiaryTokenCount = feeProjectTokenBalanceAfter > expectedBalanceWithoutFeeTokens
                        ? feeProjectTokenBalanceAfter - expectedBalanceWithoutFeeTokens
                        : 0;

                    // Remove the estimate and apply the actual amount.
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

        emit LPFeesRouted(projectId, terminalToken, amount, feeAmount, remainingAmount, beneficiaryTokenCount);
    }

    /// @notice Returns the portion of this contract's balance of `token` that is not currently free to reuse.
    /// @dev When no fee route is in flight, the reserved amount is the total ERC-20 balance already promised to
    /// project beneficiaries through `claimableFeeTokens`.
    /// @dev While fee routing for `token` is mid-flight, reentrant code must conservatively treat the full current
    /// balance as reserved because the final claim bookkeeping has not been written yet.
    /// @param token The ERC-20 token whose reserved balance should be returned.
    /// @return reservedBalance The amount of `token` balance that callers must treat as unavailable.
    function _reservedTokenBalance(address token) internal view returns (uint256) {
        // During fee routing, the contract may already be holding freshly minted fee tokens that have not yet been
        // reflected in `_totalOutstandingFeeTokenClaims`. Treat the whole balance as reserved until routing finishes.
        if (_inflightFeeRoutingCount[token] != 0) return IERC20(token).balanceOf(address(this));
        return _totalOutstandingFeeTokenClaims[token];
    }

    /// @notice Sort input tokens in order expected by Uniswap V4 (token0 < token1)
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @notice Convert terminal token to Uniswap V4 Currency
    /// @dev Juicebox uses JBConstants.NATIVE_TOKEN for native ETH; V4 uses Currency.wrap(address(0))
    function _toCurrency(address terminalToken) internal pure returns (Currency) {
        return Currency.wrap(_isNativeToken(terminalToken) ? address(0) : terminalToken);
    }
}
