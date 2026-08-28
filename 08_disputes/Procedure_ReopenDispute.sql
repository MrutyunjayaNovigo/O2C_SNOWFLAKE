-- ============================================================
-- Reopen Dispute — Snowflake Procedure (Dispute Action)
-- Entry point : CALL CASHAPP.SP_REOPEN_DISPUTE('<dispute_id>')
-- Preconditions: dispute must exist and currently be resolved.
-- On success   : disputes.status -> 'OPEN', resolved_at/resolved_by cleared.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_REOPEN_DISPUTE(
    P_DISPUTE_ID STRING
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


def run(session, p_dispute_id: str) -> dict:
    row = _fetch_one(
        session, 'SELECT STATUS FROM CASHAPP.DISPUTES WHERE DISPUTE_ID = ?', [p_dispute_id],
    )
    if row is None:
        return {'dispute_id': p_dispute_id, 'status': 'SKIPPED', 'message': 'Dispute not found'}
    if row['STATUS'] != 'RESOLVED':
        return {'dispute_id': p_dispute_id, 'status': 'SKIPPED', 'message': 'Dispute is not resolved'}

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.DISPUTES SET STATUS = 'OPEN', RESOLVED_AT = NULL, RESOLVED_BY = NULL, "
            "UPDATED_AT = CURRENT_TIMESTAMP() WHERE DISPUTE_ID = ?",
            params=[p_dispute_id],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'dispute_id': p_dispute_id, 'status': 'ERROR', 'message': str(exc)}

    return {'dispute_id': p_dispute_id, 'status': 'OPEN', 'message': 'Dispute reopened'}
$$;

GRANT USAGE ON PROCEDURE CASHAPP.SP_REOPEN_DISPUTE(STRING) TO ROLE O2C_APP;

-- CALL CASHAPP.SP_REOPEN_DISPUTE('<dispute_id>');
