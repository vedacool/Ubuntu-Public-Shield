#!/usr/bin/env bats
#
# Matcher tests — the native "brain" pieces. Vuln matching is verified against
# REAL dpkg version semantics on the CI runner (bash is always installed).

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  export SHIELD_FEED_DIR="${BATS_TEST_TMPDIR}/feeds"
  mkdir -p "${SHIELD_FEED_DIR}"
}

@test "threat-intel: no feed -> feed_present false, valid JSON" {
  run bash "${REPO}/agent/collectors/80-threat-intel.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.threat_intel.feed_present == false' >/dev/null
}

@test "threat-intel: with feed -> feed_present true and matches is an array" {
  printf '%s\n' '203.0.113.7' '# a comment' '198.51.100.9' > "${SHIELD_FEED_DIR}/threat-ips.txt"
  run bash "${REPO}/agent/collectors/80-threat-intel.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.threat_intel.feed_present == true and (.threat_intel.matches | type == "array")' >/dev/null
}

@test "vulns: no feed -> feed_present false, valid JSON" {
  run bash "${REPO}/agent/collectors/90-vulns.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.vulns.feed_present == false' >/dev/null
}

@test "vulns: flags an installed package whose fixed_version is higher" {
  # bash is installed on the runner; a fixed_version of 999:9 is always greater.
  printf 'bash\t999:9-1\tCVE-TEST-0001\tcritical\n' > "${SHIELD_FEED_DIR}/vulns.tsv"
  run bash "${REPO}/agent/collectors/90-vulns.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.vulns.vulnerable | any(.package == "bash")' >/dev/null
  # CVEs are now grouped per-package into a .cves array
  echo "$output" | jq -e '.vulns.vulnerable[] | select(.package=="bash") | .cves | any(. == "CVE-TEST-0001")' >/dev/null
  # apt-candidate cross-check classifies every finding as available/pending
  echo "$output" | jq -e '.vulns.vulnerable[] | select(.package=="bash") | (.status=="fix_available" or .status=="fix_pending")' >/dev/null
  # counts are consistent: available + pending == vulnerable packages
  echo "$output" | jq -e '.vulns.cve_count >= 1 and (.vulns.fix_available_count + .vulns.fix_pending_count == .vulns.vulnerable_count)' >/dev/null
}

@test "vulns: does NOT flag when installed version already meets the fix" {
  printf 'bash\t0.0.1\tCVE-TEST-0002\tlow\n' > "${SHIELD_FEED_DIR}/vulns.tsv"
  run bash "${REPO}/agent/collectors/90-vulns.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.vulns.vulnerable | any(.package == "bash") | not' >/dev/null
}

@test "vulns: ignores packages that are not installed" {
  printf 'this-pkg-does-not-exist-xyz\t9.9\tCVE-TEST-0003\thigh\n' > "${SHIELD_FEED_DIR}/vulns.tsv"
  run bash "${REPO}/agent/collectors/90-vulns.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.vulns.vulnerable_count == 0' >/dev/null
}
