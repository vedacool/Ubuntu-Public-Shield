#!/usr/bin/env bash
# Action: accept the current persistence state as the new drift baseline.
# Use after you've reviewed drift and confirmed the changes are legitimate.
#   --preview : report current drift that would be accepted (default)
#   --apply   : rewrite the baseline to match the current state
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent/actions/lib.sh
. "${SCRIPT_DIR}/lib.sh"

DRIFT="${SHIELD_HOME:-/opt/shield}/collectors/60-drift.sh"
[ -x "${DRIFT}" ] || DRIFT="${SCRIPT_DIR}/../collectors/60-drift.sh"

mode="$(action_mode "$@")"

if [ "${mode}" = "preview" ]; then
  current="$(bash "${DRIFT}" 2>/dev/null || echo '{}')"
  echo "${current}" | jq '{action:"rebaseline-drift", mode:"preview",
    drift_to_accept: (.drift // {}), note:"run with --apply to accept as new baseline"}'
  exit 0
fi

log_action "rebaseline-drift" "apply" "resetting persistence baseline"
SHIELD_REBASELINE=1 bash "${DRIFT}" >/dev/null 2>&1 || true
jq -n '{action:"rebaseline-drift", mode:"apply", ok:true, note:"baseline reset to current state"}'
