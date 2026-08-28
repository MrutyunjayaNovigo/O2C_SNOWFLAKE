output "warehouse_name" {
  value = snowflake_warehouse.o2c_wh.name
}

output "database_name" {
  value = snowflake_database.o2c_db.name
}

output "runtime_role_name" {
  value = snowflake_account_role.o2c_app.name
}

output "external_access_integrations" {
  description = "Names to reference in a procedure's EXTERNAL_ACCESS_INTEGRATIONS = (...) clause — matches what R__sp_email_capture.sql expects."
  value = {
    gmail    = snowflake_external_access_integration.gmail_api.name
    azure_di = snowflake_external_access_integration.azure_di.name
  }
}
