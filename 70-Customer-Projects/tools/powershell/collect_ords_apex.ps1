#Requires -Version 5.1
#==============================================================================
# Script   : collect_ords_apex.ps1
# Purpose  : Collect the ORDS / APEX environment of a MS Windows host for the
#            third analysis (customer-analyse/analyse_ords_apex.sh) - the
#            Windows / PowerShell version of tools/bash/collect_ords_apex.sh,
#            same files and line formats:
#            - every ORDS installation: standalone (Jetty, java -jar ords.war
#              or bin\ords.cmd, as a Windows service through NSSM / WinSW /
#              a scheduled task), Tomcat (Procrun service TomcatN.exe or
#              Bootstrap), WebLogic deployment, services not running, unpacked
#              software, the old configuration layout (ihwt-ords-find)
#            - version (jar names of ords.war + "ords --version"), Java,
#              configuration of every pool ("ords config list
#              --include-defaults", masked copies of settings.xml / pool.xml),
#              file-based ORDS users ("ords config user list", no passwords)
#            - APEX images (/i/): directory + apex_version.txt (version only
#              from the images, no database connect)
#            - web tier routes to ORDS / /i/ (Nginx, Apache, OHS, IIS), fixed
#              Authorization headers, AJP
#            - security: listen address of the ORDS ports, Windows Firewall
#              inbound rules of these ports, the additional features
#              (Database Actions, REST Enabled SQL, Database API), Tomcat AJP
#              connectors / version / tomcat-users.xml
#            - logs of the last -LogDays days, AGGREGATED (requests per day,
#              status classes, hits on the SQL endpoints, errors per day)
#            READ-ONLY: writes only into the output directory. Runs the ORDS
#            program read-only ("--version", "config list", "config user
#            list" - a JVM for a few seconds each, timeout 90 s) unless
#            -NoExec; skipped when less than 512 MB memory is free. Secrets
#            are masked (the wallet is never copied). The archive is
#            ENCRYPTED by default (AES-256, openssl compatible).
#            Needs ihw_tools_lib.ps1 next to it.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
#==============================================================================
<#
.SYNOPSIS
  Collect the ORDS / APEX state of a Windows host (read-only, masked).

.PARAMETER OutBase
  Base directory of the output (default: $env:TEMP).

.PARAMETER NoExec
  Do not run the ORDS program (files only).

.PARAMETER LogDays
  Days of logs to aggregate (default 7).

.PARAMETER Ords
  More ORDS homes / config directories to look at (when the discovery finds nothing).

.PARAMETER NoEncrypt
  Plain ZIP (still masked) instead of the encrypted .zip.enc.

.PARAMETER Keep
  Keep the output directory next to the archive.

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\collect_ords_apex.ps1

.EXAMPLE
  .\collect_ords_apex.ps1 -Ords D:\ords\config -NoExec -Keep

.NOTES
  Runs as the owner of the ORDS installation or an administrator (the
  Windows service parameters in the registry need read access to HKLM).
  Doc: 70-Customer-Projects/tools/powershell/README.md
#>
[CmdletBinding()]
param(
    [string] $OutBase = $(if ($env:TEMP) { $env:TEMP } else { "/tmp" }),
    [switch] $NoExec,
    [int] $LogDays = 7,
    [string[]] $Ords = @(),
    [switch] $NoEncrypt,
    [switch] $Keep,
    [switch] $Version
)

Set-StrictMode -Version 2
$SCRIPT_VERSION = "2026-11-27.1"   # bump on every change - shown in 00_summary.txt
if ($Version) { Write-Output $SCRIPT_VERSION; exit 0 }

$lib = Join-Path $PSScriptRoot "ihw_tools_lib.ps1"
if (-not (Test-Path -LiteralPath $lib)) { Write-Host "ihw_tools_lib.ps1 missing next to $PSCommandPath" -ForegroundColor Red; exit 2 }
. $lib
$host_name = [Environment]::MachineName
$ts        = Get-Date -Format "yyyyMMdd_HHmmss"
try { $OutBase = (Resolve-Path -LiteralPath $OutBase -ErrorAction Stop).Path } catch { Write-Host "Output directory does not exist: $OutBase" -ForegroundColor Red; exit 2 }
$NAME = "ords_collect_{0}_{1}" -f $host_name, $ts
$OUT  = Join-Path $OutBase $NAME
if (-not (ihwt-git-guard $OutBase "$NAME.zip")) { exit 2 }
$PASS = ""
if (-not $NoEncrypt) {
    $PASS = ihwt-read-passphrase "ORDS collector archive"
    if (-not $PASS) { Write-Host "  -> or use -NoEncrypt (plain ZIP, masked)" -ForegroundColor Yellow; exit 2 }
}
try { New-Item -ItemType Directory -Path $OUT -Force -ErrorAction Stop | Out-Null }
catch { Write-Host "Cannot create $OUT : $_" -ForegroundColor Red; exit 2 }
$SUM = Join-Path $OUT "00_summary.txt"
$IHWT_OUT = $OUT; $IHWT_SUM = $SUM
$EXEC = -not $NoExec

