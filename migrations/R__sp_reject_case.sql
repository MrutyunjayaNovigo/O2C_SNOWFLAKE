-- ============================================================
-- Reject Case — Snowflake Procedure (Case Action)
-- Migrated from: cash-app-snowflake-api/app/case/service.py CaseService.reject_case
-- Entry point : CALL CASHAPP.SP_REJECT_CASE('<case_id>', '<rejected_by>', '<reason>')
-- Preconditions: case must exist and cases.case_status must be 'OPEN'.
-- On success   : cases.case_status -> 'CLOSED', closure_reason -> 'REJECTED',
--                workflow_stage -> 'EXCEPTION', closed_at -> now; one
--                case_events row, event_type = 'REJECTED'.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_REJECT_CASE(
    P_CASE_ID STRING,
    P_REJECTED_BY STRING,
    P_REASON STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
import uuid


def _fetch_one(session, sql_text, params=None):
    rows = session.sql(sql_text, params=params or []).collect()
    return rows[0] if rows else None


def run(session, p_case_id: str, p_rejected_by: str, p_reason: str) -> dict:
    case_row = _fetch_one(
        session, 'SELECT CASE_STATUS FROM CASHAPP.CASES WHERE CASE_ID = ?', [p_case_id],
    )
    if case_row is None:
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'message': 'Case not found'}
    if case_row['CASE_STATUS'] != 'OPEN':
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'message': 'Case is already closed'}

    message = 'Case rejected by {}'.format(p_rejected_by or 'analyst')
    if p_reason:
        message += ' — {}'.format(p_reason)
    event_data = json.dumps({'rejected_by': p_rejected_by, 'reason': p_reason})

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.CASES SET CASE_STATUS = 'CLOSED', CLOSURE_REASON = 'REJECTED', "
            "WORKFLOW_STAGE = 'EXCEPTION', CLOSED_AT = CURRENT_TIMESTAMP(), "
            "UPDATED_AT = CURRENT_TIMESTAMP() WHERE CASE_ID = ?",
            params=[p_case_id],
        ).collect()
        session.sql(
            "INSERT INTO CASHAPP.CASE_EVENTS (EVENT_ID, CASE_ID, EVENT_TYPE, EVENT_MESSAGE, EVENT_DATA) "
            "SELECT ?, ?, 'REJECTED', ?, PARSE_JSON(?)",
            params=[str(uuid.uuid4()), p_case_id, message, event_data],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'case_id': p_case_id, 'status': 'ERROR', 'message': str(exc)}

    return {
        'case_id': p_case_id, 'status': 'REJECTED', 'workflow_stage': 'EXCEPTION',
        'message': 'Case rejected and closed',
    }
$$;

-- CALL CASHAPP.SP_REJECT_CASE('<case_id>', 'test-user', 'testing reject flow');
