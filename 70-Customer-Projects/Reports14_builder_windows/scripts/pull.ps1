# =============================================================================
# pull.ps1 - den aktuellen Stand des Reports-Repositorys holen
# =============================================================================
# Aufruf zu BEGINN der Arbeit, bevor ein Bericht im Builder geoeffnet wird:
#
#   cd E:\git\<Ihr Login>\Reports
#   .\pull.ps1
#
# Was das Skript macht:
#   1. holt den neuesten Stand vom Git-Server - nur "fast-forward":
#      kein Merge, kein Stash, nichts wird hinter Ihrem Ruecken veraendert
#   2. haben Sie noch eigene, nicht eingecheckte Aenderungen, bleiben sie
#      erhalten. Git bricht von selbst ab, wenn ein Kollege DENSELBEN Bericht
#      geaendert hat - dann wird nichts ueberschrieben.
#   3. zeigt die letzten 5 Check-ins
#
# Ablage : E:\git\<Login>\Reports\pull.ps1 (Teil des Repositorys)
# Doku   : Git_checkin.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
# Nur ASCII - Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI.
# =============================================================================

# --- 1. In den obersten Ordner des Repositorys wechseln (eine Ebene ueber dem Skript)
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot
Write-Host "Repository: $RepoRoot"

# --- 2. Eigene, nicht eingecheckte Aenderungen anzeigen (nur zur Info)
$changes = git status --porcelain
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: git status ist fehlgeschlagen - ist das ein Git-Repository?" -ForegroundColor Red
    exit 1
}
if ($changes) {
    Write-Host ""
    Write-Host "Hinweis: Sie haben noch nicht eingecheckte Aenderungen - sie bleiben erhalten:" -ForegroundColor Yellow
    $changes | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
}

# --- 3. Neuesten Stand holen - nur fast-forward
Write-Host "Hole den neuesten Stand vom Git-Server ..."
git pull --ff-only
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "FEHLER: git pull ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
    Write-Host "Steht dort 'would be overwritten': ein Kollege hat denselben Bericht geaendert." -ForegroundColor Red
    Write-Host "In Ihrem Ordner wurde NICHTS veraendert. Bitte den Git-Ansprechpartner fragen." -ForegroundColor Red
    exit 1
}

# --- 4. Die letzten 5 Check-ins anzeigen
Write-Host ""
Write-Host "Die letzten 5 Check-ins:"
git log --oneline -5
Write-Host ""
Write-Host "OK - Sie sind auf dem aktuellen Stand. Builder ueber 'Reports Builder (Git)' starten." -ForegroundColor Green
exit 0
