#Requires -Version 5.1
#==============================================================================
# Script   : collect_fmw_env.ps1
# Purpose  : Collect the state of an Oracle Forms & Reports / FMW host on
#            MS Windows Server (12.2.1.x and 14.1.2) for the analyses: what is
#            installed where, patch level (Oracle, Java, Windows updates, Nginx
#            - installed by hand on Windows - / web tier), performance (memory,
#            load profile), security / quality of operation (Derby, FADS,
#            certificates, processes). The CONFIGURATION is not copied - that
#            is export_forms_reports_conf.ps1; an analysis always needs both.
#            Windows / PowerShell version of tools/bash/collect_fmw_env.sh
#            (same file layout 00_summary.txt, 10_os.txt ... 71_log_errors.txt).
#            READ-ONLY: writes only into the output directory (OPatch itself
#            writes its usual logs to ORACLE_HOME\cfgtoollogs when it reads
#            the inventory). Secrets are masked before they are stored. The
#            archive is ENCRYPTED by default (AES-256, openssl compatible).
#            Needs ihw_tools_lib.ps1 next to it.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
#==============================================================================
<#
.SYNOPSIS
  Collect the FMW / Forms / Reports metadata of a Windows host (read-only, masked).

.DESCRIPTION
  Areas: OS (hotfixes, pending Windows updates, volumes, firewall, listening
  ports), Windows services, Java, Oracle Home / inventory / OPatch, domain
  facts, running processes and memory, web tier (Nginx in detail, IIS, OHS,
  Apache) with HTTPS certificates, load profile, logs (+ Windows event log
  with -Logs). The configuration files are in export_forms_reports_conf.ps1.
  Host names, IPs and paths stay in the output (needed for the analysis) -
  passwords, {AES} values, userid= values do not.

.PARAMETER OracleHome
  Default: $env:ORACLE_HOME, running WebLogic (-Dweblogic.home), registry,
  C:|D:|E:\Oracle\Middleware\Oracle_Home ...

.PARAMETER DomainHome
  Default: $env:DOMAIN_HOME, <OracleHome>\domain-registry.xml, running AdminServer.

.PARAMETER OutBase
  Base directory of the output (default: $env:TEMP).

.PARAMETER Full
  Also "opatch lsinventory -details" and "-bugs_fixed" (slow, large).

.PARAMETER Logs
  Also the error lines of the server logs (last 200) and the errors of the
  Windows event logs Application / System of the last 7 days.

.PARAMETER NoEncrypt
  Plain ZIP (still masked) instead of the encrypted .zip.enc.

.PARAMETER Keep
  Keep the output directory next to the archive.

.PARAMETER NoLoad
  No load profile (default: aggregated counts of the last -LoadDays days).

.PARAMETER LoadDays
  Period of the load profile in days (default 90).

.PARAMETER RwAuth
  Reports admin user for getserverinfo / showjobs of a secured Reports server
  (the password is asked hidden; or IHW_RW_AUTH=user/password in the environment).

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\collect_fmw_env.ps1

.EXAMPLE
  .\collect_fmw_env.ps1 -OracleHome D:\Oracle\Middleware\Oracle_Home -DomainHome D:\Oracle\user_projects\domains\fr_domain -Logs

.NOTES
  Runs as the software owner of the Oracle Home or an administrator.
  Doc: 70-Customer-Projects/tools/powershell/README.md
#>
[CmdletBinding()]
param(
    [string] $OracleHome = $env:ORACLE_HOME,
    [string] $DomainHome = $env:DOMAIN_HOME,
    [string] $OutBase = $(if ($env:TEMP) { $env:TEMP } else { "/tmp" }),
    [switch] $Full,
    [switch] $Logs,
    [switch] $NoEncrypt,
    [switch] $Keep,
    [switch] $NoLoad,
    [int] $LoadDays = 90,
    [string] $RwAuth = "",
    [switch] $Version
)

Set-StrictMode -Version 2
$SCRIPT_VERSION = "2026-11-16.4"   # bump on every change - shown in 00_summary.txt
if ($Version) { Write-Output $SCRIPT_VERSION; exit 0 }

$lib = Join-Path $PSScriptRoot "ihw_tools_lib.ps1"
if (-not (Test-Path -LiteralPath $lib)) { Write-Host "ihw_tools_lib.ps1 missing next to $PSCommandPath" -ForegroundColor Red; exit 2 }
. $lib
$host_name  = [Environment]::MachineName
$ts         = Get-Date -Format "yyyyMMdd_HHmmss"
try { $OutBase = (Resolve-Path -LiteralPath $OutBase -ErrorAction Stop).Path } catch { Write-Host "Output directory does not exist: $OutBase" -ForegroundColor Red; exit 2 }
$NAME       = "fmw_collect_{0}_{1}" -f $host_name, $ts
$OUT        = Join-Path $OutBase $NAME
# customer data (host names, IPs, paths) never into a git work tree
if (-not (ihwt-git-guard $OutBase "$NAME.zip")) { exit 2 }
# passphrase first - before the minutes of collecting
$PASS = ""
if (-not $NoEncrypt) {
    $PASS = ihwt-read-passphrase "collector archive"
    if (-not $PASS) { Write-Host "  -> or use -NoEncrypt (plain ZIP, masked)" -ForegroundColor Yellow; exit 2 }
}
$RWAUTH = "$env:IHW_RW_AUTH"
if (-not $NoLoad -and $RwAuth -and -not $RWAUTH) {
    $sp = Read-Host -AsSecureString "  Password of the Reports admin $RwAuth"
    $RWAUTH = "$RwAuth/" + [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp))
}
try { New-Item -ItemType Directory -Path $OUT -Force -ErrorAction Stop | Out-Null }
catch { Write-Host "Cannot create $OUT : $_" -ForegroundColor Red; exit 2 }
$SUM = Join-Path $OUT "00_summary.txt"
$IHWT_OUT = $OUT; $IHWT_SUM = $SUM

ihwt-say "collect_fmw_env.ps1 version $SCRIPT_VERSION"
ihwt-say "Output: $OUT"

# running processes (CIM on Windows; ps for a test run on Linux)
$procs = @(ihwt-procs)
$fmw_pat = 'weblogic\.(Server|NodeManager)|frmweb|rwserver|rwengine|rwEng|rwrun|httpd|nginx|beasvc|NetworkServerControl'

#------------------------------------------------------------------------------
# Locate ORACLE_HOME / DOMAIN_HOME
#------------------------------------------------------------------------------
# (ihwt-find-homes of the lib - the same search as export_forms_reports_conf.ps1)
$homes = ihwt-find-homes $OracleHome $DomainHome $procs
if (-not $homes.OH) { Write-Host "ORACLE_HOME not found - use -OracleHome" -ForegroundColor Yellow }
if ($DomainHome -and -not $homes.DH) { Write-Host "DOMAIN_HOME $DomainHome has no config.xml - use -DomainHome" -ForegroundColor Yellow }
$OracleHome = $homes.OH; $DomainHome = $homes.DH
$OH = $OracleHome; $DH = $DomainHome

