#!/usr/bin/env bash
# Collector: surface the latest webshell-scan result (the scan itself is heavy,
# so it runs on its own schedule via agent/scanners/webshell-scan.sh and writes
# webshell.json; this just includes it in the state document).
# Emits: { "webshell": { ... } }
set -euo pipefail

f="${SHIELD_STATE_DIR:-/var/lib/shield/state}/webshell.json"
if [ -r "${f}" ] && jq -e . "${f}" >/dev/null 2>&1; then
  cat "${f}"
else
  echo '{"webshell": {"scanned": 0, "finding_count": 0, "findings": [], "note": "no scan yet"}}'
fi
