// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IJBController} from "@bananapus/core-v5/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v5/src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";
import {JBPermissioned} from "@bananapus/core-v5/src/abstract/JBPermissioned.sol";
import {IJBSplitHook} from "@bananapus/core-v5/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v5/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v5/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v5/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v5/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v5/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v5/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v5/src/libraries/JBRulesetMetadataResolver.sol";
import {JBSplitHookContext} from "@bananapus/core-v5/src/structs/JBSplitHookContext.sol";
import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {mulDiv, sqrt} from "@prb/math/src/Common.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v5/src/JBPermissionIds.sol";
import {IUniV4DeploymentSplitHook} from "./interfaces/IUniV4DeploymentSplitHook.sol";
import {IREVDeployer} from "./interfaces/IREVDeployer.sol";

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
contract UniV4DeploymentSplitHook is IUniV4DeploymentSplitHook, IJBSplitHook, JBPermissioned, ERC2771Context, Ownable {
    using JBRulesetMetadataResolver for JBRuleset;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @dev Thrown when a parameter is the zero address.
    error UniV4DeploymentSplitHook_ZeroAddressNotAllowed();

    /// @dev Thrown when a projectId does not exist in the JBDirectory
    error UniV4DeploymentSplitHook_InvalidProjectId();

    /// @dev Thrown when `processSplitWith` is called and this contract is not the hook specified in the JBSplitHookContext
    error UniV4DeploymentSplitHook_NotHookSpecifiedInContext();

    /// @dev Thrown when `processSplitWith` is not called by the project's controller
    error UniV4DeploymentSplitHook_SplitSenderNotValidControllerOrTerminal();

    /// @dev Thrown when trying to deploy pool but no tokens have been accumulated
    error UniV4DeploymentSplitHook_NoTokensAccumulated();

    /// @dev Thrown when trying to perform an action that's not allowed in the current stage
    error UniV4DeploymentSplitHook_InvalidStageForAction();

    /// @dev Thrown when the split hook receives terminal tokens from payouts (should only receive reserved tokens)
    error UniV4DeploymentSplitHook_TerminalTokensNotAllowed();

    /// @dev Thrown when fee percent exceeds 100% (10000 basis points)
    error UniV4DeploymentSplitHook_InvalidFeePercent();

    /// @dev Thrown when trying to claim tokens for a non-revnet operator
    error UniV4DeploymentSplitHook_UnauthorizedBeneficiary();

    /// @dev Thrown when terminalToken is not a valid terminal token for the projectId
    error UniV4DeploymentSplitHook_InvalidTerminalToken();

    /// @dev Thrown when pool has already been deployed for this project/token pair
    error UniV4DeploymentSplitHook_PoolAlreadyDeployed();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice Basis points constant (10000 = 100%)
    uint256 public constant BPS = 10000;

    /// @notice Uniswap V4 pool fee (10000 = 1% fee tier)
    uint24 public constant POOL_FEE = 10000;

    /// @notice Tick spacing for 1% fee tier (200 ticks)
    int24 public constant TICK_SPACING = 200;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice JBDirectory (to find important control contracts for given projectId)
    address public immutable DIRECTORY;

    /// @notice JBTokens (to find project tokens)
    address public immutable TOKENS;

    /// @notice Uniswap V4 PoolManager
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Uniswap V4 PositionManager (handles LP NFTs and liquidity operations)
    IPositionManager public immutable POSITION_MANAGER;

    /// @notice Permit2 contract for token approvals
    IAllowanceTransfer public immutable PERMIT2;

    /// @notice WETH address (for native ETH edge cases)
    address public immutable WETH;

    /// @notice Project ID to receive LP fees
    uint256 public immutable FEE_PROJECT_ID;

    /// @notice Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    uint256 public immutable FEE_PERCENT;

    /// @notice REVDeployer contract address for revnet operator validation
    address public immutable REV_DEPLOYER;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice ProjectID => Terminal token => whether a PoolKey has been set
    mapping(uint256 projectId => mapping(address terminalToken => bool)) public poolKeySet;

    /// @notice PoolId => PositionManager tokenId (LP NFT)
    /// @dev The contract will only control a single position for a given pool
    mapping(PoolId => uint256 tokenId) public tokenIdForPool;

    /// @notice ProjectID => Accumulated project token balance
    mapping(uint256 projectId => uint256 accumulatedProjectTokens) public accumulatedProjectTokens;

    /// @notice ProjectID => whether any pool has been deployed for this project
    /// @dev Set to true when deployPool succeeds; used by processSplitWith to decide accumulate vs burn
    mapping(uint256 projectId => bool deployed) public projectDeployed;

    /// @notice ProjectID => Fee tokens claimable by that project
    mapping(uint256 projectId => uint256 claimableFeeTokens) public claimableFeeTokens;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice ProjectID => Terminal token => PoolKey (stored internally, exposed via poolKeyOf)
    mapping(uint256 projectId => mapping(address terminalToken => PoolKey)) internal _poolKeyOf;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param initialOwner Initial owner/admin of the contract
    /// @param directory JBDirectory address
    /// @param permissions JBPermissions address
    /// @param tokens JBTokens address
    /// @param poolManager Uniswap V4 PoolManager address
    /// @param positionManager Uniswap V4 PositionManager address
    /// @param permit2 Permit2 contract address
    /// @param weth WETH address
    /// @param feeProjectId Project ID to receive LP fees
    /// @param feePercent Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    /// @param revDeployer REVDeployer contract address for revnet operator validation
    /// @param trustedForwarder A trusted forwarder of transactions to this contract.
    constructor(
        address initialOwner,
        address directory,
        IJBPermissions permissions,
        address tokens,
        address poolManager,
        address positionManager,
        address permit2,
        address weth,
        uint256 feeProjectId,
        uint256 feePercent,
        address revDeployer,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
        Ownable(initialOwner)
    {
        if (directory == address(0)) revert UniV4DeploymentSplitHook_ZeroAddressNotAllowed();
        if (tokens == address(0)) revert UniV4DeploymentSplitHook_ZeroAddressNotAllowed();
        if (poolManager == address(0)) revert UniV4DeploymentSplitHook_ZeroAddressNotAllowed();
        if (positionManager == address(0)) revert UniV4DeploymentSplitHook_ZeroAddressNotAllowed();
        if (permit2 == address(0)) revert UniV4DeploymentSplitHook_ZeroAddressNotAllowed();
        if (revDeployer == address(0)) revert UniV4DeploymentSplitHook_ZeroAddressNotAllowed();
        if (feePercent > BPS) revert UniV4DeploymentSplitHook_InvalidFeePercent(); // Max 100% in basis points

        DIRECTORY = directory;
        TOKENS = tokens;

        POOL_MANAGER = IPoolManager(poolManager);
        POSITION_MANAGER = IPositionManager(positionManager);
        PERMIT2 = IAllowanceTransfer(permit2);
        WETH = weth;
        FEE_PERCENT = feePercent;
        REV_DEPLOYER = revDeployer;

        // Validate FEE_PROJECT_ID points to a valid project with a controller
        // This ensures fee routing will work correctly
        if (feeProjectId != 0) {
            address feeController = address(IJBDirectory(directory).controllerOf(feeProjectId));
            if (feeController == address(0)) {
                revert UniV4DeploymentSplitHook_InvalidProjectId();
            }
        }
        FEE_PROJECT_ID = feeProjectId;
    }

    /// @notice Accept ETH transfers (needed for native ETH handling).
    receive() external payable {}

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice As per ERC-165 to declare supported interfaces
    /// @param interfaceId Interface ID as specified by `type(interface).interfaceId`
    /// @return Whether the interface is supported
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IUniV4DeploymentSplitHook).interfaceId
            || interfaceId == type(IJBSplitHook).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Check if a pool has been deployed for a project/terminal token pair
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    /// @return deployed True if pool exists
    function isPoolDeployed(uint256 projectId, address terminalToken) public view returns (bool deployed) {
        return poolKeySet[projectId][terminalToken];
    }

    /// @notice Get the PoolKey for a project/terminal token pair
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    /// @return poolKey The Uniswap V4 PoolKey
    function poolKeyOf(uint256 projectId, address terminalToken) public view returns (PoolKey memory poolKey) {
        return _poolKeyOf[projectId][terminalToken];
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice For given terminalToken amount, compute equivalent projectToken amount at current JuiceboxV4 price
    function _getProjectTokensOutForTerminalTokensIn(
        uint256 projectId,
        address terminalToken,
        uint256 terminalTokenInAmount
    ) internal view returns (uint256 projectTokenOutAmount) {
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken));
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(projectId, terminalToken);

        uint32 baseCurrency = ruleset.baseCurrency();

        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES().pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });

        projectTokenOutAmount = mulDiv(terminalTokenInAmount, ruleset.weight, weightRatio);
    }

    /// @notice For given terminalToken amount, compute equivalent projectToken amount using a specific weight
    function _getProjectTokensOutForTerminalTokensInWithWeight(
        uint256 projectId,
        address terminalToken,
        uint256 terminalTokenInAmount,
        uint256 weight
    ) internal view returns (uint256 projectTokenOutAmount) {
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken));
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(projectId, terminalToken);

        uint32 baseCurrency = ruleset.baseCurrency();

        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES().pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });

        projectTokenOutAmount = mulDiv(terminalTokenInAmount, weight, weightRatio);
    }

    /// @notice Compute Uniswap V4 SqrtPriceX96 for current JuiceboxV4 price
    function _getSqrtPriceX96ForCurrentJuiceboxPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken
    ) internal view returns (uint160 sqrtPriceX96) {
        (address token0, address token1) = _sortTokens(terminalToken, projectToken);

        uint256 token0Amount = 10 ** 18;
        uint256 token1Amount;

        if (token0 == terminalToken) {
            token1Amount = _getProjectTokensOutForTerminalTokensIn(projectId, terminalToken, token0Amount);
        } else {
            token1Amount = _getTerminalTokensOutForProjectTokensIn(projectId, terminalToken, token0Amount);
        }

        return uint160(mulDiv(sqrt(token1Amount), 2**96, sqrt(token0Amount)));
    }

    /// @notice For given projectToken amount, compute equivalent terminalToken amount at current JuiceboxV4 price
    function _getTerminalTokensOutForProjectTokensIn(
        uint256 projectId,
        address terminalToken,
        uint256 projectTokenInAmount
    ) internal view returns (uint256 terminalTokenOutAmount) {
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken));
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(projectId, terminalToken);

        uint32 baseCurrency = ruleset.baseCurrency();

        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES().pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });

        terminalTokenOutAmount = mulDiv(projectTokenInAmount, weightRatio, ruleset.weight);
    }

    /// @notice For given projectToken amount, compute equivalent terminalToken amount using a specific weight
    function _getTerminalTokensOutForProjectTokensInWithWeight(
        uint256 projectId,
        address terminalToken,
        uint256 projectTokenInAmount,
        uint256 weight
    ) internal view returns (uint256 terminalTokenOutAmount) {
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken));
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(projectId, terminalToken);

        uint32 baseCurrency = ruleset.baseCurrency();

        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES().pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });

        terminalTokenOutAmount = mulDiv(projectTokenInAmount, weightRatio, weight);
    }

    /// @notice Calculate the issuance rate (price ceiling) - tokens received per terminal token paid
    function _getIssuanceRate(uint256 projectId, address terminalToken) internal view returns (uint256 projectTokensPerTerminalToken) {
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset, JBRulesetMetadata memory metadata) = IJBController(controller).currentRulesetOf(projectId);

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

    /// @notice Calculate the cash out rate (price floor) - terminal tokens received per project token cashed out
    function _getCashOutRate(uint256 projectId, address terminalToken) internal view returns (uint256 terminalTokensPerProjectToken) {
        try IJBMultiTerminal(address(IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken))).STORE().currentReclaimableSurplusOf(
            projectId,
            10 ** 18,
            new IJBTerminal[](0),
            new JBAccountingContext[](0),
            _getTokenDecimals(terminalToken),
            uint256(uint160(terminalToken))
        ) returns (uint256 reclaimableAmount) {
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
    function _getIssuanceRateSqrtPriceX96(uint256 projectId, address terminalToken, address projectToken) internal view returns (uint160 sqrtPriceX96) {
        (address token0, address token1) = _sortTokens(terminalToken, projectToken);

        uint256 projectTokensPerTerminalToken = _getIssuanceRate(projectId, terminalToken);

        uint256 token0Amount = 10 ** 18;
        uint256 token1Amount;

        if (token0 == terminalToken) {
            token1Amount = projectTokensPerTerminalToken;
        } else {
            token1Amount = mulDiv(token0Amount, 10 ** 18, projectTokensPerTerminalToken);
        }

        return uint160(mulDiv(sqrt(token1Amount), 2**96, sqrt(token0Amount)));
    }

    /// @notice Convert cash out rate to sqrtPriceX96 (price floor)
    function _getCashOutRateSqrtPriceX96(uint256 projectId, address terminalToken, address projectToken) internal view returns (uint160 sqrtPriceX96) {
        (address token0, address token1) = _sortTokens(terminalToken, projectToken);

        uint256 terminalTokensPerProjectToken = _getCashOutRate(projectId, terminalToken);

        uint256 token0Amount = 10 ** 18;
        uint256 token1Amount;

        if (token0 == terminalToken) {
            token1Amount = mulDiv(token0Amount, 10 ** 18, terminalTokensPerProjectToken);
        } else {
            token1Amount = terminalTokensPerProjectToken;
        }

        return uint160(mulDiv(sqrt(token1Amount), 2**96, sqrt(token0Amount)));
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Claim fee tokens for a beneficiary (must be the project's revnet operator)
    function claimFeeTokensFor(uint256 projectId, address beneficiary) external {
        if (!IREVDeployer(REV_DEPLOYER).isSplitOperatorOf(projectId, beneficiary)) {
            revert UniV4DeploymentSplitHook_UnauthorizedBeneficiary();
        }

        uint256 claimableAmount = claimableFeeTokens[projectId];
        claimableFeeTokens[projectId] = 0;

        if (claimableAmount > 0) {
            address feeProjectToken = address(IJBTokens(TOKENS).tokenOf(FEE_PROJECT_ID));
            IERC20(feeProjectToken).safeTransfer(beneficiary, claimableAmount);
            emit FeeTokensClaimed(projectId, beneficiary, claimableAmount);
        }
    }

    /// @notice Collect LP fees and route them back to the project
    /// @dev V4: decrease liquidity with amount=0 triggers fee accounting, then TAKE_PAIR to receive tokens
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external {
        if (!poolKeySet[projectId][terminalToken]) revert UniV4DeploymentSplitHook_InvalidStageForAction();

        PoolKey memory key = _poolKeyOf[projectId][terminalToken];
        PoolId poolId = key.toId();
        uint256 tokenId = tokenIdForPool[poolId];
        if (tokenId == 0) revert UniV4DeploymentSplitHook_InvalidStageForAction();

        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));

        // Track balances before fee collection
        (uint256 balance0Before, uint256 balance1Before) = _getTokenBalances(key);

        // Decrease liquidity with 0 amount to collect fees, then TAKE_PAIR
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));

        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Calculate collected amounts
        (uint256 balance0After, uint256 balance1After) = _getTokenBalances(key);
        uint256 amount0 = balance0After > balance0Before ? balance0After - balance0Before : 0;
        uint256 amount1 = balance1After > balance1Before ? balance1After - balance1Before : 0;

        // Route terminal token fees back to the project
        _routeCollectedFees(projectId, projectToken, terminalToken, amount0, amount1, key);

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
    ) external {
        _requirePermissionFrom({
            account: IJBDirectory(DIRECTORY).PROJECTS().ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        if (poolKeySet[projectId][terminalToken]) revert UniV4DeploymentSplitHook_PoolAlreadyDeployed();

        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];

        if (projectTokenBalance == 0) revert UniV4DeploymentSplitHook_NoTokensAccumulated();

        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken));
        if (terminal == address(0)) revert UniV4DeploymentSplitHook_InvalidTerminalToken();

        _deployPoolAndAddLiquidity(projectId, projectToken, terminalToken, amount0Min, amount1Min, minCashOutReturn);

        projectDeployed[projectId] = true;

        PoolKey memory key = _poolKeyOf[projectId][terminalToken];
        emit ProjectDeployed(projectId, terminalToken, key.toId());
    }

    /// @notice Rebalance LP position to match current issuance and cash out rates
    function rebalanceLiquidity(
        uint256 projectId,
        address terminalToken,
        uint256 decreaseAmount0Min,
        uint256 decreaseAmount1Min,
        uint256 increaseAmount0Min,
        uint256 increaseAmount1Min
    ) external {
        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken));
        if (terminal == address(0)) revert UniV4DeploymentSplitHook_InvalidTerminalToken();

        if (!poolKeySet[projectId][terminalToken]) revert UniV4DeploymentSplitHook_InvalidStageForAction();

        PoolKey memory key = _poolKeyOf[projectId][terminalToken];
        PoolId poolId = key.toId();
        uint256 tokenId = tokenIdForPool[poolId];
        if (tokenId == 0) revert UniV4DeploymentSplitHook_InvalidStageForAction();

        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));

        // Get current position liquidity
        uint128 liquidity = POSITION_MANAGER.getPositionLiquidity(tokenId);

        // Step 1: Remove all liquidity + collect fees via BURN_POSITION + TAKE_PAIR
        {
            bytes memory removeActions = abi.encodePacked(
                uint8(Actions.BURN_POSITION),
                uint8(Actions.TAKE_PAIR)
            );
            bytes[] memory removeParams = new bytes[](2);
            removeParams[0] = abi.encode(tokenId, decreaseAmount0Min, decreaseAmount1Min, bytes(""));
            removeParams[1] = abi.encode(key.currency0, key.currency1, address(this));

            POSITION_MANAGER.modifyLiquidities(abi.encode(removeActions, removeParams), block.timestamp);
        }

        // Route any fees from the collected amounts
        {
            uint256 projectTokenBalance = IERC20(projectToken).balanceOf(address(this));
            uint256 terminalTokenBalance = _getTerminalTokenBalance(terminalToken);

            // Route terminal token fees (we'll use remaining balances for new position)
            // For now, just burn project tokens received as fees later
        }

        // Calculate new tick bounds based on current rates
        (int24 tickLower, int24 tickUpper) = _calculateTickBounds(projectId, terminalToken, projectToken);

        // Get current balances for new position
        uint256 projectTokenBalance = IERC20(projectToken).balanceOf(address(this));
        uint256 terminalTokenBalance = _getTerminalTokenBalance(terminalToken);

        // Sort tokens and compute amounts
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        (address token0, address token1) = _sortTokens(projectToken, uniswapTerminalToken);

        uint256 amount0Desired = projectToken == token0 ? projectTokenBalance : terminalTokenBalance;
        uint256 amount1Desired = projectToken == token1 ? projectTokenBalance : terminalTokenBalance;

        // Approve tokens for V4 position manager via Permit2
        if (projectTokenBalance > 0) {
            _approveTokensForPositionManager(projectToken, projectTokenBalance);
        }
        if (terminalTokenBalance > 0 && !_isNativeToken(terminalToken)) {
            _approveTokensForPositionManager(terminalToken, terminalTokenBalance);
        }

        // Step 2: Create new position with updated ticks
        uint256 newTokenId = POSITION_MANAGER.nextTokenId();

        {
            bytes memory mintActions = abi.encodePacked(
                uint8(Actions.MINT_POSITION),
                uint8(Actions.SETTLE_PAIR),
                uint8(Actions.SWEEP),
                uint8(Actions.SWEEP)
            );
            bytes[] memory mintParams = new bytes[](4);
            mintParams[0] = abi.encode(key, tickLower, tickUpper, _computeLiquidity(key, tickLower, tickUpper, amount0Desired, amount1Desired), amount0Desired, amount1Desired, address(this), bytes(""));
            mintParams[1] = abi.encode(key.currency0, key.currency1);
            mintParams[2] = abi.encode(key.currency0, address(this));
            mintParams[3] = abi.encode(key.currency1, address(this));

            uint256 ethValue = _isNativeToken(terminalToken) ? terminalTokenBalance : 0;
            POSITION_MANAGER.modifyLiquidities{value: ethValue}(abi.encode(mintActions, mintParams), block.timestamp);
        }

        // Update the tokenId mapping
        tokenIdForPool[poolId] = newTokenId;

        // Handle leftover tokens
        uint256 projectTokenLeftover = IERC20(projectToken).balanceOf(address(this));
        uint256 terminalTokenLeftover = _getTerminalTokenBalance(terminalToken);

        if (projectTokenLeftover > 0) {
            _burnProjectTokens(projectId, projectToken, projectTokenLeftover, "Burning leftover project tokens");
        }
        if (terminalTokenLeftover > 0) {
            _addToProjectBalance(projectId, terminalToken, terminalTokenLeftover, _isNativeToken(terminalToken));
        }
    }

    /// @notice IJbSplitHook function called by JuiceboxV4 terminal/controller when sending funds to designated split hook contract
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

    /// @notice Add liquidity to a Uniswap V4 pool using accumulated tokens
    function _addUniswapLiquidity(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minCashOutReturn
    ) internal {
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];

        if (projectTokenBalance == 0) return;

        (int24 tickLower, int24 tickUpper) = _calculateTickBounds(projectId, terminalToken, projectToken);

        uint160 sqrtPriceInit = _computeInitialSqrtPrice(projectId, terminalToken, projectToken);

        uint256 cashOutAmount = _computeOptimalCashOutAmount(
            projectId, terminalToken, projectToken,
            projectTokenBalance, sqrtPriceInit, tickLower, tickUpper
        );

        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken));

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

            IJBMultiTerminal(terminal).cashOutTokensOf(
                address(this),
                projectId,
                cashOutAmount,
                terminalToken,
                effectiveMinReturn,
                payable(address(this)),
                ""
            );
        }

        // Get actual balances after cash out
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        (address token0, address token1) = _sortTokens(projectToken, uniswapTerminalToken);

        uint256 projectTokenAmount = IERC20(projectToken).balanceOf(address(this));

        uint256 terminalTokenBalanceAfter = _getTerminalTokenBalance(terminalToken);
        uint256 terminalTokenAmount = terminalTokenBalanceAfter > terminalTokenBalanceBefore
            ? terminalTokenBalanceAfter - terminalTokenBalanceBefore
            : 0;

        // Approve tokens via Permit2 chain for V4 PositionManager
        if (projectTokenAmount > 0) {
            _approveTokensForPositionManager(projectToken, projectTokenAmount);
        }
        if (terminalTokenAmount > 0 && !_isNativeToken(terminalToken)) {
            _approveTokensForPositionManager(terminalToken, terminalTokenAmount);
        }

        // Calculate amounts based on token ordering
        uint256 amount0Desired = projectToken == token0 ? projectTokenAmount : terminalTokenAmount;
        uint256 amount1Desired = projectToken == token1 ? projectTokenAmount : terminalTokenAmount;

        // Get the pool key
        PoolKey memory key = _poolKeyOf[projectId][terminalToken];

        // Compute liquidity for the position
        uint256 liquidity = _computeLiquidity(key, tickLower, tickUpper, amount0Desired, amount1Desired);

        // Mint position via V4 PositionManager
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, amount0Desired, amount1Desired, address(this), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        params[3] = abi.encode(key.currency1, address(this));

        uint256 ethValue = _isNativeToken(terminalToken) ? terminalTokenAmount : 0;
        POSITION_MANAGER.modifyLiquidities{value: ethValue}(abi.encode(actions, params), block.timestamp);

        PoolId poolId = key.toId();
        tokenIdForPool[poolId] = tokenId;

        // Handle leftover tokens
        uint256 projectTokenLeftover = IERC20(projectToken).balanceOf(address(this));
        uint256 terminalTokenLeftover = _getTerminalTokenBalance(terminalToken);
        // Subtract pre-existing balance
        if (terminalTokenLeftover > terminalTokenBalanceBefore) {
            terminalTokenLeftover -= terminalTokenBalanceBefore;
        } else {
            terminalTokenLeftover = 0;
        }

        if (projectTokenLeftover > 0) {
            _burnProjectTokens(projectId, projectToken, projectTokenLeftover, "Burning leftover project tokens");
        }
        if (terminalTokenLeftover > 0) {
            _addToProjectBalance(projectId, terminalToken, terminalTokenLeftover, _isNativeToken(terminalToken));
        }

        // Clear accumulated balances after successful LP creation
        accumulatedProjectTokens[projectId] = 0;
    }

    /// @notice Burn received project tokens in deployment stage
    function _burnReceivedTokens(uint256 projectId, address projectToken) internal {
        uint256 projectTokenBalance = IERC20(projectToken).balanceOf(address(this));
        if (projectTokenBalance > 0) {
            _burnProjectTokens(projectId, projectToken, projectTokenBalance, "Burning additional tokens");
        }
    }

    /// @notice Create and initialize Uniswap V4 pool
    function _createAndInitializePool(uint256 projectId, address projectToken, address terminalToken) internal {
        address uniswapTerminalToken = _toUniswapToken(terminalToken);

        // Build PoolKey with sorted currencies
        (Currency currency0, Currency currency1) = _sortCurrencies(projectToken, uniswapTerminalToken);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // Compute initial price at geometric mean of [cashOutRate, issuanceRate]
        uint160 sqrtPriceX96 = _computeInitialSqrtPrice(projectId, terminalToken, projectToken);

        // Initialize the pool
        POSITION_MANAGER.initializePool(key, sqrtPriceX96);

        // Store pool key
        _poolKeyOf[projectId][terminalToken] = key;
        poolKeySet[projectId][terminalToken] = true;
    }

    /// @notice Compute the initial sqrtPriceX96 for pool initialization
    function _computeInitialSqrtPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken
    ) internal view returns (uint160 sqrtPriceX96) {
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
    ) internal view returns (uint256 cashOutAmount) {
        uint256 cashOutRate = _getCashOutRate(projectId, terminalToken);

        if (cashOutRate == 0) return 0;

        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        bool terminalIsToken0 = uniswapTerminalToken < projectToken;

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
    ) internal {
        if (!poolKeySet[projectId][terminalToken]) {
            _createAndInitializePool(projectId, projectToken, terminalToken);
        }

        _addUniswapLiquidity(projectId, projectToken, terminalToken, amount0Min, amount1Min, minCashOutReturn);
    }

    /// @notice Route fees back to the project via addToBalance
    function _routeFeesToProject(uint256 projectId, address terminalToken, uint256 amount) internal {
        if (amount == 0) return;

        address token = terminalToken;

        // Calculate fee amount to send to fee project
        uint256 feeAmount = (amount * FEE_PERCENT) / BPS;
        uint256 remainingAmount = amount - feeAmount;

        // Route fee portion to fee project
        uint256 beneficiaryTokenCount = 0;
        if (feeAmount > 0) {
            address feeTerminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf(FEE_PROJECT_ID, token));
            if (feeTerminal != address(0)) {
                address feeProjectToken = address(IJBTokens(TOKENS).tokenOf(FEE_PROJECT_ID));
                uint256 feeTokensBefore = IERC20(feeProjectToken).balanceOf(address(this));

                if (_isNativeToken(terminalToken)) {
                    IJBMultiTerminal(feeTerminal).pay{value: feeAmount}(
                        FEE_PROJECT_ID,
                        token,
                        feeAmount,
                        address(this),
                        0,
                        "LP Fee",
                        ""
                    );
                } else {
                    IERC20(token).forceApprove(feeTerminal, feeAmount);
                    IJBMultiTerminal(feeTerminal).pay(
                        FEE_PROJECT_ID,
                        token,
                        feeAmount,
                        address(this),
                        0,
                        "LP Fee",
                        ""
                    );
                }

                uint256 feeTokensAfter = IERC20(feeProjectToken).balanceOf(address(this));
                beneficiaryTokenCount = feeTokensAfter > feeTokensBefore ? feeTokensAfter - feeTokensBefore : 0;

                claimableFeeTokens[projectId] += beneficiaryTokenCount;
            }
        }

        // Route remaining amount to original project
        if (remainingAmount > 0) {
            _addToProjectBalance(projectId, token, remainingAmount, _isNativeToken(terminalToken));
        }

        emit LPFeesRouted(projectId, terminalToken, amount, feeAmount, remainingAmount, beneficiaryTokenCount);
    }

    /// @notice Check if terminal token is native ETH
    function _isNativeToken(address terminalToken) internal pure returns (bool isNative) {
        return terminalToken == JBConstants.NATIVE_TOKEN;
    }

    /// @notice Convert terminal token to Uniswap-compatible token address
    /// @dev In V4, native ETH uses address(0) directly, but for token sorting we use WETH
    function _toUniswapToken(address terminalToken) internal view returns (address uniswapToken) {
        return _isNativeToken(terminalToken) ? WETH : terminalToken;
    }

    /// @notice Get the terminal token balance (handles native ETH vs ERC20)
    function _getTerminalTokenBalance(address terminalToken) internal view returns (uint256) {
        return _isNativeToken(terminalToken)
            ? address(this).balance
            : IERC20(terminalToken).balanceOf(address(this));
    }

    /// @notice Get token balances for both currencies of a pool key
    function _getTokenBalances(PoolKey memory key) internal view returns (uint256 balance0, uint256 balance1) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        balance0 = token0 == address(0) ? address(this).balance : IERC20(token0).balanceOf(address(this));
        balance1 = token1 == address(0) ? address(this).balance : IERC20(token1).balanceOf(address(this));
    }

    /// @notice Calculate tick bounds for liquidity position based on issuance and cash out rates
    function _calculateTickBounds(
        uint256 projectId,
        address terminalToken,
        address projectToken
    ) internal view returns (int24 tickLower, int24 tickUpper) {
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
        uint256 amount1,
        PoolKey memory key
    ) internal {
        if (amount0 == 0 && amount1 == 0) return;

        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // For native ETH in V4, currency0 might be address(0)
        // Map back: address(0) -> WETH for comparison
        address effectiveToken0 = token0 == address(0) ? WETH : token0;
        address effectiveToken1 = token1 == address(0) ? WETH : token1;

        if (amount0 > 0 && effectiveToken0 == uniswapTerminalToken) {
            _routeFeesToProject(projectId, terminalToken, amount0);
        }
        if (amount1 > 0 && effectiveToken1 == uniswapTerminalToken) {
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
            IJBController(controller).burnTokensOf(
                address(this),
                projectId,
                amount,
                memo
            );
            emit TokensBurned(projectId, projectToken, amount);
        }
    }

    /// @notice Add tokens to project balance via terminal
    function _addToProjectBalance(uint256 projectId, address token, uint256 amount, bool isNative) internal {
        if (amount == 0) return;

        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, token));
        if (terminal == address(0)) return;

        if (!isNative) {
            IERC20(token).forceApprove(terminal, amount);
        }

        IJBMultiTerminal(terminal).addToBalanceOf{value: isNative ? amount : 0}(
            projectId, token, amount, false, "", ""
        );
    }

    /// @notice Approve tokens for PositionManager via Permit2 chain
    /// @dev Token -> Permit2 (approve) -> PositionManager (allow via Permit2.approve)
    function _approveTokensForPositionManager(address token, uint256 amount) internal {
        IERC20(token).forceApprove(address(PERMIT2), amount);
        PERMIT2.approve(token, address(POSITION_MANAGER), uint160(amount), uint48(block.timestamp + 1));
    }

    /// @notice Sort two token addresses
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @notice Sort two token addresses into Currencies
    function _sortCurrencies(address tokenA, address tokenB) internal pure returns (Currency currency0, Currency currency1) {
        if (tokenA < tokenB) {
            return (Currency.wrap(tokenA), Currency.wrap(tokenB));
        } else {
            return (Currency.wrap(tokenB), Currency.wrap(tokenA));
        }
    }

    /// @notice Compute liquidity for a position given amounts and tick range
    /// @dev Simplified computation - in production this would use LiquidityAmounts library
    function _computeLiquidity(
        PoolKey memory, /* key */
        int24, /* tickLower */
        int24, /* tickUpper */
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint256 liquidity) {
        // Use the geometric mean as a simple approximation
        // The actual PositionManager will use the correct amount based on current price
        liquidity = sqrt(amount0 * amount1);
        if (liquidity == 0) liquidity = amount0 + amount1;
    }

    //*********************************************************************//
    // ---------------------- ERC2771 overrides -------------------------- //
    //*********************************************************************//

    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }
}
