# =============================================================================
# checkin.ps1 - geaenderte Berichte einchecken (rdf -> xml, commit, push)
# =============================================================================
# Aufruf, wenn die Berichte fertig sind - in einem PowerShell-Fenster, das mit
# "Als Administrator ausfuehren" gestartet wurde (die Reports-Werkzeuge
# brauchen das auf diesem Server):
#
#   cd E:\git\<Ihr Login>
#   .\Reports\checkin.ps1 "was ich geaendert habe"
#
# Startordner egal: das Skript wechselt selbst in den obersten Ordner des
# Repositorys (git rev-parse --show-toplevel).
#
# Was das Skript macht:
#   1. hat der Git-Server neuere Check-ins, holt es sie zuerst (nur
#      fast-forward, kein Stash). Hat ein Kollege DENSELBEN Bericht geaendert,
#      bricht es ab - nichts wird ueberschrieben.
#   2. zeigt die geaenderten Dateien (Berichte in source\, Bilder in images\)
#      als nummerierte Liste: Nummer = nur diese eine Datei, a = alle,
#      n = nichts einchecken, nur noch nicht gesendete Check-ins hochladen
#      (wird nur angeboten, wenn es solche gibt - z.B. nach einem
#      abgelehnten Push), x oder Enter = abbrechen
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

# Umlaute: Git liefert Dateinamen und Kommentare als UTF-8. Ohne diese Zeile
# liest Windows PowerShell 5.1 sie in der Konsolen-Codepage (falsche Zeichen,
# z.B. f<C3><BC>r statt fuer). Gilt fuer dieses Konsolenfenster.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Einstellungen - an den Server anpassen ---------------------------------
# Konverter, Domain und DB-Login-Datei stehen in convert_rdf.ps1.
$ConvertScript = Join-Path $PSScriptRoot 'convert_rdf.ps1'

# Ordner im Repository (relativ zum obersten Ordner des Repositorys) -
# dieselben Werte wie in convert_rdf.ps1
$SourceDir = 'Reports/source'
$XmlDir    = 'Reports/xml'
$ImageDir  = 'Reports/images'
# ----------------------------------------------------------------------------

# Am Ende - auch bei Abbruch oder Fehler - wieder in den Ordner des Skripts
# wechseln: Exit-Script statt exit
function Exit-Script([int]$Code) {
    Set-Location $PSScriptRoot
    exit $Code
}

# --- 0. In den obersten Ordner des Repositorys wechseln - egal, in welchem
# Ordner das Skript gestartet wird (wie checkin_only.ps1 und convert_rdf.ps1)
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

# --- 0a. Pruefungen vor dem Start (Administrator-Fenster, Konverter,
# DB-Login-Datei) - macht convert_rdf.ps1 -Check und zeigt die Meldung selbst
if (-not (Test-Path $ConvertScript)) {
    Write-Host "FEHLER: convert_rdf.ps1 fehlt neben checkin.ps1: $ConvertScript" -ForegroundColor Red
    Exit-Script 1
}
& $ConvertScript -Check
# convert_rdf.ps1 springt am Ende in seinen Skript-Ordner - zurueck ins Repository
Set-Location $RepoRoot
if ($LASTEXITCODE -ne 0) {
    Exit-Script 1
}

