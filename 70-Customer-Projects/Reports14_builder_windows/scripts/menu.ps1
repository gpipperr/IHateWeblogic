# =============================================================================
# menu.ps1 - Startmenue fuer die Reports-Git-Skripte (per Doppelklick)
# =============================================================================
# Zeigt die Skripte aus menu.ini als nummerierte Liste. Der Anwender waehlt
# eine Nummer - das Skript laeuft in DIESEM Fenster, danach bleibt das
# Fenster offen (Start ueber menu.cmd mit -NoExit), damit das Ergebnis
# stehen bleibt. Fuer den naechsten Schritt: wieder Doppelklick auf das Icon.
# x = abbrechen, das Fenster schliesst sich.
#
#   ===================================
#    Oracle Reports Git Handling
#   ===================================
#
#    1 - pull.ps1     - Hole die letzten Aenderungen vom Git-Server
#    2 - status.ps1   - Zeige den aktuellen Status an
#    ...
#   -----------------------------------
#   Waehle eine Option oder breche mit x ab :
#
# Start : Doppelklick auf menu.cmd (oder eine Desktop-Verknuepfung darauf)
#         oder im PowerShell-Fenster:  .\Reports\menu.ps1
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
    # von menu.cmd gesetzt: eigenes Fenster - x schliesst es
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
$frage = 'Option waehlen oder mit x abbrechen'
$skriptPfad = ''
if ($cfg.Contains('Menue')) {
    if ($cfg['Menue']['Titel'])      { $titel = $cfg['Menue']['Titel'] }
    if ($cfg['Menue']['Frage'])      { $frage = $cfg['Menue']['Frage'] }
    if ($cfg['Menue']['SkriptPfad']) { $skriptPfad = $cfg['Menue']['SkriptPfad'] }
}

# Ordner der Skripte: SkriptPfad aus menu.ini - %VARIABLE% wird ersetzt
# (z.B. E:\git\%USERNAME%\Reports), ein relativer Pfad gilt ab dem Ordner
# von menu.ps1 (z.B. ..\Reports), leer = Ordner von menu.ps1
function Resolve-Ordner([string]$Pfad) {
    # "E:\mit Leerzeichen\Reports" - Anfuehrungszeichen weglassen
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

# --- 2. Menue anzeigen
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
Write-Host ""
Write-Host $Line -ForegroundColor Cyan
Write-Host " $titel" -ForegroundColor Cyan
Write-Host $Line -ForegroundColor Cyan
Write-Host ""
foreach ($f in $fehler) { Write-Host "WARNUNG: $(Split-Path -Leaf $Ini) $f" -ForegroundColor Yellow }
if ($items.Count -eq 0) {
    Write-Host "FEHLER: In $Ini steht kein Menuepunkt." -ForegroundColor Red
    return
}

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
Write-Host $Line2
Write-Host ""

# --- 3. Auswahl - bis eine gueltige Nummer oder x kommt
$wahl = $null
while ($null -eq $wahl) {
    $in = "$(Read-Host "$frage ")".Trim()
    if ($in -eq 'x' -or $in -eq 'X') {
        # Abbruch: eigenes Fenster (menu.cmd, -NoExit) ganz schliessen -
        # exit allein liesse dort die Eingabezeile offen. Aus einer eigenen
        # PowerShell gestartet: nur zurueck, Ihr Fenster bleibt.
        if ($Fenster) { [Environment]::Exit(0) }
        return
    }
    $nr = 0
    if ([int]::TryParse($in, [ref]$nr) -and $nr -ge 1 -and $nr -le $items.Count) {
        $wahl = $items[$nr - 1]
    }
    else {
        Write-Host "  Bitte eine Nummer von 1 bis $($items.Count) eingeben oder x." -ForegroundColor Yellow
    }
}

# --- 4. Gewaehltes Skript in diesem Fenster starten
Write-Host ""
Write-Host $Line -ForegroundColor Cyan
Write-Host " $(("$($wahl.Skript) $($wahl.Parameter)").Trim()) - $($wahl.Kurz)" -ForegroundColor Cyan
Write-Host $Line -ForegroundColor Cyan
if ($wahl.Lang -ne '') { Write-Wrapped $wahl.Lang 72 '  ' }
Write-Host ""

if (-not (Test-Path -LiteralPath $wahl.Pfad)) {
    Write-Host "FEHLER: $($wahl.Pfad) fehlt." -ForegroundColor Red
    return
}

if ($wahl.Admin) {
    # Administrator-Fenster? (die Reports-Werkzeuge brauchen das)
    $isAdmin = $false
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { }
    if (-not $isAdmin) {
        Write-Host "FEHLER: $($wahl.Skript) braucht ein Administrator-Fenster." -ForegroundColor Red
        Write-Host "        Menue mit Rechtsklick -> 'Als Administrator ausfuehren' starten" -ForegroundColor Red
        Write-Host "        (Verknuepfung -> Eigenschaften -> Erweitert -> 'Als Administrator ausfuehren')." -ForegroundColor Red
        return
    }
}

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

Write-Host ""
Write-Host $Line2
if ($rc -eq 0) {
    Write-Host " Fertig: $($wahl.Skript). Fenster bleibt offen - schliessen mit X." -ForegroundColor Green
}
else {
    Write-Host " $($wahl.Skript) mit Fehler beendet (Rueckgabe $rc) - siehe Meldungen oben." -ForegroundColor Red
}
Write-Host " Naechster Schritt: wieder Doppelklick auf das Menue-Icon."
Write-Host $Line2
