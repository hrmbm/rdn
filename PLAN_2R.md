# Checkpoint 2R — Plan

## Scope approved
- A: optimize the incentive recap calendar path without changing formulae or JSON output.
- B: investigate dashboard/pending-approval latency; only adopt changes supported by measured plans and parity tests.
- C: recover deleted migration history and document the current database baseline.

## Guardrails
- Repository: `hrmbm/rdn`; working branch: `checkpoint-2r/performance-recap-dashboard`; base: `main`.
- Supabase project: `reholz/hris` (`dzfjtnqitwfbihaasmot`).
- No writes, DDL, deployment, or migration execution on the active Supabase project under the current "review" policy.
- No merge to `main` or production deployment in this checkpoint.
- Preserve incentive formulas, attendance classification, JSON keys, sorting, and role-based visibility.

## Implementation
1. Materialize employee/date calendar base rows and distinct (date, branch) keys; resolve each day type once and reuse it across employees.
2. Benchmark dashboard pending-approval query alternatives. Retain the current RPC because the UNION ALL experiment did not show a reliable performance gain.
3. Restore the two SQL migrations removed from repository history; restoration is archival only, not an instruction to re-run them.
4. Record test evidence, limitations, and a change ledger.
