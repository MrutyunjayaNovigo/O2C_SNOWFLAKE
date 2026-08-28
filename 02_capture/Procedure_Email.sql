-- Email capture stored procedure with dynamic extraction_method and fixed confidence handling
-- Co-authored with CoCo
-- ============================================================
-- Phase 2 (Capture, Hop 1) — Email
-- Gmail REST API + external LLM (body) + Azure DI (attachments)
--                                       -->  cashapp.channel_captures
--                                            cashapp.capture_source_documents
--                                            cashapp.capture_remittance_claims
--
-- Port of CaptureService.run_email_capture / _write_email_capture
-- (cash-app-api/app/capture/service.py) plus extractor_email.py's body/
-- attachment orchestration. Control flow, retry/skip thresholds, and the
-- confidence capture-gate are preserved exactly.
--
-- NOTE: this does NOT use IMAP. Snowflake's HOST_PORT egress network rules
-- only allow ports 80/443, so raw IMAP (port 993) cannot be reached from a
-- stored procedure at all — confirmed by testing, not a config mistake.
-- Mail is fetched via the Gmail REST API (HTTPS/443) instead — same data,
-- different transport. See email_capture_prereqs.sql for the one-time
-- OAuth2 setup this requires (scripts/gmail_oauth_setup.py gets the
-- refresh token).
--
-- This procedure reaches two live external services (see
-- email_capture_prereqs.sql — must be run first): Gmail API and Azure
-- Document Intelligence. Body-text extraction uses Snowflake's native
-- SNOWFLAKE.CORTEX.COMPLETE (llama3.1-70b, see _CORTEX_MODEL below)
-- instead of the app's external Groq call — an intentional deviation from
-- cash-app-api, not a gap: keeps LLM inference on Snowflake credits rather
-- than a separate external LLM API. Azure DI is not Cortex Document AI —
-- reimplemented here as a raw REST call against the same API the app's
-- Azure DI SDK wraps, since that SDK isn't in the Snowflake Anaconda
-- channel — same provider, same model, no SDK dependency.
--
-- Idempotency uses MERGE against an enforced UNIQUE(channel_id,
-- source_reference_id) on channel_captures (see prereqs file, item 6) —
-- available now that Hybrid Tables are in place, unlike the existence-
-- check-then-INSERT pattern lockbox still uses.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA cashapp;

CREATE OR REPLACE PROCEDURE O2C_DB.cashapp.sp_capture_email()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests', 'snowflake-ml-python')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (eai_gmail_api, eai_azure_di)
SECRETS = (
  'gmail_oauth'  = cashapp.sec_gmail_oauth,
  'azure_di_key' = cashapp.sec_azure_di_key
)
AS
$$
import re
import io
import json
import time
import uuid
import base64
import traceback
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation

import requests
import _snowflake

_CHANNEL_CODE = "EMAIL"

# Gmail REST API — not IMAP. Snowflake's HOST_PORT egress network rules only
# allow ports 80/443, so raw IMAP (port 993) cannot be reached from inside a
# stored procedure at all. Gmail's API is the HTTPS/443 equivalent of the
# IMAP fetch app/core/email_client.py used to do.
_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
_GMAIL_API_BASE = "https://gmail.googleapis.com/gmail/v1/users/me"

# Snowflake Cortex LLM — runs natively, no external egress or API key needed.
# llama3.1-70b offers strong instruction-following for structured extraction.
_CORTEX_MODEL = "llama3.1-70b"

# Kept in sync manually with app/core/config.py AZURE_DI_ENDPOINT.
_AZURE_DI_ENDPOINT = "https://apsdocintelligence.cognitiveservices.azure.com"
_AZURE_DI_INVOICE_MODEL = "prebuilt-invoice"
_AZURE_DI_LAYOUT_MODEL = "prebuilt-layout"

