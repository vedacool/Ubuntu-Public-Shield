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

It is a **fleet defence console**: one desktop app watches and safely manages many
servers over SSH; each server runs a lightweight, read-only **agent** with no open
ports. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/STACK.md](docs/STACK.md).

## Status

Early build. The **agent + installer** work now (v1: system facts, listening ports
with public-exposure flag, pending security updates). The desktop app and the rest
of the five-function roadmap are in [BACKLOG.md](BACKLOG.md).

## Install the agent (on each server you want to protect)

```bash
git clone https://github.com/vedacool/Ubuntu-Public-Shield.git
cd Ubuntu-Public-Shield
sudo bash install.sh            # preview first with: sudo bash install.sh --dry-run
```

This installs the agent to `/opt/shield`, adds a systemd timer (default every 5 min:
`--interval=10min` to change), and writes state to `/var/lib/shield/state/latest.json`.
**No network port is opened.** Inspect the state any time:

```bash
jq . /var/lib/shield/state/latest.json
```

## Getting started (development)

```bash
sudo apt-get install -y shellcheck bats jq   # dev tooling
bats tests/                                    # run the test suite
```

## Layout

| Path | What |
|------|------|
| `install.sh` | installs the agent on a server (idempotent, `--dry-run`) |
| `agent/` | the agent runner (`shield-agent`) + `collectors/*.sh` |
| `docs/` | `ARCHITECTURE.md`, `STACK.md` — the design + pinned versions |
| `.github/workflows/ci.yml` | CI: shellcheck → bats → gitleaks on every push/PR |
| `tests/` | `bats` test suite |
| `CONVENTIONS.md` | script style, idempotency/dry-run/host-guard rules |
| `CODEMAP/` | code map (`INVARIANTS.md` is the must-read for safe changes) |
| `SECURITY-OPS-CHECKLIST.md` | what this repo and the target server must satisfy |

## Safety principles

Every hardening script is **idempotent**, supports **`--dry-run`**, **backs up**
config before editing, and **guards against locking you out** (verifies a working
SSH path before disabling fallbacks). See [CODEMAP/INVARIANTS.md](CODEMAP/INVARIANTS.md).
