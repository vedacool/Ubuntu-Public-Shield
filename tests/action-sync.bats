#!/usr/bin/env bats
#
# The action allowlist is declared in four places that must stay in sync:
#   - desktop/src-tauri/src/lib.rs  (ACTIONS — the security gate)
#   - agent/security/shield-sudoers.example  (SHIELD_APPLY — the privilege grant)
#   - desktop/src/routes/+page.svelte  (the UI buttons)
#   - desktop/src/lib/types.ts  (the ActionName type)
# Drift here means a broken button, a rejected action, or a privilege mismatch.

setup() { REPO="${BATS_TEST_DIRNAME}/.."; }

@test "action allowlist is identical across lib.rs, sudoers, svelte and types" {
  # Canonical set = the .sh names quoted inside the Rust ACTIONS array block
  # (scoped so test-module strings elsewhere in lib.rs don't leak in).
  mapfile -t acts < <(awk '/const ACTIONS/,/\];/' "${REPO}/desktop/src-tauri/src/lib.rs" \
    | grep -oE '"[a-z][a-z-]*\.sh"' | tr -d '"' | sort -u)
  [ "${#acts[@]}" -eq 4 ] || { echo "expected 4 actions in lib.rs, got ${#acts[@]}"; return 1; }

  for a in "${acts[@]}"; do
    grep -q "$a" "${REPO}/agent/security/shield-sudoers.example" || { echo "missing in sudoers: $a"; return 1; }
    grep -q "$a" "${REPO}/desktop/src/routes/+page.svelte" || { echo "missing in svelte: $a"; return 1; }
    grep -q "$a" "${REPO}/desktop/src/lib/types.ts" || { echo "missing in types.ts: $a"; return 1; }
  done

  # No EXTRA action script granted in the sudoers SHIELD_APPLY set.
  extra="$(grep -oE 'actions/[a-z][a-z-]*\.sh' "${REPO}/agent/security/shield-sudoers.example" | sed 's#actions/##' | sort -u)"
  [ "$(printf '%s\n' "${acts[@]}" | sort -u)" = "${extra}" ] \
    || { echo "sudoers actions differ from canonical"; return 1; }
}
