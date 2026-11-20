---
nav_title: "wlsmon operations"
title: "wlsmon – Operations and Troubleshooting (Oracle Forms & Reports 14c Monitor)"
description: "Operating wlsmon on Oracle Forms & Reports 14.1.2: install, update and remove, status and logs of the collector, configuration changes, secrets, and the known faults with their fix (403, stale, false disk warning, missing tooltips)."
---

# wlsmon – operations and troubleshooting

← [11-wlsmon](../README.md) · concept: [01-wlsmon_concept.md](01-wlsmon_concept.md)

State 2026-11-20: one host with both roles (data + GUI) live on the test
host. Paths below use the default `WLSMON_BASE=$ORACLE_BASE/admin/wlsmon`.

---

## 1. Install, update, remove

```bash
# 1. FMW owner: questions -> etc/wlsmon.conf + etc/pending/ (dry-run shows the diff)
./11-wlsmon/00-setup-interview.sh
./11-wlsmon/00-setup-interview.sh --apply

# 2. FMW owner: program, GUI, ui.json, WebLogic monitor user, collect --check
./11-wlsmon/01-install-wlsmon_fmw.sh
./11-wlsmon/01-install-wlsmon_fmw.sh --apply

# 3. root (or the FMW owner with sudo): group, ACLs, credentials, nginx, systemd, first run
sudo ./11-wlsmon/02-install-wlsmon_root.sh
sudo ./11-wlsmon/02-install-wlsmon_root.sh --apply
```

