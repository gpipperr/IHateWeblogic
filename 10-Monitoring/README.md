# 10-Monitoring – AI-Assisted Proactive Monitoring

> Certificates, keys and trust stores of the whole stack (terms, where what lives, who needs what, customer PKI / TLS interception): [certificates_trust_stores.md](../80-FMW-Architecture/certificates_trust_stores.md)

**Module:** `10-Monitoring/`
**Runs as:** `oracle` (cron / systemd timer)
**Phase:** Ongoing operation – the last stage of the lifecycle, after installation,
configuration, SSL, fonts, performance tuning and Forms are all in place.

**Status:** Concept – first script implemented: `cve_inventory.sh` (CVE watch step 1, 2026-10-19).

---

## Purpose

Every other module in this project answers a question when a human asks it:
"Is the Reports engine healthy?", "Is the certificate about to expire?",
"Are there errors in the WLS_FORMS log?"

This module closes the gap between "diagnostic data exists" and
"someone actually reads it before it becomes an incident". It collects the
structured output that the existing scripts already produce, sends it to
Claude for interpretation, and turns raw check output into a short,
actionable verdict – so a human only needs to look when something is
actually wrong.

**This is still not a monitoring/alerting replacement.** It does not replace
Nagios, Grafana, Enterprise Manager or the customer's existing NOC tooling.
It is a diagnostic co-pilot that sits on top of the checks this project
already has, adds root-cause reasoning, and produces a human-readable
summary a DBA can act on immediately.

---

## Why This Belongs Last in the Lifecycle

```
Install → Configure → SSL → Fonts → Performance → Forms → Patches → Monitoring
```

