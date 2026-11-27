#Requires -Version 5.1
#==============================================================================
# Script   : reports_network_scan_fmw.ps1
# Purpose  : Oracle Reports server discovery (UDP multicast) of this domain and
#            the Reports servers in the network - Windows / PowerShell version
#            of tools/bash/reports_network_scan_fmw.sh (same six steps):
#              1. every rwnetwork.conf of the domain: channel / port, all equal?
#              2. multicast prerequisites: route 224.0.0.0/4, Windows Firewall
#                 inbound rule for the UDP port
#              3. self-test: send one datagram to channel:port and receive it
#                 on this host (UdpClient); skipped while rwserver.exe runs
#              4. active scan over a port range with Oracle's DiagServerLocator:
#                 environment of reports.cmd (cmd /c "call reports.cmd && set"),
#                 one temp copy of rwnetwork.conf per port as
#                 COMPONENT_CONFIG_PATH; foreign hosts on the own port, the
#                 same server name on another host (REP-56040), free ports
#              5. discovery errors in the Reports server logs (REP-56040,
#                 REP-50600, REP-50125 invalid stream header)
#              6. -SetPort N: own port per environment - shows the change of
#                 every rwnetwork.conf; -Apply backs up (.bak_<ts>) and changes
#            READ-ONLY unless -SetPort N -Apply. Runs on Linux with pwsh too
#            (test: reports.sh instead of reports.cmd, ip route).
#            Needs ihw_tools_lib.ps1 next to it.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
#==============================================================================
<#
.SYNOPSIS
  Reports multicast discovery: configuration, firewall, self-test, port scan,
  log errors, optional port change (read-only unless -SetPort N -Apply).
.PARAMETER OracleHome
  FMW Oracle Home (default: environment, running WebLogic, registry, C:/D:/E:\Oracle\...).
.PARAMETER DomainHome
  WebLogic domain (default: domain-registry.xml, running WebLogic).
.PARAMETER OutBase
  Directory of the log file (default TEMP).
