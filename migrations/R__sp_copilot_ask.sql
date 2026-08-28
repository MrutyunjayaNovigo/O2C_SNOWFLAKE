-- ============================================================
-- Copilot agent loop — Snowflake Procedure
-- Entry point : CALL CASHAPP.SP_COPILOT_ASK('<question>','<user_id>','<persona>','<case_id or null>')
-- Reads       : cashapp.system_config, plus whatever the two tools read
-- Writes      : cashapp.copilot_runs, cashapp.copilot_steps  (append-only)
-- Loop        : plan -> tool -> observe, capped at copilot_max_steps, then answer.
--
-- Two rules that matter more than they look:
--   1. Tool dispatch goes through TOOLS, an allow-list. A name the model
--      invented never reaches a CALL statement.
--   2. A tool failure is an observation, not an exception. The model sees
--      "ok: false" and decides what to do next — which is the whole point of
--      a loop rather than a pipeline.
--
-- Scope note  : both tools are read-only, so the worst outcome of a bad plan
--               is a wrong answer, never a wrong action. Adding a tool that
--               writes changes that calculus — revisit this header first.
-- ============================================================

USE DATABASE O2C_DB;
USE SCHEMA CASHAPP;

CREATE OR REPLACE PROCEDURE CASHAPP.SP_COPILOT_ASK(
    P_QUESTION STRING,
    P_USER_ID  STRING,
    P_PERSONA  STRING,
    P_CASE_ID  STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
import json, re, time

DEFAULTS = {'copilot_model': 'llama3.1-70b', 'copilot_max_steps': '4', 'copilot_max_tokens': '250'}

TOOLS = {
    'case_retrieval': ('CALL CASHAPP.SP_TOOL_CASE_RETRIEVAL(?)', 'case_ref'),
    'match_explain':  ('CALL CASHAPP.SP_TOOL_MATCH_EXPLAIN(?)',  'case_id'),
}

PERSONAS = {
    'analyst':    'an AR Cash Application Analyst',
    'manager':    'an AR / Shared Services Manager',
    'controller': 'a Finance Controller',
}

SYSTEM = """You are the Cash Clear Copilot, inside an SAP cash-application product. The user is {who}.

You answer by calling tools. Never answer a question about a specific case from memory.

Tools:
  case_retrieval(case_ref)  -> case status, workflow stage, amount, customer, routing reason
  match_explain(case_id)    -> per-invoice L1-L4 scores, composite confidence, variance, thresholds

Reply with ONE json object and nothing else:
  {% raw %}{{"tool": "<name>", "args": {{"<arg>": "<value>"}}}}{% endraw %}   to call a tool
  {% raw %}{{"answer": "<text>"}}{% endraw %}                                  when you can answer

Rules:
- Never invent a case number, customer name, SAP document number, amount or score.
  If a tool returns ok:false, say what is missing and stop. Do not guess.
- If the question cannot be answered with these two tools, say so plainly in an answer.
- Answer in 2-4 short sentences. Use **bold** for figures and identifiers.
- Cite what you read: name the case and the scores you based the answer on.
"""


def _rows(session, sql_text, params=None):
    return session.sql(sql_text, params=params or []).collect()


def _config(session):
    cfg = dict(DEFAULTS)
    try:
        for r in _rows(session, "SELECT CONFIG_KEY, CONFIG_VALUE FROM CASHAPP.SYSTEM_CONFIG "
                                "WHERE CONFIG_KEY LIKE 'copilot_%'"):
            cfg[r['CONFIG_KEY']] = r['CONFIG_VALUE']
    except Exception:
        pass
    return cfg


def _log_step(session, run_id, step_no, phase, tool_name, tool_args, tool_result, raw, model, ms):
    session.sql(
        "INSERT INTO CASHAPP.COPILOT_STEPS "
        "(RUN_ID, STEP_NO, PHASE, TOOL_NAME, TOOL_ARGS, TOOL_RESULT, RAW_MODEL, MODEL, LATENCY_MS) "
        "SELECT ?, ?, ?, ?, TRY_PARSE_JSON(?), TRY_PARSE_JSON(?), ?, ?, ?",
        params=[run_id, step_no, phase, tool_name,
                json.dumps(tool_args) if tool_args is not None else None,
                json.dumps(tool_result) if tool_result is not None else None,
                (raw or '')[:4000], model, ms],
    ).collect()


def _complete(session, model, messages, max_tokens):
    started = time.time()
    rows = _rows(session,
                 "SELECT SNOWFLAKE.CORTEX.COMPLETE(?, PARSE_JSON(?), PARSE_JSON(?)) AS R",
                 [model, json.dumps(messages),
                  json.dumps({'temperature': 0.0, 'max_tokens': max_tokens})])
    ms = int((time.time() - started) * 1000)
    if not rows or rows[0]['R'] is None:
        return '', ms
    payload = rows[0]['R']
    if isinstance(payload, str):
        payload = json.loads(payload)
    choices = payload.get('choices') or []
    return ((choices[0].get('messages') or '').strip() if choices else ''), ms


def _extract_json(raw):
    """Models fence JSON, prefix it with prose, or both. Take the first object."""
    if not raw:
        return None
    fenced = re.search(r'`{3}(?:json)?\s*(\{.*?\})\s*`{3}', raw, re.S)
    candidate = fenced.group(1) if fenced else None
    if candidate is None:
        brace = re.search(r'\{.*\}', raw, re.S)
        candidate = brace.group(0) if brace else None
    if candidate is None:
        return None
    try:
        return json.loads(candidate)
    except Exception:
        return None


def _run_tool(session, name, args):
    sql_text, arg_name = TOOLS[name]
    args = args or {}
    value = args.get(arg_name) or args.get('case_id') or args.get('case_ref')
    if not value:
        return {'ok': False, 'reason': name + ' needs ' + arg_name}
    try:
        rows = _rows(session, sql_text, [str(value)])
        out = rows[0][0] if rows else None
        if isinstance(out, str):
            return json.loads(out)
        return out or {'ok': False, 'reason': 'tool returned nothing'}
    except Exception as exc:
        return {'ok': False, 'reason': name + ' failed: ' + str(exc)}


def run(session, p_question: str, p_user_id: str, p_persona: str, p_case_id: str) -> dict:
    question = (p_question or '').strip()
    if not question:
        return {'answered': False, 'answer': None, 'steps': [],
                'stop_reason': 'ERROR', 'error': 'No question supplied'}

    cfg = _config(session)
    model = cfg['copilot_model']
    max_steps = int(cfg['copilot_max_steps'])
    max_tokens = int(cfg['copilot_max_tokens'])
    who = PERSONAS.get((p_persona or '').lower(), 'a finance user')

    run_id = _rows(session, 'SELECT UUID_STRING() AS ID')[0]['ID']
    session.sql(
        'INSERT INTO CASHAPP.COPILOT_RUNS (RUN_ID, USER_ID, PERSONA, QUESTION, CASE_ID, MODEL) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        params=[run_id, p_user_id, p_persona, question, p_case_id, model],
    ).collect()

    opening = question
    if p_case_id:
        opening = question + '\n\n(The user is currently viewing case ' + str(p_case_id) + '.)'

    messages = [{'role': 'system', 'content': SYSTEM.format(who=who)},
                {'role': 'user', 'content': opening}]

    started = time.time()
    trace = []
    answer = None
    stop_reason = 'STEP_CAP'
    repaired = False

    for step_no in range(1, max_steps + 1):
        raw, ms = _complete(session, model, messages, max_tokens)
        parsed = _extract_json(raw)

        if parsed is None:
            # One repair attempt, then stop. A model that cannot emit an object
            # twice will not manage it on a third try.
            if repaired:
                _log_step(session, run_id, step_no, 'PLAN', None, None, None, raw, model, ms)
                stop_reason = 'PARSE_FAIL'
                break
            repaired = True
            _log_step(session, run_id, step_no, 'REPAIR', None, None, None, raw, model, ms)
            messages.append({'role': 'assistant', 'content': raw})
            messages.append({'role': 'user', 'content':
                             'That was not valid JSON. Reply with one json object only: '
                             '{"tool":...,"args":{...}} or {"answer":"..."}.'})
            continue

        if 'answer' in parsed:
            answer = str(parsed['answer']).strip()
            _log_step(session, run_id, step_no, 'ANSWER', None, None, None, raw, model, ms)
            trace.append({'step': step_no, 'phase': 'ANSWER'})
            stop_reason = 'ANSWERED'
            break

        name = parsed.get('tool')
        args = parsed.get('args') or {}

        if name not in TOOLS:
            observation = {'ok': False,
                           'reason': 'Unknown tool "' + str(name) + '". Available: '
                                     + ', '.join(TOOLS)}
            _log_step(session, run_id, step_no, 'TOOL', str(name), args, observation, raw, model, ms)
        else:
            observation = _run_tool(session, name, args)
            _log_step(session, run_id, step_no, 'TOOL', name, args, observation, raw, model, ms)
            trace.append({'step': step_no, 'phase': 'TOOL', 'tool': name,
                          'args': args, 'ok': bool(observation.get('ok'))})

        messages.append({'role': 'assistant', 'content': raw})
        messages.append({'role': 'user',
                         'content': 'Tool result:\n' + json.dumps(observation)[:2500]})

    latency = int((time.time() - started) * 1000)

    # COPILOT_RUNS is append-only, so the outcome lands as a second row keyed on
    # the same RUN_ID rather than an UPDATE. Read the latest by FINISHED_AT.
    session.sql(
        'INSERT INTO CASHAPP.COPILOT_RUNS '
        '(RUN_ID, USER_ID, PERSONA, QUESTION, CASE_ID, MODEL, STEP_COUNT, STOP_REASON, '
        ' ANSWERED, ANSWER, LATENCY_MS, FINISHED_AT) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP())',
        params=[run_id, p_user_id, p_persona, question, p_case_id, model, len(trace),
                stop_reason, answer is not None, answer, latency],
    ).collect()

    return {'run_id': run_id, 'answered': answer is not None, 'answer': answer,
            'steps': trace, 'stop_reason': stop_reason, 'latency_ms': latency}
$$;

GRANT USAGE ON PROCEDURE CASHAPP.SP_COPILOT_ASK(STRING, STRING, STRING, STRING) TO ROLE O2C_APP;

-- Snowflake matches procedure overloads by argument TYPE. A bare NULL cannot be
-- resolved to STRING and surfaces as "Unknown user-defined function" — cast it.
-- CALL CASHAPP.SP_COPILOT_ASK('Why is case CC-1042 still unmatched?', 'u1', 'analyst', NULL::STRING);
