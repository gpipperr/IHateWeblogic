---
nav_title: "wlsmon concept"
title: "wlsmon – Lightweight Runtime Monitor for Oracle Forms & Reports 14c (Concept)"
description: "Concept of a read-only runtime monitor for Oracle Forms & Reports 14.1.2 on WebLogic: static JSON per host, GUI with the APEX libraries behind Nginx, one GUI host for many data hosts, no extra software, no side effects on WebLogic."
---

# wlsmon – lightweight runtime monitor (concept)

← [11-wlsmon](../README.md)

**State 2026-11-20: P1 implemented, live on the test host and at the first
customer** (one host, both roles) – operation and faults in
[04-wlsmon_operations.md](04-wlsmon_operations.md). This document is the
master for the scripts (Doc-as-Master, as in `09-Install/docs/`).

**Source:** a first plan and a frontend prototype by Gunther (2026-11-18):
- JSON contract;
- vanilla JS dashboard;
- sample data generator.

Both are local and not in git (`90-Source-MetaData/wlsmon/`). This concept takes over:
- the contract;
- the display levels;
- the rollup rules;
- the Nginx / CSP rules.

It changes the GUI basis (font-apex icons and Oracle JET charts from APEX
`/i/`, with an own small CSS in the colours of the project site). It adds
the split between one GUI host and many data hosts.

## 1. Goal and non-goals

**Goal:** make a Forms & Reports environment more transparent for maintenance.
The most important runtime facts at a glance:
- one traffic light per host;
- the state of every component;
- key figures every 5 minutes;
- the history over 24 hours, 7 days and one year.

Typical questions it answers:
- Is everything running?
- Since when has the heap of WLS_FORMS been high?
- How many Forms sessions were there at the peak last week?
- Did a core dump or a stuck thread happen tonight?

**Not a goal:**
- no NOC replacement: no alerting chain, no escalation, no Nagios / Prometheus
  / Grafana stack;
- no configuration tool: wlsmon never changes the domain, never restarts
  anything.

The JSON files are open for other tools: an existing PRTG or Nagios can read
`now.json` instead of polling WebLogic itself.

## 2. Ground rules

### 2.1 Software

- **Only what an IHateWeblogic host already has:**
  - **python3 with its standard library** – the whole monitor logic
    (collector, build, pull) is one Python program; python3 is on every OL
    host because `dnf` itself needs it (already used by
    `10-Monitoring/cve_inventory.sh`);
  - systemd (timers, limits, encrypted credentials), iproute (`ss`), Nginx;
    bash only for the three installation scripts.
- **Self-contained at runtime:** the monitor runs only from `$WLSMON_BASE`
  (program, rules, configuration, credentials – section 9.1). The
  repository and the IHateWeblogic library are needed only to install and
  update it; a host where they have been removed keeps running.
- **Only `dnf` packages from the normal BaseOS / AppStream repositories,**
  so that everything is patched with the OS:
  - **no pip, no PyPI, no npm, no Ansible Galaxy** – customer servers often
    cannot reach these sources, and nobody patches what they bring;
  - no Grafana, no Prometheus, no exporter JVM, no Node.js;
  - optional, never required: `jq` (AppStream) for admins to look at the
    JSON by hand (`jq . $WLSMON_BASE/api/now.json`) or for a small PRTG /
    Nagios check; `python3-requests` (BaseOS) is not needed either.
- **Python version:** OL9 ships python3 3.9, OL8 (also certified for F&R
  14.1.2) 3.6. The code stays **3.6-compatible** – no `dataclasses`, no `:=`,
  no `match`, no `|` in type hints – so it runs on both without an extra
  package.
- **GUI libraries:** two of the ones APEX already ships under `/i/` –
  font-apex icons and Oracle JET charts. They are updated with every APEX
  patch, so there are no own copies of JavaScript libraries to maintain. The
  look is our own (colours of the project site, one small CSS file – section
  7 and the [interface design](02-wlsmon_interface_design.md)).

### 2.2 No side effects on WebLogic

- **Read-only.** One REST POST per 5 minutes against the AdminServer on
  `localhost` – nothing per managed server, nothing that writes.
- **No WLST:**
  - every call starts a JVM (CPU and several hundred MB of RAM);
  - every 5 minutes that would be a load of its own.
- **Low priority and hard limits** for the collector (section 5): it gets CPU
  and I/O only when WebLogic does not need them.
- **No restart, no change.** Whatever the collector finds, it only writes it
  into the JSON.

### 2.3 Data economy

The JSON holds:
- counters, codes (`BEA-000337`, `REP-50171`) and states;
- no log lines – they can contain user names, SQL or paths;
- no passwords, no connect strings, no configuration content.

A stolen JSON file reveals load and health, nothing more.

## 3. Architecture – data and GUI separated

```
data hosts B, C, D (each)                        GUI host A (can be a data host too)
systemd timer 5 min (User=oracle)                systemd timer 5 min: wlsmon.py pull
  wlsmon.py collect                                GET https://B/wlsmon/api/*.json  -> $WLSMON_BASE/hosts/B/
    REST / /proc / logs, levels, rings, rollups    ... C, D                         -> $WLSMON_BASE/hosts/C/ ...
  -> $WLSMON_BASE/api/{now,day,week,history}.json  writes hosts.json (one line per host)

$WLSMON_BASE = $ORACLE_BASE/admin/wlsmon (section 9.1)

Nginx on B: /wlsmon/api/*.json                   Nginx on A: /wlsmon/            GUI: overview + host view
  only for the IP of A + the pull login                        /wlsmon/hosts/<h>/ the pulled JSON
```

### 3.1 The JSON files are the interface

Each data host writes 7 static files, schema-versioned:

| File | Content | Resolution | Kept |
|---|---|---|---|
| `now.json` | traffic light with reasons, components, key figures | current | – |
| `day.json` | series for the charts | 5 min | 24 h (288 points) |
| `week.json` | series, maximum per hour | 1 h | 7 days (168 points) |
| `history.json` | series, maximum per 12 h + worst level | 12 h | 1 year (730 points) |
| `patch.json` | patch level per component, expected vs. installed CPU, installed patches | daily | current |
| `security.json` | security checks with level, result and hint | hourly | current |
| `logs.json` | log events of the last 24 h grouped by code, hits per rule id (ignored entries included) | 5 min | 24 h window |

The contract follows the prototype plan (schema 1):
- `schema`, `generated_at`, `interval_sec`, `host`, `domain`, `product`,
  `environment` (`prod | qa | test | dev`);
- `collector` (version, duration, errors);
- `overall` (level + reasons);
- `components[]`, `metrics[]`, `layout`, `daily`;
- the series column-oriented.

The fields added by the prototype (2026-11-19) are listed in section 3.5.

Rules:
- `level` is only `ok | warn | crit`. Anything else is shown as `stale`.
- `value` is a plain number (decimal point) and is formatted only in the
  browser (`Intl`, `WLSMON_LOCALE`, interface design section 8) with
  `decimals`. `display` only for composite or text values such as
  `3 · 1 · 0` or `n/a`.
- Texts in the JSON are English.

A data host serves only these files – no logic, no query parameters.

### 3.2 Entry point: the overview on A

The first page (`index.html`) shows one tile per host:
- overall level and domain;
- age of the data;
- the two or three most important reasons.