.PARAMETER Ports
  Port range of the scan (default 14021-14030, Oracle's range).
.PARAMETER Port
  Self-test this port instead of the configured one.
.PARAMETER Timeout
  DiagServerLocator answer timeout per port in seconds (default 3).
.PARAMETER Listen
  Passive listen of the self-test in seconds (default 10).
.PARAMETER NoScan
  Steps 1-3 and 5 only.
.PARAMETER LogDays
  Days of Reports server logs (default 7).
.PARAMETER SetPort
  Own multicast port: show the change of every rwnetwork.conf.
.PARAMETER Apply
  With -SetPort: back up and change (restart Reports after it).
.PARAMETER Force
  With -SetPort: change even if another host answers on the port.
.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\reports_network_scan_fmw.ps1
.EXAMPLE
  .\reports_network_scan_fmw.ps1 -SetPort 14028 -Apply
.NOTES
  Exit 0 = ok, 1 = warnings, 2 = failures.
  Doc: 70-Customer-Projects/tools/powershell/README.md
#>
[CmdletBinding()]
param(
    [string] $OracleHome = $env:ORACLE_HOME,
    [string] $DomainHome = $env:DOMAIN_HOME,
    [string] $OutBase = $(if ($env:TEMP) { $env:TEMP } else { "/tmp" }),
    [string] $Ports = "14021-14030",
    [int] $Port = 0,
    [int] $Timeout = 3,
    [int] $Listen = 10,
    [switch] $NoScan,
    [int] $LogDays = 7,
    [int] $SetPort = 0,
    [switch] $Apply,
    [switch] $Force,
    [switch] $Version
)
Set-StrictMode -Version 2
$SCRIPT_VERSION = "2026-11-27.1"   # bump on every change
if ($Version) { Write-Output $SCRIPT_VERSION; exit 0 }
$lib = Join-Path $PSScriptRoot "ihw_tools_lib.ps1"
if (-not (Test-Path -LiteralPath $lib)) { Write-Host "ihw_tools_lib.ps1 missing next to $PSCommandPath" -ForegroundColor Red; exit 2 }
. $lib
if ($Ports -notmatch '^(\d+)-(\d+)$') { Write-Host "-Ports A-B" -ForegroundColor Red; exit 2 }
$P_FROM = [int]$Matches[1]; $P_TO = [int]$Matches[2]
if ($SetPort -and ($SetPort -lt 1024 -or $SetPort -gt 65535)) { Write-Host "-SetPort: a port 1024-65535 (Oracle range for Reports: 14021-14030)" -ForegroundColor Red; exit 2 }
if ($Apply -and -not $SetPort) { Write-Host "-Apply only with -SetPort N" -ForegroundColor Red; exit 2 }

$LOG = Join-Path $OutBase ("reports_network_scan_{0}_{1}.log" -f [Environment]::MachineName, (Get-Date -Format "yyyyMMdd_HHmmss"))
try { ihwt-write-file $LOG @() } catch { $LOG = "" }
$script:N_WARN = 0; $script:N_FAIL = 0
function _log  { param([string] $t) if ($LOG) { ihwt-append-file $LOG $t } }
function _p    { param([string] $t) Write-Host $t; _log $t }
function ok    { param([string] $t) Write-Host "  OK   " -ForegroundColor Green -NoNewline; Write-Host $t; _log "  OK   $t" }
function warn  { param([string] $t) $script:N_WARN++; Write-Host " WARN  " -ForegroundColor Yellow -NoNewline; Write-Host $t; _log " WARN  $t" }
function fail  { param([string] $t) $script:N_FAIL++; Write-Host " FAIL  " -ForegroundColor Red -NoNewline; Write-Host $t; _log " FAIL  $t" }
function info  { param([string] $t) _p "       $t" }
function section { param([string] $t) _p ""; _p "=== $t ===" }
function _mc   { param([string] $f, [string] $attr) $m = [regex]::Match(((_ihwt-lines $f) -join "`n"), '<multicast[^>]*\s' + $attr + '="([^"]*)"'); if ($m.Success) { return $m.Groups[1].Value }; return "" }

$procs = @(ihwt-procs)
$homes = ihwt-find-homes $OracleHome $DomainHome $procs
$OH = "$($homes.OH)".TrimEnd('\', '/'); $DH = "$($homes.DH)".TrimEnd('\', '/')
if (-not $DH -or -not (ihwt-isdir (Join-Path $DH "config"))) { Write-Host "DOMAIN_HOME not found - use -DomainHome" -ForegroundColor Red; exit 2 }

_p "reports_network_scan_fmw.ps1 $SCRIPT_VERSION - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
_p "Host        : $([Net.Dns]::GetHostEntry([Environment]::MachineName).HostName)"
_p "ORACLE_HOME : $(if ($OH) { $OH } else { '<not found>' })"
_p "DOMAIN_HOME : $DH"
_p "Log         : $LOG"

#==============================================================================
# 1. Discovery configuration - every rwnetwork.conf of the domain
#==============================================================================
section "1. Discovery configuration (rwnetwork.conf)"
$CFG = ihwt-jp @($DH, "config", "fmwconfig")
$NET = @(Get-ChildItem -LiteralPath $CFG -Recurse -File -Filter rwnetwork.conf -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -notmatch '[\\/](mbeans|templates?)[\\/]' } | Sort-Object FullName | ForEach-Object { $_.FullName })
$SERVERS = @(ihwt-rs-list $DH | Where-Object { $_.Name -ne '-' -and $_.Name -ne 'in-process' } | ForEach-Object { $_.Name } | Sort-Object -Unique)
$OWN_CH = ""; $OWN_PORT = ""; $diff = $false
if (-not $NET.Count) { fail "no rwnetwork.conf below $CFG - Reports not configured in this domain?" }
function _rel { param([string] $f) return $f.Substring($CFG.Length).TrimStart('\', '/') }
foreach ($f in $NET) {
    $ch = _mc $f "channel"; $po = _mc $f "port"
    if (-not $po) { warn ("{0,-70} no <multicast port=...> - discovery off / naming service?" -f (_rel $f)); continue }
    _p ("  {0,-70} {1}:{2}" -f (_rel $f), $(if ($ch) { $ch } else { "?" }), $po)
    if (-not $OWN_PORT) { $OWN_CH = $ch; $OWN_PORT = $po } elseif ($ch -ne $OWN_CH -or $po -ne $OWN_PORT) { $diff = $true }
}
if ($diff) { fail "the rwnetwork.conf files use different channels / ports - every participant needs the same (fix: -SetPort N -Apply)" }
elseif ($OWN_PORT) {
    ok "all $($NET.Count) rwnetwork.conf use ${OWN_CH}:${OWN_PORT}"
    if ($OWN_PORT -eq '14021') { info "14021 = Oracle's default port - every untouched environment in the network uses it too" }
}
if (-not $OWN_CH) { $OWN_CH = "228.5.6.7" }
if ($Port) { $OWN_PORT = "$Port"; info "port for the checks: $OWN_PORT (-Port)" } elseif (-not $OWN_PORT) { $OWN_PORT = "14021" }
info "own Reports server(s): $(if ($SERVERS.Count) { $SERVERS -join ' ' } else { 'none' })"

#==============================================================================
# 2. Multicast prerequisites
#==============================================================================
section "2. Multicast prerequisites"
if ($IHWT_ON_WINDOWS) {
    $rt = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -eq '224.0.0.0/4' })
    if ($rt.Count) { ok ("multicast route 224.0.0.0/4 on interface(s): {0}" -f ((@($rt | ForEach-Object { $_.InterfaceAlias }) | Sort-Object -Unique) -join ', ')) }
    else { warn "no IPv4 route 224.0.0.0/4 - Windows normally has one per interface (route print)" }
    $fp = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled })
    if (-not $fp.Count) { ok "Windows Firewall off - no UDP rule needed" }
    else {
        $rules = @()
        foreach ($pf in @(Get-NetFirewallPortFilter -Protocol UDP -ErrorAction SilentlyContinue | Where-Object { @($_.LocalPort) -contains $OWN_PORT -or @($_.LocalPort) -contains 'Any' })) {
            $rules += @($pf | Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' })
        }
        # program rules (java.exe / rwserver.exe allowed for every port) count too
        if ($rules.Count) { ok ("Windows Firewall: inbound UDP {0} allowed ({1})" -f $OWN_PORT, ((@($rules | ForEach-Object { $_.DisplayName }) | Sort-Object -Unique | Select-Object -First 3) -join ', ')) }
        else {
            warn "Windows Firewall on ($((@($fp | ForEach-Object { $_.Name })) -join ',')) - no inbound allow rule for UDP $OWN_PORT found (a program rule for rwserver.exe / java.exe may still allow it)"
            info "  as administrator: New-NetFirewallRule -DisplayName 'Oracle Reports discovery' -Direction Inbound -Protocol UDP -LocalPort $OWN_PORT -Action Allow"
        }
    }
} else {
    $dev = "$(& ip -o route get $OWN_CH 2>$null)"
    if ($dev -match ' dev (\S+)') { ok "multicast route: $OWN_CH via $($Matches[1]) (Linux test run)" } else { fail "no route to the multicast group $OWN_CH - Reports discovery fails (REP-50600)" }
}