_LAYOUT_MIMES = {
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "text/csv", "text/plain",
}
_MIME_TO_DOC_TYPE = {
    "application/pdf": "PDF", "image/png": "IMAGE", "image/jpeg": "IMAGE",
    "image/jpg": "IMAGE", "image/tiff": "IMAGE", "image/bmp": "IMAGE",
    "application/vnd.ms-excel": "EXCEL",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "EXCEL",
    "text/csv": "CSV",
}


def _classify_error(exc):
    if isinstance(exc, (ValueError, KeyError, AttributeError, IndexError)):
        return "PARSE_ERROR"
    return "EXTRACTION_ERROR"


# ── Channel / cursor / config helpers (same shape as sp_capture_lockbox) ────

def _get_channel_id(session):
    rows = session.sql(
        'SELECT channel_id FROM cashapp.channels WHERE channel_code = ? AND is_active = TRUE',
        params=[_CHANNEL_CODE],
    ).collect()
    if not rows:
        raise Exception("Channel EMAIL not found in cashapp.channels — seed data missing")
    return rows[0]["CHANNEL_ID"]


def _get_cursor(session, channel_id):
    rows = session.sql(
        'SELECT last_processed_at FROM cashapp.channel_sync_cursors WHERE channel_id = ?',
        params=[channel_id],
    ).collect()
    if not rows or rows[0]["LAST_PROCESSED_AT"] is None:
        return None
    value = rows[0]["LAST_PROCESSED_AT"]
    # TIMESTAMP_TZ always returns with tzinfo from Snowpark. If somehow naive,
    # treat as UTC (should not happen with the explicit +0000 writes).
    return value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)


def _upsert_cursor(session, channel_id, last_id, last_at):
    # Keep the datetime timezone-aware as UTC when binding — Snowflake's
    # TIMESTAMP_TZ will store the correct +0000 offset. The previous approach
    # (strip tzinfo → bind naive) caused Snowflake to apply the session TZ
    # offset (-0700), corrupting the cursor by +7h on read.
    last_at_utc = last_at.astimezone(timezone.utc)
    session.sql(
        '''MERGE INTO cashapp.channel_sync_cursors t
           USING (SELECT ? AS channel_id) s
           ON t.channel_id = s.channel_id
           WHEN MATCHED THEN UPDATE SET
               last_processed_id = ?, last_processed_at = ?::TIMESTAMP_TZ, sync_status = 'IDLE',
               error_message = NULL, updated_at = CURRENT_TIMESTAMP()
           WHEN NOT MATCHED THEN INSERT (channel_id, last_processed_id, last_processed_at, sync_status)
               VALUES (?, ?, ?::TIMESTAMP_TZ, 'IDLE')''',
        params=[channel_id, last_id, last_at_utc.strftime('%Y-%m-%d %H:%M:%S +0000'),
                channel_id, last_id, last_at_utc.strftime('%Y-%m-%d %H:%M:%S +0000')],
    ).collect()


def _retry_count(session, message_id, channel_id):
    rows = session.sql(
        'SELECT COUNT(*) AS n FROM cashapp.capture_error_log '
        'WHERE source_reference_id = ? AND channel_id = ?',
        params=[message_id, channel_id],
    ).collect()
    return rows[0]["N"]


def _get_config(session, key, default):
    rows = session.sql(
        'SELECT config_value FROM cashapp.system_config '
        'WHERE config_key = ? AND company_code IS NULL',
        params=[key],
    ).collect()
    return rows[0]["CONFIG_VALUE"] if rows else default


def _capture_exists(session, source_ref, channel_id):
    rows = session.sql(
        'SELECT EXISTS(SELECT 1 FROM cashapp.channel_captures '
        'WHERE source_reference_id = ? AND channel_id = ?) AS e',
        params=[source_ref, channel_id],
    ).collect()
    return bool(rows[0]["E"])


# ── Gmail API fetch — HTTPS replacement for app/core/email_client.py's IMAP ──

def _b64url_decode(data):
    if not data:
        return b""
    padded = data + "=" * (-len(data) % 4)   # Gmail omits base64url padding
    return base64.urlsafe_b64decode(padded)


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


