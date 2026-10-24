# Install the CPU October 2026 Patch Set – Forms & Reports 14.1.2 (manual)

Manual, step-by-step installation of the **CPU October 2026** patch set plus
the **Security Alert CVE-2026-91403** on an Oracle Forms & Reports 14.1.2.0.0
home (FMW / WebLogic 14.1.2, Oracle Linux 9, Nginx frontend) – without the
IHateWeblogic scripts. Every step names the script that automates it; this
guide is the master for that automation (doc-as-master).

| | |
|---|---|
| Cycle | CPU October 2026 (2026-10-20) + Security Alert CVE-2026-91403 (2026-10-21) |
| Starting point | CSPU September 2026 (the test host, section 1a of the [README](README.md)) |
| Sources | KA1182 (PDF 2026-10-22), CPU360, CPU426, the patch READMEs ([README](README.md) section 3a), [00-patch-references.md](../../09-Install/docs/00-patch-references.md) |
| Status | **draft 2026-10-24** – the steps are written from KA1182 and the September run; the README facts are added one by one; **not yet run on the test host** |
| Markers | **documented** (README / KA1182), **confirmed (live)** (test host, date), **assumption** |

Target state:

| Component | Before (Sep 2026) | After (Oct 2026) |
|---|---|---|
| JDK at `JDK_HOME` | 21.0.12.1 | **21.0.13.0.2** |
| OPatch | 13.9.4.2.24 | **13.9.4.2.25** |
| WLS SPB | 39925660 (PSU 14.1.2.0.260823) | **40125898** (PSU 14.1.2.0.260922) |
| Infrastructure bundles | none | ADF, WebCenter Core, OWSM, FMW Control, OAMCLIENT, UMS, OPSS, LibOVD |
| PERL | 38590500 (5.40.2) | **39951765** (5.42.2) |
| Forms / Reports QPR | 39842516 / 39600348 | unchanged |
| OHS / WebGate (binaries) | none | **39987730** / 39100536 |
| Bundled JDK `oracle_common/jdk` | 17.0.12 | unchanged – no patch (blocked) |

---

## 0. Prerequisites

```bash
# as the software owner (oracle) – values of this library's layout
export ORACLE_HOME=/u01/app/oracle/fmw
export DOMAIN_HOME=/u01/app/oracle/domains/fr_domain
export JDK_HOME=/u01/app/oracle/java/jdk-21            # link -> jdk-21.0.x
export PATCH_STORAGE=/srv/patch_storage                 # downloaded ZIPs
export STAGE=/u01/app/oracle/stage/cpu_oct2026          # unpack (>= 6 GB, outside ORACLE_HOME)
export BACKUP=/u01/backup/cpu_oct2026
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

Or everything in one run: [../tools/collect_fmw_env.sh](../tools/collect_fmw_env.sh) `--full`.
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
$IHW/01-Run/startStop.sh stop-all          # or: fmw_ctl.sh stop-all (autostart)
ps -ef | grep -E "$ORACLE_HOME|$DOMAIN_HOME" | grep -v grep   # expected: empty
```

Reports server, engines, WLS servers and the Node Manager must be gone –
OPatch relinks binaries in steps 8 / 9.

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

---

## 5. JDK 21.0.13.0.2 at `JDK_HOME`

Target: the **alert release** of CPU426, not the CPU release 21.0.13
(itself affected by CVE-2026-91403). Patch 40186074 (release-specific) or
35702194 ("JDK 21 latest" – only if the ZIP really contains 21.0.13.0.2).

The patch has no README and the ZIP name never changes
(`p35702194_2100_Linux-x86-64.zip`) – check the version **inside** before
using it (a copy downloaded on 2026-10-20 still contained 21.0.12.1):

