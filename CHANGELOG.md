# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. The closest V5 source comparison is `nana-lp-split-hook-v5` in `../../v5/evm`; the current repo is the V6 Uniswap V4 LP split hook package.

## Current V6 Surface

- `JBUniswapV4LPSplitHook`
- `JBUniswapV4LPSplitHookDeployer`
- `IJBUniswapV4LPSplitHook`
- `IJBUniswapV4LPSplitHookDeployer`
- `JBUniswapV4LPSplitHookMath`
- `AddLiquidityParams`

## Summary

- The V5 comparison package was a Uniswap V3 deployment split hook. V6 is a Uniswap V4 pool-manager and position-manager design.
- V6 deploys hook clones through a deployer and initializes per-clone state, rather than treating one hook as a static V3 deployment helper.
- Post-deployment reserved-token inflows are accumulated and can be converted into more protocol-owned liquidity through `addLiquidity(...)`.
- V6 removes the V5 post-deploy burn event/path from this hook; burning is a split-routing decision outside this hook.
- LP fee routing, fee-token claims, pool deployment, and liquidity growth have V6-specific events and errors.

## ABI, Event, and Error Changes

- Replaced interface:
  - `IUniV3DeploymentSplitHook` -> `IJBUniswapV4LPSplitHook`
- Removed V5 functions/events:
  - V5 `deployPool(projectId, terminalToken, amount0Min, amount1Min)` shape
  - `isAccumulationStage(...)`
  - `TokensBurned`
- Added or changed functions:
  - `initialize(...)`
  - `deployPool(uint256,uint256)`
  - `addLiquidity(uint256,address,uint256)`
  - `poolKeyOf(uint256,address)`
  - `isPoolDeployed(uint256,address)`
  - deployer `deployHookFor(...)`
  - deployer `setChainSpecificConstants(...)`
- Added or changed events:
  - `HookDeployed`
  - `ProjectDeployed` carries a V4 pool ID.
  - `LiquidityAdded`
  - `LPFeesRouted`
  - `FeeTokensClaimed`
- Added or migration-sensitive errors include:
  - V4 price-deviation / TWAP availability errors
  - deployer one-shot configuration errors
  - pool-deployment and liquidity-range validation errors

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: `nana-lp-split-hook-v5`.
- Own-source ABI artifacts compared: V6 `7`, V5 `2`.
- Contract/interface coverage: `7` added, `2` removed, `0` shared names with ABI changes, `0` shared names ABI-identical.
- Shared-name ABI item deltas: `0` added, `0` removed, `0` modified.

Added V6 ABI artifacts:
- `IJBUniswapV4LPSplitHook` from `src/interfaces/IJBUniswapV4LPSplitHook.sol`: `8` functions, `4` events, `0` errors.
- `IJBUniswapV4LPSplitHookDeployer` from `src/interfaces/IJBUniswapV4LPSplitHookDeployer.sol`: `7` functions, `1` events, `0` errors.
- `IREVOwner` from `src/JBUniswapV4LPSplitHook.sol`: `1` functions, `0` events, `0` errors.
- `JBLPSplitHookHelpers` from `src/libraries/JBLPSplitHookHelpers.sol`: `0` functions, `0` events, `0` errors.
- `JBUniswapV4LPSplitHook` from `src/JBUniswapV4LPSplitHook.sol`: `35` functions, `4` events, `28` errors.
- `JBUniswapV4LPSplitHookDeployer` from `src/JBUniswapV4LPSplitHookDeployer.sol`: `7` functions, `1` events, `3` errors.
- `JBUniswapV4LPSplitHookMath` from `src/libraries/JBUniswapV4LPSplitHookMath.sol`: `10` functions, `0` events, `3` errors.

Removed V5 ABI artifacts:
- `IUniV3DeploymentSplitHook` from `src/interfaces/IUniV3DeploymentSplitHook.sol`: `4` functions, `4` events, `0` errors.
- `UniV3DeploymentSplitHook` from `src/UniV3DeploymentSplitHook.sol`: `26` functions, `5` events, `16` errors.

Generated event/error name deltas:
- Event names added:
  - `FeeTokensClaimed`, `HookDeployed`, `LPFeesRouted`, `LiquidityAdded`, `ProjectDeployed`.
