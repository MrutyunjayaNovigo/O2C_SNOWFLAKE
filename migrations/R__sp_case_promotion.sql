-- ============================================================
-- Case Promotion — Snowflake Task + Procedure (Service 2)
-- Migrated from: cash-app-api/app/case/promotion_service.py,
--                app/case/promotion_repository.py,
--                app/customer/service.py, app/customer/repository.py
-- Source data : cashapp.channel_captures (PENDING), master."FEBEP" +
--               master."FEBKO" (bank credit confirmation), master."KNA1" +
--               master."KNBK" (customer master, for resolution)
-- Target data : cashapp.payments, cashapp.cases, cashapp.case_events,
--               cashapp.channel_captures (status advance)
--
-- Ported to a Snowflake Python (Snowpark) stored procedure — verified 1:1
-- against the current cash-app-api source, not just the prior JavaScript
-- version. Two things changed from that JS version as a result:
--
--   1. Layer 2 fuzzy matching now uses the real `rapidfuzz` library
--      (fuzz.token_sort_ratio) — the exact same function the app calls.
--      The JS version had to hand-roll an LCS-based approximation of
--      token_sort_ratio (no fuzzy-matching library available in Snowflake
--      JavaScript) and carried an explicit caveat that its scores were
--      "close in spirit but not bit-for-bit identical" to the app. Python
--      removes that gap entirely — requires the `rapidfuzz` package to be
--      available in the Snowflake Anaconda channel your account uses;
--      confirm with a scratch CREATE PROCEDURE before relying on this.
--   2. The CUSTOMER_RESOLVED case_event's message and event_data now
--      include the numeric resolution_layer (e.g. "... via BANK_ACCOUNT
--      layer 1 (confidence 1.000)") — the JS version omitted it from both
--      the message and the payload; the Python app includes it in both.
--
-- Behaviour preserved:
--   - Scans PENDING channel_captures oldest-first, up to BATCH_SIZE (50)
--     per run. A capture without a confirmed FEBEP bank credit stays
--     PENDING and is retried next run (this is the "wait for settlement"
--     gate — not a failure).
--   - FEBEP match: BTRG > 0 (credit), BTRG == capture payment amount
--     (truncated to integer via Python int(), same truncate-toward-zero
--     semantics as the app's int(capture.payment_amount) — same unit-scale
--     assumption as the Python repository: confirm with business before
--     processing minor-unit currencies), FEBKO.BUDAT within +/-7 days of
--     capture.payment_date.
--   - A FEBEP line is claimed exclusively via payments.bank_reference
--     ('KUKEY:ESNUM') so two captures can never promote off the same
--     bank credit line.
--   - Customer resolution — 4-layer cascade, identical precedence and
--     confidence values to app/customer/service.py:
--       Pre-layer : direct KUNNR lookup (handles EDI SNDPRN arriving
--                   without leading zeros) -> KUNNR_DIRECT, 0.95
--       Layer 1   : exact bank account match (KNBK.BANKN [+ BANKL])
--                   -> BANK_ACCOUNT, 1.0
--       Layer 2   : fuzzy name match on KNA1.NAME1 / KNBK.KOINH via
--                   rapidfuzz.fuzz.token_sort_ratio -> FUZZY_NAME,
--                   round(score/100, 3) (threshold 75)
--       Layer 3   : single unique substring hit on KNA1.NAME1 using the
--                   longest "significant" word (>=4 chars, business-
--                   suffix stop words removed) -> PATTERN, 0.5
--       Layer 4   : unresolved -> UNRESOLVED, 0.0, sap_customer_id NULL
--   - cases.resolution_layer stores the resolution METHOD string (e.g.
--     'BANK_ACCOUNT'), not the numeric layer — this mirrors an existing
--     naming quirk in the Python model (Case.resolution_layer is set to
--     resolution.resolution_method), preserved here for parity rather
--     than "fixed", since fixing it is a cross-repo schema/API decision.
--   - case_number format CASE-YYYYMMDD-XXXXXXXX (UTC date + 8 hex chars),
--     generated in pure Python (datetime/uuid) — same approach as the app,
--     rather than round-tripping through SQL as the JS version did.
--   - Each capture is promoted in its own transaction (payment + case +
--     capture status update + 2 case_events, all-or-nothing). Any failure
--     during that write rolls back and counts as skipped, not an error —
--     most likely a unique-constraint clash on cases.capture_id from a
--     concurrent run. NOTE: this is intentionally broader than what
--     cash-app-api's own code does today — the app only wraps the final
--     `db.commit()` in a narrow `except IntegrityError`, but since
--     SQLAlchemy's flush() sends INSERTs to Postgres immediately (and
--     Postgres validates UNIQUE constraints at insert time, not deferred),
--     a concurrent capture_id clash is more likely to surface earlier, at
--     the Case row's own flush — outside that narrow except — and count as
--     an error in the app rather than a skip. This procedure keeps the
--     broader, more defensive per-capture transaction (matching this
--     file's own documented intent) rather than reproducing that gap.
--   - Resolution failures (e.g. a bad KNA1/KNBK query) are NOT caught by
--     the per-capture write's rollback — they happen before BEGIN and
--     propagate to the outer per-capture loop, which counts them as
--     errors, same as the app.
--   - workflow_stage is set to 'MATCHING' and left there — this replaces
--     the Python asyncio.create_task(run_matching(...)) fire-and-forget
--     call, which has no equivalent in a scheduled-task model. Once the
--     Matching phase (04_matching) is migrated, its task polls
--     cases WHERE workflow_stage = 'MATCHING' instead of being triggered
--     inline.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA cashapp;

CREATE OR REPLACE PROCEDURE cashapp.SP_CASE_PROMOTION()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'rapidfuzz')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import re
import json
import uuid
from datetime import timedelta, datetime, timezone
from decimal import Decimal

