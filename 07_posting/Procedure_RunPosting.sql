-- ============================================================
-- Run Posting — Snowflake Procedure (Service 6, demo/simulated layer only)
-- Migrated from: cash-app-snowflake-api/app/posting/{service,repository,bapi_client,schemas}.py
-- Entry point : CALL CASHAPP.RUN_POSTING('<case_id>')
-- Input       : P_CASE_ID from cashapp.cases.case_id
-- Run guard   : Executes only when cashapp.cases.workflow_stage = 'VALIDATION'
--               AND postguard_status = 'PASS' AND sap_document_number IS NULL
--               (not already posted — sap_document_number is the exclusive
--               posting signal, written only here).
-- Source data : cashapp.cases, cashapp.case_match_proposals (selected proposal),
--               cashapp.case_invoice_matches (included lines — company_code,
--               fiscal_year), cashapp.system_config (sap_integration_enabled)
-- Target data : cashapp.cases (sap_document_number, sap_company_code,
--               sap_fiscal_year, case_status, closure_reason, closed_at,
--               posting_attempts), cashapp.payments (payment_status,
--               applied_amount, unapplied_amount), cashapp.case_events
--               (POSTED or POSTING_FAILED event)
--
-- Scope of this draft — demo/simulated layer ONLY:
--   Mirrors the Python posting service's Layer 1 (sap_integration_enabled=false):
--   always succeeds on attempt 1, BELNR = 'DEMO-<uuid8>', SYSTEM = 'SIMULATED'.
--   Layer 2 (real BAPI_ACC_DOCUMENT_POST / POSTING_INTERFACE_CLEARING via RFC)
--   is NOT implemented here — pure Snowflake SQL cannot call an RFC-enabled SAP
--   function module without an external function, same limitation PostGuard
--   Check 8 (BAPI_DRY_RUN) already documents. If sap_integration_enabled=true,
--   this procedure parks the case in POSTING_EXCEPTION/NEEDS_REVIEW rather than
--   silently pretending to post.
--
--   Not implemented (left for a follow-up pass, see PRD
--   development_understanding.md section "6A. Posting Service"):
--     - Scheduler-driven retry pool (posting_max_retries / posting_retry_interval_minutes)
--     - AWKEY reconciliation against master.BKPF (only meaningful once real SAP
--       posting exists — demo mode never writes BKPF)
--     - Transient vs permanent error classification
--   posting_attempts is still incremented so that machinery can be layered on
--   later without a schema change.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.RUN_POSTING(P_CASE_ID STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run_posting'
EXECUTE AS OWNER
AS
$$
import uuid
import json


def run_posting(session, p_case_id: str) -> dict:

    def fetch_one(sql, params=None):
        rows = session.sql(sql, params=params or []).collect()
        return rows[0] if rows else None

    # === Guard: case exists, in VALIDATION, PostGuard passed, not already posted ===
    case_row = fetch_one("""
        SELECT WORKFLOW_STAGE, POSTGUARD_STATUS, SAP_DOCUMENT_NUMBER, PAYMENT_ID,
               SAP_CUSTOMER_ID, PAYMENT_AMOUNT, COALESCE(POSTING_ATTEMPTS, 0) AS POSTING_ATTEMPTS
        FROM CASHAPP.CASES WHERE CASE_ID = ?
    """, [p_case_id])

    if case_row is None:
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'detail': 'Case not found'}

    if case_row['WORKFLOW_STAGE'] != 'VALIDATION':
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'detail': 'Case is not in VALIDATION stage'}

    if case_row['POSTGUARD_STATUS'] != 'PASS':
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'detail': 'PostGuard has not passed for this case'}

    if case_row['SAP_DOCUMENT_NUMBER'] is not None:
        return {
            'case_id': p_case_id, 'status': 'SKIPPED',
            'detail': 'Already posted', 'sap_document_number': case_row['SAP_DOCUMENT_NUMBER'],
        }

    payment_id = case_row['PAYMENT_ID']
    posting_attempts = case_row['POSTING_ATTEMPTS'] + 1

    # === Selected proposal (strategy not required for the demo path, but kept
    #     for parity with the real path and for the event trail) ===
    prop_row = fetch_one("""
        SELECT MATCH_STRATEGY FROM CASHAPP.CASE_MATCH_PROPOSALS
        WHERE CASE_ID = ? AND IS_SELECTED = TRUE LIMIT 1
    """, [p_case_id])
    match_strategy = prop_row['MATCH_STRATEGY'] if prop_row else None

    match_row = fetch_one("""
        SELECT MIN(m.COMPANY_CODE) AS COMPANY_CODE, MIN(m.FISCAL_YEAR) AS FISCAL_YEAR
        FROM CASHAPP.CASE_INVOICE_MATCHES m
        JOIN CASHAPP.CASE_MATCH_PROPOSALS p ON m.PROPOSAL_ID = p.PROPOSAL_ID
        WHERE p.CASE_ID = ? AND p.IS_SELECTED = TRUE AND m.IS_INCLUDED = TRUE
    """, [p_case_id])
    company_code = match_row['COMPANY_CODE'] if match_row else None
    fiscal_year = match_row['FISCAL_YEAR'] if match_row else None

    # === SAP integration gate ===
    sap_row = fetch_one("""
        SELECT CONFIG_VALUE FROM CASHAPP.SYSTEM_CONFIG
        WHERE CONFIG_KEY = 'sap_integration_enabled' AND COMPANY_CODE IS NULL LIMIT 1
    """)
    sap_integrated = (sap_row['CONFIG_VALUE'] if sap_row else 'false') or 'false'

    session.sql(
        "UPDATE CASHAPP.CASES SET POSTING_ATTEMPTS = ?, UPDATED_AT = CURRENT_TIMESTAMP() WHERE CASE_ID = ?",
        params=[posting_attempts, p_case_id],
    ).collect()

    if sap_integrated.lower() == 'true':
        # Real BAPI_ACC_DOCUMENT_POST / POSTING_INTERFACE_CLEARING requires an
        # RFC-enabled external function not available from pure Snowflake SQL.
        # Park for ops rather than pretend to post — see file header.
        session.sql("""
            UPDATE CASHAPP.CASES SET WORKFLOW_STAGE = 'POSTING_EXCEPTION', POSTING_EXCEPTION_TYPE = 'NEEDS_REVIEW'
            WHERE CASE_ID = ?
        """, params=[p_case_id]).collect()
        event_data = json.dumps({'reason': 'sap_integration_enabled=true but no RFC path from Snowflake SQL', 'posting_attempts': posting_attempts})
        session.sql("""
            INSERT INTO CASHAPP.CASE_EVENTS (EVENT_ID, CASE_ID, EVENT_TYPE, EVENT_MESSAGE, EVENT_DATA, OCCURRED_AT)
            SELECT UUID_STRING(), ?, 'POSTING_FAILED', 'Posting failed - real SAP integration not available from this procedure', TRY_PARSE_JSON(?), CURRENT_TIMESTAMP()
        """, params=[p_case_id, event_data]).collect()
        session.sql('COMMIT').collect()
        return {'case_id': p_case_id, 'status': 'POSTING_EXCEPTION', 'detail': 'Real SAP integration not implemented in this procedure'}

    # === Demo/simulated posting — always succeeds on attempt 1 ===
    belnr = 'DEMO-' + str(uuid.uuid4())[:8]
    fiscal_year_str = str(fiscal_year) if fiscal_year is not None else None
    bapi_return = [{
        'TYPE': 'S', 'ID': 'F5', 'NUMBER': '743',
        'MESSAGE': 'Document posted and cleared', 'SYSTEM': 'SIMULATED',
    }]

    session.sql("""
        UPDATE CASHAPP.CASES
        SET SAP_DOCUMENT_NUMBER = ?, SAP_COMPANY_CODE = ?, SAP_FISCAL_YEAR = ?,
            CASE_STATUS = 'CLOSED', CLOSURE_REASON = 'POSTED', CLOSED_AT = CURRENT_TIMESTAMP(),
            UPDATED_AT = CURRENT_TIMESTAMP()
        WHERE CASE_ID = ?
    """, params=[belnr, company_code, fiscal_year_str, p_case_id]).collect()

    if payment_id:
        session.sql("""
            UPDATE CASHAPP.PAYMENTS
            SET PAYMENT_STATUS = 'FULL', APPLIED_AMOUNT = PAYMENT_AMOUNT, UNAPPLIED_AMOUNT = 0,
                UPDATED_AT = CURRENT_TIMESTAMP()
            WHERE PAYMENT_ID = ?
        """, params=[payment_id]).collect()

    event_data = json.dumps({
        'sap_document_number': belnr, 'company_code': company_code, 'fiscal_year': fiscal_year_str,
        'match_strategy': match_strategy, 'posting_attempts': posting_attempts, 'bapi_return': bapi_return,
    })
    session.sql("""
        INSERT INTO CASHAPP.CASE_EVENTS (EVENT_ID, CASE_ID, EVENT_TYPE, EVENT_MESSAGE, EVENT_DATA, OCCURRED_AT)
        SELECT UUID_STRING(), ?, 'POSTED', 'Posted to SAP (simulated) - ' || ?, TRY_PARSE_JSON(?), CURRENT_TIMESTAMP()
    """, params=[p_case_id, belnr, event_data]).collect()

    # Same lesson as RUN_POSTGUARD (see its header) — a Snowpark Python
    # procedure's DML sits in an uncommitted scoped transaction until this
    # is called; skipping it rolls everything back silently on return.
    session.sql('COMMIT').collect()

    return {
        'case_id': p_case_id, 'status': 'POSTED', 'sap_document_number': belnr,
        'company_code': company_code, 'fiscal_year': fiscal_year_str,
    }
$$;

-- CALL CASHAPP.RUN_POSTING('<case_id>');
