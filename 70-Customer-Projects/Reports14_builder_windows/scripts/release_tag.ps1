# =============================================================================
# release_tag.ps1 - Freigaben fuer die Produktion anzeigen und per Tag setzen
# =============================================================================
# Teil 1: alle Check-ins auf origin/development, die in noch keinem prod-Tag
#         enthalten sind - nummeriert, mit Dateien und einer Liste pro Datei
# Teil 2: die letzten 20 prod-Tags mit Datum, Freigeber, Check-in und den
#         Dateien, die seit der vorherigen Freigabe geaendert wurden
# Teil 3: fragt nach einer Nummer aus Teil 1, setzt auf diesen Check-in einen
#         Tag mit Kommentar und sendet ihn zum Git-Server, z.B.
#             prod-2026-11-12_1430_umsatz.rdf
#
# Standard: nur .rdf-Dateien (-Filter '*.rdf'). Mit -Filter ein anderes
# Muster, mit -Filter '' alle Dateien.
#
#   cd E:\git\<Ihr Login>
#   .\Reports\release_tag.ps1                    anzeigen, dann Nummer waehlen
#                                                (Enter = nichts taggen)
#   .\Reports\release_tag.ps1 -File umsatz       nur Dateien, deren Name
#                                                'umsatz' enthaelt
#   .\Reports\release_tag.ps1 -Filter ''         alle Dateien, nicht nur .rdf
#   .\Reports\release_tag.ps1 -Filter '*.png'    nur Bilder (.png)
#   .\Reports\release_tag.ps1 -Nummer 2 -Ja      Check-in Nr. 2 ohne Rueckfrage
#                                                taggen und senden
#
# Weitere Parameter: -Branch (Standard origin/development), -TagPrefix (prod),
# -Anzahl (20 Freigaben in Teil 2), -TagDatei / -Nachricht (ohne Rueckfrage),
# -NoPush (Tag nur lokal), -NoFetch (ohne git fetch).
#
# Aendert nichts an Ihren Dateien und wechselt keinen Branch - es setzt nur
# den Tag. Startordner egal: das Skript wechselt selbst in den obersten
# Ordner des Repositorys und am Ende zurueck in den Ordner des Skripts.
#
# Achtung: ein Tag auf Check-in Nr. 3 gibt auch alle aelteren Check-ins frei
# (Nr. 4, 5, ...) - sie sind im Stand von Nr. 3 enthalten.
#
# Doku   : Git_checkin.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
# Nur ASCII - Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI.
# =============================================================================

