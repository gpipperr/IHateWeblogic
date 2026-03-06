# 09-Install – Oracle Forms & Reports 14.1.2 Installation

Vollständiger Installationsfahrplan für Oracle Forms & Reports 14.1.2 (FMW 14.1.2.0.0)
auf Oracle Linux 9 – von der OS-Konfiguration bis zur validierten Produktivumgebung.

> **Modul-Nummer:** `09-Install` (`08-` ist bereits durch `08-SSL` belegt)

---

## 1. Architektur & Sicherheitskonzept

### SSL-Proxy-Architektur

```
Internet / Intranet
        │
        │ HTTPS (443)
        ▼
   ┌─────────────┐
   │    Nginx    │  ← SSL-Terminierung, kein Oracle HTTP Server (OHS)
   │ (Port 443)  │
   └──────┬──────┘
          │ HTTP (nur localhost / 127.0.0.1)
          ├──► AdminServer    :7001
          ├──► WLS_FORMS      :9001
          └──► WLS_REPORTS    :9002

WebLogic lauscht ausschließlich auf 127.0.0.1 – kein direkter Zugriff von außen.
SSL endet vollständig bei Nginx; WLS-intern kein SSL erforderlich.
```

### WebLogic-Benutzer

| Benutzer | Rolle | Beschreibung |
|---|---|---|
| `webadmin` | WLS Administrator | Vollzugriff auf WLS Console und WLST |
| `nodemanager` | Node Manager Auth | Authentifizierung des Node Managers |
| `MonUser` | Monitor | Read-only für Monitoring/Alerting |
| `RepRunner` | Reports-Ausführung | Startet Reports Jobs über rwservlet |

Alle Passwörter werden verschlüsselt gespeichert (`openssl des3 -pbkdf2` + Disk-UUID als Key,
analog `00-Setup/weblogic_sec.sh`).

### Oracle-User

Die gesamte Lib läuft unter dem OS-User `oracle`.
Für root-Operationen (OS-Parameter, Pakete, Nginx) erhält `oracle` selektive `sudo`-Rechte.
Skripte der Gruppe `root_*` prüfen die sudo-Berechtigung und zeigen bei fehlendem sudo
die notwendigen Befehle zur manuellen Ausführung.

---

## 2. Installations-Flow

```
Phase 0 – Vorbereitung (als root oder mit sudo)
  00-root_user_oracle.sh        OS-User oracle: Gruppen, sudo-Rechte, Shell-Limits
  01-root_set_os_parameter.sh   Kernel-Parameter, Pakete, Java installieren
  02-root_nginx.sh              Nginx installieren, Default-Config aus Parametern erzeugen
  03-root_nginx_ssl.sh          SSL-Zertifikat einbinden, Nginx SSL-Config, Reload

Phase 1 – Pre-Install-Checks (als oracle)
  04-oracle_pre_checks.sh       Alle Voraussetzungen prüfen vor dem Download
  04-oracle_pre_download.sh     Software und Patches von MOS laden (getMOSPatch.jar)

Phase 2 – WebLogic Installation (als oracle)
  05-oracle_install_weblogic.sh FMW Infrastructure 14.1.2 Silent-Install
  05-oracle_patch_weblogic.sh   OPatch aktualisieren + WLS-Patches anwenden

Phase 3 – Forms & Reports Installation (als oracle)
  06-oracle_install_forms_reports.sh  Forms/Reports 14.1.2 Silent-Install
  06-oracle_patch_forms_reports.sh    Forms/Reports-Patches anwenden

Phase 4 – Repository & Domain (als oracle)
  07-oracle_setup_repository.sh  RCU: Metadaten-Schemas anlegen (MDS, OPSS, STB, IAU …)
  08-oracle_setup_domain.sh      Domain anlegen (config.sh silent mode)

Phase 5 – Konfiguration & Validierung (als oracle)
  09-oracle_configure.sh         Bestehende Skripte aus 00–07 aufrufen für finale Konfig
  10-oracle_validate.sh          Vollständiger Prüfbericht mit bestehenden Check-Skripten
```

---

## 3. Script Reference

### `00-root_user_oracle.sh`

Läuft als `root` oder mit `sudo`.

