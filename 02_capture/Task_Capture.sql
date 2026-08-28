-- ============================================================
-- Orchestration for all Phase 2 Hop 1 capture procedures — Lockbox
-- (Procedure_Lockbox.sql), EDI (Procedure_Edi.sql), and Email
-- (Procedure_Email.sql), run in sequence by the wrapper procedure
-- Procedure_CaptureAll.sql (cashapp.SP_CAPTURE_ALL). Replaces the
-- APScheduler 5-minute loop that used to call CaptureService.run_edi_capture()
-- / run_lockbox_capture() / run_email_capture() in one job.
--
-- Previously these three ran as separate tasks (task_email_capture,
-- TASK_LOCKBOX_CAPTURE, TASK_EDI_CAPTURE) — but they already shared the
-- same 5-minute schedule and warehouse, so they're consolidated into one
-- task here to match cash-app-api's single capture job.
--
-- Same dedicated batch warehouse as before. Email's workload is
-- network/latency-bound (Gmail API + external LLM + Azure DI polling), not
-- CPU bound, so it runs last in the sequence (see Procedure_CaptureAll.sql)
-- and never delays the pure-SQL EDI/Lockbox runs. If email starts crowding
-- out the total run time on O2C_WH, split it onto its own XS warehouse
-- rather than resizing the shared one.
-- ============================================================

USE DATABASE O2C_DB;

DROP TASK IF EXISTS cashapp.task_email_capture;
DROP TASK IF EXISTS cashapp.TASK_LOCKBOX_CAPTURE;
DROP TASK IF EXISTS cashapp.TASK_EDI_CAPTURE;

CREATE OR REPLACE TASK cashapp.TASK_CAPTURE
  WAREHOUSE = O2C_WH
  SCHEDULE = '5 MINUTE'
  COMMENT = 'Phase 2 Hop 1 — EDI + Lockbox + Email capture -> cashapp.channel_captures'
AS
  CALL cashapp.SP_CAPTURE_ALL();

-- Tasks are created SUSPENDED by default. Resume once email_capture_prereqs.sql
-- has been run (including the one-time Gmail OAuth consent step) and a
-- manual CALL cashapp.SP_CAPTURE_ALL() has come back clean.
ALTER TASK cashapp.TASK_CAPTURE RESUME;

-- ── Manual testing ─────────────────────────────────────────────────────────
-- Run once by hand before trusting the schedule:
--   CALL cashapp.SP_CAPTURE_ALL();
--
-- Inspect scheduled run history / errors:
--   SELECT *
--   FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
--          TASK_NAME => 'TASK_CAPTURE',
--          SCHEDULED_TIME_RANGE_START => DATEADD('hour', -6, CURRENT_TIMESTAMP())
--        ))
--   ORDER BY SCHEDULED_TIME DESC;
--
-- To pause without dropping (e.g. during a bulk backfill):
--   ALTER TASK cashapp.TASK_CAPTURE SUSPEND;