```bash
unzip -l $PATCH_STORAGE/patches/35702194/p35702194_*.zip | grep -o 'jdk-21[^_]*'   # must be jdk-21.0.13.0.2
cd $(dirname $JDK_HOME)
tar -xzf $STAGE/jdk-21.0.13.0.2_linux-x64_bin.tar.gz
grep JAVA_RUNTIME_VERSION $(dirname $JDK_HOME)/jdk-21.0.13.0.2*/release   # 21.0.13.0.2+…
ln -sfn jdk-21.0.13.0.2 $JDK_HOME                                         # link switch
$JDK_HOME/bin/java -version
```

Then: domain files and `oui/` that WLST resolved to `jdk-21.0.x` instead of
the link (known pattern) – `07-Maintenance/domain_jdk_path.sh` lists them,
`--apply` sets the link path again.

The bundled JDK 17.0.12 in `$ORACLE_HOME/oracle_common/jdk` stays – KA1182
lists no patch; do not replace it by hand.

Automated: `07-Maintenance/80-patch_java_os.sh --apply` (`JDK_PATCH_NR`).
Rollback: `ln -sfn <old jdk> $JDK_HOME`.

---

## 6. OPatch 13.9.4.2.25

```bash
$ORACLE_HOME/OPatch/opatch lspatches | grep 23335292 && \
  $ORACLE_HOME/OPatch/opatch rollback -id 23335292 -silent -invPtrLoc $INV_PTR && sleep 30
mkdir -p $STAGE/opatch $STAGE/tmp
unzip -q -o $STAGE/WLS_SPB_14.1.2.0.261007/tools/opatch/generic/*.zip -d $STAGE/opatch  # or p28186730_*.zip
$JDK_HOME/bin/java -Djava.io.tmpdir=$STAGE/tmp -jar $STAGE/opatch/6880880/opatch_generic.jar \
    -silent oracle_home=$ORACLE_HOME -invPtrLoc $INV_PTR
$ORACLE_HOME/OPatch/opatch version        # 13.9.4.2.25
```

No rollback except the restore of step 4. The NGINST patches 31101362,
29137924, 29909359 are contained – never apply them afterwards. OPatch .25
is in the SPB (`tools/opatch/generic/`, SPB README) – no separate download.

Automated: `05-oracle_patch_weblogic.sh` (prefers the copy inside the SPB).

---

## 7. WLS Stack Patch Bundle 40125898 (`napply`)

SPBAT is not supported for the distribution "WebLogic Server for FMW"
(Forms & Reports installer) – `napply` with the patch list of the SPB.

```bash
OH=$ORACLE_HOME
cd $STAGE/WLS_SPB_14.1.2.0.261007/binary_patches
( unset JAVA_HOME ORACLE_HOME
  $OH/OPatch/opatch napply -report -oh $OH -phBaseFile linux64_patchlist.txt -invPtrLoc $INV_PTR
) 2>&1 | tee $LOGDIR/07_spb_report.txt
( unset JAVA_HOME ORACLE_HOME
  $OH/OPatch/opatch napply -silent -oh $OH -phBaseFile linux64_patchlist.txt -invPtrLoc $INV_PTR
) 2>&1 | tee $LOGDIR/07_spb_apply.txt
cd -
$ORACLE_HOME/OPatch/opatch lspatches | tee $LOGDIR/07_lspatches_after_spb.txt
```

Expected (SPB README, documented): marker **40126042** (interim 40125902),
WLS PSU 40058371 (14.1.2.0.260922), Third-Party BP 40035655, Coherence CP10
39984190, RDA 39646824, JDBC 39487373, DB client RU 39264447, Samples
38063775, RCU fix 38391376. Then:
- **39988381** (Sep SPU) is not in the SPB list. It is an overlay on the
  Sep PSU 39919611 (base bug 39924025, README inside the ZIP – the MOS portal
  README is a placeholder), so it can **not** be re-applied on PSU 40058371.
  Check the `-report` output for what happens to it (expected: removed with
  the old PSU – assumption), then after the apply
  `opatch lsinventory -bugs_fixed | grep 39924025` must show the new PSU;
  if missing: no Sep overlay on top, look for an overlay on 40058371
  (open point 1);
