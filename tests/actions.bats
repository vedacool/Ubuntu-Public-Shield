#!/usr/bin/env bats
# Per-item acknowledge action — the safe replacement for accept-all rebaseline.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  ACK="${REPO}/agent/actions/acknowledge-drift.sh"
  export SHIELD_BASELINE_DIR="${BATS_TEST_TMPDIR}/baseline"
  export SHIELD_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${SHIELD_BASELINE_DIR}" "${SHIELD_STATE_DIR}"
  FP='authkey:/home/tester/.ssh/authorized_keys:deadbeef'
}

@test "acknowledge: preview (mine) changes nothing, ok:true" {
  run bash "${ACK}" --fp "${FP}" --verdict mine
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .mode == "preview" and .verdict == "mine"' >/dev/null
  [ ! -f "${SHIELD_BASELINE_DIR}/persistence.snapshot" ]
}

@test "acknowledge: rejects an unknown fingerprint kind" {
  run bash "${ACK}" --fp 'evil:rm -rf /' --verdict mine
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.ok == false' >/dev/null
}

@test "acknowledge: rejects a bad verdict" {
  run bash "${ACK}" --fp "${FP}" --verdict whatever
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.ok == false' >/dev/null
}

@test "acknowledge --apply mine: folds the fingerprint into the baseline" {
  run bash "${ACK}" --fp "${FP}" --verdict mine --apply
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .mode == "apply"' >/dev/null
  grep -qxF "${FP}" "${SHIELD_BASELINE_DIR}/persistence.snapshot"
  grep -qF "mine" "${SHIELD_STATE_DIR}/acknowledged.tsv"
}

@test "acknowledge --apply suspicious: records to flagged, not baseline" {
  run bash "${ACK}" --fp "${FP}" --verdict suspicious --apply
  [ "$status" -eq 0 ]
  grep -qxF "${FP}" "${SHIELD_BASELINE_DIR}/flagged.snapshot"
  [ ! -f "${SHIELD_BASELINE_DIR}/persistence.snapshot" ]
}

@test "acknowledge mine clears a prior suspicious flag" {
  bash "${ACK}" --fp "${FP}" --verdict suspicious --apply
  bash "${ACK}" --fp "${FP}" --verdict mine --apply
  grep -qxF "${FP}" "${SHIELD_BASELINE_DIR}/persistence.snapshot"
  run grep -qxF "${FP}" "${SHIELD_BASELINE_DIR}/flagged.snapshot"
  [ "$status" -ne 0 ]
}