AI-assisted analysis is only useful once the environment is in a known-good
state and the "normal" baseline is established. Pointing this module at a
freshly installed, half-configured system would just produce noise – most
findings would be "not configured yet" rather than genuine anomalies.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  1. COLLECT                                                       │
│     claude_monitor.sh calls existing check scripts in             │
│     report/JSON-friendly mode and captures their output:          │
│                                                                    │
│       02-Checks/os_check.sh                                       │
│       02-Checks/java_check.sh                                     │
│       02-Checks/ssl_check.sh                                       │
│       02-Checks/port_check.sh                                     │
│       02-Checks/weblogic_performance.sh                           │
│       01-Run/rwserver_status.sh                                   │
│       05-ReportsPerformance/engine_perf_analyse.sh                 │
│       06-FormsDiag/forms_perf_analyse.sh                          │
│       03-Logs/grep_logs.sh  (ORA-, REP-, FRM- patterns, last N h) │
└──────────────────────┬─────────────────────────────────────────────┘
                       │  structured findings (ok/warn/fail + details)
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│  2. ANALYSE   (Claude sandbox of setup_claude.md)                  │
│     claude_analyze.sh builds a prompt from:                       │
│       - installation context (environment.conf, no secrets)       │
│       - collected findings from step 1                           │
│       - known/accepted issues (monitor.conf allow-list)           │
│     → sends to Claude API (Anthropic SDK, curl or python)         │
│     → Claude returns a structured verdict (see Output below)      │
└──────────────────────┬─────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│  3. REPORT / NOTIFY                                                │
│     - Always written to 10-Monitoring/reports/ (local, gitignored) │
│     - Notification only above configured severity threshold       │
│       (avoid alert fatigue – this is the whole point of the       │
│       AI layer: filter noise, don't add to it)                    │
└──────────────────────────────────────────────────────────────────┘
```

---

## CVE Watch – installed components vs. Oracle security advisories

**Status:** step 1 implemented (`cve_inventory.sh`, 2026-10-19), step 2
implemented (`cve_watch.sh`, 2026-10-30 – early warning between the Oracle
releases); steps 3–4 concept. Prototype of the later steps = the manual check of 2026-10-18 in
`09-Install/docs/00-patch-references.md`, section "CVE check".

### cve_inventory.sh (step 1, implemented)

Background: the homes and the two JDKs it inventories –
[weblogic_middleware_architecture.md §1](../80-FMW-Architecture/weblogic_middleware_architecture.md#1-terms--the-four-homes); the Reports / Forms KPIs a
later collector reads come from `05-`/`06-`, explained in
[report_engine_architecture.md §6](../80-FMW-Architecture/report_engine_architecture.md#6-performance-parameters-rwserverconf) and
[forms_runtime_architecture.md §5](../80-FMW-Architecture/forms_runtime_architecture.md#5-memory-and-limits).

```bash
./10-Monitoring/cve_inventory.sh              # inventory, read-only
./10-Monitoring/cve_inventory.sh --online     # + advisories after the configured cycle
./10-Monitoring/cve_inventory.sh --no-os      # without the dnf errata check
./10-Monitoring/cve_inventory.sh --json FILE  # default reports/inventory_<date>.json
```

| Section | Source | Result |
|---|---|---|
| 1. Components | `comps.xml` → advisory product names (WLS, JRF, OPSS, Coherence, Forms, Reports, OHS, WebGate) + libOVD jar date | version + "configured in the domain" / "binaries only" |
| 2. Patch level | `PATCH_CYCLE*`, `WLS_SPB_MARKER_PATCH`, `INSTALL_PATCHES*` from `09-Install/oracle_software_version.conf` (patch numbers: `download/patches_fmw.csv`) vs. `opatch lspatches` | FAIL per missing configured patch; SPB level with build date; OPatch vs. `OPATCH_VERSION_MIN`; WARN for OHS / WebGate binaries in the home |
| 3. Java | `JDK_HOME` and `oracle_common/jdk` (`java.version`, `java.version.date`); which **running** JVMs use each JDK (`/proc/<pid>/exe`), domain `JavaHome` | WARN below `JDK_VERSION_MIN`, or other major release older than a year – with the list of processes that really run on it |
| 4. Active use and exposure | running processes per product (WLS servers, Node Manager, `frmweb`, `rwserver`, Reports engines, OHS, Nginx); sockets of the oracle processes beyond loopback (`ss -ltnp`, only the process role goes into the JSON, no addresses); firewalld / nftables state | WARN for processes reachable from the network without a firewall |
| 5. OS | `/etc/os-release`, kernel, `rpm -q nginx openssl glibc`, `dnf --cacheonly updateinfo list --security` (timeout 60 s) | open security advisories (ELSA), no repository access needed |
| 6. Advisories (`--online`) | index of `oracle.com/security-alerts/`, release date = third Tuesday of the advisory month | WARN per CPU / CSPU released after `PATCH_CYCLE_DATE`, INFO for announced ones |

**Patch scope vs. urgency:** everything on disk is patched – a component
that is not running can still be started by an attacker who got a foothold
(other service, stolen account) and then exploited. Active use and network
exposure (section 4) only decide **how fast**: running + reachable = next
maintenance window, on disk only = with the regular cycle.

Exit 0 / 1 (warnings) / 2 (configured patch missing). `inventory.json`
holds product names, versions, patch numbers and advisory names only (no
host names, IPs or domain names). `reports/` is gitignored.

Live run on the test host (2026-10-19, ~10 s, **confirmed (live)**): CSPU Sep
2026 set complete (SPB 14.1.2.0.260825 built 2026-08-25, 39988381, both
QPRs, PERL); CPU Oct 2026 correctly reported as "announced" (20 Oct);
findings:
- **Oracle HTTP Server and OAM WebGate binaries are in the Oracle Home** –
  the Forms & Reports installer puts them there although Nginx is the
  frontend (no OHS instance in the domain). Their CVEs apply to the files
  on disk; KA1182 lists bundle patches for both (our patch list had them as
  "only if installed" and assumed "not installed") – decision open.
- **FMW-bundled JDK `oracle_common/jdk` = 17.0.12 (2024-07-16) is in use**:
  the Reports engines run on it – Oracle's `$DOMAIN_HOME/reports/bin/reports.sh`
  puts `oracle_common/jdk/bin` first in `PATH`. WebLogic, Node Manager and
  the domain use `JDK_HOME` 21.0.12.1, so a JDK update via `JDK_HOME`
  (`02b-`) never reaches the engines. (First version of this check said "not
  used by the domain" – it only looked at the domain configuration, not at
  the running JVMs.) Decision open: update the bundled JDK in place, or point
  the engines to `JDK_HOME` (Oracle file `reports.sh` – supported way to be
  checked).
- **No firewall** (firewalld not running) and **~50 prestarted `frmweb`**
  (`prestartRuntimes=true`, prestart per config section), `rwserver`, the
  Reports engines and two WLS ports (Coherence on `WLS_FORMS`) listen on all
  interfaces / the host address – reachable from the network past Nginx.
  The September 2026 CSPU has a Forms CVE over TCP (CVE-2026-83104, 9.1).
  **Fixed the same day:** firewalld enabled with only ssh / http / https /
  14027/udp (`01-root_os_baseline.sh --only firewall,ssh`, see
  `09-Install/docs/00-root_set_os_parameter.md`); the inventory now reports
  these sockets as "filtered by firewalld". Still open: loopback binding of
  the `frmweb` / `rwserver` sockets.
- 4 open OS security advisories (Important) in the dnf cache.

### Monthly run (example – not activated by any script)

Oracle releases on the third Tuesday of the month (CPU or CSPU); the
day after is always a Wednesday between the 16th and the 22nd. systemd
expresses that directly – cron cannot (day-of-month and day-of-week are
OR-ed in cron), it needs a guard.

```ini
# /etc/systemd/system/ihw-cve-inventory.service
[Unit]
Description=IHateWeblogic CVE inventory (monthly, after the Oracle security release)
After=network-online.target

[Service]
Type=oneshot
User=oracle
ExecStart=/path/to/IHateWeblogic/10-Monitoring/cve_inventory.sh --online
# exit 1 (warnings) is the normal case after a new release – not a failure
SuccessExitStatus=1

# /etc/systemd/system/ihw-cve-inventory.timer
[Unit]
Description=Wednesday after the third Tuesday (Oracle CPU / CSPU release day + 1)

[Timer]
OnCalendar=Wed *-*-16..22 06:30
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl daemon-reload && systemctl enable --now ihw-cve-inventory.timer
systemctl list-timers ihw-cve-inventory.timer
# checked 2026-10-19: systemd-analyze calendar 'Wed *-*-16..22 06:30'
#   -> 2026-10-21, 2026-11-18, 2026-12-16, 2027-01-20 (= release + 1 day)
```

Cron alternative (oracle crontab – the `date` guard picks the Wednesday):

```
30 6 16-22 * * [ "$(date +\%u)" = 3 ] && /path/to/IHateWeblogic/10-Monitoring/cve_inventory.sh --online >/dev/null 2>&1
```

Result: the console log in `log/<date>/cve_inventory_*.log` and
`10-Monitoring/reports/inventory_<date>.json`; exit code 1 = a new advisory
is released and not yet covered by `PATCH_CYCLE`. Notification follows with
the later steps (section "Notification").

### cve_watch.sh (step 2, implemented) – early warning between the releases

```bash
./10-Monitoring/cve_watch.sh                       # newest reports/inventory_*.json
./10-Monitoring/cve_watch.sh --with-inventory      # on the server: inventory first
./10-Monitoring/cve_watch.sh --inventory /path/inventory_kunde.json --state-dir /path/kunde/
./10-Monitoring/cve_watch.sh --cron [--apply]      # daily 07:10, marker "# IHW cve_watch"
journalctl -t ihw-cve                              # new WARN / CRIT
```

Read-only. Input is the `inventory.json` of `cve_inventory.sh` (products,
versions, both JDKs and – since 2026-10-30 – the **third-party jars** of the
Oracle Home as Maven coordinates, paths relative to `ORACLE_HOME`; no host
data). So the watcher runs on any host with internet: customer servers
without egress (OCI) run `cve_inventory.sh`, the admin / share host runs
`cve_watch.sh --inventory … --state-dir …` (one state directory per
installation).

**Why not just poll NVD by CPE?** For Oracle's own code (WebLogic, Forms,
Reports, OPSS, Java SE) Oracle is the CNA and publishes the CVE in the same
minute as the CPU / CSPU / Security Alert – before the patch there is nothing
in NVD, and the NVD CPE (`cpe:2.3:a:oracle:weblogic_server:14.1.2.0.0`) is
added days to weeks **later** (records stay "Awaiting Analysis"). A CPE
search is the slowest source, not an early one. The CNA record itself carries
an `affected` block (product + versions) – the watcher matches that on
release day. The real head start comes from the third-party libraries in the
home (their CVEs are public long before Oracle bundles the fix), from KEV
(exploited) and from out-of-band Security Alerts.

| Source | What | Match / level |
|---|---|---|
| `oracle.com/security-alerts/` (`curl -A "Mozilla/5.0"`) | CPU / CSPU released after `PATCH_CYCLE_DATE`; Security Alerts by revision | released, not applied → WARN; an alert's CVE is looked up in NVD and matched |
| NVD API 2.0, `sourceIdentifier=secalert_us@oracle.com` | all Oracle CNA records since the last run (first run 119 days, API limit 120) | CNA product + exact version (FMW 14.1.2.0.0 / 12.2.1.x); Java SE: installed ≤ listed version of the same major; published ≤ `PATCH_CYCLE_DATE` = covered by the applied cycle (INFO). Records of our product families are kept in the state and re-matched every run – a JDK upgrade or a newer cycle clears them |
| OSV.dev `querybatch` | jar coordinate + version → GHSA / CVE | CVSS ≥ `CVE_MIN_CVSS` → WARN; Oracle builds (`5.3.49.INTERNAL_90`, five-part versions) → INFO, the fix may be backported |
| CISA KEV | known exploited | an affected, not covered finding in KEV → CRIT |
| FIRST EPSS | exploit probability | shown for WARN / CRIT |
| heise security feed (`/security/feed.xml`) | articles on WebLogic, Forms, Reports, Fusion Middleware, Java SE, Oracle + Lücke / Exploit | INFO; WARN when a CVE in the article matches a finding |

Levels: CRIT = KEV, or Oracle CVE with CVSS ≥ `CVE_CRIT_CVSS` (9.0), remote
without authentication and a protocol in `CVE_EXPOSED_PROTOCOLS` (`HTTP
HTTPS` – Nginx publishes only HTTPS; T3 / IIOP CVEs stay WARN); WARN ≥
`CVE_MIN_CVSS` (7.0). Alerts (console FAIL / WARN, journal `ihw-cve`, exit
2 / 1) only for **new or escalated** findings – the first run is the
baseline; the console and `reports/cve_watch_<date>.md` (SEVERITY block)
also list the open known ones. Accepted risks: `reports/cve_accepted.txt`
(`CVE;reason;date` → INFO). `NVD_API_KEY` (free) raises the NVD limit from
5 to 50 requests per 30 s. Self-test: `--save-fixtures DIR` once, then
`--offline DIR --state-dir <scratch>` with a changed inventory.

Live 2026-10-30 (test host, CPU Oct 2026 applied): 3710 Oracle records in
119 days, 283 matches – 233 covered by the applied cycle; open: Java SE
CVEs of the FMW-bundled JDK 17.0.12 and the eMudhra alert CVE-2026-114820
also for `JDK_HOME` 21.0.13.0.2 (known, see 00-patch-references.md), 22
library findings (jackson-databind / -core 2.16.1 in `jlib/` + `sqlcl/lib/`,
jackson-core 2.21.5 in `oracle_common` – current Oracle copy –, httpcore5,
jline telnet in SQLcl, OpenJPA 1.1.1 …); Security Alert CVE-2026-109618
(PHP, in KEV) correctly INFO – no installed product. Simulated older
inventory (CSPU Sep, JDK 21.0.12.1): CRIT CVE-2026-91323 (WLS HTTP), WARN
CVE-2026-83399 (T3 / IIOP), WARN "cpuoct2026 not applied" – the result of
the manual check of 2026-10-22. Runtime about 60 s.

### Why

Since May 2026 Oracle publishes security fixes **monthly** (CPU in
Jan/Apr/Jul/Oct, CSPU in the other months, third Tuesday – see "Terms" in
`00-patch-references.md`). A CSPU risk matrix lists only the *new* CVEs, and
the September 2026 CSPU alone had five CVSS 10.0 entries in Fusion
Middleware (WLS Web Container, Forms Services, OPSS …). Reading every
advisory by hand and matching it against what is really installed on each
server is exactly the kind of work that gets skipped – and that an agent
can do reliably every month.

### What is checked – "installed components"

Collected locally, deterministically (no AI, no network):

| Source | Gives | Matches advisory product |
|---|---|---|
| `$ORACLE_HOME/inventory/ContentsXML/comps.xml` (fast; `opatch lsinventory` is slow) | installed components + version (`oracle.as.install.wls`, `oracle.developer.forms.*`, Reports, Coherence, OHS / WebGate if present) | Oracle WebLogic Server, Oracle Forms, Oracle Coherence, Oracle HTTP Server, Oracle Fusion Middleware, Oracle Platform Security for Java, Middleware Common Libraries and Tools, Fusion Middleware Control |
| `opatch lspatches` | applied patches (SPB marker, PSU, QPRs, SPUs) | current patch level → which cycle is applied |
| `09-Install/oracle_software_version.conf` | configured cycle (e.g. "CSPU Sep 2026") | compared with the latest released advisory |
| `$JDK_HOME/bin/java -version` **and** `$ORACLE_HOME/oracle_common/jdk/bin/java -version` | both JDKs – the domain JDK and the FMW-bundled one | Oracle Java SE |
| `rpm -q nginx openssl glibc kernel …`, `dnf updateinfo list --security` | OS / Nginx security errata | Oracle Linux (ELSA) – not in the Oracle CPU/CSPU |
| repository DB version (optional, `sqlplus` / `rcu_repository_check.sh`) | DB release + RU | Oracle Database Server matrix |
| JACOB version (`JACOB_VERSION`), Nginx frontend exposure | third-party / exposure context | – |

Live example (test host, 2026-10-18): WLS / Forms / Reports 14.1.2.0.0, the
complete CSPU Sep 2026 patch set, `JDK_HOME` = Java 21.0.12.1 – and the
FMW-bundled `oracle_common/jdk` still at **17.0.12 (July 2024)**. It is
not the domain JDK, but it is on disk, and nobody would notice without an
inventory check.

### Flow

```
 third Tuesday + 1 day (systemd timer / cron), or on demand
        │
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 1. INVENTORY  cve_inventory.sh  (local, deterministic)              │
│    components + versions, patches, both JDKs, OS errata             │
│    → inventory.json  (product names only – no host / customer data) │
└──────────────────────┬──────────────────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. ADVISORIES  cve_watch.sh                                         │
│    oracle.com/security-alerts/  → all cpu*/cspu* advisories since   │
│    the last applied cycle (curl -A "Mozilla/5.0"; plain clients get │
│    HTTP 403); parse the risk matrices (CVE, product, component,     │
│    protocol, remote w/o auth, CVSS, affected versions)              │
│    + CISA KEV feed (known exploited) + NVD (optional)               │
│    → match product + version against inventory.json                 │
│    → candidates.json  (deterministic match, no AI)                  │
└──────────────────────┬──────────────────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. ASSESS  Claude                                                   │
│    - exposure: Nginx publishes only HTTPS 443 → HTTP CVEs of        │
│      WLS / Forms are reachable, T3/IIOP only internally; Forms CVE  │
│      only if Forms is installed / deployed                          │
│    - is it fixed by the applied patch set? (cycle compare; KA1182   │
│      mapping, see open items)                                       │
│    - urgency: CVSS ≥ 9 + remote w/o auth + exposed, or KEV → CRIT   │
│    - concrete action with our scripts: 04-oracle_pre_download.sh,   │
│      07-Maintenance patch cycle, 02b-root_os_java.sh, dnf           │
│    - DRAFT (never applied) for oracle_software_version.conf and the │
│      "CVE check" section of 00-patch-references.md                  │
└──────────────────────┬──────────────────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. REPORT  reports/cve_<yyyy-mm>.md + standard SEVERITY block       │
│    notify only on WARN / CRIT (same threshold logic as above)       │
└─────────────────────────────────────────────────────────────────────┘
```

Example output (illustrative – the CPU Oct 2026 risk matrix is not published yet, numbers invented):

```
SEVERITY: CRIT
FINDING: CPU Oct 2026 released – WLS 14.1.2.0.0 and Java SE 21.0.12.1 affected; applied cycle is CSPU Sep 2026
ROOT_CAUSE: 3 new WLS CVEs remote w/o auth over HTTP (CVSS ≥ 9), reachable through Nginx; JDK_HOME 21.0.12.1 listed as affected
RECOMMENDED_ACTION: KA1182 → update oracle_software_version.conf + download/patches_fmw.csv (draft attached), 04-oracle_pre_download.sh --apply --mos, 07-Maintenance patch cycle, new JDK via 02b-
TICKET_RELEVANCE: yes
```

### Why an agent fits this job

Steps 1 and 2 are plain scripts. Step 3 is where a model helps: the
product names in the risk matrix do not map 1:1 to OPatch component names,
the exposure depends on this installation (Nginx, which managed servers,
Forms deployed or not), and the outcome should be a short, prioritised list
with the matching project script – not 1283 CVE rows. Two ways to run it:

| Option | How | Pros / cons |
|---|---|---|
| **Claude API** (`claude_analyze.sh`, as planned above) | the script sends `inventory.json` + `candidates.json`, gets the SEVERITY block back | deterministic input, small data, no tools on the server; the model cannot look anything up itself |
| **Claude Code headless** (`claude -p` from the timer, restricted tools: read-only repo + `curl` to the advisory URLs) | the agent runs steps 2–3 itself, can read the repo docs (`00-patch-references.md`, KA notes) and write the draft | more flexible (new advisory formats, follow-up lookups); needs a tool allow-list and must never run `--apply` scripts or `opatch` |

In both cases: **read-only** – the job never downloads or applies patches,
it only reports and drafts. Applying stays a human decision (patch cycle in
`07-Maintenance/README.md`).

### Data leaving the server

Only product names, versions and patch numbers – no host names, IPs,
domain names, customer names or credentials (same rule as for commits).
`--dry-run` shows the exact payload.

### Configuration (`monitor.conf`)

| Parameter | Meaning | Default |
|---|---|---|
| `CVE_WATCH_ENABLED` | enable the monthly job | `true` |
| `CVE_MIN_CVSS` | report threshold | `7.0` |
| `CVE_CRIT_CVSS` | CRIT if remote w/o auth and exposed | `9.0` |
| `CVE_EXPOSED_PROTOCOLS` | what the frontend publishes | `HTTP` (Nginx 443) |
| `CVE_ACCEPTED` | accepted CVEs with reason + date (allow-list) | empty |
| `CVE_KEV_FEED` | CISA Known Exploited Vulnerabilities JSON | `https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json` |

### Open points

- **Patch ↔ CVE mapping** is only in MOS KA1182 (login). Without it the
  job can decide "newer cycle released than applied → affected
  components" but not "this CVE is fixed by that patch". Check whether the
  MOS credentials already used by `getMOSPatch` (`mos_sec.conf.des3`) can
  read KA1182 in a supported way; otherwise the cycle comparison + a human
  look into KA1182 stays the method.
- Risk-matrix HTML format can change → parser with a self-test (known CVE
  rows of CSPU Sep 2026 as fixture).
- `dnf updateinfo` needs repository access (hung on the test host without
  it) → timeout, report "not checked" instead of blocking.
- Client side (Java on the PCs, FSAL) is out of scope – listed as a hint
  only when Java SE is in an advisory.

---

## Certificate expiry – cert_expiry_check.sh

```bash
./10-Monitoring/cert_expiry_check.sh                    # run the checks now
./10-Monitoring/cert_expiry_check.sh --cron             # show the crontab line
./10-Monitoring/cert_expiry_check.sh --cron --apply     # install it (daily 06:15)
./10-Monitoring/cert_expiry_check.sh --cron --remove --apply
journalctl -t ihw-cert                                  # WARN / FAIL entries
```

Monitor role: calls the read-only checks of `08-SSL` and keeps their exit
codes, never `--apply`:

| Check | What | Exit |
|---|---|---|
| `08-SSL/ssl_config.sh --expiry` | the certificate Nginx **serves** on `127.0.0.1:443` (the file in `/etc/nginx/ssl` is root-only) | 0 / 1 < 30 days / 2 expired |
| `08-SSL/ssl_local_ca.sh status` | own root CA, server and code-signing certificate, chain, keystore – only if `SSL_CA_DIR/ca` exists | 0 / 1 missing, < 30 days, root < 365 days / 2 expired, broken |

Exit of the wrapper = the highest of both; WARN / FAIL also go to the
system journal (`logger -t ihw-cert`, priority warning / err) – the hook for
a log monitor until the notification step exists. The crontab line carries
the marker `# IHW cert_expiry_check` (install / update / remove are
idempotent). Live 2026-10-23: both OK (server 819 days, code signing 1089,
root 3644), same result with `env -i` (cron environment); installed in the
oracle crontab of the test host.

