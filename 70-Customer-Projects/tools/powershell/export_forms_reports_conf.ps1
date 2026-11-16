#Requires -Version 5.1
#==============================================================================
# Script   : export_forms_reports_conf.ps1
# Purpose  : Export the customer-specific Forms & Reports CONFIGURATION of an
#            EXISTING environment on MS Windows Server (12.2.1.x or 14.1.2)
#            into one archive - all that is needed to build the environment
#            again with the IHateWeblogic 14c library on Linux. What is
#            installed, patch level, Java, OS, performance and security of
#            operation are NOT here - that is collect_fmw_env.ps1; an analysis
#            always needs both runs.
#            Windows / PowerShell version of tools/bash/export_forms_reports_conf.sh
#            with the SAME archive layout (00_report.txt, raw/, ihw_import/,
#            sources_*, manifest.csv, secrets_locations.txt), so the analysis
#            on our side reads Linux and Windows exports alike:
#              raw/        1:1 copies (domain/, oracle_home/, other/<drive>/...)
#              ihw_import/ proposals for the library (nothing is applied) +
#                          Windows only: registry_env.txt (Oracle KEY_* and
#                          machine environment), path_map.txt (Windows path ->
#                          proposal for the Linux path)
#              sources_*   paths of the Forms / Reports sources - inventory
#                          only, NO module content
#            Paths in the derived files are written with "/" (D:/Oracle/...).
#            READ-ONLY on the system: writes only below -OutBase.
#            Passwords stay in the files (1:1) - the archive is ENCRYPTED
#            (AES-256, openssl compatible, passphrase asked twice); -Masked
#            masks them and leaves the archive unencrypted.
#            NEVER commit an export: OutBase inside a git work tree is refused
#            unless git ignores it. Needs ihw_tools_lib.ps1 next to it.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
#==============================================================================
<#
.SYNOPSIS
  Export the Forms & Reports configuration of a Windows host for the 14c rebuild.

.DESCRIPTION
  Forms (formsweb.cfg + every envFile, Registry.dat, webutil.cfg, jnlp, customer
  jars), Reports (rwserver.conf / rwservlet.properties / cgicmd.dat of every
  Reports server, uifont.ali, PPD, AFM), domain scripts, JDBC data sources,
  Oracle Net, web tier (IIS + iisproxy.ini, Nginx, Apache, OHS), fonts, the
  Oracle registry environment, the source inventory and a proposal for the
  14c environment.conf. Load profile, certificates of the HTTPS listeners,
  patch level, Java, OS and memory are in collect_fmw_env.ps1.

.PARAMETER OracleHome
  Default: $env:ORACLE_HOME, running WebLogic, registry, C:|D:|E:\Oracle\Middleware\Oracle_Home ...

.PARAMETER DomainHome
  Default: $env:DOMAIN_HOME, <OracleHome>\domain-registry.xml, running AdminServer.

.PARAMETER OutBase
  Output directory (default: $env:TEMP).

.PARAMETER Masked
  Mask passwords and do not encrypt (shareable for an analysis).

.PARAMETER NoFonts
  Do not copy font files (only list them).

.PARAMETER Keep
  Keep the unpacked staging directory.

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\export_forms_reports_conf.ps1

.EXAMPLE
  .\export_forms_reports_conf.ps1 -OracleHome D:\Oracle\Middleware\Oracle_Home -DomainHome D:\Oracle\user_projects\domains\fr_domain -OutBase D:\temp

.NOTES
  Runs as the software owner of the Oracle Home or an administrator.
  Decrypt on our side: openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -in <file>.zip.enc -out <file>.zip
  Doc: 70-Customer-Projects/tools/powershell/README.md
#>
[CmdletBinding()]
param(
    [string] $OracleHome = $env:ORACLE_HOME,
    [string] $DomainHome = $env:DOMAIN_HOME,
    [string] $OutBase = $(if ($env:TEMP) { $env:TEMP } else { "/tmp" }),
    [switch] $Masked,
    [switch] $NoFonts,
    [switch] $Keep,
    # moved to collect_fmw_env.ps1 - accepted and ignored with a note
    [switch] $NoLoad,
    [int] $LoadDays = 0,
    [string] $RwAuth = "",
    [switch] $Version
)

Set-StrictMode -Version 2
$SCRIPT_VERSION = "2026-11-16.1"   # bump on every change - shown in the report
if ($Version) { Write-Output $SCRIPT_VERSION; exit 0 }

$lib = Join-Path $PSScriptRoot "ihw_tools_lib.ps1"
if (-not (Test-Path -LiteralPath $lib)) { Write-Host "ihw_tools_lib.ps1 missing next to $PSCommandPath" -ForegroundColor Red; exit 2 }
. $lib
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$ND = [char]0x2013                     # en dash like the bash version (ASCII source for PS 5.1)
$LATIN1 = [Text.Encoding]::GetEncoding(28591)   # byte-preserving read / write of config files
$PSEP = [IO.Path]::PathSeparator       # ";" on Windows (FORMS_PATH, CLASSPATH ...), ":" on Linux
$WARNINGS = New-Object System.Collections.Generic.List[string]
function say  { param([string] $t) ihwt-say $t }
function warn { param([string] $t) Write-Host "  WARN  $t" -ForegroundColor Yellow; $WARNINGS.Add($t) }

# --- never into git ------------------------------------------------------------
try { $OutBase = (Resolve-Path -LiteralPath $OutBase -ErrorAction Stop).Path } catch { Write-Host "Output directory does not exist: $OutBase" -ForegroundColor Red; exit 2 }
$HOSTN = [Environment]::MachineName
$TS = Get-Date -Format "yyyyMMdd_HHmmss"
$NAME = "ihw_export_{0}_{1}" -f $HOSTN, $TS
if (-not (ihwt-git-guard $OutBase "$NAME.zip")) { exit 2 }

# --- passphrase first (before minutes of collecting) ---------------------------
$PASS = ""
if (-not $Masked) {
    $PASS = ihwt-read-passphrase "export archive"
    if (-not $PASS) { Write-Host "  -> or use -Masked" -ForegroundColor Yellow; exit 2 }
}
$moved = @(); if ($NoLoad) { $moved += "-NoLoad" }; if ($PSBoundParameters.ContainsKey('LoadDays')) { $moved += "-LoadDays" }; if ($RwAuth) { $moved += "-RwAuth" }
if ($moved.Count) { say "NOTE: $($moved -join ' ') - the load profile moved to collect_fmw_env.ps1 (2026-11-16), ignored here" }
$RwAuth = ""

# --- ORACLE_HOME / DOMAIN_HOME (ihwt-find-homes, as collect_fmw_env.ps1) --------
$procs = @(ihwt-procs)
$homes = ihwt-find-homes $OracleHome $DomainHome $procs
$OH = $homes.OH; $DH = $homes.DH
if (-not $OH) { Write-Host "ORACLE_HOME not found - use -OracleHome" -ForegroundColor Red; exit 2 }
if (-not $DH) { Write-Host "DOMAIN_HOME not found (config\config.xml) - use -DomainHome" -ForegroundColor Red; exit 2 }
$OH = (Get-Item -LiteralPath $OH).FullName.TrimEnd('\', '/'); $DH = (Get-Item -LiteralPath $DH).FullName.TrimEnd('\', '/')
$OHF = ihwt-fwd $OH; $DHF = ihwt-fwd $DH
$CFG = ihwt-jp @($DH, "config", "fmwconfig")

$STAGE = Join-Path $OutBase $NAME
try { New-Item -ItemType Directory -Path (Join-Path $STAGE "raw"), (Join-Path $STAGE "ihw_import") -Force -ErrorAction Stop | Out-Null }
catch { Write-Host "Cannot create $STAGE : $_" -ForegroundColor Red; exit 2 }
$IMP = Join-Path $STAGE "ihw_import"
$DONE = $false

say "export_forms_reports_conf.ps1 $SCRIPT_VERSION"
say "ORACLE_HOME $OH"
say "DOMAIN_HOME $DH"
say "staging     $STAGE"

#------------------------------------------------------------------------------
# helpers
#------------------------------------------------------------------------------
$SEEN = @{}
$MANIFEST = New-Object System.Collections.Generic.List[string]; $MANIFEST.Add("category;source;stored;size;sha256")
$SECRETS = New-Object System.Collections.Generic.List[string]
$SECRET_RE = [regex] '(?i)(password|passwd|dbpassword|authid|userid|<identifier|\{AES)'

# _glob DIR FILTER - files of DIR (no recursion) matching FILTER (case-insensitive)
function _glob {
    param([string] $Dir, [string] $Filter = "*")
    if (-not (ihwt-isdir $Dir)) { return @() }
    $re = '^' + [regex]::Escape($Filter).Replace('\*', '.*').Replace('\?', '.') + '$'
    return @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $re } | Sort-Object FullName | ForEach-Object { $_.FullName })
}
function _dirs {
    param([string] $Dir)
    if (-not (ihwt-isdir $Dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object { $_.FullName })
}
# _rel PATH - place of a source file below the stage (raw/domain, raw/oracle_home,
# raw/other/<drive>/..., raw/other/UNC/<server>/...)
function _rel {
    param([string] $Full)
    $f = ihwt-fwd $Full
    if (ihwt-under $f $DHF) { return "raw/domain/" + $f.Substring($DHF.Length).TrimStart('/') }
    if (ihwt-under $f $OHF) { return "raw/oracle_home/" + $f.Substring($OHF.Length).TrimStart('/') }
    if ($f -match '^([A-Za-z]):/(.*)$') { return "raw/other/$($Matches[1].ToUpper())/$($Matches[2])" }
    if ($f -match '^//([^/]+)/(.*)$') { return "raw/other/UNC/$($Matches[1])/$($Matches[2])" }
    return "raw/other$f"
}
# _store SRC CATEGORY [DEST_REL] [SOURCE_NAME] - copy into raw/ (or DEST_REL)
function _store {
    param([string] $Src, [string] $Cat, [string] $Rel = "", [string] $SrcName = "")
    if (-not $Src -or -not (Test-Path -LiteralPath $Src -PathType Leaf)) { return $false }
    try { $fi = Get-Item -LiteralPath $Src -Force -ErrorAction Stop } catch { return $false }
    $full = $fi.FullName
    if (-not $Rel) { $Rel = _rel $full }
    if ($SEEN.ContainsKey($Rel)) { return $true }
    $SEEN[$Rel] = 1
    $dst = Join-Path $STAGE $Rel
    $isTxt = ihwt-is-text $full
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force -ErrorAction Stop | Out-Null
        if ($Masked -and $isTxt) { [IO.File]::WriteAllText($dst, (ihwt-mask ([IO.File]::ReadAllText($full, $LATIN1))), $LATIN1) }
        else { Copy-Item -LiteralPath $full -Destination $dst -Force -ErrorAction Stop }
        (Get-Item -LiteralPath $dst -Force).LastWriteTime = $fi.LastWriteTime
    } catch { warn "not readable as $([Environment]::UserName): $(ihwt-fwd $full)"; return $false }
    # where secrets are (file + line + keyword, never the value)
    if ($isTxt) {
        $n = 0
        foreach ($l in [IO.File]::ReadAllLines($full, $LATIN1)) { $n++; foreach ($m in $SECRET_RE.Matches($l)) { $SECRETS.Add("${Rel}:${n}:$($m.Value)") } }
    }
    $sha = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
    $MANIFEST.Add(("{0};{1};{2};{3};{4}" -f $Cat, $(if ($SrcName) { $SrcName } else { ihwt-fwd $full }), $Rel, $fi.Length, $sha))
    return $true
}
# _expand PATH - resolve the usual variables of env files / scripts
function _expand {
    param([string] $p)
    foreach ($v in @(@('ORACLE_HOME', $OH), @('DOMAIN_HOME', $DH), @('MW_HOME', $OH), @('WL_HOME', (Join-Path $OH "wlserver")))) {
        $p = [regex]::Replace($p, '\$\{?' + $v[0] + '\}?|%' + $v[0] + '%', $v[1].Replace('$', '$$'))
    }
    return $p
}
function _first { param($a) $x = @($a); if ($x.Count) { return "$($x[0])" }; return "" }
function _last  { param($a) $x = @($a); if ($x.Count) { return "$($x[$x.Count - 1])" }; return "" }
function _text  { param([string] $f) if ($f -and (Test-Path -LiteralPath $f -PathType Leaf)) { try { return [IO.File]::ReadAllText($f, $LATIN1) } catch { } }; return "" }
# _nocomment TEXT - lines outside <!-- ... --> (line based, like the awk of bash)
function _nocomment {
    param([string] $t)
    $c = $false; $o = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($t -split "`r?`n")) { if ($l -match '<!--') { $c = $true }; if ($c) { if ($l -match '-->') { $c = $false }; continue }; $o.Add($l) }
    return ($o -join "`n")
}
function _sortu { param($a) return @(@($a) | Where-Object { "$_" -ne "" } | Sort-Object -Unique) }

