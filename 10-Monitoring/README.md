# 10-Monitoring – AI-Assisted Proactive Monitoring

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
│  2. ANALYSE                                                       │
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

**Status:** step 1 implemented (`cve_inventory.sh`, 2026-10-19); steps 2–4
concept. Prototype of the later steps = the manual check of 2026-10-18 in
`09-Install/docs/00-patch-references.md`, section "CVE check".

### cve_inventory.sh (step 1, implemented)

```bash
./10-Monitoring/cve_inventory.sh              # inventory, read-only
./10-Monitoring/cve_inventory.sh --online     # + advisories after the configured cycle
./10-Monitoring/cve_inventory.sh --no-os      # without the dnf errata check
./10-Monitoring/cve_inventory.sh --json FILE  # default reports/inventory_<date>.json
```

| Section | Source | Result |
|---|---|---|
| 1. Components | `comps.xml` → advisory product names (WLS, JRF, OPSS, Coherence, Forms, Reports, OHS, WebGate) + libOVD jar date | version + "configured in the domain" / "binaries only" |
| 2. Patch level | `PATCH_CYCLE*`, `WLS_SPB_MARKER_PATCH`, `INSTALL_PATCHES*` from `09-Install/oracle_software_version.conf` vs. `opatch lspatches` | FAIL per missing configured patch; SPB level with build date; OPatch vs. `OPATCH_VERSION_MIN`; WARN for OHS / WebGate binaries in the home |
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
RECOMMENDED_ACTION: KA1182 → update oracle_software_version.conf (draft attached), 04-oracle_pre_download.sh --apply --mos, 07-Maintenance patch cycle, new JDK via 02b-
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

## Planned Scripts

| Script | Purpose |
|---|---|
| `claude_monitor.sh` | Orchestrator – runs the collection step, calls `claude_analyze.sh`, handles notification. Cron-friendly (no interactive prompts). |
| `claude_analyze.sh` | Builds the prompt from collected findings + `monitor.conf`, calls the Claude API, parses the structured response. |
| `cve_inventory.sh` | **implemented** – CVE watch step 1 – installed components, patches, both JDKs, OS errata → `inventory.json` (local, read-only) |
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

| Module | Role in this module |
|---|---|
| `02-Checks/` | Primary data source – OS, Java, SSL, port, WebLogic health |
| `09-Install/oracle_software_version.conf`, `09-Install/docs/00-patch-references.md` | Applied / configured patch cycle; target of the CVE watch drafts |
| `07-Maintenance/` (patch cycle) | Where a CVE watch finding leads to |
| `01-Run/rwserver_status.sh` | Reports engine live status |
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
- Consider a `--dry-run` mode that shows the exact prompt without calling the API (useful for prompt tuning and for reviewing what data leaves the server)
