-- Email capture prerequisites: network egress, secrets, and storage setup
-- Co-authored with CoCo
-- ============================================================
-- DEPRECATED — sections 1-3 (network rules, secrets, external access
-- integrations) are now owned by Terraform: see
-- terraform/07_network_and_secrets.tf, with the one-time Gmail OAuth
-- consent steps documented in terraform/README.md. Do NOT fill in real
-- secret values below and run this file — use `terraform apply` with
-- terraform/terraform.tfvars instead. Kept here only as historical
-- reference for sections 4-5 (attachment stage, runtime config), which
-- Terraform does not manage.
-- ============================================================
-- Prerequisites for cashapp.sp_capture_email (see email_capture_procedure.sql)
--
-- Lockbox and EDI never needed any of this — they only read tables Snowflake
-- already has (master."FLB2" etc). Email is the first capture channel that
-- has to reach LIVE external services from inside Snowflake: the mailbox via
-- the Gmail API (not IMAP — see item 1), an external LLM API, and Azure
-- Document Intelligence. This file is the network egress + secrets +
-- attachment-storage plumbing that makes that possible. Run once per
-- environment, before creating the procedure.
--
-- Values below are placeholders — fill in from app/core/config.py / .env
-- locally before running, and NEVER commit the real values here. This file
-- is a template; the actual secrets belong only in your local .env / vault.
-- ============================================================

USE WAREHOUSE O2C_WH;
USE DATABASE O2C_DB;
USE SCHEMA cashapp;

-- ── 1. Gmail API egress (NOT IMAP) ──────────────────────────────────────────
-- CONFIRMED: Snowflake's HOST_PORT egress network rules only allow ports
-- 80/443 — raw IMAP (port 993) is rejected outright, no workaround. Mail is
-- fetched via the Gmail REST API (gmail.googleapis.com, HTTPS/443) instead —
-- same mailbox, different transport. See email_capture_procedure.sql's
-- _fetch_emails/_get_message for the Gmail API port of what
-- app/core/email_client.py used to do over IMAP.
--
-- This needs a one-time OAuth2 setup that CANNOT happen inside Snowflake —
-- it requires an interactive browser consent step:
--   1. In GCP project cfo-automation-496704: APIs & Services > Library >
--      enable "Gmail API".
--   2. APIs & Services > Credentials > Create Credentials > OAuth client ID
--      > Application type "Desktop app". Download the client JSON.
--   3. APIs & Services > OAuth consent screen > User type "External" (this
--      is a plain @gmail.com account, not Workspace, so "Internal" isn't
--      available) > add cashapplication2310@gmail.com as a test user >
--      scope https://www.googleapis.com/auth/gmail.readonly.
--   4. Run scripts/gmail_oauth_setup.py locally (NOT in Snowflake) with the
--      downloaded client JSON — it opens a browser, you sign in as
--      cashapplication2310@gmail.com and consent, and it prints
--      client_id / client_secret / refresh_token.
--   5. Paste those three values into the SECRET_STRING below.
--
-- GOTCHA: while the OAuth consent screen stays in "Testing" publish status,
-- refresh tokens for gmail.readonly (a sensitive scope) expire after 7 days
-- — you'll need to re-run step 4 periodically until this is either moved to
-- "In production" or goes through Google's app verification. For a 5-minute
-- scheduled task this WILL eventually break silently if left on Testing —
-- treat this as a known follow-up, not a one-and-done setup.

CREATE OR REPLACE NETWORK RULE cashapp.nr_gmail_api
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('gmail.googleapis.com:443', 'oauth2.googleapis.com:443');

CREATE OR REPLACE SECRET cashapp.sec_gmail_oauth
  TYPE = GENERIC_STRING
  SECRET_STRING = '{"client_id":"<GMAIL_OAUTH_CLIENT_ID>","client_secret":"<GMAIL_OAUTH_CLIENT_SECRET>","refresh_token":"<GMAIL_OAUTH_REFRESH_TOKEN>"}';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION eai_gmail_api
  ALLOWED_NETWORK_RULES = (cashapp.nr_gmail_api)
  ALLOWED_AUTHENTICATION_SECRETS = (cashapp.sec_gmail_oauth)
  ENABLED = TRUE;

