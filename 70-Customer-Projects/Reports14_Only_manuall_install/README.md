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
   einfachstes Starten/Stoppen der gesamten Umgebung für den laufenden
   Betrieb, über zwei eigene Skripte ohne jede Abhängigkeit zu den
   IHateWeblogic-Skripten.

## Hinweis

Die externe Datenbank wird in keinem dieser Kochbücher angelegt – sie
läuft nicht auf dieser Maschine und wird von einem anderen Team betrieben;
es werden nur Schemas in einer bereits bestehenden Datenbank registriert.
