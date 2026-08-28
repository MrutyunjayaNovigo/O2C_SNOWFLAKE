-- ============================================================
-- Resolve Outreach — Snowflake Procedure
-- Entry point : CALL CASHAPP.SP_RESOLVE_OUTREACH('<request_id>')
-- Preconditions: request must exist and not already be resolved.
-- On success   : outreach_requests.status -> 'RESOLVED'.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_RESOLVE_OUTREACH(
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
    if row['STATUS'] == 'RESOLVED':
        return {'request_id': p_request_id, 'status': 'SKIPPED', 'message': 'Request is already resolved'}

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.OUTREACH_REQUESTS SET STATUS = 'RESOLVED', UPDATED_AT = CURRENT_TIMESTAMP() "
            "WHERE REQUEST_ID = ?",
            params=[p_request_id],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'request_id': p_request_id, 'status': 'ERROR', 'message': str(exc)}

    return {'request_id': p_request_id, 'status': 'RESOLVED', 'message': 'Outreach resolved'}
$$;

GRANT USAGE ON PROCEDURE CASHAPP.SP_RESOLVE_OUTREACH(STRING) TO ROLE O2C_APP;

-- CALL CASHAPP.SP_RESOLVE_OUTREACH('<request_id>');