- Event names removed or replaced:
  - `FeeTokensClaimed`, `LPFeesRouted`, `OwnershipTransferred`, `ProjectDeployed`, `TokensBurned`.
- Error names added:
  - `JBMetadataResolver_DataNotPadded`, `JBMetadataResolver_MetadataTooLong`, `JBMetadataResolver_MetadataTooShort`, `JBPermissioned_Unauthorized`, `JBUniswapV4LPSplitHookDeployer_AlreadyConfigured`, `JBUniswapV4LPSplitHookDeployer_NotConfigured`, `JBUniswapV4LPSplitHookDeployer_Unauthorized`, `JBUniswapV4LPSplitHookMath_InvalidTickBounds`.
  - `JBUniswapV4LPSplitHookMath_NoTerminalTokenFound`, `JBUniswapV4LPSplitHook_AlreadyInitialized`, `JBUniswapV4LPSplitHook_ExistingPoolPriceOutOfBounds`, `JBUniswapV4LPSplitHook_FeePercentWithoutFeeProject`, `JBUniswapV4LPSplitHook_InsufficientBalance`, `JBUniswapV4LPSplitHook_InsufficientLiquidity`, `JBUniswapV4LPSplitHook_InvalidFeePercent`, `JBUniswapV4LPSplitHook_InvalidProjectId`.
  - `JBUniswapV4LPSplitHook_InvalidStageForAction`, `JBUniswapV4LPSplitHook_InvalidTerminalToken`, `JBUniswapV4LPSplitHook_NoTokensAccumulated`, `JBUniswapV4LPSplitHook_NotHookSpecifiedInContext`, `JBUniswapV4LPSplitHook_OnlyOneTerminalTokenSupported`, `JBUniswapV4LPSplitHook_Permit2AmountOverflow`, `JBUniswapV4LPSplitHook_PoolAlreadyDeployed`, `JBUniswapV4LPSplitHook_PriceDeviationTooHigh`.
  - `JBUniswapV4LPSplitHook_SplitSenderNotValidControllerOrTerminal`, `JBUniswapV4LPSplitHook_TemporaryAllowanceNotConsumed`, `JBUniswapV4LPSplitHook_TerminalNotFound`, `JBUniswapV4LPSplitHook_TerminalTokensNotAllowed`, `JBUniswapV4LPSplitHook_TwapUnavailable`, `JBUniswapV4LPSplitHook_UnclaimedFeeTokenChanged`, `JBUniswapV4LPSplitHook_ZeroLiquidity`, `PRBMath_MulDiv_Overflow`.
  - `SafeERC20FailedOperation`.
- Error names removed or replaced:
  - `JBPermissioned_Unauthorized`, `OwnableInvalidOwner`, `OwnableUnauthorizedAccount`, `PRBMath_MulDiv_Overflow`, `SafeERC20FailedOperation`, `UniV3DeploymentSplitHook_InvalidFeePercent`, `UniV3DeploymentSplitHook_InvalidProjectId`, `UniV3DeploymentSplitHook_InvalidStageForAction`.
  - `UniV3DeploymentSplitHook_InvalidTerminalToken`, `UniV3DeploymentSplitHook_NoTokensAccumulated`, `UniV3DeploymentSplitHook_NotHookSpecifiedInContext`, `UniV3DeploymentSplitHook_PoolAlreadyDeployed`, `UniV3DeploymentSplitHook_SplitSenderNotValidControllerOrTerminal`, `UniV3DeploymentSplitHook_TerminalTokensNotAllowed`, `UniV3DeploymentSplitHook_UnauthorizedBeneficiary`, `UniV3DeploymentSplitHook_ZeroAddressNotAllowed`.

## Migration Notes

- Treat this as a V3-to-V4 architecture migration. V5 pool addresses and V3 min-amount assumptions do not map directly.
- Regenerate ABIs from V6 and update indexers for `LiquidityAdded` instead of V5 `TokensBurned`.
- If you operated the V5 hook, re-evaluate permissions around `SET_BUYBACK_POOL` and V6 post-deploy liquidity growth.
