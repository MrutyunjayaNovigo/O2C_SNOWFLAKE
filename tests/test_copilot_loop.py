# Offline harness: exec the procedure body against a stubbed Snowpark session
# and drive the loop through its real paths. Proves control flow, JSON
# extraction, the tool allow-list and the repair branch without a warehouse.
#
# Reads migrations/R__sp_copilot_ask.sql — the schemachange-deployed source
# of truth — not the old 10_copilot/ copy that migrations/ superseded.
# {% raw %}/{% endraw %} tags are stripped before exec since this reads the
# file directly rather than through schemachange's Jinja renderer, which
# would otherwise strip them itself; the content between the tags is
# untouched either way, so this exactly mirrors what actually gets deployed.
import io, json, re

body = io.open('migrations/R__sp_copilot_ask.sql', encoding='utf-8').read().split('$$')[1]
body = body.replace('{% raw %}', '').replace('{% endraw %}', '')
mod = {}
exec(compile(body, 'proc', 'exec'), mod)


class Row(dict):
    def __getitem__(self, k):
        if isinstance(k, int):
            return list(self.values())[k]
        return dict.__getitem__(self, k)


class Result:
    def __init__(self, rows): self._rows = rows
    def collect(self): return self._rows


class Session:
    def __init__(self, completions, tool_results):
        self.completions = list(completions)
        self.tool_results = tool_results
        self.steps = []
        self.runs = []

    def sql(self, text, params=None):
        params = params or []
        t = ' '.join(text.split())
        if 'CORTEX.COMPLETE' in t:
            payload = {'choices': [{'messages': self.completions.pop(0)}]}
            return Result([Row(R=json.dumps(payload))])
        if t.startswith('SELECT UUID_STRING'):
            return Result([Row(ID='run-test-1')])
        if 'FROM CASHAPP.SYSTEM_CONFIG' in t:
            return Result([])                      # fall back to DEFAULTS
        if t.startswith('INSERT INTO CASHAPP.COPILOT_STEPS'):
            self.steps.append(params)
            return Result([])
        if t.startswith('INSERT INTO CASHAPP.COPILOT_RUNS'):
            self.runs.append(params)
            return Result([])
        if t.startswith('CALL CASHAPP.SP_TOOL_'):
            name = 'case_retrieval' if 'CASE_RETRIEVAL' in t else 'match_explain'
            return Result([Row(R=json.dumps(self.tool_results[name]))])
        raise AssertionError('unexpected sql: ' + t[:90])


CASE_OK = {'ok': True, 'case': {'case_id': 'c-1', 'case_number': 'CC-1042',
                                'status': 'OPEN', 'workflow_stage': 'REVIEW'}}
MATCH_OK = {'ok': True, 'proposals': [{'rank': 1, 'confidence': 0.71}]}
TOOLS = {'case_retrieval': CASE_OK, 'match_explain': MATCH_OK}

def phases(s):
    return [(p[2], p[3]) for p in s.steps]

fails = []

# 1 — happy path: two tools then an answer
s = Session([
    '```json\n{"tool":"case_retrieval","args":{"case_ref":"CC-1042"}}\n```',
    '{"tool":"match_explain","args":{"case_id":"c-1"}}',
    'Sure! {"answer":"**CC-1042** sits at **0.71**, below the auto threshold."}',
], TOOLS)
r = mod['run'](s, 'Why is CC-1042 unmatched?', 'u1', 'analyst', None)
assert r['answered'] and r['stop_reason'] == 'ANSWERED', r
assert phases(s) == [('TOOL', 'case_retrieval'), ('TOOL', 'match_explain'), ('ANSWER', None)], phases(s)
assert len(s.runs) == 2, 'expected an opening and a closing run row'
print('1 happy path            OK  ->', r['answer'][:52])

# 2 — invented tool name must never reach a CALL
s = Session(['{"tool":"delete_everything","args":{"x":1}}',
             '{"answer":"I cannot do that with the tools I have."}'], TOOLS)
r = mod['run'](s, 'drop the table', 'u1', 'analyst', None)
assert r['answered'], r
assert s.steps[0][3] == 'delete_everything' and s.steps[0][5] is not None
obs = json.loads(s.steps[0][5])
assert obs['ok'] is False and 'Unknown tool' in obs['reason'], obs
print('2 allow-list holds      OK  ->', obs['reason'][:52])

# 3 — one repair attempt, then give up
s = Session(['no json here', 'still no json', 'and again'], TOOLS)
r = mod['run'](s, 'hello', 'u1', 'analyst', None)
assert r['answered'] is False and r['stop_reason'] == 'PARSE_FAIL', r
assert [p[2] for p in s.steps] == ['REPAIR', 'PLAN'], [p[2] for p in s.steps]
print('3 repair then stop      OK  -> stop_reason =', r['stop_reason'])

# 4 — step cap honoured (4 tool calls, never answers)
s = Session(['{"tool":"case_retrieval","args":{"case_ref":"CC-1"}}'] * 6, TOOLS)
r = mod['run'](s, 'loop forever', 'u1', 'analyst', None)
assert r['stop_reason'] == 'STEP_CAP' and len(r['steps']) == 4, r
print('4 step cap honoured     OK  -> steps =', len(r['steps']))

# 5 — a failing tool is an observation, not a crash
s = Session(['{"tool":"match_explain","args":{"case_id":"nope"}}',
             '{"answer":"Matching has not run for that case."}'],
            {'case_retrieval': CASE_OK,
             'match_explain': {'ok': False, 'reason': 'No match proposals exist'}})
r = mod['run'](s, 'explain nope', 'u1', 'analyst', None)
assert r['answered'] and json.loads(s.steps[0][5])['ok'] is False
print('5 tool failure survives OK  ->', r['answer'][:52])

# 6 — empty question short-circuits before any model call
r = mod['run'](Session([], TOOLS), '   ', 'u1', 'analyst', None)
assert r['stop_reason'] == 'ERROR' and not r['answered'], r
print('6 empty question guard  OK')

print('\nall 6 scenarios pass')
