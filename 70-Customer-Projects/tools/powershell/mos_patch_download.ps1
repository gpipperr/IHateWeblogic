#Requires -Version 5.1
#==============================================================================
# Script   : mos_patch_download.ps1
# Purpose  : Download a list of My Oracle Support patches (CSV) in one run with
#            getMOSPatch.jar - the right platform and file per patch, a check
#            of every ZIP (CRC of every entry, SHA-256) and a summary.
#            Windows / PowerShell version of tools/bash/mos_patch_download.sh
#            (same CSV format, same directory layout, same exit codes).
#            Standalone - no library; needs Java (11+ for the password runner).
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
#==============================================================================
<#
.SYNOPSIS
  CSV-driven download of My Oracle Support patches with getMOSPatch.jar.

.DESCRIPTION
  Reads the patch list (CSV: patch;platform;file_regexp;required;step;
  description[;dir[;sha256]]), downloads every selected patch into
  <Dir>\<dir>\ (default <dir> = patch number) and checks each ZIP.

  Without -Apply only the plan is shown.

  The MOS password is asked once (hidden) and handed to getMOSPatch through
  GetMOSPatchRunner.java over stdin - never on a process command line, never
  stored, masked in the output. The runner needs Java 11 or newer (single-file
  source launch). With an older Java (FMW 12c: JDK 8) getMOSPatch is started
  directly and asks for user / password itself for every patch.

  CSV column sha256 is a SOFT check (WARN): Oracle re-releases patches under
  the same number. The ZIP check (CRC of every entry) is the hard check.

  Exit: 0 = all required patches present, 1 = optional missing or SHA-256
  differs from the list, 2 = required missing / error.

.PARAMETER Csv
  Patch list, e.g. ..\..\Reports14_Only_manuall_install\patches_cpu_oct2026.csv

.PARAMETER Dir
  Target directory, one sub-directory per patch.

.PARAMETER Jar
  getMOSPatch.jar (default: .\getMOSPatch.jar, <Dir>\getMOSPatch.jar, script directory).

.PARAMETER User
  MOS user (e-mail). Default: $env:MOS_USER, else asked.

.PARAMETER All
  Also the rows with required=optional.

.PARAMETER Only
  Only these patch numbers (comma separated).

.PARAMETER Steps
  Only rows with these values in column "step" (optional rows included).

.PARAMETER Java
  java.exe to use (default: $env:JAVA_HOME\bin\java.exe, java in PATH).

.PARAMETER Proxy
  HTTPS proxy host:port for getMOSPatch. Default: $env:HTTPS_PROXY.

.PARAMETER PasswordStdin
  Read the MOS password from stdin (first line) instead of asking.

.PARAMETER Apply
  Download (default: plan only).

.EXAMPLE
  .\mos_patch_download.ps1 -Csv patches_cpu_oct2026.csv -Dir D:\install\cpu_okt2026\zip -All

.EXAMPLE
  .\mos_patch_download.ps1 -Csv patches_cpu_oct2026.csv -Dir D:\install\cpu_okt2026\zip -All -Apply -Java D:\Oracle\jdk-21\bin\java.exe

.NOTES
  ExecutionPolicy: powershell.exe -ExecutionPolicy Bypass -File .\mos_patch_download.ps1 ...
  Doc: 70-Customer-Projects/tools/powershell/README.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Csv,
    [Parameter(Mandatory = $true)] [string] $Dir,
    [string] $Jar = "",
    [string] $User = $env:MOS_USER,
    [switch] $All,
    [string[]] $Only = @(),
    [string[]] $Steps = @(),
    [string] $Java = "",
    [string] $Proxy = "",
    [switch] $PasswordStdin,
    [switch] $Apply,
    [switch] $Version
)

Set-StrictMode -Version 2
$SCRIPT_VERSION = "2026-11-03.1"   # bump on every change
if ($Version) { Write-Output $SCRIPT_VERSION; exit 0 }

$LANG_CODE = "4L"
$RETRIES   = 3
$script:n_ok = 0; $script:n_warn = 0; $script:n_fail = 0

