-- ============================================================
-- Escalate Case — Snowflake Procedure (Case Action)
-- Migrated from: cash-app-snowflake-api/app/case/service.py CaseService.escalate_case
-- Entry point : CALL CASHAPP.SP_ESCALATE_CASE('<case_id>', '<target_tier>', '<escalated_by>', '<reason>')
-- P_TARGET_TIER must be one of L1 / L2 / L3.
--
-- Preconditions enforced, in order:
--   1. Case must exist and cases.case_status must be 'OPEN'.
--   2. cases.workflow_stage must be one of REVIEW, PENDING_APPROVAL, VALIDATION
--      (a VALIDATION case is post-approval — analyst pulling it back).
--   3. A VALIDATION case may only be escalated while still un-posted — blocked
--      once postguard_status='PASS', sap_document_number is set, or
--      posting_attempts > 0 (posting pipeline already touched it).
--   4. target_tier must rank strictly above the case's current escalation_tier
--      (L1=1, L2=2, L3=3, unset=0) — cannot escalate sideways or down.
--
-- On success: workflow_stage -> 'PENDING_APPROVAL', escalation_tier -> target_tier;
-- one case_events row, event_type = 'ESCALATED'.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_ESCALATE_CASE(
    P_CASE_ID STRING,
    P_TARGET_TIER STRING,
    P_ESCALATED_BY STRING,
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

_ESCALATABLE = ('REVIEW', 'PENDING_APPROVAL', 'VALIDATION')
_TIER_RANK = {'L1': 1, 'L2': 2, 'L3': 3}
_TIER_ROLE = {'L1': 'Manager', 'L2': 'CFO', 'L3': 'Executive'}


def _fetch_one(session, sql_text, params=None):
    rows = session.sql(sql_text, params=params or []).collect()
    return rows[0] if rows else None


def run(session, p_case_id: str, p_target_tier: str, p_escalated_by: str, p_reason: str) -> dict:
    target_tier = (p_target_tier or '').strip().upper()
    if target_tier not in _TIER_RANK:
        return {'case_id': p_case_id, 'status': 'ERROR', 'message': 'target_tier must be one of L1, L2, L3'}

    case_row = _fetch_one(
        session,
        'SELECT CASE_STATUS, WORKFLOW_STAGE, POSTGUARD_STATUS, SAP_DOCUMENT_NUMBER, '
        'POSTING_ATTEMPTS, ESCALATION_TIER, APPROVAL_STATUS FROM CASHAPP.CASES WHERE CASE_ID = ?',
        [p_case_id],
    )
    if case_row is None:
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'message': 'Case not found'}
    if case_row['CASE_STATUS'] != 'OPEN':
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'message': 'Case is already closed'}

    workflow_stage = case_row['WORKFLOW_STAGE']
    if workflow_stage not in _ESCALATABLE:
        return {
            'case_id': p_case_id, 'status': 'SKIPPED',
            'message': 'Escalation only applies to REVIEW, PENDING_APPROVAL or VALIDATION cases — stage is {}'.format(workflow_stage),
        }

    posting_attempts = case_row['POSTING_ATTEMPTS'] or 0
    if case_row['POSTGUARD_STATUS'] == 'PASS' or case_row['SAP_DOCUMENT_NUMBER'] is not None or posting_attempts > 0:
        return {
            'case_id': p_case_id, 'status': 'SKIPPED',
            'message': 'Cannot escalate — case has already passed PostGuard and is posting or posted',
        }

    current_tier = case_row['ESCALATION_TIER']
    current_rank = _TIER_RANK.get(current_tier or '', 0)
    target_rank = _TIER_RANK[target_tier]
    if target_rank <= current_rank:
        return {
            'case_id': p_case_id, 'status': 'SKIPPED',
            'message': 'Cannot escalate to {} — already at or above that tier (current escalation_tier={})'.format(
                target_tier, current_tier or 'none'),
        }

    message = 'Case escalated to {} by {}'.format(_TIER_ROLE[target_tier], p_escalated_by or 'analyst')
    if p_reason:
        message += ' — {}'.format(p_reason)
    event_data = json.dumps({
        'escalated_by': p_escalated_by,
        'reason': p_reason,
        'previous_workflow_stage': workflow_stage,
        'previous_escalation_tier': current_tier,
        'new_escalation_tier': target_tier,
    })

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.CASES SET WORKFLOW_STAGE = 'PENDING_APPROVAL', ESCALATION_TIER = ?, "
            "UPDATED_AT = CURRENT_TIMESTAMP() WHERE CASE_ID = ?",
            params=[target_tier, p_case_id],
        ).collect()
        session.sql(
            "INSERT INTO CASHAPP.CASE_EVENTS (EVENT_ID, CASE_ID, EVENT_TYPE, EVENT_MESSAGE, EVENT_DATA) "
            "SELECT ?, ?, 'ESCALATED', ?, PARSE_JSON(?)",
            params=[str(uuid.uuid4()), p_case_id, message, event_data],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'case_id': p_case_id, 'status': 'ERROR', 'message': str(exc)}

    return {
        'case_id': p_case_id, 'status': 'ESCALATED', 'workflow_stage': 'PENDING_APPROVAL',
        'escalation_tier': target_tier, 'approval_status': case_row['APPROVAL_STATUS'],
        'message': 'Case escalated to {}'.format(target_tier),
    }
$$;

-- CALL CASHAPP.SP_ESCALATE_CASE('<case_id>', 'L2', 'test-user', 'testing escalate flow');
