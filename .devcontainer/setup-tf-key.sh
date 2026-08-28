#!/usr/bin/env bash
# Materializes the Snowflake TF deployer private key from the
# SNOWFLAKE_TF_PRIVATE_KEY_B64 Codespaces secret onto disk, since Terraform's
# SNOWFLAKE_PRIVATE_KEY_PATH variable needs a real file path, not env content.
# No-ops if the secret isn't set (e.g. running outside Codespaces).
set -euo pipefail

if [ -n "${SNOWFLAKE_TF_PRIVATE_KEY_B64:-}" ]; then
  mkdir -p "$HOME/.ssh"
  echo "$SNOWFLAKE_TF_PRIVATE_KEY_B64" | base64 -d > "$HOME/.ssh/tf_deployer_key.p8"
  chmod 600 "$HOME/.ssh/tf_deployer_key.p8"
  echo "Wrote $HOME/.ssh/tf_deployer_key.p8"
else
  echo "SNOWFLAKE_TF_PRIVATE_KEY_B64 not set — skipping key materialization."
fi