#------------------------------------------------------------------------------
# Output helpers (console + log)
#------------------------------------------------------------------------------
function local-log    { param([string] $Text) if ($script:log_file) { Add-Content -Path $script:log_file -Value $Text -Encoding UTF8 } }
function local-print  { param([string] $Text) Write-Host $Text; local-log $Text }
function local-ok     { param([string] $Text) $script:n_ok++;   Write-Host "  OK   " -ForegroundColor Green -NoNewline;  Write-Host $Text; local-log "  OK   $Text" }
function local-warn   { param([string] $Text) $script:n_warn++; Write-Host " WARN  " -ForegroundColor Yellow -NoNewline; Write-Host $Text; local-log " WARN  $Text" }
function local-fail   { param([string] $Text) $script:n_fail++; Write-Host " FAIL  " -ForegroundColor Red -NoNewline;    Write-Host $Text; local-log " FAIL  $Text" }
function local-info   { param([string] $Text) local-print ("       " + $Text) }
function local-section{ param([string] $Text) local-print ""; local-print "=== $Text ===" }

# java -version -> major version (8, 11, 17, 21 ...); 0 = not runnable
function local-java-major {
    param([string] $JavaExe)
    try {
        $v = (& $JavaExe -version 2>&1 | Out-String)
    } catch { return 0 }
    if ($v -match 'version "1\.(\d+)') { return [int]$Matches[1] }
    if ($v -match 'version "(\d+)')    { return [int]$Matches[1] }
    return 0
}

# Quote one argument for ProcessStartInfo.Arguments (Windows rules)
function local-quote {
    param([string] $Arg)
    if ($Arg -notmatch '[\s"]') { return $Arg }
    return '"' + ($Arg -replace '"', '\"') + '"'
}

# Is a ZIP of this patch already in <Dir>\<sub>\ ?
function local-have {
    param([string] $Nr, [string] $Re, [string] $Sub)
    $d = Join-Path $script:dir_abs $Sub
    if (-not (Test-Path -LiteralPath $d)) { return $null }
    foreach ($f in Get-ChildItem -LiteralPath $d -Filter *.zip -File -ErrorAction SilentlyContinue) {
        if ($Re) { if ([regex]::IsMatch($f.Name, "^(?:$Re)$")) { return $f } }
        elseif ($f.Name -like "p${Nr}_*") { return $f }
    }
    return $null
}

#------------------------------------------------------------------------------
# Start
#------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Csv -PathType Leaf)) { Write-Host "CSV not found: $Csv" -ForegroundColor Red; exit 2 }
try {
    New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null
} catch { Write-Host "Cannot create $Dir : $_" -ForegroundColor Red; exit 2 }
$script:dir_abs = (Resolve-Path -LiteralPath $Dir).ProviderPath
$script_dir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$runner         = Join-Path $script_dir "GetMOSPatchRunner.java"
$script:log_file = Join-Path $script:dir_abs ("mos_patch_download_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

local-print ("mos_patch_download.ps1 {0} - {1} - {2}" -f $SCRIPT_VERSION, (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), [Environment]::MachineName)
local-print "CSV : $Csv"
local-print "Dir : $script:dir_abs"
if ($Apply) { local-print "Mode: APPLY (download)" } else { local-print "Mode: plan only (use -Apply to download)" }

#==============================================================================
# 1. Prerequisites
#==============================================================================
local-section "1. Prerequisites"
$java_exe = $Java
if (-not $java_exe) {
    foreach ($c in @( $(if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME "bin\java.exe" }),
                      $(if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME "bin/java" }) )) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $java_exe = $c; break }
    }
}
if (-not $java_exe) {
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) { $java_exe = $cmd.Source }
}
$java_major = 0
if ($java_exe) { $java_major = local-java-major $java_exe }
if ($java_major -gt 0) {
    local-ok "Java: $java_exe (major version $java_major)"
} else {
    local-fail "No Java found - set JAVA_HOME or use -Java"
}
$use_runner = ($java_major -ge 11) -and (Test-Path -LiteralPath $runner -PathType Leaf)
if ($use_runner) {
    local-ok "Password runner: $runner (MOS password asked once, never on a command line)"
} elseif ($java_major -gt 0) {
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        local-warn "GetMOSPatchRunner.java missing next to the script - getMOSPatch asks for user / password for every patch"
    } else {
        local-warn "Java $java_major < 11 - no runner; getMOSPatch asks for user / password for every patch (use -Java <JDK 11+>)"
    }
}

