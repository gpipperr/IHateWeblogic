# =============================================================================
# release_tag.ps1 - Freigaben fuer die Produktion anzeigen und per Tag setzen
# =============================================================================
# Es gibt nur den Branch main. Jeder Bericht wird einzeln eingecheckt
# (checkin.ps1); ein prod-Tag auf einen Check-in startet in GitLab die
# Pipeline, die GENAU die Dateien dieses Check-ins in die Produktion bringt.
#
# Teil 1: noch nicht in Produktion - Check-ins auf origin/main, die neuer
#         sind als der Stand ihrer Datei in Produktion (= Check-in des zuletzt
#         angelegten prod-Tags dieser Datei) - nummeriert, mit Dateien und
#         einer Liste pro Datei
# Teil 2: die letzten 20 Check-ins nach Datum (neueste zuerst), jede Datei
#         mit dem Tag ihres Check-ins - ohne Tag: NO_TAG
#         danach die letzten 20 Freigaben nach Tag sortiert (neuester Tag
#         zuerst), pro Tag NUR die Dateien seines Check-ins
# Teil 3: fragt nach einer Nummer aus Teil 1 oder einer Commit-ID (auch ein
#         aelterer Check-in, z.B. aus Teil 2 = Rollback), setzt auf genau
#         diesen Check-in einen Tag mit Kommentar und sendet ihn, z.B.
#             prod-2026-11-12_1430_umsatz.rdf
#         -> die Pipeline in GitLab verteilt den Bericht nach Produktion
#
# Standard: nur .rdf-Dateien (-Filter '*.rdf'). Mit -Filter ein anderes
# Muster, mit -Filter '' alle Dateien.
#
#   cd E:\git\<Ihr Login>\oracle-report
#   .\deploy\release_tag.ps1                    anzeigen, dann Nummer waehlen
#                                                (Enter = nichts taggen)
#   .\deploy\release_tag.ps1 -List             nur anzeigen (Teil 1 und 2),
#                                                keine Frage, kein Tag
#   .\deploy\release_tag.ps1 -File umsatz       nur Dateien, deren Name
#                                                'umsatz' enthaelt
#   .\deploy\release_tag.ps1 -Filter ''         alle Dateien, nicht nur .rdf
#   .\deploy\release_tag.ps1 -Filter '*.png'    nur Bilder (.png)
#   .\deploy\release_tag.ps1 -Nummer 2 -Ja      Check-in Nr. 2 ohne Rueckfrage
#                                                taggen und senden
#   .\deploy\release_tag.ps1 -Commit 52819c1    genau diesen (aelteren)
#                                                Check-in taggen
#
# Weitere Parameter: -Branch (Standard origin/main), -TagPrefix (prod),
# -Anzahl (20 Check-ins / Freigaben in Teil 2), -TagDatei / -Nachricht (ohne Rueckfrage),
# -NoPush (Tag nur lokal), -NoFetch (ohne git fetch).
#
# Aendert nichts an Ihren Dateien und wechselt keinen Branch - es setzt nur
# den Tag. Startordner egal: das Skript wechselt selbst in den obersten
# Ordner des Repositorys und am Ende zurueck in den Ordner des Skripts.
#
# Ein Tag gibt NUR seinen Check-in frei - aeltere und neuere Check-ins
# bleiben, wo sie sind. Gibt es von derselben Datei einen neueren Check-in,
# warnt das Skript: die Produktion bekommt den aelteren Stand (Rollback).
#
# Doku   : Git_deploy.md (IHateWeblogic, 14-ReportsBuilder)
# Nur ASCII - Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI.
# =============================================================================