## Idea: configuration security scanner for WebLogic / Forms / Reports

**Status:** idea (2026-10-19) – not designed in detail yet.

The CVE watch answers "which known holes does the installed **code**
have?". A second, complementary job would answer "which holes does our
**configuration** open?" – the typical findings of a penetration test on a
Forms/Reports installation, checked by script before an auditor finds them.
Same principles: read-only, ok / warn / fail, SEVERITY block for Claude,
references to the project script that fixes it.

Candidate checks (to be verified against Oracle's "Securing a Production
Environment for Oracle WebLogic Server" and the Forms / Reports security
chapters before implementing):

| Area | Examples |
|---|---|
| WebLogic | production mode; demo identity / trust keystores still in use – **SSL listen ports enabled with the WebLogic demo certificate** (`CertGenCA`, `DemoCertFor_<domain>`): found 2026-10-19 on the test host, WLS_FORMS 9501 / WLS_REPORTS 9512 active although TLS ends at Nginx (bound to 127.0.0.1, behind the firewall; detected today by `02-Checks/ssl_check.sh` → FAIL) – fix: disable the SSL listen port in the domain setup (`09-Install/08-`) or own certificate in a custom keystore; T3 / IIOP reachable (`HttpTunnelingEnabled`, connection filter, `RemoteAnonymousRMIT3Enabled`); sample / unused deployments (e.g. `wls-wsat`, async); admin console / EM / `/management` reachable through Nginx from outside; account lockout settings; `boot.properties` encrypted; audit provider |
| Forms | `formsweb.cfg`: public `debug` / test configurations, `allowNewConnections`, `userid=` accepted in the URL, test modules deployed (`test_form` from 15-); `webutil.cfg`: `transfer.appsrv.read/write` directories, host command / OLE enabled without need; signed jars (JACOB) and expiry |
| Reports | rwservlet web commands open (`showenv`, `showjobs`, `getserverinfo`, `killjobs` – doc 81); `DIAGNOSTIC` in `rwservlet.properties`; `<identifier>` and `securityId` set (`REPORTS_SECURITY`); `cgicmd.dat` with clear-text `userid`; `folderAccess` read / write paths |
| Nginx / TLS | protocols and ciphers (`ssl_config.sh`), only the needed locations proxied, security headers, certificate expiry (`ssl_local_ca.sh status`) |
| OS | firewall active and only ssh / 80 / 443 / Reports UDP open, sshd hardening (`01-root_os_baseline.sh` sections 8 + 9), permissions of `*.des3`, keystores, `boot.properties`, world-readable config files |
| External view | optional probe from a second host: what an attacker sees (open ports, reachable URLs, error pages with version strings) |