| Schritt | Was |
|---|---|
| oracle-User prüfen/anlegen | `useradd -m -g oinstall -G dba,oper oracle` |
| Gruppen anlegen | `oinstall`, `dba`, `oper` |
| sudo-Rechte einrichten | `/etc/sudoers.d/oracle-fmw` – selektive Rechte für dnf/sysctl/nginx |
| Shell-Limits setzen | `/etc/security/limits.conf` – nofile, nproc, stack |
| Bash-Profile | `.bash_profile` / `.bashrc` – ORACLE_BASE, JAVA_HOME, PATH |

`--apply`: Ändert OS-Dateien. Ohne `--apply`: zeigt alle notwendigen Befehle.

---

### `01-root_set_os_parameter.sh`

Läuft als `root` oder mit `sudo`.

**Benötigte Pakete (Oracle Linux 9):**

```bash
dnf install -y \
  binutils compat-openssl11 cups-libs \
  glibc glibc-devel ksh \
  libaio libaio-devel libX11 libXau libXi libXrender libXtst \
  libgcc libstdc++ libstdc++-devel libnsl \
  make net-tools nfs-utils smartmontools sysstat \
  unzip wget curl tar \
  fontconfig freetype dejavu-sans-fonts dejavu-serif-fonts \
  xorg-x11-utils
```

**Kernel-Parameter (`/etc/sysctl.d/99-oracle-fmw.conf`):**

```
kernel.sem            = 250 32000 100 128
kernel.shmall         = 1073741824
kernel.shmmax         = 4398046511104
kernel.shmmni         = 4096
net.core.rmem_default = 262144
net.core.rmem_max     = 4194304
net.core.wmem_default = 262144
net.core.wmem_max     = 1048576
net.ipv4.ip_local_port_range = 9000 65500
vm.swappiness         = 10
```

**JDK 21 Installation:**
- Download via MOS oder Oracle Java Download (JDK 21.0.x)
- Entpacken nach `$JDK_HOME` (z. B. `/app/oracle/java/jdk-21.0.6`)
- Kein System-JDK überschreiben (FMW nutzt eigenes JDK)

---

### `02-root_nginx.sh`

Installiert Nginx und erzeugt eine Basis-Konfiguration aus `environment.conf`.

```nginx
# Erzeugte Konfiguration (Vorlage):
upstream wls_forms   { server 127.0.0.1:9001; }
upstream wls_reports { server 127.0.0.1:9002; }
upstream wls_admin   { server 127.0.0.1:7001; }

server {
    listen 80;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    # SSL-Direktiven → 03-root_nginx_ssl.sh
    location /forms/    { proxy_pass http://wls_forms;   }
    location /reports/  { proxy_pass http://wls_reports; }
    # /console nur von definierten Admin-IPs
}
```

---

### `03-root_nginx_ssl.sh`

Konfiguriert SSL in Nginx. Das Zertifikat muss vom Kunden bereitgestellt werden
(kein Self-Signed in Produktion). Das Skript prüft die Zertifikatsdateien und
bindet sie in die Nginx-Konfiguration ein.

| Was | Prüfung |
|---|---|
| Zertifikat-Datei (`.crt` / `.pem`) | vorhanden, lesbar, nicht abgelaufen |
| Key-Datei (`.key`) | vorhanden, passend zum Zertifikat |
| Intermediate Chain | optional, wird geprüft wenn angegeben |
| `ssl_protocols` | nur TLS 1.2 + 1.3 |
| `ssl_ciphers` | ECDHE-Cipher, keine RC4/3DES |

`--apply`: schreibt SSL-Block in Nginx-Conf + `nginx -t` + `systemctl reload nginx`.

---

### `04-oracle_pre_checks.sh`

Prüft als `oracle`-User alle Voraussetzungen vor dem Download/Install.
**Wiederverwendung bestehender Scripts:**

