#!/usr/bin/env bash
# Collector: listening TCP/UDP sockets. Flags anything bound to a public
# interface (0.0.0.0 / *  / ::) as `public: true` — the "an update opened a
# door" signal. Process name is best-effort (needs root for full visibility).
# Emits: { "ports": [ { proto, address, port, process, public } ], ... }
set -euo pipefail

command -v ss >/dev/null 2>&1 || { echo '{"ports": [], "ports_error": "ss not found"}'; exit 0; }

records=()
# -H no header, -t tcp, -u udp, -l listening, -n numeric, -p process (best-effort)
while read -r proto _ _ _ local _ procinfo; do
  [ -n "${proto:-}" ] || continue
  [ -n "${local:-}" ] || continue

  port="${local##*:}"
  addr="${local%:*}"

  case "${addr}" in
    "0.0.0.0"|"*"|"::"|"[::]") public=true ;;
    *) public=false ;;
  esac

  # Extract the process name from users:(("name",pid=123,fd=4)) if present.
  proc=""
  if [[ "${procinfo:-}" =~ \"([^\"]+)\" ]]; then
    proc="${BASH_REMATCH[1]}"
  fi

  records+=("$(jq -n \
      --arg proto "${proto}" \
      --arg address "${addr}" \
      --arg port "${port}" \
      --arg process "${proc}" \
      --argjson public "${public}" \
      '{proto:$proto, address:$address, port:($port|tonumber? // $port), process:$process, public:$public}')")
done < <(ss -Htulnp 2>/dev/null || true)

if [ "${#records[@]}" -eq 0 ]; then
  echo '{"ports": []}'
else
  printf '%s\n' "${records[@]}" \
    | jq -s '{ports: ., ports_public_count: ([.[] | select(.public)] | length)}'
fi
