#!/usr/bin/env bash
#
# Real-time file-integrity sensor (v2). Watches security-relevant paths with
# inotify and appends only SECURITY-relevant events to an event log that the
# 45-file-events collector surfaces. Runs as a continuous systemd service
# (Restart=always) — the real-time complement to the 5-minute drift collector.
#
# Two event classes:
#   webshell-suspect : a *.php/.phtml/.phar/etc file created/modified in a web root
#   persistence      : any change under cron/systemd/authorized_keys/passwd/sudoers
#
# Deliberately NOT -e: this is long-running and must survive transient hiccups.
set -uo pipefail

STATE_DIR="${SHIELD_STATE_DIR:-/var/lib/shield/state}"
LOG="${STATE_DIR}/file-events.log"
WEBROOTS="${SHIELD_WEBROOTS:-/var/www}"
LOG_CAP="${SHIELD_WATCH_LOGCAP:-2000}"

mkdir -p "${STATE_DIR}"
command -v inotifywait >/dev/null 2>&1 || {
  echo "shield-watch: inotifywait not found (install inotify-tools)" >&2
  exit 1
}

# Web roots (space-separated) that exist.
webroots=()
# shellcheck disable=SC2086  # intentional split of space-separated web roots
for r in ${WEBROOTS}; do
  [ -d "${r}" ] && webroots+=("${r}")
done

# Persistence paths worth watching (rarely change → any event is interesting).
persist=()
for p in /etc/crontab /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly \
         /etc/systemd/system /root/.ssh /etc/passwd /etc/sudoers /etc/sudoers.d; do
  [ -e "${p}" ] && persist+=("${p}")
done
for h in /home/*/.ssh; do
  [ -d "${h}" ] && persist+=("${h}")
done

watch=("${webroots[@]}" "${persist[@]}")
if [ "${#watch[@]}" -eq 0 ]; then
  echo "shield-watch: nothing to watch" >&2
  exit 0
fi

is_php() {
  case "$1" in
    *.php | *.phtml | *.phar | *.php5 | *.inc) return 0 ;;
    *) return 1 ;;
  esac
}

log_event() { # <type> <path> <events>
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" >> "${LOG}"
  # Keep the log bounded.
  local n
  n="$(wc -l < "${LOG}" 2>/dev/null || echo 0)"
  if [ "${n}" -gt "$((LOG_CAP + 500))" ]; then
    tail -n "${LOG_CAP}" "${LOG}" > "${LOG}.tmp" && mv -f "${LOG}.tmp" "${LOG}"
  fi
}

echo "shield-watch: watching ${#watch[@]} paths" >&2

# -m monitor (continuous), -r recursive, quiet. Format: <fullpath>|<events>
inotifywait -m -r -q -e create -e modify -e moved_to -e attrib \
  --format '%w%f|%e' "${watch[@]}" |
  while IFS='|' read -r path events; do
    [ -n "${path}" ] || continue

    matched=0
    for r in "${webroots[@]}"; do
      if [[ "${path}" == "${r}"* ]] && is_php "${path}"; then
        log_event "webshell-suspect" "${path}" "${events}"
        matched=1
        break
      fi
    done
    [ "${matched}" -eq 1 ] && continue

    for p in "${persist[@]}"; do
      if [[ "${path}" == "${p}"* ]]; then
        log_event "persistence" "${path}" "${events}"
        break
      fi
    done
  done
