# 10_copilot — agentic Copilot

A plan/act/observe loop that answers case questions by calling two read-only
tools, running entirely inside Snowflake as a Snowpark stored procedure.

## Run order

Order matters — the loop writes to the audit tables on its first statement.

```
Create_Tables_Copilot.sql        tables + grants + system_config rows
Procedure_ToolCaseRetrieval.sql  tool 1
Procedure_ToolMatchExplain.sql   tool 2
Procedure_CopilotAsk.sql         the loop
```

`./deploy.sh` runs all four in order. It uses the `newacct` snow CLI
connection unless `SNOW_CONNECTION` says otherwise, and needs a role that can
create in `O2C_DB.CASHAPP` — the runtime role cannot.

## Calling it

```sql
CALL CASHAPP.SP_COPILOT_ASK('Why has case <n> not been auto-posted?',
                            'user-id', 'analyst', NULL::STRING);
```

Snowflake matches procedure overloads by argument **type**. A bare `NULL`
cannot be resolved to `STRING` and surfaces as "Unknown user-defined
function" — cast it.

## Two things that are easy to get wrong

**The append-only grants need the REVOKEs.** This schema carries a future
grant handing `O2C_APP` full DML on every table created in it, so a new table
arrives already writable and `GRANT SELECT, INSERT` restricts nothing. The
`REVOKE UPDATE, DELETE` lines in `Create_Tables_Copilot.sql` are what actually
makes the trail tamper-evident. Verify with:

```sql
USE ROLE O2C_APP; USE SECONDARY ROLES NONE;
UPDATE CASHAPP.COPILOT_STEPS SET TOOL_NAME = 'x';   -- must fail
```

**The tools must never raise.** They return `{ok: false, reason: ...}` instead.
An exception inside the loop kills the run; a failed observation is something
the model can read and recover from.

## Tuning

`system_config` rows, no redeploy needed:

| key | default | |
|---|---|---|
| `copilot_model` | `llama3.1-70b` | Snowflake retires models — this is why it is config, not code |
| `copilot_max_steps` | `4` | hard cap on loop iterations |
| `copilot_max_tokens` | `250` | the answer is 2-4 sentences |

## Tests

`python test_copilot_loop.py` drives the loop against a stubbed session and
covers the happy path, the tool allow-list, JSON repair, the step cap, tool
failure and the empty-question guard. No warehouse required.