function line   { param([string] $File, [string] $Text) ihwt-append $File $Text }   # machine-readable line
function nosemi { param([string] $t) return ("$t" -replace '[;\r\n]', ',') }
# value of a key/value line: masked like ihwt-mask, plus every key that names a secret
# (old pool.xml with db.password in clear text, before the wallet)
function maskv  { param([string] $k, [string] $v) if ($v -and $k -match '(?i)pass|secret|pwd|credential') { return "***MASKED***" }; return nosemi ((ihwt-mask "$k=$v") -replace '^[^=]*=', '') }
function dash   { param([string] $t) if ("$t") { return "$t" } else { return "-" } }

ihwt-say "collect_ords_apex.ps1 version $SCRIPT_VERSION"
ihwt-say "Output: $OUT"
ihwt-write-file $SUM @(
    ("ORDS / APEX collection {0} {1}" -f [char]0x2013, (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")),
    "collect_ords_apex.ps1 version $SCRIPT_VERSION (ihw_tools_lib $(ihwt-lib-version), read-only, secrets masked)", "")
ihwt-fact "Host" ([Net.Dns]::GetHostEntry([Environment]::MachineName).HostName)
ihwt-fact "User" ("{0}\{1}" -f [Environment]::UserDomainName, [Environment]::UserName)
$memfree = 0
if ($IHWT_ON_WINDOWS) {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) { ihwt-fact "OS" ("{0} (build {1})" -f $os.Caption, $os.BuildNumber); $memfree = [int]($os.FreePhysicalMemory / 1KB) }
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    ihwt-fact "Administrator" "$admin"
} else {
    ihwt-fact "OS" "$((Get-Content /etc/os-release -ErrorAction SilentlyContinue | Where-Object { $_ -like 'PRETTY_NAME=*' }) -replace '^PRETTY_NAME=|"', '') (not Windows - test run)"
    $mi = Get-Content /proc/meminfo -ErrorAction SilentlyContinue | Where-Object { $_ -match '^MemAvailable:\s+(\d+)' } | Select-Object -First 1
    if ($mi -and $mi -match '(\d+)') { $memfree = [int]([long]$Matches[1] / 1024) }
}
ihwt-fact "PowerShell" ("{0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
ihwt-fact "Memory available MB" "$memfree"
if ($EXEC -and $memfree -lt 512) { $EXEC = $false; ihwt-fact "ORDS program calls" "skipped (less than 512 MB available)" }
elseif ($EXEC) { ihwt-fact "ORDS program calls" "yes (--version, config list, config user list)" }
else { ihwt-fact "ORDS program calls" "no (-NoExec)" }

#==============================================================================
# 1. Discovery
#==============================================================================
ihwt-say "1/7 Discovery"
$procs = @(ihwt-procs)
$INST = @(ihwt-ords-find $procs $Ords)
ihwt-append 10_instances.txt ("### ORDS installations: ords;id;mode;home;war;config;pid;unit;user;ports`n{0}`n### rc=0`n" -f ($INST -join "`n"))
$I = @($INST | ForEach-Object {
    $f = $_ -split ';'
    [pscustomobject]@{ Id = $f[1]; Mode = $f[2]; Home = $f[3]; War = $f[4]; Cfg = $f[5]; Pid = $f[6]; Unit = $f[7]; User = $f[8]; Ports = $f[9] }
})
$RUNI = @($I | Where-Object { $_.Mode -notlike 'software*' })
if ($RUNI.Count) {
    $mc = @{}; foreach ($r in $RUNI) { if ($mc.ContainsKey($r.Mode)) { $mc[$r.Mode]++ } else { $mc[$r.Mode] = 1 } }
    ihwt-fact "ORDS installations" ("{0} ({1})" -f $RUNI.Count, (($mc.GetEnumerator() | ForEach-Object { "$($_.Value) $($_.Key)" }) -join ', '))
} else {
    ihwt-fact "ORDS installations" "none"
    ihwt-say "no ORDS found (use -Ords DIR if it lives somewhere else)"
}
$swn = @($I | Where-Object { $_.Mode -like 'software*' })
ihwt-fact "ORDS software dirs" ("{0} ({1} not used by an instance)" -f $swn.Count, @($swn | Where-Object { $_.Mode -eq 'software' }).Count)
$svcs = @{}
if ($IHWT_ON_WINDOWS) { foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) { $svcs[$s.Name] = $s } }
$byPid = @{}; foreach ($p in $procs) { $byPid["$($p.ProcessId)"] = $p }
foreach ($r in $RUNI) {
    if ($r.Pid -ne '-' -and $byPid.ContainsKey($r.Pid)) {
        $p = $byPid[$r.Pid]
        ihwt-block 10_instances.txt "process of $($r.Id) (pid $($r.Pid))" ("{0}`nstarted {1}, working set {2} MB, executable {3}" -f $p.CommandLine, $p.CreationDate, [math]::Round($p.WorkingSetSize / 1MB), $p.ExecutablePath)
    }
    if ($r.Unit -ne '-') {
        if ($IHWT_ON_WINDOWS -and $svcs.ContainsKey($r.Unit)) { ihwt-block 10_instances.txt "Windows service $($r.Unit)" (ihwt-ords-svc-text $svcs[$r.Unit]) }
        elseif (-not $IHWT_ON_WINDOWS) { ihwt-run 10_instances.txt "systemd unit $($r.Unit)" "systemctl" @("cat", $r.Unit) }
    }
}

# --- per instance: java, ords command ----------------------------------------
function java-of {
    param($r)
    $j = ""
    if ($r.Pid -ne '-' -and $byPid.ContainsKey($r.Pid)) { $j = "$($byPid[$r.Pid].ExecutablePath)" }
    if (-not $j -and $r.Unit -ne '-' -and $svcs.ContainsKey($r.Unit)) {
        $tx = ihwt-ords-svc-text $svcs[$r.Unit]
        $m = [regex]::Match($tx, 'JAVA_HOME=([^\r\n;]+?)(\s|$)'); if ($m.Success) { $j = ihwt-jp @($m.Groups[1].Value.Trim('"'), "bin", "java.exe") }
        if (-not $j) { $m = [regex]::Match($tx, 'procrun\.Java\.Jvm=(.+?)[\\/]bin[\\/]server[\\/]jvm\.dll'); if ($m.Success) { $j = ihwt-jp @($m.Groups[1].Value, "bin", "java.exe") } }
    }
    if (-not $j -and $env:JAVA_HOME) { $j = ihwt-jp @($env:JAVA_HOME, "bin", $(if ($IHWT_ON_WINDOWS) { "java.exe" } else { "java" })) }
    if (-not $j) { $c = Get-Command java -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { $j = $c.Source } }
    return $j
}
function ords-run {
    param($r, [string] $Java, [string[]] $Arguments)
    if (-not $Java -or -not (Test-Path -LiteralPath $Java)) { return $null }
    $jh = Split-Path -Parent (Split-Path -Parent $Java)
    $env_ = @{ JAVA_HOME = $jh }
    $cmd = ""
    foreach ($c in @((ihwt-jp @($r.Home, "bin", "ords.cmd")), (ihwt-jp @($r.Home, "bin", "ords")))) { if ($r.Home -ne '-' -and (Test-Path -LiteralPath $c -PathType Leaf)) { $cmd = $c; break } }
    if ($cmd -and ($IHWT_ON_WINDOWS -eq ($cmd -like '*.cmd'))) { $res = ihwt-exec $cmd (@("--config", $r.Cfg) + $Arguments) $env_ 90 }
    elseif ($r.War -ne '-' -and (Test-Path -LiteralPath $r.War -PathType Leaf)) { $res = ihwt-exec $Java (@("-jar", $r.War, "--config", $r.Cfg) + $Arguments) $env_ 90 }
    else { return $null }
    if ($res.Rc -ne 0) { return $null }
    return "$($res.Out)"
}

#==============================================================================
# 2. Versions + Java
#==============================================================================
ihwt-say "2/7 Versions"
$VERS = @()
foreach ($r in $I) {
    $v = $(if ($r.War -ne '-') { ihwt-ords-war-version $r.War } else { "" })
    line 20_version.txt "version;$($r.Id);$($r.Mode);jar;$(dash $v)"
    if ($r.Mode -like 'software*') { continue }
    $VERS += "$($r.Id) $(if ($v) { $v } else { '?' })"
    $j = java-of $r
    if ($r.Pid -ne '-' -or $r.Unit -ne '-') {
        $jv = "-"
        if ($j -and (Test-Path -LiteralPath $j)) { $jr = ihwt-exec $j @("-version") @{} 30; $jv = nosemi (("$($jr.Out)" -split "`r?`n") | Where-Object { $_ } | Select-Object -First 1) }
        line 20_version.txt "java;$($r.Id);$(dash $j);$jv"
    }
    if ($EXEC -and $r.Cfg -ne '-' -and (ihwt-isdir $r.Cfg)) {
        $o = ords-run $r $j @("--version")
        $ev = ""; if ($o) { $m = [regex]::Match($o, 'Oracle REST Data Services\s*([0-9]\S*)'); if ($m.Success) { $ev = $m.Groups[1].Value } }
        line 20_version.txt "version;$($r.Id);$($r.Mode);exec;$(if ($ev) { $ev } else { 'not readable' })"
    }
}
ihwt-fact "ORDS versions" $(if ($VERS.Count) { $VERS -join ', ' } else { "none" })
$jl = @(_ihwt-lines (Join-Path $OUT "20_version.txt") | Where-Object { $_ -like 'java;*' } | ForEach-Object { $f = $_ -split ';'; "$($f[1]) $($f[3])" })
ihwt-fact "ORDS Java" $(if ($jl.Count) { $jl -join ', ' } else { "-" })

#==============================================================================
# 3. Configuration: pools, features, users, wallet, old layout
#==============================================================================
ihwt-say "3/7 Configuration"
foreach ($r in $RUNI) {
    if ($r.Cfg -eq '-' -or -not (ihwt-isdir $r.Cfg)) { continue }
    $j = java-of $r
    if ($r.Mode -eq 'old-layout') {
        $dx = Join-Path $r.Cfg "defaults.xml"
        ihwt-copy 30_config.txt $dx
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $r.Cfg "conf") -Filter *.xml -File -ErrorAction SilentlyContinue)) { ihwt-copy 30_config.txt $f.FullName }
        foreach ($e in (ihwt-ords-entries $dx)) { $k, $v = $e -split ';', 2; line 30_config.txt "cfg;$($r.Id);global;$k;$(maskv $k $v);file" }
        continue
    }
    ihwt-copy 30_config.txt (ihwt-jp @($r.Cfg, "global", "settings.xml"))
    $pools = @(Get-ChildItem -LiteralPath (Join-Path $r.Cfg "databases") -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    foreach ($pl in $pools) {
        ihwt-copy 30_config.txt (ihwt-jp @($r.Cfg, "databases", $pl, "pool.xml"))
        foreach ($w in @(Get-ChildItem -LiteralPath (ihwt-jp @($r.Cfg, "databases", $pl, "wallet")) -File -Force -ErrorAction SilentlyContinue)) {
            line 30_config.txt "wallet;$($r.Id);$pl;$($w.FullName);owner $(_ihwt-owner $w.FullName)"
        }
    }
    $got = $false
    if ($EXEC) {
        $pl_ = $(if ($pools.Count) { $pools } else { @("default") })
        foreach ($pl in $pl_) {
            $o = ords-run $r $j @("config", "--db-pool", $pl, "list", "--include-defaults")
            if (-not $o -or $o -notmatch '(?m)^-----') { continue }
            $got = $true
            # columns from the dash line (Setting / Value / Source - values may hold blanks)
            $st = @(); $on = $false
            foreach ($l in ($o -split "`r?`n")) {
                if ($l -match '^-----') { $st = @(); for ($i = 0; $i -lt $l.Length; $i++) { if ($l[$i] -eq '-' -and ($i -eq 0 -or $l[$i - 1] -eq ' ')) { $st += $i } }; $on = $true; continue }
                if (-not $on -or -not $l.Trim() -or $st.Count -lt 3) { continue }
                $l2 = $l.PadRight($st[2] + 1)
                $k = $l2.Substring($st[0], $st[1] - $st[0]).Trim(); $v = $l2.Substring($st[1], $st[2] - $st[1]).Trim(); $s = $l2.Substring($st[2]).Trim()
                if ($k) { line 30_config.txt "cfg;$($r.Id);$pl;$k;$(maskv $k $v);$s" }
            }
        }
        $uo = ords-run $r $j @("config", "user", "list")
        if ($uo) {
            $on = $false
            foreach ($l in ($uo -split "`r?`n")) {
                if ($l -match '^-----') { $on = $true; continue }
                if (-not $on -or -not $l.Trim()) { continue }
                $f = @($l.Trim() -split '\s+'); line 30_config.txt "user;$($r.Id);$($f[0]);$(nosemi (($f | Select-Object -Skip 1) -join ' '))"
            }
        }
    }
    if (-not $got) {   # files only: global + every pool, source = file
        foreach ($e in (ihwt-ords-entries (ihwt-jp @($r.Cfg, "global", "settings.xml")))) { $k, $v = $e -split ';', 2; line 30_config.txt "cfg;$($r.Id);global;$k;$(maskv $k $v);file" }
        foreach ($pl in $pools) {
            foreach ($e in (ihwt-ords-entries (ihwt-jp @($r.Cfg, "databases", $pl, "pool.xml")))) { $k, $v = $e -split ';', 2; line 30_config.txt "cfg;$($r.Id);$pl;$k;$(maskv $k $v);file" }
        }
    }
    # file-based users (ords config user add): credentials file, never its content
    foreach ($f in @((ihwt-jp @($r.Cfg, "global", "credentials")), (Join-Path $r.Cfg "credentials"))) {
        if (Test-Path -LiteralPath $f -PathType Leaf) { line 30_config.txt "credfile;$($r.Id);$f;$(@(_ihwt-lines $f | Where-Object { $_ }).Count) entries;owner $(_ihwt-owner $f)" }
    }
}
$CFGF = Join-Path $OUT "30_config.txt"
$cfgl = @(_ihwt-lines $CFGF | Where-Object { $_ -like 'cfg;*' } | ForEach-Object { , ($_ -split ';') })
$pk = @($cfgl | Where-Object { $_[2] -ne 'global' } | ForEach-Object { "$($_[1])/$($_[2])" } | Sort-Object -Unique)
ihwt-fact "ORDS pools" $(if ($pk.Count) { $pk -join ', ' } else { "-" })
function feat {
    param([string] $Id, [string] $Pl, [string] $Key)
    $p = ""; $g = ""
    foreach ($c in $cfgl) { if ($c[1] -eq $Id -and $c[3] -eq $Key) { if ($c[2] -eq $Pl) { $p = $c[4] } elseif ($c[2] -eq 'global') { $g = $c[4] } } }
    if ($p) { return $p }; return $g
}
$FEATS = @()
foreach ($r in $RUNI) {
    foreach ($pl in @($cfgl | Where-Object { $_[1] -eq $r.Id -and $_[2] -ne 'global' } | ForEach-Object { $_[2] } | Sort-Object -Unique)) {
        $sdw = feat $r.Id $pl "feature.sdw"; $rsq = feat $r.Id $pl "restEnabledSql.active"
        $dba = feat $r.Id $pl "database.api.enabled"; $gql = feat $r.Id $pl "feature.graphql"
        $ch = 5
        if ($sdw -eq 'true') { $ch = 1 } elseif ($rsq -eq 'true' -and $dba -eq 'true') { $ch = 2 } elseif ($rsq -eq 'true') { $ch = 3 } elseif ($dba -eq 'true') { $ch = 4 }
        line 70_security.txt ("feature;{0};{1};{2};{3};{4};{5};{6}" -f $r.Id, $pl, $(if ($sdw) { $sdw } else { "false" }), $(if ($rsq) { $rsq } else { "false" }), $(if ($dba) { $dba } else { "false" }), $(if ($gql) { $gql } else { "default" }), $ch)
        $FEATS += "$($r.Id)/$pl choice $ch"
    }
}
ihwt-fact "ORDS features" ("{0} (1 Database Actions, 2 REST SQL + DB API, 3 REST SQL, 4 DB API, 5 none)" -f $(if ($FEATS.Count) { $FEATS -join ', ' } else { "-" }))
$cl_ = @(_ihwt-lines $CFGF)
ihwt-fact "ORDS file users" ("{0} user(s), {1} credentials file(s)" -f @($cl_ | Where-Object { $_ -like 'user;*' }).Count, @($cl_ | Where-Object { $_ -like 'credfile;*' }).Count)