- post-install: MOS **KB694158**.

Unlike 12c no patch has to be rolled back before the `napply`; the
requirement is OPatch 13.9.4.2.25 (step 6) and JDK ≥ 17.0.12 / 21.0.4.

Rollback (whole SPB only): `opatch nrollback -oh $ORACLE_HOME -idFile rollback_patchlist.txt` in `binary_patches/`.

Automated: `05-oracle_patch_weblogic.sh --apply` (`WLS_SPB_PATCH_NR`, marker
`WLS_SPB_MARKER_PATCH`; afterwards `WLS_SPB_CHECK_BUGS="39924025"` is checked in
`opatch lsinventory -bugs_fixed` – WARN if missing).

---

## 8. FMW infrastructure bundle patches

Not in the SPB; KA1182 tab "FMW Infrastructure 14.1.2.0" requires them
whenever only the WLS SPB is applied. All components are in the home.

```bash
for P in 40050062 40035984 40024749 39995927 40057999 39940047 39979746 39726399; do
    echo "===== $P =====" | tee -a $LOGDIR/08_infra.txt
    cd $STAGE/$P || break
    $ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./ -invPtrLoc $INV_PTR \
        2>&1 | tee -a $LOGDIR/08_infra.txt
    read -p "prereq of $P passed, no conflict? [y/n] " A; [ "$A" = y ] || { cd -; break; }
    $ORACLE_HOME/OPatch/opatch apply -silent -invPtrLoc $INV_PTR 2>&1 | tee -a $LOGDIR/08_infra.txt
    cd -
done
```

ADF 40050062 and its "post-install step" (README → MOS Doc ID 3093394.1 =
KB **PNEWS2138**, read 2026-10-24, documented): there is **no command** to
run. The note is a coordination rule – since July 2025 the ADF BP, the FMW
Third-Party BP and the WLS PSU share the GraalVM libraries and must come
from the same cycle. For a runtime home (our F&R domain – EM is an ADF
application): ADF BP only together with the WLS PSU; the Third-Party BP is
additionally needed by the JDeveloper IDE. In this cycle the PSU 40058371
and the Third-Party BP 40035655 come with the SPB → apply the SPB (step 7)
**before** ADF and never ADF alone. Symptom of a mismatch: EM / ADF apps do
not deploy, `BEA-149205` for `adf.oracle.domain.webapp.nativebridge` or
"Unresolved Webapp Library references … `adf.oracle.domain.webapp.graal-bundle`"
(check in step 11). A conflict
prompt "… will be rolled back … proceed?" → answer `n`, merge patch from
Support. Per-patch facts: README section 3a (pending).

Automated: `05-oracle_patch_weblogic.sh --apply` (`INSTALL_PATCHES`, after the
SPB, in this order; a component missing in the home → SKIPPED). Unlike the
loop above, the script runs the conflict check for all patches first and
aborts on any conflict – no prompt.

---

## 9. PERL, Forms QPR, Reports QPR

The QPRs 39842516 / 39600348 are already installed (Sep) and unchanged in
October – only PERL is new. When the QPRs are (re-)applied: **Forms before
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
predecessor; the conflict check shows whether OPatch rolls it back itself
(expected, same component). Single fix CVE-2026-4176 (README, confirmed).
Optional 38936596 only with `REPORTS_BIDIPARENTHESIS=YES`.

Automated: `06-oracle_patch_forms_reports.sh --apply` (rolls back 38590500 first –
`SUPERSEDES` map; `INSTALL_PATCHES_FR_COMMON`,
`INSTALL_PATCHES_FORMS`, `INSTALL_PATCHES_REPORTS`; Forms before Reports and
the `libzrc` fix are built in).

---

## 10. OHS 39987730 and WebGate 39100536 (binaries)

The OHS and WebGate binaries come with every Forms & Reports home
(`oracle.ohs2`, `oracle.ohs2.collocated`, `oracle.oamclient.webgate.ohs`) –
patched although Nginx is the frontend and no OHS instance exists.

