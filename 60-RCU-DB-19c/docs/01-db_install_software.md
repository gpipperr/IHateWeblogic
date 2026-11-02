# Step 1 – 01-db_install_software.sh

**Script:** `60-RCU-DB-19c/01-db_install_software.sh`
**Runs as:** `oracle`
**Phase:** Install Oracle 19c Database software + patches in one step

---

## Purpose

Install Oracle 19c into the **patched** `DB_ORACLE_HOME` (e.g. 19.33.0) in one
run: from a gold image, or from the 19.3 base with the RU applied by `opatch`
into the image before the installer runs. No separate patching step, no
`cp -a`, no unpatched base home. `--target-home` builds an **additional** home
for the out-of-place patch of a running database (`09-db_patch_rcu.sh`).

Flow (as in the script):
0. Disk space check (first, also in the dry-run), pre-checks
   (`DB_INSTALL_ARCHIVE` present – on every route, `DB_AUTOUPGRADE_HOME`),
   "already registered" check (a complete registered home ends the run here)
1. `--clean`: processes from the home (DB → FAIL, listener → stopped),
   detach + remove the home and `base_stage`
2. Extract the 19.3 base ZIP to `base_stage` – **only** when AutoUpgrade has to
   download (it is its `source_home` + Java); skipped with patch ZIPs / a gold
   image in `patchdir` or offline ZIPs in `$PATCH_STORAGE/database/patches/`
3. Patch set: `--fresh-patches` moves the old set (incl. a gold image) to
   `patchdir_<timestamp>/`; offline ZIPs are **linked** into an empty
   `patchdir`; otherwise AutoUpgrade (newest `autoupgrade.jar`, MOS keystore)
   downloads `recommended,jdk`
4. Space check of the unpacked ZIPs (`zipinfo -t`), unpack them to
   `patch_stage/`, identify the RU (`bundle.xml`, or `etc/config/inventory.xml`
   "Database Release Update") and the OneOffs
