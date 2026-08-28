# O2C_APP itself — every migrations/*.sql GRANT statement targets this role,
# but nothing in the repo ever created it (confirmed: grepped the whole
# tree). It's been tribal knowledge, set up by hand once per account. This
# is that missing step, made explicit.
#
# Deliberately NOT given CREATE TABLE/PROCEDURE/TASK on the database — every
# migrations/*.sql file's own comments confirm this boundary already exists
# ("O2C_APP does not have CREATE TABLE on this schema" appears in
# 08_disputes, 09_outreach, 10_copilot). This role runs the app; it doesn't
# own the schema.
resource "snowflake_account_role" "o2c_app" {
  name    = var.runtime_role_name
  comment = "Runtime role for Cash Clear tasks/procedures. Cannot CREATE in O2C_DB by design — schema ownership stays with the deploying role (ACCOUNTADMIN)."
}

resource "snowflake_grant_account_role" "o2c_app_to_user" {
  for_each  = toset(var.runtime_users)
  role_name = snowflake_account_role.o2c_app.name
  user_name = each.value
}

resource "snowflake_grant_privileges_to_account_role" "o2c_app_warehouse_usage" {
  account_role_name = snowflake_account_role.o2c_app.name
  privileges         = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.o2c_wh.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "o2c_app_database_usage" {
  account_role_name = snowflake_account_role.o2c_app.name
  privileges         = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.o2c_db.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "o2c_app_cashapp_schema_usage" {
  account_role_name = snowflake_account_role.o2c_app.name
  privileges         = ["USAGE"]
  on_schema_object {
    object_type = "SCHEMA"
    object_name = "\"${snowflake_database.o2c_db.name}\".\"${snowflake_schema.cashapp.name}\""
  }
}

# Narrowed from the existing account's future grant (confirmed via
# 10_copilot/README.md — it currently hands O2C_APP SELECT/INSERT/UPDATE/
# DELETE on every new CASHAPP table, which is why that folder needs a
# REVOKE UPDATE, DELETE right after every CREATE TABLE just to make an
# audit trail tamper-evident). SELECT + INSERT is enough for every table
# most of the pipeline writes append-only. Tables that legitimately need
# UPDATE/DELETE (disputes, outreach, system_config) already grant it
# explicitly and narrowly in their own migration file
# (migrations/V6.1, V7.1) — same pattern the source repo already used,
# just made the default instead of a per-table bolt-on.
resource "snowflake_grant_privileges_to_account_role" "o2c_app_cashapp_future_tables" {
  account_role_name = snowflake_account_role.o2c_app.name
  privileges         = ["SELECT", "INSERT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema           = "\"${snowflake_database.o2c_db.name}\".\"${snowflake_schema.cashapp.name}\""
    }
  }
}
