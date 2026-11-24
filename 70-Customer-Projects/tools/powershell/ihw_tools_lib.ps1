#==============================================================================
# Script   : ihw_tools_lib.ps1
# Purpose  : Shared helpers of the standalone Windows customer tools in
#            70-Customer-Projects/tools/powershell (collect_fmw_env.ps1,
#            export_forms_reports_conf.ps1) - the PowerShell twin of
#            tools/bash/ihw_tools_lib.sh: masking, output helpers, git guard,
#            passphrase + openssl-compatible encryption, packing, web tier
#            (find / flatten / routes / settings), certificates, Nginx patch
#            facts, Reports server list, load profile, OS update state,
#            homes, ini parsing, font classes, registry environment.
#            Same output formats as the bash versions, so the analyses on our
#            side read Linux and Windows archives alike.
# Use      : . (Join-Path $PSScriptRoot "ihw_tools_lib.ps1")
#            The caller sets $IHWT_OUT (output directory) and $IHWT_SUM
#            (00_summary.txt) before it uses ihwt-append / ihwt-fact.
# Rules    : functions only - no output / exit at load time; prefix ihwt-;
#            Windows PowerShell 5.1 and PowerShell 7; Set-StrictMode 2 safe;
#            also runs on Linux (pwsh) for the test run of the tools.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
#==============================================================================

$IHWT_PS_LIB_VERSION = "2026-11-24.1"
$IHWT_ON_WINDOWS = ([Environment]::OSVersion.Platform -eq 'Win32NT')
$IHWT_ENC_OPTS = "-aes-256-cbc -pbkdf2 -iter 200000 -md sha256"
$IHWT_WT_HEAD = "type;conf;listen;server_name;tls;protocols;path;target;access;cert"
function ihwt-lib-version { return $IHWT_PS_LIB_VERSION }
# every file is written as UTF-8 WITHOUT BOM and with LF line ends (Windows
# PowerShell 5.1 writes a BOM with "-Encoding UTF8", Windows writes CRLF -
# both break the awk / sed of the analyses on our side)
$IHWT_UTF8 = New-Object System.Text.UTF8Encoding($false)
function ihwt-write-file  { param([string] $Path, $Lines) [IO.File]::WriteAllText($Path, ((@($Lines) -join "`n") -replace "`r`n", "`n") + "`n", $IHWT_UTF8) }
function ihwt-append-file { param([string] $Path, [string] $Text) [IO.File]::AppendAllText($Path, ($Text -replace "`r`n", "`n") + "`n", $IHWT_UTF8) }

#------------------------------------------------------------------------------
# Masking - the rules of ihwt_mask (bash)
#------------------------------------------------------------------------------
function ihwt-mask {
    param([string] $Text)
    if (-not $Text) { return $Text }
    $t = $Text
    # line by line like the sed of bash: no class may run over a line end
    $t = [regex]::Replace($t, '(<[^>/\r\n]*[Pp]ass[Ww]or[dD][^>\r\n]*>)[^<\r\n]*', '$1***MASKED***')
    $t = [regex]::Replace($t, '(<identifier[^>\r\n]*>)[^<\r\n]*', '$1***MASKED***')
    $t = [regex]::Replace($t, '(name="[^"\r\n]*([Pp]ass[Ww](or)?[dD]|pwd|PWD)[^"\r\n]*"[ \t]+value=")[^"\r\n]*', '$1***MASKED***')
    $t = [regex]::Replace($t, '\{AES(256)?\}[A-Za-z0-9+/=]+', '{AES}***MASKED***')
    $t = [regex]::Replace($t, '(?m)((^|[\s;&?])(userid|USERID|UserId|authid|AUTHID|password|PASSWORD|Password|passwd|pwd|PWD|dbpassword)[ \t]*=[ \t]*)[^\s;&]+', '$1***MASKED***')
    $t = [regex]::Replace($t, '(-D[A-Za-z0-9._]*[Pp]ass[Ww]ord[A-Za-z0-9._]*=)\S+', '$1***MASKED***')
    $t = [regex]::Replace($t, '([A-Za-z0-9_]+)/[^@\s/"]+@', '$1/***MASKED***@')
    return $t
}

#------------------------------------------------------------------------------
# Output helpers ($IHWT_OUT / $IHWT_SUM of the caller)
#------------------------------------------------------------------------------
function ihwt-append { param([string] $File, [string] $Text) ihwt-append-file (Join-Path $IHWT_OUT $File) $Text }
function ihwt-fact   { param([string] $Key, [string] $Value) ihwt-append-file $IHWT_SUM ("{0,-28} {1}" -f $Key, $Value) }
function ihwt-say    { param([string] $Text) Write-Host "  $Text" }
function ihwt-isdir  { param([string] $p) return ($p -and (Test-Path -LiteralPath $p -PathType Container)) }
function ihwt-prop   { param([string] $v) return ($v -replace '\\:', ':' -replace '\\\\', '\') }
function ihwt-jp     { param([string[]] $Parts) $p = $Parts[0]; for ($i = 1; $i -lt $Parts.Count; $i++) { $p = Join-Path $p $Parts[$i] }; return $p }

# ihwt-runps FILE TITLE { scriptblock } - PowerShell output, masked
function ihwt-runps {
    param([string] $File, [string] $Title, [scriptblock] $Block)
    $txt = ""; $rc = 0
    try { $txt = (& $Block 2>&1 | Out-String -Width 4096) }
    catch { $txt = "ERROR: $_"; $rc = 1 }
    ihwt-append $File ("### {0}`n### $ {1}`n{2}`n### rc={3}`n" -f $Title, (($Block.ToString().Trim() -split "`r?`n") -join ' '), (ihwt-mask $txt), $rc)
}
# ihwt-block FILE TITLE TEXT - a block in the collector format (### TITLE ...
# ### rc=0) for text built by the script (read by ihwt_block of the analyses)
function ihwt-block { param([string] $File, [string] $Title, [string] $Text) ihwt-append $File ("### {0}`n{1}`n### rc=0`n" -f $Title, (ihwt-mask $Text)) }

# ihwt-exec EXE ARGS... - run an external program (timeout), returns @{Out; Rc}.
# .bat / .cmd run through cmd.exe.
function ihwt-exec {
    param([string] $Exe, [string[]] $Arguments = @(), [hashtable] $EnvVars = @{}, [int] $TimeoutSec = 600)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $q = @($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
    if ($IHWT_ON_WINDOWS -and $Exe -match '\.(bat|cmd)$') {
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
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; return @{ Out = "TIMEOUT after $TimeoutSec s"; Rc = 124 } }
        return @{ Out = ($o.Result + $e.Result); Rc = $p.ExitCode }
    } catch { return @{ Out = "ERROR: $_"; Rc = 127 } }
}
# ihwt-run FILE TITLE EXE ARGS... - external program into a file, masked
function ihwt-run {
    param([string] $File, [string] $Title, [string] $Exe, [string[]] $Arguments = @(), [hashtable] $EnvVars = @{})
    $r = ihwt-exec $Exe $Arguments $EnvVars
    ihwt-append $File ("### {0}`n### $ {1} {2}`n{3}`n### rc={4}`n" -f $Title, $Exe, ($Arguments -join ' '), (ihwt-mask $r.Out), $r.Rc)
}
# ihwt-copy FILE SOURCE - masked copy of a file into an output file
function ihwt-copy {
    param([string] $File, [string] $Src)
    if (-not $Src -or -not (Test-Path -LiteralPath $Src -PathType Leaf)) { return }
    try {
        $fi = Get-Item -LiteralPath $Src -Force
        $txt = [IO.File]::ReadAllText($fi.FullName)
        ihwt-append $File ("### file: {0} ({1} bytes, {2})`n{3}`n" -f $fi.FullName, $fi.Length, $fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm"), (ihwt-mask $txt))
    } catch { ihwt-append $File "### not readable: $Src ($_)" }
}

# ihwt-procs - running processes: Win32_Process on Windows, ps for the test run
# on Linux (same properties used by the tools: ProcessId, ParentProcessId, Name,
# CommandLine, ExecutablePath, CreationDate, WorkingSetSize, PrivatePageCount)
function ihwt-procs {
    if ($IHWT_ON_WINDOWS) { return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) }
    return @(& ps -eo pid=,ppid=,rss=,lstart=,args= 2>$null | ForEach-Object {
        if ($_ -match '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\w{3} \w{3}\s+\d+ [\d:]+ \d{4})\s+(.*)$') {
            $exe = ""; try { $exe = "$((Get-Item -LiteralPath "/proc/$($Matches[1])/exe" -ErrorAction Stop).Target)" } catch { }
            $st = $null; try { $st = [datetime]::ParseExact(($Matches[4] -replace '\s+', ' '), 'ddd MMM d HH:mm:ss yyyy', [Globalization.CultureInfo]::InvariantCulture) } catch { }
            [pscustomobject]@{ ProcessId = [int]$Matches[1]; ParentProcessId = [int]$Matches[2]; Name = (($Matches[5] -split ' ')[0] | Split-Path -Leaf)
                               CommandLine = $Matches[5]; ExecutablePath = $exe; CreationDate = $st
                               WorkingSetSize = [long]$Matches[3] * 1024; PrivatePageCount = [long]0 }
        } })
}

#------------------------------------------------------------------------------
# Git guard - customer data never into a git work tree (unless ignored)
#------------------------------------------------------------------------------
function ihwt-git-guard {
    param([string] $Dir, [string] $Name)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $true }
    $top = (& git -C $Dir rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $top) { return $true }
    $full = [IO.Path]::GetFullPath((Join-Path $Dir $Name))
    & git -C $top check-ignore -q -- $full 2>$null
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Host "REFUSED: $Dir is inside the git work tree $top and not ignored -" -ForegroundColor Red
    Write-Host "         it would contain customer data. Use a path outside git or an ignored path." -ForegroundColor Red
    return $false
}

#------------------------------------------------------------------------------
# Passphrase + encryption - compatible with
#   openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256
# (header "Salted__" + 8 byte salt, PBKDF2-HMAC-SHA256 -> 32 byte key + 16 byte
# IV, PKCS#7). Decrypt on our side with the same openssl command as the bash
# archives. No openssl.exe needed on the customer host.
#------------------------------------------------------------------------------
# ihwt-read-passphrase WHAT - ask twice (hidden); returns the passphrase or ""
# when there is no interactive console
function ihwt-read-passphrase {
    param([string] $What = "archive")
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Write-Host "Encryption needs a passphrase from a console ($What)" -ForegroundColor Yellow; return ""
    }
    while ($true) {
        $a = Read-Host -AsSecureString "  Passphrase for the $What"
        $b = Read-Host -AsSecureString "  Repeat passphrase       "
        $pa = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
        $pb = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
        if ($pa -and $pa -ceq $pb) { $pb = ""; return $pa }
        Write-Host "  empty or not equal - again"
    }
}
# PBKDF2-HMAC-SHA256 - .NET 4.7.2+ / .NET Core have it built in; Windows Server
# 2016 with .NET 4.6.2 gets the manual loop (slower, same result)
function _ihwt-pbkdf2 {
    param([byte[]] $Pass, [byte[]] $Salt, [int] $Iter, [int] $Len)
    try {
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Pass, $Salt, $Iter, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $r = $kdf.GetBytes($Len); $kdf.Dispose(); return ,$r
    } catch {
        $h = New-Object System.Security.Cryptography.HMACSHA256(,$Pass)
        $out = New-Object byte[] $Len; $blocks = [math]::Ceiling($Len / 32); $pos = 0
        for ($i = 1; $i -le $blocks; $i++) {
            $ib = [BitConverter]::GetBytes([int]$i); [Array]::Reverse($ib)
            $u = $h.ComputeHash([byte[]]($Salt + $ib)); $t = [byte[]]$u.Clone()
            for ($j = 1; $j -lt $Iter; $j++) { $u = $h.ComputeHash($u); for ($k = 0; $k -lt 32; $k++) { $t[$k] = $t[$k] -bxor $u[$k] } }
            $n = [math]::Min(32, $Len - $pos); [Array]::Copy($t, 0, $out, $pos, $n); $pos += $n
        }
        $h.Dispose(); return ,$out
    }
}
function _ihwt-aes {
    param([byte[]] $Key, [byte[]] $Iv)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $Key; $aes.IV = $Iv
    return $aes
}
# ihwt-encrypt IN OUT PASS
function ihwt-encrypt {
    param([string] $In, [string] $Out, [string] $Pass)
    $salt = New-Object byte[] 8
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($salt); $rng.Dispose()
    $kiv = _ihwt-pbkdf2 ([Text.Encoding]::UTF8.GetBytes($Pass)) $salt 200000 48
    $aes = _ihwt-aes $kiv[0..31] $kiv[32..47]
    $fo = [IO.File]::Create($Out)
    try {
        $hdr = [Text.Encoding]::ASCII.GetBytes("Salted__"); $fo.Write($hdr, 0, 8); $fo.Write($salt, 0, 8)
        $cs = New-Object System.Security.Cryptography.CryptoStream($fo, $aes.CreateEncryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)
        $fi = [IO.File]::OpenRead($In); $fi.CopyTo($cs); $fi.Close(); $cs.FlushFinalBlock(); $cs.Close()
    } finally { $fo.Close(); $aes.Dispose() }
}
# ihwt-decrypt IN OUT PASS - $false on a wrong passphrase (OUT removed)
function ihwt-decrypt {
    param([string] $In, [string] $Out, [string] $Pass)
    $fi = [IO.File]::OpenRead($In)
    try {
        $hdr = New-Object byte[] 16; [void]$fi.Read($hdr, 0, 16)
        if ([Text.Encoding]::ASCII.GetString($hdr, 0, 8) -ne "Salted__") { return $false }
        $kiv = _ihwt-pbkdf2 ([Text.Encoding]::UTF8.GetBytes($Pass)) ([byte[]]$hdr[8..15]) 200000 48
        $aes = _ihwt-aes $kiv[0..31] $kiv[32..47]
        $cs = New-Object System.Security.Cryptography.CryptoStream($fi, $aes.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Read)
        $fo = [IO.File]::Create($Out)
        try { $cs.CopyTo($fo); $fo.Close(); $cs.Close(); return $true }
        catch { $fo.Close(); Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue; return $false }
    } finally { $fi.Close() }
}

# ihwt-pack BASE NAME PASS - pack BASE\NAME into NAME.zip, with PASS into
# NAME.zip.enc (the plain ZIP is removed), plus "<sha256>  <file>" in .sha256
# (sha256sum format). Returns the archive file name, "" on an error.
function ihwt-pack {
    param([string] $Base, [string] $Name, [string] $Pass = "")
    # own ZIP with "/" in the entry names and the directory NAME/ as top level
    # (like zip -r of the bash version) - Compress-Archive of Windows
    # PowerShell 5.1 writes "\", unzip on Linux then creates broken file names
    $zip = Join-Path $Base "$Name.zip"; $src = Join-Path $Base $Name
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        $za = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -Force)) {
                $rel = $f.FullName.Substring($src.Length).TrimStart('\', '/') -replace '\\', '/'
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $f.FullName, "$Name/$rel")
            }
        } finally { $za.Dispose() }
    } catch { Write-Host "packing failed: $_" -ForegroundColor Red; Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue; return "" }
    $a = "$Name.zip"
    if ($Pass) {
        try { ihwt-encrypt $zip "$zip.enc" $Pass }
        catch { Remove-Item -LiteralPath $zip, "$zip.enc" -Force -ErrorAction SilentlyContinue; Write-Host "encryption failed - unencrypted archive removed: $_" -ForegroundColor Red; return "" }
        Remove-Item -LiteralPath $zip -Force; $a = "$a.enc"
    }
    $h = (Get-FileHash -LiteralPath (Join-Path $Base $a) -Algorithm SHA256).Hash.ToLower()
    [IO.File]::WriteAllText((Join-Path $Base "$a.sha256"), "$h  $a`n")
    return $a
}

# ihwt-identity WIDTH OH DH - identification lines "KEY<pad>value" of a run
function ihwt-identity {
    param([int] $Width, [string] $OH, [string] $DH)
    $fmw = ""; if ($OH) { $m = Select-String -LiteralPath (ihwt-jp @($OH, "inventory", "registry.xml")) -Pattern 'version="1[0-9.]+"' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($m) { $fmw = $m.Matches[0].Value } }
    $java = ""
    if ($OH) { foreach ($j in @((ihwt-jp @($OH, "oracle_common", "jdk", "bin", "java.exe")), (ihwt-jp @($OH, "oracle_common", "jdk", "bin", "java")))) {
        if (Test-Path -LiteralPath $j -PathType Leaf) { $java = ((ihwt-exec $j @("-version") -TimeoutSec 60).Out -split "`n" | Select-Object -First 1).Trim(); break } } }
    $ram = ""
    if ($IHWT_ON_WINDOWS) { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue; if ($cs) { $ram = [math]::Round($cs.TotalPhysicalMemory / 1MB) } }
    elseif (Test-Path /proc/meminfo) { $m = Select-String -LiteralPath /proc/meminfo -Pattern '^MemTotal:\s+(\d+)' | Select-Object -First 1; if ($m) { $ram = [math]::Floor([long]$m.Matches[0].Groups[1].Value / 1024) } }
    $hn = [Environment]::MachineName; try { $hn = [System.Net.Dns]::GetHostEntry([string]$hn).HostName } catch { }
    $f = "{0,-$Width} {1}"
    return @(
        ($f -f "Host", $hn),
        ($f -f "ORACLE_HOME", $(if ($OH) { $OH } else { "(not found)" })),
        ($f -f "DOMAIN_HOME", $(if ($DH) { $DH } else { "(not found)" })),
        ($f -f "Platform", ("{0} {1}" -f $(if ($IHWT_ON_WINDOWS) { "Windows" } elseif ("$([Environment]::OSVersion.Platform)" -eq "Unix" -and (Test-Path -LiteralPath /proc/version)) { "Linux" } else { [Environment]::OSVersion.Platform }), $(if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "x86" }))),
        ($f -f "FMW version", $fmw),
        ($f -f "Java", $java),
        ($f -f "CPUs", [Environment]::ProcessorCount),
        ($f -f "RAM MB", $ram))
}

