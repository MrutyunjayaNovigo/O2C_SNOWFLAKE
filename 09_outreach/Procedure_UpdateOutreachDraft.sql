-- ============================================================
-- Update Outreach Draft — Snowflake Procedure
-- Entry point : CALL CASHAPP.SP_UPDATE_OUTREACH_DRAFT('<request_id>', '<subject>', '<body>')
-- Preconditions: request must exist and still be in DRAFTED state —
--                once sent, the thread log is the record of what actually
--                went out, so the draft is no longer editable.
-- On success   : outreach_requests.draft_subject / draft_body updated.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_UPDATE_OUTREACH_DRAFT(
    P_REQUEST_ID STRING,
    P_SUBJECT STRING,
    P_BODY STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
def _fetch_one(session, sql_text, params=None):
    rows = session.sql(sql_text, params=params or []).collect()
    return rows[0] if rows else None


def run(session, p_request_id: str, p_subject: str, p_body: str) -> dict:
    row = _fetch_one(
        session, 'SELECT STATUS FROM CASHAPP.OUTREACH_REQUESTS WHERE REQUEST_ID = ?', [p_request_id],
    )
    if row is None:
        return {'request_id': p_request_id, 'status': 'SKIPPED', 'message': 'Outreach request not found'}
    if row['STATUS'] != 'DRAFTED':
        return {'request_id': p_request_id, 'status': 'SKIPPED', 'message': 'Only a drafted request can be edited'}
    if not p_subject or not p_subject.strip() or not p_body or not p_body.strip():
        return {'request_id': p_request_id, 'status': 'SKIPPED', 'message': 'Subject and body cannot be empty'}

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.OUTREACH_REQUESTS SET DRAFT_SUBJECT = ?, DRAFT_BODY = ?, "
            "UPDATED_AT = CURRENT_TIMESTAMP() WHERE REQUEST_ID = ?",
            params=[p_subject, p_body, p_request_id],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'request_id': p_request_id, 'status': 'ERROR', 'message': str(exc)}

    return {'request_id': p_request_id, 'status': 'DRAFTED', 'message': 'Draft updated'}
$$;

GRANT USAGE ON PROCEDURE CASHAPP.SP_UPDATE_OUTREACH_DRAFT(STRING, STRING, STRING) TO ROLE O2C_APP;

-- CALL CASHAPP.SP_UPDATE_OUTREACH_DRAFT('<request_id>', '<subject>', '<body>');
