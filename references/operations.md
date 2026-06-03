# UniV4 LP Split Hook Operations

## Deployment surface

- [`src/JBUniswapV4LPSplitHookDeployer.sol`](../src/JBUniswapV4LPSplitHookDeployer.sol) is the first stop for clone deployment, salts, and registry provenance.
- [`script/Deploy.s.sol`](../script/Deploy.s.sol) is the deployment entry point when current environment wiring matters.
- `src/interfaces/` and [`test/TestBaseV4.sol`](../test/TestBaseV4.sol) are useful when the issue is integration or harness setup.

## Change checklist

- If you edit deployment behavior, verify fee-project and fee-percent initialization, the immutable implementation address, one-shot V4 constants, same-address CREATE2 assumptions, and address-registry registration.
- If you edit deployPool or rebalance logic, check permission gates and weight-decay assumptions together.
- If you edit `addLiquidity`, top-up vs. re-range, or the TWAP guard, re-check the decay-gated authorization, the `_MAX_TWAP_DEVIATION_TICKS` / `_RERANGE_THRESHOLD_TICKS` thresholds, the force-direct cash-out metadata, and the re-range burn-and-re-mint (`_retireActivePosition`) together.
- If you edit fee collection, confirm the project-token fee carry-into-accumulation and terminal-token routing still align; there is only ever one active position per pair (re-range burns + re-mints).

## Common failure modes

- A runtime issue is blamed on the hook when the clone was deployed with the wrong fee or provenance assumptions.
- Rebalancing changes look safe locally but alter fee routing or leftover handling.
- The repo is blamed for oracle behavior that actually originates in the paired UniV4 router hook.
