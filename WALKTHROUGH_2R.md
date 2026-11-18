# Checkpoint 2R — Walkthrough

## A — Incentive recap
The active `hris_incentive_calculate(date,date,text)` repeatedly invokes `attendance_resolved_day_type(date,branch)` in the period calendar and inside schedule-rule predicates. The revised CTE chain materializes the employee/date base and distinct date/branch keys, then materializes one resolved day type per key and reuses it for all employee rows and schedule predicates. The calculation/rate formulas and output assembly remain untouched.

## B — Dashboard and pending approvals
The active `get_pending_approvals(text)` uses OR predicates across role/status cases. I tested an alternative with mutually exclusive `UNION ALL` branches and verified JSON parity for sampled roles. However, the observed plan for the cuti queue was slower in this sample (about 69 ms vs 46 ms); the absensi path was essentially unchanged (about 3.0 ms vs 2.8 ms). Therefore the alternative was rejected and the production RPC definition is not changed in this patch. The dashboard UI/request-sequencing layer also cannot be changed safely because the tracked `index.html` is empty.

## C — Migration history
The repository had two migration files deleted in commit `03be64c5aaab5368582e4b08aad073996d9931ea`. Their exact prior contents are restored in this branch. Supabase `supabase_migrations.schema_migrations` is absent and `list_migrations` is empty, while `public.hris_feature_migrations` exists. This does not prove that the live schema was not applied manually. Restored migrations must not be replayed without schema-diff review.
