#==============================================================================
# Script   : ihw_tools_lib.ps1
# Purpose  : Shared helpers of the standalone Windows customer tools in
#            70-Customer-Projects/tools/powershell (collect_fmw_env.ps1,
#            export_forms_reports_conf.ps1) - the PowerShell twin of
#            tools/bash/ihw_tools_lib.sh: masking, output helpers, git guard,
#            passphrase + openssl-compatible encryption, packing, web tier
#            (find / flatten / routes / settings), certificates, Nginx patch
#            facts, Reports server list, load profile, OS update state.
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

$IHWT_PS_LIB_VERSION = "2026-11-16.1"
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
    $t = [regex]::Replace($t, '(<[^>/]*[Pp]ass[Ww]or[dD][^>]*>)[^<]*', '$1***MASKED***')
    $t = [regex]::Replace($t, '(<identifier[^>]*>)[^<]*', '$1***MASKED***')
    $t = [regex]::Replace($t, '(name="[^"]*([Pp]ass[Ww](or)?[dD]|pwd|PWD)[^"]*"\s+value=")[^"]*', '$1***MASKED***')
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
        ($f -f "Platform", ("{0} {1}" -f $(if ($IHWT_ON_WINDOWS) { "Windows" } else { [Environment]::OSVersion.Platform }), $(if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "x86" }))),
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
                "listen" { $vv = $a -replace '\s.*$', ''; if ($vv -notmatch ':') { $vv = "*:$vv" }; $st.gl = $(if ($st.gl) { "$($st.gl),$vv" } else { $vv }); continue }
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
        foreach ($r in $RT) { $v = $(if ($r.v) { $VH[$r.v] } else { $null })
            $rows.Add(("{0};{1};{2};{3};{4};{5};{6};{7};{8};{9}" -f $Type, $Main, $(if ($v) { $v.vl } else { $st.gl }), $(if ($v -and $v.vn) { $v.vn } else { $st.gn }),
                $(if ($v) { $v.vt } elseif ($st.gt) { $st.gt } else { "no" }), $(if ($v -and $v.vpr) { $v.vpr } else { $st.gpr }), $r.p, $r.t, $r.a, $(if ($v -and $v.vcert) { $v.vcert } else { $st.gcert }))) }
        for ($i = 1; $i -le $st.nv; $i++) { $v = $VH[$i]; if ($v.rows) { continue }
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
        if ($lw -match '^(server_tokens|servertokens|serversignature|traceenable|debugconfiginfo|autoindex)$') { $res += "$Type;$Main;$w;$a;$f" }
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
# the certificate file of the route. "source;subject;issuer;not_after" (no header)
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
            $src = "https $($f[0]) $lis ($name)"; $c = $null
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                if ($tcp.ConnectAsync($h, [int]$port).Wait(10000)) {
                    $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, ({ $true } -as [System.Net.Security.RemoteCertificateValidationCallback]))
                    $ssl.AuthenticateAsClient($name)
                    $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
                    $ssl.Close()
                }
                $tcp.Close()
            } catch { $c = $null }
            if (-not $c -and $f[9] -and (Test-Path -LiteralPath $f[9] -PathType Leaf)) {
                try { $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($f[9]); $src = "https $($f[0]) $lis (file $($f[9]))" } catch { $c = $null }
            }
            # openssl order and names ("C=DE, ST=..., CN=...") like the bash version
            $dn = { param($x) _ihwt-dn $x.RawData }
            if ($c) { $res += ("{0};{1};{2};{3}" -f $src, (& $dn $c.SubjectName), (& $dn $c.IssuerName), $c.NotAfter.ToUniversalTime().ToString("MMM d HH:mm:ss yyyy 'GMT'", [Globalization.CultureInfo]::InvariantCulture)) }
            else { $res += "$src;-;-;not reachable / no readable certificate file" }
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
