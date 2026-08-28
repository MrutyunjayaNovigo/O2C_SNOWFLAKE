-- ============================================================
-- cashapp.disputes — app-owned workflow state for dispute cases
-- ============================================================
-- master."Dispute_Cases" is external/replica data (same category as KNA1,
-- BSID, etc.) — read-only, refreshed independently of this app, and it has
-- no state, owner, evidence, or priority columns. This table holds the
-- operational workflow state Cash Clear itself owns and mutates (the
-- Route/Resolve/Reopen actions), keyed back to the source row rather than
-- adding columns to it — same relationship cashapp.cases already has to
-- the SAP replica tables it references.
--
-- CASE_ID alone is not globally unique in master."Dispute_Cases" (it repeats
-- across company codes), so the link back uses (source_case_id, source_bukrs)
-- together, not source_case_id alone.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE TABLE IF NOT EXISTS CASHAPP.DISPUTES (
    DISPUTE_ID      STRING       NOT NULL DEFAULT UUID_STRING(),
    SOURCE_CASE_ID  STRING       NOT NULL,   -- master."Dispute_Cases".CASE_ID
    SOURCE_BUKRS    STRING       NOT NULL,   -- master."Dispute_Cases".BUKRS
    CASE_ID         STRING,                  -- nullable FK -> cashapp.cases.case_id
    STATUS          STRING       NOT NULL DEFAULT 'OPEN',  -- OPEN | EVIDENCE_ATTACHED | ROUTED_TO_REP | RESOLVED
    PRIORITY        STRING,
    OWNER_NAME      STRING,
    EVIDENCE        STRING,
    NOTE            STRING,
    RESOLVED_AT     TIMESTAMP_TZ,
    RESOLVED_BY     STRING,
    CREATED_AT      TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT      TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_DISPUTES PRIMARY KEY (DISPUTE_ID),
    CONSTRAINT UQ_DISPUTES_SOURCE UNIQUE (SOURCE_CASE_ID, SOURCE_BUKRS)
);

-- ── Grants — run this block (and the CREATE above) as ACCOUNTADMIN or
-- whichever role owns schema CASHAPP; O2C_APP does not have CREATE TABLE
-- on this schema (confirmed — same gap hit when creating sec_gmail_oauth).
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE CASHAPP.DISPUTES TO ROLE O2C_APP;

-- CALL to verify after creation:
-- DESCRIBE TABLE CASHAPP.DISPUTES;
