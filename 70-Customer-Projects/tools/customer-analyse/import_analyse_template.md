# Forms & Reports configuration analysis – {{CUSTOMER}}

| | |
|---|---|
| Customer | {{CUSTOMER}} |
| Analysis date | {{DATE}} |
| Source host | {{SRC_HOST}} |
| Source ORACLE_HOME | `{{SRC_ORACLE_HOME}}` |
| Source DOMAIN_HOME | `{{SRC_DOMAIN_HOME}}` |
| Source FMW version | {{SRC_FMW_VERSION}} |
| Source Java | {{SRC_JAVA}} |
| Export | `{{EXPORT_FILE}}` – export_forms_reports_conf.sh {{EXPORT_VERSION}} |
| Reference for 14c | {{REF_INFO}} |
| Created by | analyse_forms_reports_export.sh {{ANALYSE_VERSION}} (ihw_tools_lib {{LIB_VERSION}}) |

This report describes the Forms & Reports configuration of the existing
environment, as read from the configuration export. It is the starting point
for the rebuild on Oracle Forms & Reports 14.1.2 with the IHateWeblogic
library: section 12 shows the load of the last weeks, section 13 where each
part goes, section 14 what should be clarified or changed on the way.

**No password, key or other secret is shown in this report** – secrets are
only counted (section 11). The report contains host names, paths and user
directory names of the customer: hand it only to the customer.

## Contents

