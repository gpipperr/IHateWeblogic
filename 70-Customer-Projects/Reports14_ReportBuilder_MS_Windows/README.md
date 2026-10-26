# Report Builder Environment on MS Windows – Oracle Reports Builder 14.1.2

Minimale Entwicklungsumgebung für den **Oracle Reports Builder 14.1.2** auf
einem zentralen **Windows Server**, auf dem die Entwickler per **RDP**
arbeiten. Gleicher Kunde wie die Linux-Reports-Installation in
[`../Reports14_Only_manuall_install/`](../Reports14_Only_manuall_install/README.md):
Die Berichte werden unter Windows entworfen und auf dem Linux-Reports-Server
ausgeführt und getestet.

→ Schritt-für-Schritt-Anleitung:
[ReportBuilder_Windows_Kochbuch_de.txt](ReportBuilder_Windows_Kochbuch_de.txt)

## Die Frage: geht der Reports Builder ohne den kompletten FMW-Stack?

Für Forms gibt es die Installationsart **„Standalone Forms Builder“** – ein
Oracle Home ohne WebLogic-Domain. Für Reports gibt es so etwas **nicht**.
Ergebnis der Recherche in der Oracle-Dokumentation (Stand 2026-10-26):

| Befund | Quelle |
|---|---|
| Reports 14.1.2 ist unverändert gegenüber 12.2.1.3 und deprecated – Installation nach der **Installationsdoku 12.2.1.3**, nur mit der 14.1.2-Software | [Install Forms 14.1.2, Kap. 5 „About Oracle Reports“](https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/oracle-reports.html) |
| Installationsarten des Forms-&-Reports-Installers: **„Forms and Reports Deployment“** oder **„Standalone Forms Builder“** – kein Reports-Gegenstück | [Install 12.2.1.3 §2.4.4](https://docs.oracle.com/middleware/12213/formsandreports/install-fnr/installing-and-configuring-oracle-forms-and-reports1.htm) |
| „**One ReportsTools component is compulsory**“ – der Builder braucht eine Reports-Tools-Instanz, angelegt per WLST `createReportsToolsInstance()` gegen einen **laufenden AdminServer** | ebd. §2.4.7, §2.4.7.1, §2.4.7.3 |
| Das Domain-Template „Oracle Reports Tools“ zieht **Oracle JRF** (voll) und **Oracle Enterprise Manager** nach → **RCU-Schemas sind Pflicht**. „Oracle Forms Development“ läuft dagegen auf Restricted JRF ohne Datenbank – für Reports fehlt dieses Gegenstück | `template-info.xml` der Templates; WLST offline `selectTemplate('Oracle Reports Tools')` → JRF, EM, Coherence-Extension (geprüft 2026-10-26 auf dem 14.1.2-Testsystem) |
| Das WLS Stack Patch Bundle enthält eine eigene `windows64_patchlist.txt` und den DB-Client für Windows → Patchen wie unter Linux per `opatch napply` | SPB 40125898 (CPU Oktober 2026) |

**Eine Domain mit RCU lässt sich also nicht vermeiden.** Vermeiden lässt sich
aber der **laufende Server-Stack** – und genau der macht unter Windows den
Aufwand (Windows-Dienste, Autostart, SSL, Speicherlecks im Dauerbetrieb, siehe
[pipperr.de – Reports 14c unter Windows](https://pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64)).

## Entscheidung: Builder-Domain ohne Reports-Server

| Teil | Komplette Reports-Installation (Server) | **Builder-Umgebung (hier)** |
|---|---|---|
| Software | FMW Infrastructure + Forms & Reports | gleich – ein Oracle Home |
| RCU | eigenes Präfix | eigenes Präfix in der **bestehenden** Datenbank des Kunden |
| Domain-Templates | JRF, EM, Reports Tools, Reports Server, Reports Application, Reports Bridge, OHS | **nur JRF + EM + Reports Tools** |
| Managed Server | WLS_REPORTS (+ Cluster, Machine, Node Manager) | **keiner** – nur der AdminServer |
| Domain-Modus | Production (Secure Mode, `t3s`) | **Development** (kein Secure Mode, `t3`) |
| AdminServer | läuft dauerhaft (Windows-Dienst) | läuft **nur einmal** für `createReportsToolsInstance`, danach gestoppt |
| Windows-Dienste / Autostart / SSL | nötig | **entfallen** |
| Berichte ausführen | lokal über `rwservlet` | auf dem **Linux-Reports-Server** (`rwservlet`) |

Im Alltag startet der Entwickler nur `rwbuilder.bat` aus
`DOMAIN_HOME\reports\bin` – es läuft kein WebLogic. Damit entfallen die
aufwendigen und fehleranfälligen Teile der Windows-Serverinstallation.

```
 Entwickler (RDP) ──► Windows Server ──── Reports Builder (rwbuilder.bat)
                         │  Oracle Home + Builder-Domain (AdminServer aus)
                         ├──────────► bestehende DB: RCU-Präfix + Anwendungsdaten
                         └─ .rdf / .rep  ──► Linux-Reports-Server (rwservlet) zum Testen
```

## Mehrbenutzerbetrieb (RDP)

- **Eine** Installation, ein Oracle Home, eine Builder-Domain; installiert mit
  einem lokalen Admin-Konto (z. B. `ORASYSTEM`), Entwickler starten den
  Builder über eine Verknüpfung für alle Benutzer.
- Berichtsquellen in einem gemeinsamen Verzeichnis (oder Versionsverwaltung),
  im `REPORTS_PATH` des Builders; Fonts und `uifont.ali` **identisch** zum
  Linux-Server halten, sonst sieht die Vorschau anders aus als die
  Server-Ausgabe (siehe
  [Font_kochbuch_de.txt](../Reports14_Only_manuall_install/Font_kochbuch_de.txt)).
- Datenbankverbindungen über eine gemeinsame `tnsnames.ora`
  (`%DOMAIN_HOME%\config\fmwconfig`, `TNS_ADMIN` aus `reports.bat`).
- Java: Oracle JDK nur für Oracle-Produkte → lizenzfrei nach MOS Doc ID
  1557737.1.

## Patchstand

CPU Oktober 2026 – dieselben Patches wie der Linux-Server
([FMW_Kochbuch_de.txt](../Reports14_Only_manuall_install/FMW_Kochbuch_de.txt)
Schritt 3, [Reports_kochbuch_de.txt](../Reports14_Only_manuall_install/Reports_kochbuch_de.txt)
Schritt 2), jeweils in der Windows-Variante (MOS-Plattform „Microsoft Windows
x64 (64-bit)“, getMOSPatch `233P`). JDK 21.0.13.0.2 aus MOS-Patch 35702194
(Windows). Builder und Server sollen **denselben Patchstand** haben – ein mit
einem neueren Builder gespeicherter Bericht muss auf dem Server laufen.

## Offene Punkte für den Kunden

| # | Frage |
|---|---|
| 1 | Windows Server 2022 (zertifiziert) oder 2025 (nur getestet, nicht zertifiziert)? Englisches OS? |
| 2 | Datenbank für das RCU-Präfix (Host/Service, DBA für RCU) – dieselbe wie für den Linux-Server? Präfix-Name? |
| 3 | Wie viele gleichzeitige RDP-Entwickler? (RAM: grob 0,5–1 GB pro Builder-Sitzung, Basis 8 GB – Annahme, im Betrieb messen) |
| 4 | Ablage der Berichtsquellen (Netzlaufwerk, Git?) und Weg auf den Linux-Server (Freigabe, sftp, Deployment-Skript) |
| 5 | Virenschutz: Ausnahmen für das Oracle Home während Installation und Patchen |
| 6 | ~~Windows-Varianten der plattformabhängigen Patches auf MOS?~~ **Geklärt 2026-10-26: alle vorhanden** (Plattform „Microsoft Windows x64 (64-bit)“): Reports 39600348 (3,5 MB, 2026-08-17), PERL 39951765 (38,4 MB, 2026-10-19), OHS 39987730 (20,3 MB, 2026-10-19), WebGate 39100536 (11,1 MB, 2026-04-21). **Auffällig:** der Windows-Reports-QPR heißt „MERGE REQUEST ON TOP OF 14.1.2.0.0 FOR BUGS 38991174 37866660 39375353“ – nur 3 Bugs, die Linux-Variante listet 12. Nach dem Einspielen mit `opatch lsinventory -bugs_fixed` vergleichen; fehlende Fixes ggf. beim Support erfragen. |

Status: **dokumentiert 2026-10-26**, live auf dem Kunden-Server zu prüfen –
im Kochbuch sind die Schritte entsprechend markiert.
