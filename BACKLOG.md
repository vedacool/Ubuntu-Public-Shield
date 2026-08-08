# Backlog — Ubuntu Public Shield

Single source of truth for tasks, findings, and the roadmap. Organised by the five
defence functions (see `docs/ARCHITECTURE.md`). `audit-software` logs findings here.

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

**Desktop app (Tauri)**
- [ ] Add-server + fleet list; SSH connect; read `latest.json`
- [ ] Tiles: resources, listening ports (flag public), pending security updates, Lynis score
- [ ] One confirmed action end-to-end: apply security updates (preview → confirm → apply → log)

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

## 🔭 v2
- [ ] Native eBPF sensor via Rust `aya` (exec + outbound-connect + web-dir-write), gated on BTF, fallback to v1 fanotify path — after a 2-day cross-arch spike
- [ ] NVD enrichment · FireHOL · URLhaus/ThreatFox + DNS · CrowdSec CTI · ML/LLM webshell classifier · BPF-LSM enforcement

## ✅ Done
- [x] software-start baseline (git, CI, tests, knowledge layer)
- [x] Architecture + stack + version research; hybrid-native decision (`docs/ARCHITECTURE.md`, `docs/STACK.md`)
- [x] v1 agent foundation: runner, install.sh, systemd timer, first three collectors
