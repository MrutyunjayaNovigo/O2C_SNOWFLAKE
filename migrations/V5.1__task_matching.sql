-- ============================================================
-- Orchestration for the matching procedure (SP_MATCHING, matching.sql).
-- Replaces the fire-and-forget asyncio.create_task(run_matching(case_id))
-- that cash-app-api's PromotionService fires per-case immediately after
-- creating a case (promotion_service.py).
--
-- Snowflake tasks can't fire per-row the way asyncio.create_task does, so
-- the closest equivalent is a Task DAG: TASK_MATCHING has no SCHEDULE of
-- its own — it runs AFTER cashapp.TASK_CASE_PROMOTION completes, sweeping
-- whatever cases that run just created, instead of matching a single case
-- instantly. Same trigger relationship as the app (matching follows
-- promotion), just batched per promotion run rather than per case.
-- ============================================================

USE DATABASE O2C_DB;

-- A DAG's root task must be suspended before a new child task can be added
-- to it. Resume order below is child-before-root — resuming the root last
-- re-activates the whole graph.
ALTER TASK cashapp.TASK_CASE_PROMOTION SUSPEND;

CREATE OR REPLACE TASK cashapp.TASK_MATCHING
  WAREHOUSE = O2C_WH
  AFTER cashapp.TASK_CASE_PROMOTION
  COMMENT = 'Runs after Case Promotion — matches newly created cashapp.cases rows via SP_MATCHING()'
AS
  CALL cashapp.SP_MATCHING();

ALTER TASK cashapp.TASK_MATCHING RESUME;
ALTER TASK cashapp.TASK_CASE_PROMOTION RESUME;

-- ── Manual testing ─────────────────────────────────────────────────────────
-- Run once by hand before trusting the DAG:
--   CALL cashapp.SP_MATCHING();
--
-- Inspect scheduled run history / errors (matching runs show up keyed off
-- the root task's schedule, since it has none of its own):
--   SELECT *
--   FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
--          TASK_NAME => 'TASK_MATCHING',
--          SCHEDULED_TIME_RANGE_START => DATEADD('hour', -6, CURRENT_TIMESTAMP())
--        ))
--   ORDER BY SCHEDULED_TIME DESC;
--
-- Confirm the DAG is wired correctly:
--   SELECT *
--   FROM TABLE(INFORMATION_SCHEMA.TASK_DEPENDENTS(
--          TASK_NAME => 'TASK_CASE_PROMOTION', RECURSIVE => TRUE
--        ));
--
-- To pause matching without dropping (e.g. during a bulk backfill) —
-- suspending the child alone is safe, it does not require suspending the root:
--   ALTER TASK cashapp.TASK_MATCHING SUSPEND;
