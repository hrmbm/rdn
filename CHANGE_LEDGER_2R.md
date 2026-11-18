# Checkpoint 2R — Change Ledger

| Item | Change | State | Safety |
|---|---|---|---|
| Branch | Created `checkpoint-2r/performance-recap-dashboard` from `main` | Done | No main-branch change |
| Incentive SQL | Materialized date/branch calendar resolution | Prepared for review | Not applied to Supabase |
| Approvals SQL | Split role/status predicates into UNION ALL branches | Prepared for review | Not applied to Supabase |
| Migration 001 | Restored `001_area_surabaya_sekitarnya.sql` | Archived | Do not replay without schema diff |
| Migration 002 | Restored `002_admin_personal_attendance.sql` | Archived | Do not replay without schema diff |
| Frontend | No source edits | Blocked | `index.html` is 0 bytes |
| Database | No DDL or writes | Unchanged | Review gate honored |
| Deployment/merge | None | Not performed | Awaiting review |
