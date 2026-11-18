-- CHECKPOINT 2R — REVIEW ONLY; DO NOT APPLY TO ACTIVE SUPABASE WITHOUT A SEPARATE APPROVAL.
-- Target project: dzfjtnqitwfbihaasmot (reholz/hris), PostgreSQL 17.
-- This patch preserves incentive formulas and role predicates. See TEST_RESULTS_2R.md.
BEGIN;

CREATE OR REPLACE FUNCTION public.hris_incentive_calculate(p_start_date date, p_end_date date, p_employee_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_formula public.incentive_formula_versions%ROWTYPE;
  v_records jsonb;
  v_cfg jsonb;
  v_reimbursement_entertain_limit numeric(14,2);
  v_reimbursement_transport_limit numeric(14,2);
BEGIN
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_start_date > p_end_date
     OR (p_end_date - p_start_date) > 62 THEN
    RAISE EXCEPTION 'Rentang periode insentif tidak valid (maksimal 63 hari inklusif).' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_formula
  FROM public.incentive_formula_versions
  WHERE effective_from <= p_end_date
  ORDER BY effective_from DESC, version_no DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Belum ada formula yang efektif untuk periode ini. Simpan formula backend terlebih dahulu.' USING ERRCODE = 'P0002';
  END IF;
  v_cfg := v_formula.config;
  SELECT entertain_limit,transport_limit INTO v_reimbursement_entertain_limit,v_reimbursement_transport_limit
  FROM public.incentive_reimbursement_limits WHERE id=1;

  WITH employees AS (
    SELECT k.employee_id, k.nama, k.branch, k.organization, k.job_position, k.job_code, k.bank_name, k.bank_account, k.join_date, k.contract_end_date
    FROM public.karyawan k
    WHERE k.status_akun = 'AKTIF'
      AND (p_employee_id IS NULL OR k.employee_id = p_employee_id)
  
      AND NOT EXISTS (
        SELECT 1
        FROM public.incentive_employee_exclusions AS exclusion
        WHERE exclusion.employee_id = k.employee_id
          AND exclusion.is_excluded = true
      )
), raw_events AS (
    SELECT a.*
    FROM public.absensi a
    JOIN employees e ON e.employee_id = a.employee_id
    WHERE a.tanggal BETWEEN p_start_date AND p_end_date
  ), daily0 AS (
    SELECT
      a.employee_id, a.tanggal,
      min(a.jam) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_in,
      max(a.jam) FILTER (WHERE a.tipe='PULANG' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_out,
      max(a.status_approval) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_in_status,
      max(a.status_approval) FILTER (WHERE a.tipe='PULANG' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_out_status,
      bool_or(a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS valid_clock_in,
      bool_or(a.tipe='PULANG' AND a.status_approval IN ('VALID','DISETUJUI')) AS valid_clock_out,
      bool_or(a.status_approval IN ('VALID','DISETUJUI')) AS any_final,
      bool_or(a.status_approval IN ('PENDING_ATASAN','PENDING_HR')) AS has_pending,
      bool_or(a.status_approval IN ('DITOLAK_ATASAN','DITOLAK_HR')) AS has_rejected,
      bool_or(a.outside_location) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_in_outside,
      bool_or(a.outside_location) FILTER (WHERE a.tipe='PULANG' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_out_outside,
      -- Prefer Clock In area, otherwise accept approved Clock Out area.
      COALESCE(
        max(a.area) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI') AND a.outside_location IS TRUE AND a.area IS NOT NULL),
        max(a.area) FILTER (WHERE a.tipe='PULANG' AND a.status_approval IN ('VALID','DISETUJUI') AND a.outside_location IS TRUE AND a.area IS NOT NULL)
      ) AS area,
      count(DISTINCT a.area) FILTER (WHERE a.tipe IN ('MASUK','PULANG') AND a.status_approval IN ('VALID','DISETUJUI') AND a.outside_location IS TRUE AND a.area IS NOT NULL) AS area_count,
      substring(max(a.catatan) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI'))
        FROM '\[\[RHATT=(P[1-5]?|SDL[1-5]|SDLL)\]\]') AS attendance_marker,
      max(a.punctuality_status) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS punctuality_status,
      max(a.scheduled_check_in_snapshot) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS scheduled_check_in,
      max(a.late_tolerance_minutes_snapshot) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS late_tolerance_minutes,
      count(*) AS event_count,
      string_agg(DISTINCT a.status_approval, ', ' ORDER BY a.status_approval) AS statuses
    FROM raw_events a
    GROUP BY a.employee_id, a.tanggal
  ), sick_outside_days AS (
    SELECT c.employee_id::text AS employee_id, g.dt::date AS tanggal,
      NULL::time AS clock_in, NULL::time AS clock_out,
      NULL::text AS clock_in_status, NULL::text AS clock_out_status,
      FALSE AS valid_clock_in, FALSE AS valid_clock_out, FALSE AS any_final,
      FALSE AS has_pending, FALSE AS has_rejected,
      FALSE AS clock_in_outside, FALSE AS clock_out_outside,
      c.area_sakit::text AS area, 1::bigint AS area_count,
      NULL::text AS attendance_marker, NULL::text AS punctuality_status,
      NULL::time AS scheduled_check_in, NULL::integer AS late_tolerance_minutes,
      0::bigint AS event_count, 'APPROVED_SDR_DL'::text AS statuses,
      TRUE AS sick_outside
    FROM public.pengajuan_cuti c
    CROSS JOIN LATERAL generate_series(c.tanggal_mulai,c.tanggal_selesai,interval '1 day') g(dt)
    JOIN employees e ON e.employee_id=c.employee_id
    CROSS JOIN LATERAL (
      SELECT COALESCE((
        SELECT bh.branch
        FROM public.attendance_employee_branch_history bh
        WHERE bh.employee_id=c.employee_id
          AND bh.effective_from<=g.dt::date
          AND (bh.effective_to IS NULL OR bh.effective_to>=g.dt::date)
        ORDER BY bh.effective_from DESC LIMIT 1
      ), NULLIF(BTRIM(e.branch),''), 'Pusat') AS day_branch
    ) branch_at_day
    JOIN LATERAL (
      SELECT sr.is_workday
      FROM public.attendance_schedule_rules sr
      WHERE LOWER(BTRIM(sr.branch))=LOWER(BTRIM(branch_at_day.day_branch))
        AND sr.effective_from<=g.dt::date
        AND (sr.effective_to IS NULL OR sr.effective_to>=g.dt::date)
        AND (
          public.attendance_resolved_day_type(g.dt::date,branch_at_day.day_branch) NOT IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF')
          OR (EXTRACT(ISODOW FROM g.dt::date)::integer=7
              AND public.attendance_resolved_day_type(g.dt::date,branch_at_day.day_branch)='WORKING_DAY')
        )
        AND (
          sr.day_of_week=EXTRACT(ISODOW FROM g.dt::date)::integer
          OR (EXTRACT(ISODOW FROM g.dt::date)::integer=7
              AND public.attendance_resolved_day_type(g.dt::date,branch_at_day.day_branch)='WORKING_DAY'
              AND sr.day_of_week BETWEEN 1 AND 6 AND sr.is_workday=TRUE)
        )
        AND NOT (
          EXTRACT(ISODOW FROM g.dt::date)::integer=7
          AND public.attendance_resolved_day_type(g.dt::date,branch_at_day.day_branch)='WORKING_DAY'
          AND sr.day_of_week=7 AND sr.is_workday=FALSE
        )
      ORDER BY CASE WHEN sr.day_of_week=EXTRACT(ISODOW FROM g.dt::date)::integer THEN 0 ELSE 1 END,
               sr.effective_from DESC,sr.day_of_week
      LIMIT 1
    ) schedule_for_day ON schedule_for_day.is_workday=TRUE
    WHERE c.kode_cuti='SDR' AND c.dinas_luar_sakit IS TRUE
      AND c.area_sakit IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')
      AND c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI'
      AND g.dt::date BETWEEN p_start_date AND p_end_date
      AND NOT EXISTS (SELECT 1 FROM daily0 d WHERE d.employee_id=c.employee_id AND d.tanggal=g.dt::date)
  ), daily_seed AS (
    SELECT d.*,
      EXISTS (SELECT 1 FROM public.pengajuan_cuti c WHERE c.employee_id=d.employee_id
        AND c.kode_cuti='SDR' AND c.dinas_luar_sakit IS TRUE AND c.area_sakit IS NOT NULL
        AND c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI'
        AND c.tanggal_mulai<=d.tanggal AND c.tanggal_selesai>=d.tanggal) AS sick_outside,
      COALESCE((SELECT c.area_sakit FROM public.pengajuan_cuti c WHERE c.employee_id=d.employee_id
        AND c.kode_cuti='SDR' AND c.dinas_luar_sakit IS TRUE AND c.area_sakit IS NOT NULL
        AND c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI'
        AND c.tanggal_mulai<=d.tanggal AND c.tanggal_selesai>=d.tanggal
        ORDER BY c.tanggal_mulai DESC, c."timestamp" DESC LIMIT 1),d.area) AS effective_area
    FROM daily0 d
    UNION ALL
    SELECT sd.*, sd.area AS effective_area FROM sick_outside_days sd
  ), day0 AS (
    SELECT d.*,
      CASE WHEN d.sick_outside THEN TRUE
           WHEN d.effective_area='Surabaya & Sekitarnya' THEN FALSE
           ELSE (coalesce(d.clock_in_outside,false) OR coalesce(d.clock_out_outside,false)) END AS outside_flag,
      EXISTS (
        SELECT 1 FROM public.pengajuan_cuti c
        WHERE c.employee_id=d.employee_id
          AND c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI'
          AND c.tanggal_mulai <= d.tanggal AND c.tanggal_selesai >= d.tanggal
          AND NOT (d.sick_outside AND c.kode_cuti='SDR' AND c.dinas_luar_sakit IS TRUE AND c.area_sakit=d.effective_area)
      ) AS timeoff_conflict
    FROM daily_seed d
  ), classified AS (
    SELECT d.*,
      CASE
        WHEN d.sick_outside AND d.effective_area='Area 1' THEN 'SDR-DL1'
        WHEN d.sick_outside AND d.effective_area='Area 2' THEN 'SDR-DL2'
        WHEN d.sick_outside AND d.effective_area='Area 3' THEN 'SDR-DL3'
        WHEN d.sick_outside AND d.effective_area='Area 4' THEN 'SDR-DL4'
        WHEN d.sick_outside AND d.effective_area='Area lainnya' THEN 'SDR-DLL'
        WHEN d.attendance_marker IS NOT NULL THEN d.attendance_marker
        WHEN d.outside_flag AND d.effective_area='Area 1' THEN 'DL1'
        WHEN d.outside_flag AND d.effective_area='Area 2' THEN 'DL2'
        WHEN d.outside_flag AND d.effective_area='Area 3' THEN 'DL3'
        WHEN d.outside_flag AND d.effective_area='Area 4' THEN 'DL4'
        WHEN d.outside_flag AND d.effective_area='Area lainnya' THEN 'DL5'
        WHEN d.any_final THEN 'H'
        ELSE '—'
      END AS attendance_code,
      CASE d.effective_area
        WHEN 'Area 1' THEN 'AREA 1' WHEN 'Area 2' THEN 'AREA 2'
        WHEN 'Area 3' THEN 'AREA 3' WHEN 'Area 4' THEN 'AREA 4'
        WHEN 'Area lainnya' THEN 'AREA LAIN' ELSE NULL END AS area_rate_key,
      CASE
        WHEN d.punctuality_status IN ('EARLY','ON_TIME') THEN TRUE
        WHEN d.punctuality_status='LATE' THEN FALSE
        WHEN d.clock_in IS NOT NULL AND d.scheduled_check_in IS NOT NULL
          AND d.late_tolerance_minutes IS NOT NULL
          THEN d.clock_in <= (d.scheduled_check_in + make_interval(mins => d.late_tolerance_minutes))::time
        ELSE FALSE
      END AS on_time_by_snapshot
    FROM day0 d
  ), rated AS (
    SELECT c.*,
      CASE WHEN c.sick_outside OR (c.attendance_code IN ('SDL1','SDL2','SDL3','SDL4','SDL5','SDLL')
                 AND coalesce((v_cfg->'eligibility'->>'standby_as_outside')::boolean,true))
          OR (c.outside_flag AND c.attendance_code IN ('DL1','DL2','DL3','DL4','DL5'))
        THEN NULLIF(v_cfg->'outside_rates'->c.area_rate_key->>upper(coalesce(e.job_code,'')),'')::numeric
        ELSE NULL END AS outside_rate,
      (NOT c.sick_outside AND (c.attendance_marker = 'P' OR c.attendance_marker IN ('P1','P2','P3','P4','P5'))) AS is_picket,
      (NOT c.sick_outside AND c.attendance_marker IN ('SDL1','SDL2','SDL3','SDL4','SDL5','SDLL')) AS is_standby,
      (c.any_final AND NOT c.timeoff_conflict AND NOT c.sick_outside) AS attendance_eligible,
      (c.any_final AND NOT c.timeoff_conflict AND NOT c.sick_outside AND NOT c.outside_flag
        AND coalesce(c.attendance_marker,'') NOT IN ('P1','P2','P3','P4','P5','SDL1','SDL2','SDL3','SDL4','SDL5','SDLL')) AS transport_eligible,
      (c.any_final AND NOT c.timeoff_conflict AND NOT c.sick_outside) AS phone_eligible,
      (c.valid_clock_in AND NOT c.timeoff_conflict AND NOT c.sick_outside AND NOT c.outside_flag
        AND c.on_time_by_snapshot) AS meal_eligible,
      ((c.sick_outside OR c.any_final) AND NOT c.timeoff_conflict AND (c.sick_outside OR c.area_count <= 1)
        AND (c.sick_outside OR c.outside_flag) AND c.area_rate_key IS NOT NULL
        AND (c.sick_outside OR c.attendance_code IN ('DL1','DL2','DL3','DL4','DL5')
          OR (c.attendance_code IN ('SDL1','SDL2','SDL3','SDL4','SDL5','SDLL')
            AND coalesce((v_cfg->'eligibility'->>'standby_as_outside')::boolean,true)))) AS outside_eligible,
      CASE
        WHEN NOT c.sick_outside AND c.clock_in IS NOT NULL AND c.clock_out IS NOT NULL AND c.clock_out > c.clock_in
         AND c.clock_in_status='DISETUJUI' AND c.clock_out_status IN ('VALID','DISETUJUI')
         AND NOT c.timeoff_conflict AND c.area_count <= 1
         AND ((c.attendance_marker='P' AND (NOT coalesce(c.clock_in_outside,false) OR c.effective_area='Surabaya & Sekitarnya'))
           OR (c.attendance_marker IN ('P1','P2','P3','P4','P5') AND coalesce(c.clock_in_outside,false)))
        THEN CASE
          WHEN floor(extract(epoch FROM (c.clock_out-c.clock_in))/3600)::integer >= coalesce((v_cfg->>'piket_min_hours')::integer,4)
          THEN least(coalesce((v_cfg->>'piket_max_hours')::integer,8),
               floor(extract(epoch FROM (c.clock_out-c.clock_in))/3600)::integer)
          ELSE 0
        END
        ELSE 0
      END AS picket_paid_hours
    FROM classified c
    JOIN employees e ON e.employee_id=c.employee_id
  ), daily_calc AS (
    SELECT r.*, e.nama, e.branch, e.organization, e.job_position, e.job_code,
      CASE WHEN r.meal_eligible THEN
        CASE WHEN upper(coalesce(e.job_code,''))='OB' THEN coalesce((v_cfg->>'meal_ob')::numeric,0)
             ELSE coalesce((v_cfg->>'meal_other')::numeric,0) END
      ELSE 0 END AS meal_amount_day,
      CASE WHEN r.outside_eligible AND r.outside_rate IS NOT NULL THEN r.outside_rate ELSE 0 END AS outside_amount_day,
      CASE WHEN r.is_picket AND r.picket_paid_hours >= coalesce((v_cfg->>'piket_min_hours')::integer,4)
        THEN r.picket_paid_hours * coalesce((v_cfg->>'piket_hourly_rate')::numeric,15000) ELSE 0 END AS picket_amount_day,
      (r.is_picket AND r.picket_paid_hours >= coalesce((v_cfg->>'piket_min_hours')::integer,4)) AS picket_eligible,
      array_remove(ARRAY[
        CASE WHEN r.timeoff_conflict THEN 'Konflik: ada absensi pada tanggal Time Off final; hari dikecualikan.' END,
        CASE WHEN r.area_count > 1 AND NOT r.sick_outside THEN 'Konflik area: lebih dari satu Area pada tanggal yang sama; tarif area dan Piket dikecualikan.' END,
        CASE WHEN r.has_pending THEN 'Ada event absensi yang masih menunggu approval; event pending tidak dihitung.' END,
        CASE WHEN r.has_rejected THEN 'Ada event absensi yang ditolak; event tersebut tidak dihitung.' END,
        CASE WHEN r.outside_flag AND NOT r.sick_outside AND r.area IS NULL THEN 'Dinas luar tanpa Area tervalidasi pada Clock In/Clock Out; tarif DL tidak dihitung.' END,
        CASE WHEN r.sick_outside AND (r.outside_rate IS NULL OR r.outside_rate <= 0) THEN 'Tarif SDR-DL belum aktif: periksa kombinasi Area dan Kode Jabatan pada Formula Insentif.' END,
        CASE WHEN r.outside_eligible AND (r.outside_rate IS NULL OR r.outside_rate <= 0) THEN 'Tarif DL untuk kombinasi Area/Job Code kosong atau nol; nominal tidak dibayarkan.' END,
        CASE WHEN r.valid_clock_in AND r.clock_in IS NOT NULL AND r.punctuality_status IS NULL AND r.scheduled_check_in IS NULL THEN 'Uang makan tidak dihitung: snapshot jadwal masuk tidak tersedia.' END,
        CASE WHEN r.is_picket AND (r.clock_in IS NULL OR r.clock_out IS NULL) THEN 'Piket belum memiliki pasangan Clock In dan Clock Out; jam Piket belum dapat dihitung.' END,
        CASE WHEN r.is_picket AND r.clock_in IS NOT NULL AND r.clock_out IS NOT NULL AND r.clock_out <= r.clock_in THEN 'Durasi Piket tidak valid: Clock Out tidak setelah Clock In.' END,
        CASE WHEN r.is_picket AND r.clock_in IS NOT NULL AND r.clock_out IS NOT NULL AND r.clock_out > r.clock_in
          AND r.picket_paid_hours < coalesce((v_cfg->>'piket_min_hours')::integer,4) THEN 'Durasi Piket di bawah 4 jam; nominal Piket Rp0.' END,
        CASE WHEN r.is_picket AND r.clock_in_status IS DISTINCT FROM 'DISETUJUI' THEN 'Piket belum mendapat persetujuan final; nominal Piket tidak dihitung.' END,
        CASE WHEN nullif(btrim(e.job_code),'') IS NULL AND r.outside_flag THEN 'Job Code kosong; tarif dinas luar tidak dihitung.' END
      ], NULL) AS day_warnings
    FROM rated r JOIN employees e ON e.employee_id=r.employee_id
  ), period_calendar_base AS (
    SELECT e.employee_id, g.dt::date AS tanggal,
      COALESCE((
        SELECT bh.branch
        FROM public.attendance_employee_branch_history bh
        WHERE bh.employee_id=e.employee_id
          AND bh.effective_from<=g.dt::date
          AND (bh.effective_to IS NULL OR bh.effective_to>=g.dt::date)
        ORDER BY bh.effective_from DESC LIMIT 1
      ), NULLIF(BTRIM(e.branch),''), 'Pusat') AS day_branch
    FROM employees e
    CROSS JOIN LATERAL generate_series(p_start_date,p_end_date,interval '1 day') g(dt)
    WHERE (e.join_date IS NULL OR g.dt::date>=e.join_date)
      AND (e.contract_end_date IS NULL OR g.dt::date<=e.contract_end_date)
  ), period_calendar_keys AS MATERIALIZED (
    SELECT DISTINCT tanggal, day_branch
    FROM period_calendar_base
  ), period_calendar_day_types AS MATERIALIZED (
    SELECT k.tanggal, k.day_branch,
      public.attendance_resolved_day_type(k.tanggal,k.day_branch) AS day_type
    FROM period_calendar_keys k
  ), period_calendar AS (
    SELECT b.employee_id, b.tanggal, b.day_branch,
      day_types.day_type AS day_type,
      COALESCE(schedule_for_day.is_workday,FALSE)
        AND day_types.day_type NOT IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF') AS is_workday,
      (schedule_for_day.is_workday IS NOT NULL) AS schedule_known
    FROM period_calendar_base b
    JOIN period_calendar_day_types day_types
      ON day_types.tanggal=b.tanggal
     AND day_types.day_branch=b.day_branch
    LEFT JOIN LATERAL (
      SELECT sr.is_workday
      FROM public.attendance_schedule_rules sr
      WHERE LOWER(BTRIM(sr.branch))=LOWER(BTRIM(b.day_branch))
        AND sr.effective_from<=b.tanggal
        AND (sr.effective_to IS NULL OR sr.effective_to>=b.tanggal)
        AND (
          day_types.day_type NOT IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF')
          OR (EXTRACT(ISODOW FROM b.tanggal)::integer=7
              AND day_types.day_type='WORKING_DAY')
        )
        AND (
          sr.day_of_week=EXTRACT(ISODOW FROM b.tanggal)::integer
          OR (EXTRACT(ISODOW FROM b.tanggal)::integer=7
              AND day_types.day_type='WORKING_DAY'
              AND sr.day_of_week BETWEEN 1 AND 6 AND sr.is_workday=TRUE)
        )
        AND NOT (
          EXTRACT(ISODOW FROM b.tanggal)::integer=7
          AND day_types.day_type='WORKING_DAY'
          AND sr.day_of_week=7 AND sr.is_workday=FALSE
        )
      ORDER BY CASE WHEN sr.day_of_week=EXTRACT(ISODOW FROM b.tanggal)::integer THEN 0 ELSE 1 END,
               sr.effective_from DESC,sr.day_of_week
      LIMIT 1
    ) schedule_for_day ON TRUE  ), period_day_flags AS (
    SELECT pc.employee_id, pc.tanggal, pc.day_branch, pc.day_type, pc.is_workday, pc.schedule_known,
      COALESCE(att.outside_attendance,FALSE) OR COALESCE(sick.sick_outside,FALSE) AS outside_day,
      COALESCE(att.home_branch_attendance,FALSE) AS home_return_day,
      COALESCE(att.special_dayoff_marker,FALSE) AS special_dayoff_marker,
      COALESCE(sick.sick_outside,FALSE) AS sick_outside_day
    FROM period_calendar pc
    LEFT JOIN LATERAL (
      SELECT
        BOOL_OR(a.status_approval IN ('VALID','DISETUJUI') AND a.outside_location IS TRUE
          AND a.area IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')) AS outside_attendance,
        BOOL_OR(a.status_approval IN ('VALID','DISETUJUI')
          AND NULLIF(BTRIM(a.branch_target),'') IS NOT NULL
          AND LOWER(BTRIM(a.branch_target))=LOWER(BTRIM(pc.day_branch))
          AND COALESCE(a.outside_location,FALSE)=FALSE) AS home_branch_attendance,
        BOOL_OR(a.status_approval IN ('VALID','DISETUJUI')
          AND substring(COALESCE(a.catatan,'') FROM '\[\[RHATT=(P[1-5]?|SDL[1-5]|SDLL)\]\]') IS NOT NULL) AS special_dayoff_marker
      FROM raw_events a
      WHERE a.employee_id=pc.employee_id AND a.tanggal=pc.tanggal
    ) att ON TRUE
    LEFT JOIN LATERAL (
      SELECT EXISTS (
        SELECT 1 FROM public.pengajuan_cuti c
        WHERE c.employee_id=pc.employee_id AND c.kode_cuti='SDR'
          AND c.dinas_luar_sakit IS TRUE
          AND c.area_sakit IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')
          AND c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI'
          AND c.tanggal_mulai<=pc.tanggal AND c.tanggal_selesai>=pc.tanggal
      ) AS sick_outside
    ) sick ON TRUE
  ), employee_period_flags AS (
    SELECT e.employee_id,
      COUNT(*) FILTER (WHERE f.is_workday) AS scheduled_work_days,
      COUNT(*) FILTER (WHERE f.is_workday AND f.outside_day) AS outside_work_days,
      BOOL_OR(f.home_return_day) AS returned_home,
      COALESCE(jsonb_agg(jsonb_build_object(
        'date',f.tanggal,'workday',f.is_workday,
        'sick_outside',f.sick_outside_day,
        'outside_day',f.outside_day,
        'home_return',f.home_return_day,
        'standby_or_picket',f.special_dayoff_marker
      ) ORDER BY f.tanggal) FILTER (
        WHERE f.is_workday
           OR (NOT f.is_workday AND (f.special_dayoff_marker OR f.sick_outside_day))
      ),'[]'::jsonb) AS family_trip_dates,
      COUNT(*) FILTER (WHERE NOT f.is_workday AND (f.special_dayoff_marker OR f.sick_outside_day)) AS special_off_days,
      COUNT(*) FILTER (WHERE f.day_type NOT IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF') AND NOT f.schedule_known) AS schedule_unknown_days
    FROM employees e
    LEFT JOIN period_day_flags f ON f.employee_id=e.employee_id
    GROUP BY e.employee_id
  ), pm_pasuruan_daily AS (
    SELECT a.employee_id, a.tanggal
    FROM raw_events a
    JOIN employees e ON e.employee_id=a.employee_id
    WHERE UPPER(COALESCE(e.job_code,''))='PM'
      AND LOWER(BTRIM(COALESCE(a.branch_target,'')))='pasuruan'
      AND a.status_approval IN ('VALID','DISETUJUI')
      AND COALESCE(a.outside_location,FALSE)=FALSE
      AND a.tipe IN ('MASUK','PULANG')
    GROUP BY a.employee_id,a.tanggal
  ), pm_pasuruan_period AS (
    SELECT e.employee_id,
      COUNT(p.tanggal)::integer AS pasuruan_days,
      COALESCE(jsonb_agg(p.tanggal ORDER BY p.tanggal) FILTER (WHERE p.tanggal IS NOT NULL),'[]'::jsonb) AS pasuruan_dates
    FROM employees e
    LEFT JOIN pm_pasuruan_daily p ON p.employee_id=e.employee_id
    GROUP BY e.employee_id
  ), reimbursement_by_employee AS (
    SELECT a.employee_id,
      COALESCE(SUM(a.amount) FILTER (WHERE a.category='ENTERTAIN'),0) AS entertain_amount,
      COALESCE(SUM(a.amount) FILTER (WHERE a.category='TRANSPORT'),0) AS transport_amount,
      COALESCE(SUM(a.amount),0) AS total_amount
    FROM public.hr_reimbursement_requests a
    JOIN employees e ON e.employee_id=a.employee_id
      AND UPPER(COALESCE(e.job_code,''))='HYBRID'
    WHERE a.period_start=p_start_date
      AND a.period_end=p_end_date
      AND a.status='DISETUJUI'
    GROUP BY a.employee_id
  ), per_employee AS (
    SELECT e.employee_id, e.nama, e.branch, e.organization, e.job_position, e.job_code, e.bank_name, e.bank_account,
      count(*) FILTER (WHERE d.attendance_eligible) AS attendance_days,
      count(*) FILTER (WHERE d.meal_eligible) AS punctual_days,
      coalesce(sum(d.meal_amount_day),0)::numeric(18,0) AS meal_amount,
      count(*) FILTER (WHERE d.transport_eligible) AS transport_days,
      CASE WHEN count(*) FILTER (WHERE d.transport_eligible) >= coalesce((v_cfg->>'transport_threshold')::integer,25)
        THEN coalesce((v_cfg->>'transport_cap')::numeric,0)
        ELSE (count(*) FILTER (WHERE d.transport_eligible) * coalesce((v_cfg->>'transport_daily')::numeric,0)) END::numeric(18,0) AS transport_amount,
      count(*) FILTER (WHERE d.phone_eligible) AS phone_days,
      CASE WHEN count(*) FILTER (WHERE d.phone_eligible) >= coalesce((v_cfg->>'phone_threshold')::integer,25)
        THEN coalesce((v_cfg->>'phone_cap')::numeric,0)
        ELSE (count(*) FILTER (WHERE d.phone_eligible) * coalesce((v_cfg->>'phone_daily')::numeric,0)) END::numeric(18,0) AS phone_amount,
      count(*) FILTER (WHERE d.outside_eligible) AS outside_days,
      coalesce(sum(d.outside_amount_day),0)::numeric(18,0) AS outside_amount,
      coalesce(sum(d.outside_amount_day) FILTER (WHERE d.area_rate_key='AREA 1'),0)::numeric(18,0) AS area_1_amount,
      coalesce(sum(d.outside_amount_day) FILTER (WHERE d.area_rate_key='AREA 2'),0)::numeric(18,0) AS area_2_amount,
      coalesce(sum(d.outside_amount_day) FILTER (WHERE d.area_rate_key='AREA 3'),0)::numeric(18,0) AS area_3_amount,
      coalesce(sum(d.outside_amount_day) FILTER (WHERE d.area_rate_key='AREA 4'),0)::numeric(18,0) AS area_4_amount,
      coalesce(sum(d.outside_amount_day) FILTER (WHERE d.area_rate_key='AREA LAIN'),0)::numeric(18,0) AS area_lain_amount,
      count(*) FILTER (WHERE d.picket_eligible) AS picket_days,
      coalesce(sum(d.picket_paid_hours),0) AS picket_hours,
      coalesce(sum(d.picket_amount_day),0)::numeric(18,0) AS picket_amount,
      CASE WHEN COALESCE(epf.scheduled_work_days,0)>0
        AND epf.outside_work_days=epf.scheduled_work_days
        AND COALESCE(epf.schedule_unknown_days,0)=0
        AND COALESCE(epf.returned_home,FALSE)=FALSE
        THEN 360000 ELSE 0 END::numeric(18,0) AS family_trip_amount,
      CASE WHEN UPPER(COALESCE(e.job_code,''))='PM' AND COALESCE(pp.pasuruan_days,0)>4
        THEN pp.pasuruan_days*80000 ELSE 0 END::numeric(18,0) AS extra_transport_amount,
      COALESCE(epf.scheduled_work_days,0) AS family_trip_scheduled_work_days,
      COALESCE(epf.outside_work_days,0) AS family_trip_outside_work_days,
      COALESCE(epf.returned_home,FALSE) AS returned_home,
      COALESCE(epf.family_trip_dates,'[]'::jsonb) AS family_trip_dates,
      COALESCE(epf.special_off_days,0) AS family_trip_special_off_days,
      COALESCE(epf.schedule_unknown_days,0) AS family_trip_schedule_unknown_days,
      COALESCE(pp.pasuruan_days,0) AS extra_transport_days,
      COALESCE(pp.pasuruan_dates,'[]'::jsonb) AS extra_transport_dates,
      coalesce(jsonb_agg(jsonb_build_object(
        'date', d.tanggal,
        'attendance_code', d.attendance_code,
        'clock_in', d.clock_in,
        'clock_out', d.clock_out,
        'clock_in_status', d.clock_in_status,
        'clock_out_status', d.clock_out_status,
        'area', d.effective_area,
        'outside_location', (coalesce(d.clock_in_outside,false) OR coalesce(d.clock_out_outside,false)),
        'punctuality_status', d.punctuality_status,
        'scheduled_check_in', d.scheduled_check_in,
        'late_tolerance_minutes', d.late_tolerance_minutes,
        'meal_eligible', d.meal_eligible,
        'meal_amount', d.meal_amount_day,
        'transport_eligible', d.transport_eligible,
        'phone_eligible', d.phone_eligible,
        'outside_eligible', d.outside_eligible,
        'outside_rate_key', d.area_rate_key,
        'outside_job_code', e.job_code,
        'outside_rate', d.outside_rate,
        'outside_rate_configured', (d.outside_rate IS NOT NULL AND d.outside_rate > 0),
        'outside_amount', d.outside_amount_day,
        'picket_hours_paid', d.picket_paid_hours,
        'picket_amount', d.picket_amount_day,
        'warnings', to_jsonb(d.day_warnings)
      ) ORDER BY d.tanggal) FILTER (WHERE d.event_count > 0 OR d.sick_outside), '[]'::jsonb) AS details,
      coalesce(jsonb_agg(jsonb_build_object('date',d.tanggal,'warnings',to_jsonb(d.day_warnings)) ORDER BY d.tanggal)
        FILTER (WHERE cardinality(d.day_warnings)>0), '[]'::jsonb) AS warnings
    FROM employees e
    LEFT JOIN daily_calc d ON d.employee_id=e.employee_id
    LEFT JOIN employee_period_flags epf ON epf.employee_id=e.employee_id
    LEFT JOIN pm_pasuruan_period pp ON pp.employee_id=e.employee_id
    GROUP BY e.employee_id, e.nama, e.branch, e.organization, e.job_position, e.job_code,
      e.bank_name, e.bank_account, epf.scheduled_work_days, epf.outside_work_days,
      epf.returned_home, epf.family_trip_dates, epf.special_off_days, epf.schedule_unknown_days,
      pp.pasuruan_days, pp.pasuruan_dates
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'employee_id', x.employee_id,
    'nama', x.nama,
    'branch', x.branch,
    'organization', x.organization,
    'job_position', x.job_position,
    'job_code', x.job_code,
    'bank_name', x.bank_name,
    'bank_account', x.bank_account,
    'attendance_days', x.attendance_days,
    'punctual_days', x.punctual_days,
    'meal_days', x.punctual_days,
    'meal_amount', x.meal_amount,
    'transport_days', x.transport_days,
    'transport_amount', x.transport_amount,
    'phone_days', x.phone_days,
    'phone_amount', x.phone_amount,
    'outside_days', x.outside_days,
    'outside_amount', x.outside_amount,
    'area_1_amount', x.area_1_amount,
    'area_2_amount', x.area_2_amount,
    'area_3_amount', x.area_3_amount,
    'area_4_amount', x.area_4_amount,
    'area_lain_amount', x.area_lain_amount,
    'family_trip_amount', x.family_trip_amount,
    'extra_transport_amount', x.extra_transport_amount,
    'underpayment_last_month_amount', COALESCE((
      SELECT u.amount
      FROM public.incentive_underpayments u
      WHERE u.employee_id=x.employee_id
        AND u.period_start=p_start_date
        AND u.period_end=p_end_date
      LIMIT 1
    ),0),
    'reimbursement_entertain_amount', COALESCE(rbe.entertain_amount,0),
    'reimbursement_transport_amount', COALESCE(rbe.transport_amount,0),
    'reimbursement_over_budget_amount',
      GREATEST(0,COALESCE(rbe.entertain_amount,0)-v_reimbursement_entertain_limit)
      + GREATEST(0,COALESCE(rbe.transport_amount,0)-v_reimbursement_transport_limit),
    'picket_days', x.picket_days,
    'picket_hours', x.picket_hours,
    'picket_amount', x.picket_amount,
    'family_trip_scheduled_work_days', x.family_trip_scheduled_work_days,
    'family_trip_outside_work_days', x.family_trip_outside_work_days,
    'family_trip_returned_home', x.returned_home,
    'family_trip_dates', x.family_trip_dates,
    'family_trip_special_off_days', x.family_trip_special_off_days,
    'family_trip_schedule_unknown_days', x.family_trip_schedule_unknown_days,
    'extra_transport_days', x.extra_transport_days,
    'extra_transport_dates', x.extra_transport_dates,
    'extra_amount', 0,
    'total_amount',
      COALESCE(x.meal_amount,0)+COALESCE(x.transport_amount,0)+COALESCE(x.phone_amount,0)
      +COALESCE(x.outside_amount,0)+COALESCE(x.picket_amount,0)+COALESCE(x.family_trip_amount,0)
      +COALESCE(x.extra_transport_amount,0)
      +COALESCE(rbe.total_amount,0)
      +COALESCE((SELECT u.amount FROM public.incentive_underpayments u
        WHERE u.employee_id=x.employee_id AND u.period_start=p_start_date AND u.period_end=p_end_date LIMIT 1),0),
    'details', x.details,
    'warnings', x.warnings
  ) ORDER BY x.nama), '[]'::jsonb) INTO v_records
  FROM per_employee x
  LEFT JOIN reimbursement_by_employee rbe ON rbe.employee_id=x.employee_id;

  RETURN jsonb_build_object(
    'ok', true,
    'period', jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'timezone','Asia/Jakarta'),
    'formula', jsonb_build_object('version',v_formula.version_no,'effective_from',v_formula.effective_from,'config',v_formula.config),
    'records', v_records
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.get_pending_approvals(p_token text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_emp public.karyawan;
  v_abs json;
  v_cuti json;
  v_role text;
BEGIN
  v_emp := public.session_karyawan(p_token);
  v_role := UPPER(COALESCE(v_emp.role,''));

  SELECT COALESCE(json_agg(q.item ORDER BY q.sort_ts DESC), '[]'::json)
  INTO v_abs
  FROM (
    SELECT public.absensi_to_json(a) AS item, a."timestamp" AS sort_ts
    FROM public.absensi a
    WHERE v_role IN ('KARYAWAN','SUPERADMIN')
      AND a.status_approval='PENDING_ATASAN'
      AND a.atasan_id=v_emp.employee_id
    UNION ALL
    SELECT public.absensi_to_json(a), a."timestamp"
    FROM public.absensi a
    WHERE v_role='SUPERADMIN'
      AND a.status_approval='PENDING_HR'
    UNION ALL
    SELECT public.absensi_to_json(a), a."timestamp"
    FROM public.absensi a
    WHERE v_role='ADMIN'
      AND a.status_approval IN ('PENDING_ATASAN','PENDING_HR')
  ) q;

  SELECT COALESCE(json_agg(q.item ORDER BY q.sort_ts DESC), '[]'::json)
  INTO v_cuti
  FROM (
    SELECT public.cuti_to_json(c) AS item, c."timestamp" AS sort_ts
    FROM public.pengajuan_cuti c
    JOIN public.karyawan k ON k.employee_id=c.employee_id
    WHERE v_role IN ('KARYAWAN','SUPERADMIN')
      AND c.status_atasan='PENDING'
      AND k.approval_line_id=v_emp.employee_id
    UNION ALL
    SELECT public.cuti_to_json(c), c."timestamp"
    FROM public.pengajuan_cuti c
    JOIN public.karyawan k ON k.employee_id=c.employee_id
    WHERE v_role='SUPERADMIN'
      AND c.status_atasan='DISETUJUI'
      AND c.status_hr='PENDING'
    UNION ALL
    SELECT public.cuti_to_json(c), c."timestamp"
    FROM public.pengajuan_cuti c
    JOIN public.karyawan k ON k.employee_id=c.employee_id
    WHERE v_role='ADMIN'
      AND c.status_atasan='PENDING'
    UNION ALL
    SELECT public.cuti_to_json(c), c."timestamp"
    FROM public.pengajuan_cuti c
    JOIN public.karyawan k ON k.employee_id=c.employee_id
    WHERE v_role='ADMIN'
      AND c.status_atasan='DISETUJUI'
      AND c.status_hr='PENDING'
  ) q;

  RETURN json_build_object(
    'absensi', COALESCE(v_abs,'[]'::json),
    'cuti', COALESCE(v_cuti,'[]'::json),
    'total', json_array_length(COALESCE(v_abs,'[]'::json)) + json_array_length(COALESCE(v_cuti,'[]'::json))
  );
END;
$function$;

COMMIT;
