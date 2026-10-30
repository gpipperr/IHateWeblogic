# tools – metadata collection and patch download for a Forms & Reports host

Shared, standalone helpers for the patch analyses in `70-Customer-Projects/`
– **no** IHateWeblogic library, plain bash + coreutils, copy them to the host
and run them there. One script for all releases: it works for FMW / Forms &
Reports **12.2.1.x** (12.2.1.19 on WLS 12.2.1.4, JDK 8) and **14.1.2** (JDK
17 / 21) – tested on both (2026-10-23). Release differences are detected at
runtime, never by a second copy of the script.

| Script | Purpose |
|---|---|
| [collect_fmw_env.sh](#collect_fmw_envsh) | read-only metadata collection for the patch analysis |
| [mos_patch_download.sh](#mos_patch_downloadsh) | download a patch list (CSV) from My Oracle Support with getMOSPatch in one run |
| [clone_check_fmw.sh](#clone_check_fmwsh) | read-only: is the installation clone-capable (golden image) – sockets, WebLogic, Reports ORB, host name / IP in the domain, RCU repository, web tier |
| [fmw_patch_env.sh](#fmw_patch_envsh) | detect and set the variables of the manual patch cookbooks (`ORACLE_HOME`, `DOMAIN_HOME`, `INV_PTR`, `JDK_LINK`, `PATCH_DIR`, `STAGE`, `BACKUP` …) |

Used by:
- [Forms12_reports12_patch_analyse_10_2026](../Forms12_reports12_patch_analyse_10_2026/README.md)
  (patch list [patches_cpu_oct2026.csv](../Forms12_reports12_patch_analyse_10_2026/patches_cpu_oct2026.csv))
- [Forms14_reports14_patch_analyse_10_2026](../Forms14_reports14_patch_analyse_10_2026/README.md)

## collect_fmw_env.sh

Collects the metadata of an Oracle Forms & Reports / FMW host – OS, Java,
Oracle Home / inventory / patches, domain configuration, processes, Oracle
Net, logs – into one directory plus a `.tar.gz` for the analysis.

```bash
# as the software owner of the Oracle Home (oracle), not root
cp collect_fmw_env.sh /tmp/ && cd /tmp && chmod +x collect_fmw_env.sh
./collect_fmw_env.sh                    # auto-detect ORACLE_HOME / DOMAIN_HOME
./collect_fmw_env.sh -o /oracle/product/mw -d /oracle/user_projects/domains/fr_domain
./collect_fmw_env.sh --full             # + opatch lsinventory -details / -bugs_fixed
./collect_fmw_env.sh --logs             # + error lines of the server logs (last 200)
```

| Option | Meaning |
|---|---|
| `-o DIR` | Oracle Home (default: `$ORACLE_HOME`, then `/oracle/product/mw`, `/u01/app/oracle/fmw`, …) |
| `-d DIR` | domain home (default: `$DOMAIN_HOME`, `$ORACLE_HOME/domain-registry.xml`, the running AdminServer) |
| `-t DIR` | base directory of the output (default `/tmp`) |
| `--full` | large inventory output – for bug / CVE questions (`-bugs_fixed`) |
| `--logs` | error / FRM- / REP- / ORA- lines of the server logs |

Since 2026-10-29.1 also: the Reports / Forms components of `comps.xml`
(the home inventory OPatch uses – Reports binaries **without** these entries
are never patched, `00_summary.txt` then shows `!! Reports NOT REGISTERED`)
and the binary (`/proc/<pid>/exe`) of every WebLogic / Forms / Reports
process (`Processes outside ORACLE_HOME / JDK` – a process from another home
must be patched there).

Check the version first: `./collect_fmw_env.sh -V` (also the first line of
`00_summary.txt`) – it must match the version in the repository.

Result: `/tmp/fmw_collect_<host>_<timestamp>/` and `….tar.gz` (about 100 KB
without `--full`); `00_summary.txt` holds the key facts, every other file one
area (`10_os`, `20_java`, `30_inventory`, `31_opatch`, `40_config.xml`,
`41_domain_scripts`, `42_forms_reports_config`, `43_ohs_config`, `50_processes`, `60_net`, `61_webserver`,
`70_logs`). Runtime on the test host: about 30 s.

**Read-only:** writes only into the output directory (OPatch writes its usual
logs to `$ORACLE_HOME/cfgtoollogs` while it reads the inventory). Every
command runs under `timeout 600`.

**Secrets:** password elements, `{AES}` values, `userid=` / `authid=` /
`password=` values, `user/password@` connect strings and `-D…password=`
arguments are replaced by `***MASKED***` before anything is written.
Host names, IP addresses and paths stay in the output – they are needed for
the analysis. Check the files before sending; never commit the output to a
repository.

## mos_patch_download.sh

Downloads all patches of a CSV list from My Oracle Support with
[getMOSPatch](https://github.com/MarisElsins/getMOSPatch) – per patch the
right platform and only the needed file, then `unzip -t` and SHA-256 of every
ZIP. Standalone like `collect_fmw_env.sh`: bash + coreutils + Java +
python (only for the password terminal), no IHateWeblogic library.

### Place getMOSPatch on the host

1. On a machine with internet: download `getMOSPatch.jar` from the GitHub
   page above (Releases), copy it to the host – next to the script, into the
   target directory, or anywhere (`-j`).
2. Java 8 or newer (the Oracle Home's JDK is fine:
   `export JAVA_HOME=<ORACLE_HOME>/oracle_common/jdk` or the server JDK, or
   `--java <path>`).
3. **No `.getMOSPatch.cfg` to prepare:** getMOSPatch reads the platform /
   language from `.getMOSPatch.cfg` in the *current working directory*; the
   script writes one per patch directory (`<platform>;4L`, 4L = American
   English) from the CSV.
4. MOS account with download rights for the product (Extended Support for
   12.2.1.x patches). The user is `-u` / `$MOS_USER` or asked; the password
   is asked **once** (hidden) and typed into getMOSPatch through a pseudo
   terminal – never on a command line, never stored, masked in the log.
5. Outbound HTTPS to `updates.oracle.com`, the Oracle SSO
   `login-ext.identity.oraclecloud.com` and the Akamai download hosts
   (`*.oracle.com`). Behind a proxy: `--proxy host:port`, default
   `$https_proxy`. With TLS interception
   the company root CA must be in the `cacerts` of the Java used – see
   [certificates_trust_stores.md §6](../../80-FMW-Architecture/certificates_trust_stores.md).

```bash
# as any user with write access to the target directory (oracle is fine)
cd /oracle/install/cpu_okt2026
cp <repo>/70-Customer-Projects/tools/mos_patch_download.sh .
cp <repo>/70-Customer-Projects/Forms12_reports12_patch_analyse_10_2026/patches_cpu_oct2026.csv .
# getMOSPatch.jar placed here by hand
./mos_patch_download.sh -c patches_cpu_oct2026.csv -d ./zip                      # plan only
./mos_patch_download.sh -c patches_cpu_oct2026.csv -d ./zip -u me@example.com --apply
./mos_patch_download.sh -c patches_cpu_oct2026.csv -d ./zip --only 39888613,39600813 --apply

# patch list of the library (14.1.2) on a host without the library - result in
# the PATCH_STORAGE layout (column dir), then rsync to the target host:
./mos_patch_download.sh -c patches_fmw.csv -d /share/patch_storage --all --apply
```

| Option | Meaning |
|---|---|
| `-c FILE` | patch list (CSV, format below) |
| `-d DIR` | target directory; one sub-directory per patch: `DIR/<dir>/p<patch>_*.zip` (`<dir>` = column `dir`, default `<patch>`) |
| `-j JAR` | getMOSPatch.jar (default: `./`, then `DIR/`, then the script directory) |
| `-u USER` | MOS user (default `$MOS_USER`, else asked) |
| `--all` | also the rows with `required=optional` |
| `--only N,N` | only these patch numbers (optional rows included) |
| `--steps S,S` | only rows with these values in column `step` (optional rows included) – the library passes its roles (`spb,wls,jdk,…`) |
| `--password-stdin` | read the MOS password from the first line of stdin instead of asking (caller: `09-Install/04-oracle_pre_download.sh --mos`); needs `-u` / `$MOS_USER` |
| `--java JAVA` | Java binary (default `$JAVA_HOME/bin/java`, then `java` in `PATH`) |
| `--proxy H:P` | HTTPS proxy for getMOSPatch (default: `$https_proxy` / `$HTTPS_PROXY`) |
| `--apply` | download – without it the plan is printed (which patch, platform, file, already present) |

Checks first: Java, jar, `unzip`, `sha256sum`, python (`python3`, then
`/usr/libexec/platform-python` – always present on OL8 / OL9; without python
getMOSPatch asks for user / password itself for every patch), free space
(WARN below 15 GB – a full 12c CPU set has ~6 GB). A ZIP already present is
skipped – a second run only loads what is missing. Up to 3 attempts per
patch and platform.

Result: `DIR/<dir>/…zip`, `DIR/patches_sha256.txt` (compare with the
SHA-256 shown on the MOS download page), `DIR/patches_sha256.csv`
(`patch;step;file;sha256` – to fill the `sha256` column after an analysis),
`DIR/mos_patch_download_<ts>.log`.
Exit code 0 = all required patches present, 1 = an optional one missing or a
SHA-256 differs from the list, 2 = a required one missing / damaged ZIP /
prerequisite missing.

### CSV format

`;`-separated, `#` = comment, one header line:

```
patch;platform;file_regexp;required;step;description[;dir[;sha256]]
40129641;2000P;p40129641_122140_Generic\.zip;yes;6;WLS Stack Patch Bundle 12.2.1.4.261007
39888613;226P;p39888613_1221190_Linux-x86-64\.zip;yes;8;Oracle Forms QPR 12.2.1.19
40186682;226P;p40186682_.*_Linux-x86-64\.zip;yes;4;JDK 8u511 (file name not fixed)
```

| Column | Meaning |
|---|---|
| `patch` | MOS patch number |
| `platform` | MOS platform code; alternatives with `\|` (`2000P\|226P`) are tried in order when MOS has no file for the first |
| `file_regexp` | Java regex of the **whole file name** (incl. `\.zip`); empty = all files of the platform. The script strips a trailing `\.zip` before passing it to getMOSPatch – getMOSPatch compares with `String.matches()` against the file name **without** `.zip` (`p38832179_122140_Linux-x86-64`), a regexp ending in `\.zip` never matches there (checked in the class, 2026-10-28) |
| `required` | `yes` or `optional` (only with `--all` / `--only`) |
| `step` | step of the cookbook that applies the patch (information only); in the library list `09-Install/download/patches_fmw.csv` the **role** (`spb`, `wls`, `jdk`, … – [download/README.md](../../09-Install/download/README.md)), filter with `--steps` |
| `description` | free text |
| `dir` | optional: target below `-d` (default `<patch>`) – e.g. `patches/40125898`, `client/jdk/35702194`, `database/cvu` |
| `sha256` | optional: SHA-256 of the analysed file – **soft check**: a different value is a WARN (exit 1), never a FAIL – Oracle re-releases patches under the same number (the JDK patch with every update); `unzip -t` stays the hard check |

Platform codes (checked 2026-10-22):

| Code | Platform |
|---|---|
| `226P` | Linux x86-64 |
| `2000P` | Generic (all platforms – most FMW bundle patches) |
| `233P` | Microsoft Windows x64 (64-bit) |
| `46P` | Linux x86 (32-bit) |
| `541P` | Linux ARM 64-bit |

All codes of a patch: in an empty directory without `.getMOSPatch.cfg`
`java -jar getMOSPatch.jar patch=<nr> reset=yes` – getMOSPatch lists the
platforms / languages the patch exists for and writes a new
`.getMOSPatch.cfg` there.

### Troubleshooting

| Message | Cause / action |
|---|---|
| `No files available` / `There's nothing to download!` | no file for this platform – check the code (`reset=yes`), or the regexp does not match the file name (without `.zip`!); remove the regexp and look at the offered list |
| `Invalid credentials` | MOS user / password wrong, or the account is locked – log in once in the browser |
| `ERROR: …403…` / no download right | the MOS account (CSI) has no support / Extended Support for the product |
| `PKIX path building failed` | TLS interception – company root CA into the Java `cacerts` (see above) |
| hangs at the start | no outbound HTTPS – proxy (`--proxy`) or firewall |
| `unzip -t` FAIL | download broken – delete the ZIP, run again (skips the good ones) |

Live-tested 2026-10-28 on the test host (OL9, Java 21, getMOSPatch from the
patch repository): `--only 38832179` → ZIP, `unzip -t`, SHA-256 OK; password
not in the log. 2026-10-30 (version 2026-10-30.1): `patches_fmw.csv` with
`--password-stdin --only 39726399,39600348` → `patches/<nr>/`, digests equal
to the CSV; wrong digest → WARN / exit 1, damaged ZIP → FAIL / exit 2; called
by `04-oracle_pre_download.sh --apply --mos` (all present, plumbing).

## fmw_patch_env.sh

Replaces the hand-edited `export` block **VORAUSSETZUNGEN** of the manual
patch cookbooks (`Patch_Kochbuch_*_de.txt`): detects the values on the host
and sets them. Standalone like the other tools.

```bash
cd /oracle/install/cpu_okt2026                 # base directory of the patch run
./fmw_patch_env.sh                             # show only (a script cannot set variables of its caller)
. ./fmw_patch_env.sh                           # SOURCED: exports the variables into this shell
. ./fmw_patch_env.sh --apply                   # + creates the directories, writes ./patch_env.sh
. /oracle/install/cpu_okt2026/patch_env.sh     # 2nd terminal / new login: same values
```

| Variable | Detected from |
|---|---|
| `ORACLE_HOME` | `-o`, `$ORACLE_HOME`, running WebLogic (`-Dweblogic.home`), default paths (`/oracle/product/mw`, `/u01/app/oracle/fmw` …) |
| `DOMAIN_HOME` | `-d`, `$DOMAIN_HOME`, `$ORACLE_HOME/domain-registry.xml` (WARN with more than one domain), running AdminServer |
| `INV_PTR` / `INVENTORY` | `/etc/oraInst.loc`, else `$ORACLE_HOME/oraInst.loc`; `inventory_loc` |
| `JDK_LINK` / `NEW_JDK_BASE` | `JAVA_HOME` of `$ORACLE_HOME/oui/.globalEnv.properties` (the JDK of OPatch and the servers) / its parent |
| `PATCH_DIR` / `STAGE` / `LOGDIR` | `-b` (default: current directory) + `/zip`, `/stage`, `/stage/logs` – `PATCH_DIR` = the `-d` of `mos_patch_download.sh` |
| `BACKUP` | `-k`; default `<prefix>/backup/<name>` for `<prefix>/install/<name>` (cookbook layout), else `<base>/backup` |

Shown as well (the cookbook decides on them): JDK build and link or real
directory (step 4.4 variant a / b), bundled JDK `oracle_common/jdk` (4.7),
OPatch version, glibc (Forms before Reports QPR from 2.34), OHS instances
(step 9), number of ZIPs in `PATCH_DIR`, running WebLogic / Forms / Reports
processes, free space of `STAGE` / `BACKUP`.

FAIL (rc 2): Oracle Home, domain, inventory or JDK not found, JDK inside
`ORACLE_HOME` (KB175049), base directory inside the Oracle / Domain Home.
WARN (rc 1): `BACKUP` on the file system of `ORACLE_HOME`, more than one
domain, run as root. Read-only without `--apply`; with it only the four
directories and `patch_env.sh` in the base directory are created.
Tested 2026-10-29 on the 14c test host (executed, sourced, `--apply`).

## clone_check_fmw.sh

Standalone, read-only version of `02-Checks/clone_check.sh` for customer
hosts (12.2.1.x and 14.1.2): could this installation become a **golden
image** / be moved to another host? Target: everything internal on
`127.0.0.1`, only the web tier (OHS / Apache / Nginx) and the certificate
carry the host name. Background and recipe:
[clone_golden_image.md](../../80-FMW-Architecture/clone_golden_image.md).

```bash
cp clone_check_fmw.sh /tmp/ && cd /tmp && chmod +x clone_check_fmw.sh
./clone_check_fmw.sh                     # auto-detect ORACLE_HOME / DOMAIN_HOME
./clone_check_fmw.sh -d /oracle/user_projects/domains/fr_domain -t /tmp
```

| Section | FIX (before an image) | STEP (after cloning) / INFO |
|---|---|---|
| 1 listening sockets (`ss`) | java / `rwserver` socket on all interfaces or the host IP | web tier (`httpd`, `nginx`) by design; `frmweb` (no bind option); Coherence remainder; multicast discovery |
| 2 `config.xml`, `nodemanager.properties` | listen address not loopback, SSL listen port on, Coherence unicast not `127.0.0.1` | – |
| 3 Reports | no `ORBServerHost=127.0.0.1` in `reports.sh` / `setUserOverrides.sh` | discovery port / server name per clone |
| 4 host name / IP in `$DOMAIN_HOME/config` | unknown file | JDBC / OPSS (DB host), OHS config; RCU repository local (cloned along) or **external** (own prefix per clone) |
| 5 machine identity | – | domain key travels with the clone, stored WLST credentials |
| 6 by design | – | OHS `ServerName` / `Listen`, Apache / Nginx `server_name` + certificate, `tnsnames.ora` hosts |

Nothing is changed: for SSL / Coherence the needed WLST online commands are
printed at the end (run them with the AdminServer up, then restart the
managed servers). Needs `ss`; python (`python3`, else
`/usr/libexec/platform-python`) to parse `config.xml` – without it section 2
is reported as not checked. As `oracle` only the own sockets show a process
name; as root all. Exit 0 = clone-capable, 1 = items to fix, 2 = no domain.
Log: `<-t>/clone_check_<host>_<ts>.log` (contains host names / IPs – keep it
out of repositories). Tested 2026-10-29 on the 14c test host: same verdict
as `02-Checks/clone_check.sh` ("yes").
