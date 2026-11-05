# tools – metadata collection and patch download for a Forms & Reports host

Shared, standalone helpers for the patch analyses in `70-Customer-Projects/`
– **no** IHateWeblogic library, copy them to the host and run them there.

**For the customer: one ZIP per platform, one link** (no git clone on the
customer host):

| ZIP | Content | Link |
|---|---|---|
| [ihw_customer_tools_linux.zip](ihw_customer_tools_linux.zip) | `tools/*.sh` (all of `bash/` except the analysis, incl. `ihw_tools_lib.sh`), `tools/doc/` (this README, the road map, `patch_install.ini.template`), `tools/VERSIONS.txt` | `https://github.com/gpipperr/IHateWeblogic/raw/main/70-Customer-Projects/tools/ihw_customer_tools_linux.zip` |
| [ihw_customer_tools_windows.zip](ihw_customer_tools_windows.zip) | `tools/*.ps1`, `GetMOSPatchRunner.java`, `tools/doc/README.md`, `tools/VERSIONS.txt` | `https://github.com/gpipperr/IHateWeblogic/raw/main/70-Customer-Projects/tools/ihw_customer_tools_windows.zip` |

Each with a `.sha256` next to it (same link + `.sha256`). Unpacked with
`unzip … -d $ORACLE_BASE` it gives `$ORACLE_BASE/tools/` – the layout of the
road map [Start_beim_Kunden_kochbuch_de.txt](../Start_beim_Kunden_kochbuch_de.txt).

**Maintainer rule:** the ZIPs are built by
[make_customer_zip.sh](make_customer_zip.sh) – deterministic (fixed time
stamps, sorted, no extra attributes), so they only change when a tool really
changed. Before **every commit** that touches `bash/`, `powershell/`, this
README or the road map:

```bash
70-Customer-Projects/tools/make_customer_zip.sh            # check: exit 1 + changed files = stale
70-Customer-Projects/tools/make_customer_zip.sh --apply    # rebuild (+ .sha256), commit the ZIPs with the change
```

Not in the ZIPs: `analyse_forms_reports_export.sh` and `customer-analyse/`
(the analysis runs on our host), the local cookbook formatter.

| Folder | Platform |
|---|---|
| `bash/` | Linux – plain bash + coreutils (this README) |
| [powershell/](powershell/README.md) | MS Windows Server – Windows PowerShell 5.1 / PowerShell 7: `collect_fmw_env.ps1`, `fmw_patch_env.ps1`, `mos_patch_download.ps1` (+ `GetMOSPatchRunner.java`), same output / CSV format as the bash versions |

The bash scripts (`bash/`): one script for all releases – it works for FMW / Forms &
Reports **12.2.1.x** (12.2.1.19 on WLS 12.2.1.4, JDK 8) and **14.1.2** (JDK
17 / 21) – tested on both (2026-10-23). Release differences are detected at
runtime, never by a second copy of the script.