```bash
for P in 39987730 39100536; do
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
list of the 12c analysis (section 3.5b). The same header-spoofing class is
open for our Nginx frontend (README open point 11). The OHS BP
README (documented) confirms CVE-2026-87347 / -87346 and switches the
July / August 2026 CSPU hardening off by default (flags) – relevant only for
an OHS instance.

The WebGate BP release notes (documented) ask to stop Node Manager and the
OHS component before `apply` – with no OHS instance that is already covered
by step 3. The patch is cumulative and confirms CVE-2025-0725 (bundled
libcurl); it has been in the set since April 2026 but was never applied on
the test host.

Automated: `06-oracle_patch_forms_reports.sh --apply` (`INSTALL_PATCHES_FR_COMMON`
= PERL, OHS, WebGate – applied **before** the QPRs; no dependency between
them, the order of steps 9 / 10 here is only for reading).

---

## 11. Start and verify

```bash
$ORACLE_HOME/OPatch/opatch lspatches | tee $LOGDIR/11_lspatches_after.txt
diff $LOGDIR/01_lspatches_before.txt $LOGDIR/11_lspatches_after.txt
$IHW/01-Run/startStop.sh start-all
$IHW/09-Install/15-deploy-test-report-forms_template.sh        # smoke test Forms + Reports
$IHW/10-Monitoring/cve_inventory.sh                            # patch level vs. cycle
```

Check the AdminServer log for JEP 290 warnings (must not appear with JDK
21.0.13.0.2, KB159467) and the PSU post-install items of KB694158. ADF /
GraalVM coordination (PNEWS2138, step 8) – no hits allowed:

```bash
grep -E 'BEA-149205|graal-bundle|nativebridge' \
     $DOMAIN_HOME/servers/AdminServer/logs/AdminServer.log
```

---

## 12. Rollback

| What | How |
|---|---|
| Everything / after OPatch problems | stop, restore `oracle_home.tgz`, `oraInventory.tgz`, `domain_home.tgz` of step 4, JDK link back |
| One bundle (steps 8–10) | `opatch rollback -id <patch> -silent` (reverse order) |
| SPB | `opatch nrollback -oh $ORACLE_HOME -idFile rollback_patchlist.txt` (whole SPB only) |
| JDK | `ln -sfn <old jdk> $JDK_HOME` |

To go back to the September level by hand: the frozen
[00-patch-references_september_2026.md](../../09-Install/docs/00-patch-references_september_2026.md)
names its patches.

---

## 13. Known problems / references

| Problem | Cause / fix |
|---|---|
| Forms relink rc=73, `dlsym@GLIBC_2.34` in `libzrc.so` | Reports QPR before Forms QPR on glibc 2.34 – KB873815, step 9 |
| "OPatch succeeded" but patch missing | prereq failed or component missing ("skipped") – read the output |
| OPatch patches its own JDK / inventory damage | `JAVA_HOME` in `$ORACLE_HOME/oui/.globalEnv.properties` inside the home – must point to `JDK_HOME` (KB175049) |
| Domain still on the old JDK after the link switch | WLST resolved the link into domain files – `07-Maintenance/domain_jdk_path.sh --apply` |
| Reports QPR "completed with warnings" | known, harmless – `09-Install/docs/06` |
| Reports server / engines do not start, `REP-50125 java.lang.NullPointerException` in `Utility.getOrbProperties` | Bug 39868225 from QPR 39600348 (KB924687): `REPORTS_JVM_OPTIONS` set without `-DORBWaitForResponseTimeout` – our `13-` sets it in `reports.sh` and `rwserver.conf` (`09-Install/docs/13` troubleshooting) |

MOS: KA1182, CPU360, CPU426, KB694158, KB559857, KB175049, KB159467,
KB873815, KB168467, KB924687. Background: [00-patch-references.md](../../09-Install/docs/00-patch-references.md).
