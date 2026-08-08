#!/usr/bin/env bash
# Collector: pending package updates, total and security, on Debian/Ubuntu.
# Emits: { "updates": { total, security, source } }
set -euo pipefail

total=0
security=0
source="none"

if [ -x /usr/lib/update-notifier/apt-check ]; then
  # apt-check prints "total;security" on stderr. Take the LAST line and match
  # unanchored, so a preceding warning line doesn't defeat the parse.
  out="$(/usr/lib/update-notifier/apt-check 2>&1 | tail -n1 || true)"
  if [[ "${out}" =~ ([0-9]+)\;([0-9]+) ]]; then
    total="${BASH_REMATCH[1]}"
    security="${BASH_REMATCH[2]}"
    source="apt-check"
  fi
elif command -v apt-get >/dev/null 2>&1; then
  # Fallback: simulate an upgrade and count upgradable packages.
  sim="$(LC_ALL=C apt-get -s upgrade 2>/dev/null || true)"
  total="$(printf '%s\n' "${sim}" | grep -c '^Inst ' || true)"
  security="$(printf '%s\n' "${sim}" | grep -c -i '^Inst .*security' || true)"
  source="apt-get-sim"
fi

[[ "${total}"    =~ ^[0-9]+$ ]] || total=0
[[ "${security}" =~ ^[0-9]+$ ]] || security=0

jq -n \
  --argjson total "${total}" \
  --argjson security "${security}" \
  --arg source "${source}" \
  '{updates: {total: $total, security: $security, source: $source}}'