| Check | Quelle |
|---|---|
| OS-Version, RAM, Disk | → `02-Checks/os_check.sh` (aufgerufen) |
| Java-Version, JAVA_HOME | → `02-Checks/java_check.sh` (aufgerufen) |
| DB-Konnektivität (RCU-DB) | → `02-Checks/db_connect_check.sh` (aufgerufen) |
| Ports frei? (7001, 9001, 9002, 5556) | → `02-Checks/port_check.sh` (aufgerufen) |
| Disk-Platz für Install | min. 10 GB in `ORACLE_HOME`, 5 GB in `ORACLE_BASE` |
| Verzeichnisse vorhanden | `ORACLE_BASE`, `ORACLE_HOME`, `JDK_HOME` |
| oracle-User Limits | nofile ≥ 65536, nproc ≥ 16384 |

---

### `04-oracle_pre_download.sh`

Lädt Software und Patches von My Oracle Support via `getMOSPatch.jar`.

**getMOSPatch.jar Integration:**

```bash
# Konfigurationsdatei .getMOSPatch.cfg (aus environment.conf erzeugt):
226P;Linux x86-64        # Platform-Code
4L;German (D)            # Language (anpassbar)

# Aufruf:
java -jar getMOSPatch.jar \
    MOSUser="${MOS_USER}" \
    MOSPass="${MOS_PASSWORD_DECRYPTED}" \
    patch=<PATCH_NR> \
    download=all
```

MOS-Passwort wird analog zu WebLogic-Passwort gespeichert:
`mos_sec.conf.des3` – Disk-UUID als Schlüssel.

**Download-Reihenfolge:**

| Was | MOS Patch / Download |
|---|---|
| FMW Infrastructure 14.1.2 (WLS) | MOS #Installer |
| Oracle Forms & Reports 14.1.2 Shiphome | MOS #Installer |
| OPatch (aktuellste Version) | MOS #6880880 |
| WebLogic Patches aus `INSTALL_PATCHES` | MOS Patch-Nr. |
| Forms/Reports Patches | MOS Patch-Nr. |

SHA256-Prüfsumme nach jedem Download (aus MOS-Readme).

---

### `05-oracle_install_weblogic.sh`

Silent-Installation von FMW Infrastructure 14.1.2 (enthält WebLogic Server).

```bash
# Response-File-Vorlage (aus environment.conf befüllt):
[ENGINE]
Response File Version=1.0.0.0.0

[GENERIC]
ORACLE_HOME=/u01/oracle/fmw
INSTALL_TYPE=WebLogic Server
MYORACLESUPPORT_USERNAME=
MYORACLESUPPORT_PASSWORD=
DECLINE_SECURITY_UPDATES=true
SECURITY_UPDATES_VIA_MYORACLESUPPORT=false
PROXY_HOST=
PROXY_PORT=
PROXY_USER=
PROXY_PWD=
COLLECTOR_SUPPORTHUB_URL=
```

```bash
java -jar fmw_14.1.2.0.0_infrastructure.jar \
    -silent \
    -responseFile "$RESPONSE_FILE" \
    -invPtrLoc "$ORACLE_BASE/oraInst.loc"
```

Prüfung nach Install: `$ORACLE_HOME/OPatch/opatch lsinventory`.

---

### `05-oracle_patch_weblogic.sh`

Wendet WLS-Patches in der korrekten Reihenfolge an.

**Voraussetzungen:**
- OPatch Version ≥ 13.9.4.0.0 für FMW 14.1.2
- Alle Server **gestoppt** (OPatch prüft das)

**Ablauf:**

```
1. OPatch aktualisieren (falls neuer als installierte Version)
   $ORACLE_HOME/OPatch/opatch version
   unzip p6880880_*.zip -d $ORACLE_HOME

2. Patch-Konfliktprüfung (Dry-Run):
   $ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail \
       -phBaseDir /patch/storage/<PATCH_NR>

3. Patches anwenden (aus INSTALL_PATCHES, in Reihenfolge):
   $ORACLE_HOME/OPatch/opatch apply /patch/storage/<PATCH_NR>

4. Inventory-Eintrag prüfen:
   $ORACLE_HOME/OPatch/opatch lsinventory | grep <PATCH_NR>
```

> **Wichtig:** Patches immer in der vom Oracle-Readme vorgegebenen Reihenfolge anwenden.
> Konfliktprüfung (`prereq`) immer vor dem eigentlichen `apply`.

---

### `06-oracle_install_forms_reports.sh`

Silent-Installation von Oracle Forms & Reports 14.1.2.