Relation: `02-Checks/ssl_check.sh` already finds demo certificates on the
WLS SSL ports (2026-10-19); `cve_inventory.sh` section 4 (active use / exposure) is the first
building block – it already finds open sockets and the missing firewall
(2026-10-19).

---

## Claude Code setup – setup_claude.md

Precondition for every Claude-based script here: [setup_claude.md](setup_claude.md)
– never on a production host (`IHW_ENV_TYPE=prod`), managed settings with
sandbox, secret deny rules and the guard hook [claude/ihw_guard.sh](claude/ihw_guard.sh);
check and install commands: `./10-Monitoring/claude_setup_check.sh [--profile maintainer] [--apply]`.
The same sandbox is the base for the proactive log analysis below.

## Patch-cycle analysis – patch_cycle_analysis.sh

Standardised analysis of every Oracle cycle (CPU, CSPU, Security Alert) with
Claude Code. Procedure, rules and the registry "where the cycle lives in the
lib": [patch_cycle_analysis_skill.md](patch_cycle_analysis_skill.md); the
Claude Code skill `/patch-cycle-analysis` points to it – template
[claude/skills/patch-cycle-analysis/SKILL.md](claude/skills/patch-cycle-analysis/SKILL.md),
copied once into the local, untracked `.claude/skills/` (`.claude/` is not in Git):
`mkdir -p .claude/skills && cp -r 10-Monitoring/claude/skills/patch-cycle-analysis .claude/skills/`.

