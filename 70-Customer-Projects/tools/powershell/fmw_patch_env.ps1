#==============================================================================
# Script   : fmw_patch_env.ps1
# Purpose  : Detect the variables of the manual patch cookbooks
#            (Patch_Kochbuch_*_de.txt, block VORAUSSETZUNGEN) from the running
#            Windows environment and set them:
#              ORACLE_HOME DOMAIN_HOME INV_PTR INVENTORY JDK_LINK NEW_JDK_BASE
#              PATCH_DIR STAGE BACKUP LOGDIR
#            Windows / PowerShell version of tools/bash/fmw_patch_env.sh.
#            Standalone - no library.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
#==============================================================================
<#
.SYNOPSIS
  Set the variables of the FMW patch cookbook (Windows).

.DESCRIPTION
  DOT-SOURCE it to set the variables in the current PowerShell session:
      . .\fmw_patch_env.ps1 [-OracleHome ...] [-DomainHome ...] [-Base ...] [-Apply]
  Started normally (.\fmw_patch_env.ps1) it only shows the values.

  Every variable is set as environment variable ($env:ORACLE_HOME, also seen
  by opatch.bat / cmd.exe started from this session) and as PowerShell
  variable ($ORACLE_HOME).

  Detection order:
    ORACLE_HOME  -OracleHome, $env:ORACLE_HOME, running WebLogic (-Dweblogic.home),
                 C:|D:|E:\Oracle\Middleware\Oracle_Home, ...\Oracle\Oracle_Home
    DOMAIN_HOME  -DomainHome, $env:DOMAIN_HOME, domain-registry.xml,
                 running AdminServer (-Dweblogic.RootDirectory)
    INVENTORY    registry HKLM\SOFTWARE\Oracle inst_loc, <ORACLE_HOME>\oraInst.loc
    JDK_LINK     JAVA_HOME of <ORACLE_HOME>\oui\.globalEnv.properties

.PARAMETER Base
  Base directory of the patch run (default: current directory).
  -> PATCH_DIR=<Base>\zip  STAGE=<Base>\stage  LOGDIR=<STAGE>\logs

.PARAMETER Backup
  Backup directory (default: <prefix>\backup\<name> when <Base> = <prefix>\install\<name>,
  else <Base>\backup).

.PARAMETER Apply
  Create PATCH_DIR / STAGE / LOGDIR / BACKUP and write <Base>\patch_env.ps1
  (load it in a 2nd window with: . <Base>\patch_env.ps1).

.EXAMPLE
  cd D:\install\cpu_okt2026; . D:\tools\fmw_patch_env.ps1 -Apply

.NOTES
  Runs as the software owner of the Oracle Home (the account that installed it).
  Doc: 70-Customer-Projects/tools/powershell/README.md
#>
[CmdletBinding()]
param(
    [string] $OracleHome = $env:ORACLE_HOME,
    [string] $DomainHome = $env:DOMAIN_HOME,
    [string] $Base = (Get-Location).ProviderPath,
    [string] $Backup = "",
    [switch] $Apply,
    [switch] $Version
)
# No Set-StrictMode / exit at top level: the script is meant to be dot-sourced
# (both would act on the caller's session).

$fpe_version = "2026-11-03.1"   # bump on every change
$fpe_sourced = ($MyInvocation.InvocationName -eq '.')
$fpe_rc = 0

