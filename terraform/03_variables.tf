# ============================================================
# Connection
# ============================================================

variable "SNOWFLAKE_ORGANIZATION_NAME" {
  description = "Snowflake organization name (Admin > Accounts in Snowsight)."
  type        = string
}

variable "SNOWFLAKE_ACCOUNT_NAME" {
  description = "Snowflake account name (not the locator) — the account this stack bootstraps."
  type        = string
}

variable "SNOWFLAKE_USER" {
  description = "User Terraform authenticates as. Needs ACCOUNTADMIN or a role with CREATE WAREHOUSE/DATABASE/ROLE/INTEGRATION/SECRET at the account level."
  type        = string
}

variable "snowflake_role" {
  description = "Role Terraform assumes for every resource in this stack."
  type        = string
  default     = "ACCOUNTADMIN"
}

variable "SNOWFLAKE_PRIVATE_KEY_PATH" {
  description = "Path to the PEM private key for key-pair auth (see terraform/README.md setup). Empty string disables key-pair auth (not recommended)."
  type        = string
  default     = ""
}

variable "snowflake_private_key_passphrase" {
  description = "Passphrase for the private key, if it's encrypted."
  type        = string
  default     = ""
  sensitive   = true
}

# ============================================================
# Warehouse / database
# ============================================================

variable "warehouse_name" {
  description = "Matches the literal name migrations/*.sql hardcodes (USE WAREHOUSE ...) — changing this requires updating migrations/ too."
  type        = string
  default     = "O2C_WH"
}

variable "warehouse_size" {
  type    = string
  default = "XSMALL"
}

variable "database_name" {
  description = "Matches the literal name migrations/*.sql hardcodes (USE DATABASE ...) — changing this requires updating migrations/ too."
  type        = string
  default     = "O2C_DB"
}

# ============================================================
# Runtime role
# ============================================================

variable "runtime_role_name" {
  description = "The role every stored proc/task in migrations/ grants to (O2C_APP throughout the repo). Deliberately cannot CREATE in the database — see 06_roles_and_grants.tf."
  type        = string
  default     = "O2C_APP"
}

variable "RUNTIME_USERS" {
  description = "Snowflake users O2C_APP is granted to — the service user tasks run as, plus any human operators who need it. At least one entry required or tasks/procs have no one to run as."
  type        = list(string)
}

# ============================================================
# Email capture — Gmail OAuth (see terraform/README.md item 1 for the
# one-time browser consent step that produces these three values)
# ============================================================

variable "GMAIL_CLIENT_ID" {
  type = string
}

variable "GMAIL_CLIENT_SECRET" {
  type      = string
  sensitive = true
}

variable "GMAIL_REFRESH_TOKEN" {
  type      = string
  sensitive = true
}

# ============================================================
# Email capture — Azure Document Intelligence
# ============================================================

variable "AZURE_DI_ENDPOINT_HOST" {
  description = "Host only, e.g. yourresource.cognitiveservices.azure.com (no scheme, no path — used as a HOST_PORT network rule value)."
  type        = string
}

variable "AZURE_DI_API_KEY" {
  type      = string
  sensitive = true
}

# ============================================================
# Optional — the LLM integration the source repo left in place but unused
# (sp_capture_email calls SNOWFLAKE.CORTEX.COMPLETE instead). Off by default;
# flip on only if some future procedure actually needs external LLM egress.
# ============================================================

variable "create_unused_llm_integration" {
  type    = bool
  default = false
}

variable "GROQ_API_KEY" {
  type      = string
  sensitive = true
  default   = ""
}
