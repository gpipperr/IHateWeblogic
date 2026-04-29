# 06-FormsDiag – Oracle Forms Diagnostics & Performance

Diagnostics, configuration overview and performance analysis for Oracle Forms Server.
All scripts source `environment.conf` and write output to `$DIAG_LOG_DIR/`.

---

## 1. Overview

| Script | Status | Purpose |
|---|---|---|
| `forms_settings.sh` | ✅ implemented | Forms version, FORMS_PATH, config files, servlet config, fonts, live sessions, shared libs |
| `forms_perf_settings.sh` | ✅ implemented | Performance parameters from `formsweb.cfg`, `default.env`, WLS_FORMS JVM heap |
| `forms_perf_analyse.sh` | ✅ implemented | Live session memory analysis, HTTP response times, WLS_FORMS log scan |

---

## 2. Recommended Execution Order

```
Step 1 – Configuration overview
  ./06-FormsDiag/forms_settings.sh

Step 2 – Performance settings check
  ./06-FormsDiag/forms_perf_settings.sh

Step 3 – Live performance analysis
  ./06-FormsDiag/forms_perf_analyse.sh
  ./06-FormsDiag/forms_perf_analyse.sh --lines 1000   # more log history
```

---

## 3. Script Reference

### forms_settings.sh

```bash
./06-FormsDiag/forms_settings.sh
./06-FormsDiag/forms_settings.sh --forms-home /u01/oracle/fmw/forms
```

Options:

| Option | Description |
|---|---|
| `--forms-home PATH` | Explicit Forms home directory (auto-detected otherwise) |

Read-only. Sections:

| Section | What is checked |
|---|---|
| 1 – Forms Version | `frmcmp` binary, version from FMW inventory `registry.xml` |
| 2 – FORMS_PATH | Directories for `.fmx`/`.fmb` files – existence + file count per directory |
| 3 – Config files | Paths to `formsweb.cfg`, `default.env`, `registry.dat` |
| 4 – Servlet config | Key `formsweb.cfg` parameters: `serverURL`, `lookAndFeel`, `heartbeatInterval`, `separateFrame` |
| 5 – Fonts | `TK_FONTALIAS` / `uifont.ali` path, `[PDF:Subset]` section present |
| 6 – Live sessions | `pgrep frmweb` count + WLS_FORMS JVM PID |
| 7 – Shared libraries | `ldd frmweb` – missing `.so` files that cause startup failures |

---

### forms_perf_settings.sh

```bash
./06-FormsDiag/forms_perf_settings.sh
./06-FormsDiag/forms_perf_settings.sh --forms-home /u01/oracle/fmw/forms
```

Read-only. Sections:

**1. formsweb.cfg – Performance Parameters:**

| Parameter | Default | Recommendation |
|---|---|---|
| `heartbeatInterval` | 120 s | Match load balancer idle timeout; never 0 on LB environments |
| `maxEventBunchSize` | 25 | Increase to 50–100 on fast LAN; keep low on WAN |
| `networkRetries` | 3 | Increase to 5 on unreliable networks |
| `lookAndFeel` | Generic | Keep Generic for lighter client-side rendering |
| `separateFrame` | true | false = lighter HTML integration (browser-dependent) |
| `splashScreen` | – | Set to `no` to reduce perceived startup time |

**2. default.env – Timeouts:**

| Variable | Description | Recommendation |
|---|---|---|
| `FORMS_TIMEOUT` | Session idle timeout (minutes) | ≥ 30 min; align with business requirements |
| `TWO_TASK` | DB service name (Easy Connect) | Must resolve correctly or Forms cannot connect |
| `TNS_ADMIN` | `tnsnames.ora` directory | Must exist; use Easy Connect to avoid tnsnames |

**3. WLS_FORMS JVM Heap:**
- Reads `-Xms`/`-Xmx` from live process cmdline and/or `setDomainEnv.sh`
- Shows WLS_FORMS JVM RSS vs. configured `-Xmx`
- Estimates maximum session capacity (WLS_FORMS heap / avg session overhead)

---

### forms_perf_analyse.sh

```bash
./06-FormsDiag/forms_perf_analyse.sh
./06-FormsDiag/forms_perf_analyse.sh --lines 1000
./06-FormsDiag/forms_perf_analyse.sh --no-log
```

Options:

| Option | Description |
|---|---|
| `--lines N` | Last N log lines to analyse (default: 500) |
| `--no-log` | Skip WLS_FORMS server log scan |

Sections:

**1. Active Sessions:** counts `frmweb` processes, measures RSS per session,
estimates total Forms memory vs. available RAM.

**2. HTTP Response Times (`access.log`):**
Parses WLS HTTP access log for `/forms/frmservlet` requests.
Extracts min/avg/max response times and HTTP status distribution.

| Threshold | Evaluation |
|---|---|
| avg < 2000 ms | OK |
| avg 2000–5000 ms | WARN |
| avg > 5000 ms | FAIL |

> WLS access log must be enabled: WLS Console → WLS_FORMS → Logging → HTTP → Enable.

**3. Server Log Analysis:** scans `WLS_FORMS.log` for:

| Pattern | Meaning |
|---|---|
| `ORA-` | Oracle DB error in Forms → run `db_connect_check.sh` |
| `FRM-` | Oracle Forms application error |
| `timeout` / `timed out` | Session timeout – check `heartbeatInterval` vs. LB idle timeout |
| `OutOfMemoryError` | WLS_FORMS JVM heap too small |
| `Connection refused` | DB or internal service unreachable |