| Script | Purpose |
|---|---|
| [bash/collect_fmw_env.sh](#collect_fmw_envsh) | read-only metadata collection for the patch analysis |
| [bash/mos_patch_download.sh](#mos_patch_downloadsh) | download a patch list (CSV) from My Oracle Support with getMOSPatch in one run |
| [bash/clone_check_fmw.sh](#clone_check_fmwsh) | read-only: is the installation clone-capable (golden image) – sockets, WebLogic, Reports ORB, host name / IP in the domain, RCU repository, web tier |
| [bash/fmw_patch_env.sh](#fmw_patch_envsh) | detect and set the variables of the manual patch cookbooks (`ORACLE_HOME`, `DOMAIN_HOME`, `INV_PTR`, `JDK_LINK`, `PATCH_DIR`, `STAGE`, `BACKUP` …) |
| [bash/export_forms_reports_conf.sh](#export_forms_reports_confsh) | read-only: export the customer-specific Forms & Reports configuration (formsweb.cfg, env files, cgicmd.dat, Reports servers, uifont.ali, custom fonts, customer jars, source paths + dependencies) into one encrypted archive for the 14c rebuild |
| [bash/ihw_shell_env.sh](#ihw_shell_envsh) | interactive: `setdb` / `setfmw` / `setfw` – one menu to switch the **current shell** between the FMW home, its domains and DB homes (with / without SID); `c` clear, `h` help, `wlst`, `cdlog` …, `domain`; puts `$ORACLE_BASE/tools` into the PATH (installed as `~/.bashrc.d/ihw_env.sh`) |
| [bash/set_script_env.sh](#set_script_envsh-and-the-operation-tools) | sourced: load the customer's `patch_install.ini` into the session for the cookbook commands; `set_script_env_show` lists the values |
| [bash/status.sh, show_log.sh, show_errors.sh, show_all_logs.sh](#set_script_envsh-and-the-operation-tools) | operation (German output): status in three stages (ports, processes, HTTP + Node Manager, rc 0/1/2), the log of one component, all current logs live, only the error lines – read `patch_install.ini` next to them |
| [bash/analyse_forms_reports_export.sh](#analyse_forms_reports_exportsh) | turn an export of `export_forms_reports_conf.sh` into an analysis report for the customer (English Markdown): all sections as tables, the 14c target mapping and rule-based findings, security first – output git-ignored in `customer-analyse/` |
| [bash/ihw_tools_lib.sh](#ihw_tools_libsh) | shared helpers of these tools (masking, ini parsing, font classes, git guard, Markdown tables) – sourced, lies next to the tools |
| [bash/check_disk_space.sh](#check_disk_spacesh) | read-only: where is the space of the local disks – usage tree, known space eaters with their clean command, deleted-but-open files, files > 500 MB; NFS / network mounts are never scanned |

Cookbooks (`*_Kochbuch_de.txt`): **a blank line after every command**
(customer request 2026-11-03).
All style rules: [../cookbook-Skill.md](../cookbook-Skill.md).

Order at a customer (tools → setdb → ini → analysis or installation):
[../Start_beim_Kunden_kochbuch_de.txt](../Start_beim_Kunden_kochbuch_de.txt).

Used by:
- [Reports14_linux_manual_install](../Reports14_linux_manual_install/README.md)
  (all values in [patch_install.ini](../Reports14_linux_manual_install/patch_install.ini))
- [FormsReports12_patch_cpu_2026-10](../FormsReports12_patch_cpu_2026-10/README.md)
  (patch list [patches_cpu_forms_reports_12c_oct2026.csv](../FormsReports12_patch_cpu_2026-10/patches_cpu_forms_reports_12c_oct2026.csv))
- [FormsReports14_patch_cpu_2026-10](../FormsReports14_patch_cpu_2026-10/README.md)

## collect_fmw_env.sh

Collects the metadata of an Oracle Forms & Reports / FMW host – OS, Java,
Oracle Home / inventory / patches, domain configuration, processes, Oracle
Net, logs – for the **patch analysis** (the configuration for a move:
`export_forms_reports_conf.sh`). Since 2026-11-05.1 the result is an
**encrypted ZIP** (`fmw_collect_<host>_<ts>.zip.enc` + `.sha256`) – masked,
but with host names, IPs and paths of the customer.

```bash
# as the software owner of the Oracle Home (oracle), not root - from the
# unpacked tools ZIP (needs ihw_tools_lib.sh next to it)
cd $ORACLE_BASE/tools
./collect_fmw_env.sh                    # auto-detect, passphrase asked twice at the start
./collect_fmw_env.sh --no-encrypt       # plain ZIP (still masked) - e.g. without a terminal
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
| `--no-encrypt` | plain `.zip` instead of `.zip.enc` (the content is masked in both cases) |
| `--keep` | keep the output directory next to the archive |

Encryption: the same as the configuration export (`ihw_tools_lib.sh`
`ihwt_read_passphrase` / `ihwt_pack`: openssl AES-256-CBC, PBKDF2 200 000,
the passphrase only via a file descriptor). Decrypt:
`openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -in <file>.zip.enc -out <file>.zip` –
or hand the `.zip.enc` to `10-Monitoring/patch_cycle_analysis.sh analyse --env`,
which decrypts and unpacks it into `env/`. Inside a git work tree `-t` is
refused unless git ignores the path.

**Patch scope since 2026-11-05.1** (for KA1182 / CPU / CSPU):

| File | Content |
|---|---|
| `30_inventory.txt` | + product versions of `inventory/registry.xml` (WLS / Forms & Reports / OPatch – selects the patch list) |
| `33_components.txt` | patch-relevant `comps.xml` components with version (DB client, Perl, OHS, WebGate, Coherence, ADF / JRF / OPSS / OWSM / EM / UMS / WebCenter / LibOVD / OAMCLIENT, Forms / Reports), `sqlplus -V`, `perl -v`, OHS / WebGate directories |
| `34_other_homes.txt` | `opatch lspatches -oh` of every other home of the central inventory (separate OHS / WebGate / DB client / old FMW homes) |
| `35_opatch_prereq.txt` | inventory locks, owner / mode of the home and inventory, files not owned by the user, `.patch_storage` size, free space, the last apply / napply / rollback runs with their result |
| `44_forms_client.txt` | client JRE of the Forms users: JNLP `java version`, `formsweb.cfg` Java keys, `frmsal.jar` |
| `00_summary.txt` | + bundled JDK `oracle_common/jdk`, product versions, DB client, Perl, WebGate, `.patch_storage`, free space, locks, other homes, domain version, `openssl` / `ca-certificates` |

The process tree holds only the processes of the software owner (no command
lines of other users of the host).

Since 2026-10-29.1 also: the Reports / Forms components of `comps.xml`
(the home inventory OPatch uses – Reports binaries **without** these entries
are never patched, `00_summary.txt` then shows `!! Reports NOT REGISTERED`)
and the binary (`/proc/<pid>/exe`) of every WebLogic / Forms / Reports
process (`Processes outside ORACLE_HOME / JDK` – a process from another home
must be patched there).

Check the version first: `./collect_fmw_env.sh -V` (also the first line of
`00_summary.txt`) – it must match the version in the repository.

Result: `/tmp/fmw_collect_<host>_<timestamp>.zip.enc` (about 130 KB
without `--full`); `00_summary.txt` holds the key facts, every other file one
area (`10_os`, `20_java`, `30_inventory`, `31_opatch`, `33_components`,
`34_other_homes`, `35_opatch_prereq`, `40_config.xml`, `41_domain_scripts`,
`42_forms_reports_config`, `43_ohs_config`, `44_forms_client`, `50_processes`,
`60_net`, `61_webserver` (Nginx / Apache / standalone OHS: routing, rated
directives, configuration with all includes), `70_logs`). Runtime on the test host: about 60 s.

**Read-only:** writes only into the output directory (OPatch writes its usual
logs to `$ORACLE_HOME/cfgtoollogs` while it reads the inventory). Every
command runs under `timeout 600`.

**Secrets:** password elements, `<identifier>` content, `{AES}` values,
`userid=` / `authid=` / `password=` values, `user/password@` connect strings
and `-D…password=` arguments are replaced by `***MASKED***` before anything is
written (`ihwt_mask`, the same rules as the configuration export).
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
cp <repo>/70-Customer-Projects/tools/bash/mos_patch_download.sh .
cp <repo>/70-Customer-Projects/FormsReports12_patch_cpu_2026-10/patches_cpu_forms_reports_12c_oct2026.csv .
# getMOSPatch.jar placed here by hand
./mos_patch_download.sh -c patches_cpu_forms_reports_12c_oct2026.csv -d ./zip                      # plan only
./mos_patch_download.sh -c patches_cpu_forms_reports_12c_oct2026.csv -d ./zip -u me@example.com --apply
./mos_patch_download.sh -c patches_cpu_forms_reports_12c_oct2026.csv -d ./zip --only 39888613,39600813 --apply

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
| `JDK_HOME`, `JAVA_HOME` | = `JDK_LINK` – the cookbook steps use `JDK_HOME`; since 2026-11-03 set by the script and written to `patch_env.sh` (before, an empty `JDK_HOME` in a new shell made the `ps \| grep` check of step 4 match every process) |
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

## ihw_shell_env.sh

Environment switcher for the oracle user, after the model of `setdb` in
[OraBashShell .profile](https://github.com/gpipperr/OraBashShell). It
changes **only the current shell** – no installation file, no
`environment.conf` of the library (that one is switched with
`00-Setup/detect_env_conf.sh --select`).

**Install** (as oracle, also on customer hosts – the file is standalone):

```bash
mkdir -p ~/.bashrc.d
chmod 700 ~/.bashrc.d
cp ihw_shell_env.sh ~/.bashrc.d/ihw_env.sh
grep -n 'bashrc.d' ~/.bashrc
# Expected: the OL9 default loop "for rc in ~/.bashrc.d/*" (else add it)
```

Then open a new shell. On the test host `09-Install/03-root_user_oracle.sh`
does the same ([doc 5b](../../09-Install/docs/03-root_user_oracle.md)).
The first start detects the homes and writes `~/.ihw_env.conf` (mode 600,
editable): inventory (`/etc/oraInst.loc` → `inventory.xml`, removed or
missing homes skipped) plus `/etc/oratab`. A FMW home has
`wlserver/server/lib/weblogic.jar`; its domains come from
`domain-registry.xml`, its JDK from `oui/.globalEnv.properties`. A DB home
has `bin/oracle` + `bin/sqlplus`; its SIDs come from `/etc/oratab` and the
running `ora_pmon_*` processes; `ORACLE_BASE` from `bin/orabase`.

**Use** – `setdb`, `setfmw` and `setfw` show the same menu (live, test host):

```
    Current environment :  login values
-----------------------------------------------------------
  FMW
      1 ---> -  (home only)         Home: /u01/app/oracle/fmw
      2 ---> fr_domain              Home: /u01/app/oracle/fmw
-----------------------------------------------------------
  DB
    OraDB19Home1Patched            /u01/app/oracle/product/19.30.0/db_home1
      3 ---> -  (no SID)
    OraDB19Home_19_33_0            /u01/app/oracle/product/19.33.0/db_home1
      4 ---> FMWCDB
      5 ---> -  (no SID)
-----------------------------------------------------------
      c ---> clear environment    (back to the login values)
      h ---> help                 (aliases / functions / variables)
      q ---> quit                 (nothing changed)
   Selection [1]:
```

Every DB home gets one line per SID **and always one `(no SID)` line**
(OPatch / work on the home without `ORACLE_SID`), the same idea as
"home only" for FMW; the homes in inventory order, each under a header
with its **home name** (`install/orabasetab`, else the inventory) and path. `setdb 2` selects directly, `*` marks the active entry, `q` or an invalid
choice changes nothing.

Where the homes come from (`ihwenv_configure`, every path once – symlinks
and a trailing `/` only for the comparison, the registered spelling is
kept for OPatch):
- the central inventory (`/etc/oraInst.loc`), entries not `REMOVED`;
- **further inventories** named in `<home>/oraInst.loc` – a DB home
  installed with its own `-invPtrLoc` or by another team is not in the
  FMW inventory;
- `/etc/oratab`;
- the standard locations `/u0?/app/*/product/*/*`, `/oracle/product/*/*`,
  `/opt/oracle/product/*/*`, `$ORACLE_BASE/product/*/*` (only directories
  with `bin/oracle`) – a DB home **without SID** is in no oratab and
  without them it would not be listed (customer, 2026-11-03).

What was found but not listed is written as `# skipped: <home> (reason)`
into the cache and shown after the run: directory missing, client home (no
`bin/oracle`), neither FMW nor DB. A home still missing: add the line by
hand to `~/.ihw_env.conf` (`IHW_DB_ENV+=("- <home> <base>")`).

| Entry | Sets | PATH (in front of the login PATH) |
|---|---|---|
| FMW domain | `ORACLE_HOME` `WL_HOME` `DOMAIN_HOME` `DOMAIN_NAME` `JDK_HOME` `JAVA_HOME` `WLST` `NM_HOME` `FMWCONFIG` `FORMS_INSTANCE` `FORMS_APP_CONF` (formsweb.cfg, default.env) `REPORTS_APP_CONF` (rwservlet.properties, cgicmd.dat) `REPORTS_SERVER_CONF_DIR` (rwserver.conf) `REPORTS_TOOLS_CONF_DIR` (rwbuilder.conf); unsets `ORACLE_SID` | `$DOMAIN_HOME/reports/bin` (`rwrun.sh`, `rwclient.sh` – the domain wrappers, plain `$ORACLE_HOME/bin/rwrun` lacks the Reports env), `$DOMAIN_HOME/bin`, `$JAVA_HOME/bin`, `$ORACLE_HOME/oracle_common/common/bin` (FMW `wlst.sh`), `$ORACLE_HOME/bin`, `$ORACLE_HOME/OPatch` |
| FMW home only | the same without the domain variables (patching, OPatch) | without the two domain directories |
| DB (SID or `-`) | `ORACLE_HOME` `ORACLE_SID` (unset for `-`) `ORACLE_BASE`; removes all FMW variables | `$ORACLE_HOME/bin`, `$ORACLE_HOME/OPatch` |
| `c` | back to the login values (saved at the first `setdb` call), all switcher variables removed | login PATH |

Never changed: `TNS_ADMIN`, `NLS_LANG` (one Oracle Net directory for all
processes).

`SQLPATH` / `ORACLE_PATH` (sqlplus / SQLcl: personal `login.sql` and DBA
scripts in `~/sql`, as in OraBashShell) are set **only by a DB entry**.
FMW entries and `c` remove them, and a fresh login has none: a `login.sql`
disturbs `datapatch`, `catcon` and `utlrp` and every scripted sqlplus call.
So `setdb c` before patching a DB home by hand. The IHateWeblogic library
unsets both in every script anyway. The login PATH is cleaned of the entries of the login
`ORACLE_HOME` / `JAVA_HOME` before the new entries are put in front, so
PATH does not grow (live: 8 switches, length 156 / 240 / 121 constant).

Helpers: `whichenv`, `ihwenv_configure [-f]`, `wlst` (FMW `wlst.sh` from
`oracle_common` – never `wlserver/common/bin/wlst.sh`, it lacks `createCred`,
`grantAppRole` & co.; without arguments it starts in `$DOMAIN_HOME`), `cdoh`,
`cddh`, `cdcfg`, `cdnm`, `cdlog [server]` (server logs; with a DB entry the
ADR `diag` directory + `adrci show homes`). A function `myprompt` defined in
`.bash_profile` is called after each switch (as in OraBashShell).

Non-interactive shells (scp, sftp, cron, `bash -c`) load nothing and print
nothing (first line `[[ $- == *i* ]] || return`). Tested 2026-11-03 on the
14c test host (isolated `HOME` + real login shell): all four entries,
`c`, `h`, invalid input, PATH length, nested shell, `wlst` start directory.

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

## check_disk_space.sh

Where is the space of the **local** disks? Read-only – deletes nothing, prints
the clean command per finding. Network file systems (NFS, CIFS, sshfs … – e.g.
the NFS-mounted ZFS patch archive) are read from `/proc/self/mounts` and
**never scanned**, also not when they are mounted below a local directory
(`du -x` / `find -xdev` per local file system).

```bash
sudo ./check_disk_space.sh                 # as root: complete picture
sudo ./check_disk_space.sh --big 1000      # single files >= 1 GB only
sudo ./check_disk_space.sh --min 500       # tree: directories >= 500 MB only
```

| Option | Meaning |
|---|---|
| `--min MB` | smallest directory in the usage tree (default 100) |
| `--big MB` | smallest single file in section 5 (default 500) |
| `--top N` | at most N entries per tree level (default 15) |
| `-t DIR` | directory of the report file (default `/tmp`) |

Sections:

1. **File systems** – local (scanned, WARN >= 85 %, FULL >= 95 %) and network
   (listed, not scanned).
2. **Usage tree** – 2 levels below each local mount point; mount points of
   other file systems are marked. df used much larger than the du sum
   (> 1 GB and > 5 %) = hidden space: deleted but open files (section 4) or
   files written **under** a mount point before the NFS / disk was mounted –
   the bind-mount command to see them is printed.
3. **Known space eaters**, largest first, each with its clean command: dnf
   cache, journal, rotated logs, old kernels, crash / core dumps (our
   `core_pattern` writes to `/var/tmp/core`), `/tmp`, `/var/tmp`; Oracle homes
   of the central inventory – **in use** (process, `/etc/oratab`, registered
   domain) or **not in use** (old home after an out-of-place patch →
   `deinstall`), `.patch_storage` (`opatch util cleanup`), AutoUpgrade
   `patchdir` (gold image, base ZIP), ADR (`adrci purge`), audit files, FRA,
   unlinked JDKs below `$ORACLE_BASE/java`, CVU home, OUI leftovers,
   `PATCH_STORAGE` (→ `07-Maintenance/patch_storage.sh clean`), WebLogic logs
   / tmp / cache, IHateWeblogic logs and config backups. Locations come from
   the environment, the repository's `environment.conf` (when run from the
   repository) or the defaults.
4. **Deleted but still open files** (`/proc/*/fd`) – the space comes back only
   when the process ends.
5. **Single files >= `--big`** with date and owner.

Exit code: 0 = all local file systems < 85 %, 1 = one >= 85 %, 2 = one >= 95 %.
Runtime on the test host (100 GB disk, 92 GB used): about 40 s.

## export_forms_reports_conf.sh

Exports the customer-specific configuration of an **existing** Forms &
Reports environment (12.2.1.x or 14.1.2) into one archive – the input for
the rebuild with the 14c library. Read-only on the host, writes only below
`-t OUTDIR`. Step 1 of the migration; the import into the library is a
later, separate step (after the first real customer export).

```bash
# as the software owner (oracle), not root - from the unpacked tools ZIP
# (the script needs ihw_tools_lib.sh next to it)
cd $ORACLE_BASE/tools
./export_forms_reports_conf.sh                      # auto-detect, encrypted archive (passphrase asked twice)
./export_forms_reports_conf.sh -o /oracle/product/mw -d /oracle/user_projects/domains/fr_domain
./export_forms_reports_conf.sh --masked             # passwords masked, not encrypted – for analysis
```

| Option | Meaning |
|---|---|
| `-o DIR` / `-d DIR` | Oracle Home / domain home (default: environment, `domain-registry.xml`, running process, known paths – as `collect_fmw_env.sh`) |
| `-t DIR` | output directory (default `/tmp`); inside a git work tree it is **refused** unless git ignores the path |
| `--masked` | mask passwords in every file, archive not encrypted |
| `--no-fonts` | list the font files only, do not copy them |
| `--keep` | keep the unpacked staging directory (delete it yourself – customer data) |
| `--no-load` | no load profile (default: on, see below) |
| `--load-days N` | period of the load profile (access logs / sar files changed in the last N days, default 90) |
| `--rw-auth USER` | Reports admin (`<identifier>`) for `getserverinfo` / `showjobs` of a **secured** Reports server – password asked hidden at the start; non-interactive: `IHW_RW_AUTH=user/password` in the environment. Passed to curl only via a config on stdin (never on the command line) |

**Load profile** (`load/`, since 2026-11-04.4) – **only counted values**, no
log line leaves the host (access logs hold client addresses, user names and,
with GET report calls, passwords):

| File | Content |
|---|---|
| `forms_starts.csv` | `date;section;starts` – `frmservlet?config=…` with HTTP 2xx from the WLS_FORMS access logs |
| `forms_traffic.csv` / `forms_hourly.csv` | `date;requests;lservlet;http_5xx;avg_ms` (avg only with `time-taken`) / `hour;starts` |
| `now.txt` | `frmweb` processes + RSS, Reports engine processes, uptime, load average |
| `reports_requests.csv` | `date;command;requests;http_5xx` from the WLS_REPORTS access logs (command = `getserverinfo`, `showjobs`, report run …, no parameters) |
| `reports_<server>_serverinfo.xml`, `reports_jobs.csv` | `getserverinfo` and the past job queue (`server;id;report;status;started_epoch;seconds` – no owner, no parameters) of every **running** Reports server; a not running in-process server is not asked (the request would start it) |
| `host_sar.csv` | `date;cpu_avg;cpu_peak;mem_avg` from `/var/log/sa` (sysstat), if present |

**Output:** `ihw_export_<host>_<ts>.zip.enc` (+ `.sha256`; `.zip` with
`--masked`; `.tar.gz` if `zip` is missing). Decrypt:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -in ihw_export_<host>_<ts>.zip.enc -out ihw_export_<host>_<ts>.zip
```

### Passwords – two modes

The configuration files contain passwords: `cgicmd.dat` `userid=` /
`authid=`, `default.env` / env files, `rwserver.conf` `<identifier>` (clear
until the Reports server encrypts it), `{AES}` values in `config.xml`, data
source passwords. Choose the mode **before** the run:

| | Default: **encrypted** | `--masked` |
|---|---|---|
| Passwords in the archive | **included** (1:1 copies – needed for the rebuild) | replaced by `***MASKED***` in every text file (also in the derived `ihw_import/` files) |
| Archive | AES-256 encrypted (`.zip.enc`) | not encrypted (`.zip`) |
| Use | input for the 14c rebuild / later import | analysis, may be sent by mail / ticket after a look at it |
| Needs | `openssl`, a terminal for the passphrase | – |

**Passphrase (encrypted mode):**
- Asked **at the start**, before the minutes of collecting, so you do not
  have to wait for it. It is asked twice and hidden (`read -s`); empty or
  unequal input is asked again.
- Without a terminal (cron, pipe, `ssh host cmd` without `-t`) the script
  **refuses** to run. Use `--masked` there, or start it in an interactive
  session.
- It is handed to `openssl` over a file descriptor (`-pass fd:3`), **never on
  the command line**, so it is not visible in `ps` / `/proc/<pid>/cmdline`.
  It is not written to any file, and the variable is cleared right after
  the encryption.
- Encryption: `openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256
  -salt`. PBKDF2 with 200 000 iterations makes guessing a weak passphrase
  expensive, but it does not make a weak passphrase strong. Use a long one
  (e.g. 4–5 random words), because the archive holds the customer's
  passwords.
- **Forgotten passphrase = archive lost**: there is no recovery key. Give
  the passphrase to the recipient on a **different channel** than the file
  (phone / messenger vs. mail / share) and keep it in the password safe
  together with the customer entry.
- `openssl` of OL8 / OL9 (1.1.1 / 3.x) supports `-pbkdf2`. Decrypt with the
  same parameters (command above, also printed at the end of the run); on
  Windows with the `openssl.exe` of Git for Windows.

**Masking (`--masked`):**
- The same rules as `collect_fmw_env.sh`, plus `<identifier>…</identifier>`,
  `name="…password…" value="…"` (XML attributes) and `dbpassword=`.
- `raw/` files are masked while they are copied. Every other text file
  (`ihw_import/`, reports, dependency lists) is masked again before packing,
  because these files quote configuration lines. A first version left a
  `authid` value in `ihw_import/cgicmd.dat.customer_keys`; that is fixed and
  tested.
- Binary files (fonts, jars) are copied unchanged – they hold no passwords.
- Masking is pattern based: a password in an unusual place (own variable
  name, comment) can stay. Look through the archive before sending it.

**In both modes:**
- `secrets_locations.txt` lists **where** secrets are (`file:line:keyword`,
  never the value). With it you know which files to look at, and which
  passwords the rebuild needs.
- `umask 077`: the staging directory and the archive are readable for the
  running user only.
- The **staging directory** (`<OUTDIR>/ihw_export_<host>_<ts>/`) holds the
  files **unencrypted**: in clear text in the default mode, masked with
  `--masked`. It is removed after packing, unless `--keep` is given (the
  script then reminds you to delete it).
- **Abort** (Ctrl-C, `kill`, SIGHUP when the SSH session drops, error
  exit): an exit trap removes the staging directory and a half-written or
  still unencrypted archive, then prints `ABORTED (rc …)`. With `--keep`
  the staging directory is kept and the message names it. Since version
  2026-11-03.2; tested with SIGINT / SIGTERM in both modes. Only a
  `kill -9` or a power loss leaves it behind – then delete it by hand:
  `rm -rf /tmp/ihw_export_<host>_<ts>`.
- The archive itself never goes into git (see "Customer data" below). After
  the rebuild delete it in `/tmp` and on every copy, and keep the
  passphrase only as long as the archive exists.

| Part | Content |
|---|---|
| `00_report.txt` | versions, paths, Forms sections, Reports servers, customer jars, fonts, source dirs, warnings, what goes where |
| `raw/domain/`, `raw/oracle_home/`, `raw/other/` | 1:1 copies below their original path: `formsweb.cfg` + every `envFile`, `Registry.dat`, `webutil.cfg`, `*.res`, jnlp files; per Reports server (standalone + in-process) `rwserver.conf`, `rwnetwork.conf`, `rwservlet.properties`, `cgicmd.dat`; ReportsTools `uifont.ali`, PPD, AFM; `reports.sh`, `setUserOverrides.sh`, `config.xml`, `jps-config-jse.xml`, `tnsnames.ora` / `sqlnet.ora`, web tier: every configuration file of Nginx / Apache (+ `mod_wl`) / OHS incl. all includes |
| `ihw_import/` | proposals laid out for the library (nothing applied): `formsweb.cfg.default_overrides` / `.sections`, `default.env.customer_keys` (`FORMS_PATH_CUSTOMER`, `CLASSPATH_CUSTOMER`), `webutil.cfg.overrides`, `cgicmd.dat.customer_keys` (without Oracle's sample keys), `uifont.ali.customer`, `custom_fonts_dir/`, `forms_java/` + `jars.txt`, `reports_servers.txt`, `environment.conf.proposal`, `web_tier.txt` (routing) + `web_tier_settings.txt` |
| `sources_inventory.csv`, `sources_files.txt`, `sources_dependencies.txt` | every configured Forms / Reports source directory (`FORMS_PATH`, `REPORTS_PATH`, `folderAccess`, `sourceDir`, WebUtil transfer dirs, icon path) with file counts per type; attached libraries / menus per `.fmx` (heuristic, `strings`), missing referenced files, TNS aliases vs. `tnsnames.ora` |
| `manifest.csv`, `secrets_locations.txt` | `category;source;stored;size;sha256`; where passwords are (file:line:keyword, never the value) |

**Never in the archive:** module files (`.fmb .fmx .pll .plx .mmb .mmx
.olb .rdf .rep`) – only their paths and counts; `frm*.jar` and `jacob*.jar`
(FSAL / JACOB come from our 14- / 40- logic and are never overwritten);
free fonts (Liberation / DejaVu / Carlito / Caladea – OS packages, 14b-
deploys them).

**Fonts – three classes** (`ihw_import/fonts.txt` column `class`, grouped in
`00_report.txt`, since 2026-11-03.3):

| Class | Example | On 14c |
|---|---|---|
| `customer` | barcode (`IDAutomationC128L.ttf`), corporate fonts | must move – no replacement |
| `ms` | `arial*`, `times*`, `cour*`, `verdana*`, `calibri*`, Arial Unicode MS, Wingdings | licensed with Windows / Office **of the customer** – never into the library or git. 14c uses the free replacement: Arial / Times New Roman / Courier New / Arial Narrow / Calibri → Liberation / Carlito with **identical metrics** (same line breaks; Cambria → Caladea not set up yet); Verdana / Tahoma / Georgia … → DejaVu / Liberation only **similar** (line breaks and field widths can shift); symbol fonts (Wingdings, Symbol) have no replacement. The Windows licence does **not** allow copying these fonts to another server ("You may not copy them to other computers or servers", Microsoft font FAQ) – the original on the new server only with extended rights (Monotype / foundry). |
| `free` | Liberation, DejaVu | skipped – `14b-` deploys the OS packages |

All `customer` and `ms` files are copied into `ihw_import/custom_fonts_dir/`
(the export is the input for that decision). The import step must take only
`customer` plus the `ms` fonts the customer released. Mapping and PDF
background: [reports_fonts_architecture.md](../../80-FMW-Architecture/reports_fonts_architecture.md)
(licences, metric compatibility, migration path), [04-ReportsFonts/README.md](../../04-ReportsFonts/README.md)
(§7 "Windows-Specific Fonts on Linux": metric-compatible replacements, fonts requiring the original TTF, licence note).

**Customer data:** the export contains passwords, host names and paths – it
never goes into git (refused inside the repo; `.gitignore` has
`ihw_export_*` and `70-Customer-Projects/**/export/` for a copy placed there
for the import). Tested 2026-11-03 on 14.1.2 and on a simulated 12.2.1 tree
(`forms_12.2.1` / `reports_12.2.1`, standalone + in-process server).

## analyse_forms_reports_export.sh

Step 2 of the 12c/14c → 14c migration (step 1 = `export_forms_reports_conf.sh`
at the customer, step 3 = the import into the library – still open). It turns
one export into a **structured report** the customer gets ("this is how we
build it in 14c"):

```bash
# on our host - the export (encrypted .zip.enc, masked .zip or an unpacked directory)
tools/bash/analyse_forms_reports_export.sh -i ihw_export_<host>_<ts>.zip.enc -k <customer>
tools/bash/analyse_forms_reports_export.sh -i <export> -k <customer> --ref-home /u01/app/oracle/fmw   # 14c templates as reference
```

| Option | Meaning |
|---|---|
| `-i` | the export: `.zip.enc` (passphrase asked hidden, passed to openssl via fd), `.zip`, `.tar.gz` or a directory |
| `-k` | short customer name – run directory `<date>_<customer>`, report name |
| `-o` | base directory (default `tools/customer-analyse/`); inside a git work tree it is **refused** unless git ignores it |
| `--ref-home` | 14c `ORACLE_HOME` (default `$ORACLE_HOME`, else `/u01/app/oracle/fmw`) – customer keys are compared with Oracle's 14.1.2 templates (`forms/templates/config/formsweb.cfg`, `default.env`, `webutil.cfg`); without it these rules are listed as "not checked" |
| `--fresh` | unpack the export again (default: reuse `export/` of an earlier run) |

**Output** (`tools/customer-analyse/<date>_<customer>/`, git-ignored – only
the README, the template and `rules/` are committed):

```
export/                                 the unpacked export (clear text with an encrypted export!)
csv/                                    every table as ';'-CSV (findings.csv, jars.csv, tns.csv ...)
import_analyse_<customer>_<date>.md     the report
```

**Report** (template
[customer-analyse/import_analyse_template.md](customer-analyse/import_analyse_template.md)):
summary, Forms sections + `[default]` against the 14c standard + all keys of
the customer sections, env files + differing keys, WebUtil, customer jars
(signature, digest, signer expiry + timestamp, class version, duplicates),
Reports servers (engines read from `rwserver.conf`), `rwservlet.properties`,
`cgicmd.dat` key names, fonts (class + 14c replacement; free fonts as one line
per directory), source directories (one line for many sibling directories,
e.g. per-user homes), dependencies (libraries used / missing), TNS aliases
(defined / used / not defined), secrets (counted: active lines and all
keyword hits – never a value), the 14c target table, the
`environment.conf` proposal, the findings.

**Findings** – one row `severity;area;finding;recommendation`, security
first, WARN > HINT > INFO. Examples of the rules:

| Area | Rule |
|---|---|
| Security / Forms | `userid` stored in a section (clear text / `{AES}` encrypted), `allow_debug=true`, `restrictedURLparams` shorter than the 14c standard, client trace, `http://` URLs, `FORMS_RESTRICT_ENTER_QUERY=FALSE`, password keywords on active env file lines |
| Security / WebUtil | `transfer.appsrv.accessControl=FALSE`, `/tmp` as transfer directory, `transfer.database.enabled`, own `install.syslib` DLLs (not JACOB) |
| Security / Reports | no encrypted `<identifier>`, no `securityId`, no `<folderAccess>`, `webcommandaccess` L2, `cgicmd.dat` keys with logins, world-writable read / write directories |
| Security / WebLogic, net | production mode, empty `listen-address`, demo keystores, Node Manager, `-D…password` in start scripts, `sqlnet.ora` encryption |
| Security / web tier (Nginx, Apache + `mod_wl`, OHS) | `/console` `/em` (and other WLS admin paths) routed without allow / deny / `Require`, old TLS protocols (SSLv3 / TLS 1.0 / 1.1, Apache `all` without `-TLSv1 -TLSv1.1`, OHS `nzos_Version_1_0/1_1`), HTTPS without a protocol list, plain HTTP routed to WebLogic, `TraceEnable on`, `DebugConfigInfo ON`, directory listing, version shown (`server_tokens`, `ServerTokens`), backends reached over the network; routes not covered by the 14c Nginx template (table 13.2) |
| Security / Jars | unsigned, SHA-1 / MD5 signature (JDK 21 = unsigned), signer expired without timestamp (WARN) / with timestamp (HINT), expiring in 90 days (`keytool -printcert -jarfile`, read only) |
| Oracle Net | aliases unused / used but not defined / defined twice, `SID=`, IP as host, several TNS_ADMIN – usages read from the active lines only, Oracle's `cgicmd.dat` sample keys and Kerberos principals ignored |
| Forms runtime (rules of `06-FormsDiag`) | timeout chain `heartBeat` < `FORMS_TIMEOUT` < servlet session-timeout (own table 3.2), `maxRuntimeProcesses` missing (DoS), prestart pool in `[default]` / none at all, `networkRetries=0`, `gzipCompressApplet`, no `time-taken` in the WLS_FORMS access log, env values with the old host name – recommendations point to `06-FormsDiag/forms_perf_settings.sh` / `forms_perf_analyse.sh` and `environment.conf` |
| Reports engines (rules of `05-ReportsPerformance`) | `engLife` < 10 (workaround – question to the customer, our measured approach as alternative), no `engineResponseTimeOut`, obsolete engine JVM options (`-Xoss`, PermGen, CMS), tiny `-Xms`, identical engine blocks on several servers, leftover in-process server that is still the rwservlet default |
| Forms / Jars / Reports / Fonts / Sources | keys not in the 14c template (minus [rules/formsweb_14c_known_keys.txt](customer-analyse/rules/formsweb_14c_known_keys.txt)), overrides equal to the 14c default, missing env files / jars, case / content duplicates, unreferenced jars, short `engLife`, in-process server, shared broadcast port, Microsoft / symbol / customer fonts, missing or world-writable source directories, `.fmb` without `.fmx`, missing libraries |

**Safety:** every value passes `ihwt_mask`; alias names are the only thing
read from an unmasked login (`user/pw@ALIAS` → `ALIAS`); the finished report
is searched for clear-text patterns (`password=…`, `{AES}…`,
`<identifier>…</identifier>`, `user/pw@`) and **deleted** on a hit. The report
still holds host names, paths and user directory names of the customer – hand
it only to that customer.

Export version 2026-11-05.3 adds the **web tier**: Nginx, Apache httpd with
the WebLogic plug-in (`mod_wl`) and OHS – also a standalone OHS web tier
domain – are found from the running processes (`nginx: master -c`,
`httpd -f / -d`), the default paths and a bounded search; every configuration
file **including all includes** is stored below `raw/other/…` (shared lib
functions `ihwt_webtier_find` / `_flatten` / `_routes` / `_settings`, no
binary and no root needed – files the owner cannot read are listed as
warnings). `ihw_import/web_tier.txt` holds one row per route
(`type;conf;listen;server_name;tls;protocols;path;target;access;cert`),
`web_tier_settings.txt` the rated directives. The certificate subjects now
come from **every** HTTPS listener (`openssl s_client` with the server name,
else the certificate file) – before only OHS `ssl.conf` was read, so a
customer with TLS on Nginx / Apache had no subject. `WLS_SERVER_FQDN` is
taken from the `server_name` of the HTTPS route to `/forms`; the analysis
maps every route to the 14c Nginx (section 13.2) and proposes
`ADMIN_IP_RANGE`. `collect_fmw_env.sh` 2026-11-05.2 uses the same functions
(`61_webserver.txt`: routing table, rated directives, configuration with the
includes inlined, masked).

Export version 2026-11-04.5 additionally collects the JDBC descriptors
`config/jdbc/*-jdbc.xml` (RCU data sources, `ihw_import/jdbc.txt`:
URL + schema user, passwords stay `{AES}` / masked), the public part of the
certificates (`ihw_import/certificates.txt`: subject / issuer / expiry of the
OHS HTTPS listeners and of the jar signers) and puts ports, listen address,
old public name and the RCU database into `environment.conf.proposal`. The
report shows them as the checklist **13.1 Values for the 14c
environment.conf** (from export / decision / asked / secret / missing).

Export version 2026-11-04.3 additionally collects the `weblogic.xml` /
`web.xml` of `formsapp.ear` (servlet session-timeout for the timeout chain)
and CPUs / RAM of the host (header of `00_report.txt` – sizing proposals);
older exports list these rules under "not checked".

Tested 2026-11-04: test-host export (masked, 14.1.2) and the first real
customer export (12.2.1.4, export version 2026-11-03.1 without the font class
column – computed by the analysis).

## ihw_tools_lib.sh

Shared helpers of the tools in `bash/` – **not** the IHateWeblogic library
(`00-Setup/IHateWeblogic_lib.sh`): no `environment.conf`, no
`ok`/`warn`/`fail`, functions only (prefix `ihwt_`), no output when sourced.
The tools source it from their own directory; the road map copies all
`tools/bash/*.sh`, so it always lies next to them.

| Function | Purpose |
|---|---|
| `ihwt_mask` | stdin → stdout, secrets masked (`<…password…>`, `<identifier>`, `{AES}`, `userid=` / `authid=` / `password=`, `-D…password=`, `user/pw@`) |
| `ihwt_sections FILE` / `ihwt_keys FILE` / `ihwt_cfgval FILE KEY` | ini / key=value parsing (formsweb.cfg, env files, webutil.cfg) |
| `ihwt_font_class NAME` | `class;replacement` of a font file (customer / ms / free) |
| `ihwt_git_guard DIR NAME` | refuse customer data inside a git work tree unless ignored |
| `ihwt_md_table "Col1;Col2"` | `;`-CSV on stdin → Markdown table (`_none found_` when empty) |

Used by `export_forms_reports_conf.sh` (since 2026-11-04.1 – output checked
identical before / after) and `analyse_forms_reports_export.sh`.

## set_script_env.sh and the operation tools

Moved here on 2026-11-04 from `Reports14_linux_manual_install/tools/`; the
former `env.ini` (operation) and `install.ini` (installation) are now **one**
`patch_install.ini` per customer folder, the former `set_env.sh` (PATH,
`wlst`, `domain`) is replaced by `setdb`
([ihw_shell_env.sh](#ihw_shell_envsh), it puts `$ORACLE_BASE/tools` into the
PATH at login – variable `IHW_TOOLS_DIR`).

On the host everything lies in one directory:

```
$ORACLE_BASE/tools/
  status.sh  show_log.sh  show_errors.sh  show_all_logs.sh  set_script_env.sh  (755)
  patch_install.ini                                                            (600)
```

```bash
. $ORACLE_BASE/tools/set_script_env.sh     # values for the cookbook commands
set_script_env_show                        # check: all values of the ini

status.sh -q                               # reads patch_install.ini itself
IHW_INI=/path/other.ini status.sh          # another ini (test, second domain)
```

| Value in `patch_install.ini` | Used by |
|---|---|
| `DOMAIN_HOME`, `DOMAIN_NAME`, `ORACLE_HOME` | all four tools |
| `ADMIN_SERVER`, `WLS_ADMIN_PORT`, `MANAGED_SERVERS` (`name:port …`) | `status.sh`, `show_log.sh` |
| `REPORTS_SERVERS` (default `$REPORTS_SERVER_NAME`) | `status.sh`, `show_log.sh` |
| `NM_HOST`, `WLS_NODEMANAGER_PORT`, `NM_TYPE`, `WLST_CONFIG_FILE`, `WLST_KEY_FILE` | `status.sh` stage 3 (Node Manager via WLST, storeUserConfig files) |
| `EXTRA_PORTS` | `status.sh` stage 1 (e.g. Nginx `80 443`) |
| `LOG_MINUTES` | `show_all_logs.sh`, `show_errors.sh` |

No passwords in the ini. Cookbook:
[Tools_status_logs_kochbuch.txt](../Reports14_linux_manual_install/Tools_status_logs_kochbuch.txt).
Tested 2026-11-04 on the test host from a scratch copy (`status.sh -q`:
all OK, `set_script_env_show`).
