# =============================================================================
# checkin_only.ps1 - geaenderte Dateien einchecken (ohne Reports-Teil)
# =============================================================================
# Wie checkin.ps1, aber ohne die Reports-Werkzeuge: keine Administrator-
# Pruefung, keine Wandlung .rdf -> .xml. Fuer einen Rechner ohne Reports und
# ohne Administrator-Rechte - und zum Ausprobieren des Git-Ablaufs.
#
#   cd E:\git\<Ihr Login>
#   .\Reports\checkin_only.ps1 "was ich geaendert habe"
#
# Was das Skript macht:
#   1. hat der Git-Server neuere Check-ins, holt es sie zuerst (nur
#      fast-forward, kein Stash). Hat ein Kollege DIESELBE Datei geaendert,
#      bricht es ab - nichts wird ueberschrieben.
#   2. zeigt alle geaenderten Dateien des Repositorys als nummerierte Liste:
#      Nummer = nur diese eine Datei, a = alle,
#      n = nichts einchecken, nur noch nicht gesendete Check-ins hochladen
#      (wird nur angeboten, wenn es solche gibt - z.B. nach einem
#      abgelehnten Push)
#   3. fragt nach einem Kommentar, wenn keiner angegeben ist
#   4. git add + commit (nur die Auswahl, mit Ihrem Kommentar) + push
#
# Voraussetzung: Git for Windows (Name / E-Mail einmal mit git_setup.ps1 setzen)
#
# Doku   : Git_checkin.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
# Nur ASCII - Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI.
# =============================================================================

param(
    [string]$Comment
)

# --- 0. In den obersten Ordner des Repositorys wechseln
Set-Location $PSScriptRoot
$RepoRoot = git rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: Das Skript liegt nicht in einem Git-Repository." -ForegroundColor Red
    exit 1
}
Set-Location $RepoRoot
Write-Host "Repository: $RepoRoot"

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
# Schritt 4 zusammengefuehrt (merge).
$ahead = git rev-list --count '@{u}..HEAD'
if ([int]$behind -gt 0 -and [int]$ahead -gt 0) {
    Write-Host "Der Git-Server hat $behind neuere(n) Check-in(s), Sie haben $ahead noch nicht gesendete(n)."
    Write-Host "Beides wird beim Senden zusammengefuehrt (Schritt 4)."
}
if ([int]$behind -gt 0 -and [int]$ahead -eq 0) {
    Write-Host "Der Git-Server hat $behind neuere(n) Check-in(s) - hole sie zuerst ..."
    # Nur fast-forward: Ihre Aenderungen bleiben erhalten. Git bricht von selbst
    # ab, wenn eine Ihrer Aenderungen ueberschrieben wuerde (gleiche Datei).
    git pull --ff-only --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "FEHLER: Ein Kollege hat dieselbe Datei geaendert (siehe Meldung oben)." -ForegroundColor Red
        Write-Host "Es wurde nichts eingecheckt und nichts ueberschrieben." -ForegroundColor Red
        Write-Host "Bitte Ihre Datei sichern und den Git-Ansprechpartner fragen." -ForegroundColor Red
        exit 1
    }
}

# --- 2. Welche Dateien sind geaendert? Auswahl: Nummer, a = alle, n = nur senden
# Neue (--others), geaenderte (--modified) und geloeschte (--deleted) Dateien
# im ganzen Repository. Eine geloeschte Datei steht bei --modified und
# --deleted - Sort-Object -Unique zeigt sie nur einmal.
$changed = @(git ls-files --modified --deleted --others --exclude-standard | Sort-Object -Unique)
$selected = @()

if ($changed.Count -eq 0 -and [int]$ahead -eq 0) {
    Write-Host "Nichts einzuchecken - keine geaenderten Dateien." -ForegroundColor Yellow
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
    # n nur anbieten, wenn es lokale Check-ins gibt, die noch nicht auf dem
    # Git-Server sind (z.B. nach einem abgelehnten Push)
    if ([int]$ahead -gt 0) {
        $answer = Read-Host "Welche Datei einchecken? Nummer (nur diese), a (alle) oder n (nichts einchecken, nur die $ahead noch nicht gesendete(n) Check-in(s) hochladen)"
    }
    else {
        $answer = Read-Host "Welche Datei einchecken? Nummer (nur diese) oder a (alle)"
    }
    $answer = "$answer".Trim()
    $number = 0
    if ($answer -eq 'a' -or $answer -eq 'A') {
        $selected = $changed
    }
    elseif (($answer -eq 'n' -or $answer -eq 'N') -and [int]$ahead -gt 0) {
        # Nichts auswaehlen - unten werden nur die noch nicht gesendeten Check-ins hochgeladen
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

# --- 4. Hinzufuegen (nur die Auswahl), committen, hochladen
$nothingNew = $true
if ($selected.Count -gt 0) {
    git add --all -- $selected
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: git add ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
        exit 1
    }
    git diff --cached --quiet -- $selected
    $nothingNew = ($LASTEXITCODE -eq 0)
}

if ($nothingNew -and [int]$ahead -eq 0) {
    Write-Host "Nichts einzuchecken - keine Aenderung in der Auswahl." -ForegroundColor Yellow
    exit 0
}

if ($nothingNew) {
    Write-Host "Nichts Neues - sende nur Ihre(n) $ahead noch nicht gesendeten Check-in(s)."
}

if (-not $nothingNew) {
    Write-Host ""
    Write-Host "Diese Dateien werden eingecheckt:"
    git diff --cached --name-status -- $selected

    # "-- $selected": nur die ausgewaehlten Dateien kommen in den Check-in
    git commit --quiet -m $Comment -- $selected
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
        Write-Host "FEHLER: Ein Kollege hat gleichzeitig eine Ihrer Dateien geaendert" -ForegroundColor Red
        Write-Host "(eine eingecheckte oder eine, die Sie noch bearbeiten - siehe Meldung oben)." -ForegroundColor Red
        Write-Host "Ihr Check-in ist lokal gespeichert, aber NICHT auf dem Git-Server." -ForegroundColor Red
        Write-Host "Bitte den Git-Ansprechpartner fragen." -ForegroundColor Red
        exit 1
    }
    git push --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: git push ist erneut fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
        Write-Host "Ihr Check-in ist lokal gespeichert. Spaeter erneut starten." -ForegroundColor Red
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
