#!/usr/bin/env bash
# Materializes the Snowflake TF deployer private key from the
# SNOWFLAKE_TF_PRIVATE_KEY_PEM Codespaces secret onto disk, since Terraform's
# SNOWFLAKE_PRIVATE_KEY_PATH variable needs a real file path, not env content.
# Stores the raw PEM text directly (no base64 round-trip) — Codespaces
# secrets support multiline values, and skipping the encode/decode step
# avoids the copy-paste corruption that step kept introducing.
# No-ops if the secret isn't set (e.g. running outside Codespaces).
set -euo pipefail

if [ -n "${SNOWFLAKE_TF_PRIVATE_KEY_PEM:-}" ]; then
  mkdir -p "$HOME/.ssh"
  printf '%s\n' "$SNOWFLAKE_TF_PRIVATE_KEY_PEM" | tr -d '\r' > "$HOME/.ssh/tf_deployer_key.p8"
  chmod 600 "$HOME/.ssh/tf_deployer_key.p8"
  echo "Wrote $HOME/.ssh/tf_deployer_key.p8"
else
  echo "SNOWFLAKE_TF_PRIVATE_KEY_PEM not set — skipping key materialization."
fi

# HCP Terraform auth (remote state backend, 01_versions.tf's cloud block).
# Written as a credentials file rather than relying on the
# TF_TOKEN_app_terraform_io env var directly — Codespaces force-uppercases
# secret names, which would turn that into TF_TOKEN_APP_TERRAFORM_IO and
# Terraform wouldn't recognize it. The TF_API_TOKEN secret's name can be
# anything; only the file content below needs the exact casing.
if [ -n "${TF_API_TOKEN:-}" ]; then
  mkdir -p "$HOME/.terraform.d"
  cat > "$HOME/.terraform.d/credentials.tfrc.json" << EOF
{
  "credentials": {
    "app.terraform.io": {
      "token": "$TF_API_TOKEN"
    }
  }
}
EOF
  chmod 600 "$HOME/.terraform.d/credentials.tfrc.json"
  echo "Wrote $HOME/.terraform.d/credentials.tfrc.json"
else
  echo "TF_API_TOKEN not set — skipping HCP Terraform auth."
fi
