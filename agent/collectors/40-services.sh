#!/usr/bin/env bash
# Collector: systemd service overview + failed units (a failed/newly-appeared
# service is a common persistence signal).
# Emits: { "services": { running_count, enabled_count, failed_count, failed[] } }
set -euo pipefail

if ! command -v systemctl >/dev/null 2>&1; then
  echo '{"services": {"note": "systemd not present"}}'
  exit 0
fi

running_count="$(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | wc -l | tr -d ' ')"
enabled_count="$(systemctl list-unit-files --type=service --state=enabled --no-legend --plain 2>/dev/null | wc -l | tr -d ' ')"

failed=()
while read -r unit _; do
  [ -n "${unit:-}" ] || continue
  failed+=("${unit}")
done < <(systemctl list-units --type=service --state=failed --no-legend --plain 2>/dev/null || true)

[[ "${running_count}" =~ ^[0-9]+$ ]] || running_count=0
[[ "${enabled_count}" =~ ^[0-9]+$ ]] || enabled_count=0

if [ "${#failed[@]}" -eq 0 ]; then
  failed_json='[]'
else
  failed_json="$(printf '%s\n' "${failed[@]}" | jq -R . | jq -s .)"
fi

jq -n \
  --argjson running "${running_count}" \
  --argjson enabled "${enabled_count}" \
  --argjson failed "${failed_json}" \
  '{services: {running_count: $running, enabled_count: $enabled,
              failed_count: ($failed | length), failed: $failed}}'
