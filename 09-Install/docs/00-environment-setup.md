# Environment Setup – Konzept und Parameter

**Ziel:** `environment.conf` erstellen, bevor oder nachdem Oracle FMW installiert wird.

---

## Übersicht: Wann wird `environment.conf` erstellt?

| Situation | Tool | Methode |
|---|---|---|
| **Neu-Install** (kein FMW vorhanden) | `09-Install/01-setup-interview.sh` | Interaktives Interview, Defaults vorschlagen |
| **Bestehende Umgebung, keine conf** | `00-Setup/env_check.sh --interview --apply` | Auto-Detect + User bestätigt/korrigiert |
| **Bestehende Umgebung, conf vorhanden** | `00-Setup/env_check.sh --apply` | Auto-Detect, fehlende Werte ergänzen |
| **Multi-Domain-Umgebung** | `00-Setup/set_env.sh` | Symlink auf aktive conf umschalten |

---

## Grundprinzipien

**Idempotent:** Jedes `--apply` schreibt nur Werte die noch nicht gesetzt sind.
Vorhandene Werte in einer bestehenden `environment.conf` werden nicht überschrieben —
außer der User gibt beim `--interview` explizit einen anderen Wert ein.

**Zwei Parameterklassen:**

```
[Install-Parameter]     → vom Interview gesetzt, vor der Installation bekannt
[Runtime-Parameter]     → von env_check.sh auto-detektiert, nach der Installation verfügbar
```

**Passwörter nie im Klartext:** Alle Passwörter werden sofort verschlüsselt
(via `00-Setup/weblogic_sec.sh`) und nur als `*.des3`-Dateien gespeichert.

---

## Ablauf Neu-Installation

```
1. 09-Install/01-setup-interview.sh --apply
   → Fragt alle Install-Parameter interaktiv ab
   → Schreibt environment.conf (nur Install-Parameter)
   → Verschlüsselt WLS-Admin-Passwort → weblogic_sec.conf.des3
   → Verschlüsselt MOS-Passwort      → mos_sec.conf.des3

2. [Phase 0–1 Installation läuft durch]

3. 00-Setup/env_check.sh --apply
   → Detektiert Runtime-Parameter (Pfade, Instanzen)
   → Ergänzt environment.conf um Runtime-Abschnitt
   → Vorhandene Install-Parameter werden nicht überschrieben
```

## Ablauf Bestehende Umgebung (keine conf)

```
1. 00-Setup/env_check.sh --interview --apply
   → Scannt laufende WLS-Prozesse, FMW-Pfade, jps-config.xml
   → Zeigt jeden erkannten Wert an, User bestätigt oder korrigiert
   → Schreibt vollständige environment.conf
```

---

## Alle Parameter

### Block 1 – Installations-Pfade
*(Install-Parameter – werden von `01-setup-interview.sh` gesetzt)*

| Variable | Default | Beschreibung | Validation |
|---|---|---|---|
| `ORACLE_BASE` | `/u01/app/oracle` | Basis-Verzeichnis für alle Oracle-Installationen | Verzeichnis schreibbar oder erstellbar |
| `ORACLE_HOME` | `$ORACLE_BASE/fmw` | FMW-Installationsziel (= `FMW_HOME` nach Install) | Muss leer sein vor Installation |
| `JDK_HOME` | `$ORACLE_BASE/java/jdk-21` | Oracle JDK 21 Symlink (von `02b-root_os_java.sh`) | `$JDK_HOME/bin/java -version` muss JDK 21 liefern |
| `PATCH_STORAGE` | `/srv/patch_storage` | Ablage für Installer-ZIPs und Patches | ≥ 20 GB frei |

### Block 2 – FMW-Laufzeit-Pfade
*(Runtime-Parameter – von `env_check.sh` nach der Installation detektiert)*

| Variable | Wert | Beschreibung |
|---|---|---|
| `FMW_HOME` | `$ORACLE_HOME` | FMW-Installationsverzeichnis (nach Install = `ORACLE_HOME`) |
| `WL_HOME` | `$FMW_HOME/wlserver` | WebLogic Server Heimat (abgeleitet) |
| `JAVA_HOME` | `$FMW_HOME/oracle_common/jdk` | FMW-gebündeltes JDK (≠ `JDK_HOME`!) |
| `WLST` | `$FMW_HOME/oracle_common/common/bin/wlst.sh` | WLST-Skript (abgeleitet) |
| `RWRUN` | `$FMW_HOME/bin/rwrun` | Reports rwrun-Binary (abgeleitet) |
| `RWCLIENT` | `$FMW_HOME/bin/rwclient` | Reports rwclient-Binary (abgeleitet) |