try {
#==============================================================================
# 1. Forms
#==============================================================================
say "Forms ..."
$FORMS_CFGS = @(foreach ($s in @(_dirs (Join-Path $CFG "servers"))) {
    foreach ($a in @(_dirs (Join-Path $s "applications"))) {
        if ((Split-Path -Leaf $a) -match '^(forms|formsapp)_') { $f = ihwt-jp @($a, "config", "formsweb.cfg"); if (Test-Path -LiteralPath $f -PathType Leaf) { $f } }
    } }) | Sort-Object
$FORMS_CFGS = @($FORMS_CFGS)
$envSet = [ordered]@{}
foreach ($fw in $FORMS_CFGS) {
    $cdir = Split-Path -Parent $fw
    [void](_store $fw forms_wls)
    foreach ($f in @(@(_glob $cdir "*.env") + @(_glob $cdir "*.cfg") + @(_glob (ihwt-jp @($cdir, "oracle", "forms", "registry")) "*"))) { [void](_store $f forms_wls) }
    # every envFile of every section (relative = config dir)
    $seenE = @{}
    foreach ($e in (ihwt-cfgval $fw 'envFile')) {
        if (-not $e -or $seenE.ContainsKey($e)) { continue }; $seenE[$e] = 1
        $ef = $(if ([IO.Path]::IsPathRooted($e)) { $e } else { Join-Path $cdir $e })
        $ef = _expand $ef
        if (Test-Path -LiteralPath $ef -PathType Leaf) { [void](_store $ef forms_env); $envSet[(Get-Item -LiteralPath $ef -Force).FullName] = 1 }
        else { warn "envFile $e of $(ihwt-fwd $fw) not found" }
    }
}
if (-not $FORMS_CFGS.Count) { warn "no formsweb.cfg found (Forms not deployed?)" }
$ENV_FILES = @($envSet.Keys | Sort-Object)

foreach ($d in @(@(_dirs (ihwt-jp @($CFG, "components", "FORMS", "instances"))) + @(_dirs (ihwt-jp @($CFG, "components", "FORMS")) | Where-Object { (Split-Path -Leaf $_) -notin @('instances', 'mbeans') }))) {
    $sv = Join-Path $d "server"
    foreach ($f in @(@(_glob $sv "*.cfg") + @(_glob $sv "*.conf") + @(_glob $sv "*.xml"))) { [void](_store $f forms_inst) }
    foreach ($r in @(_dirs (ihwt-jp @($d, "admin", "resource")))) { foreach ($f in @(_glob $r "fmrweb*.res")) { [void](_store $f forms_inst) } }
}
foreach ($f in @(@(_glob (ihwt-jp @($OH, "forms", "java")) "*.jnlp") + @(_glob (ihwt-jp @($OH, "forms", "server")) "*.jnlp"))) { [void](_store $f forms_jnlp) }
# session-timeout of the Forms servlet (formsapp.ear -> formsweb.war WEB-INF/weblogic.xml):
# needed for the timeout chain heartBeat < FORMS_TIMEOUT < session-timeout
$ear = ihwt-jp @($OH, "forms", "j2ee", "formsapp.ear")
if (Test-Path -LiteralPath $ear -PathType Leaf) {
    $za = $null; $wz = $null
    try {
        $za = [IO.Compression.ZipFile]::OpenRead($ear)
        $we = $za.GetEntry("formsweb.war")
        if ($we) {
            $ms = New-Object IO.MemoryStream; $st = $we.Open(); $st.CopyTo($ms); $st.Close(); $ms.Position = 0
            $wz = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Read)
            foreach ($x in @("weblogic.xml", "web.xml")) {
                $en = $wz.GetEntry("WEB-INF/$x")
                if ($en -and $en.Length -gt 0) {
                    $tmp = Join-Path $STAGE ".ear_$x"
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($en, $tmp, $true)
                    [void](_store $tmp forms_ear "raw/oracle_home/forms/j2ee/formsapp.ear/formsweb.war/WEB-INF/$x" "$(ihwt-fwd $ear)!formsweb.war!WEB-INF/$x")
                    Remove-Item -LiteralPath $tmp -Force
                }
            }
        }
    } catch { warn "formsapp.ear not readable: $_" }
    finally { if ($wz) { $wz.Dispose() }; if ($za) { $za.Dispose() } }
}

# --- customer jars (never frm*.jar / frmsal / jacob - they come from 14-/40-) ---
$JARS = New-Object System.Collections.Generic.List[string]; $JARS.Add("jar;size;sha256;referenced_in;stored")
$JREF = @{}
$JDIR = ihwt-jp @($OH, "forms", "java")
# relative jar names (archive=, jnlp href) live in $OH/forms/java
function _jpath { param([string] $j) if ([IO.Path]::IsPathRooted($j)) { return (ihwt-fwd $j) }; return (ihwt-fwd (Join-Path $JDIR ($j -replace '^\./', ''))) }
function _jadd  { param([string] $p, [string] $r) if ($JREF.ContainsKey($p)) { $JREF[$p] += $r } else { $JREF[$p] = $r } }
foreach ($fw in $FORMS_CFGS) {
    foreach ($l in (ihwt-sections $fw)) {
        $sec, $k, $v = $l -split "`t", 3
        if ($k -cmatch '^(archive|archive_.*|WebUtilArchive|webUtilArchive)$') {
            foreach ($j in ($v -split '[,\s]+')) { if ($j) { _jadd (_jpath $j) "formsweb.cfg[$sec].$k " } }
        }
    }
}
foreach ($ef in $ENV_FILES) {
    foreach ($cp in (ihwt-cfgval $ef 'CLASSPATH')) {
        foreach ($p in ($cp -split [regex]::Escape([string]$PSEP))) {
            $p = $p.Trim(); if (-not $p -or $p -match '[%$]') { continue }   # Oracle placeholders (%ORACLE_HOME% ...)
            if ($p -like '*.jar') { _jadd (_jpath (_expand $p)) "$(Split-Path -Leaf $ef):CLASSPATH " }
        }
    }
}
$jn = Join-Path $JDIR "extensions.jnlp"
if (Test-Path -LiteralPath $jn -PathType Leaf) {
    foreach ($l in [IO.File]::ReadAllLines($jn)) {
        if ($l -match '^\s*<!--') { continue }
        foreach ($m in [regex]::Matches($l, 'href="([^"]+\.jar)"')) { _jadd (_jpath $m.Groups[1].Value) "extensions.jnlp " }
    }
}
foreach ($j in @(_glob $JDIR "*.jar")) { _jadd (ihwt-fwd $j) "" }
foreach ($jp in @($JREF.Keys | Sort-Object)) {
    $jb = Split-Path -Leaf $jp
    if ($jb -like 'frm*.jar' -or $jb -like 'jacob*.jar') { continue }                          # Oracle / our 14c logic
    if ((ihwt-under $jp $OHF) -and -not (ihwt-under $jp (ihwt-fwd $JDIR))) { continue }         # other Oracle jars
    if (Test-Path -LiteralPath $jp -PathType Leaf) {
        [void](_store $jp customer_jar "ihw_import/forms_java/$jb")
        $fi = Get-Item -LiteralPath $jp -Force
        $JARS.Add(("{0};{1};{2};{3};{4}" -f $jp, $fi.Length, (Get-FileHash -LiteralPath $jp -Algorithm SHA256).Hash.ToLower(), $(if ($JREF[$jp]) { $JREF[$jp] } else { "in forms/java, not referenced" }), "ihw_import/forms_java/$jb"))
    } else {
        $JARS.Add("$jp;-;-;$($JREF[$jp]);MISSING")
    }
}
# signers of the customer jars (keytool of the JDK in the Oracle Home)
$JARCERTS = New-Object System.Collections.Generic.List[string]
$kt = ""
foreach ($k in @((ihwt-jp @($OH, "oracle_common", "jdk", "bin", "keytool.exe")), (ihwt-jp @($OH, "oracle_common", "jdk", "bin", "keytool")))) { if (Test-Path -LiteralPath $k -PathType Leaf) { $kt = $k; break } }
if (-not $kt) { $c = Get-Command keytool -ErrorAction SilentlyContinue; if ($c) { $kt = $c.Source } }
if ($kt) {
    foreach ($j in @(_glob (Join-Path $IMP "forms_java") "*.jar")) {
        $out = (ihwt-exec $kt @("-printcert", "-jarfile", $j) -TimeoutSec 120).Out
        $s1 = $false; $ow = ""; $is = ""; $un = ""
        foreach ($l in ($out -split "`r?`n")) {
            if ($l -match '^Signer #1') { $s1 = $true }
            if (-not $s1) { continue }
            if (-not $ow -and $l -match '^Owner: (.*)$') { $ow = $Matches[1] }
            if (-not $is -and $l -match '^Issuer: (.*)$') { $is = $Matches[1] }
            if (-not $un -and $l -match 'until: (.*)$') { $un = $Matches[1] }
        }
        if ($ow -or $is -or $un) { $JARCERTS.Add(("jar {0};{1};{2};{3}" -f (Split-Path -Leaf $j), ($ow -replace ';', ','), ($is -replace ';', ','), $un)) }
    }
}

