#!/usr/bin/env bash
# Action: apply pending SECURITY package updates (Debian/Ubuntu).
#   --preview : list the security packages that would be upgraded (default)
#   --apply   : perform the upgrade (security only) and log it
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent/actions/lib.sh
. "${SCRIPT_DIR}/lib.sh"

mode="$(action_mode "$@")"

if ! command -v apt-get >/dev/null 2>&1; then
  jq -n '{action:"apply-security-updates", error:"apt-get not found (Debian/Ubuntu only)"}'
  exit 0
fi

# Security-upgradable packages: Inst lines whose origin suite ends in -security.
pkgs="$(LC_ALL=C apt-get -s upgrade 2>/dev/null | awk '/^Inst / && /security/ {print $2}' | sort -u || true)"
count="$(printf '%s' "${pkgs}" | grep -c . || true)"
[[ "${count}" =~ ^[0-9]+$ ]] || count=0

if [ "${mode}" = "preview" ]; then
  jq -n \
    --argjson count "${count}" \
    --argjson packages "$(lines_to_json_array "${pkgs}")" \
    '{action:"apply-security-updates", mode:"preview",
      would_upgrade_count:$count, packages:$packages,
      note:"run with --apply to perform"}'
  exit 0
fi

# --apply
log_action "apply-security-updates" "apply" "upgrading ${count} security package(s)"
export DEBIAN_FRONTEND=noninteractive
ok=true
if command -v unattended-upgrade >/dev/null 2>&1; then
  unattended-upgrade -v >/dev/null 2>&1 || ok=false
else
  apt-get update -y >/dev/null 2>&1 || true
  if [ "${count}" -gt 0 ]; then
    # shellcheck disable=SC2086  # intentional word-splitting of the package list
    apt-get -y --only-upgrade install ${pkgs} >/dev/null 2>&1 || ok=false
  fi
fi

jq -n --argjson count "${count}" --argjson ok "${ok}" \
  '{action:"apply-security-updates", mode:"apply", upgraded_count:$count, ok:$ok}'
