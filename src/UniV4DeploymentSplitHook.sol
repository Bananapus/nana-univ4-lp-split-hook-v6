// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IJBController} from "@bananapus/core/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core/interfaces/IJBPermissions.sol";
import {JBPermissioned} from "@bananapus/core/abstract/JBPermissioned.sol";
import {IJBSplitHook} from "@bananapus/core/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core/libraries/JBRulesetMetadataResolver.sol";
import {JBSplitHookContext} from "@bananapus/core/structs/JBSplitHookContext.sol";
import {JBConstants} from "@bananapus/core/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv, sqrt} from "@prb/math/src/Common.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {JBPermissionIds} from "@bananapus/permission-ids/JBPermissionIds.sol";
import {IUniV4DeploymentSplitHook} from "./interfaces/IUniV4DeploymentSplitHook.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/**
 * @title UniV4DeploymentSplitHook
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
contract UniV4DeploymentSplitHook is IUniV4DeploymentSplitHook, IJBSplitHook, JBPermissioned {
    using JBRulesetMetadataResolver for JBRuleset;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error UniV4DeploymentSplitHook_ZeroAddressNotAllowed();
    error UniV4DeploymentSplitHook_InvalidProjectId();
    error UniV4DeploymentSplitHook_NotHookSpecifiedInContext();
    error UniV4DeploymentSplitHook_SplitSenderNotValidControllerOrTerminal();
    error UniV4DeploymentSplitHook_NoTokensAccumulated();
    error UniV4DeploymentSplitHook_InvalidStageForAction();
    error UniV4DeploymentSplitHook_TerminalTokensNotAllowed();
    error UniV4DeploymentSplitHook_InvalidFeePercent();
    error UniV4DeploymentSplitHook_InvalidTerminalToken();
    error UniV4DeploymentSplitHook_PoolAlreadyDeployed();
    error UniV4DeploymentSplitHook_AlreadyInitialized();
    error UniV4DeploymentSplitHook_FeePercentWithoutFeeProject();

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
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice JBDirectory (to find important control contracts for given projectId)
    address public immutable DIRECTORY;

    /// @notice JBTokens (to find project tokens)
    address public immutable TOKENS;

    /// @notice Uniswap V4 PoolManager address
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Uniswap V4 PositionManager address
    IPositionManager public immutable POSITION_MANAGER;

    /// @notice Project ID to receive LP fees
    uint256 public FEE_PROJECT_ID;

    /// @notice Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
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

    /// @notice ProjectID => whether any pool has been deployed for this project
    mapping(uint256 projectId => bool deployed) public projectDeployed;

    /// @notice ProjectID => Fee tokens claimable by that project
    mapping(uint256 projectId => uint256 claimableFeeTokens) public claimableFeeTokens;

    /// @notice Whether this clone instance has been initialized.
    bool public initialized;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory JBDirectory address
    /// @param permissions JBPermissions address
    /// @param tokens JBTokens address
    /// @param poolManager Uniswap V4 PoolManager address
    /// @param positionManager Uniswap V4 PositionManager address
    constructor(
        address directory,
        IJBPermissions permissions,
        address tokens,
        IPoolManager poolManager,
        IPositionManager positionManager
    )
        JBPermissioned(permissions)
    {
        if (directory == address(0)) revert UniV4DeploymentSplitHook_ZeroAddressNotAllowed();
        if (tokens == address(0)) revert UniV4DeploymentSplitHook_ZeroAddressNotAllowed();
        if (address(poolManager) == address(0)) revert UniV4DeploymentSplitHook_ZeroAddressNotAllowed();
        if (address(positionManager) == address(0)) revert UniV4DeploymentSplitHook_ZeroAddressNotAllowed();

        DIRECTORY = directory;
        TOKENS = tokens;
        POOL_MANAGER = poolManager;
        POSITION_MANAGER = positionManager;
    }

    /// @notice Initialize per-instance config on a clone. Can only be called once.
    /// @param feeProjectId Project ID to receive LP fees.
    /// @param feePercent Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%).
    function initialize(uint256 feeProjectId, uint256 feePercent) external {
        if (initialized) revert UniV4DeploymentSplitHook_AlreadyInitialized();

        if (feePercent > BPS) revert UniV4DeploymentSplitHook_InvalidFeePercent();

        // If fees are configured, a valid fee project must be specified — otherwise fee tokens get stuck
        // because primaryTerminalOf(0, token) returns address(0).
        if (feePercent > 0 && feeProjectId == 0) revert UniV4DeploymentSplitHook_FeePercentWithoutFeeProject();

        if (feeProjectId != 0) {
            address feeController = address(IJBDirectory(DIRECTORY).controllerOf(feeProjectId));
            if (feeController == address(0)) revert UniV4DeploymentSplitHook_InvalidProjectId();
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
        return
            interfaceId == type(IUniV4DeploymentSplitHook).interfaceId || interfaceId == type(IJBSplitHook).interfaceId;
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

    /// @notice For given terminalToken amount, compute equivalent projectToken amount at current JuiceboxV4 price
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

        projectTokenOutAmount = mulDiv(terminalTokenInAmount, ruleset.weight, weightRatio);
    }

    /// @notice For given projectToken amount, compute equivalent terminalToken amount at current JuiceboxV4 price
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

        terminalTokenOutAmount = mulDiv(projectTokenInAmount, weightRatio, ruleset.weight);
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
        (address token0,) = _sortTokens(terminalToken, projectToken);

        uint256 token0Amount = 10 ** 18;
        uint256 token1Amount;

        if (token0 == terminalToken) {
            token1Amount = _getProjectTokensOutForTerminalTokensIn(projectId, terminalToken, token0Amount);
        } else {
            token1Amount = _getTerminalTokensOutForProjectTokensIn(projectId, terminalToken, token0Amount);
        }

        return uint160(mulDiv(sqrt(token1Amount), 2 ** 96, sqrt(token0Amount)));
    }

    /// @notice Calculate the issuance rate (price ceiling)
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

        uint256 tokensPerTerminalToken = _getProjectTokensOutForTerminalTokensIn(projectId, terminalToken, 10 ** 18);

        if (reservedPercent > 0) {
            projectTokensPerTerminalToken = mulDiv(
                tokensPerTerminalToken,
                uint256(JBConstants.MAX_RESERVED_PERCENT - reservedPercent),
                uint256(JBConstants.MAX_RESERVED_PERCENT)
            );
        } else {
            projectTokensPerTerminalToken = tokensPerTerminalToken;
        }
    }

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
            .currentReclaimableSurplusOf({
                projectId: projectId,
                cashOutCount: 10 ** 18,
                terminals: new IJBTerminal[](0),
                accountingContexts: new JBAccountingContext[](0),
                decimals: _getTokenDecimals(terminalToken),
                currency: uint256(uint160(terminalToken))
            }) returns (
            uint256 reclaimableAmount
        ) {
            terminalTokensPerProjectToken = reclaimableAmount;
        } catch {
            terminalTokensPerProjectToken = 0;
        }
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
        (address token0,) = _sortTokens(terminalToken, projectToken);

        uint256 projectTokensPerTerminalToken = _getIssuanceRate(projectId, terminalToken);

        uint256 token0Amount = 10 ** 18;
        uint256 token1Amount;

        if (token0 == terminalToken) {
            token1Amount = projectTokensPerTerminalToken;
        } else {
            token1Amount = mulDiv(token0Amount, 10 ** 18, projectTokensPerTerminalToken);
        }

        return uint160(mulDiv(sqrt(token1Amount), 2 ** 96, sqrt(token0Amount)));
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
        (address token0,) = _sortTokens(terminalToken, projectToken);

        uint256 terminalTokensPerProjectToken = _getCashOutRate(projectId, terminalToken);

        uint256 token0Amount = 10 ** 18;
        uint256 token1Amount;

        if (token0 == terminalToken) {
            token1Amount = mulDiv(token0Amount, 10 ** 18, terminalTokensPerProjectToken);
        } else {
            token1Amount = terminalTokensPerProjectToken;
        }

        return uint160(mulDiv(sqrt(token1Amount), 2 ** 96, sqrt(token0Amount)));
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
            address feeProjectToken = address(IJBTokens(TOKENS).tokenOf(FEE_PROJECT_ID));
            IERC20(feeProjectToken).safeTransfer(beneficiary, claimableAmount);
            emit FeeTokensClaimed(projectId, beneficiary, claimableAmount);
        }
    }

    /// @notice Collect LP fees and route them back to the project
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external {
        uint256 tokenId = tokenIdOf[projectId][terminalToken];
        if (tokenId == 0) revert UniV4DeploymentSplitHook_InvalidStageForAction();

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

        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        // Calculate collected amounts
        uint256 amount0 = _currencyBalance(key.currency0) - bal0Before;
        uint256 amount1 = _currencyBalance(key.currency1) - bal1Before;

        // Route terminal token fees back to the project
        _routeCollectedFees(projectId, projectToken, terminalToken, amount0, amount1);

        // Burn collected project token fees
        _burnReceivedTokens(projectId, projectToken);
    }

    /// @notice Deploy a Uniswap V4 pool for a project using accumulated tokens
    function deployPool(
        uint256 projectId,
        address terminalToken,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minCashOutReturn
    )
        external
    {
        _requirePermissionFrom({
            account: IJBDirectory(DIRECTORY).PROJECTS().ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        if (tokenIdOf[projectId][terminalToken] != 0) revert UniV4DeploymentSplitHook_PoolAlreadyDeployed();

        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];

        if (projectTokenBalance == 0) revert UniV4DeploymentSplitHook_NoTokensAccumulated();

        address terminal =
            address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        if (terminal == address(0)) revert UniV4DeploymentSplitHook_InvalidTerminalToken();

        _deployPoolAndAddLiquidity(projectId, projectToken, terminalToken, amount0Min, amount1Min, minCashOutReturn);

        projectDeployed[projectId] = true;

        emit ProjectDeployed(projectId, terminalToken, PoolId.unwrap(_poolKeys[projectId][terminalToken].toId()));
    }

    /// @notice Rebalance LP position to match current issuance and cash out rates
    function rebalanceLiquidity(
        uint256 projectId,
        address terminalToken,
        uint256 decreaseAmount0Min,
        uint256 decreaseAmount1Min,
        uint256 increaseAmount0Min,
        uint256 increaseAmount1Min
    )
        external
    {
        address terminal =
            address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        if (terminal == address(0)) revert UniV4DeploymentSplitHook_InvalidTerminalToken();

        uint256 tokenId = tokenIdOf[projectId][terminalToken];
        if (tokenId == 0) revert UniV4DeploymentSplitHook_InvalidStageForAction();

        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));
        PoolKey memory key = _poolKeys[projectId][terminalToken];

        // Step 1: Burn old position (removes all liquidity + collects fees) and take all tokens
        {
            bytes memory burnActions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));

            bytes[] memory burnParams = new bytes[](2);
            burnParams[0] = abi.encode(tokenId, uint128(decreaseAmount0Min), uint128(decreaseAmount1Min), "");
            burnParams[1] = abi.encode(key.currency0, key.currency1, address(this));

            POSITION_MANAGER.modifyLiquidities(abi.encode(burnActions, burnParams), block.timestamp + 60);
        }

        // Route any fees collected during burn
        {
            uint256 projectTokenBalance = IERC20(projectToken).balanceOf(address(this));
            uint256 terminalTokenBalance = _getTerminalTokenBalance(terminalToken);

            // Route fees from the old position
            _routeCollectedFees(
                projectId,
                projectToken,
                terminalToken,
                _getAmountForCurrency(key, projectToken, terminalToken, true),
                _getAmountForCurrency(key, projectToken, terminalToken, false)
            );
        }

        // Step 2: Mint new position with updated tick bounds
        {
            uint256 projectTokenBalance = IERC20(projectToken).balanceOf(address(this));
            uint256 terminalTokenBalance = _getTerminalTokenBalance(terminalToken);

            (int24 tickLower, int24 tickUpper) = _calculateTickBounds(projectId, terminalToken, projectToken);

            // Get current pool price for liquidity calculation
            uint160 sqrtPriceX96 = _getSqrtPriceX96ForCurrentJuiceboxPrice(projectId, terminalToken, projectToken);
            uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

            // Sort amounts by currency order
            Currency terminalCurrency = _toCurrency(terminalToken);
            (address token0,) = _sortTokens(projectToken, Currency.unwrap(terminalCurrency));
            uint256 amount0 = projectToken == token0 ? projectTokenBalance : terminalTokenBalance;
            uint256 amount1 = projectToken == token0 ? terminalTokenBalance : projectTokenBalance;

            // Calculate liquidity from amounts
            uint128 liquidity =
                LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtPriceA, sqrtPriceB, amount0, amount1);

            if (liquidity > 0) {
                uint256 newTokenId = POSITION_MANAGER.nextTokenId();

                _mintPosition(
                    key, tickLower, tickUpper, liquidity, amount0, amount1, increaseAmount0Min, increaseAmount1Min
                );

                tokenIdOf[projectId][terminalToken] = newTokenId;
            } else {
                // Old position was burned but no new position can be created.
                // Clear tokenIdOf so the position can be re-created via deployPool later,
                // rather than leaving a stale reference to a burned NFT.
                tokenIdOf[projectId][terminalToken] = 0;
            }

            // Handle leftover tokens
            _handleLeftoverTokens(projectId, projectToken, terminalToken);
        }
    }

    /// @notice IJBSplitHook: called by JuiceboxV4 controller when sending funds to designated split hook
    function processSplitWith(JBSplitHookContext calldata context) external payable {
        if (address(context.split.hook) != address(this)) revert UniV4DeploymentSplitHook_NotHookSpecifiedInContext();

        address controller = address(IJBDirectory(DIRECTORY).controllerOf(context.projectId));
        if (controller == address(0)) revert UniV4DeploymentSplitHook_InvalidProjectId();
        if (controller != msg.sender) revert UniV4DeploymentSplitHook_SplitSenderNotValidControllerOrTerminal();

        if (context.groupId != 1) revert UniV4DeploymentSplitHook_TerminalTokensNotAllowed();

        address projectToken = context.token;

        if (!projectDeployed[context.projectId]) {
            _accumulateTokens(context.projectId, projectToken, context.amount);
        } else {
            _burnReceivedTokens(context.projectId, projectToken);
        }
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Accumulate project tokens in accumulation stage
    function _accumulateTokens(uint256 projectId, address projectToken, uint256 amount) internal {
        accumulatedProjectTokens[projectId] += amount;
    }

    /// @notice Create and initialize Uniswap V4 pool
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
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // Compute initial price at geometric mean of [cashOutRate, issuanceRate]
        uint160 sqrtPriceX96 = _computeInitialSqrtPrice(projectId, terminalToken, projectToken);

        // Initialize pool (safe if already exists — returns type(int24).max)
        POSITION_MANAGER.initializePool(key, sqrtPriceX96);

        // Store the pool key
        _poolKeys[projectId][terminalToken] = key;
    }

    /// @notice Add liquidity to a Uniswap V4 pool using accumulated tokens
    function _addUniswapLiquidity(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minCashOutReturn
    )
        internal
    {
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];

        if (projectTokenBalance == 0) return;

        (int24 tickLower, int24 tickUpper) = _calculateTickBounds(projectId, terminalToken, projectToken);

        uint160 sqrtPriceInit = _computeInitialSqrtPrice(projectId, terminalToken, projectToken);

        uint256 cashOutAmount = _computeOptimalCashOutAmount(
            projectId, terminalToken, projectToken, projectTokenBalance, sqrtPriceInit, tickLower, tickUpper
        );

        // Cash out the computed fraction to get terminal tokens for pairing
        address terminal =
            address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));

        uint256 terminalTokenBalanceBefore = _getTerminalTokenBalance(terminalToken);

        if (terminal != address(0) && cashOutAmount > 0) {
            uint256 effectiveMinReturn = minCashOutReturn;
            if (effectiveMinReturn == 0 && cashOutAmount > 0) {
                uint256 cashOutRate = _getCashOutRate(projectId, terminalToken);
                if (cashOutRate > 0) {
                    uint256 expectedReturn = mulDiv(cashOutAmount, cashOutRate, 10 ** 18);
                    effectiveMinReturn = mulDiv(expectedReturn, 99, 100);
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

        // Get balances after cash out
        uint256 projectTokenAmount = IERC20(projectToken).balanceOf(address(this));
        uint256 terminalTokenAmount = _getTerminalTokenBalance(terminalToken) - terminalTokenBalanceBefore;

        PoolKey memory key = _poolKeys[projectId][terminalToken];

        // Sort amounts by currency order
        Currency terminalCurrency = _toCurrency(terminalToken);
        (address token0,) = _sortTokens(projectToken, Currency.unwrap(terminalCurrency));
        uint256 amount0 = projectToken == token0 ? projectTokenAmount : terminalTokenAmount;
        uint256 amount1 = projectToken == token0 ? terminalTokenAmount : projectTokenAmount;

        // Calculate liquidity from amounts
        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceInit, sqrtPriceA, sqrtPriceB, amount0, amount1);

        // Record tokenId before minting
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        _mintPosition(key, tickLower, tickUpper, liquidity, amount0, amount1, amount0Min, amount1Min);

        tokenIdOf[projectId][terminalToken] = tokenId;

        // Handle leftover tokens
        _handleLeftoverTokens(projectId, projectToken, terminalToken);

        // Clear accumulated balances after successful LP creation
        accumulatedProjectTokens[projectId] = 0;
    }

    /// @notice Mint a V4 position via PositionManager
    function _mintPosition(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Min,
        uint256 amount1Min
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
            IERC20(token0).forceApprove(address(POSITION_MANAGER), amount0);
        }

        if (token1 == address(0)) {
            // currency1 is native ETH (shouldn't happen since ETH is always currency0)
            ethValue = amount1;
        } else if (amount1 > 0) {
            IERC20(token1).forceApprove(address(POSITION_MANAGER), amount1);
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
            key, tickLower, tickUpper, uint256(liquidity), uint128(amount0), uint128(amount1), address(this), ""
        );
        // SETTLE currency0: payerIsUser=true means PositionManager pulls from msg.sender (this contract) via approve
        params[1] = abi.encode(key.currency0, uint256(0), true);
        // SETTLE currency1
        params[2] = abi.encode(key.currency1, uint256(0), true);
        // SWEEP leftover currency0 back to this contract
        params[3] = abi.encode(key.currency0, address(this));
        // SWEEP leftover currency1 back to this contract
        params[4] = abi.encode(key.currency1, address(this));

        POSITION_MANAGER.modifyLiquidities{value: ethValue}(abi.encode(actions, params), block.timestamp + 60);
    }

    /// @notice Burn received project tokens in deployment stage
    function _burnReceivedTokens(uint256 projectId, address projectToken) internal {
        uint256 projectTokenBalance = IERC20(projectToken).balanceOf(address(this));
        if (projectTokenBalance > 0) {
            _burnProjectTokens(projectId, projectToken, projectTokenBalance, "Burning additional tokens");
        }
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
        uint256 cashOutRate = _getCashOutRate(projectId, terminalToken);

        if (cashOutRate == 0) {
            return _getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken);
        }

        uint160 sqrtPriceCashOut = _getCashOutRateSqrtPriceX96(projectId, terminalToken, projectToken);
        uint160 sqrtPriceIssuance = _getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken);

        int24 tickCashOut = TickMath.getTickAtSqrtPrice(sqrtPriceCashOut);
        int24 tickIssuance = TickMath.getTickAtSqrtPrice(sqrtPriceIssuance);

        int24 tickLower = tickCashOut < tickIssuance ? tickCashOut : tickIssuance;
        int24 tickUpper = tickCashOut < tickIssuance ? tickIssuance : tickCashOut;

        if (tickLower == tickUpper) {
            return sqrtPriceIssuance;
        }

        int24 tickMid = _alignTickToSpacing((tickLower + tickUpper) / 2, TICK_SPACING);

        int24 minTick = TickMath.MIN_TICK;
        int24 maxTick = TickMath.MAX_TICK;
        if (tickMid < minTick) tickMid = _alignTickToSpacing(minTick, TICK_SPACING) + TICK_SPACING;
        if (tickMid > maxTick) tickMid = _alignTickToSpacing(maxTick, TICK_SPACING) - TICK_SPACING;

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
        uint256 cashOutRate = _getCashOutRate(projectId, terminalToken);

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

        uint256 diffPriceInit_A = uint256(sqrtPriceInit) - uint256(sqrtPriceA);
        uint256 diffB_PriceInit = uint256(sqrtPriceB) - uint256(sqrtPriceInit);

        if (terminalIsToken0) {
            numerator = mulDiv(diffPriceInit_A, uint256(sqrtPriceB), diffB_PriceInit);
            denominator = uint256(sqrtPriceInit);
        } else {
            numerator = mulDiv(uint256(sqrtPriceInit), diffPriceInit_A, diffB_PriceInit);
            denominator = 1;
        }

        uint256 ratioE18;
        if (terminalIsToken0) {
            ratioE18 = mulDiv(numerator, 10 ** 18, denominator);
        } else {
            ratioE18 = mulDiv(numerator, 10 ** 18, 1);
        }

        if (ratioE18 == 0) return 0;

        uint256 denom = cashOutRate + ratioE18;
        if (denom == 0) return 0;

        cashOutAmount = mulDiv(totalProjectTokens, ratioE18, denom);

        uint256 maxCashOut = totalProjectTokens / 2;
        if (cashOutAmount > maxCashOut) cashOutAmount = maxCashOut;
    }

    /// @notice Deploy pool and add liquidity using accumulated tokens
    function _deployPoolAndAddLiquidity(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minCashOutReturn
    )
        internal
    {
        if (tokenIdOf[projectId][terminalToken] == 0) {
            _createAndInitializePool(projectId, projectToken, terminalToken);
        }

        _addUniswapLiquidity(projectId, projectToken, terminalToken, amount0Min, amount1Min, minCashOutReturn);
    }

    /// @notice Route fees back to the project
    function _routeFeesToProject(uint256 projectId, address terminalToken, uint256 amount) internal {
        if (amount == 0) return;

        uint256 feeAmount = (amount * FEE_PERCENT) / BPS;
        uint256 remainingAmount = amount - feeAmount;

        uint256 beneficiaryTokenCount = 0;
        if (feeAmount > 0) {
            address feeTerminal =
                address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: FEE_PROJECT_ID, token: terminalToken}));
            if (feeTerminal != address(0)) {
                address feeProjectToken = address(IJBTokens(TOKENS).tokenOf(FEE_PROJECT_ID));
                uint256 feeTokensBefore = IERC20(feeProjectToken).balanceOf(address(this));

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
                    IERC20(terminalToken).forceApprove(feeTerminal, feeAmount);
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

                uint256 feeTokensAfter = IERC20(feeProjectToken).balanceOf(address(this));
                beneficiaryTokenCount = feeTokensAfter > feeTokensBefore ? feeTokensAfter - feeTokensBefore : 0;

                claimableFeeTokens[projectId] += beneficiaryTokenCount;
            }
        }

        if (remainingAmount > 0) {
            _addToProjectBalance(projectId, terminalToken, remainingAmount, _isNativeToken(terminalToken));
        }

        emit LPFeesRouted(projectId, terminalToken, amount, feeAmount, remainingAmount, beneficiaryTokenCount);
    }

    /// @notice Check if terminal token is native ETH
    function _isNativeToken(address terminalToken) internal pure returns (bool isNative) {
        return terminalToken == JBConstants.NATIVE_TOKEN;
    }

    /// @notice Convert terminal token to Uniswap V4 Currency
    /// @dev Juicebox uses JBConstants.NATIVE_TOKEN for native ETH; V4 uses Currency.wrap(address(0))
    function _toCurrency(address terminalToken) internal pure returns (Currency) {
        return Currency.wrap(_isNativeToken(terminalToken) ? address(0) : terminalToken);
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
        tickLower = TickMath.getTickAtSqrtPrice(_getCashOutRateSqrtPriceX96(projectId, terminalToken, projectToken));
        tickUpper = TickMath.getTickAtSqrtPrice(_getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken));

        tickLower = _alignTickToSpacing(tickLower, TICK_SPACING);
        tickUpper = _alignTickToSpacing(tickUpper, TICK_SPACING);

        if (tickLower >= tickUpper) {
            uint160 currentSqrtPrice = _getSqrtPriceX96ForCurrentJuiceboxPrice(projectId, terminalToken, projectToken);
            int24 currentTick = TickMath.getTickAtSqrtPrice(currentSqrtPrice);
            currentTick = _alignTickToSpacing(currentTick, TICK_SPACING);
            tickLower = currentTick - TICK_SPACING;
            tickUpper = currentTick + TICK_SPACING;
        }
    }

    /// @notice Route collected fees from Uniswap position to project
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
        (address token0,) = _sortTokens(projectToken, Currency.unwrap(terminalCurrency));

        // Route terminal token fees
        if (amount0 > 0 && token0 == Currency.unwrap(terminalCurrency)) {
            _routeFeesToProject(projectId, terminalToken, amount0);
        }
        if (amount1 > 0 && token0 != Currency.unwrap(terminalCurrency)) {
            _routeFeesToProject(projectId, terminalToken, amount1);
        }
    }

    /// @notice Align tick to tick spacing using proper floor semantics for negative ticks
    function _alignTickToSpacing(int24 tick, int24 spacing) internal pure returns (int24 alignedTick) {
        int24 rounded = (tick / spacing) * spacing;
        if (tick < 0 && rounded > tick) {
            rounded -= spacing;
        }
        return rounded;
    }

    /// @notice Burn project tokens using the controller
    function _burnProjectTokens(uint256 projectId, address projectToken, uint256 amount, string memory memo) internal {
        if (amount == 0) return;

        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        if (controller != address(0)) {
            IJBController(controller)
                .burnTokensOf({holder: address(this), projectId: projectId, tokenCount: amount, memo: memo});
            emit TokensBurned(projectId, projectToken, amount);
        }
    }

    /// @notice Add tokens to project balance via terminal
    function _addToProjectBalance(uint256 projectId, address token, uint256 amount, bool isNative) internal {
        if (amount == 0) return;

        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: token}));
        if (terminal == address(0)) return;

        if (!isNative) {
            IERC20(token).forceApprove(terminal, amount);
        }

        IJBMultiTerminal(terminal).addToBalanceOf{value: isNative ? amount : 0}({
            projectId: projectId, token: token, amount: amount, shouldReturnHeldFees: false, memo: "", metadata: ""
        });
    }

    /// @notice Handle leftover tokens after V4 mint operation
    function _handleLeftoverTokens(uint256 projectId, address projectToken, address terminalToken) internal {
        // Burn any remaining project tokens
        uint256 projectTokenLeftover = IERC20(projectToken).balanceOf(address(this));
        if (projectTokenLeftover > 0) {
            _burnProjectTokens(projectId, projectToken, projectTokenLeftover, "Burning leftover project tokens");
        }

        // Add any remaining terminal tokens to project balance
        uint256 terminalTokenLeftover = _getTerminalTokenBalance(terminalToken);
        if (terminalTokenLeftover > 0) {
            _addToProjectBalance(projectId, terminalToken, terminalTokenLeftover, _isNativeToken(terminalToken));
        }
    }

    /// @notice Sort input tokens in order expected by Uniswap V4 (token0 < token1)
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @notice Get balance of a currency held by this contract
    function _currencyBalance(Currency currency) internal view returns (uint256) {
        if (currency.isAddressZero()) {
            return address(this).balance;
        }
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /// @notice Get terminal token balance held by this contract
    function _getTerminalTokenBalance(address terminalToken) internal view returns (uint256) {
        if (_isNativeToken(terminalToken)) {
            return address(this).balance;
        }
        return IERC20(terminalToken).balanceOf(address(this));
    }

    /// @notice Get amount for a specific currency side (helper for fee routing after burn)
    function _getAmountForCurrency(
        PoolKey memory key,
        address projectToken,
        address terminalToken,
        bool isToken0
    )
        internal
        pure
        returns (uint256)
    {
        // This is a placeholder — actual amounts come from balance tracking
        return 0;
    }
}
