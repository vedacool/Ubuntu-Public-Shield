#!/usr/bin/env bash
#
# Ubuntu Public Shield — agent installer.
# Run ON the server you want to protect:
#
#     git clone https://github.com/vedacool/Ubuntu-Public-Shield.git
#     cd Ubuntu-Public-Shield
#     sudo bash install.sh                 # or: sudo bash install.sh --dry-run
#
# Installs the read-only agent to /opt/shield and a systemd timer that refreshes
# /var/lib/shield/state/latest.json. Opens NO network port. Idempotent.
set -euo pipefail

SHIELD_HOME="/opt/shield"
STATE_DIR="/var/lib/shield/state"
INTERVAL="5min"
DRY_RUN=false

for arg in "$@"; do
  case "${arg}" in
    --dry-run)      DRY_RUN=true ;;
    --interval=*)   INTERVAL="${arg#*=}" ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^#\s\?//'; exit 0 ;;
    *) echo "Unknown option: ${arg}" >&2; exit 2 ;;
  esac
done

log() { printf '[shield-install] %s\n' "$*"; }
# shellcheck disable=SC2294  # eval is intentional: run() previews or executes a command string
run() { if ${DRY_RUN}; then log "DRY: $*"; else eval "$@"; fi; }

# --- Preconditions ---------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root:  sudo bash install.sh" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/agent"
if [ ! -d "${SRC_DIR}" ]; then
  echo "Could not find ./agent next to install.sh — run this from the cloned repo." >&2
  exit 1
fi

# --- Detect environment ----------------------------------------------------
os_pretty="unknown"; os_id=""; os_like=""
# shellcheck disable=SC1091
if [ -r /etc/os-release ]; then . /etc/os-release; os_pretty="${PRETTY_NAME:-unknown}"; os_id="${ID:-}"; os_like="${ID_LIKE:-}"; fi
log "OS: ${os_pretty}   arch: $(uname -m)   kernel: $(uname -r)"

case "${os_id} ${os_like}" in
  *debian*|*ubuntu*) : ;;
  *) log "WARNING: v1 targets Debian/Ubuntu. apt-based collectors may report 'none' here." ;;
esac

# --- Dependencies ----------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  log "Installing dependency: jq"
  if command -v apt-get >/dev/null 2>&1; then
    run "apt-get update -y && apt-get install -y jq"
  else
    echo "jq is required but no apt-get found — install jq manually and re-run." >&2
    exit 1
  fi
fi

# inotify-tools powers the real-time file-integrity sensor (shield-watch).
# Optional — if it can't be installed, the sensor is simply skipped.
if ! command -v inotifywait >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  log "Installing dependency: inotify-tools (real-time file sensor)"
  run "apt-get install -y inotify-tools || true"
fi

# --- Install agent files ---------------------------------------------------
log "Installing agent -> ${SHIELD_HOME}"
run "install -d -m 0755 '${SHIELD_HOME}' '${STATE_DIR}' '${STATE_DIR%/state}/feeds'"
run "install -d -m 0755 '${SHIELD_HOME}/collectors' '${SHIELD_HOME}/scanners' '${SHIELD_HOME}/actions' '${SHIELD_HOME}/tools' '${SHIELD_HOME}/sensors'"
run "install -m 0755 '${SRC_DIR}/shield-agent' '${SHIELD_HOME}/shield-agent'"
run "install -m 0644 '${SRC_DIR}/VERSION' '${SHIELD_HOME}/VERSION'"
run "install -m 0755 ${SRC_DIR}/collectors/*.sh '${SHIELD_HOME}/collectors/'"
run "install -m 0755 ${SRC_DIR}/scanners/*.sh '${SHIELD_HOME}/scanners/'"
run "install -m 0755 ${SRC_DIR}/actions/*.sh '${SHIELD_HOME}/actions/'"
run "install -m 0755 ${SRC_DIR}/sensors/*.sh '${SHIELD_HOME}/sensors/'"
if compgen -G "$(dirname "${SRC_DIR}")/tools/*.sh" >/dev/null 2>&1; then
  run "install -m 0755 $(dirname "${SRC_DIR}")/tools/*.sh '${SHIELD_HOME}/tools/'"