```bash
# Response-File-Vorlage:
[ENGINE]
Response File Version=1.0.0.0.0

[GENERIC]
ORACLE_HOME=/u01/oracle/fmw
INSTALL_TYPE=Complete

# Komponenten-Auswahl (aus INSTALL_COMPONENTS in environment.conf):
# FORMS_ONLY | REPORTS_ONLY | FORMS_AND_REPORTS
```

```bash
$FMW_HOME/oracle_common/jdk/bin/java -jar \
    fmw_14.1.2.0.0_fr_linux64.bin \
    -silent \
    -responseFile "$RESPONSE_FILE"
```

---

### `06-oracle_patch_forms_reports.sh`

Analog `05-oracle_patch_weblogic.sh` für Forms/Reports-Patches.

**Besonderheit FMW-Patches:** Einige Patches betreffen beide Homes (WLS + FR).
`opatch lsinventory -all_nodes` zeigt welches Home betroffen ist.

---

### `07-oracle_setup_repository.sh`

Legt die FMW-Metadaten-Schemas in der Oracle-Datenbank an (RCU – Repository Creation Utility).

**Benötigte Schemas:**

| Schema-Prefix | Komponente | Zweck |
|---|---|---|
| `_STB` | Service Table | Zentrales Metadaten-Repository |
| `_MDS` | Metadata Service | ADF Metadaten |
| `_OPSS` | Oracle Platform Security | Security Policies |
| `_IAU` | Audit | Audit-Trail |
| `_IAU_APPEND` | Audit Append | Audit-Daten |
| `_IAU_VIEWER` | Audit Viewer | Audit-Lesezugriff |
| `_UCSUMS` | UMS | User Messaging |

```bash
$ORACLE_HOME/oracle_common/bin/rcu \
    -silent \
    -createRepository \
    -connectString "${DB_HOST}:${DB_PORT}:${DB_SERVICE}" \
    -dbUser sys \
    -dbRole sysdba \
    -schemaPrefix "${DB_SCHEMA_PREFIX}" \
    -component STB \
    -component MDS \
    -component OPSS \
    -component IAU \
    -component IAU_APPEND \
    -component IAU_VIEWER \
    -component UCSUMS \
    -f < /tmp/rcu_passwords.txt   # eine Zeile pro Schema-Passwort
```

RCU-Passwörter werden nur temporär für den Prozess in `/tmp` geschrieben und
sofort nach dem RCU-Aufruf gelöscht (`trap cleanup EXIT`).

---

### `08-oracle_setup_domain.sh`

Legt die WebLogic-Domain an (Forms/Reports-Domain-Template, Silent-Mode).

**Domain-Templates (aus FMW 14.1.2):**

```
$ORACLE_HOME/wlserver/common/templates/wls/wls.jar
$ORACLE_HOME/oracle_common/common/templates/wls/oracle.jrf_template.jar
$ORACLE_HOME/forms/common/templates/wls/oracle.forms.templates.jar
$ORACLE_HOME/reports/common/templates/wls/oracle.reports.templates.jar
```

**WLST Silent Domain-Erzeugung:**

```python
# domain_config.py (aus environment.conf befüllt):
readTemplate('<template_path>/wls.jar')
set('Name', 'fr_domain')
cd('/Security/fr_domain/User/weblogic')
cmo.setPassword('<WLS_ADMIN_PWD>')
setOption('OverwriteDomain', 'true')
writeDomain('<DOMAIN_HOME>')
closeTemplate()
```

**Managed Server anlegen:**

| Server | Listen-Address | Port |
|---|---|---|
| `WLS_FORMS` | `127.0.0.1` | `9001` |
| `WLS_REPORTS` | `127.0.0.1` | `9002` |

> Listen-Address auf `127.0.0.1` setzen – Nginx ist der einzige externe Zugang.

---

### `09-oracle_configure.sh`

Finale Konfiguration nach Domain-Erstellung.
Ruft bestehende Skripte aus den Modulen 00–07 auf:

```bash
# Aufruf-Sequenz:
./00-Setup/env_check.sh                        # environment.conf validieren
./02-Checks/weblogic_performance.sh --apply     # java.security + JVM Heap
./04-ReportsFonts/uifont_ali_update.sh --apply  # Font-Konfiguration
./04-ReportsFonts/fontpath_config.sh --apply    # REPORTS_FONT_DIRECTORY
./07-Maintenance/backup_config.sh               # Initialen Konfig-Backup
```

