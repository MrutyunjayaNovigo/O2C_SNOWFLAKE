# Replaces Email_Prerequisite/Email_capture_prereqs.sql sections 1-3. That
# file had the Gmail OAuth client secret + refresh token, an Azure DI key,
# and a Groq API key hardcoded as plaintext SQL literals, committed to git.
# Everything here comes from Terraform variables instead — sourced from a
# gitignored terraform.tfvars or TF_VAR_* env vars, never committed. See
# terraform/README.md for why this doesn't retroactively fix the exposure
# already in git history (it doesn't — those specific credentials still need
# rotating).
#
# These objects live inside O2C_DB.cashapp even though Terraform, not
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
  schema   = snowflake_schema.cashapp.name

  mode       = "EGRESS"
  type       = "HOST_PORT"
  value_list = ["gmail.googleapis.com:443", "oauth2.googleapis.com:443"]

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_secret_with_generic_string" "gmail_oauth" {
  name     = "SEC_GMAIL_OAUTH"
  database = snowflake_database.o2c_db.name
  schema   = snowflake_schema.cashapp.name

  secret_string = jsonencode({
    client_id     = var.GMAIL_CLIENT_ID
    client_secret = var.GMAIL_CLIENT_SECRET
    refresh_token = var.GMAIL_REFRESH_TOKEN
  })

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_external_access_integration" "gmail_api" {
  name    = "EAI_GMAIL_API"
  enabled = true

  allowed_network_rules = ["\"${snowflake_database.o2c_db.name}\".\"${snowflake_schema.cashapp.name}\".\"${snowflake_network_rule.gmail_api.name}\""]

  allowed_authentication_secrets {
    secrets = ["\"${snowflake_database.o2c_db.name}\".\"${snowflake_schema.cashapp.name}\".\"${snowflake_secret_with_generic_string.gmail_oauth.name}\""]
  }
}

# ── 2. Azure Document Intelligence egress ───────────────────────────────────

resource "snowflake_network_rule" "azure_di" {
  name     = "NR_AZURE_DI"
  database = snowflake_database.o2c_db.name
  schema   = snowflake_schema.cashapp.name

  mode       = "EGRESS"
  type       = "HOST_PORT"
  value_list = ["${var.AZURE_DI_ENDPOINT_HOST}:443"]

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_secret_with_generic_string" "azure_di" {
  name          = "SEC_AZURE_DI_KEY"
  database      = snowflake_database.o2c_db.name
  schema        = snowflake_schema.cashapp.name
  secret_string = var.AZURE_DI_API_KEY

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_external_access_integration" "azure_di" {
  name    = "EAI_AZURE_DI"
  enabled = true

  allowed_network_rules = ["\"${snowflake_database.o2c_db.name}\".\"${snowflake_schema.cashapp.name}\".\"${snowflake_network_rule.azure_di.name}\""]

  allowed_authentication_secrets {
    secrets = ["\"${snowflake_database.o2c_db.name}\".\"${snowflake_schema.cashapp.name}\".\"${snowflake_secret_with_generic_string.azure_di.name}\""]
  }
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
  schema   = snowflake_schema.cashapp.name

  mode       = "EGRESS"
  type       = "HOST_PORT"
  value_list = ["api.groq.com:443"]

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_secret_with_generic_string" "llm_api_key" {
  count         = var.create_unused_llm_integration ? 1 : 0
  name          = "SEC_LLM_API_KEY"
  database      = snowflake_database.o2c_db.name
  schema        = snowflake_schema.cashapp.name
  secret_string = var.GROQ_API_KEY

  depends_on = [snowflake_schema.cashapp]
}

resource "snowflake_external_access_integration" "llm_api" {
  count   = var.create_unused_llm_integration ? 1 : 0
  name    = "EAI_LLM_API"
  enabled = true

  allowed_network_rules = ["\"${snowflake_database.o2c_db.name}\".\"${snowflake_schema.cashapp.name}\".\"${snowflake_network_rule.llm_api[0].name}\""]

  allowed_authentication_secrets {
    secrets = ["\"${snowflake_database.o2c_db.name}\".\"${snowflake_schema.cashapp.name}\".\"${snowflake_secret_with_generic_string.llm_api_key[0].name}\""]
  }
}