#------------------------------------------------------------------------------
# Web tier: Nginx (Windows: installed by hand), Apache httpd (+ mod_wl), OHS,
# IIS (+ WebLogic IIS plug-in). Same formats as the bash functions:
#   ihwt-webtier-find DH...           -> "type;main_conf" strings
#   ihwt-webtier-flatten TYPE MAIN    -> lines with all includes inlined (#@@ markers)
#   ihwt-webtier-routes TYPE MAIN L   -> routing rows ($IHWT_WT_HEAD)
#   ihwt-webtier-settings TYPE MAIN L -> "type;conf;key;value;file"
#------------------------------------------------------------------------------
# ihwt-nginx-installs [PROCS] - every Nginx of the host: running processes,
# Windows services (also through a wrapper: NSSM, WinSW, srvany), scheduled
# tasks, usual directories. Objects: Exe, Conf, Prefix, StartedBy, Pid, Started
function ihwt-nginx-installs {
    param($Procs = $null)
    if ($null -eq $Procs) { $Procs = ihwt-procs }
    $found = [ordered]@{}
    $add = {
        param([string] $exe, [string] $conf, [string] $prefix, [string] $by, $procId, $started)
        if (-not $exe -and -not $conf) { return }
        if ($exe) { try { $exe = [IO.Path]::GetFullPath($exe) } catch { } }
        $key = if ($exe) { $exe.ToLower() } else { $conf.ToLower() }
        if ($found.Contains($key)) {
            $o = $found[$key]
            if ($by -and $o.StartedBy -notmatch [regex]::Escape($by)) { $o.StartedBy = (@($o.StartedBy, $by) | Where-Object { $_ }) -join ', ' }
            if ($procId -and -not $o.Pid) { $o.Pid = $procId; $o.Started = $started }
            if ($conf -and -not $o.Conf) { $o.Conf = $conf }
            return
        }
        $found[$key] = [pscustomobject]@{ Exe = $exe; Conf = $conf; Prefix = $prefix; StartedBy = $by; Pid = $procId; Started = $started }
    }
    $confOf = {
        param([string] $exe, [string] $cmd)
        $prefix = ""; $conf = ""
        if ($cmd -match '\s-p\s+"?([^"]+?)"?(\s+-|\s*$)') { $prefix = $Matches[1] }
        if ($cmd -match '\s-c\s+"?([^"]+?)"?(\s+-|\s*$)') { $conf = $Matches[1] }
        # no -c: the compiled-in --conf-path (nginx -V), relative to the prefix
        # (Windows builds: conf/nginx.conf below the directory of nginx.exe)
        if (-not $conf -and $exe -and (Test-Path -LiteralPath $exe -PathType Leaf)) {
            $v = (ihwt-exec $exe @("-V") -TimeoutSec 30).Out
            if ($v -match '--conf-path=(\S+)') { $conf = $Matches[1] }
            if (-not $prefix -and $v -match '--prefix=(\S+)' -and [IO.Path]::IsPathRooted($Matches[1])) { $prefix = $Matches[1] }
        }
        if (-not $prefix -and $exe) { $prefix = Split-Path -Parent $exe }
        if ($conf -and -not [IO.Path]::IsPathRooted($conf) -and $prefix) { $conf = Join-Path $prefix $conf }
        if (-not $conf -and $prefix) { $conf = ihwt-jp @($prefix, "conf", "nginx.conf") }
        return @($conf, $prefix)
    }
    # running: Windows nginx.exe (master = the one whose parent is no nginx);
    # Linux test run: "nginx: master process <bin> [-c conf]"
    $npids = @($Procs | Where-Object { $_.Name -match '^nginx(\.exe)?$' -or "$($_.CommandLine)" -like 'nginx: master process*' } | ForEach-Object { $_.ProcessId })
    foreach ($p in @($Procs | Where-Object { $_.Name -match '^nginx(\.exe)?$' -or "$($_.CommandLine)" -like 'nginx: master process*' })) {
        $cmd = "$($p.CommandLine)"
        if ($cmd -like 'nginx: worker*' -or $cmd -like 'nginx: cache*') { continue }
        if ($IHWT_ON_WINDOWS -and ($npids -contains $p.ParentProcessId)) { continue }
        $exe = "$($p.ExecutablePath)"
        if (-not $exe -and $cmd -match '^nginx: master process (\S+)') { $exe = $Matches[1] }
        $c = & $confOf $exe $cmd
        & $add $exe $c[0] $c[1] "" $p.ProcessId $p.CreationDate
    }
    if ($IHWT_ON_WINDOWS) {
        foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
            $pn = "$($s.PathName)"; $exe = ""; $cmd = ""; $by = ""
            $par = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)\Parameters"
            if ($pn -match '(?i)nssm(\.exe)?') {
                $app = (Get-ItemProperty -LiteralPath $par -Name Application -ErrorAction SilentlyContinue).Application
                if ("$app" -notmatch '(?i)nginx') { continue }
                $exe = $app; $cmd = "$app " + (Get-ItemProperty -LiteralPath $par -Name AppParameters -ErrorAction SilentlyContinue).AppParameters
                $dir = (Get-ItemProperty -LiteralPath $par -Name AppDirectory -ErrorAction SilentlyContinue).AppDirectory
                if ($dir -and $cmd -notmatch '\s-p\s') { $cmd += " -p `"$dir`"" }
                $by = "service $($s.Name) (NSSM, $($s.StartMode), $($s.StartName))"
            } elseif ($pn -match '(?i)nginx') {
                $w = ($pn -replace '^"([^"]+)".*$', '$1') -replace '^(\S+).*$', '$1'
                $xml = [IO.Path]::ChangeExtension($w, ".xml")
                if ($w -notmatch '(?i)nginx\.exe$' -and (Test-Path -LiteralPath $xml)) {
                    # WinSW: <executable> / <arguments> / <workingdirectory> next to the wrapper
                    $x = Get-Content -LiteralPath $xml -Raw
                    $exe = if ($x -match '<executable>\s*([^<]+?)\s*</executable>') { $Matches[1] } else { "" }
                    if ($exe -and -not [IO.Path]::IsPathRooted($exe)) { $exe = Join-Path (Split-Path -Parent $w) $exe }
                    $cmd = "$exe " + $(if ($x -match '<arguments>\s*([^<]+?)\s*</arguments>') { $Matches[1] } else { "" })
                    if ($x -match '<workingdirectory>\s*([^<]+?)\s*</workingdirectory>' -and $cmd -notmatch '\s-p\s') { $cmd += " -p `"$($Matches[1])`"" }
                    $by = "service $($s.Name) (WinSW, $($s.StartMode), $($s.StartName))"
                } else {
                    $exe = $w; $cmd = $pn
                    $by = "service $($s.Name) ($(if ($w -match '(?i)srvany') { 'srvany, ' })$($s.StartMode), $($s.StartName))"
                    if ($w -match '(?i)srvany') {
                        $exe = (Get-ItemProperty -LiteralPath $par -Name Application -ErrorAction SilentlyContinue).Application; $cmd = "$exe"
                    }
                }
            } else { continue }
            if ($exe -and $exe -notmatch '(?i)nginx') { continue }
            $c = & $confOf $exe $cmd
            & $add $exe $c[0] $c[1] $by $null $null
        }
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { "$($_.Actions.Execute) $($_.Actions.Arguments)" -match '(?i)nginx' })) {
            foreach ($ac in @($t.Actions)) {
                $exe = "$($ac.Execute)" -replace '"', ''; if ($exe -notmatch '(?i)nginx') { continue }
                $cmd = "$exe $($ac.Arguments)"; if ($ac.WorkingDirectory -and $cmd -notmatch '\s-p\s') { $cmd += " -p `"$($ac.WorkingDirectory)`"" }
                $c = & $confOf $exe $cmd
                & $add $exe $c[0] $c[1] "scheduled task $($t.TaskPath)$($t.TaskName)" $null $null
            }
        }
        $dirs = @("C:\nginx*", "D:\nginx*", "E:\nginx*", "C:\tools\nginx*", "D:\tools\nginx*", "C:\opt\nginx*", "D:\opt\nginx*")
        if ($env:ProgramFiles) { $dirs += (Join-Path $env:ProgramFiles "nginx*") }
        foreach ($d in @(Get-Item -Path $dirs -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer })) {
            foreach ($x in @(Get-ChildItem -LiteralPath $d.FullName -Filter nginx.exe -File -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
                $c = & $confOf $x.FullName ""
                & $add $x.FullName $c[0] $c[1] "" $null $null
            }
        }
    } else {
        foreach ($f in @("/usr/sbin/nginx", "/usr/local/nginx/sbin/nginx", "/opt/nginx/sbin/nginx")) {
            if (Test-Path -LiteralPath $f -PathType Leaf) {
                $conf = ""; $v = (ihwt-exec $f @("-V") -TimeoutSec 30).Out
                if ($v -match '--conf-path=(\S+)') { $conf = $Matches[1] }
                & $add $f $conf (Split-Path -Parent $f) "" $null $null
            }
        }
    }
    foreach ($o in $found.Values) { if (-not $o.StartedBy) { $o.StartedBy = $(if ($o.Pid) { "running, started by hand (no service / task found)" } else { "not started (no service / task / process)" }) } }
    return @($found.Values)
}

# ihwt-webtier-find DH... - "type;main_conf" of every web server configuration
function ihwt-webtier-find {
    param([string[]] $DomainHomes = @(), $Procs = $null, $NginxInstalls = $null)
    if ($null -eq $Procs) { $Procs = ihwt-procs }
    if ($null -eq $NginxInstalls) { $NginxInstalls = ihwt-nginx-installs $Procs }
    $l = New-Object System.Collections.Generic.List[string]
    foreach ($n in $NginxInstalls) { if ($n.Conf) { $l.Add("nginx;$($n.Conf)") } }
    # Apache / OHS httpd: -f conf / -d root of the process, else conf\httpd.conf next to bin
    foreach ($p in @($Procs | Where-Object { $_.Name -match '^(httpd|apache2?)(\.exe)?$' })) {
        $cmd = "$($p.CommandLine)"; $exe = "$($p.ExecutablePath)"
        $t = if ($cmd -match '(?i)OHS|[\\/]ohs[\\/]') { "ohs" } else { "apache" }
        $conf = ""; $root = ""
        if ($cmd -match '\s-f\s+"?([^"\s]+)') { $conf = $Matches[1] }
        if ($cmd -match '\s-d\s+"?([^"\s]+)') { $root = $Matches[1] }
        if (-not $conf -and $root) { $conf = Join-Path $root "conf\httpd.conf" }
        if (-not $conf -and $exe) { $conf = ihwt-jp @((Split-Path -Parent (Split-Path -Parent $exe)), "conf", "httpd.conf") }
        if ($t -eq "ohs") { $conf = $conf -replace '([\\/])components\1OHS\1instances\1([^\\/]+)\1', '$1components$1OHS$1$2$1' }
        if ($conf) { $l.Add("$t;$conf") }
    }
    if ($IHWT_ON_WINDOWS) {
        foreach ($f in @("C:\Apache24\conf\httpd.conf", "D:\Apache24\conf\httpd.conf", "C:\xampp\apache\conf\httpd.conf")) { if (Test-Path -LiteralPath $f) { $l.Add("apache;$f") } }
        $iis = Join-Path "$env:windir" "System32\inetsrv\config\applicationHost.config"
        if ((Get-Service W3SVC -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $iis)) { $l.Add("iis;$iis") }
    } else {
        foreach ($f in @("/etc/httpd/conf/httpd.conf", "/etc/apache2/apache2.conf", "/usr/local/apache2/conf/httpd.conf")) { if (Test-Path -LiteralPath $f) { $l.Add("apache;$f") } }
    }
    foreach ($d in $DomainHomes) {
        if (-not $d) { continue }
        foreach ($c in @(Get-ChildItem -LiteralPath (ihwt-jp @($d, "config", "fmwconfig", "components", "OHS")) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "instances" })) {
            $f = Join-Path $c.FullName "httpd.conf"; if (Test-Path -LiteralPath $f) { $l.Add("ohs;$f") }
        }
    }
    $seen = @{}; $res = @()
    foreach ($e in $l) {
        $t = $e.Substring(0, $e.IndexOf(';')); $f = $e.Substring($e.IndexOf(';') + 1)
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try { $f = (Get-Item -LiteralPath $f -Force).FullName } catch { }
        if ($seen.ContainsKey($f.ToLower())) { continue }
        $seen[$f.ToLower()] = 1; $res += "$t;$f"
    }
    return $res
}

function _ihwt-wt-flat {
    param([string] $Type, [string] $File, [string] $Root, [hashtable] $Vars, [int] $Depth, [System.Collections.Generic.List[string]] $Out)
    if ($Depth -gt 8) { $Out.Add("#@@ TOO_DEEP $File"); return }
    $lines = $null
    try { $lines = [IO.File]::ReadAllLines($File) } catch { $Out.Add("#@@ UNREADABLE $File"); return }
    $Out.Add("#@@ FILE $File")
    foreach ($line in $lines) {
        $Out.Add($line)
        $inc = ""
        if ($Type -eq "nginx") { if ($line -match '^\s*include\s+([^;]+);') { $inc = $Matches[1] } }
        elseif ($Type -ne "iis") { if ($line -match '^\s*(?i:include(optional)?)\s+"?([^"]+)"?') { $inc = $Matches[2] } }
        if (-not $inc) { continue }
        $inc = $inc.Trim() -replace '"', '' -replace "'", ''
        foreach ($k in $Vars.Keys) { $inc = $inc.Replace('${' + $k + '}', $Vars[$k]) }
        $inc = $inc -replace '([\\/])components\1OHS\1instances\1([^\\/]+)\1', '$1components$1OHS$1$2$1'
        if ($inc -match '\$\{') { $Out.Add("#@@ UNRESOLVED $inc"); continue }
        if (-not [IO.Path]::IsPathRooted($inc)) { $inc = Join-Path $Root $inc }
        if ((Split-Path -Leaf $inc) -match '^(mime\.types|.*fastcgi_params|uwsgi_params|scgi_params|koi-.*|win-utf)$') { $Out.Add("#@@ SKIPPED $inc"); continue }
        $hits = @(Get-Item -Path $inc -Force -ErrorAction SilentlyContinue | Sort-Object FullName)
        if (-not $hits.Count) { $Out.Add("#@@ NOT_FOUND $inc"); continue }
        foreach ($h in $hits) { if (-not $h.PSIsContainer) { _ihwt-wt-flat $Type $h.FullName $Root $Vars ($Depth + 1) $Out } }
    }
    $Out.Add("#@@ END $File")
}
# ihwt-webtier-flatten TYPE MAIN - lines with all includes inlined
function ihwt-webtier-flatten {
    param([string] $Type, [string] $Main)
    $vars = @{}; $root = Split-Path -Parent $Main
    if ($Type -eq "ohs") {
        $n = Split-Path -Leaf $root
        $d = $root -replace '[\\/]config[\\/]fmwconfig[\\/]components[\\/]OHS[\\/].*$', ''
        $vars = @{ ORACLE_INSTANCE = $d; DOMAIN_HOME = $d; COMPONENT_TYPE = "OHS"; COMPONENT_NAME = $n }
    } elseif ($Type -eq "apache") {
        $m = Select-String -LiteralPath $Main -Pattern '^\s*ServerRoot\s+"?([^"\s]+)' -ErrorAction SilentlyContinue | Select-Object -First 1
        $root = if ($m -and (ihwt-isdir $m.Matches[0].Groups[1].Value)) { $m.Matches[0].Groups[1].Value } else { Split-Path -Parent (Split-Path -Parent $Main) }
    }
    $out = New-Object System.Collections.Generic.List[string]
    _ihwt-wt-flat $Type $Main $root $vars 0 $out
    return $out.ToArray()
}

# ihwt-webtier-routes TYPE MAIN LINES - routing rows ($IHWT_WT_HEAD), the
# logic of ihwt_webtier_routes (bash) line by line
function ihwt-webtier-routes {
    param([string] $Type, [string] $Main, [string[]] $Lines)
    $rows = New-Object System.Collections.Generic.List[string]
    if ($Type -eq "nginx") {
        $tok = New-Object System.Collections.Generic.List[string]
        foreach ($raw in $Lines) {
            if ($raw -like '#@@*') { continue }
            $x = $raw -replace '\s#.*$', '' -replace '^\s*#.*$', ''
            $x = $x.Replace('{', "{`n").Replace('}', "`n}`n").Replace(';', ";`n")
            foreach ($t in ($x -split "`n")) { $tok.Add($t) }
        }
        $trim = { param($s) ($s -replace '^\s+', '') -replace '[\s;{]+$', '' }
        $args_ = { param($s) ((& $trim $s) -replace '^\S+\s*', '') }
        $ctx = @{}; $carg = @{}; $sp = 0; $cur = 0; $ns = 0; $up = ""
        $SV = @{}; $ups = @{}; $gpr = ""; $RT = New-Object System.Collections.Generic.List[object]
        $lp = @{}; $lt = @{}; $la = @{}
        foreach ($t in $tok) {
            $l = & $trim $t
            if ($l -eq "" -and $t -notmatch '}') { continue }
            $w = $l -replace '\s.*$', ''
            if ($t -match '\{\s*$') {
                $sp++; $ctx[$sp] = $w; $carg[$sp] = & $args_ $l
                if ($w -eq "server" -and $ctx[$sp - 1] -eq "http") { $ns++; $SV[$ns] = @{ sl = ""; sn = ""; tls = "no"; pr = ""; acc = ""; cert = ""; rows = 0; ret = "" }; $cur = $ns }
                if ($w -eq "location") { $lp[$sp] = $carg[$sp]; $lt[$sp] = "-"; $la[$sp] = "" }
                if ($w -eq "upstream") { $up = $carg[$sp] }
                continue
            }
            if ($t -match '^}') {
                if ($ctx[$sp] -eq "location" -and $cur) { $RT.Add(@{ s = $cur; p = $lp[$sp]; t = $lt[$sp]; a = $la[$sp] }); $SV[$cur].rows++ }
                if ($ctx[$sp] -eq "server") { $cur = 0 }
                if ($ctx[$sp] -eq "upstream") { $up = "" }
                $sp--; continue
            }
            $a = & $args_ $l
            if ($w -eq "ssl_protocols") { if ($cur) { $SV[$cur].pr = $a } else { $gpr = $a } }
            if ($w -eq "upstream") { continue }
            if ($ctx[$sp] -eq "upstream" -and $w -eq "server") { $u = $a -replace '\s.*$', ''; $ups[$up] = $(if ($ups.ContainsKey($up) -and $ups[$up]) { "$($ups[$up]),$u" } else { $u }); continue }
            if (-not $cur) { continue }
            $s = $SV[$cur]
            if ($w -eq "listen") { $v = $a; if ($v -match '(^|\s)ssl(\s|$)') { $s.tls = "yes" }; $v = $v -replace '\s.*$', ''; if ($v -notmatch ':') { $v = "*:$v" }; $s.sl = $(if ($s.sl) { "$($s.sl),$v" } else { $v }) }
            if ($w -eq "ssl" -and $a -match '^on') { $s.tls = "yes" }
            if ($w -eq "server_name") { $s.sn = $a -replace '\s+', ',' }
            if ($w -eq "ssl_certificate") { $s.cert = $a }
            if (($w -eq "allow" -and $a -notmatch '^all') -or ($w -eq "deny" -and $a -match '^all') -or ($w -eq "auth_basic" -and $a -notmatch '^off') -or $w -eq "auth_request") {
                if ($ctx[$sp] -eq "location") { $la[$sp] = "restricted" } else { $s.acc = "restricted" } }
            if ($ctx[$sp] -eq "location" -and $w -eq "proxy_pass") { $h = ($a -replace '^[a-z]+://', '') -replace '/.*$', ''; $lt[$sp] = $h }
            if ($ctx[$sp] -eq "location" -and $w -eq "return" -and $a -match '^30[1278]') { $lt[$sp] = "redirect " + ($a -replace '^[0-9]+\s*', '') }
            if ($ctx[$sp] -eq "location" -and ($w -eq "alias" -or $w -eq "root") -and $lt[$sp] -eq "-") { $lt[$sp] = "static $a" }
            if ($ctx[$sp] -eq "server" -and $w -eq "return" -and $a -match '^30[1278]') { $s.ret = "redirect " + ($a -replace '^[0-9]+\s*', '') }
        }
        foreach ($r in $RT) {
            $s = $SV[$r.s]; $t = $r.t
            if ($t -notmatch '^(redirect|static) ' -and $t -ne "-" -and $t -notmatch ':' -and $ups.ContainsKey($t)) { $t = "$t($($ups[$t]))" }
            $rows.Add(("nginx;{0};{1};{2};{3};{4};{5};{6};{7};{8}" -f $Main, $s.sl, $s.sn, $s.tls, $(if ($s.pr) { $s.pr } else { $gpr }), $r.p, $t, $(if ($r.a) { $r.a } elseif ($s.acc) { $s.acc } else { "open" }), $s.cert))
        }
        for ($i = 1; $i -le $ns; $i++) { $s = $SV[$i]; if ($s.rows) { continue }
            $rows.Add(("nginx;{0};{1};{2};{3};{4};-;{5};{6};{7}" -f $Main, $s.sl, $s.sn, $s.tls, $(if ($s.pr) { $s.pr } else { $gpr }), $(if ($s.ret) { $s.ret } else { "-" }), $(if ($s.acc) { $s.acc } else { "open" }), $s.cert)) }
        $rows = @($rows | ForEach-Object { $_ -replace '\s*;', ';' })
    } elseif ($Type -eq "iis") {
        # sites + bindings of applicationHost.config; WebLogic target from the
        # iisproxy.ini of the plug-in (WebLogicHost / WebLogicPort / WebLogicCluster)
        $txt = $Lines -join "`n"; $tgt = "-"
        $ini = @(Get-ChildItem -Path "$env:SystemDrive\inetpub", "C:\Oracle", "D:\Oracle" -Filter iisproxy.ini -File -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($ini.Count) { $it = Get-Content -LiteralPath $ini[0].FullName -Raw
            if ($it -match '(?im)^\s*WebLogicCluster\s*=\s*(\S+)') { $tgt = $Matches[1] }
            elseif ($it -match '(?im)^\s*WebLogicHost\s*=\s*(\S+)') { $h = $Matches[1]; $tgt = $h + ":" + $(if ($it -match '(?im)^\s*WebLogicPort\s*=\s*(\d+)') { $Matches[1] } else { "7001" }) } }
        foreach ($m in [regex]::Matches($txt, '<site\s+name="([^"]*)"[\s\S]*?</site>')) {
            foreach ($b in [regex]::Matches($m.Value, '<binding\s+protocol="([^"]*)"\s+bindingInformation="([^"]*)"')) {
                $bi = $b.Groups[2].Value -split ':'; $lis = $(if ($bi[0] -eq '*' -or $bi[0] -eq '') { '*' } else { $bi[0] }) + ":" + $bi[1]
                $rows.Add(("iis;{0};{1};{2};{3};;/;{4};open;" -f $Main, $lis, $(if ($bi.Count -gt 2 -and $bi[2]) { $bi[2] } else { $m.Groups[1].Value }), $(if ($b.Groups[1].Value -eq 'https') { 'yes' } else { 'no' }), $(if ($m.Value -match '(?i)iisproxy|iisforward') { $tgt } else { "-" })))
            }
        }
    } else {
        # Apache / OHS (the awk of ihwt_webtier_routes)
        $hport = @{}
        $st = @{ vh = 0; nv = 0; gl = ""; gn = ""; gt = ""; gpr = ""; gcert = ""; gwh = ""; gwp = ""; gwc = ""; gred = ""; grows = 0; inl = $false; lpth = ""; lh = $false; lwh = ""; lwp = ""; lwc = ""; lacc = "open"; lpx = "" }
        $VH = @{}; $RT = New-Object System.Collections.Generic.List[object]
        $wlt = { param($h, $p, $c)
            if ($c) { return $c }
            $v = $(if ($st.vh) { $VH[$st.vh] } else { $null })
            if (-not $h -and -not $p) { if ($v -and $v.wc) { return $v.wc }; if ($st.gwc) { return $st.gwc } }
            if (-not $h) { $h = $(if ($v -and $v.wh) { $v.wh } else { $st.gwh }) }
            if (-not $p) { $p = $(if ($v -and $v.wp) { $v.wp } else { $st.gwp }) }
            return "${h}:$p" }
        $row = { param($path, $target, $acc) $RT.Add(@{ v = $st.vh; p = $path; t = $target; a = $acc }); if ($st.vh) { $VH[$st.vh].rows++ } else { $st.grows++ } }
        foreach ($raw in $Lines) {
            if ($raw -like '#@@*') { continue }
            $x = $raw -replace '^\s*#.*$', ''; $l = $x.Trim(); if (-not $l) { continue }
            $w = ($l -replace '\s.*$', '').ToLower(); $a = ($l -replace '^\S+\s*', '').Trim()
            $v = $(if ($st.vh) { $VH[$st.vh] } else { $null })
            if ($w -match '^<virtualhost') { $st.nv++; $st.vh = $st.nv; $VH[$st.vh] = @{ vl = (($a -replace '>$', '') -replace '\s+', ','); vt = "no"; vpr = ""; vn = ""; vcert = ""; wh = ""; wp = ""; wc = ""; red = ""; rows = 0 }; continue }
            if ($w -match '^</virtualhost') { $st.vh = 0; continue }
            if ($w -match '^<location(match)?>?$' -or $w -match '^<location(match)?>') { $st.inl = $true; $st.lpth = ($a -replace '"', '') -replace '>$', ''; $st.lh = $false; $st.lwh = ""; $st.lwp = ""; $st.lwc = ""; $st.lacc = "open"; $st.lpx = ""; continue }
            if ($w -match '^</location') { if ($st.lh -or $st.lpx) { & $row $st.lpth $(if ($st.lpx) { $st.lpx } else { & $wlt $st.lwh $st.lwp $st.lwc }) $st.lacc }; $st.inl = $false; continue }
            switch ($w) {
                "listen" { $vv = $a -replace '\s.*$', ''; if ($vv -notmatch ':') { $vv = "*:$vv" }; $st.gl = $(if ($st.gl) { "$($st.gl),$vv" } else { $vv })
                           if ($a -match '\shttps$') { $hport[($vv -replace '.*:', '')] = 1 }; continue }
                "servername" { $vv = ($a -replace '^https?://', '') -replace ':.*$', ''; if ($v) { $v.vn = $vv } else { $st.gn = $vv }; continue }
                "serveralias" { if ($v) { $v.vn = ("$($v.vn),$a") -replace '\s+', ',' }; continue }
                "sslengine" { if ($a.ToLower() -match '^on') { if ($v) { $v.vt = "yes" } else { $st.gt = "yes" } }; continue }
                "sslprotocol" { if ($v) { $v.vpr = $a } else { $st.gpr = $a }; continue }
                { $_ -eq "sslcertificatefile" -or $_ -eq "sslwallet" } { if ($v) { $v.vcert = $a -replace '"', '' } else { $st.gcert = $a -replace '"', '' }; continue }
                "sethandler" { if ($a.ToLower() -match 'weblogic-handler' -and $st.inl) { $st.lh = $true }; continue }
                "weblogichost" { if ($st.inl) { $st.lwh = $a } elseif ($v) { $v.wh = $a } else { $st.gwh = $a }; continue }
                "weblogicport" { if ($st.inl) { $st.lwp = $a } elseif ($v) { $v.wp = $a } else { $st.gwp = $a }; continue }
                "weblogiccluster" { if ($st.inl) { $st.lwc = $a } elseif ($v) { $v.wc = $a } else { $st.gwc = $a }; continue }
                "matchexpression" { & $row ($a -replace '\s.*$', '') (& $wlt "" "" "") "open"; continue }
                "proxypass" { $pp = $a -split '\s+'; if ($pp.Count -lt 2 -or $pp[1] -eq "!") { continue }
                              $tt = ($pp[1] -replace '^[a-z]+://', '') -replace '/.*$', ''
                              if ($st.inl) { $st.lpx = $tt } else { & $row $pp[0] $tt "open" }; continue }
            }
            if (($w -eq "require" -and $a.ToLower() -notmatch '^all granted') -or $w -eq "allow" -or $w -eq "deny" -or $w -eq "authtype") { if ($st.inl) { $st.lacc = "restricted" }; continue }
            if ($w -eq "redirect" -or $w -eq "redirectmatch" -or ($w -eq "rewriterule" -and $a -match 'https:')) { if ($v) { $v.red = "redirect $a" } else { $st.gred = "redirect $a" } }
        }
        # global routes are inherited by every VirtualHost without own routes
        # (as bash): global rows keep only the listeners no vhost covers
        $used = @{}; $inh = @{}
        for ($i = 1; $i -le $st.nv; $i++) { if (-not $VH[$i].rows -and $st.grows) { $inh[$i] = 1; foreach ($q in ($VH[$i].vl -split ',')) { $used[($q -replace '.*:', '')] = 1 } } }
        $glp = @(($st.gl -split ',') | Where-Object { $_ -and -not $used.ContainsKey(($_ -replace '.*:', '')) -and -not $hport.ContainsKey(($_ -replace '.*:', '')) }) -join ','
        if (-not $st.nv) { $glp = $st.gl }
        foreach ($r in $RT) { $v = $(if ($r.v) { $VH[$r.v] } else { $null })
            if (-not $v -and -not $glp) { continue }
            $rows.Add(("{0};{1};{2};{3};{4};{5};{6};{7};{8};{9}" -f $Type, $Main, $(if ($v) { $v.vl } else { $glp }), $(if ($v -and $v.vn) { $v.vn } else { $st.gn }),
                $(if ($v) { $v.vt } elseif ($st.gt) { $st.gt } else { "no" }), $(if ($v -and $v.vpr) { $v.vpr } else { $st.gpr }), $r.p, $r.t, $r.a, $(if ($v -and $v.vcert) { $v.vcert } else { $st.gcert }))) }
        for ($i = 1; $i -le $st.nv; $i++) { if (-not $inh.ContainsKey($i)) { continue }; $v = $VH[$i]
            foreach ($r in @($RT | Where-Object { -not $_.v })) {
                $rows.Add(("{0};{1};{2};{3};{4};{5};{6};{7};{8};{9}" -f $Type, $Main, $v.vl, $(if ($v.vn) { $v.vn } else { $st.gn }), $v.vt, $(if ($v.vpr) { $v.vpr } else { $st.gpr }), $r.p, $r.t, $r.a, $(if ($v.vcert) { $v.vcert } else { $st.gcert }))) } }
        for ($i = 1; $i -le $st.nv; $i++) { $v = $VH[$i]; if ($v.rows -or $inh.ContainsKey($i)) { continue }
            $rows.Add(("{0};{1};{2};{3};{4};{5};-;{6};open;{7}" -f $Type, $Main, $v.vl, $(if ($v.vn) { $v.vn } else { $st.gn }), $v.vt, $(if ($v.vpr) { $v.vpr } else { $st.gpr }), $(if ($v.red) { $v.red } else { "-" }), $(if ($v.vcert) { $v.vcert } else { $st.gcert }))) }
        if (-not $st.nv -and -not $st.grows) { $rows.Add(("{0};{1};{2};{3};{4};{5};-;{6};open;{7}" -f $Type, $Main, $st.gl, $st.gn, $(if ($st.gt) { $st.gt } else { "no" }), $st.gpr, $(if ($st.gred) { $st.gred } else { "-" }), $st.gcert)) }
        if ($Type -eq "ohs") {
            $cd = Split-Path -Parent $Main; $n = Split-Path -Leaf $cd; $d = $cd -replace '[\\/]config[\\/]fmwconfig[\\/]components[\\/]OHS[\\/].*$', ''
            $rows = @($rows | ForEach-Object { ($_.Replace('${ORACLE_INSTANCE}', $d).Replace('${DOMAIN_HOME}', $d).Replace('${COMPONENT_TYPE}', 'OHS').Replace('${COMPONENT_NAME}', $n)) -replace '([\\/])components\1OHS\1instances\1([^\\/]+)\1', '$1components$1OHS$1$2$1' })
        }
    }
    return @($rows | ForEach-Object { ihwt-mask $_ })
}

# ihwt-webtier-settings TYPE MAIN LINES - "type;conf;key;value;file" of the
# directives the analysis rates
function ihwt-webtier-settings {
    param([string] $Type, [string] $Main, [string[]] $Lines)
    $stk = New-Object System.Collections.Generic.Stack[string]; $res = @()
    foreach ($raw in $Lines) {
        if ($raw -like '#@@ FILE *') { $stk.Push($raw.Substring(9)); continue }
        if ($raw -like '#@@ END *') { if ($stk.Count) { [void]$stk.Pop() }; continue }
        if ($raw -match '^\s*#') { continue }
        $l = ($raw -replace '^\s+', '') -replace '[\s;]+$', ''; $w = $l -replace '\s.*$', ''; $a = $l -replace '^\S+\s*', ''; $lw = $w.ToLower()
        $f = $(if ($stk.Count) { $stk.Peek() } else { "" })
        if ($lw -match '^(server_tokens|servertokens|serversignature|traceenable|debugconfiginfo|autoindex|wlproxyssl|wlproxysslpassthrough)$') { $res += "$Type;$Main;$w;$a;$f" }
        elseif ($lw -eq "options" -and $a.ToLower() -match '(^|\s)\+?indexes') { $res += "$Type;$Main;Options;$a;$f" }
    }
    return $res
}

# _ihwt-dn DER - distinguished name in encoding order with openssl's short
# names ("C=DE, ST=Hessen, ..., CN=host") - .NET formats the RDNs in a
# platform-dependent order, so the DER (SEQUENCE OF SET OF SEQUENCE {OID,
# value}) is read directly
function _ihwt-dn {
    param([byte[]] $D)
    $names = @{ '2.5.4.6' = 'C'; '2.5.4.8' = 'ST'; '2.5.4.7' = 'L'; '2.5.4.10' = 'O'; '2.5.4.11' = 'OU'; '2.5.4.3' = 'CN'
                '2.5.4.5' = 'serialNumber'; '1.2.840.113549.1.9.1' = 'emailAddress'; '0.9.2342.19200300.100.1.25' = 'DC'; '2.5.4.9' = 'street'; '2.5.4.17' = 'postalCode' }
    $tl = { param([int] $p) $len = [int]$D[$p + 1]; $h = 2
            if ($len -band 0x80) { $n = $len -band 0x7F; $len = 0; for ($k = 0; $k -lt $n; $k++) { $len = ($len -shl 8) + $D[$p + 2 + $k] }; $h = 2 + $n }
            return @($D[$p], $h, $len) }
    $out = @()
    try {
        $t = & $tl 0; $pos = $t[1]; $end = $t[1] + $t[2]
        while ($pos -lt $end) {
            $set = & $tl $pos; $sp = $pos + $set[1]; $se = $sp + $set[2]
            while ($sp -lt $se) {
                $sq = & $tl $sp; $ip = $sp + $sq[1]
                $o = & $tl $ip; $ob = $D[($ip + $o[1])..($ip + $o[1] + $o[2] - 1)]
                $oid = "{0}.{1}" -f [math]::Floor($ob[0] / 40), ($ob[0] % 40); $v = 0
                for ($k = 1; $k -lt $ob.Count; $k++) { $v = ($v -shl 7) + ($ob[$k] -band 0x7F); if (-not ($ob[$k] -band 0x80)) { $oid += ".$v"; $v = 0 } }
                $vp = $ip + $o[1] + $o[2]; $vv = & $tl $vp; $vb = [byte[]]$D[($vp + $vv[1])..($vp + $vv[1] + $vv[2] - 1)]
                $val = if ($vv[0] -eq 0x1E) { [Text.Encoding]::BigEndianUnicode.GetString($vb) } else { [Text.Encoding]::UTF8.GetString($vb) }
                $out += ("{0}={1}" -f $(if ($names.ContainsKey($oid)) { $names[$oid] } else { $oid }), $val)
                $sp = $sp + $sq[1] + $sq[2]
            }
            $pos = $se
        }
    } catch { return "?" }
    return (($out -join ', ') -replace ';', ',')
}

# ihwt-certificates ROWS - subject / issuer / expiry (public part) of every
# HTTPS listener of the routing rows: TLS handshake with the server name, else
# the certificate file of the route. "source;subject;issuer;not_after;san;key;sig;chain"
# (no header, as bash ihwt_certificates; chain = certificates the server sends)
# openssl date format "%b %e %H:%M:%S %Y GMT" (day padded with a blank)
function _ihwt-osdate { param([datetime] $D) $u = $D.ToUniversalTime(); $ci = [Globalization.CultureInfo]::InvariantCulture
    return ("{0} {1,2} {2} GMT" -f $u.ToString('MMM', $ci), $u.Day, $u.ToString('HH:mm:ss yyyy', $ci)) }
function _ihwt-cert-cols {
    param($c)
    $san = ""
    foreach ($e in $c.Extensions) { if ($e.Oid.Value -eq '2.5.29.17') { $san = ($e.Format($false) -replace '(DNS Name|DNS|IP Address)[=:]', '' -replace '\s', '' -replace ';', ',') } }
    $ka = $c.PublicKey.Oid.Value; $kb = ""
    switch ($ka) {
        '1.2.840.113549.1.1.1' { $kn = 'RSA'; try { $kb = $c.PublicKey.GetRSAPublicKey().KeySize } catch { try { $kb = $c.PublicKey.Key.KeySize } catch { } } }
        '1.2.840.10045.2.1' { $kn = 'EC'; try { $kb = $c.PublicKey.GetECDsaPublicKey().KeySize } catch { } }
        '1.2.840.113549.1.1.10' { $kn = 'RSA-PSS' }
        default { $kn = $c.PublicKey.Oid.FriendlyName }
    }
    $sm = @{ '1.2.840.113549.1.1.11' = 'sha256WithRSAEncryption'; '1.2.840.113549.1.1.12' = 'sha384WithRSAEncryption'; '1.2.840.113549.1.1.13' = 'sha512WithRSAEncryption'
             '1.2.840.113549.1.1.5' = 'sha1WithRSAEncryption'; '1.2.840.113549.1.1.4' = 'md5WithRSAEncryption'; '1.2.840.113549.1.1.10' = 'rsassaPss'
             '1.2.840.10045.4.3.2' = 'ecdsa-with-SHA256'; '1.2.840.10045.4.3.3' = 'ecdsa-with-SHA384'; '1.2.840.10045.4.3.4' = 'ecdsa-with-SHA512' }
    $sg = $(if ($sm.ContainsKey($c.SignatureAlgorithm.Value)) { $sm[$c.SignatureAlgorithm.Value] } else { $c.SignatureAlgorithm.FriendlyName })
    return ("{0};{1} {2};{3}" -f $(if ($san) { $san } else { '' }), $kn, $kb, $sg)
}
function ihwt-certificates {
    param([string[]] $Rows)
    $seen = @{}; $res = @()
    $hn = [Environment]::MachineName; try { $hn = [System.Net.Dns]::GetHostEntry([string]$hn).HostName } catch { }
    foreach ($r in $Rows) {
        $f = $r -split ';'; if ($f.Count -lt 10 -or $f[4] -ne "yes") { continue }
        $sn = ($f[3] -split ',')[0]
        foreach ($lis in ($f[2] -split ',')) {
            if ($lis -match '^\[' -and $lis -notmatch '^\[::\]:') { continue }
            $port = $lis -replace '^.*:', ''; $key = "$($f[0]);$port;$sn"; if ($seen.ContainsKey($key)) { continue }; $seen[$key] = 1
            $h = $lis.Substring(0, $lis.LastIndexOf(':')); if ($h -in @('*', '0.0.0.0', '[::]', '')) { $h = "127.0.0.1" }
            $name = $(if ($sn -in @('', '_', 'localhost') -or $sn -like '`**') { $hn } else { $sn })
            $src = "https $($f[0]) $lis ($name)"; $c = $null; $script:_ihwt_chain = "-"
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                if ($tcp.ConnectAsync($h, [int]$port).Wait(10000)) {
                    # the certificates the server sent are in the ExtraStore of the chain (.NET Core)
                    $cb = { param($snd, $crt, $chn, $err) try { $script:_ihwt_chain = "$(1 + @($chn.ChainPolicy.ExtraStore | Where-Object { $_.Thumbprint -ne $crt.GetCertHashString() }).Count)" } catch { }; $true }
                    $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, ($cb -as [System.Net.Security.RemoteCertificateValidationCallback]))
                    $ssl.AuthenticateAsClient($name)
                    $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
                    $ssl.Close()
                }
                $tcp.Close()
            } catch { $c = $null }
            if (-not $c -and $f[9] -and (Test-Path -LiteralPath $f[9] -PathType Leaf)) {
                try { $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($f[9]); $src = "https $($f[0]) $lis (file $($f[9]))"; $script:_ihwt_chain = "file" } catch { $c = $null }
            }
            # openssl order and names ("C=DE, ST=..., CN=...") like the bash version
            $dn = { param($x) _ihwt-dn $x.RawData }
            if ($c) { $res += ("{0};{1};{2};{3};{4};{5}" -f $src, (& $dn $c.SubjectName), (& $dn $c.IssuerName), $(_ihwt-osdate $c.NotAfter), (_ihwt-cert-cols $c), $script:_ihwt_chain) }
            else { $res += "$src;-;-;not reachable / no readable certificate file;-;-;-;-" }
        }
    }
    return $res
}