if (-not $Jar) {
    foreach ($c in @((Join-Path (Get-Location).ProviderPath "getMOSPatch.jar"),
                     (Join-Path $script:dir_abs "getMOSPatch.jar"),
                     (Join-Path $script_dir "getMOSPatch.jar"))) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { $Jar = $c; break }
    }
}
if ($Jar -and (Test-Path -LiteralPath $Jar -PathType Leaf)) {
    $Jar = (Resolve-Path -LiteralPath $Jar).ProviderPath
    local-ok "getMOSPatch: $Jar"
} else {
    local-fail "getMOSPatch.jar not found (-Jar, .\, $script:dir_abs, $script_dir) - see tools/README.md"
}

try {
    $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($script:dir_abs))
    $free_gb = [math]::Floor($drive.AvailableFreeSpace / 1GB)
    if ($free_gb -lt 15) { local-warn "Free space on $($drive.Name): $free_gb GB (recommended >= 15 GB for a CPU set)" }
    else                 { local-ok   "Free space on $($drive.Name): $free_gb GB" }
} catch { local-warn "Free space not readable: $_" }

$java_opts = @()
if (-not $Proxy -and $env:HTTPS_PROXY) { $Proxy = $env:HTTPS_PROXY }
if ($Proxy) {
    $p = $Proxy -replace '^[a-zA-Z]+://', '' -replace '^[^@]*@', '' -replace '/.*$', ''
    $ph = $p; $pp = "80"
    if ($p -match '^(.+):(\d+)$') { $ph = $Matches[1]; $pp = $Matches[2] }
    $java_opts = @("-Dhttps.proxyHost=$ph", "-Dhttps.proxyPort=$pp", "-Dhttp.proxyHost=$ph", "-Dhttp.proxyPort=$pp")
    local-info "HTTPS proxy: ${ph}:$pp"
}
if ($script:n_fail -gt 0) { local-print ""; local-print "Prerequisites missing - nothing downloaded"; exit 2 }

