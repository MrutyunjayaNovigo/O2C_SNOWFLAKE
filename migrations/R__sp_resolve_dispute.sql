-- ============================================================
-- Resolve Dispute — Snowflake Procedure (Dispute Action)
-- Entry point : CALL CASHAPP.SP_RESOLVE_DISPUTE('<dispute_id>', '<resolved_by>', '<note>')
-- Preconditions: dispute must exist and not already be resolved.
-- On success   : disputes.status -> 'RESOLVED', resolved_at -> now,
--                resolved_by -> resolved_by, note appended if provided.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_RESOLVE_DISPUTE(
    P_DISPUTE_ID STRING,
    P_RESOLVED_BY STRING,
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
def _fetch_one(session, sql_text, params=None):
    rows = session.sql(sql_text, params=params or []).collect()
    return rows[0] if rows else None


def run(session, p_dispute_id: str, p_resolved_by: str, p_note: str) -> dict:
    row = _fetch_one(
        session, 'SELECT STATUS FROM CASHAPP.DISPUTES WHERE DISPUTE_ID = ?', [p_dispute_id],
    )
    if row is None:
        return {'dispute_id': p_dispute_id, 'status': 'SKIPPED', 'message': 'Dispute not found'}
    if row['STATUS'] == 'RESOLVED':
        return {'dispute_id': p_dispute_id, 'status': 'SKIPPED', 'message': 'Dispute is already resolved'}

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.DISPUTES SET STATUS = 'RESOLVED', RESOLVED_AT = CURRENT_TIMESTAMP(), "
            "RESOLVED_BY = ?, NOTE = COALESCE(?, NOTE), UPDATED_AT = CURRENT_TIMESTAMP() "
            "WHERE DISPUTE_ID = ?",
            params=[p_resolved_by, p_note, p_dispute_id],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'dispute_id': p_dispute_id, 'status': 'ERROR', 'message': str(exc)}

    return {
        'dispute_id': p_dispute_id, 'status': 'RESOLVED',
        'message': 'Resolved by {}'.format(p_resolved_by or 'analyst'),
    }
$$;

GRANT USAGE ON PROCEDURE CASHAPP.SP_RESOLVE_DISPUTE(STRING, STRING, STRING) TO ROLE O2C_APP;

-- CALL CASHAPP.SP_RESOLVE_DISPUTE('<dispute_id>', 'test-user', 'Credit memo issued');
