#!/usr/bin/env bash
# Collector: match current outbound connections against a known-bad IP bundle
# (e.g. abuse.ch Feodo C2 IPs — the "is this box calling home" signal).
# Bundle: one IP per line at ${SHIELD_FEED_DIR}/threat-ips.txt (# comments ok).
# Exact-IP match only; CIDR/DROP prefix matching is done by the desktop brain
# (radix trie), not in the agent.
# Emits: { "threat_intel": { feed_present, checked, match_count, matches[] } }
set -euo pipefail

FEED="${SHIELD_FEED_DIR:-/var/lib/shield/feeds}/threat-ips.txt"

if [ ! -r "${FEED}" ] || ! command -v ss >/dev/null 2>&1; then
  echo '{"threat_intel": {"feed_present": false, "checked": 0, "match_count": 0, "matches": []}}'
  exit 0
fi

declare -A bad
while IFS= read -r line; do
  line="${line%%#*}"; line="${line//[[:space:]]/}"
  [ -n "${line}" ] || continue
  bad["${line}"]=1
done < "${FEED}"

matches=()
checked=0
while read -r peer; do
  [ -n "${peer}" ] || continue
  ip="${peer%:*}"; ip="${ip#[}"; ip="${ip%]}"
  [ -n "${ip}" ] || continue
  checked=$((checked + 1))
  if [ -n "${bad[${ip}]:-}" ]; then
    matches+=("$(jq -n --arg ip "${ip}" '{ip: $ip}')")
  fi
done < <(ss -Htn state established 2>/dev/null | awk '{print $4}' || true)

if [ "${#matches[@]}" -eq 0 ]; then matches_json='[]'; else matches_json="$(printf '%s\n' "${matches[@]}" | jq -s 'unique')"; fi

jq -n \
  --argjson checked "${checked}" \
  --argjson matches "${matches_json}" \
  '{threat_intel: {feed_present: true, checked: $checked,
                   match_count: ($matches | length), matches: $matches}}'
