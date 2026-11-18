---
nav_title: "Manual guide – full"
title: "Install the CSPU November 2026 Patch Set – F&R 14.1.2 (full)"
description: "Step-by-step manual installation of the full CSPU November 2026 patch set on Oracle Forms & Reports 14.1.2 from any older level: OPatch, napply, start, verify."
---

# Install the CSPU November 2026 Patch Set – Forms & Reports 14.1.2 (manual, full)

Manual, step-by-step installation of the **complete cumulative CSPU
November 2026** patch set on an Oracle Forms & Reports 14.1.2.0.0 home
(FMW / WebLogic 14.1.2, Oracle Linux 9, Nginx frontend) on **any older
level** – without the IHateWeblogic scripts. A home on CPU October 2026
needs only the
[cumulative guide](install_14c_patch_set_november_2026_manual_cumulativ_from_cpu102026.md).
Every step names the script that automates it (doc-as-master).

**One run, not "October CPU + November CSPU":** KA1182 is cumulative – the
November list below already contains the patches released with the CPU
October 2026 (OPatch .25, Coherence CP10, WebCenter Core, OWSM, FMW Control,
OAMCLIENT, LibOVD, PERL, the QPRs). A never patched home needs exactly this
guide; the October guide is not needed first. Only the repository DB has
two layers (RU 19.33 of the CPU + MRP of the CSPU) – own window, see
[00-patch-references.md](../../09-Install/docs/00-patch-references.md#what-a-home-needs--cpu-vs-cspu-one-list-two-starting-points).

| | |
|---|---|
| Cycle | CSPU November 2026 (2026-11-17) |
| Starting point | any 14.1.2.0.0 level – up to a never patched home |
| Sources | KA1182 (2026-11-17), CPU450, CPU435, KB694158 (Nov 2026), the patch READMEs from the ZIPs ([README](README.md) section 3a, unchanged patches: [October 3a](../FormsReports14_patch_cpu_2026-10/README.md#3a-facts-from-the-patch-readmes)), [00-patch-references.md](../../09-Install/docs/00-patch-references.md) |
| Status | **documented 2026-11-18** – the steps are those of the October guide (verified on the test host 2026-10-24) with the November numbers; the November part (JDK 21.0.13.1, SPB 40289362, ADF / OPSS / UMS, OHS 40181911) was **confirmed live 2026-11-18** with the [cumulative guide](install_14c_patch_set_november_2026_manual_cumulativ_from_cpu102026.md) (SecureRandom fix added to step 5). "Live 2026-10-24" notes are October findings of the same mechanism |
| Automated (lib switched 2026-11-18, conf = this set) | [`07-Maintenance/80-patch_java_os.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/80-patch_java_os.sh) (step 5), [`81-patch_weblogic.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/81-patch_weblogic.sh) (= `05-`, steps 6–8), [`82-patch_forms_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/82-patch_forms_reports.sh) (= `06-`, steps 9–10) – each with the stop gate and a VM-snapshot pause on `--apply`; fresh install: `09-Install/05-` / `06-` |
| Markers | **documented** (README / KA1182), **confirmed (live)** (test host, date), **assumption** |

Target state:

| Component | Example before (CSPU Sep 2026) | After (CSPU Nov 2026) |
|---|---|---|
| JDK at `JDK_HOME` | 21.0.12.1 | **21.0.13.1** |
| OPatch | 13.9.4.2.24 | **13.9.4.2.25** |
| WLS SPB | 39925660 (PSU 14.1.2.0.260823) | **40289362** (PSU 14.1.2.0.261025, marker 40289390) |
| Infrastructure bundles | none | ADF **40155248**, WebCenter Core 40035984, OWSM 40024749, FMW Control 39995927, OAMCLIENT 40057999, UMS **40145610**, OPSS **40154045**, LibOVD 39726399 |
| PERL | 38590500 (5.40.2) | **39951765** (5.42.2) |
| Forms / Reports QPR | 39842516 / 39600348 | unchanged |
| OHS / WebGate (binaries) | none | **40181911** / 39100536 |
| Bundled JDK `oracle_common/jdk` | 17.0.12 | unchanged – no patch (blocked) |

---

## 0. Prerequisites

```bash
# as the software owner (oracle) – values of this library's layout
export ORACLE_HOME=/u01/app/oracle/fmw
export DOMAIN_HOME=/u01/app/oracle/domains/fr_domain
export JDK_HOME=/u01/app/oracle/java/jdk-21            # link -> jdk-21.0.x
export PATCH_STORAGE=/srv/patch_storage                 # downloaded ZIPs
export STAGE=/u01/app/oracle/stage/cspu_nov2026          # unpack (>= 6 GB, outside ORACLE_HOME)
export BACKUP=/u01/app/oracle/backup/cspu_nov2026     # under ORACLE_BASE – /u01 itself belongs to root
export INV_PTR=/etc/oraInst.loc
export LOGDIR=$STAGE/logs
export IHW=/path/to/IHateWeblogic                     # checkout of this library
mkdir -p $STAGE $BACKUP $LOGDIR
```

Rules for the whole run:
- the installation owner, never root; all processes of the home stopped
  from step 3 on;
- `STAGE` and `PATCH_STORAGE` outside `ORACLE_HOME`;
- "OPatch succeeded" alone proves nothing – read every output for
  "Prerequisite check … failed", "skipped", "make", "error";
- `opatch` without a TTY needs `-silent`.

Automated: downloads `09-Install/04-oracle_pre_download.sh --apply --mos`.

---

## 1. Inventory before

```bash
$ORACLE_HOME/oui/bin/viewInventory.sh | grep -i distribution | tee $LOGDIR/01_distribution.txt
$ORACLE_HOME/OPatch/opatch version
$ORACLE_HOME/OPatch/opatch lspatches   | tee $LOGDIR/01_lspatches_before.txt
$ORACLE_HOME/OPatch/opatch lsinventory -bugs_fixed > $LOGDIR/01_bugs_before.txt
ldd --version | head -1                                   # glibc 2.34 on OL9
readlink -f $JDK_HOME
```

Invalid objects of the RCU schemas – record them now, compare in step 11
(only new ones are caused by the patches; the test host has 69 invalid
objects since the RCU run – IAU synonyms, OPSS ORA-00942):

```bash
$IHW/07-Maintenance/rcu_repository_check.sh | tee $LOGDIR/01_rcu_check.txt   # check 6
```

Or everything in one run: [../tools/bash/collect_fmw_env.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/collect_fmw_env.sh) `--full`.
Expected on the test host: see [README](README.md) section 1a.

---

## 2. Stage the patches

```bash
cd $STAGE
for Z in $PATCH_STORAGE/patches/*/p*.zip; do   # 04-: patches/<nr>/p<nr>_*.zip
    case "$Z" in *SOLARIS*|*AIX*|*MSWIN*|*HPUX*) echo "WRONG PLATFORM: $Z"; continue ;; esac
    unzip -q -o "$Z" -d $STAGE
done
ls -1 $STAGE
```

Platform ZIPs (`*_Linux-x86-64.zip`): PERL, OHS, WebGate; the QPRs if
re-applied. Everything else is Generic. Do not change the unpacked SPB
directory.

---

## 3. Stop everything

```bash
$IHW/01-Run/startStop.sh stop-all --apply  # also stops ORDS (since 2026-10-24)
ps -ef | grep -E "$ORACLE_HOME|$DOMAIN_HOME|$JDK_HOME" | grep -v grep   # expected: empty
```

Reports server, engines, WLS servers and the Node Manager must be gone –
OPatch relinks binaries in steps 8 / 9. **ORDS** (`ords@ords_<n>.service`,
`12-APEX-Ords`) runs on the JDK at `JDK_HOME` and blocks the JDK switch of
step 5 – by hand: `sudo systemctl stop ords@ords_1` (live finding
2026-10-24: `02b --upgrade-jdk` refused, PID of ORDS).
Start afterwards: `startStop.sh start-all --apply` (ORDS last).

---

## 4. Backup

```bash
INVENTORY=$(sed -n 's/^inventory_loc=//p' $INV_PTR)
tar -czpf $BACKUP/oracle_home.tgz  -C $(dirname $ORACLE_HOME) $(basename $ORACLE_HOME)
tar -czpf $BACKUP/oraInventory.tgz -C $(dirname $INVENTORY)   $(basename $INVENTORY)
tar -czpf $BACKUP/domain_home.tgz  -C $(dirname $DOMAIN_HOME) $(basename $DOMAIN_HOME)
```

Restoring these three is the only rollback for the OPatch upgrade and the
safest one for the SPB. Configuration backup in addition:
`07-Maintenance/backup_config.sh --apply`.

**VM snapshot now** – everything is stopped, so the snapshot is consistent
(it does not replace the tar backup). `80-` / `81-` / `82-` pause for it on
`--apply` and continue only on `ok` (since 2026-10-24 – the snapshot had been
forgotten on the first run).

---

## 5. JDK 21.0.13.1 at `JDK_HOME`

KA1182: "21.0.13.1 or later" – Patch 35702194 ("JDK 21 latest") or the
fixed patch 40239626 (CPU435). The ZIP name never changes
(`p35702194_2100_Linux-x86-64.zip`) – check the version **inside** (the
download of 2026-11-18 contains `jdk-21.0.13.1`):

```bash
unzip -l $PATCH_STORAGE/patches/35702194/p35702194_*.zip | grep -o 'jdk-21[^_]*' | sort -u   # must be jdk-21.0.13.1
cd $(dirname $JDK_HOME)
unzip -p $PATCH_STORAGE/patches/35702194/p35702194_2100_Linux-x86-64.zip \
    jdk-21.0.13.1_linux-x64_bin.tar.gz | tar -xzf -
grep JAVA_RUNTIME_VERSION jdk-21.0.13.1/release          # 21.0.13.1+4-…
ln -sfn $(dirname $JDK_HOME)/jdk-21.0.13.1 $JDK_HOME       # link switch (absolute)
$JDK_HOME/bin/java -version
```

**SecureRandom – mandatory after every manual JDK switch** (live finding
2026-11-18): every new Oracle JDK ships `securerandom.source=file:/dev/random`
(blocking entropy source); the library sets `file:/dev/./urandom`
(`02b-root_os_java.sh` / `80-` do it, a manual unpack does not –
`90-oracle_validate.sh` reports FAIL):

```bash
F=$JDK_HOME/conf/security/java.security
cp -p $F $F.bak_$(date +%Y%m%d_%H%M%S)
sed -i 's|^securerandom.source=file:/dev/random$|securerandom.source=file:/dev/./urandom|' $F
grep '^securerandom.source' $F                         # file:/dev/./urandom
```

Then: domain files and `oui/` that WLST resolved to `jdk-21.0.x` instead of
the link (known pattern) – [`07-Maintenance/domain_jdk_path.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/domain_jdk_path.sh) lists them,
`--apply` sets the link path again.

The bundled JDK 17.0.12 in `$ORACLE_HOME/oracle_common/jdk` stays – KA1182
lists no patch; do not replace it by hand. 21.0.13.1 also closes the
eMudhra alert CVE-2026-114820 (roots removed) –
[00-patch-references.md – eMudhra](../../09-Install/docs/00-patch-references.md#emudhra-ca-incident--cve-2026-114820-state-2026-10-26).

Live 2026-10-24 (October, 21.0.13.0.2): unpack + link switch 13 s; no
domain file pinned the old version.

Automated: `07-Maintenance/80-patch_java_os.sh --apply` (`JDK_PATCH_NR`;
refuses while any JVM runs from `JDK_HOME`, names e.g. the ORDS unit).
Rollback: `ln -sfn <old jdk> $JDK_HOME`.

---

## 6. OPatch 13.9.4.2.25

```bash
$ORACLE_HOME/OPatch/opatch lspatches | grep 23335292 && \
  $ORACLE_HOME/OPatch/opatch rollback -id 23335292 -silent -invPtrLoc $INV_PTR && sleep 30
mkdir -p $STAGE/opatch $STAGE/tmp
unzip -q -o $STAGE/WLS_SPB_14.1.2.0.261112/tools/opatch/generic/*.zip -d $STAGE/opatch  # or p28186730_*.zip
$JDK_HOME/bin/java -Djava.io.tmpdir=$STAGE/tmp -jar $STAGE/opatch/6880880/opatch_generic.jar \
    -silent oracle_home=$ORACLE_HOME -invPtrLoc $INV_PTR
$ORACLE_HOME/OPatch/opatch version        # 13.9.4.2.25
```

No rollback except the restore of step 4. The NGINST patches 31101362,
29137924, 29909359 are contained – never apply them afterwards. OPatch .25
is in the SPB (`tools/opatch/generic/`, SPB README) – no separate download.

Live 2026-10-24: `p28186730_1394225_Generic.zip` from the SPB, 23335292 not
present, ~1 min, `opatch version` 13.9.4.2.25.

Automated: `81-patch_weblogic.sh --apply --opatch-only` first (prefers the
copy inside the SPB, backs up `OPatch/` and the inventory) – a
`--check-only` with the old OPatch stops early on purpose, the SPB report
needs .25. Then `81- --check-only`, then `81- --apply`.

---

## 7. WLS Stack Patch Bundle 40289362 (`napply`)

SPBAT is not supported for the distribution "WebLogic Server for FMW"
(Forms & Reports installer) – `napply` with the patch list of the SPB.

```bash
OH=$ORACLE_HOME
cd $STAGE/WLS_SPB_14.1.2.0.261112/binary_patches
( unset JAVA_HOME ORACLE_HOME
  $OH/OPatch/opatch napply -report -oh $OH -phBaseFile linux64_patchlist.txt -invPtrLoc $INV_PTR
) 2>&1 | tee $LOGDIR/07_spb_report.txt
( unset JAVA_HOME ORACLE_HOME
  $OH/OPatch/opatch napply -silent -oh $OH -phBaseFile linux64_patchlist.txt -invPtrLoc $INV_PTR
) 2>&1 | tee $LOGDIR/07_spb_apply.txt
cd -
$ORACLE_HOME/OPatch/opatch lspatches | tee $LOGDIR/07_lspatches_after_spb.txt
```

Content (SPB README from the ZIP, 11-Nov-26, documented): marker
**40289390** (interim 40289366), WLS PSU **40205408** (14.1.2.0.261025),
Third-Party BP **40288205** (14.1.2.0.261111), Coherence CP10 39984190, RDA
39646824, JDBC 39487373, DB client RU 39264447, Samples 38063775, OPatch
.25, RCU fix 38391376. On a home with an older SPB the `-report` shows the
supersets (October example: 40058371 > 39919611 + the Sep SPU 39988381 –
"Bug Superset of 39988381 (39924025)"); Samples is skipped when the
component is not in the home.

After the apply `opatch lsinventory -bugs_fixed | grep -E '39924025|40073770'`
shows 40205408 (CVE-2026-70748 fix since the October PSU; the new JAX-WS
gate). Post-install: MOS **KB694158** – November 2026: new attribute
`FeatureCompatibilityMBean.JAXWSRejectUnknownSEIOperationsEnabled`, **default
true**; check in step 11.

Unlike 12c no patch has to be rolled back before the `napply`; the
requirement is OPatch 13.9.4.2.25 (step 6; the PSU needs ≥ 13.9.4.2.18) and
JDK ≥ 17.0.12 / 21.0.4.

Live 2026-10-24 (October SPB): unpack ~1 min, `napply` ~5 min. Every
`opatch lspatches` takes ~25 s on this home.

Rollback (whole SPB only): `opatch nrollback -oh $ORACLE_HOME -idFile rollback_patchlist.txt` in `binary_patches/`.

Automated: `05-oracle_patch_weblogic.sh --apply` (`WLS_SPB_PATCH_NR`, marker
`WLS_SPB_MARKER_PATCH`; afterwards `WLS_SPB_CHECK_BUGS="39924025"` is checked in
`opatch lsinventory -bugs_fixed` – WARN if missing).

---

## 8. FMW infrastructure bundle patches

Not in the SPB; KA1182 tab "FMW Infrastructure 14.1.2.0" requires them
whenever only the WLS SPB is applied. All components are in the home.

```bash
for P in 40155248 40035984 40024749 39995927 40057999 40145610 40154045 39726399; do
    echo "===== $P =====" | tee -a $LOGDIR/08_infra.txt
    cd $STAGE/$P || break
    $ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./ -invPtrLoc $INV_PTR \
        2>&1 | tee -a $LOGDIR/08_infra.txt
    read -p "prereq of $P passed, no conflict? [y/n] " A; [ "$A" = y ] || { cd -; break; }
    $ORACLE_HOME/OPatch/opatch apply -silent -invPtrLoc $INV_PTR 2>&1 | tee -a $LOGDIR/08_infra.txt
    cd -
done
```

ADF 40155248 and its "post-install step" (README → MOS Doc ID 3093394.1 =
KB **PNEWS2138**, read 2026-10-24, documented): there is **no command** to
run. The note is a coordination rule – since July 2025 the ADF BP, the FMW
Third-Party BP and the WLS PSU share the GraalVM libraries and must come
from the same cycle. For a runtime home (our F&R domain – EM is an ADF
application): ADF BP only together with the WLS PSU; the Third-Party BP is
additionally needed by the JDeveloper IDE. In this cycle the PSU 40205408
and the Third-Party BP 40288205 come with the SPB → apply the SPB (step 7)
**before** ADF and never ADF alone. Symptom of a mismatch: EM / ADF apps do
not deploy, `BEA-149205` for `adf.oracle.domain.webapp.nativebridge` or
"Unresolved Webapp Library references … `adf.oracle.domain.webapp.graal-bundle`"
(check in step 11). A conflict
prompt "… will be rolled back … proceed?" → answer `n`, merge patch from
Support. Per-patch facts: README section 3a.

Live 2026-10-24 (October bundles): no conflict for any of the eight, each `apply` rc=0, ADF
~2 min, the others ~4 min each (OPatch inventory load + backup per call,
even for 0.5 MB) – **~31 min** in total.

Automated: `05-oracle_patch_weblogic.sh --apply` (`INSTALL_PATCHES`, after the
SPB, in this order; a component missing in the home → SKIPPED). Unlike the
loop above, the script runs the conflict check for all patches first and
aborts on any conflict – no prompt.

---

## 9. PERL, Forms QPR, Reports QPR

The QPRs 39842516 / 39600348 are already installed (Sep) and unchanged in
October / November – PERL 39951765 is new against September. When the QPRs are (re-)applied: **Forms before
Reports**, and on glibc ≥ 2.34 check `libzrc` first (MOS KB873815, Bug
38892485 – confirmed live 2026-10-14, `09-Install/docs/06` section "Forms
relink fails after a Reports QPR"):

```bash
nm -D $ORACLE_HOME/lib/libzrc.so.0 | grep -w dlsym     # @GLIBC_2.34 -> rebuild against the stubs:
mkdir -p /tmp/libzrc && cd /tmp/libzrc
cp -p $ORACLE_HOME/lib/libzrc.so.0 $ORACLE_HOME/lib/libzrc.so.0.glibc_$(date +%Y%m%d_%H%M%S)
ar x $ORACLE_HOME/lib/libzrc.a
gcc -shared -Wl,-G,-hlibzrc.so.0 -L$ORACLE_HOME/lib/stubs -o $ORACLE_HOME/lib/libzrc.so.0 *.o -ldl
nm -D $ORACLE_HOME/lib/libzrc.so.0 | grep -w dlsym     # expected: dlsym@GLIBC_2.2.5
cd / && rm -rf /tmp/libzrc
```

PERL 39951765 (component `oracle.perlint`, needs DBCLIENT for FMW ≥
23.26.0 – comes with the SPB):

```bash
cd $STAGE/39951765
$ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./ -invPtrLoc $INV_PTR
$ORACLE_HOME/OPatch/opatch apply -silent -invPtrLoc $INV_PTR 2>&1 | tee $LOGDIR/09_perl.txt
cd -
```

It replaces 38590500 (5.40.2) – the README does not mention the
predecessor. Live 2026-10-24: the conflict check reports no conflict even
with 38590500 still installed (OPatch would treat it as a subset); the
tested way is the explicit rollback first, as the script does:

```bash
$ORACLE_HOME/OPatch/opatch rollback -id 38590500 -silent -invPtrLoc $INV_PTR
```

Then apply 39951765 (~4.5 min). Single fix CVE-2026-4176 (README,
confirmed). Optional 38936596 only with `REPORTS_BIDIPARENTHESIS=YES`.

Automated: `06-oracle_patch_forms_reports.sh --apply` (rolls back 38590500 first –
`SUPERSEDES` map; `INSTALL_PATCHES_FR_COMMON`,
`INSTALL_PATCHES_FORMS`, `INSTALL_PATCHES_REPORTS`; Forms before Reports and
the `libzrc` fix are built in).

---

## 10. OHS 40181911 and WebGate 39100536 (binaries)

The OHS and WebGate binaries come with every Forms & Reports home
(`oracle.ohs2`, `oracle.ohs2.collocated`, `oracle.oamclient.webgate.ohs`) –
patched although Nginx is the frontend and no OHS instance exists.

```bash
for P in 40181911 39100536; do
    cd $STAGE/$P || break
    $ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./ -invPtrLoc $INV_PTR
    $ORACLE_HOME/OPatch/opatch apply -silent -invPtrLoc $INV_PTR 2>&1 | tee -a $LOGDIR/10_ohs.txt
    cd -
done
```

Post-install: MOS **KB559857** (the 14.1.2 counterpart of KB187736, read
2026-10-24) – **nothing to do without an OHS instance**: the KB has no
command, only hardening directives for an OHS instance / the Apache plug-in
(all off by default). If an instance is created later, use the directive
list of the 12c analysis (section 3.5b). The same header-spoofing class
was closed for our Nginx frontend on 2026-10-26 (README open point 11,
[`09-Install/nginx-wls.conf.template`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/nginx-wls.conf.template)). The OHS BP
40181911 README (from the ZIP, documented) adds "Fix for Bug 39932075" =
CVE-2026-9545 (curl, CPU450) and is cumulative: CVE-2026-87347 / -87346
and the July / August 2026 hardening switched off by default (.260907).
KB559857 is unchanged since 2026-10-20.

The WebGate BP release notes (documented) ask to stop Node Manager and the
OHS component before `apply` – with no OHS instance that is already covered
by step 3. The patch is cumulative and confirms CVE-2025-0725 (bundled
libcurl); it has been in the set since April 2026 but was never applied on
the test host. Live 2026-10-24 (October OHS 39987730): OHS ~3.5 min, WebGate ~3.5 min, rc=0, no
"completed with warnings".

Automated: `06-oracle_patch_forms_reports.sh --apply` (`INSTALL_PATCHES_FR_COMMON`
= PERL, OHS, WebGate – applied **before** the QPRs; no dependency between
them, the order of steps 9 / 10 here is only for reading).

---

## 11. Start and verify

```bash
$ORACLE_HOME/OPatch/opatch lspatches | tee $LOGDIR/11_lspatches_after.txt
diff $LOGDIR/01_lspatches_before.txt $LOGDIR/11_lspatches_after.txt
$IHW/01-Run/startStop.sh start-all --apply                     # ORDS last
until $IHW/01-Run/rwserver_status.sh | grep -q 'Connection pool OK'; do sleep 10; done   # Reports server ready (REP-50001 otherwise)
$IHW/09-Install/15-deploy-test-report-forms_template.sh --apply # smoke test (without --apply: dry run only)
$IHW/07-Maintenance/rcu_repository_check.sh | tee $LOGDIR/11_rcu_check.txt
diff <(grep -A20 '6. Invalid' $LOGDIR/01_rcu_check.txt) <(grep -A20 '6. Invalid' $LOGDIR/11_rcu_check.txt)
$IHW/10-Monitoring/cve_inventory.sh                            # patch level vs. cycle
```

Check the AdminServer log for JEP 290 warnings (must not appear with JDK
21.0.13.1, KB159467) and the PSU post-install items of KB694158 – new in
November: the JAX-WS gate (default true) – no "Invalid operation" SOAP
faults in the server logs, EM login and Reports via `rwservlet` work. ADF /
GraalVM coordination (PNEWS2138, step 8) – **errors** only; the
`BEA-160151 Registered library … nativebridge` info lines are normal:

```bash
grep -E 'BEA-149205|Unresolved Webapp Library' \
     $DOMAIN_HOME/servers/AdminServer/logs/AdminServer.log      # expected: empty
grep -il 'Invalid operation' $DOMAIN_HOME/servers/*/logs/*.log   # expected: empty (JAX-WS gate)
```

Live 2026-10-24 (October): `start-all` ~2.5 min, no `<Error>` / `<Critical>` in the
AdminServer / WLS_FORMS / WLS_REPORTS logs, EM answers, smoke test 30 OK
(6 s), Forms session from the Windows PC OK, [`rcu_repository_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/rcu_repository_check.sh): no
object invalidated by the patches.

---

## 12. Rollback

| What | How |
|---|---|
| Everything / after OPatch problems | stop, restore `oracle_home.tgz`, `oraInventory.tgz`, `domain_home.tgz` of step 4, JDK link back |
| One bundle (steps 8–10) | `opatch rollback -id <patch> -silent` (reverse order) |
| SPB | `opatch nrollback -oh $ORACLE_HOME -idFile rollback_patchlist.txt` (whole SPB only) |
| JDK | `ln -sfn <old jdk> $JDK_HOME` |

To go back to an earlier level by hand: the frozen
[00-patch-references_october_2026.md](../../09-Install/docs/00-patch-references_october_2026.md)
(or [_september_2026](../../09-Install/docs/00-patch-references_september_2026.md))
names its patches; `04- --fresh-patches` archives the previous ZIPs as
`$PATCH_STORAGE/patches_<date>/`.

---

## 13. Known problems / references

| Problem | Cause / fix |
|---|---|
| Forms relink rc=73, `dlsym@GLIBC_2.34` in `libzrc.so` | Reports QPR before Forms QPR on glibc 2.34 – KB873815, step 9 |
| "OPatch succeeded" but patch missing | prereq failed or component missing ("skipped") – read the output |
| OPatch patches its own JDK / inventory damage | `JAVA_HOME` in `$ORACLE_HOME/oui/.globalEnv.properties` inside the home – must point to `JDK_HOME` (KB175049) |
| Domain still on the old JDK after the link switch | WLST resolved the link into domain files – `07-Maintenance/domain_jdk_path.sh --apply` |
| Reports QPR "completed with warnings" | known, harmless – `09-Install/docs/06` |
| JDK switch refused: "Java processes still run from `JDK_HOME`" | a JVM outside the domain uses the JDK – on the test host the ORDS unit `ords@ords_1` (live 2026-10-24); `startStop.sh stop-all` stops it since then |
| `81- --check-only` stops with "OPatch … < 13.9.4.2.25" | intended – `81- --apply --opatch-only` first, then `--check-only` |
| Wrapper script prints a syntax error at its very end | the script file was edited while it ran (bash reads incrementally) – the patch run itself is fine; never edit a running script |
| SOAP fault "Invalid operation" after the patch | new JAX-WS gate of PSU 40205408, default true (KB694158) – `JAXWSRejectUnknownSEIOperationsEnabled=false` only for a legitimate client |
| Reports server / engines do not start, `REP-50125 java.lang.NullPointerException` in `Utility.getOrbProperties` | Bug 39868225 from QPR 39600348 (KB924687): `REPORTS_JVM_OPTIONS` set without `-DORBWaitForResponseTimeout` – our `13-` sets it in `reports.sh` and `rwserver.conf` (`09-Install/docs/13` troubleshooting) |

MOS: KA1182, CPU450, CPU435, KB694158, PNEWS2138, KB559857, KB175049, KB159467,
KB873815, KB168467, KB924687. Background: [00-patch-references.md](../../09-Install/docs/00-patch-references.md).