param(
    # Branch auf dem Git-Server, dessen Check-ins freigegeben werden
    [string]$Branch    = 'origin/main',
    # Anfang der Tag-Namen: prod-...
    [string]$TagPrefix = 'prod',
    # Anzahl der Check-ins in Teil 2
    [int]   $Anzahl    = 20,
    # nur Dateien, deren Name diesen Text enthaelt (Teil genuegt, gross/klein egal)
    [string]$File      = '',
    # Dateimuster fuer den ganzen Pfad (gross/klein egal); '' = alle Dateien
    [string]$Filter    = '*.rdf',
    # Nummer aus Teil 1 ohne Abfrage
    [int]   $Nummer    = 0,
    # oder: Commit-ID (z.B. aus Teil 2) ohne Abfrage - auch ein aelterer
    [string]$Commit    = '',
    # Dateiname fuer den Tag-Namen ohne Abfrage
    [string]$TagDatei  = '',
    # Tag-Kommentar ohne Abfrage
    [string]$Nachricht = '',
    # keine Sicherheitsabfrage vor dem Taggen
    [switch]$Ja,
    # Tag nur lokal setzen, nicht zum Git-Server senden
    [switch]$NoPush,
    # ohne vorheriges git fetch
    [switch]$NoFetch,
    # nur anzeigen (Teil 1 und 2) - keine Frage, kein Tag
    [switch]$List
)

# Umlaute: Git liefert Dateinamen und Kommentare als UTF-8. Ohne diese Zeile
# liest Windows PowerShell 5.1 sie in der Konsolen-Codepage (falsche Zeichen).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Einstellungen - an das Repository anpassen -----------------------------
$Remote     = 'origin'
$TagPattern = "$TagPrefix-*"
$Line       = '=' * 78

# Am Ende - auch bei Abbruch oder Fehler - wieder in den Ordner des Skripts
# wechseln: Exit-Script statt exit
function Exit-Script([int]$Code) {
    Set-Location $PSScriptRoot
    exit $Code
}

# Nach jedem git-Aufruf: bei Fehler Meldung und Abbruch
function Assert-Git([string]$What) {
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: $What ist fehlgeschlagen (siehe Meldung von git oben)." -ForegroundColor Red
        Exit-Script 1
    }
}

function Get-StatusText([string]$s) {
    switch ($s) {
        'A'     { 'neu      ' }
        'M'     { 'geaendert' }
        'D'     { 'geloescht' }
        'R'     { 'umbenannt' }
        'C'     { 'kopiert  ' }
        default { $s.PadRight(9) }
    }
}

function Write-Datei($f, [string]$prefix = '') {
    $color = 'Gray'
    if ($f.Status -eq 'A') { $color = 'Green' }
    if ($f.Status -eq 'D') { $color = 'Red' }
    Write-Host ("        {0}{1}  {2}" -f $prefix, (Get-StatusText $f.Status), $f.Pfad) -ForegroundColor $color
}

