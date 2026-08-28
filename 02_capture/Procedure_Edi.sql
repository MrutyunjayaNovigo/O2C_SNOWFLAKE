-- ============================================================
-- EDI 820 (REMADV) Capture — Snowflake Task + Procedure
-- Migrated from: cash-app-api/app/capture/service.py (run_edi_capture,
--                _edi_should_capture, _write_edi_capture) + repository.py
--                + extractor_edi.py
-- Ported to a Snowflake Python (Snowpark) stored procedure — verified 1:1
-- against the current cash-app-api source (not just the prior JS version):
-- same query filters, same should-capture gate, same Decimal-based amount
-- parsing as extractor_edi._parse_decimal (strict — a malformed numeric
-- string like SAP's trailing-minus "123.45-" yields 0, same as the app;
-- an earlier draft of this port carried over the old JS's lenient
-- parseFloat-style parsing, which has been corrected here).
--
-- One intentional divergence from the current app: cash-app-api's
-- run_edi_capture() does not actually commit/rollback per IDoc (unlike
-- run_lockbox_capture(), which does) — a single failing IDoc's partial
-- writes are not guaranteed to be rolled back there. This procedure keeps
-- the atomic per-IDoc BEGIN/COMMIT/ROLLBACK described below, matching
-- Lockbox's (correct) pattern and this file's original documented intent,
-- by deliberate choice rather than mirroring that gap.
-- Source data : master."EDIDC" (IDoc control envelope), master."EDID4"
--               (IDoc data segments), master."BSID"/"BSAD" (open/cleared
--               AR items — used only as a capture-worthiness filter)
-- Target data : cashapp.channel_captures, cashapp.capture_source_documents,
--               cashapp.capture_remittance_claims, cashapp.capture_runs,
--               cashapp.capture_error_log, cashapp.channel_sync_cursors
--
-- Behaviour preserved from the Python implementation:
--   - Cursor-based incremental capture keyed on EDIDC.DOCNUM (channel_sync_cursors)
--   - Only inbound REMADV IDocs (MESTYP='REMADV', DIRECT=2) not in a broken
--     status ('54','55','60','68') are considered, up to EDI_CAPTURE_BATCH_SIZE
--     (500) per run
--   - Segments are grouped by SEGNAM; E1EDP02/E1EDP05 children are matched to
--     their parent E1EDP01 line via PSGNUM == parent SEGNUM (ported 1:1 from
--     extract_edi's KEY=VALUE|KEY=VALUE SDATA parsing)
--   - "Should capture" filter: an IDoc with claims is skipped only if EVERY
--     claim's invoice is already cleared in BSAD and not open in BSID — i.e.
--     the IDoc is redundant. IDocs with no claims/company code always capture.
--   - Idempotency guard on (channel_id, source_reference_id=DOCNUM)
--   - Each IDoc's writes are atomic (its own BEGIN/COMMIT/ROLLBACK); on
--     failure the partial write is rolled back, the error is logged to
--     capture_error_log, and the run stops — the cursor only advances to the
--     last IDoc successfully processed, so the failed IDoc is retried next run
--   - A DOCNUM that has failed EDI_CAPTURE_MAX_RETRIES (5) times before is
--     permanently skipped (cursor advances past it) instead of blocking capture
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA cashapp;

CREATE OR REPLACE PROCEDURE cashapp.SP_EDI_CAPTURE()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import re
import json
import uuid
from datetime import datetime
from decimal import Decimal, InvalidOperation

_MAX_RETRIES = 5               # mirrors settings.EDI_CAPTURE_MAX_RETRIES
_BATCH_SIZE = 500               # mirrors settings.EDI_CAPTURE_BATCH_SIZE
_EDI_CHANNEL_CODE = 'EDI_820'
_FIELD_MAPPING = 'FIELD_MAPPING'
_BROKEN_STATUSES = "('54','55','60','68')"

_INT_RE = re.compile(r'^[+-]?\d+$')


# ── Cursor / retry helpers ──────────────────────────────────────────────────

def _upsert_cursor(session, channel_id, doc_number):
    session.sql(
        '''MERGE INTO O2C_DB.cashapp.channel_sync_cursors t
           USING (SELECT ? AS channel_id, ? AS last_processed_id) s
           ON t.channel_id = s.channel_id
           WHEN MATCHED THEN UPDATE SET t.last_processed_id = s.last_processed_id,
             t.sync_status = 'IDLE', t.error_message = NULL, t.updated_at = CURRENT_TIMESTAMP()
           WHEN NOT MATCHED THEN INSERT (channel_id, last_processed_id, sync_status, updated_at)
             VALUES (s.channel_id, s.last_processed_id, 'IDLE', CURRENT_TIMESTAMP())''',
        params=[channel_id, doc_number],
    ).collect()


def _retry_count(session, source_reference_id, channel_id):
    rows = session.sql(
        'SELECT COUNT(*) AS n FROM O2C_DB.cashapp.capture_error_log '
        'WHERE source_reference_id = ? AND channel_id = ?',
        params=[source_reference_id, channel_id],
    ).collect()
    return rows[0]["N"]


# ── SDATA / segment parsing — ported from extractor_edi.py ─────────────────

def _parse_sdata(sdata):
    result = {}
    for part in (sdata or "").split("|"):
        idx = part.find("=")
        if idx >= 0:
            key = part[:idx].strip()
            value = part[idx + 1:].strip()
            result[key] = value
    return result


def _parse_edi_date(value):
    # YYYYMMDD -> 'YYYY-MM-DD', or None if malformed (mirrors _parse_date)
    if not value or len(value) < 8:
        return None
    try:
        y = int(value[0:4])
        mo = int(value[4:6])
        d = int(value[6:8])
    except ValueError:
        return None
    try:
        return datetime(y, mo, d).strftime('%Y-%m-%d')
    except ValueError:
        return None


def _parse_decimal(value):
    # Mirrors extractor_edi._parse_decimal exactly: strict Decimal parsing,
    # not lenient prefix-parsing — a malformed string (including SAP's
    # trailing-minus convention, e.g. "123.45-") yields 0, same as the app.
    try:
        return Decimal(str(value).strip())
    except (InvalidOperation, AttributeError):
        return Decimal("0")


# ── REMADV extraction — ported from extractor_edi.extract_edi ──────────────

def _extract_edi(doc, segments):
    by_name = {}
    for s in segments:
        by_name.setdefault(s["segnam"], []).append(s)

    e1edk01 = by_name.get("E1EDK01") or []
    header = _parse_sdata(e1edk01[0]["sdata"]) if e1edk01 else {}
    currency = header.get("CURCY", "")
    payment_date = _parse_edi_date(header.get("DOCDAT", ""))

    company_code = None
    for k14_raw in by_name.get("E1EDK14", []) or []:
        d14 = _parse_sdata(k14_raw["sdata"])
        if d14.get("QUALF") == "011":
            company_code = d14.get("BUKRS") or None
            break

    claims = []
    total_amount = Decimal("0")
    p01_list = by_name.get("E1EDP01", []) or []

    for edp01 in p01_list:
        line = _parse_sdata(edp01["sdata"])
        gross = _parse_decimal(line.get("BELNR", "0"))
        total_amount += gross

        invoice_number = None
        po_number = None
        deduction = Decimal("0")
        reason_code = None

        children = [seg for seg in segments if seg["psgnum"] == edp01["segnum"]]

        for child in children:
            if child["segnam"] == "E1EDP02":
                d02 = _parse_sdata(child["sdata"])
                qualf02 = d02.get("QUALF")
                if qualf02 == "009":
                    invoice_number = d02.get("BELNR") or None
                elif qualf02 == "001":
                    po_number = d02.get("BELNR") or None
            elif child["segnam"] == "E1EDP05":
                d05 = _parse_sdata(child["sdata"])
                amt = _parse_decimal(d05.get("BETRG", "0"))
                if d05.get("ALCKZ") == "-":
                    deduction = amt
                reason_code = d05.get("QUALF") or reason_code

        if invoice_number:
            claims.append({
                "invoice_number": invoice_number,
                "gross_amount": gross,
                "deduction_amount": deduction,
                "net_amount": gross - deduction,
                "reason_code": reason_code,
                "po_number": po_number,
            })

    edkt1 = by_name.get("E1EDKT1", []) or []
    text_lines = []
    for e in edkt1:
        t = (_parse_sdata(e["sdata"]).get("TDLINE") or "").strip()
        if t:
            text_lines.append(t)
    free_text = " ".join(text_lines) if text_lines else None

    raw_segments = {}
    for seg in segments:
        raw_segments[seg["segnum"]] = {
            "name": seg["segnam"],
            "level": seg["hlevel"],
            "parent": seg["psgnum"],
            "data": seg["sdata"],
        }
    raw_segments["free_text"] = free_text

    return {
        "payer_partner_number": doc["sndprn"],
        "payment_amount": total_amount,
        "currency": currency,
        "payment_date": payment_date,
        "company_code": company_code,
        "claims": claims,
        "raw_segments": raw_segments,
    }


# ── Capture-worthiness filter — ported from _edi_should_capture ────────────

def _is_invoice_open(session, company_code, belnr):
    rows = session.sql(
        'SELECT COUNT(*) AS n FROM O2C_DB.master."BSID" WHERE "BUKRS" = ? AND "BELNR" = ?',
        params=[company_code, belnr],
    ).collect()
    return rows[0]["N"] > 0


def _is_invoice_cleared(session, company_code, belnr):
    rows = session.sql(
        'SELECT COUNT(*) AS n FROM O2C_DB.master."BSAD" WHERE "BUKRS" = ? AND "BELNR" = ?',
        params=[company_code, belnr],
    ).collect()
    return rows[0]["N"] > 0


def _should_capture(session, company_code, claims):
    if not claims or not company_code:
        return True

    for claim in claims:
        inv_num = str(claim["invoice_number"]).strip()
        if not _INT_RE.match(inv_num):
            return True

        belnr = int(inv_num)
        if _is_invoice_open(session, company_code, belnr):
            return True
        if not _is_invoice_cleared(session, company_code, belnr):
            return True
    return False


# ── Write — ported from _write_edi_capture ──────────────────────────────────

def _write_edi_capture(session, channel_id, doc_number, result):
    currency5 = (result["currency"] or "USD")[:5]

    capture_id = str(uuid.uuid4())
    session.sql(
        '''INSERT INTO O2C_DB.cashapp.channel_captures
           (capture_id, channel_id, source_reference_id, payer_name, payment_reference,
            payment_amount, currency, payment_date, extraction_method, capture_status)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING')''',
        params=[capture_id, channel_id, doc_number, result["payer_partner_number"], doc_number,
                result["payment_amount"], currency5, result["payment_date"], _FIELD_MAPPING],
    ).collect()

    document_id = str(uuid.uuid4())
    session.sql(
        '''INSERT INTO O2C_DB.cashapp.capture_source_documents
           (document_id, capture_id, channel_id, document_type, extraction_provider,
            extraction_status, parsed_content)
           SELECT ?, ?, ?, 'EDI_IDOC', ?, 'COMPLETED', PARSE_JSON(?)''',
        params=[document_id, capture_id, channel_id, _FIELD_MAPPING,
                json.dumps(result["raw_segments"], default=str)],
    ).collect()

    for claim in result["claims"]:
        claim_id = str(uuid.uuid4())
        reason_code10 = str(claim["reason_code"])[:10] if claim["reason_code"] else None
        session.sql(
            '''INSERT INTO O2C_DB.cashapp.capture_remittance_claims
               (claim_id, capture_id, source_document_id, invoice_number, gross_amount,
                deduction_amount, net_amount, currency, reason_code, po_number)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
            params=[claim_id, capture_id, document_id, claim["invoice_number"], claim["gross_amount"],
                    claim["deduction_amount"], claim["net_amount"], currency5, reason_code10,
                    claim["po_number"] or None],
        ).collect()


# ── Main capture run ────────────────────────────────────────────────────

def run(session):
    channel_rows = session.sql(
        "SELECT channel_id FROM O2C_DB.cashapp.channels WHERE channel_code = ? AND is_active = TRUE",
        params=[_EDI_CHANNEL_CODE],
    ).collect()
    if not channel_rows:
        return {"processed": 0, "captured": 0, "skipped": 0, "errors": 0,
                "message": "Channel EDI_820 not found in cashapp.channels — seed data missing"}
    channel_id = channel_rows[0]["CHANNEL_ID"]

    cursor_rows = session.sql(
        "SELECT last_processed_id FROM O2C_DB.cashapp.channel_sync_cursors WHERE channel_id = ?",
        params=[channel_id],
    ).collect()
    after_docnum = cursor_rows[0]["LAST_PROCESSED_ID"] if cursor_rows else None
    if after_docnum is None:
        after_docnum = ''

    doc_rows = session.sql(
        'SELECT "DOCNUM","SNDPRN" FROM O2C_DB.master."EDIDC" '
        'WHERE "MESTYP" = \'REMADV\' AND "DIRECT" = 2 AND "STATUS" NOT IN ' + _BROKEN_STATUSES + ' '
        'AND "DOCNUM" > ? ORDER BY "DOCNUM" LIMIT ' + str(_BATCH_SIZE),
        params=[after_docnum],
    ).collect()
    docs = [{"docnum": r["DOCNUM"], "sndprn": r["SNDPRN"]} for r in doc_rows]

    if not docs:
        return {"processed": 0, "captured": 0, "skipped": 0, "errors": 0}

    run_id = str(uuid.uuid4())
    session.sql(
        "INSERT INTO O2C_DB.cashapp.capture_runs (run_id, channel_id, batch_size, cursor_start, status) "
        "VALUES (?, ?, ?, ?, 'RUNNING')",
        params=[run_id, channel_id, _BATCH_SIZE, after_docnum if after_docnum != '' else None],
    ).collect()

    captured = skipped = errors = 0
    last_success_docnum = after_docnum

    for doc in docs:
        prior_failures = _retry_count(session, doc["docnum"], channel_id)

        if prior_failures >= _MAX_RETRIES:
            last_success_docnum = doc["docnum"]
            skipped += 1
            continue

        txn_open = False
        try:
            seg_rows = session.sql(
                'SELECT "DOCNUM","SEGNUM","SEGNAM","HLEVEL","PSGNUM","SDATA" '
                'FROM O2C_DB.master."EDID4" WHERE "DOCNUM" = ? ORDER BY "SEGNUM"',
                params=[doc["docnum"]],
            ).collect()
            segments = [{
                "docnum": r["DOCNUM"], "segnum": r["SEGNUM"], "segnam": r["SEGNAM"],
                "hlevel": r["HLEVEL"], "psgnum": r["PSGNUM"], "sdata": r["SDATA"],
            } for r in seg_rows]

            result = _extract_edi(doc, segments)

            if not _should_capture(session, result["company_code"], result["claims"]):
                skipped += 1
                last_success_docnum = doc["docnum"]
                continue

            existing = session.sql(
                "SELECT COUNT(*) AS n FROM O2C_DB.cashapp.channel_captures "
                "WHERE source_reference_id = ? AND channel_id = ?",
                params=[doc["docnum"], channel_id],
            ).collect()
            if existing[0]["N"] > 0:
                skipped += 1
                last_success_docnum = doc["docnum"]
                continue

            session.sql("BEGIN").collect()
            txn_open = True
            _write_edi_capture(session, channel_id, doc["docnum"], result)
            session.sql("COMMIT").collect()
            txn_open = False

            captured += 1
            last_success_docnum = doc["docnum"]

        except Exception as exc:
            if txn_open:
                session.sql("ROLLBACK").collect()
            errors += 1

            error_id = str(uuid.uuid4())
            err_msg = str(exc)
            session.sql(
                "INSERT INTO O2C_DB.cashapp.capture_error_log "
                "(error_id, run_id, channel_id, source_reference_id, attempt_number, "
                " error_type, error_message, error_detail) "
                "SELECT ?, ?, ?, ?, ?, 'EXTRACTION_ERROR', ?, PARSE_JSON(?)",
                params=[error_id, run_id, channel_id, doc["docnum"], prior_failures + 1,
                        err_msg[:1000], json.dumps({"message": err_msg})],
            ).collect()
            break  # cursor stays at last_success_docnum — retried next run

    if last_success_docnum and last_success_docnum != after_docnum:
        _upsert_cursor(session, channel_id, last_success_docnum)

    final_status = 'COMPLETED' if errors == 0 else 'PARTIAL'
    session.sql(
        "UPDATE O2C_DB.cashapp.capture_runs SET status = ?, finished_at = CURRENT_TIMESTAMP(), "
        "items_attempted = ?, items_captured = ?, items_skipped = ?, items_errored = ?, cursor_end = ? "
        "WHERE run_id = ?",
        params=[final_status, captured + skipped + errors, captured, skipped, errors,
                last_success_docnum if last_success_docnum != after_docnum else None, run_id],
    ).collect()

    return {
        "processed": len(docs),
        "captured": captured,
        "skipped": skipped,
        "errors": errors,
    }
$$;

-- Task orchestration for this procedure lives in Task_Capture.sql
-- (cashapp.TASK_CAPTURE, via Procedure_CaptureAll.sql).
