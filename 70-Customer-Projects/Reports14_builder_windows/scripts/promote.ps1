# =============================================================================
# promote.ps1 - EINEN Bericht fuer die Produktion freigeben (development -> main)
# =============================================================================
# Bringt genau einen Bericht (.rdf + .xml, auf Wunsch Bilder) aus dem Branch
# development in einen Merge Request nach main. Nach der Genehmigung und dem
# Merge in GitLab startet dort der Produktions-Deploy (Knopf "Play").
# Alle anderen Berichte aus development bleiben, wo sie sind.
#
#   cd E:\git\<Ihr Login>
#   .\Reports\promote.ps1 umsatz
#
# Was das Skript macht:
#   1. holt den Stand des Git-Servers (git fetch - Ihre Dateien bleiben)
#   2. prueft: Bericht auf dem Git-Server in development vorhanden, anders als
#      in main, bei Ihnen nicht ungesendet geaendert
#   3. fragt, welche geaenderten Bilder mitgehen sollen
#   4. zeigt die Check-ins des Berichts und fragt nach dem Grund der Freigabe
#   5. baut den Freigabe-Stand in einem eigenen, temporaeren Ordner (Ihr
#      Arbeitsordner und Ihr Branch werden NICHT angefasst) und sendet ihn
#      als Branch release/<bericht>-<datum> - GitLab legt dabei den Merge
#      Request nach main an
#   6. raeumt den temporaeren Ordner wieder auf
#
# Startordner egal: das Skript wechselt selbst in den obersten Ordner des
# Repositorys und am Ende zurueck in den Ordner des Skripts.
#
# Doku   : Git_deploy.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
# Nur ASCII - Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI.
# =============================================================================

param(
    [Parameter(Position = 0)]
    [string]$Report
)

# Umlaute: Git liefert Dateinamen und Kommentare als UTF-8. Ohne diese Zeile
# liest Windows PowerShell 5.1 sie in der Konsolen-Codepage (falsche Zeichen).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Einstellungen - an das Repository anpassen -----------------------------
$Remote     = 'origin'
$DevBranch  = 'development'
$MainBranch = 'main'
# Ordner im Repository (relativ zum obersten Ordner) - wie in checkin.ps1
$SourceDir  = 'Reports/source'
$XmlDir     = 'Reports/xml'
$ImageDir   = 'Reports/images'
# ----------------------------------------------------------------------------

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
$RepoRoot = (Get-Location).Path
Write-Host "Repository: $RepoRoot"

# --- Aufruf pruefen: nur der Name zaehlt (umsatz, umsatz.rdf oder Pfad)
if (-not $Report) {
    Write-Host "Aufruf: .\Reports\promote.ps1 <berichtsname>" -ForegroundColor Yellow
    Exit-Script 1
}
$name    = [IO.Path]::GetFileNameWithoutExtension($Report)
$rdf     = "$SourceDir/$name.rdf"
$xml     = "$XmlDir/$name.xml"
$devRef  = "$Remote/$DevBranch"
$mainRef = "$Remote/$MainBranch"

# --- 1. Stand des Git-Servers holen
Write-Host "Hole den Stand vom Git-Server (an Ihren Dateien aendert sich nichts) ..."
# git fetch: den Stand des Git-Servers abholen - nur in die Kopie des
#   Server-Stands (origin/...), Ihre Dateien und Check-ins bleiben unveraendert
#   --quiet : keine Fortschrittsanzeige
git fetch --quiet $Remote
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: git fetch ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
    Exit-Script 1
}

# --- 2. Pruefungen
# git cat-file -e <stand>:<datei>: Exit-Code 0, wenn die Datei in diesem Stand
#   existiert (keine Ausgabe). 2>$null: keine Meldung, wenn nicht
git cat-file -e "${devRef}:$rdf" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: $rdf gibt es auf dem Git-Server in $DevBranch nicht." -ForegroundColor Red
    Write-Host "Name pruefen - oder der Bericht ist noch nicht eingecheckt (checkin.ps1)." -ForegroundColor Red
    Exit-Script 1
}
git cat-file -e "${devRef}:$xml" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: $xml fehlt in $DevBranch - den Bericht einmal mit checkin.ps1 einchecken." -ForegroundColor Red
    Exit-Script 1
}

# git diff --quiet A B -- <dateien>: Exit-Code 0 = in beiden Staenden gleich,
#   1 = verschieden (keine Ausgabe)
git diff --quiet $mainRef $devRef -- $rdf $xml
if ($LASTEXITCODE -eq 0) {
    Write-Host "Der Bericht $name ist in $MainBranch schon genau so - nichts freizugeben." -ForegroundColor Yellow
    Exit-Script 0
}

