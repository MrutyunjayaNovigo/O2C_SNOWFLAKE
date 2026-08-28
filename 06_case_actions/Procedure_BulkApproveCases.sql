-- ============================================================
-- Bulk Approve Cases — Snowflake Procedure (Case Action)
-- Migrated from: cash-app-snowflake-api/app/case/service.py CaseService.bulk_approve_cases
-- Entry point : CALL CASHAPP.SP_BULK_APPROVE_CASES(ARRAY_CONSTRUCT('<case_id_1>', '<case_id_2>'), '<approved_by>', '<note>')
-- Approves a list of cases independently — a failure on one case does not
-- block the others. Delegates all per-case validation/transition/event/
-- PostGuard-trigger logic to CASHAPP.SP_APPROVE_CASE, called once per
-- case_id, so the two procedures cannot drift out of sync.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_BULK_APPROVE_CASES(
    P_CASE_IDS ARRAY,
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
def run(session, p_case_ids: list, p_approved_by: str, p_note: str) -> dict:
    results = []
    for case_id in p_case_ids:
        try:
            result = session.call('CASHAPP.SP_APPROVE_CASE', case_id, p_approved_by, p_note)
        except Exception as exc:
            result = {'case_id': case_id, 'status': 'ERROR', 'message': str(exc)}
        results.append(result)

    succeeded = sum(1 for r in results if r.get('status') == 'APPROVED')
    return {
        'total': len(results),
        'succeeded': succeeded,
        'failed': len(results) - succeeded,
        'results': results,
    }
$$;

-- CALL CASHAPP.SP_BULK_APPROVE_CASES(ARRAY_CONSTRUCT('<case_id_1>', '<case_id_2>'), 'test-user', 'testing bulk approve');
