-- ============================================================
-- Copilot tool: case retrieval — Snowflake Procedure
-- Entry point : CALL CASHAPP.SP_TOOL_CASE_RETRIEVAL('<case_number or case_id>')
-- Reads       : cashapp.cases, cashapp.payments, master.kna1
-- Writes      : nothing. This tool is read-only by design.
-- Contract    : always returns {ok: bool, ...}. It never raises — an exception
--               inside an agent loop kills the run, so failures come back as
--               data the model can reason about.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_TOOL_CASE_RETRIEVAL(
    P_CASE_REF STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
def _one(session, sql_text, params=None):
    rows = session.sql(sql_text, params=params or []).collect()
    return rows[0] if rows else None


def _num(v):
    return float(v) if v is not None else None


def run(session, p_case_ref: str) -> dict:
    ref = (p_case_ref or '').strip()
    if not ref:
        return {'ok': False, 'reason': 'No case reference supplied'}

    # Accept either the human-facing case number or the UUID, so the model can
    # pass through whatever the user typed without a lookup step of its own.
    case = _one(session, """
        SELECT c.CASE_ID, c.CASE_NUMBER, c.CASE_STATUS, c.WORKFLOW_STAGE, c.PRIORITY_LEVEL,
               c.PAYMENT_AMOUNT, c.CURRENCY_CODE, c.SAP_CUSTOMER_ID, c.SAP_COMPANY_CODE,
               c.MATCH_STRATEGY, c.MATCH_CONFIDENCE, c.RESOLUTION_LAYER, c.AUTONOMY_TIER,
               c.APPROVAL_STATUS, c.POSTGUARD_STATUS, c.ROUTE_REASON, c.ASSIGNED_TO,
               c.SAP_DOCUMENT_NUMBER, c.PAYMENT_ID, c.CREATED_AT
        FROM CASHAPP.CASES c
        WHERE c.CASE_NUMBER = ? OR c.CASE_ID = ?
        LIMIT 1
    """, [ref, ref])

    if case is None:
        return {'ok': False, 'reason': f'No case found for reference {ref}'}

    payment = None
    if case['PAYMENT_ID']:
        payment = _one(session, """
            SELECT PAYMENT_REFERENCE, BANK_REFERENCE, PAYMENT_AMOUNT, APPLIED_AMOUNT,
                   UNAPPLIED_AMOUNT, CURRENCY_CODE, PAYMENT_DATE, PAYMENT_STATUS
            FROM CASHAPP.PAYMENTS WHERE PAYMENT_ID = ?
        """, [case['PAYMENT_ID']])

    customer_name = None
    if case['SAP_CUSTOMER_ID']:
        cust = _one(session,
                    'SELECT NAME1 FROM MASTER.KNA1 WHERE KUNNR = ? LIMIT 1',
                    [case['SAP_CUSTOMER_ID']])
        customer_name = cust['NAME1'] if cust else None

    return {
        'ok': True,
        'case': {
            'case_id': case['CASE_ID'],
            'case_number': case['CASE_NUMBER'],
            'status': case['CASE_STATUS'],
            'workflow_stage': case['WORKFLOW_STAGE'],
            'priority': case['PRIORITY_LEVEL'],
            'payment_amount': _num(case['PAYMENT_AMOUNT']),
            'currency': case['CURRENCY_CODE'],
            'customer_id': case['SAP_CUSTOMER_ID'],
            'customer_name': customer_name,
            'company_code': case['SAP_COMPANY_CODE'],
            'match_strategy': case['MATCH_STRATEGY'],
            'match_confidence': _num(case['MATCH_CONFIDENCE']),
            'resolution_layer': case['RESOLUTION_LAYER'],
            'autonomy_tier': case['AUTONOMY_TIER'],
            'approval_status': case['APPROVAL_STATUS'],
            'postguard_status': case['POSTGUARD_STATUS'],
            'route_reason': case['ROUTE_REASON'],
            'assigned_to': case['ASSIGNED_TO'],
            'sap_document_number': case['SAP_DOCUMENT_NUMBER'],
            'created_at': str(case['CREATED_AT']) if case['CREATED_AT'] else None,
        },
        'payment': None if payment is None else {
            'reference': payment['PAYMENT_REFERENCE'],
            'bank_reference': payment['BANK_REFERENCE'],
            'amount': _num(payment['PAYMENT_AMOUNT']),
            'applied': _num(payment['APPLIED_AMOUNT']),
            'unapplied': _num(payment['UNAPPLIED_AMOUNT']),
            'currency': payment['CURRENCY_CODE'],
            'payment_date': str(payment['PAYMENT_DATE']) if payment['PAYMENT_DATE'] else None,
            'status': payment['PAYMENT_STATUS'],
        },
    }
$$;

GRANT USAGE ON PROCEDURE CASHAPP.SP_TOOL_CASE_RETRIEVAL(STRING) TO ROLE O2C_APP;

-- CALL CASHAPP.SP_TOOL_CASE_RETRIEVAL('CC-1042');
