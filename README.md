# Ubuntu Public LAMP Server Shield

A hardening toolkit for **public-facing Ubuntu LAMP servers** (Linux · Apache ·
MySQL/MariaDB · PHP). It applies well-known security baselines — firewall, SSH
hardening, fail2ban, Apache/TLS headers, database and PHP lockdown, automatic
security updates — as auditable, idempotent Bash scripts (with an optional
Ansible layer planned).

> ⚠️ **Run only on a server you own or are authorized to administer.** These
> scripts change firewall, SSH, web, and database configuration and can lock you
> out if misused. Always use `--dry-run` first, keep a second console open, and
> confirm you're on the intended host (`TARGET_HOSTNAME`).

## Status

Greenfield / scaffolding stage. See [BACKLOG.md](BACKLOG.md) for the build queue
and roadmap.

## Getting started (development)

```bash
sudo apt-get install -y shellcheck bats   # dev tooling
cp .env.example .env                        # fill in your target config (never commit .env)
bats tests/                                 # run the test suite
```

## Layout

| Path | What |
|------|------|
| `.github/workflows/ci.yml` | CI: shellcheck → bats → gitleaks on every push/PR |
| `tests/` | `bats` test suite (one file per script area) |
| `CONVENTIONS.md` | script style, idempotency/dry-run/host-guard rules |
| `CODEMAP/` | code map (`INVARIANTS.md` is the must-read for safe changes) |
| `SECURITY-OPS-CHECKLIST.md` | what this repo and the target server must satisfy |
| `.env.example` | the config contract (copy to `.env`) |

## Safety principles

Every hardening script is **idempotent**, supports **`--dry-run`**, **backs up**
config before editing, and **guards against locking you out** (verifies a working
SSH path before disabling fallbacks). See [CODEMAP/INVARIANTS.md](CODEMAP/INVARIANTS.md).