Zusätzlich:
- Node Manager konfigurieren (`nodemanager.properties`)
- WLS-User anlegen (`MonUser`, `RepRunner`) via WLST
- `setUserOverrides.sh` mit Heap-Einstellungen (via `weblogic_performance.sh`)
- `cgicmd.dat` für Reports-Batch-Parameter

---

### `10-oracle_validate.sh`

Vollständiger Prüfbericht nach der Installation.
Ruft alle vorhandenen Check-Skripte auf und erzeugt eine Zusammenfassung:

```bash
./02-Checks/os_check.sh
./02-Checks/java_check.sh
./02-Checks/port_check.sh --http
./02-Checks/weblogic_performance.sh
./02-Checks/db_connect_check.sh --login
./02-Checks/ssl_check.sh
./01-Run/rwserver_status.sh
./05-ReportsPerformance/engine_perf_settings.sh
./06-FormsDiag/forms_settings.sh
```

Exit-Code 0 = Installation erfolgreich.
Log wird nach `$DIAG_LOG_DIR/install_validation_<date>.log` geschrieben.

---

## 4. Interview-Skript: `01-setup-interview.sh`

Das zentrale Konfigurations-Interview. Läuft vor allen anderen Installations-Schritten.

### Prinzip

- Liest bestehende `environment.conf` und `setup.conf` ein
- Fragt **nur fehlende oder leere** Parameter ab (idempotent – wiederholbar)
- Passwörter werden sofort verschlüsselt, nie im Klartext gespeichert
- Schreibt Antworten nach `setup.conf` (Company-Template für weitere Installationen)
- Befüllt am Ende bei Bestätigung die `environment.conf`

### Abfragereihenfolge

**Block 1 – Verzeichnisse & Homes**

| Parameter | Default | Prüfung |
|---|---|---|
| `ORACLE_BASE` | `/u01/app/oracle` | Verzeichnis vorhanden? |
| `ORACLE_HOME` (FMW) | `$ORACLE_BASE/fmw` | Vorhanden oder anlegen |
| `JDK_HOME` | `$ORACLE_BASE/java/jdk-21` | `java -version` prüfen |
| `DOMAIN_HOME` | `$ORACLE_BASE/domains/fr_domain` | – |
| `PATCH_STORAGE` | `/srv/patch_storage` | Disk-Platz prüfen |

**Block 2 – Komponenten-Auswahl**

```
Was soll installiert werden?
  [1] Forms und Reports (Standard)
  [2] Nur Forms
  [3] Nur Reports
```

**Block 3 – Domain-Konfiguration**

| Parameter | Default |
|---|---|
| `WLS_ADMIN_PORT` | `7001` |
| `WLS_ADMIN_USER` | `webadmin` |
| `WLS_ADMIN_PWD` | _(verschlüsselt)_ |
| `WLS_NODEMANAGER_PORT` | `5556` |
| `WLS_FORMS_PORT` | `9001` |
| `WLS_REPORTS_PORT` | `9002` |
| Reports Server Name | `repserver01` |
| Reports Server Instances | `1` |
| Forms Customer-Verzeichnis | `/app/forms/custom` |
| Reports Customer-Verzeichnis | `/app/reports/custom` |

**Block 4 – Datenbank (RCU)**

| Parameter | Default |
|---|---|
| `DB_HOST` | – |
| `DB_PORT` | `1521` |
| `DB_SERVICE` | – |
| `DB_SCHEMA_PREFIX` | `DEV` |
| DB SYS-Passwort | _(verschlüsselt, für RCU)_ |
| `SQLPLUS_BIN` | _(aus PATH)_ |

→ Sofortiger Verbindungstest via `02-Checks/db_connect_check.sh`

**Block 5 – My Oracle Support**

| Parameter | Default |
|---|---|
| `MOS_USER` | – |
| `MOS_PWD` | _(verschlüsselt → `mos_sec.conf.des3`)_ |
| `INSTALL_PATCHES` | _(Komma-separierte Patch-Nummern)_ |

**Block 6 – Zusammenfassung & Bestätigung**

