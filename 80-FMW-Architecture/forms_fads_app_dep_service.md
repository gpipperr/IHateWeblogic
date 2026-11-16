---
title: "Oracle Forms FADS – Application Deployment Services"
description: "What Oracle Forms Application Deployment Services (FADS) is, whether it is part of every Forms 12.2.1.4 / 14.1.2 domain, what it changes, pros and cons."
---

# Oracle Forms Application Deployment Services (FADS)

Short summary of FADS for Forms 12.2.1.4 and 14.1.2 – what it is, whether
it comes with every installation, which files it changes, and when it is
worth it. Markers as in [README.md](README.md): **documented** (sources at
the end), **confirmed (live)** = test host 2026-11-16 (Forms 14.1.2, CPU Oct
2026), **assumption**.

## What it is

A deployment tool for Forms applications, available since 12.2.1.3
(**documented**):

| Part | What it does |
|---|---|
| **Forms Application Packager** (`fa_packager.sh`) | packs the artifacts of one application (`fmb`, `mmb`, `pll`, `olb`, `sql`, user exits, client jars, WebUtil files) plus a descriptor into a **`.far`** archive |
| **FADS web UI** (`/fadsui`) and **FADSCLI** (`fadscli.sh`) | upload / deploy a `.far` to the Forms managed servers, list, download and delete archives; login = the Fusion Middleware Control (EM) admin user |
| **FADS services** (`fads.ear`, `fads-ui.ear`) | run on the **AdminServer**, keep an **archive repository** of every deployed version (redeploy / go back) |

When an application is deployed, FADS **compiles** it and **merges** its
configuration into the server files (**documented**):

| From the `.far` | Into |
|---|---|
| `app.cfg` | **`formsweb.cfg`** – a new section named after the application (empty when no `app.cfg`; `userid` is ignored; no section `default` allowed) |
| `app.env` | a new **`<appname>.env`** (created even without `app.env`) |
| `app_jvmcontrollers.cfg` | **`jvmcontrollers.cfg`** |
| `app_registry.dat` | **`Registry.dat`** |

## Is it always there?

**The software yes, the service no.**

- The files are installed with every Forms Oracle Home:
  `$ORACLE_HOME/forms/fads/` with `fads.ear`, `fads-ui.ear`,
  `fads_config.py`, `fads-client/`, `policy/fadsWSMPolicy.zip`
  (**confirmed (live)**; on the test host the EAR files still carry the
  install date 2026-10-14 – the CPU October 2026 Forms QPR did not replace
  them).
- In a domain FADS exists **only when someone added it on purpose**
  (**documented**, 14.1.2 installation guide):
  1. Configuration Wizard: extension template *"Oracle Forms Application
     Deployment Service (FADS)"* (at domain creation or later), target
     `WSM-PM` to the AdminServer; for an upgraded domain the **UMS** schema
     of the RCU repository is needed;
  2. post step `wlst.sh $ORACLE_HOME/forms/fads/fads_config.py config` –
     shuts the AdminServer down, creates an **OWSM keystore** in OPSS
     (`kss://owsm/keystore`, key pair `fad`), a **WSM policy set** for the
     REST services (`oracle/multi_token_rest_service_policy`) and imports
     an authorization policy (read from the script, **confirmed (live)**);
  3. **after every Forms patch set or one-off:**
     `fads_config.py updateHostPort <adminhost> <port> <DOMAIN_HOME>` – the
     script takes `fads-ui.ear` from the (patched) Oracle Home again,
     rewrites the host / port in it and redeploys it.
- **Older releases (12.2.1.3 / 12.2.1.4) need SQL Developer in the Oracle
  Home:** `fads_config.py config` asks for "Oracle SQL Developer 4.2 or
  higher under ORACLE_HOME" and loads
  `sqldeveloper/sqldeveloper/lib/oracle.dbtools-common.jar` and
  `oracle.sqldeveloper.sqlcl.jar` from it. These jars exist only up to SQL
  Developer **17.x** – with 19.x the script stops with `NameError: system`;
  Oracle's answer: "Do not update SqlDeveloper beyond version 17"
  (**documented**, MOS KB147124 / Doc ID 2639008.1). So a FADS domain of
  that age keeps an old SQL Developer inside the FMW home – one more
  outdated component on the server.
