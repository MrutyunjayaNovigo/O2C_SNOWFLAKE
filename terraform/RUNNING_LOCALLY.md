# Running Terraform locally

This repo's Terraform stack now runs from three places — your local machine,
the Codespace, and CI (`.github/workflows/deploy.yml`) — all sharing one
HCP Terraform remote state. This file is just the local-machine setup;
`terraform/README.md` covers what the stack owns and does.

## Prerequisites

**1. Terraform binary.** A working install already exists at:
```
C:\Users\mrutyunjaya.sahoo\terraform\terraform.exe
```
Add that folder to your `PATH` if you want to run `terraform` as a bare
command instead of the full path.

**2. HCP Terraform login.** State lives remotely (org
`snowflake-terraform-mj`, workspace `o2c-snowflake` — see the `cloud {}`
block in `01_versions.tf`). A credentials file is already in place at:
```
C:\Users\mrutyunjaya.sahoo\AppData\Roaming\terraform.d\credentials.tfrc.json
```
Nothing to do here unless that file goes missing or the token is rotated —
if so, its contents need to be:
```json
{
  "credentials": {
    "app.terraform.io": {
      "token": "<your HCP Terraform API token>"
    }
  }
}
```

**3. `terraform.tfvars`.** Local, gitignored, already filled in at
`terraform/terraform.tfvars`. `SNOWFLAKE_PRIVATE_KEY_PATH` points to
`../rsa_key.p8` — relative to the `terraform/` folder, since that's where
these commands run from, not the repo root.

## Running it

```bash
cd terraform
terraform plan     # read it before applying, always
terraform apply
```

Since state is shared now, this reflects the real, current state of the
account — no more "already exists" errors from a blank local state
colliding with what's actually in Snowflake.

## If you ever need to re-import something

If state and reality ever drift apart again (e.g. a lost Codespace's local
state, like what happened once already), re-attach existing Snowflake
objects with `terraform import <resource address> <id>` rather than
letting `apply` try to recreate them. The full set of import commands used
the last time this happened:

```bash
terraform import snowflake_account_role.o2c_app O2C_APP

terraform import snowflake_warehouse.o2c_wh O2C_WH

terraform import snowflake_database.o2c_db O2C_DB

terraform import snowflake_schema.master '"O2C_DB"."MASTER"'
terraform import snowflake_schema.cashapp '"O2C_DB"."CASHAPP"'
terraform import snowflake_schema.cashapp_authdb '"O2C_DB"."CASHAPP_AUTHDB"'

terraform import 'snowflake_grant_account_role.o2c_app_to_user["O2C_APP_SVC_USER"]' \
  '"O2C_APP"|USER|"O2C_APP_SVC_USER"'

terraform import snowflake_grant_privileges_to_account_role.o2c_app_warehouse_usage \
  '"O2C_APP"|false|false|USAGE|OnAccountObject|WAREHOUSE|"O2C_WH"'

terraform import snowflake_grant_privileges_to_account_role.o2c_app_database_usage \
  '"O2C_APP"|false|false|USAGE|OnAccountObject|DATABASE|"O2C_DB"'

terraform import snowflake_grant_privileges_to_account_role.o2c_app_cashapp_schema_usage \
  '"O2C_APP"|false|false|USAGE|OnSchema|OnSchema|"O2C_DB"."CASHAPP"'

terraform import snowflake_grant_privileges_to_account_role.o2c_app_cashapp_future_tables \
  '"O2C_APP"|false|false|INSERT,SELECT|OnSchemaObject|OnFuture|TABLES|InSchema|"O2C_DB"."CASHAPP"'

terraform import snowflake_network_rule.gmail_api '"O2C_DB"."CASHAPP"."NR_GMAIL_API"'
terraform import snowflake_network_rule.azure_di '"O2C_DB"."CASHAPP"."NR_AZURE_DI"'

terraform import snowflake_secret_with_generic_string.gmail_oauth \
  '"O2C_DB"."CASHAPP"."SEC_GMAIL_OAUTH"'
terraform import snowflake_secret_with_generic_string.azure_di \
  '"O2C_DB"."CASHAPP"."SEC_AZURE_DI_KEY"'
```

Import IDs are literal — the exact casing/format has to match what the
provider actually stored (e.g. schema names are case-sensitive quoted
identifiers; grant resources use the same `|`-delimited ID shown in their
`id` attribute after a successful create). If an import fails with "object
does not exist", that's usually a casing mismatch, not a real absence —
check `SHOW` output in Snowsight for the object's actual name before
assuming it needs to be created fresh.

**Always run `terraform plan` after a batch of imports, before applying.**
That's what caught the real bug last time: the schemas were missing
`is_transient = false`, which without it looked like a no-op but was
actually forcing Terraform to destroy and recreate all three schemas on
the next apply — harmless while they're empty, catastrophic once
schemachange has populated them with real tables.
