---
nav_title: "F&R – Java wechseln"
title: "Forms & Reports: neues JDK, Link und Domain umstellen"
description: "Neues Oracle JDK für Forms & Reports 12.2.1.4 / 14.1.2 installieren, versionsneutralen Link anlegen und die WebLogic-Domain von Hand darauf umstellen."
permalink: /70-Customer-Projects/FormsReports_change_java/
---

# Forms & Reports – neues JDK installieren und die Domain auf einen Link umstellen

Der FMW-Installer und WLST (`createDomain`, `updateDomain`, Config Wizard)
lösen einen JDK-Link auf und schreiben das **echte Versionsverzeichnis**
(`jdk-21.0.12.1`) in die Domain und ins Oracle Home. Wird beim nächsten
JDK-Update nur der Link umgebogen, laufen Node Manager, Server, OPatch und
WLST trotzdem weiter mit dem alten JDK.

Das Kochbuch beschreibt den Weg von Hand, ohne die IHateWeblogic-Skripte:

- [Java_wechsel_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/FormsReports_change_java/Java_wechsel_Kochbuch_de.txt) – neues JDK
  auspacken, `java.security` (SecureRandom) und eigene CAs in `cacerts`
  übernehmen, Link anlegen oder umbiegen, alle Dateien mit dem alten Pfad
  finden, sichern und mit vi auf den Link ändern, prüfen, Rückweg.

## Was angepasst wird

Gefunden auf dem 14.1.2-Testsystem (23 Dateien):

| Datei | Wofür |
|---|---|
| `$DOMAIN_HOME/bin/setDomainEnv.sh`, `setNMJavaHome.sh` | JDK der Server und des Node Managers |
| `$DOMAIN_HOME/nodemanager/nodemanager.properties` | `JavaHome=` des Node Managers |
| `$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/*/bin/*.sh` | Skripte der Forms-Instanz (Compiler, Builder) |
| `$DOMAIN_HOME/init-info/*` | Vorlagen, aus denen ein späteres `updateDomain` die Skripte neu schreibt |
| `$ORACLE_HOME/oui/.globalEnv.properties`, `oui/bin/*.sh` | `JAVA_HOME` von OPatch, `wlst.sh` und Installer |
| `$ORACLE_HOME/bin/aqxmlctl` | vom Installer geschrieben (kein Startpfad von Forms / Reports) |
| `~/.bash_profile` des oracle-Users | eigenes `JAVA_HOME` |

## Wo der echte Pfad bleibt

- **Der Link selbst** – die einzige Stelle, die auf das Versionsverzeichnis zeigt.
- **`$ORACLE_HOME/oracle_common/jdk`** – eigenes JDK im Home, kein Link; die
  Reports-Engines laufen fest damit (Produkteigenschaft).
- **Logs, `*.bak`, `servers/*/adr` (Incidents), `$ORACLE_HOME/inventory`** –
  Historie, wird nicht geändert.
- **`java.security` und `cacerts`** liegen *im* JDK-Verzeichnis: bei jedem
  Wechsel ins neue JDK übernehmen (Kochbuch Schritt 3).

Nach jedem `updateDomain` / Config-Wizard-Lauf steht wieder der echte Pfad in
den Dateien – dann Schritt 6 des Kochbuchs wiederholen.

## Automatisch

Mit der IHateWeblogic-Bibliothek erledigt
[07-Maintenance/domain_jdk_path.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/domain_jdk_path.sh)
die Schritte 6.1 bis 6.4 (ohne Parameter nur auflisten, `--apply` mit
Sicherung); das JDK-Update selbst macht
[09-Install/02b-root_os_java.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/02b-root_os_java.sh) `--upgrade-jdk`.
Hintergrund: [08-oracle_setup_domain.md §3b](../../09-Install/docs/08-oracle_setup_domain.md),
[01-root_setup_java.md](../../09-Install/docs/01-root_setup_java.md).
