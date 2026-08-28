-- Fix Snowpark None parameter binding for numeric columns in SP_MATCHING
-- Co-authored with CoCo
-- ============================================================
-- Matching Engine — Snowflake Task + Procedure (Service 3)
-- Migrated from: cash-app-api/app/matching/service.py, scorer_l1.py,
--                scorer_l2.py, scorer_l3.py, scorer_l4.py
-- Source data : cashapp.cases (workflow_stage='MATCHING'), cashapp.payments,
--               cashapp.channel_captures, cashapp.capture_remittance_claims,
--               cashapp.capture_source_documents (parsed_content:free_text),
--               cashapp.customer_match_patterns, cashapp.system_config,
--               master."BSID" (open items), master."KNB1" (TOGRU), master."T043"
--               (tolerance), master."KNA1" (customer name)
-- Target data : cashapp.case_match_proposals, cashapp.case_invoice_matches,
--               cashapp.case_events, cashapp.cases (routing fields)
--
-- Trigger model: replaces the old asyncio.create_task(run_matching(case_id))
-- fire-and-forget call. Per Procedure_CasePromotion.sql's own note, Case
-- Promotion leaves workflow_stage='MATCHING' precisely so this task can pick
-- it up — same scheduled-polling-batch idiom as capture/promotion, not a
-- Snowflake STREAM object. See Task_Matching.sql.
--
-- LANGUAGE PYTHON, not JavaScript (earlier draft of this file was JS,
-- matching Procedure_CasePromotion.sql's pure-internal-SQL pattern). Matching
-- still has zero external REST dependency — only Cortex SQL functions and
-- internal tables — so EXTERNAL_ACCESS_INTEGRATIONS/SECRETS are still not
-- needed here, same as before. Python was chosen this time specifically to
-- get near-literal parity with app/matching/service.py + scorer_l1-4.py:
--   - rapidfuzz.fuzz.token_sort_ratio / partial_ratio used directly (see
--     PACKAGES below) instead of the hand-rolled LCS-based JS approximation
--     — this removes deviation risk (1) from the JS version entirely,
--     PROVIDED rapidfuzz resolves from your account's Anaconda channel.
--     Verify with a throwaway `CREATE OR REPLACE PROCEDURE` using this
--     PACKAGES list before relying on it — if it fails to resolve, this
--     whole L2 section needs to fall back to a hand-rolled approximation
--     (the JS version's tokenSortRatio/partialRatio, ported to Python, would
--     be the fallback).
--   - decimal.Decimal used throughout for money math (stdlib, always
--     available) — same type the Postgres app used via SQLAlchemy Numeric
--     columns, not float. Snowpark returns NUMBER/NUMERIC columns as Decimal
--     natively, so this is a straight port, not a workaround.
--   - Function names/structure mirror the Python module layout directly
--     (score_l1, score_l2, score_l3, score_l4_batch, _composite,
--     _variance_strategy, _autonomy_tier, _workflow_routing,
--     _build_route_reason, _generate_ai_summary, _route_pending) so this
--     file can be diffed against app/matching/*.py function-by-function.
--
-- Behaviour preserved from the Python implementation — identical to the
-- JS version's notes:
--   - Guard: sap_customer_id (KUNNR) resolved + a KNB1 row exists for that
--     KUNNR -> otherwise routes PENDING_APPROVAL / UNRESOLVED_CUSTOMER.
--   - No open BSID items (SHKZG='S', WAERS=payment currency) -> PENDING_APPROVAL
--     / NO_OPEN_INVOICES.
--   - Tolerance: KNB1.TOGRU -> T043 row for (BUKRS, TOGRU, WAERS); T043's
--     bukrs/togru/waers/betrg/prztl columns are lowercase in this replica
--     (confirmed against the live schema, not just the Postgres docstring).
--     prztl is a percent (5.00 = 5%), converted to a fraction to match
--     system_config's convention (same fix as commit 1c9b3a1 on the Python
--     side). Missing TOGRU or missing T043 row both fall back to
--     system_config defaults and log a MATCH_DECISION event.
--   - Four scoring layers (L1-L4), composite = weighted average over
--     whichever layers fired (L1 weight 1.00, L2 0.85, L3 0.80, L4 0.65).
--     L3/L4 are excluded from the denominator (not scored 0) when they
--     don't apply, matching score_l3/score_l4_batch returning None in
--     Python.
--   - Routing: best < manual_match_confidence_min -> UNRESOLVABLE;
--     ambiguous (gap between best two < ambiguity_confidence_margin) ->
--     AMBIGUOUS_MATCH; best < auto_match_confidence_min -> LOW_CONFIDENCE;
--     else AUTO.
--   - Variance/strategy classification (FULL_CLEAR / WRITE_OFF /
--     FX_WRITE_OFF / RESIDUAL / PARTIAL) and autonomy tier
--     (AUTO/L1/L2/L3 by payment_amount vs system_config maxes) ported 1:1.
--   - Writes one case_match_proposals row + one case_invoice_matches row
--     per scored candidate + case_events (INVOICES_FETCHED, MATCH_LAYER_1..4,
--     MATCH_AMBIGUOUS when applicable, MATCH_DECISION) + updates the case,
--     all in one transaction per case (BEGIN/COMMIT/ROLLBACK, same shape as
--     Procedure_CasePromotion.sql's promoteOne).
--
-- REMAINING KNOWN DEVIATION — read before trusting auto-routing:
--   L4 uses SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m', ...)
--   in place of LiteLLM/Groq's embedding model. Different model = different
--   vector space = L4 scores will NOT numerically match today's production
--   scores, even for the same email text. auto_match_confidence_min (0.85),
--   manual_match_confidence_min (0.65), and ambiguity_confidence_margin
--   (0.05) in system_config were calibrated against the Python engine's
--   score distribution (rapidfuzz + LiteLLM embeddings). With rapidfuzz now
--   matched exactly, L4's embedding-model swap is the ONLY remaining source
--   of score drift — still worth a backtest against historical cases before
--   enabling TASK_MATCHING on live traffic, but a much narrower risk surface
--   than the JS version carried.
-- ============================================================
 
USE DATABASE O2C_DB;
USE SCHEMA cashapp;
 
CREATE OR REPLACE PROCEDURE cashapp.SP_MATCHING()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'rapidfuzz')
HANDLER = 'run'
AS
$$
import re
import uuid
import json
import traceback
from datetime import date
from decimal import Decimal, InvalidOperation
 
from rapidfuzz import fuzz
 
BATCH_SIZE = 50
CORTEX_MODEL = "llama3.1-70b"          # same model as Procedure_Email.sql
EMBED_MODEL = "snowflake-arctic-embed-m"  # EMBED_TEXT_768 — see header deviation note
 
L1_W, L2_W, L3_W, L4_W = Decimal("1.00"), Decimal("0.85"), Decimal("0.80"), Decimal("0.65")
 
 
# ── SQL helpers ──────────────────────────────────────────────────────────
def _safe_sql(session, sql_text, params=None):
    """Execute SQL, replacing None params with NULL literals to avoid Snowpark binding issues."""
    if not params:
        return session.sql(sql_text, params=[]).collect()
    parts = sql_text.split('?')
    built = []
    actual_params = []
    for i, p in enumerate(params):
        built.append(parts[i])
        if p is None:
            built.append('NULL')
        else:
            built.append('?')
            actual_params.append(p)
    built.append(parts[len(params)])
    return session.sql(''.join(built), params=actual_params).collect()


def _rows(session, sql_text, params=None):
    return _safe_sql(session, sql_text, params)
 
 
def _scalar(session, sql_text, params=None):
    rows = _rows(session, sql_text, params)
    return rows[0][0] if rows else None
 
 
# ── String helpers — ported 1:1 from scorer_l1._normalize_ref ────────────
def _normalize_ref(value) -> str:
    if value is None:
        return ""
    s = str(value).strip().lower()
    m = re.search(r"\[(\d+)\]", s)
    if m:
        s = m.group(1)
    try:
        s = str(int(float(s)))
    except (ValueError, TypeError):
        pass
    return s
 
 
def _to_decimal(value):
    if value is None:
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None
 
 
# ── L1 — deterministic exact reference matching (scorer_l1.score_l1) ─────
def score_l1(candidates, claim_invoice_numbers, payment_reference, payment_amount, tolerance_abs, tolerance_pct):
    if not candidates:
        return []
 
    norm_claims = {_normalize_ref(r) for r in claim_invoice_numbers if r}
    norm_pref = _normalize_ref(payment_reference) if payment_reference else ""
 
    if not norm_claims and not norm_pref:
        return [0.0] * len(candidates)
 
    matched_mask = []
    for cand in candidates:
        cand_belnr = _normalize_ref(cand["belnr"])
        cand_xblnr = _normalize_ref(cand["xblnr"])
        cand_zuonr = _normalize_ref(cand["zuonr"])
        hit = (
            (bool(norm_claims) and (cand_belnr in norm_claims or cand_xblnr in norm_claims))
            or (bool(norm_pref) and (norm_pref == cand_zuonr or norm_pref == cand_xblnr))
        )
        matched_mask.append(hit)
 
    matched = [c for c, m in zip(candidates, matched_mask) if m]
    if not matched:
        return [0.5] * len(candidates)
 
    matched_belnrs = {_normalize_ref(c["belnr"]) for c in matched}
    matched_xblnrs = {_normalize_ref(c["xblnr"]) for c in matched if c["xblnr"]}
    all_found = all(r in matched_belnrs or r in matched_xblnrs for r in norm_claims)
 
    matched_sum = sum((c["amount"] or Decimal("0")) for c in matched)
    threshold = max(tolerance_abs, payment_amount * tolerance_pct)
    balanced = abs(matched_sum - payment_amount) <= threshold
 
    tier = 0.99 if (all_found and balanced) else 0.5
    return [tier if m else 0.0 for m in matched_mask]
 
 
# ── L2 — fuzzy matching (scorer_l2.score_l2, real rapidfuzz) ─────────────
def _score_l2a(candidate, claim_invoice_numbers, payment_reference):
    cand_belnr = str(candidate["belnr"] or "")
    cand_xblnr = str(candidate["xblnr"] or "")
    cand_zuonr = str(candidate["zuonr"] or "")
    cand_targets = [t for t in (cand_belnr, cand_xblnr) if t]
 
    best = 0.0
    for ref in (r for r in claim_invoice_numbers if r):
        for target in cand_targets:
            score = max(fuzz.token_sort_ratio(ref, target), fuzz.partial_ratio(ref, target)) / 100.0
            if score > best:
                best = score
 
    if payment_reference:
        pr_targets = [t for t in (cand_zuonr, cand_xblnr) if t]
        for target in pr_targets:
            score = max(fuzz.token_sort_ratio(payment_reference, target), fuzz.partial_ratio(payment_reference, target)) / 100.0
            if score > best:
                best = score
 
    return round(best, 4)
 
 
def _score_l2b(candidate, payment_amount, tolerance_pct):
    if not candidate["amount"] or payment_amount == Decimal("0"):
        return 0.0
    gap_pct = float(abs(candidate["amount"] - payment_amount) / payment_amount)
    cap = 2.0 * float(tolerance_pct)
    if cap <= 0:
        return 0.0
    return round(max(0.0, 1.0 - gap_pct / cap), 4)
 
 
def _score_l2c(candidate, payment_reference, payer_name):
    sgtxt = str(candidate["sgtxt"] or "")
    if not sgtxt:
        return 0.0
    best = 0.0
    for signal in (s for s in (payment_reference, payer_name) if s):
        score = fuzz.partial_ratio(signal, sgtxt) / 100.0
        if score > best:
            best = score
    return round(best, 4)
 
 
def score_l2(candidate, claim_invoice_numbers, payment_reference, payer_name, payment_amount, tolerance_pct):
    l2a = _score_l2a(candidate, claim_invoice_numbers, payment_reference)
    l2b = _score_l2b(candidate, payment_amount, tolerance_pct)
    l2c = _score_l2c(candidate, payment_reference, payer_name)
    return round(l2a * 0.50 + l2b * 0.30 + l2c * 0.20, 4)
 
 
# ── L3 — schema-aware customer pattern matching (scorer_l3.score_l3) ─────
def _within_tolerance(candidate, payment_amount, tolerance_abs, tolerance_pct):
    if not candidate["amount"]:
        return False
    gap = abs(candidate["amount"] - payment_amount)
    threshold = max(tolerance_abs, payment_amount * tolerance_pct)
    return gap <= threshold
 
 
def _score_po(candidate, claim_invoice_numbers, po_numbers, payment_reference, payment_amount, tolerance_abs, tolerance_pct):
    cand_zuonr = _normalize_ref(candidate["zuonr"])
    all_refs = [_normalize_ref(r) for r in (claim_invoice_numbers + po_numbers) if r]
    if payment_reference:
        all_refs.append(_normalize_ref(payment_reference))
    all_refs = [r for r in all_refs if r]
 
    if not all_refs or cand_zuonr not in all_refs:
        return 0.0
    return 0.99 if _within_tolerance(candidate, payment_amount, tolerance_abs, tolerance_pct) else 0.5
 
 
def _transform_refs(regex_pattern, claim_invoice_numbers, po_numbers, payment_reference):
    compiled = re.compile(regex_pattern)
    source = claim_invoice_numbers + po_numbers + ([payment_reference] if payment_reference else [])
    results = []
    for ref in filter(None, source):
        m = compiled.search(ref)
        if m:
            results.append(m.group(0))
    return results
 
 
def _score_exact(candidate, refs, payment_amount, tolerance_abs, tolerance_pct):
    if not refs:
        return 0.0
    cand_belnr = _normalize_ref(candidate["belnr"])
    cand_xblnr = _normalize_ref(candidate["xblnr"])
    norm_refs = {_normalize_ref(r) for r in refs}
    if cand_belnr not in norm_refs and cand_xblnr not in norm_refs:
        return 0.0
    return 0.99 if _within_tolerance(candidate, payment_amount, tolerance_abs, tolerance_pct) else 0.5
 
 
def score_l3(candidate, patterns, claim_invoice_numbers, po_numbers, payment_reference,
             payment_amount, tolerance_abs, tolerance_pct, error_collector):
    if not patterns:
        return None
 
    best = 0.0
    has_scoreable_pattern = False
 
    for pattern in patterns:
        ptype = (pattern["pattern_type"] or "").upper()
        if ptype == "PARENT_PAYER":
            continue
        has_scoreable_pattern = True
 
        if ptype == "MEMO_ONLY":
            continue
 
        if ptype == "PO_NOT_INVOICE":
            score = _score_po(candidate, claim_invoice_numbers, po_numbers, payment_reference,
                               payment_amount, tolerance_abs, tolerance_pct)
            if score > best:
                best = score
 
        elif ptype == "REF_TRANSFORM":
            if not pattern["pattern_value"]:
                continue
            try:
                transformed = _transform_refs(pattern["pattern_value"], claim_invoice_numbers, po_numbers, payment_reference)
            except re.error as exc:
                error_collector.append(f"REF_TRANSFORM pattern_id={pattern['pattern_id']} invalid regex: {exc}")
                continue
            score = _score_exact(candidate, transformed, payment_amount, tolerance_abs, tolerance_pct)
            if score > best:
                best = score
 
    if not has_scoreable_pattern:
        return None
    return round(best, 4)
 
 
# ── L4 — contextual embedding cosine similarity (scorer_l4.score_l4_batch) ─
def _embed_text(session, text):
    rows = _rows(session, "SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(?, ?) AS emb", [EMBED_MODEL, text or ""])
    if not rows:
        return None
    raw = rows[0][0]
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except (ValueError, TypeError):
            return None
    return list(raw) if raw is not None else None  # Snowpark generally returns VECTOR as a native list already
 
 
def _cosine(a, b):
    if not a or not b:
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = sum(x * x for x in a) ** 0.5
    norm_b = sum(x * x for x in b) ** 0.5
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return round(dot / (norm_a * norm_b), 4)
 
 
def _candidate_text(candidate, kna1_name):
    parts = filter(None, [str(candidate["xblnr"] or ""), str(candidate["sgtxt"] or ""), kna1_name or ""])
    return " ".join(parts)
 
 
def score_l4_batch(session, candidates, payer_name, free_text, kna1_name):
    payment_text = " ".join(filter(None, [payer_name, free_text]))
    payment_vec = _embed_text(session, payment_text)
    if not payment_vec:
        raise RuntimeError("payment text embedding failed")
 
    scores = []
    for cand in candidates:
        vec = _embed_text(session, _candidate_text(cand, kna1_name))
        if not vec:
            raise RuntimeError("candidate text embedding failed")
        scores.append(_cosine(payment_vec, vec))
    return scores
 
 
# ── Cortex LLM — AI summary (service.py._generate_ai_summary) ────────────
def _llm_complete(session, system_msg, user_msg):
    rows = _rows(session, "SELECT SNOWFLAKE.CORTEX.COMPLETE(?, CONCAT(?, '\\n\\n', ?)) AS response",
                 [CORTEX_MODEL, system_msg, user_msg])
    return rows[0][0] if rows else ""
 
 
def _safe_parse_json(raw):
    if not raw:
        return {}
    raw = raw.strip()
    m = re.search(r"```(?:json)?\s*([\s\S]+?)\s*```", raw)
    if m:
        raw = m.group(1)
    try:
        result = json.loads(raw)
        return result if isinstance(result, dict) else {}
    except json.JSONDecodeError:
        return {}
 
 
_AI_SUMMARY_SYSTEM = (
    "You are a cash application assistant helping AR analysts. "
    "Given payment context, return ONLY valid JSON with two keys: "
    "\"title\" (max 10 words, punchy — customer name + key situation + amount if helpful) and "
    "\"summary\" (2-3 sentences — what happened, any notable detail from the remittance memo, "
    "what the analyst should do next). "
    "Be specific and actionable. Reference the memo text directly if present. "
    "No filler phrases. Direct, professional AR analyst tone."
)
 
 
def _generate_ai_summary(session, payment_amount, currency, route_reason, payer_name=None, customer_name=None,
                          approval_status=None, routing=None, strategy=None, invoice_refs=None, variance=None,
                          variance_type=None, reason_codes=None, free_text=None, confidence=None, tier=None):
    display_name = customer_name or payer_name or "Unknown payer"
 
    lines = [f"Customer: {display_name}", f"Payment: ${payment_amount:,.2f} {currency}"]
    if approval_status:
        lines.append(f"Routing issue: {approval_status.replace('_', ' ').title()}")
    if strategy:
        lines.append(f"Match strategy: {strategy.replace('_', ' ').title()}")
    if routing and routing != "AUTO":
        lines.append(f"Match result: {routing.replace('_', ' ').title()}")
    if invoice_refs:
        lines.append(f"Invoice(s): {', '.join(invoice_refs[:5])}")
    if variance and variance != Decimal("0"):
        lines.append(f"Variance: ${abs(variance):,.2f} ({variance_type or 'unknown'})")
    if reason_codes:
        lines.append(f"Reason code(s): {', '.join(reason_codes)}")
    if free_text:
        lines.append(f"Remittance memo: \"{free_text[:200]}\"")
    if confidence is not None:
        lines.append(f"Confidence: {confidence:.0%}")
    if tier:
        lines.append(f"Approval tier: {tier}")
 
    try:
        raw = _llm_complete(session, _AI_SUMMARY_SYSTEM, "\n".join(lines))
        clean = re.sub(r"```(?:json)?\s*|\s*```", "", raw.strip())
        parsed = json.loads(clean)
        title = str(parsed.get("title") or "").strip()
        summary = str(parsed.get("summary") or "").strip()
        if title and summary:
            return title, summary
    except Exception:
        pass
 
    return f"{display_name} · ${payment_amount:,.2f} {currency}", route_reason
 
 
# ── Config (system_config, same convention as matching_repository.py) ────
def _get_config_value(session, key):
    return _scalar(session, "SELECT config_value FROM cashapp.system_config WHERE config_key = ? AND company_code IS NULL LIMIT 1", [key])
 
 
def _get_config_float(session, key, fallback):
    v = _get_config_value(session, key)
    if v is None:
        return fallback
    try:
        return float(v)
    except (ValueError, TypeError):
        return fallback
 
 
# ── Composite / routing / variance / tier helpers (service.py) ───────────
def _composite(l1, l2, l3, l4):
    numerator = l1 * L1_W + l2 * L2_W
    denominator = L1_W + L2_W
    if l3 is not None:
        numerator += l3 * L3_W
        denominator += L3_W
    if l4 is not None:
        numerator += l4 * L4_W
        denominator += L4_W
    return round(numerator / denominator, 4) if denominator > 0 else Decimal("0")
 
 
def _select_set(scored, routing):
    if not scored:
        return []
    if routing == "UNRESOLVABLE":
        return []
    if routing == "AMBIGUOUS_MATCH":
        return scored[:1]
    l1_exact = [s for s in scored if s["l1"] >= 0.99]
    if l1_exact:
        return l1_exact
    return scored[:1]
 
 
def _autonomy_tier(amount, auto_max, l1_max, l2_max):
    if amount <= auto_max:
        return "AUTO"
    if amount <= l1_max:
        return "L1"
    if amount <= l2_max:
        return "L2"
    return "L3"
 
 
def _workflow_routing(routing, tier):
    if routing == "UNRESOLVABLE":
        return "PENDING_APPROVAL", "UNRESOLVABLE"
    if routing == "AMBIGUOUS_MATCH":
        return "PENDING_APPROVAL", "AMBIGUOUS_MATCH"
    if routing == "LOW_CONFIDENCE":
        return "PENDING_APPROVAL", "LOW_CONFIDENCE"
    if tier == "AUTO":
        return "VALIDATION", None
    return "REVIEW", None
 
 
def _is_residual(variance, claims):
    if not any(c["reason_code"] for c in claims):
        return False
    total_deductions = sum((c["deduction_amount"] or Decimal("0")) for c in claims)
    return abs(abs(total_deductions) - abs(variance)) <= Decimal("1.00")
 
 
def _variance_strategy(variance, tol_abs, tol_pct, payment_amount, payment_currency, home_currency, claims):
    abs_var = abs(variance)
    if abs_var == Decimal("0"):
        return "FULL_CLEAR", "NONE"
 
    threshold = max(tol_abs, payment_amount * tol_pct)
    if abs_var <= threshold:
        if payment_currency.strip().upper() != home_currency.strip().upper():
            return "FX_WRITE_OFF", "FX_DIFF"
        vtype = "SHORT_PAY" if variance < Decimal("0") else "OVER_PAY"
        return "WRITE_OFF", vtype
 
    if _is_residual(variance, claims):
        return "RESIDUAL", "SHORT_PAY"
 
    vtype = "SHORT_PAY" if variance < Decimal("0") else "OVER_PAY"
    return "PARTIAL", vtype
 
 
def _claim_detail(cand, claims):
    cand_belnr = _normalize_ref(cand["belnr"])
    cand_xblnr = _normalize_ref(cand["xblnr"])
    for claim in claims:
        ref = _normalize_ref(claim["invoice_number"])
        if ref and (ref == cand_belnr or ref == cand_xblnr):
            ded_amt = claim["deduction_amount"] or Decimal("0")
            return ded_amt, claim["reason_code"], cand["amount"] - ded_amt
    return Decimal("0"), None, cand["amount"]
 
 
def _primary_layer(l1, l2, l3, l4):
    scores = [(l1, 1), (l2, 2)]
    if l3 is not None:
        scores.append((l3, 3))
    if l4 is not None:
        scores.append((l4, 4))
    return max(scores, key=lambda x: x[0])[1]
 
 
def _dec(value):
    if value is None:
        return None
    return Decimal(str(round(value, 3)))
 
 
def _build_route_reason(routing, scored, strategy, variance, variance_type, payment_amount, currency,
                         tier, best_score, second_score, ambiguity_gap):
    top = scored[0] if scored else None
    belnr = str(top["cand"]["belnr"]) if top else "unknown"
    inv_amt = top["cand"]["amount"] if top else None
    inv_str = f"${inv_amt:,.2f}" if inv_amt is not None else currency
 
    if routing == "UNRESOLVABLE":
        return f"No confident match — best candidate invoice {belnr} ({best_score:.0%} confidence), manual selection required"
 
    if routing == "AMBIGUOUS_MATCH":
        second_belnr = str(scored[1]["cand"]["belnr"]) if len(scored) > 1 else "?"
        gap = best_score - second_score
        return (f"Ambiguous match — invoice {belnr} ({best_score:.0%}) vs invoice {second_belnr} "
                f"({second_score:.0%}), gap {gap:.1%} below {ambiguity_gap:.0%} margin")
 
    if strategy == "FULL_CLEAR":
        if routing == "LOW_CONFIDENCE":
            return f"Possible match — invoice {belnr} ({inv_str}), {best_score:.0%} confidence"
        return f"Exact match — invoice {belnr} ({inv_str})"
 
    if strategy in ("WRITE_OFF", "FX_WRITE_OFF") and payment_amount:
        var_pct = float(abs(variance) / payment_amount * 100)
        var_str = f"${abs(variance):,.2f} ({var_pct:.1f}%)"
        if variance_type == "FX_DIFF":
            base = f"FX variance — invoice {belnr} ({inv_str}), {var_str}"
        else:
            direction = "Short pay" if variance < Decimal("0") else "Over pay"
            base = f"{direction} vs invoice {belnr} ({inv_str}) — variance {var_pct:.1f}%"
        if routing == "LOW_CONFIDENCE":
            return base + f", below auto-match threshold ({best_score:.0%})"
        return base + " within tolerance"
 
    if strategy == "RESIDUAL":
        if routing == "LOW_CONFIDENCE":
            return f"Residual clearing — invoice {belnr} ({inv_str}), {best_score:.0%} confidence"
        return f"Residual clearing — invoice {belnr} ({inv_str}), deduction applied"
 
    if strategy == "PARTIAL" and payment_amount:
        var_pct = float(abs(variance) / payment_amount * 100)
        if routing == "LOW_CONFIDENCE":
            return f"Partial payment — invoice {belnr} ({inv_str}), {var_pct:.1f}% outstanding, below auto-match threshold"
        return f"Partial payment — invoice {belnr} ({inv_str}), {var_pct:.1f}% outstanding"
 
    if tier == "L3":
        return f"High-value payment — CFO sign-off required (${payment_amount:,.2f} {currency})"
    if tier in ("L1", "L2"):
        return f"Matched — {tier} manager approval required (${payment_amount:,.2f} {currency})"
 
    return f"Matched — invoice {belnr} ({best_score:.0%} confidence)"
 
 
# ── event / case-update helpers ─────────────────────────────────────────
def _insert_event(session, case_id, event_type, message, data_obj=None):
    _safe_sql(session,
        "INSERT INTO cashapp.case_events (event_id, case_id, event_type, event_message, event_data) "
        "SELECT ?, ?, ?, ?, PARSE_JSON(?)",
        params=[str(uuid.uuid4()), case_id, event_type, message, json.dumps(data_obj)])
 
 
def _route_pending(session, case_id, approval_status, message, route_reason, ai_title, ai_summary):
    _insert_event(session, case_id, "MATCH_DECISION", message, {"approval_status": approval_status})
    _safe_sql(session,
        "UPDATE cashapp.cases SET workflow_stage = 'PENDING_APPROVAL', approval_status = ?, "
        "route_reason = ?, ai_summary_title = ?, ai_summary = ?, updated_at = CURRENT_TIMESTAMP() "
        "WHERE case_id = ?",
        params=[approval_status, route_reason, ai_title, ai_summary, case_id])
 
 
# ── Per-case matching (service.py._match) ─────────────────────────────────
def _match_one(session, case_row, config):
    case_id = case_row["case_id"]
 
    session.sql("BEGIN").collect()
    try:
        kunnr = (case_row["sap_customer_id"] or "").strip()
        pay_ccy = (case_row["currency_code"] or "USD").strip()
 
        # ── Guard: KUNNR ──
        if not kunnr:
            reason = "Customer not identified — payer name and bank account did not match any SAP customer record"
            ai_title, ai_summary = _generate_ai_summary(
                session, case_row["payment_amount"], pay_ccy, reason,
                payer_name=case_row["payer_name"], approval_status="UNRESOLVED_CUSTOMER",
            )
            _route_pending(session, case_id, "UNRESOLVED_CUSTOMER",
                            "Matching skipped — KUNNR not resolved at case creation", reason, ai_title, ai_summary)
            session.sql("COMMIT").collect()
            return "unresolved_customer"
 
        bukrs = _scalar(session, 'SELECT "BUKRS" FROM master."KNB1" WHERE "KUNNR" = ? LIMIT 1', [kunnr])
        if not bukrs:
            reason = f"Customer {kunnr} found but not configured for this company code"
            ai_title, ai_summary = _generate_ai_summary(
                session, case_row["payment_amount"], pay_ccy, reason,
                payer_name=case_row["payer_name"], approval_status="UNRESOLVED_CUSTOMER",
            )
            _route_pending(session, case_id, "UNRESOLVED_CUSTOMER",
                            f"Matching skipped — no KNB1 record for KUNNR {kunnr}", reason, ai_title, ai_summary)
            session.sql("COMMIT").collect()
            return "unresolved_customer"
 
        # ── Open items ──
        cand_rows = _rows(
            session,
            'SELECT "BUKRS","KUNNR","GJAHR","BELNR","BUZEI","WRBTR","WAERS","ZUONR","SGTXT","XBLNR" '
            'FROM master."BSID" WHERE "BUKRS" = ? AND "KUNNR" = ? AND "SHKZG" = \'S\' AND "WAERS" = ?',
            [bukrs, kunnr, pay_ccy],
        )
        candidates = [
            {
                "bukrs": r[0], "kunnr": r[1], "gjahr": r[2], "belnr": r[3], "buzei": r[4],
                "amount": r[5], "currency": r[6], "zuonr": r[7], "sgtxt": r[8], "xblnr": r[9],
            }
            for r in cand_rows
        ]
 
        _insert_event(session, case_id, "INVOICES_FETCHED",
                      f"{len(candidates)} open BSID item(s) for KUNNR {kunnr} BUKRS {bukrs} {pay_ccy}",
                      {"kunnr": kunnr, "bukrs": bukrs, "currency": pay_ccy, "count": len(candidates)})
 
        kna1_name = _scalar(session, 'SELECT "NAME1" FROM master."KNA1" WHERE "KUNNR" = ?', [kunnr])
 
        if not candidates:
            reason = f"No open invoices for customer {kunnr} in {pay_ccy}"
            ai_title, ai_summary = _generate_ai_summary(
                session, case_row["payment_amount"], pay_ccy, reason,
                payer_name=case_row["payer_name"], customer_name=kna1_name, approval_status="NO_OPEN_INVOICES",
            )
            _route_pending(session, case_id, "NO_OPEN_INVOICES",
                            f"No open BSID items for KUNNR {kunnr} in {pay_ccy}", reason, ai_title, ai_summary)
            session.sql("COMMIT").collect()
            return "no_open_invoices"
 
        # ── Config (cached per-batch, passed in from run()) ──
        auto_min = config["auto_min"]
        manual_min = config["manual_min"]
        ambiguity_gap = config["ambiguity_gap"]
        home_currency = config["home_currency"]
        def_tol_pct = config["def_tol_pct"]
        def_tol_abs = config["def_tol_abs"]
        auto_post_max = config["auto_post_max"]
        l1_max = config["l1_max"]
        l2_max = config["l2_max"]
 
        # ── Tolerance ──
        togru = _scalar(session, 'SELECT "TOGRU" FROM master."KNB1" WHERE "KUNNR" = ? AND "BUKRS" = ?', [kunnr, bukrs])
        tol_fallback_reason = None
        if togru:
            tol_row = _rows(session, 'SELECT "betrg","prztl" FROM master."T043" WHERE "bukrs" = ? AND "togru" = ? AND "waers" = ?',
                             [bukrs, togru, pay_ccy])
            if tol_row:
                abs_lower, pct_lower = tol_row[0][0], tol_row[0][1]
                # T043.prztl is a percent (5.00 = 5%) — convert to a fraction, same fix as
                # Postgres commit 1c9b3a1, to match system_config's already-fractional convention.
                tol_pct = (Decimal(str(pct_lower)) / Decimal("100")) if pct_lower else def_tol_pct
                tol_abs = Decimal(str(abs_lower)) if abs_lower else def_tol_abs
            else:
                tol_fallback_reason = f"TOGRU={togru} set but T043 row missing for BUKRS={bukrs} WAERS={pay_ccy}"
                tol_pct, tol_abs = def_tol_pct, def_tol_abs
        else:
            tol_fallback_reason = "KNB1.TOGRU is NULL"
            tol_pct, tol_abs = def_tol_pct, def_tol_abs
 
        if tol_fallback_reason:
            _insert_event(session, case_id, "MATCH_DECISION",
                          f"Tolerance fallback — {tol_fallback_reason}: using {tol_pct * 100:.1f}% / ${tol_abs}",
                          {"reason": tol_fallback_reason, "togru": togru, "tol_pct": float(tol_pct),
                           "tol_abs": str(tol_abs), "fallback": True})
 
        # ── Scoring inputs ──
        claim_rows = _rows(session,
            "SELECT invoice_number, deduction_amount, reason_code, po_number "
            "FROM cashapp.capture_remittance_claims WHERE capture_id = ?", [case_row["capture_id"]])
        claims = [
            {"invoice_number": r[0], "deduction_amount": r[1], "reason_code": r[2], "po_number": r[3]}
            for r in claim_rows
        ]
        claim_refs = [c["invoice_number"] for c in claims if c["invoice_number"]]
        po_numbers = [c["po_number"] for c in claims if c["po_number"]]
 
        free_text = _scalar(session,
            "SELECT parsed_content:free_text::STRING FROM cashapp.capture_source_documents "
            "WHERE capture_id = ? AND document_type IN ('LOCKBOX_RECORD','EMAIL_BODY','EDI_IDOC') LIMIT 1",
            [case_row["capture_id"]])
 
        pat_rows = _rows(session,
            "SELECT pattern_id, pattern_type, pattern_value FROM cashapp.customer_match_patterns "
            "WHERE customer_kunnr = ? AND bukrs = ? AND is_active = TRUE", [kunnr, bukrs])
        patterns = [{"pattern_id": r[0], "pattern_type": r[1], "pattern_value": r[2]} for r in pat_rows]
 
        payer_name = kna1_name or case_row["payer_name"]
        payment_ref = case_row["payment_reference"]
        payment_amount = case_row["payment_amount"]
 
        # ── L1 ──
        l1_scores = score_l1(candidates, claim_refs, payment_ref, payment_amount, tol_abs, tol_pct)
        _insert_event(session, case_id, "MATCH_LAYER_1",
                      f"L1 scored {len(candidates)} candidate(s) — {len(claim_refs)} claim ref(s)",
                      {"claim_refs": claim_refs[:10], "payment_ref": payment_ref, "top_scores": sorted(l1_scores, reverse=True)[:5]})
 
        # ── L2 ──
        l2_scores = [score_l2(c, claim_refs, payment_ref, payer_name, payment_amount, tol_pct) for c in candidates]
        _insert_event(session, case_id, "MATCH_LAYER_2", f"L2 scored {len(candidates)} candidate(s)",
                      {"top_scores": sorted(l2_scores, reverse=True)[:5]})
 
        # ── L3 ──
        l3_errors = []
        l3_scores = [score_l3(c, patterns, claim_refs, po_numbers, payment_ref, payment_amount, tol_abs, tol_pct, l3_errors)
                     for c in candidates]
        _insert_event(session, case_id, "MATCH_LAYER_3",
                      f"L3 scored {len(candidates)} candidate(s) — {len(patterns)} pattern(s)" +
                      (f" — {len(l3_errors)} error(s)" if l3_errors else ""),
                      {"pattern_count": len(patterns), "has_patterns": bool(patterns), "errors": l3_errors[:5]})
 
        # ── L4 ──
        l4_scores, l4_error = None, None
        if free_text:
            try:
                l4_scores = score_l4_batch(session, candidates, payer_name, free_text, kna1_name)
            except Exception as exc:
                l4_error = str(exc)
        _insert_event(session, case_id, "MATCH_LAYER_4",
                      (f"L4 scored {len(candidates)} candidate(s)" if l4_scores is not None
                       else ("L4 skipped — no free_text" if not free_text else f"L4 failed: {l4_error}")),
                      {"fired": l4_scores is not None, "free_text_present": bool(free_text), "error": l4_error,
                       "top_scores": sorted(l4_scores, reverse=True)[:5] if l4_scores else None})
 
        # ── Composite ──
        scored = []
        for i, cand in enumerate(candidates):
            l3 = l3_scores[i]
            l4 = l4_scores[i] if l4_scores else None
            comp = _composite(Decimal(str(l1_scores[i])), Decimal(str(l2_scores[i])),
                               Decimal(str(l3)) if l3 is not None else None,
                               Decimal(str(l4)) if l4 is not None else None)
            scored.append({"cand": cand, "l1": l1_scores[i], "l2": l2_scores[i], "l3": l3, "l4": l4, "composite": comp})
        scored.sort(key=lambda x: x["composite"], reverse=True)
 
        best_score = scored[0]["composite"]
        second_score = scored[1]["composite"] if len(scored) > 1 else Decimal("0")
 
        # ── Routing ──
        is_ambiguous = len(scored) > 1 and (best_score - second_score) < ambiguity_gap
        if best_score < manual_min:
            routing = "UNRESOLVABLE"
        elif is_ambiguous:
            routing = "AMBIGUOUS_MATCH"
        elif best_score < auto_min:
            routing = "LOW_CONFIDENCE"
        else:
            routing = "AUTO"
 
        # ── Variance + strategy ──
        selected = _select_set(scored, routing)
        total_inv_amt = sum((s["cand"]["amount"] or Decimal("0")) for s in selected)
        variance = payment_amount - total_inv_amt
 
        strategy, variance_type = None, None
        if routing != "UNRESOLVABLE" and selected:
            strategy, variance_type = _variance_strategy(variance, tol_abs, tol_pct, payment_amount, pay_ccy, home_currency, claims)
 
        # ── Autonomy tier + workflow stage ──
        tier = _autonomy_tier(payment_amount, auto_post_max, l1_max, l2_max)
        new_stage, new_approval = _workflow_routing(routing, tier)
 
        if routing == "AMBIGUOUS_MATCH":
            _insert_event(session, case_id, "MATCH_AMBIGUOUS",
                          f"Ambiguous — top {best_score:.3f}, second {second_score:.3f}, "
                          f"gap {best_score - second_score:.4f} < margin {ambiguity_gap}",
                          {"top_score": round(float(best_score), 4), "second_score": round(float(second_score), 4),
                           "gap": round(float(best_score - second_score), 4), "margin": float(ambiguity_gap)})
 
        # ── Save proposal ──
        proposal_id = str(uuid.uuid4())
        _safe_sql(session,
            "INSERT INTO cashapp.case_match_proposals "
            "(proposal_id, case_id, proposal_rank, is_selected, match_strategy, match_confidence, "
            " total_invoice_amount, total_payment_amount, variance_amount, variance_currency, "
            " variance_type, tolerance_group, posting_date) "
            "VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params=[proposal_id, case_id, routing == "AUTO", strategy, round(best_score, 3),
                    total_inv_amt if selected else None, payment_amount, variance if selected else None,
                    pay_ccy, variance_type, togru, date.today()])

        # ── Save invoice matches (all scored candidates) ──
        selected_ids = {id(s) for s in selected}
        for s in scored:
            cand = s["cand"]
            ded_amt, ded_code, net_amt = _claim_detail(cand, claims)
            _safe_sql(session,
                "INSERT INTO cashapp.case_invoice_matches "
                "(match_id, proposal_id, case_id, company_code, customer_number, fiscal_year, document_number, "
                " line_item, invoice_amount, deduction_amount, deduction_reason_code, net_amount, currency, "
                " match_layer, l1_score, l2_score, l3_score, l4_score, confidence, is_included) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                params=[str(uuid.uuid4()), proposal_id, case_id, cand["bukrs"], cand["kunnr"], cand["gjahr"],
                        cand["belnr"], cand["buzei"], cand["amount"], ded_amt, ded_code, net_amt, cand["currency"],
                        _primary_layer(s["l1"], s["l2"], s["l3"], s["l4"]),
                        _dec(s["l1"]), _dec(s["l2"]), _dec(s["l3"]), _dec(s["l4"]), _dec(float(s["composite"])),
                        id(s) in selected_ids])

        # ── Update case ──
        route_reason = _build_route_reason(
            routing=routing, scored=scored, strategy=strategy,
            variance=variance if selected else payment_amount, variance_type=variance_type,
            payment_amount=payment_amount, currency=pay_ccy, tier=tier,
            best_score=best_score, second_score=second_score, ambiguity_gap=ambiguity_gap,
        )

        invoice_refs = [str(s["cand"]["belnr"]) for s in (selected if selected else scored[:1]) if s["cand"]["belnr"]]
        ai_title, ai_summary_text = _generate_ai_summary(
            session, payment_amount, pay_ccy, route_reason,
            payer_name=payer_name, customer_name=kna1_name, routing=routing, strategy=strategy,
            invoice_refs=invoice_refs, variance=variance if selected else None, variance_type=variance_type,
            reason_codes=list({c["reason_code"] for c in claims if c["reason_code"]}),
            free_text=free_text, confidence=float(best_score), tier=tier,
        )

        _safe_sql(session,
            "UPDATE cashapp.cases SET workflow_stage = ?, approval_status = ?, match_strategy = ?, "
            "match_confidence = ?, review_autonomy_tier = ?, route_reason = ?, ai_summary_title = ?, "
            "ai_summary = ?, ai_confidence = ?, updated_at = CURRENT_TIMESTAMP() WHERE case_id = ?",
            params=[new_stage, new_approval, strategy, round(best_score, 3), tier, route_reason,
                    ai_title, ai_summary_text, round(best_score, 3), case_id])
 
        _insert_event(session, case_id, "MATCH_DECISION",
                      f"Match complete — routing={routing} stage={new_stage} strategy={strategy} "
                      f"confidence={best_score:.3f} tier={tier}",
                      {"routing": routing, "new_stage": new_stage, "approval_status": new_approval,
                       "strategy": strategy, "variance_type": variance_type,
                       "variance_amount": str(variance) if selected else None,
                       "match_confidence": round(float(best_score), 3), "review_autonomy_tier": tier,
                       "candidate_count": len(candidates)})
 
        session.sql("COMMIT").collect()
        return routing.lower()
    except Exception:
        try:
            session.sql("ROLLBACK").collect()
        except Exception:
            pass
        raise
 
 
# ── Main matching pass (HANDLER) ──────────────────────────────────────────
def run(session):
    case_rows = _rows(session,
        "SELECT case_id, capture_id, payment_id, sap_customer_id, payment_amount, currency_code "
        "FROM cashapp.cases WHERE workflow_stage = 'MATCHING' ORDER BY created_at ASC LIMIT ?", [BATCH_SIZE])
 
    cases = []
    for r in case_rows:
        capture_id, payment_id = r[1], r[2]
        payment_ref = _scalar(session, "SELECT payment_reference FROM cashapp.payments WHERE payment_id = ?", [payment_id])
        payer_name = _scalar(session, "SELECT payer_name FROM cashapp.channel_captures WHERE capture_id = ?", [capture_id])
        cases.append({
            "case_id": r[0], "capture_id": capture_id, "payment_id": payment_id,
            "sap_customer_id": r[3], "payment_amount": r[4], "currency_code": r[5],
            "payment_reference": payment_ref, "payer_name": payer_name,
        })
 
    if not cases:
        return {"processed": 0, "auto": 0, "low_confidence": 0, "ambiguous_match": 0,
                "unresolvable": 0, "unresolved_customer": 0, "no_open_invoices": 0, "errors": 0}

    # ── Cache config values once per batch (eliminates ~9 queries × N cases) ──
    config = {
        "auto_min": Decimal(str(_get_config_float(session, "auto_match_confidence_min", 0.85))),
        "manual_min": Decimal(str(_get_config_float(session, "manual_match_confidence_min", 0.65))),
        "ambiguity_gap": Decimal(str(_get_config_float(session, "ambiguity_confidence_margin", 0.05))),
        "home_currency": _get_config_value(session, "company_home_currency") or "USD",
        "def_tol_pct": Decimal(str(_get_config_float(session, "default_amount_tolerance_pct", 0.01))),
        "def_tol_abs": Decimal(str(_get_config_float(session, "default_amount_tolerance_abs", 1.00))),
        "auto_post_max": Decimal(str(_get_config_float(session, "auto_post_amount_max", 10000))),
        "l1_max": Decimal(str(_get_config_float(session, "l1_approval_amount_max", 100000))),
        "l2_max": Decimal(str(_get_config_float(session, "l2_approval_amount_max", 1000000))),
    }

    counts = {"auto": 0, "low_confidence": 0, "ambiguous_match": 0, "unresolvable": 0,
              "unresolved_customer": 0, "no_open_invoices": 0, "errors": 0}
    error_details = []
    for case_row in cases:
        try:
            outcome = _match_one(session, case_row, config)
            counts[outcome] = counts.get(outcome, 0) + 1
        except Exception as exc:
            counts["errors"] += 1
            error_details.append({
                "case_id": case_row["case_id"],
                "error": str(exc),
                "traceback": traceback.format_exc()[-500:]
            })

    return {"processed": len(cases), **counts, "error_details": error_details[:5]}
$$;
 
-- Task orchestration for this procedure lives in Task_Matching.sql
-- (cashapp.TASK_MATCHING) — runs AFTER cashapp.TASK_CASE_PROMOTION rather
-- than on its own schedule.
