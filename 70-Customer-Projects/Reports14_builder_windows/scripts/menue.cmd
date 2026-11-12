@echo off
rem ===========================================================================
rem menue.cmd - startet menue.ps1 per Doppelklick
rem ===========================================================================
rem Eine .ps1-Datei oeffnet Windows per Doppelklick nur im Editor - diese
rem Datei startet sie in PowerShell. Das Fenster bleibt nach dem Skript offen
rem (-NoExit), damit das Ergebnis stehen bleibt; schliessen mit dem X oder exit.
rem
rem Desktop-Icon: Rechtsklick auf menue.cmd -> Senden an -> Desktop
rem (Verknuepfung erstellen). Fuer checkin.ps1 braucht es ein Administrator-
rem Fenster: Verknuepfung -> Eigenschaften -> Erweitert -> "Als Administrator
rem ausfuehren" anhaken.
rem
rem   -NoProfile              : ohne persoenliches PowerShell-Profil
rem   -NoExit                 : Fenster nach dem Skript offen lassen
rem   -ExecutionPolicy Bypass : Skripte aus diesem Ordner ohne Signatur
rem                             erlauben (nur fuer dieses Fenster)
rem   %~dp0                   : Ordner dieser Datei
rem   -Fenster                : eigenes Fenster - x im Menue schliesst es
rem ===========================================================================
powershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0menue.ps1" -Fenster
