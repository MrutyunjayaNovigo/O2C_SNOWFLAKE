-- ============================================================
-- Copilot agent trail — tables + config
-- Entry point : run once, before the SP_COPILOT_* procedures.
-- Note        : O2C_APP is granted SELECT and INSERT only. No UPDATE, no
--               DELETE — a run's trail must not be editable by the runtime
--               that wrote it, or it is not evidence.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE TABLE IF NOT EXISTS CASHAPP.COPILOT_RUNS (
    RUN_ID       STRING       NOT NULL DEFAULT UUID_STRING(),
    USER_ID      STRING       NULL,
    PERSONA      STRING       NULL,
    QUESTION     STRING       NOT NULL,
    CASE_ID      STRING       NULL,      -- case in view when asked, if any
    MODEL        STRING       NULL,
    STEP_COUNT   INTEGER      NOT NULL DEFAULT 0,
    STOP_REASON  STRING       NULL,      -- ANSWERED | STEP_CAP | PARSE_FAIL | ERROR
    ANSWERED     BOOLEAN      NOT NULL DEFAULT FALSE,
    ANSWER       STRING       NULL,
    LATENCY_MS   INTEGER      NULL,
    STARTED_AT   TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    FINISHED_AT  TIMESTAMP_TZ NULL,
    CONSTRAINT PK_COPILOT_RUNS PRIMARY KEY (RUN_ID)
);

CREATE TABLE IF NOT EXISTS CASHAPP.COPILOT_STEPS (
    STEP_ID     STRING       NOT NULL DEFAULT UUID_STRING(),
    RUN_ID      STRING       NOT NULL,
    STEP_NO     INTEGER      NOT NULL,
    PHASE       STRING       NOT NULL,   -- PLAN | TOOL | ANSWER | REPAIR
    TOOL_NAME   STRING       NULL,
    TOOL_ARGS   VARIANT      NULL,
    TOOL_RESULT VARIANT      NULL,
    RAW_MODEL   STRING       NULL,       -- what the model actually emitted
    MODEL       STRING       NULL,
    LATENCY_MS  INTEGER      NULL,
    CREATED_AT  TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_COPILOT_STEPS PRIMARY KEY (STEP_ID)
);

-- Deliberately narrow: append, read. Nothing else.
GRANT SELECT, INSERT ON TABLE CASHAPP.COPILOT_RUNS  TO ROLE O2C_APP;
GRANT SELECT, INSERT ON TABLE CASHAPP.COPILOT_STEPS TO ROLE O2C_APP;

-- The GRANTs above are NOT sufficient on their own. This schema carries a
-- future grant (created 2026-08-09) handing O2C_APP SELECT/INSERT/UPDATE/DELETE
-- on every table created in it, so a new table arrives already writable and the
-- narrow grant merely re-states two privileges it already had. Verified: before
-- these REVOKEs, O2C_APP updated and deleted rows in both tables.
REVOKE UPDATE, DELETE ON TABLE CASHAPP.COPILOT_RUNS  FROM ROLE O2C_APP;
REVOKE UPDATE, DELETE ON TABLE CASHAPP.COPILOT_STEPS FROM ROLE O2C_APP;

-- Model and caps are configuration, not code — tunable without a redeploy.
MERGE INTO CASHAPP.SYSTEM_CONFIG t
USING (
    SELECT 'copilot_model'      AS CONFIG_KEY, 'llama3.1-70b' AS CONFIG_VALUE
    UNION ALL SELECT 'copilot_max_steps',  '4'
    UNION ALL SELECT 'copilot_max_tokens', '700'
) s ON t.CONFIG_KEY = s.CONFIG_KEY
WHEN NOT MATCHED THEN INSERT (CONFIG_KEY, CONFIG_VALUE) VALUES (s.CONFIG_KEY, s.CONFIG_VALUE);

-- Verification — expect a privilege error on the UPDATE:
--   USE ROLE O2C_APP; USE SECONDARY ROLES NONE;
--   UPDATE CASHAPP.COPILOT_STEPS SET TOOL_NAME = 'x';
