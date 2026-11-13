# =============================================================================
# menu.ps1 - Startmenue fuer die Reports-Git-Skripte (per Doppelklick)
# =============================================================================
# Zeigt die Skripte aus menu.ini als nummerierte Liste. Der Anwender waehlt
# eine Nummer - das Skript laeuft in DIESEM Fenster, danach erscheint das
# Menue darunter wieder (die Ausgabe des Skripts bleibt oben stehen, zurueck-
# scrollen). c = Bildschirm loeschen und Menue neu anzeigen. x oder q =
# beenden, das eigene Fenster (menu.cmd) schliesst sich. m + Enter startet
# das Menue in einem offenen Fenster neu (z.B. nach Strg+C).
#
#   ===================================
#    Oracle Reports Git Handling
#   ===================================
#
#    1 - pull.ps1     - Hole die letzten Aenderungen vom Git-Server
#    2 - status.ps1   - Zeige den aktuellen Status an
#    ...
#    c = Bildschirm loeschen und Menue neu anzeigen   x / q = beenden
#   -----------------------------------
#   Waehle eine Option oder breche mit x / q ab :
#
# Start : Doppelklick auf menu.cmd (oder eine Desktop-Verknuepfung darauf)
#         oder im PowerShell-Fenster:  .\menu.ps1 (oberster Ordner des
#         Repositorys, Skripte in deploy - SkriptPfad in menu.ini)
# Inhalt: menu.ini im selben Ordner - Skript, Kurz- und Langtext,
#         Sortierung, Parameter, Admin, SkriptPfad (Beschreibung in menu.ini)
#         SkriptPfad = Ordner der Skripte, wenn sie nicht neben menu.ps1
#         liegen - fuer alle in [Menue] oder je Eintrag
#
# Doku   : Git_checkin.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
# Nur ASCII - Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI.
# Umlaute stehen nur in menu.ini (UTF-8).
# =============================================================================

param(
    # andere Menue-Datei (Standard: menu.ini neben diesem Skript)
    [string]$Ini = '',
    # von menu.cmd gesetzt: eigenes Fenster - x / q schliesst es
    [switch]$Fenster,
    # von menu.cmd gesetzt: Fensterhoehe in Zeilen / Breite in Zeichen
    # (0 = nicht aendern)
    [int]$Zeilen = 0,
    [int]$Spalten = 0
)

# Umlaute: Ausgaben von git als UTF-8 lesen (wie in den anderen Skripten)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Line  = '=' * 60
$Line2 = '-' * 60

if ($Ini -eq '') { $Ini = Join-Path $PSScriptRoot 'menu.ini' }

# Kurzbefehl m: das Menue in diesem Fenster erneut starten (statt neuem
# Doppelklick). global: = bleibt nach dem Ende des Skripts in der offenen
# PowerShell-Sitzung erhalten. Gleiche Menue-Datei, gleiches -Fenster,
# Fenstergroesse nicht noch einmal setzen.
$mAufruf = "& '$($PSCommandPath.Replace("'", "''"))' -Ini '$($Ini.Replace("'", "''"))'"
if ($Fenster) { $mAufruf += ' -Fenster' }
Set-Item -Path function:global:m -Value ([scriptblock]::Create($mAufruf))

# Kurzbefehle x und q: das eigene Fenster (menu.cmd) schliessen - nach dem
# Skript reicht x + Enter statt Klick auf das X. Nur im eigenen Fenster, eine
# selbst geoeffnete PowerShell bleibt davon unberuehrt.
if ($Fenster) {
    Set-Item -Path function:global:x -Value { [Environment]::Exit(0) }
    Set-Item -Path function:global:q -Value { [Environment]::Exit(0) }
}

# --- 1. menu.ini lesen
# Einfaches INI-Format: [abschnitt], schluessel = wert, ; oder # = Kommentar
function Read-Ini([string]$Path) {
    $data = [ordered]@{}
    $sec  = $null
    # -Encoding UTF8: Umlaute richtig - Windows PowerShell 5.1 liest sonst ANSI
    foreach ($l in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $t = $l.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $sec = $Matches[1].Trim()
            if (-not $data.Contains($sec)) { $data[$sec] = @{} }
            continue
        }
        $i = $t.IndexOf('=')
        if ($i -gt 0 -and $null -ne $sec) {
            $data[$sec][$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
        }
    }
    return $data
}

# Langen Text auf mehrere Zeilen umbrechen (an Leerzeichen)
function Write-Wrapped([string]$Text, [int]$Width, [string]$Indent) {
    $cur = ''
    foreach ($word in ($Text -split '\s+')) {
        if (-not $word) { continue }
        if ($cur -eq '') { $cur = $word }
        elseif (($cur.Length + 1 + $word.Length) -le $Width) { $cur += " $word" }
        else { Write-Host "$Indent$cur"; $cur = $word }
    }
    if ($cur -ne '') { Write-Host "$Indent$cur" }
}

if (-not (Test-Path -LiteralPath $Ini)) {
    Write-Host "FEHLER: Menue-Datei $Ini fehlt." -ForegroundColor Red
    return
}
$cfg = Read-Ini $Ini

