#Requires -Version 5.1
#==============================================================================
# Script   : collect_fmw_env.ps1
# Purpose  : Collect the metadata of an Oracle Forms & Reports / FMW host on
#            MS Windows Server (12.2.1.x and 14.1.2) - from the OS to Forms -
#            into one directory + ZIP for analysis.
#            Windows / PowerShell version of tools/bash/collect_fmw_env.sh
#            (same file layout 00_summary.txt, 10_os.txt ... 71_log_errors.txt).
#            READ-ONLY: writes only into the output directory (OPatch itself
#            writes its usual logs to ORACLE_HOME\cfgtoollogs when it reads
#            the inventory). Secrets are masked before they are stored.
#            Standalone - no library.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
#==============================================================================
<#
.SYNOPSIS
  Collect the FMW / Forms / Reports metadata of a Windows host (read-only, masked).

.DESCRIPTION
  Areas: OS (hotfixes, volumes, firewall, listening ports), Windows services,
  Java, Oracle Home / inventory / OPatch, domain configuration, Forms / Reports
  configuration files, running processes, Oracle Net, web tier (IIS / OHS),
  logs (+ Windows event log with -Logs).
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
    [switch] $Version
)

Set-StrictMode -Version 2
$SCRIPT_VERSION = "2026-11-13.1"   # bump on every change - shown in 00_summary.txt
if ($Version) { Write-Output $SCRIPT_VERSION; exit 0 }

$on_windows = ([Environment]::OSVersion.Platform -eq 'Win32NT')
$host_name  = [Environment]::MachineName
$ts         = Get-Date -Format "yyyyMMdd_HHmmss"
$OUT        = Join-Path $OutBase ("fmw_collect_{0}_{1}" -f $host_name, $ts)
try { New-Item -ItemType Directory -Path $OUT -Force -ErrorAction Stop | Out-Null }
catch { Write-Host "Cannot create $OUT : $_" -ForegroundColor Red; exit 2 }
$SUM = Join-Path $OUT "00_summary.txt"

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
# Mask secrets - same rules as mask() of tools/bash/collect_fmw_env.sh
function local-mask {
    param([string] $Text)
    if (-not $Text) { return $Text }
    $t = $Text
    $t = [regex]::Replace($t, '(<[^>/]*[Pp]ass[Ww]or[dD][^>]*>)[^<]*', '$1***MASKED***')
    $t = [regex]::Replace($t, '\{AES(256)?\}[A-Za-z0-9+/=]+', '{AES}***MASKED***')
    $t = [regex]::Replace($t, '(?m)((^|[\s;&?])(userid|USERID|UserId|authid|AUTHID|password|PASSWORD|Password|passwd|pwd|PWD)[ \t]*=[ \t]*)[^\s;&]+', '$1***MASKED***')
    $t = [regex]::Replace($t, '(-D[A-Za-z0-9._]*[Pp]ass[Ww]ord[A-Za-z0-9._]*=)\S+', '$1***MASKED***')
    $t = [regex]::Replace($t, '([A-Za-z0-9_]+)/[^@\s/]+@', '$1/***MASKED***@')
    return $t
}
function local-append { param([string] $File, [string] $Text) Add-Content -LiteralPath (Join-Path $OUT $File) -Value $Text -Encoding UTF8 }
function local-fact   { param([string] $Key, [string] $Value) Add-Content -LiteralPath $SUM -Value ("{0,-28} {1}" -f $Key, $Value) -Encoding UTF8 }
function local-say    { param([string] $Text) Write-Host "  $Text" }

# local-runps FILE TITLE { scriptblock } - PowerShell output, masked
function local-runps {
    param([string] $File, [string] $Title, [scriptblock] $Block)
    $txt = ""
    try { $txt = (& $Block 2>&1 | Out-String -Width 4096) ; $rc = 0 }
    catch { $txt = "ERROR: $_"; $rc = 1 }
    local-append $File ("### {0}`n### PS> {1}`n{2}`n### rc={3}`n" -f $Title, $Block.ToString().Trim(), (local-mask $txt), $rc)
}