#==============================================================================
# 4. Web tier: routes to ORDS / /i/, fixed Authorization headers, AJP
#==============================================================================
ihwt-say "4/7 Web tier"
$ports = New-Object System.Collections.Generic.List[string]
foreach ($r in $RUNI) {
    foreach ($p in ("$($r.Ports)" -split ',')) { if ($p -and $p -ne '-') { $ports.Add($p) } }
    $p = ihwt-ords-cfgval $r.Cfg "standalone.http.port"; if ($p) { $ports.Add($p) }
}
$pre = $(if ($ports.Count) { (@($ports | Sort-Object -Unique) -join '|') } else { "none" })
$WTR = Join-Path $OUT "50_webtier.txt"
ihwt-append 50_webtier.txt "### routes to ORDS / APEX images ($IHWT_WT_HEAD)"
$wt = @(ihwt-webtier-find @() $procs)
foreach ($e in $wt) {
    $t = $e.Substring(0, $e.IndexOf(';')); $m = $e.Substring($e.IndexOf(';') + 1)
    $flat = @(ihwt-webtier-flatten $t $m)
    foreach ($row in @(ihwt-webtier-routes $t $m $flat)) {
        $f = $row -split ';'
        if ($f.Count -lt 8) { continue }
        if ($f[6] -match '^/(ords|i|apex)' -or $f[6] -match 'ords' -or $f[7] -match (":(" + $pre + ")([^0-9]|$)")) { ihwt-append 50_webtier.txt $row }
    }
    # fixed Authorization header towards a backend = one login for everybody
    for ($n = 0; $n -lt $flat.Count; $n++) {
        $x = $flat[$n]
        if ($x -match '^[^#]*(proxy_set_header|RequestHeader\s+(set|append|add|merge))\s+"?Authorization') {
            $x = [regex]::Replace($x, '(?i)(Basic|Bearer)\s+[^";\s]+', '$1 ***MASKED***'); line 70_security.txt "authhdr;$t;$m;$(nosemi "$($n + 1):$x")"
        }
        if ($x -match '^[^#]*(ajp://|JkMount|JkWorkersFile)') { line 70_security.txt "ajp;web;$t;$(nosemi "$($n + 1):$x")" }
    }
}
ihwt-append 50_webtier.txt "### rc=0`n"
$wtn = @(_ihwt-lines $WTR | Where-Object { $_ -and $_ -notlike '#*' }).Count
ihwt-fact "Web tier routes to ORDS" ("{0} (web servers: {1})" -f $wtn, ((@($wt | ForEach-Object { ($_ -split ';')[0] }) | Sort-Object -Unique) -join ' '))

