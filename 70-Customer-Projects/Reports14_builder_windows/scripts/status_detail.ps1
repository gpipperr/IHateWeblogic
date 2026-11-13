# =============================================================================
# status_detail.ps1 - Liste der letzten Check-ins mit Dateien, Tags und Prod (nur lesen)
# =============================================================================
# Aendert nichts. Zeigt die letzten 20 Check-ins des aktuellen Branches als
# Tabelle - eine Zeile pro Datei:
#
#   |Datum|Commit ID|Datei|Tag|Prod|
#
#   Datum     : Datum des Check-ins (2026-11-12 14:30)
#   Commit ID : Kurz-Nummer des Check-ins
#   Datei     : jede Datei, die der Check-in geaendert hat (- = keine,
#               z.B. beim Zusammenfuehren)
#   Tag       : Tag(s) auf diesem Check-in, ohne Tag: NO_TAG. Hat der Tag
#               einen Kommentar (git tag -a), steht er in der Zeile darunter
#               (eingerueckt, lange Kommentare umgebrochen) - so bleibt die
#               Tabelle schmal
#   Prod      : Stand dieser Version gegenueber der Produktion - je Datei:
#               PROD  = genau diese Version ist in der Produktion (der
#                       zuletzt angelegte prod-Tag dieser Datei zeigt auf
#                       diesen Check-in)
#               offen = diese Version wartet auf die Freigabe - einer von
#                       zwei Faellen:
#                       a) die Datei war noch NIE in der Produktion (kein
#                          prod-Tag enthaelt sie, z.B. ein neuer Bericht)
#                       b) die Version ist NEUER als die in der Produktion
#                          (eingecheckt nach dem Check-in, der in der
#                          Produktion ist)
#                       Hat eine Datei mehrere offene Versionen, sind alle
#                       offen - freigegeben wird in der Regel die neueste.
#                       Ein Tag auf eine offene Version macht sie zu PROD,
#                       aeltere offene Versionen derselben Datei werden alt.
#               alt   = aeltere Version - die Produktion hat eine neuere
#                       (oder nach einem Rollback eine andere) Version
#               -     = geht nicht in die Produktion (.xml, Skripte, Doku,
#                       geloeschte Dateien) - nur source/*.rdf und images/*
#                       werden verteilt
#               In der Produktion ist je Datei der Check-in des ZULETZT
#               angelegten prod-Tags (ein spaeterer Tag auf eine aeltere
#               Version = Rollback). Gleiche Logik wie in release_tag.ps1.
#               Grundlage: Ihr Stand und die Tags vom letzten pull.ps1 -
#               eine Freigabe eines Kollegen sehen Sie erst danach.
#
# Darunter eine Zeile: welche Dateien DIESER Liste noch offen fuer die
# Produktion sind (nur die gezeigten Check-ins - aeltere offene stehen
# evtl. nicht in der Liste, dann mit groesserer Anzahl aufrufen).
# Optional ein Hinweis auf das Freigabe-Skript: $ReleaseSkript in den
# Einstellungen (leer = kein Hinweis).
#
#   cd E:\git\<Ihr Login>\oracle-report
#   .\deploy\status_detail.ps1          die letzten 20 Check-ins
#   .\deploy\status_detail.ps1 50       die letzten 50 Check-ins
#   .\deploy\status_detail.ps1 -File umsatz
#                                        nur Dateien, deren Name 'umsatz'
#                                        enthaelt (gross/klein egal) - die
#                                        letzten 20 Check-ins dieser Dateien
#                                        Umlaute: gross/klein muss stimmen
#                                        (git kennt das nur fuer a-z)
#
# Tags und Stand sind die vom letzten pull.ps1 - das Skript holt selbst
# nichts vom Git-Server.
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

# --- Einstellungen - an das Repository anpassen -----------------------------
# prod-Tags (wie -TagPrefix in release_tag.ps1)
$TagPattern = 'prod-*'
# Diese Dateien bringt die Pipeline in die Produktion (wie deploy/ci_deploy.sh)
$ProdMuster = @('source/*.rdf', 'images/*')
# Name des Freigabe-Skripts fuer den Hinweis unter der Tabelle, z.B.
# 'release_tag.ps1' - leer = kein Hinweis (jeder Kunde hat seinen eigenen)
$ReleaseSkript = ''

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

