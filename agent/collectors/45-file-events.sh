#!/usr/bin/env bash
# Collector: surface recent real-time file-integrity events from the shield-watch
# sensor (agent/sensors/shield-watch.sh). Read-only over the event log.
# Emits: { "file_events": { watching, total, webshell_suspect, persistence, recent[] } }
set -euo pipefail

LOG="${SHIELD_STATE_DIR:-/var/lib/shield/state}/file-events.log"

if [ ! -r "${LOG}" ]; then
  echo '{"file_events": {"watching": false, "total": 0, "webshell_suspect": 0, "persistence": 0, "recent": []}}'
  exit 0
fi

total="$(wc -l < "${LOG}" 2>/dev/null | tr -d ' ')"
[[ "${total}" =~ ^[0-9]+$ ]] || total=0
webshell_ct="$(grep -c $'\twebshell-suspect\t' "${LOG}" 2>/dev/null || true)"
persist_ct="$(grep -c $'\tpersistence\t' "${LOG}" 2>/dev/null || true)"
[[ "${webshell_ct}" =~ ^[0-9]+$ ]] || webshell_ct=0
[[ "${persist_ct}" =~ ^[0-9]+$ ]] || persist_ct=0

# Most recent 20 events (newest first) as structured JSON.
recent="$(tail -n 20 "${LOG}" \
  | jq -R 'split("\t") | select(length == 4) | {ts: .[0], type: .[1], path: .[2], event: .[3]}' \
  | jq -s 'reverse')"
[ -n "${recent}" ] || recent='[]'

jq -n \
  --argjson total "${total}" \
  --argjson webshell "${webshell_ct}" \
  --argjson persistence "${persist_ct}" \
  --argjson recent "${recent}" \
  '{file_events: {watching: true, total: $total,
                  webshell_suspect: $webshell, persistence: $persistence,
                  recent: $recent}}'
