-- ============================================================
-- Select Proposal — Snowflake Procedure (Case Action)
-- Migrated from: cash-app-snowflake-api/app/case/service.py CaseService.select_proposal
-- Entry point : CALL CASHAPP.SP_SELECT_PROPOSAL('<case_id>', '<proposal_id>')
-- Unselects any other proposal on the case, then selects the given one.
-- Requires proposal_id to belong to case_id.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_SELECT_PROPOSAL(
    P_CASE_ID STRING,
    P_PROPOSAL_ID STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
def run(session, p_case_id: str, p_proposal_id: str) -> dict:
    exists_row = session.sql(
        "SELECT 1 AS X FROM CASHAPP.CASE_MATCH_PROPOSALS WHERE PROPOSAL_ID = ? AND CASE_ID = ?",
        params=[p_proposal_id, p_case_id],
    ).collect()
    if not exists_row:
        return {
            'case_id': p_case_id, 'proposal_id': p_proposal_id, 'status': 'SKIPPED',
            'message': 'Proposal not found for case',
        }

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.CASE_MATCH_PROPOSALS SET IS_SELECTED = FALSE WHERE CASE_ID = ?",
            params=[p_case_id],
        ).collect()
        session.sql(
            "UPDATE CASHAPP.CASE_MATCH_PROPOSALS SET IS_SELECTED = TRUE WHERE PROPOSAL_ID = ?",
            params=[p_proposal_id],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'case_id': p_case_id, 'proposal_id': p_proposal_id, 'status': 'ERROR', 'message': str(exc)}

    return {'case_id': p_case_id, 'proposal_id': p_proposal_id, 'status': 'SELECTED'}
$$;

-- CALL CASHAPP.SP_SELECT_PROPOSAL('<case_id>', '<proposal_id>');