ihwt-write-file $SUM @(
    ("FMW environment collection {0} {1}" -f [char]0x2013, (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")),   # en dash like bash (ASCII source for PS 5.1)
    "collect_fmw_env.ps1 version $SCRIPT_VERSION (ihw_tools_lib $(ihwt-lib-version), read-only, secrets masked)", "")
foreach ($l in (ihwt-identity 28 $OH $DH)) { ihwt-append-file $SUM $l }
ihwt-fact "User" ("{0}\{1}" -f [Environment]::UserDomainName, [Environment]::UserName)
if ($IHWT_ON_WINDOWS) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    ihwt-fact "Administrator" "$admin"
}
ihwt-fact "PowerShell" ("{0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)

#==============================================================================
# 1. Operating system
#==============================================================================
ihwt-say "1/8 OS"
if ($IHWT_ON_WINDOWS) {
    ihwt-runps 10_os.txt "OS" { Get-CimInstance Win32_OperatingSystem | Format-List Caption, Version, BuildNumber, OSArchitecture, InstallDate, LastBootUpTime, TotalVisibleMemorySize, FreePhysicalMemory, CodeSet, Locale, OSLanguage }
    ihwt-runps 10_os.txt "Computer" { Get-CimInstance Win32_ComputerSystem | Format-List Name, Domain, Manufacturer, Model, NumberOfProcessors, NumberOfLogicalProcessors, TotalPhysicalMemory, HypervisorPresent }
    ihwt-runps 10_os.txt "Hotfixes (last 30)" { Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 30 | Format-Table -AutoSize HotFixID, Description, InstalledOn }
    ihwt-runps 10_os.txt "Volumes" { Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Format-Table -AutoSize DeviceID, FileSystem, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,1)}}, VolumeName }
    ihwt-runps 10_os.txt "Pagefile" { Get-CimInstance Win32_PageFileUsage | Format-Table -AutoSize Name, AllocatedBaseSize, CurrentUsage, PeakUsage }
    ihwt-runps 10_os.txt "Time zone / culture / code page" { Get-TimeZone | Format-List Id, DisplayName; Get-Culture | Format-List Name, DisplayName; [Console]::OutputEncoding | Format-List CodePage, EncodingName; & cmd.exe /c chcp }
    ihwt-runps 10_os.txt "Windows Firewall profiles" { Get-NetFirewallProfile | Format-Table -AutoSize Name, Enabled, DefaultInboundAction, DefaultOutboundAction }
    ihwt-runps 10_os.txt "Network addresses" { Get-NetIPAddress | Where-Object { $_.AddressState -eq 'Preferred' } | Format-Table -AutoSize InterfaceAlias, AddressFamily, IPAddress, PrefixLength }
    ihwt-runps 10_os.txt "Listening ports" { $pn = @{}; Get-Process | ForEach-Object { $pn[$_.Id] = $_.ProcessName }; Get-NetTCPConnection -State Listen | Sort-Object LocalPort | Format-Table -AutoSize LocalAddress, LocalPort, OwningProcess, @{n='Process';e={$pn[[int]$_.OwningProcess]}} }
    ihwt-runps 10_os.txt "Scheduled tasks (Oracle / WebLogic / Forms / Reports)" { Get-ScheduledTask | Where-Object { "$($_.TaskName) $($_.Actions.Execute) $($_.Actions.Arguments)" -match '(?i)oracle|weblogic|wls|fmw|forms|report|nodemanager' } | Format-Table -AutoSize TaskPath, TaskName, State, @{n='Action';e={"$($_.Actions.Execute) $($_.Actions.Arguments)"}} }
    ihwt-runps 10_os.txt "Environment (system)" { [Environment]::GetEnvironmentVariables('Machine').GetEnumerator() | Sort-Object Name | Format-Table -AutoSize -Wrap Name, Value }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        ihwt-fact "OS" ("{0} (build {1})" -f $os.Caption, $os.BuildNumber)
        ihwt-fact "Uptime" ("{0:dd}d {0:hh}h (since {1})" -f ((Get-Date) - $os.LastBootUpTime), $os.LastBootUpTime)
        ihwt-fact "Memory MB (total/avail)" ("{0} / {1}" -f [math]::Round($os.TotalVisibleMemorySize / 1KB), [math]::Round($os.FreePhysicalMemory / 1KB))
    }
    ihwt-fact "Last hotfix" ("{0}" -f (Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1 | ForEach-Object { "$($_.HotFixID) $($_.InstalledOn)" }))
    $cv = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
    if ($cv) { ihwt-fact "Windows build" ("{0}.{1} ({2})" -f $cv.CurrentBuild, $(if ($cv.PSObject.Properties['UBR']) { $cv.UBR } else { "?" }), $(if ($cv.PSObject.Properties['DisplayVersion']) { $cv.DisplayVersion } else { $cv.ReleaseId })) }
    # updates not installed - Windows Update Agent CACHE of the last scan (no
    # network forced); the list stays in 10_os.txt, the analyses show the numbers
    $advf = Join-Path $OUT ".os_advisories"
    ihwt-fact "OS security advisories" (ihwt-os-advisories -ListFile $advf)
    ihwt-block 10_os.txt "Updates not installed (Windows Update cache: severity;KB;title)" ($(if (Test-Path -LiteralPath $advf) { (Get-Content -LiteralPath $advf) -join "`n" } else { "not available" }))
    Remove-Item -LiteralPath $advf -Force -ErrorAction SilentlyContinue
} else {
    ihwt-runps 10_os.txt "OS (not Windows - test run)" { Get-Content /etc/os-release; & uname -a }
}

