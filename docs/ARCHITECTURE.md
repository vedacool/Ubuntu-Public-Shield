# Architecture — Ubuntu Public Shield

## What this is
A **fleet defence console**: one desktop app (on your PC) that watches and safely
manages many servers (public Ubuntu LAMP box, Raspberry Pi, more later). It is
both **prevention** (hardening — the "Shield") and **detection + safe response**.

Its job, for a non-expert with no time: **do the expert thinking for you** —
detect, explain in plain English, prioritise ("do this one thing now"), and guide
or one-click the fix.

## The shape

```
                    ┌─ Your PC ─────────────────────┐
                    │  Defence Dashboard (Tauri app)│
                    │  - fleet view + drill-down    │
                    │  - correlation "brain"        │
                    │  - fetches data feeds centrally│
                    └───────────────┬───────────────┘
                                    │ SSH (read state / run confirmed actions)
             ┌──────────────────────┼──────────────────────┐
             ▼                      ▼                      ▼
   ┌─ Ubuntu server ─┐   ┌─ RPi server ────┐   ┌─ future server ─┐
   │ shield agent    │   │ shield agent    │   │ shield agent    │
   │ (no open ports) │   │ (no open ports) │   │ (no open ports) │
   └─────────────────┘   └─────────────────┘   └─────────────────┘
```

## Deployment model
- The **agent + `install.sh`** live in this (public) repo.
- On each server you run `sudo bash install.sh`. It installs the agent to
  `/opt/shield`, sets up a systemd timer, and writes state to
  `/var/lib/shield/state/latest.json`. **No port is opened.**
- The **desktop app** connects over the SSH you already have, reads the agent's
  JSON state, and (later) runs confirmed actions. Nothing new is exposed to the
  internet on any server.

## Why "orchestrate + a native brain", not "rebuild everything"
Threats change daily; the value of AV signatures / CVE data / threat-intel / a
community IPS is the **continuously-maintained data**, not the code. Rebuilding
those means becoming their full-time maintainer (the opposite of "no time") and
risks *false confidence*. So:

- **Build native** where the value is logic we control and it has no live-data
  dependency: the agent framework + one unified event model, drift/persistence
  detection, port/connection monitoring, the **webshell scoring engine**, the
  anomaly + correlation **brain**, the vuln/threat-intel *matchers*, the dashboard.
- **Consume** where value = live global data or a security-critical parser:
  Netdata, CrowdSec, Lynis, AIDE, chkrootkit, ClamAV/YARA-X rules; data feeds
  (Ubuntu OVAL/USN, OSV, abuse.ch Feodo, Spamhaus DROP, DB-IP Lite).
- The cure for "bolted-on" is the **integration layer**: consumed tools are
  normalised into the same event model as everything we build, so from the
  outside it is one coherent product.

## The five functions (how features are organised)
1. **Identify** — asset/package/web-app inventory, ports (inside+outside), TLS certs, exposed secrets.
2. **Protect** — hardening + Lynis score, patching (apt + web-app), firewall, access/SSH-key audit, egress.
3. **Detect** — resources (Netdata), attacks (CrowdSec), file integrity (AIDE), **webshells**, rootkits/persistence, C2/outbound, login anomaly, **tamper/blinding detection of the guard itself**, log search.
4. **Respond** — phone alerts (ntfy), incident timeline/correlation, **guided one-click containment** (isolate keeping SSH, kill, block, disable), evidence capture.
5. **Recover** — backup + tested restore (restic), rollback, rebuild-from-clean, post-incident report.

## Build phasing
- **v1 (now):** agent + `install.sh` (this increment starts it); native collectors
  (sysinfo, ports, updates) → JSON state; desktop app reads it; drift baseline;
  webshell scorer; consume Lynis/CrowdSec/Netdata; vuln matcher over Ubuntu
  OVAL/OSV; threat-intel matcher over Feodo/DROP. All via **fanotify/inotify +
  `ss`/`/proc`** — works on every kernel, no eBPF.
- **v2:** native **eBPF sensor** via Rust `aya` (process-exec + outbound-connect +
  web-dir-write). Gated on kernel **BTF** presence (`/sys/kernel/btf/vmlinux`) —
  Raspberry Pi OS ships without BTF by default, so this falls back to the v1 path.
  De-risk with a 2-day cross-arch spike first. Plus NVD enrichment, more feeds,
  ML/LLM webshell classifier, BPF-LSM enforcement.

See `docs/STACK.md` for pinned versions and the full tool list.

## Safety invariants (see also CODEMAP/INVARIANTS.md)
- Nothing auto-applies: **preview → confirm → apply → log**; back up before change; rollback.
- **Never lock yourself out**: SSH/firewall changes verify access first.
- Scoped privilege (v2 sudoers), not blanket root; fleet changes one server at a time.
- The agent has **no listening port**; the desktop app is the only mover, over SSH.
