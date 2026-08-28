-- ============================================================
-- Email capture prerequisites — schema-owned half only.
--
-- The original Email_Prerequisite/Email_capture_prereqs.sql mixed two kinds
-- of setup together: account security perimeter (network rule, secret,
-- external access integration — anything holding a credential) and schema
-- contents (an internal stage, seed config rows). This migration is only
-- the second half. The network rule / secret / external access integration
-- are created by Terraform instead — see terraform/07_network_and_secrets.tf —
-- because they hold live credentials that must come from tfvars/env vars,
-- never from a committed SQL literal (the original file had the Gmail OAuth
-- secret, an Azure DI key, and a Groq key hardcoded in plaintext — do not
-- reproduce that pattern; those specific credentials are already compromised
-- via git history and should be rotated regardless of this migration).
--
-- Run `terraform apply` before this migration — sp_capture_email's
-- EXTERNAL_ACCESS_INTEGRATIONS clause references eai_gmail_api and
-- eai_azure_di by name, which only exist once Terraform has created them.
--
-- One-time manual step this migration cannot do: the Gmail OAuth refresh
-- token that Terraform writes into cashapp.sec_gmail_oauth has to come from
-- an interactive browser consent flow (scripts/gmail_oauth_setup.py, run
-- locally, NOT in Snowflake/CI) before `terraform apply` can succeed. See
-- DEPLOYMENT.md.
-- ============================================================

USE WAREHOUSE O2C_WH;
USE DATABASE O2C_DB;
USE SCHEMA cashapp;

-- ── Attachment storage — Snowflake-internal stage ───────────────────────────
-- DIRECTORY = TRUE enables the stage's directory table, so landed files are
-- browsable via `SELECT * FROM DIRECTORY(@cashapp.stg_email_attachments)`.
CREATE STAGE IF NOT EXISTS cashapp.stg_email_attachments
  DIRECTORY = (ENABLE = TRUE);

-- ── Runtime config sp_capture_email reads (global, company_code NULL) ───────
INSERT INTO cashapp.system_config (config_id, company_code, config_key, config_value, description)
SELECT UUID_STRING(), NULL, 'email_confidence_threshold', '0.75',
       'Email captures below this overall extraction confidence are discarded, never written'
WHERE NOT EXISTS (
  SELECT 1 FROM cashapp.system_config WHERE company_code IS NULL AND config_key = 'email_confidence_threshold'
);

INSERT INTO cashapp.system_config (config_id, company_code, config_key, config_value, description)
SELECT UUID_STRING(), NULL, 'email_capture_batch_size', '100',
       'Max emails fetched per sp_capture_email run'
WHERE NOT EXISTS (
  SELECT 1 FROM cashapp.system_config WHERE company_code IS NULL AND config_key = 'email_capture_batch_size'
);

INSERT INTO cashapp.system_config (config_id, company_code, config_key, config_value, description)
SELECT UUID_STRING(), NULL, 'email_capture_max_retries', '5',
       'Per-message retry ceiling before permanent skip'
WHERE NOT EXISTS (
  SELECT 1 FROM cashapp.system_config WHERE company_code IS NULL AND config_key = 'email_capture_max_retries'
);
