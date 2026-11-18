# Checkpoint 2R — Test Results

## Read-only tests executed against the active project

| Test | Result |
|---|---|
| Incentive baseline, 2026-11-01 to 2026-11-18 | 37 records; payload 151,937 chars; MD5 `8d1f315ee15b42925bb5ea37d2e0be56` |
| Period calendar equivalence | Old 625 rows; proposed 625 rows; old-only 0; new-only 0 |
| Distinct resolved calendar keys | 54 keys for 625 employee/date rows |
| Pending approvals parity — ADMIN | absensi identical (10 rows); cuti identical (9 rows) |
| Pending approvals parity — KARYAWAN | absensi identical (0 rows); cuti identical (0 rows) |
| Pending approvals parity — SUPERADMIN | absensi identical (0 rows); cuti identical (0 rows) |
| Cuti plan, current OR query | ~45.7 ms; bitmap OR over existing status indexes |
| Cuti plan, UNION ALL experiment | ~69.5 ms; two branch scans plus append |
| Absensi plan, current OR query | ~2.8 ms |
| Absensi plan, UNION ALL experiment | ~3.0 ms |

## Not yet tested
- Full post-change incentive output hash and latency, because active database DDL is gated.
- Production RPC execution after replacement.
- Browser/dashboard runtime and request sequencing, because the current tracked `index.html` is empty.
- End-to-end authenticated session calls for all individual accounts.

## Interpretation
The calendar equivalence test supports that the proposed materialization preserves day_type, is_workday, and schedule_known for the tested 2026-11-01..2026-11-18 employee/date set. The pending-approval parity test supports exact JSON array equality for the sampled employee in each role on current data. The UNION ALL experiment was not adopted because the plan sample did not improve. These tests are not a substitute for full regression after the incentive SQL is applied to an isolated copy.