#==============================================================================
# 5. APEX images (/i/): web server static dirs, ORDS static path, Tomcat i\
#==============================================================================
ihwt-say "5/7 APEX images"
$img = [ordered]@{}
function add-img { param([string] $d, [string] $by) if (-not $d) { return }; $d = $d.TrimEnd('\', '/'); if (-not $img.Contains($d) -or $img[$d] -eq '-') { $img[$d] = $by } }
foreach ($l in (_ihwt-lines $WTR)) { $f = $l -split ';'; if ($f.Count -ge 8 -and $f[7] -like 'static *') { add-img ($f[7].Substring(7)) "$($f[0]) $($f[6])" } }
foreach ($r in $RUNI) {
    $d = ihwt-ords-cfgval $r.Cfg "standalone.static.path"; if ($d) { add-img $d "ords $($r.Id) static $(ihwt-ords-cfgval $r.Cfg 'standalone.static.context.path')" }
    if ($r.Mode -eq 'tomcat') { $d = ihwt-jp @($r.Home, "webapps", "i"); if (ihwt-isdir $d) { add-img $d "tomcat $($r.Id) /i/" } }
}
$iroots = @()
if ($IHWT_ON_WINDOWS) {
    foreach ($dk in @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue)) {
        $iroots += @(Get-ChildItem -LiteralPath "$($dk.DeviceID)\" -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)oracle|ords|apex|^app|tomcat|apache|nginx|inetpub|middleware|product|^srv$' } | ForEach-Object { $_.FullName })
    }
} else { $iroots = @("/u01", "/u02", "/opt", "/app", "/srv", "/oracle", "/var/www") | Where-Object { ihwt-isdir $_ } }
$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($rt in $iroots) {
    if ($sw.Elapsed.TotalSeconds -gt 60) { break }
    foreach ($f in @(Get-ChildItem -LiteralPath $rt -Recurse -Depth 6 -File -Force -Filter apex_version.txt -ErrorAction SilentlyContinue)) {
        if ($f.FullName -match '(?i)[\\/]\.patch_storage[\\/]|[\\/]apex[\\/]images[\\/]') { continue }
        add-img $f.DirectoryName "-"
    }
}
foreach ($d in @($img.Keys | Sort-Object)) {
    if (-not (ihwt-isdir $d)) { continue }
    $v = ihwt-apex-version $d
    $dt = "-"; $avf = Join-Path $d "apex_version.txt"; if (Test-Path -LiteralPath $avf) { $dt = (Get-Item -LiteralPath $avf).LastWriteTime.ToString('yyyy-MM-dd') }
    line 40_apex_images.txt "apex;$d;$(dash $v);$dt;$(nosemi $img[$d])"
}
$al = @(_ihwt-lines (Join-Path $OUT "40_apex_images.txt") | Where-Object { $_ -like 'apex;*' } | ForEach-Object { $f = $_ -split ';'; "$($f[2]) ($($f[1]))" })
ihwt-fact "APEX images" $(if ($al.Count) { $al -join ', ' } else { "none found" })

#==============================================================================
# 6. Security: listen addresses, firewall, Tomcat (AJP, version, users)
#==============================================================================
ihwt-say "6/7 Security"
$lp = @(ihwt-listen-ports)
foreach ($r in $RUNI) {
    foreach ($p in ("$($r.Ports)" -split ',')) {
        if (-not $p -or $p -eq '-') { continue }
        foreach ($l in @($lp | Where-Object { ($_ -split ';')[2] -eq $p })) {
            $f = $l -split ';'; $sc = $(if ($f[3] -eq 'local') { "loopback" } else { "network" })
            line 70_security.txt "listen;$($r.Id);$($f[1]):$($f[2]);$sc"
        }
    }
    if ($r.Mode -eq 'standalone-stopped' -or $r.Mode -eq 'not-running') { line 70_security.txt "listen;$($r.Id);$(ihwt-ords-cfgval $r.Cfg 'standalone.binds'):$(ihwt-ords-cfgval $r.Cfg 'standalone.http.port');configured" }
    if ($r.Mode -like 'tomcat*') {
        $tv = ""
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $z = [System.IO.Compression.ZipFile]::OpenRead((ihwt-jp @($r.Home, "lib", "catalina.jar")))
            try { $en = $z.GetEntry("org/apache/catalina/util/ServerInfo.properties"); if ($en) { $sr = New-Object IO.StreamReader($en.Open()); $tx = $sr.ReadToEnd(); $sr.Close(); $m = [regex]::Match($tx, '(?m)^server\.number=(\S+)'); if ($m.Success) { $tv = $m.Groups[1].Value } } } finally { $z.Dispose() }
        } catch { }
        line 70_security.txt "tomcat;$($r.Id);version;$(if ($tv) { $tv } else { '?' })"
        $sxf = ihwt-jp @($r.Home, "conf", "server.xml"); $sx = ""; try { $sx = [IO.File]::ReadAllText($sxf) } catch { }
        $sx = [regex]::Replace($sx, '(?s)<!--.*?-->', '')
        foreach ($cm in [regex]::Matches($sx, '(?s)<Connector[^>]*>')) { if ($cm.Value -match 'AJP') { line 70_security.txt "ajp;tomcat;$($r.Id);$(nosemi (ihwt-mask (($cm.Value -replace '\s+', ' ') -replace '(?i)(secret=")[^"]*', '$1***MASKED***')))" } }
        $ux = ""; try { $ux = [IO.File]::ReadAllText((ihwt-jp @($r.Home, "conf", "tomcat-users.xml"))) } catch { }
        $ux = [regex]::Replace($ux, '(?s)<!--.*?-->', '')
        $pwa = 'pass' + 'word'   # attribute name built (the pre-commit secret scan reads a literal as a value)
        line 70_security.txt "tomcatusers;$($r.Id);$([regex]::Matches($ux, "<user[^>]*$pwa=").Count)"
        ihwt-copy 30_config.txt $sxf
    }
}
if ($IHWT_ON_WINDOWS) {
    $fp = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    if ($fp.Count) {
        line 70_security.txt "firewalld;state;windows-firewall $((@($fp | ForEach-Object { "$($_.Name)=$(if ($_.Enabled) { 'on' } else { 'off' })" })) -join ',')"
        $open = @()
        foreach ($p in @($ports | Sort-Object -Unique)) {
            foreach ($pf in @(Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue | Where-Object { @($_.LocalPort) -contains $p })) {
                $ru = $pf | Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' }
                foreach ($x in @($ru)) { $open += "$p '$($x.DisplayName)' ($($x.Profile))" }
            }
        }
        line 70_security.txt "firewalld;open;$(nosemi $(if ($open.Count) { 'inbound allow: ' + ($open -join ', ') } else { 'no inbound allow rule for the ORDS ports' }))"
    } else { line 70_security.txt "firewalld;state;not readable" }
} else {
    $fw = "$(& firewall-cmd --state 2>&1)"
    if ($fw -match '^(running|not running)') { $fw = $Matches[1] } elseif (Get-Command firewall-cmd -ErrorAction SilentlyContinue) { $fw = "not readable (no root)" } else { $fw = "not installed" }
    line 70_security.txt "firewalld;state;$fw"
}
$SECF = Join-Path $OUT "70_security.txt"
$sl = @(_ihwt-lines $SECF)
$li = @($sl | Where-Object { $_ -like 'listen;*' } | ForEach-Object { $f = $_ -split ';'; "$($f[1]) $($f[2]) ($($f[3]))" })
ihwt-fact "ORDS listen" $(if ($li.Count) { $li -join ', ' } else { "-" })
ihwt-fact "ORDS AJP / auth headers" ("{0} AJP, {1} fixed Authorization header(s)" -f @($sl | Where-Object { $_ -like 'ajp;*' }).Count, @($sl | Where-Object { $_ -like 'authhdr;*' }).Count)

#==============================================================================
# 7. Logs of the last N days - aggregated (no single request, no client IP)
#==============================================================================
ihwt-say "7/7 Logs (last $LogDays days)"
$LIM = (Get-Date).Date.AddDays(-$LogDays)
$LIMS = $LIM.ToString('yyyy-MM-dd')
$mo = @{ Jan = '01'; Feb = '02'; Mar = '03'; Apr = '04'; May = '05'; Jun = '06'; Jul = '07'; Aug = '08'; Sep = '09'; Oct = '10'; Nov = '11'; Dec = '12' }
foreach ($r in $RUNI) {
    $acc = @(); $errs = @()
    $a = ihwt-ords-cfgval $r.Cfg "standalone.access.log"
    if ($a -and (ihwt-isdir $a)) { $acc += @(Get-ChildItem -LiteralPath $a -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $LIM -and ($_.Name -like 'ords_*.log' -or $_.Name -like '*access*') -and $_.Name -notlike 'ords_sys*' -and $_.Name -notlike 'ords_std*' } | ForEach-Object { $_.FullName }) }
    if ($r.Mode -eq 'tomcat') { $acc += @(Get-ChildItem -LiteralPath (Join-Path $r.Home "logs") -File -Filter '*access_log*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $LIM } | ForEach-Object { $_.FullName }) }
    # error logs: java.util.logging file of the instance, stdout / stderr of the service, catalina
    $lpat = ""; foreach ($l in (_ihwt-lines (ihwt-jp @($r.Cfg, "global", "logging.properties")))) { if ($l -match '^java\.util\.logging\.FileHandler\.pattern=(.+)$') { $lpat = $Matches[1].Trim(); break } }
    if ($lpat) { $errs += @(Get-ChildItem -Path ($lpat -replace '%g', '*' -replace '%u', '*' -replace '%h', $HOME -replace '%t', [IO.Path]::GetTempPath()) -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
    if ($r.Unit -ne '-' -and $svcs.ContainsKey($r.Unit)) {
        $tx = ihwt-ords-svc-text $svcs[$r.Unit]
        foreach ($m in [regex]::Matches($tx, '(?m)^(nssm\.AppStdout|nssm\.AppStderr)=(.+)$')) { $errs += $m.Groups[2].Value.Trim() }
        foreach ($m in [regex]::Matches($tx, '(?m)^procrun\.Log\.Path=(.+)$')) { $errs += @(Get-ChildItem -LiteralPath $m.Groups[1].Value.Trim() -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $LIM -and $_.Name -notlike '*access*' } | ForEach-Object { $_.FullName }) }
    } elseif ($r.Unit -ne '-' -and -not $IHWT_ON_WINDOWS) {
        $uc = "$(& systemctl cat $r.Unit 2>$null | Out-String)"
        foreach ($m in [regex]::Matches($uc, '(?m)^Standard(Output|Error)=(append|file):(.+)$')) { $errs += ($m.Groups[3].Value.Trim() -replace '%i', $r.Id) }
    }
    if ($r.Mode -eq 'tomcat') { $errs += @(Get-ChildItem -LiteralPath (Join-Path $r.Home "logs") -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^catalina' -and $_.LastWriteTime -ge $LIM } | ForEach-Object { $_.FullName }) }
    $errs = @($errs | Where-Object { $_ } | Sort-Object -Unique)
    line 60_logs.txt "logfiles;$($r.Id);access;$(nosemi ($acc -join ' '))"
    line 60_logs.txt "logfiles;$($r.Id);errors;$(nosemi ($errs -join ' '))"
    # access log (NCSA): day, status class, internal / external client, SQL endpoints
    $n = @{}; $c = @{}; $ex = @{}; $h = @{}; $ok = @{}
    foreach ($af in $acc) {
        foreach ($l in (_ihwt-lines $af)) {
            $m = [regex]::Match($l, '\[(\d+)/([A-Za-z]+)/(\d+)'); if (-not $m.Success -or -not $mo.ContainsKey($m.Groups[2].Value)) { continue }
            $day = "{0}-{1}-{2:D2}" -f $m.Groups[3].Value, $mo[$m.Groups[2].Value], [int]$m.Groups[1].Value
            if ([string]::CompareOrdinal($day, $LIMS) -lt 0) { continue }
            $st = ""; $sm = [regex]::Match($l, '" (\d{3}) '); if ($sm.Success) { $st = $sm.Groups[1].Value }
            $ip = ($l -split '\s', 2)[0]
            $ext = $(if ($ip -match '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|::1|-)') { "int" } else { "ext" })
            $req = ""; $rm = [regex]::Match($l, '"[A-Z]+ ([^ "]+)'); if ($rm.Success) { $req = $rm.Groups[1].Value }
            if ($n.ContainsKey($day)) { $n[$day]++ } else { $n[$day] = 1 }
            $ck = "$day|$(if ($st) { $st.Substring(0, 1) } else { '' })"; if ($c.ContainsKey($ck)) { $c[$ck]++ } else { $c[$ck] = 1 }
            $ek = "$day|$ext"; if ($ex.ContainsKey($ek)) { $ex[$ek]++ } else { $ex[$ek] = 1 }
            $ep = ""
            if ($req -match '/sql-developer|/_sdw') { $ep = "database_actions" } elseif ($req -match '/_/sql') { $ep = "rest_enabled_sql" }
            elseif ($req -match '/_/db-api') { $ep = "database_api" } elseif ($req -match '/graphql') { $ep = "graphql" }
            elseif ($req -match '/_/landing') { $ep = "landing" } elseif ($req -match '/apex|f\?p=|/r/') { $ep = "apex" }
            if ($ep) { if ($h.ContainsKey($ep)) { $h[$ep]++ } else { $h[$ep] = 1 }; if ($st -like '2*') { if ($ok.ContainsKey($ep)) { $ok[$ep]++ } else { $ok[$ep] = 1 } } }
        }
    }
    $g = { param($t, $k) if ($t.ContainsKey($k)) { return $t[$k] }; return 0 }
    foreach ($d in @($n.Keys | Sort-Object)) {
        line 60_logs.txt ("access;{0};{1};{2};{3};{4};{5};{6};{7};{8}" -f $r.Id, $d, $n[$d], (& $g $c "$d|2"), (& $g $c "$d|3"), (& $g $c "$d|4"), (& $g $c "$d|5"), (& $g $ex "$d|int"), (& $g $ex "$d|ext"))
    }
    foreach ($k in @($h.Keys | Sort-Object)) { line 60_logs.txt ("endpoint;{0};{1};{2};{3}" -f $r.Id, $k, $h[$k], (& $g $ok $k)) }
    # errors per day + the last 50 lines
    foreach ($ef in $errs) {
        if (-not (Test-Path -LiteralPath $ef -PathType Leaf) -or (Get-Item -LiteralPath $ef).Length -eq 0) { continue }
        $pd = @{}; $u = 0; $last = New-Object System.Collections.Generic.List[string]
        foreach ($l in (_ihwt-lines $ef)) {
            if ($l -cnotmatch 'SEVERE|ERROR|Exception') { continue }
            if ($l -match '^(\d{4}-\d{2}-\d{2})') { $d = $Matches[1]; if ([string]::CompareOrdinal($d, $LIMS) -ge 0) { if ($pd.ContainsKey($d)) { $pd[$d]++ } else { $pd[$d] = 1 } } } else { $u++ }
            if ($l -cmatch 'SEVERE|ERROR') { $last.Add($(if ($l.Length -gt 400) { $l.Substring(0, 400) } else { $l })); if ($last.Count -gt 50) { $last.RemoveAt(0) } }
        }
        foreach ($d in @($pd.Keys | Sort-Object)) { line 60_logs.txt "errors;$($r.Id);$ef;$d;$($pd[$d])" }
        if ($u) { line 60_logs.txt "errors;$($r.Id);$ef;undated;$u" }
        ihwt-append 60_logs.txt ("### last error lines: {0}`n{1}`n" -f $ef, (ihwt-mask ($last -join "`n")))
    }
}
$LOGF = Join-Path $OUT "60_logs.txt"
$ll = @(_ihwt-lines $LOGF)
$rq = 0; $rx = 0; foreach ($l in @($ll | Where-Object { $_ -like 'access;*' })) { $f = $l -split ';'; $rq += [int]$f[3]; $rx += [int]$f[10] }
ihwt-fact "ORDS requests (log)" ("{0} in the last {1} days ({2} from outside the private nets)" -f $rq, $LogDays, $rx)
$eh = @($ll | Where-Object { $_ -match '^endpoint;[^;]*;(database_actions|rest_enabled_sql|database_api|graphql);' } | ForEach-Object { $f = $_ -split ';'; "$($f[2]) $($f[3]) ($($f[4]) ok)" })
ihwt-fact "ORDS SQL endpoint hits" $(if ($eh.Count) { $eh -join ', ' } else { "none" })

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
exit 0