1. [Summary](#1-summary)
2. [Forms – configuration sections](#2-forms--configuration-sections-formswebcfg) –
   [2.1 `[default]` settings](#21-default-settings-that-differ-from-oracles-standard),
   [2.2 customer sections](#22-settings-of-the-customer-sections)
3. [Forms – environment files](#3-forms--environment-files) –
   [3.1 differing keys](#31-keys-that-differ-from-oracles-defaultenv),
   [3.2 timeout chain](#32-forms-runtime--timeout-chain)
4. [WebUtil](#4-webutil-webutilcfg)
5. [Customer jar files](#5-customer-jar-files)
6. [Reports](#6-reports) –
   [6.1 servers](#61-reports-servers), [6.2 servlet](#62-reports-servlet-rwservletproperties),
   [6.3 report keys](#63-report-keys-cgicmddat)
7. [Fonts](#7-fonts)
8. [Source directories](#8-source-directories)
9. [Dependencies](#9-dependencies)
10. [Oracle Net](#10-oracle-net-database-aliases)
11. [Secrets](#11-secrets)
12. [Load profile](#12-load-profile) –
    [12.1 Forms starts per section](#121-forms--application-starts-per-section),
    [12.2 Forms per day](#122-forms--requests-per-day),
    [12.3 Forms per hour](#123-forms--application-starts-per-hour),
    [12.4 Reports servers](#124-reports--server-counters),
    [12.5 Reports per report](#125-reports--jobs-per-report),
    [12.6 Reports requests](#126-reports--servlet-requests-per-day),
    [12.7 Host](#127-host--cpu-and-memory-sar)
13. [Target in 14c – how we build it](#13-target-in-14c--how-we-build-it) –
    [13.1 environment.conf values](#131-values-for-the-14c-environmentconf),
    [13.2 web tier](#132-web-tier--routing-today-and-in-14c)
14. [Findings and recommendations](#14-findings-and-recommendations) –
    [14.1 security](#141-security-findings), [14.2 other](#142-other-findings),
    [14.3 not checked](#143-not-checked)

---

## 1. Summary

| Item | Count |
|---|---|
| Forms configuration sections (`formsweb.cfg`) | {{N_FORMS_SECTIONS}} |
| Forms environment files (`envFile`) | {{N_ENV_FILES}} |
| Customer jar files | {{N_JARS}} |
| Reports servers | {{N_REPORTS_SERVERS}} |
| Font files | {{N_FONTS}} |
| Source directories (Forms / Reports) | {{N_SOURCE_DIRS}} |
| Compiled modules analysed for dependencies | {{N_MODULES}} |
| TNS aliases (defined / used) | {{N_TNS_DEFINED}} / {{N_TNS_USED}} |
| Places with secrets (passwords, keys) | {{N_SECRETS}} |
| Findings: WARN / HINT / INFO | {{N_WARN}} / {{N_HINT}} / {{N_INFO}} |

The most important findings are in [section 14](#14-findings-and-recommendations).

## 2. Forms – configuration sections (`formsweb.cfg`)

Each section is one way to start the application (URL `…/forms/frmservlet?config=<section>`).
"userid" shows whether a database login is stored in the section (the value
is never shown).

<!-- BLOCK:forms_sections -->

### 2.1 `[default]` settings that differ from Oracle's standard

"14c standard" is the value in Oracle's 14.1.2 template of `formsweb.cfg`.

<!-- BLOCK:forms_default -->

### 2.2 Settings of the customer sections

All keys of the customer's own sections (values masked where they contain a
password).

<!-- BLOCK:forms_section_keys -->

## 3. Forms – environment files

<!-- BLOCK:env_files -->

### 3.1 Keys that differ from Oracle's `default.env`

<!-- BLOCK:env_keys -->

### 3.2 Forms runtime – timeout chain

Oracle's rule: `heartBeat` (client keep-alive, minutes) < `FORMS_TIMEOUT`
(runtime ends without client contact, minutes) < session-timeout of the
Forms servlet. Unset values are shown with Oracle's default.

<!-- BLOCK:forms_timeouts -->

## 4. WebUtil (`webutil.cfg`)

<!-- BLOCK:webutil -->

## 5. Customer jar files

Jar files the Forms client loads in addition to Oracle's (`archive=`,
`CLASSPATH`, `extensions.jnlp`). Oracle's own jars (`frm*.jar`) and JACOB are
excluded – they come with 14c.

<!-- BLOCK:jars -->

## 6. Reports

### 6.1 Reports servers

<!-- BLOCK:reports_servers -->

### 6.2 Reports servlet (`rwservlet.properties`)

<!-- BLOCK:rwservlet -->

### 6.3 Report keys (`cgicmd.dat`)

Only the key names – the parameters can contain logins.

<!-- BLOCK:cgicmd -->

## 7. Fonts

| Class | Meaning |
|---|---|
| customer | own or bought font (e.g. barcode) – must move to 14c |
| ms | Microsoft font – licensed with Windows / Office of the old host, may not simply be copied; 14c uses the free replacement |
| free | free font, installed as an OS package on 14c |

<!-- BLOCK:fonts -->

## 8. Source directories

Directories where Forms / Reports look for modules, libraries, images and
output (`FORMS_PATH`, `REPORTS_PATH`, Reports `folderAccess`, WebUtil
transfer). Counts per file type – the modules themselves are not part of the
export.

<!-- BLOCK:sources -->

## 9. Dependencies

Read from the compiled modules (heuristic: names of libraries and menus
found in `.fmx` / `.mmx` / `.plx`).

### 9.1 Libraries and menus used

<!-- BLOCK:deps_libs -->

### 9.2 Missing references

<!-- BLOCK:deps_missing -->

## 10. Oracle Net (database aliases)

<!-- BLOCK:tns -->

## 11. Secrets

Where passwords or keys are stored today (number of places per file, keyword
hits – may include comments). In 14c these are replaced by encrypted storage
(WebLogic `boot.properties`, Reports `cmdkey` with the `RepRunner` user,
encrypted `<identifier>`, Oracle wallet).

<!-- BLOCK:secrets -->

## 12. Load profile

{{LOAD_INFO}}

The export only counts – no log line, client address, user name or report
parameter leaves the old host.

| | |
|---|---|
| Period of the access logs | {{LOAD_PERIOD}} |
| `frmweb` processes at the export (sessions + pool) | {{LOAD_FRMWEB}} |
| Reports engine processes at the export | {{LOAD_RWENG}} |
| Host at the export | {{LOAD_HOST}} |

### 12.1 Forms – application starts per section

Requests of the start page (`frmservlet?config=…`, HTTP 2xx) – about one per
application start. Sections of `formsweb.cfg` without a start in the period
are listed with 0.

<!-- BLOCK:load_forms_sections -->

### 12.2 Forms – requests per day

<!-- BLOCK:load_forms_days -->

### 12.3 Forms – application starts per hour

All days of the period added up – shows the working hours and the peak.

<!-- BLOCK:load_forms_hours -->

### 12.4 Reports – server counters

`getserverinfo` of every Reports server running at the export (counters since
the server start).

<!-- BLOCK:load_reports_servers -->

### 12.5 Reports – jobs per report

From the past job queue of the server (up to the last 1000 jobs).

<!-- BLOCK:load_reports_jobs -->

### 12.6 Reports – servlet requests per day

<!-- BLOCK:load_reports_requests -->

### 12.7 Host – CPU and memory (sar)

Daily average and peak of the CPU, average memory use (`sysstat`).

<!-- BLOCK:load_sar -->

## 13. Target in 14c – how we build it

| Part of the old environment | Target in the 14c installation (IHateWeblogic library) |
|---|---|
| `formsweb.cfg` `[default]` settings | `09-Install/forms_templates/formsweb.cfg.template` – only the differing keys, merged into Oracle's 14c file |
| own `formsweb.cfg` sections | own sections in the 14c `formsweb.cfg` (import step) |
| environment files (`*.env`) | `forms_templates/default.env.template` + one env file per application, paths from `environment.conf` |
| WebUtil settings | `forms_templates/webutil.cfg.template` (transfer directories below the Forms work area) |
| customer jar files | `$ORACLE_HOME/forms/java`, signed with the code-signing certificate (step `14-`), delivered to the clients by the Forms client distribution (`40-`) |
| Reports servers | standalone Reports server(s) from `environment.conf` (`13-`), secured (`securityId`, encrypted `<identifier>`) |
| Forms runtime tuning (`maxRuntimeProcesses`, prestart pool, timeout chain, access log) | values in `environment.conf` (`FORMS_MAX_RUNTIME_PROCESSES` proposed from the RAM, `FORMS_PRESTART_SECTION`), checked by `06-FormsDiag/forms_perf_settings.sh` (timeout chain, limits, pooling), load and response times measured by `forms_perf_analyse.sh` (`time-taken` in the access log) |
| Reports engine tuning (`engLife`, engines, heap, timeouts) | measured instead of fixed: values in `environment.conf` (`REPORTS_ENGINE_*`), checked against CPUs / RAM by `05-ReportsPerformance/engine_perf_settings.sh`, load and run times measured by `engine_perf_analyse.sh` (queuing, pool usage, `engineResponseTimeOut` proposal) – start values `engLife=50`, `initEngine`/`minEngine=2`, `maxEngine=5` |
| report keys (`cgicmd.dat`) | `cgicmd.dat` after the library block, logins via the `RepRunner` user |
| fonts | free replacements as OS packages (`14b-`), customer fonts into `04-ReportsFonts/custom_fonts_dir/` |
| source directories | one customer directory tree below `$ORACLE_BASE/forms` / `reports` (`FORMS_CUSTOMER_DIR`, `REPORTS_PATH`) |
| database aliases | one `tnsnames.ora` in one `TNS_ADMIN` for all processes |
| web tier (OHS / Apache with the WebLogic plug-in / Nginx) | one Nginx on the host (`04-root_nginx.sh`, TLS `05-root_nginx_ssl.sh`), WebLogic only on 127.0.0.1 – section 13.2 |

### 13.1 Values for the 14c `environment.conf`

The checklist for the 14c interview (`09-Install/01-setup-interview.sh`):
{{N_ENV_EXPORT}} values come from the export, {{N_ENV_DEC}} are decisions to
clarify with the customer, {{N_ENV_MISS}} are missing in this export. Host
layout and passwords are always asked during the installation – passwords are
never taken from an export.

<!-- BLOCK:env_values -->

### 13.2 Web tier – routing today and in 14c

{{WT_INFO}} "access" = restricted by allow / deny / Require / authentication
in that location.

<!-- BLOCK:web_tier -->

### 13.3 Raw proposal of the export (`environment.conf.proposal`)

```
{{ENV_PROPOSAL}}
```

## 14. Findings and recommendations

| Severity | Meaning |
|---|---|
| WARN | must be clarified or changed – would break or stay insecure in 14c |
| HINT | clean up during the move |
| INFO | for information |

### 14.1 Security findings

<!-- BLOCK:findings_security -->

### 14.2 Other findings

<!-- BLOCK:findings_other -->

### 14.3 Not checked

Rules that could not be applied with the data of this export:

<!-- BLOCK:not_checked -->

---
_Created with IHateWeblogic `analyse_forms_reports_export.sh` – https://pipperr.de_
