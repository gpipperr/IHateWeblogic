# =============================================================================
# checkin.ps1 - geaenderte Berichte einchecken (rdf -> xml, commit, push)
# =============================================================================
# Aufruf, wenn die Berichte fertig sind - in einem PowerShell-Fenster, das mit
# "Als Administrator ausfuehren" gestartet wurde (die Reports-Werkzeuge
# brauchen das auf diesem Server):
#
#   cd E:\git\<Ihr Login>\Reports
#   .\checkin.ps1 "was ich geaendert habe"
#
# Was das Skript macht:
#   1. fragt nach einem Kommentar, wenn keiner angegeben ist
#   2. hat der Git-Server neuere Check-ins, holt es sie zuerst (nur
#      fast-forward, kein Stash). Hat ein Kollege DENSELBEN Bericht geaendert,
#      bricht es ab - nichts wird ueberschrieben.
#   3. wandelt jede neue oder geaenderte .rdf in source\ nach xml\<name>.xml
#      (bricht beim ersten Fehler ab - dann wird nichts eingecheckt)
#   4. loescht die xml\<name>.xml eines geloeschten Berichts
#   5. git add + commit (mit Ihrem Kommentar) + push
#
# Voraussetzungen:
#   - DB-Login fuer den Konverter in %USERPROFILE%\.rwconv\login.txt,
#     eine Zeile:  userid=<db user>/<kennwort>@<tns alias>   (Git_checkin.md 2.1)
#   - Git for Windows; das Kennwort fuer den Git-Server speichert der
#     Git Credential Manager (wird beim ersten Push einmal abgefragt)
#
# Ablage : E:\git\<Login>\Reports\checkin.ps1 (Teil des Repositorys)
# Doku   : Git_checkin.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
# Nur ASCII - Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI.
# =============================================================================

param(
    [string]$Comment
)

# --- Einstellungen - an den Server anpassen ---------------------------------
# Domain des Builders (Kochbuch Schritt 6). Ist die Umgebungsvariable
# DOMAIN_HOME gesetzt, gilt sie.
$DomainHome = 'E:\oracle\user_projects\domains\rwbuilder_domain'
if ($env:DOMAIN_HOME) {
    $DomainHome = $env:DOMAIN_HOME
}
$Converter = "$DomainHome\reports\bin\rwconverter.bat"
# Nur fuer Tests: anderer Konverter ueber die Umgebungsvariable RWCONVERTER
if ($env:RWCONVERTER) {
    $Converter = $env:RWCONVERTER
}
$LoginFile = Join-Path $env:USERPROFILE '.rwconv\login.txt'

# Ordner im Repository (relativ zum obersten Ordner des Repositorys)
$SourceDir = 'Reports/source'
$XmlDir    = 'Reports/xml'
$ImageDir  = 'Reports/images'
# ----------------------------------------------------------------------------

# --- 0. In den obersten Ordner des Repositorys wechseln (eine Ebene ueber dem Skript)
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot
Write-Host "Repository: $RepoRoot"

# --- 0a. Pruefungen vor dem Start
if ($env:OS -eq 'Windows_NT') {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "FEHLER: PowerShell mit 'Als Administrator ausfuehren' starten - die Reports-Werkzeuge brauchen das." -ForegroundColor Red
        exit 1
    }
}
if (-not (Test-Path $Converter)) {
    Write-Host "FEHLER: Konverter nicht gefunden: $Converter" -ForegroundColor Red
    Write-Host "Bitte `$DomainHome oben im Skript pruefen." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $LoginFile)) {
    Write-Host "FEHLER: DB-Login-Datei nicht gefunden: $LoginFile" -ForegroundColor Red
    Write-Host "Einmal anlegen, eine Zeile:  userid=<db user>/<kennwort>@<tns alias>" -ForegroundColor Red
    Write-Host "(Git_checkin.md Abschnitt 2.1)" -ForegroundColor Red
    exit 1
}

# --- 1. Kommentar
if (-not $Comment) {
    $Comment = Read-Host "Was haben Sie geaendert? (Kommentar fuer den Check-in)"
}
if (-not $Comment) {
    Write-Host "Kein Kommentar - es wurde nichts eingecheckt." -ForegroundColor Yellow
    exit 1
}

# --- 2. Hat der Git-Server neuere Check-ins? Dann zuerst holen.
Write-Host "Pruefe den Git-Server auf neuere Check-ins ..."
git fetch --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: git fetch ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
    exit 1
}
$behind = git rev-list --count 'HEAD..@{u}'
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: Vergleich mit dem Git-Server nicht moeglich (kein Upstream-Branch?)." -ForegroundColor Red
    exit 1
}
# Lokale Check-ins, die noch nicht auf dem Git-Server sind (z.B. nach einem
# abgelehnten Push). Dann geht kein fast-forward - sie werden beim Senden in
# Schritt 5 auf den neuen Stand gesetzt.
$ahead = git rev-list --count '@{u}..HEAD'
if ([int]$behind -gt 0 -and [int]$ahead -gt 0) {
    Write-Host "Der Git-Server hat $behind neuere(n) Check-in(s), Sie haben $ahead noch nicht gesendete(n)."
    Write-Host "Beides wird beim Senden zusammengefuehrt (Schritt 5)."
}
if ([int]$behind -gt 0 -and [int]$ahead -eq 0) {
    Write-Host "Der Git-Server hat $behind neuere(n) Check-in(s) - hole sie zuerst ..."
    # Nur fast-forward: Ihre Aenderungen bleiben erhalten. Git bricht von selbst
    # ab, wenn eine Ihrer Aenderungen ueberschrieben wuerde (gleicher Bericht).
    git pull --ff-only --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "FEHLER: Ein Kollege hat denselben Bericht geaendert (siehe Meldung oben)." -ForegroundColor Red
        Write-Host "Es wurde nichts eingecheckt und nichts ueberschrieben." -ForegroundColor Red
        Write-Host "Bitte Ihren Bericht sichern und den Git-Ansprechpartner fragen." -ForegroundColor Red
        exit 1
    }
}

