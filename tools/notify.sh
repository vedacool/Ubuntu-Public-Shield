#!/usr/bin/env bash
# Send a push alert via ntfy (outbound only — the server never listens).
# Fires only when SHIELD_NTFY_URL is configured (the user's own topic), so it is
# inert by default. The desktop brain calls this; it does not self-trigger.
#
#   SHIELD_NTFY_URL=https://ntfy.sh/your-topic \
#     tools/notify.sh "High" "webshell found on web01: /var/www/x.php"
#
# Args: <priority: min|low|default|high|urgent> <message...>
set -euo pipefail

URL="${SHIELD_NTFY_URL:-}"
priority="${1:-default}"
shift || true
message="$*"

if [ -z "${URL}" ]; then
  echo "notify: SHIELD_NTFY_URL not set — alert not sent (this is fine if unconfigured)" >&2
  exit 0
fi
[ -n "${message}" ] || { echo "notify: empty message" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "notify: curl required" >&2; exit 1; }

curl -fsS --max-time 15 \
  -H "Title: Ubuntu Public Shield" \
  -H "Priority: ${priority}" \
  -H "Tags: shield,warning" \
  -d "${message}" \
  "${URL}" >/dev/null 2>&1 \
  && echo "notify: sent (${priority})" \
  || { echo "notify: send failed" >&2; exit 1; }
