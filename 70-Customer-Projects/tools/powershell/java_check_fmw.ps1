#Requires -Version 5.1
#==============================================================================
# Script   : java_check_fmw.ps1
# Purpose  : Which Java does this Forms / Reports host really use - and where
#            is a JDK path pinned that breaks after a JDK switch? Windows /
#            PowerShell version of tools/bash/java_check_fmw.sh (same five
#            sections, same rules). READ-ONLY.
#              1. JDK of the configuration: JAVA_HOME of the session,
#                 oui\.globalEnv.properties (WLST / OPatch), setDomainEnv.cmd,
#                 setNMJavaHome.cmd, nodemanager.properties, the Node Manager /
#                 WebLogic Windows services (registry Parameters) - link /
#                 junction or versioned directory, version, Oracle JDK / OpenJDK
#              2. the FMW-bundled JDK ORACLE_HOME\oracle_common\jdk (Reports
#                 engines, the JVM in rwserver, tools): real directory or
#                 replaced by a junction / another JDK, bin\java.exe +
#                 jvm.dll present, files changed after its release file
#              3. Reports: reports.cmd / reports.bat names only
#                 oracle_common\jdk?, the jvm.dll loaded by the running rwserver
#              4. running processes: Node Manager, WebLogic servers, Reports
#                 engines, rwserver, frmweb - executable, version, vendor
#              5. every file with a JDK path: missing directory = FAIL,
#                 versioned directory instead of the link = WARN, file + line
#            Runs on Linux with pwsh too (test; same output as the bash tool).
#            Needs ihw_tools_lib.ps1 next to it.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
#==============================================================================
<#
.SYNOPSIS
  Java of a Forms / Reports host: configuration, bundled JDK, Reports,
  running processes, pinned JDK paths (read-only).
.PARAMETER OracleHome
  FMW Oracle Home (default: environment, running WebLogic, registry, C:/D:/E:\Oracle\...).
.PARAMETER DomainHome
  WebLogic domain (default: domain-registry.xml, running WebLogic).
.PARAMETER OutBase
  Directory of the log file (default TEMP).
.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\java_check_fmw.ps1
.NOTES
  Exit 0 = ok, 1 = warnings, 2 = failures (something will not start).
  Doc: 70-Customer-Projects/tools/powershell/README.md
#>
[CmdletBinding()]
param(
    [string] $OracleHome = $env:ORACLE_HOME,
    [string] $DomainHome = $env:DOMAIN_HOME,
    [string] $OutBase = $(if ($env:TEMP) { $env:TEMP } else { "/tmp" }),
    [switch] $Version
)
Set-StrictMode -Version 2
$SCRIPT_VERSION = "2026-11-26.1"   # bump on every change
if ($Version) { Write-Output $SCRIPT_VERSION; exit 0 }
$lib = Join-Path $PSScriptRoot "ihw_tools_lib.ps1"
if (-not (Test-Path -LiteralPath $lib)) { Write-Host "ihw_tools_lib.ps1 missing next to $PSCommandPath" -ForegroundColor Red; exit 2 }
. $lib

$LOG = Join-Path $OutBase ("java_check_{0}_{1}.log" -f [Environment]::MachineName, (Get-Date -Format "yyyyMMdd_HHmmss"))
try { ihwt-write-file $LOG @() } catch { $LOG = "" }
$script:N_WARN = 0; $script:N_FAIL = 0; $FIXLIST = New-Object System.Collections.Generic.List[string]
function _log { param([string] $t) if ($LOG) { ihwt-append-file $LOG $t } }
function _p    { param([string] $t) Write-Host $t; _log $t }
function ok    { param([string] $t) Write-Host "  OK   " -ForegroundColor Green -NoNewline; Write-Host $t; _log "  OK   $t" }
function warn  { param([string] $t) $script:N_WARN++; Write-Host " WARN  " -ForegroundColor Yellow -NoNewline; Write-Host $t; _log " WARN  $t" }
function fail  { param([string] $t) $script:N_FAIL++; Write-Host " FAIL  " -ForegroundColor Red -NoNewline; Write-Host $t; _log " FAIL  $t" }
function info  { param([string] $t) _p "       $t" }
function section { param([string] $t) _p ""; _p "=== $t ===" }
function fixit { param([string] $t) if (-not $FIXLIST.Contains($t)) { $FIXLIST.Add($t) } }