```
1 ANALYSE  prepare: public Oracle sources      -> readme_list.md (what to download)
           analyse: READMEs + collector archive -> analysis README + manual guide
2 MANUAL   apply by hand (manual guide) or with the released lib (07-Maintenance 80-82)
3 UPDATE   maintainer only: update_plan.md = the prompt that switches the lib
```

```bash
./10-Monitoring/patch_cycle_analysis.sh                       # status: cycle, newer advisories, Patch-Doku
./10-Monitoring/patch_cycle_analysis.sh prepare --apply       # next cycle (index or calendar), start Claude
#   -> download the documents of readme_list.md into Patch-Doku/<yyyy-mm>_<cycle>/readmes/
./10-Monitoring/patch_cycle_analysis.sh analyse --env /tmp/fmw_env_full.tgz --apply           # customer
./10-Monitoring/patch_cycle_analysis.sh analyse --mode maintainer --apply                       # we
./10-Monitoring/patch_cycle_analysis.sh analyse --print-prompt                                  # prompt only
claude "$(cat 70-Customer-Projects/Forms14_reports14_patch_analyse_<mm>_<yyyy>/update_plan.md)" # stage 3
```

| Mode | Writes | End of the cycle |
|---|---|---|
| `customer` (default) | only `10-Monitoring/Patch-Doku/<cycle>/result/` – the repo stays untouched | patches by hand; for automation pull the current release of the lib |
| `maintainer` | snapshot + new `09-Install/docs/00-patch-references.md`, new 70 folder, `update_plan.md` | after the live run: session with `update_plan.md`, commit, `git tag <cycle>` |

