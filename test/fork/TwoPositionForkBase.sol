// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// External packages (alphabetized)
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

// Local: test helpers
import {ForkDeployHelper} from "../helpers/ForkDeployHelper.sol";

// Local: contracts and libraries
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";
import {JBLPSplitHookHelpers} from "../../src/libraries/JBLPSplitHookHelpers.sol";
import {JBUniswapV4LPSplitHookMath} from "../../src/libraries/JBUniswapV4LPSplitHookMath.sol";

/// @notice A third-party LP that adds liquidity straight through the PoolManager and settles both currencies from its
/// own balances (native ETH or an ERC-20 it holds), so it can occupy a range on either side of the spot.
contract ThirdPartyLP is IUnlockCallback {
    /// @notice The Uniswap V4 PoolManager this LP adds liquidity through.
    IPoolManager public immutable POOL_MANAGER;

    /// @param poolManager The Uniswap V4 PoolManager this LP adds liquidity through.
    constructor(IPoolManager poolManager) {
        // Pin the PoolManager so the unlock callback can authenticate its caller.
        POOL_MANAGER = poolManager;
    }

    /// @notice Accepts native ETH so the LP can fund the native side of its positions.
    receive() external payable {}

    /// @notice Adds `liquidity` to the `[tickLower, tickUpper)` range of the pool, paying from this contract's
    /// balances.
    /// @param key The pool to add liquidity to.
    /// @param tickLower The range's lower tick.
    /// @param tickUpper The range's upper tick.
    /// @param liquidity The liquidity to add.
    function add(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) external {
        // Unlock the PoolManager; the add itself runs in `unlockCallback`.
        POOL_MANAGER.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
    }

    /// @notice Adds the encoded liquidity and settles every currency the add leaves owed.
    /// @param data The ABI-encoded pool key, lower tick, upper tick and liquidity from `add`.
    /// @return result Empty bytes; the PoolManager ignores the callback's return data here.
    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        // Only the PoolManager may drive a liquidity add from this contract's balances.
        require(msg.sender == address(POOL_MANAGER), "only pool manager");

        // Recover the range and liquidity `add` encoded.
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint256));

        // Add the liquidity under the default salt; the returned delta is what this contract owes.
        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                // Test liquidity amounts stay far below `type(int256).max`.
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: int256(liquidity),
                salt: 0
            }),
            ""
        );

        // Pay each side of the add so the unlock closes with no outstanding deltas.
        _settle({currency: key.currency0, amount: delta.amount0()});
        _settle({currency: key.currency1, amount: delta.amount1()});

        // The PoolManager does not read the callback's return data.
        return "";
    }

    /// @notice Pays the PoolManager what a negative delta says this contract owes in `currency`.
    /// @param currency The currency the delta is denominated in.
    /// @param amount The delta; negative means this contract owes that amount.
    function _settle(Currency currency, int128 amount) private {
        // A non-negative delta owes nothing.
        if (amount >= 0) return;

        // `amount` is negative here, so its negation fits in a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-amount));

        if (Currency.unwrap(currency) == address(0)) {
            // Native ETH settles by value.
            POOL_MANAGER.settle{value: owed}();
        } else {
            // An ERC-20 settles by syncing the reserve, transferring in, then settling the difference.
            POOL_MANAGER.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), owed), "transfer failed");
            POOL_MANAGER.settle();
        }
    }
}