#------------------------------------------------------------------------------
# Nginx patch facts - "key;value" lines, the keys of ihwt_nginx_patch (bash)
# plus the Windows keys (Nginx on Windows is installed by hand: no package
# manager, OpenSSL linked statically into nginx.exe)
#------------------------------------------------------------------------------
function ihwt-nginx-patch {
    param($Installs = $null)
    if ($null -eq $Installs) { $Installs = ihwt-nginx-installs }
    $Installs = @($Installs | Where-Object { $_.Exe -and (Test-Path -LiteralPath $_.Exe -PathType Leaf) })
    if (-not $Installs.Count) { return @("installed;no") }
    # the running one first, it is what the clients reach
    $main = @($Installs | Sort-Object @{ e = { if ($_.Pid) { 0 } else { 1 } } }, Exe)[0]
    $res = New-Object System.Collections.Generic.List[string]
    $res.Add("installed;yes"); $res.Add("binary;$($main.Exe)")
    $v = (ihwt-exec $main.Exe @("-V") -TimeoutSec 30).Out
    $ver = if ($v -match 'nginx version: nginx/(\S+)') { $Matches[1] } else { "" }
    $res.Add("version;$ver")
    $res.Add("openssl;$(if ($v -match '(?m)^built with (.+)$') { $Matches[1].Trim() } else { '' })")
    $mp = if ($v -match '--modules-path=(\S+)') { $Matches[1] } else { "" }
    $res.Add("dynamic_modules_dir;$mp")
    if ($ver -match '^\d+\.(\d+)\.') { $res.Add("line;$(if ([int]$Matches[1] % 2) { 'mainline (odd minor version)' } else { 'stable (even minor version)' })") }
    $fi = Get-Item -LiteralPath $main.Exe -Force
    $res.Add("binary_date;$($fi.LastWriteTime.ToString('yyyy-MM-dd'))")
    if ($IHWT_ON_WINDOWS) {
        $res.Add("package;none (installed by hand - no patches through a package manager)")
        $res.Add("origin;manual install (Windows)")
        $res.Add("file_version;$($fi.VersionInfo.FileVersion)")
        $res.Add("started_by;$($main.StartedBy)")
        $res.Add("config;$($main.Conf)")
        # who may write into the nginx directory (a directory below C:\ is often
        # writable for every user) - only the entries with write rights
        try {
            $acl = Get-Acl -LiteralPath (Split-Path -Parent $main.Exe)
            $wr = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and ("$($_.FileSystemRights)" -match 'FullControl|Modify|Write') } | ForEach-Object { "$($_.IdentityReference)" } | Sort-Object -Unique)
            $res.Add("writable_by;$($wr -join ', ')")
            $weak = @($wr | Where-Object { $_ -match '(?i)\\Users$|Authenticated Users|Everyone|\\Benutzer$|Authentifizierte Benutzer|Jeder' })
            $res.Add("writable_by_non_admins;$(if ($weak.Count) { $weak -join ', ' } else { 'no' })")
        } catch { $res.Add("writable_by;not readable ($_)") }
    } else {
        $pk = (ihwt-exec "rpm" @("-qf", "--qf", "%{NAME} %{VERSION}-%{RELEASE}", $main.Exe) -TimeoutSec 30).Out.Trim()
        if ($pk -and $pk -notmatch 'not owned|ERROR') { $res.Add("package;$pk"); $res.Add("origin;OS repository (rpm)") }
        else { $res.Add("package;none (built / copied by hand - no patches through dnf)"); $res.Add("origin;own build") }
    }
    if ($main.Pid) {
        $res.Add("master_pid;$($main.Pid)")
        if ($main.Started) {
            $started = [datetime]$main.Started
            $res.Add("master_started;$($started.ToString('yyyy-MM-dd HH:mm'))")
            $res.Add("restart_pending;$(if ($fi.LastWriteTime -gt $started) { 'yes (nginx binary newer than the running master)' } else { 'no' })")
        }
    } else { $res.Add("master_pid;not running") }
    $others = @($Installs | Where-Object { $_.Exe -ne $main.Exe })
    $res.Add("installs;$($Installs.Count)$(if ($others.Count) { ' - also: ' + (@($others | ForEach-Object { "$($_.Exe) ($($_.StartedBy))" }) -join '; ') })")
    return $res.ToArray()
}

