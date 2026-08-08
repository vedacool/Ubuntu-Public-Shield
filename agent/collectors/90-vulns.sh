#!/usr/bin/env bash
# Collector: match installed dpkg packages against a vulnerability bundle using
# Debian version semantics (dpkg --compare-versions — never a hand-rolled
# compare). Bundle is backport-correct (built from Ubuntu OVAL/USN + OSV by the
# brain), so it does not raise NVD-style false positives.
# Bundle: TSV at ${SHIELD_FEED_DIR}/vulns.tsv with columns:
#   package <TAB> fixed_version <TAB> cve <TAB> priority
# A package is vulnerable if installed AND installed_version << fixed_version.
# Emits: { "vulns": { feed_present, checked, vulnerable_count, vulnerable[] } }
set -euo pipefail

FEED="${SHIELD_FEED_DIR:-/var/lib/shield/feeds}/vulns.tsv"

if [ ! -r "${FEED}" ] || ! command -v dpkg-query >/dev/null 2>&1; then
  echo '{"vulns": {"feed_present": false, "checked": 0, "vulnerable_count": 0, "vulnerable": []}}'
  exit 0
fi

declare -A inst
while IFS=' ' read -r p v; do
  [ -n "${p}" ] || continue
  inst["${p}"]="${v}"
done < <(dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null || true)

vuln=()
checked=0
while IFS=$'\t' read -r pkg fixed cve prio; do
  [ -n "${pkg}" ] || continue
  case "${pkg}" in \#*) continue ;; esac
  iv="${inst[${pkg}]:-}"
  [ -n "${iv}" ] || continue
  [ -n "${fixed}" ] || continue
  checked=$((checked + 1))
  if dpkg --compare-versions "${iv}" lt "${fixed}" 2>/dev/null; then
    vuln+=("$(jq -n \
      --arg p "${pkg}" --arg i "${iv}" --arg f "${fixed}" \
      --arg c "${cve:-}" --arg pr "${prio:-unknown}" \
      '{package:$p, installed:$i, fixed:$f, cve:$c, priority:$pr}')")
  fi
done < "${FEED}"

if [ "${#vuln[@]}" -eq 0 ]; then vuln_json='[]'; else vuln_json="$(printf '%s\n' "${vuln[@]}" | jq -s .)"; fi

jq -n \
  --argjson checked "${checked}" \
  --argjson vulnerable "${vuln_json}" \
  '{vulns: {feed_present: true, checked: $checked,
            vulnerable_count: ($vulnerable | length), vulnerable: $vulnerable}}'