Prototype details (2026-11-19):
- the tiles are grouped by **product**, inside a group ordered by
  environment (Production, QA, Test, Development) and then worst level first;
  each group has the badge of its worst host;
- a tile shows host name, level (or `STALE <n> min`), environment mark,
  domain, "updated 15:20 · 2 min ago", up to three reasons, the number of
  collector errors and a short line (Forms sessions, heap, load, CPU,
  uptime); the whole tile is the link to `host.html?host=<id>`;
- above the tiles: number of hosts per level, a filter by environment and a
  search over host, product and domain; same refresh button (5 minutes),
  colour mode switch and logo as the host view; the host view has a link
  "← All hosts" back.

`hosts.json` (schema 1): `generated_at`, `interval_sec`, `hosts[]` with `id`,
`name`, `product`, `environment`, `domain`, `level`, `generated_at` and
`interval_sec` of the host's own `now.json`, `reasons[]` (max. 3),
`collector_errors` (count) and `summary` (`forms_sessions`,
`heap_forms_pct`, `load1`, `cpu_pct`, `since`). The GUI computes STALE
itself from `generated_at`, so a host whose pull fails turns grey even when
`hosts.json` is fresh.

`wlsmon.py pull` writes the tiles to `hosts.json` after each round. A host
whose data is older than two intervals is shown as **stale**: grey, with the
time of the last data. It never blocks the page.

### 3.3 Drill-down: the host view

A click on a tile opens the host view (`?host=B`). It is the dashboard of the
prototype:
- header: product name in bold with the environment mark, below it thin
  "Forms & Reports domain <domain>"; refresh button with a 5-minute
  countdown (click = reload all data now), colour mode switch, project logo;
- traffic light with reasons (collector errors as their own chips);
- four tabs below the traffic light, each with its own status badge:
  - **Overview:** components, key figures with sparklines, daily facts,
    day / week / year charts, the 12-hour rollup table;
  - **Patch level:** expected vs. installed CPU, version and patch level per
    component, installed patches (`patch.json`);
  - **Security:** checks sorted by severity (`security.json`);
  - **Log viewer:** events grouped by code with filter by severity, server
    and text, plus the hits per rule id (`logs.json`).

It reads `hosts/B/{now,day,week,history,patch,security,logs}.json` **from A**:
- the browser never talks to B;
- everything is same-origin (CSP `connect-src 'self'`, no CORS headers).

### 3.4 Pull instead of a live proxy

- A fetches the files of every host every 5 minutes. B needs no outgoing
  connection.
- A slow or dead B costs only its own pull (timeout per request). The other hosts
  and the GUI are not affected.
- A keeps the last copy, so the history of B stays visible during an outage of
  B.
- **One host only** (phase 1): A is also the data host. `hosts/<self>/` points
  to `$WLSMON_BASE/api/`, and the overview has one tile.

### 3.5 Contract additions from the prototype (2026-11-19)

**Components from outside to inside, with dependencies:**
- one component `"type": "host"` (the server) with `since` (boot time, ISO);
  the GUI shows "up since <date> · <n> days"; its level comes from the host
  key figures (load, CPU, memory, disk);
- `requires: [ids]` – the component cannot work when one of them is DOWN;
- `parent: id` – shown nested inside that component (several Reports servers
  such as `reptool01`, `itsutf8`, `def25` inside `WLS_REPORTS`, list from
  `WLSMON_REPORTS_SERVERS`);
- `down: true` and `word: "DOWN"` for a component that has failed;
- `layout.stages` – the order from outside to inside, e.g.
  `[["nginx"], ["AdminServer", "NodeManager"], ["WLS_FORMS"], ["WLS_REPORTS"], ["DB"]]`.

