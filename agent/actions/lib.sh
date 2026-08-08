#!/usr/bin/env bash
# Common helpers for shield action scripts.
#
# SAFETY MODEL (see CODEMAP/INVARIANTS.md): every action is preview-by-default.
#   --preview (default): read-only. Prints JSON describing what it WOULD do.
#   --apply           : performs the change and appends an audit line to the log.
# The desktop app runs --preview, shows it, waits for the user to confirm, then
# runs --apply. Nothing changes without an explicit --apply.
set -euo pipefail

SHIELD_LOG_DIR="${SHIELD_LOG_DIR:-/var/lib/shield/log}"
ACTION_LOG="${ACTION_LOG:-${SHIELD_LOG_DIR}/actions.log}"

# action_mode "$@" -> "preview" | "apply"
action_mode() {
  local mode="preview" a
  for a in "$@"; do
    case "${a}" in
      --apply) mode="apply" ;;
      --preview) mode="preview" ;;
    esac
  done
  printf '%s' "${mode}"
}

# log_action <action> <mode> <summary>
log_action() {
  mkdir -p "${SHIELD_LOG_DIR}" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" >> "${ACTION_LOG}" 2>/dev/null || true
}

# lines_to_json_array <newline-separated-string>
lines_to_json_array() {
  if [ -z "${1:-}" ]; then echo '[]'; else printf '%s\n' "$1" | jq -R . | jq -s '. - [""]'; fi
}
