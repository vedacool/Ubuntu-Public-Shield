# Backlog — Ubuntu Public Shield

Single source of truth for tasks, findings, and the roadmap. Organised by the five
defence functions (see `docs/ARCHITECTURE.md`). `audit-software` logs findings here.

## 🔍 Full audit — 2026-08-08 (commit 3118c31)
Verdict after fixes: **GO** (no open P0/P1). Fixed items verified in CI; open items are P2/P3 hardening.

**Fixed (P1):**
- [x] SSH argument injection via unvalidated `user`/`host` (`desktop/src-tauri/src/lib.rs`) — added `valid_field()` charset+leading-dash guard and `--` before target.
- [x] `servers.json` non-atomic write + silent wipe on corruption (`lib.rs`) — atomic tmp+rename, corrupt-file backup instead of discard, `CONFIG_LOCK` mutex.
- [x] Zero tests on the security-critical Rust backend — added `#[cfg(test)]` tests (allowlist, `valid_field`, banner parse).
- [x] `Cargo.lock` not committed for a shipped binary — committed + CI builds `--locked`.

**Fixed (P2):**
- [x] Webshell false-negative on the canonical obfuscated shell (a decoder wrapping request data inside a sink) scored below threshold — fixed with a new detection signal + newline-stripped blob scan (webshell-scan.sh).
- [x] Non-atomic writes: drift snapshot (`60-drift.sh`) + `webshell.json` (`webshell-scan.sh`) — tmp+mv; `LC_ALL=C` for drift sort/comm.
- [x] apply-updates preview/apply divergence + optimistic log (`apply-security-updates.sh`) — apply the previewed list, log outcome, `confirmed_count`.
- [x] Agent timer ran root unsandboxed — added `NoNewPrivileges`/`ProtectSystem=strict`/`ReadWritePaths`/`ProtectHome=read-only`/etc. (`install.sh`).
- [x] `apt-check` parse brittle (`30-updates.sh`); no `systemctl` presence check (`install.sh`); SSH stdout banner breaks JSON parse (`lib.rs parse_json_lenient`).
- [x] Frontend a11y/UX: input labels, visible focus, tile sub-text + borderline contrast, non-colour severity cue (WATCH/ALERT), accessible modal (role/aria/Esc/backdrop/restore-focus/autofocus), in-modal apply error, top-level load error, `signals ?? []` guard, composite finding key, remove-button label.
- [x] Action allowlist drift across 4 files — CI test `tests/action-sync.bats` enforces parity.
- [x] STACK.md version drift; Dependabot npm+cargo; Cargo.toml placeholder metadata.

**Open (P2) — schedule:**
- [ ] Webview **CSP is `null`** (`tauri.conf.json`) — set a restrictive CSP; needs live-test verification that it doesn't break the SvelteKit bundle (Svelte auto-escapes, so this is defense-in-depth).
- [ ] SSOT: JSON-array helper reimplemented 3× (`agent/actions/lib.sh` vs `60-drift.sh` `to_json_array` vs inline in `40-services.sh`/`webshell-scan.sh`) — promote to shared `agent/lib.sh`, align empty-strip behaviour.

**Live test on the Pi (2026-08-08, Debian 11 aarch64) — validated; follow-ups:**
- [x] Agent installs + runs on real hardware; all collectors emit correct data; systemd sandboxing verified (no permission errors); webshell scanner runs on real `/var/www` (0 FP).
- [x] Drift collector spammed syslog (`crontab -l -u` per user, ~17 lines/5min) + wasted CPU — now reads `/var/spool/cron/crontabs` directly.
- [ ] Drift SUID `find` runs every 5min (~10s CPU on a Pi) — consider slower cadence for heavy drift parts.
- [ ] Ports: IPv6 UDP wildcard shows as `*` (TCP shows `[::]`) — normalise for display.

**Open (P3) — polish:**
- [ ] SSH `StrictHostKeyChecking=accept-new` (TOFU) — offer a strict mode + surface fingerprint on first add.
- [ ] `cargo audit`/`cargo-deny` license+advisory gate in CI.
- [ ] Full modal focus-trap; sidebar min-width/reflow at high zoom.
- [ ] `30-updates.sh` fallback under-reports security updates copied to `-updates` suite (apt-check primary path is authoritative).
- [ ] `tools/fetch-feeds.sh` feed integrity verification (currently TLS-only).

## 🚩 Manual follow-ups
- [ ] On the Pi: run `ls /sys/kernel/btf/vmlinux` — decides whether v2 eBPF works without a kernel rebuild.
- [ ] Verify LMD version (1.6.6 vs 2.0.1) before pinning.
- [ ] Enable Dependabot in repo Settings; add branch protection on `main`.
- [ ] Decide desktop app ↔ agent connection: SSH key setup (dedicated `shield` user + authorized key) vs enrollment token.

