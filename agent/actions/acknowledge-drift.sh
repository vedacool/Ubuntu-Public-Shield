#!/usr/bin/env bash
# Action: acknowledge ONE persistence-drift item, informed and per-item — the
# safe replacement for the blunt accept-all rebaseline.
#
#   --verdict mine        fold this exact fingerprint into the trusted baseline
#                         so it stops alarming (you confirmed it's you).
#   --verdict suspicious  record + flag it (stays visible, logged) for follow-up.
#
# Usage: acknowledge-drift.sh --fp "<fingerprint>" --verdict mine|suspicious [--apply]
# Without --apply it previews (changes nothing). Every apply is appended to an
# audit log. Only our own fingerprint kinds are accepted; the value is never eval'd.
set -euo pipefail

BASELINE_DIR="${SHIELD_BASELINE_DIR:-/var/lib/shield/baseline}"
STATE_DIR="${SHIELD_STATE_DIR:-/var/lib/shield/state}"
SNAP="${BASELINE_DIR}/persistence.snapshot"
FLAGGED="${BASELINE_DIR}/flagged.snapshot"
LOG="${STATE_DIR}/acknowledged.tsv"

fp=""
verdict=""
apply=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fp) fp="${2:-}"; shift 2 ;;
    --verdict) verdict="${2:-}"; shift 2 ;;
    --apply) apply=1; shift ;;
    --preview) apply=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Accept only our known fingerprint kinds — defence against a malformed/hostile fp.
case "${fp}" in
  authkey:* | cron:* | usercron:* | unit:* | suid:*) : ;;
  *)
    jq -n '{action:"acknowledge-drift", ok:false, error:"invalid or missing --fp"}'
    exit 2
    ;;
esac
case "${verdict}" in
  mine | suspicious) : ;;
  *)
    jq -n '{action:"acknowledge-drift", ok:false, error:"--verdict must be mine|suspicious"}'
    exit 2
    ;;
esac

mode="preview"
[ "${apply}" = 1 ] && mode="apply"

emit() { # <ok-bool> <note>
  jq -n --argjson ok "$1" --arg note "$2" \
    --arg m "${mode}" --arg v "${verdict}" --arg fp "${fp}" \
    '{action:"acknowledge-drift", ok:$ok, mode:$m, verdict:$v, fp:$fp, note:$note}'
}

if [ "${apply}" != 1 ]; then
  if [ "${verdict}" = mine ]; then
    emit true "would add this item to the trusted baseline — it stops alarming"
  else
    emit true "would flag this item as suspicious — it stays visible and is logged"
  fi
  exit 0
fi

mkdir -p "${BASELINE_DIR}" "${STATE_DIR}"
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "${verdict}" "${fp}" >> "${LOG}"

if [ "${verdict}" = mine ]; then
  { [ -f "${SNAP}" ] && cat "${SNAP}"; printf '%s\n' "${fp}"; } | LC_ALL=C sort -u > "${SNAP}.new"
  mv -f "${SNAP}.new" "${SNAP}"
  # If it had been flagged before, clear that flag now that it's trusted.
  if [ -f "${FLAGGED}" ]; then
    grep -vxF "${fp}" "${FLAGGED}" > "${FLAGGED}.new" 2>/dev/null || true
    mv -f "${FLAGGED}.new" "${FLAGGED}"
  fi
  emit true "added to trusted baseline"
else
  { [ -f "${FLAGGED}" ] && cat "${FLAGGED}"; printf '%s\n' "${fp}"; } | LC_ALL=C sort -u > "${FLAGGED}.new"
  mv -f "${FLAGGED}.new" "${FLAGGED}"
  emit true "flagged as suspicious"
fi
