# =============================================================================
# convert_rdf.ps1 - einen Bericht von .rdf nach .xml wandeln (rwconverter)
# =============================================================================
# Wird von checkin.ps1 fuer jeden ausgewaehlten Bericht aufgerufen - kann aber
# auch allein laufen, z.B. um eine Wandlung zu testen:
#
#   .\convert_rdf.ps1 -Check
#        nur pruefen: Administrator-Fenster, Konverter, DB-Login-Datei
#
#   .\convert_rdf.ps1 bericht
#        wandelt source\bericht.rdf -> xml\bericht.xml (vorher dieselben
#        Pruefungen). "bericht.rdf" oder ein Pfad gehen auch - es zaehlt nur
#        der Name. Die Ordner stehen fest unten in den Einstellungen.
#        Die xml-Datei heisst immer <name>.xml: so bleibt das XML stabil
#        (rwconverter setzt den internen Berichtsnamen aus dem Zieldateinamen,
#        wenn die .rdf so heisst wie der Bericht; eine umbenannte .rdf behaelt
#        ihren alten internen Namen - im Builder einmal neu speichern).
#
# Exit-Code: 0 = OK, 1 = Fehler (Meldung steht auf dem Bildschirm)
#
# Voraussetzungen:
#   - PowerShell mit "Als Administrator ausfuehren" gestartet (die
#     Reports-Werkzeuge brauchen das auf diesem Server)
#   - DB-Login fuer den Konverter, eine Zeile:
#       userid=<db user>/<kennwort>@<tns alias>   (Git_checkin.md 2.1)
#     Gesucht wird zuerst %USERPROFILE%\.rwconv\login.txt (pro Benutzer),
#     gibt es die nicht, die feste Datei aus $LoginFileFixed (Einstellungen).
#
# Ablage : E:\git\<Login>\Reports\convert_rdf.ps1 (Teil des Repositorys)
# Doku   : Git_checkin.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
# Nur ASCII - Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI.
# =============================================================================

param(
    [Parameter(Position = 0)]
    [string]$Report,
    [switch]$Check
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
# DB-Login-Datei: zuerst die persoenliche Datei des Benutzers, gibt es die
# nicht, die feste Datei - den Pfad an den Server anpassen.
$LoginFileUser  = Join-Path $env:USERPROFILE '.rwconv\login.txt'
$LoginFileFixed = 'E:\oracle\rwconv\login.txt'
$LoginFile = $LoginFileUser
if (-not (Test-Path $LoginFileUser)) {
    $LoginFile = $LoginFileFixed
}

# Ordner der Berichte - neben diesem Skript (E:\git\<Login>\Reports\...)
$SourceDir = Join-Path $PSScriptRoot 'source'
$XmlDir    = Join-Path $PSScriptRoot 'xml'
# ----------------------------------------------------------------------------

# --- 1. Pruefungen
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
    Write-Host "Bitte `$DomainHome oben in convert_rdf.ps1 pruefen." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $LoginFile)) {
    Write-Host "FEHLER: DB-Login-Datei nicht gefunden - gesucht:" -ForegroundColor Red
    Write-Host "  1. $LoginFileUser   (pro Benutzer)" -ForegroundColor Red
    Write-Host "  2. $LoginFileFixed   (fest, `$LoginFileFixed oben in convert_rdf.ps1)" -ForegroundColor Red
    Write-Host "Eine davon anlegen, eine Zeile:  userid=<db user>/<kennwort>@<tns alias>" -ForegroundColor Red
    Write-Host "(Git_checkin.md Abschnitt 2.1)" -ForegroundColor Red
    exit 1
}
if ($Check) {
    exit 0
}

# --- 2. Aufruf pruefen: nur der Name zaehlt (bericht, bericht.rdf oder Pfad)
if (-not $Report) {
    Write-Host "Aufruf: .\convert_rdf.ps1 <berichtsname>   (oder -Check)" -ForegroundColor Yellow
    exit 1
}
$name   = [IO.Path]::GetFileNameWithoutExtension($Report)
$Source = Join-Path $SourceDir "$name.rdf"
$Dest   = Join-Path $XmlDir "$name.xml"
if (-not (Test-Path $Source)) {
    Write-Host "FEHLER: Bericht nicht gefunden: $Source" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $XmlDir)) {
    New-Item -ItemType Directory -Path $XmlDir | Out-Null
}

# --- 3. Wandeln - rwconverter liest den DB-Login aus der Datei (cmdfile=),
# so steht das Kennwort nie auf der Kommandozeile.
# Start-Process leitet die Ausgabe in eine Datei um: rwconverter.exe ist ein
# Windows-Programm ohne Konsole - ein normaler Aufruf liefert PowerShell keine
# Meldung zurueck. (Die Option logfile= hilft nicht: veraltet, ohne die
# REP-Meldungen, und bei falschem Login fragt rwconverter dann interaktiv
# nach dem Kennwort - getestet 2026-11-12.)
$tempDir = [IO.Path]::GetTempPath()
$outFile = Join-Path $tempDir "convert_rdf_$name.out.txt"
$errFile = Join-Path $tempDir "convert_rdf_$name.err.txt"
$start   = (Get-Date).AddSeconds(-2)
$convArgs = @(
    "`"source=$Source`"",
    "stype=rdffile",
    "`"dest=$Dest`"",
    "dtype=xmlfile",
    "batch=yes",
    "overwrite=yes",
    "`"cmdfile=$LoginFile`""
)
$proc = Start-Process -FilePath $Converter -ArgumentList $convArgs -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile
$rc = $proc.ExitCode

# Ausgabe beider Kanaele einlesen und die Temp-Dateien wieder loeschen
$output = @()
if (Test-Path $outFile) {
    $output += Get-Content $outFile
    Remove-Item $outFile
}
if (Test-Path $errFile) {
    $output += Get-Content $errFile
    Remove-Item $errFile
}

# Erfolg = Exit-Code 0 UND die xml-Datei wurde jetzt geschrieben
# (eine alte xml-Datei von frueher zaehlt nicht)
$xmlWritten = $false
if (Test-Path $Dest) {
    $xmlWritten = ((Get-Item $Dest).LastWriteTime -ge $start)
}

if ($rc -ne 0 -or -not $xmlWritten) {
    Write-Host ""
    Write-Host "FEHLER: Wandlung von $Source fehlgeschlagen (Exit-Code $rc, xml geschrieben: $xmlWritten):" -ForegroundColor Red
    $messages = @($output | Where-Object { "$_" -match 'REP-|ORA-|canceled' })
    if ($messages.Count -gt 0) {
        $messages | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    elseif ($output.Count -gt 0) {
        $output | Where-Object { "$_".Trim() } | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    else {
        Write-Host "  rwconverter hat keine Meldung geliefert. Bericht im Reports Builder oeffnen" -ForegroundColor Red
        Write-Host "  und kompilieren - dort steht der Fehler; Login-Datei pruefen." -ForegroundColor Red
    }
    exit 1
}
exit 0