# local-exec EXE ARGS... - run an external program (timeout 600 s), returns
# @{Out; Rc}. .bat / .cmd run through cmd.exe.
function local-exec {
    param([string] $Exe, [string[]] $Arguments = @(), [hashtable] $EnvVars = @{})
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $q = @($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
    if ($on_windows -and $Exe -match '\.(bat|cmd)$') {
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/d /c ""' + $Exe + '" ' + ($q -join ' ') + '"'
    } else {
        $psi.FileName = $Exe
        $psi.Arguments = ($q -join ' ')
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[$k] = $EnvVars[$k] }
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(600000)) { try { $p.Kill() } catch { }; return @{ Out = "TIMEOUT after 600 s"; Rc = 124 } }
        return @{ Out = ($o.Result + $e.Result); Rc = $p.ExitCode }
    } catch { return @{ Out = "ERROR: $_"; Rc = 127 } }
}
# local-run FILE TITLE EXE ARGS... - external program into a file, masked
function local-run {
    param([string] $File, [string] $Title, [string] $Exe, [string[]] $Arguments = @(), [hashtable] $EnvVars = @{})
    $r = local-exec $Exe $Arguments $EnvVars
    local-append $File ("### {0}`n### $ {1} {2}`n{3}`n### rc={4}`n" -f $Title, $Exe, ($Arguments -join ' '), (local-mask $r.Out), $r.Rc)
}
# local-copy FILE SOURCE - masked copy of a config file
function local-copy {
    param([string] $File, [string] $Src)
    if (-not $Src -or -not (Test-Path -LiteralPath $Src -PathType Leaf)) { return }
    try {
        $fi = Get-Item -LiteralPath $Src -Force
        $txt = [IO.File]::ReadAllText($fi.FullName)
        local-append $File ("### file: {0} ({1} bytes, {2})`n{3}`n" -f $fi.FullName, $fi.Length, $fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm"), (local-mask $txt))
    } catch { local-append $File "### not readable: $Src ($_)" }
}
function local-isdir { param([string] $p) return ($p -and (Test-Path -LiteralPath $p -PathType Container)) }
function local-prop  { param([string] $v) return ($v -replace '\\:', ':' -replace '\\\\', '\') }
function local-jp    { param([string[]] $Parts) $p = $Parts[0]; for ($i = 1; $i -lt $Parts.Count; $i++) { $p = Join-Path $p $Parts[$i] }; return $p }

local-say "collect_fmw_env.ps1 version $SCRIPT_VERSION"
local-say "Output: $OUT"

# running processes (CIM on Windows; ps for a test run on Linux)
$procs = @()
if ($on_windows) {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
} else {
    $procs = @(& ps -eo pid=,args= 2>$null | ForEach-Object {
        if ($_ -match '^\s*(\d+)\s+(.*)$') {
            $exe = ""; try { $exe = (Get-Item -LiteralPath "/proc/$($Matches[1])/exe" -ErrorAction Stop).Target } catch { }
            [pscustomobject]@{ ProcessId = [int]$Matches[1]; Name = (($Matches[2] -split ' ')[0] | Split-Path -Leaf); CommandLine = $Matches[2]; ExecutablePath = "$exe" }
        } })
}
$fmw_pat = 'weblogic\.(Server|NodeManager)|frmweb|rwserver|rwengine|rwEng|rwrun|httpd|nginx|beasvc|NetworkServerControl'

#------------------------------------------------------------------------------
# Locate ORACLE_HOME / DOMAIN_HOME
#------------------------------------------------------------------------------
if (-not (local-isdir (Join-Path "$OracleHome" "OPatch"))) {
    $OracleHome = ""
    foreach ($p in $procs) {
        if ("$($p.CommandLine)" -match '-Dweblogic\.home="?([^"\s]+?)[\\/]wlserver[\\/]server') { $OracleHome = $Matches[1]; break }
    }
    if (-not (local-isdir (Join-Path "$OracleHome" "OPatch")) -and $on_windows) {
        $OracleHome = ""
        foreach ($k in @(Get-ChildItem -LiteralPath "HKLM:\SOFTWARE\Oracle" -ErrorAction SilentlyContinue)) {
            $v = (Get-ItemProperty -LiteralPath $k.PSPath -Name ORACLE_HOME -ErrorAction SilentlyContinue).ORACLE_HOME
            if ($v -and (local-isdir (Join-Path $v "OPatch")) -and (local-isdir (Join-Path $v "wlserver"))) { $OracleHome = $v; break }
        }
        if (-not $OracleHome) {
            foreach ($d in @("C:", "D:", "E:")) {
                foreach ($s in @("\Oracle\Middleware\Oracle_Home", "\Oracle\Oracle_Home", "\Oracle\fmw", "\app\oracle\fmw", "\oracle\product\mw")) {
                    if (local-isdir "$d$s\OPatch") { $OracleHome = "$d$s"; break }
                }
                if ($OracleHome) { break }
            }
        }
    }
}
if (-not (local-isdir (Join-Path "$OracleHome" "OPatch"))) { Write-Host "ORACLE_HOME not found - use -OracleHome" -ForegroundColor Yellow; $OracleHome = "" }
if (-not $DomainHome -and $OracleHome -and (Test-Path -LiteralPath (Join-Path $OracleHome "domain-registry.xml"))) {
    $m = Select-String -LiteralPath (Join-Path $OracleHome "domain-registry.xml") -Pattern 'location="([^"]*)"' | Select-Object -First 1
    if ($m) { $DomainHome = $m.Matches[0].Groups[1].Value }
}
if (-not $DomainHome) {
    foreach ($p in $procs) { if ("$($p.CommandLine)" -match '-Dweblogic\.RootDirectory="?([^"\s]+)') { $DomainHome = $Matches[1]; break } }
}
if ($DomainHome -and -not (Test-Path -LiteralPath (local-jp @($DomainHome, "config", "config.xml")))) {
    Write-Host "DOMAIN_HOME $DomainHome has no config.xml - use -DomainHome" -ForegroundColor Yellow; $DomainHome = ""
}
$OH = $OracleHome; $DH = $DomainHome

Set-Content -LiteralPath $SUM -Encoding UTF8 -Value @(
    ("FMW environment collection - {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")),
    "collect_fmw_env.ps1 version $SCRIPT_VERSION (read-only, secrets masked)", "")
local-fact "Host" ([System.Net.Dns]::GetHostEntry([string]$host_name).HostName)
local-fact "User" ("{0}\{1}" -f [Environment]::UserDomainName, [Environment]::UserName)
if ($on_windows) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    local-fact "Administrator" "$admin"
}
local-fact "PowerShell" ("{0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
local-fact "ORACLE_HOME" $(if ($OH) { $OH } else { "(not found)" })
local-fact "DOMAIN_HOME" $(if ($DH) { $DH } else { "(not found)" })

#==============================================================================
# 1. Operating system
#==============================================================================
local-say "1/7 OS"
if ($on_windows) {
    local-runps 10_os.txt "OS" { Get-CimInstance Win32_OperatingSystem | Format-List Caption, Version, BuildNumber, OSArchitecture, InstallDate, LastBootUpTime, TotalVisibleMemorySize, FreePhysicalMemory, CodeSet, Locale, OSLanguage }
    local-runps 10_os.txt "Computer" { Get-CimInstance Win32_ComputerSystem | Format-List Name, Domain, Manufacturer, Model, NumberOfProcessors, NumberOfLogicalProcessors, TotalPhysicalMemory, HypervisorPresent }
    local-runps 10_os.txt "Hotfixes (last 30)" { Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 30 | Format-Table -AutoSize HotFixID, Description, InstalledOn }
    local-runps 10_os.txt "Volumes" { Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Format-Table -AutoSize DeviceID, FileSystem, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,1)}}, VolumeName }
    local-runps 10_os.txt "Pagefile" { Get-CimInstance Win32_PageFileUsage | Format-Table -AutoSize Name, AllocatedBaseSize, CurrentUsage, PeakUsage }
    local-runps 10_os.txt "Time zone / culture / code page" { Get-TimeZone | Format-List Id, DisplayName; Get-Culture | Format-List Name, DisplayName; [Console]::OutputEncoding | Format-List CodePage, EncodingName; & cmd.exe /c chcp }
    local-runps 10_os.txt "Windows Firewall profiles" { Get-NetFirewallProfile | Format-Table -AutoSize Name, Enabled, DefaultInboundAction, DefaultOutboundAction }
    local-runps 10_os.txt "Network addresses" { Get-NetIPAddress | Where-Object { $_.AddressState -eq 'Preferred' } | Format-Table -AutoSize InterfaceAlias, AddressFamily, IPAddress, PrefixLength }
    local-runps 10_os.txt "Listening ports" { $pn = @{}; Get-Process | ForEach-Object { $pn[$_.Id] = $_.ProcessName }; Get-NetTCPConnection -State Listen | Sort-Object LocalPort | Format-Table -AutoSize LocalAddress, LocalPort, OwningProcess, @{n='Process';e={$pn[[int]$_.OwningProcess]}} }
    local-runps 10_os.txt "Scheduled tasks (Oracle / WebLogic / Forms / Reports)" { Get-ScheduledTask | Where-Object { "$($_.TaskName) $($_.Actions.Execute) $($_.Actions.Arguments)" -match '(?i)oracle|weblogic|wls|fmw|forms|report|nodemanager' } | Format-Table -AutoSize TaskPath, TaskName, State, @{n='Action';e={"$($_.Actions.Execute) $($_.Actions.Arguments)"}} }
    local-runps 10_os.txt "Environment (system)" { [Environment]::GetEnvironmentVariables('Machine').GetEnumerator() | Sort-Object Name | Format-Table -AutoSize -Wrap Name, Value }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        local-fact "OS" ("{0} (build {1})" -f $os.Caption, $os.BuildNumber)
        local-fact "Uptime" ("{0:dd}d {0:hh}h (since {1})" -f ((Get-Date) - $os.LastBootUpTime), $os.LastBootUpTime)
        local-fact "Memory MB (total/free)" ("{0} / {1}" -f [math]::Round($os.TotalVisibleMemorySize / 1KB), [math]::Round($os.FreePhysicalMemory / 1KB))
    }
    local-fact "Last hotfix" ("{0}" -f (Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1 | ForEach-Object { "$($_.HotFixID) $($_.InstalledOn)" }))
} else {
    local-runps 10_os.txt "OS (not Windows - test run)" { Get-Content /etc/os-release; & uname -a }
}