# git rev-parse --abbrev-ref HEAD: Name des aktuellen Branches (main)
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
#   --date-order            : nach Datum, neueste zuerst
#   --name-status           : unter jedem Check-in die geaenderten Dateien
#                             mit Status (A neu, M geaendert, D geloescht,
#                             R umbenannt)
#   --decorate-refs=refs/tags/ : als Markierung (%D) nur Tags, keine Branches
#   --format                : eine Kopfzeile je Check-in, beginnt mit '@@':
#                             %h Kurz-Nummer, %H volle Nummer, %ad Datum,
#                             %D Tags (nur um zu sehen, ob der Check-in
#                             einen Tag hat)
#   --date=format:'%Y-%m-%d %H:%M' : Datum als 2026-11-12 14:30
#   -- <muster>             : nur mit -File: nur passende Dateien (siehe oben)
$lines = @(git -c core.quotePath=false --no-pager log -n $Anzahl --date-order --name-status `
    --decorate-refs=refs/tags/ --format='@@%h|%H|%ad|%D' --date=format:'%Y-%m-%d %H:%M' `
    @pathspec)
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: git log ist fehlgeschlagen (noch kein Check-in?)." -ForegroundColor Red
    Exit-Script 1
}

# Zeilen in Check-ins mit Dateien und Tags umsetzen
$commits = New-Object System.Collections.Generic.List[object]
$current = $null
foreach ($line in $lines) {
    if ($line.StartsWith('@@')) {
        $parts = $line.Substring(2).Split('|', 4)
        $tags = @()
        if ($parts[3].Trim() -ne '') {
            # Tags mit Kommentar lesen - nur fuer Check-ins, die einen Tag haben
            # git tag -l --points-at <nr>: alle Tags auf diesem Check-in
            #   --format : %(refname:short) Tag-Name, %(objecttype) 'tag' bei
            #              einem Tag mit Kommentar (git tag -a), 'commit' bei
            #              einem einfachen Tag; %(contents:subject) erste
            #              Zeile des Tag-Kommentars
            $tagList = @(git -c core.quotePath=false tag -l --points-at $parts[1] `
                --format='%(refname:short)|%(objecttype)|%(contents:subject)')
            foreach ($t in $tagList) {
                if (-not $t) { continue }
                $tp = $t.Split('|', 3)
                $text = ''
                # '|' im Kommentar wuerde die Markdown-Tabelle zerlegen
                if ($tp[1] -eq 'tag') { $text = $tp[2].Trim().Replace('|', '/') }
                $tags += [pscustomobject]@{ Name = $tp[0]; Kommentar = $text }
            }
        }
        $current = [pscustomobject]@{
            Hash = $parts[0]; Voll = $parts[1]; Datum = $parts[2]; Tags = $tags
            Dateien = New-Object System.Collections.ArrayList }
        $commits.Add($current)
    }
    elseif ($line.Trim() -ne '' -and $null -ne $current) {
        # "M<TAB>pfad", "R100<TAB>alt<TAB>neu": Status = erster Buchstabe,
        # Pfad = bei Umbenennung der neue
        $p = $line -split "`t"
        [void]$current.Dateien.Add([pscustomobject]@{ Status = $p[0].Substring(0, 1); Pfad = $p[-1] })
    }
}

if ($commits.Count -eq 0) {
    if ($File -ne '') {
        Write-Host "Keine Check-ins mit einer Datei, deren Name '$File' enthaelt (Branch $branch)." -ForegroundColor Yellow
    }
    else {
        Write-Host "Keine Check-ins gefunden (Branch $branch)." -ForegroundColor Yellow
    }
    Exit-Script 0
}

# --- 2. Was ist in der Produktion? (gleiche Logik wie in release_tag.ps1)
# Pro Datei der Check-in des ZULETZT angelegten prod-Tags - ein spaeterer Tag
# auf eine aeltere Version = Rollback, dann ist wieder die aeltere drin.
function Test-Prod([string]$Pfad) {
    foreach ($m in $ProdMuster) { if ($Pfad -like $m) { return $true } }
    return $false
}

# git for-each-ref refs/tags/<muster>: alle prod-Tags
#   --sort=creatordate : aeltester Tag zuerst
#   --format : Check-in, auf den der Tag zeigt - %(*objectname) bei einem
#              Tag mit Kommentar, %(objectname) bei einem einfachen Tag
$prodShas = @(git for-each-ref "refs/tags/$TagPattern" --sort=creatordate `
    '--format=%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)' | Where-Object { $_ })

$inProd = @{}
if ($prodShas.Count -gt 0) {
    # git diff-tree --stdin: die Dateien aller getaggten Check-ins in EINEM Aufruf
    #   (Nummern kommen ueber die Pipe; Ausgabe: Nummer, darunter die Dateien)
    #   -r            : auch Dateien in Unterordnern
    #   --root        : auch beim allerersten Check-in
    #   --name-only   : nur die Dateinamen
    #   --diff-filter=AMR : neu, geaendert, umbenannt - wie die Pipeline
    $dt = @($prodShas | git -c core.quotePath=false diff-tree --stdin -r --root --name-only --diff-filter=AMR)
    $dateienVon = @{}
    $sha = $null
    foreach ($l in $dt) {
        if (-not $l) { continue }
        if ($l -match '^[0-9a-f]{40}$') { $sha = $l; $dateienVon[$sha] = @(); continue }
        if ($null -ne $sha) { $dateienVon[$sha] += $l }
    }
    foreach ($s in $prodShas) {
        if (-not $dateienVon.ContainsKey($s)) { continue }
        foreach ($f in $dateienVon[$s]) { if (Test-Prod $f) { $inProd[$f] = $s } }
    }
}

# Ist der Check-in in der Produktion auch in Ihrem Stand? Wenn nicht, ist er
# neuer als alles hier (Kollege hat freigegeben, Sie haben noch nicht geholt).
$prodLokal = @{}
foreach ($s in ($inProd.Values | Sort-Object -Unique)) {
    # git merge-base --is-ancestor <nr> HEAD: ist <nr> in Ihrem Stand enthalten?
    #   Rueckgabe 0 = ja, 1 = nein
    git merge-base --is-ancestor $s HEAD 2>$null
    $prodLokal[$s] = ($LASTEXITCODE -eq 0)
}

# git log ist neu -> alt: bis zum Check-in in der Produktion = offen, danach alt
$gesehen = @{}
$neuerAufServer = $false
function Get-Prod($f, [string]$voll) {
    if ($f.Status -eq 'D' -or -not (Test-Prod $f.Pfad)) { return '-' }
    if (-not $inProd.ContainsKey($f.Pfad)) { return 'offen' }
    $p = $inProd[$f.Pfad]
    if ($p -eq $voll) { $script:gesehen[$f.Pfad] = $true; return 'PROD' }
    if (-not $prodLokal[$p]) { $script:neuerAufServer = $true; return 'alt' }
    if ($script:gesehen.ContainsKey($f.Pfad)) { return 'alt' }
    return 'offen'
}

# Lange Tag-Kommentare auf mehrere Zeilen umbrechen (an Leerzeichen)
function Split-Text([string]$t, [int]$w) {
    $out = @()
    $cur = ''
    foreach ($word in ($t -split '\s+')) {
        if (-not $word) { continue }
        if ($cur -eq '') { $cur = $word }
        elseif (($cur.Length + 1 + $word.Length) -le $w) { $cur += " $word" }
        else { $out += $cur; $cur = $word }
    }
    if ($cur -ne '') { $out += $cur }
    return $out
}

# Breite der Spalte Tag = laengster Tag-Name (mindestens 40) - Kommentare
# werden darauf umgebrochen und machen die Tabelle nicht breiter
$wrap = 40
foreach ($c in $commits) { foreach ($t in $c.Tags) { if ($t.Name.Length -gt $wrap) { $wrap = $t.Name.Length } } }

# Tabellenzeilen: links die Dateien des Check-ins, rechts die Tag-Zeilen
# (Name, darunter der Kommentar) - so viele Zeilen wie der laengere Teil
$rows  = New-Object System.Collections.Generic.List[object]
$offen = New-Object System.Collections.Generic.List[string]
foreach ($c in $commits) {
    $tagZeilen = @()
    foreach ($t in $c.Tags) {
        $tagZeilen += $t.Name
        if ($t.Kommentar -ne '') {
            foreach ($z in (Split-Text $t.Kommentar ($wrap - 2))) { $tagZeilen += "  $z" }
        }
    }
    if ($tagZeilen.Count -eq 0) { $tagZeilen = @('NO_TAG') }

    $dateien = @($c.Dateien)
    $n = [Math]::Max([Math]::Max($dateien.Count, $tagZeilen.Count), 1)
    for ($k = 0; $k -lt $n; $k++) {
        $r = [pscustomobject]@{ Datum = ''; Commit = ''; Datei = ''; Tag = ''; Prod = '' }
        if ($k -lt $dateien.Count) {
            $f = $dateien[$k]
            $r.Datum = $c.Datum; $r.Commit = $c.Hash; $r.Datei = $f.Pfad
            $r.Prod = Get-Prod $f $c.Voll
            if ($r.Prod -eq 'offen') {
                $leaf = $f.Pfad.Substring($f.Pfad.LastIndexOf('/') + 1)
                if (-not $offen.Contains($leaf)) { $offen.Add($leaf) }
            }
        }
        elseif ($k -eq 0) {
            # Check-in ohne Datei (z.B. Zusammenfuehren)
            $r.Datum = $c.Datum; $r.Commit = $c.Hash; $r.Datei = '-'; $r.Prod = '-'
        }
        if ($k -lt $tagZeilen.Count) { $r.Tag = $tagZeilen[$k] }
        $rows.Add($r)
    }
}

# --- 3. Tabelle ausgeben (Spalten auf gleiche Breite)
$head = [pscustomobject]@{ Datum = 'Datum'; Commit = 'Commit ID'; Datei = 'Datei'; Tag = 'Tag'; Prod = 'Prod' }
$wD = ($rows + $head | ForEach-Object { $_.Datum.Length }  | Measure-Object -Maximum).Maximum
$wC = ($rows + $head | ForEach-Object { $_.Commit.Length } | Measure-Object -Maximum).Maximum
$wF = ($rows + $head | ForEach-Object { $_.Datei.Length }  | Measure-Object -Maximum).Maximum
$wT = ($rows + $head | ForEach-Object { $_.Tag.Length }    | Measure-Object -Maximum).Maximum
$wP = 5

function Format-Row($r) {
    return '|' + $r.Datum.PadRight($wD) + '|' + $r.Commit.PadRight($wC) + '|' + $r.Datei.PadRight($wF) +
           '|' + $r.Tag.PadRight($wT) + '|' + $r.Prod.PadRight($wP) + '|'
}

Write-Host "Repository: $((Get-Location).Path)"
if ($File -ne '') {
    Write-Host "Die letzten $Anzahl Check-ins lokal ($branch) mit '$File' im Dateinamen:" -ForegroundColor Cyan
}
else {
    Write-Host "Die letzten $Anzahl Check-ins lokal ($branch):" -ForegroundColor Cyan
}
Write-Host ""
Write-Host (Format-Row $head)
Write-Host ('|' + ('-' * $wD) + '|' + ('-' * $wC) + '|' + ('-' * $wF) + '|' + ('-' * $wT) + '|' + ('-' * $wP) + '|')
$color = 'Gray'
foreach ($r in $rows) {
    # Farbe nach Prod; Zeilen nur mit Tag-Kommentar wie die Zeile darueber
    if ($r.Prod -eq 'PROD')      { $color = 'Green' }
    elseif ($r.Prod -eq 'offen') { $color = 'Yellow' }
    elseif ($r.Prod -ne '')      { $color = 'Gray' }
    Write-Host (Format-Row $r) -ForegroundColor $color
}
Write-Host ""
if ($offen.Count -eq 0) {
    Write-Host "Offen fuer die Produktion (in dieser Liste): nichts." -ForegroundColor Green
}
else {
    Write-Host ("Offen fuer die Produktion (in dieser Liste): {0} Datei(en) - {1}" -f $offen.Count, ($offen -join ', ')) -ForegroundColor Yellow
}
if ($neuerAufServer) {
    Write-Host "Hinweis: die Produktion hat neuere Versionen als Ihr Stand - erst pull.ps1." -ForegroundColor Yellow
}
# Legende der Spalte Prod
Write-Host "Prod: PROD = in Produktion | offen = wartet auf Freigabe (nie freigegeben oder neuer als Produktion)"
Write-Host "      alt = aeltere Version | - = geht nicht in die Produktion (.xml, Skripte, geloescht)"
if ($ReleaseSkript -ne '') {
    Write-Host "Freigeben: $ReleaseSkript"
}
Write-Host "Tipp: status.ps1 zeigt, was lokal und auf dem Git-Server noch offen ist."
Exit-Script 0
