-- ============================================================
-- Draft Outreach — Snowflake Procedure
-- Entry point : CALL CASHAPP.SP_DRAFT_OUTREACH('<case_id>')
-- Preconditions: case must exist and approval_status must be one of the
--                two categories with a real, reliable flag today —
--                UNRESOLVED_CUSTOMER or NO_OPEN_INVOICES. Any other case
--                (including the three reason categories with no backing
--                flag yet — missing remittance, PO-not-invoice, unreadable
--                scan) is SKIPPED, not guessed at.
-- On success   : inserts a cashapp.outreach_requests row, status DRAFTED,
--                drafted via SNOWFLAKE.CORTEX.COMPLETE in a language
--                inferred from the customer's KNA1.LAND1 country code —
--                a guess, not a known correspondence-language preference.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_DRAFT_OUTREACH(
    P_CASE_ID STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
import uuid

_CORTEX_MODEL = "llama3.1-70b"

_REASON_TEXT = {
    'UNRESOLVED_CUSTOMER': "we could not identify which customer this payment belongs to",
    'NO_OPEN_INVOICES': "the customer we identified for this payment has no open invoices to apply it against",
}

# Inferred from country — a reasonable default, not a stated preference.
_LANG_BY_COUNTRY = {
    'DE': ('de', 'German'), 'AT': ('de', 'German'), 'CH': ('de', 'German'),
    'FR': ('fr', 'French'), 'BE': ('fr', 'French'),
    'SA': ('ar', 'Arabic'), 'AE': ('ar', 'Arabic'), 'EG': ('ar', 'Arabic'),
    'QA': ('ar', 'Arabic'), 'KW': ('ar', 'Arabic'), 'BH': ('ar', 'Arabic'),
}
_DEFAULT_LANG = ('en', 'English')


def _fetch_one(session, sql_text, params=None):
    rows = session.sql(sql_text, params=params or []).collect()
    return rows[0] if rows else None


def _llm_complete(session, system_msg, user_msg):
    rows = session.sql(
        "SELECT SNOWFLAKE.CORTEX.COMPLETE(?, CONCAT(?, '\\n\\n', ?)) AS response",
        params=[_CORTEX_MODEL, system_msg, user_msg],
    ).collect()
    return rows[0]['RESPONSE']


def run(session, p_case_id: str) -> dict:
    case_row = _fetch_one(
        session,
        'SELECT CASE_NUMBER, SAP_CUSTOMER_ID, PAYMENT_AMOUNT, CURRENCY_CODE, APPROVAL_STATUS '
        'FROM CASHAPP.CASES WHERE CASE_ID = ?',
        [p_case_id],
    )
    if case_row is None:
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'message': 'Case not found'}

    approval_status = case_row['APPROVAL_STATUS']
    if approval_status not in _REASON_TEXT:
        return {
            'case_id': p_case_id, 'status': 'SKIPPED',
            'message': 'No reliable reason detected for this case (approval_status={})'.format(approval_status),
        }

    customer_name = None
    lang_code, lang_label = _DEFAULT_LANG
    if case_row['SAP_CUSTOMER_ID']:
        cust_row = _fetch_one(
            session, 'SELECT NAME1, LAND1 FROM MASTER.KNA1 WHERE KUNNR = ?',
            [case_row['SAP_CUSTOMER_ID']],
        )
        if cust_row is not None:
            customer_name = cust_row['NAME1']
            lang_code, lang_label = _LANG_BY_COUNTRY.get(cust_row['LAND1'], _DEFAULT_LANG)

    reason_sentence = _REASON_TEXT[approval_status]
    prompt = (
        'Case {}: payment of {} {} received. Customer on file: {}. '
        'Issue: {}.'
    ).format(
        case_row['CASE_NUMBER'], case_row['PAYMENT_AMOUNT'], case_row['CURRENCY_CODE'],
        customer_name or 'unknown', reason_sentence,
    )
    system_msg = (
        'You are an accounts receivable analyst writing a short, polite email to a '
        'customer to resolve a payment application issue. Write the email in {}. '
        'Return ONLY a valid JSON object with keys "subject" and "body" (body uses \\n '
        'for line breaks). No prose, no markdown fences, no text outside the JSON object.'
    ).format(lang_label)

    raw = _llm_complete(session, system_msg, prompt)
    try:
        drafted = json.loads(raw)
        subject = drafted['subject']
        body = drafted['body']
    except Exception:
        return {'case_id': p_case_id, 'status': 'ERROR', 'message': 'Cortex did not return valid JSON'}

    request_id = str(uuid.uuid4())
    session.sql('BEGIN').collect()
    try:
        session.sql(
            "INSERT INTO CASHAPP.OUTREACH_REQUESTS "
            "(REQUEST_ID, CASE_ID, REASON, CHANNEL, LANG, STATUS, DRAFT_SUBJECT, DRAFT_BODY) "
            "SELECT ?, ?, ?, 'EMAIL', ?, 'DRAFTED', ?, ?",
            params=[request_id, p_case_id, approval_status, lang_code, subject, body],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        return {'case_id': p_case_id, 'status': 'ERROR', 'message': str(exc)}

    return {
        'request_id': request_id, 'case_id': p_case_id, 'status': 'DRAFTED', 'lang': lang_code,
        'message': 'Draft ready in {}'.format(lang_label),
    }
$$;

GRANT USAGE ON PROCEDURE CASHAPP.SP_DRAFT_OUTREACH(STRING) TO ROLE O2C_APP;

-- CALL CASHAPP.SP_DRAFT_OUTREACH('<case_id>');