5. `/etc/oraInst.loc` check (created via `sudo` if missing), then the install
   route ([Installation routes](#installation-routes)):
   - **gold image** in `patchdir` → unpack as the home, newest OPatch,
     `runInstaller`, OneOffs with `opatch apply`
   - **RU ZIP** (default) → 19.3 base into the home, newest OPatch,
     `attachHome`, RU + OneOffs with `opatch apply`, `lspatches` check,
     `detachHome`, `runInstaller` on the patched image
   - `--apply-ru-installer` → `runInstaller -applyRU … -applyOneOffs …`
     (fails on FMW hosts – research only; ignored when a gold image is present)
6. Checks: home registered, no image build path in `bin/`; `patch_stage` removed
7. `root.sh` (`sudo -n`, else prompt) + `chopt disable olap` / `rat`
8. Verification (`opatch lspatches`, OPatch version) + next-step hint

`uniaud_on` relink is NOT done here – a manual step after DBCA with database
and listener down ([04-db_audit_setup.md](04-db_audit_setup.md#prerequisites));
`03-` only reports it, `09-db_patch_rcu.sh` relinks a new home.

## Options

| Option | Effect |
|---|---|
| (none) | Dry-run: disk space, pre-checks, configuration; no change |
| `--apply` | Extract / link / download as needed + install |
| `--clean` | Dry-run of the clean: processes from the home, what would be removed |
| `--clean --apply` | Stop the listener of the home, detach + remove the home and `base_stage`, then install (patch ZIPs are kept) |
| `--target-home DIR` | Install into DIR (absolute, not the running home); `environment_db.conf` unchanged |
| `--fresh-patches` | Move `patchdir/p*.zip`, `db_goldimage_*.zip`, `patches_info.json` to `patchdir_<timestamp>/` first → current set |
| `--apply-ru-installer` | RU via `runInstaller -applyRU` (fails on FMW hosts – research only) |

Exit codes: 1 = unknown option / bad `--target-home` / WARN (e.g. `root.sh`
not confirmed), 2 = FAIL.

---

## Prerequisites

- `/etc/oraInst.loc` exists (FMW host: `09-Install/03-root_user_oracle.sh`;
  DB-only host: `00-root_db_os_baseline.sh --apply`; fallback: `01-` creates
  it via `sudo`). It must point to `ORACLE_INVENTORY` – on a mismatch `01-`
  only WARNs and uses the existing pointer: fix the config, never re-point
  it (FMW is registered there)
- `00-root_db_os_baseline.sh --apply` completed (groups, limits,
  `libpthread_nonshared.a`, `expect`)
- Recommended: `00b-db_cvu_check.sh --apply` (standalone CVU, `cluvfy comp sys -r 19`)
  without unexpected FAILED items — [00b-db_cvu_check.md](00b-db_cvu_check.md)
- Oracle 19c base ZIP at `DB_INSTALL_ARCHIVE`
  (default `$PATCH_STORAGE/database/LINUX.X64_193000_db_home.zip`; manual
  download, see below) – checked on **every** route, also with a gold image
- `environment_db.conf` from `00a-db_env_interview.sh --apply`
- Free space (checked first, also in the dry-run): new home min 12 / rec 15 GB
  (`DB_HOME_MIN_FREE_GB` / `DB_HOME_REC_FREE_GB`), AutoUpgrade staging min 8 /
  rec 14 GB (`DB_STAGE_MIN_FREE_GB` / `DB_STAGE_REC_FREE_GB`), 6 GB less when
  no `base_stage` is needed (floor 2 / 4). One file system: the sum –
  20 / 29 GB with, 14 / 23 GB without AutoUpgrade download. Second check before
  unpacking: unpacked size of the ZIPs + 10 % (+ the home, same file system)
- MOS credentials in `mos_sec.conf.des3` (`00-Setup/mos_sec.sh --apply`) –
  only for the AutoUpgrade download; not needed when `patchdir` holds the set
  or the offline ZIPs exist under `$PATCH_STORAGE/database/patches/`

---

## Base ZIP Download (manual, one-time)

> **The Oracle 19c base ZIP cannot be downloaded automatically.**
> Oracle eDelivery requires a browser session and license agreement acceptance.

### Manual download steps

Simplest: **https://www.oracle.com/database/technologies/oracle19c-linux-downloads.html**
(Oracle account login) → *Oracle Database 19c (19.3) for Linux x86-64*, ZIP –
the file is already called `LINUX.X64_193000_db_home.zip`, same SHA-256 as
below. Alternative eDelivery:

1. Log in at **https://edelivery.oracle.com** with your Oracle account
2. Search for: `Oracle Database 19c Enterprise Edition 19.3.0.0.0`
   (or SE2 — the ZIP file is identical)
3. Select Platform: **Linux x86-64** and add to cart
4. Accept the license agreement and download

### File details

| Field | Value |
|---|---|
| Part number | `V982063-01` |
| Filename | `V982063-01.zip` → place as `LINUX.X64_193000_db_home.zip` |
| Size | 2.8 GB |
| SHA-256 | `BA8329C757133DA313ED3B6D7F86C5AC42CD9970A28BF2E6233F3235233AA8D8` |

```bash
sha256sum V982063-01.zip
scp V982063-01.zip oracle@dbserver:$PATCH_STORAGE/database/LINUX.X64_193000_db_home.zip
```

> EE and SE2 deliver **the same ZIP file** — edition is determined by the license.

---

## Patch Download (AutoUpgrade)

`autoupgrade.jar` is downloaded automatically from oracle.com (no auth required).

MOS credentials (`mos_sec.conf.des3`) are used to download the RU, OJVM, OPatch,
and DPBP ZIPs from My Oracle Support.

The downloaded ZIPs are stored in `$DB_AUTOUPGRADE_HOME/patchdir/` and **reused
on subsequent runs** — delete them only to force a re-download.

```bash
DB_AUTOUPGRADE_HOME/
├── bin/autoupgrade.jar            ← newest (previous kept as autoupgrade.jar.<version>)
├── config/db19patch.cfg           ← download config (generated)
├── config/keystore.cfg
├── keystore/                      ← MOS keystore (auto-login) + flag .mos_configured
├── logs/
├── patchdir/                      ← patch set (kept across runs; offline route: symlinks)
│   ├── db_goldimage_19_33_*.zip   ← gold image (online "recommended", 4.9 GB)
│   ├── p39915792_*.zip            ← DB RU 19.33 (offline route; inventory.xml "Database Release Update")
│   ├── p39803650_*.zip            ← OJVM RU 19.33       (OneOff)
│   ├── p39902051_*.zip            ← JDK bundle patch    (OneOff)
│   ├── p40057600_*.zip            ← Data Pump bundle    (OneOff)
│   ├── p6880880_*.zip             ← OPatch 12.2.0.1.55
│   └── patches_info.json
├── patchdir_<timestamp>/          ← previous set (--fresh-patches)
├── patch_stage/                   ← unpacked patches (removed after success)
└── base_stage/                    ← 19.3 base, only for the AutoUpgrade download (removed by --clean)
```

`DB_TARGET_RU` in `environment_db.conf` → AutoUpgrade `patch1.patch`:
- `RECOMMENDED` (default) → `recommended,jdk` – AutoUpgrade 26.6 delivers a
  gold image `db_goldimage_19_<ru>_*.zip` + OJVM / DPBP / JDK / OPatch
- `19.33` → `ru:19.33,ojvm:19.33,opatch,dpbp,jdk` – fixed, reproducible
- **not** `19.CURRENT` / `19.LATEST` – rejected by AutoUpgrade 26.x ("The patch
  parameter for prefix patch1 includes a value that is not supported"); `01-`
  falls back to `recommended,jdk` with a WARN
- any other value is passed to `patch1.patch` unchanged

### AutoUpgrade download by hand

```bash
AU=$DB_AUTOUPGRADE_HOME
unzip -q $DB_INSTALL_ARCHIVE -d $AU/base_stage          # source_home + Java 8
curl -fsSL -o $AU/bin/autoupgrade.jar https://download.oracle.com/otn-pub/otn_software/autoupgrade.jar
cat > $AU/config/db19patch.cfg <<CFG
global.global_log_dir=$AU/logs
global.keystore=$AU/keystore
patch1.source_home=$AU/base_stage
patch1.folder=$AU/patchdir
patch1.patch=recommended,jdk
patch1.target_version=19
patch1.download=YES
CFG
$AU/base_stage/jdk/bin/java -Dhttps.protocols=TLSv1.2 -jar $AU/bin/autoupgrade.jar \
    -config $AU/config/db19patch.cfg -patch -mode download
```

### Offline patches (host without MOS)

1. On a host with MOS:
   `70-Customer-Projects/tools/mos_patch_download.sh -c 09-Install/download/patches_db.csv -d $PATCH_STORAGE --apply`
   → `$PATCH_STORAGE/database/patches/<nr>/p<nr>_*.zip` (SHA-256 checked against the CSV)
2. Copy `$PATCH_STORAGE/database/` to the DB host (same path)
3. `01-` links them (`ln -sfn`) into an **empty** `patchdir` – no AutoUpgrade,
   no MOS, no Java, no `base_stage`. By hand:
   `ln -s $PATCH_STORAGE/database/patches/*/p*.zip $DB_AUTOUPGRADE_HOME/patchdir/`
4. The RU of the list (19.33 = **39915792**, 2.2 GB) takes the base route
   ("patch first, then install")

As long as `$PATCH_STORAGE/database/patches/` holds ZIPs, `--fresh-patches`
links them again instead of downloading. A gold image of another host can be
copied into `patchdir` instead – together with the OneOff ZIPs (OJVM, DPBP,
JDK, OPatch) of the same `patchdir`.

### MOS keystore

MOS credentials are stored **once** in the AutoUpgrade keystore
(`$DB_AUTOUPGRADE_HOME/keystore/`, auto-login) and reused. `01-` fills it with
`expect` (installed by `00-root_db_os_baseline.sh`) from `mos_sec.conf.des3`;
the keystore password is `IHateWeblogic-<hostname -s>`. `keystore.cfg` holds
`global.global_log_dir` + `global.keystore`. Manual equivalent (same
`-Dhttps.protocols` flag as the download):

```bash
java -jar "$DB_AUTOUPGRADE_HOME/bin/autoupgrade.jar" \
    -config "$DB_AUTOUPGRADE_HOME/config/keystore.cfg" -patch -load_password
# Enter password: / again:            <- keystore password
# MOS> add -user your.email@example.com
# Enter your secret/Password: / again <- MOS password
# MOS> exit
# Save ... [YES|NO] ? YES   /   Convert ... to auto-login [YES|NO] ? YES
```

AutoUpgrade 26.x: `-mode setmospassword` was replaced by `-load_password`,
`group mos` is no longer needed. Changed MOS credentials:
`rm -rf "$DB_AUTOUPGRADE_HOME/keystore" && ./01-db_install_software.sh --apply`
(the whole directory – `keystore/*` misses the flag `.mos_configured`, the
keystore would not be refilled).

**TLS by Java version** (set by `01-` automatically): Java 8 (JDK of the 19.3
base, `base_stage/jdk`, used first) `-Dhttps.protocols=TLSv1.2` – TLSv1.3
throws `IllegalArgumentException`; Java 11+ (`java-11-openjdk`, or the JDK of
the running DB home) `TLSv1.3`; not Java 21. Java is only needed for the
download. AutoUpgrade talks to `login-ext.identity.oraclecloud.com`
and `updates.oracle.com` – a host without egress uses the offline route
(`patches_db.csv`, `PATCH_STORAGE`).

---

## DB home JDK patch and AutoUpgrade version

The DB RU also replaces `$ORACLE_HOME/jdk` – but with the JDK of the
**previous** quarter (confirmed (live) 2026-10-28: RU 19.30 of January 2026
→ `1.8.0_471-b09`; the RU's `actions.xml` contains ~2,000 actions under
`jdk/`). The current JDK comes with the separate **JDK bundle patch**, which
AutoUpgrade downloads with the keyword **`jdk`** – it is **not** part of
`recommended` (our March 2026 download with AutoUpgrade 26.2: RU, OJVM, DPBP,
OPatch only). `01-` therefore uses `recommended,jdk` (or
`ru:<v>,ojvm:<v>,opatch,dpbp,jdk`); the JDK patch lands in `patchdir/` and is
applied with `opatch apply` like the other OneOffs (base route before the
installer, gold image after it; `-applyOneOffs` only with
`--apply-ru-installer`).

| Item | Value (CPU Oct 2026, checked 2026-10-28) |
|---|---|
| AutoUpgrade | **26.6.260925** – `01-` downloads the newest `autoupgrade.jar` before every patch download and keeps the previous one as `autoupgrade.jar.<version>` (keywords change between releases) |
| `jdk` → | patch **39902051** "JDK BUNDLE PATCH 19.0.0.0.261020" (`p39902051_190000_Linux-x86-64.zip`, SHA-256 `8F9D82C0…53ED51`) – tested: AutoUpgrade 26.6 with `patch=jdk` / `opatch,jdk` |
| Content | JDK `1.8.0_511-b09` (own build line of Oracle homes – not comparable with the b-numbers of the public JRE); files 2026-09-22 → CPU level; **not** the level of the Java alerts of 21 / 24 Oct 2026 (`cacerts` still with the emSign roots, `blacklisted.certs` = list of 2024) |
| OPatch | `opatch` → 12.2.0.1.55 (Oct 2026); the JDK patch needs ≥ 12.2.0.1.52 |
| Existing home | `cd <dir>/<nr>; $ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./; opatch apply` – **no** database shutdown needed (README); rollback `opatch rollback -id <nr>`; with Examples installed first `chmod -R 755 $ORACLE_HOME/jdk` |
| Each cycle | AutoUpgrade takes the newest revision automatically; check its content (emSign roots gone from `cacerts` = alert level) |

## Additional home for patching (`--target-home`)

For the next RU of a **running** database `01-` builds a second home next to
the running one; `09-db_patch_rcu.sh` then moves the instance
([09-db_patch_rcu.md](09-db_patch_rcu.md)):

```bash
./60-RCU-DB-19c/01-db_install_software.sh --target-home $ORACLE_BASE/product/19.33.0/db_home1 --fresh-patches --apply
```

The route (gold image or patch first, then install) is the same as for a
first install – see [Installation routes](#installation-routes).

`--target-home` keeps `DB_ORACLE_HOME` / `environment_db.conf` unchanged.
Home name in the central inventory: `OraDB19Home1` for the first install,
`OraDB19Home_<version dir>` for `--target-home` (non-alphanumeric characters
→ `_`, e.g. `OraDB19Home_19_33_0`); an existing name gets `_YYYYMMDD`.
`--fresh-patches` moves the old set (patch ZIPs, gold image,
`patches_info.json`) to `patchdir_<timestamp>/` – before 2026-11-02 an old
gold image stayed and won over the new download. Disk space: see
[Prerequisites](#prerequisites).

## Installation routes

19c is an **image-based** install: `runInstaller` must run from the home it
installs (`base_stage/runInstaller` with `ORACLE_HOME=<new home>` stops with
rc=1 "The Oracle home is the location from where setup script is executed",
customer 2026-11-02). `01-` therefore always unpacks into `DB_ORACLE_HOME`
first and puts the newest OPatch (p6880880, 12.2.0.1.55 for 19.33) into it.

| `patchdir` contains | Route | State |
|---|---|---|
| `db_goldimage_*.zip` (RU ZIP too or not; a gold image alone counts as the patch set – no download) | gold image | live 2026-10-28 (19.33) |
| RU ZIP, no gold image | patch the image with `opatch`, then install (default) | live test host 2026-11-02 (19.33, `--target-home`, rc=6, 41 OK) |
| RU ZIP + `--apply-ru-installer` | `runInstaller -applyRU` | **fails on FMW hosts** |

### Patch first, then install (default without a gold image)

**Why this order:** the 19.3 base installer cannot link on OL9 (rc=252,
"Error in invoking target", see Troubleshooting) and stops **before**
"Setup files" and before registering the home. "Setup files" is the
instantiation: the image's scripts carry the build path of Oracle's image –
`bin/dbca` has `OH=/u01/app/oracle/product/19.0.0/dbhome_1` until the
installer replaces it. The first version of this route (2026-11-02: install,
rc=252 accepted, `attachHome`, `opatch`, `relink all`) left those paths in
place – `dbca` then failed with `…/19.0.0/dbhome_1/bin/platform_common: No
such file or directory` (customer, `03-`). So the RU goes into the **image**
first; its `runInstaller` then links with the RU makefiles, instantiates and
registers – like a gold image. (This is what `-applyRU` does internally, but
with `opatch` instead of `opatchauto`, which fails with "Invalid Home".)

For a fresh install no database uses the home yet – no second home needed;
the home directory gets the target name right away (`product/19.33.0/db_home1`).

```bash
export OH=$DB_ORACLE_HOME PS=$DB_AUTOUPGRADE_HOME/patch_stage
INV=$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc)/ContentsXML/inventory.xml
mkdir -p $OH && chmod 775 $OH
unzip -q $DB_INSTALL_ARCHIVE -d $OH
rm -rf $OH/OPatch
unzip -q -o p6880880_190000_Linux-x86-64.zip -d $OH          # OPatch 12.2.0.1.55 – mandatory
for z in $DB_AUTOUPGRADE_HOME/patchdir/p[0-9]*.zip; do       # RU + OneOffs (not p6880880)
    case $z in *p6880880*) ;; *) unzip -q -o $z -d $PS ;; esac; done
# 1. register the image temporarily - opatch needs the home in the inventory
$OH/oui/bin/runInstaller -silent -attachHome ORACLE_HOME=$OH ORACLE_HOME_NAME=OraDB19Home1
grep -c "LOC=\"$OH\"" $INV                                   # 1
# 2. RU first, then the OneOffs in patch-number order (OJVM, JDK bundle, Data Pump bundle)
for p in 39915792 39803650 39902051 40057600; do
    (cd $PS/$p && ORACLE_HOME=$OH $OH/OPatch/opatch apply -silent -oh $OH) || break
done                                                         # "OPatch succeeded", no "skipped"
ORACLE_HOME=$OH $OH/OPatch/opatch lspatches | grep '^39915792;'
# 3. unregister again - the installer registers the home itself
$OH/oui/bin/runInstaller -silent -detachHome ORACLE_HOME=$OH
# 4. install the patched image (links, instantiates, registers); rc 0 or 6 = OK
cd $OH
CV_ASSUME_DISTID=OEL7.6 ./runInstaller -silent -ignorePrereqFailure -waitforcompletion \
    oracle.install.option=INSTALL_DB_SWONLY ORACLE_BASE=$ORACLE_BASE \
    ORACLE_HOME=$OH ORACLE_HOME_NAME=OraDB19Home1 oracle.install.db.InstallEdition=EE \
    oracle.install.db.OSDBA_GROUP=dba oracle.install.db.OSOPER_GROUP=oper \
    oracle.install.db.OSBACKUPDBA_GROUP=dba oracle.install.db.OSDGDBA_GROUP=dba \
    oracle.install.db.OSKMDBA_GROUP=dba oracle.install.db.OSRACDBA_GROUP=dba \
    SECURITY_UPDATES_VIA_MYORACLESUPPORT=false DECLINE_SECURITY_UPDATES=true
grep -c "LOC=\"$OH\"" $INV                                   # 1 – registered
grep -lI /u01/app/oracle/product/19.0.0/dbhome_1 $OH/bin/*   # nothing – instantiated
rm -rf $PS
```
Then [After Installation](#after-installation).

`01-` checks each `opatch apply` on its output (a "SKIPPED" / "not
applicable" patch is a failure, the benign "re-links will eventually be
skipped because they are duplicates" is ignored), that the RU is listed in
`opatch lspatches`, that attach / detach changed the inventory, and after the
installer that the home is registered and no `bin/` script still contains
`/u01/app/oracle/product/19.0.0/dbhome_1`. Unlike the gold image this home
has no OCW RU – not needed for a single instance without GI/ASM.

**Repair of a home from the first version** (registered, patched, but
`dbca` with the image path): `detachHome`, then step 4 from the home – or
`01- --clean --apply`.

### Gold image

AutoUpgrade 26.6 `recommended` (19.33, live 2026-10-28) delivers
`db_goldimage_19_<ru>_*.zip` – a complete patched home with RU and OCW RU
(4.9 GB) – instead of an RU ZIP. When a gold image lies in `patchdir`, `01-`
takes it (an RU ZIP beside it is extracted but not used). `01-` unpacks it as
the new home, puts the newest OPatch into it, runs its `runInstaller` without
patches (rc 6 = success with warnings) and applies the OneOffs (OJVM, JDK
bundle, Data Pump bundle) with `opatch apply` – `-applyOneOffs` rejected the
OJVM RU as "not applicable" on the gold image. No `base_stage`. Unpacked 19.33
home + OneOffs: 11 GB. A gold image can be copied from another host
(together with its OneOff ZIPs, see [Offline patches](#offline-patches-host-without-mos)).

```bash
export OH=$DB_ORACLE_HOME PS=$DB_AUTOUPGRADE_HOME/patch_stage
mkdir -p $OH && chmod 775 $OH
unzip -q db_goldimage_19_33_*.zip -d $OH
unzip -q -o p6880880_190000_Linux-x86-64.zip -d $OH          # newest OPatch (over the old one)
cd $OH
CV_ASSUME_DISTID=OEL7.6 ./runInstaller -silent -ignorePrereqFailure -waitforcompletion \
    <same arguments as step 4 above>                         # rc 0 or 6 = OK
for p in 39803650 39902051 40057600; do                      # OneOffs unpacked to $PS
    (cd $PS/$p && ORACLE_HOME=$OH $OH/OPatch/opatch apply -silent -oh $OH) || break
done
```
Then [After Installation](#after-installation).

### runInstaller -applyRU (`--apply-ru-installer`, research only)

> **State 2026-11-02: this route is NOT working on an FMW host with a shared
> central inventory.** `runInstaller -applyRU` attaches the unpacked home
> temporarily ("tempGIName"), runs `opatchauto apply <RU> -binary` and
> detaches it again – opatchauto then stops with `Invalid Home :
> <DB_ORACLE_HOME>` / "… is not applicable to the oracle home" (prereqs
> `checkPatchApplicable`, `checkConflictAgainstOHWithDetail` … "NOT
> ATTEMPTED"). Seen on the test host in all five runs of March 2026 (RU
> 19.30 = 38632161; the attach logged `OUI-10053 Unable to generate
> temporary script …/orainstRoot.sh`) and at the customer 2026-11-02 (RU
> 19.33 = 39915792, OPatch 12.2.0.1.55). Cause not confirmed yet – to be
> researched on a test host (AttachHome log, inventory permissions).

```bash
CV_ASSUME_DISTID=OEL7.6 ./runInstaller -silent -ignorePrereqFailure -waitforcompletion \
    -applyRU /path/to/RU_patch_dir -applyOneOffs /path/to/OJVM_dir,... \
    oracle.install.option=INSTALL_DB_SWONLY ...
```

`CV_ASSUME_DISTID=OEL7.6` suppresses the `supportedOSCheck` NPE (MOS Doc ID
2584365.1) on all routes.

---

## After Installation

```bash
# as root (01- tries sudo -n first, else it prompts; not confirmed = WARN, exit 1):
$DB_ORACLE_HOME/root.sh

# as oracle:
export ORACLE_HOME=$DB_ORACLE_HOME
$ORACLE_HOME/bin/chopt disable olap        # rc<>0 = WARN (may already be disabled)
$ORACLE_HOME/bin/chopt disable rat

# Verify:
$ORACLE_HOME/OPatch/opatch lspatches
$ORACLE_HOME/OPatch/opatch version
$ORACLE_HOME/bin/sqlplus -V
```

---

## Re-running / --clean

```bash
# Fresh install (removes DB_ORACLE_HOME + base_stage; keeps patchdir ZIPs):
./01-db_install_software.sh --clean --apply
```

- A **registered** home normally ends `01-` with "installation complete";
  `--clean` goes past that check. A registered home whose `bin/dbca` still
  has the image path `/u01/app/oracle/product/19.0.0/dbhome_1` (not
  instantiated, first base-route version) is a FAIL with the hint to
  `--clean --apply`.
- A non-empty home that is **not** registered (a failed run) → FAIL
  "DB_ORACLE_HOME already exists" → `--clean --apply`.
- `--clean` alone (dry-run) lists the processes from the home and what would
  be removed.
- `--clean` checks the processes running **from** the home first: a
  database instance (`ora_pmon_*`, `oracle<SID>`) → FAIL, the home is not
  removed (`03-db_create_database.sh --clean --apply` first). A listener
  (`tnslsnr`, from `02-`) → stopped with `lsnrctl stop`; its `listener.ora`
  lives in `<home>/network/admin` and is removed with the home, so
  `02-db_setup_listener.sh --apply` runs again after the install (the
  systemd unit points to the same path and stays). A listener that survives
  `lsnrctl stop` → FAIL with the hint `sudo systemctl stop oracle-listener`.
- `detachHome` errors are ignored (the home is removed anyway).

---

## environment_db.conf Variables Used

```bash
ORACLE_BASE            # shared with FMW (from environment.conf)
ORACLE_INVENTORY       # must match /etc/oraInst.loc (from environment.conf)
PATCH_STORAGE          # environment.conf – base ZIP, offline patches
DB_ORACLE_HOME         # target patched home, e.g. product/19.33.0/db_home1
DB_EDITION             # EE (default) | SE2
DB_INSTALL_ARCHIVE     # path to LINUX.X64_193000_db_home.zip
DB_AUTOUPGRADE_HOME    # AutoUpgrade work dir (patchdir, base_stage, …)
DB_TARGET_RU           # RECOMMENDED | 19.33 | own AutoUpgrade patch spec
DB_CV_ASSUME_DISTID    # OEL7.6 (default) – supportedOSCheck of the 19.3 installer
DB_HOME_MIN_FREE_GB / DB_HOME_REC_FREE_GB     # 12 / 15
DB_STAGE_MIN_FREE_GB / DB_STAGE_REC_FREE_GB   # 8 / 14
MOS_SEC_FILE           # default $ROOT_DIR/mos_sec.conf.des3 (00-Setup/mos_sec.sh --apply)
```

---

## Troubleshooting

### [INS-08101] supportedOSCheck NullPointerException

The 19.3.0 installer predates OL8/OL9.  Fixed by:
- `CV_ASSUME_DISTID=OEL7.6` (set by the script from `DB_CV_ASSUME_DISTID`)
- `-ignorePrereqFailure` flag

### rc=252 on OL9

The 19.3.0 base installer returns rc=252 on OL9 ("Error in invoking target"):
on the test host (2026-03) target `client_sharedlib` (`libasmclntsh19.ohso`),
at the customer (2026-11-02) target `all_no_orcl` / `orion` with
`libnnzst19.a(ccme_ck_rand_load_fileS1.o): undefined reference to 'stat'` –
the 19.3 objects/stubs predate glibc 2.33/2.34. The RU brings OL9-compatible
libraries and makefiles.

The installer stops in the link phase **before** "Setup files"
(instantiation) and before it registers the home. Hence the default route
patches the image first and installs it afterwards (see above) – with the RU
in the home the installer links on OL9. rc=252 from that installer is a FAIL.
A half-installed home from a failed run: `01- --clean --apply` (detach if
registered, remove, reinstall).

### "No RU identified"

`01-` takes as RU the extracted directory with a `bundle.xml` (system patch,
GI-style bundle) **or** whose `etc/config/inventory.xml` has the patch
description "Database Release Update" – the single DB RU from MOS (19.33 =
patch **39915792**, 2.2 GB, 5.1 GB unpacked) has **no** `bundle.xml`
(customer 2026-11-02; until then only `bundle.xml` was accepted). The FAIL
lists every extracted directory with size and patch description. Causes:

- **Disk full while unzipping** (customer 2026-10-30: 10 GB free on the staging
  file system) – the RU directory exists but is incomplete. Since 2026-10-30
  `01-` checks the unpacked size of all ZIPs (`zipinfo -t`) plus the new home
  (same file system) **before** extracting, and stops on an `unzip` error
  (the old pipe `unzip | tee` hid it).
- AutoUpgrade downloaded only individual patches (not a bundled RU): set
  `DB_TARGET_RU=RECOMMENDED` or `19.33`, then `--fresh-patches --apply`
  (or delete `patchdir/p*.zip`). With a gold image in `patchdir` this FAIL
  does not occur.
- Offline route: the RU row is in `09-Install/download/patches_db.csv`;
  the ZIPs are **linked** from `$PATCH_STORAGE/database/patches/` into
  `patchdir` (no second copy).

### `libpthread_nonshared.a` missing (OL9)

Relinks (`chopt`, `uniaud_on`, `opatch`) fail on OL9 with `ld: cannot find
/usr/lib64/libpthread_nonshared.a` – pthreads were merged into libc in RHEL 9.
An empty archive satisfies the linker (created by `00-root_db_os_baseline.sh
--apply`): `ar cr /usr/lib64/libpthread_nonshared.a; chmod 644 …`.

### "Cannot create /etc/oraInst.loc" / INS-32031

`/etc/oraInst.loc` must exist before `runInstaller` runs — the 19c installer
reads only `/etc/oraInst.loc` (not `$ORACLE_BASE/oraInst.loc`).

```bash
# FMW host: 09-Install/03-root_user_oracle.sh; DB-only host: 00-root_db_os_baseline.sh --apply
cat /etc/oraInst.loc
# Expected:
#   inventory_loc=/u01/app/oraInventory   ← ORACLE_INVENTORY
#   inst_group=oinstall
```

If missing: `01-` creates it via `sudo tee` (oracle needs sudo), else re-run
`00-root_db_os_baseline.sh --apply`. Pointing elsewhere: `01-` only WARNs –
fix `ORACLE_INVENTORY`, never re-point the file.
`ORACLE_INVENTORY` must be set in `environment_db.conf` (or derived from
`$(dirname "$ORACLE_BASE")/oraInventory` — the standard Oracle layout).

---

## History

Until 2026-03 a separate `02-db_patch_db_software.sh` cloned the installed
19.3 home (`cp -a`), fixed the hard-coded home path in `chopt` / `root.sh`
with `sed`, attached it and applied the patches with `opatch napply` (the
19.30 home of March 2026). It was replaced by the routes above and removed
on 2026-11-02 (stub and doc `02-db_patch_autoupgrade.md` are in the git
history). Background on AutoUpgrade `create_home` / PATCH109 "Invalid Home"
(the gold image ZIP has no `oraInst.loc`, OPatch error 106) is in that doc too.

References: [AutoUpgrade direct download](https://mikedietrichde.com/2024/11/21/download-autoupgrade-directly-from-oracle-com/),
[AutoUpgrade patching](https://mikedietrichde.com/2024/10/28/autoupgrades-patching-the-feature-you-waited-for/),
[AutoUpgrade / patch automation 19c (pipperr.de)](https://www.pipperr.de/dokuwiki/doku.php?id=dba:autouppgrade_patch_automation_19c).

---

## Next Step

```
02-db_setup_listener.sh --apply
```

With `--target-home`: `09-db_patch_rcu.sh --new-home <dir>` (dry-run first).
Before `04-`: manual `uniaud_on` relink ([04-db_audit_setup.md](04-db_audit_setup.md#prerequisites)).
