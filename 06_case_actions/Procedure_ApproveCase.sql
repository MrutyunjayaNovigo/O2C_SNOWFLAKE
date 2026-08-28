-- ============================================================
-- Approve Case — Snowflake Procedure (Case Action)
-- Migrated from: cash-app-snowflake-api/app/case/service.py CaseService.approve_case
-- Entry point : CALL CASHAPP.SP_APPROVE_CASE('<case_id>', '<approved_by>', '<note>')
-- Input       : P_CASE_ID   from cashapp.cases.case_id
--               P_APPROVED_BY  analyst/approver identity, nullable
--               P_NOTE         free-text note, nullable
-- Source data : cashapp.cases, cashapp.case_match_proposals, cashapp.case_invoice_matches
-- Target data : cashapp.cases (workflow_stage, approval_status, assigned_to),
--               cashapp.case_events (APPROVED event)
--
-- Accepted stages (mirrors the Python guard exactly):
--   PENDING_APPROVAL, REVIEW_L1, REVIEW_L2, REVIEW_L3, VALIDATION (AUTO tier)
--
-- Preconditions enforced, in order — first failure short-circuits and returns
-- a SKIPPED/ERROR result without writing anything:
--   1. Case must exist.
--   2. cases.case_status must be 'OPEN' — cannot approve a closed case.
--   3. cases.workflow_stage must be one of the accepted stages above.
--   4. Case must have a selected proposal (case_match_proposals.is_selected = TRUE)
--      with at least one included invoice line (case_invoice_matches.is_included = TRUE)
--      — same has_valid_proposal() check as CaseRepository.
--
-- On success:
--   - cases.workflow_stage -> 'VALIDATION', approval_status -> NULL,
--     assigned_to -> COALESCE(p_approved_by, existing assigned_to)
--   - one case_events row, event_type = 'APPROVED'
--   - CASHAPP.RUN_POSTGUARD(case_id) is called synchronously in the same
--     procedure, immediately after commit. This is the direct equivalent of
--     the Python app's `asyncio.create_task(run_postguard(case_id))`
--     fire-and-forget call — Snowflake procedures have no async task-spawn
--     primitive, so PostGuard runs inline here instead of being scheduled.
--     Its result is included in the returned VARIANT for visibility.
--   - If PostGuard's result comes back postguard_status = 'PASS',
--     CASHAPP.RUN_POSTING(case_id) is then called synchronously too — the
--     equivalent of the Python app's "PostGuard passes -> triggers posting
--     service" (development_understanding.md, PostGuard section). Its result
--     is included in the returned VARIANT as posting_result.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_APPROVE_CASE(
    P_CASE_ID STRING,
    P_APPROVED_BY STRING,
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

_APPROVABLE = ('PENDING_APPROVAL', 'REVIEW_L1', 'REVIEW_L2', 'REVIEW_L3', 'VALIDATION')


def _fetch_one(session, sql_text, params=None):
    rows = session.sql(sql_text, params=params or []).collect()
    return rows[0] if rows else None


def _has_valid_proposal(session, case_id):
    row = _fetch_one(
        session,
        """
        SELECT COUNT(*) AS CNT
        FROM CASHAPP.CASE_INVOICE_MATCHES m
        JOIN CASHAPP.CASE_MATCH_PROPOSALS p ON m.PROPOSAL_ID = p.PROPOSAL_ID
        WHERE p.CASE_ID = ? AND p.IS_SELECTED = TRUE AND m.IS_INCLUDED = TRUE
        """,
        [case_id],
    )
    return row['CNT'] > 0


def run(session, p_case_id: str, p_approved_by: str, p_note: str) -> dict:
    case_row = _fetch_one(
        session,
        'SELECT CASE_STATUS, WORKFLOW_STAGE, ASSIGNED_TO, APPROVAL_STATUS '
        'FROM CASHAPP.CASES WHERE CASE_ID = ?',
        [p_case_id],
    )
    if case_row is None:
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'message': 'Case not found'}

    if case_row['CASE_STATUS'] != 'OPEN':
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'message': 'Case is already closed'}

    workflow_stage = case_row['WORKFLOW_STAGE']
    if workflow_stage not in _APPROVABLE:
        return {
            'case_id': p_case_id, 'status': 'SKIPPED',
            'message': 'Case cannot be approved from stage {}'.format(workflow_stage),
        }

    if not _has_valid_proposal(session, p_case_id):
        return {
            'case_id': p_case_id, 'status': 'SKIPPED',
            'message': 'No selected proposal with included invoices — resolve the case before approving',
        }

    assigned_to = p_approved_by or case_row['ASSIGNED_TO']
    message = 'Case approved by {}'.format(p_approved_by or 'analyst')
    if p_note:
        message += ' — {}'.format(p_note)

    event_data = json.dumps({
        'approved_by': p_approved_by,
        'note': p_note,
        'previous_workflow_stage': workflow_stage,
        'previous_approval_status': case_row['APPROVAL_STATUS'],
    })

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.CASES SET WORKFLOW_STAGE = 'VALIDATION', APPROVAL_STATUS = NULL, "
            "ASSIGNED_TO = ?, UPDATED_AT = CURRENT_TIMESTAMP() WHERE CASE_ID = ?",
            params=[assigned_to, p_case_id],
        ).collect()

        session.sql(
            "INSERT INTO CASHAPP.CASE_EVENTS (EVENT_ID, CASE_ID, EVENT_TYPE, EVENT_MESSAGE, EVENT_DATA) "
            "SELECT ?, ?, 'APPROVED', ?, PARSE_JSON(?)",
            params=[str(uuid.uuid4()), p_case_id, message, event_data],
        ).collect()

        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'case_id': p_case_id, 'status': 'ERROR', 'message': str(exc)}

    postguard_result = None
    try:
        postguard_result = session.call('CASHAPP.RUN_POSTGUARD', p_case_id)
    except Exception as exc:
        postguard_result = {'status': 'ERROR', 'message': str(exc)}

    # session.call() on a VARIANT-returning procedure comes back as a JSON
    # string here, not an already-parsed dict — only exception-branch results
    # built inline above are real dicts. Normalise before inspecting it.
    postguard_result_parsed = postguard_result
    if isinstance(postguard_result, str):
        try:
            postguard_result_parsed = json.loads(postguard_result)
        except (ValueError, TypeError):
            postguard_result_parsed = None

    posting_result = None
    if isinstance(postguard_result_parsed, dict) and postguard_result_parsed.get('postguard_status') == 'PASS':
        try:
            posting_result = session.call('CASHAPP.RUN_POSTING', p_case_id)
        except Exception as exc:
            posting_result = {'status': 'ERROR', 'message': str(exc)}

    return {
        'case_id': p_case_id,
        'status': 'APPROVED',
        'workflow_stage': 'VALIDATION',
        'message': 'Case approved — PostGuard validation triggered',
        'postguard_result': postguard_result,
        'posting_result': posting_result,
    }
$$;

-- CALL CASHAPP.SP_APPROVE_CASE('<case_id>', 'test-user', 'testing approve flow');
