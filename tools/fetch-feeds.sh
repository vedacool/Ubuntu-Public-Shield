#!/usr/bin/env bash
# Build the threat-intel + vulnerability bundles the agent matchers consume.
#
# Intended to run on the DESKTOP/BRAIN (or centrally), which then pushes the
# bundle files to each agent's ${SHIELD_FEED_DIR}. Can also run directly on a
# server. Requires network access — exercised during live testing.
#
# Outputs into ${SHIELD_FEED_DIR:-/var/lib/shield/feeds}:
#   threat-ips.txt  — exact-match C2 IPs (abuse.ch ThreatFox + Feodo, CC0)
#   drop.txt        — Spamhaus DROP CIDRs (brain-side prefix matching)
#   vulns.tsv       — package<TAB>fixed_version<TAB>cve<TAB>priority  (see note)
#
# Feeds & licences (see docs/STACK.md): Feodo = CC0; DROP = fair-use;
# Ubuntu OVAL/USN = CC-BY-SA; OSV = CC-BY/CC0.
set -euo pipefail

FEED_DIR="${SHIELD_FEED_DIR:-/var/lib/shield/feeds}"
# abuse.ch ThreatFox recent botnet_cc IOCs (CC0) — the live C2 IP source.
# Feodo's IP blocklist is near-dead (a handful of stale IPs) so we merge it in
# only as a supplement.
THREATFOX_URL="${SHIELD_THREATFOX_URL:-https://threatfox.abuse.ch/export/csv/ip-port/recent/}"
FEODO_URL="${SHIELD_FEODO_URL:-https://feodotracker.abuse.ch/downloads/ipblocklist.txt}"
DROP_URL="${SHIELD_DROP_URL:-https://www.spamhaus.org/drop/drop.txt}"

command -v curl >/dev/null 2>&1 || { echo "fetch-feeds: curl required" >&2; exit 1; }
mkdir -p "${FEED_DIR}"

fetch() {  # fetch <url> <dest>
  local url="$1" dest="$2" tmp
  tmp="$(mktemp)"
  if curl -fsSL --max-time 60 "${url}" -o "${tmp}" 2>/dev/null; then
    mv -f "${tmp}" "${dest}"
    echo "fetch-feeds: updated ${dest} ($(wc -l < "${dest}" | tr -d ' ') lines)"
  else
    rm -f "${tmp}"
    echo "fetch-feeds: WARNING could not fetch ${url} (kept previous ${dest} if any)" >&2
  fi
}

# --- C2 IPs: abuse.ch ThreatFox (primary) + Feodo (supplement) --------------
# Extract with grep -oE (leading IPv4 only) so trailing CRLF / :port / quotes
# never defeat the match — that CRLF trap silently emptied the old Feodo parse.
ips_tmp="$(mktemp)"

tf="$(mktemp)"
if curl -fsSL --max-time 90 "${THREATFOX_URL}" -o "${tf}" 2>/dev/null; then
  # CSV; ioc_value ("IP:PORT") is the 3rd '", "'-separated field.
  grep -v '^#' "${tf}" | awk -F'", "' 'NF>=4 {print $3}' \
    | grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}' >> "${ips_tmp}" || true
fi
rm -f "${tf}"

fe="$(mktemp)"
if curl -fsSL --max-time 60 "${FEODO_URL}" -o "${fe}" 2>/dev/null; then
  grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}' "${fe}" >> "${ips_tmp}" || true
fi
rm -f "${fe}"

if [ -s "${ips_tmp}" ]; then
  sort -u "${ips_tmp}" > "${FEED_DIR}/threat-ips.txt"
  echo "fetch-feeds: threat-ips.txt ($(wc -l < "${FEED_DIR}/threat-ips.txt" | tr -d ' ') C2 IPs — ThreatFox + Feodo)"
else
  echo "fetch-feeds: WARNING no C2 IPs fetched (kept previous threat-ips.txt if any)" >&2
fi
rm -f "${ips_tmp}"

# --- Spamhaus DROP CIDRs (brain does prefix matching) -----------------------
fetch "${DROP_URL}" "${FEED_DIR}/drop.txt"

