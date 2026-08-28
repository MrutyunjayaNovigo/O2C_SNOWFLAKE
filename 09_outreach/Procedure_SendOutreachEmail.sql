-- ============================================================
-- Send Outreach Email — Snowflake Procedure
-- Entry point : CALL CASHAPP.SP_SEND_OUTREACH_EMAIL('<request_id>')
-- Preconditions: request must exist, be DRAFTED, and the case's resolved
--                customer (if any) must have MASTER.KNA1.SMTP_ADDR set —
--                there is no other source of a destination address. A
--                request whose case has no resolved customer (approval
--                status UNRESOLVED_CUSTOMER) has no KUNNR to look up and
--                is SKIPPED, not sent nowhere.
-- On success   : actually sends via the Gmail API (not a simulation),
--                outreach_requests.status -> 'SENT', last_contact_at ->
--                now; one outreach_threads row created.
-- Replaces SP_MARK_OUTREACH_SENT, which only recorded a manual
-- confirmation because no send transport existed yet.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_SEND_OUTREACH_EMAIL(
    P_REQUEST_ID STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (eai_gmail_api)
SECRETS = (
  'gmail_oauth' = cashapp.sec_gmail_oauth
)
EXECUTE AS OWNER
AS
$$
import base64
import json
from email.mime.text import MIMEText

import requests
import _snowflake

_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
_SEND_URL = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"
_FROM_ADDR = "cashapplication2310@gmail.com"


def _fetch_one(session, sql_text, params=None):
    rows = session.sql(sql_text, params=params or []).collect()
    return rows[0] if rows else None


def _get_access_token():
    creds = json.loads(_snowflake.get_generic_secret_string('gmail_oauth'))
    resp = requests.post(
        _OAUTH_TOKEN_URL,
        data={
            'client_id': creds['client_id'],
            'client_secret': creds['client_secret'],
            'refresh_token': creds['refresh_token'],
            'grant_type': 'refresh_token',
        },
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()['access_token']


def _gmail_send(access_token, to_addr, subject, body):
    msg = MIMEText(body)
    msg['To'] = to_addr
    msg['From'] = _FROM_ADDR
    msg['Subject'] = subject
    raw = base64.urlsafe_b64encode(msg.as_bytes()).decode()
    resp = requests.post(
        _SEND_URL,
        headers={'Authorization': 'Bearer {}'.format(access_token)},
        json={'raw': raw}, timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def run(session, p_request_id: str) -> dict:
    req = _fetch_one(
        session,
        'SELECT CASE_ID, STATUS, DRAFT_SUBJECT, DRAFT_BODY FROM CASHAPP.OUTREACH_REQUESTS WHERE REQUEST_ID = ?',
        [p_request_id],
    )
    if req is None:
        return {'request_id': p_request_id, 'status': 'SKIPPED', 'message': 'Outreach request not found'}
    if req['STATUS'] != 'DRAFTED':
        return {'request_id': p_request_id, 'status': 'SKIPPED', 'message': 'Request is not in DRAFTED state'}

    case_row = _fetch_one(
        session, 'SELECT SAP_CUSTOMER_ID FROM CASHAPP.CASES WHERE CASE_ID = ?', [req['CASE_ID']],
    )
    to_addr = None
    if case_row is not None and case_row['SAP_CUSTOMER_ID']:
        cust_row = _fetch_one(
            session, 'SELECT SMTP_ADDR FROM MASTER.KNA1 WHERE KUNNR = ?', [case_row['SAP_CUSTOMER_ID']],
        )
        if cust_row is not None:
            to_addr = cust_row['SMTP_ADDR']

    if not to_addr:
        return {
            'request_id': p_request_id, 'status': 'SKIPPED',
            'message': 'No email address on file for this customer — cannot send',
        }

    try:
        access_token = _get_access_token()
        _gmail_send(access_token, to_addr, req['DRAFT_SUBJECT'], req['DRAFT_BODY'])
    except Exception as exc:
        return {'request_id': p_request_id, 'status': 'ERROR', 'message': 'Send failed: {}'.format(str(exc)[:300])}

    session.sql('BEGIN').collect()
    try:
        session.sql(
            "UPDATE CASHAPP.OUTREACH_REQUESTS SET STATUS = 'SENT', LAST_CONTACT_AT = CURRENT_TIMESTAMP(), "
            "UPDATED_AT = CURRENT_TIMESTAMP() WHERE REQUEST_ID = ?",
            params=[p_request_id],
        ).collect()
        session.sql(
            "INSERT INTO CASHAPP.OUTREACH_THREADS (REQUEST_ID, SUBJECT, STATE) VALUES (?, ?, 'OPEN')",
            params=[p_request_id, req['DRAFT_SUBJECT']],
        ).collect()
        session.sql('COMMIT').collect()
    except Exception as exc:
        session.sql('ROLLBACK').collect()
        # The email genuinely went out at this point — a DB failure here means
        # it's sent but not recorded, not that nothing happened. Surface that
        # distinction rather than reporting a generic error.
        return {
            'request_id': p_request_id, 'status': 'ERROR',
            'message': 'Email sent to {} but failed to record: {}'.format(to_addr, str(exc)[:200]),
        }

    return {'request_id': p_request_id, 'status': 'SENT', 'message': 'Email sent to {}'.format(to_addr)}
$$;

GRANT USAGE ON PROCEDURE CASHAPP.SP_SEND_OUTREACH_EMAIL(STRING) TO ROLE O2C_APP;

-- CALL CASHAPP.SP_SEND_OUTREACH_EMAIL('<request_id>');