#==============================================================================
# 3. Self-test: send + receive on channel:port (UdpClient)
#==============================================================================
section "3. Multicast self-test (${OWN_CH}:${OWN_PORT})"
if (@($procs | Where-Object { $_.Name -match '^rwserver(\.exe)?$' }).Count) {
    ok "a Reports server runs on this host - reception works, self-test skipped"
} else {
    $u = $null; $w = $null
    try {
        $grp = [Net.IPAddress]::Parse($OWN_CH)
        $u = New-Object Net.Sockets.UdpClient
        $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $u.Client.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, [int]$OWN_PORT)))
        $u.JoinMulticastGroup($grp)
        $u.Client.ReceiveTimeout = 500
        $w = New-Object Net.Sockets.UdpClient
        $w.MulticastLoopback = $true; $w.Ttl = 1
        $tok = [Text.Encoding]::ASCII.GetBytes("IHW-MC-SELFTEST-$((Get-Date).Ticks)")
        [void]$w.Send($tok, $tok.Length, (New-Object Net.IPEndPoint($grp, [int]$OWN_PORT)))
        $own = $false; $senders = @{}; $end = (Get-Date).AddSeconds([math]::Max($Listen, 3))
        while ((Get-Date) -lt $end) {
            $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            try { $data = $u.Receive([ref]$ep) } catch { continue }
            if ([Text.Encoding]::ASCII.GetString($data) -eq [Text.Encoding]::ASCII.GetString($tok)) { $own = $true }
            else { $k = "$($ep.Address)"; $senders[$k] = 1 + $(if ($senders.ContainsKey($k)) { $senders[$k] } else { 0 }) }
        }
        if ($own) { ok "packet to ${OWN_CH}:${OWN_PORT} sent and received on this host" }
        else { fail "own packet to ${OWN_CH}:${OWN_PORT} NOT received - the Reports server stops with REP-50600 (firewall, interface)" }
        $ownips = @(); try { $ownips = @([Net.Dns]::GetHostAddresses([Environment]::MachineName) | ForEach-Object { "$_" }) } catch { }
        foreach ($k in $senders.Keys) {
            if ($ownips -contains $k) { info "  packets from this host ($k) - own Reports server starting / searching" }
            else { warn "foreign sender $k on ${OWN_CH}:${OWN_PORT} ($($senders[$k]) packets) - another environment on this port?" }
        }
        info "  passive listen $([math]::Max($Listen, 3)) s - Reports servers send only while starting; the active scan below asks them"
    } catch { warn "self-test could not run: $($_.Exception.Message)" }
    finally { if ($u) { $u.Close() }; if ($w) { $w.Close() } }
}

