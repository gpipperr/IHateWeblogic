# Oracle Reports 14.1.2 – manuelle Installation (ohne Forms)

Kundenspezifische Anleitung für eine reine Oracle-Reports-Installation
(FMW 14.1.2, WebLogic 14.1.2, Oracle Linux 9), die der Kunde ohne die
IHateWeblogic-Skripte selbst Schritt für Schritt nachvollziehen kann. Jede
Datei ist ein eigenständiges, reines Text-Kochbuch mit Copy-paste-Befehlen
und deutschen Kommentaren.

## Reihenfolge

1. [OS_Kochbuch_de.txt](OS_Kochbuch_de.txt) – Betriebssystem vorbereiten:
   Pakete, Java, oracle-User, Netzwerk-Grundlagen auf Oracle Linux 9;
   Schritt 9: Firewall und SSH absichern (mit Sicherheitsnetz).
2. [FMW_Kochbuch_de.txt](FMW_Kochbuch_de.txt) – WebLogic/FMW-Infrastruktur
   installieren, patchen (CPU Oktober 2026: OPatch 13.9.4.2.25, WLS Stack
   Patch Bundle 40125898, acht FMW-Infrastruktur-Bundles) und
   SSL-Zertifikat auf Nginx ausrollen.
3. [SSL_Kochbuch_de.txt](SSL_Kochbuch_de.txt) – SSL-Zertifikat erzeugen und
   prüfen (nur Zertifikatserstellung/-kontrolle, das Ausrollen selbst steht
   im FMW-Kochbuch).
4. [Reports_kochbuch_de.txt](Reports_kochbuch_de.txt) – Oracle Reports
   installieren und patchen (Reports-QPR, PERL, OHS-/WebGate-Binaries),
   RCU-Schema registrieren, WebLogic-Domain anlegen und den Reports-Server
   konfigurieren (bewusst ohne Forms).
5. [Font_kochbuch_de.txt](Font_kochbuch_de.txt) – TrueType-Fonts und den
   HTML-Parameterformular-Fontpfad für Reports einrichten.
6. [WLS_Report_start_stop_kochbuch.txt](WLS_Report_start_stop_kochbuch.txt) –
   Starten, Stoppen und Statusabfrage der Umgebung im laufenden Betrieb,
   ohne jede Abhängigkeit zu den IHateWeblogic-Skripten:
   - **Schritt 0 – Handbetrieb mit den Oracle-Skripten:** Übersicht der
     Start-/Stop-Skripte, die Oracle in `$DOMAIN_HOME/bin/` mitliefert
     (`startWebLogic.sh`, `startNodeManager.sh`, `startManagedWebLogic.sh`,
     `startComponent.sh` und die `stop*`-Gegenstücke). Damit lassen sich
     AdminServer, Node Manager, Managed Server und Reports Server einzeln
     starten und in umgekehrter Reihenfolge stoppen – z.B. zur Fehlersuche
     oder wenn nur eine Komponente neu gestartet werden soll.
   - **Statusabfrage aller vier Komponenten:** AdminServer und Managed
     Server über `/weblogic/ready` (HTTP 200), Node Manager über Port 5556
     und Prozess, Reports Server über den `rwserver`-Prozess und
     `getserverinfo` (Engine-Status `1` = bereit). Wichtig: `getserverinfo`
     braucht als `authid` den Server-Administrator aus `<identifier>` in
     `rwserver.conf`, nicht einen WebLogic-Benutzer.
   - **Schritt 1–4 – alles auf einmal:** zwei eigene Skripte
     `start_wls_all.sh` / `stop_wls_all.sh`, die die Umgebung immer
     komplett in der richtigen Reihenfolge starten bzw. stoppen (das
     WebLogic-Passwort wird beim Stoppen verdeckt abgefragt und nirgends
     gespeichert).
   - **Bekannte Probleme:** u.a. Server stirbt direkt nach dem Start
     (fehlende `boot.properties`, `BEA-090782`), `REP-52262` bei der
     Statusabfrage.

   Sobald der Autostart (Punkt 7) eingerichtet ist, wird die Umgebung nur
   noch über `systemctl start/stop` bedient – die Befehle aus diesem
   Kochbuch dienen dann nur noch der Fehlersuche.
7. [Autostart_linux_middleware.txt](Autostart_linux_middleware.txt) –
   automatischer Start/Stop beim Hoch- und Herunterfahren des Servers über
   eine systemd-Unit (wartet auf "RUNNING" statt fester Pausen, Stop ohne
   Passworteingabe über boot.properties).

