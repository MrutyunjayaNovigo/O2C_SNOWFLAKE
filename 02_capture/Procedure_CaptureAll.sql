-- ============================================================
-- Wrapper procedure for Phase 2 Hop 1 capture — runs Lockbox, EDI, and
-- Email capture in sequence under a single Snowflake Task, replacing the
-- three independently-scheduled tasks (task_email_capture,
-- TASK_LOCKBOX_CAPTURE, TASK_EDI_CAPTURE) that previously shared the same
-- 5-minute schedule and warehouse anyway.
--
-- Order is Lockbox, EDI, then Email. Lockbox/EDI are pure-SQL and fast;
-- Email is network/latency-bound (Gmail API + external LLM + Azure DI
-- polling), so it runs last and never delays the other two.
--
-- Each sub-procedure already handles its own errors internally (per-IDoc /
-- per-item try/except, logged to cashapp.capture_error_log) and returns a
-- result VARIANT rather than raising. The try/except here is a defensive
-- backstop only, so one sub-procedure raising unexpectedly still lets the
-- remaining ones run instead of aborting the whole task.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA cashapp;

CREATE OR REPLACE PROCEDURE cashapp.SP_CAPTURE_ALL()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
def run(session):
    results = {}
    for name, proc_name in (
        ("lockbox", "cashapp.SP_LOCKBOX_CAPTURE"),
        ("edi", "cashapp.SP_EDI_CAPTURE"),
        ("email", "cashapp.sp_capture_email"),
    ):
        try:
            results[name] = session.call(proc_name)
        except Exception as exc:
            results[name] = {"error": str(exc)}
    return results
$$;

-- Task orchestration for this procedure lives in Task_Capture.sql
-- (cashapp.TASK_CAPTURE).
