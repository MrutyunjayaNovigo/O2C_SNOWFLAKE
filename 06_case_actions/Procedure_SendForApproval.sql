-- ============================================================
-- Send Case For Approval — Snowflake Procedure (Case Action)
-- Migrated from: cash-app-snowflake-api/app/case/service.py CaseService.send_for_approval
-- Entry point : CALL CASHAPP.SP_SEND_FOR_APPROVAL('<case_id>', '<sent_by>', '<note>')
-- Routes a REVIEW or PENDING_APPROVAL case to the Manager queue (REVIEW_L1),
-- or a REVIEW_L1 case on to the CFO queue (REVIEW_L2).
--
-- Preconditions: case must exist, cases.case_status must be 'OPEN', and
-- workflow_stage must be one of REVIEW, PENDING_APPROVAL, REVIEW_L1.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_SEND_FOR_APPROVAL(
    P_CASE_ID STRING,
    P_SENT_BY STRING,
    P_NOTE STRING
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

_STAGE_PROGRESSION = {'REVIEW': 'REVIEW_L1', 'PENDING_APPROVAL': 'REVIEW_L1', 'REVIEW_L1': 'REVIEW_L2'}
_STAGE_LABEL = {'REVIEW_L1': 'Manager', 'REVIEW_L2': 'CFO'}


def _fetch_one(session, sql_text, params=None):
    rows = session.sql(sql_text, params=params or []).collect()
    return rows[0] if rows else None


def run(session, p_case_id: str, p_sent_by: str, p_note: str) -> dict:
    case_row = _fetch_one(
        session,
        'SELECT CASE_STATUS, WORKFLOW_STAGE, ASSIGNED_TO, REVIEW_AUTONOMY_TIER, APPROVAL_STATUS '
        'FROM CASHAPP.CASES WHERE CASE_ID = ?',
        [p_case_id],
    )
    if case_row is None:
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'message': 'Case not found'}
    if case_row['CASE_STATUS'] != 'OPEN':
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'message': 'Case is already closed'}

    workflow_stage = case_row['WORKFLOW_STAGE']
    new_stage = _STAGE_PROGRESSION.get(workflow_stage)
    if new_stage is None:
        return {
            'case_id': p_case_id, 'status': 'SKIPPED',
            'message': 'Cannot send for approval from stage {}'.format(workflow_stage),
        }
    approver_label = _STAGE_LABEL[new_stage]

    assigned_to = p_sent_by or case_row['ASSIGNED_TO']
    message = 'Case sent for {} approval by {}'.format(approver_label, p_sent_by or 'analyst')
    if p_note:
        message += ' — {}'.format(p_note)
    event_data = json.dumps({
        'sent_by': p_sent_by,
        'note': p_note,
        'review_autonomy_tier': case_row['REVIEW_AUTONOMY_TIER'],
        'previous_workflow_stage': workflow_stage,
    })

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.CASES SET WORKFLOW_STAGE = ?, ASSIGNED_TO = ?, "
            "UPDATED_AT = CURRENT_TIMESTAMP() WHERE CASE_ID = ?",
            params=[new_stage, assigned_to, p_case_id],
        ).collect()
        session.sql(
            "INSERT INTO CASHAPP.CASE_EVENTS (EVENT_ID, CASE_ID, EVENT_TYPE, EVENT_MESSAGE, EVENT_DATA) "
            "SELECT ?, ?, 'SENT_FOR_APPROVAL', ?, PARSE_JSON(?)",
            params=[str(uuid.uuid4()), p_case_id, message, event_data],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'case_id': p_case_id, 'status': 'ERROR', 'message': str(exc)}

    return {
        'case_id': p_case_id, 'status': 'SENT_FOR_APPROVAL', 'workflow_stage': new_stage,
        'approval_status': case_row['APPROVAL_STATUS'],
        'message': 'Case sent for {} approval'.format(approver_label),
    }
$$;

-- CALL CASHAPP.SP_SEND_FOR_APPROVAL('<case_id>', 'test-user', 'testing send-for-approval flow');