#==============================================================================
# 2. Java
#==============================================================================
local-say "2/7 Java"
$ge_file = ""; $jdk_ge = ""
if ($OH) {
    $ge_file = local-jp @($OH, "oui", ".globalEnv.properties")
    $m = Select-String -LiteralPath $ge_file -Pattern '^JAVA_HOME=(.*)$' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { $jdk_ge = local-prop $m.Matches[0].Groups[1].Value.Trim() }
}
$jcand = New-Object System.Collections.Generic.List[string]
if ($OH) {
    Select-String -LiteralPath $ge_file -Pattern '^JAVA_HOME[A-Z0-9_]*=(.*)$' -ErrorAction SilentlyContinue | ForEach-Object { $jcand.Add((local-prop $_.Matches[0].Groups[1].Value.Trim())) }
    $jcand.Add((local-jp @($OH, "oracle_common", "jdk")))
}
if ($env:JAVA_HOME) { $jcand.Add($env:JAVA_HOME) }
foreach ($p in $procs) {
    if ("$($p.ExecutablePath)" -match '^(.*)[\\/]bin[\\/]javaw?(\.exe)?$') { $jcand.Add(($Matches[1] -replace '[\\/]jre$', '')) }
}
$jdks = @($jcand | Where-Object { $_ } | Sort-Object -Unique)
foreach ($j in $jdks) {
    $jx = local-jp @($j, "bin", "java.exe"); if (-not (Test-Path -LiteralPath $jx)) { $jx = local-jp @($j, "bin", "java") }
    if (-not (Test-Path -LiteralPath $jx -PathType Leaf)) { continue }
    local-run 20_java.txt "java -version: $j" $jx @("-version")
    local-runps 20_java.txt "link / release: $j" ([scriptblock]::Create("`$i = Get-Item -LiteralPath '$($j -replace "'", "''")' -Force; `"LinkType: `$(`$i.LinkType)  Target: `$(@(`$i.Target) -join ' ')`"; Get-Content -LiteralPath (Join-Path '$($j -replace "'", "''")' 'release') -ErrorAction SilentlyContinue"))
}
local-runps 20_java.txt "Java of the running processes" { $procs | Where-Object { $_.Name -match '^javaw?(\.exe)?$' } | Format-Table -AutoSize ProcessId, ExecutablePath }
if ($ge_file) { local-copy 20_java.txt $ge_file }
local-fact "JDK of OPatch (.globalEnv)" $(if ($jdk_ge) { $jdk_ge } else { "?" })
if ($jdk_ge) {
    $jx = local-jp @($jdk_ge, "bin", "java.exe"); if (-not (Test-Path -LiteralPath $jx)) { $jx = local-jp @($jdk_ge, "bin", "java") }
    if (Test-Path -LiteralPath $jx) { local-fact "JDK version (.globalEnv)" (((local-exec $jx @("-version")).Out -split "`n" | Select-Object -First 2) -join ' ') }
    $it = Get-Item -LiteralPath $jdk_ge -Force -ErrorAction SilentlyContinue
    if ($it) { local-fact "JDK link type" $(if ($it.LinkType) { "$($it.LinkType) -> $(@($it.Target)[0])" } else { "real directory (no junction)" }) }
}
local-fact "JDKs of running processes" ((@($procs | Where-Object { $_.Name -match '^javaw?(\.exe)?$' } | ForEach-Object { $_.ExecutablePath } | Sort-Object -Unique)) -join ' ')

#==============================================================================
# 3. Oracle Home, inventory, patches
#==============================================================================
local-say "3/7 Oracle Home / OPatch"
if ($on_windows) {
    local-runps 30_inventory.txt "Registry HKLM\SOFTWARE\Oracle (inst_loc, KEY_* homes)" {
        foreach ($k in @("HKLM:\SOFTWARE\Oracle", "HKLM:\SOFTWARE\WOW6432Node\Oracle")) {
            if (-not (Test-Path $k)) { continue }
            "[$k]"; Get-ItemProperty -LiteralPath $k | Select-Object * -ExcludeProperty PS* | Format-List
            Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue | ForEach-Object { "[$($_.Name)]"; Get-ItemProperty -LiteralPath $_.PSPath | Select-Object * -ExcludeProperty PS* | Format-List }
        }
    }
}
if ($OH) {
    $inv = ""
    if ($on_windows) { $inv = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Oracle" -Name inst_loc -ErrorAction SilentlyContinue).inst_loc }
    foreach ($c in @((Join-Path $OH "oraInst.loc"), "/etc/oraInst.loc")) {
        if (Test-Path -LiteralPath $c) {
            local-copy 30_inventory.txt $c
            if (-not $inv) { $m = Select-String -LiteralPath $c -Pattern '^inventory_loc=(.*)$' | Select-Object -First 1; if ($m) { $inv = $m.Matches[0].Groups[1].Value.Trim() } }
        }
    }
    if ($inv) { local-copy 30_inventory.txt (local-jp @($inv, "ContentsXML", "inventory.xml")) }
    local-fact "Central inventory" $(if ($inv) { $inv } else { "?" })

    $op = local-jp @($OH, "OPatch", "opatch.bat"); if (-not $on_windows) { $op = local-jp @($OH, "OPatch", "opatch") }
    $openv = @{}; if ($jdk_ge) { $openv["JAVA_HOME"] = $jdk_ge }
    local-run 31_opatch.txt "opatch version"     $op @("version")     $openv
    local-run 31_opatch.txt "opatch lspatches"   $op @("lspatches")   $openv
    local-run 31_opatch.txt "opatch lsinventory" $op @("lsinventory") $openv
    if ($Full) {
        local-run 32_opatch_details.txt "opatch lsinventory -details"    $op @("lsinventory", "-details")    $openv
        local-run 32_opatch_details.txt "opatch lsinventory -bugs_fixed" $op @("lsinventory", "-bugs_fixed") $openv
    }
    $comp_dir = local-jp @($OH, "inventory", "Components")
    local-runps 30_inventory.txt "Components (Forms / Reports / OHS / WebGate / SQL Developer)" ([scriptblock]::Create("Get-ChildItem -LiteralPath '$($comp_dir -replace "'", "''")' -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -match '(?i)forms|reports|ohs|webgate|sqldeveloper|oracle\.rdbms|perl' } | ForEach-Object { `$_.Name }"))
    local-runps 30_inventory.txt "Top level of the Oracle Home" ([scriptblock]::Create("Get-ChildItem -LiteralPath '$($OH -replace "'", "''")' -Force | Format-Table -AutoSize Mode, LastWriteTime, Length, Name"))
    local-runps 30_inventory.txt "Forms / Reports binaries" ([scriptblock]::Create("Get-ChildItem -LiteralPath (Join-Path '$($OH -replace "'", "''")' 'bin') -File -ErrorAction SilentlyContinue | Where-Object { `$_.BaseName -match '^(frmweb|frmcmp|frmcmp_batch|frmbld|rwserver|rwrun|rwbuilder|rwconverter|rwclient)$' } | Format-Table -AutoSize Name, Length, LastWriteTime, @{n='Version';e={`$_.VersionInfo.FileVersion}}"))
    local-copy 30_inventory.txt (Join-Path $OH "domain-registry.xml")

    $r = local-exec $op @("version") $openv
    if ($r.Out -match 'OPatch Version: (\S+)') { local-fact "OPatch" $Matches[1] }
    $r = local-exec $op @("lspatches") $openv
    local-fact "Patches (lspatches)" (@($r.Out -split "`n" | Where-Object { $_ -match '^\d+;' }).Count)
    $comps_xml = local-jp @($OH, "inventory", "ContentsXML", "comps.xml")
    $rc_n = 0
    if (Test-Path -LiteralPath $comps_xml) {
        $cm = @(Select-String -LiteralPath $comps_xml -Pattern 'COMP NAME="(oracle\.(reports|forms|developer)[^"]*)" VER="([^"]*)"' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[3].Value)" } | Sort-Object -Unique)
        local-append 30_inventory.txt ("### Reports / Forms components in comps.xml (OPatch view)`n{0}`n" -f ($cm -join "`n"))
        $rc_n = @($cm | Where-Object { $_ -like 'oracle.reports*' }).Count
    }
    $rb_n = @(Get-ChildItem -LiteralPath (Join-Path $OH "bin") -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('rwserver', 'rwrun', 'rwserver.exe', 'rwrun.exe') }).Count
    local-fact "Reports comps.xml / binaries" "$rc_n component(s) / $rb_n of rwserver,rwrun"
    if ($rc_n -eq 0 -and $rb_n -gt 0) { local-fact "!! Reports NOT REGISTERED" "binaries in the home but no oracle.reports component - OPatch would never patch them" }
    $comps = @(Get-ChildItem -LiteralPath $comp_dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    local-fact "Reports component in home" ("{0} entries" -f @($comps | Where-Object { $_ -match '(?i)reports' }).Count)
    local-fact "OHS component in home" ("{0} entries" -f @($comps | Where-Object { $_ -match '(?i)ohs' }).Count)
}

#==============================================================================
# 4. Domain configuration (masked)
#==============================================================================
local-say "4/7 Domain"
if ($DH) {
    $cfg = local-jp @($DH, "config", "config.xml")
    local-copy 40_config.xml.txt $cfg
    local-runps 40_domain.txt "Servers / listen addresses / ports (config.xml)" ([scriptblock]::Create("Select-String -LiteralPath '$($cfg -replace "'", "''")' -Pattern '<(name|listen-address|listen-port|machine|cluster|enabled|nm-type|listen-port-enabled)>' | Select-Object -First 200 | ForEach-Object { `$_.Line.Trim() }"))
    local-runps 40_domain.txt "Servers on disk" ([scriptblock]::Create("Get-ChildItem -LiteralPath (Join-Path '$($DH -replace "'", "''")' 'servers') -ErrorAction SilentlyContinue | Format-Table -AutoSize Mode, LastWriteTime, Name"))
    local-runps 40_domain.txt "Domain files" ([scriptblock]::Create("foreach (`$s in @('', 'bin', 'nodemanager')) { Get-ChildItem -LiteralPath (Join-Path '$($DH -replace "'", "''")' `$s) -Force -ErrorAction SilentlyContinue | Format-Table -AutoSize Mode, LastWriteTime, Length, FullName }"))
    foreach ($f in @(@("nodemanager", "nodemanager.properties"), @("bin", "setUserOverrides.cmd"), @("bin", "setDomainEnv.cmd"),
                     @("bin", "startNodeManager.cmd"), @("bin", "startWebLogic.cmd"), @("bin", "setUserOverrides.sh"), @("bin", "setDomainEnv.sh"))) {
        local-copy 41_domain_scripts.txt (local-jp (@($DH) + $f))
    }
    foreach ($f in @(Get-ChildItem -LiteralPath (local-jp @($DH, "reports", "bin")) -File -ErrorAction SilentlyContinue)) { local-copy 41_domain_scripts.txt $f.FullName }
    local-runps 40_domain.txt "Versioned JDK paths in the domain (instead of a junction)" ([scriptblock]::Create("Get-ChildItem -LiteralPath (Join-Path '$($DH -replace "'", "''")' 'bin'), (Join-Path '$($DH -replace "'", "''")' 'nodemanager') -File -ErrorAction SilentlyContinue | Select-String -Pattern 'jdk1\.8\.0_|jdk-[0-9]' | Select-Object -First 50 | ForEach-Object { `"`$(`$_.Path):`$(`$_.LineNumber): `$(`$_.Line.Trim())`" }"))
    # Forms / Reports configuration files
    $fmwcfg = local-jp @($DH, "config", "fmwconfig")
    foreach ($pat in @("formsweb.cfg", "default.env", "webutil.cfg", "ftrace.cfg", "registry.dat", "rwserver.conf",
                       "rwservlet.properties", "cgicmd.dat", "uifont.ali", "rwnetwork.conf")) {
        Get-ChildItem -LiteralPath $fmwcfg -Recurse -File -Filter $pat -ErrorAction SilentlyContinue | Select-Object -First 10 |
            ForEach-Object { local-copy 42_forms_reports_config.txt $_.FullName }
    }
    # OHS instances (domain configuration, not the runtime copy)
    foreach ($d in @(Get-ChildItem -LiteralPath (local-jp @($fmwcfg, "components", "OHS")) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "instances" })) {
        foreach ($f in @("httpd.conf", "ssl.conf", "admin.conf", "mod_wl_ohs.conf")) { local-copy 43_ohs_config.txt (Join-Path $d.FullName $f) }
        Get-ChildItem -LiteralPath (Join-Path $d.FullName "moduleconf") -Filter *.conf -File -ErrorAction SilentlyContinue | ForEach-Object { local-copy 43_ohs_config.txt $_.FullName }
    }
    $xml = $null; try { [xml]$xml = [IO.File]::ReadAllText($cfg) } catch { }
    if ($xml) {
        local-fact "Domain" $xml.domain.name
        local-fact "Domain version" $xml.domain.'domain-version'
        # listen-port is missing in config.xml when it is the default 7001 (StrictMode: check the property)
        local-fact "Servers (config.xml)" ((@($xml.domain.server | ForEach-Object { "{0}:{1}" -f $_.name, $(if ($_.PSObject.Properties['listen-port']) { $_.'listen-port' } else { "7001" }) })) -join ' ')
    }
}

#==============================================================================
# 5. Running processes, Windows services
#==============================================================================
local-say "5/7 Processes / services"
$fmw_procs = @($procs | Where-Object { "$($_.Name) $($_.CommandLine)" -match $fmw_pat })
if ($on_windows) {
    local-runps 50_processes.txt "WLS / Node Manager / Forms / Reports / OHS processes" { $fmw_procs | Sort-Object ProcessId | Format-List ProcessId, ParentProcessId, Name, CreationDate, @{n='WorkingSetMB';e={[math]::Round($_.WorkingSetSize/1MB)}}, ExecutablePath, CommandLine }
    local-runps 50_processes.txt "Windows services (Oracle / WebLogic / Node Manager / Forms / Reports / OHS / IIS)" {
        Get-CimInstance Win32_Service | Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match '(?i)oracle|weblogic|wls|beasvc|nodemanager|forms|report|ohs|w3svc|nginx' } |
            Sort-Object Name | Format-List Name, DisplayName, State, StartMode, StartName, ProcessId, PathName
    }
    $svc_run = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' -and "$($_.Name) $($_.DisplayName) $($_.PathName)" -match '(?i)weblogic|wls|beasvc|nodemanager|report|ohs' })
    local-fact "FMW services running" ((@($svc_run | ForEach-Object { $_.Name })) -join ' ')
} else {
    local-runps 50_processes.txt "WLS / Node Manager / Forms / Reports processes (test run)" { $fmw_procs | Format-List ProcessId, Name, ExecutablePath, CommandLine }
}
local-fact "frmweb processes" (@($procs | Where-Object { $_.Name -match '^frmweb' }).Count)
local-fact "WLS servers running" ((@($procs | ForEach-Object { if ("$($_.CommandLine)" -match '-Dweblogic\.Name=(\S+)') { $Matches[1] } } | Sort-Object -Unique)) -join ' ')
# Which home do the running FMW processes come from?
$foreign = @($fmw_procs | ForEach-Object { $_.ExecutablePath } | Where-Object { $_ -match '[\\/](javaw?|frmweb|rwserver|rwrun|rwengine)(\.exe)?$' } | Sort-Object -Unique | Where-Object {
              -not (($OH -and $_.StartsWith($OH, [StringComparison]::OrdinalIgnoreCase)) -or ($jdk_ge -and $_.StartsWith($jdk_ge, [StringComparison]::OrdinalIgnoreCase))) })
local-fact "Processes outside ORACLE_HOME / JDK" $(if ($foreign.Count) { $foreign -join ' ' } else { "none" })
# Apache Derby = WebLogic evaluation database, started by every startWebLogic.cmd
# while DERBY_FLAG is not false (80-FMW-Architecture/fmw_derby_history.md)
$derby = @($procs | Where-Object { "$($_.CommandLine)" -match 'org\.apache\.derby\.drda\.NetworkServerControl\s+start' })
$derby_lsn = $null
if ($on_windows) { $derby_lsn = @(Get-NetTCPConnection -State Listen -LocalPort 1527 -ErrorAction SilentlyContinue) | Select-Object -First 1 }
if ($derby.Count -or $derby_lsn) {
    $dpid = if ($derby.Count) { $derby[0].ProcessId } else { $derby_lsn.OwningProcess }
    $dadr = if ($derby_lsn) { "$($derby_lsn.LocalAddress):1527" } else { "1527" }
    local-fact "Derby network server" "running (pid $dpid, $dadr)"
} else {
    local-fact "Derby network server" "not running"
}
if ($DH) {
    $dflag = $false
    foreach ($f in @("setUserOverrides.cmd", "setUserOverrides.sh")) {
        $uo = local-jp @($DH, "bin", $f)
        if ((Test-Path -LiteralPath $uo) -and (Select-String -LiteralPath $uo -Pattern '^\s*(set\s+|export\s+)?"?DERBY_FLAG="?false"?' -Quiet)) { $dflag = $true }
    }
    local-fact "DERBY_FLAG (setUserOverrides)" $(if ($dflag) { "false" } else { "not set (Derby starts with every server)" })
}

#==============================================================================
# 6. Oracle Net, web tier
#==============================================================================
local-say "6/7 Oracle Net / web tier"
$tns_dirs = New-Object System.Collections.Generic.List[string]
if ($env:TNS_ADMIN) { $tns_dirs.Add($env:TNS_ADMIN) }
if ($on_windows) {
    foreach ($k in @(Get-ChildItem -LiteralPath "HKLM:\SOFTWARE\Oracle" -ErrorAction SilentlyContinue)) {
        $v = (Get-ItemProperty -LiteralPath $k.PSPath -Name TNS_ADMIN -ErrorAction SilentlyContinue).TNS_ADMIN
        if ($v) { $tns_dirs.Add($v) }
    }
    $v = [Environment]::GetEnvironmentVariable('TNS_ADMIN', 'Machine'); if ($v) { $tns_dirs.Add($v) }
}
if ($DH) { $tns_dirs.Add((local-jp @($DH, "config", "fmwconfig"))) }
if ($OH) { $tns_dirs.Add((local-jp @($OH, "network", "admin"))) }
foreach ($d in @($tns_dirs | Sort-Object -Unique)) {
    if (-not (local-isdir $d)) { continue }
    Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('tnsnames.ora', 'sqlnet.ora', 'ldap.ora') } |
        Select-Object -First 10 | ForEach-Object { local-copy 60_net.txt $_.FullName }
}
local-fact "TNS_ADMIN candidates" ((@($tns_dirs | Sort-Object -Unique)) -join ' ; ')
if ($on_windows) {
    local-runps 61_webserver.txt "Which process owns 80 / 443 / 7777 / 4443 / 8080 / 8443" { $pn = @{}; Get-Process | ForEach-Object { $pn[$_.Id] = $_.ProcessName }; Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in 80, 443, 7777, 4443, 8080, 8443 } | Format-Table -AutoSize LocalAddress, LocalPort, OwningProcess, @{n='Process';e={$pn[[int]$_.OwningProcess]}} }
    local-runps 61_webserver.txt "IIS (W3SVC) and the WebLogic IIS plug-in" {
        Get-Service W3SVC -ErrorAction SilentlyContinue | Format-List Name, Status, StartType
        if (Test-Path "$env:windir\System32\inetsrv\config\applicationHost.config") {
            Select-String -LiteralPath "$env:windir\System32\inetsrv\config\applicationHost.config" -Pattern 'iisproxy|iisforward|<site |bindingInformation' | ForEach-Object { $_.Line.Trim() }
        }
    }
    foreach ($f in @(Get-ChildItem -Path "C:\nginx*\conf", "D:\nginx*\conf" -Filter *.conf -File -ErrorAction SilentlyContinue)) { local-copy 61_webserver.txt $f.FullName }
}

#==============================================================================
# 7. Logs (sizes always, error lines only with -Logs)
#==============================================================================
local-say "7/7 Logs"
if ($DH) {
    # a wildcard in the middle of -Path returns the logs directories themselves - list each one
    $logfiles = @(Get-ChildItem -LiteralPath (Join-Path $DH "servers") -Directory -ErrorAction SilentlyContinue |
                  ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_.FullName "logs") -File -ErrorAction SilentlyContinue })
    local-runps 70_logs.txt "Server log files" { $logfiles | Sort-Object FullName | Format-Table -AutoSize LastWriteTime, Length, FullName }
    local-runps 70_logs.txt "Error counts per server log" { $logfiles | Where-Object { $_.Extension -eq '.log' } | ForEach-Object { "{0,6} {1}" -f @(Select-String -LiteralPath $_.FullName -Pattern '<Error>' -SimpleMatch -ErrorAction SilentlyContinue).Count, $_.FullName } }
    if ($Logs) {
        foreach ($f in @($logfiles | Where-Object { $_.Extension -in @('.log', '.out') })) {
            $lines = @(Select-String -LiteralPath $f.FullName -Pattern '<Error>|<Critical>|<Alert>|<Emergency>|FRM-|REP-|ORA-' -ErrorAction SilentlyContinue | Select-Object -Last 200 | ForEach-Object { $_.Line })
            local-append 71_log_errors.txt ("### errors: {0}`n{1}`n" -f $f.FullName, (local-mask ($lines -join "`n")))
        }
    }
}
if ($Logs -and $on_windows) {
    local-runps 72_eventlog.txt "Windows event log: errors Application / System, last 7 days (max 300)" {
        Get-WinEvent -FilterHashtable @{ LogName = 'Application', 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 300 -ErrorAction SilentlyContinue |
            Format-Table -AutoSize -Wrap TimeCreated, LogName, ProviderName, Id, @{n='Message';e={ ($_.Message -split "`n")[0] }}
    }
}

#==============================================================================
# Pack
#==============================================================================
Add-Content -LiteralPath $SUM -Value "`nFiles:" -Encoding UTF8
Get-ChildItem -LiteralPath $OUT -File | ForEach-Object { Add-Content -LiteralPath $SUM -Value ("{0,10}  {1}" -f $_.Length, $_.Name) -Encoding UTF8 }
$zip = "$OUT.zip"
try {
    Compress-Archive -Path (Join-Path $OUT "*") -DestinationPath $zip -Force -ErrorAction Stop
    local-say "Summary : $SUM"
    local-say ("Archive : {0} ({1} KB)" -f $zip, [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB))
} catch { local-say "Summary : $SUM"; local-say "ZIP failed: $_ - send the directory instead" }
local-say "Secrets are masked - check 00_summary.txt and the files before sending."
exit 0
