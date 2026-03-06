# 05-ReportsPerformance – Oracle Reports Engine Performance

Diagnostics and tuning for Oracle Reports Server engine parameters.
All scripts source `environment.conf` and write output to `$DIAG_LOG_DIR/`.

---

## 1. Overview

| Script | Status | Purpose |
|---|---|---|
| `engine_perf_settings.sh` | ✅ implemented | Read and update engine/cache tuning parameters in `rwserver.conf` |
| `engine_perf_analyse.sh` | ✅ implemented | Live performance analysis via `getserverinfo` XML + WLS log scan |

---

## 2. Recommended Execution Order

```
Step 1 – Read current settings
  ./05-ReportsPerformance/engine_perf_settings.sh

Step 2 – Analyse live performance
  ./05-ReportsPerformance/engine_perf_analyse.sh
  ./05-ReportsPerformance/engine_perf_analyse.sh --lines 1000   # more log history

Step 3 – Apply tuning (if required)
  ./05-ReportsPerformance/engine_perf_settings.sh --apply
```

---

## 3. Script Reference

### engine_perf_settings.sh

```bash
./05-ReportsPerformance/engine_perf_settings.sh
./05-ReportsPerformance/engine_perf_settings.sh --apply
./05-ReportsPerformance/engine_perf_settings.sh --conf /path/to/rwserver.conf
```

Options:

| Option | Description |
|---|---|
| `--apply` | Interactive dialog to update parameters + backup + write |
| `--conf PATH` | Explicit path to `rwserver.conf` |

Sections in the output:

**1. Engine Parameters** – reads `<engine>` block from `rwserver.conf`:

| Parameter | Description | Oracle Recommendation |
|---|---|---|
| `minEngine` | Minimum engine instances always running | ≥ 2 to avoid cold-start delay |
| `maxEngine` | Maximum concurrent engine instances | Tune based on CPU cores and load |
| `engLife` | Max jobs per engine before restart | 50–500; lower = more isolation |
| `initTime` | Max seconds to wait for engine start | 30–120; increase if cold starts timeout |
| `maxIdle` | Max idle time (seconds) before engine is released | 120–600 |
| `jvmOptions` | JVM flags passed to rwengine JVM (heap, GC flags) | `-Xmx` matches report workload |

Evaluations:
- `minEngine = 0` or `1` → WARN cold-start risk
- `maxEngine < 2` → WARN single-threaded bottleneck
- `-Xmx` vs. available RAM → WARN if > 70% of free RAM

**2. Cache Parameters** – reads `<cache>` block from `rwserver.conf`:

| Parameter | Description |
|---|---|
| `cacheSize` | Max report cache entries |
| `maxJobSize` | Max size (bytes) of a cached report output |
| `purgeTime` | Seconds before old cache entries are purged |

**3. Live Process Check** – counts `rwengine` processes vs. `minEngine`/`maxEngine`.

**`--apply` mode:**

Interactive dialog prompts for new values.  Before writing, a timestamped backup
is created via `backup_file()`.  Values are updated with `sed` – no `xmllint` needed.

---

### engine_perf_analyse.sh

```bash
./05-ReportsPerformance/engine_perf_analyse.sh
./05-ReportsPerformance/engine_perf_analyse.sh --port 9012
./05-ReportsPerformance/engine_perf_analyse.sh --server repserver01
./05-ReportsPerformance/engine_perf_analyse.sh --lines 1000
./05-ReportsPerformance/engine_perf_analyse.sh --no-http
```

Options:

| Option | Description |
|---|---|
| `--port N` | WLS_REPORTS listen port (default: auto-detect from config.xml) |
| `--server NAME` | Reports Server name (default: from rwserver.conf) |
| `--lines N` | Last N lines of WLS_REPORTS log to scan (default: 500) |
| `--no-http` | Skip HTTP `getserverinfo` call (only log analysis) |

Sections in the output:

**1. Job Statistics** – from `getserverinfo` XML (`<property name="..."/>` elements):

| Property | Evaluation |
|---|---|
| `successfulJobs` | Baseline count |
| `failedJobs` | > 0 → WARN; > 5% of total → FAIL |
| `currentJobs` | > 0 → OK (engines working) |
| `potentialRunawayJobs` | > 0 → FAIL |

**2. Response Times** – timing analysis:

| Property | Unit | Bottleneck indicator |
|---|---|---|
| `averageResponseTime` | ms | End-to-end client wait |
| `averageElapsedTime` | ms | Actual engine processing time |
| `avgQueuingTime` | ms | Time waiting for a free engine |

Rule: `avgQueuingTime > avgElapsedTime` → queue bottleneck → increase `maxEngine`.

**3. Engine Pool** – live idle/busy state per engine instance from `getserverinfo`.

**4. Log Analysis** – scans `$DOMAIN_HOME/servers/WLS_REPORTS/logs/`:

| Pattern | Meaning |
|---|---|
| `ORA-` | Oracle DB errors in Reports jobs → check with `db_connect_check.sh` |
| `REP-` | Oracle Reports engine errors |
| `Engine.*started` | Engine startup events (count vs. configured minEngine) |
| `OutOfMemoryError` | JVM heap exhausted → increase `-Xmx` in `jvmOptions` |

**5. Recommendations** – consolidated guidance based on all sections:
- Queuing bottleneck → increase `maxEngine`
- Heap issues → increase `-Xmx` in `jvmOptions`
- DB errors → run `02-Checks/db_connect_check.sh`
- Reports errors → run `03-Logs/grep_logs.sh 'REP-'`

---

## 4. Performance Tuning Best Practices

### Engine Pool

| Scenario | Recommendation |
|---|---|
| Reports start slowly (first job) | Increase `minEngine` to ≥ 2 |
| All engines frequently busy | Increase `maxEngine` (in steps of 2) |
| High memory consumption | Reduce `maxEngine` + increase `-Xmx` per engine |
| Memory leak symptoms | Reduce `engLife` (e.g. 50) to recycle engines more often |

### JVM Heap (`jvmOptions`)

- Start with `-Xms256m -Xmx512m` per engine for standard reports
- Complex reports with large datasets or images: `-Xmx1024m` or higher
- Rule of thumb: `maxEngine × -Xmx` must fit in available RAM with headroom

### Cache

| Scenario | Recommendation |
|---|---|
| Reports re-run unchanged frequently | Increase `cacheSize` |
| Large PDF/XLS output | Increase `maxJobSize` |
| Cache fills disk | Reduce `purgeTime` or `cacheSize` |

---

## 5. Related Scripts

| Script | Purpose |
|---|---|
| `01-Run/rwserver_status.sh` | Engine health + live job status via rwservlet |
| `02-Checks/db_connect_check.sh` | Diagnose DB connection (ORA- errors in Reports) |
| `03-Logs/grep_logs.sh` | Search logs for REP- / ORA- error patterns |
| `07-Maintenance/backup_config.sh` | Backup rwserver.conf before tuning |

---

## 6. References

- Oracle Reports Tuning Guide – Engine Configuration:
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_tune003.htm#RSPUB23760
- Oracle Reports Troubleshooting (rwrun segfault / engine crashes):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_troubl.htm
- Oracle FMW 14.1.2 System Requirements:
  https://docs.oracle.com/en/middleware/fusion-middleware/fmw-infrastructure/14.1.2/infst/