#------------------------------------------------------------------------------
# OS update state (Windows): updates not installed from the Windows Update
# Agent CACHE (offline search of the last scan - no network forced), with a
# timeout. "N advisories (C critical/important, ...)" like ihwt_os_advisories.
#------------------------------------------------------------------------------
function ihwt-os-advisories {
    param([int] $TimeoutSec = 180, [string] $ListFile = "")
    if (-not $IHWT_ON_WINDOWS) { return "not available (no Windows)" }
    $job = Start-Job -ScriptBlock {
        try {
            $s = New-Object -ComObject Microsoft.Update.Session
            $q = $s.CreateUpdateSearcher(); $q.Online = $false
            $r = $q.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
            foreach ($u in $r.Updates) { "{0};{1};{2}" -f $(if ($u.MsrcSeverity) { $u.MsrcSeverity } else { "-" }), (@($u.KBArticleIDs) -join ','), $u.Title }
        } catch { "ERROR;$_" }
    }
    if (-not (Wait-Job $job -Timeout $TimeoutSec)) { Stop-Job $job; Remove-Job $job -Force; return "not available (Windows Update search timed out after $TimeoutSec s)" }
    $l = @(Receive-Job $job); Remove-Job $job -Force
    if ($l.Count -and "$($l[0])" -like 'ERROR;*') { return "not available ($("$($l[0])".Substring(6)))" }
    if ($ListFile) { ihwt-write-file $ListFile $l }
    $c = @($l | Where-Object { $_ -match '^(Critical|Important);' }).Count
    return ("{0} advisories ({1} critical/important, Windows Update cache)" -f $l.Count, $c)
}

#------------------------------------------------------------------------------
# ORACLE_HOME / DOMAIN_HOME of the host (collector and export alike):
# parameter / environment, running WebLogic (-Dweblogic.home), registry
# HKLM\SOFTWARE\Oracle (ORACLE_HOME with OPatch + wlserver), usual directories;
# DOMAIN_HOME from domain-registry.xml, else -Dweblogic.RootDirectory.
# Returns @{ OH = ...; DH = ... } ("" when not found)
#------------------------------------------------------------------------------
function ihwt-find-homes {
    param([string] $OracleHome, [string] $DomainHome, $Procs = $null)
    if ($null -eq $Procs) { $Procs = ihwt-procs }
    if (-not (ihwt-isdir (Join-Path "$OracleHome" "OPatch"))) {
        $OracleHome = ""
        foreach ($p in $Procs) {
            if ("$($p.CommandLine)" -match '-Dweblogic\.home="?([^"\s]+?)[\\/]wlserver[\\/]server') { $OracleHome = $Matches[1]; break }
        }
        if (-not (ihwt-isdir (Join-Path "$OracleHome" "OPatch")) -and $IHWT_ON_WINDOWS) {
            $OracleHome = ""
            foreach ($k in @(Get-ChildItem -LiteralPath "HKLM:\SOFTWARE\Oracle" -ErrorAction SilentlyContinue)) {
                $v = (Get-ItemProperty -LiteralPath $k.PSPath -Name ORACLE_HOME -ErrorAction SilentlyContinue).ORACLE_HOME
                if ($v -and (ihwt-isdir (Join-Path $v "OPatch")) -and (ihwt-isdir (Join-Path $v "wlserver"))) { $OracleHome = $v; break }
            }
            if (-not $OracleHome) {
                foreach ($d in @("C:", "D:", "E:")) {
                    foreach ($s in @("\Oracle\Middleware\Oracle_Home", "\Oracle\Oracle_Home", "\Oracle\fmw", "\app\oracle\fmw", "\oracle\product\mw")) {
                        if (ihwt-isdir "$d$s\OPatch") { $OracleHome = "$d$s"; break }
                    }
                    if ($OracleHome) { break }
                }
            }
        }
        if (-not $OracleHome -and -not $IHWT_ON_WINDOWS) {
            foreach ($c in @("/oracle/product/mw", "/u01/app/oracle/fmw", "/u01/oracle/fmw", "/u01/app/oracle/middleware", "/u01/oracle/middleware")) {
                if (ihwt-isdir "$c/OPatch") { $OracleHome = $c; break }
            }
        }
    }
    if (-not (ihwt-isdir (Join-Path "$OracleHome" "OPatch"))) { $OracleHome = "" }
    if (-not $DomainHome -and $OracleHome -and (Test-Path -LiteralPath (Join-Path $OracleHome "domain-registry.xml"))) {
        $m = Select-String -LiteralPath (Join-Path $OracleHome "domain-registry.xml") -Pattern 'location="([^"]*)"' | Select-Object -First 1
        if ($m) { $DomainHome = $m.Matches[0].Groups[1].Value }
    }
    if (-not $DomainHome) {
        foreach ($p in $Procs) { if ("$($p.CommandLine)" -match '-Dweblogic\.RootDirectory="?([^"\s]+)') { $DomainHome = $Matches[1]; break } }
    }
    if ($DomainHome -and -not (Test-Path -LiteralPath (ihwt-jp @($DomainHome, "config", "config.xml")))) { $DomainHome = "" }
    return @{ OH = $OracleHome; DH = $DomainHome }
}

#------------------------------------------------------------------------------
# Paths, text files, strings
#------------------------------------------------------------------------------
# ihwt-fwd PATH - "/" instead of "\" (D:/Oracle/...) - every path in the derived
# files of the export, so the analyses on our side (basename, prefixes) read
# Windows and Linux archives alike; Windows accepts "/" too
function ihwt-fwd { param([string] $p) return ($p -replace '\\', '/') }
# ihwt-under PATH BASE - $true when PATH is BASE or below it (case-insensitive
# on Windows, "\" and "/" alike)
function ihwt-under {
    param([string] $p, [string] $b)
    if (-not $p -or -not $b) { return $false }
    $p = (ihwt-fwd $p).TrimEnd('/'); $b = (ihwt-fwd $b).TrimEnd('/')
    $cmp = $(if ($IHWT_ON_WINDOWS) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })
    return ($p.Equals($b, $cmp) -or $p.StartsWith("$b/", $cmp))
}
# ihwt-is-text FILE - like "grep -Iq ." (not empty, no NUL byte in the first 8 KB)
function ihwt-is-text {
    param([string] $f)
    try {
        $fs = [IO.File]::OpenRead($f)
        try { $buf = New-Object byte[] 8192; $n = $fs.Read($buf, 0, 8192) } finally { $fs.Close() }
        if ($n -le 0) { return $false }
        return ([Array]::IndexOf($buf, [byte]0, 0, $n) -lt 0)
    } catch { return $false }
}
# ihwt-strings FILE MINLEN - printable ASCII runs like "strings -n MINLEN"
function ihwt-strings {
    param([string] $f, [int] $Min = 4)
    try { $s = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($f)) } catch { return @() }
    return @([regex]::Matches($s, "[\x20-\x7E\t]{$Min,}") | ForEach-Object { $_.Value })
}

#------------------------------------------------------------------------------
# Config file parsing (ihwt_cfgval / ihwt_sections / ihwt_keys of bash)
#------------------------------------------------------------------------------
function _ihwt-lines { param([string] $f) if (-not $f -or -not (Test-Path -LiteralPath $f -PathType Leaf)) { return @() }; try { return [IO.File]::ReadAllLines($f) } catch { return @() } }
# ihwt-cfgval FILE KEYREGEX - values of KEY=... (all occurrences, trailing blanks
# removed; case-sensitive like the sed of bash)
function ihwt-cfgval {
    param([string] $f, [string] $Key)
    return @(_ihwt-lines $f | ForEach-Object { if ($_ -cmatch "^\s*$Key\s*=\s*(.*)$") { $Matches[1] -replace '\s+$', '' } })
}
# ihwt-sections FILE - "section`tkey`tvalue" of an ini-like file
function ihwt-sections {
    param([string] $f)
    $s = ""; $res = New-Object System.Collections.Generic.List[string]
    foreach ($l in (_ihwt-lines $f)) {
        if ($l -match '^\s*[#;]') { continue }
        if ($l -match '^\s*\[([^\]]+)\]') { $s = $Matches[1]; continue }
        $i = $l.IndexOf('='); if ($i -lt 0) { continue }
        $k = $l.Substring(0, $i) -replace '\s', ''; $v = $l.Substring($i + 1) -replace '\s+$', ''
        if ($k) { $res.Add("$s`t$k`t$v") }
    }
    return $res.ToArray()
}
# ihwt-keys FILE - "key`tvalue" of a key=value file (no sections)
function ihwt-keys {
    param([string] $f)
    $res = New-Object System.Collections.Generic.List[string]
    foreach ($l in (_ihwt-lines $f)) {
        if ($l -match '^\s*[#;]') { continue }
        $i = $l.IndexOf('='); if ($i -lt 0) { continue }
        $k = $l.Substring(0, $i) -replace '\s', ''; $v = $l.Substring($i + 1) -replace '\s+$', ''
        if ($k) { $res.Add("$k`t$v") }
    }
    return $res.ToArray()
}
# ihwt-font-class FILE_NAME - "class;replacement" (the list of ihwt_font_class)
function ihwt-font-class {
    param([string] $n)
    $d = [char]0x2013   # en dash like the bash version (ASCII source for PS 5.1)
    switch -regex ($n.ToLower()) {
        '^(liberation|dejavu|carlito|caladea)'          { return 'free;OS package (14b-)' }
        '^(arialuni|arial-unicode|arial_unicode)'       { return "ms;DejaVu Sans / Noto (similar $d only needed for non-Latin text)" }
        '^arialn'                                       { return 'ms;Liberation Sans Narrow (identical metrics)' }
        '^(arial|ariblk)'                               { return 'ms;Liberation Sans (identical metrics)' }
        '^times'                                        { return 'ms;Liberation Serif (identical metrics)' }
        '^cour'                                         { return 'ms;Liberation Mono (identical metrics)' }
        '^calibri'                                      { return 'ms;Carlito (identical metrics)' }
        '^cambria'                                      { return 'ms;Caladea (identical metrics) - not set up in 14c yet, see reports_fonts_architecture.md' }
        '^(verdana|tahoma|trebuc|segoe|micross)'        { return "ms;DejaVu Sans (similar $d layout can shift)" }
        '^(georgia|pala|book|constan)'                  { return "ms;Liberation Serif (similar $d layout can shift)" }
        '^(consola|lucon)'                              { return 'ms;Liberation Mono (similar)' }
        '^(wingding|webdings|symbol|marlett)'           { return "ms;none $d symbol font, original TTF needed" }
        '^(candara|corbel|comic|impact|l_10646|gara|century|gothic|franklin)' { return "ms;DejaVu Sans / Liberation (similar $d check)" }
        default                                         { return "customer;none $d must move" }
    }
}

