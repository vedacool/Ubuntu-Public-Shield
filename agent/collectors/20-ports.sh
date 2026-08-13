#!/usr/bin/env bash
# Collector: listening sockets + real EXPOSURE analysis.
#
# The raw "bound to 0.0.0.0" signal is not the same as "reachable from the
# internet". This collector works out:
#   - host_exposure: is this host directly internet-addressable, or behind NAT
#     (a private IP)? Behind NAT, an all-interfaces bind is only LAN-reachable
#     unless the router forwards a port (which we can't see from here — noted).
#   - per-port reach: local (this machine only) / lan / internet
#   - per-port risk: known-risky services (databases, admin panels, remote
#     access, cleartext protocols) elevated by how far they're reachable.
#
# Emits: { ports:[{proto,address,port,process,public,reach,risk,risk_note}],
#          ports_public_count,
#          exposure:{host_ip, host_exposure, internet_reachable_count,
#                    lan_reachable_count, risky:[...]} }
set -euo pipefail

command -v ss >/dev/null 2>&1 || { echo '{"ports": [], "ports_error": "ss not found"}'; exit 0; }

# --- host IP + NAT detection ------------------------------------------------
host_ip="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)"
[ -n "${host_ip}" ] || host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

is_private() { # IPv4 -> 0 if RFC1918 / CGNAT / loopback / link-local
  case "$1" in
    10.* | 192.168.* | 127.* | 169.254.*) return 0 ;;
    172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].*) return 0 ;;
    100.6[4-9].* | 100.[7-9][0-9].* | 100.1[0-1][0-9].* | 100.12[0-7].*) return 0 ;;
    *) return 1 ;;
  esac
}
if [ -n "${host_ip}" ] && ! is_private "${host_ip}"; then
  host_exposure="public"
else
  host_exposure="nat"
fi

reach_for() { # <address> -> local|lan|internet
  case "$1" in
    127.* | ::1 | "[::1]") echo local; return ;;
    fe80* | "[fe80"*) echo lan; return ;;
  esac
  case "$1" in
    "0.0.0.0" | "*" | "::" | "[::]")
      if [ "${host_exposure}" = public ]; then echo internet; else echo lan; fi ;;
    *)
      if is_private "$1"; then echo lan; else echo internet; fi ;;
  esac
}

# service class + friendly label from port/process
classify() { # <port> <proc> -> "class|label"
  local port="$1" proc="$2" class="other" label=""
  case "${proc}" in
    sshd) class="remote"; label="SSH remote login" ;;
    pihole-FTL) class="admin"; label="Pi-hole admin panel" ;;
    mysqld | mariadbd) class="database"; label="MySQL/MariaDB" ;;
    redis-server) class="database"; label="Redis (often no auth)" ;;
  esac
  if [ "${class}" = other ]; then
    case "${port}" in
      3306) class="database"; label="MySQL/MariaDB" ;;
      5432) class="database"; label="PostgreSQL" ;;
      6379) class="database"; label="Redis (often no auth)" ;;
      11211) class="database"; label="Memcached (often no auth)" ;;
      27017 | 27018 | 27019) class="database"; label="MongoDB" ;;
      9200 | 9300) class="database"; label="Elasticsearch" ;;
      5984) class="database"; label="CouchDB" ;;
      21) class="cleartext"; label="FTP (cleartext)" ;;
      23) class="cleartext"; label="Telnet (cleartext)" ;;
      3389) class="remote"; label="RDP" ;;
      5900 | 5901 | 5902 | 5903 | 5904 | 5905) class="remote"; label="VNC" ;;
      8080 | 8081 | 8443 | 9000 | 9090 | 8888 | 3000 | 8006) class="admin"; label="web admin / app panel" ;;
    esac
  fi
  printf '%s|%s' "${class}" "${label}"
}

risk_note_for() { # <class> <label> <reach> -> "risk|note" (risk: none|watch|high)
  local class="$1" label="$2" reach="$3" where risk note
  if [ "${reach}" = local ] || [ "${class}" = other ]; then
    printf 'none|'; return
  fi
  if [ "${reach}" = internet ]; then where="the internet"; risk="high"; else where="your LAN"; risk="watch"; fi
  case "${class}" in
    database) note="${label} reachable from ${where} — make sure it requires a password (or bind it to localhost)." ;;
    admin) note="${label} reachable from ${where} — ensure it's password-protected." ;;
    remote) note="${label} reachable from ${where}." ; [ "${reach}" = lan ] && risk="watch" ;;
    cleartext) note="${label} — credentials travel unencrypted; avoid exposing it." ; risk="high" ;;
    *) note="Reachable from ${where}." ;;
  esac
  printf '%s|%s' "${risk}" "${note}"
}

records=()
while read -r proto _ _ _ local _ procinfo; do
  [ -n "${proto:-}" ] || continue
  [ -n "${local:-}" ] || continue

  port="${local##*:}"
  addr="${local%:*}"

  case "${addr}" in
    "0.0.0.0" | "*" | "::" | "[::]") public=true ;;
    *) public=false ;;
  esac

  proc=""
  if [[ "${procinfo:-}" =~ \"([^\"]+)\" ]]; then proc="${BASH_REMATCH[1]}"; fi

  reach="$(reach_for "${addr}")"
  cl="$(classify "${port}" "${proc}")"
  class="${cl%%|*}"; label="${cl#*|}"
  rn="$(risk_note_for "${class}" "${label}" "${reach}")"
  risk="${rn%%|*}"; risk_note="${rn#*|}"

  records+=("$(jq -n \
    --arg proto "${proto}" --arg address "${addr}" --arg port "${port}" \
    --arg process "${proc}" --argjson public "${public}" \
    --arg reach "${reach}" --arg risk "${risk}" --arg risk_note "${risk_note}" \
    '{proto:$proto, address:$address, port:($port|tonumber? // $port),
      process:$process, public:$public, reach:$reach, risk:$risk,
      risk_note:(if $risk_note=="" then null else $risk_note end)}')")
done < <(ss -Htulnp 2>/dev/null || true)

if [ "${#records[@]}" -eq 0 ]; then
  echo '{"ports": [], "exposure": {"host_exposure": "unknown"}}'
  exit 0
fi

printf '%s\n' "${records[@]}" | jq -s \
  --arg host_ip "${host_ip}" --arg host_exposure "${host_exposure}" \
  '{ports: .,
    ports_public_count: ([.[] | select(.public)] | length),
    exposure: {
      host_ip: $host_ip,
      host_exposure: $host_exposure,
      internet_reachable_count: ([.[] | select(.reach=="internet")] | length),
      lan_reachable_count:      ([.[] | select(.reach=="lan")] | length),
      risky: [.[] | select(.risk != "none")
              | {proto, port, process, reach, risk, risk_note}]
    }}'
