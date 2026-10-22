# =============================================================================
# FormsWeb-Setup.ps1 - Forms client mini installer / starter (user scope)
# Installs the Forms client bundle of the Forms server into
# %LOCALAPPDATA%\FormsWeb, keeps it current and starts the Forms Standalone
# Launcher (FSAL). No administrator rights, no registry outside HKCU.
#
#   -Install    load the bundle, create desktop + start menu shortcut
#   -Start      check for updates (self-update first), then start Forms
#   -Rollback   switch back to the previous installed version
#   -Uninstall  remove %LOCALAPPDATA%\FormsWeb and the shortcuts
#   -BaseUrl    bundle URL, e.g. https://forms.company.local/formsWeb/
#               (only needed for the first -Install, then kept in state.json)
#
# Served and versioned by 09-Install/40-oracle_forms_client_bundle.sh;
# concept: 09-Install/docs/40-forms_client_distribution.md
# Pure ASCII on purpose: Windows PowerShell 5.1 reads UTF-8 files without BOM
# as ANSI.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================
param(
    [switch]$Install,
    [switch]$Start,
    [switch]$Rollback,
    [switch]$Uninstall,
    [string]$BaseUrl,
    [int]$Restarted = 0
)

$FormsWebSetupVersion = '1.0.0'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # progress bar slows downloads in PS 5.1
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 12288  # 12288 = TLS 1.3
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
[Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials

$Root      = Join-Path $env:LOCALAPPDATA 'FormsWeb'
$StateFile = Join-Path $Root 'state.json'
$MfCache   = Join-Path $Root 'manifest.json'
$LogDir    = Join-Path $Root 'logs'
$Self      = Join-Path $Root 'FormsWeb-Setup.ps1'

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function Write-Log([string]$msg) {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path (Join-Path $LogDir ('FormsWeb-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))) -Value $line
    Write-Host $line
}

function Show-Error([string]$msg) {
    Write-Log "ERROR $msg"
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($msg, 'Oracle Forms', 'OK', 'Error') | Out-Null
    } catch { }
}

function Get-Url([string]$file) { return ($script:Base.TrimEnd('/') + '/' + $file) }

function Get-Remote([string]$file, [string]$target) {
    Invoke-WebRequest -UseBasicParsing -UseDefaultCredentials -TimeoutSec 600 `
        -Uri (Get-Url $file) -OutFile $target
}

function Test-Hash([string]$path, [string]$sha256) {
    $h = (Get-FileHash -Path $path -Algorithm SHA256).Hash
    return ($h -eq $sha256)     # -eq is case-insensitive
}

function Read-State {
    if (Test-Path $StateFile) { return (Get-Content $StateFile -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{ baseUrl = ''; current = $null; previous = $null }
}

function Save-State($st) { $st | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding ASCII }

function New-Shortcuts($mf) {
    $name = $mf.start.shortcutName
    if (-not $name) { $name = 'Oracle Forms' }
    $shell = New-Object -ComObject WScript.Shell
    $targets = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) ($name + '.lnk')),
        (Join-Path ([Environment]::GetFolderPath('Programs')) ($name + '.lnk'))
    )
    foreach ($t in $targets) {
        $lnk = $shell.CreateShortcut($t)
        $lnk.TargetPath       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments        = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Self + '" -Start'
        $lnk.WorkingDirectory = $Root
        $lnk.IconLocation     = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',13'
        $lnk.Description      = 'Oracle Forms (FSAL) - checks for updates on every start'
        $lnk.Save()
    }
    Write-Log ('Shortcuts written: ' + $name)
}

function Remove-Shortcuts($mf) {
    $name = 'Oracle Forms'
    if ($mf -and $mf.start.shortcutName) { $name = $mf.start.shortcutName }
    foreach ($d in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        $p = Join-Path $d ($name + '.lnk')
        if (Test-Path $p) { Remove-Item $p -Force }
    }
}

# -----------------------------------------------------------------------------
# Manifest: online, else the cached copy (offline start)
# -----------------------------------------------------------------------------
function Get-Manifest {
    $tmp = Join-Path $env:TEMP ('formsweb-manifest-{0}.json' -f $PID)
    try {
        Get-Remote 'manifest.json' $tmp
        $mf = Get-Content $tmp -Raw | ConvertFrom-Json
        Copy-Item $tmp $MfCache -Force
        Remove-Item $tmp -Force
        $script:Online = $true
        return $mf
    } catch {
        $script:Online = $false
        Write-Log ('Server not reachable (' + $_.Exception.Message + ') - using the installed version')
        if (Test-Path $MfCache) { return (Get-Content $MfCache -Raw | ConvertFrom-Json) }
        return $null
    }
}

# -----------------------------------------------------------------------------
# Self-update: a newer setup script on the server replaces this one first
# -----------------------------------------------------------------------------
function Update-Self($mf) {
    if (-not $script:Online -or -not $mf.setup) { return }
    if ($mf.setup.version -eq $FormsWebSetupVersion) { return }
    if ($Restarted -ge 1) {
        Write-Log ('Self-update loop guard: still version ' + $FormsWebSetupVersion + ' after restart, continuing')
        return
    }
    $tmp = Join-Path $env:TEMP ('FormsWeb-Setup-{0}.ps1' -f $PID)
    Get-Remote $mf.setup.file $tmp
    if (-not (Test-Hash $tmp $mf.setup.sha256)) {
        Remove-Item $tmp -Force
        Write-Log 'Self-update: SHA-256 mismatch - kept the current script'
        return
    }
    Copy-Item $tmp $Self -Force
    Remove-Item $tmp -Force
    Write-Log ('Self-update ' + $FormsWebSetupVersion + ' -> ' + $mf.setup.version + ', restarting')
    $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $Self, '-Restarted', '1')
    if ($Install)  { $args2 += '-Install' }
    if ($Start)    { $args2 += '-Start' }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args2
    exit 0
}

# -----------------------------------------------------------------------------
# Components: download changed ones, verify, extract, switch state at the end
# -----------------------------------------------------------------------------
function Update-Components($mf, $st) {
    $cur = $st.current
    $new = [ordered]@{}
    $changed = $false
    foreach ($name in @('java', 'fsal', 'jacob')) {
        $c = $mf.components.$name
        if (-not $c) { continue }
        $old = $null
        if ($cur) { $old = $cur.$name }
        if ($old -and $old.sha256 -eq $c.sha256 -and (Test-Path $old.path)) {
            $new[$name] = $old
            continue
        }
        $changed = $true
        $tmp = Join-Path $env:TEMP ('formsweb-{0}-{1}' -f $PID, $c.file)
        Write-Log ('Download ' + $c.file + ' (' + [math]::Round($c.size / 1MB, 1) + ' MB)')
        Get-Remote $c.file $tmp
        if (-not (Test-Hash $tmp $c.sha256)) {
            Remove-Item $tmp -Force
            throw ('SHA-256 mismatch for ' + $c.file + ' - download rejected')
        }
        switch ($name) {
            'java' {
                $dir = Join-Path $Root ('java\' + $c.version + '-' + $c.sha256.Substring(0, 8))
                if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [IO.Compression.ZipFile]::ExtractToDirectory($tmp, $dir)
                Remove-Item $tmp -Force
                if (-not (Test-Path (Join-Path $dir 'bin\javaw.exe'))) { throw ('javaw.exe missing in ' + $c.file) }
                $path = $dir
            }
            default {
                $sub = Join-Path $Root $name
                if (-not (Test-Path $sub)) { New-Item -ItemType Directory -Path $sub -Force | Out-Null }
                $path = Join-Path $sub $c.file
                Move-Item $tmp $path -Force
            }
        }
        $new[$name] = [pscustomobject]@{ version = $c.version; file = $c.file; sha256 = $c.sha256; path = $path }
        Write-Log ('Installed ' + $name + ' ' + $c.version)
    }
    if ($changed) {
        $st.previous = $st.current
        $st.current  = [pscustomobject]$new
        Save-State $st
        Remove-Unused $st
    }
    return $changed
}

# keep only what current and previous reference
function Remove-Unused($st) {
    $keep = @()
    foreach ($s in @($st.current, $st.previous)) {
        if (-not $s) { continue }
        foreach ($p in $s.PSObject.Properties) { $keep += $p.Value.path }
    }
    foreach ($sub in @('java', 'fsal', 'jacob')) {
        $d = Join-Path $Root $sub
        if (-not (Test-Path $d)) { continue }
        foreach ($i in Get-ChildItem $d) {
            if ($keep -notcontains $i.FullName) {
                Remove-Item $i.FullName -Recurse -Force
                Write-Log ('Removed old ' + $i.Name)
            }
        }
    }
}

# JACOB DLL: place the verified copy where WebUtil expects it, so WebUtil
# (size check only, no hash) need not push it (assumption, client test)
function Copy-Jacob($mf, $st) {
    if (-not $st.current.jacob) { return }
    $host_ = ([Uri]$mf.server).Host
    $dir = Join-Path $env:USERPROFILE ('webutil\syslib\' + $host_)
    $dst = Join-Path $dir $st.current.jacob.file
    if ((Test-Path $dst) -and (Test-Hash $dst $st.current.jacob.sha256)) { return }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item $st.current.jacob.path $dst -Force
    Write-Log ('JACOB DLL placed: ' + $dst)
}

function Start-Forms($mf, $st) {
    if (-not $st.current -or -not $st.current.java) { throw 'Forms client not installed - run the installer first' }
    $javaw = Join-Path $st.current.java.path 'bin\javaw.exe'
    $fsal  = $st.current.fsal.path
    $al = @('-jar', ('"' + $fsal + '"'), '-url', ('"' + $mf.start.url + '"')) + @($mf.start.fsalArgs)
    Write-Log ('Start ' + $mf.start.url + ' with Java ' + $st.current.java.version)
    Start-Process -FilePath $javaw -ArgumentList $al -WorkingDirectory $Root
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
try {
    if (-not ($Install -or $Start -or $Rollback -or $Uninstall)) { $Start = $true }
    if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
    $st = Read-State

    if ($Uninstall) {
        $mf = $null
        if (Test-Path $MfCache) { $mf = Get-Content $MfCache -Raw | ConvertFrom-Json }
        Remove-Shortcuts $mf
        Set-Location $env:TEMP
        Remove-Item $Root -Recurse -Force
        Write-Host 'Forms client removed.'
        exit 0
    }

    if ($Rollback) {
        if (-not $st.previous) { throw 'No previous version to roll back to' }
        $tmp = $st.current; $st.current = $st.previous; $st.previous = $tmp
        Save-State $st
        Write-Log ('Rollback: Java ' + $st.current.java.version + ' is current again')
        exit 0
    }

    if ($BaseUrl) { $st.baseUrl = $BaseUrl }
    if (-not $st.baseUrl) { throw 'No server URL - call with -BaseUrl https://<server>/formsWeb/' }
    $script:Base = $st.baseUrl
    Save-State $st

    # this script lives in $Root (copied there by the bootstrap)
    if ($PSCommandPath -and ($PSCommandPath -ne $Self)) { Copy-Item $PSCommandPath $Self -Force }

    $mf = Get-Manifest
    if (-not $mf) { throw ('Server not reachable and no installed version: ' + $script:Base) }

    Update-Self $mf
    if ($script:Online) {
        $null = Update-Components $mf $st
        Copy-Jacob $mf $st
    }
    if ($Install) { New-Shortcuts $mf }
    if ($Start -or $Install) { Start-Forms $mf $st }
} catch {
    Show-Error $_.Exception.Message
    exit 1
}
