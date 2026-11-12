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
#   1. hat der Git-Server neuere Check-ins, holt es sie zuerst (nur
#      fast-forward, kein Stash). Hat ein Kollege DENSELBEN Bericht geaendert,
#      bricht es ab - nichts wird ueberschrieben.
#   2. zeigt die geaenderten Dateien (Berichte in source\, Bilder in images\)
#      als nummerierte Liste: Nummer = nur diese eine Datei, a = alle,
#      n = nichts Neues, nur noch nicht gesendete Check-ins senden
#   3. fragt nach einem Kommentar, wenn keiner angegeben ist
#   4. wandelt die ausgewaehlte(n) .rdf nach xml\<name>.xml - mit
#      convert_rdf.ps1 (bricht beim ersten Fehler ab - dann wird nichts
#      eingecheckt)
#   5. loescht die xml\<name>.xml eines geloeschten Berichts
#   6. git add (nur die Auswahl) + commit (mit Ihrem Kommentar) + push
#
# Voraussetzungen:
#   - convert_rdf.ps1 im selben Ordner (Konverter + DB-Login-Datei dort
#     eingestellt, Git_checkin.md 2.1)
#   - Git for Windows (Name / E-Mail einmal mit git_setup.ps1 setzen); das Kennwort fuer den Git-Server speichert der
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
# Konverter, Domain und DB-Login-Datei stehen in convert_rdf.ps1.
$ConvertScript = Join-Path $PSScriptRoot 'convert_rdf.ps1'

# Ordner im Repository (relativ zum obersten Ordner des Repositorys)
$SourceDir = 'Reports/source'
$XmlDir    = 'Reports/xml'
$ImageDir  = 'Reports/images'
# ----------------------------------------------------------------------------

# --- 0. In den obersten Ordner des Repositorys wechseln (eine Ebene ueber dem Skript)
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot
Write-Host "Repository: $RepoRoot"

# --- 0a. Pruefungen vor dem Start (Administrator-Fenster, Konverter,
# DB-Login-Datei) - macht convert_rdf.ps1 -Check und zeigt die Meldung selbst
if (-not (Test-Path $ConvertScript)) {
    Write-Host "FEHLER: convert_rdf.ps1 fehlt neben checkin.ps1: $ConvertScript" -ForegroundColor Red
    exit 1
}
& $ConvertScript -Check
if ($LASTEXITCODE -ne 0) {
    exit 1
}

# --- 1. Hat der Git-Server neuere Check-ins? Dann zuerst holen.
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
# abgelehnten Push). Dann geht kein fast-forward - beides wird beim Senden in
# Schritt 6 zusammengefuehrt (merge).
$ahead = git rev-list --count '@{u}..HEAD'
if ([int]$behind -gt 0 -and [int]$ahead -gt 0) {
    Write-Host "Der Git-Server hat $behind neuere(n) Check-in(s), Sie haben $ahead noch nicht gesendete(n)."
    Write-Host "Beides wird beim Senden zusammengefuehrt (Schritt 6)."
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

# --- 2. Welche Dateien sind geaendert? Auswahl: eine Nummer oder a = alle
# Neue (--others), geaenderte (--modified) und geloeschte (--deleted) Dateien
# in source und images. Eine geloeschte Datei steht bei --modified und
# --deleted - Sort-Object -Unique zeigt sie nur einmal.
$changed = @(git ls-files --modified --deleted --others --exclude-standard -- $SourceDir $ImageDir | Sort-Object -Unique)
$selected = @()

if ($changed.Count -eq 0 -and [int]$ahead -eq 0) {
    Write-Host "Nichts einzuchecken - keine geaenderten Berichte oder Bilder." -ForegroundColor Yellow
    exit 0
}

if ($changed.Count -gt 0) {
    Write-Host ""
    Write-Host "Geaenderte Dateien:"
    for ($i = 0; $i -lt $changed.Count; $i++) {
        $file  = $changed[$i]
        $state = 'geaendert'
        if (-not (Test-Path $file)) {
            $state = 'geloescht'
        }
        else {
            # Noch nie eingecheckt? Dann kennt git ls-files die Datei nicht.
            $known = git ls-files -- $file
            if (-not $known) {
                $state = 'neu'
            }
        }
        Write-Host ("  {0,3}  {1,-10} {2}" -f ($i + 1), $state, $file)
    }
    Write-Host ""
    $answer = Read-Host "Welche Datei einchecken? Nummer (nur diese), a (alle) oder n (nichts Neues, nur senden)"
    $answer = "$answer".Trim()
    $number = 0
    if ($answer -eq 'a' -or $answer -eq 'A') {
        $selected = $changed
    }
    elseif ($answer -eq 'n' -or $answer -eq 'N') {
        # Nichts auswaehlen - unten werden nur noch nicht gesendete Check-ins gesendet
        if ([int]$ahead -eq 0) {
            Write-Host "Nichts Neues ausgewaehlt und nichts zu senden - es wurde nichts eingecheckt." -ForegroundColor Yellow
            exit 0
        }
    }
    elseif ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $changed.Count) {
        $selected = @($changed[$number - 1])
    }
    else {
        Write-Host "Ungueltige Auswahl '$answer' - es wurde nichts eingecheckt." -ForegroundColor Yellow
        exit 1
    }
}