Every script shows what it would do without `--apply`. Options:
[concept §9.2](01-wlsmon_concept.md#92-installation-scripts).

| Task | Command |
|---|---|
| **Update** (new repository state / tools ZIP) | `01-install-wlsmon_fmw.sh --apply` – copies only changed files; `02-install-wlsmon_root.sh` (dry run) shows whether a template changed, then `--apply` |
| Change a setting | `00-setup-interview.sh --apply` (offers the current values), then `02-install-wlsmon_root.sh --apply` for web-tier keys (section 3) |
| Change one secret | `00-setup-interview.sh --secret NAME --apply`, then `02-install-wlsmon_root.sh --apply` (encrypts it) |
| Monitor user lost its password | `01-install-wlsmon_fmw.sh --reset-monitor-password --apply` |
| **Remove** | `sudo 02-install-wlsmon_root.sh --remove --apply`, then `01-install-wlsmon_fmw.sh --remove --apply` – `etc/` stays and is listed, the WebLogic monitor user is listed for manual removal |

After an update of `www/`: reload the page with **Ctrl+F5** – the browser
keeps the old JS and CSS otherwise.

---

## 2. Is it running?

```bash
systemctl list-timers 'wlsmon*' --no-pager          # next / last run (every 5 min)
systemctl status wlsmon-collect.service --no-pager  # result of the last run
journalctl -u wlsmon-collect.service --since -1h    # output and errors of the runs
```

Expected output: one run every 5 minutes, `status=0/SUCCESS`, a few
hundred ms each.

| What | Where |
|---|---|
| Result of the last round | `$WLSMON_BASE/api/now.json` (`generated_at`, `level`, `collector.errors`) |
| Overview tile (single host) | `$WLSMON_BASE/hosts/hosts.json`, `hosts/<id>` is a symlink to `../api` |
| Time series, offsets, pauses | `$WLSMON_BASE/state/` (`series.json`, `state.json`, locks) |
| Collector errors | `now.json` → `collector.errors`, shown in the GUI; the journal for crashes |
| Check by hand (FMW owner) | `python3 $WLSMON_BASE/bin/wlsmon.py collect --check` – one round, printed, nothing written; WebLogic REST and Reports are skipped without the credentials of the service |
| Resources | the journal line "Consumed … CPU time" per run, `systemd-cgtop` during a run – limits `CPUQuota=10%`, `MemoryMax=200M` |

The GUI shows **stale** when `generated_at` is older than two intervals –
the collector watches itself that way.

---

## 3. Configuration

`$WLSMON_BASE/etc/wlsmon.conf` – `KEY=value`, read by `wlsmon.py` at each
run; reference of all keys: [concept §9.3](01-wlsmon_concept.md#93-configuration-reference-wlsmonconf).

- Collector keys (thresholds, ports, servers, disks): take effect at the
  next run – no restart.
- Web-tier keys (`WLSMON_ADMIN_IP_RANGE`, `WLSMON_GUI_USERS`, `WLSMON_GUI_IP`,
  `WLSMON_STYLE_SRC`) and the core directory: only through
  `02-install-wlsmon_root.sh --apply` (renders the nginx include and the unit).
- Local log rules: `$WLSMON_BASE/etc/wlsmon_rules.local.cfg` (never
  overwritten); test a rule against a log copy with
  `wlsmon.py rules --test LOGFILE`.

Secrets are not in `wlsmon.conf`: systemd credentials in `etc/creds/*.cred`
(root, host bound), the htpasswd files in `/etc/nginx/wlsmon/`
([concept §3b](01-wlsmon_concept.md#3b-password-storage--systemd-credentials-no-library)).

---

## 4. Known faults and their fix

| Symptom | Cause | Fix |
|---|---|---|
| **403** on JS / CSS / JSON, host page without data, overview **stale** | files below `www/`, `api/`, `hosts/` are not group `wlsmon` – the setgid bit of the directories is gone. Linux clears setgid on every `chmod` by an owner who is not in the file's group; an oracle login older than the `usermod -aG wlsmon` of `02-` is such an owner (2026-11-20) | `sudo 02-install-wlsmon_root.sh --apply` (group, 2750, 640). `01-install` changes modes only when they differ and warns when a file is not group `wlsmon` |
| `hosts.json` 404 on a single host | collector older than 2026-11-20 (wrote no own tile) | `01-install-wlsmon_fmw.sh --apply` |
| Disk WARN for the core directory, but the disk is fine | `PrivateTmp=yes` hides `/var/tmp/core` from the service | unit with `BindReadOnlyPaths=-<core dir>` – `02-install-wlsmon_root.sh --apply` |
| Host WARN "Memory free" | a real finding on a small host – `WLSMON_MEM_USED_PCT` | adjust the threshold only if the value is normal for this host |
| nginx error count contains the monitor's own probe | older collector counted the security probe of `/management/weblogic/latest` from 127.0.0.1 | `01-install-wlsmon_fmw.sh --apply` |
| REST components "n/a", 401 in `collector.errors` | monitor user password differs from the credential; the collector pauses 30 min after a 401 (`WLSMON_401_PAUSE_MIN`, avoids the realm lockout) | `01-install-wlsmon_fmw.sh --reset-monitor-password --apply` |
| `rep_<server>` "not checked" in `collect --check` | the check by hand has no service credentials | normal – the service reads `reports_mon` |
| Service does not start, `LoadCredentialEncrypted` error | a `.cred` file named in the unit is missing | `02-install-wlsmon_root.sh --apply` – it keeps only the credential blocks whose file exists |
| Charts drawn as plain SVG, no JET | `/i/libraries/oraclejet/<ver>` not found (APEX upgrade changed the version) | `01-install-wlsmon_fmw.sh --apply` rewrites `ui.json` with the newest versions |
| No tooltip on the large charts | JET `hoverBehavior: 'dim'` suppresses the data-cursor tooltip (JET 20.1.4) | fixed in `wlsmon_charts.js` 2026-11-20 – update + Ctrl+F5 |

**Debug the GUI without the login (test host only):** back up
`/etc/nginx/oracle-wls.d/wlsmon.conf`, comment the two `auth_basic` lines,
`nginx -t`, reload. Afterwards restore the backup (or
`02-install-wlsmon_root.sh --apply`, which renders the file again) and check
that `/wlsmon/host.html` answers 401.

---

## 5. Access checks (curl, on the host)

```bash
SN=$(hostname -f); R="--resolve $SN:443:127.0.0.1"
curl -sk $R -o /dev/null -w '%{http_code}\n' https://$SN/wlsmon/host.html          # 401 (login)
curl -sk $R -o /dev/null -w '%{http_code}\n' -X POST https://$SN/wlsmon/api/now.json  # 401/403 (POST refused)
```

With a login: 200 for the GUI and the seven JSON files, 404 for every other
file below `/wlsmon/api/` and `/wlsmon/hosts/`, 403 from an IP outside
`WLSMON_ADMIN_IP_RANGE` ([concept §6](01-wlsmon_concept.md#6-nginx)).
`02-install-wlsmon_root.sh --apply` runs the local part of these checks at
its end.

---

## 6. Backup

`$WLSMON_BASE/etc/` (without `pending/`) holds the configuration and the
local rules; the credentials are bound to the host and are created again by
the interview + `02-`. Category `wlsmon` in
`07-Maintenance/backup_config.sh` – **open** (development step 13).
