# UniV4 LP Split Hook Operations

## Deployment surface

- [`src/JBUniswapV4LPSplitHookDeployer.sol`](../src/JBUniswapV4LPSplitHookDeployer.sol) is the first stop for clone deployment, salts, and registry provenance.
- [`script/Deploy.s.sol`](../script/Deploy.s.sol) is the deployment entry point when current environment wiring matters.
- `src/interfaces/` and [`test/TestBaseV4.sol`](../test/TestBaseV4.sol) are useful when the issue is integration or harness setup.

## Change checklist

- If you edit deployment behavior, verify fee-project and fee-percent initialization, the immutable implementation address, one-shot V4 constants, same-address CREATE2 assumptions, and address-registry registration.
- If you edit deployPool or the recycle, check the economic gate (spot vs. issuance ceiling), the oracle-TWAP guard, the ask/bid range clamps in `_recycle`, and the cash-out-price floor derivation together.
- If you edit `addLiquidity`, inline automation, or the TWAP guard, re-check the permissionless entry, the `_MIN_ADD_ACCUMULATION` threshold, `_MAX_TWAP_DEVIATION_TICKS`, `_AUTOMATION_GAS_BUDGET` (2,000,000, both the minimum to start the attempt and the cap forwarded to it, so the caller's later splits keep their gas; cold through the clone, `MultiTerminalRecycleFork` measures about 1.28M with one terminal plus about 30k per extra terminal, covering about 20 terminals), and `_recycle` (which retires the ask and bid and re-mints both single-sided) together.
- If you edit fee collection, confirm the best-effort `feeProjectId` cut still applies symmetrically to both the project-token and terminal-token sides, that the terminal-token remainder is still added to the project's balance and the project-token remainder burned, that `sendToTerminal` (and the fee-token claim) still revert `TransferNotExact` when the hook is debited more than it sent, and that a reverting route still falls back to the correct per-project ledger (`accumulatedTerminalTokens`, `accumulatedProjectTokens`) without blocking collection; fees are collected from both `askTokenIdOf` and `bidTokenIdOf`.
- If you edit `processSplitWith`, re-check both branches: reserved tokens (group 1, controller only, no value, `_MIN_ADD_ACCUMULATION` gate) and payouts (`_acceptPayout`: token group, project terminal, deployed pool, pool terminal token, value or pull, no threshold).

## Common failure modes

- A runtime issue is blamed on the hook when the clone was deployed with the wrong fee or provenance assumptions.
- Recycle changes look safe locally but alter fee routing, leftover handling, or which side a token lands on.
- A test or integration reads a single `tokenIdOf` position id; this hook tracks `askTokenIdOf` and `bidTokenIdOf`.
- The repo is blamed for oracle behavior that actually originates in the paired UniV4 router hook.
