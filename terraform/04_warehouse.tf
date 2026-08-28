# Mirrors 01_initial_script/Create_Script.sql's original CREATE WAREHOUSE —
# this is now the source of truth for it; migrations/V1.1 only USEs it.

resource "snowflake_warehouse" "o2c_wh" {
  name           = var.warehouse_name
  warehouse_size = var.warehouse_size
  auto_suspend   = 60
  auto_resume    = true
  comment        = "Cash Clear O2C — shared batch warehouse for capture/promotion/matching tasks and interactive procedure calls."
}