# Passt die Datei zu -Filter (ganzer Pfad, Muster mit * und ?) und -File
# (Teil des Dateinamens)? Beides ohne Unterschied gross/klein - auch Umlaute.
function Test-Datei([string]$Pfad) {
    if ($Filter -ne '' -and -not ($Pfad -like $Filter)) { return $false }
    if ($File -ne '') {
        $leaf = $Pfad.Substring($Pfad.LastIndexOf('/') + 1)
        if ($leaf.IndexOf($File, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

# Zeilen von git --name-status ("M<TAB>pfad", "R100<TAB>alt<TAB>neu") ->
# Objekte mit Status (erster Buchstabe) und Pfad (bei Umbenennung der neue),
# nur Dateien, die zu -Filter / -File passen
function ConvertFrom-NameStatus([string[]]$lines) {
    foreach ($l in $lines) {
        if (-not $l) { continue }
        $p = $l -split "`t"
        if (Test-Datei $p[-1]) {
            [pscustomobject]@{ Status = $p[0].Substring(0, 1); Pfad = $p[-1] }
        }
    }
}

# Tag-Name: nur Zeichen, die in Tag-Namen sicher sind - Umlaute umschreiben
# (Zeichen-Codes, damit diese Datei ASCII bleibt)
function Get-SafeName([string]$s) {
    $umlaut = @{ 0x00E4 = 'ae'; 0x00F6 = 'oe'; 0x00FC = 'ue'; 0x00C4 = 'Ae'; 0x00D6 = 'Oe'; 0x00DC = 'Ue'; 0x00DF = 'ss' }
    foreach ($code in $umlaut.Keys) {
        $s = $s.Replace([string][char]$code, $umlaut[$code])
    }
    $s = $s -replace '[^A-Za-z0-9._-]', '_'
    $s = $s -replace '\.{2,}', '.'
    return $s.Trim('.', '_', '-')
}

if ($List -and ($Nummer -gt 0 -or $Commit -ne '')) {
    Write-Host "FEHLER: -List zeigt nur an - nicht zusammen mit -Nummer / -Commit." -ForegroundColor Red
    Exit-Script 1
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

if (-not $NoFetch) {
    Write-Host "Hole den Stand und die Tags vom Git-Server (an Ihren Dateien aendert sich nichts) ..."
    # git fetch: den Stand des Git-Servers abholen - nur in die Kopie des
    #   Server-Stands (origin/...), Ihre Dateien und Check-ins bleiben unveraendert
    #   $Remote : der Git-Server (origin)
    #   --tags  : auch alle Tags holen - Freigaben der Kollegen
    #   --quiet : keine Fortschrittsanzeige
    git fetch $Remote --tags --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARNUNG: git fetch ist fehlgeschlagen - der Stand unten ist der vom letzten Abruf." -ForegroundColor Yellow
    }
}

# git rev-parse --verify --quiet: gibt es den Branch? (leer = nein)
#   "$Branch^{commit}" : muss auf einen Check-in zeigen
git rev-parse --verify --quiet "$Branch^{commit}" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: Branch '$Branch' gibt es nicht." -ForegroundColor Red
    Exit-Script 1
}

$filterInfo = @()
if ($Filter -ne '') { $filterInfo += "nur $Filter" }
if ($File -ne '')   { $filterInfo += "Dateiname mit '$File'" }
$filterText = ''
if ($filterInfo.Count -gt 0) { $filterText = ', ' + ($filterInfo -join ', ') }

# --- 1. Noch nicht freigegebene Check-ins
Write-Host ""
Write-Host $Line -ForegroundColor Cyan
Write-Host " NOCH NICHT IN PRODUKTION  ($Branch, Tags '$TagPattern'$filterText)" -ForegroundColor Cyan
Write-Host $Line -ForegroundColor Cyan

# Check-ins mit prod-Tag: Nummer des Check-ins -> Name(n) seiner Tags
# git for-each-ref refs/tags/<muster>: alle Tags mit diesem Muster
#   --sort=creatordate : aeltester Tag zuerst
#   --format : %(*objectname) Check-in eines Tags mit Kommentar,
#              %(objectname) Check-in eines einfachen Tags,
#              %(refname:short) Name des Tags
$tagged = @{}
$tagRefs = @(git for-each-ref "refs/tags/$TagPattern" --sort=creatordate '--format=%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)|%(refname:short)')
Assert-Git 'git for-each-ref'
foreach ($r in $tagRefs) {
    if (-not $r) { continue }
    $tp = $r.Split('|', 2)
    if ($tagged.ContainsKey($tp[0])) { $tagged[$tp[0]] += ", $($tp[1])" }
    else { $tagged[$tp[0]] = $tp[1] }
}

# git log: alle Check-ins des Branches mit ihren Dateien (neu -> alt)
#   -c core.quotePath=false : Dateinamen mit Umlauten im Klartext
#   --no-pager              : direkt ausgeben, nicht seitenweise
#   --no-merges             : ohne Zusammenfuehrungen (haben keine eigenen Dateien)
#   --date=format:'%Y-%m-%d %H:%M' : Datum als 2026-11-12 14:30
#   --date-order            : nach Datum sortiert, neueste zuerst
#   --name-status           : unter jedem Check-in die Dateien mit Status
#                             (A neu, M geaendert, D geloescht, R umbenannt)
#   --format                : Kopfzeile je Check-in, beginnt mit '@@':
#                             %H volle Nummer, %h Kurz-Nummer, %ad Datum,
#                             %an Autor, %s Kommentar
$lines = @(git -c core.quotePath=false --no-pager log --no-merges --date-order --date=format:'%Y-%m-%d %H:%M' `
    --name-status --format='@@%H|%h|%ad|%an|%s' $Branch)
Assert-Git 'git log'

# Zeilen in Check-ins mit Dateien umsetzen; Check-ins ohne passende Datei
# (wegen -Filter / -File) fallen weg
$alleCommits = New-Object System.Collections.ArrayList
$cur = $null
foreach ($l in ($lines + '@@END')) {
    if ($l.StartsWith('@@')) {
        if ($null -ne $cur -and $cur.Dateien.Count -gt 0) { [void]$alleCommits.Add($cur) }
        $cur = $null
        if ($l -eq '@@END') { break }
        $p = $l.Substring(2).Split('|', 5)
        $cur = [pscustomobject]@{
            Voll = $p[0]; Hash = $p[1]; Datum = $p[2]; Autor = $p[3]; Text = $p[4]
            Dateien = New-Object System.Collections.ArrayList
        }
    }
    elseif ($l -and $null -ne $cur) {
        foreach ($f in ConvertFrom-NameStatus @($l)) { [void]$cur.Dateien.Add($f) }
    }
}

# Was ist in Produktion? Pro Datei der Check-in des ZULETZT angelegten Tags
# (Tags in der Reihenfolge ihres Datums - ein spaeterer Tag auf eine aeltere
# Version = Rollback, dann ist wieder die aeltere in Produktion)
$bySha = @{}
foreach ($c in $alleCommits) { $bySha[$c.Voll] = $c }
$inProd = @{}
foreach ($r in $tagRefs) {
    if (-not $r) { continue }
    $sha = $r.Split('|', 2)[0]
    if ($bySha.ContainsKey($sha)) {
        foreach ($f in $bySha[$sha].Dateien) { $inProd[$f.Pfad] = $sha }
    }
}

# Offen: neu -> alt durchgehen bis zum Check-in, der von der Datei in
# Produktion ist - aeltere Check-ins dieser Datei sind damit erledigt.
$freigegeben = @{}
$offen = New-Object System.Collections.ArrayList
foreach ($c in $alleCommits) {
    foreach ($f in $c.Dateien) {
        if ($inProd[$f.Pfad] -eq $c.Voll) { $freigegeben[$f.Pfad] = $true }
    }
    # nur die noch nicht freigegebenen Dateien - als eigenes Objekt, damit
    # die Liste in Teil 2 alle Dateien des Check-ins behaelt
    $rest = @($c.Dateien | Where-Object { -not $freigegeben.ContainsKey($_.Pfad) })
    if ($rest.Count -gt 0) {
        [void]$offen.Add([pscustomobject]@{
            Voll = $c.Voll; Hash = $c.Hash; Datum = $c.Datum; Autor = $c.Autor; Text = $c.Text
            Dateien = $rest })
    }
}

if ($offen.Count -eq 0) {
    Write-Host "  Alles freigegeben - keine offenen Check-ins." -ForegroundColor Green
}
else {
    for ($i = 0; $i -lt $offen.Count; $i++) {
        $c = $offen[$i]
        Write-Host ""
        Write-Host ("  [{0,2}]  {1}  {2}  {3,-15}  {4}" -f ($i + 1), $c.Hash, $c.Datum, $c.Autor, $c.Text) -ForegroundColor Yellow
        foreach ($f in $c.Dateien) { Write-Datei $f }
    }

    # Liste pro Datei (git log ist neu -> alt: der erste Treffer ist der neueste)
    $proDatei = [ordered]@{}
    for ($i = 0; $i -lt $offen.Count; $i++) {
        $c = $offen[$i]
        foreach ($f in $c.Dateien) {
            if (-not $proDatei.Contains($f.Pfad)) {
                $proDatei[$f.Pfad] = [pscustomobject]@{ Datei = $f.Pfad; Anzahl = 0; Zuletzt = "[$($i + 1)] $($c.Datum) $($c.Hash)" }
            }
            $proDatei[$f.Pfad].Anzahl++
        }
    }
    Write-Host ""
    Write-Host ("  {0} offene Check-ins, {1} Dateien:" -f $offen.Count, $proDatei.Count) -ForegroundColor Cyan
    $w = ($proDatei.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    if ($w -lt 5) { $w = 5 }
    Write-Host ("    {0}  {1,7}  {2}" -f 'Datei'.PadRight($w), 'Anzahl', 'zuletzt')
    foreach ($d in ($proDatei.Values | Sort-Object Datei)) {
        Write-Host ("    {0}  {1,7}  {2}" -f $d.Datei.PadRight($w), $d.Anzahl, $d.Zuletzt)
    }
}

# --- 2. Die letzten Check-ins mit ihrem Tag - nach Datum, neueste zuerst
# Jede Datei steht mit dem Tag IHRES Check-ins (= damit ging sie in die
# Produktion), ohne Tag: NO_TAG
Write-Host ""
Write-Host $Line -ForegroundColor Cyan
Write-Host " LETZTE $Anzahl CHECK-INS MIT TAG  (Tags '$TagPattern'$filterText)" -ForegroundColor Cyan
Write-Host $Line -ForegroundColor Cyan

$rows = New-Object System.Collections.Generic.List[object]
$zahl = 0
foreach ($c in $alleCommits) {
    if ($zahl -ge $Anzahl) { break }
    $zahl++
    $tagText = 'NO_TAG'
    if ($tagged.ContainsKey($c.Voll)) { $tagText = $tagged[$c.Voll] }
    foreach ($f in $c.Dateien) {
        $rows.Add([pscustomobject]@{ Datum = $c.Datum; Commit = $c.Hash; Datei = $f.Pfad; Tag = $tagText })
    }
}

if ($rows.Count -eq 0) {
    Write-Host "  Keine Check-ins gefunden." -ForegroundColor Yellow
}
else {
    $head = [pscustomobject]@{ Datum = 'Datum'; Commit = 'Commit'; Datei = 'Datei'; Tag = 'Tag' }
    $wD = ($rows + $head | ForEach-Object { $_.Datum.Length }  | Measure-Object -Maximum).Maximum
    $wC = ($rows + $head | ForEach-Object { $_.Commit.Length } | Measure-Object -Maximum).Maximum
    $wF = ($rows + $head | ForEach-Object { $_.Datei.Length }  | Measure-Object -Maximum).Maximum
    Write-Host ""
    Write-Host ("  {0}  {1}  {2}  {3}" -f 'Datum'.PadRight($wD), 'Commit'.PadRight($wC), 'Datei'.PadRight($wF), 'Tag')
    foreach ($r in $rows) {
        $color = 'Green'
        if ($r.Tag -eq 'NO_TAG') { $color = 'Gray' }
        Write-Host ("  {0}  {1}  {2}  {3}" -f $r.Datum.PadRight($wD), $r.Commit.PadRight($wC), $r.Datei.PadRight($wF), $r.Tag) -ForegroundColor $color
    }
}
Write-Host ""

# --- 2b. Die letzten Freigaben - nach Tag sortiert (neuester Tag zuerst)
# Pro Tag NUR die Dateien seines Check-ins - genau die gingen mit diesem Tag
# in die Produktion (nicht die Dateien zwischen zwei Tags)
Write-Host $Line -ForegroundColor Cyan
Write-Host " LETZTE $Anzahl FREIGABEN  (Tags '$TagPattern' nach Datum des Tags$filterText)" -ForegroundColor Cyan
Write-Host $Line -ForegroundColor Cyan

# git for-each-ref refs/tags/<muster>: alle Tags mit diesem Muster
#   --sort=-creatordate : neuester Tag zuerst
#   --format : %(refname:short) Tag-Name, %(creatordate:...) Datum des Tags,
#              %(taggername) Freigeber (- bei einfachem Tag ohne Kommentar),
#              %(*objectname) / %(objectname) Check-in, auf den der Tag zeigt
$fmt = '%(refname:short)|%(creatordate:format:%Y-%m-%d %H:%M)|%(if)%(taggername)%(then)%(taggername)%(else)-%(end)|%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)'
$tagListe = @(git -c core.quotePath=false for-each-ref "refs/tags/$TagPattern" --sort=-creatordate "--format=$fmt")
Assert-Git 'git for-each-ref'

$fRows = New-Object System.Collections.Generic.List[object]
$gezeigt = 0
foreach ($r in $tagListe) {
    if (-not $r -or $gezeigt -ge $Anzahl) { continue }
    $t = $r.Split('|', 4)
    # git diff-tree: die Dateien des Check-ins, auf den der Tag zeigt
    #   -r / --root / --no-commit-id / --name-status : wie oben
    $dateien = @(ConvertFrom-NameStatus @(git -c core.quotePath=false diff-tree -r --root --no-commit-id --name-status $t[3]))
    Assert-Git 'git diff-tree'
    # Tag ohne passende Datei (wegen -Filter / -File): auslassen
    if ($dateien.Count -eq 0) { continue }
    foreach ($f in $dateien) {
        $fRows.Add([pscustomobject]@{ Datum = $t[1]; Tag = $t[0]; Commit = $t[3].Substring(0, 7); Datei = $f.Pfad; Von = $t[2] })
    }
    $gezeigt++
}

if ($fRows.Count -eq 0) {
    Write-Host "  Keine Freigaben gefunden." -ForegroundColor Yellow
}
else {
    $wD = ($fRows | ForEach-Object { $_.Datum.Length } | Measure-Object -Maximum).Maximum
    $wT = (@($fRows | ForEach-Object { $_.Tag.Length }) + 3 | Measure-Object -Maximum).Maximum
    $wF = (@($fRows | ForEach-Object { $_.Datei.Length }) + 5 | Measure-Object -Maximum).Maximum
    Write-Host ""
    Write-Host ("  {0}  {1}  {2}  {3}  {4}" -f 'Datum'.PadRight($wD), 'Tag'.PadRight($wT), 'Commit ', 'Datei'.PadRight($wF), 'Freigeber')
    foreach ($r in $fRows) {
        Write-Host ("  {0}  {1}  {2}  {3}  {4}" -f $r.Datum.PadRight($wD), $r.Tag.PadRight($wT), $r.Commit, $r.Datei.PadRight($wF), $r.Von) -ForegroundColor Green
    }
}
Write-Host ""

# -List: nur anzeigen - hier aufhoeren
if ($List) {
    Write-Host "Nur angezeigt (-List) - kein Tag gesetzt. Freigeben: release_tag.ps1 ohne -List."
    Exit-Script 0
}

# --- 3. Check-in fuer die Produktion freigeben (Tag setzen)
# Gewaehlt wird eine Nummer aus Teil 1 ODER eine Commit-ID (z.B. aus Teil 2,
# auch ein aelterer Check-in = Rollback). Der Tag zeigt immer auf genau diesen
# einen Check-in - die Pipeline bringt nur dessen Dateien in die Produktion,
# neuere Check-ins gehen NICHT mit.
Write-Host $Line -ForegroundColor Cyan
Write-Host " FREIGABE FUER DIE PRODUKTION" -ForegroundColor Cyan
Write-Host $Line -ForegroundColor Cyan

$eingabe = $Commit
if ($Nummer -gt 0) { $eingabe = "$Nummer" }
if (-not $eingabe) {
    $frage = "  Nummer aus der Liste oben (1-$($offen.Count)) oder Commit-ID (Enter = keine Freigabe)"
    if ($offen.Count -eq 0) { $frage = "  Commit-ID fuer die Freigabe (Enter = keine Freigabe)" }
    $eingabe = "$(Read-Host $frage)".Trim()
    if (-not $eingabe) {
        Write-Host "  Keine Freigabe gesetzt."
        Exit-Script 0
    }
}

$c  = $null
$nr = 0
if ([int]::TryParse($eingabe, [ref]$nr) -and $nr -ge 1 -and $nr -le $offen.Count -and -not $Commit) {
    $c = $offen[$nr - 1]
}
elseif ($eingabe -match '^[0-9a-fA-F]{4,40}$') {
    # git rev-parse --verify --quiet <id>^{commit}: volle Nummer des
    #   Check-ins (leer, wenn es ihn nicht gibt)
    $voll = git rev-parse --verify --quiet "$eingabe^{commit}"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: Check-in '$eingabe' gibt es nicht." -ForegroundColor Red
        Exit-Script 1
    }
    # git merge-base --is-ancestor <id> <branch>: liegt der Check-in auf dem
    #   Branch (Exit-Code 0 = ja)?
    git merge-base --is-ancestor $voll $Branch
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: Check-in '$eingabe' liegt nicht auf $Branch." -ForegroundColor Red
        Exit-Script 1
    }
    # git rev-list --parents -n 1 <id>: der Check-in und seine Vorgaenger -
    #   mehr als einer = Zusammenfuehrung (hat keine eigenen Dateien)
    $parents = @("$(git rev-list --parents -n 1 $voll)".Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    if ($parents.Count -gt 2) {
        Write-Host "FEHLER: '$eingabe' ist eine Zusammenfuehrung - bitte den Check-in des Berichts waehlen." -ForegroundColor Red
        Exit-Script 1
    }
    # git log -1 --format=...: Kopfdaten dieses einen Check-ins
    $kopf = (git -c core.quotePath=false --no-pager log -1 --date=format:'%Y-%m-%d %H:%M' --format='%H|%h|%ad|%an|%s' $voll).Split('|', 5)
    # git diff-tree: die Dateien dieses Check-ins - die passenden zu -Filter /
    #   -File (z.B. nur die .rdf, ohne die .xml); passt keine, alle
    #   -r / --root / --no-commit-id / --name-status : wie in Teil 2
    $ns = @(git -c core.quotePath=false diff-tree -r --root --no-commit-id --name-status $voll)
    $dateien = @(ConvertFrom-NameStatus $ns)
    if ($dateien.Count -eq 0) {
        $dateien = @(foreach ($l in $ns) {
            if (-not $l) { continue }
            $p = $l -split "`t"
            [pscustomobject]@{ Status = $p[0].Substring(0, 1); Pfad = $p[-1] }
        })
    }
    $c = [pscustomobject]@{ Voll = $kopf[0]; Hash = $kopf[1]; Datum = $kopf[2]; Autor = $kopf[3]; Text = $kopf[4]; Dateien = $dateien }
    if ($c.Dateien.Count -eq 0) {
        Write-Host "FEHLER: Check-in '$eingabe' hat keine Dateien." -ForegroundColor Red
        Exit-Script 1
    }
    if ($tagged.ContainsKey($c.Voll)) {
        Write-Host "  Hinweis  : Der Check-in hat schon den Tag $($tagged[$c.Voll])." -ForegroundColor Yellow
    }
}
else {
    Write-Host "FEHLER: Ungueltige Eingabe: '$eingabe' (Nummer 1-$($offen.Count) oder Commit-ID)" -ForegroundColor Red
    Exit-Script 1
}

