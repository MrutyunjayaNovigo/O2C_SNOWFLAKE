# The database is an empty shell plus its three schemas — everything INSIDE
# a schema (tables, procs, tasks) still belongs to schemachange.
#
# Schemas themselves are a deliberate exception to the "Terraform = infra,
# schemachange = schema content" split described in migrations/README.md:
# they're created here, not in migrations/V1.1, because
# 07_network_and_secrets.tf needs CASHAPP to exist to create a network
# rule/secret/integration inside it, and Terraform runs before schemachange
# (see the top-level DEPLOYMENT.md order). Creating schemas here breaks that
# circular dependency; migrations/V1.1's own `CREATE SCHEMA IF NOT EXISTS`
# statements stay in place as a no-op safety net (and so the migration file
# still reads as the complete picture on its own).

resource "snowflake_database" "o2c_db" {
  name    = var.database_name
  comment = "Cash Clear O2C — master (SAP replica), cashapp (hybrid/OLTP), cashapp_authdb (hybrid/OLTP)."
}

resource "snowflake_schema" "master" {
  database = snowflake_database.o2c_db.name
  name     = "MASTER"
  comment  = "SAP replica, read-only ETL. Standard tables, no HYBRID."
}

resource "snowflake_schema" "cashapp" {
  database = snowflake_database.o2c_db.name
  name     = "CASHAPP"
  comment  = "Transactional application schema. HYBRID tables, OLTP workload."
}

resource "snowflake_schema" "cashapp_authdb" {
  database = snowflake_database.o2c_db.name
  name     = "CASHAPP_AUTHDB"
  comment  = "Auth schema. HYBRID tables, OLTP workload."
}