$titel = 'Oracle Reports Git Handling'
$frage = 'Option waehlen oder mit x / q abbrechen'
$skriptPfad = ''
if ($cfg.Contains('Menue')) {
    if ($cfg['Menue']['Titel'])      { $titel = $cfg['Menue']['Titel'] }
    if ($cfg['Menue']['Frage'])      { $frage = $cfg['Menue']['Frage'] }
    if ($cfg['Menue']['SkriptPfad']) { $skriptPfad = $cfg['Menue']['SkriptPfad'] }
}

# Ordner der Skripte: SkriptPfad aus menu.ini - %VARIABLE% wird ersetzt
# (z.B. E:\git\%USERNAME%\oracle-report\deploy), ein relativer Pfad gilt ab dem Ordner
# von menu.ps1 (z.B. deploy), leer = Ordner von menu.ps1
function Resolve-Ordner([string]$Pfad) {
    # "E:\mit Leerzeichen\deploy" - Anfuehrungszeichen weglassen
    $Pfad = $Pfad.Trim().Trim('"', "'").Trim()
    if ($Pfad -eq '') { return $PSScriptRoot }
    $Pfad = [Environment]::ExpandEnvironmentVariables($Pfad)
    if (-not [IO.Path]::IsPathRooted($Pfad)) { $Pfad = Join-Path $PSScriptRoot $Pfad }
    return [IO.Path]::GetFullPath($Pfad)
}

# Menuepunkte: alle Abschnitte ausser [Menue] mit Skript, nach Sortierung
$items = New-Object System.Collections.ArrayList
$fehler = @()
foreach ($name in $cfg.Keys) {
    if ($name -eq 'Menue') { continue }
    $e = $cfg[$name]
    if (-not $e['Skript']) { $fehler += "[$name]: Skript fehlt"; continue }
    $sort = 0
    if (-not [int]::TryParse("$($e['Sortierung'])", [ref]$sort)) { $sort = 9999 }
    $kurz = $e['Kurz']
    if (-not $kurz) { $kurz = $e['Skript'] }
    # SkriptPfad im Eintrag geht vor SkriptPfad in [Menue]
    $ordner = $skriptPfad
    if ($e['SkriptPfad']) { $ordner = $e['SkriptPfad'] }
    [void]$items.Add([pscustomobject]@{
        Name = $name; Sort = $sort; Skript = $e['Skript']; Parameter = "$($e['Parameter'])"
        Kurz = $kurz; Lang = "$($e['Lang'])"; Admin = ("$($e['Admin'])" -match '^(ja|yes|true|1)$')
        Pfad = Join-Path (Resolve-Ordner $ordner) $e['Skript'] })
}
$items = @($items | Sort-Object Sort, Name)

