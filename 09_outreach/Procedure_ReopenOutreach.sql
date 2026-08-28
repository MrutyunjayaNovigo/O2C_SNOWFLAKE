-- ============================================================
-- Reopen Outreach — Snowflake Procedure
-- Entry point : CALL CASHAPP.SP_REOPEN_OUTREACH('<request_id>')
-- Preconditions: request must exist and currently be RESOLVED.
-- On success   : outreach_requests.status -> 'SENT' (the email was already
--                sent before it was marked resolved — reopening means the
--                issue isn't actually settled, not that drafting restarts).
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_REOPEN_OUTREACH(
    P_REQUEST_ID STRING
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


def run(session, p_request_id: str) -> dict:
    row = _fetch_one(
        session, 'SELECT STATUS FROM CASHAPP.OUTREACH_REQUESTS WHERE REQUEST_ID = ?', [p_request_id],
    )
    if row is None:
        return {'request_id': p_request_id, 'status': 'SKIPPED', 'message': 'Outreach request not found'}
    if row['STATUS'] != 'RESOLVED':
        return {'request_id': p_request_id, 'status': 'SKIPPED', 'message': 'Request is not resolved'}

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.OUTREACH_REQUESTS SET STATUS = 'SENT', UPDATED_AT = CURRENT_TIMESTAMP() "
            "WHERE REQUEST_ID = ?",
            params=[p_request_id],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'request_id': p_request_id, 'status': 'ERROR', 'message': str(exc)}

    return {'request_id': p_request_id, 'status': 'SENT', 'message': 'Outreach reopened'}
$$;

GRANT USAGE ON PROCEDURE CASHAPP.SP_REOPEN_OUTREACH(STRING) TO ROLE O2C_APP;

-- CALL CASHAPP.SP_REOPEN_OUTREACH('<request_id>');
