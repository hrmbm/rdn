# Checkpoint 2R — Plan

## Scope approved
- A: optimize the incentive recap calendar path without changing formulae or JSON output.
- B: optimize pending-approval RPC query paths while preserving role visibility.
- C: recover deleted migration history and document the current database baseline.

## Guardrails
- Repository: `hrmbm/rdn`; working branch: `checkpoint-2r/performance-recap-dashboard`; base: `main`.
- Supabase project: `reholz/hris` (`dzfjtnqitwfbihaasmot`).
- No writes, DDL, deployment, or migration execution on the active Supabase project under the current "review" policy.
- No merge to `main` or production deployment in this checkpoint.
- Preserve incentive formulas, attendance classification, JSON keys, sorting, and role-based visibility.

## Implementation
1. Materialize distinct (date, branch) calendar keys, resolve each day type once, and reuse that value across employees.
2. Split `get_pending_approvals` filters into mutually exclusive `UNION ALL` branches to expose existing indexes.
3. Restore the two SQL migrations removed from repository history; restoration is archival only, not an instruction to re-run them.
4. Record test evidence, limitations, and a change ledger.
