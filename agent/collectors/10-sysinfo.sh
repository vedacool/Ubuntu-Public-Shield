#!/usr/bin/env bash
# Collector: basic system facts + coarse resource snapshot.
# Emits: { "system": { ... } }
set -euo pipefail

# shellcheck disable=SC1091
{ [ -r /etc/os-release ] && . /etc/os-release; } 2>/dev/null || true

mem_total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
load1="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)"
uptime_s="$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)"
disk_pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"

# sanitise to safe values
[[ "${mem_total}" =~ ^[0-9]+$ ]] || mem_total=0
[[ "${mem_avail}" =~ ^[0-9]+$ ]] || mem_avail=0
[[ "${disk_pct}"  =~ ^[0-9]+$ ]] || disk_pct=0
uptime_s="${uptime_s%.*}"
[[ "${uptime_s}"  =~ ^[0-9]+$ ]] || uptime_s=0

jq -n \
  --arg hostname "$(hostname)" \
  --arg os "${PRETTY_NAME:-unknown}" \
  --arg kernel "$(uname -r)" \
  --arg arch "$(uname -m)" \
  --arg load1 "${load1}" \
  --argjson mem_total_kb "${mem_total}" \
  --argjson mem_avail_kb "${mem_avail}" \
  --argjson uptime_s "${uptime_s}" \
  --argjson disk_root_pct "${disk_pct}" \
  '{system: {
      hostname: $hostname,
      os: $os,
      kernel: $kernel,
      arch: $arch,
      load1: ($load1 | tonumber? // 0),
      mem_total_kb: $mem_total_kb,
      mem_avail_kb: $mem_avail_kb,
      mem_used_pct: (if $mem_total_kb > 0
                     then (100 - ($mem_avail_kb * 100 / $mem_total_kb)) | floor
                     else 0 end),
      uptime_s: $uptime_s,
      disk_root_pct: $disk_root_pct
  }}'
