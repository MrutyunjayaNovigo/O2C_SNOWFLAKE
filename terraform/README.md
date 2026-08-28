# Terraform — account-level infrastructure

## What this owns, and what it doesn't

This stack creates the objects that should exist **once per account** and
that either hold a credential or sit at the account/security boundary:

- `O2C_WH` warehouse
- `O2C_DB` database + its three schemas (`master`, `cashapp`, `cashapp_authdb`)
- `O2C_APP` role — created here because nothing in the SQL tree ever created
  it, despite every `GRANT ... TO ROLE O2C_APP` statement in `migrations/`
  assuming it exists. That gap is what originally prompted this file.
- Warehouse/database/schema `USAGE` grants and the `CASHAPP` future-tables
  grant for `O2C_APP`
- The Gmail / Azure Document Intelligence network rules, secrets, and
  external access integrations that `R__sp_email_capture.sql` depends on

It does **not** own tables, stored procedures, tasks, or per-table grants —
those change often, are pure SQL, and belong to `../migrations/` (run by
schemachange). See `../migrations/README.md` for that half and
`../DEPLOYMENT.md` for the combined run order. Full boundary rationale is in
`../migrations/README.md`, "Why the role split looks like this."

## Why the files are numbered

Unlike `../migrations/`, where the `V`/`R` prefixes control real execution
order, Terraform loads every `.tf` file in the directory together and
resolves order itself from the resource dependency graph (`depends_on`,
implicit references) — renaming these files changes nothing about what
Terraform actually does. The `01_`–`08_` prefixes here are purely so the
folder reads top-to-bottom in the order things conceptually get created:
provider setup, then compute, then the database/schemas it depends on, then
the role and grants that need both, then the secrets that need the schema,
then outputs last. `00_terraform.tfvars.example` sorts first because it's
the one file you touch before running anything.

## What's in each file

| File | Creates |
|---|---|
| `00_terraform.tfvars.example` | Template — copy to `terraform.tfvars`, fill in, never commit the copy |
| `01_versions.tf` | Provider pin, backend |
| `02_providers.tf` | Snowflake provider auth (key-pair) |
| `03_variables.tf` | Every input variable |
| `04_warehouse.tf` | `O2C_WH` |
| `05_database.tf` | `O2C_DB` + its 3 schemas |
| `06_roles_and_grants.tf` | `O2C_APP` role, warehouse/database/schema grants, future-tables grant |
| `07_network_and_secrets.tf` | Gmail/Azure DI network rules, secrets, external access integrations |
| `08_outputs.tf` | Names to reference from `EXTERNAL_ACCESS_INTEGRATIONS = (...)` clauses |

## Before you run this

**Nothing has been applied.** These are unexecuted `.tf` files — `terraform
init`/`plan`/`apply` were deliberately not run. Read this whole section
before the first apply.

**1. The provider pin is the biggest risk on a new account.** `01_versions.tf`
pins `snowflakedb/snowflake` to `>= 1.0.0, < 2.0.0`. This provider has
renamed core resources across versions before — `snowflake_role` became
`snowflake_account_role`, and the entire grant resource family
(`snowflake_grant_privileges_to_account_role`, the `on_account_object` /
`on_schema_object { future { ... } }` blocks used throughout these files)
was redesigned in the "new grants" rollout. Before your first `terraform
apply` on a fresh account:
```
terraform init
terraform plan
```
and read the plan output carefully. If `plan` errors on an unrecognized
argument or block, check the resource's page on the Terraform Registry for
the exact pinned version — the grant resources are the most likely place
for a mismatch.

**2. Gmail OAuth cannot be scripted.** `GMAIL_CLIENT_ID` /
`GMAIL_CLIENT_SECRET` / `GMAIL_REFRESH_TOKEN` (used in
`07_network_and_secrets.tf`) come from an interactive browser consent flow,
same as the original `Email_Prerequisite/Email_capture_prereqs.sql`
documented:
1. In the target GCP project: enable the Gmail API.
2. Create an OAuth client ID (Desktop app type), download the client JSON.
3. OAuth consent screen → add the mailbox as a test user, scope
   `gmail.readonly`.
4. Run `scripts/gmail_oauth_setup.py` **locally, not in Snowflake/CI** with
   the downloaded client JSON — it opens a browser, you consent, it prints
   `client_id` / `client_secret` / `refresh_token`.
5. Put those three values in `terraform.tfvars` (or `TF_VAR_gmail_*` env
   vars) — never in a committed file.

While the consent screen stays in "Testing" publish status, this refresh
token expires after 7 days and needs re-running step 4 periodically — same
caveat the original file called out, unchanged by moving it into Terraform.

**3. Key-pair auth setup (one-time per account):**
```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out tf_deployer_key.p8 -nocrypt
openssl rsa -in tf_deployer_key.p8 -pubout -out tf_deployer_key.pub
```
Assign the public key to the Terraform deployer user:
```sql
ALTER USER TF_DEPLOYER SET RSA_PUBLIC_KEY = '<contents of tf_deployer_key.pub, minus header/footer lines>';
```
Point `SNOWFLAKE_PRIVATE_KEY_PATH` in `terraform.tfvars` at
`tf_deployer_key.p8`. Never commit the `.p8` file — `.gitignore` at the repo
root already excludes `*.p8`.

**4. Copy the tfvars template and fill it in:**
```bash
cp 00_terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — it's gitignored, safe to put real values in
```

**5. State holds secrets in plaintext.** Terraform state includes the
resolved value of every argument, including the Gmail/Azure secrets above —
`sensitive = true` on a variable only masks console/plan output, it does
**not** encrypt state. Local state (the default here — see the commented-out
`backend` block in `01_versions.tf`) is fine for one operator bootstrapping one
account by hand. The moment more than one person or a CI pipeline touches
this, switch to a remote backend with encryption at rest and access control
before the first apply — moving existing local state to a new backend later
is extra, avoidable work (`terraform init -migrate-state`).

## Running it

```bash
cd terraform
terraform init
terraform plan   # read it — this is the point of the exercise
terraform apply
```

Single pass. `05_database.tf` creates the three schemas Terraform needs
before it can create the Gmail/Azure network rule, secret, and integration
inside `CASHAPP` — see the comment at the top of `05_database.tf` for why
schemas are the one exception to the "Terraform doesn't own schema content"
rule.
`schemachange deploy` (see `../migrations/README.md`) runs after this, not
before — its `CREATE SCHEMA IF NOT EXISTS` statements land on schemas that
already exist and no-op harmlessly.

## Verifying

```sql
SHOW WAREHOUSES LIKE 'O2C_WH';
SHOW DATABASES LIKE 'O2C_DB';
SHOW ROLES LIKE 'O2C_APP';
SHOW INTEGRATIONS LIKE 'EAI_%';
DESCRIBE EXTERNAL ACCESS INTEGRATION EAI_GMAIL_API;
```

## Tearing down

`terraform destroy` will drop the warehouse, database (and everything inside
it — tables included, since they live inside the database Terraform owns),
role, and integrations. There is no soft option here beyond Snowflake's own
Time Travel/undrop window — treat `destroy` on a real account the way you'd
treat `DROP DATABASE`, because that's exactly what it does.
