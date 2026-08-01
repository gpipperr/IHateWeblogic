# 10-Monitoring – AI-Assisted Proactive Monitoring

**Module:** `10-Monitoring/`
**Runs as:** `oracle` (cron / systemd timer)
**Phase:** Ongoing operation – the last stage of the lifecycle, after installation,
configuration, SSL, fonts, performance tuning and Forms are all in place.

**Status:** Concept only – no scripts implemented yet.

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

## Planned Scripts

| Script | Purpose |
|---|---|
| `claude_monitor.sh` | Orchestrator – runs the collection step, calls `claude_analyze.sh`, handles notification. Cron-friendly (no interactive prompts). |
| `claude_analyze.sh` | Builds the prompt from collected findings + `monitor.conf`, calls the Claude API, parses the structured response. |
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
- Consider a `--dry-run` mode that shows the exact prompt without calling the API (useful for prompt tuning and for reviewing what data leaves the server)