#==============================================================================
# 2. Reports
#==============================================================================
say "Reports ..."
$RSV = New-Object System.Collections.Generic.List[string]
$RSV.Add("name;type;running;rwserver.conf;engines(init/min/max);engLife;identifier;securityId;jobStatusRepository;broadcast_port")
function _rs_line {
    param([string] $n, [string] $t, [string] $c, [string] $net)
    $run = $(if (@($procs | Where-Object { "$($_.CommandLine)" -match "rwserver.* server=$([regex]::Escape($n))( |`"|$)" }).Count) { "yes" } else { "no" })
    $txt = _text $c; $eng = ""
    foreach ($l in ($txt -split "`r?`n")) {
        if ($l -match 'initEngine="[0-9]+"[^>]*') {
            $eng = (@([regex]::Matches($Matches[0], '(initEngine|minEngine|maxEngine)="([0-9]+)"') | ForEach-Object { $_.Groups[2].Value }) -join '/'); break
        }
    }
    $life = $(if ($txt -match 'engLife="([0-9]+)"') { $Matches[1] } else { "" })
    $idf = $(if ($txt -match '<identifier[^>]*encrypted="yes"') { "encrypted" } elseif ($txt -match '<identifier') { "clear" } else { "none" })
    $sec = $(if ($txt -match 'securityId=') { "yes" } else { "no" })
    $jsr = $(if ((_nocomment $txt) -match '<jobStatusRepository') { "yes" } else { "no" })
    $port = ""
    foreach ($l in ((_text $net) -split "`r?`n")) { if ($l -match '<(multicast|cluster)[^>]*port="([0-9]+)"') { $port = $Matches[2]; break } }
    $RSV.Add(("{0};{1};{2};{3};{4};{5};{6};{7};{8};{9}" -f $n, $t, $run, (ihwt-fwd $c), $(if ($eng) { $eng } else { "-" }), $(if ($life) { $life } else { "-" }), $idf, $sec, $jsr, $(if ($port) { $port } else { "-" })))
}
# the Reports servers of the domain (ihwt-rs-list - the collector uses the
# same list for the load profile): standalone components, then the rwservlet
# configurations of the WLS_REPORTS applications
$INPROC_DIRS = @(); $RS_CONFS = @()
foreach ($r in @(ihwt-rs-list $DH)) {
    if ($r.Type -eq "standalone") {
        foreach ($f in @(@(_glob $r.Dir "*.conf") + @(_glob $r.Dir "*.xml") + @(_glob $r.Dir "*.properties"))) { [void](_store $f reports_server) }
        _rs_line $r.Name standalone $r.Conf $r.NetConf; $RS_CONFS += $r.Conf
    } else {
        $INPROC_DIRS += $r.Dir; $RS_CONFS += $r.Conf
        foreach ($f in @((Join-Path $r.Dir "rwserver.conf"), (Join-Path $r.Dir "rwservlet.properties"), (Join-Path $r.Dir "cgicmd.dat"), (Join-Path $r.Dir "CGICMD.DAT"), (Join-Path $r.Dir "rwnetwork.conf")) + @(_glob $r.Dir "*.xml")) { [void](_store $f reports_wls) }
        if ($r.Type -eq "in-process") { _rs_line $r.Name "in-process" $r.Conf $r.NetConf }
        $inp = $(if ((_text (Join-Path $r.Dir "rwservlet.properties")) -match '<inprocess>([^<]*)</inprocess>') { $Matches[1] } else { "-" })
        $RSV.Add(("# rwservlet {0}: server={1} inprocess={2}" -f (ihwt-fwd $r.Dir), $r.Name, $inp))
    }
}
[void](_store (ihwt-jp @($OH, "reports", "conf", "cgicmd.dat")) reports_fmw)
$TOOLS_DIRS = @(_dirs (ihwt-jp @($CFG, "components", "ReportsToolsComponent")) | Where-Object { (Split-Path -Leaf $_) -ne "mbeans" })
foreach ($d in $TOOLS_DIRS) {
    $adm = ihwt-jp @($d, "guicommon", "tk", "admin")
    foreach ($f in @(@(_glob $d "*.conf") + @(Join-Path $adm "uifont.ali") + @(_glob (Join-Path $adm "PPD") "*.ppd") + @(_glob (Join-Path $adm "AFM") "*"))) { [void](_store $f reports_tools) }
}
# Reports start script of the domain: reports.sh (Linux), reports.cmd / .bat (Windows)
$REP_SCRIPTS = @(foreach ($x in @("reports.sh", "reports.cmd", "reports.bat")) { $f = ihwt-jp @($DH, "reports", "bin", $x); if (Test-Path -LiteralPath $f -PathType Leaf) { $f } })
foreach ($f in $REP_SCRIPTS) { [void](_store $f reports_script) }

#==============================================================================
# 3. Domain, Oracle Net, web tier, Windows registry
#==============================================================================
say "Domain / Oracle Net / web tier ..."
$DOM_SCRIPTS = @(foreach ($x in @("setUserOverrides.sh", "setUserOverrides.cmd", "setDomainEnv.sh", "setDomainEnv.cmd")) { ihwt-jp @($DH, "bin", $x) })
foreach ($f in @($DOM_SCRIPTS + @((ihwt-jp @($DH, "nodemanager", "nodemanager.properties")), (ihwt-jp @($DH, "config", "config.xml")), (Join-Path $CFG "jps-config-jse.xml")))) { [void](_store $f domain) }
$REGENV = @(ihwt-registry-env)
$TNS = @($CFG, (ihwt-jp @($OH, "network", "admin")))
foreach ($ef in $ENV_FILES) { $t = _first (ihwt-cfgval $ef 'TNS_ADMIN'); if ($t) { $TNS += (_expand $t) } }
foreach ($c in @($REP_SCRIPTS + @($INPROC_DIRS | ForEach-Object { Join-Path $_ "rwserver.conf" }) + $RS_CONFS)) {
    if ((_text $c) -match 'TNS_ADMIN"?\s*(value="|=)([^";\s]+)') { $TNS += (_expand $Matches[2]) }
}
foreach ($r in @($REGENV | Where-Object { $_.Name -eq 'TNS_ADMIN' })) { $TNS += $r.Value }
$TNS_DIRS = @(); $seenT = @{}
foreach ($t in $TNS) { $k = (ihwt-fwd $t).TrimEnd('/'); if ($k -and -not $seenT.ContainsKey($k)) { $seenT[$k] = 1; $TNS_DIRS += $k } }
$TNS_DIRS = @($TNS_DIRS | Sort-Object)
foreach ($t in $TNS_DIRS) { foreach ($x in @("tnsnames.ora", "sqlnet.ora", "ldap.ora")) { [void](_store (Join-Path $t $x) oracle_net) } }
foreach ($d in @(_dirs (ihwt-jp @($CFG, "components", "OHS")) | Where-Object { (Split-Path -Leaf $_) -ne "instances" })) {
    foreach ($f in @((Join-Path $d "mod_wl_ohs.conf"), (Join-Path $d "httpd.conf"), (Join-Path $d "ssl.conf")) + @(_glob (Join-Path $d "moduleconf") "*.conf")) { [void](_store $f ohs) }
}
# JDBC system resources (RCU data sources: URL + schema user; passwords are {AES})
$JDBC = New-Object System.Collections.Generic.List[string]; $JDBC.Add("datasource;url;user")
foreach ($f in @(_glob (ihwt-jp @($DH, "config", "jdbc")) "*-jdbc.xml")) {
    [void](_store $f domain_jdbc)
    $t = _text $f
    $u = $(if ($t -match '<url>([^<]*)</url>') { $Matches[1] } else { "" })
    $usr = $(if (($t -replace "`r?`n", ' ') -match '<name>user</name>\s*<value>([^<]*)') { $Matches[1] } else { "" })
    $JDBC.Add(("{0};{1};{2}" -f ((Split-Path -Leaf $f) -replace '-jdbc\.xml$', ''), $u, $usr))
}
# web tier in front of WebLogic: IIS (+ WebLogic plug-in iisproxy.ini), Nginx
# (installed by hand on Windows), Apache (+ mod_wl), OHS - every configuration
# file incl. includes into raw/, the routing into ihw_import/web_tier.txt
$WT = New-Object System.Collections.Generic.List[string]; $WT.Add($IHWT_WT_HEAD)
$WTS = New-Object System.Collections.Generic.List[string]; $WTS.Add("type;conf;key;value;file")
$WT_FOUND = @(ihwt-webtier-find @($DH) $procs)
foreach ($e in $WT_FOUND) {
    $t = $e.Substring(0, $e.IndexOf(';')); $m = $e.Substring($e.IndexOf(';') + 1)
    $flat = @(ihwt-webtier-flatten $t $m)
    foreach ($l in $flat) {
        if ($l -like '#@@ FILE *') { [void](_store $l.Substring(9) "web_tier_$t") }
        elseif ($l -like '#@@ UNREADABLE *') { warn "web tier ($t): not readable as $([Environment]::UserName): $(ihwt-fwd $l.Substring(15)) $ND copy it by hand (administrator)" }
    }
    # conf / file columns with "/" like every path of the derived files
    foreach ($r in @(ihwt-webtier-routes $t $m $flat)) { $p = $r -split ';', 3; if ($p.Count -eq 3) { $WT.Add(("{0};{1};{2}" -f $p[0], (ihwt-fwd $p[1]), $p[2])) } }
    foreach ($r in @(ihwt-webtier-settings $t $m $flat)) { $p = $r -split ';'; $p[1] = ihwt-fwd $p[1]; $p[$p.Count - 1] = ihwt-fwd $p[$p.Count - 1]; $WTS.Add($p -join ';') }
    if ($t -eq "iis") {
        # iisproxy.ini of the WebLogic IIS plug-in: next to the iisproxy.dll /
        # iisforward.dll named in applicationHost.config, else the usual places
        $ini = @()
        foreach ($mm in [regex]::Matches((_text $m), '"([^"]*(iisproxy|iisforward)\.dll)"', 'IgnoreCase')) { $ini += (Join-Path (Split-Path -Parent ([Environment]::ExpandEnvironmentVariables($mm.Groups[1].Value))) "iisproxy.ini") }
        if ($IHWT_ON_WINDOWS) { $ini += @(Get-ChildItem -Path "$env:SystemDrive\inetpub", "C:\Oracle", "D:\Oracle" -Filter iisproxy.ini -File -Recurse -Depth 4 -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
        foreach ($f in $ini) { [void](_store $f web_tier_iis) }
    }
}
if (-not $WT_FOUND.Count) { warn "web tier: no IIS / Nginx / Apache / OHS configuration found (other host? -> export it there too)" }
# certificates: only the signers of the customer jars (part of the jars); the
# certificates of the HTTPS listeners are collected by collect_fmw_env.ps1
$CERTS = @("source;subject;issuer;not_after") + @($JARCERTS | Sort-Object -Unique)

#==============================================================================
# 4. Fonts
#==============================================================================
say "Fonts ..."
$FDL = @(ihwt-jp @($DH, "reports", "fonts"))
$fre = $(if ($IHWT_ON_WINDOWS) { 'REPORTS_FONT_DIRECTORY\s*=\s*"?([^"\r\n]+)' } else { 'REPORTS_FONT_DIRECTORY\s*=\s*"?([^";\s]+)' })
foreach ($f in @($REP_SCRIPTS + $DOM_SCRIPTS + $ENV_FILES)) {
    foreach ($m in [regex]::Matches((_text $f), $fre)) { foreach ($p in ($m.Groups[1].Value.Trim() -split [regex]::Escape([string]$PSEP))) { if ($p) { $FDL += (_expand $p) } } }
}
foreach ($r in @($REGENV | Where-Object { $_.Name -eq 'REPORTS_FONT_DIRECTORY' })) { foreach ($p in ($r.Value -split ';')) { if ($p) { $FDL += $p } } }
$WINFONTS = ""
if ($IHWT_ON_WINDOWS -and $env:windir) { $WINFONTS = ihwt-fwd (Join-Path $env:windir "Fonts"); $FDL += $WINFONTS }
$FONT_DIRS = @(); $seenF = @{}
foreach ($d in $FDL) { $k = (ihwt-fwd $d).TrimEnd('/'); if ($k -and -not $seenF.ContainsKey($k)) { $seenF[$k] = 1; $FONT_DIRS += $k } }
$FONT_DIRS = @($FONT_DIRS | Sort-Object)
$FONTS = New-Object System.Collections.Generic.List[string]; $FONTS.Add("font;size;dir;class;replacement_14c;exported")
foreach ($fd in $FONT_DIRS) {
    if (-not (ihwt-isdir $fd)) { continue }
    $isWin = ($WINFONTS -and (ihwt-under $fd $WINFONTS))
    foreach ($ff in @(Get-ChildItem -LiteralPath $fd -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(ttf|ttc|otf)$' } | Sort-Object FullName)) {
        $fb = $ff.Name; $fc = ihwt-font-class $fb; $cls = $fc.Substring(0, $fc.IndexOf(';'))
        if ($cls -eq "free") { $FONTS.Add("$fb;$($ff.Length);$fd;$fc;no (OS package $ND 14b- deploys it)"); continue }
        if ($isWin) {
            # Windows font directory: the fonts of Windows itself belong to
            # TrustedInstaller - only those with a known name are listed (the
            # replacement matters), unknown Windows fonts are skipped; fonts an
            # administrator installed (barcode, corporate ...) are customer fonts
            $own = ""; try { $own = (Get-Acl -LiteralPath $ff.FullName -ErrorAction Stop).Owner } catch { }
            if ($own -match 'TrustedInstaller' -and $cls -ne "ms") { continue }
        }
        if ($cls -eq "ms" -and $IHWT_ON_WINDOWS) { $FONTS.Add("$fb;$($ff.Length);$fd;$fc;no (Microsoft font $ND Windows licence, listed only)"); continue }
        if (-not $NoFonts) {
            [void](_store $ff.FullName fonts "ihw_import/custom_fonts_dir/$fb")
            $FONTS.Add("$fb;$($ff.Length);$fd;$fc;ihw_import/custom_fonts_dir/")
        } else { $FONTS.Add("$fb;$($ff.Length);$fd;$fc;no (-NoFonts)") }
    }
}

#==============================================================================
# 5. ihw_import - customer settings against Oracle's templates
#==============================================================================
say "Comparing with Oracle's templates ..."
$TPL = ihwt-jp @($OH, "forms", "templates", "config")
# _diff BASE CUST - lines of CUST not in BASE, sorted (comm -13 of sorted lists)
function _diff {
    param($Base, $Cust)
    $b = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($x in @($Base)) { [void]$b.Add($x) }
    $l = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($Cust)) { if (-not $b.Contains($x)) { $l.Add($x) } }
    $a = $l.ToArray(); [Array]::Sort($a, [StringComparer]::InvariantCultureIgnoreCase); return $a   # close to sort(1) of bash
}
$O_FWD = New-Object System.Collections.Generic.List[string]; $O_FWS = New-Object System.Collections.Generic.List[string]
foreach ($fw in $FORMS_CFGS) {
    $d = @(_diff (ihwt-sections (Join-Path $TPL "formsweb.cfg")) (ihwt-sections $fw))
    $O_FWD.Add("# $(ihwt-fwd $fw) $ND [default] keys that differ from / are missing in Oracle's $(ihwt-fwd (Join-Path $TPL 'formsweb.cfg'))")
    $O_FWD.Add("# target: 09-Install/forms_templates/formsweb.cfg.template ([default] overrides)")
    $O_FWS.Add("# $(ihwt-fwd $fw) $ND customer sections and changed keys of other sections")
    $O_FWS.Add("# (14- has no mechanism for own sections yet $ND later import step)")
    $last = $null
    foreach ($x in $d) {
        $s, $k, $v = $x -split "`t", 3
        if ($s -eq "default") { $O_FWD.Add("$k=$v"); continue }
        if ($s -ne $last) { $O_FWS.Add(""); $O_FWS.Add("[$s]"); $last = $s }
        $O_FWS.Add("$k=$v")
    }
}
# env files: keys differing from Oracle's default.env
$O_ENV = New-Object System.Collections.Generic.List[string]
$libKeys = @("ORACLE_HOME", "PATH", "LD_LIBRARY_PATH", "LD_PRELOAD", "FORMS_INSTANCE", "COMPONENT_CONFIG_PATH", "TNS_ADMIN", "TMPDIR")
if ($IHWT_ON_WINDOWS) { $libKeys += @("TEMP", "TMP") }
function _oracle_entry { param([string] $e) $f = ihwt-fwd $e; return ($f.StartsWith($OHF, [StringComparison]::OrdinalIgnoreCase) -or $f.StartsWith($DHF, [StringComparison]::OrdinalIgnoreCase)) }
foreach ($ef in $ENV_FILES) {
    $O_ENV.Add("# $(ihwt-fwd $ef) $ND keys that differ from / are missing in Oracle's default.env")
    $O_ENV.Add("# target: forms_templates/default.env.template (FORMS_PATH, NLS_*, CLASSPATH extras, own variables)")
    # keys 14- sets itself from environment.conf / Oracle's paths: only as
    # comment; for CLASSPATH / FORMS_PATH only the customer entries
    foreach ($x in (_diff (ihwt-keys (Join-Path $TPL "default.env")) (ihwt-keys $ef))) {
        $k, $v = $x -split "`t", 2
        if ($k -ceq "CLASSPATH" -or $k -ceq "FORMS_PATH") {
            $cu = @($v -split [regex]::Escape([string]$PSEP) | Where-Object { $_ -and -not (_oracle_entry $_) -and $_ -notmatch '^[$%]' })
            $O_ENV.Add("# $k (full): $v")
            if ($cu.Count) { $O_ENV.Add("${k}_CUSTOMER=$($cu -join $PSEP)") }
        } elseif ($libKeys -ccontains $k) { $O_ENV.Add("# (set by 14- / environment.conf) $k=$v") }
        else { $O_ENV.Add("$k=$v") }
    }
    $O_ENV.Add("")
}
# webutil.cfg: differing keys (install.syslib stays Oracle's)
$O_WU = New-Object System.Collections.Generic.List[string]
$WEBUTILS = @(foreach ($i in @(_dirs (ihwt-jp @($CFG, "components", "FORMS", "instances")))) { $f = ihwt-jp @($i, "server", "webutil.cfg"); if (Test-Path -LiteralPath $f -PathType Leaf) { $f } })
foreach ($wc in $WEBUTILS) {
    $O_WU.Add("# $(ihwt-fwd $wc) $ND keys that differ from Oracle's webutil.cfg (install.syslib.* skipped)")
    $O_WU.Add("# target: forms_templates/webutil.cfg.template")
    foreach ($x in (_diff @(ihwt-keys (Join-Path $TPL "webutil.cfg") | Where-Object { $_ -notmatch '^install\.syslib' }) @(ihwt-keys $wc | Where-Object { $_ -notmatch '^install\.syslib' }))) { $O_WU.Add(($x -replace "`t", '=')) }
    $O_WU.Add("")
}
# cgicmd.dat: every active key (not the IHateWeblogic block, not Oracle's samples)
$O_CG = New-Object System.Collections.Generic.List[string]
foreach ($cg in @(@($INPROC_DIRS | ForEach-Object { Join-Path $_ "cgicmd.dat" }) + @(ihwt-jp @($OH, "reports", "conf", "cgicmd.dat")))) {
    if (-not (Test-Path -LiteralPath $cg -PathType Leaf)) { continue }
    $O_CG.Add("# $(ihwt-fwd $cg) $ND active keys (target: after the END marker of 14b-'s block)")
    $inb = $false
    foreach ($l in [IO.File]::ReadAllLines($cg, $LATIN1)) {
        if ($l -match 'IHateWeblogic BEGIN') { $inb = $true }
        if ($l -match 'IHateWeblogic END') { $inb = $false; continue }
        if ($inb -or $l -match '^\s*[#;]' -or $l -match '^\s*$') { continue }
        $k = $l -replace '\s*:.*$', ''
        if ($k -cmatch '^(orqa|report_defaultid|report_secure|run|breakbparam|runp|express)$') { continue }
        $O_CG.Add($l)
    }
    $O_CG.Add("")
}
# uifont.ali: lines not in Oracle's template, with their section
$O_UF = New-Object System.Collections.Generic.List[string]
$ubase = _first @(foreach ($d in @((ihwt-jp @($OH, "frcommon", "templates")), (ihwt-jp @($OH, "guicommon", "tk", "admin")))) {
    if (ihwt-isdir $d) { Get-ChildItem -LiteralPath $d -Filter uifont.ali -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName } } })
$bl = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
if ($ubase) { foreach ($l in [IO.File]::ReadAllLines($ubase, $LATIN1)) { if ($l -notmatch '^\s*#' -and $l -notmatch '^\s*$') { [void]$bl.Add($l) } } }
foreach ($d in $TOOLS_DIRS) {
    $ua = ihwt-jp @($d, "guicommon", "tk", "admin", "uifont.ali")
    if (-not (Test-Path -LiteralPath $ua -PathType Leaf)) { continue }
    $O_UF.Add("# $(ihwt-fwd $ua) $ND lines not in Oracle's $(if ($ubase) { ihwt-fwd $ubase } else { 'template (not found)' }) (target: 04-ReportsFonts/uifont_ali_template.ali)")
    $sec = ""; $last = $null
    foreach ($l in [IO.File]::ReadAllLines($ua, $LATIN1)) {
        if ($l -match '^\s*\[') { $sec = $l; continue }
        if ($l -match '^\s*#' -or $l -match '^\s*$') { continue }
        if (-not $bl.Contains($l)) { if ($sec -ne $last) { $O_UF.Add($sec); $last = $sec }; $O_UF.Add($l) }
    }
    $O_UF.Add("")
}

#==============================================================================
# 6. Sources - paths + dependencies, inventory only (no module content)
#==============================================================================
say "Sources inventory ..."
$SRCDIR = @{}
$DEP = New-Object System.Collections.Generic.List[string]
function _adddir {
    param([string] $p, [string] $ref)
    $p = (ihwt-fwd (_expand $p.Trim())); if ($p.Length -gt 1) { $p = $p.TrimEnd('/') }
    if ($p) { if ($SRCDIR.ContainsKey($p)) { $SRCDIR[$p] += "$ref " } else { $SRCDIR[$p] = "$ref " } }
}
$PSX = [regex]::Escape([string]$PSEP)
foreach ($ef in $ENV_FILES) {
    $b = Split-Path -Leaf $ef
    foreach ($v in (ihwt-cfgval $ef 'FORMS_PATH')) { foreach ($p in ($v -split $PSX)) { if ($p) { _adddir $p "FORMS_PATH($b)" } } }
    foreach ($p in ((_first (ihwt-cfgval $ef 'REPORTS_PATH')) -split $PSX)) { if ($p) { _adddir $p "REPORTS_PATH($b)" } }
}
foreach ($f in $REP_SCRIPTS) {
    $re = $(if ($f -like '*.sh') { '(?m)^REPORTS_PATH=([^;\r\n]+)' } else { '(?im)^\s*set\s+"?REPORTS_PATH=([^"\r\n]+)' })
    $v = _last @([regex]::Matches((_text $f), $re) | ForEach-Object { $_.Groups[1].Value })
    $sp = $(if ($f -like '*.sh') { ':' } else { ';' })
    foreach ($p in ($v -split $sp)) { if ($p -and $p -notmatch 'REPORTS_PATH') { _adddir $p "REPORTS_PATH($(Split-Path -Leaf $f))" } }
}
foreach ($c in @(@($INPROC_DIRS | ForEach-Object { Join-Path $_ "rwserver.conf" }) + $RS_CONFS | Sort-Object -Unique)) {
    $t = _text $c; if (-not $t) { continue }
    $cn = Split-Path -Leaf (Split-Path -Parent $c)
    $rsp = $(if ($IHWT_ON_WINDOWS) { ';' } else { '[:;]' })
    if ($t -match 'name="REPORTS_PATH"[^>]*value="([^"]*)"') { foreach ($p in ($Matches[1] -split $rsp)) { if ($p) { _adddir $p "REPORTS_PATH($cn)" } } }
    if ($t -match '<read>([^<]*)</read>') { foreach ($p in ($Matches[1] -split ';')) { if ($p) { _adddir $p "folderAccess.read" } } }
    if ($t -match '<write>([^<]*)</write>') { foreach ($p in ($Matches[1] -split ';')) { if ($p) { _adddir $p "folderAccess.write" } } }
}
foreach ($wc in $WEBUTILS) {
    foreach ($x in (ihwt-keys $wc)) { $k, $v = $x -split "`t", 2; if ($k -match '^transfer\.appsrv\.(read|write)\.|^transfer\.appsrv\.workAreaRoot$') { _adddir $v "webutil:$k" } }
}
foreach ($fw in $FORMS_CFGS) {
    $v = _first (ihwt-cfgval (ihwt-jp @((Split-Path -Parent $fw), "oracle", "forms", "registry", "Registry.dat")) 'default\.icons\.iconpath')
    $abs = $(if ($IHWT_ON_WINDOWS) { $v -match '^([A-Za-z]:[\\/]|\\\\|//)' } else { $v -like '/*' })
    if ($abs) { _adddir $v "Registry.dat iconpath" } elseif ($v) { $DEP.Add("Registry.dat iconpath (URL / relative): $v") }
}
# Windows: FORMS_PATH / REPORTS_PATH of the Oracle registry keys (Windows
# Reports reads REPORTS_PATH from the registry when no env file sets it)
foreach ($r in @($REGENV | Where-Object { $_.Name -in @('FORMS_PATH', 'REPORTS_PATH') })) {
    foreach ($p in ($r.Value -split ';')) { if ($p) { _adddir $p "$($r.Name)(registry:$(Split-Path -Leaf $r.Source))" } }
}

$EXTS = @("fmb", "fmx", "pll", "plx", "mmb", "mmx", "olb", "rdf", "rep", "jsp", "xml", "gif", "jpg", "png", "ico")
$INV = New-Object System.Collections.Generic.List[string]; $INV.Add("path;configured_in;exists;owner:mode;$($EXTS -join ';');newest")
$FILES = New-Object System.Collections.Generic.List[string]; $FILES.Add("# per source directory: file;size;mtime $ND NO content is exported")
$DEP.Add("# HEURISTIC $ND dependencies read with `"strings`" from compiled modules (.fmx/.mmx/.plx)")
$DEP.Add("# and from text reports (.rep/.jsp/.xml); .fmb/.rdf are binary and not read."); $DEP.Add("")
# UNC paths: reachable? (Test-Path can hang for a minute on a dead server -
# checked in a job with a timeout, once per server)
$UNCOK = @{}
function _reachable {
    param([string] $p)
    if ($p -notmatch '^//([^/]+)/') { return (ihwt-isdir $p) }
    $srv = $Matches[1]
    if (-not $UNCOK.ContainsKey($srv)) {
        $j = Start-Job -ScriptBlock { param($x) Test-Path -LiteralPath $x } -ArgumentList ($p -replace '/', '\')
        $UNCOK[$srv] = $(if (Wait-Job $j -Timeout 15) { [bool](Receive-Job $j) } else { $false }); Remove-Job $j -Force
        if (-not $UNCOK[$srv]) { return $false }
    }
    return ($UNCOK[$srv] -and (ihwt-isdir $p))
}
function _owner_mode {
    param([string] $p)
    if (-not $IHWT_ON_WINDOWS) { $o = (& stat -c '%U:%a' $p 2>$null); return "$o" }
    try {
        $acl = Get-Acl -LiteralPath $p -ErrorAction Stop
        # write right for every user (Everyone / Users / Authenticated Users / Domain Users)
        $w = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and "$($_.IdentityReference)" -match '(?i)(^Everyone$|\\Users$|Authenticated Users$|\\Domain Users$|^Jeder$|\\Benutzer$|Authentifizierte Benutzer$)' -and "$($_.FileSystemRights)" -match 'FullControl|Modify|Write' })
        return ("{0}:{1}" -f ($acl.Owner -replace '[;:]', '_'), $(if ($w.Count) { "users-write" } else { "restricted" }))
    } catch { return "-" }
}
$LIBS = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal); [void]$LIBS.Add("WEBUTIL")
$SRC_SORTED = @($SRCDIR.Keys | Sort-Object)
$REACH = @{}
foreach ($p in $SRC_SORTED) {
    $REACH[$p] = _reachable $p
    if ($REACH[$p]) { foreach ($f in @(Get-ChildItem -LiteralPath $p -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(plx|pll|mmx)$' })) { [void]$LIBS.Add(([IO.Path]::GetFileNameWithoutExtension($f.Name)).ToUpper()) } }
}
foreach ($p in $SRC_SORTED) {
    if (-not $REACH[$p]) {
        $ex = $(if ($p -match '^//' -and -not (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) { "no (UNC, not reachable)" } else { "no" })
        $INV.Add(("{0};{1};{2};-;{3}-" -f $p, $SRCDIR[$p], $ex, ("-;" * $EXTS.Count))); continue
    }
    $all = @(Get-ChildItem -LiteralPath $p -File -Force -ErrorAction SilentlyContinue)
    $cnts = ($EXTS | ForEach-Object { $e = $_; @($all | Where-Object { $_.Extension -ieq ".$e" }).Count }) -join ';'
    $newest = $(if ($all.Count) { ($all | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime.ToString('yyyy-MM-dd') } else { "-" })
    $INV.Add(("{0};{1};yes;{2};{3};{4}" -f $p, $SRCDIR[$p], (_owner_mode $p), $cnts, $newest))
    $FILES.Add(""); $FILES.Add("## $p")
    $mods = @($all | Where-Object { $_.Name -match '(?i)\.(fm.|pl.|mm.|olb|rdf|rep|jsp|xml)$' } | ForEach-Object { "{0};{1};{2}" -f $_.Name, $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') })
    $ma = [string[]]$mods; [Array]::Sort($ma, [StringComparer]::Ordinal); foreach ($x in $ma) { $FILES.Add($x) }
    foreach ($m in @($all | Where-Object { $_.Extension -match '^\.(fmx|mmx|plx)$' } | Sort-Object FullName)) {
        $s3 = (ihwt-strings $m.FullName 3) -join "`n"
        $tok = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($t in [regex]::Matches($s3.ToUpper(), '[A-Z0-9_]+')) { [void]$tok.Add($t.Value) }
        $used = @($LIBS | Where-Object { if ($_ -match '^[A-Z0-9_]+$') { $tok.Contains($_) } else { $s3.ToUpper().Contains($_) } } | Sort-Object)
        $refs = @([regex]::Matches(((ihwt-strings $m.FullName 4) -join "`n"), '(?i)[A-Za-z0-9_$#-]+\.(plx|pll|mmx|mmb|olb|fmx)') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        if ($used.Count -or $refs.Count) {
            $DEP.Add(("{0}: libraries/menus={1} explicit={2}" -f (ihwt-fwd $m.FullName), $(if ($used.Count) { $used -join ',' } else { "-" }), $(if ($refs.Count) { $refs -join ',' } else { "-" })))
        }
    }
    foreach ($r in @($all | Where-Object { $_.Extension -match '^\.(rep|jsp)$' })) {
        foreach ($ref in @([regex]::Matches((_text $r.FullName), '(?i)[^"'' <>=\r\n]+\.(gif|jpe?g|png|bmp|xsl|css|js)') | ForEach-Object { $_.Value } | Sort-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $ref -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath (Join-Path $p $ref) -ErrorAction SilentlyContinue)) {
                $DEP.Add("$(ihwt-fwd $r.FullName): referenced file not found: $ref")
            }
        }
    }
}
# libraries / menus referenced explicitly but not present in any source directory
$DEP.Add(""); $DEP.Add("# explicit references without a file in the source directories:")
$expl = @($DEP | ForEach-Object { if ($_ -match 'explicit=(\S+)') { $Matches[1] -split ',' } } | Where-Object { $_ -and $_ -ne '-' } | Sort-Object -Unique)
foreach ($x in $expl) { if (-not $LIBS.Contains(([IO.Path]::GetFileNameWithoutExtension($x)).ToUpper())) { $DEP.Add("  $x") } }
# TNS aliases used (userid=x/y@ALIAS) vs tnsnames.ora
$DEP.Add(""); $DEP.Add("# TNS aliases used in env files / cgicmd.dat / reports config:")
$tnsText = (@($TNS_DIRS | ForEach-Object { _text (Join-Path $_ "tnsnames.ora") }) -join "`n")
$useText = (@($ENV_FILES | ForEach-Object { _text $_ }) + @($O_CG | Where-Object { $_ -notmatch '^#' })) -join "`n"
foreach ($a in @([regex]::Matches($useText, '@([A-Za-z0-9_.]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) {
    if ($tnsText -match "(?im)^\s*$([regex]::Escape($a))\s*=") { $DEP.Add("  $a (in tnsnames.ora)") } else { $DEP.Add("  $a (NOT in a collected tnsnames.ora)") }
}

#==============================================================================
# 7. Windows: registry environment + path map
#==============================================================================
$REG_TXT = @(); $PMAP = @()
if ($REGENV.Count) {
    $envKeys = @{}; foreach ($ef in $ENV_FILES) { foreach ($x in (ihwt-keys $ef)) { $envKeys[($x -split "`t", 2)[0]] = 1 } }
    $REG_TXT = @("source;name;value;in_env_files") + @($REGENV | ForEach-Object { "{0};{1};{2};{3}" -f $_.Source, $_.Name, ($_.Value -replace ';', '|'), $(if ($envKeys.ContainsKey($_.Name)) { "yes" } else { "no" }) })
}
# Windows path -> proposal for the Linux path of the 14c host (below
# ORACLE_BASE; ORACLE_HOME / DOMAIN_HOME paths are placed by the library)
function _linux_path {
    param([string] $p)
    if (ihwt-under $p $OHF) { return '$ORACLE_HOME' + $p.Substring($OHF.Length) }
    if (ihwt-under $p $DHF) { return '$DOMAIN_HOME' + $p.Substring($DHF.Length) }
    if ($p -match '^//([^/]+)/(.*)$') { return "/mnt/$($Matches[1])/$($Matches[2] -replace ' ', '_')   # share: mount it (cifs / NFS)" }
    if ($p -match '^[A-Za-z]:/(.*)$') { $r = $Matches[1] -replace ' ', '_'; return '$ORACLE_BASE/' + $r + $(if ($Matches[1] -match ' ') { "   # blanks replaced" } else { "" }) }
    return $p
}
$pm = [ordered]@{}
foreach ($p in $SRC_SORTED) { $pm[$p] = $SRCDIR[$p].Trim() }
foreach ($p in $FONT_DIRS) { if ($p -ne $WINFONTS -and (ihwt-isdir $p) -and -not $pm.Contains($p)) { $pm[$p] = "fonts" } }
foreach ($p in $TNS_DIRS) { if (-not $pm.Contains($p)) { $pm[$p] = "TNS_ADMIN" } }
if (@($pm.Keys | Where-Object { $_ -match '^([A-Za-z]:/|//)' }).Count) {
    $PMAP = @("windows_path;used_in;linux_proposal") + @($pm.Keys | Where-Object { $_ -match '^([A-Za-z]:/|//)' } | ForEach-Object { "{0};{1};{2}" -f $_, $pm[$_], (_linux_path $_) })
}

#==============================================================================
# 8. environment.conf proposal
#==============================================================================
$rows = @($RSV | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^#' })
$row1 = $(if ($rows.Count) { $rows[0] -split ';' } else { @() })
$rc = $(if ($row1.Count -gt 3) { _text $row1[3] } else { "" })
function _eng { param([string] $a) if ($rc -match "$a=`"([0-9]+)`"") { return $Matches[1] }; return "" }
$fp1 = _first @(foreach ($ef in $ENV_FILES) { ihwt-cfgval $ef 'FORMS_PATH' })
$fp1 = ($fp1 -split $PSX)[0]
$PROP = New-Object System.Collections.Generic.List[string]
$PROP.Add("# Proposal for environment.conf of the 14c installation $ND review, nothing is applied")
$PROP.Add("# source host: $HOSTN, $(Get-Date -Format 'yyyy-MM-dd HH:mm')"); $PROP.Add("")
$PROP.Add("REPORTS_SERVER_NAMES=`"$(@($rows | ForEach-Object { ($_ -split ';')[0] }) -join ' ')`"")
$PROP.Add("REPORTS_PATH=`"$(@($SRC_SORTED | Where-Object { $SRCDIR[$_] -match 'REPORTS_PATH|folderAccess\.read' } | Sort-Object -Unique) -join $PSEP)`"")
# REPORTS_TMP: the <write> directory; many sibling directories (one per
# user) -> propose their parent instead of the first user's directory
$wd = @($SRC_SORTED | Where-Object { $SRCDIR[$_] -match 'folderAccess\.write' } | Sort-Object)
$wp = _first @($wd | Group-Object { $_ -replace '/[^/]*$', '' } | Where-Object { $_.Count -gt 5 } | Sort-Object Count -Descending | ForEach-Object { $_.Name })
if ($wp) { $PROP.Add("REPORTS_TMP=`"$wp`"   # $(@($wd | Where-Object { $_.StartsWith("$wp/") }).Count) write directories below it (one per user?) - choose one output directory") }
else { $PROP.Add("REPORTS_TMP=`"$(_first $wd)`"") }
$PROP.Add("REPORTS_ENGINE_INIT=`"$(_eng initEngine)`""); $PROP.Add("REPORTS_ENGINE_MIN=`"$(_eng minEngine)`""); $PROP.Add("REPORTS_ENGINE_MAX=`"$(_eng maxEngine)`""); $PROP.Add("REPORTS_ENGINE_LIFE=`"$(_eng engLife)`"")
$PROP.Add("REPORTS_MAX_CONNECT=`"$(_eng maxConnect)`""); $PROP.Add("REPORTS_MAX_QUEUE=`"$(_eng maxQueueSize)`"")
$PROP.Add("REPORTS_BROADCAST_PORT=`"$(if ($row1.Count -gt 9) { $row1[9] })`"   # 14c: choose a port unique in the subnet")
$PROP.Add("FORMS_CUSTOMER_DIR=`"$(if ($fp1) { ihwt-fwd (_expand $fp1) })`"")
$nls = _first @(foreach ($ef in $ENV_FILES) { ihwt-cfgval $ef 'NLS_LANG' })
if (-not $nls -and @($REGENV | Where-Object { $_.Name -eq 'NLS_LANG' }).Count) { $r = @($REGENV | Where-Object { $_.Name -eq 'NLS_LANG' })[0]; $PROP.Add("NLS_LANG=`"$($r.Value)`"   # from the registry ($($r.Source))") }
else { $PROP.Add("NLS_LANG=`"$nls`"") }
$PROP.Add("TNS_ADMIN_SOURCE=`"$(($TNS_DIRS | ForEach-Object { "$_ " }) -join '')`"   # old TNS_ADMIN directories; 14c uses one TNS_ADMIN")
foreach ($fw in $FORMS_CFGS) {
    $sl = @(ihwt-sections $fw)
    $PROP.Add("FORMS_MAX_RUNTIME_PROCESSES=`"$(@($sl | ForEach-Object { $s, $k, $v = $_ -split "`t", 3; if ($s -ceq 'default' -and $k -ceq 'maxRuntimeProcesses') { $v } }) -join "`n")`"")
    $ps = _first @($sl | ForEach-Object { $s, $k, $v = $_ -split "`t", 3; if ($k -ceq 'prestartRuntimes' -and $v.ToLower() -eq 'true') { $s } })
    if ($ps) { $PROP.Add("FORMS_PRESTART_SECTION=`"$ps`"") }
}
# ports / listen address of the servers (config.xml; AdminServer default 7001)
$cx = $null; try { [xml]$cx = [IO.File]::ReadAllText((ihwt-jp @($DH, "config", "config.xml"))) } catch { }
function _sp {
    param([string] $re)
    if (-not $cx) { return @("", "") }
    foreach ($s in @($cx.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'server' })) {
        $n = $s.SelectSingleNode('*[local-name()="name"]'); if (-not $n -or $n.InnerText -cnotmatch $re) { continue }
        $pt = $s.SelectSingleNode('*[local-name()="listen-port"]'); $la = $s.SelectSingleNode('*[local-name()="listen-address"]')
        return @($(if ($pt -and $pt.InnerText) { $pt.InnerText } else { "7001" }), $(if ($la) { $la.InnerText } else { "" }))
    }
    return @("", "")
}
$PROP.Add("WLS_ADMIN_PORT=`"$((_sp '^AdminServer$')[0])`""); $PROP.Add("WLS_FORMS_PORT=`"$((_sp 'FORMS')[0])`""); $PROP.Add("WLS_REPORTS_PORT=`"$((_sp 'REPORTS')[0])`"")
$PROP.Add("WLS_LISTEN_ADDRESS=`"$((_sp '^AdminServer$')[1])`"   # 14c default: 127.0.0.1 behind Nginx")
$PROP.Add("WLS_NODEMANAGER_PORT=`"$(_last (ihwt-cfgval (ihwt-jp @($DH, 'nodemanager', 'nodemanager.properties')) 'ListenPort'))`"")
# old public name: server name of the HTTPS route to /forms, else of any HTTPS
# route, else any server name; else the OHS ServerName
$wr = @($WT | Select-Object -Skip 1 | ForEach-Object { ,($_ -split ';') })
$cand = @($wr | Where-Object { $_.Count -gt 6 -and $_[4] -eq 'yes' -and $_[6] -match 'forms' } | ForEach-Object { $_[3] }) + @($wr | Where-Object { $_.Count -gt 4 -and $_[4] -eq 'yes' } | ForEach-Object { $_[3] }) + @($wr | Where-Object { $_.Count -gt 3 } | ForEach-Object { $_[3] })
$sn = _first @($cand | ForEach-Object { $_ -split ',' } | Where-Object { $_ -notmatch '^(_|localhost|\*.*|-)?$' })
if (-not $sn) { $sn = _first @(foreach ($h in @(_dirs (ihwt-jp @($CFG, "components", "OHS")) | ForEach-Object { Join-Path $_ "httpd.conf" })) { [regex]::Matches((_text $h), '(?m)^\s*ServerName\s+(\S+)') | ForEach-Object { $_.Groups[1].Value } }) }
$sn = ($sn -replace '^.*://', '') -replace ':.*$', ''
if (-not $sn) { try { $sn = [System.Net.Dns]::GetHostEntry([string]$HOSTN).HostName } catch { $sn = $HOSTN } }
$PROP.Add("WLS_SERVER_FQDN=`"$sn`"   # OLD public name - the 14c host may get a new name / DNS alias")
$PROP.Add("WEB_TIER_OLD=`"$(@($WT_FOUND | ForEach-Object { ($_ -split ';')[0] } | Sort-Object -Unique) -join ' ')`"   # web server(s) in front today - 14c: Nginx (04-root_nginx.sh)")
# RCU database of the domain (WLSSchemaDataSource: jdbc:oracle:thin:@//host:port/service
# or a descriptor - RCU writes (host=..)(port=..)(service_name=..) in lower case)
$ru = _first @($JDBC | Where-Object { $_ -like 'WLSSchemaDataSource;*' })
$url = ""; $usr = ""; if ($ru) { $x = $ru -split ';'; $url = $x[1]; $usr = $x[2] }
$dh_ = ""; $dp = ""; $ds = ""
if ($url -match '@//([^/:]*):?([0-9]*)/(.*)$') { $dh_ = $Matches[1]; $dp = $Matches[2]; $ds = $Matches[3] }
elseif ($url -match '(?i)HOST=([^)]*).*PORT=([0-9]*).*SERVICE_NAME=([^)]*)') { $dh_ = $Matches[1]; $dp = $Matches[2]; $ds = $Matches[3] }
$PROP.Add("DB_HOST=`"$dh_`"   # RCU database of the OLD domain - 14c needs a new RCU (14.1.2 schemas)")
$PROP.Add("DB_PORT=`"$dp`""); $PROP.Add("DB_SERVICE=`"$ds`"")
$PROP.Add("DB_SCHEMA_PREFIX=`"$(($usr -split '_')[0])`"   # old prefix - choose a new one for the 14c RCU")

#==============================================================================
# 9. write the derived files, report, packaging
#==============================================================================
$w = { param($rel, $lines) ihwt-write-file (Join-Path $STAGE $rel) @($lines) }
& $w "ihw_import/jars.txt" $JARS
& $w "ihw_import/reports_servers.txt" $RSV
& $w "ihw_import/jdbc.txt" $JDBC
& $w "ihw_import/web_tier.txt" $WT
& $w "ihw_import/web_tier_settings.txt" $WTS
& $w "ihw_import/certificates.txt" $CERTS
& $w "ihw_import/fonts.txt" $FONTS
if ($O_FWD.Count) { & $w "ihw_import/formsweb.cfg.default_overrides" $O_FWD }
if ($O_FWS.Count) { & $w "ihw_import/formsweb.cfg.sections" $O_FWS }
if ($O_ENV.Count) { & $w "ihw_import/default.env.customer_keys" $O_ENV }
if ($O_WU.Count)  { & $w "ihw_import/webutil.cfg.overrides" $O_WU }
if ($O_CG.Count)  { & $w "ihw_import/cgicmd.dat.customer_keys" $O_CG }
if ($O_UF.Count)  { & $w "ihw_import/uifont.ali.customer" $O_UF }
& $w "ihw_import/environment.conf.proposal" $PROP
if ($REG_TXT.Count) { & $w "ihw_import/registry_env.txt" $REG_TXT }
if ($PMAP.Count) { & $w "ihw_import/path_map.txt" $PMAP }
& $w "sources_inventory.csv" $INV
& $w "sources_files.txt" $FILES
& $w "sources_dependencies.txt" $DEP
& $w "secrets_locations.txt" $SECRETS
if (-not $SECRETS.Count) { [IO.File]::WriteAllText((Join-Path $STAGE "secrets_locations.txt"), "") }

$fontRows = @($FONTS | Select-Object -Skip 1 | ForEach-Object { ,($_ -split ';') })
$REP = New-Object System.Collections.Generic.List[string]
$REP.Add("Forms & Reports configuration export $ND $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$REP.Add("export_forms_reports_conf.ps1 $SCRIPT_VERSION (ihw_tools_lib $(ihwt-lib-version)) $ND $(if ($Masked) { 'passwords MASKED' } else { "passwords INCLUDED $ND archive encrypted" })"); $REP.Add("")
$REP.Add("!!! Contains customer data $ND NEVER commit to git, keep encrypted, delete after the import."); $REP.Add("")
foreach ($l in (ihwt-identity 24 $OHF $DHF)) { $REP.Add($l) }
$REP.Add(""); $REP.Add("== Forms ==")
if ($FORMS_CFGS.Count) { foreach ($f in $FORMS_CFGS) { $REP.Add("  $(ihwt-fwd $f)") } } else { $REP.Add("  none") }
$REP.Add("  env files: $(if ($ENV_FILES.Count) { @($ENV_FILES | ForEach-Object { ihwt-fwd $_ }) -join ' ' } else { 'none' })")
$REP.Add("  sections: $((@(foreach ($fw in $FORMS_CFGS) { [regex]::Matches((_text $fw), '(?m)^\[([^\]]+)\]') | ForEach-Object { $_.Groups[1].Value } }) | Sort-Object -Unique) -join ' ')")
$REP.Add(""); $REP.Add("== Reports servers (ihw_import/reports_servers.txt) =="); foreach ($l in $RSV) { $REP.Add("  $l") }
$REP.Add(""); $REP.Add("== Web tier (ihw_import/web_tier.txt, web_tier_settings.txt) ==")
if ($WT_FOUND.Count) { foreach ($e in $WT_FOUND) { $REP.Add("  $(ihwt-fwd $e)") } } else { $REP.Add("  none found") }
foreach ($g in @($WT | Select-Object -Skip 1 | Group-Object { ($_ -split ';')[0] })) { $REP.Add(("  {0}: {1} route(s)" -f $g.Name, $g.Count)) }
$REP.Add(""); $REP.Add("== Customer jars (ihw_import/jars.txt) $ND FSAL / JACOB / frm*.jar excluded =="); foreach ($l in $JARS) { $REP.Add("  $l") }
$REP.Add(""); $REP.Add("== Fonts (ihw_import/fonts.txt) ==")
$REP.Add(("  {0} font file(s): {1} customer, {2} Microsoft, {3} free (skipped $ND 14b- deploys them)" -f $fontRows.Count, @($fontRows | Where-Object { $_[3] -eq 'customer' }).Count, @($fontRows | Where-Object { $_[3] -eq 'ms' }).Count, @($fontRows | Where-Object { $_[3] -eq 'free' }).Count))
$REP.Add(""); $REP.Add("  Customer fonts (barcode, corporate ...) $ND must move to 14c, no replacement:")
foreach ($x in @($fontRows | Where-Object { $_[3] -eq 'customer' })) { $REP.Add(("    {0,-28} {1,10}  {2}" -f $x[0], $x[1], $x[2])) }
$REP.Add(""); $REP.Add("  Microsoft fonts $ND licensed with Windows / Office of THIS host: the Windows licence does")
$REP.Add("  NOT allow copying them to another server (Microsoft font FAQ). 14c uses the free")
$REP.Add("  replacement; the original only with extended rights (Monotype / foundry). `"similar`" =")
$REP.Add("  line breaks / field widths can shift; symbol fonts have no replacement.")
$REP.Add("  Background: 80-FMW-Architecture/reports_fonts_architecture.md")
foreach ($x in @($fontRows | Where-Object { $_[3] -eq 'ms' })) { $REP.Add(("    {0,-28} {1,10}  -> {2}" -f $x[0], $x[1], $x[4])) }
$REP.Add(""); $REP.Add("== Source directories (sources_inventory.csv) $ND inventory only, no module content =="); foreach ($l in $INV) { $REP.Add("  $l") }
$REP.Add(""); $REP.Add("== Secrets (secrets_locations.txt: file:line:keyword $ND values never listed) =="); $REP.Add("  $($SECRETS.Count) locations")
if ($IHWT_ON_WINDOWS) {
    $REP.Add(""); $REP.Add("== Windows (ihw_import/registry_env.txt, path_map.txt) ==")
    $REP.Add(("  {0} registry / machine environment value(s), {1} of them not in an env file" -f [math]::Max(0, $REG_TXT.Count - 1), @($REG_TXT | Select-Object -Skip 1 | Where-Object { $_ -like '*;no' }).Count))
    $REP.Add(("  {0} Windows path(s) with a proposal for the Linux path of the 14c host" -f [math]::Max(0, $PMAP.Count - 1)))
    $REP.Add("  The Windows paths stay in raw/ and in the proposals - the import maps them by hand (path_map.txt).")
}
$REP.Add(""); $REP.Add("== ihw_import/ $ND what goes where ==")
$REP.Add("  Import with 00-Setup/customer_conf_import.sh -i <this archive> (overlay environments/<env>.customer/,")
$REP.Add("  read by 13- / 14- / 14b-; process: 09-Install/docs/00-transfer_customer_settings.md)")
$REP.Add("  formsweb.cfg.default_overrides -> overlay forms/formsweb.default.cfg      (14-)")
$REP.Add("  formsweb.cfg.sections          -> overlay forms/formsweb.sections.cfg     (14-)")
$REP.Add("  default.env.customer_keys      -> overlay forms/env/<name>.env            (14-)")
$REP.Add("  webutil.cfg.overrides          -> overlay forms/webutil.cfg.overrides     (14-)")
$REP.Add("  forms_java/ + jars.txt         -> overlay forms/jars/ (deduplicated, signed by 14-)")
$REP.Add("  reports_servers.txt            -> REPORTS_SERVER_INSTANCES + overlay reports/<server>.env (13-)")
$REP.Add("  cgicmd.dat.customer_keys       -> overlay reports/cgicmd.dat.customer, without logins (14b-)")
$REP.Add("  uifont.ali.customer            -> overlay fonts/uifont.ali.customer       (14b-)")
$REP.Add("  custom_fonts_dir/              -> overlay fonts/ (customer fonts; Microsoft fonts only with licence $ND fonts.txt class)")
$REP.Add("  environment.conf.proposal      -> import block of environments/<env>.conf")
$REP.Add("  web_tier.txt                   -> 09-Install/nginx-wls.conf.template (04-root_nginx.sh): own paths by hand")
if ($IHWT_ON_WINDOWS) {
    $REP.Add("  registry_env.txt               -> env keys of the registry (FORMS_PATH, REPORTS_PATH, NLS_LANG ...) for overlay forms/env/ (14-)")
    $REP.Add("  path_map.txt                   -> Windows path -> Linux path: FORMS_PATH / REPORTS_PATH / environment.conf by hand")
}
$REP.Add(""); $REP.Add("== Not in this export (collect_fmw_env.ps1) ==")
$REP.Add("  load profile, certificates of the HTTPS listeners, patch level, Java, OS, memory")
if ($WARNINGS.Count) { $REP.Add(""); $REP.Add("== Warnings =="); foreach ($x in $WARNINGS) { $REP.Add("  $x") } }
$REP.Add(""); $REP.Add("== Files (manifest.csv) =="); $REP.Add("  $($MANIFEST.Count - 1) files")
& $w "00_report.txt" $REP
& $w "manifest.csv" $MANIFEST

# -Masked: the derived files (ihw_import/, reports_servers, dependencies ...)
# quote config lines too - mask every text file outside raw/ (already masked)
if ($Masked) {
    $rawDir = ihwt-fwd (Join-Path $STAGE "raw")
    foreach ($f in @(Get-ChildItem -LiteralPath $STAGE -File -Recurse -Force | Where-Object { -not (ihwt-under (ihwt-fwd $_.FullName) $rawDir) })) {
        if (ihwt-is-text $f.FullName) { [IO.File]::WriteAllText($f.FullName, (ihwt-mask ([IO.File]::ReadAllText($f.FullName, $LATIN1))), $LATIN1) }
    }
}

$arch = ihwt-pack $OutBase $NAME $PASS
$PASS = ""
if (-not $arch) { exit 2 }
if (-not $Keep) { Remove-Item -LiteralPath $STAGE -Recurse -Force }
$DONE = $true

Write-Host ""
say ("Archive : {0} ({1} KB)" -f (Join-Path $OutBase $arch), [math]::Round((Get-Item -LiteralPath (Join-Path $OutBase $arch)).Length / 1KB))
say "SHA-256 : $(Join-Path $OutBase "$arch.sha256")"
if ($arch -like '*.enc') { say "Decrypt : openssl enc -d $IHWT_ENC_OPTS -in $arch -out $($arch -replace '\.enc$', '')" }
if ($Keep) { say "Staging : $STAGE (kept $ND contains $(if ($Masked) { 'masked' } else { 'CLEAR-TEXT' }) data, delete it)" }
if ($WARNINGS.Count) { say "$($WARNINGS.Count) warning(s) $ND see 00_report.txt" }
say "Contains customer data $ND never commit it to git."
say "For the analysis also run collect_fmw_env.ps1 (state, load profile, certificates) on this host."
}
finally {
    # abort (Ctrl-C, error) before the end: remove the staging directory
    # (clear-text passwords in the default mode) and a partial archive
    if (-not $DONE) {
        $PASS = ""
        Remove-Item -LiteralPath (Join-Path $OutBase "$NAME.zip"), (Join-Path $OutBase "$NAME.zip.enc") -Force -ErrorAction SilentlyContinue
        if ($Keep) { Write-Host "`n  ABORTED - staging kept (-Keep): $STAGE - contains $(if ($Masked) { 'masked' } else { 'CLEAR-TEXT' }) data, delete it" -ForegroundColor Red }
        else { Remove-Item -LiteralPath $STAGE -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "`n  ABORTED - staging directory and partial archive removed" -ForegroundColor Red }
    }
}
exit 0
