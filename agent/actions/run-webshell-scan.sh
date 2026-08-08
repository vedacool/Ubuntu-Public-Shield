#!/usr/bin/env bash
# Action: run the (heavier) webshell scan on demand.
#   --preview : report the web roots that would be scanned (default)
#   --apply   : run the scan now; refreshes webshell.json
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent/actions/lib.sh
. "${SCRIPT_DIR}/lib.sh"

SCANNER="${SHIELD_HOME:-/opt/shield}/scanners/webshell-scan.sh"
[ -x "${SCANNER}" ] || SCANNER="${SCRIPT_DIR}/../scanners/webshell-scan.sh"
ROOTS="${SHIELD_WEBROOTS:-/var/www}"

mode="$(action_mode "$@")"

if [ "${mode}" = "preview" ]; then
  jq -n --argjson roots "$(lines_to_json_array "$(printf '%s' "${ROOTS}" | tr ' ' '\n')")" \
    '{action:"run-webshell-scan", mode:"preview", web_roots:$roots,
      note:"run with --apply to scan now"}'
  exit 0
fi

log_action "run-webshell-scan" "apply" "scanning ${ROOTS}"
bash "${SCANNER}" | jq '{action:"run-webshell-scan", mode:"apply", result:.webshell}'