8. [Reports_security.txt](Reports_security.txt) – Härtung der fertigen
   Reports-/WebLogic-Umgebung (nach SSL): Ports/Firewall, Nginx (Header,
   `/em` nur für Admins, Reports-Verwaltungsbefehle wie `showenv` von außen
   gesperrt), Kennwort-Richtlinie und Kontosperre, persönliche
   Admin-Konten, Reports-Benutzer/Rollen/Policies, Reports-Server-
   Administrator `<identifier>`, `rwservlet.properties`, Dateirechte,
   Node Manager, sudo, Patchstand, Kennwortwechsel. Benutzer und Rollen
   jeweils über die Oberfläche (Enterprise Manager) **und** als
   WLST-Befehle zum Selbst-Eintippen.

9. [Tools_status_logs_kochbuch.txt](Tools_status_logs_kochbuch.txt) –
   kleine Betriebs-Skripte aus dem Ordner [`tools/`](tools/), abgelegt
   unter `/u01/oracle/tools` (ohne IHateWeblogic-Lib, Daten in `env.ini`,
   per `set_env.sh` aus der `~/.bash_profile` geladen – mit PATH auf die
   Tools und den Kurzbefehlen `wlst` und `domain`):
   - `status.sh` – Zustand in drei Stufen: Ports (`ss`), Prozesse (`ps`,
     inkl. "gestartet vom Node Manager?" und Anzahl Reports-Engines),
     Status über `/weblogic/ready` und den Node Manager (WLST mit den
     gespeicherten storeUserConfig-Zugangsdaten); Rückgabewert 0/1/2.
   - `show_all_logs.sh` – alle aktuellen Logs der Domain live (`tail -F`).
   - `show_errors.sh` – nur Fehlerzeilen (`<Error>`, `REP-`, `BEA-`,
     `JPS-`, Exceptions …), mit `-r` erst die letzten Fehler, dann live.
   - `show_log.sh` – das aktuelle Log einer Komponente (Node Manager,
     AdminServer, Managed Server, Reports-Server/Engines) per Auswahl-Menü
     oder direkt (`show_log.sh reports engine`).
   - `install.ini` + `set_install_env.sh` – alle Parameter der
     Installations-Kochbücher an einer Stelle, für die nächste
     Installation in die Sitzung zu laden.

## Download-Checkliste (Vorbereitung)

Alles vor dem Installationstermin herunterladen und in das Patch-Verzeichnis
legen (`/u01/oracle/patch_storage`, Aufbau wie in
[OS_Kochbuch_de.txt](OS_Kochbuch_de.txt) Schritt 7: `wls/`, `fr/`,
`patches/<nummer>/`). Stand **CPU Oktober 2026** – vor dem Download in MOS
KA1182 prüfen, ob sich Nummern geändert haben. Bei MOS-Patches die
Plattform beachten: **Generic** = ein ZIP für alle Plattformen, sonst
**Linux x86-64** (getMOSPatch: Plattform `226P`). Dateinamen und Größen:
Download auf dem Testsystem vom 26.10.2026.

**a) Oracle Software Delivery Cloud** (edelivery.oracle.com)

| ✓ | Datei | Inhalt | Größe | Ziel | Kochbuch |
|---|---|---|---|---|---|
| [ ] | `V1045135-01.zip` | FMW Infrastructure 14.1.2.0.0 – SHA-256 `1AAE35167BDED101E7194AA3D75C26B292010035A36C289A3F90B663D84E68BD` | 2,1 GB | `wls/` | FMW Schritt 1 |
| [ ] | `V1045121-01.zip` | Forms and Reports 14.1.2.0.0 for Linux x86-64 – SHA-256 `01D7A1042F0896FA5BDDD1EA268C1B60452476032819AAA307A789B15373175B` | 1,3 GB | `fr/` | Reports Schritt 1 |

**b) My Oracle Support – Java**

| ✓ | Patch | Datei | Inhalt | Größe | Kochbuch |
|---|---|---|---|---|---|
| [ ] | 35702194 | `p35702194_2100_Linux-x86-64.zip` | Oracle JDK 21 – im ZIP prüfen: `jdk-21.0.13.0.2_linux-x64_bin.tar.gz` (oder neuer) | 539 MB | OS Schritt 4 |

**c) My Oracle Support – WebLogic / FMW Infrastructure** (alle *Generic*)