from rapidfuzz import fuzz

_BATCH_SIZE = 50                # mirrors PromotionService._BATCH_SIZE
_DATE_WINDOW_DAYS = 7            # mirrors PromotionService._DATE_WINDOW
_FUZZY_THRESHOLD = 75            # mirrors customer/service.py _FUZZY_THRESHOLD
_MIN_WORD_LEN = 4                # mirrors customer/service.py _MIN_WORD_LEN

# Common business-name tokens that appear in many company names — not distinctive
_STOP_WORDS = frozenset({
    "corp", "corporation", "inc", "incorporated", "ltd", "limited", "llc",
    "company", "companies", "group", "international", "industries", "industry",
    "services", "solutions", "enterprise", "enterprises", "holdings",
    "partners", "partnership", "association", "associates",
    "and", "the", "of", "for",
})

_WORD_RE = re.compile(r'[a-zA-Z]+')


# ── Helpers — ported from promotion_service.py's module-level helpers ──────

def _new_case_number():
    today = datetime.now(timezone.utc).strftime('%Y%m%d')
    suffix = uuid.uuid4().hex[:8].upper()
    return "CASE-{}-{}".format(today, suffix)


def _priority_for(amount):
    if amount is None:
        return "LOW"
    amt = amount if isinstance(amount, Decimal) else Decimal(str(amount))
    if amt >= Decimal("50000"):
        return "HIGH"
    if amt >= Decimal("5000"):
        return "MEDIUM"
    return "LOW"


def _significant_words(name):
    if not name:
        return []
    tokens = _WORD_RE.findall(name.lower())
    return [t for t in tokens if len(t) >= _MIN_WORD_LEN and t not in _STOP_WORDS]


# ── Customer repository reads — ported from app/customer/repository.py ─────

def _find_by_kunnr(session, kunnr):
    raw = kunnr.strip()
    candidates = list({raw, raw.zfill(10)})
    placeholders = ", ".join(["?"] * len(candidates))
    rows = session.sql(
        'SELECT "KUNNR", "NAME1" FROM O2C_DB.master."KNA1" '
        'WHERE "KUNNR" IN ({}) LIMIT 1'.format(placeholders),
        params=candidates,
    ).collect()
    return (rows[0]["KUNNR"], rows[0]["NAME1"]) if rows else None