> **Wichtig:** `JAVA_HOME` in `environment.conf` zeigt auf das **FMW-gebündelte JDK**
> (`oracle_common/jdk`), nicht auf `JDK_HOME`. Oracle Support fragt bei Problemen
> immer nach dem JDK-Vendor — daher muss `.bash_profile` von `oracle` explizit
> `JDK_HOME` setzen, unabhängig von `alternatives`.

### Block 3 – WebLogic Domain
*(Mix: Basis vom Interview, Managed-Server-Name von env_check.sh detektiert)*

| Variable | Default | Beschreibung |
|---|---|---|
| `DOMAIN_HOME` | `$ORACLE_BASE/domains/fr_domain` | Domain-Heimat |
| `DOMAIN_NAME` | `fr_domain` | Domain-Name (= `basename $DOMAIN_HOME`) |
| `WL_ADMIN_URL` | `t3://localhost:7001` | T3-URL des AdminServers |
| `WLS_ADMIN_PORT` | `7001` | AdminServer HTTP-Port |
| `WLS_FORMS_PORT` | `9001` | WLS_FORMS Managed-Server-Port |
| `WLS_REPORTS_PORT` | `9002` | WLS_REPORTS Managed-Server-Port |
| `WLS_NODEMANAGER_PORT` | `5556` | NodeManager-Port |
| `WLS_MANAGED_SERVER` | `WLS_REPORTS` | Name des Reports Managed Servers (auto-detektiert) |
| `SETDOMAINENV` | `$DOMAIN_HOME/bin/setDomainEnv.sh` | Domain-Environment-Skript (abgeleitet) |

### Block 4 – Reports-Komponenten
*(Runtime-Parameter – von env_check.sh nach der Installation detektiert)*

| Variable | Beschreibung |
|---|---|
| `REPORTS_COMPONENT_HOME` | Primäre ReportsTools-Instanz (`reptools1`) |
| `REPORTS_ADMIN` | `$REPORTS_COMPONENT_HOME/guicommon/tk/admin` |
| `UIFONT_ALI` | Pfad zur `uifont.ali` (= `TK_FONTALIAS` = `ORACLE_FONTALIAS`) |
| `TK_FONTALIAS` | Überschreibt Oracle-Default-uifont.ali (= `UIFONT_ALI`) |
| `ORACLE_FONTALIAS` | Wie `TK_FONTALIAS` (= `UIFONT_ALI`) |
| `REPORTS_FONT_DIR` | `$DOMAIN_HOME/reports/fonts` – TTF-Ablage |
| `REPORTS_INSTANCES` | Bash-Array aller `reptools*`-Instanzen |
| `REPORTS_SERVER_NAME` | `repserver01` – Name des Reports Servers |

### Block 5 – Konfigurations-Dateien
*(Runtime-Parameter – von env_check.sh detektiert)*

| Variable | Beschreibung |
|---|---|
| `RWSERVER_CONF` | `rwserver.conf` Pfad (unter `servers/WLS_REPORTS/applications/`) |
| `CGICMD_DAT` | `cgicmd.dat` Pfad (im selben Verzeichnis wie `rwserver.conf`) |

### Block 6 – Datenbank (RCU)
*(Install-Parameter – vom Interview gesetzt; wird auch aus `jps-config.xml` detektiert)*

| Variable | Default | Beschreibung |
|---|---|---|
| `DB_HOST` | – | Datenbankserver-Hostname |
| `DB_PORT` | `1521` | Oracle Listener-Port |
| `DB_SERVICE` | – | Service-Name (nicht SID) |
| `DB_SERVER` | `dedicated` | Connection-Modus: `dedicated` oder `shared` |
| `DB_SCHEMA_PREFIX` | `DEV` | Präfix für RCU-Schemas (z.B. `DEV_MDS`, `DEV_STB`) |
| `SQLPLUS_BIN` | leer | Optional: Pfad zu sqlplus für Login-Test |
| `SEC_CONF_DB` | `db_connect.conf.des3` | Verschlüsselte DB-Credentials |
| `LOCAL_REP_DB` | `false` | `true` wenn Oracle DB auf demselben Host läuft |

> **`LOCAL_REP_DB`:** Steuert das Verhalten von `01-root_os_baseline.sh` bei
> Konflikten mit `oracle-database-preinstall-*`-Sysctl-Werten.
> `false` → konfliktierenden Sysctl-Dateien werden als FAIL markiert und bereinigt.
> `true`  → nur WARN, keine Änderung (DB braucht die großen Shm-Werte).

### Block 7 – My Oracle Support
*(Install-Parameter – nur im Interview, werden nicht in environment.conf persistent)*