# Administrator-Fenster? (die Reports-Werkzeuge brauchen das)
function Test-Admin {
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

# --- 2. Fenster vorbereiten (einmal)
try { $Host.UI.RawUI.WindowTitle = $titel } catch { }

# Fenstergroesse aus menu.cmd setzen - Puffer (Zurueckscrollen) 3000 Zeilen.
# Das Fenster darf nie groesser als der Puffer sein, daher die Reihenfolge.
# Klappt nur im klassischen Konsolenfenster; Windows Terminal und andere
# Umgebungen lehnen es ab - dann bleibt die Groesse einfach, wie sie ist.
if ($Zeilen -gt 0 -or $Spalten -gt 0) {
    try {
        $raw = $Host.UI.RawUI
        $max = $raw.MaxPhysicalWindowSize
        $win = $raw.WindowSize
        $h = $win.Height
        $w = $win.Width
        if ($Zeilen -gt 0)  { $h = [Math]::Min($Zeilen, $max.Height) }
        if ($Spalten -gt 0) { $w = [Math]::Min($Spalten, $max.Width) }
        $bufH = [Math]::Max($raw.BufferSize.Height, 3000)
        if ($w -gt $raw.BufferSize.Width) {
            $raw.BufferSize = New-Object Management.Automation.Host.Size($w, $bufH)
            $raw.WindowSize = New-Object Management.Automation.Host.Size($w, $h)
        }
        else {
            $raw.BufferSize = New-Object Management.Automation.Host.Size($raw.BufferSize.Width, $bufH)
            $raw.WindowSize = New-Object Management.Automation.Host.Size($w, $h)
            $raw.BufferSize = New-Object Management.Automation.Host.Size($w, $bufH)
        }
    }
    catch { }
}

foreach ($f in $fehler) { Write-Host "WARNUNG: $(Split-Path -Leaf $Ini) $f" -ForegroundColor Yellow }
if ($items.Count -eq 0) {
    Write-Host "FEHLER: In $Ini steht kein Menuepunkt." -ForegroundColor Red
    return
}

# Menue ausgeben - nach jedem Skript erneut (unter dessen Ausgabe) und mit c
# auf einem frisch geloeschten Bildschirm
function Show-Menu {
    Write-Host ""
    Write-Host $Line -ForegroundColor Cyan
    Write-Host " $titel" -ForegroundColor Cyan
    Write-Host $Line -ForegroundColor Cyan
    Write-Host ""
    $wS = ($items | ForEach-Object { ("$($_.Skript) $($_.Parameter)").Trim().Length } | Measure-Object -Maximum).Maximum
    $wN = "$($items.Count)".Length
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $aufruf = ("$($it.Skript) $($it.Parameter)").Trim()
        $kurz  = $it.Kurz
        $color = 'White'
        if (-not (Test-Path -LiteralPath $it.Pfad)) { $color = 'Red'; $kurz = "$kurz (Skript fehlt)" }
        Write-Host (" {0} - {1} - {2}" -f "$($i + 1)".PadLeft($wN), $aufruf.PadRight($wS), $kurz) -ForegroundColor $color
    }
    # Fehlende Skripte: wo gesucht wurde - SkriptPfad in menu.ini pruefen oder
    # das Skript dorthin kopieren (pull.ps1)
    $fehlen = @($items | Where-Object { -not (Test-Path -LiteralPath $_.Pfad) })
    if ($fehlen.Count -gt 0) {
        Write-Host ""
        foreach ($it in $fehlen) { Write-Host "  Skript fehlt: $($it.Pfad)" -ForegroundColor Red }
        Write-Host "  -> SkriptPfad in $(Split-Path -Leaf $Ini) pruefen ($Ini)" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host " c = Bildschirm loeschen und Menue neu anzeigen   x / q = beenden" -ForegroundColor DarkGray
    Write-Host $Line2
    Write-Host ""
}

# --- 3. Schleife: Menue - Auswahl - Skript - Menue ... bis x / q
Show-Menu
while ($true) {
    $in = "$(Read-Host "$frage ")".Trim()

    # -in vergleicht ohne Unterschied gross/klein: x X q Q
    if ($in -in @('x', 'q')) {
        # Abbruch: eigenes Fenster (menu.cmd, -NoExit) ganz schliessen -
        # exit allein liesse dort die Eingabezeile offen. Aus einer eigenen
        # PowerShell gestartet: nur zurueck, Ihr Fenster bleibt.
        if ($Fenster) { [Environment]::Exit(0) }
        return
    }

    # c: Bildschirm loeschen, Menue neu schreiben
    if ($in -eq 'c') {
        Clear-Host
        Show-Menu
        continue
    }

    $nr = 0
    if (-not ([int]::TryParse($in, [ref]$nr) -and $nr -ge 1 -and $nr -le $items.Count)) {
        Write-Host "  Bitte eine Nummer von 1 bis $($items.Count) eingeben, c oder x / q." -ForegroundColor Yellow
        continue
    }
    $wahl = $items[$nr - 1]

    # --- 4. Gewaehltes Skript in diesem Fenster starten
    Write-Host ""
    Write-Host $Line -ForegroundColor Cyan
    Write-Host " $(("$($wahl.Skript) $($wahl.Parameter)").Trim()) - $($wahl.Kurz)" -ForegroundColor Cyan
    Write-Host $Line -ForegroundColor Cyan
    if ($wahl.Lang -ne '') { Write-Wrapped $wahl.Lang 72 '  ' }
    Write-Host ""

    $rc = 0
    if (-not (Test-Path -LiteralPath $wahl.Pfad)) {
        Write-Host "FEHLER: $($wahl.Pfad) fehlt." -ForegroundColor Red
        $rc = 1
    }
    elseif ($wahl.Admin -and -not (Test-Admin)) {
        Write-Host "FEHLER: $($wahl.Skript) braucht ein Administrator-Fenster." -ForegroundColor Red
        Write-Host "        Menue mit Rechtsklick -> 'Als Administrator ausfuehren' starten" -ForegroundColor Red
        Write-Host "        (Verknuepfung -> Eigenschaften -> Erweitert -> 'Als Administrator ausfuehren')." -ForegroundColor Red
        $rc = 1
    }
    else {
        # Skript mit den Parametern aus menu.ini aufrufen: & 'pfad' <parameter>
        # (exit im Skript beendet nur das Skript, nicht dieses Fenster)
        $global:LASTEXITCODE = 0
        try {
            & ([scriptblock]::Create("& '$($wahl.Pfad.Replace("'", "''"))' $($wahl.Parameter)"))
            $rc = $global:LASTEXITCODE
        }
        catch {
            Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
            $rc = 1
        }
        # die Skripte springen am Ende in ihren eigenen Ordner - zurueck
        Set-Location $PSScriptRoot
    }

    Write-Host ""
    Write-Host $Line2
    if ($rc -eq 0) {
        Write-Host " Fertig: $($wahl.Skript)." -ForegroundColor Green
    }
    else {
        Write-Host " $($wahl.Skript) mit Fehler beendet (Rueckgabe $rc) - siehe Meldungen oben." -ForegroundColor Red
    }
    # Menue wieder darunter - die Ausgabe des Skripts bleibt oben stehen
    # (zurueckscrollen), c loescht den Bildschirm
    Show-Menu
}