def _find_by_bank_account(session, bank_account, bank_key):
    sql = ('SELECT k."KUNNR", a."NAME1" FROM O2C_DB.master."KNBK" k '
           'LEFT JOIN O2C_DB.master."KNA1" a ON k."KUNNR" = a."KUNNR" '
           'WHERE k."BANKN" = ?')
    params = [bank_account]
    if bank_key:
        sql += ' AND k."BANKL" = ?'
        params.append(bank_key)
    sql += ' LIMIT 1'
    rows = session.sql(sql, params=params).collect()
    return (rows[0]["KUNNR"], rows[0]["NAME1"]) if rows else None


def _load_all_for_fuzzy(session):
    rows = session.sql(
        'SELECT a."KUNNR", a."NAME1", k."KOINH" FROM O2C_DB.master."KNA1" a '
        'LEFT JOIN O2C_DB.master."KNBK" k ON a."KUNNR" = k."KUNNR"'
    ).collect()
    return [(r["KUNNR"], r["NAME1"] or "", r["KOINH"]) for r in rows]


def _find_by_name_pattern(session, word):
    rows = session.sql(
        'SELECT "KUNNR", "NAME1" FROM O2C_DB.master."KNA1" WHERE "NAME1" ILIKE ?',
        params=["%" + word + "%"],
    ).collect()
    return [(r["KUNNR"], r["NAME1"] or "") for r in rows]


# ── 4-layer customer resolution cascade — ported from app/customer/service.py ──

def _fuzzy_match(payer_name, candidates):
    best_per_kunnr = {}   # kunnr -> (score, name1)
    for kunnr, name1, koinh in candidates:
        s_name = fuzz.token_sort_ratio(payer_name, name1) if name1 else 0
        s_koinh = fuzz.token_sort_ratio(payer_name, koinh) if koinh else 0
        score = max(s_name, s_koinh)
        current = best_per_kunnr.get(kunnr)
        if current is None or score > current[0]:
            best_per_kunnr[kunnr] = (score, name1)

    if not best_per_kunnr:
        return None

    best_kunnr = max(best_per_kunnr, key=lambda k: best_per_kunnr[k][0])
    best_score, best_name = best_per_kunnr[best_kunnr]

    if best_score < _FUZZY_THRESHOLD:
        return None

    return {
        "customer_number": best_kunnr,
        "resolution_layer": 2,
        "resolution_method": "FUZZY_NAME",
        "confidence": round(best_score / 100.0, 3),
        "customer_name": best_name,
    }


def _pattern_match(session, payer_name):
    words = _significant_words(payer_name)
    for word in sorted(words, key=len, reverse=True):
        matches = _find_by_name_pattern(session, word)
        if len(matches) == 1:
            kunnr, name1 = matches[0]
            return {
                "customer_number": kunnr,
                "resolution_layer": 3,
                "resolution_method": "PATTERN",
                "confidence": 0.5,
                "customer_name": name1,
            }
    return None


def _resolve_customer(session, payer_name, bank_account, bank_key):
    has_name = bool(payer_name and payer_name.strip())

    # Pre-layer: direct KUNNR lookup (handles EDI SNDPRN arriving without leading zeros)
    if has_name:
        match = _find_by_kunnr(session, payer_name.strip())
        if match:
            kunnr, name1 = match
            return {
                "customer_number": kunnr,
                "resolution_layer": 1,
                "resolution_method": "KUNNR_DIRECT",
                "confidence": 0.95,
                "customer_name": name1,
            }

    # Layer 1: exact bank account match
    if bank_account:
        match = _find_by_bank_account(session, bank_account, bank_key)
        if match:
            kunnr, name1 = match
            return {
                "customer_number": kunnr,
                "resolution_layer": 1,
                "resolution_method": "BANK_ACCOUNT",
                "confidence": 1.0,
                "customer_name": name1,
            }

    # Layer 2: fuzzy name match
    if has_name:
        candidates = _load_all_for_fuzzy(session)
        result = _fuzzy_match(payer_name, candidates)
        if result:
            return result

    # Layer 3: pattern match
    if has_name:
        result = _pattern_match(session, payer_name)
        if result:
            return result

    # Layer 4: unresolved
    return {
        "customer_number": None,
        "resolution_layer": 4,
        "resolution_method": "UNRESOLVED",
        "confidence": 0.0,
        "customer_name": None,
    }


