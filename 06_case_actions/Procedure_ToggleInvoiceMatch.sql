-- ============================================================
-- Toggle Invoice Match — Snowflake Procedure (Case Action)
-- Migrated from: cash-app-snowflake-api/app/case/service.py CaseService.toggle_invoice_match
-- Entry point : CALL CASHAPP.SP_TOGGLE_INVOICE_MATCH('<match_id>', '<proposal_id>', TRUE|FALSE)
-- Sets case_invoice_matches.is_included for a single match row. Requires
-- match_id to belong to proposal_id.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_TOGGLE_INVOICE_MATCH(
    P_MATCH_ID STRING,
    P_PROPOSAL_ID STRING,
    P_IS_INCLUDED BOOLEAN
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
def run(session, p_match_id: str, p_proposal_id: str, p_is_included: bool) -> dict:
    session.sql('BEGIN').collect()
    try:
        result = session.sql(
            "UPDATE CASHAPP.CASE_INVOICE_MATCHES SET IS_INCLUDED = ? "
            "WHERE MATCH_ID = ? AND PROPOSAL_ID = ?",
            params=[p_is_included, p_match_id, p_proposal_id],
        ).collect()
        rows_affected = result[0]['number of rows updated'] if result else 0

        if rows_affected == 0:
            session.sql('ROLLBACK').collect()
            return {
                'match_id': p_match_id, 'proposal_id': p_proposal_id, 'status': 'SKIPPED',
                'message': 'Invoice match not found',
            }

        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'match_id': p_match_id, 'proposal_id': p_proposal_id, 'status': 'ERROR', 'message': str(exc)}

    return {
        'match_id': p_match_id, 'proposal_id': p_proposal_id, 'status': 'UPDATED',
        'is_included': p_is_included,
    }
$$;

-- CALL CASHAPP.SP_TOGGLE_INVOICE_MATCH('<match_id>', '<proposal_id>', TRUE);
