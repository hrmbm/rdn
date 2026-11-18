# Checkpoint 2R — Investigation and Repair Report

## Environment
- GitHub: `hrmbm/rdn`, base `main`, working branch `checkpoint-2r/performance-recap-dashboard`.
- Supabase: project `reholz/hris`, ref `dzfjtnqitwfbihaasmot`, PostgreSQL 17.
- No production database writes or deployment performed.

## Findings
1. Incentive recap: the active calculation repeatedly resolves the same day type per employee/date and again inside schedule-rule predicates. Prior request telemetry showed roughly 18.46 seconds average upstream execution. The day-type helper alone was about 5.87 ms for a single sample and 753 shared buffer hits.
2. Pending approvals: earlier telemetry showed roughly 751 ms mean upstream and 1.95 s p95. Existing indexes and the bitmap plan support the current OR predicates. A UNION ALL rewrite was tested but not adopted: the cuti sample plan was about 69 ms vs 46 ms for the current query; absensi was about 3.0 ms vs 2.8 ms. There is no measured basis to ship that rewrite.
3. Migration tracking: the standard Supabase migration ledger is absent/empty, while feature migration metadata exists. Two SQL migrations were deleted from Git history and are restored here for audit continuity only.

## Repair
- A: materialized employee/date base rows and distinct date/branch calendar keys, then reused one resolved day type per key.
- B: investigated query-plan alternatives and retained the current pending-approval RPC because the alternative did not show a performance win.
- C: restored historical migrations and added plan, walkthrough, checkpoint, report, tests, and change ledger.

## Performance evidence
For the isolated period-calendar query over the 2026-11-01..2026-11-18 window (625 employee/date rows), one EXPLAIN ANALYZE sample measured 99.66 ms for the original repeated-resolution form and 32.11 ms for the materialized form. The materialized form resolved 54 distinct date/branch keys. This is a calendar-subquery benchmark, not a full incentive RPC before/after result.

## Safety and limitations
- SQL is staged in `supabase/review/`, not executed.
- No frontend change was made. The tracked `index.html` currently has 0 bytes; there is no safe source to edit or run dashboard runtime tests against.
- No full live before/after RPC latency claim is made. The existing incentive baseline is captured by hash, but parity after the SQL replacement must be verified after approval on an isolated database branch or through a separately approved migration.
