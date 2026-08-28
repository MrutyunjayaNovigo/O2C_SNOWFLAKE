-- Python conversion of RUN_POSTGUARD stored procedure
-- Co-authored with CoCo
-- ============================================================
-- PostGuard - Snowflake Snowpark Procedure (Service 4 Validation Gate)
-- Migrated from: cash-app-api/app/postguard/service.py,
--                cash-app-api/app/postguard/checks.py,
--                cash-app-api/app/postguard/repository.py
-- Entry point : CALL CASHAPP.RUN_POSTGUARD('<case_id>')
-- Input       : P_CASE_ID from cashapp.cases.case_id
-- Run guard   : Executes validations only when cashapp.cases.workflow_stage = 'VALIDATION'
-- Source data : cashapp.cases (case/payment context, workflow stage),
--               cashapp.case_match_proposals (selected proposal, strategy,
--               posting date, variance, tolerance group),
--               cashapp.case_invoice_matches (included invoice lines, SAP invoice
--               identifiers, company code, customer number, net amount, currency,
--               deduction reason code),
--               cashapp.system_config (default tolerances, duplicate lookback days,
--               SAP integration flag),
--               master.T001B (posting period), master.T053 (reason code to GL),
--               master.SKB1 (company-code GL validation), master.TBSL (posting keys),
--               master.TCURX (currency decimal precision), master.TCURR (FX rates),
--               master.T043 (tolerance limits), master.BKPF (duplicate AWKEY lookup)
-- Validations : 1 SCHEMA - selected proposal, included invoices, required fields,
--                 amount balance, FULL_CLEAR variance rule
--               2 PERIOD_OPEN - posting date open in master.T001B
--               3 GL_ACCOUNT - derive write-off/FX GL and validate in master.SKB1
--               4 POSTING_KEYS - validate expected BSCHL/KOART/SHKZG in master.TBSL
--               5 CURRENCY - validate TCURX precision and TCURR FX rate when needed
--               6 TOLERANCE - validate variance against master.T043 or config fallback
--               7 DUPLICATE - compute deterministic AWKEY and check master.BKPF
--               8 BAPI_DRY_RUN - simulated pass when SAP integration is disabled;
--                 fails safely when SAP integration is enabled without external RFC
-- Target data : cashapp.case_postguard_checks (one audit row per check that ran),
--               cashapp.case_events (POSTGUARD_PASS or POSTGUARD_FAIL event),
--               cashapp.cases (updates POSTGUARD_STATUS, WORKFLOW_STAGE on failure,
--               AWKEY on success; no new case row is inserted)
-- Outcome     : Stops on first failed validation. PASS updates case as postguard-ready;
--               FAIL parks the case in VALIDATION_EXCEPTION; SKIPPED returns when the
--               case is missing or not in VALIDATION stage.
-- Note        : This Snowpark version preserves the Python PostGuard control flow but
--               does not trigger the Python posting service after PASS.
-- ============================================================
USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.RUN_POSTGUARD(P_CASE_ID STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run_postguard'
EXECUTE AS OWNER
AS
$$
import snowflake.snowpark as snowpark
from snowflake.snowpark.functions import col, lit, when, coalesce, abs as sp_abs, count, min as sp_min, sum as sp_sum
from datetime import datetime
import hashlib
import json

def run_postguard(session: snowpark.Session, p_case_id: str) -> dict:
    run_at = datetime.now()
    checks_run = 0
    failed = False
    reason_code = None
    detail = None
    check_data = None

    # Helper: insert a postguard check record
    def insert_check(check_seq, check_name, passed, reason, det, data):
        data_json = json.dumps(data) if data else 'null'
        session.sql(f"""
            INSERT INTO CASHAPP.CASE_POSTGUARD_CHECKS
            (CHECK_ID, CASE_ID, RUN_AT, CHECK_SEQUENCE, CHECK_NAME, PASSED, REASON_CODE, DETAIL, CHECK_DATA)
            SELECT UUID_STRING(), ?, ?, ?, ?, ?, ?, ?, TRY_PARSE_JSON(?)
        """, params=[p_case_id, run_at, check_seq, check_name, passed, reason, det, data_json]).collect()

    # Helper: record failure event and update case
    def fail_case(failed_check, reason, det, checks_run_count):
        session.sql("""
            UPDATE CASHAPP.CASES SET POSTGUARD_STATUS = 'FAIL', WORKFLOW_STAGE = 'VALIDATION_EXCEPTION'
            WHERE CASE_ID = ?
        """, params=[p_case_id]).collect()
        event_data = json.dumps({'failed_check': failed_check, 'reason_code': reason, 'detail': det, 'checks_run': checks_run_count})
        session.sql(f"""
            INSERT INTO CASHAPP.CASE_EVENTS (EVENT_ID, CASE_ID, EVENT_TYPE, EVENT_MESSAGE, EVENT_DATA, OCCURRED_AT)
            SELECT UUID_STRING(), ?, 'POSTGUARD_FAIL', ?, TRY_PARSE_JSON(?), CURRENT_TIMESTAMP()
        """, params=[p_case_id, f'PostGuard failed - {failed_check}: {reason}', event_data]).collect()
        # Without this, the checks/update/event writes above (and every
        # insert_check() call earlier in this run) sit in an uncommitted scoped
        # transaction and Snowflake silently rolls them all back when the
        # procedure returns — postguard_status stays NULL forever.
        session.sql('COMMIT').collect()

    # Helper: fetch a single value
    def fetch_one(sql, params=None):
        rows = session.sql(sql, params=params or []).collect()
        return rows[0] if rows else None

    # === Validate case exists ===
    row = fetch_one("SELECT COUNT(*) AS CNT FROM CASHAPP.CASES WHERE CASE_ID = ?", [p_case_id])
    if row['CNT'] == 0:
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'detail': 'Case not found'}

    # === Load case data ===
    case_row = fetch_one("""
        SELECT WORKFLOW_STAGE, TO_VARCHAR(PAYMENT_ID) AS PAYMENT_ID, SAP_CUSTOMER_ID,
               CURRENCY_CODE, PAYMENT_AMOUNT
        FROM CASHAPP.CASES WHERE CASE_ID = ?
    """, [p_case_id])

    workflow_stage = case_row['WORKFLOW_STAGE']
    payment_id = case_row['PAYMENT_ID']
    sap_customer_id = case_row['SAP_CUSTOMER_ID']
    case_currency = case_row['CURRENCY_CODE']
    payment_amount = case_row['PAYMENT_AMOUNT']

    if workflow_stage != 'VALIDATION':
        return {'case_id': p_case_id, 'status': 'SKIPPED', 'detail': 'Case is not in VALIDATION stage', 'workflow_stage': workflow_stage}

    # === Load proposal ===
    prop_row = fetch_one("""
        SELECT PROPOSAL_ID, MATCH_STRATEGY, POSTING_DATE, COALESCE(VARIANCE_AMOUNT, 0) AS VARIANCE_AMOUNT, TOLERANCE_GROUP
        FROM CASHAPP.CASE_MATCH_PROPOSALS
        WHERE CASE_ID = ? AND IS_SELECTED = TRUE LIMIT 1
    """, [p_case_id])

    proposal_id = prop_row['PROPOSAL_ID'] if prop_row else None
    match_strategy = prop_row['MATCH_STRATEGY'] if prop_row else None
    posting_date = prop_row['POSTING_DATE'] if prop_row else None
    variance_amount = float(prop_row['VARIANCE_AMOUNT']) if prop_row else 0
    tolerance_group = prop_row['TOLERANCE_GROUP'] if prop_row else None

    # === Load invoice match aggregates ===
    match_row = fetch_one("""
        SELECT COUNT(*) AS MATCH_COUNT, MIN(COMPANY_CODE) AS COMPANY_CODE,
               MIN(CUSTOMER_NUMBER) AS CUSTOMER_NUMBER, MIN(CURRENCY) AS INVOICE_CURRENCY,
               COALESCE(SUM(COALESCE(NET_AMOUNT, 0)), 0) AS TOTAL_NET
        FROM CASHAPP.CASE_INVOICE_MATCHES
        WHERE PROPOSAL_ID = ? AND IS_INCLUDED = TRUE
    """, [proposal_id])

    match_count = match_row['MATCH_COUNT'] if match_row else 0
    company_code = match_row['COMPANY_CODE'] if match_row else None
    customer_number = match_row['CUSTOMER_NUMBER'] if match_row else None
    invoice_currency = match_row['INVOICE_CURRENCY'] if match_row else None
    total_net = float(match_row['TOTAL_NET']) if match_row else 0

    # ========== Check 1: SCHEMA ==========
    checks_run += 1
    failed = False
    reason_code = None
    detail = None

    if proposal_id is None:
        failed, reason_code, detail = True, 'SCHEMA_NO_PROPOSAL', 'No selected proposal found for this case'
    elif match_count == 0:
        failed, reason_code, detail = True, 'SCHEMA_NO_PROPOSAL', 'Selected proposal has no included invoice lines'
    elif not sap_customer_id or not sap_customer_id.strip():
        failed, reason_code, detail = True, 'SCHEMA_MISSING_FIELD', 'Case field sap_customer_id is null or empty'
    elif not case_currency or not case_currency.strip():
        failed, reason_code, detail = True, 'SCHEMA_MISSING_FIELD', 'Case field currency_code is null or empty'
    elif not match_strategy or not match_strategy.strip():
        failed, reason_code, detail = True, 'SCHEMA_MISSING_FIELD', 'Proposal field match_strategy is null or empty'
    elif posting_date is None:
        failed, reason_code, detail = True, 'SCHEMA_MISSING_FIELD', 'Proposal field posting_date is null'
    else:
        missing_row = fetch_one("""
            SELECT COUNT(*) AS CNT FROM CASHAPP.CASE_INVOICE_MATCHES
            WHERE PROPOSAL_ID = ? AND IS_INCLUDED = TRUE
              AND (COMPANY_CODE IS NULL OR CUSTOMER_NUMBER IS NULL OR FISCAL_YEAR IS NULL
                   OR DOCUMENT_NUMBER IS NULL OR LINE_ITEM IS NULL)
        """, [proposal_id])
        missing_count = missing_row['CNT']

        if missing_count > 0:
            failed, reason_code, detail = True, 'SCHEMA_MISSING_FIELD', 'One or more included invoice matches are missing required SAP invoice fields'
        elif abs((total_net + variance_amount) - float(payment_amount or 0)) > 0.01:
            failed, reason_code, detail = True, 'SCHEMA_UNBALANCED', 'Amounts do not balance: net amount plus variance does not equal payment amount'
        elif match_strategy == 'FULL_CLEAR' and variance_amount != 0:
            failed, reason_code, detail = True, 'SCHEMA_UNBALANCED', 'Strategy FULL_CLEAR requires zero variance'
        else:
            detail = 'Proposal schema valid'

    insert_check(1, 'SCHEMA', not failed, reason_code if failed else None, detail, None)
    if failed:
        fail_case('SCHEMA', reason_code, detail, checks_run)
        return {'case_id': p_case_id, 'postguard_status': 'FAIL', 'failed_check': 'SCHEMA', 'reason_code': reason_code}

    # ========== Check 2: PERIOD_OPEN ==========
    checks_run += 1
    failed = False
    reason_code = None

    period_row = fetch_one("""
        SELECT COUNT(*) AS CNT FROM MASTER.T001B
        WHERE BUKRS = ? AND MKOAR = '+' AND DATAB <= ? AND DATBI >= ? LIMIT 1
    """, [company_code, posting_date, posting_date])

    if period_row['CNT'] == 0:
        failed, reason_code, detail = True, 'PERIOD_CLOSED', 'Posting date is not within any open period for company code'
    else:
        detail = 'Posting period open'

    insert_check(2, 'PERIOD_OPEN', not failed, reason_code if failed else None, detail, None)
    if failed:
        fail_case('PERIOD_OPEN', reason_code, detail, checks_run)
        return {'case_id': p_case_id, 'postguard_status': 'FAIL', 'failed_check': 'PERIOD_OPEN', 'reason_code': reason_code}

    # ========== Check 3: GL_ACCOUNT ==========
    checks_run += 1
    failed = False
    reason_code = None
    check_data = None
    gl_account = None
    gl_source = None

    if match_strategy == 'FULL_CLEAR':
        detail = 'FULL_CLEAR - no write-off GL line to validate'
    else:
        if match_strategy == 'FX_WRITE_OFF':
            gl_account = 880000
            gl_source = 'FX gain/loss'
        else:
            reason_row = fetch_one("""
                SELECT MIN(DEDUCTION_REASON_CODE) AS REASON
                FROM CASHAPP.CASE_INVOICE_MATCHES
                WHERE PROPOSAL_ID = ? AND IS_INCLUDED = TRUE AND DEDUCTION_REASON_CODE IS NOT NULL
            """, [proposal_id])
            reason_for_gl = reason_row['REASON'] if reason_row else None

            gl_row = fetch_one("""
                SELECT TRY_TO_NUMBER(TRIM(HKONT)) AS GL FROM MASTER.T053
                WHERE RSTGR = ? LIMIT 1
            """, [reason_for_gl])
            gl_account = gl_row['GL'] if gl_row else None
            gl_source = 'T053 reason code'

        if gl_account is None:
            failed, reason_code, detail = True, 'GL_ACCOUNT_INVALID', 'Cannot derive write-off GL account'
        else:
            skb1_row = fetch_one("""
                SELECT COUNT(*) AS CNT FROM MASTER.SKB1
                WHERE SAKNR = ? AND BUKRS = ?
            """, [gl_account, company_code])

            if skb1_row['CNT'] == 0:
                failed, reason_code, detail = True, 'GL_ACCOUNT_INVALID', 'GL account not found in SKB1 for company code'
            else:
                detail = 'GL account valid in SKB1'
                check_data = {'gl_account': int(gl_account), 'source': gl_source}

    insert_check(3, 'GL_ACCOUNT', not failed, reason_code if failed else None, detail, check_data)
    if failed:
        fail_case('GL_ACCOUNT', reason_code, detail, checks_run)
        return {'case_id': p_case_id, 'postguard_status': 'FAIL', 'failed_check': 'GL_ACCOUNT', 'reason_code': reason_code}

    # ========== Check 4: POSTING_KEYS ==========
    checks_run += 1
    failed = False
    reason_code = None
    check_data = None

    pk_row = fetch_one("""
        WITH EXPECTED AS (
            SELECT * FROM VALUES
                ('FULL_CLEAR',   'D', 'H', '15'),
                ('FULL_CLEAR',   'S', 'S', '40'),
                ('WRITE_OFF',    'D', 'H', '15'),
                ('WRITE_OFF',    'S', 'S', '40'),
                ('WRITE_OFF',    'S', 'S', '40'),
                ('FX_WRITE_OFF', 'D', 'H', '15'),
                ('FX_WRITE_OFF', 'S', 'S', '40'),
                ('FX_WRITE_OFF', 'S', 'H', '50'),
                ('RESIDUAL',     'D', 'H', '15'),
                ('RESIDUAL',     'S', 'S', '40'),
                ('RESIDUAL',     'D', 'S', '06'),
                ('PARTIAL',      'D', 'H', '15'),
                ('PARTIAL',      'S', 'S', '40')
            AS E(STRATEGY, KOART, SHKZG, BSCHL)
        )
        SELECT COUNT(*) AS BAD_COUNT
        FROM EXPECTED E
        LEFT JOIN MASTER.TBSL T ON T.BSCHL = E.BSCHL
        WHERE E.STRATEGY = COALESCE(?, 'FULL_CLEAR')
          AND (T.BSCHL IS NULL OR COALESCE(T.KOART, '') <> E.KOART OR COALESCE(T.SHKZG, '') <> E.SHKZG)
    """, [match_strategy])

    if pk_row['BAD_COUNT'] > 0:
        failed, reason_code, detail = True, 'POSTING_KEY_INVALID', 'One or more posting keys are missing or do not match expected KOART/SHKZG'
    else:
        detail = 'Posting keys valid for strategy'
        check_data = {'strategy': match_strategy}

    insert_check(4, 'POSTING_KEYS', not failed, reason_code if failed else None, detail, check_data)
    if failed:
        fail_case('POSTING_KEYS', reason_code, detail, checks_run)
        return {'case_id': p_case_id, 'postguard_status': 'FAIL', 'failed_check': 'POSTING_KEYS', 'reason_code': reason_code}

    # ========== Check 5: CURRENCY ==========
    checks_run += 1
    failed = False
    reason_code = None
    check_data = None

    cur_row = fetch_one("SELECT CURRDEC FROM MASTER.TCURX WHERE CURRKEY = TRIM(?) LIMIT 1", [case_currency])
    dec_places = cur_row['CURRDEC'] if cur_row else None

    if dec_places is None:
        failed, reason_code, detail = True, 'CURRENCY_PRECISION_INVALID', 'Currency not found in TCURX'
    else:
        amount_str = str(payment_amount)
        if '.' in amount_str:
            actual_decimals = len(amount_str.split('.')[1].rstrip('0'))
        else:
            actual_decimals = 0

        if actual_decimals > int(dec_places):
            failed, reason_code, detail = True, 'CURRENCY_PRECISION_INVALID', 'Payment amount has more decimal places than currency allows'
        elif (match_strategy == 'FX_WRITE_OFF' and invoice_currency
              and invoice_currency.strip() != case_currency.strip()):
            fx_row = fetch_one("""
                SELECT UKURS FROM MASTER.TCURR
                WHERE KURST = 'M' AND FCURR = TRIM(?) AND TCURR = TRIM(?) AND GDATU <= ?
                ORDER BY GDATU DESC LIMIT 1
            """, [case_currency, invoice_currency, posting_date])
            fx_rate = fx_row['UKURS'] if fx_row else None

            if fx_rate is None:
                failed, reason_code, detail = True, 'FX_RATE_MISSING', 'No exchange rate found on or before posting date'
            else:
                detail = 'Currency precision and FX rate valid'
                check_data = {'fx_rate': float(fx_rate), 'from_currency': case_currency, 'to_currency': invoice_currency}
        else:
            detail = 'Currency precision valid; FX check skipped'

    insert_check(5, 'CURRENCY', not failed, reason_code if failed else None, detail, check_data)
    if failed:
        fail_case('CURRENCY', reason_code, detail, checks_run)
        return {'case_id': p_case_id, 'postguard_status': 'FAIL', 'failed_check': 'CURRENCY', 'reason_code': reason_code}

    # ========== Check 6: TOLERANCE ==========
    checks_run += 1
    failed = False
    reason_code = None
    check_data = None
    variance_abs = abs(variance_amount)

    if match_strategy == 'FULL_CLEAR' or variance_abs == 0:
        detail = 'FULL_CLEAR or zero variance - tolerance check skipped'
    else:
        tol_row = fetch_one("""
            SELECT COUNT(*) AS CNT FROM MASTER.T043
            WHERE BUKRS = ? AND TOGRU = ? AND WAERS = TRIM(?)
        """, [company_code, tolerance_group, case_currency])

        if tol_row['CNT'] > 0:
            tol_vals = fetch_one("""
                SELECT COALESCE(PRZTL, 0) AS TOL_PCT, COALESCE(WRBTR, 0) AS TOL_ABS
                FROM MASTER.T043
                WHERE BUKRS = ? AND TOGRU = ? AND WAERS = TRIM(?) LIMIT 1
            """, [company_code, tolerance_group, case_currency])
            tol_pct = float(tol_vals['TOL_PCT'])
            tol_abs_val = float(tol_vals['TOL_ABS'])
            allowed = max((tol_pct / 100) * float(payment_amount or 0), tol_abs_val)
        else:
            cfg_row = fetch_one("""
                SELECT CONFIG_VALUE FROM CASHAPP.SYSTEM_CONFIG
                WHERE CONFIG_KEY = 'default_amount_tolerance_pct' AND COMPANY_CODE IS NULL LIMIT 1
            """)
            tol_pct = float(cfg_row['CONFIG_VALUE']) if cfg_row and cfg_row['CONFIG_VALUE'] else 0.01

            cfg_row2 = fetch_one("""
                SELECT CONFIG_VALUE FROM CASHAPP.SYSTEM_CONFIG
                WHERE CONFIG_KEY = 'default_amount_tolerance_abs' AND COMPANY_CODE IS NULL LIMIT 1
            """)
            tol_abs_val = float(cfg_row2['CONFIG_VALUE']) if cfg_row2 and cfg_row2['CONFIG_VALUE'] else 1.00
            allowed = max(tol_pct * float(payment_amount or 0), tol_abs_val)

        if variance_abs > allowed:
            failed, reason_code, detail = True, 'TOLERANCE_EXCEEDED', 'Variance exceeds allowed tolerance'
        else:
            detail = 'Variance within tolerance'
            check_data = {'variance': variance_abs, 'allowed': allowed}

    insert_check(6, 'TOLERANCE', not failed, reason_code if failed else None, detail, check_data)
    if failed:
        fail_case('TOLERANCE', reason_code, detail, checks_run)
        return {'case_id': p_case_id, 'postguard_status': 'FAIL', 'failed_check': 'TOLERANCE', 'reason_code': reason_code}

    # ========== Check 7: DUPLICATE ==========
    checks_run += 1
    failed = False
    reason_code = None
    check_data = None

    keys_row = fetch_one("""
        SELECT LISTAGG(TO_VARCHAR(FISCAL_YEAR) || '-' || TO_VARCHAR(DOCUMENT_NUMBER) || '-' || LINE_ITEM, '|')
               WITHIN GROUP (ORDER BY FISCAL_YEAR, DOCUMENT_NUMBER, LINE_ITEM) AS INVOICE_KEYS
        FROM CASHAPP.CASE_INVOICE_MATCHES
        WHERE PROPOSAL_ID = ? AND IS_INCLUDED = TRUE
    """, [proposal_id])
    invoice_keys = keys_row['INVOICE_KEYS'] if keys_row else ''

    # Compute AWKEY hash
    hash_input = f"{payment_id or ''}:{company_code or ''}:{invoice_keys or ''}:{float(payment_amount or 0)}:{match_strategy or ''}:{posting_date}"
    awkey = hashlib.sha256(hash_input.encode()).hexdigest()[:32]

    # Lookback days config
    cfg_row = fetch_one("""
        SELECT CONFIG_VALUE FROM CASHAPP.SYSTEM_CONFIG
        WHERE CONFIG_KEY = 'duplicate_lookback_days' AND COMPANY_CODE IS NULL LIMIT 1
    """)
    lookback_days = int(cfg_row['CONFIG_VALUE']) if cfg_row and cfg_row['CONFIG_VALUE'] else 90

    dup_row = fetch_one("""
        SELECT TO_VARCHAR(MIN(BELNR)) AS EXISTING_BELNR FROM MASTER.BKPF
        WHERE AWKEY = ? AND BUDAT >= DATEADD(DAY, ?, ?)
    """, [awkey, -lookback_days, posting_date])
    existing_belnr = dup_row['EXISTING_BELNR'] if dup_row else None

    if existing_belnr:
        failed, reason_code, detail = True, 'DUPLICATE_POSTING', 'AWKEY already exists in BKPF'
        check_data = {'awkey': awkey, 'original_belnr': existing_belnr}
    else:
        detail = 'No duplicate found for AWKEY'
        check_data = {'awkey': awkey}

    insert_check(7, 'DUPLICATE', not failed, reason_code if failed else None, detail, check_data)
    if failed:
        fail_case('DUPLICATE', reason_code, detail, checks_run)
        return {'case_id': p_case_id, 'postguard_status': 'FAIL', 'failed_check': 'DUPLICATE', 'reason_code': reason_code}

    # ========== Check 8: BAPI_DRY_RUN ==========
    checks_run += 1
    failed = False
    reason_code = None
    check_data = None

    sap_row = fetch_one("""
        SELECT CONFIG_VALUE FROM CASHAPP.SYSTEM_CONFIG
        WHERE CONFIG_KEY = 'sap_integration_enabled' AND COMPANY_CODE IS NULL LIMIT 1
    """)
    sap_integrated = sap_row['CONFIG_VALUE'] if sap_row else 'false'

    if (sap_integrated or 'false').lower() == 'true':
        failed, reason_code = True, 'BAPI_CHECK_FAILED'
        detail = 'SAP integration is enabled, but pure Snowflake SQL cannot call BAPI_ACC_DOCUMENT_CHECK without an external function'
    else:
        detail = 'SAP integration disabled - dry-run simulated as PASS'
        check_data = {
            'bapi_return': [{'TYPE': 'S', 'ID': 'F5', 'NUMBER': '743', 'MESSAGE': 'Document is ready for posting', 'SYSTEM': 'SIMULATED'}]
        }

    insert_check(8, 'BAPI_DRY_RUN', not failed, reason_code if failed else None, detail, check_data)
    if failed:
        fail_case('BAPI_DRY_RUN', reason_code, detail, checks_run)
        return {'case_id': p_case_id, 'postguard_status': 'FAIL', 'failed_check': 'BAPI_DRY_RUN', 'reason_code': reason_code}

    # ========== All checks passed ==========
    session.sql("""
        UPDATE CASHAPP.CASES SET POSTGUARD_STATUS = 'PASS', AWKEY = ? WHERE CASE_ID = ?
    """, params=[awkey, p_case_id]).collect()

    event_data = json.dumps({'checks_run': checks_run, 'awkey': awkey})
    session.sql("""
        INSERT INTO CASHAPP.CASE_EVENTS (EVENT_ID, CASE_ID, EVENT_TYPE, EVENT_MESSAGE, EVENT_DATA, OCCURRED_AT)
        SELECT UUID_STRING(), ?, 'POSTGUARD_PASS', 'PostGuard passed - all checks green', TRY_PARSE_JSON(?), CURRENT_TIMESTAMP()
    """, params=[p_case_id, event_data]).collect()

    # See fail_case() above — same uncommitted-scoped-transaction issue applies
    # to the pass path: without this, POSTGUARD_STATUS/AWKEY and every
    # insert_check() row from this run are rolled back on return.
    session.sql('COMMIT').collect()

    return {'case_id': p_case_id, 'postguard_status': 'PASS', 'checks_run': checks_run, 'awkey': awkey}
$$;



--CALL CASHAPP.RUN_POSTGUARD('<case_id>');
