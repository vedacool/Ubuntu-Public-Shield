#!/usr/bin/env bats
#
# Action tests — preview mode must be read-only and emit valid JSON on any host.
# --apply paths need root/apt and are exercised during live testing, not CI.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  export SHIELD_HOME="${REPO}/agent"
  export SHIELD_LOG_DIR="${BATS_TEST_TMPDIR}/log"
  export SHIELD_BASELINE_DIR="${BATS_TEST_TMPDIR}/baseline"
  export SHIELD_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${SHIELD_LOG_DIR}" "${SHIELD_BASELINE_DIR}" "${SHIELD_STATE_DIR}"
}

@test "every action defaults to preview mode and emits valid JSON" {
  for a in "${REPO}"/agent/actions/*.sh; do
    case "$a" in */lib.sh) continue ;; esac
    run bash "$a"
    [ "$status" -eq 0 ] || { echo "action failed: $a"; return 1; }
    echo "$output" | jq -e '.mode == "preview" or (.error | length > 0)' >/dev/null \
      || { echo "not preview/valid: $a -> $output"; return 1; }
  done
}

@test "preview mode writes nothing to the action log" {
  bash "${REPO}/agent/actions/apply-security-updates.sh" >/dev/null || true
  [ ! -s "${SHIELD_LOG_DIR}/actions.log" ]
}

@test "rebaseline preview surfaces the current drift block" {
  run bash "${REPO}/agent/actions/rebaseline-drift.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "rebaseline-drift" and .mode == "preview"' >/dev/null
}

@test "webshell-scan --apply actually scans and refreshes state" {
  webroot="${BATS_TEST_TMPDIR}/www"
  mkdir -p "${webroot}"
  local open="<?""php"
  printf '%s echo 1; ?>\n' "${open}" > "${webroot}/i.php"
  SHIELD_WEBROOTS="${webroot}" run bash "${REPO}/agent/actions/run-webshell-scan.sh" --apply
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "run-webshell-scan" and .mode == "apply"' >/dev/null
  [ -f "${SHIELD_STATE_DIR}/webshell.json" ]
}
