#Requires -Version 5.1
#==============================================================================
# Script   : update_tools_from_git.ps1
# Purpose  : Update the customer tools in THIS directory from the IHateWeblogic
#            repository: download the Windows tools ZIP, show per file what is
#            installed and what is new; with -Apply replace the changed files
#            and unpack the new ones (backup first). Read-only without -Apply.
#            Windows / PowerShell version of tools/bash/update_tools_from_git.sh
#            (same output, same exit codes; no setdb part - there is no shell
#            switcher on Windows). Standalone - it may update ihw_tools_lib.ps1
#            itself, so it does not use it.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
#==============================================================================
<#
.SYNOPSIS
  Update the IHateWeblogic customer tools (Windows) from the repository.

.DESCRIPTION
  Downloads ihw_customer_tools_windows.zip (+ .sha256) from the repository,
  branch main, checks it and compares every file of its VERSIONS.txt with the
  file in the tools directory (the directory of this script):
    changed      version installed -> repository
    new          not installed yet
    local newer  the local version is newer (test host) - kept, no downgrade
  Files that are not in the ZIP (patch_env.ps1, own scripts) stay as they are.

  Certificate check: OFF for the download - customer networks often intercept
  TLS with their own CA. The SHA-256 proves a complete transfer, not the
  origin. Proxy: the system proxy (Windows PowerShell 5.1) or -Proxy URL.

  -Apply: every replaced file is saved to <tools>\backup\tools_<timestamp>\
  (the newest 3 backups are kept), then each file is written as a temp file
  and moved into place. PowerShell reads a script completely before it runs
  it, so this script can update itself.

  Exit: 0 up to date / applied, 1 updates available (read-only), 2 error.

.PARAMETER Apply
  Replace the changed files, unpack the new ones (backup first).
.PARAMETER Zip
  Offline: a ZIP copied by hand (Zip.sha256 next to it is checked when
  present) - no download.
.PARAMETER Url
  Other source (default: the repository, or $env:IHW_TOOLS_URL).
.PARAMETER Proxy
  Proxy URL for the download (e.g. http://proxy:8080), with the credentials of
  the logged-on user.
.PARAMETER Version
  Print the version and exit.

.EXAMPLE
  .\update_tools_from_git.ps1
.EXAMPLE
  .\update_tools_from_git.ps1 -Apply
.EXAMPLE
  .\update_tools_from_git.ps1 -Zip C:\temp\ihw_customer_tools_windows.zip -Apply
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $Zip = "",
    [string] $Url = $(if ($env:IHW_TOOLS_URL) { $env:IHW_TOOLS_URL } else { "https://github.com/gpipperr/IHateWeblogic/raw/main/70-Customer-Projects/tools/ihw_customer_tools_windows.zip" }),
    [string] $Proxy = "",
    [switch] $Version
)

$SCRIPT_VERSION = "2026-11-19.1"   # bump on every change
if ($Version) { Write-Output $SCRIPT_VERSION; exit 0 }
$ErrorActionPreference = 'Stop'

function Say  { param([string] $T) Write-Host "  $T" }
function Err  { param([string] $T) Write-Host "  ERROR $T" -ForegroundColor Red }
function Line { Write-Host ("  " + ("-" * 72)) }
# first VERSION = "..." / *_VERSION="..." of a file, "-" when none
function Get-Ver {
    param([string] $F)
    if (-not (Test-Path -LiteralPath $F -PathType Leaf)) { return "-" }
    $m = Select-String -LiteralPath $F -Pattern '[A-Z_]*VERSION\s*=\s*"([0-9][^"]*)"' -List -ErrorAction SilentlyContinue
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return "-"
}
function Get-Sha { param([string] $F) if (Test-Path -LiteralPath $F -PathType Leaf) { return (Get-FileHash -LiteralPath $F -Algorithm SHA256).Hash.ToLower() }; return "" }
# $true when the local version is newer than the repository one (never downgrade)
function Test-Newer {
    param([string] $L, [string] $R)
    if ($L -eq "-" -or $R -eq "-" -or -not $R -or $L -eq $R) { return $false }
    $a = @($L -split '[.\-]' | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
    $b = @($R -split '[.\-]' | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
    for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
        $x = $(if ($i -lt $a.Count) { $a[$i] } else { 0 }); $y = $(if ($i -lt $b.Count) { $b[$i] } else { 0 })
        if ($x -ne $y) { return ($x -gt $y) }
    }
    return $false
}
# download without certificate check (PS 7: -SkipCertificateCheck, 5.1: callback)
function Get-Download {
    param([string] $From, [string] $To)
    $a = @{ Uri = $From; OutFile = $To; UseBasicParsing = $true; TimeoutSec = 300 }
    if ($Proxy) { $a.Proxy = $Proxy; $a.ProxyUseDefaultCredentials = $true }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $a.SkipCertificateCheck = $true }
    else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest @a } finally { $ProgressPreference = $pp }
}