fi

# --- systemd service + timer (generated so --interval works) ----------------
if ! command -v systemctl >/dev/null 2>&1; then
  log "systemctl not found — this host is not systemd."
  log "Agent files are installed at ${SHIELD_HOME}. Add a cron entry to run"
  log "${SHIELD_HOME}/shield-agent periodically (e.g. every 5 minutes)."
  exit 1
fi
log "Installing systemd service + timer (interval: ${INTERVAL})"
if ${DRY_RUN}; then
  log "DRY: would write /etc/systemd/system/shield-agent.{service,timer}"
else
  cat > /etc/systemd/system/shield-agent.service <<EOF
[Unit]
Description=Ubuntu Public Shield agent (collect system state)
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SHIELD_HOME}/shield-agent
Nice=10
IOSchedulingClass=idle
# Runs as root (collectors need to read dpkg, ss -p, /root, authorized_keys),
# but sandboxed: read-only filesystem except the state dir, no new privileges.
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${STATE_DIR%/state}
ProtectHome=read-only
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
EOF

  cat > /etc/systemd/system/shield-agent.timer <<EOF
[Unit]
Description=Run Ubuntu Public Shield agent periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
EOF
fi

run "systemctl daemon-reload"
run "systemctl enable --now shield-agent.timer"

# --- Real-time file-integrity sensor (optional; needs inotify-tools) --------
if command -v inotifywait >/dev/null 2>&1; then
  log "Installing real-time file sensor (shield-watch.service)"
  if ! ${DRY_RUN}; then
    cat > /etc/systemd/system/shield-watch.service <<EOF
[Unit]
Description=Ubuntu Public Shield real-time file-integrity sensor
After=multi-user.target

[Service]
Type=simple
ExecStart=${SHIELD_HOME}/sensors/shield-watch.sh
Restart=always
RestartSec=5
Nice=10
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${STATE_DIR%/state}
ProtectHome=read-only
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
  fi
  run "systemctl daemon-reload"
  run "systemctl enable --now shield-watch.service"
else
  log "inotify-tools unavailable — skipping real-time sensor (periodic drift still covers persistence)."
fi

# --- Threat/vuln feeds (fetched on a timer) ---------------------------------
log "Installing feed fetcher (shield-feeds.timer)"
if ! ${DRY_RUN}; then
  cat > /etc/systemd/system/shield-feeds.service <<EOF
[Unit]
Description=Ubuntu Public Shield feed fetcher (threat-intel + vuln bundles)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SHIELD_HOME}/tools/fetch-feeds.sh
Nice=15
IOSchedulingClass=idle
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${STATE_DIR%/state}
ProtectHome=yes
PrivateTmp=yes
EOF

  cat > /etc/systemd/system/shield-feeds.timer <<EOF
[Unit]
Description=Refresh Ubuntu Public Shield threat/vuln feeds

[Timer]
OnBootSec=2min
OnUnitActiveSec=12h
Persistent=true

[Install]
WantedBy=timers.target
EOF
fi
run "systemctl daemon-reload"
run "systemctl enable --now shield-feeds.timer"

# Fetch once now so the first collection already has feed data.
log "Fetching feeds (first run)"
run "'${SHIELD_HOME}/tools/fetch-feeds.sh' || true"

# --- First run -------------------------------------------------------------
log "Running first collection"
run "'${SHIELD_HOME}/shield-agent' || true"

log "Done."
log "State file: ${STATE_DIR}/latest.json"
if ! ${DRY_RUN}; then
  log "Preview:"
  jq '.meta, .system, .updates, {ports_public_count}' "${STATE_DIR}/latest.json" 2>/dev/null || true
fi
