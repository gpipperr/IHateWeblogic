# =============================================================================
# pull.ps1 - den aktuellen Stand des Reports-Repositorys holen
# =============================================================================
# Aufruf zu BEGINN der Arbeit, bevor ein Bericht im Builder geoeffnet wird:
#
#   cd E:\git\<Ihr Login>\oracle-report
#   .\deploy\pull.ps1
#
# Startordner egal: das Skript wechselt selbst in den obersten Ordner des
# Repositorys (git rev-parse --show-toplevel).
#
# Was das Skript macht:
#   1. holt den neuesten Stand vom Git-Server - nur "fast-forward":
#      kein Merge, kein Stash, nichts wird hinter Ihrem Ruecken veraendert
#   2. haben Sie noch eigene, nicht eingecheckte Aenderungen, bleiben sie
#      erhalten. Git bricht von selbst ab, wenn ein Kollege DENSELBEN Bericht
#      geaendert hat - dann wird nichts ueberschrieben.
#   3. zeigt die letzten 5 Check-ins
#
# Ablage : E:\git\<Login>\oracle-report\deploy\pull.ps1 (Teil des Repositorys)
# Doku   : Git_checkin.md (IHateWeblogic, 14-ReportsBuilder)
# Nur ASCII - Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI.
# =============================================================================

# Umlaute: Git liefert Dateinamen und Kommentare als UTF-8. Ohne diese Zeile
# liest Windows PowerShell 5.1 sie in der Konsolen-Codepage (falsche Zeichen,
# z.B. f<C3><BC>r statt fuer). Gilt fuer dieses Konsolenfenster.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Am Ende - auch bei Abbruch oder Fehler - wieder in den Ordner des Skripts
# wechseln: Exit-Script statt exit
function Exit-Script([int]$Code) {
    Set-Location $PSScriptRoot
    exit $Code
}

# --- 1. In den obersten Ordner des Repositorys wechseln - egal, in welchem
# Ordner das Skript gestartet wird (wie checkin.ps1 und checkin_only.ps1)
Set-Location $PSScriptRoot
# git rev-parse --show-toplevel: liefert den obersten Ordner des Repositorys,
#   in dem der aktuelle Ordner liegt (Fehler, wenn er in keinem liegt).
# 2>$null: die englische Fehlermeldung von git ausblenden
$RepoRoot = git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: Das Skript liegt nicht in einem Git-Repository." -ForegroundColor Red
    Exit-Script 1
}
Set-Location $RepoRoot
# Windows-Schreibweise (git liefert E:/git/...)
$RepoRoot = (Get-Location).Path
Write-Host "Repository: $RepoRoot"

# --- 2. Eigene, nicht eingecheckte Aenderungen anzeigen (nur zur Info)
# git status: zeigt geaenderte, neue und geloeschte Dateien
#   -c core.quotePath=false : Dateinamen mit Umlauten im Klartext (sonst "\303\274")
#   --porcelain             : kurzes, gleichbleibendes Format, eine Zeile pro Datei
$changes = git -c core.quotePath=false status --porcelain
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: git status ist fehlgeschlagen - ist das ein Git-Repository?" -ForegroundColor Red
    Exit-Script 1
}
if ($changes) {
    Write-Host ""
    Write-Host "Hinweis: Sie haben noch nicht eingecheckte Aenderungen - sie bleiben erhalten:" -ForegroundColor Yellow
    $changes | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
}

# --- 3. Neuesten Stand holen - nur fast-forward
Write-Host "Hole den neuesten Stand vom Git-Server ..."
# git pull: neue Check-ins vom Git-Server holen und einspielen
#   --ff-only : nur "fast-forward" - Ihr Stand wird nur nach vorne geschoben;
#               ist das nicht moeglich, bricht git ab statt zusammenzufuehren
git pull --ff-only
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "FEHLER: git pull ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
    Write-Host "Steht dort 'would be overwritten': ein Kollege hat denselben Bericht geaendert." -ForegroundColor Red
    Write-Host "In Ihrem Ordner wurde NICHTS veraendert. Bitte den Git-Ansprechpartner fragen." -ForegroundColor Red
    Exit-Script 1
}

# --- 4. Die letzten 5 Check-ins anzeigen
Write-Host ""
Write-Host "Die letzten 5 Check-ins:"
# git log: Liste der Check-ins
#   --no-pager    : alles direkt ausgeben, kein Blaettern mit 'less'
#   --oneline     : eine Zeile pro Check-in (Kurz-Nummer + Kommentar)
#   --no-decorate : ohne Branch-Namen in Klammern
#   -5            : nur die letzten 5
git --no-pager log --oneline --no-decorate -5
Write-Host ""
Write-Host "OK - Sie sind auf dem aktuellen Stand. Builder ueber 'Reports Builder (Git)' starten." -ForegroundColor Green
Exit-Script 0
