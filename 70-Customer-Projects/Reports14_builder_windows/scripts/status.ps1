# =============================================================================
# status.ps1 - Stand anzeigen: lokal und auf dem Git-Server (nur lesen)
# =============================================================================
# Aendert nichts - weder Dateien noch Check-ins. Holt nur den aktuellen Stand
# des Git-Servers (git fetch) und zeigt:
#   1. Branch und Git-Server-Branch
#   2. geaenderte Dateien, die noch nicht eingecheckt sind
#   3. lokale Check-ins, die noch nicht auf dem Git-Server sind
#   4. Check-ins auf dem Git-Server, die Sie noch nicht haben
#   5. die letzten 5 Check-ins - lokal und auf dem Git-Server
#
#   cd E:\git\<Ihr Login>
#   .\Reports\status.ps1
#
# Doku   : Git_checkin.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
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

# --- 0. In den obersten Ordner des Repositorys wechseln
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
Write-Host "Repository: $((Get-Location).Path)"

# --- 1. Branch und Git-Server-Branch
# git rev-parse --abbrev-ref HEAD: Name des aktuellen Branches (z.B. development)
$branch   = git rev-parse --abbrev-ref HEAD
# git rev-parse --abbrev-ref '@{u}': Name des Git-Server-Branches, mit dem
#   dieser Branch verbunden ist ("Upstream", z.B. origin/development).
#   '@{u}' = upstream; Fehler, wenn keiner eingetragen ist
$upstream = git rev-parse --abbrev-ref '@{u}' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Branch    : $branch"
    Write-Host "FEHLER: Dieser Branch hat keinen Git-Server-Branch (Upstream)." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "Branch    : $branch  (Git-Server: $upstream)"

Write-Host "Hole den Stand vom Git-Server (an Ihren Dateien aendert sich nichts) ..."
# git fetch: den Stand des Git-Servers abholen - nur in die Kopie des
#   Server-Stands (origin/...), Ihre Dateien und Check-ins bleiben unveraendert
#   --quiet : keine Fortschrittsanzeige
git fetch --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "WARNUNG: git fetch ist fehlgeschlagen - der Git-Server-Stand unten ist der vom letzten Abruf." -ForegroundColor Yellow
}

# --- 2. Geaenderte Dateien, noch nicht eingecheckt
Write-Host ""
Write-Host "Lokal geaendert, noch nicht eingecheckt:" -ForegroundColor Cyan
# git ls-files: Dateien auflisten
#   -c core.quotePath=false : Dateinamen mit Umlauten im Klartext
#   --modified              : geaenderte Dateien (und geloeschte)
#   --deleted               : geloeschte Dateien
#   --others                : neue Dateien, die git noch nicht kennt
#   --exclude-standard      : ohne die Dateien aus .gitignore
$changed = @(git -c core.quotePath=false ls-files --modified --deleted --others --exclude-standard | Sort-Object -Unique)
if ($changed.Count -eq 0) {
    Write-Host "  - keine -"
}
foreach ($file in $changed) {
    $state = 'geaendert'
    if (-not (Test-Path $file)) {
        $state = 'geloescht'
    }
    else {
        # git ls-files -- <datei>: gibt die Datei aus, wenn sie schon eingecheckt
        #   ist - leer = neue Datei. '--' = ab hier folgen nur Dateinamen
        $known = git -c core.quotePath=false ls-files -- $file
        if (-not $known) {
            $state = 'neu'
        }
    }
    Write-Host ("  {0,-10} {1}" -f $state, $file)
}

# --- 3. Lokale Check-ins, noch nicht auf dem Git-Server
# git rev-list --count A..B: zaehlt die Check-ins, die in B sind, aber nicht in A
#   '@{u}..HEAD' : lokal, aber noch nicht auf dem Git-Server (ahead)
#   'HEAD..@{u}' : auf dem Git-Server, aber noch nicht lokal (behind)
$ahead  = git rev-list --count '@{u}..HEAD'
$behind = git rev-list --count 'HEAD..@{u}'

Write-Host ""
Write-Host "Lokal eingecheckt, noch NICHT auf dem Git-Server: $ahead" -ForegroundColor Cyan
if ([int]$ahead -gt 0) {
    # git log ... '@{u}..HEAD': nur die Check-ins, die noch nicht auf dem Git-Server sind
    #   --no-pager / --no-decorate : direkt ausgeben, ohne Branch-Namen
    #   --format='  %h  %s'        : Kurz-Nummer (%h) und Kommentar (%s)
    git --no-pager log --no-decorate --format='  %h  %s' '@{u}..HEAD'
    Write-Host "  -> mit checkin.ps1 (oder checkin_only.ps1) hochladen - Auswahl n = nur senden"
}

# --- 4. Check-ins auf dem Git-Server, die Sie noch nicht haben
Write-Host ""
Write-Host "Auf dem Git-Server, bei Ihnen noch NICHT vorhanden: $behind" -ForegroundColor Cyan
if ([int]$behind -gt 0) {
    # git log ... 'HEAD..@{u}': nur die Check-ins vom Git-Server, die lokal fehlen
    #   --no-pager / --no-decorate : direkt ausgeben, ohne Branch-Namen
    #   --format='  %h  %s'        : Kurz-Nummer (%h) und Kommentar (%s)
    git --no-pager log --no-decorate --format='  %h  %s' 'HEAD..@{u}'
    if ([int]$ahead -gt 0) {
        # pull.ps1 kann nur fast-forward - mit eigenen, nicht gesendeten
        # Check-ins geht das nicht; checkin.ps1 fuehrt beides zusammen
        Write-Host "  -> mit checkin.ps1 (oder checkin_only.ps1) holen und zusammenfuehren - pull.ps1 geht hier nicht"
    }
    else {
        Write-Host "  -> mit pull.ps1 holen"
    }
}

# --- 5. Die letzten 5 Check-ins - lokal und auf dem Git-Server
Write-Host ""
Write-Host "Die letzten 5 Check-ins lokal ($branch):" -ForegroundColor Cyan
# git log: die letzten 5 Check-ins (ohne '@{u}' = lokal, mit '@{u}' = Git-Server)
#   --no-pager / --no-decorate : direkt ausgeben, ohne Branch-Namen
#   --format : %h Kurz-Nummer, %ad Datum, %<(14,trunc)%an Autor auf
#              14 Zeichen gekuerzt, %s Kommentar
#   --date=format:'%Y-%m-%d %H:%M' : Datum als 2026-11-12 14:30
git --no-pager log --no-decorate -5 --format='  %h  %ad  %<(14,trunc)%an  %s' --date=format:'%Y-%m-%d %H:%M'

Write-Host ""
Write-Host "Die letzten 5 Check-ins auf dem Git-Server ($upstream):" -ForegroundColor Cyan
# wie oben, '@{u}' = der Stand des Git-Servers (Upstream)
git --no-pager log --no-decorate -5 --format='  %h  %ad  %<(14,trunc)%an  %s' --date=format:'%Y-%m-%d %H:%M' '@{u}'

Write-Host ""
if ([int]$ahead -eq 0 -and [int]$behind -eq 0 -and $changed.Count -eq 0) {
    Write-Host "OK - lokal und Git-Server sind gleich, nichts offen." -ForegroundColor Green
}
else {
    Write-Host "Offen: $($changed.Count) geaenderte Datei(en), $ahead nicht gesendete(r) und $behind nicht geholte(r) Check-in(s)." -ForegroundColor Yellow
}
Exit-Script 0