- **14.1.2:** no SQL Developer check any more – `fads.ear` carries its own
  `APP-INF/lib/dbtools-common-21.2.0.jar`, and `fads_config.py` only
  undeploys an old `fads-dbtools-library` when it finds one (**confirmed
  (live)**, test host: no `sqldeveloper/` in the Oracle Home).
- Test host: **not configured** – no FADS application in `config.xml`, no
  `/fadsui` route in the Nginx template of this library (**confirmed
  (live)**).

So "FADS overwrote the Forms configuration during a CPU" can only happen in
a domain where FADS was added. **Assumption** for the colleague's case, to
be checked there: the configuration files (`formsweb.cfg`, `Registry.dat`,
`jvmcontrollers.cfg`, the `.env` files) were written by a FADS (re)deploy
of the archived application versions, or the post-patch steps of FADS were
run while the files had been changed by hand outside FADS – FADS keeps its
own picture of each application and writes it back.

**Check:** the customer collector
[`collect_fmw_env.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/collect_fmw_env.sh) / `.ps1` (2026-11-16.1) records
"FADS in the domain" (FADS deployments in `config.xml`, the FADS template in
`init-info/domain-info.xml`) and "FADS software in home"; the patch analysis
reports a configured FADS as WARN, so an unintended FADS is seen before the
next patch.

## Pros and cons

| Pro | Con |
|---|---|
| one archive per application version, deploy to several managed servers in one step | **one more owner of `formsweb.cfg`, `Registry.dat`, `jvmcontrollers.cfg`, `*.env`** – hand edits, scripts (`09-Install/14-`) and FADS can overwrite each other |
| compile on the server, consistent artifacts | extra parts: OWSM keystore + policy set, `WSM-PM`, UMS schema, two applications on the AdminServer |
| archive repository = easy redeploy / roll back of an application | a web UI and REST services on the **AdminServer** (deploy rights = EM admin) – more attack surface; must stay behind the admin network, SSL recommended |
| CLI for scripting / CI | post step after **every** Forms patch (`updateHostPort`), forgotten → FADS broken or old version deployed |
| no file copying by hand on Linux hosts | FADSCLI takes admin and DB passwords **on the command line** (process list, shell history) |
| | web upload limit 100 MB per `.far`; ADF warnings in the AdminServer log are "normal" (noise) |
| | 12.2.1.x: depends on an old SQL Developer (≤ 17.x) inside the Oracle Home |

**For this library:** not used. Forms applications and their configuration
come from the customer's own deployment (Git, rsync, scripts) and from
`09-Install/14-oracle_setup_forms.sh` (merges key overrides into
`formsweb.cfg` / `default.env`). Using FADS as well would give the
configuration files two masters. Where a customer already runs FADS: back
up the Forms configuration before every patch, run the FADS post steps,
and compare the files afterwards
([`07-Maintenance/backup_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/backup_config.sh) category `forms_wls`).

## Sources

1. Working with Oracle Forms 14.1.2 – Oracle Forms Application Deployment
   Services: <https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/oracle-forms-application-deployment-services.html>
2. Working with Oracle Forms 12.2.1.4 – the same chapter:
   <https://docs.oracle.com/en/middleware/developer-tools/forms/12.2.1.4/working-forms/oracle-forms-application-deployment-services.html>
3. Installing Oracle Forms 14.1.2 – Installing the Forms Application
   Deployment Services (template, UMS, `fads_config.py config` /
   `updateHostPort`): <https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/installing-forms-application-deployment-services.html>
4. Forms 12.2.1.3 – FADS chapter (first release):
   <https://docs.oracle.com/middleware/12213/formsandreports/deploy-forms/oracle-forms-application-deployment-services-fads.htm>
5. MOS KB147124 / Doc ID 2639008.1 "FADS Configuration Script
   'fads_config.py' Issue" (last updated 2025-11-28): `NameError: system`
   in `fullConfig`, SQL Developer jars `oracle.dbtools-common.jar` /
   `oracle.sqldeveloper.sqlcl.jar` only up to SQL Developer 17.x
6. `$ORACLE_HOME/forms/fads/fads_config.py` of the test host (functions
   `fullConfig`, `updateOwsmFadsPolicy`, `updateHostPort`)