#==============================================================================
# 4. Active scan with DiagServerLocator over a port range
#==============================================================================
$SCAN_DONE = $false; $FOREIGN = New-Object System.Collections.Generic.List[string]
if (-not $NoScan) {
    section "4. Active scan - Reports servers per port (DiagServerLocator)"
    $rsh = ""
    foreach ($n in $(if ($IHWT_ON_WINDOWS) { @("reports.cmd", "reports.bat") } else { @("reports.sh") })) { $f = ihwt-jp @($DH, "reports", "bin", $n); if (Test-Path -LiteralPath $f) { $rsh = $f; break } }
    $java = ihwt-jp @($OH, "oracle_common", "jdk", "bin", $(if ($IHWT_ON_WINDOWS) { "java.exe" } else { "java" }))
    $tpl = $(if ($NET.Count) { $NET[0] } else { "" })
    if (-not $rsh -or -not $java -or -not (Test-Path -LiteralPath $java) -or -not $tpl) {
        warn "scan not possible - need DOMAIN_HOME\reports\bin\reports.cmd, ORACLE_HOME\oracle_common\jdk and one rwnetwork.conf"
    } else {
        # the environment of the reports script (class path, PATH with the Reports
        # DLLs) - read once, then given to every java call
        $envv = @{}
        if ($IHWT_ON_WINDOWS) {
            # a small .cmd (quoting of cmd /c through ProcessStartInfo is fragile)
            $wrap = Join-Path ([IO.Path]::GetTempPath()) "ihw_rnscan_env_$PID.cmd"
            [IO.File]::WriteAllText($wrap, ("@echo off`r`nset `"DOMAIN_HOME={0}`"`r`nset `"ORACLE_HOME={1}`"`r`ncall `"{2}`" >nul 2>&1`r`nset`r`n" -f $DH, $OH, $rsh), [Text.Encoding]::Default)
            $r = ihwt-exec $wrap @() @{} 120
            Remove-Item -LiteralPath $wrap -Force -ErrorAction SilentlyContinue
        }
        else { $r = ihwt-exec "/bin/bash" @("-c", "export DOMAIN_HOME='$DH' ORACLE_HOME='$OH'; . '$rsh' >/dev/null 2>&1; env") @{} 120 }
        foreach ($l in ("$($r.Out)" -split "`r?`n")) { $i = $l.IndexOf('='); if ($i -gt 0) { $envv[$l.Substring(0, $i)] = $l.Substring($i + 1) } }
        $cp = $(if ($envv.ContainsKey('REPORTS_CLASSPATH')) { $envv['REPORTS_CLASSPATH'] } else { "" })
        if (-not $cp) { warn "REPORTS_CLASSPATH not set by $rsh - scan not possible" }
        else {
            $SCAN_DONE = $true
            info "ports $P_FROM-$P_TO, channel $OWN_CH, timeout $Timeout s per port"
            $ownnames = @([Environment]::MachineName, ([Net.Dns]::GetHostEntry([Environment]::MachineName).HostName)) + @(try { [Net.Dns]::GetHostAddresses([Environment]::MachineName) | ForEach-Object { "$_" } } catch { })
            $free = @(); $any = $false; $sfail = $false
            _p ""; _p ("  {0,-7} {1,-24} {2,-8} {3}" -f "Port", "Name", "Type", "Host")
            _p ("  {0,-7} {1,-24} {2,-8} {3}" -f "-------", "------------------------", "--------", "----------------------------")
            for ($po = $P_FROM; $po -le $P_TO; $po++) {
                $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ihw_rnscan_{0}_{1}" -f $PID, $po)
                New-Item -ItemType Directory -Path $tmp -Force | Out-Null
                $tx = [IO.File]::ReadAllText($tpl)
                $tx = [regex]::Replace($tx, '(<multicast[^>]*\sport=")\d*', ('${1}' + $po)); $tx = [regex]::Replace($tx, '(<multicast[^>]*\schannel=")[^"]*', ('${1}' + $OWN_CH))
                [IO.File]::WriteAllText((Join-Path $tmp "rwnetwork.conf"), $tx, $IHWT_UTF8)
                $e2 = @{}; foreach ($k in $envv.Keys) { $e2[$k] = $envv[$k] }; $e2['COMPONENT_CONFIG_PATH'] = $tmp
                $res = ihwt-exec $java @("-DORACLE_HOME=$OH", "-classpath", $cp, "oracle.reports.utility.DiagServerLocator", "-findAll", "-timeout", "$Timeout") $e2 ($Timeout + 30)
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
                $hits = @(("$($res.Out)" -split "`r?`n") | Where-Object { $_ -match '^\(\d+\) Name = ' })
                if (-not $hits.Count) {
                    if ("$($res.Out)" -match 'REP-50503') { _p ("  {0,-7} -" -f $po); $free += $po }
                    else { $er = @(("$($res.Out)" -split "`r?`n") | Where-Object { $_ -match 'REP-|Exception' }) + @(""); _p ("  {0,-7} ? {1}" -f $po, $er[0]); $sfail = $true }
                    continue
                }
                $any = $true
                foreach ($h in $hits) {
                    $nm = $(if ($h -match 'Name = (\S+)') { $Matches[1] } else { "?" }); $ty = $(if ($h -match 'Type = (\S+)') { $Matches[1] } else { "?" }); $ho = $(if ($h -match 'Host = (\S+)') { $Matches[1] } else { "?" })
                    $mine = ($ownnames -contains $ho) -or ($ownnames -contains ($ho -split '\.')[0])
                    _p ("  {0,-7} {1,-24} {2,-8} {3}{4}" -f $po, $nm, $ty, $ho, $(if ($mine) { "  (this host)" } else { "" }))
                    if (-not $mine) { $FOREIGN.Add("$po|$nm@$ho") }
                    if ("$po" -eq $OWN_PORT -and -not $mine) { warn "  port $po (own port) is used by $nm on $ho - the environments see each other" }
                    if ($SERVERS -contains $nm -and -not $mine) { fail "  server name '$nm' also on $ho (port $po) - same name on the same port = REP-56040" }
                }
            }
            _p ""
            if (-not $any) { info "no Reports server answered in the range" }
            if ($sfail) { warn "some ports could not be scanned - see the '?' lines" }
            if ($free.Count) { info "ports without an answer: $($free -join ' ') (only RUNNING servers answer - a port may still belong to a stopped environment)" }
        }
    }
}

