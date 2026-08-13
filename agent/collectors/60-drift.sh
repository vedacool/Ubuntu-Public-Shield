#!/usr/bin/env bash
# Collector: persistence & drift detection. Snapshots security-relevant
# persistence points, compares to a stored baseline, and reports what was
# added/removed since. The first run establishes the baseline. Set
# SHIELD_REBASELINE=1 to accept the current state as the new baseline.
#
# Watched: authorized_keys, cron (system + per-user), admin systemd units,
# SUID/SGID binaries in standard bin dirs.
# Emits: { "drift": { baseline_created, added[], removed[], *_count } }
set -euo pipefail

BASELINE_DIR="${SHIELD_BASELINE_DIR:-/var/lib/shield/baseline}"
mkdir -p "${BASELINE_DIR}"
snap_file="${BASELINE_DIR}/persistence.snapshot"
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

hash_str() { sha256sum | cut -d' ' -f1; }

{
  # 1) authorized_keys (root + human homes), one line per key
  for akf in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -r "${akf}" ] || continue
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      case "${line}" in \#*) continue ;; esac
      printf 'authkey:%s:%s\n' "${akf}" "$(printf '%s' "${line}" | hash_str)"
    done < "${akf}"
  done

  # 2) cron: system drop-ins + per-user crontabs
  for cf in /etc/crontab /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* \
            /etc/cron.weekly/* /etc/cron.monthly/*; do
    [ -f "${cf}" ] || continue
    printf 'cron:%s:%s\n' "${cf}" "$(hash_str < "${cf}")"
  done
  # Read user crontab spool files directly. Using `crontab -l -u` instead would
  # fork per user AND emit a "LIST (user)" line to syslog on every run (log spam).
  # Debian: /var/spool/cron/crontabs ; RHEL/others: /var/spool/cron
  for spool in /var/spool/cron/crontabs/* /var/spool/cron/*; do
    [ -f "${spool}" ] || continue
    printf 'usercron:%s:%s\n' "$(basename "${spool}")" "$(hash_str < "${spool}")"
  done

  # 3) admin-defined systemd units
  for unit in /etc/systemd/system/*.service /etc/systemd/system/*.timer; do
    [ -f "${unit}" ] || continue
    printf 'unit:%s:%s\n' "${unit}" "$(hash_str < "${unit}")"
  done

  # 4) SUID/SGID binaries in standard locations
  for d in /usr/bin /usr/sbin /bin /sbin /usr/local/bin /usr/local/sbin; do
    [ -d "${d}" ] || continue
    while IFS= read -r f; do
      printf 'suid:%s\n' "${f}"
    done < <(find "${d}" -xdev -type f -perm /6000 2>/dev/null || true)
  done
} > "${tmp}"

# Force C collation so the baseline and later runs sort identically regardless
# of the ambient locale (timer vs shell) — otherwise comm reports false drift.
LC_ALL=C sort -u -o "${tmp}" "${tmp}"
watched="$(wc -l < "${tmp}" | tr -d ' ')"

# First run, or explicit re-baseline requested. Write atomically (tmp + mv) so an
# interrupted write can't leave a partial baseline that fakes drift next run.
if [ ! -f "${snap_file}" ] || [ "${SHIELD_REBASELINE:-0}" = "1" ]; then
  cp "${tmp}" "${snap_file}.new" && mv -f "${snap_file}.new" "${snap_file}"
  jq -n --argjson n "${watched}" \
    '{drift: {baseline_created: true, watched_items: $n,
              added: [], removed: [], added_count: 0, removed_count: 0}}'
  exit 0
fi

added="$(LC_ALL=C comm -13 "${snap_file}" "${tmp}" || true)"
removed="$(LC_ALL=C comm -23 "${snap_file}" "${tmp}" || true)"

to_json_array() {
  if [ -z "$1" ]; then echo '[]'; else printf '%s\n' "$1" | jq -R . | jq -s .; fi
}
added_json="$(to_json_array "${added}")"
removed_json="$(to_json_array "${removed}")"

# Fingerprints the user marked "suspicious" via the acknowledge action — kept
# visible (not folded into the baseline) so they keep showing until investigated.
FLAGGED="${BASELINE_DIR}/flagged.snapshot"
flagged_json='[]'
[ -r "${FLAGGED}" ] && flagged_json="$(to_json_array "$(cat "${FLAGGED}")")"

# Enrich each added item: parse kind + target from the fingerprint and mark
# whether it's brand-new or already flagged suspicious. Items the user confirmed
# as theirs are folded into the baseline, so they never reach here.
added_items="$(jq -n --argjson added "${added_json}" --argjson flagged "${flagged_json}" '
  ($flagged) as $fl
  | [ $added[] as $s
      | ($s | split(":")) as $p
      | (if $p[0] == "suid" then {kind: "suid", target: ($p[1:] | join(":"))}
         else {kind: $p[0], target: ($p[1:-1] | join(":"))} end)
      | . + {fp: $s, status: (if ($fl | index($s)) then "flagged" else "new" end)} ]')"
flagged_count="$(jq -n --argjson a "${added_items}" '[$a[] | select(.status == "flagged")] | length')"

jq -n \
  --argjson watched "${watched}" \
  --argjson added "${added_json}" \
  --argjson removed "${removed_json}" \
  --argjson items "${added_items}" \
  --argjson fc "${flagged_count}" \
  '{drift: {baseline_created: false, watched_items: $watched,
            added: $added, removed: $removed,
            added_count: ($added | length), removed_count: ($removed | length),
            added_items: $items, flagged_count: $fc}}'