function local-fpe-main {
    param([string] $OracleHome, [string] $DomainHome, [string] $Base, [string] $Backup, [bool] $Apply)

    $nfail = 0; $nwarn = 0
    $on_windows = ([Environment]::OSVersion.Platform -eq 'Win32NT')
    function local-ok   { param([string] $t) Write-Host "  OK   " -ForegroundColor Green  -NoNewline; Write-Host $t }
    function local-warn { param([string] $t) Set-Variable -Scope 1 -Name nwarn -Value ($nwarn + 1); Write-Host " WARN  " -ForegroundColor Yellow -NoNewline; Write-Host $t }
    function local-fail { param([string] $t) Set-Variable -Scope 1 -Name nfail -Value ($nfail + 1); Write-Host " FAIL  " -ForegroundColor Red    -NoNewline; Write-Host $t }
    function local-var  { param([string] $n, [string] $v) Write-Host ("  {0,-13} {1}" -f $n, $v) }
    # Java .properties value: "C\:\\Oracle\\jdk" -> "C:\Oracle\jdk"
    function local-prop { param([string] $v) return ($v -replace '\\:', ':' -replace '\\\\', '\') }
    function local-isdir { param([string] $p) return ($p -and (Test-Path -LiteralPath $p -PathType Container)) }

    # command lines of running processes (CIM on Windows; ps for a test on Linux)
    $cmdlines = @()
    if ($on_windows) {
        $cmdlines = @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue |
                      ForEach-Object { $_.CommandLine } | Where-Object { $_ })
    } else {
        $cmdlines = @(& ps -eo args= 2>$null | Where-Object { $_ -match 'java' })
    }

    $mode = "executed: display only (dot-source it to set the variables)"
    if ($fpe_sourced) { $mode = "dot-sourced: variables are set in this session" }
    Write-Host ("fmw_patch_env.ps1 {0} - {1} - {2}" -f $fpe_version, [Environment]::MachineName, $mode)

    #--- ORACLE_HOME ----------------------------------------------------------
    $src_oh = "option / environment"
    if (-not (local-isdir (Join-Path "$OracleHome" "OPatch"))) {
        $OracleHome = ""
        foreach ($c in $cmdlines) {
            if ($c -match '-Dweblogic\.home="?([^"\s]+?)[\\/]wlserver[\\/]server') { $OracleHome = $Matches[1]; $src_oh = "running WebLogic (-Dweblogic.home)"; break }
        }
        if (-not (local-isdir (Join-Path "$OracleHome" "OPatch"))) {
            $OracleHome = ""
            foreach ($d in @("C:", "D:", "E:")) {
                foreach ($s in @("\Oracle\Middleware\Oracle_Home", "\Oracle\Oracle_Home", "\Oracle\fmw", "\app\oracle\fmw", "\oracle\product\mw")) {
                    if (local-isdir "$d$s\OPatch") { $OracleHome = "$d$s"; $src_oh = "default path"; break }
                }
                if ($OracleHome) { break }
            }
        }
    }
    if (-not (local-isdir (Join-Path "$OracleHome" "OPatch"))) { local-fail "ORACLE_HOME not found - use -OracleHome"; $OracleHome = "" }

    #--- DOMAIN_HOME ----------------------------------------------------------
    $src_dh = "option / environment"
    if (-not $DomainHome -and $OracleHome) {
        $reg = Join-Path $OracleHome "domain-registry.xml"
        if (Test-Path -LiteralPath $reg) {
            $locs = @(Select-String -LiteralPath $reg -Pattern 'location="([^"]*)"' -AllMatches |
                      ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value })
            if ($locs.Count -gt 0) { $DomainHome = $locs[0]; $src_dh = $reg }
            if ($locs.Count -gt 1) { local-warn "domain-registry.xml lists more than one domain - first one taken, check / use -DomainHome" }
        }
    }
    if (-not $DomainHome) {
        foreach ($c in $cmdlines) {
            if ($c -match '-Dweblogic\.RootDirectory="?([^"\s]+)') { $DomainHome = $Matches[1]; $src_dh = "running WebLogic (-Dweblogic.RootDirectory)"; break }
        }
    }
    if (-not ($DomainHome -and (Test-Path -LiteralPath (Join-Path $DomainHome "config\config.xml")))) {
        if (-not ($DomainHome -and (Test-Path -LiteralPath (Join-Path $DomainHome "config/config.xml")))) {
            local-fail "DOMAIN_HOME not found (no config\config.xml) - use -DomainHome"; $DomainHome = ""
        }
    }

    #--- Inventory: registry inst_loc (Windows), oraInst.loc --------------------
    $invptr = ""; $inv = ""
    if ($on_windows) {
        foreach ($k in @("HKLM:\SOFTWARE\Oracle", "HKLM:\SOFTWARE\WOW6432Node\Oracle")) {
            $v = (Get-ItemProperty -LiteralPath $k -Name inst_loc -ErrorAction SilentlyContinue).inst_loc
            if ($v) { $invptr = ($k -replace '^HKLM:', 'HKLM') + " (inst_loc)"; $inv = $v; break }
        }
    }
    if (-not $inv) {
        foreach ($c in @((Join-Path "$OracleHome" "oraInst.loc"), "/etc/oraInst.loc")) {
            if ($c -and (Test-Path -LiteralPath $c)) {
                $l = Select-String -LiteralPath $c -Pattern '^inventory_loc=(.*)$' | Select-Object -First 1
                if ($l) { $invptr = $c; $inv = $l.Matches[0].Groups[1].Value.Trim(); break }
            }
        }
    }
    if (-not (local-isdir (Join-Path "$inv" "ContentsXML"))) { local-fail "central inventory not found (pointer: $(if ($invptr) { $invptr } else { 'none' }))" }

    #--- JDK of OPatch / the servers (.globalEnv.properties) -------------------
    $jdk = ""; $jdkv = ""; $jtype = ""
    if ($OracleHome) {
        $ge = Join-Path $OracleHome "oui\.globalEnv.properties"
        if (-not (Test-Path -LiteralPath $ge)) { $ge = Join-Path $OracleHome "oui/.globalEnv.properties" }
        $l = Select-String -LiteralPath $ge -Pattern '^JAVA_HOME=(.*)$' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($l) { $jdk = local-prop $l.Matches[0].Groups[1].Value.Trim() }
    }
    $java = ""
    foreach ($j in @((Join-Path "$jdk" "bin\java.exe"), (Join-Path "$jdk" "bin/java"))) { if ($jdk -and (Test-Path -LiteralPath $j -PathType Leaf)) { $java = $j; break } }
    if ($java) {
        $vout = (& $java -version 2>&1 | Out-String)
        if ($vout -match 'build ([^)]+)\)') { $jdkv = $Matches[1] }
        $item = Get-Item -LiteralPath $jdk -Force
        if ($item.LinkType) { $jtype = "$($item.LinkType) -> $(@($item.Target)[0])  (cookbook 4.4 variant a)" }
        else { $jtype = "real directory  (cookbook 4.4 variant b: make it a junction once - mklink /J)" }
        if ($OracleHome -and $jdk.StartsWith($OracleHome, [StringComparison]::OrdinalIgnoreCase)) {
            local-fail "JAVA_HOME of .globalEnv.properties lies INSIDE ORACLE_HOME (KB175049)"
        }
    } else {
        local-fail "JAVA_HOME in $OracleHome\oui\.globalEnv.properties not found / no java: $(if ($jdk) { $jdk } else { 'empty' })"
    }

    #--- patch run directories ---------------------------------------------------
    if (Test-Path -LiteralPath $Base) { $Base = (Resolve-Path -LiteralPath $Base).ProviderPath }
    $Base = $Base.TrimEnd('\', '/')
    $sep = [IO.Path]::DirectorySeparatorChar
    if (-not $Backup) {
        if ($Base -match '^(.*)[\\/]install[\\/]([^\\/]+)$') { $Backup = Join-Path (Join-Path $Matches[1] "backup") $Matches[2] }
        else { $Backup = Join-Path $Base "backup" }
    }
    foreach ($h in @($OracleHome, $DomainHome)) {
        if ($h -and ("$Base$sep").StartsWith("$h$sep", [StringComparison]::OrdinalIgnoreCase)) {
            local-fail "base directory $Base lies inside ORACLE_HOME / DOMAIN_HOME"
        }
    }

    $vals = [ordered]@{
        ORACLE_HOME = $OracleHome; DOMAIN_HOME = $DomainHome; INV_PTR = $invptr; INVENTORY = $inv
        JDK_LINK = $jdk; NEW_JDK_BASE = $(if ($jdk) { Split-Path -Parent $jdk } else { "" })
        PATCH_DIR = (Join-Path $Base "zip"); STAGE = (Join-Path $Base "stage"); BACKUP = $Backup
        LOGDIR = (Join-Path (Join-Path $Base "stage") "logs")
    }

    Write-Host ""; Write-Host "Variables of the cookbook (block VORAUSSETZUNGEN):"
    foreach ($k in $vals.Keys) {
        $note = ""
        if ($k -eq "ORACLE_HOME") { $note = "   [$src_oh]" }
        if ($k -eq "DOMAIN_HOME") { $note = "   [$src_dh]" }
        if ($k -eq "JDK_LINK")    { $note = "   [.globalEnv.properties]" }
        local-var $k ("{0}{1}" -f $vals[$k], $note)
    }

    #--- facts the cookbook decides on ------------------------------------------
    Write-Host ""; Write-Host "Facts:"
    if ($java) { local-var "JDK" "$jdkv - $jtype" }
    foreach ($bj in @((Join-Path "$OracleHome" "oracle_common\jdk\bin\java.exe"), (Join-Path "$OracleHome" "oracle_common/jdk/bin/java"))) {
        if ($OracleHome -and (Test-Path -LiteralPath $bj -PathType Leaf)) {
            $bv = (& $bj -version 2>&1 | Out-String); if ($bv -match 'build ([^)]+)\)') { local-var "bundled JDK" "$($Matches[1])  (cookbook 4.7)" }
            break
        }
    }
    if ($OracleHome) {
        $op = Join-Path $OracleHome "OPatch\opatch.bat"
        if (-not $on_windows) { $op = Join-Path $OracleHome "OPatch/opatch" }
        if (Test-Path -LiteralPath $op) {
            $env_save = $env:JAVA_HOME
            if ($jdk) { $env:JAVA_HOME = $jdk }
            $ov = (& $op version 2>&1 | Out-String)
            $env:JAVA_HOME = $env_save
            if ($ov -match 'OPatch Version: (\S+)') { local-var "OPatch" $Matches[1] }
        }
    }
    if ($DomainHome) {
        $ohs_dir = Join-Path $DomainHome "config\fmwconfig\components\OHS"
        if (-not $on_windows) { $ohs_dir = Join-Path $DomainHome "config/fmwconfig/components/OHS" }
        $ohs = @(Get-ChildItem -LiteralPath $ohs_dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "instances" } | ForEach-Object { $_.Name })
        if ($ohs.Count -gt 0) { local-var "OHS instances" ($ohs -join ' ') }
        else { local-var "OHS instances" "none (OHS step still applies when the OHS binaries are in the home)" }
    }
    $nzip = @(Get-ChildItem -LiteralPath $vals.PATCH_DIR -Recurse -Depth 1 -Filter 'p*.zip' -File -ErrorAction SilentlyContinue).Count
    local-var "ZIPs" "$nzip in $($vals.PATCH_DIR)"

    # processes + Windows services that must be stopped before OPatch
    $pat = 'weblogic\.(Server|NodeManager)|frmweb|rwserver|rwengine|rwEng'
    $running = @($cmdlines | Where-Object { $_ -match $pat }).Count
    if ($on_windows) {
        $running += @(Get-CimInstance Win32_Process -Filter "Name='frmweb.exe' OR Name='rwserver.exe' OR Name='rwengine.exe' OR Name='httpd.exe'" -ErrorAction SilentlyContinue).Count
        $svc = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
                    $_.State -eq 'Running' -and ("$($_.Name) $($_.DisplayName) $($_.PathName)" -match '(?i)nodemanager|weblogic|wls|beasvc|reports|rwserver|ohs|oracle.*(forms|fmw|middleware)') })
        local-var "processes" "$running WebLogic / Node Manager / Forms / Reports / OHS (must be 0 from step 2 on)"
        if ($svc.Count -gt 0) {
            local-var "services" "$($svc.Count) running - stop them before OPatch (Stop-Service), set them to Manual during the patch run:"
            foreach ($s in $svc) { local-var "" ("  {0}  [{1}, {2}]" -f $s.Name, $s.StartMode, $s.StartName) }
        } else {
            local-var "services" "no running FMW service found"
        }
    } else {
        local-var "processes" "$running WebLogic / Node Manager / Forms / Reports (must be 0 from step 2 on)"
    }

    #--- free space ------------------------------------------------------------------
    function local-root { param([string] $p) $q = $p; while ($q -and -not (Test-Path -LiteralPath $q)) { $q = Split-Path -Parent $q }; if (-not $q) { $q = $p }; return [IO.Path]::GetPathRoot($q) }
    foreach ($k in @("STAGE", "BACKUP")) {
        try {
            $di = New-Object System.IO.DriveInfo (local-root $vals[$k])
            local-var "free $k" ("{0} GB on {1}" -f [math]::Round($di.AvailableFreeSpace / 1GB, 1), $di.Name)
        } catch { local-var "free $k" "not readable" }
    }
    if ($OracleHome -and $on_windows -and ((local-root $vals.BACKUP) -eq (local-root $OracleHome))) {
        local-warn "BACKUP is on the same drive as ORACLE_HOME - better another one (-Backup)"
    }

    #--- -Apply: directories + env file -----------------------------------------------
    $envf = Join-Path $Base "patch_env.ps1"
    if ($Apply -and $nfail -eq 0) {
        try {
            foreach ($k in @("PATCH_DIR", "STAGE", "LOGDIR", "BACKUP")) { New-Item -ItemType Directory -Path $vals[$k] -Force -ErrorAction Stop | Out-Null }
            $lines = @("# written by fmw_patch_env.ps1 $($fpe_version) on $(Get-Date -Format 'yyyy-MM-dd HH:mm') - load with: . $envf")
            foreach ($k in $vals.Keys) {
                $v = ($vals[$k] -replace "'", "''")
                $lines += "`$env:$k = '$v'; `$$k = '$v'"
            }
            Set-Content -LiteralPath $envf -Value $lines -Encoding ASCII -ErrorAction Stop
            local-ok "written: $envf  (in a 2nd window: . $envf)"
        } catch { local-fail "mkdir / write failed: $_" }
    } elseif ($Apply) {
        local-fail "nothing created - fix the FAIL lines first"
    } else {
        Write-Host ""; Write-Host "  -Apply creates the directories and writes $envf"
    }

    Write-Host ""
    return [pscustomobject]@{ Values = $vals; Fail = $nfail; Warn = $nwarn }
}

