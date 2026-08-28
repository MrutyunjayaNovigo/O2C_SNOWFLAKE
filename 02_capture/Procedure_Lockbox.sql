-- ============================================================
-- Lockbox Capture — Snowflake Task + Procedure
-- Migrated from: cash-app-api/app/capture/service.py (run_lockbox_capture,
--                _write_lockbox_capture) + repository.py + extractor_lockbox.py
-- Ported to a Snowflake Python (Snowpark) stored procedure — verified 1:1
-- against the current cash-app-api source (not just the prior JS version):
-- same query filters, same 3-tier SGTXT regex fallback, same atomic
-- per-batch commit/rollback as run_lockbox_capture (which — unlike
-- run_edi_capture — already does this correctly in the app today).
-- Source data : master."FLB2" (payment lines), master."FEBLB" (expected item counts)
-- Target data : cashapp.channel_captures, cashapp.capture_source_documents,
--               cashapp.capture_remittance_claims, cashapp.capture_runs,
--               cashapp.capture_error_log, cashapp.channel_sync_cursors
--
-- Behaviour preserved from the Python implementation:
--   - Cursor-based incremental capture keyed on FLB2.BATCH (channel_sync_cursors)
--   - Idempotency guard on (channel_id, source_reference_id)
--   - A batch is only processed once ALL of its FLB2 lines have arrived
--     (FEBLB.ITEM_COUNT is the expected count) — otherwise the whole run
--     defers at that point so a partially-landed batch isn't captured early
--   - A batch is written atomically: if any line in the batch fails, every
--     capture written for that batch is rolled back, the failure is logged
--     to capture_error_log, and the run stops (cursor does not advance past
--     the last fully-committed batch — the batch is retried on the next run)
--   - A batch that has failed MAX_RETRIES times in the past is permanently
--     skipped (cursor advances past it) instead of blocking the pipeline
--   - SGTXT free-text parsing (payer name + invoice reference extraction)
--     ported 1:1 from extractor_lockbox.parse_sgtxt's 3-tier regex fallback
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA cashapp;

CREATE OR REPLACE PROCEDURE cashapp.SP_LOCKBOX_CAPTURE()
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

_MAX_RETRIES = 5               # mirrors settings.LOCKBOX_CAPTURE_MAX_RETRIES
_LOCKBOX_CHANNEL_CODE = 'LOCKBOX'
_FIELD_MAPPING = 'FIELD_MAPPING'

# ── SGTXT parsing — ported from extractor_lockbox.parse_sgtxt ──────────────
_RE1 = re.compile(r'\b([A-Z][A-Z0-9]{0,7}(?:-[A-Z0-9]{1,8}){0,2}-\d{1,8})\b', re.IGNORECASE)
_RE2 = re.compile(r'\b(?:INV(?:OICE)?|REF|DOC|ORD(?:ER)?|PO)[#\-\s]*(\d{4,12})\b', re.IGNORECASE)
_RE3 = re.compile(r'\b(\d{7,10})\b')
_SPLIT_RE = re.compile(
    r'\b(?:INV(?:OICE)?|REF|DOC|ORD(?:ER)?|PO|CHK|CHECK|PAYMENT|REMIT(?:TANCE)?|FOR)\b', re.IGNORECASE)
_DIGITS4_RE = re.compile(r'\d{4,}')
_NON_NAME_CHARS_RE = re.compile(r'[^a-zA-Z\s&.\-]')
_LEADING_ZEROS_RE = re.compile(r'^0+')


def _parse_sgtxt(text):
    if not text or not text.strip():
        return {"payer_name": None, "invoice_refs": []}
    text = text.strip()

    seen = set()
    invoice_refs = []

    # Priority 1 — full alphanumeric refs (SC-01, PE-DOC-003, INV-2026-0042)
    for m in _RE1.finditer(text):
        ref = m.group(1)
        if ref not in seen:
            seen.add(ref)
            invoice_refs.append(ref)

    # Priority 2 — labeled numeric refs (INV 1800000001, PO# 98765432)
    if not invoice_refs:
        for m in _RE2.finditer(text):
            ref = _LEADING_ZEROS_RE.sub('', m.group(1)) or m.group(1)
            if ref not in seen:
                seen.add(ref)
                invoice_refs.append(ref)

    # Priority 3 — bare SAP BELNR (7-10 digit number)
    if not invoice_refs:
        for m in _RE3.finditer(text):
            ref = _LEADING_ZEROS_RE.sub('', m.group(1)) or m.group(1)
            if ref not in seen:
                seen.add(ref)
                invoice_refs.append(ref)

    # Payer name — text before the first keyword or long numeric sequence
    name_part = _SPLIT_RE.split(text, maxsplit=1)[0]
    name_part = _DIGITS4_RE.split(name_part, maxsplit=1)[0]
    name_part = _NON_NAME_CHARS_RE.sub(' ', name_part)
    payer_name = ' '.join(name_part.split())

    return {
        "payer_name": payer_name if len(payer_name) >= 3 else None,
        "invoice_refs": invoice_refs,
    }