# --- Vulnerability bundle (OSV) ---------------------------------------------
# Build vulns.tsv (source-package, fixed_version, cve, priority) from OSV, but
# ONLY for advisories that carry a real "fixed" version. Debian OSV lists many
# introduced:0/no-fix ("minor / no-DSA") entries that would be pure false
# positives; we drop those. The agent matcher (90-vulns.sh) then flags a package
# only when the installed source version is < the fixed version (an actual
# missing patch). OSV IOC data: CC-BY (see docs/STACK.md).
build_vulns_osv() {
  command -v dpkg-query >/dev/null 2>&1 || {
    echo "fetch-feeds: dpkg-query missing; skipping vuln feed" >&2; return 0; }

  local eco=""
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && . /etc/os-release
  case "${ID:-}" in
    debian) eco="Debian:${VERSION_ID:-}" ;;
    ubuntu) eco="Ubuntu:${VERSION_ID:-}" ;;
    *) echo "fetch-feeds: OSV vuln feed supports Debian/Ubuntu only (got '${ID:-?}')" >&2; return 0 ;;
  esac
  [ -n "${VERSION_ID:-}" ] || { echo "fetch-feeds: no VERSION_ID; skip vuln feed" >&2; return 0; }

  local pkgs qbatch resp out affected
  pkgs="$(mktemp)"; qbatch="$(mktemp)"; resp="$(mktemp)"; out="$(mktemp)"

  # Unique installed source packages + source versions.
  dpkg-query -W -f='${source:Package}\t${source:Version}\n' 2>/dev/null \
    | awk -F'\t' 'NF==2 && $1!="" && $2!="" {print}' | sort -u > "${pkgs}"

  jq -Rn --arg eco "${eco}" \
    '{queries: [inputs | split("\t") | {package: {ecosystem: $eco, name: .[0]}, version: .[1]}]}' \
    < "${pkgs}" > "${qbatch}"

  if ! curl -fsS --max-time 120 -X POST -H 'Content-Type: application/json' \
        -d @"${qbatch}" 'https://api.osv.dev/v1/querybatch' -o "${resp}" 2>/dev/null; then
    echo "fetch-feeds: WARNING OSV querybatch failed; kept previous vulns.tsv" >&2
    rm -f "${pkgs}" "${qbatch}" "${resp}" "${out}"; return 0
  fi

  # Which source packages have at least one advisory (results[] align to queries).
  affected="$(paste <(cut -f1 "${pkgs}") <(jq -c '.results[]?' "${resp}") \
    | awk -F'\t' '$2 ~ /"vulns"/ {print $1}' | sort -u)"

  # For each affected package, pull full advisories and keep only fixed versions.
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    local ver q1 detail
    ver="$(awk -F'\t' -v n="${name}" '$1==n{print $2; exit}' "${pkgs}")"
    q1="$(mktemp)"
    printf '{"package":{"ecosystem":"%s","name":"%s"},"version":"%s"}' "${eco}" "${name}" "${ver}" > "${q1}"
    detail="$(curl -fsS --max-time 30 -X POST -H 'Content-Type: application/json' \
      -d @"${q1}" 'https://api.osv.dev/v1/query' 2>/dev/null || echo '{}')"
    rm -f "${q1}"
    printf '%s' "${detail}" | jq -r --arg eco "${eco}" --arg name "${name}" '
      .vulns[]?
      | ((.aliases // [] | map(select(startswith("CVE-"))) | .[0]) // (.id | sub("^DEBIAN-"; ""))) as $cve
      | ((.database_specific.severity // .ecosystem_specific.urgency // "unknown") | tostring) as $prio
      | .affected[]?
      | select(.package.ecosystem == $eco and .package.name == $name)
      | .ranges[]?.events[]? | select(.fixed) | .fixed
      | "\($name)\t\(.)\t\($cve)\t\($prio)"' >> "${out}" 2>/dev/null || true
  done <<< "${affected}"

  { printf '# package\tfixed_version\tcve\tpriority\n'; sort -u "${out}"; } > "${FEED_DIR}/vulns.tsv"
  echo "fetch-feeds: vulns.tsv ($(grep -vc '^#' "${FEED_DIR}/vulns.tsv" || echo 0) fix-available CVEs for ${eco}; matcher keeps only installed<fixed)"
  rm -f "${pkgs}" "${qbatch}" "${resp}" "${out}"
}
build_vulns_osv || echo "fetch-feeds: vuln feed step failed (non-fatal)" >&2

echo "fetch-feeds: done -> ${FEED_DIR}"