`Patch-Doku/` is gitignored (Oracle documents, customer data). The script
never runs as root and needs `claude` in `PATH`; without `--apply` it only
shows what it would do. Claude needs permission for `curl` to
`www.oracle.com` and for writing into `Patch-Doku/` – grant it at the first
prompt or in `.claude/settings.json`. The cycle detection
(`ihw_oracle_advisories`, third Tuesday) is shared with `cve_inventory.sh`
section 6; before the release the next cycle comes from the calendar (CPU in
Jan/Apr/Jul/Oct, CSPU in the months between).

## Planned Scripts

| Script | Purpose |
|---|---|
| `claude_monitor.sh` | Orchestrator – runs the collection step, calls `claude_analyze.sh`, handles notification. Cron-friendly (no interactive prompts). |
| `claude_analyze.sh` | Builds the prompt from collected findings + `monitor.conf`, calls the Claude API, parses the structured response. |
| `cve_inventory.sh` | **implemented** – CVE watch step 1 – installed components, patches, both JDKs, OS errata → `inventory.json` (local, read-only) |
| `claude_setup_check.sh` | **implemented** – Claude Code sandbox / managed settings / guard hook / `IHW_ENV_TYPE` check, `--apply` renders the managed settings ([setup_claude.md](setup_claude.md)) |
| `patch_cycle_analysis.sh` | **implemented** – starts the Claude patch-cycle analysis (prepare / analyse, customer / maintainer), see above |
| `cert_expiry_check.sh` | **implemented** – daily certificate expiry check (cron), calls `08-SSL/ssl_config.sh --expiry` + `ssl_local_ca.sh status`, journal tag `ihw-cert` |
| `cve_watch.sh` | CVE watch steps 2–4 – fetch advisories since the applied cycle, match against the inventory, hand candidates to Claude, write `reports/cve_<yyyy-mm>.md` |
| `monitor.conf.template` | Committed template: thresholds, known-issue allow-list, notification target, run mode defaults. |
| `monitor.conf` | **Gitignored** – server-specific config incl. API key reference. |