$procs = @(ihwt-procs)
$homes = ihwt-find-homes $OracleHome $DomainHome $procs
$OH = "$($homes.OH)".TrimEnd('\', '/'); $DH = "$($homes.DH)".TrimEnd('\', '/')
if (-not $OH) { Write-Host "ORACLE_HOME not found - use -OracleHome" -ForegroundColor Red; exit 2 }
$EXE = if ($IHWT_ON_WINDOWS) { "java.exe" } else { "java" }
$BUNDLED = ihwt-jp @($OH, "oracle_common", "jdk")

# --- helpers -------------------------------------------------------------------
$JV = @{}
# _jver JAVA_BIN -> "17.0.12 Oracle" / "21.0.9 OpenJDK" (cached)
function _jver {
    param([string] $b)
    if ($JV.ContainsKey($b)) { return $JV[$b] }
    if (-not $b -or -not (Test-Path -LiteralPath $b -PathType Leaf)) { return "not executable" }
    $o = (& $b -version 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $v = if ($o -match 'version "([^"]+)"') { $Matches[1] } else { "?" }
    $vend = if ($o -match 'OpenJDK') { "OpenJDK" } elseif ($o -match 'HotSpot|Java\(TM\)') { "Oracle" } else { "?" }
    $JV[$b] = "$v $vend"; return $JV[$b]
}
# _real PATH -> target of a symlink / junction (also of a parent directory)
function _real {
    param([string] $p)
    try {
        $i = Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if ($i.LinkType) { $t = @($i.Target)[0]; if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path -Parent $p) $t }; return (_real $t) }
        $par = Split-Path -Parent $p
        if ($par -and $par -ne $p) { return (Join-Path (_real $par) (Split-Path -Leaf $p)) }
        return $p
    } catch { return $p }
}
function _islink { param([string] $p) try { return [bool](Get-Item -LiteralPath $p -Force -ErrorAction Stop).LinkType } catch { return $false } }
function _kind {
    param([string] $p)
    if (_islink $p) { return "link" }
    if ((Split-Path -Leaf $p) -match '^(jdk|jre|java)[-_]?\d+[._]\d') { return "versioned" }
    return "plain"
}
# _jdk_of PATH -> JDK root of ...\bin\java(.exe) / ...\bin\server\jvm.dll / .../lib/server/libjvm.so
function _jdk_of { param([string] $p) return ($p -replace '[\\/](jre[\\/])?(bin[\\/]java(\.exe)?|bin[\\/]server[\\/]jvm\.dll|lib[\\/]server[\\/]libjvm\.so|lib[\\/]libjvm\.so)$', '') }
function _same { param([string] $a, [string] $b) return ((ihwt-fwd (_real $a)).TrimEnd('/') -ieq (ihwt-fwd (_real $b)).TrimEnd('/')) }
function _javabin { param([string] $jdk) return (ihwt-jp @($jdk, "bin", $EXE)) }

_p "java_check_fmw.ps1 $SCRIPT_VERSION - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
_p "ORACLE_HOME : $OH"
_p "DOMAIN_HOME : $(if ($DH) { $DH } else { '<not found>' })"
_p "Log         : $LOG"