# ── Cursor / retry helpers ──────────────────────────────────────────────────

def _upsert_cursor(session, channel_id, batch):
    session.sql(
        '''MERGE INTO O2C_DB.cashapp.channel_sync_cursors t
           USING (SELECT ? AS channel_id, ? AS last_processed_id) s
           ON t.channel_id = s.channel_id
           WHEN MATCHED THEN UPDATE SET t.last_processed_id = s.last_processed_id,
             t.sync_status = 'IDLE', t.error_message = NULL, t.updated_at = CURRENT_TIMESTAMP()
           WHEN NOT MATCHED THEN INSERT (channel_id, last_processed_id, sync_status, updated_at)
             VALUES (s.channel_id, s.last_processed_id, 'IDLE', CURRENT_TIMESTAMP())''',
        params=[channel_id, batch],
    ).collect()


def _retry_count(session, source_reference_id, channel_id):
    rows = session.sql(
        'SELECT COUNT(*) AS n FROM O2C_DB.cashapp.capture_error_log '
        'WHERE source_reference_id = ? AND channel_id = ?',
        params=[source_reference_id, channel_id],
    ).collect()
    return rows[0]["N"]


# ── Main capture run ────────────────────────────────────────────────────

def run(session):
    channel_rows = session.sql(
        "SELECT channel_id FROM O2C_DB.cashapp.channels WHERE channel_code = ? AND is_active = TRUE",
        params=[_LOCKBOX_CHANNEL_CODE],
    ).collect()
    if not channel_rows:
        return {"processed": 0, "captured": 0, "skipped": 0, "errors": 0,
                "message": "Channel LOCKBOX not found in cashapp.channels — seed data missing"}
    channel_id = channel_rows[0]["CHANNEL_ID"]

    cursor_rows = session.sql(
        "SELECT last_processed_id FROM O2C_DB.cashapp.channel_sync_cursors WHERE channel_id = ?",
        params=[channel_id],
    ).collect()
    after_batch = cursor_rows[0]["LAST_PROCESSED_ID"] if cursor_rows else None
    if after_batch is None:
        after_batch = ''

    batch_rows = session.sql(
        'SELECT DISTINCT "BATCH" FROM O2C_DB.master."FLB2" WHERE "BATCH" > ? ORDER BY "BATCH"',
        params=[after_batch],
    ).collect()
    batches = [r["BATCH"] for r in batch_rows]

    if not batches:
        return {"processed": 0, "captured": 0, "skipped": 0, "errors": 0}

    run_id = str(uuid.uuid4())
    session.sql(
        "INSERT INTO O2C_DB.cashapp.capture_runs (run_id, channel_id, batch_size, cursor_start, status) "
        "VALUES (?, ?, NULL, ?, 'RUNNING')",
        params=[run_id, channel_id, after_batch if after_batch != '' else None],
    ).collect()

    total_captured = total_skipped = total_errors = 0
    batches_processed = 0
    last_success_batch = after_batch

    for batch in batches:
        prior_failures = _retry_count(session, batch, channel_id)

        if prior_failures >= _MAX_RETRIES:
            last_success_batch = batch
            total_skipped += 1
            _upsert_cursor(session, channel_id, batch)
            continue

        line_rows = session.sql(
            'SELECT "BATCH","ITEM_NO","CHECK_NUMBER","CHECK_DATE","CHECK_AMOUNT","REASON_CODE","SGTXT" '
            'FROM O2C_DB.master."FLB2" WHERE "BATCH" = ? AND "CHECK_AMOUNT" > 0 ORDER BY "ITEM_NO"',
            params=[batch],
        ).collect()
        lines = [{
            "batch": r["BATCH"], "item_no": r["ITEM_NO"], "check_number": r["CHECK_NUMBER"],
            "check_date": r["CHECK_DATE"], "check_amount": r["CHECK_AMOUNT"],
            "reason_code": r["REASON_CODE"], "sgtxt": r["SGTXT"],
        } for r in line_rows]

        if not lines:
            last_success_batch = batch
            _upsert_cursor(session, channel_id, batch)
            continue

        expected_rows = session.sql(
            'SELECT SUM("ITEM_COUNT") AS n FROM O2C_DB.master."FEBLB" WHERE "BATCH" = ?',
            params=[batch],
        ).collect()
        expected_count = expected_rows[0]["N"] if expected_rows else None

        if expected_count is not None and len(lines) < expected_count:
            # Batch incomplete — defer this and every later batch to the next run
            break

        session.sql("BEGIN").collect()

        batch_captured = batch_skipped = 0
        batch_failed_line = batch_failed_msg = None

        for line in lines:
            source_ref = "{}:{}".format(batch, line["item_no"])
            try:
                existing = session.sql(
                    "SELECT COUNT(*) AS n FROM O2C_DB.cashapp.channel_captures "
                    "WHERE source_reference_id = ? AND channel_id = ?",
                    params=[source_ref, channel_id],
                ).collect()
                if existing[0]["N"] > 0:
                    batch_skipped += 1
                    continue

                parsed = _parse_sgtxt(line["sgtxt"])
                check_date_str = line["check_date"].strftime('%Y-%m-%d') if line["check_date"] else None

                capture_id = str(uuid.uuid4())
                session.sql(
                    '''INSERT INTO O2C_DB.cashapp.channel_captures
                       (capture_id, channel_id, source_reference_id, payer_name, payment_reference,
                        payment_amount, currency, payment_date, extraction_method, capture_status)
                       VALUES (?, ?, ?, ?, ?, ?, 'USD', ?, ?, 'PENDING')''',
                    params=[capture_id, channel_id, source_ref, parsed["payer_name"],
                            line["check_number"] or None, line["check_amount"], check_date_str,
                            _FIELD_MAPPING],
                ).collect()

                raw_fields = {
                    "BATCH": line["batch"], "ITEM_NO": line["item_no"],
                    "CHECK_NUMBER": line["check_number"], "CHECK_DATE": check_date_str,
                    "CHECK_AMOUNT": line["check_amount"], "REASON_CODE": line["reason_code"],
                    "SGTXT": line["sgtxt"], "parsed_payer_name": parsed["payer_name"],
                    "parsed_invoice_refs": parsed["invoice_refs"], "free_text": line["sgtxt"] or None,
                }

                document_id = str(uuid.uuid4())
                session.sql(
                    '''INSERT INTO O2C_DB.cashapp.capture_source_documents
                       (document_id, capture_id, channel_id, document_type, extraction_provider,
                        extraction_status, parsed_content)
                       SELECT ?, ?, ?, 'LOCKBOX_RECORD', ?, 'COMPLETED', PARSE_JSON(?)''',
                    params=[document_id, capture_id, channel_id, _FIELD_MAPPING,
                            json.dumps(raw_fields, default=str)],
                ).collect()

                for ref in parsed["invoice_refs"]:
                    claim_id = str(uuid.uuid4())
                    reason_code10 = str(line["reason_code"])[:10] if line["reason_code"] else None
                    session.sql(
                        '''INSERT INTO O2C_DB.cashapp.capture_remittance_claims
                           (claim_id, capture_id, source_document_id, invoice_number, reason_code)
                           VALUES (?, ?, ?, ?, ?)''',
                        params=[claim_id, capture_id, document_id, ref, reason_code10],
                    ).collect()

                batch_captured += 1
            except Exception as line_err:
                batch_failed_line = source_ref
                batch_failed_msg = str(line_err)
                break

        if batch_failed_msg is not None:
            session.sql("ROLLBACK").collect()
            total_errors += 1

            error_id = str(uuid.uuid4())
            error_detail = {"failed_line": batch_failed_line, "message": batch_failed_msg}
            session.sql(
                "INSERT INTO O2C_DB.cashapp.capture_error_log "
                "(error_id, run_id, channel_id, source_reference_id, attempt_number, "
                " error_type, error_message, error_detail) "
                "SELECT ?, ?, ?, ?, ?, 'EXTRACTION_ERROR', ?, PARSE_JSON(?)",
                params=[error_id, run_id, channel_id, batch, prior_failures + 1,
                        batch_failed_msg[:1000], json.dumps(error_detail, default=str)],
            ).collect()
            break  # cursor stays at last_success_batch — whole batch retried next run

        _upsert_cursor(session, channel_id, batch)
        session.sql("COMMIT").collect()

        last_success_batch = batch
        total_captured += batch_captured
        total_skipped += batch_skipped
        batches_processed += 1

    final_status = 'COMPLETED' if total_errors == 0 else 'PARTIAL'
    cursor_end = last_success_batch if last_success_batch != after_batch else None

    session.sql(
        "UPDATE O2C_DB.cashapp.capture_runs SET status = ?, finished_at = CURRENT_TIMESTAMP(), "
        "items_attempted = ?, items_captured = ?, items_skipped = ?, items_errored = ?, cursor_end = ? "
        "WHERE run_id = ?",
        params=[final_status, total_captured + total_skipped + total_errors, total_captured,
                total_skipped, total_errors, cursor_end, run_id],
    ).collect()

    return {
        "processed": batches_processed,
        "captured": total_captured,
        "skipped": total_skipped,
        "errors": total_errors,
    }
$$;

-- Task orchestration for this procedure lives in Task_Capture.sql
-- (cashapp.TASK_CAPTURE, via Procedure_CaptureAll.sql).
