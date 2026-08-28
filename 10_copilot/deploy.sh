#!/usr/bin/env bash
set -u
SNOW=~/.snowcli-venv/bin/snow
cd "$(dirname "$0")"
OPTS="-c "${SNOW_CONNECTION:-newacct}" --role ACCOUNTADMIN --warehouse O2C_WH --database O2C_DB --schema CASHAPP"
for f in Create_Tables_Copilot.sql Procedure_ToolCaseRetrieval.sql Procedure_ToolMatchExplain.sql Procedure_CopilotAsk.sql; do
  echo "===== $f ====="
  $SNOW sql $OPTS -f "$f" 2>&1 | tail -14
done