#==============================================================================
# 2. Java
#==============================================================================
ihwt-say "2/8 Java"
$ge_file = ""; $jdk_ge = ""
if ($OH) {
    $ge_file = ihwt-jp @($OH, "oui", ".globalEnv.properties")
    $m = Select-String -LiteralPath $ge_file -Pattern '^JAVA_HOME=(.*)$' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { $jdk_ge = ihwt-prop $m.Matches[0].Groups[1].Value.Trim() }
}
$jcand = New-Object System.Collections.Generic.List[string]
if ($OH) {
    Select-String -LiteralPath $ge_file -Pattern '^JAVA_HOME[A-Z0-9_]*=(.*)$' -ErrorAction SilentlyContinue | ForEach-Object { $jcand.Add((ihwt-prop $_.Matches[0].Groups[1].Value.Trim())) }
    $jcand.Add((ihwt-jp @($OH, "oracle_common", "jdk")))
}
if ($env:JAVA_HOME) { $jcand.Add($env:JAVA_HOME) }
foreach ($p in $procs) {
    if ("$($p.ExecutablePath)" -match '^(.*)[\\/]bin[\\/]javaw?(\.exe)?$') { $jcand.Add(($Matches[1] -replace '[\\/]jre$', '')) }
}
$jdks = @($jcand | Where-Object { $_ } | Sort-Object -Unique)
foreach ($j in $jdks) {
    $jx = ihwt-jp @($j, "bin", "java.exe"); if (-not (Test-Path -LiteralPath $jx)) { $jx = ihwt-jp @($j, "bin", "java") }
    if (-not (Test-Path -LiteralPath $jx -PathType Leaf)) { continue }
    ihwt-run 20_java.txt "java -version: $j" $jx @("-version")
    ihwt-runps 20_java.txt "link / release: $j" ([scriptblock]::Create("`$i = Get-Item -LiteralPath '$($j -replace "'", "''")' -Force; `"LinkType: `$(`$i.LinkType)  Target: `$(@(`$i.Target) -join ' ')`"; Get-Content -LiteralPath (Join-Path '$($j -replace "'", "''")' 'release') -ErrorAction SilentlyContinue"))
}
ihwt-runps 20_java.txt "Java of the running processes" { $procs | Where-Object { $_.Name -match '^javaw?(\.exe)?$' } | Format-Table -AutoSize ProcessId, ExecutablePath }
if ($ge_file) { ihwt-copy 20_java.txt $ge_file }
ihwt-fact "JDK of OPatch (.globalEnv)" $(if ($jdk_ge) { $jdk_ge } else { "?" })
if ($jdk_ge) {
    $jx = ihwt-jp @($jdk_ge, "bin", "java.exe"); if (-not (Test-Path -LiteralPath $jx)) { $jx = ihwt-jp @($jdk_ge, "bin", "java") }
    if (Test-Path -LiteralPath $jx) { ihwt-fact "JDK version (.globalEnv)" (((ihwt-exec $jx @("-version")).Out -split "`n" | Select-Object -First 2) -join ' ') }
    $it = Get-Item -LiteralPath $jdk_ge -Force -ErrorAction SilentlyContinue
    if ($it) { ihwt-fact "JDK link type" $(if ($it.LinkType) { "$($it.LinkType) -> $(@($it.Target)[0])" } else { "real directory (no junction)" }) }
}
ihwt-fact "JDKs of running processes" ((@($procs | Where-Object { $_.Name -match '^javaw?(\.exe)?$' } | ForEach-Object { $_.ExecutablePath } | Sort-Object -Unique)) -join ' ')
$bj = ""; if ($OH) { foreach ($j in @((ihwt-jp @($OH, "oracle_common", "jdk", "bin", "java.exe")), (ihwt-jp @($OH, "oracle_common", "jdk", "bin", "java")))) { if (Test-Path -LiteralPath $j -PathType Leaf) { $bj = ((ihwt-exec $j @("-version") -TimeoutSec 60).Out -split "`n" | Select-Object -First 1).Trim(); break } } }
ihwt-fact "Bundled JDK (oracle_common/jdk)" $(if ($bj) { $bj } else { "none" })

#==============================================================================
# 3. Oracle Home, inventory, patches
#==============================================================================
ihwt-say "3/8 Oracle Home / OPatch"
if ($IHWT_ON_WINDOWS) {
    ihwt-runps 30_inventory.txt "Registry HKLM\SOFTWARE\Oracle (inst_loc, KEY_* homes)" {
        foreach ($k in @("HKLM:\SOFTWARE\Oracle", "HKLM:\SOFTWARE\WOW6432Node\Oracle")) {
            if (-not (Test-Path $k)) { continue }
            "[$k]"; Get-ItemProperty -LiteralPath $k | Select-Object * -ExcludeProperty PS* | Format-List
            Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue | ForEach-Object { "[$($_.Name)]"; Get-ItemProperty -LiteralPath $_.PSPath | Select-Object * -ExcludeProperty PS* | Format-List }
        }
    }
}
if ($OH) {
    $inv = ""
    if ($IHWT_ON_WINDOWS) { $inv = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Oracle" -Name inst_loc -ErrorAction SilentlyContinue).inst_loc }
    foreach ($c in @((Join-Path $OH "oraInst.loc"), "/etc/oraInst.loc")) {
        if (Test-Path -LiteralPath $c) {
            ihwt-copy 30_inventory.txt $c
            if (-not $inv) { $m = Select-String -LiteralPath $c -Pattern '^inventory_loc=(.*)$' | Select-Object -First 1; if ($m) { $inv = $m.Matches[0].Groups[1].Value.Trim() } }
        }
    }
    if ($inv) { ihwt-copy 30_inventory.txt (ihwt-jp @($inv, "ContentsXML", "inventory.xml")) }
    ihwt-fact "Central inventory" $(if ($inv) { $inv } else { "?" })

    $op = ihwt-jp @($OH, "OPatch", "opatch.bat"); if (-not $IHWT_ON_WINDOWS) { $op = ihwt-jp @($OH, "OPatch", "opatch") }
    $openv = @{}; if ($jdk_ge) { $openv["JAVA_HOME"] = $jdk_ge }
    ihwt-run 31_opatch.txt "opatch version"     $op @("version")     $openv
    ihwt-run 31_opatch.txt "opatch lspatches"   $op @("lspatches")   $openv
    ihwt-run 31_opatch.txt "opatch lsinventory" $op @("lsinventory") $openv
    if ($Full) {
        ihwt-run 32_opatch_details.txt "opatch lsinventory -details"    $op @("lsinventory", "-details")    $openv
        ihwt-run 32_opatch_details.txt "opatch lsinventory -bugs_fixed" $op @("lsinventory", "-bugs_fixed") $openv
    }
    $comp_dir = ihwt-jp @($OH, "inventory", "Components")
    ihwt-runps 30_inventory.txt "Components (Forms / Reports / OHS / WebGate / SQL Developer)" ([scriptblock]::Create("Get-ChildItem -LiteralPath '$($comp_dir -replace "'", "''")' -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -match '(?i)forms|reports|ohs|webgate|sqldeveloper|oracle\.rdbms|perl' } | ForEach-Object { `$_.Name }"))
    ihwt-runps 30_inventory.txt "Top level of the Oracle Home" ([scriptblock]::Create("Get-ChildItem -LiteralPath '$($OH -replace "'", "''")' -Force | Format-Table -AutoSize Mode, LastWriteTime, Length, Name"))
    ihwt-runps 30_inventory.txt "Forms / Reports binaries" ([scriptblock]::Create("Get-ChildItem -LiteralPath (Join-Path '$($OH -replace "'", "''")' 'bin') -File -ErrorAction SilentlyContinue | Where-Object { `$_.BaseName -match '^(frmweb|frmcmp|frmcmp_batch|frmbld|rwserver|rwrun|rwbuilder|rwconverter|rwclient)$' } | Format-Table -AutoSize Name, Length, LastWriteTime, @{n='Version';e={`$_.VersionInfo.FileVersion}}"))
    ihwt-copy 30_inventory.txt (Join-Path $OH "domain-registry.xml")

    $r = ihwt-exec $op @("version") $openv
    if ($r.Out -match 'OPatch Version: (\S+)') { ihwt-fact "OPatch" $Matches[1] }
    $r = ihwt-exec $op @("lspatches") $openv
    ihwt-fact "Patches (lspatches)" (@($r.Out -split "`n" | Where-Object { $_ -match '^\d+;' }).Count)
    $comps_xml = ihwt-jp @($OH, "inventory", "ContentsXML", "comps.xml")
    $rc_n = 0
    if (Test-Path -LiteralPath $comps_xml) {
        $cm = @(Select-String -LiteralPath $comps_xml -Pattern 'COMP NAME="(oracle\.(reports|forms|developer)[^"]*)" VER="([^"]*)"' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[3].Value)" } | Sort-Object -Unique)
        ihwt-block 30_inventory.txt "Reports / Forms components in comps.xml (OPatch view)" (($cm -join "`n"))
        $rc_n = @($cm | Where-Object { $_ -like 'oracle.reports*' }).Count
    }
    $rb_n = @(Get-ChildItem -LiteralPath (Join-Path $OH "bin") -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('rwserver', 'rwrun', 'rwserver.exe', 'rwrun.exe') }).Count
    ihwt-fact "Reports comps.xml / binaries" "$rc_n component(s) / $rb_n of rwserver,rwrun"
    if ($rc_n -eq 0 -and $rb_n -gt 0) { ihwt-fact "!! Reports NOT REGISTERED" "binaries in the home but no oracle.reports component - OPatch would never patch them" }
    $comps = @(Get-ChildItem -LiteralPath $comp_dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    ihwt-fact "Reports component in home" ("{0} entries" -f @($comps | Where-Object { $_ -match '(?i)reports' }).Count)
    ihwt-fact "OHS component in home" ("{0} entries" -f @($comps | Where-Object { $_ -match '(?i)ohs' }).Count)
    # product versions (registry.xml) - selects the patch list of KA1182
    $regx = ihwt-jp @($OH, "inventory", "registry.xml")
    $pv = @(Select-String -LiteralPath $regx -Pattern '<(distribution|feature)[^>]* name="([^"]*)"[^>]* version="([^"]*)"' -AllMatches -ErrorAction SilentlyContinue | ForEach-Object { $_.Matches } | ForEach-Object { "$($_.Groups[2].Value) $($_.Groups[3].Value)" } | Sort-Object -Unique)
    ihwt-block 30_inventory.txt "Installed distributions / features (inventory/registry.xml)" (($pv -join "`n"))
    $pd = @(Select-String -LiteralPath $regx -Pattern '<distribution[^>]* name="([^"]*)"[^>]* version="([^"]*)"' -AllMatches -ErrorAction SilentlyContinue | ForEach-Object { $_.Matches } | ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" } | Sort-Object -Unique)
    ihwt-fact "Product versions (registry.xml)" ($pd -join ';')
    # components that decide single patches (DB client, Perl, OHS, WebGate, Infrastructure bundles)
    $cpx = @(Select-String -LiteralPath $comps_xml -Pattern 'COMP NAME="([^"]*)" VER="([^"]*)"' -AllMatches -ErrorAction SilentlyContinue | ForEach-Object { $_.Matches } | ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" } |
             Where-Object { $_ -match '(?i)rdbms|client|perl|ohs|webgate|wls|weblogic|coherence|adf|jrf|opss|owsm|wsm|em|ums|webcenter|libovd|oamclient|forms|reports|jdk|dbclient' } | Sort-Object -Unique)
    ihwt-block 33_components.txt "Patch-relevant components (comps.xml)" (($cpx -join "`n"))
    $sqp = @((ihwt-jp @($OH, "bin", "sqlplus.exe")), (ihwt-jp @($OH, "bin", "sqlplus")) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    $dbc = ""; if ($sqp.Count) { $r = ihwt-exec $sqp[0] @("-V") -TimeoutSec 60; ihwt-block 33_components.txt "DB client in the home (sqlplus -V)" $r.Out; if ($r.Out -match 'Version [0-9.]+') { $dbc = $Matches[0] } }
    ihwt-fact "DB client in home" $dbc
    $plx = @((ihwt-jp @($OH, "perl", "bin", "perl.exe")), (ihwt-jp @($OH, "perl", "bin", "perl")) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    $perl = ""; if ($plx.Count) { $perl = (ihwt-exec $plx[0] @("-e", 'print $^V') -TimeoutSec 60).Out.Trim() }
    ihwt-fact "Perl in home" $perl
    ihwt-fact "WebGate in home" $(if (ihwt-isdir (Join-Path $OH "webgate")) { "yes" } else { "no" })
    ihwt-runps 33_components.txt "OHS / WebGate in the home" ([scriptblock]::Create("Get-Item -LiteralPath (Join-Path '$($OH -replace "'", "''")' 'ohs'), (Join-Path '$($OH -replace "'", "''")' 'webgate') -ErrorAction SilentlyContinue | Format-Table -AutoSize FullName, LastWriteTime"))
    # every other Oracle home of the central inventory
    $others = @()
    if ($inv -and (Test-Path -LiteralPath (ihwt-jp @($inv, "ContentsXML", "inventory.xml")))) {
        $others = @(Select-String -LiteralPath (ihwt-jp @($inv, "ContentsXML", "inventory.xml")) -Pattern '<HOME [^>]*LOC="([^"]*)"' -AllMatches | Where-Object { $_.Line -notmatch 'REMOVED="T"' } |
                    ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -and ($_.TrimEnd('\', '/') -ne $OH.TrimEnd('\', '/')) })
        foreach ($h in $others) {
            $hop = @((ihwt-jp @($h, "OPatch", "opatch.bat")), (ihwt-jp @($h, "OPatch", "opatch")) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
            if ($hop.Count) { ihwt-run 34_other_homes.txt "opatch lspatches -oh $h" $hop[0] @("lspatches", "-oh", $h) $openv }
            else { ihwt-block 34_other_homes.txt "${h}: no OPatch (missing / not a patchable home)" "" }
        }
    }
    ihwt-fact "Other Oracle homes (inventory)" ($others -join ' ')
    # OPatch prerequisites: inventory locks, rollback storage, free space, last runs
    $lk = @(Get-ChildItem -LiteralPath (Join-Path "$inv" "locks") -Force -ErrorAction SilentlyContinue)
    # "ls -la"-like lines (9 fields, name last) - the analysis reads the names
    ihwt-block 35_opatch_prereq.txt "Inventory locks" (((@($lk | ForEach-Object { "f 1 - - {0} {1} - {2}" -f $_.Length, $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm"), $_.Name })) -join "`n"))
    ihwt-fact "Inventory locks" "$($lk.Count) file(s)"
    $ps_dir = Join-Path $OH ".patch_storage"
    $psz = (Get-ChildItem -LiteralPath $ps_dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $pst = "{0:0.0}G" -f ([double]$psz / 1GB)
    ihwt-block 35_opatch_prereq.txt "Rollback storage (.patch_storage)" ("{0}`t{1}" -f $pst, $ps_dir)
    ihwt-fact ".patch_storage" $pst
    # free space as "df -hP" lines (size / used / avail with G, mount point last)
    $dfl = @("Filesystem Size Used Avail Use% Mounted")
    foreach ($pth in @($OH, $inv, [IO.Path]::GetTempPath())) { if (-not $pth) { continue }
        try { $dr = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $pth).Path))
              $dfl += ("{0} {1:0}G {2:0}G {3:0}G {4:0}% {5}" -f $dr.Name, ($dr.TotalSize / 1GB), (($dr.TotalSize - $dr.AvailableFreeSpace) / 1GB), ($dr.AvailableFreeSpace / 1GB), (100 * ($dr.TotalSize - $dr.AvailableFreeSpace) / [math]::Max([double]1, [double]$dr.TotalSize)), $pth) } catch { } }
    ihwt-block 35_opatch_prereq.txt "Free space: home / inventory / /tmp" (($dfl -join "`n"))
    try { $dr = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($OH)); ihwt-fact "Free space of the home" ("{0:0}G free of {1:0}G" -f ($dr.AvailableFreeSpace / 1GB), ($dr.TotalSize / 1GB)) } catch { }
    $oplogs = @(Get-ChildItem -LiteralPath (ihwt-jp @($OH, "cfgtoollogs", "opatch")) -Filter "opatch*.log" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    ihwt-block 35_opatch_prereq.txt "Last OPatch logs (cfgtoollogs/opatch)" (((@($oplogs | Select-Object -First 15 | ForEach-Object { "{0} {1,10} {2}" -f $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm"), $_.Length, $_.Name })) -join "`n"))
    $runs = @(foreach ($f in $oplogs) {
        $c = Select-String -LiteralPath $f.FullName -Pattern "OPatch invoked as follows: '((apply|napply|rollback|nrollback)[^']*)'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $c) { continue }
        $res = @(Select-String -LiteralPath $f.FullName -Pattern 'successfully (applied|rolled back)|OPatch (failed|stopped)|UtilSession failed|Prereq .* failed' -ErrorAction SilentlyContinue | ForEach-Object { $_.Line -replace '^\[[^\]]*\]\s*', '' } | Sort-Object -Unique) -join ' '
        "{0} | '{1}' | {2}" -f $f.Name, $c.Matches[0].Groups[1].Value, $(if ($res.Length -gt 300) { $res.Substring(0, 300) } else { $res })
    })
    ihwt-block 35_opatch_prereq.txt "Last patch runs (apply / napply / rollback) with result" (((@($runs | Select-Object -First 20)) -join "`n"))
    ihwt-block 35_opatch_prereq.txt "Files in the home NOT owned by this user (first 20)" ""
}
ihwt-fact "IHateWeblogic library" "none"

#==============================================================================
# 4. Domain configuration (masked)
#==============================================================================
ihwt-say "4/8 Domain"
if ($DH) {
    $cfg = ihwt-jp @($DH, "config", "config.xml")
    # the configuration files themselves are in the export
    # (export_forms_reports_conf.ps1) - here only what the analyses derive
    ihwt-runps 40_domain.txt "Servers / listen addresses / ports (config.xml)" ([scriptblock]::Create("Select-String -LiteralPath '$($cfg -replace "'", "''")' -Pattern '<(name|listen-address|listen-port|machine|cluster|enabled|nm-type|listen-port-enabled)>' | Select-Object -First 200 | ForEach-Object { `$_.Line.Trim() }"))
    ihwt-runps 40_domain.txt "Servers on disk" ([scriptblock]::Create("Get-ChildItem -LiteralPath (Join-Path '$($DH -replace "'", "''")' 'servers') -ErrorAction SilentlyContinue | Format-Table -AutoSize Mode, LastWriteTime, Name"))
    ihwt-runps 40_domain.txt "Domain files" ([scriptblock]::Create("foreach (`$s in @('', 'bin', 'nodemanager')) { Get-ChildItem -LiteralPath (Join-Path '$($DH -replace "'", "''")' `$s) -Force -ErrorAction SilentlyContinue | Format-Table -AutoSize Mode, LastWriteTime, Length, FullName }"))
    ihwt-runps 40_domain.txt "Versioned JDK paths in the domain (instead of a junction)" ([scriptblock]::Create("Get-ChildItem -LiteralPath (Join-Path '$($DH -replace "'", "''")' 'bin'), (Join-Path '$($DH -replace "'", "''")' 'nodemanager') -File -ErrorAction SilentlyContinue | Select-String -Pattern 'jdk1\.8\.0_|jdk-[0-9]' | Select-Object -First 50 | ForEach-Object { `"`$(`$_.Path):`$(`$_.LineNumber): `$(`$_.Line.Trim())`" }"))
    # Forms / Reports configuration files: list only (content: export)
    $fmwcfg = ihwt-jp @($DH, "config", "fmwconfig")
    ihwt-runps 40_domain.txt "Forms / Reports configuration files (list only - content: export)" ([scriptblock]::Create("Get-ChildItem -LiteralPath '$($fmwcfg -replace "'", "''")' -Recurse -File -ErrorAction SilentlyContinue | Where-Object { `$_.Name -match '(?i)^(formsweb\.cfg|.*\.env|webutil\.cfg|registry\.dat|rwserver\.conf|rwservlet\.properties|cgicmd\.dat|uifont\.ali|rwnetwork\.conf)$' } | Select-Object -First 60 | Format-Table -AutoSize LastWriteTime, Length, FullName"))
    ihwt-fact "Forms in domain" $(if (Select-String -LiteralPath $cfg -Pattern 'WLS_FORMS|formsapp|<name>forms' -Quiet -ErrorAction SilentlyContinue) { "yes" } else { "no" })
    $xml = $null; try { [xml]$xml = [IO.File]::ReadAllText($cfg) } catch { }
    if ($xml) {
        ihwt-fact "Domain" $xml.domain.name
        ihwt-fact "Domain version (config.xml)" $xml.domain.'domain-version'
        # listen-port is missing in config.xml when it is the default 7001 (StrictMode: check the property)
        ihwt-fact "Servers (config.xml)" ((@($xml.domain.server | ForEach-Object { "{0}:{1}" -f $_.name, $(if ($_.PSObject.Properties['listen-port']) { $_.'listen-port' } else { "7001" }) })) -join ' ')
    }
    # Forms Application Deployment Services (FADS): software in every Forms
    # home, in the domain only when the extension template + fads_config.py
    # were applied - then FADS also writes formsweb.cfg, Registry.dat,
    # jvmcontrollers.cfg, <app>.env (80-FMW-Architecture/forms_fads_app_dep_service.md)
    $fapps = @(Select-String -LiteralPath $cfg -Pattern '<name>(fads[^<]*)</name>' -AllMatches -ErrorAction SilentlyContinue | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $dinfo = ihwt-jp @($DH, "init-info", "domain-info.xml")
    $ftpl = ""
    $m = Select-String -LiteralPath $dinfo -Pattern 'name="([^"]*Application Deployment Servic[^"]*)"' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { $ftpl = $m.Matches[0].Groups[1].Value }
    ihwt-runps 40_domain.txt "FADS (Forms Application Deployment Services): deployments, template" ([scriptblock]::Create("Select-String -LiteralPath '$($cfg -replace "'", "''")' -Pattern '<name>fads' -Context 1,6 -ErrorAction SilentlyContinue | ForEach-Object { `$_.ToString() }; Select-String -LiteralPath '$($dinfo -replace "'", "''")' -Pattern 'Application Deployment Servic' -ErrorAction SilentlyContinue | ForEach-Object { `$_.Line.Trim() }"))
    if ($fapps.Count -or $ftpl) {
        ihwt-fact "FADS in the domain" ("CONFIGURED (deployments: {0}; template: {1})" -f $(if ($fapps.Count) { $fapps -join ' ' } else { "none" }), $(if ($ftpl) { $ftpl } else { "not listed" }))
    } else {
        ihwt-fact "FADS in the domain" "not configured"
    }
}
if ($DH -and $OH) {
    $jn = @(Get-ChildItem -Path (ihwt-jp @($OH, "forms", "java")), (ihwt-jp @($OH, "forms", "templates", "config")) -Filter *.jnlp -File -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath (ihwt-jp @($DH, "config", "fmwconfig")) -Recurse -Filter *.jnlp -File -ErrorAction SilentlyContinue)
    ihwt-block 44_forms_client.txt "JNLP j2se / java versions" (((@($jn | Select-String -Pattern 'j2se|<java ' -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line.Trim())" })) -join "`n"))
    $fwc = @(Get-ChildItem -LiteralPath (ihwt-jp @($DH, "config", "fmwconfig", "servers")) -Recurse -Filter formsweb.cfg -File -ErrorAction SilentlyContinue)
    ihwt-block 44_forms_client.txt "formsweb.cfg Java plug-in / client keys" (((@($fwc | Select-String -Pattern '^(jpi_|baseHTMLjpi|webstart|fsal|java_version|jre)' -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line.Trim())" })) -join "`n"))
    ihwt-block 44_forms_client.txt "FSAL / client jars (frmsal.jar)" (((@(Get-ChildItem -Path (ihwt-jp @($OH, "forms", "java", "frmsal*.jar")), (ihwt-jp @($OH, "forms", "java", "frmall.jar")) -File -ErrorAction SilentlyContinue | ForEach-Object { "{0,10} {1} {2}" -f $_.Length, $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm"), $_.FullName })) -join "`n"))
}
if ($OH) { ihwt-fact "FADS software in home" $(if (Test-Path -LiteralPath (ihwt-jp @($OH, "forms", "fads", "fads.ear"))) { "yes (forms/fads)" } else { "no" }) }

#==============================================================================
# 5. Running processes, Windows services
#==============================================================================
ihwt-say "5/8 Processes / services"
$fmw_procs = @($procs | Where-Object { "$($_.Name) $($_.CommandLine)" -match $fmw_pat })
if ($IHWT_ON_WINDOWS) {
    ihwt-runps 50_processes.txt "WLS / Node Manager / Forms / Reports / OHS processes" { $fmw_procs | Sort-Object ProcessId | Format-List ProcessId, ParentProcessId, Name, CreationDate, @{n='WorkingSetMB';e={[math]::Round($_.WorkingSetSize/1MB)}}, ExecutablePath, CommandLine }
    ihwt-runps 50_processes.txt "Windows services (Oracle / WebLogic / Node Manager / Forms / Reports / OHS / IIS)" {
        Get-CimInstance Win32_Service | Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match '(?i)oracle|weblogic|wls|beasvc|nodemanager|forms|report|ohs|w3svc|nginx' } |
            Sort-Object Name | Format-List Name, DisplayName, State, StartMode, StartName, ProcessId, PathName
    }
    $svc_run = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' -and "$($_.Name) $($_.DisplayName) $($_.PathName)" -match '(?i)weblogic|wls|beasvc|nodemanager|report|ohs' })
    ihwt-fact "FMW services running" ((@($svc_run | ForEach-Object { $_.Name })) -join ' ')
} else {
    ihwt-runps 50_processes.txt "WLS / Node Manager / Forms / Reports processes (test run)" { $fmw_procs | Format-List ProcessId, Name, ExecutablePath, CommandLine }
}
ihwt-fact "frmweb processes" (@($procs | Where-Object { $_.Name -match '^frmweb' }).Count)
ihwt-fact "WLS servers running" ((@($procs | ForEach-Object { if ("$($_.CommandLine)" -match '-Dweblogic\.Name=(\S+)') { $Matches[1] } } | Sort-Object -Unique)) -join ' ')
# Which home do the running FMW processes come from?
$foreign = @($fmw_procs | ForEach-Object { $_.ExecutablePath } | Where-Object { $_ -match '[\\/](javaw?|frmweb|rwserver|rwrun|rwengine)(\.exe)?$' } | Sort-Object -Unique | Where-Object {
              -not (($OH -and $_.StartsWith($OH, [StringComparison]::OrdinalIgnoreCase)) -or ($jdk_ge -and $_.StartsWith($jdk_ge, [StringComparison]::OrdinalIgnoreCase))) })
ihwt-fact "Processes outside ORACLE_HOME / JDK" $(if ($foreign.Count) { $foreign -join ' ' } else { "none" })
# Apache Derby = WebLogic evaluation database, started by every startWebLogic.cmd
# while DERBY_FLAG is not false (80-FMW-Architecture/fmw_derby_history.md)
$derby = @($procs | Where-Object { "$($_.CommandLine)" -match 'org\.apache\.derby\.drda\.NetworkServerControl\s+start' })
$derby_lsn = $null
if ($IHWT_ON_WINDOWS) { $derby_lsn = @(Get-NetTCPConnection -State Listen -LocalPort 1527 -ErrorAction SilentlyContinue) | Select-Object -First 1 }
if ($derby.Count -or $derby_lsn) {
    $dpid = if ($derby.Count) { $derby[0].ProcessId } else { $derby_lsn.OwningProcess }
    $dadr = if ($derby_lsn) { "$($derby_lsn.LocalAddress):1527" } else { "1527" }
    ihwt-fact "Derby network server" "running (pid $dpid, $dadr)"
} else {
    ihwt-fact "Derby network server" "not running"
}
if ($DH) {
    $dflag = $false
    foreach ($f in @("setUserOverrides.cmd", "setUserOverrides.sh")) {
        $uo = ihwt-jp @($DH, "bin", $f)
        if ((Test-Path -LiteralPath $uo) -and (Select-String -LiteralPath $uo -Pattern '^\s*(set\s+|export\s+)?"?DERBY_FLAG="?false"?' -Quiet)) { $dflag = $true }
    }
    ihwt-fact "DERBY_FLAG (setUserOverrides)" $(if ($dflag) { "false" } else { "not set (Derby starts with every server)" })
}
# Forms memory (2026-11-16): frmweb runs OUTSIDE the WLS_FORMS heap. Working
# set counts shared DLLs in every process again - private = PrivatePageCount
# (private bytes). Client = established connection from a socket of the parent
# JVM (Forms Listener servlet), pool = none (06-FormsDiag/forms_perf_analyse.sh).
# Win32_Process only - the Linux test run has no WorkingSetSize / ParentProcessId (StrictMode)
$frm = @($procs | Where-Object { $_.Name -match "^frmweb" })
$est = @()
if ($IHWT_ON_WINDOWS) { $est = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue) }
$frm_rows = @(foreach ($p in $frm) {
    $jports = @($est | Where-Object { $_.OwningProcess -eq $p.ParentProcessId } | ForEach-Object { $_.LocalPort })
    $cl = @($est | Where-Object { $_.OwningProcess -eq $p.ProcessId -and $jports -contains $_.RemotePort }).Count
    $sec = if ("$($p.CommandLine)" -match 'webfile=[^,]*,(\S+)') { $Matches[1] } else { "?" }
    [pscustomobject]@{ Pid = $p.ProcessId; PPid = $p.ParentProcessId; Section = $sec
                       WorkingSetMB = [math]::Round($p.WorkingSetSize / 1MB); PrivateMB = [math]::Round($p.PrivatePageCount / 1MB)
                       Started = $p.CreationDate; Kind = $(if ($cl) { "session" } else { "pool" }) }
})
ihwt-runps 51_forms_memory.txt "frmweb per process (MB): working set, private bytes, session|pool" { if ($frm_rows.Count) { $frm_rows | Format-Table -AutoSize } else { "none" } }
$wls = @($procs | Where-Object { "$($_.CommandLine)" -match "weblogic\.Server" })
$wls_rows = @(foreach ($p in $wls) {
    $c = "$($p.CommandLine)"
    [pscustomobject]@{ Pid = $p.ProcessId; Server = $(if ($c -match '-Dweblogic\.Name=(\S+)') { $Matches[1] } else { "?" })
                       WorkingSetMB = [math]::Round($p.WorkingSetSize / 1MB); PrivateMB = [math]::Round($p.PrivatePageCount / 1MB)
                       Args = ((([regex]::Matches($c, '(-Xm[sx]\S+|-XX:(Max|Min)?(Metaspace|RAMPercentage|HeapFreeRatio)\S*|-XX:\+Use\w*GC|-XX:\+AlwaysPreTouch|-XX:G1PeriodicGCInterval\S*)')) | ForEach-Object { $_.Value }) -join ' ') }
})
ihwt-runps 51_forms_memory.txt "WLS servers: heap / GC arguments, working set, private bytes" { if ($wls_rows.Count) { $wls_rows | Format-List } else { "none" } }
$cfgs = @()
if (ihwt-isdir $DH) { $cfgs = @(Get-ChildItem -LiteralPath (ihwt-jp @($DH, "config", "fmwconfig", "servers")) -Recurse -Filter formsweb.cfg -File -ErrorAction SilentlyContinue) }
ihwt-runps 51_forms_memory.txt "formsweb.cfg prestart / pool keys per section" {
    foreach ($f in $cfgs) { $f.FullName; $s = ""
        foreach ($l in (Get-Content -LiteralPath $f.FullName)) { if ($l -match '^\[') { $s = $l } elseif ($l -match '^\s*(prestart\w*|maxRuntimeProcesses)\s*=') { "  $s $l" } } }
}
if ($frm_rows.Count) {
    $ses = @($frm_rows | Where-Object { $_.Kind -eq "session" })
    $per = if ($ses.Count) { [math]::Round(($ses | Measure-Object PrivateMB -Sum).Sum / $ses.Count) } else { "-" }
    ihwt-fact "Forms frmweb memory" ("{0} procs ({1} session, {2} pool): working set {3} MB, private {4} MB, max working set {5} MB, private per session {6} MB" -f `
        $frm_rows.Count, $ses.Count, ($frm_rows.Count - $ses.Count), ($frm_rows | Measure-Object WorkingSetMB -Sum).Sum,
        ($frm_rows | Measure-Object PrivateMB -Sum).Sum, ($frm_rows | Measure-Object WorkingSetMB -Maximum).Maximum, $per)
} else {
    ihwt-fact "Forms frmweb memory" "no frmweb running"
}
ihwt-fact "WLS heap (Xms/Xmx, RSS)" $(if ($wls_rows.Count) { ($wls_rows | ForEach-Object {
        $xs = if ($_.Args -match '(-Xms\S+)') { $Matches[1] } else { "-Xms?" }
        $xm = if ($_.Args -match '(-Xmx\S+)') { $Matches[1] } else { "-Xmx(default 1/4 RAM)" }
        "$($_.Server) $xs/$xm ws=$($_.WorkingSetMB)MB" }) -join '; ' } else { "no WLS server running" })
if ($DH) {
    ihwt-fact "Forms prestart sections" ((@(foreach ($f in $cfgs) { $s = ""
        foreach ($l in (Get-Content -LiteralPath $f.FullName)) { if ($l -match '^\[') { $s = $l } elseif ($l -match '^\s*prestartRuntimes\s*=\s*true') { $s } } })) -join ' ')
}

#==============================================================================
# 6. Oracle Net, web tier
#==============================================================================
ihwt-say "6/8 Oracle Net / web tier"
$tns_dirs = New-Object System.Collections.Generic.List[string]
if ($env:TNS_ADMIN) { $tns_dirs.Add($env:TNS_ADMIN) }
if ($IHWT_ON_WINDOWS) {
    foreach ($k in @(Get-ChildItem -LiteralPath "HKLM:\SOFTWARE\Oracle" -ErrorAction SilentlyContinue)) {
        $v = (Get-ItemProperty -LiteralPath $k.PSPath -Name TNS_ADMIN -ErrorAction SilentlyContinue).TNS_ADMIN
        if ($v) { $tns_dirs.Add($v) }
    }
    $v = [Environment]::GetEnvironmentVariable('TNS_ADMIN', 'Machine'); if ($v) { $tns_dirs.Add($v) }
}
if ($DH) { $tns_dirs.Add((ihwt-jp @($DH, "config", "fmwconfig"))) }
if ($OH) { $tns_dirs.Add((ihwt-jp @($OH, "network", "admin"))) }
# where the Oracle Net files are (one TNS_ADMIN?) - the content is in the export
$netf = @(foreach ($d in @($tns_dirs | Sort-Object -Unique)) { if (ihwt-isdir $d) {
    Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('tnsnames.ora', 'sqlnet.ora', 'ldap.ora') } | Select-Object -First 10 } })
ihwt-block 60_net.txt "tnsnames.ora / sqlnet.ora / ldap.ora (list only - content: export)" (((@($netf | ForEach-Object { "{0} {1,8} {2}" -f $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm"), $_.Length, $_.FullName })) -join "`n"))
ihwt-fact "TNS_ADMIN candidates" ((@($tns_dirs | Sort-Object -Unique)) -join ' ; ')
if ($IHWT_ON_WINDOWS) {
    ihwt-runps 61_webserver.txt "Which process owns 80 / 443 / 7777 / 4443 / 8080 / 8443" { $pn = @{}; Get-Process | ForEach-Object { $pn[$_.Id] = $_.ProcessName }; Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in 80, 443, 7777, 4443, 8080, 8443 } | Format-Table -AutoSize LocalAddress, LocalPort, OwningProcess, @{n='Process';e={$pn[[int]$_.OwningProcess]}} }
    ihwt-runps 61_webserver.txt "IIS (W3SVC) and the WebLogic IIS plug-in" {
        Get-Service W3SVC -ErrorAction SilentlyContinue | Format-List Name, Status, StartType
        if (Test-Path "$env:windir\System32\inetsrv\config\applicationHost.config") {
            Select-String -LiteralPath "$env:windir\System32\inetsrv\config\applicationHost.config" -Pattern 'iisproxy|iisforward|<site |bindingInformation' | ForEach-Object { $_.Line.Trim() }
        }
    }
}
# every web server (Nginx installed by hand, IIS, OHS, Apache): routing and rated
# directives (ihw_tools_lib.ps1, same format as bash); the configuration itself
# is in the export
$ngx_inst = @(ihwt-nginx-installs $procs)
$wt_found = @(ihwt-webtier-find @($DH) $procs $ngx_inst)
$wt_rows = @(); $wt_set = @(); $wt_flat = @(); $wt_unread = 0
foreach ($e in $wt_found) {
    $t, $m = $e -split ';', 2
    $fl = @(ihwt-webtier-flatten $t $m); $wt_flat += $fl
    $wt_unread += @($fl | Where-Object { $_ -like '#@@ UNREADABLE*' }).Count
    $wt_rows += @(ihwt-webtier-routes $t $m $fl); $wt_set += @(ihwt-webtier-settings $t $m $fl)
}
ihwt-append 61_webserver.txt ("### Web servers found (type;main configuration)`n{0}`n`n### Routing ({1})`n{2}`n`n### Rated directives (type;conf;key;value;file)`n{3}`n" -f `
    $(if ($wt_found.Count) { $wt_found -join "`n" } else { "none" }), $IHWT_WT_HEAD, ($wt_rows -join "`n"), ($wt_set -join "`n"))
ihwt-fact "Web tier" ((@($wt_found | ForEach-Object { ($_ -split ';')[0] } | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" })) -join ', ')
ihwt-fact "Web tier unreadable" "$wt_unread file(s)"
# patch facts derived from the configuration: WebLogic plug-in (Apache / OHS / IIS), Nginx modules
$wlon = @($wt_flat | Where-Object { $_ -match '^\s*LoadModule\s+weblogic_module' } | ForEach-Object { ($_ -split '\s+')[2] } | Sort-Object -Unique)
$wloff = @($wt_flat | Where-Object { $_ -match '^\s*#\s*LoadModule\s+weblogic_module' }).Count
ihwt-fact "Apache WebLogic plug-in" $(if ($wlon.Count) { "active ($($wlon -join ','))" } elseif ($wloff) { "commented out" } else { "none" })
ihwt-fact "Apache ProxyPass routes" (@($wt_flat | Where-Object { $_ -match '(?i)^\s*ProxyPass\s' }).Count)
ihwt-block 61_webserver.txt "Nginx load_module lines" (((@($wt_flat | Where-Object { $_ -match '^\s*load_module\s' } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)) -join "`n"))
# Nginx = the central web tier of the library; on Windows installed by hand
# (no package manager, OpenSSL linked statically into nginx.exe)
$ngx = @(ihwt-nginx-patch $ngx_inst)
ihwt-block 61_webserver.txt "Nginx patch facts (key;value)" (($ngx -join "`n"))
$nv = { param($k) $l = @($ngx | Where-Object { $_ -like "${k};*" } | Select-Object -First 1); if ($l.Count) { $l[0].Substring($k.Length + 1) } else { "" } }
if ((& $nv "installed") -eq "yes") {
    ihwt-fact "Nginx" ("{0} ({1}); origin {2}; {3}" -f (& $nv "version"), (& $nv "binary"), (& $nv "origin"), (& $nv "line"))
    ihwt-fact "Nginx OpenSSL" (& $nv "openssl")
    ihwt-fact "Nginx binary date" (& $nv "binary_date")
    ihwt-fact "Nginx started by" (& $nv "started_by")
    ihwt-fact "Nginx restart pending" (& $nv "restart_pending")
    ihwt-fact "Nginx installs" (& $nv "installs")
    if (& $nv "writable_by_non_admins") { ihwt-fact "Nginx dir writable by non-admins" (& $nv "writable_by_non_admins") }
} else { ihwt-fact "Nginx" "not installed" }
if (-not $wt_found.Count -and @($procs | Where-Object { "$($_.CommandLine)" -match 'weblogic\.Server' }).Count) {
    ihwt-fact "Web tier hint" "no web server on this host while WebLogic runs - web tier on another host? run the collector there"
}
# certificates of every HTTPS listener (public part: subject / issuer / expiry)
$certs = @(ihwt-certificates $wt_rows)
ihwt-write-file (Join-Path $OUT "62_certificates.txt") (@("source;subject;issuer;not_after") + $certs)
$exp = @($certs | ForEach-Object { ($_ -split ';')[3] } | Where-Object { $_ -notmatch 'not reachable' } | ForEach-Object { try { [datetime]::ParseExact(($_ -replace ' GMT$', ''), 'MMM d HH:mm:ss yyyy', [Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-dd') } catch { } } | Sort-Object)
ihwt-fact "HTTPS certificates" ("{0} - first expiry: {1}" -f $certs.Count, $(if ($exp.Count) { $exp[0] } else { "" }))

#==============================================================================
# 7. Load profile - AGGREGATED counts only (ihw_tools_lib.ps1 ihwt-load-profile)
#==============================================================================
ihwt-say "7/8 Load profile"
if (-not $NoLoad -and $DH) {
    ihwt-load-profile $DH (Join-Path $OUT "load") $LoadDays $procs $RWAUTH
    ihwt-fact "Load profile" "load/ (last $LoadDays days, aggregated)"
} else {
    ihwt-fact "Load profile" ("not collected ({0})" -f $(if ($NoLoad) { "-NoLoad" } else { "no DOMAIN_HOME" }))
}
$RWAUTH = ""

#==============================================================================
# 8. Logs (sizes always, error lines only with -Logs)
#==============================================================================
ihwt-say "8/8 Logs"
if ($DH) {
    # a wildcard in the middle of -Path returns the logs directories themselves - list each one
    $logfiles = @(Get-ChildItem -LiteralPath (Join-Path $DH "servers") -Directory -ErrorAction SilentlyContinue |
                  ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_.FullName "logs") -File -ErrorAction SilentlyContinue })
    ihwt-runps 70_logs.txt "Server log files" { $logfiles | Sort-Object FullName | Format-Table -AutoSize LastWriteTime, Length, FullName }
    ihwt-runps 70_logs.txt "Error counts per server log" { $logfiles | Where-Object { $_.Extension -eq '.log' } | ForEach-Object { "{0,6} {1}" -f @(Select-String -LiteralPath $_.FullName -Pattern '<Error>' -SimpleMatch -ErrorAction SilentlyContinue).Count, $_.FullName } }
    if ($Logs) {
        foreach ($f in @($logfiles | Where-Object { $_.Extension -in @('.log', '.out') })) {
            $lines = @(Select-String -LiteralPath $f.FullName -Pattern '<Error>|<Critical>|<Alert>|<Emergency>|FRM-|REP-|ORA-' -ErrorAction SilentlyContinue | Select-Object -Last 200 | ForEach-Object { $_.Line })
            ihwt-append 71_log_errors.txt ("### errors: {0}`n{1}`n" -f $f.FullName, (ihwt-mask ($lines -join "`n")))
        }
    }
}
if ($Logs -and $IHWT_ON_WINDOWS) {
    ihwt-runps 72_eventlog.txt "Windows event log: errors Application / System, last 7 days (max 300)" {
        Get-WinEvent -FilterHashtable @{ LogName = 'Application', 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 300 -ErrorAction SilentlyContinue |
            Format-Table -AutoSize -Wrap TimeCreated, LogName, ProviderName, Id, @{n='Message';e={ ($_.Message -split "`n")[0] }}
    }
}

#==============================================================================
# Pack
#==============================================================================
ihwt-append-file $SUM "`nFiles:"
Get-ChildItem -LiteralPath $OUT -File | ForEach-Object { ihwt-append-file $SUM ("{0,10}  {1}" -f $_.Length, $_.Name) }
$arch = ihwt-pack $OutBase $NAME $PASS
$PASS = ""
if (-not $arch) { Write-Host "packing failed - the directory $OUT is kept" -ForegroundColor Red; exit 2 }
if (-not $Keep) { Remove-Item -LiteralPath $OUT -Recurse -Force }
ihwt-say ("Archive : {0} ({1} KB)" -f (Join-Path $OutBase $arch), [math]::Round((Get-Item -LiteralPath (Join-Path $OutBase $arch)).Length / 1KB))
ihwt-say "SHA-256 : $(Join-Path $OutBase "$arch.sha256")"
if ($arch -like '*.enc') { ihwt-say "Decrypt : openssl enc -d $IHWT_ENC_OPTS -in $arch -out $($arch -replace '\.enc$', '')" }
if ($Keep) { ihwt-say "Kept    : $OUT (00_summary.txt = key facts)" }
ihwt-say "Secrets are masked; host names, IPs and paths are included - send the encrypted archive."
ihwt-say "For the analysis also run export_forms_reports_conf.ps1 (configuration) on this host."
exit 0