| ✓ | Patch | Datei | Inhalt | Größe | Kochbuch |
|---|---|---|---|---|---|
| [ ] | 40125898 | `p40125898_141200_Generic.zip` | WLS Stack Patch Bundle 14.1.2.0.261007 – enthält OPatch 13.9.4.2.25 (kein eigener Download von 28186730 nötig) | 2,8 GB | FMW Schritt 3.2/3.3 |
| [ ] | 40050062 | `p40050062_141200_Generic.zip` | ADF Bundle | 22 MB | FMW Schritt 3.4 |
| [ ] | 40035984 | `p40035984_141200_Generic.zip` | WebCenter Core Bundle | 80 MB | FMW Schritt 3.4 |
| [ ] | 40024749 | `p40024749_141200_Generic.zip` | OWSM Bundle | 5,4 MB | FMW Schritt 3.4 |
| [ ] | 39995927 | `p39995927_141200_Generic.zip` | FMW Control (EM) Bundle | 13 MB | FMW Schritt 3.4 |
| [ ] | 40057999 | `p40057999_141200_Generic.zip` | OAMCLIENT Bundle | 2,4 MB | FMW Schritt 3.4 |
| [ ] | 39940047 | `p39940047_141200_Generic.zip` | UMS Bundle | 4,5 MB | FMW Schritt 3.4 |
| [ ] | 39979746 | `p39979746_141200_Generic.zip` | OPSS Bundle | 1,5 MB | FMW Schritt 3.4 |
| [ ] | 39726399 | `p39726399_141200_Generic.zip` | LibOVD Bundle | 0,5 MB | FMW Schritt 3.4 |

**d) My Oracle Support – Reports-Home** (Plattform *Linux x86-64*)

| ✓ | Patch | Datei | Inhalt | Größe | Kochbuch |
|---|---|---|---|---|---|
| [ ] | 39600348 | `p39600348_141200_Linux-x86-64.zip` | Reports-QPR 14.1.2 | 0,5 MB | Reports Schritt 2 |
| [ ] | 39951765 | `p39951765_141200_Linux-x86-64.zip` | PERL SPU (ersetzt 38590500) | 29 MB | Reports Schritt 2 |
| [ ] | 39987730 | `p39987730_141200_Linux-x86-64.zip` | OHS Bundle (nur Binaries) | 17 MB | Reports Schritt 2 |
| [ ] | 39100536 | `p39100536_141200_Linux-x86-64.zip` | WebGate Bundle (nur Binaries) | 21 MB | Reports Schritt 2 |

Nicht nötig: Forms-QPR 39842516 (reine Reports-Installation). Optional:
One-off 38936596 nur bei hebräischer Klammer-Darstellung
(`REPORTS_BIDIPARENTHESIS=YES`).

**e) Aus den Oracle-Linux-Repositories** (kein Download vorab, `dnf` am
Termin): Betriebssystem-Pakete, Nginx und `ca-certificates`
([OS_Kochbuch_de.txt](OS_Kochbuch_de.txt) Schritte 2–3 und 8).
Optional für den MOS-Download per Kommandozeile:
[getMOSPatch.jar](https://github.com/MarisElsins/getMOSPatch) (OS-Kochbuch
Schritt 7).

**Summe:** ca. 7 GB. Liegen für eine Patch-Nummer mehrere Varianten vor,
nur die für 14.1.2 und Linux x86-64 bzw. Generic verwenden. Die gleiche
Liste für die Windows-Builder-Umgebung (andere Plattform-ZIPs):
[ReportBuilder_Windows_Kochbuch_de.txt](../Reports14_ReportBuilder_MS_Windows/ReportBuilder_Windows_Kochbuch_de.txt).

## Entwicklungsumgebung (Reports Builder)

Der Reports Builder für diesen Server läuft auf einem eigenen Windows Server
(Entwickler per RDP) – Analyse und Kochbuch:
[../Reports14_ReportBuilder_MS_Windows/](../Reports14_ReportBuilder_MS_Windows/README.md).

## Patchstand

Alle Kochbücher stehen auf **CPU Oktober 2026** (+ Security Alert
CVE-2026-91403), auf dem Testsystem am 24.10.2026 eingespielt und
getestet; Nachträge vom 26.10.2026: Nginx entfernt vom Client
mitgeschickte WebLogic-Header, `weblogic-plugin-enabled` auch am
AdminServer, eMudhra-Vorfall (`ca-certificates`, Java-Truststore). Den
jeweils aktuellen Stand und die Historie führt
`IHateWeblogic/09-Install/docs/00-patch-references.md`; Oracle liefert
inzwischen monatlich – vor jeder Installation in MOS KA1182 prüfen.

## Hinweis

Die externe Datenbank wird in keinem dieser Kochbücher angelegt – sie
läuft nicht auf dieser Maschine und wird von einem anderen Team betrieben;
es werden nur Schemas in einer bereits bestehenden Datenbank registriert.
