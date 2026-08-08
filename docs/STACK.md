# Stack & tool versions — Ubuntu Public Shield

Verified 2026-08-08. Two stacks: the **product** (stable) and the **orchestrated
tools** (grow one at a time). Adding a feature = add a tool + a collector, never a
re-architecture.

## Product stack
Two columns: **Pin** = target; **Now** = what's actually in the repo today
(from `desktop/package.json` + `desktop/src-tauri/Cargo.toml` + CI).

| Layer | Tech | Pin (target) | Now (in repo) |
|---|---|---|---|
| Desktop shell | Tauri v2 | 2.11.x | `tauri = "2"` (Tauri v2 template) |
| UI framework | Svelte + Vite | Svelte 5.56 · Vite 8.2 | Svelte 5.56 · **Vite 6.4** (Tauri template default) |
| Runtime (build) | Node.js | 24 LTS | **22** (CI) / 20.19 (dev) |
| Core lang | Rust / Cargo | 1.97.x (never < 1.96.1) | stable (CI `dtolnay/rust-toolchain@stable`) |
| SSH transport | OS OpenSSH via ssh-agent | app never holds raw keys | ✅ shells out to `ssh` |
| Alerts | ntfy | 2.26.x | ✅ `tools/notify.sh` (outbound) |
| **Planned (not yet in repo)** | | | |
| Charts | uPlot | 1.6.32 | planned |
| PC storage | SQLite (rusqlite) | rusqlite 0.40.x | planned (v1 uses `servers.json`) |
| Secrets on PC | OS keychain (`keyring`) | 4.1.x | planned |
| eBPF (v2) | Rust `aya` | 0.13.x | v2 |

> Vite is a major behind the pin because the official Tauri v2 template ships
> Vite 6; bump to 8 is a tracked follow-up (BACKLOG). SQLite/uPlot/keyring/aya are
> roadmap items, not current dependencies.

## Orchestrated tools
| Tool | Pin | Role |
|---|---|---|
| Netdata | 2.10.x | per-second resource metrics (tiered local store) |
| CrowdSec (+AppSec) | 1.7.x | attack detection/IPS + community intel + WAF |
| Lynis | 3.1.x | hardening audit + score |
| AIDE | 0.19.x | file integrity |
| chkrootkit | 0.59 | rootkit check (rkhunter DROPPED — dead since 2018) |
| Trivy | 0.73.x | vuln scan (pkgs + app deps + config + secrets) |
| ClamAV | 1.4.x LTS | malware engine — RAM-heavy; on-demand only on Pi |
| YARA-X | 1.x | webshell rules (successor to classic YARA) |
| WP-CLI | 2.12.x | WordPress core/plugin versions + updates |
| OWASP CRS | 4.28.x | WAF rules (with CrowdSec AppSec or ModSecurity) |
| restic | 0.19.x | off-box encrypted backup (Borg 2.x still beta) |
| jq | 1.8.x | JSON assembly in agents |
| nmap | 7.99x | outside-view port scan (run from the PC) |
| LMD (maldet) | verify 1.6.6 vs 2.0.1 | webshell signatures + inotify |

## Data feeds (consume — don't rebuild)
| Feed | Use | License |
|---|---|---|
| Ubuntu OVAL/USN | OS-package vulns (backport-correct — **not** NVD) | CC-BY-SA |
| OSV.dev | PHP/Composer + app-dep vulns | CC-BY / CC0 |
| abuse.ch Feodo | outbound C2 detection | **CC0** |
| Spamhaus DROP | inbound bad-IP block | fair-use |
| DB-IP Lite | GeoIP (chosen over MaxMind's account/90-day-key friction) | CC-BY |

## Key decisions / landmines
- **Vuln matching:** Ubuntu OVAL/USN, never NVD for OS packages (backport false
  positives). Use `dpkg --compare-versions` — never hand-roll Debian version compare.
- **eBPF on Pi:** needs kernel BTF; Raspberry Pi OS lacks it by default → v2, gated + fallback.
- **Don't embed Falco/Tetragon** (heavy, k8s-oriented, hit the Pi BTF wall) — learn from Falco's Apache-2.0 rules only.
- **Licensing (if productised):** clean = Feodo (CC0), DB-IP (CC-BY), OSV, Ubuntu OVAL. Verify before bundling = FireHOL, abuse.ch URLhaus/ThreatFox, MaxMind. GPL tools (kunai/Tetragon) = run/learn, don't copy into closed source.
- **Verify at build time:** LMD version conflict; BTF presence on the actual Pi (`ls /sys/kernel/btf/vmlinux`).