#------------------------------------------------------------------------------
# Windows: Oracle registry environment (KEY_<home>: FORMS_PATH, REPORTS_PATH,
# NLS_LANG, TNS_ADMIN ...) and the machine environment variables Oracle reads.
# Objects Source, Name, Value (empty list on Linux)
#------------------------------------------------------------------------------
function ihwt-registry-env {
    $res = @()
    if (-not $IHWT_ON_WINDOWS) { return $res }
    foreach ($root in @("HKLM:\SOFTWARE\Oracle", "HKLM:\SOFTWARE\WOW6432Node\Oracle")) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'KEY_*' })) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue; if (-not $p) { continue }
            foreach ($pr in $p.PSObject.Properties) {
                if ($pr.Name -like 'PS*') { continue }
                $res += [pscustomobject]@{ Source = ("{0}\{1}" -f ($root -replace '^HKLM:', 'HKLM'), $k.PSChildName); Name = $pr.Name; Value = "$($pr.Value)" }
            }
        }
    }
    foreach ($n in @("ORACLE_HOME", "ORACLE_BASE", "TNS_ADMIN", "NLS_LANG", "NLS_DATE_FORMAT", "FORMS_PATH", "REPORTS_PATH", "REPORTS_TMP", "REPORTS_FONT_DIRECTORY", "TWO_TASK", "LOCAL", "JAVA_HOME", "DOMAIN_HOME")) {
        $v = [Environment]::GetEnvironmentVariable($n, 'Machine')
        if ($v) { $res += [pscustomobject]@{ Source = "ENV(Machine)"; Name = $n; Value = $v } }
    }
    return $res
}

#------------------------------------------------------------------------------
# Reports servers + load profile (ihwt_rs_list / ihwt_load_profile of bash)
#------------------------------------------------------------------------------
# ihwt-rs-list DH - objects Name, Type (standalone|in-process|servlet), Conf, NetConf, Dir
function ihwt-rs-list {
    param([string] $DH)
    $cfg = ihwt-jp @($DH, "config", "fmwconfig"); $names = New-Object System.Collections.Generic.List[string]; $res = @()
    $x = $null; try { [xml]$x = [IO.File]::ReadAllText((ihwt-jp @($DH, "config", "config.xml"))) } catch { }
    if ($x -and $x.domain.PSObject.Properties['system-component']) {
        foreach ($c in @($x.domain.'system-component')) { if ("$($c.'component-type')" -eq 'ReportsServerComponent') { $names.Add("$($c.name)") } }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath (ihwt-jp @($cfg, "components", "ReportsServerComponent")) -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -ne "mbeans" -and -not $names.Contains($d.Name)) { $names.Add($d.Name) }
    }
    foreach ($n in $names) { $d = ihwt-jp @($cfg, "components", "ReportsServerComponent", $n)
        $res += [pscustomobject]@{ Name = $n; Type = "standalone"; Conf = (Join-Path $d "rwserver.conf"); NetConf = (Join-Path $d "rwnetwork.conf"); Dir = $d } }
    foreach ($s in @(Get-ChildItem -LiteralPath (Join-Path $cfg "servers") -Directory -ErrorAction SilentlyContinue)) {
        foreach ($a in @(Get-ChildItem -LiteralPath (Join-Path $s.FullName "applications") -Directory -Filter "reports_*" -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $d = Join-Path $a.FullName "configuration"; if (-not (ihwt-isdir $d)) { continue }
            $p = Join-Path $d "rwservlet.properties"; $srv = ""; $inp = ""
            if (Test-Path -LiteralPath $p) { $t = Get-Content -LiteralPath $p -Raw
                if ($t -match '<server>([^<]*)</server>') { $srv = $Matches[1] }; if ($t -match '<inprocess>([^<]*)</inprocess>') { $inp = $Matches[1] } }
            $res += [pscustomobject]@{ Name = $(if ($srv) { $srv } elseif ($inp -eq 'yes') { "in-process" } else { "-" }); Type = $(if ($inp -eq 'yes') { "in-process" } else { "servlet" })
                                       Conf = (Join-Path $d "rwserver.conf"); NetConf = (Join-Path $d "rwnetwork.conf"); Dir = $d }
        }
    }
    return $res
}

# ihwt-load-profile DH LOADDIR DAYS PROCS [RWAUTH] - AGGREGATED counts only (no
# raw log line leaves the host). Same files as ihwt_load_profile (bash); no
# sar on Windows (host_sar.csv missing = "not collected").
function ihwt-load-profile {
    param([string] $DH, [string] $Load, [int] $Days, $Procs, [string] $RwAuth = "")
    New-Item -ItemType Directory -Path $Load -Force | Out-Null
    $cut = (Get-Date).AddDays(-$Days).ToString('yyyy-MM-dd'); $since = (Get-Date).AddDays(-$Days)
    $logsOf = { param($pat)
        @(Get-ChildItem -LiteralPath (Join-Path $DH "servers") -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $pat } |
          ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_.FullName "logs") -File -Filter "access.log*" -ErrorAction SilentlyContinue } |
          Where-Object { $_.LastWriteTime -ge $since } | Sort-Object FullName) }
    $readLines = { param($f)
        if ($f.Name -like '*.gz') {
            $fs = [IO.File]::OpenRead($f.FullName); $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
            $sr = New-Object IO.StreamReader($gz); while ($null -ne ($ln = $sr.ReadLine())) { $ln }; $sr.Close()
        } else { [IO.File]::ReadLines($f.FullName) } }
    # ELF access log: field positions from the #Fields header
    $elf = { param($files, $onRow)
        # field positions carry over to the next file like in the bash stream (a
        # rotated WebLogic access log has no own #Fields header)
        $dI = $tI = $uI = $sI = $ttI = -1
        foreach ($f in $files) {
            foreach ($ln in (& $readLines $f)) {
                if ($ln -like '#Fields:*') { $a = $ln -split '[ \t]+'; for ($i = 1; $i -lt $a.Count; $i++) { switch ($a[$i]) { 'date' { $dI = $i - 1 } 'time' { $tI = $i - 1 } 'cs-uri' { $uI = $i - 1 } 'sc-status' { $sI = $i - 1 } 'time-taken' { $ttI = $i - 1 } } }; continue }
                if ($ln -like '#*' -or $dI -lt 0 -or $uI -lt 0) { continue }
                $c = $ln -split '[ \t]+'; if ($c.Count -le [math]::Max($dI, $uI)) { continue }
                $d = $c[$dI]; if ($d -notmatch '^\d{4}-' -or $d -lt $cut) { continue }
                & $onRow $d $(if ($tI -ge 0 -and $c.Count -gt $tI) { $c[$tI].Substring(0, [math]::Min(2, $c[$tI].Length)) } else { "" }) $c[$uI] $(if ($sI -ge 0 -and $c.Count -gt $sI) { $c[$sI] } else { "" }) $(if ($ttI -ge 0 -and $c.Count -gt $ttI) { $c[$ttI] } else { "" })
            } } }
    # --- Forms
    $fl = & $logsOf '*FORMS*'
    if ($fl.Count) {
        $starts = @{}; $hour = @{}; $ls = @{}; $req = @{}; $e5 = @{}; $tt = @{}; $tn = @{}
        & $elf $fl { param($d, $h, $u, $st, $t)
            if ($u -match '/frmservlet' -and $st -match '^2') { $c = "default"; if ($u -match '[?&]config=([^&]+)') { $c = $Matches[1] }; $c = $c -replace '[;\t ]', '_'
                $starts["$d;$c"] = 1 + $(if ($starts.ContainsKey("$d;$c")) { $starts["$d;$c"] } else { 0 }); $hour[$h] = 1 + $(if ($hour.ContainsKey($h)) { $hour[$h] } else { 0 }) }
            if ($u -match '/lservlet') { $ls[$d] = 1 + $(if ($ls.ContainsKey($d)) { $ls[$d] } else { 0 }) }
            $req[$d] = 1 + $(if ($req.ContainsKey($d)) { $req[$d] } else { 0 })
            if ($st -match '^5') { $e5[$d] = 1 + $(if ($e5.ContainsKey($d)) { $e5[$d] } else { 0 }) }
            if ($t -match '^[0-9.]+$') { $tt[$d] = [double]$t + $(if ($tt.ContainsKey($d)) { $tt[$d] } else { 0 }); $tn[$d] = 1 + $(if ($tn.ContainsKey($d)) { $tn[$d] } else { 0 }) } }
        if ($starts.Count) { ihwt-write-file (Join-Path $Load "forms_starts.csv") @($starts.Keys | ForEach-Object { "$_;$($starts[$_])" }) }
        if ($hour.Count) { ihwt-write-file (Join-Path $Load "forms_hourly.csv") @($hour.Keys | ForEach-Object { "$_;$($hour[$_])" }) }
        if ($req.Count) { ihwt-write-file (Join-Path $Load "forms_traffic.csv") @($req.Keys | ForEach-Object {
            "{0};{1};{2};{3};{4}" -f $_, $req[$_], $(if ($ls.ContainsKey($_)) { $ls[$_] } else { 0 }), $(if ($e5.ContainsKey($_)) { $e5[$_] } else { 0 }), $(if ($tn.ContainsKey($_)) { "{0:0}" -f (1000 * $tt[$_] / $tn[$_]) } else { "-" }) }) }
        ihwt-write-file (Join-Path $Load "forms_logfiles.txt") @($fl | ForEach-Object { $_.FullName.Replace($DH, '$DOMAIN_HOME') })
    }
    $frm = @($Procs | Where-Object { $_.Name -match '^frmweb(\.exe)?$' }); $ws = @($frm | ForEach-Object { [long]$_.WorkingSetSize })
    $now = @("frmweb_count=$($frm.Count)",
             "frmweb_rss_avg_mb=$(if ($ws.Count) { [math]::Floor(($ws | Measure-Object -Sum).Sum / $ws.Count / 1MB) } else { 0 })",
             "frmweb_rss_max_mb=$(if ($ws.Count) { [math]::Floor(($ws | Measure-Object -Maximum).Maximum / 1MB) } else { 0 })",
             "frmweb_rss_total_mb=$(if ($ws.Count) { [math]::Floor(($ws | Measure-Object -Sum).Sum / 1MB) } else { 0 })")
    # --- Reports: servlet requests per day and command
    $rl = & $logsOf '*REPORTS*'
    if ($rl.Count) {
        $r = @{}; $e = @{}
        & $elf $rl { param($d, $h, $u, $st, $t)
            if ($u -notmatch '/rwservlet') { return }
            $c = ($u -replace '^.*/rwservlet/?', '') -replace '[?;].*$', ''; if (-not $c) { $c = "(report run)" }; $c = $c -replace '[0-9]+$', ''
            $k = "$d;$c"; $r[$k] = 1 + $(if ($r.ContainsKey($k)) { $r[$k] } else { 0 }); if ($st -match '^5') { $e[$k] = 1 + $(if ($e.ContainsKey($k)) { $e[$k] } else { 0 }) } }
        if ($r.Count) { ihwt-write-file (Join-Path $Load "reports_requests.csv") @($r.Keys | ForEach-Object { "$_;$($r[$_]);$(if ($e.ContainsKey($_)) { $e[$_] } else { 0 })" }) }
    }
    $now += "rwengine_count=$(@($Procs | Where-Object { "$($_.CommandLine)" -match 'RWEngine|rwEng-[0-9]' }).Count)"
    # --- Reports: getserverinfo + past jobs of every RUNNING server (POST, authid never in a URL)
    $port = "9002"; $x = $null; try { [xml]$x = [IO.File]::ReadAllText((ihwt-jp @($DH, "config", "config.xml"))) } catch { }
    if ($x) { foreach ($s in @($x.domain.server)) { if ("$($s.name)" -match 'REPORTS' -and $s.PSObject.Properties['listen-port']) { $port = "$($s.'listen-port')"; break } } }
    $url = "http://127.0.0.1:$port/reports/rwservlet"; $nc = @(); $jobs = @()
    foreach ($rs in @(ihwt-rs-list $DH | Where-Object { $_.Type -ne 'servlet' } | ForEach-Object { $_.Name } | Sort-Object -Unique)) {
        if (-not @($Procs | Where-Object { "$($_.CommandLine)" -match "rwserver.*\bserver=$([regex]::Escape($rs))(\s|$)" }).Count) { continue }
        $body = @{ server = $rs; statusformat = "XML" }; if ($RwAuth) { $body.authid = $RwAuth }
        $siXml = $null; $code = "-"
        try { $resp = Invoke-WebRequest -Uri "$url/getserverinfo" -Method Post -Body $body -UseBasicParsing -TimeoutSec 60; $siXml = $resp.Content; $code = $resp.StatusCode }
        catch { $code = $(if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "- ($($_.Exception.Message))" }) }
        if ("$siXml" -notmatch '<serverInfo') { $nc += "$rs;getserverinfo;HTTP $code - no serverInfo (secured server: -RwAuth USER)"; continue }
        ihwt-write-file (Join-Path $Load "reports_${rs}_serverinfo.xml") $siXml
        $body.queuetype = "past"; $body.count = "1000"; $sj = ""
        try { $sj = (Invoke-WebRequest -Uri "$url/showjobs" -Method Post -Body $body -UseBasicParsing -TimeoutSec 60).Content } catch { }
        $ep = { param($t) try { [long]([datetimeoffset]([datetime]::ParseExact($t, 'MMM d, yyyy, h:mm:ss/tt', [Globalization.CultureInfo]::InvariantCulture))).ToUnixTimeSeconds() } catch { "" } }
        foreach ($m in [regex]::Matches("$sj", '<job [\s\S]*?</job>')) { $j = $m.Value
            $id = if ($j -match '<job id="([^"]*)"') { $Matches[1] } else { "-" }
            $n = if ($j -match '<name>([^<]*)</name>') { $Matches[1] -replace ';', '_' } else { "-" }
            $c = if ($j -match '<status code="(\d+)"') { $Matches[1] } else { "-" }
            $sr = if ($j -match '<started>([^<]*)</started>') { $Matches[1] } else { "" }; $fr = if ($j -match '<finished>([^<]*)</finished>') { $Matches[1] } else { "" }
            $st = if ($sr) { & $ep $sr } else { "" }; $fi = if ($fr) { & $ep $fr } else { "" }
            $jobs += ("{0};{1};{2};{3};{4};{5};{6};{7}" -f $rs, $id, $n, $c, $st, $(if ($st -ne "" -and $fi -ne "") { $fi - $st } else { "" }), ($sr -replace ';', ','), ($fr -replace ';', ',')) }
    }
    $RwAuth = ""
    if ($nc.Count) { ihwt-write-file (Join-Path $Load "reports_not_collected.txt") $nc }
    if ($jobs.Count) { ihwt-write-file (Join-Path $Load "reports_jobs.csv") $jobs }
    $up = ""
    if ($IHWT_ON_WINDOWS) { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue; if ($os) { $up = "up {0:%d} days, {0:%h} hours" -f ((Get-Date) - $os.LastBootUpTime) } }
    else { $up = (& uptime -p 2>$null) }
    $now += "uptime=$up"; $now += "loadavg=$(if ($IHWT_ON_WINDOWS) { 'n/a (Windows)' } elseif (Test-Path /proc/loadavg) { ((Get-Content /proc/loadavg) -split ' ')[0..2] -join ' ' })"; $now += "load_days=$Days"
    ihwt-write-file (Join-Path $Load "now.txt") $now
}

