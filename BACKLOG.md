# Backlog — Ubuntu Public LAMP Server Shield

The single source of truth for tasks, findings, and the roadmap. `audit-software`
logs findings here (with severity + `file:line`); tick them when resolved.

## 🚩 Manual follow-ups from software-start
_Things the setup couldn't do for you — do these next._

- [ ] Create the GitHub remote and push `main` — this triggers the first CI run (shellcheck / bats / gitleaks).
- [ ] Enable Dependabot in the repo (GitHub → Settings → Code security) so `.github/dependabot.yml` takes effect.
- [ ] (Optional) Install the local pre-commit gitleaks hook: `git config core.hooksPath .githooks` (needs `gitleaks` on PATH).
- [ ] As real hardening scripts land, add a `.bats` file per script area and keep shellcheck clean.

## 🔧 To do

- [ ] Decide the top-level layout for scripts vs. config (e.g. `scripts/`, `config/`, `roles/`) and regenerate `CODEMAP/` once it exists.
- [ ] Add a safety guard so scripts refuse to run unless `TARGET_HOSTNAME` matches the current host.

## 🧱 Build queue (discussed, not yet greenlit)

- [ ] UFW firewall baseline (deny incoming, allow SSH/HTTP/HTTPS + `UFW_EXTRA_TCP_PORTS`).
- [ ] SSH hardening (move port, disable root login, key-only auth, `SSH_ALLOW_USER`).
- [ ] fail2ban for sshd + Apache auth.
- [ ] Apache hardening (disable server tokens/signature, TLS + HSTS, security headers, disable unused modules).
- [ ] MySQL/MariaDB hardening (`mysql_secure_installation` equivalent, least-priv app user).
- [ ] PHP hardening (`disable_functions`, `expose_php=Off`, open_basedir, upload limits).
- [ ] Automatic security updates (unattended-upgrades) + Let's Encrypt auto-renew.
- [ ] Consider migrating to Ansible for idempotent, declarative application.

## 🗺 Roadmap

- v0: individual bash hardening scripts, each shellcheck-clean and bats-tested.
- v1: single orchestrator script + `.env`-driven config + dry-run mode.
- v2: optional Ansible role for repeatable, idempotent runs across hosts.

## ✅ Done

- Project scaffolding via software-start (git, .gitignore, CI, tests, knowledge layer).
