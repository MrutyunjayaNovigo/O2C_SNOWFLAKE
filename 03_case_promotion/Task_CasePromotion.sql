-- ============================================================
-- Orchestration for the Phase 3 Case Promotion procedure
-- (Procedure_CasePromotion.sql). Replaces the continuous asyncio loop
-- that used to call PromotionService.run() in cash-app-api.
--
-- Snowflake tasks are schedule-based, not continuous — 2 MINUTE matches
-- cash-app-api's own promotion cadence (scheduler.py IntervalTrigger,
-- 2 min) rather than running continuously like Service 2 did. Each run
-- only touches PENDING captures with a confirmed FEBEP bank credit, so
-- overlapping runs are safe (a capture already promoted by a prior run
-- is skipped via the cases.capture_id existence check).
--
-- Same shared batch warehouse as capture (O2C_WH) to start — this is a
-- pure-SQL, CPU-bound workload like lockbox/EDI capture, not I/O-bound
-- like email capture.
--
-- cashapp.TASK_MATCHING (Task_Matching.sql) is chained AFTER this task —
-- it has no schedule of its own and fires each time this run completes.
-- ============================================================

USE DATABASE O2C_DB;

CREATE OR REPLACE TASK cashapp.TASK_CASE_PROMOTION
  WAREHOUSE = O2C_WH
  SCHEDULE = '2 MINUTE'
  COMMENT = 'Phase 3 — Case Promotion: cashapp.channel_captures (PENDING) + master.FEBEP/FEBKO -> cashapp.cases/payments'
AS
  CALL cashapp.SP_CASE_PROMOTION();

-- Tasks are created SUSPENDED by default. Resume once 02_capture tasks
-- are live and a manual CALL cashapp.SP_CASE_PROMOTION() has come back clean.
ALTER TASK cashapp.TASK_CASE_PROMOTION RESUME;

-- ── Manual testing ─────────────────────────────────────────────────────────
-- Run once by hand before trusting the schedule:
--   CALL cashapp.SP_CASE_PROMOTION();
--
-- Inspect scheduled run history / errors:
--   SELECT *
--   FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
--          TASK_NAME => 'TASK_CASE_PROMOTION',
--          SCHEDULED_TIME_RANGE_START => DATEADD('hour', -6, CURRENT_TIMESTAMP())
--        ))
--   ORDER BY SCHEDULED_TIME DESC;
--
-- Spot-check promoted cases and their resolution trail:
--   SELECT c.case_number, c.sap_customer_id, c.resolution_layer, c.resolution_confidence,
--          c.priority_level, c.workflow_stage, c.created_at
--   FROM cashapp.cases c
--   ORDER BY c.created_at DESC
--   LIMIT 20;
--
--   SELECT * FROM cashapp.case_events WHERE event_type = 'CUSTOMER_RESOLVED' ORDER BY occurred_at DESC LIMIT 20;
--
-- To pause without dropping (e.g. during a bulk backfill):
--   ALTER TASK cashapp.TASK_CASE_PROMOTION SUSPEND;