#==============================================================================
# 2. Read the CSV
#==============================================================================
local-section "2. Patch list"
# -Only 1,2 arrives as an array, -Only "1,2" as one string - accept both
$only_list  = @($Only  | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
$steps_list = @($Steps | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
$rows = New-Object System.Collections.ArrayList
foreach ($line in Get-Content -LiteralPath $Csv) {
    $line = $line.TrimEnd("`r")
    if ($line -eq "" -or $line.StartsWith("#") -or $line.StartsWith("patch;")) { continue }
    # more than 8 columns = a ";" inside a field - columns would shift
    $f = $line.Split(';')
    if ($f.Count -gt 8) { local-fail "skipped line (more than 8 columns - ';' in a field?): $line"; continue }
    while ($f.Count -lt 8) { $f += "" }
    $r = [pscustomobject]@{
        Nr = $f[0].Trim(); Plat = $f[1].Trim(); Re = $f[2].Trim(); Req = $f[3].Trim()
        Step = $f[4].Trim(); Desc = $f[5].Trim(); Sub = $f[6].Trim(); Sha = $f[7].Trim()
    }
    if ($r.Nr -notmatch '^\d+$') { local-warn "skipped line (no patch number): $line"; continue }
    if (-not $r.Req) { $r.Req = "yes" }
    if (-not $r.Sub) { $r.Sub = $r.Nr }
    if ($only_list.Count  -gt 0 -and ($only_list  -notcontains $r.Nr))   { continue }
    if ($steps_list.Count -gt 0 -and ($steps_list -notcontains $r.Step)) { continue }
    if ($r.Req -ne "yes" -and -not $All -and $only_list.Count -eq 0 -and $steps_list.Count -eq 0) {
        local-info ("{0,-10} optional - skipped (use -All)  {1}" -f $r.Nr, $r.Desc); continue
    }
    [void]$rows.Add($r)
    local-info ("{0,-10} {1,-11} step {2,-10} {3,-9} {4}" -f $r.Nr, $r.Plat, $(if ($r.Step) { $r.Step } else { "-" }), $r.Req, $r.Desc)
}
if ($rows.Count -eq 0) { local-fail "no patch selected"; exit 2 }
local-info "$($rows.Count) patch(es) selected"

if (-not $Apply) {
    local-section "Plan"
    foreach ($r in $rows) {
        if (local-have $r.Nr $r.Re $r.Sub) { local-info ("{0,-10} present - will be skipped  {1}" -f $r.Nr, $r.Sub) }
        else { local-info ("{0,-10} download  platform {1,-11} file {2} -> {3}" -f $r.Nr, $r.Plat, $(if ($r.Re) { $r.Re } else { "<all>" }), $r.Sub) }
    }
    local-print ""; local-print "Plan only - start with -Apply (MOS user + password are asked once)"
    exit 0
}

#==============================================================================
# 3. Download
#==============================================================================
local-section "3. Download"
$mos_pwd = ""
if ($PasswordStdin) {
    if (-not $User) { local-fail "-PasswordStdin needs -User or `$env:MOS_USER"; exit 2 }
    $mos_pwd = [Console]::In.ReadLine()
} elseif ($use_runner) {
    if (-not $User) { $User = Read-Host "  MOS user (e-mail)" }
    $sec = Read-Host "  MOS password for $User" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $mos_pwd = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if ($use_runner -and -not $mos_pwd) { local-fail "empty password"; exit 2 }

# Run getMOSPatch for one patch in directory $WorkDir. With the runner the
# credentials go over stdin; output is captured (password masked).
# Without the runner getMOSPatch needs the console -> output not captured.
function local-gmp {
    param([string] $WorkDir, [string[]] $GmpArgs)
    if (-not $use_runner) {
        Push-Location $WorkDir
        try { & $java_exe @java_opts -jar $Jar @GmpArgs | Out-Host } finally { Pop-Location }
        return ""
    }
    $all_args = @($java_opts) + @("-cp", $Jar, $runner) + $GmpArgs
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $java_exe
    $psi.Arguments = (($all_args | ForEach-Object { local-quote $_ }) -join ' ')
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $t_out = $proc.StandardOutput.ReadToEndAsync()
    $t_err = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.WriteLine($User)
    $proc.StandardInput.WriteLine($mos_pwd)
    $proc.StandardInput.Close()
    if (-not $proc.WaitForExit(1800000)) { try { $proc.Kill() } catch { } }
    $out = $t_out.Result + $t_err.Result
    if ($mos_pwd) { $out = $out.Replace($mos_pwd, "****") }
    return $out
}

foreach ($r in $rows) {
    $d = Join-Path $script:dir_abs $r.Sub
    if (local-have $r.Nr $r.Re $r.Sub) { local-ok ("{0,-10} already present - skipped ({1})" -f $r.Nr, $r.Sub); continue }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $got = $false; $out = ""; $pl_used = ""
    foreach ($pl in ($r.Plat -split '\|')) {
        # getMOSPatch reads the platform / language list from its working dir
        Set-Content -LiteralPath (Join-Path $d ".getMOSPatch.cfg") -Value "$pl;$LANG_CODE" -Encoding ASCII
        for ($try = 1; $try -le $RETRIES; $try++) {
            local-info ("{0,-10} platform {1}, attempt {2} - {3}" -f $r.Nr, $pl, $try, $r.Desc)
            # getMOSPatch matches the regexp against the file name WITHOUT ".zip"
            $gre = $r.Re -replace '\\\.zip$', '' -replace '\.zip$', ''
            $gargs = @("patch=$($r.Nr)", "download=all")
            if ($gre) { $gargs += "regexp=$gre" }
            $out = local-gmp $d $gargs
            local-log $out
            if (local-have $r.Nr $r.Re $r.Sub) { $got = $true; $pl_used = $pl; break }
            if ($out -match '(?i)no files available|not available for') { break }
            Start-Sleep -Seconds 10
        }
        if ($got) { break }
    }
    if ($got) {
        local-ok ("{0,-10} downloaded (platform {1})" -f $r.Nr, $pl_used)
    } elseif ($r.Req -eq "yes") {
        $last = ($out -split "`n" | Where-Object { $_ -match '(?i)error|not|denied|invalid' } | Select-Object -Last 1)
        local-fail ("{0,-10} not downloaded - {1}" -f $r.Nr, $last)
    } else {
        local-warn ("{0,-10} (optional) not downloaded" -f $r.Nr)
    }
}
$mos_pwd = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; Remove-Variable mos_pwd

#==============================================================================
# 4. Check (CRC of every entry, SHA-256)
#==============================================================================
local-section "4. Check (ZIP CRC, SHA-256)"
$sum_file = Join-Path $script:dir_abs "patches_sha256.txt"
$sum_csv  = Join-Path $script:dir_abs "patches_sha256.csv"
Set-Content -LiteralPath $sum_file -Value $null -Encoding ASCII
Set-Content -LiteralPath $sum_csv  -Value "patch;step;file;sha256" -Encoding ASCII
$missing_req = 0; $missing_opt = 0; $sha_diff = 0

# ZIP check: Java runner (CRC of every entry, like "unzip -t"); without
# Java 11+ only the structure via .NET (entries readable, CRC not verified)
function local-zipcheck {
    param([string] $Zip)
    if ($java_major -ge 11 -and (Test-Path -LiteralPath $runner)) {
        $res = (& $java_exe $runner --zipcheck $Zip 2>&1 | Out-String)
        return @{ Ok = ($LASTEXITCODE -eq 0); Msg = $res.Trim() }
    }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [System.IO.Compression.ZipFile]::OpenRead($Zip)
        try {
            foreach ($e in $z.Entries) { $s = $e.Open(); try { $s.CopyTo([System.IO.Stream]::Null) } finally { $s.Dispose() } }
        } finally { $z.Dispose() }
        return @{ Ok = $true; Msg = "structure OK (CRC not verified without Java 11+)" }
    } catch { return @{ Ok = $false; Msg = "$_" } }
}

foreach ($r in $rows) {
    $f = local-have $r.Nr $r.Re $r.Sub
    if (-not $f) {
        if ($r.Req -eq "yes") { $missing_req++ } else { $missing_opt++ }
        continue
    }
    $zc = local-zipcheck $f.FullName
    if ($zc.Ok) {
        $is = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        Add-Content -LiteralPath $sum_file -Value ("{0}  {1}\{2}" -f $is, $r.Sub, $f.Name) -Encoding ASCII
        Add-Content -LiteralPath $sum_csv  -Value ("{0};{1};{2};{3}" -f $r.Nr, $r.Step, $f.Name, $is) -Encoding ASCII
        local-ok ("{0,-10} {1,-42} {2,6} MB  {3}..." -f $r.Nr, $f.Name, [math]::Round($f.Length / 1MB), $is.Substring(0, 16))
        if ($zc.Msg -like "structure OK*") { local-info "           $($zc.Msg)" }
        # soft check: Oracle re-releases patches under the same number
        if ($r.Sha -and $is -ne $r.Sha.ToLower()) {
            local-warn ("{0,-10} SHA-256 differs from the list ({1}...) - re-released by Oracle? compare the digest on MOS, then update the CSV" -f $r.Nr, $r.Sha.Substring(0, [math]::Min(16, $r.Sha.Length)))
            $sha_diff++
        }
    } else {
        local-fail ("{0,-10} {1} is damaged ({2}) - delete it and run again" -f $r.Nr, $f.Name, $zc.Msg)
        if ($r.Req -eq "yes") { $missing_req++ } else { $missing_opt++ }
    }
}
local-info "SHA-256 list: $sum_file  (compare with the values on MOS)"

local-print ""
local-print ("=== Summary: OK {0}  WARN {1}  FAIL {2} - log {3}" -f $script:n_ok, $script:n_warn, $script:n_fail, $script:log_file)
if ($missing_req -gt 0) { local-print "$missing_req required patch(es) missing"; exit 2 }
if ($script:n_fail -gt 0) { exit 2 }
if ($missing_opt -gt 0) { local-print "$missing_opt optional patch(es) missing"; exit 1 }
if ($sha_diff -gt 0) { local-print "$sha_diff file(s) with a SHA-256 other than in the list (WARN)"; exit 1 }
exit 0