# ── Promotion repository reads — ported from app/case/promotion_repository.py ──

def _case_exists_for_capture(session, capture_id):
    rows = session.sql(
        "SELECT COUNT(*) AS n FROM O2C_DB.cashapp.cases WHERE capture_id = ?",
        params=[capture_id],
    ).collect()
    return rows[0]["N"] > 0


def _find_matching_febep(session, amount_int, payment_date, window_days):
    date_from = payment_date - timedelta(days=window_days)
    date_to = payment_date + timedelta(days=window_days)
    rows = session.sql(
        '''SELECT f."KUKEY", f."ESNUM", f."GPART", f."VWEZW"
           FROM O2C_DB.master."FEBEP" f
           JOIN O2C_DB.master."FEBKO" k ON f."KUKEY" = k."KUKEY"
           WHERE f."BTRG" > 0 AND f."BTRG" = ?
             AND k."BUDAT" BETWEEN ? AND ?
             AND NOT EXISTS (
                   SELECT 1 FROM O2C_DB.cashapp.payments p
                   WHERE p.bank_reference = CONCAT(f."KUKEY", ':', f."ESNUM")
                 )
           LIMIT 1''',
        params=[amount_int, date_from, date_to],
    ).collect()
    if not rows:
        return None
    r = rows[0]
    return r["KUKEY"], r["ESNUM"], r["GPART"], r["VWEZW"]


# ── Per-capture promotion — ported from PromotionService._promote_one ──────

def _promote_one(session, cap):
    if _case_exists_for_capture(session, cap["capture_id"]):
        return "skipped"

    if cap["payment_date"] is None:
        return "skipped"  # can't narrow FEBEP search without a payment date

    amount_int = int(cap["payment_amount"])
    match = _find_matching_febep(session, amount_int, cap["payment_date"], _DATE_WINDOW_DAYS)
    if match is None:
        return "skipped"  # no bank confirmation yet — retry next run

    kukey, esnum, gpart, vwezw = match

    resolve_payer_name = cap["payer_name"] if (cap["payer_name"] and cap["payer_name"].strip()) else gpart
    resolve_bank_account = cap["payer_bank_account"] if cap["payer_bank_account"] else (gpart or None)
    resolution = _resolve_customer(session, resolve_payer_name, resolve_bank_account, cap["payer_bank_code"])

    bank_ref = "{}:{}".format(kukey, esnum)
    currency = (cap["currency"] or "USD")[:5].strip()

    session.sql("BEGIN").collect()
    try:
        payment_id = str(uuid.uuid4())
        session.sql(
            '''INSERT INTO O2C_DB.cashapp.payments
               (payment_id, capture_id, sap_customer_id, payment_amount, applied_amount, unapplied_amount,
                currency_code, payment_date, payment_reference, bank_reference, payment_status)
               VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, 'NEW')''',
            params=[payment_id, cap["capture_id"], resolution["customer_number"], cap["payment_amount"],
                    cap["payment_amount"], currency, cap["payment_date"], vwezw, bank_ref],
        ).collect()

        case_id = str(uuid.uuid4())
        case_number = _new_case_number()
        session.sql(
            '''INSERT INTO O2C_DB.cashapp.cases
               (case_id, case_number, capture_id, payment_id, sap_customer_id, case_status, workflow_stage,
                priority_level, payment_amount, currency_code, resolution_layer, resolution_confidence)
               VALUES (?, ?, ?, ?, ?, 'OPEN', 'MATCHING', ?, ?, ?, ?, ?)''',
            params=[case_id, case_number, cap["capture_id"], payment_id, resolution["customer_number"],
                    _priority_for(cap["payment_amount"]), cap["payment_amount"], currency,
                    resolution["resolution_method"] if resolution["customer_number"] else None,
                    Decimal(str(resolution["confidence"]))],
        ).collect()

        session.sql(
            "UPDATE O2C_DB.cashapp.channel_captures "
            "SET capture_status = 'CASE_CREATED', case_id = ?, updated_at = CURRENT_TIMESTAMP() "
            "WHERE capture_id = ?",
            params=[case_id, cap["capture_id"]],
        ).collect()

        ev1_data = {
            "channel_id": cap["channel_id"],
            "source_reference_id": cap["source_reference_id"],
            "payment_amount": str(cap["payment_amount"]),
            "currency": cap["currency"],
            "payment_date": str(cap["payment_date"]),
            "bank_ref": bank_ref,
        }
        session.sql(
            "INSERT INTO O2C_DB.cashapp.case_events (event_id, case_id, event_type, event_message, event_data) "
            "SELECT ?, ?, 'PAYMENT_INGESTED', ?, PARSE_JSON(?)",
            params=[str(uuid.uuid4()), case_id,
                    "Payment ingested — source ref {}".format(cap["source_reference_id"]),
                    json.dumps(ev1_data, default=str)],
        ).collect()

        if resolution["customer_number"]:
            resolved_msg = (
                "Customer resolved — KUNNR {} via {} · layer {} (confidence {:.3f})".format(
                    resolution["customer_number"], resolution["resolution_method"],
                    resolution["resolution_layer"], resolution["confidence"])
            )
        else:
            resolved_msg = "Customer unresolved — no match found"

        ev2_data = {
            "customer_number": resolution["customer_number"],
            "customer_name": resolution["customer_name"],
            "resolution_method": resolution["resolution_method"],
            "resolution_layer": resolution["resolution_layer"],
            "confidence": resolution["confidence"],
        }
        session.sql(
            "INSERT INTO O2C_DB.cashapp.case_events (event_id, case_id, event_type, event_message, event_data) "
            "SELECT ?, ?, 'CUSTOMER_RESOLVED', ?, PARSE_JSON(?)",
            params=[str(uuid.uuid4()), case_id, resolved_msg, json.dumps(ev2_data, default=str)],
        ).collect()

        session.sql("COMMIT").collect()
        return "promoted"
    except Exception:
        # Most likely a cases.capture_id unique-constraint clash from a
        # concurrent run — treat as skipped, not an error.
        session.sql("ROLLBACK").collect()
        return "skipped"


