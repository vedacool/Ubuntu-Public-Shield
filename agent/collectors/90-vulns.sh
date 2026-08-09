#!/usr/bin/env bash
# Collector: match installed packages against the OSV-built vulnerability bundle
# (vulns.tsv: source_package<TAB>fixed_version<TAB>cve<TAB>priority) using dpkg
# version semantics — never a hand-rolled compare.
#
# A source package is vulnerable if an installed binary built from it has
# source_version << fixed_version. We group findings BY PACKAGE (not per-CVE) and
# cross-check the apt CANDIDATE version so we can tell:
#   fix_available — candidate >= fixed  (an update you can apply right now)
#   fix_pending   — candidate <  fixed  (known-vulnerable but no installable fix
#                                         yet, e.g. not published to your repo)
# We also list the installed binary packages from that source, since the source
# name (e.g. "bind9") may not itself be installed — only its libs.
#
# Emits: { "vulns": { feed_present, checked, vulnerable_count (packages),
#   cve_count, fix_available_count, fix_pending_count, vulnerable[] } }
set -euo pipefail

FEED="${SHIELD_FEED_DIR:-/var/lib/shield/feeds}/vulns.tsv"

empty='{"vulns": {"feed_present": false, "checked": 0, "vulnerable_count": 0, "cve_count": 0, "fix_available_count": 0, "fix_pending_count": 0, "vulnerable": []}}'
if [ ! -r "${FEED}" ] || ! command -v dpkg-query >/dev/null 2>&1; then
  echo "${empty}"
  exit 0
fi

# Installed: source version + installed binaries, keyed by source package.
declare -A srcver bins
while IFS=$'\t' read -r bin src sver; do
  if [ -z "${src}" ] || [ -z "${sver}" ]; then continue; fi
  srcver["${src}"]="${sver}"
  bins["${src}"]="${bins[${src}]:-}${bin} "
done < <(dpkg-query -W -f='${Package}\t${source:Package}\t${source:Version}\n' 2>/dev/null || true)

# Group advisories by source package where installed << fixed.
declare -A vfixed vcves
checked=0
while IFS=$'\t' read -r pkg fixed cve _prio; do
  [ -n "${pkg}" ] || continue
  case "${pkg}" in \#*) continue ;; esac
  [ -n "${fixed}" ] || continue
  iv="${srcver[${pkg}]:-}"
  [ -n "${iv}" ] || continue
  checked=$((checked + 1))
  if dpkg --compare-versions "${iv}" lt "${fixed}" 2>/dev/null; then
    cur="${vfixed[${pkg}]:-}"
    if [ -z "${cur}" ] || dpkg --compare-versions "${fixed}" gt "${cur}" 2>/dev/null; then
      vfixed["${pkg}"]="${fixed}"
    fi
    [ -n "${cve}" ] && vcves["${pkg}"]="${vcves[${pkg}]:-}${cve} "
  fi
done < "${FEED}"

apt_candidate() { # <binary> -> candidate version (may be empty)
  command -v apt-cache >/dev/null 2>&1 || return 0
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2; exit}'
}

entries=()
fix_avail=0
fix_pending=0
cve_total=0
for pkg in "${!vfixed[@]}"; do
  fixed="${vfixed[${pkg}]}"
  iv="${srcver[${pkg}]}"

  mapfile -t cvearr < <(printf '%s' "${vcves[${pkg}]:-}" | tr ' ' '\n' | grep -v '^$' | sort -u)
  mapfile -t binarr < <(printf '%s' "${bins[${pkg}]:-}" | tr ' ' '\n' | grep -v '^$' | sort -u)
  cve_total=$((cve_total + ${#cvearr[@]}))

  cand=""
  [ "${#binarr[@]}" -gt 0 ] && cand="$(apt_candidate "${binarr[0]}")"
  if [ -n "${cand}" ] && dpkg --compare-versions "${cand}" ge "${fixed}" 2>/dev/null; then
    status="fix_available"
    fix_avail=$((fix_avail + 1))
  else
    status="fix_pending"
    fix_pending=$((fix_pending + 1))
  fi

  if [ "${#cvearr[@]}" -eq 0 ]; then cves_json='[]'; else cves_json="$(printf '%s\n' "${cvearr[@]}" | jq -R . | jq -s .)"; fi
  if [ "${#binarr[@]}" -eq 0 ]; then bins_json='[]'; else bins_json="$(printf '%s\n' "${binarr[@]}" | jq -R . | jq -s .)"; fi

  entries+=("$(jq -n \
    --arg p "${pkg}" --arg i "${iv}" --arg f "${fixed}" \
    --arg cand "${cand}" --arg st "${status}" \
    --argjson cves "${cves_json}" --argjson bins "${bins_json}" \
    '{package:$p, installed:$i, fixed:$f, candidate:$cand, status:$st,
      cves:$cves, cve_count:($cves|length), binaries:$bins}')")
done

if [ "${#entries[@]}" -eq 0 ]; then
  ent_json='[]'
else
  # fix_available first, then by most CVEs
  ent_json="$(printf '%s\n' "${entries[@]}" | jq -s 'sort_by([(.status != "fix_available"), (-.cve_count)])')"
fi

jq -n \
  --argjson checked "${checked}" \
  --argjson vuln "${ent_json}" \
  --argjson cve_total "${cve_total}" \
  --argjson fa "${fix_avail}" \
  --argjson fp "${fix_pending}" \
  '{vulns: {feed_present: true, checked: $checked,
            vulnerable_count: ($vuln | length), cve_count: $cve_total,
            fix_available_count: $fa, fix_pending_count: $fp,
            vulnerable: $vuln}}'
