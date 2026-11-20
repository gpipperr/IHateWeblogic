---
nav_title: "Load test concept"
title: "Load Testing Oracle Forms & Reports 14c – Concept"
description: "Concept for load tests of Oracle Reports and Forms 14.1.2: what to measure, load profiles, a curl-based Reports load generator, how results feed maxEngine, heaps and sizing, and the limits for Forms."
---

# Load testing Forms & Reports – concept

**State: concept (2026-11-20), nothing implemented.** Reports first; Forms
only as options and limits (section 8).

Markers as in [README.md](README.md): **confirmed (live)**, **documented**,
**assumption**.

---

## 1. Why – the values we only estimate today

Several sizing values of this library are estimates, and the documents say
so:

| Value | Today | Where |
|---|---|---|
| RAM per Forms session | 64 MB under load (**assumption**; measured: idle pooled `frmweb` 16 MB RSS, small test form 39 MB) | [forms_reports_sizing.md](../docs/forms_reports_sizing.md) |
| `maxRuntimeProcesses` | ½ RAM / 64 MB | same, [TODO.md](https://github.com/gpipperr/IHateWeblogic/blob/main/TODO.md) "with real load" |
| `maxEngine` / `initEngine` / `minEngine` | 5 / 2 / 2 (library default) | [reports_engine_architecture.md §6](reports_engine_architecture.md#6-performance-parameters-rwserverconf) |
| Engine heap | `-Xmx256M` inherited unless `jvmOptions` is set (**confirmed (live)** 2026-10-19) | same |
| `engineResponseTimeOut` | 360 min safety net, proposal 2 × longest job (test host: longest job 1 s) | same |
| ulimit tier > 1000 sessions | doubled from the tier below, no reference | [09-Install/01-setup-interview.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/01-setup-interview.sh) |

The analysis scripts
([`engine_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_analyse.sh),
[`forms_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_perf_analyse.sh))
**evaluate** load that happened – they do not create it. A load test fills
that gap: known load in, measured behaviour out.

**Questions a Reports load test answers:**

1. Throughput: reports per minute at which response time is still
   acceptable (and where it breaks).
2. Is `maxEngine` the bottleneck (queuing) or the CPU / the DB?
3. RAM per engine under load (RSS), heap high-water mark – the right
   `jvmOptions -Xmx`.
4. Behaviour above the limit: queue growth, `maxQueueSize`, REP errors,
   does the server recover after the burst?
5. Effect on the neighbours on a single host (WLS_FORMS heap, Forms
   response, the RCU DB).
6. Stability over hours (`engLife` recycling, memory growth, file handles).

---

## 2. Ground rules

- **Never on production without a written agreement and a test window.** A
  load test is a planned overload – it can stop real users' reports.
- **Test host or a clone first** ([clone_golden_image.md](clone_golden_image.md)).
  Constrained hosts: check `free -h` before each step (the test host had a
  real OOM kill of WLS_REPORTS).
- **Same rules as the scripts:** read-only by default; the load run itself
  needs an explicit flag (`--run`), the dry run shows the plan (URLs without
  secrets, steps, duration, stop criteria).
- **Secrets:** the run user comes from `reports_users.conf.des3`
  (execution user, as `12-oracle_reports_users.sh` created it); `authid`
  only in a curl config on stdin, all parameters as POST – a GET puts the
  password into the WLS access log
  ([reports_monitoring_getserverinfo.md §2.1](reports_monitoring_getserverinfo.md#21-send-everything-as-post--never-as-url-parameters)).
- **Load generator outside the measured host if possible** – curl on the
  same host competes for CPU. On a single host: note it in the result and
  keep the generator small (curl, no JVM).
- **Stop criteria are part of the plan, not an afterthought:** error rate,
  free RAM, swap, response time – the generator stops by itself.
- **No customer data in the repo:** results with customer report names stay
  local ([customer data rule](https://github.com/gpipperr/IHateWeblogic/blob/main/CONTRIBUTING.md)).

---

## 3. What is measured – and where it already comes from

| Layer | Measure | Source |
|---|---|---|
| Client (generator) | response time per request (p50 / p95 / max), HTTP code, output size, REP code in the body | the generator's CSV (section 6) |
| Nginx | request time `rt`, upstream time, 4xx / 5xx, `limit_req` rejects (503) | access log; [11-wlsmon](../11-wlsmon/README.md) `nginx_rpm` |
| rwservlet / WLS_REPORTS | heap, threads, stuck / hogging threads | 11-wlsmon (REST), [weblogic_rest_monitoring.md](weblogic_rest_monitoring.md) |
| Reports server | engines busy / idle / dead, queue length, jobs failed, `maxEnginesUsed` | `getserverinfo` – 11-wlsmon every 5 min, the generator before / after each step; [`engine_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_analyse.sh) |
| Engines | RSS per engine PID, engine restarts (`engLife`, crashes) | `rws_engine_pids` ([`reports_server_lib.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/reports_server_lib.sh)) + `/proc/<pid>/status` – sampled by the generator |
| Job run times | queue time vs. run time per job | `showjobs` `timingInfo` (`rws_job_runtimes`) |
| OS | CPU (user / sys / iowait / steal), load, free RAM, swap, disk I/O | 11-wlsmon host metrics; `vmstat 5` beside the run for a finer grid |
| Database | sessions, waits, top SQL of the report user | AWR / ASH if licensed (Diagnostics Pack), else `v$session` / `v$sql` snapshots – **open** |

11-wlsmon samples every 5 minutes – enough for soak tests, too coarse for a
5-minute step. The generator therefore samples `getserverinfo` and the
engine RSS itself every 10–15 s during a run.

---

## 4. Load paths for Reports

```
  generator (curl -P n)
        |  HTTPS POST /reports/rwservlet   (destype=cache, desformat=pdf)
        v
  Nginx  --(limit_req planned)-->  WLS_REPORTS (rwservlet)
                                         |  ORB
                                         v
                                   rwserver  --> engines (maxEngine)  --> DB
```

| Path | What it loads | Use |
|---|---|---|
| **A – rwservlet through Nginx, synchronous** (`destype=cache`) | the whole chain as a user sees it | main test; the client waits for the PDF, so response time = queue + run + transfer |
| **B – rwservlet on the WLS_REPORTS port** (loopback, bypasses Nginx) | WLS_REPORTS + server + engines | separates Nginx effects; needed while the planned `limit_req` for rwservlet would reject the load (TODO "Reports `authid` guessing") |
| **C – `rwclient`** (server name, no HTTP) | server + engines without rwservlet | batch-like load, cron jobs ([reports_job_handling.md](reports_job_handling.md)); flags for asynchronous submission still to verify (**assumption**) |
| **D – `rwrun`** (no server) | one engine + DB | baseline: the pure run time of one report without any queuing ([reports_engine_architecture.md §5.1](reports_engine_architecture.md#51-rwrun--a-report-without-rwservlet-and-without-reports-server)) |

Start with **D** (baseline per report), then **B**, then **A**. The
difference A − B is the cost of Nginx + TLS; B − D is queuing + server
overhead.

**Report mix** – a load test is only as good as its reports:

| Report | Purpose |
|---|---|
| `test_dual.rdf` (one row from DUAL) | pure server / engine overhead, engine start, `engLife` recycling |
| a long PDF (many pages, fonts, images) | CPU and engine heap; PDF font subsetting ([reports_fonts_architecture.md](reports_fonts_architecture.md)) |
| a DB-heavy report (large query, groups) | DB time vs. engine time |
| 2–3 real reports of the customer | the real mix – with the customer's test data and parameter sets |

The generator takes a mix file: report, parameters, weight. Parameters vary
per request (e.g. department, date range) so the DB cache does not turn the
test into a cache benchmark.

---

## 5. Load profiles

The Oracle rule for the engine count (**documented**,
[reports_engine_architecture.md §6](reports_engine_architecture.md#6-performance-parameters-rwserverconf))
is Little's law: *engines needed = average run time × request rate*. 10 s
per report and 30 reports per minute → 0.5 / s × 10 s = 5 engines. The
profiles test that rule instead of trusting it.

| Profile | Shape | Answers |
|---|---|---|
| **Baseline** | 1 client, 20 requests per report | run time per report without contention (path D and B) |
| **Step** | 1, 2, 4, 8, 16, … parallel clients, each step 5 min, 1 min pause | throughput curve; the knee where p95 rises – compare with `maxEngine` and CPU count |
| **Spike** | 3 × `maxEngine` clients for 2 min after a quiet phase | queue behaviour, engine start time (`initEngine` vs. `maxEngine`), recovery |
| **Soak** | expected peak (from the step test) for 2–4 h | memory growth, `engLife` recycling cost (live 2026-10-16: 85–661 ms per job), handle leaks, log growth |

Each profile is run twice: with the current values and with the changed
value (e.g. `maxEngine` 5 → 8) – one change per run.

**Stop criteria (defaults, configurable):** error rate > 5 % over 1 min,
`MemAvailable` < 10 %, swap in use grows > 256 MB during the run, p95 > 10 ×
baseline, any engine `status="0"` (dead) for two samples.

---

## 6. The Reports load generator – proposal

Script `05-ReportsPerformance/reports_load_test.sh`, library standards
([CLAUDE.md](https://github.com/gpipperr/IHateWeblogic/blob/main/CLAUDE.md)):

- Bash + `curl` + `xargs -P` – nothing to install, also runs on a separate
  Linux client with a copy of the script and a mix file. No JMeter / JVM on
  the measured host.
- `environment.conf` for the server name, the URL, the WLS_REPORTS port
  (`rws_wls_port`); the run user from `reports_users.conf.des3` through the
  library loader; one curl config per request on stdin
  (`data-urlencode = "authid=…"`), never argv.
- Options: `--profile baseline|step|spike|soak`, `--mix FILE`,
  `--path nginx|wls`, `--clients LIST`, `--step-sec N`, `--run` (without:
  dry run with the plan), `--max-errors PCT`, `--min-mem PCT`.
- Per request one CSV line: start time, step, client, report, HTTP code,
  `time_total`, `time_starttransfer`, size, REP code (from the body when it
  is not a PDF).
- Sampler beside the load: `getserverinfo` (engines, queue), engine RSS,
  `MemAvailable`, swap, load every 15 s → second CSV; the stop criteria are
  checked on these samples.
- Before / after: `getserverinfo` + `showjobs` snapshot, `rwserver.conf`
  engine values, `free -h`, `nproc` – so a result always names the
  configuration it was measured with.
- Summary per step: requests, throughput / min, p50 / p95 / max, error
  rate, max queue, `maxEnginesUsed`, max engine RSS, min `MemAvailable`;
  `print_summary` and exit code as usual.
- Output to `log/<date>/reports_load_<time>/` (not in git).
- Cleanup: `destype=cache` fills the Reports cache – the summary shows the
  cache size before / after; `cacheSize` is part of the evaluation.

Not in the first version: a GUI, distributed generators, Forms.

---

## 7. From the result to the setting

| Finding | Setting / document |
|---|---|
| Queue grows while CPU is idle, `maxEnginesUsed = maxEngine` | raise `maxEngine` ([`engine_perf_settings.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_settings.sh), `environment.conf REPORTS_ENGINE_*`) |
| CPU saturated before `maxEngine` is reached | `maxEngine` is too high for the CPU count – lower it, or more CPUs |
| Engine RSS near the heap limit, `OutOfMemory` in `rwEng-N_diagnostic.log` | engine `jvmOptions -Xmx` (`REPORTS_ENGINE_JVM_OPTIONS`; keep the ORB options, §6 of the engine page) |
| Long first requests after quiet phases | `initEngine` / `minEngine`, `maxIdle` |
| Recycling visible in p95 | `engLife` |
| Longest job under load | `engineResponseTimeOut` proposal (2 × longest, ≥ 5 min) |
| RAM per engine × `maxEngine` + heaps | RAM line in [forms_reports_sizing.md](../docs/forms_reports_sizing.md) – measured instead of estimated |
| DB time dominates | not a Reports setting – SQL of the report, DB sizing |

Results are written down as measured values with date and host profile
(CPU, RAM, engine values) – in the sizing page for the test host, in the
local customer analysis for a customer.

---

## 8. Forms – options and limits

Forms is much harder to load-test than Reports:

- One user action is a sequence of HTTP POSTs to `lservlet` carrying the
  Forms client protocol (binary, session-bound, one `frmweb` per session –
  [forms_runtime_architecture.md](forms_runtime_architecture.md)). A plain
  HTTP tool cannot replay it without understanding the protocol.
- Sessions are long-lived and stateful – the interesting load is "N users
  working", not "N requests per second".

| Option | What it is | Limits |
|---|---|---|
| **Oracle Application Testing Suite (OATS) / OpenScript** | Oracle's tool with a Forms protocol module (**documented**) | product status and support for Forms 14.1.2 to verify (**assumption**: no longer developed); Windows-based, licence |
| **Commercial tools with an Oracle Forms protocol** (e.g. LoadRunner "Oracle NCA") | record / replay of the Forms protocol | licence; support for 14.1.2 and the standalone launcher (FSAL) to verify |
| **Real clients, scripted** (several Windows clients with FSAL, UI automation) | real protocol, real `frmweb` | few sessions per client machine; brittle |
| **Observed real load** | 11-wlsmon (Forms sessions, heap, host) + [`forms_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_perf_analyse.sh) during a busy day | no control over the load, but real – and free |
| **DB side only** (Database Replay / SQL Performance Analyzer) | replays the DB workload of a real day | Real Application Testing licence; tests the DB, not Forms / WebLogic |
| **`frmweb` RAM per session** | measure RSS / PSS of real sessions with typical forms | gives the 64 MB value a measured base – no load generator needed |

**Proposal for Forms:** first replace the 64 MB assumption with
measurements of real sessions (last row) and observe a busy day with
11-wlsmon; a synthetic Forms load test only when a customer has one of the
tools or needs a capacity statement for a large user count.

---

## 9. Open points and next steps

| # | Step | State |
|---|---|---|
| 1 | Path D baseline with `rwrun` for `test_dual.rdf` and one larger report on the test host | open |
| 2 | Verify the rwservlet POST for a report run (`destype=cache`, `authid` in the body) and the `rwclient` flags | open |
| 3 | `05-ReportsPerformance/reports_load_test.sh` – dry run, then step profile on the test host (with `free -h` checks) | open |
| 4 | Decide how the planned Nginx `limit_req` for rwservlet and the load test fit (test via path B, or an allow-list for the generator IP) | open – TODO "Reports `authid` guessing" |
| 5 | Measured RAM per engine and per `frmweb` into [forms_reports_sizing.md](../docs/forms_reports_sizing.md) | open |
| 6 | OATS / Forms protocol tools: status for 14.1.2 | open |

Related TODO item: `maxRuntimeProcesses` / `engineResponseTimeOut` with real
load ([TODO.md](https://github.com/gpipperr/IHateWeblogic/blob/main/TODO.md)).
