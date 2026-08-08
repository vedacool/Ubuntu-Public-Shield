#!/usr/bin/env bash
# Collector: last Lynis hardening index. Does NOT run Lynis (too heavy for the
# timer) — it reads the report from the most recent on-demand audit. Run the
# audit separately (action script / scheduled), then this surfaces the score.
# Emits: { "lynis": { installed, hardening_index, last_run, report_file } }
set -euo pipefail

installed=false
command -v lynis >/dev/null 2>&1 && installed=true

report="/var/log/lynis-report.dat"
index="null"
last_run=""

if [ -r "${report}" ]; then
  hi="$(awk -F'=' '/^hardening_index=/{print $2}' "${report}" 2>/dev/null | tail -n1)"
  [[ "${hi}" =~ ^[0-9]+$ ]] && index="${hi}"
  ts="$(awk -F'=' '/^report_datetime_end=/{print $2}' "${report}" 2>/dev/null | tail -n1)"
  [ -n "${ts}" ] && last_run="${ts}"
fi

jq -n \
  --argjson installed "${installed}" \
  --argjson index "${index}" \
  --arg last_run "${last_run}" \
  --arg report "${report}" \
  '{lynis: {installed: $installed, hardening_index: $index,
            last_run: $last_run, report_file: $report}}'
