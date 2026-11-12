# tools/powershell – Windows versions of the customer tools

PowerShell versions of three tools from [../bash/](../README.md), for Forms
& Reports installations on **MS Windows Server**. Each one is standalone
(no library), runs on **Windows PowerShell 5.1** (built into every Windows
Server 2016 or newer) and PowerShell 7, and covers FMW **12.2.1.x and
14.1.2**. The output and the CSV format match the bash versions, so the
analysis is the same for Linux and Windows hosts.

| Script | Purpose | bash version |
|---|---|---|
| [collect_fmw_env.ps1](#collect_fmw_envps1) | read-only metadata collection (OS, services, Java, OPatch, domain, Forms / Reports config, processes, Oracle Net, logs), secrets masked → ZIP | [collect_fmw_env.sh](../README.md#collect_fmw_envsh) |
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
```

The output goes to `<OutBase>\fmw_collect_<host>_<timestamp>\`, packed as
`.zip`. It uses the same file names as the bash version (`00_summary.txt`,
`10_os.txt` … `71_log_errors.txt`, plus `72_eventlog.txt`).

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
| Domain scripts | `setDomainEnv.cmd`, `setUserOverrides.cmd`, `startNodeManager.cmd`, `startWebLogic.cmd`, `reports\bin\*` |
| Oracle Net | `TNS_ADMIN` from the session, the machine environment and `HKLM\SOFTWARE\Oracle\KEY_*` |
| Web tier | owner of the ports 80 / 443 / 7777 / 4443 / 8080 / 8443, IIS (`W3SVC`, `iisproxy` in `applicationHost.config`), OHS instances, nginx under `C:\nginx*` / `D:\nginx*` |
| Logs (`-Logs`) | also the event log `Application` / `System`, level Critical / Error, last 7 days (max 300) |

**Masking:** the rules are the same as `mask()` of the bash version and
cover `<…password…>` elements, `{AES}` values, `userid=` / `authid=` /
`password=` / `pwd=`, `-D…Password=` and `user/password@`. They were tested
on the same input lines and give identical output (2026-11-03).

Runs as the software owner or as an administrator. Some service and registry
values are only readable for an administrator, and the summary says whether
the run had admin rights.

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
and asks for user and password itself, once per patch.

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
- the Windows-only parts: CIM (`Win32_*`), registry, services, firewall, event log, IIS;
- `opatch.bat` started through `cmd.exe`;
- `Read-Host -AsSecureString`;
- junction detection;
- Windows PowerShell 5.1 itself.

The first run at the customer is the real test. Look at `00_summary.txt`
and the console for red error lines.