## 🎯 v1 — near-term (this phase)
**Agent + install**
- [x] Agent runner + `install.sh` + systemd timer (sysinfo / ports / updates collectors)
- [x] `40-services.sh`, `50-lynis.sh` (reads last hardening score), `60-drift.sh` (baseline + diff of authorized_keys/cron/systemd/SUID)
- [x] Webshell scanner v1 (heuristic: sinks + taint-proximity + obfuscation + recursive-decode) + bats tests
- [ ] Webshell deepening: true AST/taint via PHP tokenizer; wire YARA-X community rules
- [x] Confirmed-action layer (preview→confirm→apply→log): apply-security-updates, rebaseline-drift, run-webshell-scan, run-lynis-audit + bats
- [x] Scoped `sudoers` example (`agent/security/shield-sudoers.example`) — v2 wires the no-login `shield` user

**Desktop app (Tauri)** — `desktop/`, CI verifies frontend build + `cargo check`. **Live-validated on the Pi 2026-08-08: full dashboard renders real data over SSH.**
- [x] Add-server + fleet list; SSH connect (OS ssh/ssh-agent, key auth); read `latest.json`
- [x] Tiles: updates, public ports, Lynis, drift, webshell, C2 hits, vulns, failed services, resources — all rendering live
- [x] Fixed live-test blocker: keyed `{#each}` crash on duplicate real-world keys (udp 5353 avahi+myst); now index-keyed + wrapped in `<svelte:boundary>`
- [x] Confirmed actions (preview→confirm modal→apply→refresh): **validated end-to-end on the Pi** — "Accept current drift as baseline" ran `sudo -n` over SSH, reset the baseline, drift went 1→0.
- [ ] UX: state-changing actions (esp. rebaseline) should trigger an immediate agent re-collection so the dashboard reflects the change at once, instead of lagging up to 5 min for the next timer run.
- [ ] Commit Cargo.lock (needs a cargo run first — generated in CI now); app icons; SQLite (rusqlite) instead of servers.json

**Consume + feeds**
- [ ] Netdata + CrowdSec install options in `install.sh` (flags)
- [x] Vuln matcher (`90-vulns.sh`): dpkg → bundle via `dpkg --compare-versions` + bats (real dpkg semantics)
- [x] Threat-intel matcher (`80-threat-intel.sh`): outbound conns vs Feodo exact-IP bundle + bats
- [x] Feed fetcher (`tools/fetch-feeds.sh`): Feodo (CC0) + DROP; **OVAL/OSV→vulns.tsv parser still TODO**
- [x] ntfy phone alerts (`tools/notify.sh`, outbound only, inert until configured)
- [ ] Brain-side: OVAL/USN + OSV parser → vulns.tsv; radix-trie CIDR match for DROP; DB-IP Lite GeoIP

## 🗂 By function (roadmap)
### Identify
- [ ] Asset/package/web-app inventory (incl. WordPress plugin versions via wp-cli) · TLS cert expiry · exposed-secret scan · outside-view nmap (from PC)

### Protect
- [ ] apt + unattended-upgrades control · web-app patching · UFW view/edit · SSH-key/account audit · egress rules

### Detect
- [ ] AIDE file integrity · chkrootkit · persistence diff (cron/systemd/authorized_keys) · webshell scanner · C2/outbound match · login anomaly + geo · **tamper/blinding detection of the guard** · searchable logs

### Respond
- [ ] Incident timeline/correlation · guided one-click containment (isolate keeping SSH, kill, block, disable) · evidence capture

### Recover
- [ ] restic backup + tested restore · rollback · rebuild-from-clean · post-incident report

## 🔭 v2 (in progress)
- [x] **Real-time file-integrity sensor (inotify)** — `agent/sensors/shield-watch.sh` + `45-file-events.sh` + desktop tile. **Live-validated on the Pi**: caught a webshell-suspect `.php` drop in `/var/www` instantly. This is the delivered substitute for eBPF (below).
- [~] Native eBPF sensor via Rust `aya` — **DEFERRED: confirmed no BTF on the Pi** (kernel 6.1.21-v8+; `/sys/kernel/btf/vmlinux` absent). CO-RE needs a kernel rebuild that Pi OS updates clobber. Revisit only for BTF-capable hosts (the Ubuntu box may qualify — check there). inotify sensor covers the real-time need meanwhile.
- [x] **Live feeds** — `shield-feeds.timer` + `tools/fetch-feeds.sh`. **Live-validated on the Pi:**
  - C2/bad-IP: **abuse.ch ThreatFox** (~1,970 IPs, CC0) — Feodo was near-dead + CRLF-broke the parse; switched + fixed.
  - Vulns: **OSV** querybatch→detail, keeping only fix-available CVEs; `90-vulns.sh` flags installed<fixed. Found a real miss: **bind9 deb11u5→u6, 15 CVEs**.
  - Polish: (a) `vulnerable_count` counts CVEs, not distinct packages — tile "vulnerable packages: 15" is really 1 pkg / 15 CVEs; add `package_count` + relabel. (b) OSV `priority` comes through "unknown" for Debian — enrich (CVSS/Debian urgency).
- [ ] NVD enrichment · FireHOL · URLhaus/ThreatFox + DNS · CrowdSec CTI · ML/LLM webshell classifier · BPF-LSM enforcement

## ✅ Done
- [x] software-start baseline (git, CI, tests, knowledge layer)
- [x] Architecture + stack + version research; hybrid-native decision (`docs/ARCHITECTURE.md`, `docs/STACK.md`)
- [x] v1 agent foundation: runner, install.sh, systemd timer, first three collectors
