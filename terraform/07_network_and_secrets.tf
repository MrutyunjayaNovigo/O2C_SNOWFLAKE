# Replaces Email_Prerequisite/Email_capture_prereqs.sql sections 1-3. That
# file had the Gmail OAuth client secret + refresh token, an Azure DI key,
# and a Groq API key hardcoded as plaintext SQL literals, committed to git.
# Everything here comes from Terraform variables instead — sourced from a
# gitignored terraform.tfvars or TF_VAR_* env vars, never committed. See
# terraform/README.md for why this doesn't retroactively fix the exposure
# already in git history (it doesn't — those specific credentials still need
# rotating).
#
# These objects live inside O2C_DB.CASHAPP even though Terraform, not
# schemachange, owns them — a network rule/secret/integration is part of the
# account's security perimeter (anything that reaches outside Snowflake or
# holds a credential), not app schema content, regardless of which database
# namespace it's registered under.

# ── 1. Gmail API egress (NOT IMAP — Snowflake's egress rules only allow
#      ports 80/443; see terraform/README.md item 1 for the one-time browser
#      OAuth consent step that produces the three var values below) ────────

resource "snowflake_network_rule" "gmail_api" {
  name     = "NR_GMAIL_API"
  database = snowflake_database.o2c_db.name
  schema   = "CASHAPP"

  mode       = "EGRESS"
  type       = "HOST_PORT"
  value_list = ["gmail.googleapis.com:443", "oauth2.googleapis.com:443"]

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_secret_with_generic_string" "gmail_oauth" {
  name     = "SEC_GMAIL_OAUTH"
  database = snowflake_database.o2c_db.name
  schema   = "CASHAPP"

  secret_string = jsonencode({
    client_id     = var.gmail_client_id
    client_secret = var.gmail_client_secret
    refresh_token = var.gmail_refresh_token
  })

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_external_access_integration" "gmail_api" {
  name    = "EAI_GMAIL_API"
  enabled = true

  allowed_network_rules          = ["\"${snowflake_database.o2c_db.name}\".\"CASHAPP\".\"${snowflake_network_rule.gmail_api.name}\""]
  allowed_authentication_secrets = ["\"${snowflake_database.o2c_db.name}\".\"CASHAPP\".\"${snowflake_secret_with_generic_string.gmail_oauth.name}\""]
}

# ── 2. Azure Document Intelligence egress ───────────────────────────────────

resource "snowflake_network_rule" "azure_di" {
  name     = "NR_AZURE_DI"
  database = snowflake_database.o2c_db.name
  schema   = "CASHAPP"

  mode       = "EGRESS"
  type       = "HOST_PORT"
  value_list = ["${var.azure_di_endpoint_host}:443"]

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_secret_with_generic_string" "azure_di" {
  name          = "SEC_AZURE_DI_KEY"
  database      = snowflake_database.o2c_db.name
  schema        = "CASHAPP"
  secret_string = var.azure_di_api_key

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_external_access_integration" "azure_di" {
  name    = "EAI_AZURE_DI"
  enabled = true

  allowed_network_rules          = ["\"${snowflake_database.o2c_db.name}\".\"CASHAPP\".\"${snowflake_network_rule.azure_di.name}\""]
  allowed_authentication_secrets = ["\"${snowflake_database.o2c_db.name}\".\"CASHAPP\".\"${snowflake_secret_with_generic_string.azure_di.name}\""]
}

# ── 3. External LLM API egress — off by default, matches the source file's
#      own "UNUSED, kept for reference only" note. sp_capture_email calls
#      SNOWFLAKE.CORTEX.COMPLETE instead; nothing currently attaches this
#      integration. Flip create_unused_llm_integration = true only once some
#      procedure actually declares EXTERNAL_ACCESS_INTEGRATIONS = (eai_llm_api).

resource "snowflake_network_rule" "llm_api" {
  count    = var.create_unused_llm_integration ? 1 : 0
  name     = "NR_LLM_API"
  database = snowflake_database.o2c_db.name
  schema   = "CASHAPP"

  mode       = "EGRESS"
  type       = "HOST_PORT"
  value_list = ["api.groq.com:443"]

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_secret_with_generic_string" "llm_api_key" {
  count         = var.create_unused_llm_integration ? 1 : 0
  name          = "SEC_LLM_API_KEY"
  database      = snowflake_database.o2c_db.name
  schema        = "CASHAPP"
  secret_string = var.groq_api_key

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_external_access_integration" "llm_api" {
  count   = var.create_unused_llm_integration ? 1 : 0
  name    = "EAI_LLM_API"
  enabled = true

  allowed_network_rules          = ["\"${snowflake_database.o2c_db.name}\".\"CASHAPP\".\"${snowflake_network_rule.llm_api[0].name}\""]
  allowed_authentication_secrets = ["\"${snowflake_database.o2c_db.name}\".\"CASHAPP\".\"${snowflake_secret_with_generic_string.llm_api_key[0].name}\""]
}