# ── Main promotion pass ──────────────────────────────────────────────────

def run(session):
    cap_rows = session.sql(
        "SELECT capture_id, payer_name, payer_bank_account, payer_bank_code, payment_amount, "
        "       currency, payment_date, source_reference_id, channel_id "
        "FROM O2C_DB.cashapp.channel_captures "
        "WHERE capture_status = 'PENDING' "
        "ORDER BY created_at ASC "
        "LIMIT ?",
        params=[_BATCH_SIZE],
    ).collect()

    captures = [{
        "capture_id": r["CAPTURE_ID"], "payer_name": r["PAYER_NAME"],
        "payer_bank_account": r["PAYER_BANK_ACCOUNT"], "payer_bank_code": r["PAYER_BANK_CODE"],
        "payment_amount": r["PAYMENT_AMOUNT"], "currency": r["CURRENCY"],
        "payment_date": r["PAYMENT_DATE"], "source_reference_id": r["SOURCE_REFERENCE_ID"],
        "channel_id": r["CHANNEL_ID"],
    } for r in cap_rows]

    if not captures:
        return {"processed": 0, "promoted": 0, "skipped": 0, "errors": 0}

    promoted = skipped = errors = 0

    for cap in captures:
        try:
            outcome = _promote_one(session, cap)
            if outcome == "promoted":
                promoted += 1
            else:
                skipped += 1
        except Exception:
            try:
                session.sql("ROLLBACK").collect()
            except Exception:
                pass  # no active txn — ignore
            errors += 1

    return {
        "processed": len(captures),
        "promoted": promoted,
        "skipped": skipped,
        "errors": errors,
    }
$$;

-- Task orchestration for this procedure lives in Task_CasePromotion.sql
-- (cashapp.TASK_CASE_PROMOTION).