| Variable | Beschreibung |
|---|---|
| `MOS_USER` | MOS-E-Mail-Adresse |
| `MOS_PWD` | Verschlüsselt → `mos_sec.conf.des3` (nie in env.conf) |
| `INSTALL_PATCHES` | Komma-separierte Patch-Nummern in Installationsreihenfolge |
| `INSTALL_COMPONENTS` | `FORMS_AND_REPORTS` / `FORMS_ONLY` / `REPORTS_ONLY` |

### Block 8 – Sicherheit & Betrieb
*(Mix: Teils aus Interview, teils Defaults)*

| Variable | Default | Beschreibung |
|---|---|---|
| `ORACLE_OS_USER` | `oracle` | OS-User unter dem WLS läuft |
| `SEC_CONF` | `weblogic_sec.conf.des3` | Verschlüsselte WLS-Admin-Credentials |
| `WLS_LOG_DIR` | `$DOMAIN_HOME/servers/$WLS_MANAGED_SERVER/logs` | WLS-Log-Verzeichnis |
| `DIAG_LOG_DIR` | `$ROOT_DIR/log/$(date +%Y%m%d)` | IHateWeblogic Script-Logs |
| `DISPLAY_VAR` | `:99` | X11-Display für rwrun / Oracle Installer |

---

## Beziehung JDK_HOME ↔ JAVA_HOME

```
JDK_HOME  = /u01/app/oracle/java/jdk-21        (Symlink → jdk-21.0.10)
            Gesetzt von: 02b-root_os_java.sh
            Genutzt von: 04-oracle_pre_checks.sh, oracle .bash_profile
            Oracle Support erwartet Oracle JDK hier

JAVA_HOME = /u01/oracle/fmw/oracle_common/jdk   (FMW-gebündeltes JDK)
            Gesetzt von: env_check.sh (nach FMW-Installation detektiert)
            Genutzt von: alle Diagnose-Skripte die java aufrufen
            Erst nach FMW-Installation vorhanden
```

**Phase 0/1 (vor FMW):** Nur `JDK_HOME` bekannt → `04-oracle_pre_checks.sh` nutzt `JDK_HOME`
**Phase 2+ (nach FMW):** `JAVA_HOME` zeigt auf FMW-JDK → alle anderen Skripte nutzen `JAVA_HOME`

---

## Erkennungs-Reihenfolge in `env_check.sh`

```
FMW_HOME:
  1. Standard-Pfade: /u01/oracle/fmw, /u01/app/oracle/fmw, ...
     (Nachweis: wlserver/server/lib/weblogic.jar vorhanden)
  2. Laufender Prozess: ps -eo args | -Dwls.home=<pfad>/wlserver
  3. Umgebungsvariablen: MW_HOME, ORACLE_HOME
  → Fallback: /u01/oracle/fmw (für Neu-Install)

DOMAIN_HOME:
  1. Laufender AdminServer: -Dweblogic.RootDirectory=<pfad>
  2. Standard-Basis-Verzeichnisse → erstes Unterverzeichnis mit config/config.xml
  → Fallback: /u01/user_projects/domains/fr_domain

JAVA_HOME:
  1. FMW-gebündeltes JDK: $FMW_HOME/oracle_common/jdk
  2. Laufender WLS-Prozess: -Djava.home=<pfad>
  3. System-JAVA_HOME
  → Fallback: $FMW_HOME/oracle_common/jdk

DB-Verbindung:
  1. jps-config.xml: erster DB_ORACLE-propertySet → JDBC-URL parsen
  → Fallback: leer (manuelle Eingabe erforderlich)
```

---

## Dateien im Überblick

| Datei | Inhalt | In Git? |
|---|---|---|
| `environment.conf` | Alle Laufzeit- und Install-Parameter | **Nein** (`.gitignore`) |
| `weblogic_sec.conf.des3` | Verschlüsseltes WLS-Admin-Passwort | **Nein** |
| `mos_sec.conf.des3` | Verschlüsseltes MOS-Passwort | **Nein** |
| `db_connect.conf.des3` | Verschlüsselte DB-Credentials | **Nein** |
| `environment.conf.bak.*` | Backups vor Überschreiben | **Nein** |

---

## Verwandte Skripte

| Skript | Zweck |
|---|---|
| `09-Install/01-setup-interview.sh` | Neu-Install: Interview → environment.conf + Passwörter |
| `00-Setup/env_check.sh` | Bestehend: Auto-Detect → environment.conf (ergänzend) |
| `00-Setup/weblogic_sec.sh` | Passwort-Konzept: Verschlüsselung/Entschlüsselung |
| `00-Setup/set_env.sh` | Multi-Domain: Symlink auf aktive conf umschalten |
| `04-oracle_pre_checks.sh` | Phase 1: Liest Install-Parameter aus environment.conf |