-- ── 2. External LLM API egress — UNUSED, kept for reference only ───────────
-- app/core/llm.py (cash-app-api) routes via LiteLLM using settings.LLM_MODEL
-- = "groq/llama-3.1-8b-instant". sp_capture_email deliberately does NOT use
-- this — it calls SNOWFLAKE.CORTEX.COMPLETE (llama3.1-70b) instead, an
-- intentional choice to keep LLM inference on Snowflake credits rather than
-- a separate external API. eai_llm_api is not attached to sp_capture_email's
-- EXTERNAL_ACCESS_INTEGRATIONS (see Procedure_Email.sql), so this block is
-- currently dead infrastructure. Left in place in case a future capture
-- procedure needs external LLM egress; safe to drop otherwise:
--   DROP EXTERNAL ACCESS INTEGRATION IF EXISTS eai_llm_api;
--   DROP SECRET IF EXISTS cashapp.sec_llm_api_key;
--   DROP NETWORK RULE IF EXISTS cashapp.nr_llm_api;

CREATE OR REPLACE NETWORK RULE cashapp.nr_llm_api
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('api.groq.com:443');

CREATE OR REPLACE SECRET cashapp.sec_llm_api_key
  TYPE = GENERIC_STRING
  SECRET_STRING = '<GROQ_API_KEY>';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION eai_llm_api
  ALLOWED_NETWORK_RULES = (cashapp.nr_llm_api)
  ALLOWED_AUTHENTICATION_SECRETS = (cashapp.sec_llm_api_key)
  ENABLED = TRUE;

-- ── 3. Azure Document Intelligence egress ───────────────────────────────────
-- app/core/config.py: AZURE_DI_ENDPOINT, AZURE_DI_API_KEY
-- app/core/azure_di.py uses the azure-ai-documentintelligence SDK, which is
-- also not in the Anaconda channel — sp_capture_email hits the same REST API
-- the SDK wraps directly (submit -> poll Operation-Location -> analyzeResult).

CREATE OR REPLACE NETWORK RULE cashapp.nr_azure_di
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('apsdocintelligence.cognitiveservices.azure.com:443');

CREATE OR REPLACE SECRET cashapp.sec_azure_di_key
  TYPE = GENERIC_STRING
  SECRET_STRING = '<AZURE_DI_API_KEY>';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION eai_azure_di
  ALLOWED_NETWORK_RULES = (cashapp.nr_azure_di)
  ALLOWED_AUTHENTICATION_SECRETS = (cashapp.sec_azure_di_key)
  ENABLED = TRUE;

-- ── 4. Attachment storage — Snowflake-internal stage, not GCS ───────────────
-- No storage integration, no GCP IAM grant, no external cloud dependency at
-- all — attachments live entirely inside Snowflake's own managed storage.
-- session.file.put_stream() writes to this exactly like it would to an
-- external stage; retrieval later is via GET/GET_PRESIGNED_URL or
-- session.file.get_stream(), same as for any stage.
--
-- DIRECTORY = TRUE enables the stage's directory table, so you can browse
-- what's landed via `SELECT * FROM DIRECTORY(@cashapp.stg_email_attachments)`
-- without needing a separate listing mechanism.
--
-- CREATE OR REPLACE, not IF NOT EXISTS — if this environment already has a
-- stage by this name from an earlier GCS-backed run, IF NOT EXISTS would
-- silently leave that old external stage in place instead of converting it.

CREATE OR REPLACE STAGE cashapp.stg_email_attachments
  DIRECTORY = (ENABLE = TRUE);

-- Optional cleanup: the storage integration from the earlier GCS-backed
-- design is now unused. Safe to drop once you've confirmed nothing else
-- references si_email_attachments — not done automatically here since
-- dropping infrastructure objects is worth a deliberate look first:
--   DROP STORAGE INTEGRATION IF EXISTS si_email_attachments;

-- ── 5. Runtime config sp_capture_email reads (global, company_code NULL) ────
-- Same table/pattern as the existing matching-engine thresholds. Replaces
-- what used to be env vars in app/core/config.py (EMAIL_CONFIDENCE_THRESHOLD,
-- EMAIL_CAPTURE_BATCH_SIZE, EMAIL_CAPTURE_MAX_RETRIES) now that FastAPI isn't
-- the runtime for this logic.

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