#==============================================================================
# 5. Discovery errors in the Reports server logs
#==============================================================================
section "5. Discovery errors in the Reports server logs (last $LogDays days)"
$lim = (Get-Date).Date.AddDays(-$LogDays).ToString('yyyy-MM-dd')
$rlogs = @(@((ihwt-jp @($DH, "servers")), (ihwt-jp @($DH, "system_components"))) | Where-Object { ihwt-isdir $_ } |
           ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter 'rwserver_diagnostic*.log' -ErrorAction SilentlyContinue } | Sort-Object FullName | ForEach-Object { $_.FullName })
$n56040 = 0
if (-not $rlogs.Count) { info "no rwserver_diagnostic*.log below $DH\servers" }
else {
    foreach ($f in $rlogs) {
        $hits = @(_ihwt-lines $f | Where-Object { $_ -cmatch 'REP-56040|REP-50600|REP-50125.*(StreamCorrupted|invalid stream header)' -and $_ -match '^\[(\d{4}-\d{2}-\d{2})' -and [string]::CompareOrdinal($Matches[1], $lim) -ge 0 })
        if (-not $hits.Count) { continue }
        $cnt = @{}
        foreach ($h in $hits) { $c = $(if ($h -cmatch 'REP-56040') { "REP-56040" } elseif ($h -cmatch 'REP-50600') { "REP-50600" } else { "REP-50125" }); $k = "$($h.Substring(1, 10));$c"; $cnt[$k] = 1 + $(if ($cnt.ContainsKey($k)) { $cnt[$k] } else { 0 }) }
        foreach ($k in @($cnt.Keys | Sort-Object)) {
            $d, $c = $k -split ';'; _p ("  {0,-60} {1} {2,-9} {3}x" -f $f.Substring($DH.Length).TrimStart('\', '/'), $d, $c, $cnt[$k])
            if ($c -eq 'REP-56040') { $n56040 += $cnt[$k] }
        }
        $last = $hits[-1]; info "  last: $(if ($last.Length -gt 220) { $last.Substring(0, 220) } else { $last })"
    }
    if ($n56040) {
        fail "REP-56040 ${n56040}x: a Reports server with the same name answers on the same multicast port (other environment on ${OWN_PORT}?)"
        info "  fix: own port per environment - free port from the scan, then -SetPort N -Apply here and in the other environment"
    } else { ok "no REP-56040 / REP-50600 / stream header error in $($rlogs.Count) Reports server log(s)" }
}

#==============================================================================
# 6. -SetPort N: own multicast port for this environment
#==============================================================================
if ($SetPort) {
    section ("6. Change the multicast port {0} -> {1}{2}" -f $OWN_PORT, $SetPort, $(if ($Apply) { "" } else { " (dry run)" }))
    $block = $false
    if ("$SetPort" -eq $OWN_PORT -and -not $diff) { ok "every rwnetwork.conf already uses $SetPort - nothing to do"; $block = $true }
    if (-not $block -and $SCAN_DONE) {
        $busy = @($FOREIGN | Where-Object { ($_ -split '\|')[0] -eq "$SetPort" } | ForEach-Object { ($_ -split '\|')[1] })
        if ($busy.Count -and -not $Force) { fail "port $SetPort is used by another host: $($busy -join ' ') - choose a free port (scan) or -Force"; $block = $true }
        elseif ($busy.Count) { warn "port $SetPort is used by $($busy -join ' ') - changed anyway (-Force)" }
    } elseif (-not $block) { warn "no scan in this run - the new port $SetPort was not checked against other environments" }
    if (-not $block) {
        $ts = Get-Date -Format "yyyyMMdd_HHmmss"
        foreach ($f in $NET) {
            $po = _mc $f "port"
            if (-not $po) { warn ("{0,-70} no <multicast port=...> - left as it is" -f (_rel $f)); continue }
            if ($po -eq "$SetPort") { ok ("{0,-70} already {1}" -f (_rel $f), $SetPort); continue }
            if (-not $Apply) { info ("{0,-70} {1} -> {2}" -f (_rel $f), $po, $SetPort); continue }
            try { Copy-Item -LiteralPath $f -Destination "$f.bak_$ts" -ErrorAction Stop } catch { fail "$(_rel $f): backup failed - not changed ($_)"; continue }
            # text replace: line ends (CRLF / LF) and the rest of the file stay as they are
            $tx = [IO.File]::ReadAllText($f)
            [IO.File]::WriteAllText($f, [regex]::Replace($tx, '(<multicast[^>]*\sport=")\d*', ('${1}' + $SetPort)), $IHWT_UTF8)
            if ((_mc $f "port") -eq "$SetPort") { ok ("{0,-70} {1} -> {2}  (backup .bak_{3})" -f (_rel $f), $po, $SetPort, $ts) }
            else { fail ("{0,-70} not changed - restore: Copy-Item '{1}.bak_{2}' '{1}'" -f (_rel $f), $f, $ts) }
        }
        if ($Apply) {
            info "takes effect at the next start: restart the Reports server(s) $($SERVERS -join ' ') and the managed server WLS_REPORTS"
            info "every OTHER environment on $OWN_PORT needs its own port too - run this tool there with another port"
            info "way back: Copy-Item <file>.bak_$ts <file> for each file above, then restart"
            if (@($procs | Where-Object { $_.Name -match '^rwserver(\.exe)?$' }).Count) { warn "a Reports server runs now - it keeps port $OWN_PORT until its restart" }
        } else { info "dry run - add -Apply to back up and change the files" }
    }
}

section "Result"
_p "Result: $script:N_FAIL FAIL, $script:N_WARN WARN - log: $LOG"
if ($script:N_FAIL -gt 0) { exit 2 }
if ($script:N_WARN -gt 0) { exit 1 }
exit 0
