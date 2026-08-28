-- ============================================================
-- cashapp.outreach_requests / cashapp.outreach_threads
-- ============================================================
-- Unlike Disputes, there is no external master table to read from here —
-- an outreach request is triggered directly off a real cashapp.cases row
-- (the "Draft customer outreach" button on the case detail page), so both
-- tables are fully app-owned with no source-table join involved.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE TABLE IF NOT EXISTS CASHAPP.OUTREACH_REQUESTS (
    REQUEST_ID       STRING       NOT NULL DEFAULT UUID_STRING(),
    CASE_ID          STRING       NOT NULL,   -- cashapp.cases.case_id
    REASON           STRING,                  -- UNRESOLVED_CUSTOMER | NO_OPEN_INVOICES (only 2 backed by real flags today)
    NOTE             STRING,
    CHANNEL          STRING       NOT NULL DEFAULT 'EMAIL',
    LANG             STRING,                  -- inferred from KNA1.LAND1 at draft time — a guess, not a known preference
    STATUS           STRING       NOT NULL DEFAULT 'DRAFTED',  -- DRAFTED | SENT | REPLIED | RESOLVED
    DRAFT_SUBJECT    STRING,
    DRAFT_BODY       STRING,
    LAST_CONTACT_AT  TIMESTAMP_TZ,
    CREATED_AT       TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT       TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_OUTREACH_REQUESTS PRIMARY KEY (REQUEST_ID)
);

CREATE TABLE IF NOT EXISTS CASHAPP.OUTREACH_THREADS (
    THREAD_ID   STRING       NOT NULL DEFAULT UUID_STRING(),
    REQUEST_ID  STRING       NOT NULL,   -- CASHAPP.OUTREACH_REQUESTS.REQUEST_ID
    SENT_AT     TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    SUBJECT     STRING,
    STATE       STRING       NOT NULL DEFAULT 'OPEN',  -- OPEN | REPLIED — manually set, no automatic reply detection yet
    CONSTRAINT PK_OUTREACH_THREADS PRIMARY KEY (THREAD_ID)
);

-- ── Grants — run as ACCOUNTADMIN (or whichever role owns schema CASHAPP);
-- O2C_APP does not have CREATE TABLE on this schema.
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE CASHAPP.OUTREACH_REQUESTS TO ROLE O2C_APP;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE CASHAPP.OUTREACH_THREADS TO ROLE O2C_APP;