# --- 1. Hat der Git-Server neuere Check-ins? Dann zuerst holen.
Write-Host "Pruefe den Git-Server auf neuere Check-ins ..."
# git fetch: den Stand des Git-Servers abholen - nur in die Kopie des
#   Server-Stands (origin/...), Ihre Dateien und Check-ins bleiben unveraendert
#   --quiet : keine Fortschrittsanzeige
git fetch --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: git fetch ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
    Exit-Script 1
}
# git rev-list --count A..B: zaehlt die Check-ins, die in B sind, aber nicht in A
#   'HEAD..@{u}' : auf dem Git-Server (@{u} = Upstream), aber noch nicht lokal
$behind = git rev-list --count 'HEAD..@{u}'
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: Vergleich mit dem Git-Server nicht moeglich (kein Upstream-Branch?)." -ForegroundColor Red
    Exit-Script 1
}
# Lokale Check-ins, die noch nicht auf dem Git-Server sind (z.B. nach einem
# abgelehnten Push). Dann geht kein fast-forward - beides wird beim Senden in
# Schritt 6 zusammengefuehrt (merge).
# git rev-list --count '@{u}..HEAD': zaehlt die lokalen Check-ins, die noch
#   nicht auf dem Git-Server (@{u} = Upstream) sind
$ahead = git rev-list --count '@{u}..HEAD'
if ([int]$behind -gt 0 -and [int]$ahead -gt 0) {
    Write-Host "Der Git-Server hat $behind neuere(n) Check-in(s), Sie haben $ahead noch nicht gesendete(n)."
    Write-Host "Beides wird beim Senden zusammengefuehrt (Schritt 6)."
}
if ([int]$behind -gt 0 -and [int]$ahead -eq 0) {
    Write-Host "Der Git-Server hat $behind neuere(n) Check-in(s) - hole sie zuerst ..."
    # Nur fast-forward: Ihre Aenderungen bleiben erhalten. Git bricht von selbst
    # ab, wenn eine Ihrer Aenderungen ueberschrieben wuerde (gleicher Bericht).
    # git pull: neue Check-ins vom Git-Server holen und einspielen
    #   --ff-only : nur "fast-forward" - Ihr Stand wird nur nach vorne geschoben;
    #               ist das nicht moeglich, bricht git ab statt zusammenzufuehren
    #   --quiet   : keine Fortschrittsanzeige
    git pull --ff-only --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "FEHLER: Ein Kollege hat denselben Bericht geaendert (siehe Meldung oben)." -ForegroundColor Red
        Write-Host "Es wurde nichts eingecheckt und nichts ueberschrieben." -ForegroundColor Red
        Write-Host "Bitte Ihren Bericht sichern und den Git-Ansprechpartner fragen." -ForegroundColor Red
        Exit-Script 1
    }
}

# --- 2. Welche Dateien sind geaendert? Auswahl: eine Nummer oder a = alle
# Neue (--others), geaenderte (--modified) und geloeschte (--deleted) Dateien
# in source und images. Eine geloeschte Datei steht bei --modified und
# --deleted - Sort-Object -Unique zeigt sie nur einmal.
# git ls-files: Dateien auflisten
#   -c core.quotePath=false : Dateinamen mit Umlauten im Klartext
#   --modified              : geaenderte Dateien (und geloeschte)
#   --deleted               : geloeschte Dateien
#   --others                : neue Dateien, die git noch nicht kennt
#   --exclude-standard      : ohne die Dateien aus .gitignore
$changed = @(git -c core.quotePath=false ls-files --modified --deleted --others --exclude-standard -- $SourceDir $ImageDir | Sort-Object -Unique)
$selected = @()
$states   = @()

if ($changed.Count -eq 0 -and [int]$ahead -eq 0) {
    Write-Host "Nichts einzuchecken - keine geaenderten Berichte oder Bilder." -ForegroundColor Yellow
    Exit-Script 0
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
            # git ls-files -- <datei>: gibt die Datei aus, wenn sie schon eingecheckt
            #   ist - leer = neue Datei. '--' = ab hier folgen nur Dateinamen
            $known = git -c core.quotePath=false ls-files -- $file
            if (-not $known) {
                $state = 'neu'
            }
        }
        $states += $state
        Write-Host ("  {0,3}  {1,-10} {2}" -f ($i + 1), $state, $file)
    }
    Write-Host ""
    # n nur anbieten, wenn es lokale Check-ins gibt, die noch nicht auf dem
    # Git-Server sind (z.B. nach einem abgelehnten Push)
    if ([int]$ahead -gt 0) {
        $answer = Read-Host "Welche Datei einchecken? Nummer (nur diese), a (alle), n (nichts einchecken, nur die $ahead noch nicht gesendete(n) Check-in(s) hochladen) oder x (abbrechen)"
    }
    else {
        $answer = Read-Host "Welche Datei einchecken? Nummer (nur diese), a (alle) oder x (abbrechen)"
    }
    $answer = "$answer".Trim()
    $number = 0
    # x oder nur Enter = abbrechen - Ihre Dateien bleiben, wie sie sind
    if ($answer -eq '' -or $answer -eq 'x' -or $answer -eq 'X') {
        Write-Host "Abgebrochen - es wurde nichts eingecheckt." -ForegroundColor Yellow
        Exit-Script 0
    }
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
        Exit-Script 1
    }
}

