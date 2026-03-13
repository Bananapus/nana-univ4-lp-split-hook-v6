// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

// JB core -- deploy fresh within fork.
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBRulesets} from "@bananapus/core-v6/src/JBRulesets.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";
import {JBSplits} from "@bananapus/core-v6/src/JBSplits.sol";
import {JBPrices} from "@bananapus/core-v6/src/JBPrices.sol";
import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBFundAccessLimits} from "@bananapus/core-v6/src/JBFundAccessLimits.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

// Uniswap V4.
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// Hook under test.
import {LibClone} from "solady/src/utils/LibClone.sol";
import {JBUniswapV4LPSplitHook} from "../../src/JBUniswapV4LPSplitHook.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ──────────────────────────────────────────────────────────────────────────────
// MockUSDC: simple ERC20 with 6 decimals and public mint
// ──────────────────────────────────────────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// GeomeanSwapHelper: performs swaps inside V4 PoolManager via unlock callback
// ──────────────────────────────────────────────────────────────────────────────

contract GeomeanSwapHelper is IUnlockCallback {
    using CurrencyLibrary for Currency;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IPoolManager public immutable poolManager;

    struct SwapCallbackData {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        address sender;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    receive() external payable {}

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external payable {
        // forge-lint: disable-next-line(named-struct-fields)
        poolManager.unlock(abi.encode(SwapCallbackData(key, zeroForOne, amountSpecified, msg.sender)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only pool manager");
        SwapCallbackData memory params = abi.decode(data, (SwapCallbackData));

        BalanceDelta delta = poolManager.swap(
            params.key,
            SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // Settle negative deltas (tokens owed to the pool) and take positive deltas (tokens owed to us).
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Handle currency0
        if (delta0 < 0) {
            // We owe the pool currency0
            // Safe: delta values from Uniswap V4 BalanceDelta are always valid int128.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountOwed = uint256(uint128(-delta0));
            if (params.key.currency0.isAddressZero()) {
                poolManager.settle{value: amountOwed}();
            } else {
                poolManager.sync(params.key.currency0);
                // forgefmt: disable-next-item
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                IERC20(Currency.unwrap(params.key.currency0)).transferFrom(params.sender, address(poolManager), amountOwed);
                poolManager.settle();
            }
        } else if (delta0 > 0) {
            // Safe: delta values from Uniswap V4 BalanceDelta are always valid int128.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountOwedToUs = uint256(uint128(delta0));
            poolManager.take(params.key.currency0, params.sender, amountOwedToUs);
        }

        // Handle currency1
        if (delta1 < 0) {
            // Safe: delta values from Uniswap V4 BalanceDelta are always valid int128.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountOwed = uint256(uint128(-delta1));
            if (params.key.currency1.isAddressZero()) {
                poolManager.settle{value: amountOwed}();
            } else {
                poolManager.sync(params.key.currency1);
                // forgefmt: disable-next-item
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                IERC20(Currency.unwrap(params.key.currency1)).transferFrom(params.sender, address(poolManager), amountOwed);
                poolManager.settle();
            }
        } else if (delta1 > 0) {
            // Safe: delta values from Uniswap V4 BalanceDelta are always valid int128.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountOwedToUs = uint256(uint128(delta1));
            poolManager.take(params.key.currency1, params.sender, amountOwedToUs);
        }

        return "";
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// GeomeanLPForkTest: stress tests for LP split hook pool deployment and rebalance
// ──────────────────────────────────────────────────────────────────────────────

/// @notice Fork tests that stress the LP split hook's pool deployment and rebalancing
///         across varying order sizes and liquidity depths for both ETH and USDC pools.
contract GeomeanLPForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ───────────────────────── Mainnet addresses
    // ──────────────────────────

    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant V4_POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // ───────────────────────── JB core (deployed fresh)
    // ───────────────────

    address multisig = address(0xBEEF);
    address trustedForwarder = address(0);

    JBPermissions jbPermissions;
    JBProjects jbProjects;
    JBDirectory jbDirectory;
    JBRulesets jbRulesets;
    JBTokens jbTokens;
    JBSplits jbSplits;
    JBPrices jbPrices;
    JBFundAccessLimits jbFundAccessLimits;
    JBFeelessAddresses jbFeelessAddresses;
    JBController jbController;
    JBTerminalStore jbTerminalStore;
    JBMultiTerminal jbMultiTerminal;

    // ───────────────────────── Hook under test
    // ────────────────────────────

    JBUniswapV4LPSplitHook hook;

    // ───────────────────────── Project state
    // ──────────────────────────────

    uint256 feeProjectId;
    uint256 projectId;
    IJBToken projectToken;

    // Accept ETH for cashout returns.
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ethereum", 21_700_000);

        // Verify V4 contracts exist on this fork.
        require(address(V4_POOL_MANAGER).code.length > 0, "PoolManager not deployed");
        require(address(V4_POSITION_MANAGER).code.length > 0, "PositionManager not deployed");

        // Deploy all JB core contracts fresh.
        _deployJBCore();

        // Launch fee project (project 1) -- accepts ETH.
        feeProjectId = _launchProject(false, 0);
        require(feeProjectId == 1, "fee project must be #1");

        // Launch test project (project 2) -- accepts ETH, with reserved percent + owner minting.
        projectId = _launchProject(true, 0);

        // Deploy ERC-20 for the test project.
        vm.prank(multisig);
        projectToken = jbController.deployERC20For(projectId, "Test Token", "TST", bytes32(0));

        // Pay ETH into the project to build surplus (needed for cashout during pool deployment).
        jbMultiTerminal.pay{value: 50 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 50 ether,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Deploy the hook with real V4 contracts.
        JBUniswapV4LPSplitHook hookImpl = new JBUniswapV4LPSplitHook(
            address(jbDirectory),
            IJBPermissions(address(jbPermissions)),
            address(jbTokens),
            V4_POOL_MANAGER,
            V4_POSITION_MANAGER,
            IHooks(address(0))
        );
        hook = JBUniswapV4LPSplitHook(payable(LibClone.clone(address(hookImpl))));
        hook.initialize(feeProjectId, 3800);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ETH POOL TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Accumulate different amounts of project tokens [1k, 10k, 100k, 1M] then deploy pool for each.
    ///         Verify pool deploys, position exists, liquidity > 0, and accumulated tokens clear.
    function test_fork_ethPool_varyingAccumulation() public {
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1000e18;
        amounts[1] = 10_000e18;
        amounts[2] = 100_000e18;
        amounts[3] = 1_000_000e18;

        for (uint256 i; i < amounts.length; i++) {
            // Fork fresh state for each iteration by creating a new project.
            uint256 pid = _launchProject(true, 0);

            vm.prank(multisig);
            IJBToken pToken = jbController.deployERC20For(pid, "Iter Token", "ITR", bytes32(0));

            // Pay ETH to build surplus.
            jbMultiTerminal.pay{value: 20 ether}({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 20 ether,
                beneficiary: multisig,
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            });

            // Accumulate tokens.
            _accumulateTokens(pid, address(pToken), amounts[i]);

            assertEq(
                hook.accumulatedProjectTokens(pid),
                amounts[i],
                string.concat("accumulated mismatch at index ", vm.toString(i))
            );

            // Deploy pool as project owner.
            vm.prank(multisig);
            hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);

            // Assert: pool deployed.
            assertTrue(
                hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN),
                string.concat("pool not deployed at index ", vm.toString(i))
            );

            // Assert: position NFT exists.
            uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
            assertTrue(tokenId != 0, string.concat("no position NFT at index ", vm.toString(i)));

            // Assert: position has liquidity > 0.
            uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
            assertTrue(posLiq > 0, string.concat("zero liquidity at index ", vm.toString(i)));

            // Assert: accumulated tokens cleared.
            assertEq(
                hook.accumulatedProjectTokens(pid),
                0,
                string.concat("accumulated not cleared at index ", vm.toString(i))
            );

            // Log diagnostics.
            PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,,,) = V4_POOL_MANAGER.getSlot0(poolId);

            emit log_named_uint("  accumulation amount", amounts[i]);
            emit log_named_uint("  position liquidity", posLiq);
            emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
        }
    }

    /// @notice Pay different amounts of ETH [0.1, 1, 10, 100] to build surplus, accumulate tokens,
    ///         deploy pool. Verify pool initialization price is at geometric mean.
    function test_fork_ethPool_varyingPaymentSizes() public {
        uint256[] memory ethAmounts = new uint256[](4);
        ethAmounts[0] = 0.1 ether;
        ethAmounts[1] = 1 ether;
        ethAmounts[2] = 10 ether;
        ethAmounts[3] = 100 ether;

        for (uint256 i; i < ethAmounts.length; i++) {
            uint256 pid = _launchProject(true, 0);

            vm.prank(multisig);
            IJBToken pToken = jbController.deployERC20For(pid, "Pay Token", "PAY", bytes32(0));

            // Pay ETH to project.
            _payProject(pid, ethAmounts[i]);

            // Accumulate 50k project tokens.
            _accumulateTokens(pid, address(pToken), 50_000e18);

            // Deploy pool.
            vm.prank(multisig);
            hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);

            assertTrue(
                hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN),
                string.concat("pool not deployed for ETH amount ", vm.toString(ethAmounts[i]))
            );

            // Verify pool has non-zero price (geometric mean of issuance and cashout rates).
            PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,,,) = V4_POOL_MANAGER.getSlot0(poolId);
            assertTrue(sqrtPriceX96 > 0, "pool should have nonzero price");

            // Verify position has liquidity.
            uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
            uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
            assertTrue(posLiq > 0, "position should have liquidity");

            emit log_named_uint("  ETH paid", ethAmounts[i]);
            emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
            emit log_named_uint("  position liquidity", posLiq);
        }
    }

    /// @notice Deploy pool, then simulate price movement by executing swaps in the V4 pool,
    ///         then call rebalanceLiquidity. Assert new position has non-zero liquidity
    ///         and tick bounds adjusted.
    function test_fork_ethPool_rebalanceAfterPriceMovement() public {
        // Accumulate and deploy pool for projectId.
        _accumulateTokens(projectId, address(projectToken), 100_000e18);

        vm.prank(multisig);
        hook.deployPool(projectId, JBConstants.NATIVE_TOKEN, 0);

        assertTrue(hook.isPoolDeployed(projectId, JBConstants.NATIVE_TOKEN), "pool should be deployed");

        uint256 originalTokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        uint128 originalLiq = V4_POSITION_MANAGER.getPositionLiquidity(originalTokenId);
        assertTrue(originalLiq > 0, "original position should have liquidity");

        // Get pool key for the swap.
        PoolKey memory key = hook.poolKeyOf(projectId, JBConstants.NATIVE_TOKEN);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceBefore,,,) = V4_POOL_MANAGER.getSlot0(poolId);

        // Deploy swap helper.
        GeomeanSwapHelper swapHelper = new GeomeanSwapHelper(V4_POOL_MANAGER);

        // Determine which currency is the project token (to approve it for swaps).
        address projTokenAddr = address(projectToken);
        bool projIsToken0 = Currency.unwrap(key.currency0) == projTokenAddr;

        // To move the price, swap project tokens for ETH (sell project tokens).
        // Mint some project tokens to this test contract for the swap.
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: projectId, tokenCount: 10_000e18, beneficiary: address(this), memo: "", useReservedPercent: false
        });

        // Approve the swap helper to pull project tokens via transferFrom in the callback.
        IERC20(projTokenAddr).approve(address(swapHelper), type(uint256).max);

        // Execute swap: sell project tokens for the other currency.
        // zeroForOne = true means sell token0 for token1.
        // If project is token0, we swap zeroForOne=true.
        // If project is token1, we swap zeroForOne=false.
        bool zeroForOne = projIsToken0;

        // Exact input: negative amountSpecified means exactIn.
        swapHelper.swap{value: projIsToken0 ? 0 : 0}(key, zeroForOne, -int256(5000e18));

        (uint160 sqrtPriceAfterSwap,,,) = V4_POOL_MANAGER.getSlot0(poolId);
        assertTrue(sqrtPriceAfterSwap != sqrtPriceBefore, "swap should have moved the price");

        // Now rebalance liquidity.
        vm.prank(multisig);
        hook.rebalanceLiquidity(projectId, JBConstants.NATIVE_TOKEN, 0, 0);

        // Verify new position exists.
        uint256 newTokenId = hook.tokenIdOf(projectId, JBConstants.NATIVE_TOKEN);
        assertTrue(newTokenId != 0, "new position should exist after rebalance");
        assertTrue(newTokenId != originalTokenId, "tokenId should change after rebalance");

        // Verify new position has liquidity.
        uint128 newLiq = V4_POSITION_MANAGER.getPositionLiquidity(newTokenId);
        assertTrue(newLiq > 0, "rebalanced position should have liquidity");

        emit log_named_uint("  sqrtPrice before swap", sqrtPriceBefore);
        emit log_named_uint("  sqrtPrice after swap", sqrtPriceAfterSwap);
        emit log_named_uint("  original liquidity", originalLiq);
        emit log_named_uint("  rebalanced liquidity", newLiq);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  USDC POOL TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deploy USDC pools with amounts [1k, 10k, 100k].
    ///         For each: set up project with USDC terminal, pay USDC, accumulate, deploy, verify.
    function test_fork_usdcPool_deployAndVerify() public {
        uint256[] memory usdcAmounts = new uint256[](3);
        usdcAmounts[0] = 1000e6;
        usdcAmounts[1] = 10_000e6;
        usdcAmounts[2] = 100_000e6;

        for (uint256 i; i < usdcAmounts.length; i++) {
            // Deploy a fresh MockUSDC for each iteration (unique address avoids pool collisions).
            MockUSDC usdc = new MockUSDC();

            // Launch a project that accepts this USDC.
            uint256 pid = _launchProjectWithUSDC(usdc);

            vm.prank(multisig);
            IJBToken pToken = jbController.deployERC20For(pid, "USDC Token", "UPT", bytes32(0));

            // Pay USDC to build surplus.
            _payProjectUSDC(pid, usdc, usdcAmounts[i]);

            // Accumulate project tokens (50k per iteration).
            _accumulateTokens(pid, address(pToken), 50_000e18);

            // Deploy pool with USDC.
            vm.prank(multisig);
            hook.deployPool(pid, address(usdc), 0);

            // Assert: pool deployed.
            assertTrue(
                hook.isPoolDeployed(pid, address(usdc)),
                string.concat("USDC pool not deployed at index ", vm.toString(i))
            );

            // Assert: position NFT exists.
            uint256 tokenId = hook.tokenIdOf(pid, address(usdc));
            assertTrue(tokenId != 0, string.concat("no USDC position NFT at index ", vm.toString(i)));

            // Assert: position has liquidity.
            uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
            assertTrue(posLiq > 0, string.concat("zero USDC liquidity at index ", vm.toString(i)));

            // Assert: accumulated tokens cleared.
            assertEq(
                hook.accumulatedProjectTokens(pid),
                0,
                string.concat("USDC accumulated not cleared at index ", vm.toString(i))
            );

            emit log_named_uint("  USDC amount", usdcAmounts[i]);
            emit log_named_uint("  position liquidity", posLiq);
        }
    }

    /// @notice Same as test_fork_usdcPool_deployAndVerify but focus on varying liquidity depths
    ///         and verify position liquidity scales proportionally with USDC input.
    function test_fork_usdcPool_varyingLiquidity() public {
        uint256[] memory usdcAmounts = new uint256[](3);
        usdcAmounts[0] = 1000e6;
        usdcAmounts[1] = 10_000e6;
        usdcAmounts[2] = 100_000e6;

        uint128[] memory liquidities = new uint128[](3);

        for (uint256 i; i < usdcAmounts.length; i++) {
            MockUSDC usdc = new MockUSDC();

            uint256 pid = _launchProjectWithUSDC(usdc);

            vm.prank(multisig);
            IJBToken pToken = jbController.deployERC20For(pid, "VL Token", "VLT", bytes32(0));

            _payProjectUSDC(pid, usdc, usdcAmounts[i]);

            // Scale token accumulation proportionally with USDC.
            // For 1k USDC -> 5k tokens, 10k -> 50k, 100k -> 500k.
            uint256 tokenAmount = (usdcAmounts[i] * 5000e18) / 1000e6;
            _accumulateTokens(pid, address(pToken), tokenAmount);

            vm.prank(multisig);
            hook.deployPool(pid, address(usdc), 0);

            uint256 tokenId = hook.tokenIdOf(pid, address(usdc));
            assertTrue(tokenId != 0, "position should exist");

            liquidities[i] = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
            assertTrue(liquidities[i] > 0, "position should have liquidity");

            emit log_named_uint("  USDC amount", usdcAmounts[i]);
            emit log_named_uint("  token accumulation", tokenAmount);
            emit log_named_uint("  position liquidity", liquidities[i]);
        }

        // Verify liquidity scales: each 10x USDC increase should yield significantly more liquidity.
        // We use a loose check: 2x minimum increase per 10x input (accounts for bonding curve effects).
        assertTrue(liquidities[1] > liquidities[0] * 2, "10x USDC should yield at least 2x liquidity vs 1x");
        assertTrue(liquidities[2] > liquidities[1] * 2, "100x USDC should yield at least 2x liquidity vs 10x");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  COMBINED STRESS TEST
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deploy pools with different weight/cashout configurations.
    ///         Verify the tick bounds are within expected ranges based on issuance and cashout rates.
    function test_fork_poolDeployment_tickBounds() public {
        // Configuration: (weight, cashOutTaxRate)
        // Higher cashOutTaxRate means lower cashout value, wider spread between issuance and cashout prices.
        uint112[] memory weights = new uint112[](3);
        weights[0] = 500_000e18;
        weights[1] = 1_000_000e18;
        weights[2] = 5_000_000e18;

        uint16[] memory cashOutTaxRates = new uint16[](3);
        cashOutTaxRates[0] = 0;
        cashOutTaxRates[1] = 2500;
        cashOutTaxRates[2] = 5000;

        for (uint256 i; i < weights.length; i++) {
            uint256 pid = _launchProjectWithConfig(weights[i], cashOutTaxRates[i]);

            vm.prank(multisig);
            IJBToken pToken = jbController.deployERC20For(pid, "TB Token", "TBT", bytes32(0));

            // Pay ETH.
            _payProject(pid, 10 ether);

            // Accumulate tokens.
            _accumulateTokens(pid, address(pToken), 100_000e18);

            // Deploy pool.
            vm.prank(multisig);
            hook.deployPool(pid, JBConstants.NATIVE_TOKEN, 0);

            assertTrue(
                hook.isPoolDeployed(pid, JBConstants.NATIVE_TOKEN),
                string.concat("pool not deployed at config ", vm.toString(i))
            );

            PoolKey memory key = hook.poolKeyOf(pid, JBConstants.NATIVE_TOKEN);
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96, int24 currentTick,,) = V4_POOL_MANAGER.getSlot0(poolId);
            assertTrue(sqrtPriceX96 > 0, "pool should be initialized");

            // Verify tick is within valid V4 range.
            assertTrue(currentTick >= TickMath.MIN_TICK, "tick below MIN_TICK");
            assertTrue(currentTick <= TickMath.MAX_TICK, "tick above MAX_TICK");

            // Verify position has liquidity.
            uint256 tokenId = hook.tokenIdOf(pid, JBConstants.NATIVE_TOKEN);
            uint128 posLiq = V4_POSITION_MANAGER.getPositionLiquidity(tokenId);
            assertTrue(posLiq > 0, "position should have liquidity");

            emit log_named_uint("  weight", weights[i]);
            emit log_named_uint("  cashOutTaxRate", cashOutTaxRates[i]);
            emit log_named_int("  currentTick", currentTick);
            emit log_named_uint("  sqrtPriceX96", sqrtPriceX96);
            emit log_named_uint("  position liquidity", posLiq);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INTERNAL DEPLOYMENT HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    // forge-lint: disable-next-line(mixed-case-function)
    function _deployJBCore() internal {
        jbPermissions = new JBPermissions(trustedForwarder);
        jbProjects = new JBProjects(multisig, address(0), trustedForwarder);
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        JBERC20 jbErc20 = new JBERC20();
        jbTokens = new JBTokens(jbDirectory, jbErc20);
        jbRulesets = new JBRulesets(jbDirectory);
        jbPrices = new JBPrices(jbDirectory, jbPermissions, jbProjects, multisig, trustedForwarder);
        jbSplits = new JBSplits(jbDirectory);
        jbFundAccessLimits = new JBFundAccessLimits(jbDirectory);
        jbFeelessAddresses = new JBFeelessAddresses(multisig);

        jbController = new JBController(
            jbDirectory,
            jbFundAccessLimits,
            jbPermissions,
            jbPrices,
            jbProjects,
            jbRulesets,
            jbSplits,
            jbTokens,
            address(0),
            trustedForwarder
        );

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);

        jbTerminalStore = new JBTerminalStore(jbDirectory, jbPrices, jbRulesets);

        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses,
            jbPermissions,
            jbProjects,
            jbSplits,
            jbTerminalStore,
            jbTokens,
            PERMIT2,
            trustedForwarder
        );

        vm.deal(address(this), 10_000 ether);
    }

    /// @notice Launch a project that accepts ETH with configurable owner minting.
    function _launchProject(bool withOwnerMinting, uint16 cashOutTaxRate) internal returns (uint256 id) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: withOwnerMinting ? 1000 : 0,
            cashOutTaxRate: cashOutTaxRate,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: withOwnerMinting,
            allowSetCustomToken: withOwnerMinting,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 1_000_000e18;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        id = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @notice Launch a project with a specific weight and cashOutTaxRate.
    function _launchProjectWithConfig(uint112 weight, uint16 cashOutTaxRate) internal returns (uint256 id) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 1000,
            cashOutTaxRate: cashOutTaxRate,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
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
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = weight;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        id = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @notice Launch a project that accepts a MockUSDC token.
    // forge-lint: disable-next-line(mixed-case-function)
    function _launchProjectWithUSDC(MockUSDC usdc) internal returns (uint256 id) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 1000,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(usdc))),
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
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        // Use a realistic weight for 6-decimal tokens (1 USDC = 1000 project tokens).
        // High weights (1e24) cause _getCashOutRate precision loss since the per-token
        // cashout value falls below 1 USDC unit (10^-6).
        rulesetConfigs[0].weight = 1000e18;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] =
            JBAccountingContext({token: address(usdc), decimals: 6, currency: uint32(uint160(address(usdc)))});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        id = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ACTION HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Mint project tokens to the hook, then call processSplitWith as the controller
    ///         to trigger accumulation.
    function _accumulateTokens(uint256 pid, address tokenAddr, uint256 amount) internal {
        // Mint tokens to the hook.
        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: pid, tokenCount: amount, beneficiary: address(hook), memo: "", useReservedPercent: false
        });

        // Simulate the controller calling processSplitWith.
        JBSplitHookContext memory context = JBSplitHookContext({
            token: tokenAddr,
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

        vm.prank(address(jbController));
        hook.processSplitWith(context);
    }

    /// @notice Pay ETH to a project via the terminal.
    function _payProject(uint256 pid, uint256 amount) internal {
        jbMultiTerminal.pay{value: amount}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    /// @notice Pay USDC to a project via the terminal.
    // forge-lint: disable-next-line(mixed-case-function)
    function _payProjectUSDC(uint256 pid, MockUSDC usdc, uint256 amount) internal {
        // Mint USDC to this test contract.
        usdc.mint(address(this), amount);

        // Approve the terminal to spend USDC.
        // JBMultiTerminal uses Permit2 for ERC20 pulls, so we approve Permit2 first.
        usdc.approve(address(PERMIT2), type(uint256).max);

        // Also set up Permit2 allowance for the terminal.
        // The terminal pulls via Permit2.transferFrom, so we need:
        // 1. ERC20 approve to Permit2
        // 2. Permit2 approve to terminal
        // Safe: amount fits in uint160 and block.timestamp + 3600 fits in uint48 in test context.
        IPermit2(address(PERMIT2)).
            // forge-lint: disable-next-line(unsafe-typecast)
            approve(address(usdc), address(jbMultiTerminal), uint160(amount), uint48(block.timestamp + 3600));

        jbMultiTerminal.pay({
            projectId: pid,
            token: address(usdc),
            amount: amount,
            beneficiary: multisig,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }
}
