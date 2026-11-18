---
nav_title: "PowerShell tools"
title: "Forms & Reports Customer Tools for Windows (PowerShell)"
description: "Windows PowerShell versions of the IHateWeblogic customer tools: state collection, configuration export, patch cookbook variables and MOS patch download (FMW 12.2.1 / 14.1.2)."
permalink: /70-Customer-Projects/tools/powershell/
---

# tools/powershell – Windows versions of the customer tools

PowerShell versions of the tools from [../bash/](../README.md), for Forms
& Reports installations on **MS Windows Server**. They run on **Windows
PowerShell 5.1** (built into every Windows Server 2016 or newer) and
PowerShell 7, and cover FMW **12.2.1.x and 14.1.2**. The output and the CSV
format match the bash versions, so the analysis is the same for Linux and
Windows hosts. `collect_fmw_env.ps1` and `export_forms_reports_conf.ps1` need the shared
[`ihw_tools_lib.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/powershell/ihw_tools_lib.ps1) next to it (the twin of
`bash/ihw_tools_lib.sh`: masking, encryption, web tier, Nginx, load profile);
copy the whole folder / the Windows ZIP.

| Script | Purpose | bash version |
|---|---|---|
| [collect_fmw_env.ps1](#collect_fmw_envps1) | read-only collection of the **state** (OS + pending Windows updates, services, Java, OPatch / components / other homes, domain facts, processes and memory, web tier with Nginx in detail, HTTPS certificates, load profile, logs), secrets masked → encrypted ZIP | [collect_fmw_env.sh](../README.md#collect_fmw_envsh) |
| [export_forms_reports_conf.ps1](#export_forms_reports_confps1) | read-only export of the **configuration** for the 14c rebuild (Forms, Reports, domain, JDBC, Oracle Net, web tier incl. IIS, fonts, source inventory, Oracle registry environment, Windows → Linux path map), same archive layout as bash → encrypted ZIP | [export_forms_reports_conf.sh](../README.md#export_forms_reports_confsh) |
| [ihw_tools_lib.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/powershell/ihw_tools_lib.ps1) | shared helpers, dot-sourced (must lie next to the tools) | [ihw_tools_lib.sh](../README.md#ihw_tools_libsh) |
| [fmw_patch_env.ps1](#fmw_patch_envps1) | detect and set the variables of the patch cookbooks (`ORACLE_HOME`, `DOMAIN_HOME`, `INV_PTR`, `JDK_LINK`, `PATCH_DIR`, `STAGE`, `BACKUP` …) | [fmw_patch_env.sh](../README.md#fmw_patch_envsh) |
| [mos_patch_download.ps1](#mos_patch_downloadps1) + [GetMOSPatchRunner.java](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/powershell/GetMOSPatchRunner.java) | CSV-driven download from My Oracle Support with getMOSPatch, ZIP check (CRC) and SHA-256 | [mos_patch_download.sh](../README.md#mos_patch_downloadsh) |

## Starting a script (ExecutionPolicy)

Scripts copied from a share or downloaded from the internet are blocked by
the default policy (`RemoteSigned` on servers). The machine policy is **not**
changed. Use either of these:

```powershell
# only for this one process
powershell.exe -ExecutionPolicy Bypass -File .\collect_fmw_env.ps1
# or remove the "downloaded" mark once
Get-ChildItem .\*.ps1, .\*.java | Unblock-File
```

`Get-Help .\collect_fmw_env.ps1 -Full` shows the help of each script. Every
script has a `-Version` switch.

The scripts contain only ASCII characters, so Windows PowerShell 5.1 reads
them correctly without a BOM. Git checks out `*.ps1` with CRLF line endings
(`.gitattributes`).

## collect_fmw_env.ps1

```powershell
.\collect_fmw_env.ps1                                  # auto-detect ORACLE_HOME / DOMAIN_HOME
.\collect_fmw_env.ps1 -OracleHome D:\Oracle\Middleware\Oracle_Home -DomainHome D:\Oracle\user_projects\domains\fr_domain
.\collect_fmw_env.ps1 -Full                            # + opatch lsinventory -details / -bugs_fixed
.\collect_fmw_env.ps1 -Logs                            # + error lines of the server logs + Windows event log (7 days)
.\collect_fmw_env.ps1 -OutBase D:\temp                 # default: $env:TEMP
.\collect_fmw_env.ps1 -NoEncrypt                       # plain ZIP (still masked)
.\collect_fmw_env.ps1 -RwAuth rwadmin                  # secured Reports server: password asked hidden
.\collect_fmw_env.ps1 -NoLoad                          # no load profile (default: last 90 days, -LoadDays N)
```

Since 2026-11-16.3 the collector collects the **state** only; the
configuration files are in the export (the PowerShell export follows). The
output goes to `<OutBase>\fmw_collect_<host>_<timestamp>\`, packed as
**`.zip.enc`** (passphrase asked twice at the start, `-NoEncrypt` = plain
`.zip`) with a `.sha256`. The encryption is the one of the bash tools
(AES-256-CBC, PBKDF2-HMAC-SHA256 200 000, salt) done by .NET – no
`openssl.exe` needed on the customer host; decrypt on our side:
`openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -in <file>.zip.enc -out <file>.zip`.
Every file is UTF-8 without BOM with LF line ends, the ZIP entries use `/`
(Windows PowerShell 5.1 `Compress-Archive` writes `\`) – so the Linux tools
of the analysis read it like a bash collection. It uses the same file names
as the bash version (`00_summary.txt`, `10_os.txt` … `71_log_errors.txt`,
plus `72_eventlog.txt`).

**Detection on Windows:**
- **`ORACLE_HOME`**, in this order:
  1. `-OracleHome` / `$env:ORACLE_HOME`;
  2. the command line of a running WebLogic (`-Dweblogic.home`);
  3. the registry `HKLM\SOFTWARE\Oracle\KEY_*` (value `ORACLE_HOME`);
  4. the default paths `C:|D:|E:\Oracle\Middleware\Oracle_Home`, `\Oracle\Oracle_Home`, `\Oracle\fmw`, `\app\oracle\fmw`.
- **`DOMAIN_HOME`**: `domain-registry.xml` or `-Dweblogic.RootDirectory`.
- **Inventory**: the registry value `HKLM\SOFTWARE\Oracle` `inst_loc`, otherwise `oraInst.loc` in the home.
- **JDK**: `JAVA_HOME` of `oui\.globalEnv.properties`, with the properties escaping `C\:\\…` resolved. A junction is reported as such (cookbook variant a).

**What differs from Linux:**

| Area | Windows source |
|---|---|
| OS | `Win32_OperatingSystem`, hotfixes (last 30), volumes, pagefile, time zone / culture / code page, firewall profiles, listening ports with process name, scheduled tasks with an Oracle / WebLogic reference, machine environment |
| Services | `Win32_Service` (Oracle / WebLogic / Node Manager / Forms / Reports / OHS / IIS): state, start mode, account, path |
| Processes | `Win32_Process` with start time, working set, `ExecutablePath`, `CommandLine` (masked) |
| OS updates | updates **not installed** from the Windows Update Agent cache of the last scan (`Microsoft.Update.Session`, offline search, 180 s timeout – no network forced), `MsrcSeverity` Critical / Important counted; build with `UBR` |
| Oracle Net | `TNS_ADMIN` from the session, the machine environment and `HKLM\SOFTWARE\Oracle\KEY_*` (file list only) |
| Web tier | owner of the ports 80 / 443 / 7777 / 4443 / 8080 / 8443, IIS (`W3SVC`, sites / bindings, WebLogic `iisproxy.ini`), OHS instances, Apache, **Nginx** (below) – routing and rated directives in the format of the bash version |
| Load profile | Forms / Reports access logs aggregated like bash, `getserverinfo` / `showjobs` per POST; no `sar` on Windows (CPU / memory history "not collected") |
| Logs (`-Logs`) | also the event log `Application` / `System`, level Critical / Error, last 7 days (max 300) |

**Nginx on Windows** (installed by hand – no package manager, OpenSSL linked
statically into `nginx.exe`):
- found through the running `nginx.exe` (`-p` / `-c` of the command line),
  Windows services also behind a wrapper (**NSSM**: `Parameters\Application` /
  `AppDirectory`; **WinSW**: the `<id>.xml` next to the wrapper; srvany),
  scheduled tasks and the usual directories (`C:|D:|E:\nginx*`,
  `C:\tools\nginx*`, `C:\opt\nginx*`, `%ProgramFiles%\nginx*`); several
  installations are all listed;
- `nginx.exe -V`: version, OpenSSL it was built with, stable / mainline
  (even / odd minor version); date and file version of `nginx.exe`; master
  start time against the file date (`restart pending`); how it is started
  (service / wrapper / task / by hand, start type, account);
- who may write into the nginx directory (ACL entries with write rights;
  `Users` / `Authenticated Users` / `Everyone` = security finding of the
  environment analysis).

**Licence indicators** (2026-11-16.5, `45_licence.txt`, the same lines as
bash - tested on the test host): WebLogic Server Basic restrictions visible in
the domain configuration, every application / library with "source in
ORACLE_HOME", CPU (`Win32_Processor`), virtualization (`Win32_ComputerSystem`
manufacturer / model), public cloud (`Win32_SystemEnclosure` asset tag,
`Win32_BIOS`; on Linux the DMI files as in bash), running `OracleService*` database services with the
edition of their home (`oracle_install_db_InstallEdition`) and ORDS
processes. No licence statement - see
[fmw_forms_reports_licence.md](../../../80-FMW-Architecture/fmw_forms_reports_licence.md).

**Other WebLogic domains and WebGate** (2026-11-16.7, the same lines as bash -
tested on the test host with a second domain): `41_other_domains.txt` with the
top level of every other domain (inventory homes from `inst_loc` in the
registry, `domain-registry.xml`, `nodemanager.domains`, the
`-Dweblogic.RootDirectory` / `-Ddomain.home` of the running servers, sibling
directories of the Forms domain; `setDomainEnv.cmd` / `.sh`), and the
`webgate` lines in `43_ohs.txt` (agent certificate expiry read with .NET
`X509Certificate2`).

**Architecture data** (2026-11-16.8, the same lines as bash): normalised
listening ports (`Get-NetTCPConnection`, every process visible on Windows),
`Domain summary (top level)` in `40_domain.txt` with the WebLogic plug-in flag,
certificate columns SAN / key / signature / chain (`SslStream`, chain from the
certificates the server sends), the Apache / OHS route inheritance of global
`<Location>` blocks.

**Masking:** the rules are the same as `mask()` of the bash version and
cover `<…password…>` elements, `{AES}` values, `userid=` / `authid=` /
`password=` / `pwd=`, `-D…Password=` and `user/password@`. They were tested
on the same input lines and give identical output (2026-11-03).

Runs as the software owner or as an administrator. Some service and registry
values are only readable for an administrator, and the summary says whether
the run had admin rights.

## export_forms_reports_conf.ps1

```powershell
.\export_forms_reports_conf.ps1                     # auto-detect, encrypted archive (passphrase asked twice)
.\export_forms_reports_conf.ps1 -OracleHome D:\Oracle\Middleware\Oracle_Home -DomainHome D:\Oracle\user_projects\domains\fr_domain
.\export_forms_reports_conf.ps1 -Masked             # passwords masked, not encrypted - for an analysis
.\export_forms_reports_conf.ps1 -NoFonts -Keep      # list fonts only, keep the staging directory
```

The Windows version of [export_forms_reports_conf.sh](../README.md#export_forms_reports_confsh):
the **configuration** of the host for the rebuild with the 14c library on
Linux. The state (patch level, Java, memory, load profile, HTTPS
certificates) is [collect_fmw_env.ps1](#collect_fmw_envps1) - an analysis
always needs both runs.

**Same archive as bash:** `00_report.txt`, `raw/` (1:1 copies below
`domain/`, `oracle_home/`, `other/<drive>/...`, `other/UNC/<server>/...`),
`ihw_import/` (proposals), `sources_*`, `manifest.csv`,
`secrets_locations.txt`. Every path in the derived files is written with
`/` (`D:/Oracle/...`), so the environment analysis reads Windows exports with
the same rules. On the Linux test host the PowerShell and the bash export of
the same domain give the same files (2026-11-16).

Windows specifics:
- `ihw_import/registry_env.txt` - the values of `HKLM\SOFTWARE\Oracle\KEY_*`
  (`FORMS_PATH`, `REPORTS_PATH`, `NLS_LANG`, `TNS_ADMIN` ...) and the machine
  environment variables Oracle reads, with "in an env file yes / no" - Windows
  Forms / Reports read them from the registry, Linux has none;
- `ihw_import/path_map.txt` - every Windows path of the configuration
  (sources, fonts, `TNS_ADMIN`) with a proposal for the Linux path of the 14c
  host (`$ORACLE_BASE/...`; network shares: `/mnt/<server>/<share>` + mount);
- web tier: IIS (`applicationHost.config` + the `iisproxy.ini` of the
  WebLogic plug-in next to the `iisproxy.dll`), Nginx installed by hand,
  Apache, OHS;
- fonts: the Reports font directories plus `C:\Windows\Fonts` - fonts an
  administrator installed (barcode, corporate) are customer fonts and are
  copied; Microsoft fonts are only listed, never copied (licence); the fonts of
  Windows itself (owner `TrustedInstaller`) only when the name is known;
- source directories on network shares (UNC) are checked with a timeout and
  listed as "not reachable" instead of hanging;
- domain scripts `setUserOverrides.cmd` / `setDomainEnv.cmd`,
  `reports.cmd` / `reports.bat`.

The options of the load profile (`-NoLoad`, `-LoadDays`, `-RwAuth`) belong to
`collect_fmw_env.ps1` - here they are accepted and ignored with a note.

## fmw_patch_env.ps1

```powershell
cd D:\install\cpu_okt2026
.\fmw_patch_env.ps1                    # show only (a script cannot set variables of its caller)
. .\fmw_patch_env.ps1                  # DOT-SOURCED: sets the variables in this session
. .\fmw_patch_env.ps1 -Apply           # + creates zip\ stage\ stage\logs\ ..\..\backup\cpu_okt2026\, writes patch_env.ps1
. D:\install\cpu_okt2026\patch_env.ps1 # in a 2nd window: the same variables again
```

Each variable is set twice: as an environment variable (`$env:ORACLE_HOME`,
also seen by `opatch.bat` / `cmd.exe` started from this window) and as a
PowerShell variable (`$ORACLE_HOME`). The variables are the same as in the
bash version. `-Base` (default: current directory) and `-Backup` work like
`-b` / `-k` there.

**Windows facts:**
- running WebLogic / Node Manager / Forms / Reports processes;
- the **running Windows services** that must be stopped before OPatch, with their start mode (set them to *Manual* for the patch run);
- `JDK_LINK` as junction or real directory (variant b: make it a junction once with `mklink /J`);
- `BACKUP` on the same drive as `ORACLE_HOME` → WARN.

The glibc / libzrc line of the bash version does not apply on Windows.

Dot-sourcing leaves no helper function and no helper variable in the
session, and the script never calls `exit` when dot-sourced, so the window
stays open.

## mos_patch_download.ps1

```powershell
# getMOSPatch.jar placed here by hand (see ../README.md "Place getMOSPatch on the host")
.\mos_patch_download.ps1 -Csv patches_cpu_reports_14c_oct2026.csv -Dir D:\install\cpu_okt2026\zip -All              # plan only
.\mos_patch_download.ps1 -Csv patches_cpu_reports_14c_oct2026.csv -Dir D:\install\cpu_okt2026\zip -All -Apply       # download
.\mos_patch_download.ps1 -Csv patches_cpu_reports_14c_oct2026.csv -Dir D:\install\cpu_okt2026\zip -Only 28186730,39600348 -Apply
.\mos_patch_download.ps1 ... -Apply -Java D:\Oracle\jdk-21\bin\java.exe -Proxy proxy.pipperr.local:8080
```

| Option | bash | Meaning |
|---|---|---|
| `-Csv` / `-Dir` | `-c` / `-d` | patch list / target directory (one sub-directory per patch) |
| `-Jar` | `-j` | getMOSPatch.jar (default `.\`, `<Dir>\`, script directory) |
| `-User` | `-u` | MOS user (default `$env:MOS_USER`, else asked) |
| `-All`, `-Only`, `-Steps` | `--all`, `--only`, `--steps` | selection as in bash |
| `-Java` | `--java` | `java.exe` (default `$env:JAVA_HOME`, `java` in `PATH`) |
| `-Proxy` | `--proxy` | `host:port` (default `$env:HTTPS_PROXY`) |
| `-PasswordStdin` | `--password-stdin` | password from stdin, first line |
| `-Apply` | `--apply` | download (default: plan only) |

**The MOS password – [`GetMOSPatchRunner.java`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/powershell/GetMOSPatchRunner.java).** getMOSPatch reads user and
password only through `System.console()`. On Linux the bash version feeds
them through a pseudo terminal; Windows has no such terminal, and with
redirected streams `System.console()` is null. Passing `MOSPass=` on the
command line would show the password in the process list
(`Win32_Process.CommandLine`). The small Java runner next to the script
solves this:
1. It reads user and password from stdin.
2. It hands them to `getMOSPatch.main()` **inside the same JVM**.
3. The OS command line of the process contains neither of them.

The password is asked once (hidden, `Read-Host -AsSecureString`) for all
patches. In the 2026-11-03 test it was in neither the process list nor the
log.

The runner is started as a single-file source program (`java -cp
getMOSPatch.jar GetMOSPatchRunner.java …`) and needs **Java 11 or newer**,
e.g. the bundled JDK 17 of FMW 14.1.2 or `JDK_HOME` 21. FMW 12c ships JDK 8:
point `-Java` to any JDK 11+. Without one, getMOSPatch is started directly
and asks for user and password itself, once per patch – in the same console
window (`Start-Process -NoNewWindow`, since 2026-11-18.1). Up to 2026-11-17.1
that path piped the output (`| Out-Host`); `System.console()` of getMOSPatch was
then `null` and it stopped with a `NullPointerException` in
`setAuthentication` before asking anything (customer run with Java 8,
2026-11-18; reproduced with a pseudo terminal: pipe → console `null`,
`Start-Process` → console present). A JDK 11+ for Windows is in the patch
storage of a library host: `client/jdk/35702194/p35702194_2100_MSWIN-x86-64.zip`.

**ZIP check:** `GetMOSPatchRunner.java --zipcheck` reads every entry with
`ZipInputStream`, which checks the CRC of each entry like `unzip -t`. Tested
2026-11-03: a ZIP with 4 overwritten bytes is rejected with "invalid entry
CRC". With a Java older than 11 only the ZIP structure is checked (.NET),
which the output says. SHA-256 comes from `Get-FileHash`. Output files as in
bash: `patches_sha256.txt`, `patches_sha256.csv`, `mos_patch_download_<ts>.log`.

**Platform codes for Windows.** The patch lists of our Linux customers use
`226P` (Linux x86-64). On a Windows host the native patches (e.g. Forms / Reports
QPR, OHS, WebGate, JDK) are **`233P` = Microsoft Windows x64 (64-bit)**,
file names `p<nr>_<ver>_MSWIN-x86-64.zip`. Generic patches (SPB, infra
bundles, OPatch, `2000P`) are the same. A Windows CSV therefore needs its
own `platform` / `file_regexp` columns – check the file names on MOS once.
`233P|2000P` tries both platforms in that order.

## Tested – and what is not

Tested 2026-11-16 with PowerShell 7.7.0 on the Linux test host (not on
Windows), `export_forms_reports_conf.ps1` 2026-11-16.1 / `ihw_tools_lib.ps1`
2026-11-16.2:
- all files of the archive equal to the bash export of the same domain
  (only the order of a few sorted lists differs); the environment analysis
  gives the same report for both;
- a Windows export simulated from it (drive paths, CRLF in `raw/`, registry
  values, UNC and blank paths) runs through the Windows branch of the
  environment analysis (section 13.4, Windows findings);
- the masking now works line by line like `sed` (before, a value could run
  over the line end and mask the next line too - also in the collector).

Tested 2026-11-16 with PowerShell 7.7.0 on the Linux test host (not on
Windows), `collect_fmw_env.ps1` 2026-11-16.3 / `ihw_tools_lib.ps1`:
- encryption both ways against openssl (also with umlauts in the
  passphrase), the manual PBKDF2 of .NET 4.6.2 equal to the built-in one;
- web tier find / flatten / routes / settings and the certificate lines
  identical to the bash functions; load profile files identical (except
  `host_sar.csv` – no sar);
- both analyses read the collection (patch analysis, environment analysis
  with the bash export).

Tested 2026-11-03 with PowerShell 7.4.6 on the Linux test host (not on
Windows):
- all scripts parse without errors and use only ASCII and 5.1-compatible
  syntax;
- [`mos_patch_download.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/powershell/mos_patch_download.ps1):
  - the plan for `Reports14_linux_manual_install/patches_cpu_reports_14c_oct2026.csv` is identical to the bash version (18 patches);
  - `-Apply -Only 28186730,39100536`: real MOS download through the runner (Java 21), CRC and SHA-256 OK, SHA-256 equal to the CSV;
  - the password was never in `ps` and never in the log;
- [`fmw_patch_env.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/powershell/fmw_patch_env.ps1):
  - dot-sourced with `-Apply`, it gives the same values as the bash version;
  - `patch_env.ps1` is written and the backup path is derived from `…\install\<name>`;
  - no leftovers in the session;
- [`collect_fmw_env.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/powershell/collect_fmw_env.ps1):
  - Java, OPatch, inventory, domain, Forms / Reports configuration, processes, Oracle Net and logs ran on the 14.1.2 test host;
  - the masking is identical to bash;
  - no `{AES}` value and no known password in the output.

**Not tested** because no Windows host was available:
- the Windows-only parts: CIM (`Win32_*`), registry (`KEY_*` of the export), services, firewall, event log, IIS / `iisproxy.ini`, ACLs (fonts, source directories), UNC paths;
- Nginx on Windows (NSSM / WinSW / task detection, ACL), the Windows Update Agent search;
- `opatch.bat` started through `cmd.exe`;
- `Read-Host -AsSecureString`;
- junction detection;
- Windows PowerShell 5.1 itself.

The first run at the customer is the real test. Look at `00_summary.txt`
and the console for red error lines.