**4. Recommendations:** consolidated action items from all sections.

---

## 4. Performance Tuning Best Practices

### Session Memory Planning

Each active Forms session spawns one `frmweb` native process.
Typical RSS per session:

| Workload | Approx. RSS |
|---|---|
| Simple data entry forms | 50–80 MB |
| Complex multi-block forms | 100–150 MB |
| Forms with large LOVs / images | 150–250 MB |

**Rule of thumb:** available RAM for Forms = (WLS_FORMS JVM -Xmx) + (maxSessions × avgSessionRSS)

### formsweb.cfg Key Tuning Parameters

**`heartbeatInterval`** (seconds, default: 120)
- Client sends a keepalive request every N seconds when idle
- Too small (< 30 s): unnecessary server load for idle users
- Too large or 0: load balancer may drop idle connections mid-session
- **Recommendation:** Set to 80–90% of load balancer idle timeout

**`maxEventBunchSize`** (default: 25)
- Number of user events sent per network round-trip to the server
- Higher = fewer round-trips = better for high-latency WAN connections
- **Recommendation:** 25 (LAN), 50–100 (fast internal), 10–15 (high-latency WAN)

**`lookAndFeel`** (Generic / Oracle)
- Oracle look = additional JavaScript, richer widget rendering
- Generic = lighter, faster initial load
- **Recommendation:** Generic unless Oracle-specific UI features are required

**`separateFrame`** (true / false)
- true = Forms runs in a separate browser window or applet frame
- false = Forms embedded inline (requires compatible browser config)
- **Recommendation:** Depends on browser policy; false gives smoother integration

### WLS_FORMS JVM Sizing

```
Minimum (test):   -Xms256m -Xmx512m
Production small: -Xms512m -Xmx1024m  (up to ~10 concurrent users)
Production large: -Xms1g   -Xmx2g     (10–50 concurrent users)
High load:        -Xms2g   -Xmx4g     (50+ concurrent users)
```

Set in `$DOMAIN_HOME/bin/setDomainEnv.sh` for the `WLS_FORMS` server.

### `default.env` – Session Timeout

```
FORMS_TIMEOUT=60    # 60 minutes idle timeout – adjust to business requirements
```

Align with:
- Load balancer session persistence timeout
- `heartbeatInterval` (client keepalive must be shorter than FORMS_TIMEOUT)
- SSO session timeout (if Oracle SSO / SAML is in use)

### FORMS_PATH – FMX File Location

Forms looks for `.fmx` (compiled form) and `.mmx` (compiled menu) files in
`FORMS_PATH` at runtime. Missing entries cause `FRM-10043: Cannot find form`.

Best practice:
```
FORMS_PATH=/app/forms/custom:/app/forms/standard:$FORMS_HOME/forms
```
- Custom forms first (allows overriding standard forms)
- Keep `.fmx` and `.fmb` in the same directory tree (easier maintenance)
- Never put `.fmb` source files on a production server's `FORMS_PATH`

---

## 5. Troubleshooting

### FRM-10043: Cannot find form

```
Cause:  .fmx file not in any FORMS_PATH directory
Fix:    Check FORMS_PATH in default.env
        Compile .fmb → .fmx: frmcmp module=form.fmb userid=user/pass@db
        Copy .fmx to FORMS_PATH directory
```

### FRM-40010: Cannot read form

```
Cause:  .fmx compiled with newer Oracle Forms version than runtime
Fix:    Recompile .fmb against the correct $ORACLE_HOME version of frmcmp
```

### Session drops / disconnect after idle

```
Cause A: heartbeatInterval too large or 0 → LB drops connection
         Fix: set heartbeatInterval < LB idle timeout in formsweb.cfg
Cause B: FORMS_TIMEOUT too short
         Fix: increase FORMS_TIMEOUT in default.env
Cause C: WLS_FORMS HTTP session timeout
         Fix: increase WLS session timeout in WebLogic Console
```

### OutOfMemoryError in WLS_FORMS

```
Cause:  WLS_FORMS JVM -Xmx too small for concurrent session count
Fix:    Increase -Xmx in setDomainEnv.sh for WLS_FORMS
        Calculate: -Xmx >= maxSessions × avgSessionRSS + 512m (JVM overhead)
```

---

## 6. Related Scripts

| Script | Purpose |
|---|---|
| `00-Setup/init_env.sh` | Detect FMW/Domain paths, generate `environment.conf` |
| `02-Checks/db_connect_check.sh` | Diagnose DB connection (ORA- in Forms log) |
| `02-Checks/os_check.sh` | RAM / ulimits – prerequisites for Forms sizing |
| `04-ReportsFonts/uifont_ali_update.sh` | Font configuration (shared with Reports) |
| `07-Maintenance/backup_config.sh` | Backup `formsweb.cfg` / `default.env` before changes |

---

## 7. References

- Oracle Forms 14.1.2 – Working with Oracle Forms:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/toc.htm
- Oracle Forms 14.1.2 – Performance Tuning Considerations:
  https://docs.oracle.com/en/middleware/developer-tools/forms/12.2.1.19/working-forms/performance-tuning-considerations.html
- Oracle Forms 12.2.1 – Tuning Oracle Forms Services:
  https://docs.oracle.com/middleware/1221/formsandreports/deploy-forms/tuning.htm
- Oracle Forms 14.1.2 – Release Notes / What's New:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/releasenotes-fnr/whats-new-this-release.html
- Oracle Forms 14.1.2 – Documentation Home:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/index.html
