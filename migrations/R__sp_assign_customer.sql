-- ============================================================
-- Assign Customer — Snowflake Procedure (Case Action)
-- Migrated from: cash-app-snowflake-api/app/case/service.py CaseService.assign_customer
-- Entry point : CALL CASHAPP.SP_ASSIGN_CUSTOMER('<case_id>', '<sap_customer_id>', '<assigned_by>')
-- Manual customer resolution for a case the automated 4-layer cascade in
-- SP_CASE_PROMOTION could not resolve.
--
-- Preconditions: case must exist, cases.case_status must be 'OPEN', and
-- cases.approval_status must be UNRESOLVED_CUSTOMER or NO_OPEN_INVOICES —
-- customer assignment is only meaningful when the case actually stalled on
-- customer resolution.
--
-- On success: cases.sap_customer_id + payments.sap_customer_id set,
-- workflow_stage -> 'MATCHING', approval_status -> NULL; one case_events row
-- (CUSTOMER_RESOLVED); then CASHAPP.SP_MATCHING() is called synchronously in
-- the same procedure — the direct equivalent of the Python app's
-- `asyncio.create_task(run_matching(case_id))`. SP_MATCHING batch-scans all
-- workflow_stage='MATCHING' cases rather than accepting a specific case_id,
-- so this picks up the case just assigned along with anything else pending.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_ASSIGN_CUSTOMER(
    P_CASE_ID STRING,
    P_SAP_CUSTOMER_ID STRING,
    P_ASSIGNED_BY STRING
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

_ELIGIBLE_APPROVAL_STATUS = ('UNRESOLVED_CUSTOMER', 'NO_OPEN_INVOICES')


def _fetch_one(session, sql_text, params=None):
    rows = session.sql(sql_text, params=params or []).collect()
    return rows[0] if rows else None


def run(session, p_case_id: str, p_sap_customer_id: str, p_assigned_by: str) -> dict:
    case_row = _fetch_one(
        session,
        'SELECT CASE_STATUS, APPROVAL_STATUS, PAYMENT_ID FROM CASHAPP.CASES WHERE CASE_ID = ?',
        [p_case_id],
    )
    if case_row is None:
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'message': 'Case not found'}
    if case_row['CASE_STATUS'] != 'OPEN':
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'message': 'Case is already closed'}

    approval_status = case_row['APPROVAL_STATUS']
    if approval_status not in _ELIGIBLE_APPROVAL_STATUS:
        return {
            'case_id': p_case_id, 'status': 'SKIPPED',
            'message': 'Customer assignment not applicable — approval_status is {}'.format(approval_status),
        }

    kunnr = (p_sap_customer_id or '').strip()
    if not kunnr:
        return {'case_id': p_case_id, 'status': 'ERROR', 'message': 'sap_customer_id is required'}

    event_data = json.dumps({
        'sap_customer_id': kunnr,
        'assigned_by': p_assigned_by,
        'previous_approval_status': approval_status,
    })

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.CASES SET SAP_CUSTOMER_ID = ?, WORKFLOW_STAGE = 'MATCHING', "
            "APPROVAL_STATUS = NULL, UPDATED_AT = CURRENT_TIMESTAMP() WHERE CASE_ID = ?",
            params=[kunnr, p_case_id],
        ).collect()

        if case_row['PAYMENT_ID']:
            session.sql(
                "UPDATE CASHAPP.PAYMENTS SET SAP_CUSTOMER_ID = ?, UPDATED_AT = CURRENT_TIMESTAMP() "
                "WHERE PAYMENT_ID = ?",
                params=[kunnr, case_row['PAYMENT_ID']],
            ).collect()

        session.sql(
            "INSERT INTO CASHAPP.CASE_EVENTS (EVENT_ID, CASE_ID, EVENT_TYPE, EVENT_MESSAGE, EVENT_DATA) "
            "SELECT ?, ?, 'CUSTOMER_RESOLVED', ?, PARSE_JSON(?)",
            params=[str(uuid.uuid4()), p_case_id, 'Customer manually assigned — KUNNR {}'.format(kunnr), event_data],
        ).collect()

        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'case_id': p_case_id, 'status': 'ERROR', 'message': str(exc)}

    matching_result = None
    try:
        matching_result = session.call('CASHAPP.SP_MATCHING')
    except Exception as exc:
        matching_result = {'status': 'ERROR', 'message': str(exc)}

    return {
        'case_id': p_case_id, 'status': 'ASSIGNED', 'workflow_stage': 'MATCHING',
        'message': 'Customer {} assigned — matching re-triggered'.format(kunnr),
        'matching_result': matching_result,
    }
$$;

-- CALL CASHAPP.SP_ASSIGN_CUSTOMER('<case_id>', '0001000123', 'test-user');
