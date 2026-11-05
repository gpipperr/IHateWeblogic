# Patch analysis – {{CUSTOMER}}

| | |
|---|---|
| Customer | {{CUSTOMER}} |
| Analysis date | {{DATE}} |
| Host | {{SRC_HOST}} |
| ORACLE_HOME | `{{SRC_ORACLE_HOME}}` |
| DOMAIN_HOME | `{{SRC_DOMAIN_HOME}}` |
| FMW version | {{SRC_FMW_VERSION}} |
| Operating system | {{SRC_OS}} (glibc {{SRC_GLIBC}}) |
| Collection | `{{COLLECT_FILE}}` – collect_fmw_env.sh {{COLLECT_VERSION}}, {{COLLECT_DATE}} |
| Patch cycle (reference) | **{{CYCLE}}** – patch list `{{CSV_NAME}}` |
| Created by | analyse_patch_collect.sh {{ANALYSE_VERSION}} (ihw_tools_lib {{LIB_VERSION}}) |

This report compares the patch level of the environment, as read from the
collection, with the patch list of the cycle above:
- section 4 shows what is missing;
- section 7 shows what has to be in order before patching;
- section 8 shows how to patch: with the cookbook, or with the IHateWeblogic
  library scripts when the environment was built with them.

The collection only reads the system. No password is collected – values are
masked at the source. The report contains host names and paths of the
customer: hand it only to the customer.

**Basis:** the patch list is maintained per cycle from Oracle's Critical Patch
Update documentation:
- *Critical Patch Update (CPU) Program Patch Availability Document (DB-only)
  for Oracle Fusion Middleware*, MOS KA1182;
- the README of every patch.

Before the patch date check KA1182 again – Oracle can replace a patch number
within the cycle.

## Contents

1. [Summary](#1-summary)
2. [Environment](#2-environment)
3. [Installed patches](#3-installed-patches)
4. [Patch list of the cycle against this environment](#4-patch-list-of-the-cycle-against-this-environment)
5. [Java](#5-java)
6. [Other Oracle homes and web tier](#6-other-oracle-homes-and-web-tier) –
   [6.1 other homes](#61-other-oracle-homes), [6.2 web tier](#62-web-tier)
7. [OPatch prerequisites](#7-opatch-prerequisites) –
   [7.1 last patch runs](#71-last-patch-runs)
8. [How to patch](#8-how-to-patch) –
   [8.1 order of work](#81-order-of-work), [8.2 route A – cookbook](#82-route-a--cookbook),
   [8.3 route B – IHateWeblogic library](#83-route-b--ihateweblogic-library)
9. [Findings and recommendations](#9-findings-and-recommendations) –
   [9.1 findings](#91-findings), [9.2 not checked](#92-not-checked)

---

## 1. Summary

| Item | Count |
|---|---|
| Patches of the cycle that apply to this environment | {{N_APPLY}} |
| – already installed | {{N_INSTALLED}} |
| – **missing (to install)** | **{{N_MISSING}}** |
| Patches of the cycle not needed here (component not installed / optional) | {{N_NOT_NEEDED}} |
| Installed patches (`opatch lspatches`) | {{N_LSPATCHES}} |
| Findings: WARN / HINT / INFO | {{N_WARN}} / {{N_HINT}} / {{N_INFO}} |
| **Recommended route** | **{{ROUTE}}** |

{{SUMMARY_TEXT}}

## 2. Environment

What the patch selection depends on: the installed products and components
decide which patches of the cycle apply.

<!-- BLOCK:environment -->

## 3. Installed patches

`opatch lspatches` of the Oracle Home. Status:

| Status | Meaning |
|---|---|
| current cycle | the patch of the cycle (section 4) |
| part of the SPB | installed by the WebLogic Stack Patch Bundle (`opatch napply`) |
| older version – replaced | an older version of a cycle patch; the cycle patch rolls it back or replaces it |
| not in the cycle list – check | one-off or patch of an older cycle; check with its README whether it is still needed or conflicts |

<!-- BLOCK:installed -->

## 4. Patch list of the cycle against this environment

In the order of the patch list (= order of work). "applies" depends on the
installed components (section 2).

<!-- BLOCK:patchlist -->

## 5. Java

The server JDK is updated by a JDK patch of the cycle. The JDK bundled with
the Oracle Home (`oracle_common/jdk`) is not updated by the CPU. The client
JRE of the Forms users is part of the software distribution of the clients.

<!-- BLOCK:java -->

## 6. Other Oracle homes and web tier

### 6.1 Other Oracle homes

Every other home of the central inventory is patched on its own:
- database homes with the DB Release Update;
- a separate OHS / WebGate home with its own bundle patches.

<!-- BLOCK:other_homes -->

### 6.2 Web tier

{{WT_INFO}}

<!-- BLOCK:web_tier -->

## 7. OPatch prerequisites

<!-- BLOCK:prereq -->

### 7.1 Last patch runs

From `$ORACLE_HOME/cfgtoollogs/opatch` (newest first).

<!-- BLOCK:runs -->

## 8. How to patch

All servers of the domain and the Node Manager are stopped during OPatch –
plan a maintenance window: {{DOWNTIME}}. Before the first step:
- take a backup of the Oracle Home, the central inventory and the domain;
- the patch files are downloaded with `mos_patch_download.sh` from the same
  patch list (`-c {{CSV_NAME}}`).

### 8.1 Order of work

Only the missing patches of section 4, in the order of the patch list.

<!-- BLOCK:plan -->

### 8.2 Route A – cookbook

{{ROUTE_A}}

### 8.3 Route B – IHateWeblogic library

{{ROUTE_B}}

## 9. Findings and recommendations

| Severity | Meaning |
|---|---|
| WARN | must be solved before patching – or the environment stays vulnerable |
| HINT | clean up before or during patching |
| INFO | for information |

### 9.1 Findings

<!-- BLOCK:findings -->

### 9.2 Not checked

Rules that could not be applied with the data of this collection:

<!-- BLOCK:not_checked -->

---
_Created with IHateWeblogic `analyse_patch_collect.sh` – https://pipperr.de_
