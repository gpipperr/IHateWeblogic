# =============================================================================
# status_detail.ps1 - Liste der letzten Check-ins mit Dateien und Tags (nur lesen)
# =============================================================================
# Aendert nichts. Zeigt die letzten 20 Check-ins des aktuellen Branches als
# Tabelle - eine Zeile pro Datei:
#
#   |Datum|Commit ID|Datei|Tag|
#
#   Datum     : Datum des Check-ins (2026-11-12 14:30)
#   Commit ID : Kurz-Nummer des Check-ins
#   Datei     : jede Datei, die der Check-in geaendert hat (- = keine,
#               z.B. beim Zusammenfuehren)
#   Tag       : Tag(s) auf diesem Check-in, sonst leer - mit Kommentar,
#               falls der Tag einen hat (git tag -a): v1.0 (Freigabe Q4)
#
#   cd E:\git\<Ihr Login>
#   .\Reports\status_detail.ps1          die letzten 20 Check-ins
#   .\Reports\status_detail.ps1 50       die letzten 50 Check-ins
#   .\Reports\status_detail.ps1 -File umsatz
#                                        nur Dateien, deren Name 'umsatz'
#                                        enthaelt (gross/klein egal) - die
#                                        letzten 20 Check-ins dieser Dateien
#                                        Umlaute: gross/klein muss stimmen
#                                        (git kennt das nur fuer a-z)
#
# Die Tabelle ist Markdown - sie kann z.B. in ein Ticket kopiert werden.
#
# Doku   : Git_checkin.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
# Nur ASCII - Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI.
# =============================================================================

param(
    # Anzahl der Check-ins (Standard 20)
    [Parameter(Position = 0)][int]$Anzahl = 20,
    # nur Dateien, deren Name diesen Text enthaelt (Teil des Namens genuegt)
    [string]$File = ''
)

# Umlaute: Git liefert Dateinamen als UTF-8. Ohne diese Zeile liest Windows
# PowerShell 5.1 sie in der Konsolen-Codepage (falsche Zeichen).
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

if ($Anzahl -lt 1) {
    Write-Host "FEHLER: Anzahl muss mindestens 1 sein." -ForegroundColor Red
    Exit-Script 1
}

# git rev-parse --abbrev-ref HEAD: Name des aktuellen Branches (z.B. development)
$branch = git rev-parse --abbrev-ref HEAD

# --- 1. Check-ins mit Dateien und Tags lesen
# -File: als Git-Pfadfilter (pathspec) - dann zaehlen nur Check-ins, die eine
# passende Datei geaendert haben, und nur diese Dateien werden gelistet
#   :(glob,icase) : Muster mit * , gross/klein egal
#   **/*<text>*   : <text> irgendwo im Dateinamen, in jedem Ordner
# Zeichen mit Sonderbedeutung im Muster (* ? [ ] \) werden mit \ entwertet
$pathspec = @()
if ($File -ne '') {
    $escaped  = $File -replace '([\\*?\[\]])', '\$1'
    $pathspec = @('--', ":(glob,icase)**/*$escaped*")
}

# git log: die letzten $Anzahl Check-ins des aktuellen Branches
#   -c core.quotePath=false : Dateinamen mit Umlauten im Klartext
#   --no-pager              : direkt ausgeben, nicht seitenweise
#   -n $Anzahl              : nur die letzten $Anzahl Check-ins
#   --name-only             : unter jedem Check-in die geaenderten Dateien
#   --decorate-refs=refs/tags/ : als Markierung (%D) nur Tags, keine Branches
#   --format                : eine Kopfzeile je Check-in, beginnt mit '@@':
#                             %h Kurz-Nummer, %ad Datum, %D Tags (nur um
#                             zu sehen, ob der Check-in einen Tag hat)
#   --date=format:'%Y-%m-%d %H:%M' : Datum als 2026-11-12 14:30
#   -- <muster>             : nur mit -File: nur passende Dateien (siehe oben)
$lines = @(git -c core.quotePath=false --no-pager log -n $Anzahl --name-only `
    --decorate-refs=refs/tags/ --format='@@%h|%ad|%D' --date=format:'%Y-%m-%d %H:%M' `
    @pathspec)
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: git log ist fehlgeschlagen (noch kein Check-in?)." -ForegroundColor Red
    Exit-Script 1
}

