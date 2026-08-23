#!/usr/bin/env bash
# Action: run a Lynis hardening audit on demand (heavy — minutes). Refreshes the
# report that collector 50-lynis.sh reads for the hardening score.
#   --preview : report whether Lynis is available (default)
#   --apply   : run `lynis audit system --quick`
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent/actions/lib.sh
. "${SCRIPT_DIR}/lib.sh"

mode="$(action_mode "$@")"
installed=false
command -v lynis >/dev/null 2>&1 && installed=true

if [ "${mode}" = "preview" ]; then
  jq -n --argjson installed "${installed}" \
    '{action:"run-lynis-audit", mode:"preview", lynis_installed:$installed,
      note:(if $installed then "run with --apply (takes minutes)"
            else "will install lynis, then run the scan" end)}'
  exit 0
fi

# --apply: install Lynis on demand if it isn't present, so "Set up now" works.
if ! ${installed}; then
  log_action "run-lynis-audit" "apply" "installing lynis"
  if command -v apt-get >/dev/null 2>&1; then
    if ! apt-get install -y lynis >/dev/null 2>&1; then
      apt-get update >/dev/null 2>&1 || true
      apt-get install -y lynis >/dev/null 2>&1 || true
    fi
  fi
  command -v lynis >/dev/null 2>&1 && installed=true
fi
if ! ${installed}; then
  jq -n '{action:"run-lynis-audit", mode:"apply", ok:false, error:"could not install lynis — try: sudo apt install lynis"}'
  exit 0
fi

log_action "run-lynis-audit" "apply" "running lynis audit system --quick"
lynis audit system --quick --quiet >/dev/null 2>&1 || true
index="null"
if [ -r /var/log/lynis-report.dat ]; then
  hi="$(awk -F'=' '/^hardening_index=/{print $2}' /var/log/lynis-report.dat | tail -n1)"
  [[ "${hi}" =~ ^[0-9]+$ ]] && index="${hi}"
fi
jq -n --argjson index "${index}" \
  '{action:"run-lynis-audit", mode:"apply", ok:true, hardening_index:$index}'
