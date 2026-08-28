# Deploying to a new Snowflake account

Two tools, run in this order. Full explanation of what each owns and why is
in `terraform/README.md` and `migrations/README.md` — this file is just the
command sequence.

```
terraform apply        # warehouse, database + schemas, O2C_APP role, secrets/integrations
        │
        ▼
schemachange deploy    # tables, procedures, tasks, seed/config data
        │
        ▼
manual: Gmail OAuth consent + one clean CALL of each task's procedure
```

## 0. One-time tooling setup (per machine, not per account)

```bash
pip install schemachange
# snow CLI — if not already installed, see Snowflake CLI docs
```

## 1. One-time per new account

**a. Gmail OAuth consent — cannot be scripted, do this first.** Produces the
three values `terraform.tfvars` needs (`gmail_client_id`,
`gmail_client_secret`, `gmail_refresh_token`). Full steps in
`terraform/README.md` item 2 — briefly: enable the Gmail API in the target
GCP project, create a Desktop OAuth client, add the mailbox as a test user
with the `gmail.readonly` scope, then run `scripts/gmail_oauth_setup.py`
**locally**, sign in, and copy the three printed values.

**b. Key-pair auth for Terraform.** `terraform/README.md` item 3 — generate
a keypair, assign the public half to the deployer user with `ALTER USER ...
SET RSA_PUBLIC_KEY`, keep the private half off git (already gitignored).

**c. Snow CLI connection for schemachange.**
```bash
snow connection add newacct
export SNOWFLAKE_DEFAULT_CONNECTION_NAME=newacct
```

## 2. Terraform

```bash
cd terraform
cp 00_terraform.tfvars.example terraform.tfvars
# fill in terraform.tfvars: account info, the Gmail values from step 1a,
# Azure DI endpoint/key, the runtime service user name
terraform init
terraform plan     # read it before applying, especially on the first run
                    # on a new account — see terraform/README.md item 1
                    # on why the provider pin matters here
terraform apply
cd ..
```

## 3. schemachange

```bash
schemachange deploy --config-folder .
```

Applies `migrations/V*` (once each, in order) then `migrations/R__*` (every
run, procedures only). See `migrations/README.md` for what's in each file.

## 4. Manual verification — do this before trusting the schedule

Tasks are created `SUSPENDED` by default and each `Task_*.sql` file
`RESUME`s itself, but a clean deploy isn't the same as a clean run. Call
each pipeline entry point by hand once and check for errors before relying
on the schedule:

```sql
CALL CASHAPP.SP_CAPTURE_ALL();          -- Lockbox + EDI + Email capture
CALL CASHAPP.SP_CASE_PROMOTION();       -- promotes captures to cases
CALL CASHAPP.SP_MATCHING();             -- matches promoted cases
CALL CASHAPP.SP_POSTGUARD(...);         -- see 05_postguard/Procedure_Postguard.sql for args
```

Then check task state and history:
```sql
SHOW TASKS IN SCHEMA CASHAPP;
SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
  SCHEDULED_TIME_RANGE_START => DATEADD('hour', -6, CURRENT_TIMESTAMP())
))
ORDER BY SCHEDULED_TIME DESC;
```

Gmail's refresh token expires in 7 days while the OAuth consent screen
stays in "Testing" publish status (see `terraform/README.md` item 2) — if
`SP_CAPTURE_ALL`'s email leg starts failing a week after a clean first run,
that's almost certainly it, not a deploy problem.

## What this replaces

- Manually opening and running ~30 `.sql` files in the right order by hand.
- `10_copilot/deploy.sh`, which did the same thing schemachange now does,
  but only for `10_copilot/`'s 4 files. It still works standalone and
  nothing here deletes it, but `schemachange deploy` now covers that same
  ground as part of the full pipeline — no need to run both.

## What this does NOT fix

The credentials that were in `Email_Prerequisite/Email_capture_prereqs.sql`
(Gmail OAuth client secret + refresh token, an Azure DI key, a Groq key) are
still sitting in this repo's **git history** in plaintext, on whatever
commits touched that file. Moving new deployments onto Terraform variables
stops it from happening again going forward — it doesn't retroactively
scrub history. Rotate those specific credentials; treat them as already
compromised.
