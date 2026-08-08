# Security & ops checklist — Ubuntu Public LAMP Server Shield

This toolkit *is* server hardening, so this checklist is both the checklist for
**operating this repo** and the reference for **what the scripts should enforce
on a target server**. Written before the incident, not during it.

## This repo's own hygiene
- [ ] No secrets in the repo or its history (gitleaks clean — runs in CI).
- [ ] `.env` is never committed; keys/certs/DB dumps are gitignored.
- [ ] 2FA on the GitHub account; branch protection on `main` requiring green CI.
- [ ] Every script is `shellcheck`-clean, idempotent, `--dry-run`-capable, and host-guarded.

## What the toolkit should enforce on the target server

### Access & SSH
- [ ] Key-only SSH auth; root login disabled; a working non-root sudo user first.
- [ ] **Lockout guard**: verify the new login path works before disabling the old one.
- [ ] Optional non-default SSH port; fail2ban on sshd.

### Firewall (UFW)
- [ ] Default deny incoming, allow outgoing; only SSH/HTTP/HTTPS (+ declared extras) open.

### Web (Apache) & TLS
- [ ] HTTPS enforced + HSTS; modern TLS only; Let's Encrypt auto-renew.
- [ ] Baseline security headers (CSP where feasible, X-Content-Type-Options, Referrer-Policy, etc.).
- [ ] `ServerTokens Prod`, `ServerSignature Off`; unused modules disabled.
- [ ] Rate limiting on auth/login and expensive endpoints (mod_evasive / mod_qos or upstream WAF).

### Database (MySQL/MariaDB)
- [ ] Root secured, anonymous users + test DB removed, remote root disabled.
- [ ] Least-privilege app user (only its own schema); bind to localhost unless remote is required.

### PHP
- [ ] `expose_php=Off`, dangerous `disable_functions`, `open_basedir`, sane upload/exec limits.

### Patching & backups
- [ ] `unattended-upgrades` for security updates.
- [ ] Automated **off-box** backups of DB + web root + `/etc` config, retained.
- [ ] A **restore drill has actually been run** into a scratch host. (Date: ____)

### Monitoring & edge
- [ ] fail2ban alerting to `FAIL2BAN_DEST_EMAIL`; log review / uptime check.
- [ ] Consider a free CDN/WAF in front with the origin firewalled to it.
- [ ] Recovery runbooks: DB down, disk full, bad deploy, cert expiry, locked out of SSH.

_This is an operational checklist, not legal advice. If the hardened server
handles personal data, route privacy/compliance obligations to counsel._