Following the project convention, the Claude API key itself is **not** stored
in plain text in `monitor.conf`. It is encrypted the same way as
`weblogic_sec.conf` (`openssl des3` keyed off `SYSTEMIDENTIFIER`) and decrypted
only in-memory when `claude_monitor.sh` runs.

---

## Run Modes

| Mode | When | Behaviour |
|---|---|---|
| `--scheduled` | Cron, e.g. hourly | Silent unless a finding crosses the WARN/CRIT threshold |
| `--interactive` | Manual, ad-hoc | Always prints the full report, even if everything is OK |
| `--cve` | Monthly (third Tuesday + 1 day) or on demand | CVE watch only (see above) |
| `--incident` | Manual, after a reported problem | Collects a wider log window + all checks, runs a deeper analysis, produces a support-case-ready summary |

---

## Expected Output Format

Claude's response is parsed into a fixed structure so it can be logged,
grepped, and thresholded without depending on free-text parsing of the whole
answer:

```
SEVERITY: OK | WARN | CRIT
FINDING: <one-line summary of the most relevant issue, or "no anomalies">
ROOT_CAUSE: <short technical explanation, referencing which check found what>
RECOMMENDED_ACTION: <concrete next step, ideally referencing an existing script>
TICKET_RELEVANCE: yes | no
```

