#!/usr/bin/env bats
#
# The privileged-action set is declared in several places that must stay in sync:
#   - desktop/src-tauri/src/lib.rs           (run_action ACTIONS — the gate)
#   - desktop/src/routes/+page.svelte        (the buttons)
#   - desktop/src/lib/types.ts               (ActionName)
#   - agent/security/shield-sudoers.example  (the NOPASSWD grant)
#
# acknowledge-drift.sh is privileged too, but it's invoked via its own validated
# command (acknowledge_drift), not run_action — so it lives in lib.rs + sudoers,
# not the button allowlist. It replaced the blanket rebaseline-drift.

setup() { REPO="${BATS_TEST_DIRNAME}/.."; }

actions_in_lib() {
  awk '/const ACTIONS/,/\];/' "${REPO}/desktop/src-tauri/src/lib.rs" \
    | grep -oE '"[a-z][a-z-]*\.sh"' | tr -d '"'
}

@test "run_action button allowlist is in sync (lib.rs = svelte = types = sudoers)" {
  mapfile -t acts < <(actions_in_lib | sort -u)
  [ "${#acts[@]}" -eq 3 ] || { echo "expected 3 button actions in lib.rs, got ${#acts[@]}"; return 1; }
  for a in "${acts[@]}"; do
    grep -q "$a" "${REPO}/agent/security/shield-sudoers.example" || { echo "missing in sudoers: $a"; return 1; }
    grep -q "$a" "${REPO}/desktop/src/routes/+page.svelte" || { echo "missing in svelte: $a"; return 1; }
    grep -q "$a" "${REPO}/desktop/src/lib/types.ts" || { echo "missing in types.ts: $a"; return 1; }
  done
}

@test "acknowledge-drift is granted in sudoers and wired in lib.rs" {
  grep -q 'acknowledge-drift.sh' "${REPO}/desktop/src-tauri/src/lib.rs"
  grep -q 'acknowledge-drift.sh' "${REPO}/agent/security/shield-sudoers.example"
}

@test "sudoers grants exactly the button actions + acknowledge-drift, nothing else" {
  granted="$(grep -oE 'actions/[a-z][a-z-]*\.sh' "${REPO}/agent/security/shield-sudoers.example" \
    | sed 's#actions/##' | sort -u)"
  mapfile -t acts < <(actions_in_lib)
  expected="$(printf '%s\n' "${acts[@]}" acknowledge-drift.sh | sort -u)"
  [ "${granted}" = "${expected}" ] || {
    echo "sudoers grant != buttons + acknowledge"; echo "granted:"; echo "${granted}"; echo "expected:"; echo "${expected}"; return 1;
  }
}
