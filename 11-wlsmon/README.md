---
title: "11-wlsmon – Lightweight Runtime Monitor for Oracle Forms & Reports 14c"
description: "wlsmon: read-only runtime monitor for Oracle Forms & Reports 14.1.2 – traffic light, components, key figures and history per host as static JSON, GUI with the APEX libraries behind Nginx, one GUI host for many data hosts."
permalink: /11-wlsmon/
---

# 11-wlsmon – lightweight runtime monitor

**Role: monitor, read-only.** The monitor gives operations and maintenance a
live view of a Forms & Reports environment:
- one traffic light per host;
- the state of every component (AdminServer, managed servers, Node Manager,
  Reports server, Nginx, data sources);
- key figures every 5 minutes – heap, stuck threads, Forms sessions, Reports
  queue, load, memory, disk, log errors, core dumps;
- the history over a day, a week and a year.

**State 2026-11-19: concept** –
[docs/01-wlsmon_concept.md](docs/01-wlsmon_concept.md), interface design
(colour concept): [docs/02-wlsmon_interface_design.md](docs/02-wlsmon_interface_design.md),
development plan (steps P1–P3): [docs/03-wlsmon_development.md](docs/03-wlsmon_development.md).
No script yet.

## In short

- **No extra software:**
  - python3 with its standard library (one program, 3.6-compatible), systemd
    and the existing Nginx;
  - only `dnf` packages from BaseOS / AppStream – no pip, PyPI or Galaxy;
  - the GUI uses two libraries APEX ships under `/i/` (font-apex icons, Oracle
    JET charts), so they are patched with APEX; the look is our own, in the
    colours of the project site.
- **No side effects on WebLogic:**
  - one read-only REST call per 5 minutes on `localhost`, no WLST;
  - the collector runs with low priority and hard systemd limits.
- **Data and GUI separated:**
  - every host writes 4 static JSON files;
  - one GUI host fetches them from many hosts and shows an overview with a
    drill-down per host.
- **Simple passwords:**
  - one login for people, only on the GUI host;
  - one technical pull user, the same on every data host and restricted to the
    IP of the GUI host;
  - the WebLogic monitor user (group Monitors) never leaves its host;
  - all secrets as encrypted systemd credentials, bound to the host.
- **Self-contained at runtime:** everything below `$ORACLE_BASE/admin/wlsmon`
  (program, rules, configuration, credentials); the repository and the
  library are only needed to install it. Nginx only reads it.
- **Installation (planned):**
  - `00-setup-interview.sh` (FMW owner): asks everything, defaults from
    `environment.conf` when present;
  - `01-install-wlsmon_fmw.sh` (FMW owner): program, GUI, monitor user;
  - `02-install-wlsmon_root.sh` (root, last): systemd units, Nginx include
    from a template, credentials, timers.

## Relation to 10-Monitoring

[10-Monitoring](../10-Monitoring/README.md) holds the periodic analyses: CVE
watch, certificate expiry, patch-cycle analysis. 11-wlsmon is the live
runtime view. Its daily facts (certificate days, patch cycle stamp) reuse the
logic of 10-Monitoring.

## Background

The first plan and the GUI prototype (2026-11-18) are local material and not in
git. The concept takes over:
- their JSON contract;
- their rollup rules;
- their Nginx / CSP rules.

Open work packages: [TODO.md](https://github.com/gpipperr/IHateWeblogic/blob/main/TODO.md) block "11-wlsmon".