$TOOLS = $PSScriptRoot
$WORK = Join-Path ([IO.Path]::GetTempPath()) ("ihw_update_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $WORK -Force | Out-Null
$script:rc = 0
function Invoke-IhwUpdate {
    Say "update_tools_from_git.ps1 $SCRIPT_VERSION"
    Say "tools directory : $TOOLS"

    #==========================================================================
    # 1. get the ZIP
    #==========================================================================
    $Z = Join-Path $WORK "tools.zip"
    if ($Zip) {
        if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { Err "ZIP not readable: $Zip"; $script:rc = 2; return }
        Copy-Item -LiteralPath $Zip -Destination $Z
        if (Test-Path -LiteralPath "$Zip.sha256") { Copy-Item -LiteralPath "$Zip.sha256" -Destination "$Z.sha256" }
        Say "source          : $Zip (offline)"
    } else {
        Say "source          : $Url"
        Say "                  (certificate check off - TLS interception in customer networks;"
        Say "                   the SHA-256 proves a complete transfer, not the origin)"
        try { Get-Download $Url $Z } catch { Err "download failed: $($_.Exception.Message) - proxy? -Proxy URL, or -Zip FILE"; $script:rc = 2; return }
        try { Get-Download "$Url.sha256" "$Z.sha256" } catch { Remove-Item -LiteralPath "$Z.sha256" -ErrorAction SilentlyContinue }
    }

    #==========================================================================
    # 2. check
    #==========================================================================
    if ((Test-Path -LiteralPath "$Z.sha256") -and (Get-Item -LiteralPath "$Z.sha256").Length -gt 0) {
        $want = ((Get-Content -LiteralPath "$Z.sha256" -TotalCount 1) -split '\s+')[0].ToLower()
        if ((Get-Sha $Z) -eq $want) { Say "SHA-256         : OK ($want)" }
        else { Err "SHA-256 of the ZIP does not match its .sha256 - download broken, nothing changed"; $script:rc = 2; return }
    } else { Say "SHA-256         : no .sha256 - not checked" }
    $NEWROOT = Join-Path $WORK "new"
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [IO.Compression.ZipFile]::ExtractToDirectory($Z, $NEWROOT)
    } catch { Err "ZIP broken / not unpacked: $($_.Exception.Message) - nothing changed"; $script:rc = 2; return }
    $NEW = Join-Path $NEWROOT "tools"
    $VF = Join-Path $NEW "VERSIONS.txt"
    if (-not (Test-Path -LiteralPath $VF)) { Err "no tools/VERSIONS.txt in the ZIP - not a tools ZIP"; $script:rc = 2; return }

    #==========================================================================
    # 3. compare
    #==========================================================================
    $todo = New-Object System.Collections.Generic.List[string]
    $nChg = 0; $nNew = 0; $nSame = 0
    $inZip = New-Object System.Collections.Generic.List[string]
    Line
    Write-Host ("  {0,-40} {1,-11} {2}" -f "file", "status", "version installed -> repository")
    Line
    foreach ($l in Get-Content -LiteralPath $VF) {
        if (-not $l -or $l.StartsWith('#')) { continue }
        $p = $l -split ';'; $f = $p[0]; $v = $(if ($p.Count -gt 1 -and $p[1]) { $p[1] } else { Get-Ver (Join-Path $NEW $f) }); $s = $(if ($p.Count -gt 2) { $p[2].ToLower() } else { "" })
        $inZip.Add($f)
        $loc = Join-Path $TOOLS $f
        if (-not (Test-Path -LiteralPath $loc -PathType Leaf)) {
            Write-Host ("  {0,-40} {1,-11} {2}" -f $f, "new", "- -> $v"); $nNew++; $todo.Add($f)
        } elseif ((Get-Sha $loc) -eq $s) {
            $nSame++
        } elseif (Test-Newer (Get-Ver $loc) $v) {
            Write-Host ("  {0,-40} {1,-11} {2}" -f $f, "local newer", "$(Get-Ver $loc) -> $v (kept, no downgrade)"); $nSame++
        } else {
            Write-Host ("  {0,-40} {1,-11} {2}" -f $f, "changed", "$(Get-Ver $loc) -> $v"); $nChg++; $todo.Add($f)
        }
    }
    if (($nChg + $nNew) -eq 0) { Say "all $nSame tool files are current" }
    if ((Get-Sha (Join-Path $TOOLS "VERSIONS.txt")) -ne (Get-Sha $VF)) { $todo.Add("VERSIONS.txt") }
    $base = (Resolve-Path -LiteralPath $TOOLS).Path.TrimEnd('\', '/')
    $local = @(Get-ChildItem -LiteralPath $TOOLS -Recurse -File -ErrorAction SilentlyContinue |
               ForEach-Object { $_.FullName.Substring($base.Length + 1) -replace '\\', '/' } |
               Where-Object { $_ -notlike 'backup/*' -and $_ -ne 'VERSIONS.txt' -and -not $inZip.Contains($_) } | Sort-Object)
    if ($local.Count) { Say "local only (unchanged): $($local -join ' ')" }
    Line
    Say ("summary: {0} changed, {1} new, {2} current" -f $nChg, $nNew, $nSame)

    if (-not $Apply) {
        if (($nChg + $nNew) -gt 0) {
            Say "-> update with: $PSCommandPath -Apply$(if ($Zip) { " -Zip $Zip" })"
            $script:rc = 1; return
        }
        Say "nothing to do"; $script:rc = 0; return
    }

    #==========================================================================
    # 4. apply
    #==========================================================================
    if ($todo.Count -eq 0) { Say "nothing to do"; $script:rc = 0; return }
    $BK = Join-Path (Join-Path $TOOLS "backup") ("tools_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $BK -Force | Out-Null
    foreach ($f in $todo) {
        try {
            $src = Join-Path $NEW $f; $dst = Join-Path $TOOLS $f
            $dd = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
            if (Test-Path -LiteralPath $dst) {
                $bd = Split-Path -Parent (Join-Path $BK $f)
                if (-not (Test-Path -LiteralPath $bd)) { New-Item -ItemType Directory -Path $bd -Force | Out-Null }
                Copy-Item -LiteralPath $dst -Destination (Join-Path $BK $f) -Force
            }
            $tmp = Join-Path $dd (".{0}.new.{1}" -f (Split-Path -Leaf $dst), $PID)
            Copy-Item -LiteralPath $src -Destination $tmp -Force
            Move-Item -LiteralPath $tmp -Destination $dst -Force
            Say "OK    $f"
        } catch { Err "$f not written: $($_.Exception.Message)"; $script:rc = 2 }
    }
    # keep the newest 3 backups
    @(Get-ChildItem -LiteralPath (Join-Path $TOOLS "backup") -Directory -Filter 'tools_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip 3) |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    Line
    Say "backup          : $BK"
    Say "collect_fmw_env : $(Get-Ver (Join-Path $TOOLS 'collect_fmw_env.ps1'))"
    if ($script:rc -ne 0) { Err "not every file was written - see above (backup: $BK)"; return }
    Say "Tools aktualisiert. Neue Skripte aus dem ZIP tragen keine Download-Markierung;"
    Say "blockiert die ExecutionPolicy trotzdem: Get-ChildItem $(Join-Path $TOOLS '*.ps1') | Unblock-File"
}
try { Invoke-IhwUpdate }
catch { Err "$($_.Exception.Message)"; $script:rc = 2 }
finally { Remove-Item -LiteralPath $WORK -Recurse -Force -ErrorAction SilentlyContinue }
exit $script:rc