#------------------------------------------------------------------------------
# Licence indicators (80-FMW-Architecture/fmw_forms_reports_licence.md) - NO
# licence statement. Same lines as ihwt_wls_basic / ihwt_licence_host (bash):
#   context;<key>;<value>
#   deployment;<name>;<module-type>;<order|->;<targets>;<in_oracle_home>
#   library;<name>;<targets>;<in_oracle_home>
#   indicator;<key>;<object>;<value>
#   host;<key>;<value>
#------------------------------------------------------------------------------
function _ihwt-child { param($n, [string] $t) if (-not $n) { return "" }; $c = $n.SelectSingleNode("*[local-name()='$t']"); if ($c) { return "$($c.InnerText)" }; return "" }
function ihwt-wls-basic {
    param([string] $DH, [string] $OH = "")
    $cf = ihwt-jp @($DH, "config", "config.xml")
    if (-not (Test-Path -LiteralPath $cf -PathType Leaf)) { return @() }
    $x = $null; try { [xml]$x = [IO.File]::ReadAllText($cf) } catch { return @("context;config_xml;not readable") }
    $ohf = (ihwt-fwd $OH).TrimEnd('/')
    $inoh = { param([string] $p) if (-not $p) { return "-" }
        $f = ihwt-fwd $p
        if ($f -notmatch '^(/|[A-Za-z]:/|//)') { return "yes (relative)" }
        if ($ohf -and $f.StartsWith("$ohf/", $(if ($IHWT_ON_WINDOWS) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) { return "yes" }
        return "no" }
    $out = New-Object System.Collections.Generic.List[string]
    $prod = ""; $smode = ""; $aport = ""
    foreach ($n in @($x.DocumentElement.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
        $t = $n.LocalName; $nm = _ihwt-child $n 'name'; if (-not $nm) { $nm = "-" }
        switch ($t) {
            'production-mode-enabled'     { $prod = $n.InnerText }
            'administration-port-enabled' { $aport = $n.InnerText }
            'cluster-constraints-enabled' { if ($n.InnerText -eq 'true') { $out.Add("indicator;cluster_constraints;domain;true") } }
            'security-configuration'      { $s = $n.SelectSingleNode("*[local-name()='secure-mode']"); if ($s) { $v = _ihwt-child $s 'secure-mode-enabled'; if ($v) { $smode = $v } } }
            'app-deployment' {
                $mt = _ihwt-child $n 'module-type'; $od = _ihwt-child $n 'deployment-order'; $tg = _ihwt-child $n 'target'
                $out.Add(("deployment;{0};{1};{2};{3};{4}" -f $nm, $(if ($mt) { $mt } else { "-" }), $(if ($od) { $od } else { "-" }), $(if ($tg) { $tg } else { "-" }), (& $inoh (_ihwt-child $n 'source-path'))))
                if ($mt -in @('jdbc', 'jms', 'wldf')) { $out.Add("indicator;module_deployment;$nm;$mt") }
            }
            'library' {
                $tg = _ihwt-child $n 'target'
                $out.Add(("library;{0};{1};{2}" -f $nm, $(if ($tg) { $tg } else { "-" }), (& $inoh (_ihwt-child $n 'source-path'))))
                if ($nm.ToLower() -like 'pubsub*') { $out.Add("indicator;http_pubsub;$nm;-") }
            }
            { $_ -in @('server', 'cluster', 'migratable-target') } {
                $sm = _ihwt-child $n 'startup-mode'
                if ($t -eq 'server' -and $sm.ToUpper() -in @('ADMIN', 'STANDBY')) { $out.Add("indicator;server_startup_mode;$nm;$($sm.ToUpper())") }
                if ($t -eq 'server' -and (_ihwt-child $n 'auto-migration-enabled') -eq 'true') { $out.Add("indicator;auto_migration;$nm;true") }
                $ct = _ihwt-child $n 'cluster-type'; if ($t -eq 'cluster' -and $ct -in @('man', 'wan')) { $out.Add("indicator;cluster_type;$nm;$ct") }
                if ($t -eq 'cluster' -and (_ihwt-child $n 'migration-basis') -eq 'consensus') { $out.Add("indicator;migration_basis;$nm;consensus") }
                $mp = _ihwt-child $n 'migration-policy'; if ($t -eq 'migratable-target' -and $mp -and $mp -ne 'manual') { $out.Add("indicator;migration_policy;$nm;$mp") }
                $op = $n.SelectSingleNode("*[local-name()='overload-protection']")
                if ($op -and $t -ne 'migratable-target') {
                    $ov = @(foreach ($a in @('failure-action', 'panic-action')) { $v = _ihwt-child $op $a; if ($v -and $v -ne 'no-action') { "$a=$v" } }) -join ' '
                    if ($ov) { $out.Add("indicator;overload_protection;$nm;$ov") }
                }
            }
            'self-tuning'           { foreach ($w in @($n.SelectNodes("*[local-name()='work-manager']"))) { $out.Add("indicator;global_work_manager;$(_ihwt-child $w 'name');-") } }
            'snmp-agent'            { if ((_ihwt-child $n 'enabled') -eq 'true') { $out.Add("indicator;snmp_agent;domain;enabled") } }
            'snmp-agent-deployment' { $out.Add("indicator;snmp_agent;$nm;deployment") }
            'singleton-service'     { $out.Add("indicator;singleton_service;$nm;-") }
            'saf-agent'             { $out.Add("indicator;saf_agent;$nm;-") }
            'wtc-server'            { $out.Add("indicator;wtc_server;$nm;-") }
            'wldf-system-resource'  { if ($nm -notlike 'Module-FMWDFW*') { $out.Add("indicator;wldf_resource;$nm;-") } }
        }
    }
    $out.Add("context;production_mode;$(if ($prod) { $prod } else { 'not set' })")
    $out.Add("context;secure_mode;$(if ($smode) { $smode } else { 'not set' })")
    $out.Add("context;admin_port_domain;$(if ($aport) { $aport } else { 'not set' })")
    if ($aport -eq 'true') { $out.Add("indicator;admin_port_domain;domain;true") }
    foreach ($f in @(Get-ChildItem -LiteralPath (ihwt-jp @($DH, "config", "jdbc")) -Filter '*-jdbc.xml' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $tx = [IO.File]::ReadAllText($f.FullName)
        if ($tx -match '<fan-enabled>true</fan-enabled>|<ons-node-list>[^<]+</ons-node-list>|<active-gridlink>true') { $out.Add("indicator;active_gridlink;$($f.Name);fan / ons") }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath (ihwt-jp @($DH, "config", "jms")) -Filter '*.xml' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $tx = [IO.File]::ReadAllText($f.FullName)
        if ($tx -match '<default-unit-of-order>[^<]*</default-unit-of-order>' -and $tx -notmatch '<default-unit-of-order>None</default-unit-of-order>') { $out.Add("indicator;jms_unit_of_order;$($f.Name);-") }
        if ($tx -match '<unit-of-work-handling-policy>' -and $tx -notmatch '<unit-of-work-handling-policy>PassThrough<') { $out.Add("indicator;jms_unit_of_work;$($f.Name);-") }
    }
    return $out.ToArray()
}
# ihwt-db-edition DB_HOME - edition chosen at the installation (EE, SE2, SE ...)
# from inventory/globalvariables/oracle.server/globalvariables.xml; "" = no DB home
function ihwt-db-edition {
    param([string] $H)
    $f = ihwt-jp @($H, "inventory", "globalvariables", "oracle.server", "globalvariables.xml")
    $m = Select-String -LiteralPath $f -Pattern 'NAME="oracle_install_db_InstallEdition"[^>]*VALUE="([^"]*)"' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }; return ""
}
# ihwt-licence-host OH DH PROCS - CPU, virtualization, database instances,
# ORDS processes, WebLogic domains of the home
function ihwt-licence-host {
    param([string] $OH = "", [string] $DH = "", $Procs = $null)
    if ($null -eq $Procs) { $Procs = ihwt-procs }
    $so = ""; $co = ""; $th = ""; $mo = ""; $vi = ""; $pr = ""; $db = ""
    if ($IHWT_ON_WINDOWS) {
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)
        if ($cpu.Count) {
            $so = $cpu.Count; $co = ($cpu | Measure-Object NumberOfCores -Sum).Sum
            $lp = ($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum; if ($co) { $th = [math]::Round($lp / $co) }
            $mo = "$($cpu[0].Name)".Trim()
        }
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs) {
            $pr = "$($cs.Manufacturer) $($cs.Model)".Trim()
            $vi = switch -regex ($pr) { 'VMware' { 'vmware' } 'Microsoft Corporation Virtual' { 'microsoft (Hyper-V)' } 'QEMU|KVM' { 'kvm' } 'Xen' { 'xen' } 'VirtualBox|innotek' { 'oracle (VirtualBox)' } 'Amazon EC2' { 'amazon' } 'Google' { 'google' } default { if ($cs.PSObject.Properties['HypervisorPresent'] -and $cs.HypervisorPresent) { 'hypervisor present' } else { 'none' } } }
        }
        $db = @(Get-Service -Name 'OracleService*' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name -replace '^OracleService', '' } | Sort-Object) -join ','
    } else {
        $ls = (& lscpu 2>$null) -join "`n"
        if ($ls -match '(?m)^Socket\(s\):\s*(\d+)') { $so = $Matches[1] }
        if ($ls -match '(?m)^Core\(s\) per socket:\s*(\d+)') { $co = $Matches[1]; if ($so) { $co = [int]$so * [int]$co } }
        if ($ls -match '(?m)^Thread\(s\) per core:\s*(\d+)') { $th = $Matches[1] }
        if ($ls -match '(?m)^Model name:\s*(.+)$') { $mo = $Matches[1].Trim() }
        $vi = "$(& systemd-detect-virt 2>$null)".Trim()
        if (-not $vi -and $ls -match '(?m)^Hypervisor vendor:\s*(.+)$') { $vi = $Matches[1].Trim().ToLower() }
        try { $pr = ([IO.File]::ReadAllText('/sys/class/dmi/id/product_name')).Trim() } catch { }
        $db = @($Procs | ForEach-Object { if ("$($_.CommandLine)" -match '^ora_pmon_(.+)$') { $Matches[1].Trim() } } | Sort-Object -Unique) -join ','
    }
    # public cloud (same markers as cloud-init / bash ihwt_cloud): chassis
    # asset tag OracleCloud.com = OCI, 7783-7084-3265-9085-8269-3286-77 = Azure,
    # vendor / BIOS Amazon EC2 = AWS, product Google Compute Engine = GCP
    $at = ""; $sv = ""; $bv = ""; $pn = ""; $ar = ""
    if ($IHWT_ON_WINDOWS) {
        $en = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1; if ($en) { $at = "$($en.SMBIOSAssetTag)".Trim() }
        if ($cs) { $sv = "$($cs.Manufacturer)"; $pn = "$($cs.Model)" }
        $bi = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1; if ($bi) { $bv = "$($bi.Manufacturer) $($bi.SMBIOSBIOSVersion)" }
        $ar = "$env:PROCESSOR_ARCHITECTURE"
    } else {
        foreach ($k in 'chassis_asset_tag', 'sys_vendor', 'product_name', 'bios_version', 'bios_vendor') {
            $v = ""; try { $v = ([IO.File]::ReadAllText("/sys/class/dmi/id/$k")).Trim() } catch { }
            switch ($k) { 'chassis_asset_tag' { $at = $v } 'sys_vendor' { $sv = $v } 'product_name' { $pn = $v } default { $bv = "$bv $v" } }
        }
        $ar = "$(& uname -m 2>$null)".Trim()
    }
    $cl = $(if ($at -match 'OracleCloud') { 'oci' } elseif ($at -eq '7783-7084-3265-9085-8269-3286-77') { 'azure' } elseif ("$sv $bv" -cmatch 'Amazon EC2|amazon') { 'aws' } elseif ($pn -match 'Google Compute Engine') { 'gcp' } else { 'none' })
    # edition chosen at the installation of each database home (no database
    # login): running instance -> home (Linux /proc/<pmon>/exe, Windows the
    # image path of the OracleService<SID> service), plus every home of the inventory
    $ed = New-Object System.Collections.Generic.List[string]
    if ($IHWT_ON_WINDOWS) {
        foreach ($sv in @(Get-CimInstance Win32_Service -Filter "Name LIKE 'OracleService%'" -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } | Sort-Object Name)) {
            $sid = $sv.Name -replace '^OracleService', ''; $hm = ""
            if ("$($sv.PathName)" -match '^"?(.+?)[\\/]bin[\\/]oracle\.exe') { $hm = $Matches[1] }
            $e = $(if ($hm) { ihwt-db-edition $hm } else { "" })
            $ed.Add("host;oracle_db_edition;$sid=$(if ($e) { $e } else { 'unknown' }) ($(if ($hm) { $hm } else { 'path not readable' }))")
        }
        $inv = ""; try { $inv = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Oracle" -Name inst_loc -ErrorAction Stop).inst_loc } catch { }
    } else {
        foreach ($p in @($Procs | Where-Object { "$($_.CommandLine)" -match '^ora_pmon_' } | Sort-Object ProcessId)) {
            $sid = "$($p.CommandLine)" -replace '^ora_pmon_', ''; $sid = $sid.Trim(); $exe = "$($p.ExecutablePath)"
            if ($exe) { $hm = $exe -replace '/bin/oracle$', ''; $e = ihwt-db-edition $hm } else { $hm = "(not readable as $([Environment]::UserName))"; $e = "" }
            $ed.Add("host;oracle_db_edition;$sid=$(if ($e) { $e } else { 'unknown' }) ($hm)")
        }
        $inv = ""; $m = Select-String -LiteralPath /etc/oraInst.loc -Pattern '^inventory_loc=(.*)$' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($m) { $inv = $m.Matches[0].Groups[1].Value.Trim() }
    }
    if ($inv) {
        foreach ($m in @(Select-String -LiteralPath (ihwt-jp @($inv, "ContentsXML", "inventory.xml")) -Pattern '<HOME ' -ErrorAction SilentlyContinue | Where-Object { $_.Line -notmatch 'REMOVED="T"' })) {
            if ($m.Line -match ' LOC="([^"]*)"') { $h = $Matches[1]; $e = ihwt-db-edition $h; if ($e) { $ed.Add("host;oracle_db_home;$h=$e") } }
        }
    }
    $od = @($Procs | Where-Object { "$($_.CommandLine)" -match 'ords\.war|ords\s+serve|oracle\.dbtools\.launcher' } | ForEach-Object { $_.ProcessId }) -join ','
    $dm = ""
    if ($OH -and (Test-Path -LiteralPath (Join-Path $OH "domain-registry.xml"))) {
        $dm = @(Select-String -LiteralPath (Join-Path $OH "domain-registry.xml") -Pattern 'location="([^"]*)"' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value }) -join ','
    }
    return @("host;cpu_sockets;$(if ($so) { $so } else { '-' })",
             "host;cpu_cores;$(if ($co) { $co } else { [Environment]::ProcessorCount })",
             "host;cpu_threads_per_core;$(if ($th) { $th } else { '-' })",
             "host;cpu_model;$(if ($mo) { $mo } else { '-' })",
             "host;virtualization;$(if ($vi) { $vi } else { 'none' })",
             "host;product_name;$(if ($pr) { $pr } else { '-' })",
             "host;cpu_arch;$(if ($ar) { $ar } else { '-' })",
             "host;cloud;$cl",
             "host;oracle_db_instances;$(if ($db) { $db } else { 'none' })") + $ed.ToArray() + @(
             "host;ords_process;$(if ($od) { $od } else { 'none' })",
             "host;wls_domains;$(if ($dm) { $dm } elseif ($DH) { $DH } else { '-' })")
}