# --- 3. Jede neue oder geaenderte .rdf nach xml\<name>.xml wandeln
# git ls-files listet neue (--others) und geaenderte (--modified) Dateien in source.
# Eine geloeschte Datei steht auch bei --modified - sie wird hier uebersprungen (Schritt 4).
$rdfFiles = git ls-files --modified --others --exclude-standard -- "$SourceDir/*.rdf"
$converted = 0
foreach ($rdf in $rdfFiles) {
    if (-not (Test-Path $rdf)) {
        continue
    }
    $name    = [IO.Path]::GetFileNameWithoutExtension($rdf)
    $source  = Join-Path $RepoRoot $rdf
    $xmlFile = Join-Path $RepoRoot "$XmlDir/$name.xml"
    Write-Host "Wandle $rdf -> $XmlDir/$name.xml"

    $output = & $Converter "source=$source" "stype=rdffile" "dest=$xmlFile" "dtype=xmlfile" "batch=yes" "overwrite=yes" "cmdfile=$LoginFile" 2>&1
    $rc = $LASTEXITCODE

    if ($rc -ne 0) {
        Write-Host ""
        Write-Host "FEHLER: Wandlung von $rdf fehlgeschlagen (Exit-Code $rc):" -ForegroundColor Red
        $output | Where-Object { "$_" -match 'REP-|ORA-' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        Write-Host "Es wurde nichts eingecheckt. Bericht (oder Login-Datei) korrigieren und erneut starten." -ForegroundColor Red
        exit 1
    }
    $converted = $converted + 1
}
Write-Host "Gewandelte Berichte: $converted"

# --- 4. Geloeschte Berichte: die passende xml ebenfalls loeschen
$deletedFiles = git ls-files --deleted -- "$SourceDir/*.rdf"
foreach ($rdf in $deletedFiles) {
    $name    = [IO.Path]::GetFileNameWithoutExtension($rdf)
    $xmlFile = Join-Path $RepoRoot "$XmlDir/$name.xml"
    if (Test-Path $xmlFile) {
        Write-Host "Bericht $rdf wurde geloescht - loesche $XmlDir/$name.xml"
        Remove-Item $xmlFile
    }
}

# --- 5. Hinzufuegen, committen, hochladen
git add --all -- $SourceDir $XmlDir $ImageDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: git add ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
    exit 1
}

# Gibt es ueberhaupt etwas Neues einzuchecken?
git diff --cached --quiet
$nothingNew = ($LASTEXITCODE -eq 0)

if ($nothingNew -and [int]$ahead -eq 0) {
    Write-Host "Nichts einzuchecken - keine geaenderten Berichte, XML-Dateien oder Bilder." -ForegroundColor Yellow
    exit 0
}

if ($nothingNew) {
    Write-Host "Nichts Neues - sende nur Ihre(n) $ahead noch nicht gesendeten Check-in(s)."
}

if (-not $nothingNew) {
    Write-Host ""
    Write-Host "Diese Dateien werden eingecheckt:"
    git diff --cached --name-status

    git commit --quiet -m $Comment
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: git commit ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Sende an den Git-Server ..."
# Fehlermeldung des ersten Versuchs ausblenden - der haeufigste Grund wird unten behandelt
git push --quiet 2>$null
if ($LASTEXITCODE -ne 0) {
    # Meist hat ein Kollege genau in diesem Moment eingecheckt. Ihren Check-in
    # auf dessen Stand setzen (rebase) und noch einmal senden.
    Write-Host "Der Git-Server war inzwischen neuer - setze Ihren Check-in auf den neuen Stand ..."
    git pull --rebase --quiet
    if ($LASTEXITCODE -ne 0) {
        git rebase --abort
        Write-Host ""
        Write-Host "FEHLER: Ein Kollege hat gleichzeitig denselben Bericht geaendert." -ForegroundColor Red
        Write-Host "Ihr Check-in ist lokal gespeichert, aber NICHT auf dem Git-Server." -ForegroundColor Red
        Write-Host "Bitte den Git-Ansprechpartner fragen." -ForegroundColor Red
        exit 1
    }
    git push --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: git push ist erneut fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
        Write-Host "Ihr Check-in ist lokal gespeichert. Spaeter erneut .\checkin.ps1 starten." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "OK - eingecheckt: $Comment" -ForegroundColor Green
git log --oneline -1
exit 0