# Freigegeben wird der Stand auf dem Git-Server. Ist der Bericht bei Ihnen
# geaendert und noch nicht eingecheckt, waere das nicht dabei.
# git status --porcelain -- <dateien>: eine Zeile je geaenderter Datei, leer = unveraendert
#   -c core.quotePath=false : Dateinamen mit Umlauten im Klartext
$localChange = git -c core.quotePath=false status --porcelain -- $rdf
if ($localChange) {
    Write-Host "FEHLER: $rdf ist bei Ihnen geaendert und noch nicht eingecheckt." -ForegroundColor Red
    Write-Host "Zuerst mit checkin.ps1 einchecken - freigegeben wird nur, was auf dem Git-Server ist." -ForegroundColor Red
    Exit-Script 1
}
# git rev-parse --abbrev-ref HEAD: Name des aktuellen Branches
$branch = git rev-parse --abbrev-ref HEAD
if ($branch -eq $DevBranch) {
    # git diff --quiet <server> HEAD -- <datei>: ist Ihr eingecheckter Stand
    #   des Berichts derselbe wie auf dem Git-Server?
    git diff --quiet $devRef HEAD -- $rdf
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: Ihr Stand von $rdf ist ein anderer als auf dem Git-Server" -ForegroundColor Red
        Write-Host "(noch nicht gesendet oder noch nicht geholt) - zuerst status.ps1 ansehen." -ForegroundColor Red
        Exit-Script 1
    }
}
else {
    Write-Host "Hinweis: Sie sind auf Branch '$branch' - freigegeben wird der Stand von $devRef." -ForegroundColor Yellow
}

# --- 3. Bilder: welche sind in development anders als in main?
# git diff --name-only --diff-filter=AM A B -- <ordner>: nur die Namen der
#   Dateien, die in B neu (A) oder geaendert (M) sind
$images = @(git -c core.quotePath=false diff --name-only --diff-filter=AM $mainRef $devRef -- $ImageDir)
$imageSel = @()
if ($images.Count -gt 0) {
    Write-Host ""
    Write-Host "Bilder, die in $DevBranch neu oder anders sind als in ${MainBranch}:"
    for ($i = 0; $i -lt $images.Count; $i++) {
        Write-Host ("  {0,3}  {1}" -f ($i + 1), $images[$i])
    }
    $answer = Read-Host "Welche Bilder gehen mit? Nummern mit Komma (z.B. 1,3), a (alle) oder Enter (keine)"
    $answer = "$answer".Trim()
    if ($answer -eq 'a' -or $answer -eq 'A') {
        $imageSel = $images
    }
    elseif ($answer) {
        foreach ($part in $answer.Split(',')) {
            $number = 0
            if ([int]::TryParse($part.Trim(), [ref]$number) -and $number -ge 1 -and $number -le $images.Count) {
                $imageSel += $images[$number - 1]
            }
            else {
                Write-Host "Ungueltige Auswahl '$part' - es wurde nichts freigegeben." -ForegroundColor Yellow
                Exit-Script 1
            }
        }
        $imageSel = @($imageSel | Sort-Object -Unique)
    }
}

# --- 4. Anzeigen, was freigegeben wird, und nach dem Grund fragen
Write-Host ""
Write-Host "Freigabe fuer die Produktion:" -ForegroundColor Cyan
Write-Host "  $rdf"
Write-Host "  $xml"
foreach ($img in $imageSel) {
    Write-Host "  $img"
}
Write-Host ""
Write-Host "Check-ins des Berichts seit dem letzten Stand in ${MainBranch}:"
# git log A..B -- <datei>: Check-ins, die in B sind, aber nicht in A - nur
#   die, die diesen Bericht geaendert haben
#   --no-pager / --no-decorate : direkt ausgeben, ohne Branch-Namen
#   --format : %h Kurz-Nummer, %ad Datum, %an Autor, %s Kommentar
git --no-pager log --no-decorate --format='  %h  %ad  %an  %s' --date=format:'%Y-%m-%d %H:%M' "$mainRef..$devRef" -- $rdf
Write-Host ""
$reason = Read-Host "Grund der Freigabe (erscheint im Merge Request) - Enter = abbrechen"
# Anfuehrungszeichen entfernen - der Grund geht als Push-Option an GitLab
$reason = "$reason".Replace('"', '').Replace("'", '').Trim()
if (-not $reason) {
    Write-Host "Abgebrochen - es wurde nichts freigegeben." -ForegroundColor Yellow
    Exit-Script 0
}

