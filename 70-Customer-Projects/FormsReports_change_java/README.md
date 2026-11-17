---
nav_title: "F&R – Change Java"
title: "Forms & Reports: new JDK, link and domain switch"
description: "Install a new Oracle JDK for Forms & Reports 12.2.1.4 / 14.1.2, create a version-neutral link and switch the WebLogic domain to it by hand, step by step."
permalink: /70-Customer-Projects/FormsReports_change_java/
---

# Forms & Reports – install a new JDK and switch the domain to a link

The FMW installer and WLST (`createDomain`, `updateDomain`, Config Wizard)
resolve a JDK link and write the **real version directory**
(`jdk-21.0.12.1`) into the domain and the Oracle Home. If only the link is
moved at the next JDK update, Node Manager, servers, OPatch and WLST keep
running with the old JDK.

The cookbook (in German) describes the manual way, without the IHateWeblogic
scripts:

- [Java_wechsel_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/FormsReports_change_java/Java_wechsel_Kochbuch_de.txt) – unpack the
  new JDK, carry over `java.security` (SecureRandom) and own CAs in
  `cacerts`, create or move the link, find all files with the old path, back
  them up and change them to the link with vi, check, way back.

## What is changed

Found on the 14.1.2 test system (23 files):

| File | Purpose |
|---|---|
| `$DOMAIN_HOME/bin/setDomainEnv.sh`, `setNMJavaHome.sh` | JDK of the servers and the Node Manager |
| `$DOMAIN_HOME/nodemanager/nodemanager.properties` | `JavaHome=` of the Node Manager |
| `$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/*/bin/*.sh` | scripts of the Forms instance (compiler, Builder) |
| `$DOMAIN_HOME/init-info/*` | templates from which a later `updateDomain` rewrites the scripts |
| `$ORACLE_HOME/oui/.globalEnv.properties`, `oui/bin/*.sh` | `JAVA_HOME` of OPatch, `wlst.sh` and the installer |
| `$ORACLE_HOME/bin/aqxmlctl` | written by the installer (not a start path of Forms / Reports) |
| `~/.bash_profile` of the oracle user | own `JAVA_HOME` |

## Where the real path stays

- **The link itself** – the only place that points to the version directory.
- **`$ORACLE_HOME/oracle_common/jdk`** – the home's own JDK, not a link; the
  Reports engines always run with it (product behaviour).
- **Logs, `*.bak`, `servers/*/adr` (incidents), `$ORACLE_HOME/inventory`** –
  history, not changed.
- **`java.security` and `cacerts`** live *inside* the JDK directory: carry
  them over into the new JDK at every change (cookbook step 3).

After every `updateDomain` / Config Wizard run the real path is back in the
files – then repeat step 6 of the cookbook.

## Automated

With the IHateWeblogic library,
[07-Maintenance/domain_jdk_path.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/domain_jdk_path.sh)
does steps 6.1 to 6.4 (without parameters it only lists, `--apply` with
backup); the JDK update itself is done by
[09-Install/02b-root_os_java.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/02b-root_os_java.sh) `--upgrade-jdk`.
Background: [08-oracle_setup_domain.md §3b](../../09-Install/docs/08-oracle_setup_domain.md),
[01-root_setup_java.md](../../09-Install/docs/01-root_setup_java.md).
