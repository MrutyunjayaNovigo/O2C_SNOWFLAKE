# migrations — schemachange

## What's here

Every file in this folder started as a **copy** of a file that used to live
elsewhere in the repo (`01_initial_script/`, `02_capture/`, ... `10_copilot/`,
`Email_Prerequisite/`), renamed to schemachange's naming convention. Those
original numbered folders were additive at first — kept alongside this one
while the migration was unproven — and removed once `migrations/` was
confirmed as the actual deploy path (see `../DEPLOYMENT.md`, "What this
replaces"); keeping both meant an edit to one could silently never reach the
other. Content is unchanged from the originals except for `V1.1` (warehouse/database creation lines
removed — Terraform owns those now, see `../terraform/README.md`) and
`V2.1` (a new file — it's the schema-owned half of
`Email_capture_prereqs.sql`, split out from the half that became Terraform).

schemachange (`pip install schemachange`) is a thin, Flyway-style migration
runner: it walks this folder, finds files it hasn't applied yet (tracked in
a `CHANGE_HISTORY` table it creates and owns), and runs them against
Snowflake in order. Nothing here requires a specific ORM or framework — it's
the same `.sql` files this repo already had, just with a naming convention
that tells schemachange *when* to run each one.

## The naming convention

**`V<version>__<description>.sql`** — versioned, runs **once**, in version
order, and is recorded so it's never run again even if the file changes
later. Used for anything that creates a table, task, or grant — running it
twice would either be a harmless no-op (`CREATE TABLE IF NOT EXISTS`) or
actively wrong (`DROP TASK` + `CREATE OR REPLACE TASK ... RESUME` on every
deploy would fight a manual `SUSPEND` done for a backfill).

| File | Was | Runs |
|---|---|---|
| `V1.1__warehouse_database_master_schema.sql` | `01_initial_script/Create_Script.sql` | once |
| `V1.2__seed_data.sql` | `01_initial_script/Seed_data.sql` | once |
| `V2.1__email_capture_stage_and_config.sql` | `Email_Prerequisite/Email_capture_prereqs.sql` (stage + config rows only) | once |
| `V3.1__task_capture.sql` | `02_capture/Task_Capture.sql` | once |
| `V4.1__task_case_promotion.sql` | `03_case_promotion/Task_CasePromotion.sql` | once |
| `V5.1__task_matching.sql` | `04_matching/Task_Matching.sql` | once |
| `V6.1__disputes_tables.sql` | `08_disputes/Create_Table_Disputes.sql` | once |
| `V7.1__outreach_tables.sql` | `09_outreach/Create_Tables_Outreach.sql` | once |
| `V8.1__copilot_tables.sql` | `10_copilot/Create_Tables_Copilot.sql` | once |

Version numbers follow the original folder numbers (`V1` = `01_...`, `V6` =
`08_disputes`, etc.) — not sequential 1-9 — so a future migration for, say,
`06_case_actions` table changes has an obvious slot (`V9`) instead of
forcing a renumber. `05_postguard`, `06_case_actions`, `07_posting` have no
versioned file: nothing in those folders creates a table or task, only
procedures (see below).

**`R__<description>.sql`** — repeatable, runs **every deploy** if its
content changed since last time (schemachange tracks a checksum), always
after every pending `V` file. This is every `CREATE OR REPLACE PROCEDURE`
file in the repo — 27 of them, one per source file. Re-running a `CREATE OR REPLACE PROCEDURE` is exactly what you
want on every deploy: it's how procedure code changes ship. There's no
dependency ordering to worry about between them — every `CALL` inside a
procedure body resolves at runtime, not at creation time, so it doesn't
matter which `R__` file runs first.

## What's deliberately NOT here

`05_postguard/Check_Postguard_Results.sql` was never copied here — it's a
diagnostic query file with a literal `'<case_id>'` placeholder, meant to be
opened and edited by a human investigating one case, not deployed. There's
nothing to automate, so unlike the rest of the original numbered folders
(removed once migrations/ was proven as the real deploy path — see
`../DEPLOYMENT.md`, "What this replaces"), this one had no `migrations/`
counterpart to make it redundant. It's gone from the repo entirely now;
recover it from git history if you need that exact query again.

## Why the role split looks like this

Terraform owns: warehouse, database, schemas, the `O2C_APP` role, and
anything holding a live credential (network rules, secrets, external access
integrations) — see `../terraform/README.md`. schemachange owns everything
that's pure schema content: tables, procedures, tasks, and per-table grants.

The dividing line is "does this hold a credential or sit at the account
security boundary" — not "is this DDL." Tables are DDL and still belong
here. A `SECRET` object is also just DDL, syntactically, but its argument is
a live Gmail refresh token — that has to come from a gitignored
`terraform.tfvars`/env var, not a `.sql` file sitting in git. That's the
whole reason this split exists: `Email_Prerequisite/Email_capture_prereqs.sql`
had three real credentials committed in plaintext (visible in git history
right now, not just in an old commit — the "rotate Gmail OAuth secret"
commit replaced one leaked value with another one that's *also* in
history). Moving anything credential-shaped to Terraform variables is what
stops that from happening again on a new account.

## Setup

```bash
pip install schemachange
snow connection add newacct        # one-time per account
export SNOWFLAKE_DEFAULT_CONNECTION_NAME=newacct
```

`schemachange-config.yml` (repo root) reads that connection instead of
duplicating account/user/auth config. If your schemachange version predates
`connection-name` support (added in 3.6), replace that block with explicit
fields:

```yaml
snowflake-account: 'myorg-myaccount'
snowflake-user: 'SCHEMACHANGE_DEPLOYER'
snowflake-role: 'ACCOUNTADMIN'
snowflake-authenticator: 'SNOWFLAKE_JWT'
snowflake-private-key-path: '/path/to/key.p8'
```

**Run `terraform apply` first.** `V1.1` only `USE`s the warehouse/database;
it doesn't create them. `R__sp_email_capture.sql` references
`eai_gmail_api`/`eai_azure_di` by name — those don't exist until Terraform
creates them. See `../DEPLOYMENT.md` for the exact combined sequence.

## Running it

```bash
schemachange deploy --config-folder .
```

Dry-run first if you want to see what would apply without running it:
```bash
schemachange deploy --config-folder . --dry-run
```

## Verifying

```sql
SELECT VERSION, DESCRIPTION, SCRIPT, STATUS, INSTALLED_ON
FROM O2C_DB.SCHEMACHANGE.CHANGE_HISTORY
ORDER BY INSTALLED_ON DESC;
```

## Adding a new migration later

New table/task → new `V<next-in-that-stage>.<n>__description.sql`, e.g. a
second `06_case_actions` table becomes `V9.1__...`. New/changed procedure →
edit the matching `R__sp_*.sql` file directly (or add a new `R__` file for a
genuinely new procedure) — schemachange picks up the checksum change on the
next deploy automatically, no renaming needed.
