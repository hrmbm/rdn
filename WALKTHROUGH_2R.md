# Checkpoint 2R — Walkthrough

## A — Incentive recap
The active `hris_incentive_calculate(date,date,text)` repeatedly invokes `attendance_resolved_day_type(date,branch)` in the period calendar and inside schedule-rule predicates. The revised CTE chain materializes distinct date/branch pairs and materializes one resolved day type per pair, then reuses that value for all employee rows and schedule predicates. The calculation/rate formulas and output assembly remain untouched.

## B — Pending approvals
The active `get_pending_approvals(text)` combines role-dependent predicates with OR. The proposed replacement expresses the same mutually exclusive role/status cases as `UNION ALL` branches. JSON aggregation remains ordered by the original timestamp descending. The session lookup, SECURITY DEFINER setting, search_path, JSON keys, and total calculation are retained.

## C — Migration history
The repository had two migration files deleted in commit `03be64c5aaab5368582e4b08aad073996d9931ea`. Their exact prior contents are restored in this branch. Supabase `supabase_migrations.schema_migrations` is absent and `list_migrations` is empty, while `public.hris_feature_migrations` exists. This does not prove that the live schema was not applied manually. Restored migrations must not be replayed without schema-diff review.

## Frontend boundary
The current `main/index.html` is an empty file (0 bytes), and the repository does not contain the runtime application source at that path. Therefore no dashboard UI/request-sequencing change can be safely authored or tested in this repository snapshot. This checkpoint limits B to the database RPC definition and records the source gap explicitly.