# --- 5. Freigabe-Stand in einem temporaeren Ordner bauen und senden
# Branch-Name nur aus einfachen Zeichen: Umlaute umschreiben (ue statt
# u-Umlaut), alles andere ausser A-Z 0-9 _ - wird zu _
# ([char]0x00FC usw.: die Umlaute als Zeichen-Code - die Datei bleibt ASCII)
$safeName = $name
$umlaut = @{ 0x00E4 = 'ae'; 0x00F6 = 'oe'; 0x00FC = 'ue'; 0x00C4 = 'Ae'; 0x00D6 = 'Oe'; 0x00DC = 'Ue'; 0x00DF = 'ss' }
foreach ($code in $umlaut.Keys) {
    $safeName = $safeName.Replace([string][char]$code, $umlaut[$code])
}
$safeName = $safeName -replace '[^A-Za-z0-9_-]', '_'
$stamp    = Get-Date -Format 'yyyyMMdd-HHmm'
$relBranch = "release/$safeName-$stamp"
$title    = "Release ${name}: $reason"
$wt       = Join-Path ([IO.Path]::GetTempPath()) "promote_${safeName}_$stamp"

$rc = 1
try {
    # git worktree add --detach <ordner> <stand>: einen zweiten Arbeitsordner
    #   mit dem Stand von main anlegen - Ihr Arbeitsordner bleibt, wie er ist
    #   --detach : ohne lokalen Branch (gesendet wird direkt als release/...)
    #   --quiet  : keine Meldung
    git worktree add --quiet --detach $wt $mainRef
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: temporaerer Ordner $wt konnte nicht angelegt werden." -ForegroundColor Red
        throw 'worktree'
    }

    $paths = @($rdf, $xml) + $imageSel
    # git -C <ordner>: den Befehl im temporaeren Ordner ausfuehren
    # git checkout <stand> -- <dateien>: genau diese Dateien aus development
    #   uebernehmen - sonst nichts
    git -C $wt checkout $devRef -- $paths
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: Dateien konnten nicht aus $DevBranch uebernommen werden." -ForegroundColor Red
        throw 'checkout'
    }

    # git commit -m <text> --quiet: den Freigabe-Check-in speichern (nur im
    #   temporaeren Ordner, Ihr Branch bekommt ihn nicht)
    git -C $wt commit --quiet -m $title
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: git commit ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
        throw 'commit'
    }

    Write-Host ""
    Write-Host "Sende $relBranch an den Git-Server und lege den Merge Request an ..."
    # git push <remote> HEAD:refs/heads/<branch>: den Check-in als neuen
    #   Branch release/... auf den Git-Server senden
    #   -o merge_request.create             : GitLab legt den Merge Request an
    #   -o merge_request.target=main        : Ziel des Merge Requests
    #   -o merge_request.title=...          : Titel = Bericht + Grund
    #   -o merge_request.remove_source_branch : release/... nach dem Merge loeschen
    # 2>&1: GitLab meldet den Link zum Merge Request als "remote:"-Zeilen
    $pushOut = git -C $wt push `
        -o merge_request.create `
        -o "merge_request.target=$MainBranch" `
        -o "merge_request.title=$title" `
        -o merge_request.remove_source_branch `
        $Remote "HEAD:refs/heads/$relBranch" 2>&1
    $pushRc = $LASTEXITCODE
    $pushOut | ForEach-Object { "$_" } | Where-Object { $_ -match 'remote:|error|rejected|denied' } |
        ForEach-Object { Write-Host "  $_" }
    if ($pushRc -ne 0) {
        Write-Host "FEHLER: Senden fehlgeschlagen - siehe Meldung oben. Es wurde nichts freigegeben." -ForegroundColor Red
        throw 'push'
    }
    $rc = 0
}
catch {
    $rc = 1
}
finally {
    # --- 6. Aufraeumen - immer, auch nach einem Fehler
    # git worktree remove --force <ordner>: den temporaeren Ordner loeschen
    #   (--force: auch wenn darin noch etwas geaendert ist)
    if (Test-Path $wt) {
        git worktree remove --force $wt 2>$null
    }
    # git worktree prune: Eintraege zu schon geloeschten Ordnern entfernen
    git worktree prune
}

if ($rc -ne 0) {
    Exit-Script 1
}
Write-Host ""
Write-Host "OK - Merge Request '$title' angelegt (Branch $relBranch)." -ForegroundColor Green
Write-Host "Er wartet in GitLab auf die Genehmigung. Nach dem Merge nach $MainBranch startet"
Write-Host "der Verantwortliche den Produktions-Deploy (Pipeline, Knopf 'Play')."
Exit-Script 0