Zeigt alle eingegebenen Werte (Passwörter: `****`) und fragt vor dem Schreiben.

---

## 5. environment.conf – Neue Parameter

```bash
# === 09-INSTALL: ORACLE INSTALLATION ===
ORACLE_BASE=/u01/app/oracle
ORACLE_HOME=/u01/app/oracle/fmw
JDK_HOME=/u01/app/oracle/java/jdk-21.0.6
PATCH_STORAGE=/srv/patch_storage

# === DOMAIN ===
WLS_ADMIN_PORT=7001
WLS_ADMIN_USER=webadmin
WLS_NODEMANAGER_PORT=5556
WLS_FORMS_PORT=9001
WLS_REPORTS_PORT=9002
DB_SCHEMA_PREFIX=DEV

# === KOMPONENTEN ===
INSTALL_COMPONENTS=FORMS_AND_REPORTS    # FORMS_ONLY | REPORTS_ONLY | FORMS_AND_REPORTS
FORMS_CUSTOMER_DIR=/app/forms/custom
REPORTS_CUSTOMER_DIR=/app/reports/custom

# === MOS DOWNLOADS ===
MOS_USER=vorname.nachname@firma.de
# MOS_PWD → verschlüsselt: mos_sec.conf.des3 (gleicher Mechanismus wie weblogic_sec.conf.des3)
INSTALL_PATCHES=33735326,34374498       # Komma-separiert, Reihenfolge beachten!
```

> Die Parameter bleiben nach der Installation erhalten — alle Module 00–07 lesen
> `environment.conf` ohne Änderung (bestehende Parameter wie `FMW_HOME`, `DOMAIN_HOME`
> bleiben kompatibel, neue Parameter werden nur ergänzt).

---

## 6. Wiederverwendung bestehender Skripte

Das Installationsmodul **dupliziert keinen Code**. Bestehende Checks werden aufgerufen:

| Bestehend | Genutzt in |
|---|---|
| `02-Checks/os_check.sh` | `04-oracle_pre_checks.sh` |
| `02-Checks/java_check.sh` | `04-oracle_pre_checks.sh` |
| `02-Checks/port_check.sh` | `04-oracle_pre_checks.sh` |
| `02-Checks/db_connect_check.sh` | `01-setup-interview.sh`, `04-oracle_pre_checks.sh` |
| `02-Checks/ssl_check.sh` | `10-oracle_validate.sh` |
| `02-Checks/weblogic_performance.sh` | `09-oracle_configure.sh` |
| `04-ReportsFonts/uifont_ali_update.sh` | `09-oracle_configure.sh` |
| `07-Maintenance/backup_config.sh` | `09-oracle_configure.sh` |
| `01-Run/rwserver_status.sh` | `10-oracle_validate.sh` |

Gemeinsame Funktionen, die in mehreren Install-Skripten gebraucht werden
(z. B. Silent-Response-File schreiben, OPatch-Version prüfen), werden in eine
`09-Install/install_lib.sh` ausgelagert (analog `00-Setup/IHateWeblogic_lib.sh`).

---

## 7. MOS Downloads (getMOSPatch.jar)

```
/srv/patch_storage/
├── bin/
│   ├── getMOSPatch.jar           ← von GitHub: MarisElsins/getMOSPatch
│   └── .getMOSPatch.cfg          ← Platform + Language (aus environment.conf)
├── ahf/                          ← Symlinks → bin/
├── wls/                          ← FMW Infrastructure Installer
├── fr/                           ← Forms & Reports Installer
├── opatch/                       ← OPatch (p6880880)
└── patches/                      ← Einzel-Patches nach Nummer
    ├── 33735326/
    └── 34374498/
```

`.getMOSPatch.cfg` Inhalt (wird aus environment.conf erzeugt):
```
226P;Linux x86-64
4L;German (D)
```

Platform-Codes: `226P` = Linux x86-64 · `233P` = Linux ARM 64 · `46P` = Windows x86-64

---

## 8. sudo-Konzept für oracle-User

