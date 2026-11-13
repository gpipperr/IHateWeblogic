# =============================================================================
# git_setup.ps1 - Git einmal pro Benutzer einrichten (global)
# =============================================================================
# Fragt Name, E-Mail-Adresse und das Zeilenende-Verhalten (CRLF) ab und setzt
# die Werte mit "git config --global" - sie gelten dann fuer alle
# Repositorys dieses Windows-Benutzers. Enter uebernimmt den angezeigten Wert.
#
#   .\git_setup.ps1
#
# Einmal pro Benutzer, vor dem ersten checkin.ps1. Kann jederzeit wieder
# aufgerufen werden, um einen Wert zu aendern.
#
# Ablage : E:\git\<Login>\oracle-report\deploy\git_setup.ps1 (Teil des Repositorys)
# Doku   : Git_checkin.md (IHateWeblogic, 14-ReportsBuilder)
# Nur ASCII - Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI.
# =============================================================================

# --- 0. Git vorhanden?
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    Write-Host "FEHLER: git nicht gefunden - Git for Windows installieren (oder PATH pruefen)." -ForegroundColor Red
    exit 1
}

# --- 1. Aktuelle Werte lesen (leer, wenn noch nicht gesetzt)
# git config --global <name>: Wert aus der globalen Git-Konfiguration lesen
#   (gilt fuer alle Repositorys dieses Windows-Benutzers, Datei
#   %USERPROFILE%\.gitconfig); leer, wenn nicht gesetzt
$curName  = git config --global user.name
$curEmail = git config --global user.email
$curCrlf  = git config --global core.autocrlf
if (-not $curCrlf) {
    # Vorschlag fuer Windows: true = im Repository LF, im Arbeitsordner CRLF
    $curCrlf = 'true'
}

Write-Host "Git einrichten fuer Windows-Benutzer $env:USERNAME (git config --global)"
Write-Host "Enter uebernimmt den Wert in [Klammern]."
Write-Host ""

# --- 2. Name - erscheint als Autor jedes Check-ins
$name = Read-Host "Ihr Name (Vorname Nachname) [$curName]"
$name = "$name".Trim()
if (-not $name) {
    $name = $curName
}
if (-not $name) {
    Write-Host "FEHLER: Kein Name angegeben - nichts geaendert." -ForegroundColor Red
    exit 1
}

# --- 3. E-Mail-Adresse - die Firmen-Adresse, wie im Git-Server hinterlegt
$email = Read-Host "Ihre E-Mail-Adresse [$curEmail]"
$email = "$email".Trim()
if (-not $email) {
    $email = $curEmail
}
if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    Write-Host "FEHLER: '$email' ist keine gueltige E-Mail-Adresse - nichts geaendert." -ForegroundColor Red
    exit 1
}

# --- 4. Zeilenende (CRLF)
Write-Host ""
Write-Host "Zeilenende-Verhalten (core.autocrlf):"
Write-Host "  true   - im Repository LF, im Arbeitsordner CRLF   (empfohlen fuer Windows)"
Write-Host "  input  - beim Einchecken CRLF -> LF, beim Auschecken nichts aendern"
Write-Host "  false  - nichts umwandeln"
Write-Host "(.rdf ist in .gitattributes als binary markiert und wird nie umgewandelt.)"
$crlf = Read-Host "core.autocrlf [$curCrlf]"
$crlf = "$crlf".Trim().ToLower()
if (-not $crlf) {
    $crlf = $curCrlf
}
if ($crlf -ne 'true' -and $crlf -ne 'input' -and $crlf -ne 'false') {
    Write-Host "FEHLER: '$crlf' - erlaubt sind true, input oder false - nichts geaendert." -ForegroundColor Red
    exit 1
}

# --- 5. Setzen
# git config --global <name> <wert>: Wert in die globale Git-Konfiguration
#   schreiben (%USERPROFILE%\.gitconfig, fuer alle Repositorys dieses Benutzers)
#   user.name / user.email : Autor jedes Check-ins
#   core.autocrlf          : Zeilenende-Umwandlung (siehe Auswahl oben)
git config --global user.name "$name"
$rcName = $LASTEXITCODE
git config --global user.email "$email"
$rcEmail = $LASTEXITCODE
git config --global core.autocrlf "$crlf"
$rcCrlf = $LASTEXITCODE
if ($rcName -ne 0 -or $rcEmail -ne 0 -or $rcCrlf -ne 0) {
    Write-Host "FEHLER: git config ist fehlgeschlagen - siehe Meldung oben." -ForegroundColor Red
    exit 1
}

# --- 6. Kontrolle - so steht es jetzt in der globalen Git-Konfiguration
Write-Host ""
Write-Host "Gesetzt (git config --global):" -ForegroundColor Green
Write-Host ("  user.name     = {0}" -f (git config --global user.name))
Write-Host ("  user.email    = {0}" -f (git config --global user.email))
Write-Host ("  core.autocrlf = {0}" -f (git config --global core.autocrlf))
exit 0
