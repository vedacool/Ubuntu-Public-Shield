#!/usr/bin/env bash
# Build the threat-intel + vulnerability bundles the agent matchers consume.
#
# Intended to run on the DESKTOP/BRAIN (or centrally), which then pushes the
# bundle files to each agent's ${SHIELD_FEED_DIR}. Can also run directly on a
# server. Requires network access — exercised during live testing.
#
# Outputs into ${SHIELD_FEED_DIR:-/var/lib/shield/feeds}:
#   threat-ips.txt  — exact-match C2 IPs (abuse.ch Feodo, CC0)
#   drop.txt        — Spamhaus DROP CIDRs (brain-side prefix matching)
#   vulns.tsv       — package<TAB>fixed_version<TAB>cve<TAB>priority  (see note)
#
# Feeds & licences (see docs/STACK.md): Feodo = CC0; DROP = fair-use;
# Ubuntu OVAL/USN = CC-BY-SA; OSV = CC-BY/CC0.
set -euo pipefail

FEED_DIR="${SHIELD_FEED_DIR:-/var/lib/shield/feeds}"
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

# --- Feodo C2 IPs -> exact-match bundle (strip comments/blank) --------------
raw="$(mktemp)"
if curl -fsSL --max-time 60 "${FEODO_URL}" -o "${raw}" 2>/dev/null; then
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${raw}" | sort -u > "${FEED_DIR}/threat-ips.txt" || true
  echo "fetch-feeds: threat-ips.txt ($(wc -l < "${FEED_DIR}/threat-ips.txt" | tr -d ' ') IPs)"
else
  echo "fetch-feeds: WARNING could not fetch Feodo feed" >&2
fi
rm -f "${raw}"

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