if ($Version) {
    Write-Output $fpe_version
} else {
    $fpe_res = local-fpe-main -OracleHome $OracleHome -DomainHome $DomainHome -Base $Base -Backup $Backup -Apply $Apply.IsPresent
    if ($fpe_sourced) {
        foreach ($fpe_k in $fpe_res.Values.Keys) {
            Set-Item -Path "env:$fpe_k" -Value $fpe_res.Values[$fpe_k]
            Set-Variable -Name $fpe_k -Value $fpe_res.Values[$fpe_k] -Scope Global
        }
    }
    if ($fpe_res.Fail -gt 0) {
        Write-Host " FAIL  " -ForegroundColor Red -NoNewline
        Write-Host "$($fpe_res.Fail) value(s) missing - check before starting the cookbook"
        $fpe_rc = 2
    } else {
        if ($fpe_sourced) {
            Write-Host "  OK   " -ForegroundColor Green -NoNewline; Write-Host "variables set - continue with SCHRITT 0 of the cookbook"
        } else {
            Write-Host "  To set them in this session: . $($MyInvocation.MyCommand.Path) $($MyInvocation.Line -replace '^.*?fmw_patch_env\.ps1\s*', '')"
        }
        if ($fpe_res.Warn -gt 0) { $fpe_rc = 1 }
    }
}
Remove-Item -Path function:local-fpe-main -ErrorAction SilentlyContinue
Remove-Variable -Name fpe_res, fpe_k -ErrorAction SilentlyContinue
# dot-sourced: never exit (would close the caller's window); executed: exit code
if (-not $fpe_sourced) { exit $fpe_rc }
Remove-Variable -Name fpe_version, fpe_sourced, fpe_rc -ErrorAction SilentlyContinue