```
/etc/sudoers.d/oracle-fmw:

oracle ALL=(root) NOPASSWD: /usr/bin/dnf install *
oracle ALL=(root) NOPASSWD: /usr/sbin/sysctl -p
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl start nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl stop nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl enable nginx
oracle ALL=(root) NOPASSWD: /bin/cp /etc/sysctl.d/*.conf /etc/sysctl.d/
oracle ALL=(root) NOPASSWD: /bin/cp /etc/security/limits.conf /etc/security/limits.conf
```

Skripte der `root_*`-Gruppe prüfen: `sudo -n <cmd> 2>/dev/null` — hat `oracle` sudo,
wird direkt ausgeführt. Ohne sudo: Befehl wird angezeigt zum manuellen Kopieren.

---

## 9. Oracle System-Anforderungen (FMW 14.1.2 auf OL 9)

### Hardware-Mindestanforderungen

| Ressource | Minimum | Empfohlen (Produktion) |
|---|---|---|
| RAM | 8 GB | 16–32 GB |
| CPU | 2 Kerne | 4–8 Kerne |
| Disk `ORACLE_HOME` | 10 GB | 15 GB |
| Disk `DOMAIN_HOME` | 5 GB | 10 GB |
| Disk Patch-Storage | 10 GB | 20 GB |
| Swap | = RAM | 1.5× RAM |

### Verzeichnis-Struktur

```
/u01/                             ← Mount-Point (eigene Partition empfohlen)
├── app/oracle/
│   ├── fmw/                      ← ORACLE_HOME (FMW Infrastructure + Forms/Reports)
│   ├── java/jdk-21.0.6/          ← JDK_HOME (eigenständig, NICHT unter fmw/)
│   └── oraInventory/             ← OUI Inventory
└── user_projects/
    └── domains/
        └── fr_domain/            ← DOMAIN_HOME
```

### Benötigte OS-Accounts

```bash
groupadd oinstall
groupadd dba
groupadd oper
useradd -m -g oinstall -G dba,oper oracle
```

---

## 10. Detaillierte Installations-Doku (je Schritt)

Die detaillierte Schritt-für-Schritt-Dokumentation wird als separate Dateien
neben diesem README geführt:

```
09-Install/
├── README.md                      ← dieser Fahrplan
├── install_lib.sh                 ← [TODO] gemeinsame Funktionen
├── 01-setup-interview.sh          ← [TODO] Konfigurations-Interview
├── 00-root_user_oracle.sh         ← [TODO]
├── 01-root_set_os_parameter.sh    ← [TODO]
├── 02-root_nginx.sh               ← [TODO]
├── 03-root_nginx_ssl.sh           ← [TODO]
├── 04-oracle_pre_checks.sh        ← [TODO]
├── 04-oracle_pre_download.sh      ← [TODO]
├── 05-oracle_install_weblogic.sh  ← [TODO]
├── 05-oracle_patch_weblogic.sh    ← [TODO]
├── 06-oracle_install_forms_reports.sh ← [TODO]
├── 06-oracle_patch_forms_reports.sh   ← [TODO]
├── 07-oracle_setup_repository.sh  ← [TODO]
├── 08-oracle_setup_domain.sh      ← [TODO]
├── 09-oracle_configure.sh         ← [TODO]
├── 10-oracle_validate.sh          ← [TODO]
└── response_files/                ← Response-File-Templates (befüllt aus environment.conf)
    ├── wls_install.rsp.template
    ├── fr_install.rsp.template
    └── domain_config.py.template
```

---

## 11. Referenzen

- Oracle Forms & Reports 14.1.2 – Installation Guide:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/index.html
- Oracle WebLogic Server 14.1.1 – Installation Guide:
  https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/wlsig/planning-oracle-weblogic-server-installation.html#GUID-458885D0-B7E0-437F-866F-7EA6BA1B7BCC
- Oracle WebLogic Server 14.1.1 – Documentation Home:
  https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/index.html
- Oracle Forms 14.1.2 – Praxisanleitung Windows (fachlich übertragbar):
  https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64
- Nginx + ORDS + APEX Proxy-Konzept (Nginx-Architektur-Referenz):
  https://www.pipperr.de/dokuwiki/doku.php?id=prog:oracle_apex_nginx_tomcat_ords_install_windows_server
- getMOSPatch.jar (MOS-Download-Tool):
  https://github.com/MarisElsins/getMOSPatch
