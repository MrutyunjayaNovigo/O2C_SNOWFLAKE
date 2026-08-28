#!/usr/bin/env bash
# Installs schemachange + Snowflake CLI, and registers a "newacct" snow CLI
# connection — the name schemachange-config.yml defaults to
# (SNOWFLAKE_DEFAULT_CONNECTION_NAME env var, falling back to 'newacct').
# Reuses the same TF_DEPLOYER key-pair credentials already materialized for
# Terraform (setup-tf-key.sh) — schemachange needs the same
# CREATE SCHEMA/TABLE-on-O2C_DB level access ACCOUNTADMIN has, no separate
# deployer user needed for this bootstrap. No-ops if the Terraform vars
# aren't set (e.g. running outside Codespaces).
set -euo pipefail

pip install --quiet --user schemachange snowflake-cli

if ! grep -qF '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$HOME/.local/bin:$PATH"

if [ -n "${TF_VAR_SNOWFLAKE_USER:-}" ] && [ -f "$HOME/.ssh/tf_deployer_key.p8" ]; then
  if ! snow connection list --format json 2>/dev/null | grep -q '"connection_name": *"newacct"'; then
    snow connection add \
      --connection-name newacct \
      --account "${TF_VAR_SNOWFLAKE_ORGANIZATION_NAME}-${TF_VAR_SNOWFLAKE_ACCOUNT_NAME}" \
      --user "${TF_VAR_SNOWFLAKE_USER}" \
      --authenticator SNOWFLAKE_JWT \
      --private-key-file "$HOME/.ssh/tf_deployer_key.p8" \
      --role ACCOUNTADMIN \
      --no-interactive
    echo "Registered snow CLI connection 'newacct'"
  else
    echo "snow CLI connection 'newacct' already exists — skipping"
  fi
else
  echo "TF_VAR_SNOWFLAKE_USER not set or private key missing — skipping snow connection setup."
fi