# ihwt-realpath P - resolved path (Linux: readlink -f, Windows: full path)
function ihwt-realpath {
    param([string] $P)
    if (-not $IHWT_ON_WINDOWS) { $r = "$(& readlink -f $P 2>$null)".Trim(); if ($r) { return $r } }
    try { return [IO.Path]::GetFullPath($P).TrimEnd('\', '/') } catch { return $P }
}

# ihwt-java4shell OH DH PROCS - Java4Shell (CVE-2026-114938, Base64 intrinsic of
# HotSpot, AVX-512 VBMI path) facts, read-only - the lines of bash ihwt_java4shell:
#   java4shell;cpu;<model>;avx512f=y|n|? avx512bw=.. avx512vbmi=.. bmi2=..;vulnerable=yes|no|unknown;source=jvm|dotnet|win32|cpuinfo
#   java4shell;bundled_jdk;<version>;affected|not-affected|java8|none
#   java4shell;reports_sh;<reports.bat / reports.cmd / reports.sh | ENV(Machine)>;flag=yes|no|no-file
#   java4shell;engine;<rwserver.conf>;<engine id>;flag=yes|no
#   java4shell;process;<pid>;<name>;<binary>;flag=yes|no|unknown
# CPU: Windows has no API for AVX-512 BW / VBMI -> asked from the bundled JVM
# (java -Xlog:os+cpu, Java 11+: the features the OS really enables), else .NET 8
# (PowerShell 7.4+: System.Runtime.Intrinsics.X86), else IsProcessorFeaturePresent
# (only AVX-512 F, the rest "?"). Native rwserver.exe: environment of another
# process not readable on Windows -> flag=unknown.
function ihwt-java4shell {
    param([string] $OH, [string] $DH, $Procs)
    $out = New-Object System.Collections.Generic.List[string]
    $bjdir = ""; $bjx = ""; $v = ""; $m = 0
    if ($OH) {
        $bjdir = ihwt-jp @($OH, "oracle_common", "jdk")
        foreach ($j in @((ihwt-jp @($bjdir, "bin", "java.exe")), (ihwt-jp @($bjdir, "bin", "java")))) { if (Test-Path -LiteralPath $j -PathType Leaf) { $bjx = $j; break } }
    }
    if ($bjx) {
        $vl = "$(((ihwt-exec $bjx @("-version") -TimeoutSec 60).Out -split "`n") | Select-Object -First 1)"
        if ($vl -match '"([0-9][^"]*)"') { $v = $Matches[1] }
        $pp = $v -split '[._-]'; if ($pp[0] -eq '1') { $m = [int]$pp[1] } elseif ($pp[0] -match '^\d+$') { $m = [int]$pp[0] }
    }
    # --- CPU ---
    $f = [ordered]@{ avx512f = '?'; avx512bw = '?'; avx512vbmi = '?'; bmi2 = '?' }; $src = ""
    if ($bjx -and $m -ge 11) {
        $cl = "$(((ihwt-exec $bjx @("-Xlog:os+cpu", "-version") -TimeoutSec 60).Out -split "`n") | Where-Object { $_ -match '\[os,cpu\] CPU:' } | Select-Object -First 1)"
        if ($cl) {
            $tok = @($cl -split ',\s*' | ForEach-Object { $_.Trim() })
            $f.avx512f = $(if ($tok -contains 'avx512f') { 'y' } else { 'n' })
            $f.avx512bw = $(if ($tok -contains 'avx512bw') { 'y' } else { 'n' })
            $f.avx512vbmi = $(if ($tok -contains 'avx512_vbmi' -or $tok -contains 'avx512vbmi') { 'y' } else { 'n' })
            $f.bmi2 = $(if ($tok -contains 'bmi2') { 'y' } else { 'n' })
            $src = "jvm"
        }
    }
    if (-not $src) {
        # types looked up by name - no type literals (Windows PowerShell 5.1 / .NET Framework has none of them)
        $ti = @{ avx512f = 'Avx512F'; avx512bw = 'Avx512BW'; avx512vbmi = 'Avx512Vbmi'; bmi2 = 'Bmi2' }
        if ([Type]::GetType('System.Runtime.Intrinsics.X86.Avx512Vbmi')) {
            foreach ($k in @($ti.Keys)) {
                $t = [Type]::GetType("System.Runtime.Intrinsics.X86.$($ti[$k])")
                $f[$k] = $(if ($t -and $t.GetProperty('IsSupported').GetValue($null)) { 'y' } else { 'n' })
            }
            $src = "dotnet"
        }
    }
    if (-not $src -and -not $IHWT_ON_WINDOWS -and (Test-Path -LiteralPath /proc/cpuinfo)) {
        $fl = @(((Get-Content -LiteralPath /proc/cpuinfo | Where-Object { $_ -match '^flags' } | Select-Object -First 1) -replace '^[^:]*:\s*', '') -split '\s+')
        foreach ($k in @($f.Keys)) { $f[$k] = $(if ($fl -contains $k) { 'y' } else { 'n' }) }
        $src = "cpuinfo"
    }
    if (-not $src -and $IHWT_ON_WINDOWS) {
        try {
            if (-not ('Ihwt.Cpu' -as [type])) { Add-Type -Namespace Ihwt -Name Cpu -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint f);' -ErrorAction Stop }
            $f.avx512f = $(if (('Ihwt.Cpu' -as [type])::IsProcessorFeaturePresent(41)) { 'y' } else { 'n' })   # PF_AVX512F_INSTRUCTIONS_AVAILABLE
            $src = "win32"
        } catch { $src = "none" }
    }
    $vals = @($f.Values)
    $vul = $(if ($vals -contains 'n') { 'no' } elseif ($vals -contains '?') { 'unknown' } else { 'yes' })
    $model = ""
    if ($IHWT_ON_WINDOWS) { $model = "$((Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name)".Trim() }
    elseif (Test-Path -LiteralPath /proc/cpuinfo) { $model = ((Get-Content -LiteralPath /proc/cpuinfo | Where-Object { $_ -match '^model name' } | Select-Object -First 1) -replace '^[^:]*:\s*', '') }
    $out.Add(("java4shell;cpu;{0};{1};vulnerable={2};source={3}" -f ($model -replace ';', ','), (($f.Keys | ForEach-Object { "$_=$($f[$_])" }) -join ' '), $vul, $src))
    # --- bundled JDK (range of the Oracle / OpenJDK advisory 2026-11-17) ---
    if (-not $bjx) { $out.Add("java4shell;bundled_jdk;-;none") }
    else {
        $st = "not-affected"; $lo = ""; $fix = ""
        switch ($m) { 8 { $st = "java8" } 17 { $lo = "17.0.6"; $fix = "17.0.21.1" } 21 { $fix = "21.0.13.1" } 25 { $fix = "25.0.5.1" } 27 { $fix = "27.0.1.1" } }
        if ($fix) {
            $nv = { param($x) [version](((@($x -split '[^0-9]+' | Where-Object { $_ }) + @('0', '0', '0', '0'))[0..3]) -join '.') }
            $st = "affected"
            if ($lo -and (& $nv $v) -lt (& $nv $lo)) { $st = "not-affected" }
            if ((& $nv $v) -ge (& $nv $fix)) { $st = "not-affected" }
        }
        $out.Add(("java4shell;bundled_jdk;{0};{1}" -f $(if ($v) { $v } else { "?" }), $st))
    }
    # --- configuration ---
    if ($DH) {
        $rf = ""
        foreach ($n in @("reports.bat", "reports.cmd", "reports.sh")) { $c = ihwt-jp @($DH, "reports", "bin", $n); if (Test-Path -LiteralPath $c -PathType Leaf) { $rf = $c; break } }
        if ($rf) {
            $has = @(_ihwt-lines $rf | Where-Object { $_ -match '^\s*(set\s+|export\s+)?"?REPORTS_JVM_OPTIONS=' -and $_ -match 'UseBASE64Intrinsics' }).Count -gt 0
            $out.Add(("java4shell;reports_sh;{0};flag={1}" -f $rf, $(if ($has) { 'yes' } else { 'no' })))
        } else { $out.Add(("java4shell;reports_sh;{0};flag=no-file" -f (ihwt-jp @($DH, "reports", "bin", "reports.bat")))) }
        if ($IHWT_ON_WINDOWS) {
            $ev = [Environment]::GetEnvironmentVariable('REPORTS_JVM_OPTIONS', 'Machine')
            if ($ev) { $out.Add(("java4shell;reports_sh;ENV(Machine);flag={0}" -f $(if ($ev -match 'UseBASE64Intrinsics') { 'yes' } else { 'no' }))) }
        }
        $cfg = ihwt-jp @($DH, "config", "fmwconfig")
        foreach ($rc in @(Get-ChildItem -LiteralPath $cfg -Recurse -Filter rwserver.conf -File -ErrorAction SilentlyContinue)) {
            $txt = ""; try { $txt = [IO.File]::ReadAllText($rc.FullName) } catch { continue }
            foreach ($e in [regex]::Matches($txt, '<engine\s[^>]*jvmOptions="[^"]*"')) {
                $id = $(if ($e.Value -match '\sid="([^"]*)"') { $Matches[1] } else { "?" })
                $out.Add(("java4shell;engine;{0};{1};flag={2}" -f $rc.FullName, $id, $(if ($e.Value -match 'UseBASE64Intrinsics') { 'yes' } else { 'no' })))
            }
        }
    }
    # --- running processes on the bundled JDK + native Reports binaries ---
    if ($OH) {
        $bjf = (ihwt-fwd $bjdir).ToLower() + "/bin/java"; $rwf = (ihwt-fwd (ihwt-jp @($OH, "bin"))).ToLower() + "/rw"
        foreach ($p in @($Procs)) {
            $ex = (ihwt-fwd "$($p.ExecutablePath)").ToLower()
            $isj = $ex.StartsWith($bjf); $isn = $ex.StartsWith($rwf)
            if (-not ($isj -or $isn)) { continue }
            $cmd = "$($p.CommandLine)"
            $nm = $(if ($cmd -match 'oracle\.reports\.component=(\S+)') { $Matches[1] } else { [IO.Path]::GetFileNameWithoutExtension("$($p.ExecutablePath)") })
            $fg = "no"
            if ($cmd -match 'UseBASE64Intrinsics') { $fg = "yes" }
            elseif ($isn) {
                if ($IHWT_ON_WINDOWS) { $fg = "unknown" }
                else { try { if (([IO.File]::ReadAllText("/proc/$($p.ProcessId)/environ") -split "`0" | Where-Object { $_ -like 'REPORTS_JVM_OPTIONS=*' }) -match 'UseBASE64Intrinsics') { $fg = "yes" } } catch { $fg = "unknown" } }
            }
            $out.Add(("java4shell;process;{0};{1};{2};flag={3}" -f $p.ProcessId, $nm, $p.ExecutablePath, $fg))
        }
    }
    return $out
}

# ihwt-listen-ports - listening TCP ports, normalised (as bash ihwt_listen_ports):
# "port;<addr>;<port>;<scope>;<pid>;<process>", scope local / ip / all.
# Windows: Get-NetTCPConnection (every process visible); Linux: ss.
function ihwt-listen-ports {
    $items = New-Object System.Collections.Generic.List[object]
    if ($IHWT_ON_WINDOWS) {
        $pn = @{}; Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $pn[$_.Id] = $_.ProcessName }
        foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
            $items.Add(@{ a = ("$($c.LocalAddress)" -replace '%.*$', ''); p = [int]$c.LocalPort; pid = "$($c.OwningProcess)"; pn = $(if ($pn.ContainsKey([int]$c.OwningProcess)) { $pn[[int]$c.OwningProcess] } else { '-' }) })
        }
    } else {
        foreach ($l in @(& ss -ltnpH 2>$null)) {
            $f = ($l.Trim() -split '\s+'); if ($f.Count -lt 4) { continue }
            $la = $f[3]; $pr = $(if ($f.Count -ge 6) { $f[-1] } else { '' })
            if ($la -notmatch '^(.*):(\d+)$') { continue }
            $ad = $Matches[1] -replace '%[^\]]*', ''; $po = [int]$Matches[2]
            $pid_ = '-'; $pnm = '-'
            if ($pr -match 'pid=(\d+)') { $pid_ = $Matches[1]; if ($pr -match '"([^"]*)"') { $pnm = $Matches[1] } }
            $items.Add(@{ a = $ad; p = $po; pid = $pid_; pn = $pnm })
        }
    }
    $seen = @{}; $out = New-Object System.Collections.Generic.List[object]
    foreach ($i in $items) {
        $k = "$($i.a):$($i.p)"; if ($seen.ContainsKey($k)) { continue }; $seen[$k] = 1
        $sc = 'ip'
        if ($i.a -match '^(\*|0\.0\.0\.0|\[::\]|::|\[::ffff:0\.0\.0\.0\])$') { $sc = 'all' }
        elseif ($i.a -match '^(127\.|\[::1\]|::1$|\[::ffff:127\.)') { $sc = 'local' }
        $out.Add([pscustomobject]@{ a = $i.a; p = $i.p; line = ("port;{0};{1};{2};{3};{4}" -f $i.a, $i.p, $sc, $i.pid, $i.pn) })
    }
    $arr = $out.ToArray()
    [Array]::Sort($arr, [Comparison[object]] { param($x, $y) $d = $x.p.CompareTo($y.p); if ($d -ne 0) { return $d }; return [string]::CompareOrdinal($x.a, $y.a) })
    return @($arr | ForEach-Object { $_.line })
}

