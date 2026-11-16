# Held fallbacks: no try/catch branch may redirect value

- [x] Refactor first: extract the pay-and-reconcile block of `_attemptFeeProjectCut` into `_routeFeeCut`
      (behavior-preserving), so a retry can reuse it.
- [x] A fee-project cut whose `pay` reverts is held in `heldFeeCutOf[projectId][feeToken]` instead of being forgiven
      back to the project, and excluded from spendable balance. `processHeldFeeCutOf` retries with no catch.
      A fee project with no terminal for the token still forgives (deterministic, not gas-dependent).
- [ ] Tests: out of scope for this PR.