Rules: a component behind a DOWN one is shown as *blocked* (CRIT, "blocked
by <root cause>"). Only the root cause becomes a reason ("nginx: not running
· blocks WLS_FORMS, WLS_REPORTS, …"), so an outage does not flood the page.
Only DOWN propagates, WARN does not. AdminServer and Node Manager are the
management plane: the managed servers keep running without them, so nothing
`requires` them by default.

**Key figures per component block:**
- `group` on every metric, `layout.metric_groups` for order and titles:
  Server (load, CPU, memory, disk) | nginx (requests per minute, log errors)
  | Forms (sessions with prestart pool, heap, stuck · hogging threads, log
  errors, core dumps) | Reports (jobs, engines busy · idle, heap, threads,
  log errors, core dumps) | Database (JDBC connections active · waiting,
  RCU login: green = DB reachable and login ok, red = login refused);
- log errors and core dumps are counted **per component**, the series per
  component (`log_errors_forms`, `core_dumps_reports`, …) plus the totals for
  the rollup table;
- `label` – full name for the reasons ("Heap used WLS_REPORTS"), `short` – name on
  the tile inside its block ("Heap used");
- `items[]` – a list inside a tile, e.g. the disks (domain, logs, Reports
  cache, `/tmp`, core directory) with value and level each.

**Other fields:**
- `collector.errors[]` – objects `{level, text}`, e.g. "monitor login
  refused (HTTP 401), paused for 30 min" or "rule my_rule skipped: invalid
  regex"; shown as chips, they do not change the host level;
- `daily` – `{generated_at, facts[]}` with the daily facts (days until the
  next certificate expiry, patch cycle from the inventory files, Derby
  running, GUI library paths valid);
- `logs.json` – `events[]` (`severity`, `code`, `rule`, `server`, `count`,
  `first_seen`, `last_seen`, short `text` per code – never a raw log line),
  `rules[]` (`id`, `type`, `level`, `source`, `hits`, `reason`) and `ignored`;
- `patch.json` – `baseline` (`cpu` expected from `WLSMON_PATCH_BASELINE`,
  `installed`), `components[]`, `patches[]`; read from the inventory files,
  no OPatch JVM;
- `security.json` – `checks[]` (`area`, `name`, `result`, `level`, `hint`):
  TLS certificate days and protocols, Basic Auth active, `/console` and
  `/management` not reachable, HTTP 401 in 24 h, production mode, demo
  certificates, user lockout, monitor user only in Monitors, file
  permissions, listening ports against the expected list.

## 3a. Security and simple password handling

Two kinds of access, each with exactly **one** secret:

| Who | Where | How | Secret stored |
|---|---|---|---|
| People (admins, operations) | only on A: `https://A/wlsmon/` | Basic Auth + `ADMIN_IP_RANGE` – **one** login for all hosts | password hashes in A's `htpasswd` (`openssl passwd -6`, no `httpd-tools` needed) |
| Machine A → B, C, D | `https://B/wlsmon/api/*.json` | **one** technical pull user, the same on every data host, **plus** `allow <IP of A>; deny all;` | on B/C/D only the hash in `htpasswd`; on A the password as an encrypted systemd credential (section 3b) – never on a command line, never in the process list or the environment |

- **Adding a host** is two steps, with no new password:
  - on B: `00-setup-interview.sh` (role `data`, IP of A, the hash of the
    shared pull user – shown by the interview on A), then
    `01-install-wlsmon_fmw.sh` and `02-install-wlsmon_root.sh` (section 9.2);
  - on A: `00-setup-interview.sh` again, one more entry in the host list,
    then `02-install-wlsmon_root.sh --apply`.
- **People never get a password for B.** B's API is not open to people at
  all, only to the IP of A.
- **TLS from A to B is verified:**
  - `ssl.create_default_context(cafile=…)` with the internal CA / trust
    anchors of the customer (`08-SSL`);
  - no `-k` between our own servers (unlike the tools update, which has to
    cross a TLS interception to GitHub).
- **What A can do on B:** read four static JSON files. No REST, no WLST, no
  command. A compromised A sees only status counters (data economy, 2.3).
- **The WebLogic monitor user stays local on every data host:**
  - a WebLogic user only in the group **Monitors** (read-only MBean access);
  - its password follows the password rule of the realm (12 characters,
    `07-Maintenance/wls_password_rule.sh`);
  - its password is random (generated by the interview, nobody needs to know
    it) and stored as an encrypted systemd credential (section 3b);
  - it never leaves the host.
- **No self-made lockout:**
  - after an HTTP 401 the collector pauses for a time it records in its state
    (e.g. 30 minutes) and reports "monitor login refused";
  - it does not keep retrying and so does not keep the user locked under the
    lockout rule 3 / 30 / 15 (`07-Maintenance/wls_lockout_config.sh`).
- **Later option:** a client certificate (mTLS) for the pull instead of Basic
  Auth – same location, `ssl_verify_client optional` and a check of
  `$ssl_client_verify`.

## 3b. Password storage – systemd credentials, no library

The monitor needs three secrets: the WebLogic monitor user, the Reports
`monUser` and, on A, the pull user. They are stored with **systemd
credentials** – part of systemd, nothing extra to install (systemd 252 on
OL9, `systemd-creds`).

- **Encrypted, bound to the host:** `systemd-creds encrypt` uses the host
  key `/var/lib/systemd/credential.secret` (root only) or the TPM2 if
  present. The `.cred` files in `$WLSMON_BASE/etc/creds/` are useless on
  another host, and `oracle` cannot decrypt them itself.
- **Decrypted only for the service:** the unit names them with
  `LoadCredentialEncrypted=wls_monitor:##WLSMON_BASE##/etc/creds/wls_monitor.cred`.
  At start systemd decrypts them into a RAM directory that only this service
  sees (`$CREDENTIALS_DIRECTORY`); `wlsmon.py` reads them from there. Never
  on a command line, in the environment or on disk in clear text.
- **Hand-over from the FMW owner to root – the `boot.properties` pattern:**
  - the interview (as `oracle`) writes each secret in clear text to
    `$WLSMON_BASE/etc/pending/<name>` (mode 600, directory 700);
  - `02-install-wlsmon_root.sh` encrypts each pending file to
    `etc/creds/<name>.cred` and deletes the clear text right after;
  - WebLogic does the same with `boot.properties` at its first start. So
    `oracle` needs no sudo, and a Linux team (root) and the Oracle admins can
    work separately.
- **Change a password:** `00-setup-interview.sh --secret <name> --apply`, then
  `02-install-wlsmon_root.sh --apply`.
- **OL8 (systemd 239, no credentials):** the pending file becomes
  `etc/creds/<name>` with mode 400 for `oracle` – protected only by the file
  permissions. The scripts report this as the weaker variant.
- **Test runs:** only the service sees the credentials. The first real run
  is `systemctl start wlsmon-collect.service` at the end of
  `02-install-wlsmon_root.sh`; `wlsmon.py collect --check` by hand as
  `oracle` tests everything without a password and reports the rest as
  "needs service context".

**Why not the `.des3` files of the library:** they need the library at
runtime, and their scheme is weaker – the key (disk UUID / `machine-id`) is
readable by every local user, `openssl -pass pass:…` puts it into the
process list for a moment, decryption writes a clear-text file next to the
`.des3` file, and `tail -1` over `/dev/disk/by-uuid` can return another key
after a disk is added. (Separate TODO item for the library.)

## 4. Collector

One Python program, `wlsmon.py` (standard library only), with the
subcommands `collect` (data role) and `pull` (GUI role).

systemd starts it directly – no wrapper, no library:
- configuration only from `$WLSMON_BASE/etc/wlsmon.conf` (`KEY=value`,
  written by the interview, section 9.2);
- secrets only from `$CREDENTIALS_DIRECTORY` (section 3b).

`wlsmon.py collect`:
- gathers the raw values (section 4.1);
- computes the levels;
- writes `now.json`;
- keeps the 5-minute ring;
- rolls up week and history.

Standard library modules used:

| Task | Module |
|---|---|
| WebLogic REST, `getserverinfo`, pull A → B | `urllib.request` with `ssl.create_default_context(cafile=…)`, Basic Auth header, timeout per request |
| JSON | `json` |
| Reports XML | `xml.etree.ElementTree` |
| Load, memory, processes | `/proc/loadavg`, `/proc/meminfo`, `/proc/<pid>/cmdline`, `os.cpu_count()` |
| Disks | `shutil.disk_usage` |
| Port / ready checks | `socket`, `urllib` |
| Log offsets, rotation | `os.stat` (inode, size), `seek` |
| Core dumps | `/proc/sys/kernel/core_pattern`, `glob`, `os.stat` |
| No overlap, atomic files | `fcntl.flock`, `tempfile` in the target directory + `os.replace` |
| `ss`, `coredumpctl` where needed | `subprocess` (iproute and systemd are part of the base OS) |

Every file is written atomically (temporary file in the target directory,
then `os.replace`).

### 4.1 Sources and what can be reused

| Area | Source | Reuse from the repository |
|---|---|---|
| Server state, health, heap, stuck / hogging threads, JDBC data sources | WebLogic REST `…/management/weblogic/latest/domainRuntime/search` (one POST, prototype plan 6.1); target list from `domainConfig/servers` – a missing server = DOWN | field names verified on 14.1.2 (2026-11-20): [80-FMW-Architecture/weblogic_rest_monitoring.md](../../80-FMW-Architecture/weblogic_rest_monitoring.md) |
| Fallback when the AdminServer is down | `http://localhost:<port>/weblogic/ready` per server, port checks | `70-Customer-Projects/tools/bash/status.sh` (ready probe), `01-Run/startStop.sh` (`_port_listening`) |
| Reports server: engines busy / idle, queue, failed jobs | `getserverinfo` per POST with the existing Reports user `monUser` (role `RW_MONITOR`) | the request (POST, all parameters in the body) and the verdict rules of `01-Run/reports_server_lib.sh` (`rws_fetch_serverinfo`, `rws_http_verdict`) and the XML fields of `01-Run/rwserver_status.sh`, ported to Python |
| Forms: sessions vs. prestart pool | `frmweb` processes from `/proc/<pid>/cmdline` + `ss` (a runtime with a client connection = session) | rule of `06-FormsDiag/forms_perf_analyse.sh` |
| Host | uptime from the boot time (`btime` in `/proc/stat`), `/proc/loadavg`, `os.cpu_count()`, CPU % as the average over the interval from the `/proc/stat` delta between two runs (counters in `state/`, with iowait and steal), `/proc/meminfo`, `shutil.disk_usage` of a configured list | – |
| Log errors | server and Reports logs, read from the offset of the last run (inode + byte offset in `$WLSMON_BASE/state/`; rotation = start again) – evaluated per log entry with the rules file (section 4.3); only counters and codes: `<Error>`, `<Critical>`, `BEA-000337`, `OutOfMemoryError`, `REP-`, `REP-50171` + LDAP error 49 (failed Reports logins) | patterns of `70-Customer-Projects/tools/bash/show_errors.sh`; the REP-50171 monitor is an open item of the security hardening (TODO) |
| Core dumps | directory from `sysctl -n kernel.core_pattern` (our hosts: `/var/tmp/core/coredump_%h_…`), new files since the last run; a pattern starting with `\|` (systemd-coredump) → `coredumpctl list --since`; plus `hs_err_pid*.log` in the domain directory; free space of the core directory as a disk figure (a JVM core ≈ heap size) | `09-Install/01-root_os_baseline.sh` sets `kernel.core_pattern`, `fs.suid_dumpable`, `kernel.core_uses_pid` and creates `/var/tmp/core`; `docs/03-root_user_oracle.md` sets the `core` limit of `oracle` |
| RCU schemas (STB, OPSS, IAU, MDS, WLS …) | a failed RCU login shows only at the next start of the domain – the running servers keep their pooled connections. Checked on its own, once an hour: (1) account status and expiry date of the RCU schemas from `DBA_USERS` with a read-only DB monitor user, through the `sqlplus` of the F&R Oracle Home, connect string from the STB data source: `OPEN` = ok, expiry in < 30 days = warn, `LOCKED` / `EXPIRED` = crit; (2) optional a real login with the RCU schema password (systemd credential), at most once an hour and paused after the first refusal, so that wlsmon never locks the schema itself; (3) log rule `rcu_login` (ORA-01017, ORA-28000, ORA-28001) and the state of the RCU data sources from the REST call | new; connect data from the domain configuration (`jdbc/*.xml`, STB data source) |
| Daily facts (once a day, cheap; at once after a new `ui.json` or `bin/wlsmon.py` of `01-`) | days until the next certificate expiry, patch cycle stamp from the inventory files (no OPatch JVM), Derby running, GUI library paths still valid and served by nginx | `10-Monitoring/cert_expiry_check.sh`, the facts of `collect_fmw_env.sh` |

### 4.2 Key figures and thresholds (proposal)

| Key figure | Warn / crit |
|---|---|
| Components (server, Node Manager, Reports server, Nginx, data sources) | not RUNNING = crit |
| Heap used, % of the max heap (`-Xmx`) per managed server JVM | 80 / 90 |
| Stuck · hogging threads | hogging > 0 / stuck > 0 |
| Forms sessions | from experience, per environment |
| Reports queue · failed jobs | queue > 5 / failed > 0 |
| Load 1 min | > cores / > 2 × cores |
| CPU % (average over 5 min) | 80 / 95 |
| Memory used, swap | used 85 / 95 %, swap in use 512 / 2048 MB – the worse one; the tile names the cause |
| Disk (domain, logs, Reports cache, /tmp) | 80 / 90 % |
| Log errors since the last run | > 0 / critical or > 9 |
| New core dumps | ≥ 1 = crit |
| Days until a certificate expires (daily) | < 30 / < 7 |
| RCU schema login (hourly) | password expires in < 30 days = warn / login refused, `LOCKED` or `EXPIRED` = crit |

The thresholds are `WLSMON_*` keys in `$WLSMON_BASE/etc/wlsmon.conf`, with
defaults in the program. The interview offers the values of
`environment.conf` as defaults when the library is present, so the library
stays the one source where it exists.

### 4.3 Rules file – what counts, what is noise

WebLogic writes many messages that look like errors but are harmless. A
counter without a noise filter would show yellow all the time, and nobody
would look any more. The rules for the log evaluation therefore live in a
file, not in the code.

**Two files, so that `git pull` never overwrites local rules:**

| File | Content |
|---|---|
| `11-wlsmon/rules/wlsmon_rules.cfg` (in git) | default rules, maintained in the repository |
| `$WLSMON_BASE/etc/wlsmon_rules.local.cfg` per host (not in git, survives a new clone of the repository) | local additions; a rule with the same `id` replaces the default rule |

**Format** – one rule per line, `;`-separated, like
`rules/security_weights.txt` of the analysis: readable in every editor, read
by Python without any extra library. `#` starts a comment.

```
# type;id;level;source;regex;reason
match;oom;crit;wls;OutOfMemoryError;heap exhausted
match;stuck;crit;wls;BEA-000337;stuck thread
match;rep_login;warn;reports;REP-50171;failed Reports login (LDAP 49)
ignore;wls_noise_01;-;wls;<regex>;known harmless message, reference (MOS note / own analysis)
```

| Field | Meaning |
|---|---|
| `type` | `match` = count the entry and set the level; `ignore` = drop a known harmless entry before anything is counted |
| `id` | unique name; shown in `now.json`, used for local overrides |
| `level` | `warn` / `crit` for `match`, `-` for `ignore` |
| `source` | which logs: `wls` (server logs), `reports`, `forms`, `nginx`, `*` |
| `regex` | Python regular expression, applied to the whole log entry |
| `reason` | mandatory for `ignore` – why the message is harmless |

**Rules of evaluation:**
- **Per log entry, not per line.** A WebLogic entry starts with `####<` and
  can carry a long stack trace. Per line, one stack trace would count as a
  hundred errors, and an `ignore` rule would only hit its first line.
- **Order:** `ignore` first, then `match`; an entry counts once, with the
  highest level of all matching rules. Entries with `<Error>` / `<Critical>`
  that no rule matches count under the generic rule `unclassified`.
- **Nothing disappears silently:** `now.json` lists the hits **per rule
  id**, the ignored entries included. So one can see what each `ignore` rule
  filters, and a rule that suddenly drops thousands of entries stands out.
- **An `ignore` rule without a `reason` is not loaded** (reported in
  `collector.errors`).
- **Robust:** all rules are compiled once at the start; a broken regex is
  skipped and reported in `collector.errors`, the run goes on.
- **Permissions:** the files belong to `oracle`, mode 640 – they decide what
  the monitor shows.

**Scope:**
- thresholds stay as `WLSMON_*` keys in `wlsmon.conf`; the rules file only
  holds patterns;
- later `show_errors.sh` and `03-Logs/grep_logs.sh` can read the same file,
  so the logic exists once and the noise filter also helps when reading logs
  by hand.

**First content:** the actual list of harmless messages is built from real
logs (test host, customer exports) – a message becomes an `ignore` rule only
after it has been checked there. Work package of P1.

## 5. Runtime safety (systemd)

```ini
# wlsmon-collect.service (template, ##VARIABLE## rendered by 02-install-wlsmon_root.sh)
[Service]
Type=oneshot
User=oracle
Nice=19
IOSchedulingClass=idle
CPUQuota=10%
MemoryMax=200M
TimeoutStartSec=120
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=##WLSMON_BASE##
#@CORE_DIR_BEGIN@
BindReadOnlyPaths=-##WLSMON_CORE_DIR##
#@CORE_DIR_END@
#@CRED_WLS_BEGIN@
LoadCredentialEncrypted=wls_monitor:##WLSMON_BASE##/etc/creds/wls_monitor.cred
#@CRED_WLS_END@
#@CRED_REP_BEGIN@
LoadCredentialEncrypted=reports_mon:##WLSMON_BASE##/etc/creds/reports_mon.cred
#@CRED_REP_END@
#@CRED_DB_BEGIN@
LoadCredentialEncrypted=db_monitor:##WLSMON_BASE##/etc/creds/db_monitor.cred
#@CRED_DB_END@
ExecStart=/usr/bin/flock -n ##WLSMON_BASE##/state/collect.lock /usr/bin/python3 ##WLSMON_BASE##/bin/wlsmon.py collect

# wlsmon-collect.timer
[Timer]
OnCalendar=*:0/5
RandomizedDelaySec=20
```

- `flock -n`: a run that still hangs is never started twice.
- Timeout of 20 s for every HTTP request in `wlsmon.py`: a slow AdminServer
  only makes the run report "no data".
- `MemoryMax=200M` is ample for one python3 process (a few 10 MB).
- **One marker block per credential:** a `LoadCredentialEncrypted` line whose
  file is missing makes the start fail – `02-install-wlsmon_root.sh` keeps only
  the blocks whose `.cred` exists (`db_monitor` only with `WLSMON_RCU_CHECK`).
- **Core directory:** `PrivateTmp=yes` gives the service its own `/tmp` and
  `/var/tmp` – the core directory below `/var/tmp` (`kernel.core_pattern`)
  would look empty and its disk wrong. `BindReadOnlyPaths=-<dir>` maps the real
  directory back, read-only (the `-` ignores a missing one); found live
  2026-11-20.
- Errors end up in `now.json.collector.errors`. The GUI shows **stale** when
  `generated_at` is older than two intervals, so the collector is monitored too.
- The pull on A runs the same way (`wlsmon-pull.service` / `.timer`, with
  `LoadCredentialEncrypted=pull_user:…`).

## 6. Nginx

One include file `/etc/nginx/oracle-wls.d/wlsmon.conf`, rendered from a
template:
- same pattern as `12-APEX-Ords/05-setup-nginx.sh`;
- inside the existing 443 server block of `09-Install/nginx-wls.conf.template`;
- TLS is already there (`05-root_nginx_ssl.sh`).

The template has two blocks, switched on or off with the marker technique of
the Nginx template:

- **GUI role (A):**
  - `/wlsmon/` (static GUI) and `/wlsmon/hosts/<h>/(now|day|week|history|patch|security|logs).json`
    plus `hosts.json`;
  - `allow ADMIN_IP_RANGE` + `deny all` (the same handling as `/console` in
    `04-root_nginx.sh`);
  - Basic Auth for people.
- **Data role (B, C, D):**
  - only `/wlsmon/api/(now|day|week|history|patch|security|logs).json`;
  - `allow <IP of A>` + `deny all`;
  - Basic Auth for the one pull user;
  - no GUI.
- A host can have both roles: single host, or A monitors itself.

Common rules:
- `limit_except GET { deny all; }`;
- a whitelist regex for the JSON files – everything else below `/wlsmon/api/`
  or `/wlsmon/hosts/` returns 404;
- `limit_req` zone in `/etc/nginx/conf.d/wlsmon_zone.conf` (http context);
- security headers (CSP, `nosniff`, `Referrer-Policy`, `Permissions-Policy`)
  through an `include` in **every** location – a location with its own
  `add_header` inherits none from above (Nginx pitfall);
- the headers only in the `/wlsmon/` locations, Forms and APEX stay unchanged;
- no `Access-Control-Allow-Origin`;
- `/management` and `/console` are never routed for wlsmon;
- the security check of section 3.5 probes `/console` and
  `/management/weblogic/latest` anonymously through the own Nginx from
  127.0.0.1 – the collector does not count these requests as Nginx errors.

File permissions (layout in section 9.1):
- Nginx reads only `www/`, `api/` and `hosts/` below `$WLSMON_BASE`, through
  the group `wlsmon` – it can read, never write;
- `etc/`, `state/` and `log/` are for `oracle` only;
- the `htpasswd` files stay in `/etc/nginx/wlsmon/` (`htpasswd` for people,
  `pull_htpasswd` for the pull user; `root:nginx` 640), not in the Oracle
  tree: whoever takes over the FMW owner cannot add GUI logins;
- the FMW owner reads the Nginx logs (requests per minute, 5xx, `error.log`)
  through an ACL: `setfacl -m u:<owner>:rx` on the log directory plus a
  default ACL `-d -m u:<owner>:r`, so files created by logrotate inherit the
  right; the ACLs `02-` set are listed in `/etc/nginx/wlsmon/root_acl.list`
  for `--remove`.

Tests after the setup:
- without login → 401;
- with login → 200;
- `POST` → 403;
- a file outside the whitelist → 404;
- from a foreign IP → 403.

## 7. GUI – plain HTML5 with the APEX libraries from `/i/`

The GUI uses two libraries that APEX already ships under `/i/` – served by
the same Nginx and updated with every APEX patch. The look is our own: the
colours and the frame of the project site, defined in
[02-wlsmon_interface_design.md](02-wlsmon_interface_design.md) (decision
2026-11-19).

The page itself is plain HTML5 and JavaScript – no APEX application, no APEX
runtime, no database access. From the prototype it keeps the page structure
and the security rules:
- no inline code, no `eval`, no `innerHTML`;
- values only through `textContent`;
- levels only from a whitelist.

- **Layout and colours:** one small own file `www/css/wlsmon.css` with the
  tokens of the interface design and the frame of the site
  (`assets/css/ihw.css`: header with gold line, left black border, Arial).
  The Universal Theme CSS of APEX is **not** loaded – its colours would cover
  ours.
- **Icons:** font-apex (`/i/libraries/font-apex/<ver>/`) – the status icons
  of the interface design.
- **JET only for the charts (decision 2026-11-19):** tiles, topology, tabs,
  tables, filters and badges stay the prototype's own HTML / CSS – no
  `oj-tab-bar`, `oj-table` or other JET components. Reasons:
  - the full Redwood theme would cover our own look;
  - without a build chain JET means MVVM with Knockout, and the VDOM variant
    needs node / npm – both against §2.1;
  - every further component is one more thing an APEX update can break
    (20.1.4 already has no `oj-spark-chart`);
  - if JET does not load, our own SVG draws the charts.
- **Charts:** Oracle JET (`/i/libraries/oraclejet/<ver>/`, `oj-chart`, loaded
  with the RequireJS of the JET folder), drawn in our own design: series and
  threshold colours, grid, axes, fonts and tooltips from the tokens of
  `wlsmon.css`, not from the JET theme. JET's own theme CSS only as far as
  `oj-chart` needs it to work – to verify in P1:
  - line charts for day / week / year, sparklines in the tiles;
  - if JET does not load, the values and tables still show (a simple SVG
    fallback as in the prototype).
- **Versioned paths:** the version directories change with APEX. On the test
  host, APEX 26.2.1 has JET `20.1.4` and font-apex `2.5.1`.
  - `01-install-wlsmon_fmw.sh` finds the newest version directories in the
    APEX images directory and writes them into `www/ui.json`, which the page
    reads first;
  - the daily collector run checks that these paths still exist, and otherwise
    reports "GUI libraries moved – run 01-install-wlsmon_fmw.sh --apply".
- **CSP stays strict.** `'self'` covers `/i/` (same origin).
  - JET with Knockout bindings would need `unsafe-eval`. The page is therefore
    built without Knockout bindings, or with JET's CSP-compliant expression
    evaluator, so `script-src` never gets weaker. To verify in phase 1.
  - At most `style-src 'unsafe-inline'` for chart styles.
- **Without APEX** (`INSTALL_APEX=false`, customer hosts): `/i/` is only
  static files from the APEX ZIP and needs no database.
  - `01-install-wlsmon_fmw.sh` can unpack just the `images/` folder of the
    APEX ZIP (download logic of `12-APEX-Ords/`) to `$WLSMON_BASE/www/i/`;
    `02-install-wlsmon_root.sh` routes it;
  - it is then updated with each APEX ZIP.
- **Language:** English texts; date and number format German by default,
  switchable with `WLSMON_LOCALE` (interface design, section 8).
- **Pages:**
  - overview (tiles per host);
  - host view (dashboard of the prototype with the four tabs of section 3.3,
    Reports engines busy / idle, queue, failed and a row with the daily facts).

## 8. Data retention and rollups

| Series | day (5 min) | week (1 h) | history (12 h) |
|---|---|---|---|
| Forms sessions, heap, load, CPU, nginx requests | raw | maximum | maximum |
| Free memory | raw | **minimum** | **minimum** |
| Log errors, core dumps, Reports jobs | raw | **sum** | **sum** |
| Level | – | – | worst level of the 12 h |

A peak never disappears in an average.

Size per host: a few hundred KB in total; no database, no growth beyond the
fixed rings.

## 9. Installation and maintenance

### 9.1 Layout on the host

Everything the monitor needs at runtime lives in the scope of the FMW owner,
below `$WLSMON_BASE` – default `$ORACLE_BASE/admin/wlsmon` (the OFA place for
runtime data):

```
$WLSMON_BASE/                 oracle:wlsmon  750
├── bin/        wlsmon.py (copy)          oracle only   700
├── share/      wlsmon_rules.cfg (copy)   oracle only   700
├── etc/        wlsmon.conf, wlsmon_rules.local.cfg       oracle only   700
│   ├── pending/  clear-text secrets until root encrypts them   700 / 600
│   └── creds/    *.cred (systemd credentials)          root:root 400 each
├── www/        GUI (role A)              Nginx reads   2750 / 640
├── api/        own JSON (data role)      Nginx reads   2750 / 640
├── hosts/<h>/  pulled JSON (role A)      Nginx reads   2750 / 640
│               single host: hosts/<id> -> ../api (symlink) + hosts.json
├── state/      log offsets, pause after 401, lock    oracle only   700
└── log/                                  oracle only   700
```

- **Self-contained:** program, rules, configuration and credentials are all
  here. Repository and library are only the installation source.
- **Nginx only reads,** and only `www/`, `api/`, `hosts/`:
  - through the group `wlsmon` (members: `nginx`, `oracle`), setgid on the
    three directories so that new files inherit the group;
  - `nginx` never joins `oinstall` – it would read the whole Oracle tree;
  - **setgid trap:** Linux clears the setgid bit on every `chmod` by an owner
    who is not in the file's group – e.g. an oracle login older than the
    `usermod -aG wlsmon`. `01-install` therefore changes a mode only when it
    differs and creates new directories with `umask 027`; it warns when a file
    below the three directories is not group `wlsmon` (Nginx would answer 403;
    seen live 2026-11-20).
- **Traversal of the parent directories:** `/u01/app/oracle` and `admin` are
  755 on the test host. A customer with 750 gets an ACL with the traverse
  right only (`setfacl -m u:nginx:x` on each parent) – Nginx can pass, not
  list. Checked and reported without `--apply`.
- **SELinux** (disabled by our baseline, maybe enforcing at a customer):
  `httpd_sys_content_t` only on `www/`, `api/`, `hosts/` (`semanage fcontext`
  + `restorecon`, as in `12-APEX-Ords/05-setup-nginx.sh`).
- **Backup:** the files directly in `$WLSMON_BASE/etc` (not `pending/`,
  not `creds/`) as category `wlsmon` of `07-Maintenance/backup_config.sh`
  (done 2026-11-23).

### 9.2 Installation scripts

Three install scripts, run in their order (plus `03-set-thresholds.sh` for the operation afterwards) – first the FMW owner, root last, so that
the timers start only when everything is in place:

| Script | User | Does |
|---|---|---|
| `00-setup-interview.sh` | FMW owner (`oracle`) | asks everything for wlsmon (below); without `--apply` it shows the resulting `wlsmon.conf` as a diff, with `--apply` it creates `$WLSMON_BASE/etc/` (oracle owns `admin/`, no root needed), writes `wlsmon.conf` and the secrets to `etc/pending/` |
| `01-install-wlsmon_fmw.sh` | FMW owner (`oracle`) | copies `bin/wlsmon.py`, `share/wlsmon_rules.cfg`, `www/`; writes `ui.json` (APEX library paths, `WLSMON_LOCALE`); `etc/wlsmon_rules.local.cfg` skeleton (never overwritten); creates the WebLogic monitor user in the group Monitors with the password from `pending/` – a one-time call at installation only, never at runtime; uses the domain administrator stored with `00-Setup/weblogic_sec.sh` (`WL_USER` in `weblogic_sec.conf.des3`, e.g. `webadmin`) or, without the library, asks for user and password (memory only); checks the Reports `monUser`; `wlsmon.py collect --check` |
| `02-install-wlsmon_root.sh` | root | group `wlsmon` (members `nginx`, `oracle`); `chgrp` + setgid on `www/`, `api/`, `hosts/`; traverse ACLs on the parents if needed; SELinux context; systemd units + timers from templates (`##VARIABLE##` substitution as in `09-Install/04-root_nginx.sh`); Nginx include `/etc/nginx/oracle-wls.d/wlsmon.conf` + `conf.d/wlsmon_zone.conf` from `templates/wlsmon-nginx.conf.template`, blocks of the role switched on with `#@WLSMON_GUI_BEGIN@` / `#@WLSMON_DATA_BEGIN@` markers; `htpasswd` files in `/etc/nginx/` (`openssl passwd -6`); `pending/` → `creds/*.cred` and delete the clear text; `nginx -t` + reload; enable the timers; first run with `systemctl start` and its result |
| `03-set-thresholds.sh` | FMW owner (`oracle`) | **operation, after the installation:** overview of the WARN / CRIT thresholds next to the value now and the 24-h maximum / average; `--set KEY=w,c`, `--reset KEY`, `--interactive`; checks the values, writes `wlsmon.conf` with a backup, runs `collect --check` – no restart ([operations §3a](04-wlsmon_operations.md#3a-change-the-warn--crit-levels-afterwards)) |

**Options** (all three: without `--apply` a dry run; `--base DIR` for
another `WLSMON_BASE`; `--help`):

| Script | Option | Effect |
|---|---|---|
| `00-` | `--defaults` | no questions, every default (re-runs, tests) |
| `00-` | `--secret NAME` | change only this secret: `wls_monitor`, `reports_mon`, `pull_user`, `pull_hash`, `gui_htpasswd`, `db_monitor` |
| `00-` | `--env-conf FILE` | `environment.conf` to take the defaults from |
| `01-` | `--reset-monitor-password` | set the WebLogic password of the monitor user to the `wls_monitor` secret again |
| `01-` | `--no-user` | skip the monitor user (GUI-only host, tests) |
| `01-` | `--remove` | remove the runtime (`etc/` kept and listed) |
| `02-` | `--no-start` | install, but do not enable the timers and skip the first run |
| `02-` | `--remove` | reverse everything `02-` did |
| `03-` | `--set KEY=VALUE` / `--reset KEY` / `--interactive` | change thresholds (repeatable; KEY with or without `WLSMON_`) |
| `02-` | `--test-root DIR` | **tests only:** `/etc` and `/var/log` below DIR, root commands from a fake `PATH` |

**`wlsmon.py` commands:** `collect [--check]` (one round; `--check` prints
and writes nothing), `pull` (GUI role, P2), `rules --test LOGFILE` (which
rule matches which line), `detect` (host facts for the interview: patch cycle of
the stack patch bundle, fixed / random listeners, core directory, JET /
font-apex versions below `/i/`), `defaults` (built-in `KEY=value`),
`thresholds [--check KEY=VALUE]` (overview / validation for `03-`), `monitor-user check|create|reset` (the WebLogic monitor user through
REST, secrets on stdin – used by `01-`), `version`.

**Single host (role `both`):** the collector writes its own overview tile to
`hosts/hosts.json` and the symlink `hosts/<id>` → `../api`, so the overview
and the host view work without a pull. With `WLSMON_PULL_HOSTS` set (P2) the
pull writes `hosts.json` instead.

**The interview** (`00-setup-interview.sh`):
- **Defaults**, in this order: an existing `wlsmon.conf` (a second run offers
  the last answers), `environment.conf` when the library is present, built-in
  defaults.
- **Questions:** role (`gui` / `data` / `both`), `WLSMON_BASE`; IP of A (data
  role) or the list of data hosts (GUI role); AdminServer URL / port; Reports
  server name and URL; log directories; thresholds; CA file for the pull
  (GUI role).
- **Secrets:**
  - WebLogic monitor user: generated at random (password rule of the realm,
    12 characters) – nobody needs to know it;
  - Reports `monUser`: asked (hidden input, twice);
  - pull user on A: generated; its hash is shown for the data hosts (a hash
    is no secret);
  - on a data host: asks for exactly that hash.
- **Options:** `--secret <name>` changes only one secret.

**Rules for all three:**
- library standards: read-only without `--apply` (shows what would change);
  backup before every change of an existing file; `print_summary`;
- they may use the library when it is there (defaults, admin password), but
  what they install never needs it;
- **update:** `git pull` (or a new tools ZIP) + `01-install-wlsmon_fmw.sh
  --apply`; `02-install-wlsmon_root.sh --apply` only when a template changed
  (it shows the diff without `--apply`). APEX patches update the GUI
  libraries by themselves;
- **removal:** `--remove` in reverse order:
  - `02 --remove`: timers, units, Nginx include + zone, `htpasswd`,
    credentials, group, ACLs, SELinux context;
  - `01 --remove`: `bin/`, `share/`, `www/`, data (`etc/` kept and listed);
    the WebLogic monitor user is listed for manual removal – the domain stays
    untouched.

Planned files in the repository:

```
11-wlsmon/
├── README.md
├── docs/01-wlsmon_concept.md      this document (master)
├── docs/02-wlsmon_interface_design.md   colours, status, charts, tooltips
├── docs/04-wlsmon_operations.md   install, update, thresholds, tiles, known faults
├── 00-setup-interview.sh          oracle: questions, wlsmon.conf, secrets -> etc/pending/
├── 01-install-wlsmon_fmw.sh       oracle: bin/, share/, www/, ui.json, monitor user
├── 02-install-wlsmon_root.sh      root: group, systemd, Nginx include, htpasswd, pending -> creds, timers
├── 03-set-thresholds.sh           oracle, operation: show / check / change the WARN / CRIT thresholds
├── wlsmon.py                      the program: collect (data role), pull (GUI role) – stdlib only, python 3.6+
├── rules/wlsmon_rules.cfg         default log rules (local additions: $WLSMON_BASE/etc/)
├── templates/                     wlsmon.conf, Nginx include + zone, systemd units + timers
├── www/                           GUI source from the prototype v3 (index.html, host.html, js/, css/, img/ – no own JS libraries)
│   ├── js/wlsmon_libs.js          ui.json, font-apex icons from /i/ (SVG fallback)
│   └── js/wlsmon_charts.js        chart layer: Oracle JET from /i/, SVG fallback
├── tests/                         unittest (stdlib) + fixtures/ with demo data only
└── tools/                         gen_sample_data.py (sample data), check_contract.py (contract check),
                                   render_template.py (the one template renderer), devserver.py (GUI test
                                   server with the production CSP), js_syntax_check.sh, jet_probe/
```

### 9.3 Configuration reference (`wlsmon.conf`)

`$WLSMON_BASE/etc/wlsmon.conf`, written by the interview from
[`templates/wlsmon.conf.template`](https://github.com/gpipperr/IHateWeblogic/blob/main/11-wlsmon/templates/wlsmon.conf.template);
`KEY=value`, no shell syntax. Defaults: `wlsmon.py defaults`. Thresholds are
`warn,crit`. Keys marked *(install)* are read by the install scripts, not by
the collector. Keys not in the template can be added by hand.

| Key | Default | Meaning |
|---|---|---|
| **This host** | | |
| `WLSMON_BASE` *(install)* | `$ORACLE_BASE/admin/wlsmon` | runtime directory (section 9.1) |
| `WLSMON_ROLE` | `both` | `both` (one host), `data` (B, C, D), `gui` (A only) |
| `WLSMON_HOST_ID` | short host name | id in URLs and `hosts.json` |
| `WLSMON_PRODUCT`, `WLSMON_ENV` | `Forms & Reports`, `prod` | grouping and filter of the overview (`prod`, `qa`, `test`, `dev`) |
| `WLSMON_LOCALE` | `de-DE` | number / date format of the GUI and JET |
| **Domain** | | |
| `WLSMON_DOMAIN_HOME`, `WLSMON_ORACLE_HOME` | library defaults | domain and Oracle Home |
| `WLSMON_JAVA_HOME` | `ORACLE_HOME/oracle_common/jdk` | JDK whose version is reported |
| `WLSMON_ADMIN_URL`, `WLSMON_ADMIN_SERVER` | `http://localhost:7001`, `AdminServer` | REST endpoint, AdminServer name |
| `WLSMON_FORMS_SERVER`, `WLSMON_REPORTS_SERVER` | `WLS_FORMS`, `WLS_REPORTS` | managed servers for the Forms / Reports figures |
| `WLSMON_SERVER_PORTS` | `AdminServer:7001 WLS_FORMS:9001 WLS_REPORTS:9002` | port probe when REST is not available |
| `WLSMON_NM_HOST`, `WLSMON_NM_PORT` | `localhost`, `5556` | Node Manager probe |
| `WLSMON_MON_USER` | `wlsmon_monitor` | WebLogic user, group Monitors only |
| **Reports** | | |
| `WLSMON_REPORTS_URL` | `http://localhost:9002/reports/rwservlet` | rwservlet for `getserverinfo` |
| `WLSMON_REPORTS_SERVERS` | empty | Reports server names (empty = no Reports figures) |
| `WLSMON_REPORTS_MON_USER` | `monUser` | Reports monitoring user (password: credential `reports_mon`) |
| **Host, logs, Nginx** | | |
| `WLSMON_DISKS` | empty = domain, logs, `/tmp`, core directory | `label=path …` |
| `WLSMON_CORE_DIR` | from `kernel.core_pattern` | core dump directory (also mapped into the unit) |
| `WLSMON_LOG_GLOBS`, `WLSMON_LOG_MAX_MB` | `servers/*/logs/*.log` + `*.out`, `20` | logs read per run, max. new bytes per file |
| `WLSMON_NGINX_PORT`, `…_PID`, `…_ACCESS_LOG`, `…_ERROR_LOG`, `…_CONF_DIRS` | `443`, `/run/nginx.pid`, `/var/log/nginx/…`, `/etc/nginx …` | Nginx state, logs and config (certificates) |
| `WLSMON_EXPECTED_PORTS` | `443 7001 5556 9001 9002` | fixed listeners; others are reported (random ports only counted) |
| `WLSMON_CERT_FILES` | `ssl_certificate` of the Nginx config | certificates for the expiry check |
| `WLSMON_APEX_DIR` | `/srv/apex/apex_1` | `/i/` on disk – library versions for `ui.json` |
| **Daily / hourly** | | |
| `WLSMON_PATCH_BASELINE` | empty | expected CPU / CSPU cycle `YYYY-MM` for the patch tab |
| `WLSMON_RCU_CHECK`, `WLSMON_RCU_PREFIX`, `WLSMON_RCU_DAYS` | `false`, `DEV`, `30` | RCU schema expiry check (needs the DB monitor user) |
| `WLSMON_RCU_CONNECT`, `WLSMON_SQLPLUS`, `WLSMON_DB_MON_USER` | STB data source, `ORACLE_HOME/bin/sqlplus`, empty | connection of that check |
| **Thresholds `warn,crit`** | | |
| `WLSMON_HEAP_PCT` | `80,90` | heap of the servers |
| `WLSMON_LOAD` | `cores,2×cores` | load average 1 min |
| `WLSMON_SWAP_MB` | `512,2048` | swap in use, MB – the memory tile takes the worse of this and `WLSMON_MEM_USED_PCT` |
| `WLSMON_CPU_PCT`, `WLSMON_MEM_USED_PCT`, `WLSMON_DISK_PCT` | `80,95`, `85,95`, `80,90` | host |
| `WLSMON_LOG_ERRORS` | `1,10` | counted log errors per run |
| `WLSMON_FORMS_SESSIONS` | empty = no limit | Forms sessions (per environment) |
| `WLSMON_REPORTS_QUEUE` | `5,20` | queued Reports jobs |
| `WLSMON_CERT_DAYS` | `30,7` | days until certificate expiry |
| **Runtime** | | |
| `WLSMON_401_PAUSE_MIN` | `30` | REST pause after a 401 (protects the realm lockout) |
| `WLSMON_HTTP_TIMEOUT` | `20` | seconds per HTTP request |
| **Web tier** *(install, `02-`)* | | |
| `WLSMON_ADMIN_IP_RANGE` | empty | GUI role: networks of the people, one `allow` each; `any` = no restriction (reported as WARN by the security check) |
| `WLSMON_GUI_USERS` | empty | GUI role: Basic Auth users (passwords: `gui_htpasswd`) |
| `WLSMON_GUI_IP` | empty | data role: IP of A, the only client of `/wlsmon/api/` |
| `WLSMON_STYLE_SRC` | `'self'` | CSP `style-src` (JET needs no `'unsafe-inline'`, measured 2026-11-19) |
| **Pull (GUI role, P2)** | | |
| `WLSMON_PULL_HOSTS` | empty | data hosts `id=https://host …` |
| `WLSMON_PULL_CAFILE` | empty | CA of the internal PKI (TLS always verified) |
| `WLSMON_PULL_USER` | `wlsmon_pull` | technical pull user (credential `pull_user`) |

## 10. Phases

State 2026-11-23: P1 live on the test host and at the first customer; backup
category `wlsmon` done, `--remove` + reinstall tested live. Open: the rest of
the 24-hour evaluation, the table view per chart – the list is in
[TODO.md](https://github.com/gpipperr/IHateWeblogic/blob/main/TODO.md) block "11-wlsmon".

| Phase | Content |
|---|---|
| P1 – one host | contract (schema 1) + `WLSMON_*` keys; collector (WebLogic REST, host, Forms, Reports, logs, core dumps, daily facts); rules file with the first content from real logs; build + rollups; `00-setup-interview.sh`, `01-install-wlsmon_fmw.sh`, `02-install-wlsmon_root.sh` (both roles on one host, systemd credentials); GUI with the APEX libraries; test on the test host |
| P2 – one GUI host, many data hosts | `wlsmon.py pull`, `hosts.json`, overview page, data role on other hosts (IP allow + shared pull user), TLS verification against the internal CA |
| P3 – optional | the three scripts in the customer tools ZIP (the runtime is self-contained anyway); notes for PRTG / Nagios reading `now.json` |

## 11. Open points

- Thresholds for Forms sessions and the Reports queue, per environment.
- Customer domains: the WebLogic monitor user is one change of the realm –
  agree it per customer.
- RCU check: is `sqlplus` part of the F&R 14.1.2 Oracle Home on every host;
  read-only DB monitor user (`SELECT` on `DBA_USERS` for the RCU schemas
  only) – agree it with the DBA per customer; the optional real login needs
  the RCU password as one more systemd credential.

Answered by the repository:
- the WebLogic monitor user is created with REST (`createUser`,
  `addMemberToGroup`, no WLST JVM) – live 2026-11-20; on 14.1.2
  `listMemberGroups` returns a cursor and every request needs
  `X-Requested-By`
  ([weblogic_rest_monitoring.md](../../80-FMW-Architecture/weblogic_rest_monitoring.md));
- JET charts without Knockout under the strict CSP (`style-src 'self'`) –
  measured 2026-11-19, tooltips through the data cursor (interface design §4);
- the allowed networks of the GUI are a question of the interview
  (`WLSMON_ADMIN_IP_RANGE`);
- the REST field names on 14.1.2 – verified 2026-11-20,
  [weblogic_rest_monitoring.md](../../80-FMW-Architecture/weblogic_rest_monitoring.md);
- the Reports figures come from `getserverinfo` with `monUser`;
- the web tier is the library's Nginx with the include directory
  `/etc/nginx/oracle-wls.d/`;
- the core dump location is configured by the OS baseline in sysctl
  (`kernel.core_pattern` → `/var/tmp/core`); the collector reads the pattern
  at runtime, so a customer host with a different setting works as well.

## 12. Related

- [04-wlsmon_operations.md](04-wlsmon_operations.md): install, update,
  status, known faults.
- [10-Monitoring](../../10-Monitoring/README.md): periodic analysis (CVE
  watch, certificate expiry, patch cycle). wlsmon is the live runtime view.
- [reports_monitoring_getserverinfo.md](../../80-FMW-Architecture/reports_monitoring_getserverinfo.md),
  [reports_job_queue_monitoring.md](../../80-FMW-Architecture/reports_job_queue_monitoring.md)
- [security_overview.md](../../80-FMW-Architecture/security_overview.md):
  ADMIN_IP_RANGE, lockout, password rule