# --- 3. Kommentar (nur wenn etwas Neues eingecheckt wird)
# Zuerst zeigen, wofuer der Kommentar gilt - und dass noch nicht gesendete
# Check-ins beim Hochladen mitgehen.
if ($selected.Count -gt 0) {
    Write-Host ""
    if ($selected.Count -eq 1) {
        $pos = [array]::IndexOf($changed, $selected[0])
        Write-Host "Ausgewaehlt: $($states[$pos])  $($selected[0])"
    }
    else {
        Write-Host "Ausgewaehlt: $($selected.Count) Dateien"
    }
    if ([int]$ahead -gt 0) {
        Write-Host "Hinweis: Ihr(e) $ahead noch nicht gesendete(n) Check-in(s) wird/werden mit hochgeladen." -ForegroundColor Yellow
    }
}
if ($selected.Count -gt 0 -and -not $Comment) {
    $Comment = Read-Host "Kommentar fuer diesen Check-in (was und warum)"
}
if ($selected.Count -gt 0 -and -not $Comment) {
    Write-Host "Abgebrochen (kein Kommentar) - es wurde nichts eingecheckt." -ForegroundColor Yellow
    Exit-Script 0
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
    Set-Location $RepoRoot
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Es wurde nichts eingecheckt. Bericht (oder Login-Datei) korrigieren und erneut starten." -ForegroundColor Red
        Exit-Script 1
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
    # git add: Dateien fuer den naechsten Check-in vormerken
    #   --all : auch neue und geloeschte Dateien (eine geloeschte wird als
    #           Loeschung vorgemerkt)
    #   --    : ab hier folgen nur Dateinamen - nur die Auswahl
    git add --all -- $addPaths
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: git add ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
        Exit-Script 1
    }
}

# Gibt es ueberhaupt etwas Neues einzuchecken? Nur die Auswahl zaehlt -
# andere, frueher vorgemerkte Dateien bleiben ausserhalb dieses Check-ins.
$nothingNew = $true
if ($addPaths.Count -gt 0) {
    # git diff --cached: vergleicht das Vorgemerkte mit dem letzten Check-in
    #   --quiet : keine Ausgabe, nur Exit-Code: 0 = kein Unterschied, 1 = Aenderung
    #   --      : nur die ausgewaehlten Dateien vergleichen
    git diff --cached --quiet -- $addPaths
    $nothingNew = ($LASTEXITCODE -eq 0)
}

if ($nothingNew -and [int]$ahead -eq 0) {
    Write-Host "Nichts einzuchecken - keine geaenderten Berichte, XML-Dateien oder Bilder." -ForegroundColor Yellow
    Exit-Script 0
}

if ($nothingNew) {
    Write-Host "Nichts Neues - sende nur Ihre(n) $ahead noch nicht gesendeten Check-in(s)."
}

if (-not $nothingNew) {
    Write-Host ""
    Write-Host "Diese Dateien werden eingecheckt:"
    # git diff --cached --name-status: Liste des Vorgemerkten - Buchstabe + Datei
    #   (A = neu, M = geaendert, D = geloescht)
    #   -c core.quotePath=false : Dateinamen mit Umlauten im Klartext
    git -c core.quotePath=false diff --cached --name-status -- $addPaths

    # "-- $addPaths": nur die ausgewaehlten Dateien kommen in den Check-in
    # git commit: den Check-in lokal speichern (noch nicht auf dem Git-Server)
    #   --quiet     : keine Zusammenfassung
    #   -m $Comment : Ihr Kommentar (sonst wuerde git einen Editor oeffnen)
    #   -- <dateien>: NUR diese Dateien - andere vorgemerkte bleiben draussen
    git commit --quiet -m $Comment -- $addPaths
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: git commit ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
        Exit-Script 1
    }
}

