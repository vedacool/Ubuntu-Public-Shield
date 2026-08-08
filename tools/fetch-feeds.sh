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

# --- Vulnerability bundle ----------------------------------------------------
# NOTE: building vulns.tsv means parsing Ubuntu OVAL/USN (backport-correct) and
# OSV for Composer/app deps. That parser is the remaining v1 brain task
# (tracked in BACKLOG). The agent matcher (90-vulns.sh) already consumes this
# format correctly — see tests/matchers.bats. Until the parser lands, drop a
# curated vulns.tsv here manually to exercise the matcher.
if [ ! -f "${FEED_DIR}/vulns.tsv" ]; then
  printf '# package\tfixed_version\tcve\tpriority\n' > "${FEED_DIR}/vulns.tsv"
  echo "fetch-feeds: wrote empty vulns.tsv header (OVAL/OSV parser pending)"
fi

echo "fetch-feeds: done -> ${FEED_DIR}"
