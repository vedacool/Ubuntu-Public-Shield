# Conventions — Ubuntu Public LAMP Server Shield

How this project does things, so changes stay consistent and onboarding is fast.

## What this is
A toolkit that hardens a **public-facing Ubuntu LAMP server** (firewall, SSH,
Apache, MySQL/MariaDB, PHP, fail2ban, auto-updates). Primarily Bash scripts plus
hardened config files; Ansible may be added later.

## Running the project
- Install (dev tooling): `sudo apt-get install -y shellcheck bats`
- Test: `bats tests/`
- Lint: `shellcheck -x <script>.sh` (CI lints every shell script in the repo)
- Regenerate the code map: `python scripts/gen_codemap.py --root . --out CODEMAP` (once code exists)

## Config
- All operator config comes from the environment; required keys are documented in `.env.example`.
- **Never commit `.env`, keys, certs, DB dumps, or `vault_pass`.** Secret scanning (gitleaks) runs in CI.
- Prefer prompting for or sourcing secrets at runtime over writing them to disk.

## Shell script style
- Start every script with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Must pass `shellcheck -x` clean (or carry a justified inline `# shellcheck disable=` with a reason).
- **Idempotent**: re-running a script must not double-apply or break existing state (check-before-change).
- **Dry-run friendly**: support a `--dry-run` flag that prints intended changes without applying.
- **Refuse the wrong host**: a script that mutates system state must confirm it's the intended target
  (e.g. compare against `TARGET_HOSTNAME`) and require an explicit confirmation before touching firewall/SSH.
- **Back up before you overwrite**: snapshot any system config file before editing it.

## Tests
- One `.bats` file per script area (`tests/ufw.bats`, `tests/sshd.bats`, …).
- The deploy/apply path runs the tests and **aborts if they fail** — a red build never ships.

## Commits & branches
- Work on a branch, open a PR into `main`; CI (shellcheck/bats/gitleaks) must be green to merge.

## Keeping the map current
- Regenerate `CODEMAP/` after a structural change (new script area/module).
- Durable rules and the "why" live in `CODEMAP/INVARIANTS.md` (hand-maintained).