#==============================================================================
# 1. JDK of the configuration
#==============================================================================
section "1. JDK of the configuration (who starts with which JAVA_HOME)"
$CFG = [ordered]@{}
function _cfgjdk { param([string] $k, [string] $v) if ($v) { $CFG[$k] = $v.Trim().Trim('"').TrimEnd('\', '/') } }
# literal value of KEY=... (set KEY=..., export KEY=...) - lines that only pass a variable on are skipped
function _litval {
    param([string] $f, [string] $key)
    $r = ""
    foreach ($l in @(_ihwt-lines $f)) {
        if ($l -match "^\s*(set\s+|export\s+)?`"?$key=`"?([^`"]*)`"?\s*$" -and $Matches[2] -notmatch '[%$]') { $r = $Matches[2] }
    }
    return $r
}
_cfgjdk "session JAVA_HOME" "$env:JAVA_HOME"
_cfgjdk "oui\.globalEnv.properties (WLST, OPatch)" (_litval (ihwt-jp @($OH, "oui", ".globalEnv.properties")) "JAVA_HOME")
if ($DH) {
    foreach ($s in @("setDomainEnv", "setNMJavaHome")) {
        foreach ($ext in @(".cmd", ".sh")) {
            $f = ihwt-jp @($DH, "bin", "$s$ext")
            if (Test-Path -LiteralPath $f) { _cfgjdk "bin\$s$ext" (_litval $f "JAVA_HOME") }
        }
    }
    _cfgjdk "nodemanager\nodemanager.properties (JavaHome)" (ihwt-prop (@(ihwt-cfgval (ihwt-jp @($DH, "nodemanager", "nodemanager.properties")) "JavaHome") | Select-Object -Last 1))
}
$SVCTXT = New-Object System.Collections.Generic.List[string]
if ($IHWT_ON_WINDOWS) {
    foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { "$($_.Name) $($_.DisplayName)" -match '(?i)nodemanager|weblogic|wls|forms|reports' })) {
        $par = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)\Parameters"
        $vals = @()
        try { $pp = Get-ItemProperty -LiteralPath $par -ErrorAction Stop; $vals = @($pp.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) } catch { }
        $SVCTXT.Add("# service $($s.Name): $($s.PathName)"); foreach ($v in $vals) { $SVCTXT.Add($v) }
        $jh = @($vals | Where-Object { $_ -match '(?i)^JavaHome=' } | ForEach-Object { $_ -replace '(?i)^JavaHome=', '' }) | Select-Object -First 1
        if (-not $jh) { $m = [regex]::Match(($vals -join ' '), '([A-Za-z]:\\[^"\s;]*?)\\bin\\(java\.exe|server\\jvm\.dll)'); if ($m.Success) { $jh = $m.Groups[1].Value } }
        _cfgjdk "service $($s.Name)" "$jh"
    }
} else {
    foreach ($u in @(& systemctl list-unit-files --no-legend 2>$null | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -match '(?i)weblogic|nodemanager|wls|fmw|forms|report|oracle' -and $_ -notmatch '@\.service$' })) {
        $t = @(& systemctl cat $u 2>$null); $SVCTXT.Add("# unit $u"); foreach ($l in $t) { $SVCTXT.Add("$l") }
        $jh = @($t | Where-Object { $_ -match '^Environment="?JAVA_HOME=' } | ForEach-Object { $_ -replace '^Environment="?JAVA_HOME=([^" ]*).*', '$1' }) | Select-Object -Last 1
        _cfgjdk "systemd $u" "$jh"
    }
}
foreach ($k in $CFG.Keys) {
    $p = $CFG[$k]
    if (-not (ihwt-isdir $p)) { fail ("{0,-48} {1} - DIRECTORY MISSING" -f $k, $p); fixit "${k}: JAVA_HOME=$p does not exist"; continue }
    $v = _jver (_javabin $p); $kd = _kind $p
    switch ($kd) {
        "link"      { ok ("{0,-48} {1} -> {2} ({3})" -f $k, $p, (_real $p), $v) }
        "versioned" { warn ("{0,-48} {1} ({2}) - versioned directory, not the link" -f $k, $p, $v); fixit "${k}: $p -> use the JDK link / junction" }
        default     { info ("{0,-48} {1} ({2})" -f $k, $p, $v) }
    }
    if ($v -match 'OpenJDK') { warn "  $k is OpenJDK - FMW is certified with the Oracle JDK" }
}
if ($CFG.Count -eq 0) { warn "no JAVA_HOME found in the configuration" }
$pj = Get-Command $EXE -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pj) { info ("{0,-48} {1} -> {2} ({3})" -f "java in PATH", $pj.Source, (_real $pj.Source), (_jver (_real $pj.Source))) }

