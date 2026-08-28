-- ============================================================
-- Copilot tool: match explain — Snowflake Procedure
-- Entry point : CALL CASHAPP.SP_TOOL_MATCH_EXPLAIN('<case_id>')
-- Reads       : cashapp.case_match_proposals, cashapp.case_invoice_matches,
--               cashapp.system_config
-- Writes      : nothing.
-- Why it works: the per-layer scores already exist — case_invoice_matches
--               carries l1_score..l4_score and match_layer per invoice line.
--               This tool shapes them, it does not recompute anything.
-- Caps        : 5 proposals, 20 invoice lines. Every row returned is context
--               the next model call pays for.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_TOOL_MATCH_EXPLAIN(
    P_CASE_ID STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
MAX_PROPOSALS = 5
MAX_LINES = 20


def _rows(session, sql_text, params=None):
    return session.sql(sql_text, params=params or []).collect()


def _num(v):
    return float(v) if v is not None else None


def run(session, p_case_id: str) -> dict:
    case_id = (p_case_id or '').strip()
    if not case_id:
        return {'ok': False, 'reason': 'No case id supplied'}

    # Tolerate being handed a case number instead of the UUID — the model will
    # do it eventually, and a hard failure there wastes a whole loop step.
    resolved = _rows(session,
                     'SELECT CASE_ID FROM CASHAPP.CASES WHERE CASE_ID = ? OR CASE_NUMBER = ? LIMIT 1',
                     [case_id, case_id])
    if not resolved:
        return {'ok': False, 'reason': f'No case found for {case_id}'}
    case_id = resolved[0]['CASE_ID']

    proposals = _rows(session, f"""
        SELECT PROPOSAL_ID, PROPOSAL_RANK, IS_SELECTED, MATCH_STRATEGY, MATCH_CONFIDENCE,
               TOTAL_INVOICE_AMOUNT, TOTAL_PAYMENT_AMOUNT, VARIANCE_AMOUNT, VARIANCE_CURRENCY,
               VARIANCE_TYPE, TOLERANCE_GROUP
        FROM CASHAPP.CASE_MATCH_PROPOSALS
        WHERE CASE_ID = ?
        ORDER BY PROPOSAL_RANK
        LIMIT {MAX_PROPOSALS}
    """, [case_id])

    if not proposals:
        return {'ok': False, 'reason': 'No match proposals exist for this case — '
                                       'matching has not run, or it found no candidates'}

    lines = _rows(session, f"""
        SELECT PROPOSAL_ID, DOCUMENT_NUMBER, LINE_ITEM, INVOICE_AMOUNT, NET_AMOUNT,
               DEDUCTION_AMOUNT, DEDUCTION_REASON_CODE, CURRENCY, MATCH_LAYER,
               L1_SCORE, L2_SCORE, L3_SCORE, L4_SCORE
        FROM CASHAPP.CASE_INVOICE_MATCHES
        WHERE CASE_ID = ?
        ORDER BY MATCH_LAYER, DOCUMENT_NUMBER
        LIMIT {MAX_LINES}
    """, [case_id])

    by_proposal = {}
    for ln in lines:
        by_proposal.setdefault(ln['PROPOSAL_ID'], []).append({
            'document_number': ln['DOCUMENT_NUMBER'],
            'line_item': ln['LINE_ITEM'],
            'invoice_amount': _num(ln['INVOICE_AMOUNT']),
            'net_amount': _num(ln['NET_AMOUNT']),
            'deduction_amount': _num(ln['DEDUCTION_AMOUNT']),
            'deduction_reason': ln['DEDUCTION_REASON_CODE'],
            'currency': ln['CURRENCY'],
            'winning_layer': ln['MATCH_LAYER'],
            'scores': {
                'l1_deterministic': _num(ln['L1_SCORE']),
                'l2_fuzzy': _num(ln['L2_SCORE']),
                'l3_customer_pattern': _num(ln['L3_SCORE']),
                'l4_embedding': _num(ln['L4_SCORE']),
            },
        })

    cfg = {}
    for r in _rows(session, """
        SELECT CONFIG_KEY, CONFIG_VALUE FROM CASHAPP.SYSTEM_CONFIG
        WHERE CONFIG_KEY IN ('auto_match_confidence_min','manual_match_confidence_min',
                             'ambiguity_confidence_margin')
    """):
        cfg[r['CONFIG_KEY']] = r['CONFIG_VALUE']

    return {
        'ok': True,
        'case_id': case_id,
        'thresholds': cfg,
        'layer_weights': {'l1': 1.00, 'l2': 0.85, 'l3': 0.80, 'l4': 0.65},
        'proposals': [{
            'rank': p['PROPOSAL_RANK'],
            'selected': bool(p['IS_SELECTED']),
            'strategy': p['MATCH_STRATEGY'],
            'confidence': _num(p['MATCH_CONFIDENCE']),
            'total_invoice_amount': _num(p['TOTAL_INVOICE_AMOUNT']),
            'total_payment_amount': _num(p['TOTAL_PAYMENT_AMOUNT']),
            'variance_amount': _num(p['VARIANCE_AMOUNT']),
            'variance_currency': p['VARIANCE_CURRENCY'],
            'variance_type': p['VARIANCE_TYPE'],
            'tolerance_group': p['TOLERANCE_GROUP'],
            'invoices': by_proposal.get(p['PROPOSAL_ID'], []),
        } for p in proposals],
    }
$$;

GRANT USAGE ON PROCEDURE CASHAPP.SP_TOOL_MATCH_EXPLAIN(STRING) TO ROLE O2C_APP;

-- CALL CASHAPP.SP_TOOL_MATCH_EXPLAIN('<case_id>');
