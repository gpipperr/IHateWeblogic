@echo off
rem ===========================================================================
rem menu.cmd - startet menu.ps1 per Doppelklick
rem ===========================================================================
rem Eine .ps1-Datei oeffnet Windows per Doppelklick nur im Editor - diese
rem Datei startet sie in PowerShell. Das Fenster bleibt nach dem Skript offen
rem (-NoExit), damit das Ergebnis stehen bleibt; schliessen mit dem X oder exit.
rem
rem Ablage: oberster Ordner des Repositorys (neben deploy, source, xml).
rem Desktop-Icon: Rechtsklick auf menu.cmd -> Senden an -> Desktop
rem (Verknuepfung erstellen). Fuer checkin.ps1 braucht es ein Administrator-
rem Fenster: Verknuepfung -> Eigenschaften -> Erweitert -> "Als Administrator
rem ausfuehren" anhaken.
rem
rem   -NoLogo                 : ohne Kopfzeilen "Windows PowerShell / Copyright"
rem   -NoProfile              : ohne persoenliches PowerShell-Profil
rem   -NoExit                 : Fenster nach dem Skript offen lassen
rem   -ExecutionPolicy Bypass : Skripte aus diesem Ordner ohne Signatur
rem                             erlauben (nur fuer dieses Fenster)
rem   %~dp0                   : Ordner dieser Datei
rem   -Fenster                : eigenes Fenster - x im Menue schliesst es
rem   -Zeilen / -Spalten      : Fenstergroesse (siehe unten)
rem ===========================================================================

rem --- Fenstergroesse - hier anpassen ----------------------------------------
rem ZEILEN  : Hoehe des Fensters in Zeilen (60 = etwa 800-1000 px, je nach
rem           Schrift); groesser als der Bildschirm geht nicht - dann so hoch
rem           wie moeglich
rem SPALTEN : Breite in Zeichen (0 = Breite nicht aendern)
rem menu.ps1 setzt die Groesse und einen Scroll-Puffer von 3000 Zeilen (mit
rem "mode con" ginge das Zurueckscrollen verloren). Windows Terminal (Standard
rem unter Windows 11) ignoriert die Groesse - dort gilt die Einstellung des
rem Terminals.
set ZEILEN=60
set SPALTEN=0

powershell.exe -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0menu.ps1" -Fenster -Zeilen %ZEILEN% -Spalten %SPALTEN%