# ihwt-domains-find OH DH PROCS - the OTHER WebLogic domains of this host (top
# level, read-only), as bash ihwt_domains_find: domain-registry.xml and
# nodemanager.domains of OH and every inventory home, running servers
# (-Dweblogic.RootDirectory, -Ddomain.home, working directory on Linux),
# nodemanager.domains of DH and the sibling directories of DH; DH left out.
# IHWT_DOMAINS_EXTRA (tests only): additional candidates.
function ihwt-domains-find {
    param([string] $OH, [string] $DH, $Procs)
    $cand = New-Object System.Collections.Generic.List[string]
    $homes = New-Object System.Collections.Generic.List[string]
    if ($OH) { $homes.Add($OH) }
    $inv = ""
    if ($IHWT_ON_WINDOWS) { try { $inv = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Oracle" -Name inst_loc -ErrorAction Stop).inst_loc } catch { } }
    else { $m = Select-String -LiteralPath /etc/oraInst.loc -Pattern '^inventory_loc=(.*)$' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($m) { $inv = $m.Matches[0].Groups[1].Value.Trim() } }
    if ($inv) {
        foreach ($m in @(Select-String -LiteralPath (ihwt-jp @($inv, "ContentsXML", "inventory.xml")) -Pattern '<HOME ' -ErrorAction SilentlyContinue | Where-Object { $_.Line -notmatch 'REMOVED="T"' })) {
            if ($m.Line -match ' LOC="([^"]*)"') { $homes.Add($Matches[1]) }
        }
    }
    foreach ($h in @($homes | Sort-Object -Unique)) {
        foreach ($m in @(Select-String -LiteralPath (Join-Path $h "domain-registry.xml") -Pattern 'location="([^"]*)"' -AllMatches -ErrorAction SilentlyContinue)) { foreach ($x in $m.Matches) { $cand.Add($x.Groups[1].Value) } }
        foreach ($l in @(Get-Content -LiteralPath (ihwt-jp @($h, "oracle_common", "common", "nodemanager", "nodemanager.domains")) -ErrorAction SilentlyContinue)) { if ($l -match '^[^#=]*=(.*)$') { $cand.Add(($Matches[1] -replace '\\:', ':' -replace '\\\\', '\')) } }
    }
    foreach ($p in @($Procs)) {
        $c = "$($p.CommandLine)"
        if ($c -match '-Dweblogic\.RootDirectory=("?)([^" ]+)\1') { $cand.Add($Matches[2]) }
        if ($c -match '-Ddomain\.home=("?)([^" ]+)\1') { $cand.Add($Matches[2]) }
        if (-not $IHWT_ON_WINDOWS -and $c -match '-Dweblogic\.Name=') { $w = "$(& readlink -f "/proc/$($p.ProcessId)/cwd" 2>$null)".Trim(); if ($w) { $cand.Add($w) } }
    }
    if ($DH) {
        foreach ($l in @(Get-Content -LiteralPath (ihwt-jp @($DH, "nodemanager", "nodemanager.domains")) -ErrorAction SilentlyContinue)) { if ($l -match '^[^#=]*=(.*)$') { $cand.Add(($Matches[1] -replace '\\:', ':' -replace '\\\\', '\')) } }
        $par = Split-Path -Parent $DH
        if ($par) { foreach ($d in @(Get-ChildItem -LiteralPath $par -Directory -ErrorAction SilentlyContinue)) { $cand.Add($d.FullName) } }
    }
    if ($env:IHWT_DOMAINS_EXTRA) { foreach ($x in ($env:IHWT_DOMAINS_EXTRA -split '\s+')) { if ($x) { $cand.Add($x) } } }
    $rd = $(if ($DH) { ihwt-realpath $DH } else { "" })
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in $cand) {
        if (-not $c -or -not (Test-Path -LiteralPath (ihwt-jp @($c, "config", "config.xml")))) { continue }
        $r = ihwt-realpath $c
        if ($r -eq $rd -or $out.Contains($r)) { continue }
        $out.Add($r)
    }
    $a = [string[]]$out.ToArray(); [Array]::Sort($a, [StringComparer]::Ordinal); return $a
}

# ihwt-domain-product NAME - product of a deployment / server name (as bash)
function ihwt-domain-product {
    param([string] $Name)
    $n = ($Name -split '#')[0].ToLower()
    switch -regex ($n) {
        '^formsapp' { return 'Forms' } '^reports' { return 'Reports' }
        '^(xmlpserver|bipublisher)' { return 'BI Publisher' }
        '^(analytics|bimad|bi-|biee|bicomposer)' { return 'BI / Oracle Analytics' }
        '^(oam_server|oam_admin|oamsso)' { return 'OAM' } '^(oim|identity)' { return 'OIM' }
        '^(soa-infra|soa_server)' { return 'SOA' } '^ords' { return 'ORDS' } '^apex' { return 'APEX' }
        '^fads' { return 'FADS' } '^em$' { return 'Fusion Middleware Control' } '^wsm-pm' { return 'OWSM' }
    }
    return ''
}

# ihwt-domain-summary D PROCS - top level of one domain (same lines as bash
# ihwt_domain_summary): name, version, production mode, home / JAVA_HOME of
# setDomainEnv, servers (address, port, cluster, pid / java / -Xmx when
# running), deployments with targets, products
function ihwt-domain-summary {
    param([string] $D, $Procs)
    $cf = ihwt-jp @($D, "config", "config.xml")
    if (-not (Test-Path -LiteralPath $cf)) { return @() }
    $x = $null; try { $x = [xml](Get-Content -LiteralPath $cf -Raw) } catch { return @("domain;path;$D", "domain;name;unreadable config.xml") }
    $dm = $x.DocumentElement
    $r = New-Object System.Collections.Generic.List[string]
    $r.Add("domain;path;$D")
    $r.Add("domain;name;$(_ihwt-child $dm 'name')")
    $r.Add("domain;version;$(_ihwt-child $dm 'domain-version')")
    $r.Add("domain;production_mode;$(_ihwt-child $dm 'production-mode-enabled')")
    $sde = @((ihwt-jp @($D, "bin", "setDomainEnv.sh")), (ihwt-jp @($D, "bin", "setDomainEnv.cmd"))) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $wl = ""; $oh = ""; $jh = ""
    if ($sde) {
        $lines = @(Get-Content -LiteralPath $sde -ErrorAction SilentlyContinue)
        foreach ($l in $lines) { if (-not $wl -and $l -match '^\s*(export\s+|set\s+)?WL_HOME="?([^"$%]*)"?\s*$') { $wl = $Matches[2] } }
        if ($wl) { $oh = Split-Path -Parent $wl }
        if (-not $oh) { foreach ($l in $lines) { if (-not $oh -and $l -match '^\s*(export\s+|set\s+)?(MW_HOME|ORACLE_HOME)="?([^"$%]*)"?\s*$') { $oh = $Matches[3] } } }
        foreach ($l in $lines) { if ($l -match '^\s*(export\s+|set\s+)?JAVA_HOME="?([^"$%]*)"?\s*$') { $jh = $Matches[2] } }
    }
    # WebLogic plug-in enabled (web-app-container = domain, cluster, server), as bash
    $pe = New-Object System.Collections.Generic.List[string]
    foreach ($nd in @($dm.ChildNodes)) {
        if ($nd.NodeType -ne 'Element' -or $nd.LocalName -notin @('server', 'cluster', 'web-app-container')) { continue }
        $v = _ihwt-child $nd 'weblogic-plugin-enabled'
        if ($v) { $pe.Add(("{0}={1}" -f $(if ($nd.LocalName -eq 'web-app-container') { 'domain' } else { _ihwt-child $nd 'name' }), $v)) }
    }
    $r.Add("domain;weblogic_plugin_enabled;$(if ($pe.Count) { $pe -join ',' } else { 'not set' })")
    $r.Add("domain;oracle_home;$(if ($oh) { $oh } else { '-' })")
    $r.Add("domain;java_home;$(if ($jh) { $jh } else { '-' })")
    $wls = @($Procs | Where-Object { "$($_.CommandLine)" -match '-Dweblogic\.Name=' })
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($dm.SelectNodes("*[local-name()='server']"))) {
        $n = _ihwt-child $s 'name'; $names.Add($n)
        $a = _ihwt-child $s 'listen-address'; $p = _ihwt-child $s 'listen-port'; $cl = _ihwt-child $s 'cluster'
        $pid_ = ""; $ja = "-"; $xm = "-"
        foreach ($q in $wls) {
            $c = "$($q.CommandLine)"
            if ($c -notmatch ('-Dweblogic\.Name=' + [regex]::Escape($n) + '(\s|$)')) { continue }
            $hit = $c.Contains("=$D ") -or $c.Contains("=$D/") -or $c.Contains("=$D\") -or $c.Contains("$D/") -or $c.Contains("$D\")
            if (-not $hit -and -not $IHWT_ON_WINDOWS) { $hit = ("$(& readlink -f "/proc/$($q.ProcessId)/cwd" 2>$null)".Trim() -eq $D) }
            if ($hit) {
                $pid_ = "$($q.ProcessId)"
                $ja = $(if ($c -match '^"([^"]+)"') { $Matches[1] } else { ($c -split '\s+')[0] })
                $xa = @([regex]::Matches($c, '-Xmx[0-9]+[kKmMgG]?')); if ($xa.Count) { $xm = $xa[-1].Value }
                break
            }
        }
        $r.Add(("server;{0};{1};{2};{3};{4};{5};{6}" -f $n, $(if ($a) { $a } else { '-' }), $(if ($p) { $p } else { '7001' }), $(if ($cl) { $cl } else { '-' }), $(if ($pid_) { $pid_ } else { 'no' }), $ja, $xm))
    }
    foreach ($ad in @($dm.SelectNodes("*[local-name()='app-deployment']"))) { $an = _ihwt-child $ad 'name'; $names.Add($an); $r.Add("deployment;$an;$(_ihwt-child $ad 'target')") }
    $pr = @($names | ForEach-Object { ihwt-domain-product $_ } | Where-Object { $_ } | Sort-Object -Unique)
    $pa = [string[]]$pr; [Array]::Sort($pa, [StringComparer]::Ordinal)
    $r.Add("domain;products;$(if ($pa.Count) { $pa -join ',' } else { 'unknown' })")
    return $r.ToArray()
}

# ihwt-webgate DH - WebGate configured in the OHS instances of the domain (as
# bash ihwt_webgate): "webgate;<instance>;loaded=..;id=..;security=..;primary=..;cert_until=.."
# or "webgate;none;-" - names, mode, OAM server, certificate expiry, no passphrase
function ihwt-webgate {
    param([string] $DH)
    $root = $(if ($DH) { ihwt-jp @($DH, "config", "fmwconfig", "components", "OHS") } else { "" })
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return @("webgate;none;-") }
    $out = New-Object System.Collections.Generic.List[string]
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter ObAccessClient.xml -ErrorAction SilentlyContinue |
               Where-Object { ($_.FullName -replace '\\', '/') -match '/webgate/config/ObAccessClient\.xml$' -and ($_.FullName -replace '\\', '/') -notmatch '/lang/' } |
               Sort-Object { $_.FullName } -Culture ([Globalization.CultureInfo]::InvariantCulture))
    foreach ($f in $files) {
        $base = $f.Directory.Parent.Parent.FullName; $inst = Split-Path -Leaf $base
        if (($base -replace '\\', '/') -match '/instances/') { $inst = "instances/$inst" }
        $t = (Get-Content -LiteralPath $f.FullName -Raw) -replace "[\r\n]", ' '
        $kv = @{}
        foreach ($m in [regex]::Matches($t, 'ParamName="([^"]*)"\s+Value="([^"]*)"')) { $k = $m.Groups[1].Value.ToLower(); if (-not $kv.ContainsKey($k)) { $kv[$k] = $m.Groups[2].Value } }
        $ce = "-"
        foreach ($c in @(Get-ChildItem -LiteralPath (Join-Path $base (Join-Path "webgate" "config")) -Recurse -File -Filter aaa_cert.pem -ErrorAction SilentlyContinue)) {
            try { $x509 = [Security.Cryptography.X509Certificates.X509Certificate2]::new($c.FullName); $u = $x509.NotAfter.ToUniversalTime()
                  $ce = "{0} {1,2} {2} GMT" -f $u.ToString('MMM', [Globalization.CultureInfo]::InvariantCulture), $u.Day, $u.ToString('HH:mm:ss yyyy', [Globalization.CultureInfo]::InvariantCulture); break } catch { }
        }
        $ld = $(if (Select-String -LiteralPath (Join-Path $base "httpd.conf") -Pattern '^\s*include\s.*webgate\.conf' -Quiet -ErrorAction SilentlyContinue) { 'yes' } else { 'no' })
        $pri = $(if ($kv['host']) { "$($kv['host']):$($kv['port'])" } else { '' })
        $out.Add(("webgate;{0};loaded={1};id={2};security={3};primary={4};cert_until={5}" -f $inst, $ld, $(if ($kv['id']) { $kv['id'] } else { '-' }), $(if ($kv['security']) { $kv['security'] } else { '-' }), $pri, $ce))
    }
    if ($out.Count -eq 0) { return @("webgate;none;-") }
    return $out.ToArray()
}

# ihwt-security DH OH PROCS - security facts of the domain (as ihwt_security
#   of ihw_tools_lib.sh, same "security;key;..." lines). Windows: the mode
#   field is "acl" (readers beyond owner / SYSTEM / Administrators in field 7)
#   or "acl-world" (Users / Authenticated Users / Everyone may read = world-
#   readable); owner groups = local Administrators / ORA_DBA of this account,
#   db_on_host = a running OracleService*; umask n/a. Read-only, no values.
function _ihwt-sec-tag { param([string] $T, [string] $E) $m = [regex]::Match($T, "<(?:\w+:)?$E>([^<]*)"); if ($m.Success) { return $m.Groups[1].Value }; return "" }
function _ihwt-sec-file {
    param([string] $F, [string] $Label)
    if (-not (Test-Path -LiteralPath $F -PathType Leaf)) { return $null }
    if ($IHWT_ON_WINDOWS) {
        try {
            $acl = Get-Acl -LiteralPath $F
            $rd = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and ("$($_.FileSystemRights)" -match 'FullControl|Modify|Read') } | ForEach-Object { "$($_.IdentityReference)" } |
                    Where-Object { $_ -ne "$($acl.Owner)" -and $_ -notmatch '(?i)^(NT AUTHORITY\\SYSTEM|NT-AUTORIT.T\\SYSTEM|BUILTIN\\(Administrators|Administratoren)|CREATOR OWNER|ERSTELLER-BESITZER|NT SERVICE\\TrustedInstaller)$' } | Sort-Object -Unique)
            $weak = @($rd | Where-Object { $_ -match '(?i)\\Users$|Authenticated Users|Everyone|\\Benutzer$|Authentifizierte Benutzer|Jeder' })
            return ("security;file;{0};{1};{2};-;{3};{4}" -f $Label, $(if ($weak.Count) { 'acl-world' } else { 'acl' }), $acl.Owner, $(if ($rd.Count) { $rd -join ',' } else { '-' }), $F)
        } catch { return "security;file;$Label;unreadable;-;-;-;$F" }
    }
    $s = ((ihwt-exec "stat" @("-c", "%a;%U;%G", $F) -TimeoutSec 30).Out).Trim() -split ';'
    $mem = @()
    $ge = ((ihwt-exec "getent" @("group", $s[2]) -TimeoutSec 30).Out).Trim() -split ':'
    if ($ge.Count -ge 4 -and $ge[3]) { $mem += @($ge[3] -split ',') }
    if ($ge.Count -ge 3 -and $ge[2]) { $mem += @(((ihwt-exec "getent" @("passwd") -TimeoutSec 30).Out -split "`n") | Where-Object { ($_ -split ':')[3] -eq $ge[2] } | ForEach-Object { ($_ -split ':')[0] }) }
    $oth = @($mem | Where-Object { $_ -and $_ -ne $s[1] } | Sort-Object -Unique -Culture ([Globalization.CultureInfo]::InvariantCulture))
    return ("security;file;{0};{1};{2};{3};{4};{5}" -f $Label, $s[0], $s[1], $s[2], $(if ($oth.Count) { $oth -join ',' } else { '-' }), $F)
}
function ihwt-security {
    param([string] $DH, [string] $OH, $Procs)
    $c = ihwt-jp @($DH, "config", "config.xml")
    if (-not $DH -or -not (Test-Path -LiteralPath $c)) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    # owner and its groups
    if ($IHWT_ON_WINDOWS) {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent(); $pr = [Security.Principal.WindowsPrincipal]::new($id)
        $gn = @($id.Groups | ForEach-Object { try { $_.Translate([Security.Principal.NTAccount]).Value } catch { } })
        $ag = $(if ($pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Administrators' } else { 'none' })
        $dg = @($gn | Where-Object { $_ -match '(?i)\\ORA_.*DBA$|\\ORA_OPER$' } | ForEach-Object { ($_ -split '\\')[-1] })
        $db = $(if (@(Get-Service -Name 'OracleService*' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }).Count) { 'yes' } else { 'no' })
        $out.Add(("security;owner;{0};groups={1};admin_group={2};db_group={3};db_on_host={4}" -f $id.Name, ((@($gn | ForEach-Object { ($_ -split '\\')[-1] }) | Select-Object -First 20) -join ','), $ag, $(if ($dg.Count) { $dg -join ',' } else { 'none' }), $db))
    } else {
        $ow = ((ihwt-exec "stat" @("-c", "%U", $DH) -TimeoutSec 30).Out).Trim()
        $g = @(((ihwt-exec "id" @("-nG", $ow) -TimeoutSec 30).Out).Trim() -split '\s+')
        $ag = @($g | Where-Object { $_ -in @('wheel', 'sudo', 'admin') }); $dg = @($g | Where-Object { $_ -in @('dba', 'oper', 'backupdba', 'dgdba', 'kmdba', 'racdba') })
        $db = $(if (@($Procs | Where-Object { $_.CommandLine -match '^ora_pmon_' }).Count) { 'yes' } else { 'no' })
        $out.Add(("security;owner;{0};groups={1};admin_group={2};db_group={3};db_on_host={4}" -f $ow, ($g -join ','), $(if ($ag.Count) { $ag -join ',' } else { 'none' }), $(if ($dg.Count) { $dg -join ',' } else { 'none' }), $db))
    }
    # file modes / ACLs of the secrets
    $key = ihwt-jp @($DH, "security", "SerializedSystemIni.dat")
    if (Test-Path -LiteralPath $key) { $out.Add((_ihwt-sec-file $key "domain_key")) } else { $out.Add("security;file;domain_key;missing;-;-;-;$key") }
    $out.Add((_ihwt-sec-file $c "config.xml"))
    foreach ($f in @(Get-ChildItem -LiteralPath (ihwt-jp @($DH, "config", "jdbc")) -Filter *.xml -File -ErrorAction SilentlyContinue | Sort-Object Name -Culture ([Globalization.CultureInfo]::InvariantCulture))) { $out.Add((_ihwt-sec-file $f.FullName "jdbc")) }
    $n = 0; $cf = @()
    foreach ($f in @(Get-ChildItem -LiteralPath (ihwt-jp @($DH, "servers")) -Recurse -Filter boot.properties -File -ErrorAction SilentlyContinue | Sort-Object FullName -Culture ([Globalization.CultureInfo]::InvariantCulture))) {
        $p = $f.FullName -replace '\\', '/'
        $l = "boot.properties:" + $(if ($p -match '/servers/([^/]+)/') { $Matches[1] } else { '?' })
        if ($p -match '/data/nodemanager/') { $l += ":nm_cache" }
        $out.Add((_ihwt-sec-file $f.FullName $l)); $n++
        $t = Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        if (@($t | Where-Object { $_ -match '^\s*password\s*=' }).Count -and -not @($t | Where-Object { $_ -match '^\s*password\s*=\s*\{AES' }).Count) { $cf += $f.FullName }
    }
    $out.Add(("security;boot_properties;{0};cleartext={1};{2}" -f $n, $cf.Count, $(if ($cf.Count) { $cf -join ',' } else { '-' })))
    # realm
    $cx = ((Get-Content -LiteralPath $c -Raw) -replace "[\r\n]", '')
    $m = [regex]::Match($cx, '<(?:sec:)?user-lockout-manager>.*?</(?:sec:)?user-lockout-manager>')
    if (-not $m.Success) { $out.Add("security;lockout;enabled=default;threshold=default;duration=default;reset=default") }
    else { $v = $m.Value; $out.Add(("security;lockout;enabled={0};threshold={1};duration={2};reset={3}" -f @('lockout-enabled', 'lockout-threshold', 'lockout-duration', 'lockout-reset-duration' | ForEach-Object { $x = _ihwt-sec-tag $v $_; if ($x) { $x } else { 'default' } }))) }
    $m = [regex]::Match($cx, '<(?:sec:)?password-validator.*?</(?:sec:)?password-validator>')
    if (-not $m.Success) { $out.Add("security;password_validator;present=no") }
    else { $v = $m.Value; $out.Add(("security;password_validator;present=yes;min_length={0};upper={1};lower={2};numeric={3};special={4};numeric_or_special={5};reject_user={6}" -f @('min-password-length', 'min-uppercase-characters', 'min-lowercase-characters', 'min-numeric-characters', 'min-non-alphanumeric-characters', 'min-numeric-or-special-characters', 'reject-equal-or-contain-username' | ForEach-Object { $x = _ihwt-sec-tag $v $_; if ($x) { $x } else { '-' } }))) }
    $x = _ihwt-sec-tag $cx 'configuration-audit-type'; $out.Add("security;config_audit;$(if ($x) { $x } else { 'none' })")
    $out.Add("security;auditor;$(if ($cx -match '<(sec:)?auditor') { 'yes' } else { 'no' })")
    # OPSS audit of the default jpsContext
    $jc = ihwt-jp @($DH, "config", "fmwconfig", "jps-config.xml"); $ai = ""; $fp = ""
    if (Test-Path -LiteralPath $jc) {
        $jt = ((Get-Content -LiteralPath $jc -Raw) -replace "[\r\n]", '')
        $dc = [regex]::Match($jt, '<jpsContext name="default">.*?</jpsContext>').Value
        $ai = [regex]::Match($dc, 'serviceInstanceRef ref="(audit[^"]*)"').Groups[1].Value
        $si = [regex]::Match($jt, ('<serviceInstance name="{0}"[^>]*>.*?</serviceInstance>' -f [regex]::Escape($(if ($ai) { $ai } else { 'audit' })))).Value
        $fp = [regex]::Match($si, 'name="audit.filterPreset" value="([^"]*)"').Groups[1].Value
    }
    $out.Add(("security;opss_audit;instance={0};filterPreset={1}" -f $(if ($ai) { $ai } else { '-' }), $(if ($fp) { $fp } else { '-' })))
    # applications on the AdminServer besides the FMW infrastructure
    $infra = '^(em|opss-rest|DMS Application.*|state-management-provider.*|coherence-transaction-rar|wsm-pm|FMW Welcome Page Application.*|fmw-welcome.*|mds-.*|owsm-.*|jms-.*|wls-.*|bea_wls.*|ORDS.*-rest|sdpmessaging.*|usermessagingserver.*)$'
    $adm = @([regex]::Matches($cx, '<app-deployment>.*?</app-deployment>') | ForEach-Object { $nm = _ihwt-sec-tag $_.Value 'name'; $tg = _ihwt-sec-tag $_.Value 'target'
               if ((",$tg,") -match ',AdminServer,' -and $nm -notmatch $infra) { $nm } })
    $out.Add("security;admin_apps;$(if ($adm.Count) { $adm -join ',' } else { 'none' })")
    # further copies of the domain key below ORACLE_BASE / the domain parent
    $roots = @($(if ($env:ORACLE_BASE) { $env:ORACLE_BASE } else { Split-Path -Parent (Split-Path -Parent $DH) }), (Split-Path -Parent $DH)) | Where-Object { $_ } | Sort-Object -Unique
    $kc = @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -Depth 8 -Filter SerializedSystemIni.dat -File -ErrorAction SilentlyContinue } | ForEach-Object { $_.FullName } |
            Sort-Object -Unique -Culture ([Globalization.CultureInfo]::InvariantCulture) | Where-Object { $_ -ne $key })
    $out.Add("security;key_copies;$(if ($kc.Count) { $kc -join ',' } else { 'none' })")
    if ($IHWT_ON_WINDOWS) { $out.Add("security;umask;n/a;-") }
    else {
        $bp = Join-Path ((((ihwt-exec "getent" @("passwd", $ow) -TimeoutSec 30).Out).Trim() -split ':')[5]) ".bash_profile"
        $um = @(Get-Content -LiteralPath $bp -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*umask\s+[0-7]+' } | ForEach-Object { ($_.Trim() -split '\s+')[1] }) | Select-Object -Last 1
        $out.Add("security;umask;$(if ($um) { $um } else { 'none' });$bp")
    }
    # ORDS: ords.war of the running processes / domain deployments
    $wars = @(@($Procs | ForEach-Object { $cl = "$($_.CommandLine)"
                [regex]::Matches($cl, '[^\s="]*ords\.war') | ForEach-Object { $_.Value }
                $h = [regex]::Match($cl, '-Doracle\.dbtools\.cmdline\.home=("?)([^\s"]+)\1'); if ($h.Success) { Join-Path $h.Groups[2].Value "ords.war" } }) +
              @([regex]::Matches($cx, '<source-path>([^<]*ords[^<]*\.war)</source-path>') | ForEach-Object { $_.Groups[1].Value }) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | ForEach-Object { ihwt-realpath $_ } | Sort-Object -Unique -Culture ([Globalization.CultureInfo]::InvariantCulture))
    if (-not $wars.Count) { $out.Add("security;ords;none;-") }
    foreach ($w in $wars) {
        $ver = "?"
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $z = [IO.Compression.ZipFile]::OpenRead($w)
            $vs = @($z.Entries | ForEach-Object { $mm = [regex]::Match($_.FullName, '^WEB-INF/lib/ords-[a-z-]+-(\d+\.\d+\.\d+\.\d+\.\d+)\.jar$'); if ($mm.Success) { $mm.Groups[1].Value } })
            $z.Dispose()
            if ($vs.Count) { $ver = ($vs | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name }
        } catch { }
        $out.Add("security;ords;$w;$ver")
    }
    $out.Add("security;sudo;not-probed")
    return $out.ToArray()
}

#------------------------------------------------------------------------------
# ihwt-frmweb-dump FILE - one summary line of a Forms runtime dump
#   (frmweb_dump_<pid>, a TEXT stack trace frmweb writes itself on a crash)
#   the line of ihwt_frmweb_dump (bash):
#   frmweb_dump;<file>;<mtime>;<bytes>;<FORM.BLOCK.FIELD>;<last trigger>;
#               <kind signal|error>;<top frames a>b>c>;<call stack signature>
#------------------------------------------------------------------------------
function ihwt-frmweb-dump {
    param([string] $f)
    if (-not $f -or -not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null }
    $it = Get-Item -LiteralPath $f
    $fbf = ""; $lt = ""; $sig = ""; $fr = New-Object System.Collections.Generic.List[string]; $s = 0
    $text = ""
    try {
        $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
        try { $n = [math]::Min($fs.Length, 4MB); $buf = New-Object byte[] $n; [void]$fs.Read($buf, 0, $n); $text = [Text.Encoding]::ASCII.GetString($buf) } finally { $fs.Close() }
    } catch { $text = "" }
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match '^Last Trigger +FORM/BLOCK/FIELD:\s*(.*)$') { $fbf = $Matches[1]; continue }
        if ($l -match '^Last trigger:\s*(.*)$') { $lt = $Matches[1]; continue }
        if ($l -match '^Call stack signature:.*\s(\S+)\s*$') { $sig = $Matches[1]; continue }
        if ($l -match '^([A-Za-z_][A-Za-z0-9_$.]*)\(\)\+[0-9]+ +([a-z?]+) ') {
            $fr.Add($Matches[1]); if ($Matches[2] -eq 'signal' -and -not $s) { $s = $fr.Count }
        }
    }
    $kind = if ($s) { "signal" } else { "error" }
    $st = $s
    if (-not $st) {
        for ($i = 1; $i -le $fr.Count; $i++) {
            if ($fr[$i - 1] -notmatch '^(kgdsdst|skgudmp|ksedst|ksedmp|ksfdmp|dbgex|dbge|dbgr|kgerinv|kgeriv|kgerin|kgesin|kgesic|kgeasi|kgerev|kgersel|siehjmpterm|__sighandler|sighandler|ssexhd|sslss|skgesig)') { $st = $i; break }
        }
    }
    if (-not $st) { $st = 1 }
    $top = @(); for ($i = $st; $i -le $fr.Count -and $i -lt $st + 6; $i++) { $top += $fr[$i - 1] }
    $c = { param($v) if ($v) { $v -replace ';', ',' } else { "-" } }
    return ("frmweb_dump;{0};{1};{2};{3};{4};{5};{6};{7}" -f $f, $it.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $it.Length,
            (& $c $fbf), (& $c $lt), $(if ($fr.Count) { $kind } else { "-" }), (& $c ($top -join '>')), (& $c $sig))
}
