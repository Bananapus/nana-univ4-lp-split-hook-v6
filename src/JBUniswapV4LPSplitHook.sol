// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
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
    error JBUniswapV4LPSplitHook_InvalidFeePercent();
    error JBUniswapV4LPSplitHook_InvalidProjectId();
    error JBUniswapV4LPSplitHook_InvalidStageForAction();
    error JBUniswapV4LPSplitHook_InvalidTerminalToken();
    error JBUniswapV4LPSplitHook_NoTokensAccumulated();
    error JBUniswapV4LPSplitHook_NotHookSpecifiedInContext();
    error JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported();
    error JBUniswapV4LPSplitHook_Permit2AmountOverflow();
    error JBUniswapV4LPSplitHook_PoolAlreadyDeployed();
    error JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal();
    error JBUniswapV4LPSplitHook_TerminalTokensNotAllowed();
    error JBUniswapV4LPSplitHook_InsufficientLiquidity();
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

    /// @notice JBTokens (to find project tokens)
    address public immutable TOKENS;

    /// @notice Project ID to receive LP fees
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public FEE_PROJECT_ID;

    /// @notice Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public FEE_PERCENT;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice ProjectID => Terminal token => Uniswap V4 PoolKey
    mapping(uint256 projectId => mapping(address terminalToken => PoolKey)) public _poolKeys;

    /// @notice ProjectID => Terminal token => PositionManager tokenId
    mapping(uint256 projectId => mapping(address terminalToken => uint256 tokenId)) public tokenIdOf;

    /// @notice ProjectID => Accumulated project token balance
    mapping(uint256 projectId => uint256 accumulatedProjectTokens) public accumulatedProjectTokens;

    /// @notice ProjectID => Number of deployed pools for this project.
    /// @dev This is intentionally capped at 1. `processSplitWith` only receives the project token and cannot tell
    ///      which terminal token a reserved-token distribution is intended for, so one deployment permanently flips
    ///      the project from accumulation to burn mode.
    mapping(uint256 projectId => uint256 count) public deployedPoolCount;

    /// @notice ProjectID => Fee tokens claimable by that project
    mapping(uint256 projectId => uint256 claimableFeeTokens) public claimableFeeTokens;

    /// @notice ProjectID => The weight of the ruleset when the hook first started accumulating tokens.
    mapping(uint256 projectId => uint256 weight) public initialWeightOf;

    /// @notice Whether this clone instance has been initialized.
    bool public initialized;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

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
            address feeController = address(IJBDirectory(DIRECTORY).controllerOf(feeProjectId));
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
        return _poolKeys[projectId][terminalToken];
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Calculate the cash out rate (price floor)
    function _getCashOutRate(
        uint256 projectId,
        address terminalToken
    )
        internal
        view
        returns (uint256 terminalTokensPerProjectToken)
    {
        try IJBMultiTerminal(
                address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}))
            ).STORE()
            .currentTotalReclaimableSurplusOf({
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
    }

    /// @notice Convert cash out rate to sqrtPriceX96 (price floor)
    function _getCashOutRateSqrtPriceX96(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        (address token0,) = _sortTokens({tokenA: terminalToken, tokenB: projectToken});

        uint256 terminalTokensPerProjectToken = _getCashOutRate({projectId: projectId, terminalToken: terminalToken});

        // If the cash out rate is 0 (no surplus or negligible surplus), return the minimum price.
        if (terminalTokensPerProjectToken == 0) return TickMath.MIN_SQRT_PRICE;

        uint256 token0Amount = _WAD;
        uint256 token1Amount;

        if (token0 == terminalToken) {
            token1Amount = mulDiv({x: token0Amount, y: _WAD, denominator: terminalTokensPerProjectToken});
        } else {
            token1Amount = terminalTokensPerProjectToken;
        }

        return uint160(mulDiv({x: sqrt(token1Amount), y: _Q96, denominator: sqrt(token0Amount)}));
    }

    /// @notice Calculate the issuance rate (price ceiling)
    // slither-disable-next-line unused-return
    function _getIssuanceRate(
        uint256 projectId,
        address terminalToken
    )
        internal
        view
        returns (uint256 projectTokensPerTerminalToken)
    {
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        uint16 reservedPercent = JBRulesetMetadataResolver.reservedPercent(ruleset);

        uint256 tokensPerTerminalToken = _getProjectTokensOutForTerminalTokensIn({
            projectId: projectId, terminalToken: terminalToken, terminalTokenInAmount: _WAD
        });

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

    /// @notice Convert issuance rate to sqrtPriceX96 (price ceiling)
    function _getIssuanceRateSqrtPriceX96(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        (address token0,) = _sortTokens({tokenA: terminalToken, tokenB: projectToken});

        uint256 projectTokensPerTerminalToken = _getIssuanceRate({projectId: projectId, terminalToken: terminalToken});

        uint256 token0Amount = _WAD;
        uint256 token1Amount;

        if (token0 == terminalToken) {
            token1Amount = projectTokensPerTerminalToken;
        } else {
            token1Amount = mulDiv({x: token0Amount, y: _WAD, denominator: projectTokensPerTerminalToken});
        }

        return uint160(mulDiv({x: sqrt(token1Amount), y: _Q96, denominator: sqrt(token0Amount)}));
    }

    /// @notice For given terminalToken amount, compute equivalent projectToken amount at current JuiceboxV4 price
    // slither-disable-next-line unused-return
    function _getProjectTokensOutForTerminalTokensIn(
        uint256 projectId,
        address terminalToken,
        uint256 terminalTokenInAmount
    )
        internal
        view
        returns (uint256 projectTokenOutAmount)
    {
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        address terminal =
            address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        JBAccountingContext memory context =
            IJBMultiTerminal(terminal).accountingContextForTokenOf({projectId: projectId, token: terminalToken});

        uint32 baseCurrency = ruleset.baseCurrency();

        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES()
                .pricePerUnitOf({
                    projectId: projectId,
                    pricingCurrency: context.currency,
                    unitCurrency: baseCurrency,
                    decimals: context.decimals
                });

        projectTokenOutAmount = mulDiv({x: terminalTokenInAmount, y: ruleset.weight, denominator: weightRatio});
    }

    /// @notice Compute Uniswap SqrtPriceX96 for current JuiceboxV4 price
    function _getSqrtPriceX96ForCurrentJuiceboxPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        (address token0,) = _sortTokens({tokenA: terminalToken, tokenB: projectToken});

        uint256 token0Amount = _WAD;
        uint256 token1Amount;

        if (token0 == terminalToken) {
            token1Amount = _getProjectTokensOutForTerminalTokensIn({
                projectId: projectId, terminalToken: terminalToken, terminalTokenInAmount: token0Amount
            });
        } else {
            token1Amount = _getTerminalTokensOutForProjectTokensIn({
                projectId: projectId, terminalToken: terminalToken, projectTokenInAmount: token0Amount
            });
        }

        return uint160(mulDiv({x: sqrt(token1Amount), y: _Q96, denominator: sqrt(token0Amount)}));
    }

    /// @notice For given projectToken amount, compute equivalent terminalToken amount at current JuiceboxV4 price
    // slither-disable-next-line unused-return
    function _getTerminalTokensOutForProjectTokensIn(
        uint256 projectId,
        address terminalToken,
        uint256 projectTokenInAmount
    )
        internal
        view
        returns (uint256 terminalTokenOutAmount)
    {
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        address terminal =
            address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        JBAccountingContext memory context =
            IJBMultiTerminal(terminal).accountingContextForTokenOf({projectId: projectId, token: terminalToken});

        uint32 baseCurrency = ruleset.baseCurrency();

        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES()
                .pricePerUnitOf({
                    projectId: projectId,
                    pricingCurrency: context.currency,
                    unitCurrency: baseCurrency,
                    decimals: context.decimals
                });

        terminalTokenOutAmount = mulDiv({x: projectTokenInAmount, y: weightRatio, denominator: ruleset.weight});
    }

    /// @notice Get token decimals, defaulting to 18 if unavailable
    function _getTokenDecimals(address token) internal view returns (uint8 decimals) {
        if (_isNativeToken(token)) {
            return 18;
        }
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            return 18;
        }
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Claim fee tokens for a beneficiary.
    /// @dev Requires SET_BUYBACK_POOL permission from the project owner.
    function claimFeeTokensFor(uint256 projectId, address beneficiary) external {
        _requirePermissionFrom({
            account: IJBDirectory(DIRECTORY).PROJECTS().ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        uint256 claimableAmount = claimableFeeTokens[projectId];
        claimableFeeTokens[projectId] = 0;

        if (claimableAmount > 0) {
            // Look up the fee project's ERC-20 token (e.g. JBX for project ID 1).
            address feeProjectToken = address(IJBTokens(TOKENS).tokenOf(FEE_PROJECT_ID));

            // Release these tokens from the segregated fee-token reserve.
            _totalOutstandingFeeTokenClaims[feeProjectToken] -= claimableAmount;

            // Transfer the claimed fee tokens to the beneficiary.
            IERC20(feeProjectToken).safeTransfer({to: beneficiary, value: claimableAmount});

            emit FeeTokensClaimed(projectId, beneficiary, claimableAmount);
        }
    }

    /// @notice Collect LP fees and route them back to the project
    // forge-lint: disable-next-line(mixed-case-function)
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external {
        uint256 tokenId = tokenIdOf[projectId][terminalToken];
        if (tokenId == 0) revert JBUniswapV4LPSplitHook_InvalidStageForAction();

        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));
        PoolKey memory key = _poolKeys[projectId][terminalToken];

        // Track balances before fee collection
        uint256 bal0Before = _currencyBalance(key.currency0);
        uint256 bal1Before = _currencyBalance(key.currency1);

        // Collect fees: DECREASE_LIQUIDITY with 0 liquidity + TAKE_PAIR
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), "");
        params[1] = abi.encode(key.currency0, key.currency1, address(this));

        // slither-disable-next-line reentrancy-events,reentrancy-no-eth
        POSITION_MANAGER.modifyLiquidities({
            unlockData: abi.encode(actions, params), deadline: block.timestamp + _DEADLINE_SECONDS
        });

        // Calculate collected amounts
        uint256 amount0 = _currencyBalance(key.currency0) - bal0Before;
        uint256 amount1 = _currencyBalance(key.currency1) - bal1Before;

        // Burn project tokens BEFORE routing terminal token fees. This ordering is intentional:
        // _routeCollectedFees → _routeFeesToProject → terminal.pay() can trigger pay hooks that
        // re-enter this contract. By burning first, a re-entrant _burnReceivedTokens finds zero
        // burnable balance, preventing double-burns without needing a reentrancy guard.
        // slither-disable-next-line reentrancy-events,reentrancy-no-eth
        _burnReceivedTokens({projectId: projectId, projectToken: projectToken});

        // Route terminal token fees back to the project (may call terminal.pay() externally).
        // slither-disable-next-line reentrancy-events,reentrancy-no-eth
        _routeCollectedFees({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            amount0: amount0,
            amount1: amount1
        });
    }

    /// @notice Deploy a Uniswap V4 pool for a project using accumulated tokens
    // slither-disable-next-line reentrancy-benign,reentrancy-events,unused-return
    function deployPool(uint256 projectId, address terminalToken, uint256 minCashOutReturn) external {
        // Allow anyone to deploy if the current ruleset's weight has decayed 10x from the initial weight.
        // Otherwise, require SET_BUYBACK_POOL permission from the project owner.
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        uint256 initialWeight = initialWeightOf[projectId];

        if (initialWeight == 0 || ruleset.weight * 10 > initialWeight) {
            _requirePermissionFrom({
                account: IJBDirectory(DIRECTORY).PROJECTS().ownerOf(projectId),
                projectId: projectId,
                permissionId: JBPermissionIds.SET_BUYBACK_POOL
            });
        }

        if (tokenIdOf[projectId][terminalToken] != 0) revert JBUniswapV4LPSplitHook_PoolAlreadyDeployed();
        if (deployedPoolCount[projectId] != 0) revert JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported();

        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];

        if (projectTokenBalance == 0) revert JBUniswapV4LPSplitHook_NoTokensAccumulated();

        address terminal =
            address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        if (terminal == address(0)) revert JBUniswapV4LPSplitHook_InvalidTerminalToken();

        // Flip the project into post-deploy burn mode before any external calls so reentrancy cannot
        // observe the project as still being in accumulation mode.
        deployedPoolCount[projectId]++;

        _deployPoolAndAddLiquidity({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            minCashOutReturn: minCashOutReturn
        });

        emit ProjectDeployed(projectId, terminalToken, PoolId.unwrap(_poolKeys[projectId][terminalToken].toId()));
    }

    /// @notice IJBSplitHook: called by JuiceboxV4 controller when sending funds to designated split hook
    // slither-disable-next-line unused-return
    function processSplitWith(JBSplitHookContext calldata context) external payable {
        if (address(context.split.hook) != address(this)) revert JBUniswapV4LPSplitHook_NotHookSpecifiedInContext();

        address controller = address(IJBDirectory(DIRECTORY).controllerOf(context.projectId));
        if (controller == address(0)) revert JBUniswapV4LPSplitHook_InvalidProjectId();
        if (controller != msg.sender) revert JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal();

        if (context.groupId != 1) revert JBUniswapV4LPSplitHook_TerminalTokensNotAllowed();

        address projectToken = context.token;

        if (deployedPoolCount[context.projectId] == 0) {
            // Record the initial weight on first accumulation.
            if (initialWeightOf[context.projectId] == 0) {
                (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(context.projectId);
                initialWeightOf[context.projectId] = ruleset.weight;
            }
            _accumulateTokens({projectId: context.projectId, amount: context.amount});

            // This hook requires an ERC-20 project token — credits cannot be paired as LP.
            if (projectToken == address(0)) revert JBUniswapV4LPSplitHook_InvalidProjectId();

            // Defense-in-depth: verify actual ERC-20 balance covers accumulated total.
            // The standard controller transfers tokens before calling processSplitWith,
            // but custom controllers may not — this guards against accounting drift.
            if (IERC20(projectToken).balanceOf(address(this)) < accumulatedProjectTokens[context.projectId]) {
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
            account: IJBDirectory(DIRECTORY).PROJECTS().ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        address terminal =
            address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        if (terminal == address(0)) revert JBUniswapV4LPSplitHook_InvalidTerminalToken();

        uint256 tokenId = tokenIdOf[projectId][terminalToken];
        if (tokenId == 0) revert JBUniswapV4LPSplitHook_InvalidStageForAction();

        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));
        PoolKey memory key = _poolKeys[projectId][terminalToken];

        _collectAndRouteFees({
            projectId: projectId, projectToken: projectToken, terminalToken: terminalToken, tokenId: tokenId, key: key
        });

        _burnExistingPosition({
            tokenId: tokenId, key: key, decreaseAmount0Min: decreaseAmount0Min, decreaseAmount1Min: decreaseAmount1Min
        });

        _mintRebalancedPosition({
            projectId: projectId, projectToken: projectToken, terminalToken: terminalToken, key: key
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

        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: token}));
        if (terminal == address(0)) return;

        if (!isNative) {
            IERC20(token).forceApprove({spender: terminal, value: amount});
        }

        IJBMultiTerminal(terminal).addToBalanceOf{value: isNative ? amount : 0}({
            projectId: projectId, token: token, amount: amount, shouldReturnHeldFees: false, memo: "", metadata: ""
        });
    }

    /// @notice Add liquidity to a Uniswap V4 pool using accumulated tokens
    // slither-disable-next-line reentrancy-eth,reentrancy-benign,reentrancy-events,unused-return
    function _addUniswapLiquidity(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 minCashOutReturn
    )
        internal
    {
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];

        if (projectTokenBalance == 0) return;

        (int24 tickLower, int24 tickUpper) =
            _calculateTickBounds({projectId: projectId, terminalToken: terminalToken, projectToken: projectToken});

        // Read the pool's actual current price. The pool may have been initialized by another party
        // (e.g. REVDeployer) at a different price than _computeInitialSqrtPrice would return.
        PoolKey memory key = _poolKeys[projectId][terminalToken];
        (uint160 sqrtPriceInit,,,) = POOL_MANAGER.getSlot0(key.toId());

        uint256 cashOutAmount = _computeOptimalCashOutAmount({
            projectId: projectId,
            terminalToken: terminalToken,
            projectToken: projectToken,
            totalProjectTokens: projectTokenBalance,
            sqrtPriceInit: sqrtPriceInit,
            tickLower: tickLower,
            tickUpper: tickUpper
        });

        // Cash out the computed fraction to get terminal tokens for pairing
        address terminal =
            address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));

        uint256 terminalTokenBalanceBefore = _getTerminalTokenBalance(terminalToken);

        if (terminal != address(0) && cashOutAmount > 0) {
            uint256 effectiveMinReturn = minCashOutReturn;
            if (effectiveMinReturn == 0 && cashOutAmount > 0) {
                uint256 cashOutRate = _getCashOutRate({projectId: projectId, terminalToken: terminalToken});
                if (cashOutRate > 0) {
                    uint256 expectedReturn = mulDiv({x: cashOutAmount, y: cashOutRate, denominator: _WAD});
                    effectiveMinReturn = mulDiv({
                        x: expectedReturn, y: _CASH_OUT_SLIPPAGE_NUMERATOR, denominator: _CASH_OUT_SLIPPAGE_DENOMINATOR
                    });
                }
            }

            IJBMultiTerminal(terminal)
                .cashOutTokensOf({
                    holder: address(this),
                    projectId: projectId,
                    cashOutCount: cashOutAmount,
                    tokenToReclaim: terminalToken,
                    minTokensReclaimed: effectiveMinReturn,
                    beneficiary: payable(address(this)),
                    metadata: ""
                });
        }

        // Get balances after cash out, excluding tokens reserved for outstanding fee claims
        uint256 projectTokenAmount =
            IERC20(projectToken).balanceOf(address(this)) - _totalOutstandingFeeTokenClaims[projectToken];
        uint256 terminalTokenAmount = _getTerminalTokenBalance(terminalToken) - terminalTokenBalanceBefore;

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
        if (liquidity == 0) revert JBUniswapV4LPSplitHook_ZeroLiquidity();

        // Record tokenId before minting. tokenIdOf is set after the external _mintPosition call
        // because nextTokenId() must be captured before the mint increments it. This ordering is safe:
        // the caller (deployPool) checks tokenIdOf == 0 as a guard before entering this function,
        // so reentering deployPool would revert with PoolAlreadyDeployed once tokenIdOf is nonzero.
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        _mintPosition({
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            amount0: amount0,
            amount1: amount1
        });

        tokenIdOf[projectId][terminalToken] = tokenId;

        // Handle leftover tokens
        _handleLeftoverTokens({projectId: projectId, projectToken: projectToken, terminalToken: terminalToken});

        // Clear accumulated balances after successful LP creation
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

        POSITION_MANAGER.modifyLiquidities({
            unlockData: abi.encode(burnActions, burnParams), deadline: block.timestamp + _DEADLINE_SECONDS
        });
    }

    /// @notice Burn project tokens using the controller
    // slither-disable-next-line incorrect-equality,reentrancy-events
    function _burnProjectTokens(uint256 projectId, address projectToken, uint256 amount, string memory memo) internal {
        if (amount == 0) return;

        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
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
            IERC20(projectToken).balanceOf(address(this)) - _totalOutstandingFeeTokenClaims[projectToken];

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

    /// @notice Calculate tick bounds for liquidity position based on issuance and cash out rates
    function _calculateTickBounds(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        internal
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        // Check if the cash out rate can be computed (may round to 0 with low-decimal tokens like USDC).
        uint256 cashOutRate = _getCashOutRate({projectId: projectId, terminalToken: terminalToken});

        if (cashOutRate == 0) {
            // Cash out rate rounds to 0 due to precision loss (e.g. 6-decimal USDC with large token supply).
            // Center the LP range around the issuance price with minimal width.
            int24 issuanceTick = TickMath.getTickAtSqrtPrice(
                _getIssuanceRateSqrtPriceX96({
                    projectId: projectId, terminalToken: terminalToken, projectToken: projectToken
                })
            );
            issuanceTick = _alignTickToSpacing({tick: issuanceTick, spacing: TICK_SPACING});
            tickLower = issuanceTick - TICK_SPACING;
            tickUpper = issuanceTick + TICK_SPACING;
            return (tickLower, tickUpper);
        }

        int24 rawTickA = TickMath.getTickAtSqrtPrice(
            _getCashOutRateSqrtPriceX96({
                projectId: projectId, terminalToken: terminalToken, projectToken: projectToken
            })
        );
        int24 rawTickB = TickMath.getTickAtSqrtPrice(
            _getIssuanceRateSqrtPriceX96({
                projectId: projectId, terminalToken: terminalToken, projectToken: projectToken
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
                projectId: projectId, terminalToken: terminalToken, projectToken: projectToken
            });
            int24 currentTick = TickMath.getTickAtSqrtPrice(currentSqrtPrice);
            currentTick = _alignTickToSpacing({tick: currentTick, spacing: TICK_SPACING});
            tickLower = currentTick - TICK_SPACING;
            tickUpper = currentTick + TICK_SPACING;
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

        POSITION_MANAGER.modifyLiquidities({
            unlockData: abi.encode(feeActions, feeParams), deadline: block.timestamp + _DEADLINE_SECONDS
        });

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

    /// @notice Compute the initial sqrtPriceX96 for pool initialization
    function _computeInitialSqrtPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken
    )
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        uint256 cashOutRate = _getCashOutRate({projectId: projectId, terminalToken: terminalToken});

        if (cashOutRate == 0) {
            return _getIssuanceRateSqrtPriceX96({
                projectId: projectId, terminalToken: terminalToken, projectToken: projectToken
            });
        }

        uint160 sqrtPriceCashOut = _getCashOutRateSqrtPriceX96({
            projectId: projectId, terminalToken: terminalToken, projectToken: projectToken
        });
        uint160 sqrtPriceIssuance = _getIssuanceRateSqrtPriceX96({
            projectId: projectId, terminalToken: terminalToken, projectToken: projectToken
        });

        int24 tickCashOut = TickMath.getTickAtSqrtPrice(sqrtPriceCashOut);
        int24 tickIssuance = TickMath.getTickAtSqrtPrice(sqrtPriceIssuance);

        int24 tickLower = tickCashOut < tickIssuance ? tickCashOut : tickIssuance;
        int24 tickUpper = tickCashOut < tickIssuance ? tickIssuance : tickCashOut;

        if (tickLower == tickUpper) {
            return sqrtPriceIssuance;
        }

        int24 tickMid = _alignTickToSpacing({tick: (tickLower + tickUpper) / 2, spacing: TICK_SPACING});

        int24 minTick = TickMath.MIN_TICK;
        int24 maxTick = TickMath.MAX_TICK;
        if (tickMid < minTick) tickMid = _alignTickToSpacing({tick: minTick, spacing: TICK_SPACING}) + TICK_SPACING;
        if (tickMid > maxTick) tickMid = _alignTickToSpacing({tick: maxTick, spacing: TICK_SPACING}) - TICK_SPACING;

        return TickMath.getSqrtPriceAtTick(tickMid);
    }

    /// @notice Compute optimal cash-out amount based on LP position geometry
    function _computeOptimalCashOutAmount(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        uint256 totalProjectTokens,
        uint160 sqrtPriceInit,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        view
        returns (uint256 cashOutAmount)
    {
        uint256 cashOutRate = _getCashOutRate({projectId: projectId, terminalToken: terminalToken});

        if (cashOutRate == 0) return 0;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        Currency terminalCurrency = _toCurrency(terminalToken);
        bool terminalIsToken0 = Currency.unwrap(terminalCurrency) < projectToken;

        uint256 numerator;
        uint256 denominator;

        if (uint160(sqrtPriceInit) <= sqrtPriceA) {
            return totalProjectTokens / 2;
        }
        if (uint160(sqrtPriceInit) >= sqrtPriceB) {
            return 0;
        }

        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 diffPriceInit_A = uint256(sqrtPriceInit) - uint256(sqrtPriceA);
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 diffB_PriceInit = uint256(sqrtPriceB) - uint256(sqrtPriceInit);

        if (terminalIsToken0) {
            numerator = mulDiv({x: diffPriceInit_A, y: uint256(sqrtPriceB), denominator: diffB_PriceInit});
            denominator = uint256(sqrtPriceInit);
        } else {
            numerator = mulDiv({x: uint256(sqrtPriceInit), y: diffPriceInit_A, denominator: diffB_PriceInit});
            denominator = 1;
        }

        uint256 ratioE18;
        if (terminalIsToken0) {
            ratioE18 = mulDiv({x: numerator, y: _WAD, denominator: denominator});
        } else {
            ratioE18 = mulDiv({x: numerator, y: _WAD, denominator: 1});
        }

        if (ratioE18 == 0) return 0;

        uint256 denom = cashOutRate + ratioE18;
        if (denom == 0) return 0;

        cashOutAmount = mulDiv({x: totalProjectTokens, y: ratioE18, denominator: denom});

        uint256 maxCashOut = totalProjectTokens / 2;
        if (cashOutAmount > maxCashOut) cashOutAmount = maxCashOut;
    }

    /// @notice Create and initialize Uniswap V4 pool
    // slither-disable-next-line reentrancy-benign,reentrancy-events,unused-return
    function _createAndInitializePool(
        uint256 projectId,
        address projectToken,
        address terminalToken
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
        uint160 sqrtPriceX96 =
            _computeInitialSqrtPrice({projectId: projectId, terminalToken: terminalToken, projectToken: projectToken});

        // Initialize pool (safe if already exists — returns type(int24).max)
        POSITION_MANAGER.initializePool({key: key, sqrtPriceX96: sqrtPriceX96});

        // Store the pool key
        _poolKeys[projectId][terminalToken] = key;
    }

    /// @notice Get balance of a currency held by this contract
    function _currencyBalance(Currency currency) internal view returns (uint256) {
        if (currency.isAddressZero()) {
            return address(this).balance;
        }
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /// @notice Deploy pool and add liquidity using accumulated tokens
    // slither-disable-next-line reentrancy-events
    function _deployPoolAndAddLiquidity(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 minCashOutReturn
    )
        internal
    {
        if (tokenIdOf[projectId][terminalToken] == 0) {
            _createAndInitializePool({projectId: projectId, projectToken: projectToken, terminalToken: terminalToken});
        }

        _addUniswapLiquidity({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            minCashOutReturn: minCashOutReturn
        });
    }

    /// @notice Get terminal token balance held by this contract
    function _getTerminalTokenBalance(address terminalToken) internal view returns (uint256) {
        if (_isNativeToken(terminalToken)) {
            return address(this).balance;
        }
        return IERC20(terminalToken).balanceOf(address(this));
    }

    /// @notice Handle leftover tokens after V4 mint operation
    function _handleLeftoverTokens(uint256 projectId, address projectToken, address terminalToken) internal {
        // Burn any remaining project tokens, excluding tokens reserved for outstanding fee claims
        uint256 projectTokenLeftover =
            IERC20(projectToken).balanceOf(address(this)) - _totalOutstandingFeeTokenClaims[projectToken];
        if (projectTokenLeftover > 0) {
            _burnProjectTokens({
                projectId: projectId,
                projectToken: projectToken,
                amount: projectTokenLeftover,
                memo: "Burning leftover project tokens"
            });
        }

        // Add any remaining terminal tokens to project balance
        uint256 terminalTokenLeftover = _getTerminalTokenBalance(terminalToken);
        if (terminalTokenLeftover > 0) {
            _addToProjectBalance({
                projectId: projectId,
                token: terminalToken,
                amount: terminalTokenLeftover,
                isNative: _isNativeToken(terminalToken)
            });
        }
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

        POSITION_MANAGER.modifyLiquidities{value: ethValue}({
            unlockData: abi.encode(actions, params), deadline: block.timestamp + _DEADLINE_SECONDS
        });
    }

    /// @notice Mint a new LP position with tick bounds recalculated from current issuance and cash-out rates.
    /// @dev Called after `_burnExistingPosition` has recovered the old position's principal. Computes liquidity from
    /// this contract's current token balances and the pool's live `sqrtPriceX96`. Reverts with
    /// `JBUniswapV4LPSplitHook_InsufficientLiquidity` if the resulting liquidity is zero (e.g. price moved entirely
    /// outside the new tick range), preventing `tokenIdOf` from being left stale. Any leftover tokens after minting
    /// are routed back to the project via `_handleLeftoverTokens`.
    /// @param projectId The ID of the Juicebox project being rebalanced.
    /// @param projectToken The project's ERC-20 token address.
    /// @param terminalToken The terminal token paired with the project token.
    /// @param key The pool key identifying the Uniswap V4 pool.
    // slither-disable-next-line reentrancy-eth,reentrancy-benign,reentrancy-events
    function _mintRebalancedPosition(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        PoolKey memory key
    )
        internal
    {
        uint256 projectTokenBalance = IERC20(projectToken).balanceOf(address(this));
        uint256 terminalTokenBalance = _getTerminalTokenBalance(terminalToken);

        (int24 tickLower, int24 tickUpper) =
            _calculateTickBounds({projectId: projectId, terminalToken: terminalToken, projectToken: projectToken});

        // Use the actual pool price for liquidity calculation so the target matches the pool's
        // current state. Using JB issuance price here would produce suboptimal liquidity when the
        // pool price has diverged.
        // slither-disable-next-line unused-return
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
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
            uint256 newTokenId = POSITION_MANAGER.nextTokenId();

            _mintPosition({
                key: key,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                amount0: amount0,
                amount1: amount1
            });

            tokenIdOf[projectId][terminalToken] = newTokenId;
        } else {
            // Zero liquidity means the position cannot be re-created (e.g., price moved
            // outside tick range making the position single-sided with zero on one side).
            // Revert to prevent bricking the project's LP — the old position was already
            // burned by the BURN_POSITION action above, so this protects the invariant
            // that tokenIdOf is always nonzero for deployed projects.
            revert JBUniswapV4LPSplitHook_InsufficientLiquidity();
        }

        // Return any dust left over after minting (due to rounding or single-sided excess) to the project.
        _handleLeftoverTokens({projectId: projectId, projectToken: projectToken, terminalToken: terminalToken});
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

    /// @notice Route fees back to the project
    /// @dev Fee routing uses zero slippage (minReturnedTokens = 0) by design. Fees are small amounts
    /// routed to the protocol fee project. MEV extraction on fee amounts is economically insignificant relative to gas
    /// costs. Adding slippage would require an oracle and add complexity for minimal benefit.
    // slither-disable-next-line arbitrary-send-eth,reentrancy-eth,reentrancy-benign,reentrancy-events,incorrect-equality,unused-return
    function _routeFeesToProject(uint256 projectId, address terminalToken, uint256 amount) internal {
        if (amount == 0) return;

        uint256 feeAmount = (amount * FEE_PERCENT) / BPS;
        uint256 remainingAmount = amount - feeAmount;

        uint256 beneficiaryTokenCount = 0;
        if (feeAmount > 0) {
            address feeTerminal =
                address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: FEE_PROJECT_ID, token: terminalToken}));
            // If no fee terminal is set, fee tokens are stranded in the contract. This is accepted
            // behavior — the fee project owner can set a terminal later and trigger fee collection.
            if (feeTerminal != address(0)) {
                // Track fee tokens only if the fee project has an ERC20 deployed.
                // If tokenOf returns address(0), the fee project uses internal credits only —
                // the terminal payment still routes value via credits, but we skip balance tracking
                // to avoid reverting on IERC20(address(0)).balanceOf().
                address feeProjectToken = address(IJBTokens(TOKENS).tokenOf(FEE_PROJECT_ID));
                uint256 feeTokensBefore =
                    feeProjectToken != address(0) ? IERC20(feeProjectToken).balanceOf(address(this)) : 0;

                // Fee terminal revert blocks fee collection — accepted since the fee project is
                // protocol-controlled and expected to maintain a functioning terminal.
                // minReturnedTokens is 0 by design: slippage protection is the fee project's
                // responsibility (via its own data hook / buyback hook), not this contract's.
                // Setting a floor here would risk reverting on small fee amounts where
                // mulDiv rounding yields 0 tokens, and any non-trivial floor would require
                // an oracle dependency that doesn't belong in the LP split hook.
                // See RISKS.md §8.1.
                if (_isNativeToken(terminalToken)) {
                    IJBMultiTerminal(feeTerminal).pay{value: feeAmount}({
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
                    IJBMultiTerminal(feeTerminal)
                        .pay({
                            projectId: FEE_PROJECT_ID,
                            token: terminalToken,
                            amount: feeAmount,
                            beneficiary: address(this),
                            minReturnedTokens: 0,
                            memo: "LP Fee",
                            metadata: ""
                        });
                }

                if (feeProjectToken != address(0)) {
                    uint256 feeTokensAfter = IERC20(feeProjectToken).balanceOf(address(this));
                    beneficiaryTokenCount = feeTokensAfter > feeTokensBefore ? feeTokensAfter - feeTokensBefore : 0;

                    claimableFeeTokens[projectId] += beneficiaryTokenCount;

                    // Track the total fee tokens held across all projects so that _burnReceivedTokens
                    // and _handleLeftoverTokens can exclude them from burnable balances.
                    _totalOutstandingFeeTokenClaims[feeProjectToken] += beneficiaryTokenCount;
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
