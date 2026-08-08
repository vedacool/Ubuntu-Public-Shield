#!/usr/bin/env bats
#
# Smoke test — proves the bats harness runs and CI is green from commit 1.
# Replace / expand these as real hardening scripts land (one .bats file per
# script area is a good pattern, e.g. tests/ufw.bats, tests/sshd.bats).

@test "bats harness is working" {
  run true
  [ "$status" -eq 0 ]
}

@test "repo has an .env.example (config contract exists)" {
  [ -f "${BATS_TEST_DIRNAME}/../.env.example" ]
}