# Zeilen in Tabellenzeilen umsetzen: eine Zeile pro Datei
$rows    = New-Object System.Collections.Generic.List[object]
$current = $null
$files   = 0

function Add-Commit {
    # Check-in ohne Datei (z.B. Zusammenfuehren): eine Zeile mit '-'
    if ($null -ne $script:current -and $script:files -eq 0) {
        $script:rows.Add([pscustomobject]@{
            Datum = $script:current.Datum; Commit = $script:current.Commit
            Datei = '-'; Tag = $script:current.Tag })
    }
}

foreach ($line in $lines) {
    if ($line.StartsWith('@@')) {
        Add-Commit
        $parts = $line.Substring(2).Split('|', 3)
        $tag = ''
        if ($parts[2].Trim() -ne '') {
            # Tags mit Kommentar lesen - nur fuer Check-ins, die einen Tag haben
            # git tag -l --points-at <nr>: alle Tags auf diesem Check-in
            #   --format : %(refname:short) Tag-Name, %(objecttype) 'tag' bei
            #              einem Tag mit Kommentar (git tag -a), 'commit' bei
            #              einem einfachen Tag; %(contents:subject) erste
            #              Zeile des Tag-Kommentars
            $tagList = @(git -c core.quotePath=false tag -l --points-at $parts[0] `
                --format='%(refname:short)|%(objecttype)|%(contents:subject)')
            $tagText = foreach ($t in $tagList) {
                $tp = $t.Split('|', 3)
                # "v1.0 (Kommentar)" - einfacher Tag ohne Kommentar: nur "v1.0"
                if ($tp[1] -eq 'tag' -and $tp[2].Trim() -ne '') { "$($tp[0]) ($($tp[2].Trim()))" }
                else { $tp[0] }
            }
            $tag = $tagText -join ', '
        }
        $current = [pscustomobject]@{ Datum = $parts[1]; Commit = $parts[0]; Tag = $tag }
        $files = 0
    }
    elseif ($line.Trim() -ne '' -and $null -ne $current) {
        $rows.Add([pscustomobject]@{
            Datum = $current.Datum; Commit = $current.Commit
            Datei = $line; Tag = $current.Tag })
        $files++
    }
}
Add-Commit

if ($File -ne '' -and $rows.Count -eq 0) {
    Write-Host "Keine Check-ins mit einer Datei, deren Name '$File' enthaelt (Branch $branch)." -ForegroundColor Yellow
    Exit-Script 0
}

# --- 2. Tabelle ausgeben (Spalten auf gleiche Breite)
$head = [pscustomobject]@{ Datum = 'Datum'; Commit = 'Commit ID'; Datei = 'Datei'; Tag = 'Tag' }
$wD = ($rows + $head | ForEach-Object { $_.Datum.Length }  | Measure-Object -Maximum).Maximum
$wC = ($rows + $head | ForEach-Object { $_.Commit.Length } | Measure-Object -Maximum).Maximum
$wF = ($rows + $head | ForEach-Object { $_.Datei.Length }  | Measure-Object -Maximum).Maximum
$wT = ($rows + $head | ForEach-Object { $_.Tag.Length }    | Measure-Object -Maximum).Maximum

function Format-Row($d, $c, $f, $t) {
    return '|' + $d.PadRight($wD) + '|' + $c.PadRight($wC) + '|' + $f.PadRight($wF) + '|' + $t.PadRight($wT) + '|'
}

Write-Host "Repository: $((Get-Location).Path)"
if ($File -ne '') {
    Write-Host "Die letzten $Anzahl Check-ins lokal ($branch) mit '$File' im Dateinamen:" -ForegroundColor Cyan
}
else {
    Write-Host "Die letzten $Anzahl Check-ins lokal ($branch):" -ForegroundColor Cyan
}
Write-Host ""
Write-Host (Format-Row 'Datum' 'Commit ID' 'Datei' 'Tag')
Write-Host ('|' + ('-' * $wD) + '|' + ('-' * $wC) + '|' + ('-' * $wF) + '|' + ('-' * $wT) + '|')
foreach ($r in $rows) {
    Write-Host (Format-Row $r.Datum $r.Commit $r.Datei $r.Tag)
}
Write-Host ""
Write-Host "Tipp: status.ps1 zeigt, was lokal und auf dem Git-Server noch offen ist."
Exit-Script 0
