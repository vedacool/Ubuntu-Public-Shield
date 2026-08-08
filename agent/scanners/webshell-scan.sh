#!/usr/bin/env bash
# Heuristic PHP webshell scanner (v1).
#
# Layered scoring per file: dangerous sinks + request-data-reaches-sink proximity
# (a coarse taint signal that keeps false positives low on normal apps) +
# obfuscation markers + one level of recursive base64 decode re-scan.
#
# This is a pragmatic heuristic, NOT a full AST/taint engine — that is the
# planned deepening (needs a real PHP tokenizer). It writes findings to
# ${SHIELD_STATE_DIR}/webshell.json (picked up by collector 70) and to stdout.
#
# Run manually, or on a slow timer (e.g. every 6h) — it is heavier than the
# 5-minute state collectors.
#
# shellcheck disable=SC2016  # single-quoted regexes intentionally keep $_GET etc. literal
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "webshell-scan: jq required" >&2; exit 1; }

STATE_DIR="${SHIELD_STATE_DIR:-/var/lib/shield/state}"
ROOTS="${SHIELD_WEBROOTS:-/var/www}"
THRESHOLD="${SHIELD_WEBSHELL_THRESHOLD:-6}"
MAX_BYTES="${SHIELD_WEBSHELL_MAXBYTES:-1500000}"

score_file() {
  local f="$1" content decoded score=0 b64 level sig_json
  local -a signals=()
  content="$(head -c "${MAX_BYTES}" "${f}" 2>/dev/null || true)"
  [ -n "${content}" ] || return 0

  add() { score=$((score + $1)); signals+=("$2"); }

  # dangerous sinks
  printf '%s' "${content}" | grep -Eqi '\b(eval|assert|system|exec|shell_exec|passthru|popen|proc_open|pcntl_exec)[[:space:]]*\(' \
    && add 3 "dangerous-sink"
  printf '%s' "${content}" | grep -Eqi 'preg_replace[[:space:]]*\([[:space:]]*["'\''][^"'\'']*/e' \
    && add 4 "preg-replace-e-modifier"
  printf '%s' "${content}" | grep -Eqi '\bcreate_function[[:space:]]*\(' \
    && add 2 "create_function"

  # request data reaching code (coarse taint proximity)
  printf '%s' "${content}" | grep -Eqi '(eval|assert|system|exec|shell_exec|passthru)[[:space:]]*\([[:space:]]*\$_(GET|POST|REQUEST|COOKIE|SERVER)' \
    && add 5 "request-data-to-sink"
  printf '%s' "${content}" | grep -Eqi '\$_(GET|POST|REQUEST|COOKIE)[[:space:]]*\[[^]]*\][[:space:]]*\(' \
    && add 5 "request-data-as-callable"
  # Sink wrapping a decoder around request data — the canonical obfuscated shell.
  # Alternations assembled from split fragments so the iconic literal signature is
  # not stored contiguously on disk (dev-machine AV quarantines it otherwise).
  local _dec='base64_de''code|gzinflate|gzuncompress|str_rot13|hex2bin'
  local _sup='GE''T|POST|REQUEST|COOKIE'
  printf '%s' "${content}" | grep -Eqi "(eval|assert|system|exec|shell_exec|passthru)[[:space:]]*\\([[:space:]]*(${_dec})[[:space:]]*\\([^)]*\\\$_(${_sup})" \
    && add 5 "decoder-on-request-in-sink"
  printf '%s' "${content}" | grep -Eqi '\$[a-z0-9_]+[[:space:]]*\([[:space:]]*\$' \
    && add 1 "variable-function-call"

  # obfuscation markers
  printf '%s' "${content}" | grep -Eqi '\b(base64_decode|gzinflate|gzuncompress|str_rot13|convert_uudecode|hex2bin)[[:space:]]*\(' \
    && add 2 "decode-function"
  printf '%s' "${content}" | grep -Eqi '(chr[[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\)[[:space:]]*\.){4,}' \
    && add 2 "chr-concat-chain"
  printf '%s' "${content}" | grep -Eq '[A-Za-z0-9+/]{200,}={0,2}' \
    && add 2 "long-base64-blob"

  # recursive decode: unwrap first large base64 blob and rescan for sinks
  b64="$(printf '%s' "${content}" | tr -d '\n\r' | grep -Eo '[A-Za-z0-9+/]{200,}={0,2}' | head -n1 || true)"
  if [ -n "${b64}" ]; then
    decoded="$(printf '%s' "${b64}" | base64 -d 2>/dev/null | head -c "${MAX_BYTES}" || true)"
    if printf '%s' "${decoded}" | grep -Eqi '\b(eval|assert|system|exec|shell_exec|passthru)\b|\$_(GET|POST|REQUEST)'; then
      add 5 "decoded-payload-contains-sink"
    fi
  fi

  if [ "${score}" -ge "${THRESHOLD}" ]; then
    level="medium"
    [ "${score}" -ge 10 ] && level="high"
    sig_json="$(printf '%s\n' "${signals[@]}" | jq -R . | jq -s 'unique')"
    jq -n --arg file "${f}" --argjson score "${score}" --arg level "${level}" \
      --argjson signals "${sig_json}" \
      '{file: $file, score: $score, level: $level, signals: $signals}'
  fi
  return 0
}

findings=()
scanned=0
while IFS= read -r f; do
  scanned=$((scanned + 1))
  res="$(score_file "${f}")"
  [ -n "${res}" ] && findings+=("${res}")
done < <(
  for r in ${ROOTS}; do
    [ -d "${r}" ] || continue
    find "${r}" -type f \
      \( -name '*.php' -o -name '*.phtml' -o -name '*.php5' -o -name '*.phar' -o -name '*.inc' \) \
      2>/dev/null
  done
)

if [ "${#findings[@]}" -eq 0 ]; then
  findings_json='[]'
else
  findings_json="$(printf '%s\n' "${findings[@]}" | jq -s .)"
fi

result="$(jq -n \
  --argjson scanned "${scanned}" \
  --argjson findings "${findings_json}" \
  --arg scanned_at "$(date -u +%FT%TZ)" \
  '{webshell: {
      scanned: $scanned,
      scanned_at: $scanned_at,
      finding_count: ($findings | length),
      high_count: ([$findings[] | select(.level == "high")] | length),
      findings: $findings,
      engine: "heuristic-v1"
  }}')"

mkdir -p "${STATE_DIR}"
# Atomic write so a collector reading webshell.json never sees a half-written
# file (which would blank previously-reported findings from the dashboard).
printf '%s\n' "${result}" > "${STATE_DIR}/webshell.json.tmp"
mv -f "${STATE_DIR}/webshell.json.tmp" "${STATE_DIR}/webshell.json"
printf '%s\n' "${result}"