Write-Host "Sende an den Git-Server ..."
# Fehlermeldung des ersten Versuchs ausblenden - der haeufigste Grund wird unten behandelt
# git push: lokale Check-ins an den Git-Server senden
#   --quiet  : keine Fortschrittsanzeige
#   2>$null  : Fehlermeldung ausblenden - der Fall wird unten behandelt
git push --quiet 2>$null
if ($LASTEXITCODE -ne 0) {
    # Meist hat ein Kollege genau in diesem Moment eingecheckt. Seinen Stand
    # holen und mit Ihrem Check-in zusammenfuehren (merge), dann noch einmal
    # senden. Merge statt rebase: Ihre anderen, nicht ausgewaehlten Aenderungen
    # duerfen bleiben - Git bricht VOR jeder Aenderung ab, wenn eine davon
    # ueberschrieben wuerde (kein Stash, nichts geht verloren).
    # --ff: gilt auch, wenn in der Git-Konfiguration pull.ff=only steht.
    Write-Host "Der Git-Server war inzwischen neuer - hole den neuen Stand und fuehre ihn zusammen ..."
    # git pull: neuen Stand holen und mit Ihren Check-ins zusammenfuehren
    #   --no-rebase : zusammenfuehren (merge), Ihre Check-ins nicht umschreiben
    #   --ff        : fast-forward, wenn moeglich, sonst ein Merge-Check-in
    #                 (gilt auch, wenn pull.ff=only konfiguriert ist)
    #   --no-edit   : Standard-Kommentar fuer den Merge-Check-in, kein Editor
    #   --quiet     : keine Fortschrittsanzeige
    git pull --no-rebase --ff --no-edit --quiet
    if ($LASTEXITCODE -ne 0) {
        # Halb fertigen Merge zuruecknehmen (gibt es keinen, passiert nichts)
        # git merge --abort: einen halb fertigen Merge zuruecknehmen - der Stand vor
        #   dem Pull ist wieder da. 2>$null: keine Meldung, wenn es keinen Merge gibt
        git merge --abort 2>$null
        Write-Host ""
        Write-Host "FEHLER: Ein Kollege hat gleichzeitig einen Ihrer Berichte geaendert" -ForegroundColor Red
        Write-Host "(einen eingecheckten oder einen, den Sie noch bearbeiten - siehe Meldung oben)." -ForegroundColor Red
        Write-Host "Ihr Check-in ist lokal gespeichert, aber NICHT auf dem Git-Server." -ForegroundColor Red
        Write-Host "Bitte den Git-Ansprechpartner fragen." -ForegroundColor Red
        Exit-Script 1
    }
    # git push: zweiter Versuch, jetzt mit dem zusammengefuehrten Stand
    #   --quiet : keine Fortschrittsanzeige
    git push --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: git push ist erneut fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
        Write-Host "Ihr Check-in ist lokal gespeichert. Spaeter erneut .\checkin.ps1 starten." -ForegroundColor Red
        Exit-Script 1
    }
}

Write-Host ""
if ($nothingNew) {
    Write-Host "OK - an den Git-Server gesendet." -ForegroundColor Green
}
else {
    Write-Host "OK - eingecheckt: $Comment" -ForegroundColor Green
}
# git log: den eben gesendeten Check-in zeigen
#   --no-pager    : direkt ausgeben, kein Blaettern mit 'less'
#   --oneline     : eine Zeile (Kurz-Nummer + Kommentar)
#   --no-decorate : ohne Branch-Namen in Klammern
#   -1            : nur den letzten Check-in
git --no-pager log --oneline --no-decorate -1
Exit-Script 0
