# CODEMAP — Invariants (hand-maintained)

_The generator never touches this file. Put here the things a code scan can't see
and that matter most for changing the code safely._

## Rules that must stay true
- Every script that mutates system state is **idempotent** and supports **`--dry-run`**.
- A destructive/system-changing script **must confirm the target host** (compare against `TARGET_HOSTNAME`) and require explicit operator confirmation before touching firewall or SSH.
- **Never lock yourself out**: SSH changes (port move, key-only auth, root disable) must verify a working non-root key-based login path *before* disabling the fallback.
- Any system config file is **backed up** (timestamped copy) before being edited.
- No secrets, keys, certs, or DB dumps ever enter git history (enforced by `.gitignore` + gitleaks).

## Cross-module contracts
- All operator-facing config is read from the environment; the authoritative list of keys lives in `.env.example`. Add a key there whenever a script reads a new env var.
- Firewall rules and the SSH port must stay consistent: if a script changes `SSH_PORT`, the UFW rule for SSH must change in the same run.

## State machine / legal transitions
- Recommended apply order (each step assumes the previous succeeded): firewall baseline → SSH hardening (with lockout guard) → fail2ban → Apache/TLS → MySQL → PHP → unattended-upgrades. Reordering can lock out access or open a window of exposure.

## "If you change X, also change Y"
- Change the SSH port → update the UFW rule **and** `.env.example` **and** fail2ban's jail port.
- Add a new hardening script → add its `.bats` test and regenerate `CODEMAP/`.

## Why (design decisions worth remembering)
- Bash-first (not Ansible) for v0 so the toolkit runs on a fresh box with zero dependencies; Ansible is a later, optional layer for repeatability across many hosts.
- Config via `.env` + runtime prompts (not committed config) so the same repo is safe to publish publicly — a security tool must not itself leak the secrets it manages.
