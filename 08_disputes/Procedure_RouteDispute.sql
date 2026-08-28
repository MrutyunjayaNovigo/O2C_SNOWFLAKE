-- ============================================================
-- Route Dispute — Snowflake Procedure (Dispute Action)
-- Entry point : CALL CASHAPP.SP_ROUTE_DISPUTE('<dispute_id>', '<owner>')
-- Preconditions: dispute must exist.
-- On success   : disputes.status -> 'ROUTED_TO_REP', owner_name -> owner.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_ROUTE_DISPUTE(
    P_DISPUTE_ID STRING,
    P_OWNER STRING
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


def run(session, p_dispute_id: str, p_owner: str) -> dict:
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
            "UPDATE CASHAPP.DISPUTES SET STATUS = 'ROUTED_TO_REP', OWNER_NAME = ?, "
            "UPDATED_AT = CURRENT_TIMESTAMP() WHERE DISPUTE_ID = ?",
            params=[p_owner, p_dispute_id],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'dispute_id': p_dispute_id, 'status': 'ERROR', 'message': str(exc)}

    return {
        'dispute_id': p_dispute_id, 'status': 'ROUTED_TO_REP',
        'message': 'Dispute routed to {}'.format(p_owner or 'reviewer'),
    }
$$;

GRANT USAGE ON PROCEDURE CASHAPP.SP_ROUTE_DISPUTE(STRING, STRING) TO ROLE O2C_APP;

-- CALL CASHAPP.SP_ROUTE_DISPUTE('<dispute_id>', 'M. Okonkwo · Sales');