/// @notice Shared real-mainnet setup for two-position LP split hook fork tests: JB core from source, a fee project, a
/// hook clone wired to the real Uniswap V4 PoolManager/PositionManager and a passive oracle hook whose TWAP read is
/// mocked to the spot. Holds only helpers; tests live in the inheriting contracts.
abstract contract TwoPositionForkBase is ForkDeployHelper {
    // Reads pool state (slot0, tick and position info, fee growth) from the PoolManager's storage.
    using StateLibrary for IPoolManager;

    // Derives a pool ID from its key.
    using PoolIdLibrary for PoolKey;

    // Unpacks a PositionManager position's tick range.
    using PositionInfoLibrary for PositionInfo;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice JB's native-token sentinel, the terminal token every project here accepts.
    address internal constant _NATIVE = JBConstants.NATIVE_TOKEN;

    /// @notice The mainnet Uniswap V4 PoolManager.
    IPoolManager internal constant _V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    /// @notice The mainnet Uniswap V4 PositionManager.
    IPositionManager internal constant _V4_POSITION_MANAGER =
        IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The fee project the hook routes its LP-fee cut to.
    uint256 feeProjectId;

    /// @notice The LP split hook clone under test.
    JBUniswapV4LPSplitHook hook;

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Accepts native ETH sent back to the test contract.
    receive() external payable {}

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Forks mainnet, deploys JB core and a fee project, and initializes a hook clone on the real V4 contracts.
    function setUp() public virtual {
        // Pin the fork block so pool and contract state are reproducible.
        vm.createSelectFork("ethereum", 21_700_000);

        // Deploy JB core from source against the fork.
        _deployJBCore();

        // The fee project needs an ERC-20 so the hook can hold and route fee tokens.
        feeProjectId = _launchProject({reservedPercent: 0, weight: 1_000_000e18});
        vm.prank(multisig);
        jbController.deployERC20For({projectId: feeProjectId, name: "Fee Token", symbol: "FEE", salt: bytes32(0)});

        // Deploy the implementation, then use a clone as the hook, the way production deploys it.
        JBUniswapV4LPSplitHook hookImpl = new JBUniswapV4LPSplitHook({
            directory: address(jbDirectory),
            permissions: IJBPermissions(address(jbPermissions)),
            tokens: address(jbTokens),
            permit2: IAllowanceTransfer(address(PERMIT2)),
            suckerRegistry: IJBSuckerRegistry(address(0))
        });
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));

        // Wire the clone to the real V4 contracts and a passive oracle hook, with a 38% fee-project cut.
        hook.initialize({
            initialFeeProjectId: feeProjectId,
            initialFeePercent: 3800,
            newPoolManager: _V4_POOL_MANAGER,
            newPositionManager: _V4_POSITION_MANAGER,
            newOracleHook: _deployGeomeanOracleHook(_V4_POOL_MANAGER),
            newBuybackHook: IJBBuybackHookRegistry(address(0))
        });
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Delivers `amount` freshly minted project tokens to the hook as a reserved-token split, intake only.
    /// @dev The split call is gas-capped at `INTAKE_ONLY_GAS`, so the hook records the tokens and skips inline
    /// automation.
    /// @param pid The project whose tokens are delivered.
    /// @param pToken The project's ERC-20.
    /// @param amount The number of project tokens to deliver.
    function _accumulateTokens(uint256 pid, address pToken, uint256 amount) internal {
        // Mint to the controller, which is the account that pays reserved-token splits.
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: amount, beneficiary: address(jbController), memo: "", useReservedPercent: false
        });

        // The context the controller hands a reserved-token split hook for a 100% split.
        JBSplitHookContext memory context = JBSplitHookContext({
            token: pToken,
            amount: amount,
            decimals: 18,
            projectId: pid,
            groupId: 1,
            split: JBSplit({
                percent: 1_000_000,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(hook))
            })
        });

        // As the controller, approve the hook to pull the tokens and run the split with intake-only gas.
        vm.startPrank(address(jbController));
        IERC20(pToken).approve(address(hook), amount);
        hook.processSplitWith{gas: INTAKE_ONLY_GAS}(context);
        vm.stopPrank();
    }

    /// @notice Launches a native-ETH project with zero cash-out tax, local cash-out scope and owner minting.
    /// @param reservedPercent The ruleset's reserved percent.
    /// @param weight The ruleset's issuance weight.
    /// @return id The new project's ID.
    function _launchProject(uint16 reservedPercent, uint112 weight) internal returns (uint256 id) {
        // No splits and no payout limits.
        return _launchProjectWith({
            reservedPercent: reservedPercent,
            weight: weight,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });
    }

    /// @notice `_launchProjectWith` on the given terminals, each accepting native ETH.
    /// @param reservedPercent The ruleset's reserved percent.
    /// @param weight The ruleset's issuance weight.
    /// @param splitGroups The ruleset's split groups.
    /// @param fundAccessLimitGroups The ruleset's payout limits and surplus allowances.
    /// @param terminals The terminals the project accepts native ETH on.
    /// @return id The new project's ID.
    function _launchProjectOn(
        uint16 reservedPercent,
        uint112 weight,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups,
        IJBTerminal[] memory terminals
    )
        internal
        returns (uint256 id)
    {
        // One ruleset with no approval hook, so it takes effect immediately.
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].weight = weight;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));

        // Zero cash-out tax, local cash-out scope, owner minting and custom tokens; everything else stays off.
        rulesetConfigs[0].metadata = JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: 0,
            // The native token's address truncated to 32 bits is its currency ID.
            // forge-lint: disable-next-line(unsafe-typecast)
            baseCurrency: uint32(uint160(_NATIVE)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        rulesetConfigs[0].splitGroups = splitGroups;
        rulesetConfigs[0].fundAccessLimitGroups = fundAccessLimitGroups;

        // Every terminal accepts native ETH with 18 decimals.
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        // The native token's address truncated to 32 bits is its currency ID.
        // forge-lint: disable-next-line(unsafe-typecast)
        tokensToAccept[0] = JBAccountingContext({token: _NATIVE, decimals: 18, currency: uint32(uint160(_NATIVE))});
        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](terminals.length);
        for (uint256 i; i < terminals.length; i++) {
            terminalConfigs[i] = JBTerminalConfig({terminal: terminals[i], accountingContextsToAccept: tokensToAccept});
        }

        // The multisig owns the project so tests can mint and deploy its ERC-20.
        id = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @notice `_launchProject` with the given split groups and fund access limits.
    /// @param reservedPercent The ruleset's reserved percent.
    /// @param weight The ruleset's issuance weight.
    /// @param splitGroups The ruleset's split groups.
    /// @param fundAccessLimitGroups The ruleset's payout limits and surplus allowances.
    /// @return id The new project's ID.
    function _launchProjectWith(
        uint16 reservedPercent,
        uint112 weight,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        internal
        returns (uint256 id)
    {
        // The project accepts native ETH on the multi-terminal only.
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = jbMultiTerminal;
        return _launchProjectOn({
            reservedPercent: reservedPercent,
            weight: weight,
            splitGroups: splitGroups,
            fundAccessLimitGroups: fundAccessLimitGroups,
            terminals: terminals
        });
    }

    /// @notice Pays `amount` of native ETH into the project's multi-terminal, minting to the multisig.
    /// @param pid The project to pay.
    /// @param amount The amount of native ETH to pay.
    function _pay(uint256 pid, uint256 amount) internal {
        // The payment builds the project's surplus; the minted tokens go to the multisig.
        jbMultiTerminal.pay{value: amount}({
            projectId: pid,
            token: _NATIVE,
            amount: amount,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice The project's live corridor, computed with the same linked math the hook uses.
    /// @param pid The project whose corridor to compute.
    /// @param pToken The project's ERC-20.
    /// @return tickLower The corridor's lower tick.
    /// @return tickUpper The corridor's upper tick.
    function _corridorOf(uint256 pid, address pToken) internal view returns (int24 tickLower, int24 tickUpper) {
        // The corridor depends on the project's current ruleset.
        (JBRuleset memory ruleset,) = jbController.currentRulesetOf(pid);

        // No sucker registry, so the corridor uses local balances and supply only.
        return JBUniswapV4LPSplitHookMath.calculateTickBounds({
            directory: jbDirectory,
            suckerRegistry: IJBSuckerRegistry(address(0)),
            projectId: pid,
            terminalToken: _NATIVE,
            projectToken: pToken,
            controller: address(jbController),
            ruleset: ruleset
        });
    }

    /// @notice The fees a position has accrued but not collected, exactly as `Pool` computes them on its next touch.
    /// @param tokenId The PositionManager token ID of the position.
    /// @param key The pool the position sits in.
    /// @return fee0 The uncollected currency0 fees.
    /// @return fee1 The uncollected currency1 fees.
    function _feesOf(uint256 tokenId, PoolKey memory key) internal view returns (uint256 fee0, uint256 fee1) {
        // The PositionManager owns the pool-level position, salted by the token ID.
        (int24 tickLower, int24 tickUpper) = _ticksOf(tokenId);
        (uint128 liquidity, uint256 last0, uint256 last1) = _V4_POOL_MANAGER.getPositionInfo(
            key.toId(), address(_V4_POSITION_MANAGER), tickLower, tickUpper, bytes32(tokenId)
        );
        (uint256 inside0, uint256 inside1) = _V4_POOL_MANAGER.getFeeGrowthInside(key.toId(), tickLower, tickUpper);

        // Fee growth wraps by design, so the difference is taken unchecked, matching `Pool`.
        unchecked {
            fee0 = FullMath.mulDiv(inside0 - last0, liquidity, 1 << 128);
            fee1 = FullMath.mulDiv(inside1 - last1, liquidity, 1 << 128);
        }
    }

    /// @notice The hook's pool key for a native-ETH pair (ETH always sorts as currency0).
    /// @param pToken The project's ERC-20.
    /// @return key The pool key the hook uses for the pair.
    function _keyOf(address pToken) internal view returns (PoolKey memory key) {
        // Native ETH is address(0) in V4, which sorts below every ERC-20.
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(pToken),
            fee: hook.POOL_FEE(),
            tickSpacing: hook.TICK_SPACING(),
            hooks: hook.oracleHook()
        });
    }

    /// @notice `tick` aligned down to the spacing, then 77 ticks off the grid so a spot set there never sits on a
    /// bound.
    /// @param tick The tick to offset.
    /// @return offGridTick The aligned tick plus 77.
    function _offGrid(int24 tick) internal view returns (int24 offGridTick) {
        // The hook's spacing is 200, so +77 stays strictly inside the aligned spacing.
        return JBLPSplitHookHelpers.alignTickToSpacing({tick: tick, spacing: hook.TICK_SPACING()}) + 77;
    }

    /// @notice What burning a position returns at the live spot: `Pool.modifyLiquidity` rounds a removal down.
    /// @param tokenId The PositionManager token ID of the position.
    /// @param key The pool the position sits in.
    /// @return amount0 The currency0 principal a burn returns.
    /// @return amount1 The currency1 principal a burn returns.
    function _principalOf(uint256 tokenId, PoolKey memory key)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        // The range's bounds, the live spot and the position's liquidity.
        (int24 tickLower, int24 tickUpper) = _ticksOf(tokenId);
        (uint160 spot,,,) = _V4_POOL_MANAGER.getSlot0(key.toId());
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = _V4_POSITION_MANAGER.getPositionLiquidity(tokenId);

        // Clamp the spot into the range, so a range wholly above or below the spot holds only one currency.
        uint160 sqrtLow = spot < sqrtA ? sqrtA : spot > sqrtB ? sqrtB : spot;

        // Currency0 sits above the clamped spot and currency1 below it, both rounded down as a removal is.
        amount0 = SqrtPriceMath.getAmount0Delta({
            sqrtPriceAX96: sqrtLow, sqrtPriceBX96: sqrtB, liquidity: liquidity, roundUp: false
        });
        amount1 = SqrtPriceMath.getAmount1Delta({
            sqrtPriceAX96: sqrtA, sqrtPriceBX96: sqrtLow, liquidity: liquidity, roundUp: false
        });
    }

    /// @notice The spot tick exactly as the hook reads it (from the sqrt price).
    /// @param key The pool to read.
    /// @return tick The tick at the pool's current sqrt price.
    function _spotTick(PoolKey memory key) internal view returns (int24 tick) {
        // Derive the tick from the sqrt price rather than slot0's stored tick, as the hook does.
        (uint160 sqrtPriceX96,,,) = _V4_POOL_MANAGER.getSlot0(key.toId());
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice The live tick range of a hook position, read from the PositionManager.
    /// @param tokenId The PositionManager token ID of the position.
    /// @return tickLower The position's lower tick.
    /// @return tickUpper The position's upper tick.
    function _ticksOf(uint256 tokenId) internal view returns (int24 tickLower, int24 tickUpper) {
        // The PositionManager packs the range into the position's info word.
        (, PositionInfo info) = _V4_POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        return (info.tickLower(), info.tickUpper());
    }
}