def _gmail_get(url, access_token, params=None):
    resp = requests.get(
        url, headers={'Authorization': 'Bearer {}'.format(access_token)},
        params=params, timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def _list_message_ids(access_token, after_dt, limit):
    # Gmail's after: operator EXCLUDES the given day itself (after:2026/07/29
    # only returns mail from 2026/07/30 on) — unlike IMAP's SINCE, which is
    # inclusive of the day given. Subtract a day here so the coarse filter
    # always over-fetches backward rather than silently dropping same-day
    # messages; _fetch_emails's `received_at > after_dt` check below does
    # the actual precise cutoff.
    since = after_dt or datetime(1970, 1, 2, tzinfo=timezone.utc)
    query_date = (since - timedelta(days=1)).strftime('%Y/%m/%d')
    query = 'in:inbox after:{}'.format(query_date)

    ids, page_token = [], None
    while len(ids) < limit:
        params = {'q': query, 'maxResults': min(100, limit - len(ids))}
        if page_token:
            params['pageToken'] = page_token
        body = _gmail_get('{}/messages'.format(_GMAIL_API_BASE), access_token, params)
        ids.extend(m['id'] for m in body.get('messages', []) or [])
        page_token = body.get('nextPageToken')
        if not page_token:
            break
    return ids


def _walk_parts(parts, text, attachments):
    for part in parts or []:
        mime = part.get('mimeType', '')
        filename = part.get('filename') or ''
        body = part.get('body', {}) or {}
        if filename:
            attachments.append({
                'filename': filename, 'content_type': mime,
                'attachment_id': body.get('attachmentId'), 'inline_data': body.get('data'),
            })
        elif mime == 'text/plain' and body.get('data'):
            text['text'] = _b64url_decode(body['data']).decode('utf-8', errors='replace')
        elif mime == 'text/html' and body.get('data'):
            text['html'] = _b64url_decode(body['data']).decode('utf-8', errors='replace')
        if part.get('parts'):
            _walk_parts(part['parts'], text, attachments)


def _get_message(access_token, msg_id):
    body = _gmail_get('{}/messages/{}'.format(_GMAIL_API_BASE, msg_id), access_token, {'format': 'full'})
    payload = body.get('payload', {}) or {}
    headers = {h['name']: h['value'] for h in payload.get('headers', []) or []}

    # Gmail's own id is always present and unique to this mailbox — used as
    # the source_reference key instead of the RFC822 Message-ID header,
    # which real mail occasionally omits (the IMAP-based code would silently
    # drop those messages; this is strictly more robust).
    message_id = msg_id

    internal_ms = int(body.get('internalDate', '0'))
    received_at = datetime.fromtimestamp(internal_ms / 1000.0, tz=timezone.utc)

    text, attachments_meta = {}, []
    top_body = payload.get('body', {}) or {}
    if payload.get('mimeType') == 'text/plain' and top_body.get('data'):
        text['text'] = _b64url_decode(top_body['data']).decode('utf-8', errors='replace')
    elif payload.get('mimeType') == 'text/html' and top_body.get('data'):
        text['html'] = _b64url_decode(top_body['data']).decode('utf-8', errors='replace')
    _walk_parts(payload.get('parts'), text, attachments_meta)

    attachments = []
    for att in attachments_meta:
        if att['inline_data']:
            content = _b64url_decode(att['inline_data'])
        elif att['attachment_id']:
            att_body = _gmail_get(
                '{}/messages/{}/attachments/{}'.format(_GMAIL_API_BASE, msg_id, att['attachment_id']),
                access_token,
            )
            content = _b64url_decode(att_body.get('data'))
        else:
            continue
        attachments.append({'filename': att['filename'], 'content_type': att['content_type'], 'content': content})

    return {
        'message_id': message_id,
        'from_address': headers.get('From', ''),
        'subject': headers.get('Subject', ''),
        'received_at': received_at,
        'body_html': text.get('html'),
        'body_text': text.get('text'),
        'attachments': attachments,
    }


def _fetch_emails(after_dt, limit):
    access_token = _get_access_token()
    ids = _list_message_ids(access_token, after_dt, limit)

    messages = []
    for msg_id in ids:
        try:
            msg = _get_message(access_token, msg_id)
        except Exception:
            continue   # one unparseable message must not sink the whole batch
        if after_dt is None or msg['received_at'] > after_dt:
            messages.append(msg)

    messages.sort(key=lambda m: m['received_at'])   # oldest-first so the cursor advances correctly
    return messages


def _plain_text(msg):
    if msg['body_text']:
        return msg['body_text']
    if msg['body_html']:
        return re.sub('<[^<]+?>', ' ', msg['body_html'])
    return None


# ── Attachment storage — Snowflake internal stage, no external cloud ───────

def _upload_attachment(session, content, filename, message_id):
    now = datetime.now(timezone.utc)
    safe_id = message_id.strip('<>').replace('@', '_').replace('/', '_')[:50]
    safe_name = filename.replace(' ', '_')
    rel_path = 'email-attachments/{}/{:02d}/{:02d}/{}/{}'.format(
        now.year, now.month, now.day, safe_id, safe_name)
    stage_path = '@cashapp.stg_email_attachments/{}'.format(rel_path)
    session.file.put_stream(
        io.BytesIO(content), stage_path,
        auto_compress=False, overwrite=True,
    )
    # Full stage reference, not a gs:// URI — retrieval later is via GET,
    # GET_PRESIGNED_URL, or session.file.get_stream() against this same path.
    return stage_path


# ── Snowflake Cortex LLM — email body extraction ─────────────────────────────

def _llm_complete(session, messages):
    # Use Snowflake Cortex COMPLETE — runs inside Snowflake, no external call.
    # Build a single prompt from system + user messages for the SQL function.
    system_msg = ''
    user_msg = ''
    for m in messages:
        if m['role'] == 'system':
            system_msg = m['content']
        elif m['role'] == 'user':
            user_msg = m['content']
    rows = session.sql(
        "SELECT SNOWFLAKE.CORTEX.COMPLETE(?, CONCAT(?, '\\n\\n', ?)) AS response",
        params=[_CORTEX_MODEL, system_msg, user_msg],
    ).collect()
    return rows[0]["RESPONSE"]


def _extract_body(session, msg):
    body = _plain_text(msg)
    if not body or len(body.strip()) < 20:
        return {}

    prompt = 'Subject: {}\nFrom: {}\n\n{}'.format(msg['subject'], msg['from_address'], body[:3000])
    messages = [
        {'role': 'system', 'content': (
            'Extract payment remittance information from this email. '
            'Return ONLY a valid JSON object with these keys '
            '(use null when not found):\n'
            'payer_name (string), payment_amount (number), '
            'currency (3-char ISO code, default USD), '
            'payment_date (YYYY-MM-DD), payment_reference (string), '
            'payment_purpose (string — brief narrative description of what this payment '
            "is for, e.g. 'Project Phoenix Q1 delivery' — used for matching), "
            'invoices (array of {invoice_number, gross_amount, deduction_amount, reason_code}), '
            'confidence (0.0-1.0 float — your certainty in the extraction accuracy, MUST be a number, never null).\n'
            'Return ONLY JSON — no prose, no markdown fences.'
        )},
        {'role': 'user', 'content': prompt},
    ]
    try:
        raw = _llm_complete(session, messages)
        return _safe_parse_json(raw)
    except Exception:
        return {}


def _safe_parse_json(raw):
    raw = raw.strip()
    m = re.search(r'```(?:json)?\s*([\s\S]+?)\s*```', raw)
    if m:
        raw = m.group(1)
    try:
        result = json.loads(raw)
        return result if isinstance(result, dict) else {}
    except Exception:
        return {}


# ── Azure DI — raw REST submit/poll, port of app/core/azure_di.py ──────────

def _analyze_document(content, use_layout):
    api_key = _snowflake.get_generic_secret_string('azure_di_key')
    model_id = _AZURE_DI_LAYOUT_MODEL if use_layout else _AZURE_DI_INVOICE_MODEL

    submit = requests.post(
        '{}/documentintelligence/documentModels/{}:analyze?api-version=2024-11-30'.format(
            _AZURE_DI_ENDPOINT, model_id),
        headers={'Ocp-Apim-Subscription-Key': api_key, 'Content-Type': 'application/octet-stream'},
        data=content, timeout=30,
    )
    submit.raise_for_status()
    poll_url = submit.headers['Operation-Location']

    for _ in range(20):   # ~40s ceiling — Azure DI calls are network/latency
                           # bound, not CPU bound, but the warehouse still
                           # bills while this loop waits; keep batch sizes
                           # modest so this doesn't dominate run time.
        time.sleep(2)
        poll = requests.get(poll_url, headers={'Ocp-Apim-Subscription-Key': api_key}, timeout=30)
        poll.raise_for_status()
        body = poll.json()
        status = body.get('status')
        if status == 'succeeded':
            return _normalize_di(body.get('analyzeResult', {}) or {}, use_layout)
        if status == 'failed':
            return {}, 0.0
    return {}, 0.0


def _normalize_di(result, use_layout):
    if use_layout:
        raw = {}
        for kv in result.get('keyValuePairs', []) or []:
            key = (kv.get('key') or {}).get('content')
            val = (kv.get('value') or {}).get('content')
            conf = kv.get('confidence', 0.0) or 0.0
            if key:
                raw[key] = {'value': val, 'confidence': conf}
        overall = sum(v['confidence'] for v in raw.values()) / len(raw) if raw else 0.0
        return {'model': _AZURE_DI_LAYOUT_MODEL, 'key_value_pairs': raw}, overall

    docs = result.get('documents') or []
    if not docs:
        return {'model': _AZURE_DI_INVOICE_MODEL}, 0.0
    fields = docs[0].get('fields') or {}

    def fv(key):
        f = fields.get(key)
        if not f:
            return None, 0.0
        conf = f.get('confidence', 0.0) or 0.0
        for k in ('valueString', 'valueNumber', 'valueInteger', 'valueCurrency', 'valueDate'):
            if k in f and f[k] is not None:
                v = f[k]
                if isinstance(v, dict) and 'amount' in v:
                    return float(v['amount']), conf
                return v, conf
        return f.get('content'), conf

    vendor_name, vc = fv('VendorName')
    customer_name, cc = fv('CustomerName')
    invoice_total, tc = fv('InvoiceTotal')
    invoice_date, dc = fv('InvoiceDate')
    invoice_id, ic = fv('InvoiceId')
    currency, _cconf = fv('CurrencyCode')

    # VendorName = invoice issuer = the payer. CustomerName = Bill To = us.
    payer_name = vendor_name or customer_name
    payer_conf = vc if vendor_name else cc

    line_items = []
    items = (fields.get('Items') or {}).get('valueArray') or []
    for item in items:
        obj = item.get('valueObject') or {}
        desc_f = obj.get('Description') or {}
        amt_f = obj.get('Amount') or {}
        desc = desc_f.get('valueString') or desc_f.get('content')
        amt = amt_f.get('valueNumber')
        if amt is None and isinstance(amt_f.get('valueCurrency'), dict):
            amt = amt_f['valueCurrency'].get('amount')
        if desc or amt is not None:
            line_items.append({
                'description': desc, 'amount': amt,
                'confidence': amt_f.get('confidence', 0.0) or 0.0,
            })

    normalized = {
        'model': _AZURE_DI_INVOICE_MODEL,
        'payer_name': payer_name, 'payment_amount': invoice_total,
        'payment_date': invoice_date, 'invoice_id': invoice_id,
        'currency': str(currency) if currency else 'USD',
        'line_items': line_items,
    }
    key_confs = [c for v, c in [(payer_name, payer_conf), (invoice_total, tc)] if v is not None]
    overall = sum(key_confs) / len(key_confs) if key_confs else 0.0
    return normalized, overall


def _to_decimal(value):
    if value is None:
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None


def _parse_date(value):
    if not value:
        return None
    return str(value)[:10]


# ── Extraction orchestration — port of extractor_email.py ──────────────────

def _extract_attachment(session, att, message_id):
    mime = att['content_type'].lower().split(';')[0].strip()
    doc_type = _MIME_TO_DOC_TYPE.get(mime)
    if doc_type is None:
        return None

    use_layout = mime in _LAYOUT_MIMES
    storage_path = _upload_attachment(session, att['content'], att['filename'], message_id)

    try:
        parsed, confidence = _analyze_document(att['content'], use_layout)
    except Exception:
        parsed, confidence = {}, 0.0

    source_doc = {
        'document_type': doc_type, 'filename': att['filename'], 'mime_type': mime,
        'storage_path': storage_path,
        'parsed_content': dict(parsed, free_text=None),   # mandatory key, null for PDF/IMAGE/EXCEL/CSV
        'extraction_provider': 'AZURE_DI',
        'extraction_status': 'COMPLETED' if parsed else 'FAILED',
        'confidence': confidence,
    }

    if not parsed:
        return None

    payment_amount = _to_decimal(parsed.get('payment_amount'))
    if payment_amount is None:
        return None   # no amount extracted — not a payment document

    # Azure DI's line_items are lines WITHIN a single invoice (product descriptions,
    # quantities, amounts). They are NOT separate invoices/remittance claims.
    # Store them in parsed_content for reference, but create ONE claim per invoice
    # using the invoice-level InvoiceId — that's what remittance_claims represents:
    # "which invoices does this payment cover?"
    claims = []
    invoice_id = parsed.get('invoice_id')
    if invoice_id:
        claims.append({
            'invoice_number': str(invoice_id)[:50], 'gross_amount': payment_amount,
            'deduction_amount': Decimal('0'), 'net_amount': payment_amount,
            'reason_code': None, 'confidence': confidence,
        })

    return {
        'payer_name': parsed.get('payer_name'), 'payment_amount': payment_amount,
        'currency': str(parsed.get('currency') or 'USD')[:5],
        'payment_date': _parse_date(parsed.get('payment_date')),
        'payment_reference': parsed.get('invoice_id'),
        'claims': claims, 'overall_confidence': confidence, 'source_docs': [source_doc],
    }


def _body_source_doc(ctx):
    content = dict(ctx)
    content['free_text'] = ctx.get('payment_purpose') or None   # mandatory key for EMAIL_BODY
    conf = ctx.get('confidence')
    # Compute confidence from field completeness if LLM didn't provide a numeric value.
    # Fields that matter: payer_name, payment_amount, payment_date, payment_reference, invoices
    if conf is None or (isinstance(conf, str) and not conf.strip()):
        filled = sum(1 for k in ('payer_name', 'payment_amount', 'payment_date', 'payment_reference')
                     if ctx.get(k) is not None)
        has_invoices = bool(ctx.get('invoices'))
        conf = (filled + (1 if has_invoices else 0)) / 5.0
    return {
        'document_type': 'EMAIL_BODY', 'filename': None, 'mime_type': None, 'storage_path': None,
        'parsed_content': content, 'extraction_provider': 'CORTEX_LLM',
        'extraction_status': 'COMPLETED' if ctx else 'FAILED',
        'confidence': float(conf),
    }


def _payment_from_body(ctx):
    payment_amount = _to_decimal(ctx.get('payment_amount'))
    if payment_amount is None:
        return None
    # Use LLM's confidence if numeric; otherwise compute from field completeness
    conf = ctx.get('confidence')
    if conf is None or (isinstance(conf, str) and not conf.strip()):
        filled = sum(1 for k in ('payer_name', 'payment_amount', 'payment_date', 'payment_reference')
                     if ctx.get(k) is not None)
        has_invoices = bool(ctx.get('invoices'))
        overall_conf = (filled + (1 if has_invoices else 0)) / 5.0
    else:
        overall_conf = float(conf)
    claims = []
    for inv in ctx.get('invoices', []) or []:
        inv_num = inv.get('invoice_number')
        gross = _to_decimal(inv.get('gross_amount'))
        if not inv_num or gross is None:
            continue
        ded = _to_decimal(inv.get('deduction_amount')) or Decimal('0')
        claims.append({
            'invoice_number': str(inv_num)[:50], 'gross_amount': gross, 'deduction_amount': ded,
            'net_amount': gross - ded, 'reason_code': inv.get('reason_code'),
            'confidence': overall_conf,
        })
    return {
        'payer_name': ctx.get('payer_name'), 'payment_amount': payment_amount,
        'currency': str(ctx.get('currency') or 'USD')[:5],
        'payment_date': _parse_date(ctx.get('payment_date')),
        'payment_reference': ctx.get('payment_reference'),
        'claims': claims, 'overall_confidence': overall_conf,
        'source_docs': [_body_source_doc(ctx)],
    }


def _extract_email_payments(session, msg):
    body_ctx = _extract_body(session, msg)
    results = []

    for att in msg['attachments']:
        result = _extract_attachment(session, att, msg['message_id'])
        if result is None:
            continue
        if result['payer_name'] is None:
            result['payer_name'] = body_ctx.get('payer_name')
        if result['payment_date'] is None and body_ctx.get('payment_date'):
            result['payment_date'] = _parse_date(body_ctx['payment_date'])
        if result['payment_reference'] is None:
            result['payment_reference'] = body_ctx.get('payment_reference')
        result['source_docs'].insert(0, _body_source_doc(body_ctx))
        results.append(result)

    if not results:
        body_result = _payment_from_body(body_ctx)
        if body_result:
            results.append(body_result)

    return results


# ── Write path — MERGE-based idempotency (Hybrid Tables + enforced UNIQUE) ──

def _write_capture(session, channel_id, source_ref, result):
    capture_id = str(uuid.uuid4())
    # Determine extraction method from what actually produced the data:
    # if any source_doc is AZURE_DI, that's the primary extractor; otherwise Cortex LLM (body-only)
    extraction_method = 'CORTEX_LLM'
    for doc in result.get('source_docs', []):
        if doc.get('extraction_provider') == 'AZURE_DI':
            extraction_method = 'AZURE_DI'
            break
    merged = session.sql(
        '''MERGE INTO cashapp.channel_captures t
           USING (SELECT ? AS channel_id, ? AS source_reference_id) s
           ON t.channel_id = s.channel_id AND t.source_reference_id = s.source_reference_id
           WHEN NOT MATCHED THEN INSERT
             (capture_id, channel_id, source_reference_id, payer_name, payment_reference,
              payment_amount, currency, payment_date, extraction_method,
              extraction_confidence, capture_status)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING')''',
        params=[channel_id, source_ref,
                capture_id, channel_id, source_ref, result['payer_name'], result['payment_reference'],
                result['payment_amount'], result['currency'], result['payment_date'],
                extraction_method, result['overall_confidence']],
    ).collect()

    # NOTE: verify the exact result-column name/casing for MERGE row counts in
    # your Snowpark version before relying on this — expected to be something
    # like "number of rows inserted"; confirm with a scratch call first.
    if merged[0][0] == 0:
        return   # already captured by a prior/overlapping run — no-op

    body_doc_id = attachment_doc_id = None
    for doc in result['source_docs']:
        document_id = str(uuid.uuid4())
        session.sql(
            '''INSERT INTO cashapp.capture_source_documents
               (document_id, capture_id, channel_id, document_type, original_filename, mime_type,
                storage_path, extraction_provider, extraction_status, extraction_confidence,
                parsed_content)
               SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, PARSE_JSON(?)''',
            params=[document_id, capture_id, channel_id, doc['document_type'], doc['filename'],
                    doc['mime_type'], doc['storage_path'], doc['extraction_provider'],
                    doc['extraction_status'], doc['confidence'],
                    json.dumps(doc['parsed_content'], default=str)],
        ).collect()
        if doc['document_type'] == 'EMAIL_BODY':
            body_doc_id = document_id
        else:
            attachment_doc_id = document_id

    # A payment's claims derive from the attachment (Azure DI) when present,
    # else from the email body — same rule as _write_email_capture in Python.
    source_document_id = attachment_doc_id or body_doc_id
    for claim in result['claims']:
        session.sql(
            '''INSERT INTO cashapp.capture_remittance_claims
               (claim_id, capture_id, source_document_id, invoice_number, gross_amount,
                deduction_amount, net_amount, currency, reason_code, extraction_confidence)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
            params=[str(uuid.uuid4()), capture_id, source_document_id, claim['invoice_number'],
                    claim['gross_amount'], claim['deduction_amount'], claim['net_amount'],
                    result['currency'], claim['reason_code'], claim['confidence']],
        ).collect()


def run(session):
    channel_id = _get_channel_id(session)
    after_dt = _get_cursor(session, channel_id)
    batch_size = int(_get_config(session, 'email_capture_batch_size', '100'))
    max_retries = int(_get_config(session, 'email_capture_max_retries', '5'))
    threshold = float(_get_config(session, 'email_confidence_threshold', '0.75'))

    emails = _fetch_emails(after_dt, batch_size)
    if not emails:
        return {"processed": 0, "captured": 0, "skipped": 0, "errors": 0}

    run_id = str(uuid.uuid4())
    session.sql(
        '''INSERT INTO cashapp.capture_runs (run_id, channel_id, batch_size, cursor_start)
           VALUES (?, ?, ?, ?)''',
        params=[run_id, channel_id, batch_size, str(after_dt) if after_dt else None],
    ).collect()

    captured = skipped = errors = 0
    last_id, last_at = None, after_dt

    for msg in emails:
        if _retry_count(session, msg['message_id'], channel_id) >= max_retries:
            skipped += 1
            if last_at is None or msg['received_at'] > last_at:
                last_at, last_id = msg['received_at'], msg['message_id']
            continue

        session.sql("BEGIN").collect()
        try:
            payment_results = _extract_email_payments(session, msg)

            for idx, result in enumerate(payment_results):
                if result['overall_confidence'] < threshold:
                    skipped += 1
                    continue
                source_ref = (
                    '{}#{}'.format(msg['message_id'], idx)
                    if len(payment_results) > 1 else msg['message_id']
                )
                if _capture_exists(session, source_ref, channel_id):
                    skipped += 1
                    continue
                _write_capture(session, channel_id, source_ref, result)
                captured += 1

            session.sql("COMMIT").collect()
            if last_at is None or msg['received_at'] > last_at:
                last_at, last_id = msg['received_at'], msg['message_id']

        except Exception as exc:
            session.sql("ROLLBACK").collect()
            errors += 1
            session.sql(
                '''INSERT INTO cashapp.capture_error_log
                   (error_id, run_id, channel_id, source_reference_id, attempt_number,
                    error_type, error_message, error_detail)
                   SELECT ?, ?, ?, ?, ?, ?, ?, PARSE_JSON(?)''',
                params=[str(uuid.uuid4()), run_id, channel_id, msg['message_id'],
                        _retry_count(session, msg['message_id'], channel_id) + 1,
                        _classify_error(exc), str(exc)[:1000],
                        json.dumps({"traceback": traceback.format_exc()[-3000:]})],
            ).collect()
            break   # cursor stays before this message — retried next run

    if last_at and last_at != after_dt:
        _upsert_cursor(session, channel_id, last_id, last_at)

    session.sql(
        '''UPDATE cashapp.capture_runs SET
               status = ?, finished_at = CURRENT_TIMESTAMP(),
               items_attempted = ?, items_captured = ?, items_skipped = ?, items_errored = ?,
               cursor_end = ?
           WHERE run_id = ?''',
        params=["COMPLETED" if errors == 0 else "PARTIAL",
                captured + skipped + errors, captured, skipped, errors,
                str(last_at) if last_at and last_at != after_dt else None, run_id],
    ).collect()

    return {"processed": len(emails), "captured": captured, "skipped": skipped, "errors": errors}
$$;