Example:

```
SEVERITY: WARN
FINDING: Reports engine queuing time exceeds elapsed time (avgQueuingTime 850ms > avgElapsedTime 400ms)
ROOT_CAUSE: engine_perf_analyse.sh reports a queue bottleneck; maxEngine=2 appears undersized for current load
RECOMMENDED_ACTION: Review 05-ReportsPerformance/engine_perf_settings.sh --apply, consider increasing maxEngine
TICKET_RELEVANCE: no
```

---

## Notification

Not yet decided – candidates:

| Option | Pros | Cons |
|---|---|---|
| Local file only (`reports/`) | No dependency, always works | Requires someone to check |
| `mailx` / `sendmail` | Simple, no external service | Needs local MTA configured |
| Webhook (Teams / Slack) | Immediate visibility | Needs outbound HTTPS + secret handling |

Default plan: always write to `reports/`; email as an opt-in via `monitor.conf`.

---

## Relationship to Other Modules

Rule (folder roles, [root README](../README.md)): this module calls the
analyse scripts of 01–07 **read-only** – never `--apply`, no own copies of
their logic. Repairs stay a human decision in 01–07.

| Module | Role in this module |
|---|---|
| `02-Checks/` | Primary data source – OS, Java, SSL, port, WebLogic health |
| `09-Install/oracle_software_version.conf`, `09-Install/docs/00-patch-references.md` | Applied / configured patch cycle; target of the CVE watch drafts |
| `07-Maintenance/` (patch cycle) | Where a CVE watch finding leads to |
| `01-Run/rwserver_status.sh`, `01-Run/reports_server_lib.sh` | Reports engine live status; the library is the one place that reads `getserverinfo` (with `authid`) |
| `05-ReportsPerformance/` | Reports engine performance findings |
| `06-FormsDiag/` | Forms performance findings |
| `03-Logs/` | Error pattern scanning (ORA-, REP-, FRM-) |
| `00-Setup/weblogic_sec.sh` | Encryption pattern reused for the Claude API key |
| `07-Maintenance/backup_config.sh` | Not directly used, but config drift found here may point back to it |

---

## Open Items (TODO)

- Decide on Claude API access method (direct REST via `curl`, or a thin Python wrapper using the Anthropic SDK)
- Define `monitor.conf` parameter list (thresholds, allow-list format, notification target)
- Implement `claude_monitor.sh` (collection + orchestration)
- Implement `claude_analyze.sh` (prompt construction + API call + response parsing)
- Decide on notification mechanism (see above)
- Define retention policy for `reports/` (this directory will grow unbounded otherwise)
- Idea: configuration security scanner for WebLogic / Forms / Reports (section above) – design + check list
- CVE watch: `cve_inventory.sh` done (2026-10-19); next `cve_watch.sh` with risk-matrix parser + fixture test, decide API vs. Claude Code headless, clarify KA1182 access
- ~~Scheduled certificate expiry check~~ – done 2026-10-23 (`cert_expiry_check.sh`, cron)
- Uniform machine-readable output of the 01–07 scripts (report/JSON beside `print_summary`) as input for the collector – one format for all, not per script
- Consider a `--dry-run` mode that shows the exact prompt without calling the API (useful for prompt tuning and for reviewing what data leaves the server)
- **CSPU November 2026** (release 2026-11-17) = first real run of
  `patch_cycle_analysis.sh` (prepare → analyse `--mode maintainer` → live run
  → `update_plan.md`)
- **Claude sandbox rollout on the test host** (`IHW_ENV_TYPE=test`,
  `claude_setup_check.sh --profile maintainer --apply`, root: bubblewrap +
  socat, `/etc/claude-code/`) – [setup_claude.md](setup_claude.md); Node.js of
  Claude Code from 20 (EOL) to 22 / 24 LTS
- **Proactive log analysis** on that sandbox (headless `claude -p`, read-only
  inputs; the logs now include the ORDS group of `03-Logs/log_locations.sh`);
  open: read-only mount of the production log directories on the analysis host
- Notification of the cron checks (`cert_expiry_check.sh` writes only to the
  journal tag `ihw-cert` today)

Same list, project-wide: root [README.md – Open Items, Monitoring](../README.md#monitoring-phase-9).