Write-Host ""
Write-Host ("  Ausgewaehlt: {0}  {1}  {2}" -f $c.Hash, $c.Datum, $c.Text) -ForegroundColor Yellow

# Dateiname fuer den Tag-Namen
$name = $TagDatei
if (-not $name) {
    if ($c.Dateien.Count -eq 1) {
        $name = $c.Dateien[0].Pfad
    }
    else {
        Write-Host "  Der Check-in enthaelt mehrere Dateien:"
        for ($j = 0; $j -lt $c.Dateien.Count; $j++) {
            Write-Datei $c.Dateien[$j] ("[{0}] " -f ($j + 1))
        }
        $dn = 1
        if (-not $Ja) {
            $eingabe = Read-Host "  Welche Datei kommt in den Tag-Namen? (1-$($c.Dateien.Count), Enter = 1)"
            if ($eingabe -and -not [int]::TryParse($eingabe, [ref]$dn)) {
                Write-Host "FEHLER: Ungueltige Eingabe: '$eingabe'" -ForegroundColor Red
                Exit-Script 1
            }
        }
        if ($dn -lt 1 -or $dn -gt $c.Dateien.Count) {
            Write-Host "FEHLER: Nummer $dn ist ungueltig." -ForegroundColor Red
            Exit-Script 1
        }
        $name = $c.Dateien[$dn - 1].Pfad
    }
}
$name = Get-SafeName ($name.Substring($name.Replace('\', '/').LastIndexOf('/') + 1))
if (-not $name) { $name = 'ohne-datei' }

# Tag-Name: prod-JJJJ-MM-TT_HHMM_datei (gibt es ihn schon: -2, -3, ...)
$basis   = "{0}-{1}_{2}" -f $TagPrefix, (Get-Date -Format 'yyyy-MM-dd_HHmm'), $name
$tagName = $basis
$n = 2
# git tag -l <name>: gibt den Namen aus, wenn es den Tag schon gibt
while (git tag -l $tagName) {
    $tagName = "$basis-$n"
    $n++
}
# git check-ref-format: ist das ein gueltiger Name fuer einen Tag?
git check-ref-format "refs/tags/$tagName"
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: '$tagName' ist kein gueltiger Tag-Name (-TagPrefix pruefen)." -ForegroundColor Red
    Exit-Script 1
}

if (-not $Nachricht) {
    $vorschlag = "Freigabe Produktion: $name - $($c.Text)"
    if ($Ja) {
        $Nachricht = $vorschlag
    }
    else {
        $eingabe = Read-Host "  Tag-Kommentar (Enter = '$vorschlag')"
        if ($eingabe) { $Nachricht = $eingabe } else { $Nachricht = $vorschlag }
    }
}

Write-Host ""
Write-Host "  Tag      : $tagName" -ForegroundColor Green
Write-Host "  Check-in : $($c.Hash)  $($c.Text)"
Write-Host "  Kommentar: $Nachricht"
if ($c.Dateien.Count -gt 1) {
    Write-Host "  Hinweis  : Der Check-in hat $($c.Dateien.Count) Dateien - alle gehen in die Produktion." -ForegroundColor Yellow
}
# Gibt es von diesen Dateien neuere Check-ins? Sie gehen NICHT mit - die
# Produktion bekommt den Stand dieses Check-ins (gewollt bei einem Rollback)
# git log <id>..<branch> -- <dateien>: Check-ins nach diesem, die eine der
#   Dateien geaendert haben
#   --format='%h %ad %s' : Kurz-Nummer, Datum, Kommentar
$pfadListe = @($c.Dateien | ForEach-Object { $_.Pfad })
$neuer = @(git -c core.quotePath=false --no-pager log --date=format:'%Y-%m-%d %H:%M' --format='%h  %ad  %s' "$($c.Voll)..$Branch" -- $pfadListe)
if ($neuer.Count -gt 0 -and $neuer[0]) {
    Write-Host "  ACHTUNG  : Es gibt $($neuer.Count) neuere(n) Check-in(s) dieser Datei(en) - sie gehen NICHT mit," -ForegroundColor Yellow
    Write-Host "             die Produktion bekommt den aelteren Stand dieses Check-ins:" -ForegroundColor Yellow
    foreach ($z in ($neuer | Select-Object -First 5)) { Write-Host "             $z" -ForegroundColor Yellow }
}

if (-not $Ja) {
    $frage = '  Tag setzen und zum Git-Server senden? (j/n)'
    if ($NoPush) { $frage = '  Tag setzen (nur lokal)? (j/n)' }
    $ok = Read-Host $frage
    if ($ok -notmatch '^(j|ja|y|yes)$') {
        Write-Host "  Abgebrochen, kein Tag gesetzt."
        Exit-Script 0
    }
}

# git tag: einen Tag setzen
#   -a           : Tag mit Kommentar, Freigeber und Datum (annotated)
#   $tagName     : Name des Tags
#   -m $Nachricht: der Kommentar (sonst wuerde git einen Editor oeffnen)
#   $c.Voll      : der Check-in, auf den der Tag zeigt (volle Nummer)
git tag -a $tagName -m $Nachricht $c.Voll
Assert-Git 'git tag'
Write-Host "  Tag $tagName gesetzt." -ForegroundColor Green

if (-not $NoPush) {
    # git push <remote> <tag>: nur diesen einen Tag zum Git-Server senden
    #   --quiet : keine Fortschrittsanzeige
    git push $Remote $tagName --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: Der Tag ist lokal gesetzt, aber nicht gesendet. Spaeter senden mit:" -ForegroundColor Red
        Write-Host "  git push $Remote $tagName"
        Exit-Script 1
    }
    Write-Host "  Tag zum Git-Server gesendet." -ForegroundColor Green
    Write-Host "  Die Pipeline in GitLab verteilt jetzt nach Produktion (Build -> Pipelines)." -ForegroundColor Green
}
else {
    Write-Host "  Erst mit 'git push $Remote $tagName' startet die Pipeline nach Produktion." -ForegroundColor Yellow
}

# Hinweis: Dateien dieser Freigabe als ZIP holen (z.B. fuer scp)
$pfade = @($c.Dateien | Where-Object { $_.Status -ne 'D' } | ForEach-Object { $_.Pfad })
if ($pfade.Count -gt 0) {
    Write-Host ""
    Write-Host "  Dateien dieser Freigabe als ZIP holen (im obersten Ordner des Repositorys):" -ForegroundColor DarkGray
    Write-Host ("    git archive --output=`"`$env:TEMP\{0}.zip`" {0} {1}" -f $tagName, ($pfade -join ' ')) -ForegroundColor DarkGray
}
Write-Host ""
Exit-Script 0