param(
    # Branch auf dem Git-Server, dessen Check-ins freigegeben werden
    [string]$Branch    = 'origin/development',
    # Anfang der Tag-Namen: prod-...
    [string]$TagPrefix = 'prod',
    # Anzahl der Freigaben in Teil 2
    [int]   $Anzahl    = 20,
    # nur Dateien, deren Name diesen Text enthaelt (Teil genuegt, gross/klein egal)
    [string]$File      = '',
    # Dateimuster fuer den ganzen Pfad (gross/klein egal); '' = alle Dateien
    [string]$Filter    = '*.rdf',
    # Nummer aus Teil 1 ohne Abfrage
    [int]   $Nummer    = 0,
    # Dateiname fuer den Tag-Namen ohne Abfrage
    [string]$TagDatei  = '',
    # Tag-Kommentar ohne Abfrage
    [string]$Nachricht = '',
    # keine Sicherheitsabfrage vor dem Taggen
    [switch]$Ja,
    # Tag nur lokal setzen, nicht zum Git-Server senden
    [switch]$NoPush,
    # ohne vorheriges git fetch
    [switch]$NoFetch
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
Write-Host " NOCH NICHT IN PRODUKTION  ($Branch, ohne Tag '$TagPattern'$filterText)" -ForegroundColor Cyan
Write-Host $Line -ForegroundColor Cyan

# git log: Check-ins mit ihren Dateien
#   -c core.quotePath=false : Dateinamen mit Umlauten im Klartext
#   --no-pager              : direkt ausgeben, nicht seitenweise
#   --no-merges             : ohne Zusammenfuehrungen (haben keine eigenen Dateien)
#   --date=format:'%Y-%m-%d %H:%M' : Datum als 2026-11-12 14:30
#   --name-status           : unter jedem Check-in die Dateien mit Status
#                             (A neu, M geaendert, D geloescht, R umbenannt)
#   --format                : Kopfzeile je Check-in, beginnt mit '@@':
#                             %H volle Nummer, %h Kurz-Nummer, %ad Datum,
#                             %an Autor, %s Kommentar
#   $Branch --not --tags=<muster> : Check-ins des Branches, die in KEINEM
#                             Tag mit diesem Muster enthalten sind
$lines = @(git -c core.quotePath=false --no-pager log --no-merges --date=format:'%Y-%m-%d %H:%M' `
    --name-status --format='@@%H|%h|%ad|%an|%s' $Branch --not "--tags=$TagPattern")
Assert-Git 'git log'

# Zeilen in Check-ins mit Dateien umsetzen; Check-ins ohne passende Datei
# (wegen -Filter / -File) fallen weg
$offen = New-Object System.Collections.ArrayList
$cur   = $null
foreach ($l in ($lines + '@@END')) {
    if ($l.StartsWith('@@')) {
        if ($null -ne $cur -and $cur.Dateien.Count -gt 0) { [void]$offen.Add($cur) }
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

# --- 2. Letzte Freigaben
Write-Host ""
Write-Host $Line -ForegroundColor Cyan
Write-Host " LETZTE $Anzahl FREIGABEN  (Tags '$TagPattern'$filterText)" -ForegroundColor Cyan
Write-Host $Line -ForegroundColor Cyan

# git for-each-ref refs/tags/<muster>: alle Tags mit diesem Muster
#   --sort=-v:refname --sort=-creatordate : neueste zuerst (der letzte
#                     --sort zaehlt zuerst; bei gleichem Datum nach Name)
#   --format : %(refname:short) Tag-Name, %(creatordate:...) Datum,
#              %(taggername) Freigeber (- bei einfachem Tag ohne Kommentar),
#              %(*objectname:short) Check-in, auf den der Tag zeigt
#              (%(objectname:short) bei einfachem Tag),
#              %(contents:subject) erste Zeile des Tag-Kommentars
$fmt = '%(refname:short)|%(creatordate:format:%Y-%m-%d %H:%M)|%(if)%(taggername)%(then)%(taggername)%(else)-%(end)|%(if)%(*objectname)%(then)%(*objectname:short)%(else)%(objectname:short)%(end)|%(contents:subject)'
$alleTags = @(git -c core.quotePath=false for-each-ref "refs/tags/$TagPattern" --sort=-v:refname --sort=-creatordate "--format=$fmt")
Assert-Git 'git for-each-ref'

if ($alleTags.Count -eq 0 -or -not $alleTags[0]) {
    Write-Host "  Keine Tags '$TagPattern' gefunden." -ForegroundColor Yellow
}
else {
    $gezeigt = 0
    for ($i = 0; $i -lt $alleTags.Count -and $gezeigt -lt $Anzahl; $i++) {
        $t = $alleTags[$i].Split('|', 5)
        $tag = $t[0]
        if ($i + 1 -lt $alleTags.Count) {
            $vorher = $alleTags[$i + 1].Split('|', 2)[0]
            # git diff --name-status <vorher> <tag>: Dateien, die sich zwischen
            #   der vorherigen und dieser Freigabe geaendert haben
            $dateien = @(ConvertFrom-NameStatus @(git -c core.quotePath=false diff --name-status $vorher $tag))
            Assert-Git 'git diff'
            $info = "seit $vorher"
        }
        else {
            # erste Freigabe: sie enthaelt den ganzen Stand - alle Dateien
            # git ls-tree -r --name-only <tag>: alle Dateien dieses Stands
            #   -r          : auch in Unterordnern
            #   --name-only : nur die Pfade
            $alle = @(git -c core.quotePath=false ls-tree -r --name-only $tag)
            Assert-Git 'git ls-tree'
            $dateien = @(ConvertFrom-NameStatus @($alle | ForEach-Object { "A`t$_" }))
            $info = 'erste Freigabe, alle Dateien dieses Stands'
        }

        # mit -File: Freigaben ohne diese Datei auslassen
        if ($File -ne '' -and $dateien.Count -eq 0) { continue }

        Write-Host ""
        Write-Host ("  {0,-40} {1}  {2,-15}  Check-in {3}" -f $tag, $t[1], $t[2], $t[3]) -ForegroundColor Green
        Write-Host ("        {0}" -f $t[4])
        Write-Host ("        Dateien ({0}):" -f $info) -ForegroundColor DarkGray
        if ($dateien.Count -eq 0) { Write-Host "        (keine passenden Aenderungen)" -ForegroundColor DarkGray }
        foreach ($f in $dateien) { Write-Datei $f }
        $gezeigt++
    }
}
Write-Host ""

# --- 3. Check-in fuer die Produktion freigeben (Tag setzen)
if ($offen.Count -eq 0) { Exit-Script 0 }

Write-Host $Line -ForegroundColor Cyan
Write-Host " FREIGABE FUER DIE PRODUKTION" -ForegroundColor Cyan
Write-Host $Line -ForegroundColor Cyan

$nr = $Nummer
if ($nr -eq 0) {
    $eingabe = Read-Host "  Nummer des Check-ins fuer die Freigabe (1-$($offen.Count), Enter = keine Freigabe)"
    if (-not $eingabe) {
        Write-Host "  Keine Freigabe gesetzt."
        Exit-Script 0
    }
    if (-not [int]::TryParse($eingabe, [ref]$nr)) {
        Write-Host "FEHLER: Ungueltige Eingabe: '$eingabe'" -ForegroundColor Red
        Exit-Script 1
    }
}
if ($nr -lt 1 -or $nr -gt $offen.Count) {
    Write-Host "FEHLER: Nummer $nr liegt nicht zwischen 1 und $($offen.Count)." -ForegroundColor Red
    Exit-Script 1
}

$c = $offen[$nr - 1]
Write-Host ""
Write-Host ("  Ausgewaehlt: [{0}] {1}  {2}  {3}" -f $nr, $c.Hash, $c.Datum, $c.Text) -ForegroundColor Yellow

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
if ($nr -lt $offen.Count) {
    $bereich = "[$($nr + 1)]"
    if ($nr + 1 -lt $offen.Count) { $bereich = "[$($nr + 1)]-[$($offen.Count)]" }
    Write-Host "  Hinweis  : Damit gelten auch die aelteren Check-ins $bereich als freigegeben." -ForegroundColor Yellow
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