#==============================================================================
# 2. FMW-bundled JDK oracle_common\jdk
#==============================================================================
section "2. FMW-bundled JDK $BUNDLED (Reports engines, rwserver, tools)"
if (_islink $BUNDLED) {
    fail "oracle_common\jdk is a LINK / JUNCTION -> $(_real $BUNDLED) - the bundled JDK was replaced"
    info "  Reports starts its engines and loads the JVM from here - another JDK release breaks Reports"
    fixit "oracle_common\jdk: restore the original directory (backup / patch storage) instead of the link"
} elseif (ihwt-isdir $BUNDLED) {
    ok "oracle_common\jdk is a real directory ($((Get-Item -LiteralPath $BUNDLED).LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
} else {
    fail "oracle_common\jdk missing - Reports engines / tools cannot start"; fixit "oracle_common\jdk missing"
}
if (ihwt-isdir $BUNDLED) {
    $bv = _jver (_javabin $BUNDLED)
    $rel = Join-Path $BUNDLED "release"
    info "version: $bv   release: $(@(ihwt-cfgval $rel 'JAVA_VERSION') -join '' -replace '"', '')"
    if ($bv -match '^17\..*Oracle') { ok "bundled JDK is Oracle JDK 17 (FMW 14.1.2 ships 17.0.x)" }
    elseif ($bv -match '^1\.8.*Oracle') { ok "bundled JDK is Oracle JDK 8 (FMW 12.2.1.x)" }
    else { warn "bundled JDK is $bv - not the release FMW ships (14.1.2: Oracle JDK 17, 12.2.1.x: 8)"; fixit "oracle_common\jdk holds $bv - check whether it was overwritten / bent" }
    $jvm = if ($IHWT_ON_WINDOWS) { ihwt-jp @($BUNDLED, "bin", "server", "jvm.dll") } else { ihwt-jp @($BUNDLED, "lib", "server", "libjvm.so") }
    foreach ($f in @((_javabin $BUNDLED), $jvm)) {
        $n = $f.Substring($BUNDLED.Length).TrimStart('\', '/')
        if (_islink $f) { fail "oracle_common\jdk\$n is a link -> $(_real $f)"; fixit "oracle_common\jdk\$n is a link" }
        elseif (-not (Test-Path -LiteralPath $f)) { fail "oracle_common\jdk\$n missing"; fixit "oracle_common\jdk\$n missing" }
        else { ok "oracle_common\jdk\$n present" }
    }
    $links = @(Get-ChildItem -LiteralPath $BUNDLED -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.LinkType -and $_.FullName -notmatch '[\\/]legal[\\/]' })
    if ($links.Count) { warn "$($links.Count) link(s) inside oracle_common\jdk (outside legal\):"; $links | Select-Object -First 10 | ForEach-Object { info "  $($_.FullName) -> $(@($_.Target)[0])" } }
    else { ok "no links inside oracle_common\jdk (legal\ aside)" }
    if (Test-Path -LiteralPath $rel) {
        $rt = (Get-Item -LiteralPath $rel).LastWriteTime
        $newer = @(Get-ChildItem -LiteralPath $BUNDLED -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.LinkType -and $_.LastWriteTime -gt $rt.AddMinutes(1) })
        if ($newer.Count) { warn "$($newer.Count) file(s) in oracle_common\jdk newer than its release file - changed after the install / patch:"; $newer | Sort-Object LastWriteTime -Descending | Select-Object -First 10 | ForEach-Object { info ("  {0}  {1}" -f $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $_.FullName) } }
        else { ok "no file in oracle_common\jdk changed after its release file" }
    }
}
$sib = @(Get-ChildItem -LiteralPath (Join-Path $OH "oracle_common") -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^jdk.+' -or $_.Name -match 'jdk.*\.(bak|old|orig)' })
if ($sib.Count) { info "other JDK copies next to it (backup / old switch?):"; $sib | ForEach-Object { info "  $($_.FullName)" } }

#==============================================================================
# 3. Reports
#==============================================================================
section "3. Reports - Java of the reports script and of the running processes"
$rsh = $null
if ($DH) { foreach ($n in @("reports.cmd", "reports.bat", "reports.sh")) { $f = ihwt-jp @($DH, "reports", "bin", $n); if (Test-Path -LiteralPath $f) { $rsh = $f; break } } }
if ($rsh) {
    info "$rsh ($((Get-Item -LiteralPath $rsh).LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
    $other = @(); $ln = 0
    foreach ($l in @(_ihwt-lines $rsh)) {
        $ln++
        if ($l -match '^\s*(#|rem\s|::)') { continue }
        if ($l -match '(?i)(jdk|jre|java)[^\\/\s]*[\\/]' -and $l -notmatch '(?i)oracle_common[\\/]jdk') { $other += "${ln}: $($l.Trim())" }
    }
    if ($other.Count) { warn "the reports script names another JDK than oracle_common\jdk (edited by hand?):"; $other | Select-Object -First 5 | ForEach-Object { info "  $_" }; fixit "$(Split-Path -Leaf $rsh): JDK path changed by hand ($(($other[0] -split ':')[0]))" }
    else { ok "the reports script uses only oracle_common\jdk (as delivered)" }
    if ((_ihwt-lines $rsh) -match 'UseBASE64Intrinsics') { info "the reports script carries -XX:-UseBASE64Intrinsics (Java4Shell mitigation)" }
} else { info "no reports script (no Reports in this domain)" }
if ($DH) {
    foreach ($c in @(Get-ChildItem -LiteralPath (ihwt-jp @($DH, "config", "fmwconfig", "components", "ReportsServerComponent")) -Directory -ErrorAction SilentlyContinue)) {
        $f = Join-Path $c.FullName "rwserver.conf"; if (-not (Test-Path -LiteralPath $f)) { continue }
        $m = [regex]::Match(((_ihwt-lines $f) -join ' '), 'jvmOptions="[^"]*"')
        info "$($c.Name) rwserver.conf engine $(if ($m.Success) { $m.Value } else { 'jvmOptions not set' })"
    }
}
$rws = @($procs | Where-Object { $_.Name -match '^rwserver(\.exe)?$' })
foreach ($p in $rws) {
    $mod = $null
    try { $mod = @((Get-Process -Id $p.ProcessId -ErrorAction Stop).Modules | Where-Object { $_.ModuleName -match '^(jvm\.dll|libjvm\.so)$' }) | Select-Object -First 1 } catch { }
    if (-not $mod) { info "rwserver pid $($p.ProcessId): JVM module not readable / not loaded (yet)"; continue }
    $jr = _jdk_of $mod.FileName
    if (_same $jr $BUNDLED) { ok "rwserver pid $($p.ProcessId) loads the JVM of oracle_common\jdk ($(_jver (_javabin $jr)))" }
    else { warn "rwserver pid $($p.ProcessId) loads $($mod.FileName) ($(_jver (_javabin $jr))) - not oracle_common\jdk"; fixit "rwserver uses $jr - check PATH of the reports script / the service that started the Reports server" }
}
if (-not $rws.Count) { warn "no rwserver running - Reports server down? - check its log: DOMAIN_HOME\servers\<WLS_REPORTS>\logs\reports\ and the component logs" }

#==============================================================================
# 4. Running processes
#==============================================================================
section "4. Running processes - executable, version, vendor"
$sel = @($procs | Where-Object { "$($_.CommandLine)" -match 'weblogic\.(Server|NodeManager)|rwrun\.jar|rwEng|rwengine' })
$fw = @($procs | Where-Object { $_.Name -match '^frmweb(\.exe)?$' })
if ($fw.Count) { $sel += $fw[0] }
foreach ($p in $sel) {
    $a = "$($p.CommandLine)"; $exe = "$($p.ExecutablePath)"
    # server name first: a server command line also holds "weblogic.nodemanager..." (case!)
    $what = if ($a -match '-Dweblogic\.Name=([^\s"]+)') { $Matches[1] } elseif ($a -cmatch 'weblogic\.NodeManager(\s|"|$)') { "Node Manager" } elseif ($a -match 'rwrun\.jar|rwEng|rwengine') { "Reports engine" } elseif ($p.Name -match '^frmweb') { "frmweb (one of $($fw.Count))" } else { "?" }
    if ((Split-Path -Leaf $exe) -match '^javaw?(\.exe)?$') { $v = _jver $exe; $jr = _jdk_of $exe }
    else {
        $mod = $null; try { $mod = @((Get-Process -Id $p.ProcessId -ErrorAction Stop).Modules | Where-Object { $_.ModuleName -match '^(jvm\.dll|libjvm\.so)$' }) | Select-Object -First 1 } catch { }
        $jr = if ($mod) { _jdk_of $mod.FileName } else { $exe }; $v = if ($mod) { "JVM $($mod.FileName)" } else { "JVM not loaded" }
    }
    if ($what -eq "?") { continue }                                      # e.g. a shell whose command line holds the pattern
    $line = "{0,-22} pid {1,-8} {2} ({3})" -f $what, $p.ProcessId, $jr, $v
    if ($v -match 'OpenJDK') { warn "$line - OpenJDK"; fixit "$what runs on OpenJDK ($jr)" }
    elseif ($what -eq "Reports engine" -and -not (_same $jr $BUNDLED)) { warn "$line - not oracle_common\jdk" }
    else { ok $line }
}
if (-not $sel.Count) { info "no WebLogic / Reports / Forms process running" }

#==============================================================================
# 5. Files with a JDK path
#==============================================================================
section "5. Files with a JDK path (missing = FAIL, versioned dir = WARN)"
$files = New-Object System.Collections.Generic.List[string]
function _addglob { param([string] $dir, [string] $filter) foreach ($f in @(Get-ChildItem -Path (Join-Path $dir $filter) -File -Force -ErrorAction SilentlyContinue)) { if ($f.Name -notmatch '\.(bak|ori|orig)|\.bak_') { $files.Add($f.FullName) } } }
if ($DH) {
    foreach ($e in @("*.cmd", "*.sh")) { _addglob (Join-Path $DH "bin") $e }
    _addglob (Join-Path $DH "nodemanager") "nodemanager.properties"
    foreach ($e in @("reports.cmd", "reports.bat", "reports.sh")) { _addglob (ihwt-jp @($DH, "reports", "bin")) $e }
    foreach ($d in @(Get-ChildItem -Path (ihwt-jp @($DH, "config", "fmwconfig", "servers", "*", "applications", "*", "config")) -Directory -ErrorAction SilentlyContinue)) { _addglob $d.FullName "*.env" }
    foreach ($d in @(Get-ChildItem -LiteralPath (ihwt-jp @($DH, "config", "fmwconfig", "components", "ReportsServerComponent")) -Directory -ErrorAction SilentlyContinue)) { _addglob $d.FullName "rwserver.conf" }
    foreach ($d in @(Get-ChildItem -Path (ihwt-jp @($DH, "config", "fmwconfig", "components", "FORMS", "instances", "*", "bin")) -Directory -ErrorAction SilentlyContinue)) { _addglob $d.FullName "*.cmd"; _addglob $d.FullName "*.sh" }
    foreach ($d in @(Get-ChildItem -Path (ihwt-jp @($DH, "servers", "*", "data", "nodemanager")) -Directory -ErrorAction SilentlyContinue)) { _addglob $d.FullName "startup.properties" }
}
_addglob (Join-Path $OH "oui") ".globalEnv.properties"
$svcfile = $null
if ($SVCTXT.Count) { $svcfile = Join-Path $OutBase ("java_check_services_{0}.txt" -f $PID); ihwt-write-file $svcfile $SVCTXT; $files.Add($svcfile) }
$ohf = ihwt-fwd $OH; $dhf = ihwt-fwd $DH
$compRe = '^(?:(?:jdk|jre)(?:[-_.]?[0-9A-Za-z][A-Za-z0-9._-]*)?|java[-_.]?[0-9][A-Za-z0-9._-]*|java-[A-Za-z][A-Za-z0-9._-]*|default-java)$'
$hits = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $ln = 0
    foreach ($l in @(_ihwt-lines $f)) {
        $ln++
        if ($l -match '^\s*(#|rem\s|::)') { continue }
        $x = $l -replace '%ORACLE_HOME%|\$\{ORACLE_HOME\}|\$ORACLE_HOME|\$\{MW_HOME\}', $ohf -replace '%DOMAIN_HOME%|\$\{DOMAIN_HOME\}|\$DOMAIN_HOME', $dhf
        $x = ihwt-fwd $x
        foreach ($m in [regex]::Matches($x, '(?:[A-Za-z]:)?(?:/[A-Za-z0-9._@ -]*[A-Za-z0-9._@-])+')) {
            $pre = if ($m.Index -gt 0) { $x[$m.Index - 1] } else { ' ' }
            if ("$pre" -match '[A-Za-z0-9_}%$]') { continue }               # behind an unresolved variable
            $c = $m.Value -split '/'; $r = ""; $hit = $false
            for ($i = 0; $i -lt $c.Count; $i++) {
                $r = if ($i -eq 0) { $c[0] } else { "$r/$($c[$i])" }
                if ($i -eq 0) { continue }
                $nx = if ($i + 1 -lt $c.Count) { $c[$i + 1] } else { "" }
                if ($c[$i] -match $compRe -or ($c[$i] -eq "java" -and $nx -match '^(bin|lib|jre)$')) { $hit = $true; break }
            }
            if ($hit -and $r) { $hits.Add([pscustomobject]@{ F = $f; L = $ln; P = $r }) }
        }
    }
}
$bad = 0; $seen = @{}
foreach ($h in $hits) {
    $key = "$($h.F)|$($h.P)"; if ($seen.ContainsKey($key)) { continue }; $seen[$key] = 1
    if (_same $h.P $BUNDLED) { continue }                                  # the bundled JDK: section 2
    $name = if ($svcfile -and $h.F -eq $svcfile) { "services / units" } else { (ihwt-fwd $h.F).Replace("$dhf/", "") }
    if (-not (Test-Path -LiteralPath $h.P)) { $bad++; fail ("{0,-60} line {1,-5} {2} - MISSING" -f $name, $h.L, $h.P); fixit "$name line $($h.L): $($h.P) does not exist" }
    elseif ((_kind $h.P) -eq "versioned") { $bad++; warn ("{0,-60} line {1,-5} {2} - versioned, not the link" -f $name, $h.L, $h.P); fixit "$name line $($h.L): $($h.P) -> JDK link / junction" }
}
if ($bad -eq 0) { ok "every JDK path in $($files.Count) file(s) exists and uses a link / the bundled JDK" }
if ($svcfile) { Remove-Item -LiteralPath $svcfile -Force -ErrorAction SilentlyContinue }

#==============================================================================
# Summary
#==============================================================================
section "Summary - what to adjust"
if ($FIXLIST.Count -eq 0) { ok "nothing to adjust" } else { foreach ($x in $FIXLIST) { _p "  - $x" } }
_p ""
_p "Result: $script:N_FAIL FAIL, $script:N_WARN WARN - log: $LOG"
if ($script:N_FAIL -gt 0) { exit 2 }
if ($script:N_WARN -gt 0) { exit 1 }
exit 0
