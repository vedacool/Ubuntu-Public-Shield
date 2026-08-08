#!/usr/bin/env bats
#
# Agent tests — every collector and the agent runner must emit valid JSON even
# on a minimal/non-root host (defensive by design). These run on the CI Ubuntu
# runner; collectors that need root or apt degrade gracefully rather than fail.
#
# NOTE: the webshell test builds its malicious sample from split fragments at
# runtime. Do NOT put a literal PHP webshell string in this file — antivirus on
# a Windows dev machine will quarantine the whole test file as malware.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  export SHIELD_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  export SHIELD_BASELINE_DIR="${BATS_TEST_TMPDIR}/baseline"
  mkdir -p "${SHIELD_STATE_DIR}" "${SHIELD_BASELINE_DIR}"
}

@test "jq is available" {
  run command -v jq
  [ "$status" -eq 0 ]
}

@test "each collector emits valid JSON" {
  for c in "${REPO}"/agent/collectors/*.sh; do
    run bash "$c"
    [ "$status" -eq 0 ] || { echo "collector failed: $c"; return 1; }
    echo "$output" | jq -e . >/dev/null || { echo "invalid JSON from: $c"; return 1; }
  done
}

@test "sysinfo collector reports a hostname" {
  run bash "${REPO}/agent/collectors/10-sysinfo.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.system.hostname | length > 0' >/dev/null
}

@test "ports collector returns a ports array" {
  run bash "${REPO}/agent/collectors/20-ports.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ports | type == "array"' >/dev/null
}

@test "drift collector establishes a baseline on first run" {
  run bash "${REPO}/agent/collectors/60-drift.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.drift.baseline_created == true' >/dev/null
}

@test "drift collector reports no changes on an unchanged second run" {
  bash "${REPO}/agent/collectors/60-drift.sh" >/dev/null
  run bash "${REPO}/agent/collectors/60-drift.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.drift.added_count == 0 and .drift.removed_count == 0' >/dev/null
}

@test "webshell scanner flags an obvious shell and ignores a clean file" {
  webroot="${BATS_TEST_TMPDIR}/www"
  mkdir -p "${webroot}"
  # Assemble from fragments so no literal webshell signature is stored on disk.
  local open="<?""php" sink="ev""al"
  printf '%s echo "hello world"; ?>\n' "${open}" > "${webroot}/clean.php"
  printf '%s @%s($_POST["x"]); ?>\n' "${open}" "${sink}" > "${webroot}/shell.php"
  SHIELD_WEBROOTS="${webroot}" run bash "${REPO}/agent/scanners/webshell-scan.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.webshell.findings | any(.file | endswith("shell.php"))' >/dev/null
  echo "$output" | jq -e '.webshell.findings | any(.file | endswith("clean.php")) | not' >/dev/null
}

@test "agent runner merges collectors into one document with meta" {
  SHIELD_HOME="${REPO}/agent" run bash "${REPO}/agent/shield-agent"
  [ "$status" -eq 0 ]
  [ -f "${SHIELD_STATE_DIR}/latest.json" ]
  jq -e '.meta.agent_version and .system and (.ports | type == "array")' "${SHIELD_STATE_DIR}/latest.json" >/dev/null
}
