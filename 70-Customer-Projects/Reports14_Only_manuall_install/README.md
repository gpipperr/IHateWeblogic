# Oracle Reports 14.1.2 – manuelle Installation (ohne Forms)

Kundenspezifische Anleitung für eine reine Oracle-Reports-Installation
(FMW 14.1.2, WebLogic 14.1.2, Oracle Linux 9), die der Kunde ohne die
IHateWeblogic-Skripte selbst Schritt für Schritt nachvollziehen kann. Jede
Datei ist ein eigenständiges, reines Text-Kochbuch mit Copy-paste-Befehlen
und deutschen Kommentaren.

## Reihenfolge

1. [OS_Kochbuch_de.txt](OS_Kochbuch_de.txt) – Betriebssystem vorbereiten:
   Pakete, Java, oracle-User, Netzwerk-Grundlagen auf Oracle Linux 9.
2. [FMW_Kochbuch_de.txt](FMW_Kochbuch_de.txt) – WebLogic/FMW-Infrastruktur
   installieren, patchen (CSPU September 2026) und SSL-Zertifikat auf
   Nginx ausrollen.
3. [SSL_Kochbuch_de.txt](SSL_Kochbuch_de.txt) – SSL-Zertifikat erzeugen und
   prüfen (nur Zertifikatserstellung/-kontrolle, das Ausrollen selbst steht
   im FMW-Kochbuch).
4. [Reports_kochbuch_de.txt](Reports_kochbuch_de.txt) – Oracle Reports
   installieren, RCU-Schema registrieren, WebLogic-Domain anlegen und den
   Reports-Server konfigurieren (bewusst ohne Forms).
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

## Hinweis

Die externe Datenbank wird in keinem dieser Kochbücher angelegt – sie
läuft nicht auf dieser Maschine und wird von einem anderen Team betrieben;
es werden nur Schemas in einer bereits bestehenden Datenbank registriert.
