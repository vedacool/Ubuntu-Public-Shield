#!/usr/bin/env bats
#
# Real-time file-integrity sensor tests. The shield-watch daemon itself is
# exercised during live testing (it's a long-running inotify service); here we
# test the collector that surfaces its event log.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  export SHIELD_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${SHIELD_STATE_DIR}"
}

@test "file-events collector: no log -> watching:false, valid JSON" {
  run bash "${REPO}/agent/collectors/45-file-events.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.file_events.watching == false and .file_events.total == 0' >/dev/null
}

@test "file-events collector: parses events, counts by type, newest first" {
  log="${SHIELD_STATE_DIR}/file-events.log"
  printf '%s\twebshell-suspect\t%s\tCREATE\n' "2026-08-09T00:00:00Z" "/var/www/html/a.php" >> "$log"
  printf '%s\tpersistence\t%s\tMODIFY\n' "2026-08-09T00:01:00Z" "/etc/crontab" >> "$log"
  printf '%s\twebshell-suspect\t%s\tMODIFY\n' "2026-08-09T00:02:00Z" "/var/www/html/b.php" >> "$log"

  run bash "${REPO}/agent/collectors/45-file-events.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.file_events.watching == true' >/dev/null
  echo "$output" | jq -e '.file_events.total == 3' >/dev/null
  echo "$output" | jq -e '.file_events.webshell_suspect == 2' >/dev/null
  echo "$output" | jq -e '.file_events.persistence == 1' >/dev/null
  echo "$output" | jq -e '.file_events.recent | length == 3' >/dev/null
  echo "$output" | jq -e '.file_events.recent[0].path == "/var/www/html/b.php"' >/dev/null
}