# --- 3. Kommentar (nur wenn etwas Neues eingecheckt wird)
if ($selected.Count -gt 0 -and -not $Comment) {
    $Comment = Read-Host "Was haben Sie geaendert? (Kommentar fuer den Check-in)"
}
if ($selected.Count -gt 0 -and -not $Comment) {
    Write-Host "Kein Kommentar - es wurde nichts eingecheckt." -ForegroundColor Yellow
    exit 1
}

# --- 4. Ausgewaehlte neue oder geaenderte .rdf nach xml\<name>.xml wandeln
# $addPaths sammelt, was in Schritt 6 eingecheckt wird: die Auswahl + die
# passende xml-Datei.
$addPaths  = @()
$converted = 0
foreach ($file in $selected) {
    $addPaths += $file
    if (-not $file.EndsWith('.rdf')) {
        continue
    }
    if (-not (Test-Path $file)) {
        continue
    }
    $name = [IO.Path]::GetFileNameWithoutExtension($file)
    Write-Host "Wandle $file -> $XmlDir/$name.xml"

    # convert_rdf.ps1 kennt die Ordner selbst: source\<name>.rdf -> xml\<name>.xml
    & $ConvertScript $name
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Es wurde nichts eingecheckt. Bericht (oder Login-Datei) korrigieren und erneut starten." -ForegroundColor Red
        exit 1
    }
    $addPaths += "$XmlDir/$name.xml"
    $converted = $converted + 1
}
if ($selected.Count -gt 0) {
    Write-Host "Gewandelte Berichte: $converted"
}

# --- 5. Geloeschter Bericht ausgewaehlt: die passende xml ebenfalls loeschen
foreach ($file in $selected) {
    if (-not $file.EndsWith('.rdf')) {
        continue
    }
    if (Test-Path $file) {
        continue
    }
    $name    = [IO.Path]::GetFileNameWithoutExtension($file)
    $xmlFile = Join-Path $RepoRoot "$XmlDir/$name.xml"
    if (Test-Path $xmlFile) {
        Write-Host "Bericht $file wurde geloescht - loesche $XmlDir/$name.xml"
        Remove-Item $xmlFile
        $addPaths += "$XmlDir/$name.xml"
    }
}

# --- 6. Hinzufuegen (nur die Auswahl), committen, hochladen
if ($addPaths.Count -gt 0) {
    git add --all -- $addPaths
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: git add ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
        exit 1
    }
}

# Gibt es ueberhaupt etwas Neues einzuchecken? Nur die Auswahl zaehlt -
# andere, frueher vorgemerkte Dateien bleiben ausserhalb dieses Check-ins.
$nothingNew = $true
if ($addPaths.Count -gt 0) {
    git diff --cached --quiet -- $addPaths
    $nothingNew = ($LASTEXITCODE -eq 0)
}

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
    git diff --cached --name-status -- $addPaths

    # "-- $addPaths": nur die ausgewaehlten Dateien kommen in den Check-in
    git commit --quiet -m $Comment -- $addPaths
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: git commit ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Sende an den Git-Server ..."
# Fehlermeldung des ersten Versuchs ausblenden - der haeufigste Grund wird unten behandelt
git push --quiet 2>$null
if ($LASTEXITCODE -ne 0) {
    # Meist hat ein Kollege genau in diesem Moment eingecheckt. Seinen Stand
    # holen und mit Ihrem Check-in zusammenfuehren (merge), dann noch einmal
    # senden. Merge statt rebase: Ihre anderen, nicht ausgewaehlten Aenderungen
    # duerfen bleiben - Git bricht VOR jeder Aenderung ab, wenn eine davon
    # ueberschrieben wuerde (kein Stash, nichts geht verloren).
    # --ff: gilt auch, wenn in der Git-Konfiguration pull.ff=only steht.
    Write-Host "Der Git-Server war inzwischen neuer - hole den neuen Stand und fuehre ihn zusammen ..."
    git pull --no-rebase --ff --no-edit --quiet
    if ($LASTEXITCODE -ne 0) {
        # Halb fertigen Merge zuruecknehmen (gibt es keinen, passiert nichts)
        git merge --abort 2>$null
        Write-Host ""
        Write-Host "FEHLER: Ein Kollege hat gleichzeitig einen Ihrer Berichte geaendert" -ForegroundColor Red
        Write-Host "(einen eingecheckten oder einen, den Sie noch bearbeiten - siehe Meldung oben)." -ForegroundColor Red
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
if ($nothingNew) {
    Write-Host "OK - an den Git-Server gesendet." -ForegroundColor Green
}
else {
    Write-Host "OK - eingecheckt: $Comment" -ForegroundColor Green
}
git log --oneline -1
exit 0
