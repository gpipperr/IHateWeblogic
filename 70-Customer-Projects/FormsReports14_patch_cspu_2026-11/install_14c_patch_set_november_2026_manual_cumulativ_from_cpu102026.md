---
nav_title: "Manual guide – from Oct 2026"
title: "CSPU November 2026 on top of CPU October 2026 – F&R 14.1.2"
description: "Manual install of the CSPU November 2026 on a Forms & Reports 14.1.2 home that is on CPU October 2026: JDK 21.0.13.1, SPB, ADF, OPSS, UMS, OHS, verify."
---

# CSPU November 2026 on top of CPU October 2026 – Forms & Reports 14.1.2 (manual)

Manual, step-by-step installation of the **CSPU November 2026** on an Oracle
Forms & Reports 14.1.2.0.0 home that is **on the CPU October 2026 state**
(FMW / WebLogic 14.1.2, Oracle Linux 9, Nginx frontend) – without the
IHateWeblogic scripts. Only the patches newer than October. A home on an
older level: [full guide](install_14c_patch_set_november_2026_manual_full.md).
Every step names the script that automates it (doc-as-master).

| | |
|---|---|
| Cycle | CSPU November 2026 (2026-11-17) |
| Starting point | **CPU October 2026** – check in step 1 (the test host, [README](README.md) section 1a) |
| Sources | KA1182 (2026-11-17), CPU450, CPU435, KB694158 (Nov 2026), the patch READMEs from the ZIPs ([README](README.md) section 3a), [00-patch-references.md](../../09-Install/docs/00-patch-references.md) |
| Status | **confirmed (live) 2026-11-18** – applied on the test host step by step with this guide: OPatch without errors, `lspatches` diff as expected, start + smoke test 32 OK, `90-oracle_validate.sh` 0 FAIL (after the SecureRandom fix of step 5), no invalid RCU objects; patch work ~45 min ([README](README.md) section 8) |
| Automated (lib switched 2026-11-18, conf = this set) | [`07-Maintenance/80-patch_java_os.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/80-patch_java_os.sh) (step 5), [`81-patch_weblogic.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/81-patch_weblogic.sh) (= `05-`, steps 6–7 – applied bundles are skipped), [`82-patch_forms_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/82-patch_forms_reports.sh) (= `06-`, step 8) |
| Markers | **documented** (README / KA1182), **confirmed (live)** (test host, date), **assumption** |

Target state:

| Component | Before (CPU Oct 2026) | After (CSPU Nov 2026) |
|---|---|---|
| JDK at `JDK_HOME` | 21.0.13.0.2 | **21.0.13.1** |
| OPatch | 13.9.4.2.25 | unchanged |
| WLS SPB | 40125898 (PSU 14.1.2.0.260922, marker 40126042) | **40289362** (PSU 14.1.2.0.261025, marker 40289390) |
| ADF / OPSS / UMS | 40050062 / 39979746 / 39940047 | **40155248** / **40154045** / **40145610** |
| WebCenter Core, OWSM, FMW Control, OAMCLIENT, LibOVD | October bundles | unchanged |
| PERL, Forms / Reports QPR, WebGate | 39951765, 39842516 / 39600348, 39100536 | unchanged |
| OHS (binaries) | 39987730 | **40181911** |
| Bundled JDK `oracle_common/jdk` | 17.0.12 | unchanged – no patch (blocked) |

---

## 0. Prerequisites

```bash
# as the software owner (oracle) – values of this library's layout
export ORACLE_HOME=/u01/app/oracle/fmw
export DOMAIN_HOME=/u01/app/oracle/domains/fr_domain
export JDK_HOME=/u01/app/oracle/java/jdk-21            # link -> jdk-21.0.x
export PATCH_STORAGE=/srv/patch_storage                 # downloaded ZIPs (before the lib switch: staging_cspunov2026/)
export STAGE=/u01/app/oracle/stage/cspu_nov2026         # unpack (>= 4 GB, outside ORACLE_HOME)
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

Downloads (six ZIPs, Linux x86-64 / Generic): 35702194 (JDK 21.0.13.1),
40289362, 40155248, 40154045, 40145610, 40181911 – for the Forms client
bundle also the Windows ZIP of 35702194. Automated:
`09-Install/04-oracle_pre_download.sh --apply --fresh-patches --mos` (after
the switch), before it the staging list of the analysis.

---

## 1. Inventory before – is the home on CPU October 2026?

```bash
$ORACLE_HOME/OPatch/opatch version                      # 13.9.4.2.25
$ORACLE_HOME/OPatch/opatch lspatches | tee $LOGDIR/01_lspatches_before.txt
for P in 40126042 40058371 40050062 40035984 40024749 39995927 40057999 39940047 39979746 39726399 39951765 39987730 39100536; do
    grep -q "^$P;" $LOGDIR/01_lspatches_before.txt || echo "MISSING: $P"
done
readlink -f $JDK_HOME                                    # jdk-21.0.13.0.2
$ORACLE_HOME/OPatch/opatch lsinventory -bugs_fixed > $LOGDIR/01_bugs_before.txt
$IHW/07-Maintenance/rcu_repository_check.sh | tee $LOGDIR/01_rcu_check.txt   # invalid objects, check 6
```

Expected: no "MISSING" line (Forms QPR / OHS / WebGate only if those
components are in the home). **A MISSING line → STOP**, take the
[full guide](install_14c_patch_set_november_2026_manual_full.md).

---

## 2. Stage the patches

```bash
cd $STAGE
for P in 40289362 40155248 40154045 40145610 40181911; do
    unzip -q -o $PATCH_STORAGE/patches/$P/p${P}_*.zip -d $STAGE
done
ls -d $STAGE/WLS_SPB_14.1.2.0.261112 $STAGE/40155248 $STAGE/40154045 $STAGE/40145610 $STAGE/40181911
unzip -l $PATCH_STORAGE/patches/35702194/p35702194_2100_Linux-x86-64.zip | grep -o 'jdk-21[^_]*' | sort -u
```

Expected: the five directories; the JDK ZIP shows `jdk-21.0.13.1` (checked
2026-11-18). Do not change the unpacked SPB directory.

---

## 3. Stop everything

```bash
$IHW/01-Run/startStop.sh stop-all --apply              # also stops ORDS
ps -ef | grep -E "$ORACLE_HOME|$DOMAIN_HOME|$JDK_HOME" | grep -v grep   # expected: empty
```

ORDS runs on `JDK_HOME` and blocks the JDK switch – `stop-all` stops it.

---

## 4. Backup + VM snapshot

```bash
INVENTORY=$(sed -n 's/^inventory_loc=//p' $INV_PTR)
tar -czpf $BACKUP/oracle_home.tgz  -C $(dirname $ORACLE_HOME) $(basename $ORACLE_HOME)
tar -czpf $BACKUP/oraInventory.tgz -C $(dirname $INVENTORY)   $(basename $INVENTORY)
tar -czpf $BACKUP/domain_home.tgz  -C $(dirname $DOMAIN_HOME) $(basename $DOMAIN_HOME)
$IHW/07-Maintenance/backup_config.sh --apply
```

**VM snapshot now** (everything stopped). `80-` / `81-` / `82-` pause for it
on `--apply`.

---

## 5. JDK 21.0.13.1 at `JDK_HOME`

KA1182: "21.0.13.1 or later" (35702194); CPU435 fixed patch 40239626. The
ZIP name never changes – checked in step 2.

```bash
cd $(dirname $JDK_HOME)
unzip -p $PATCH_STORAGE/patches/35702194/p35702194_2100_Linux-x86-64.zip \
    jdk-21.0.13.1_linux-x64_bin.tar.gz | tar -xzf -
grep JAVA_RUNTIME_VERSION jdk-21.0.13.1/release        # "21.0.13.1+4-…"
ln -sfn $(dirname $JDK_HOME)/jdk-21.0.13.1 $JDK_HOME     # link switch (absolute, as before)
$JDK_HOME/bin/java -version
$IHW/07-Maintenance/domain_jdk_path.sh                   # lists domain / oui files pinned to jdk-21.0.x; --apply fixes them
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

Live 2026-11-18: unpack + link switch 5 s; `java -version` 21.0.13.1+4-LTS-22;
`domain_jdk_path.sh`: only the old, unused `bin/aqxmlctl` (21.0.12.1).

The bundled JDK 17.0.12 stays (no patch). 21.0.13.1 also closes the eMudhra
alert CVE-2026-114820 – optional proof: the TLS probe of
[00-patch-references.md – eMudhra](../../09-Install/docs/00-patch-references.md#emudhra-ca-incident--cve-2026-114820-state-2026-10-26)
(expected: all test chains rejected, emSign roots gone from `cacerts`).

Automated: `07-Maintenance/80-patch_java_os.sh --apply`.
Rollback: `ln -sfn jdk-21.0.13.0.2 $JDK_HOME`.

---

## 6. WLS Stack Patch Bundle 40289362 (`napply`)

OPatch 13.9.4.2.25 is already installed (unchanged in November). SPBAT is
not supported for the distribution "WebLogic Server for FMW".

```bash
OH=$ORACLE_HOME
cd $STAGE/WLS_SPB_14.1.2.0.261112/binary_patches
( unset JAVA_HOME ORACLE_HOME
  $OH/OPatch/opatch napply -report -oh $OH -phBaseFile linux64_patchlist.txt -invPtrLoc $INV_PTR
) 2>&1 | tee $LOGDIR/06_spb_report.txt
```

Expected (**confirmed live 2026-11-18**): supersets 40205408 > 40058371,
40288205 > 40035655, 40289390 > 40126042; duplicates skipped 39984190,
39646824, 39264447, 39487373, 38391376; Samples 38063775 skipped (component
not in the home); "All checks passed". Then:

```bash
( unset JAVA_HOME ORACLE_HOME
  $OH/OPatch/opatch napply -silent -oh $OH -phBaseFile linux64_patchlist.txt -invPtrLoc $INV_PTR
) 2>&1 | tee $LOGDIR/06_spb_apply.txt
cd -
$ORACLE_HOME/OPatch/opatch lspatches | tee $LOGDIR/06_lspatches_after_spb.txt   # 40289390, 40205408, 40288205
$ORACLE_HOME/OPatch/opatch lsinventory -bugs_fixed | grep -E '39924025|40073770|40202517'
```

Expected: 39924025 (CVE-2026-70748, since the October PSU) and 40073770
(JAX-WS gate) under 40205408, 40202517 (Certifi) under 40288205.

Live 2026-11-18: `-report` ~8 min, `napply` ~11 min, "Patches 40205408,
40288205, 40289390 successfully applied", the three October patches
"inactive" (sub-set); bug check as expected.

Post-install **KB694158** (November 2026): the PSU adds
`FeatureCompatibilityMBean.JAXWSRejectUnknownSEIOperationsEnabled` – **default
true** (JAX-WS endpoints with a Service Endpoint Interface answer unknown
operations with a SOAP fault). Nothing to set; check in step 9.

Rollback (whole SPB only): `opatch nrollback -oh $ORACLE_HOME -idFile
rollback_patchlist.txt` in `binary_patches/` – re-activates the October PSU.

Automated: `05-oracle_patch_weblogic.sh --apply` (`WLS_SPB_PATCH_NR`, marker
`WLS_SPB_MARKER_PATCH=40289390`, then `WLS_SPB_CHECK_BUGS`).

---

## 7. ADF 40155248, OPSS 40154045, UMS 40145610

Only these three infrastructure bundles are new; WebCenter Core, OWSM, FMW
Control, OAMCLIENT and LibOVD stay. **ADF after the SPB** (PNEWS2138: ADF BP
+ WLS PSU + Third-Party BP from the same cycle – EM is an ADF application).

```bash
for P in 40155248 40154045 40145610; do
    echo "===== $P =====" | tee -a $LOGDIR/07_infra.txt
    cd $STAGE/$P || break
    $ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./ -invPtrLoc $INV_PTR \
        2>&1 | tee -a $LOGDIR/07_infra.txt
    read -p "prereq of $P passed, no conflict? [y/n] " A; [ "$A" = y ] || { cd -; break; }
    $ORACLE_HOME/OPatch/opatch apply -silent -invPtrLoc $INV_PTR 2>&1 | tee -a $LOGDIR/07_infra.txt
    cd -
done
```

Expected: each new bundle replaces its October predecessor (OPatch rolls
the subset back – "Patch 40050062 is a subset of 40155248 …"). A conflict
prompt "… will be rolled back … proceed?" for anything **else** → answer
`n`, merge patch from Support. Post-install: none (ADF: Doc ID 3093394.1 =
coordination rule only).

Live 2026-11-18: all three prereq checks passed; ADF 5 min, OPSS 4 min, UMS
4 min; "Sub-set patch [40050062 / 39979746 / 39940047] has become inactive".

Automated: `05-oracle_patch_weblogic.sh --apply` (`INSTALL_PATCHES`, after the
SPB; already applied bundles → "already applied").

---

## 8. OHS 40181911 (binaries)

```bash
cd $STAGE/40181911
$ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./ -invPtrLoc $INV_PTR
$ORACLE_HOME/OPatch/opatch apply -silent -invPtrLoc $INV_PTR 2>&1 | tee $LOGDIR/08_ohs.txt
cd -
```

Replaces 39987730. Post-install **KB559857** (unchanged since 2026-10-20) –
nothing to do without an OHS instance (Nginx frontend). PERL, WebGate and
the QPRs stay. Live 2026-11-18: ~4.5 min, 39987730 inactive.

Automated: `06-oracle_patch_forms_reports.sh --apply` (`SUPERSEDES` map
39987730 → 40181911).

---

## 9. Start and verify

```bash
$ORACLE_HOME/OPatch/opatch lspatches | tee $LOGDIR/09_lspatches_after.txt
diff $LOGDIR/01_lspatches_before.txt $LOGDIR/09_lspatches_after.txt
$IHW/01-Run/startStop.sh start-all --apply                     # ORDS last
until $IHW/01-Run/rwserver_status.sh | grep -q 'Connection pool OK'; do sleep 10; done   # Reports server ready
$IHW/09-Install/15-deploy-test-report-forms_template.sh --apply # smoke test
$IHW/09-Install/90-oracle_validate.sh
$IHW/07-Maintenance/rcu_repository_check.sh | tee $LOGDIR/09_rcu_check.txt
diff <(grep -A20 '6. Invalid' $LOGDIR/01_rcu_check.txt) <(grep -A20 '6. Invalid' $LOGDIR/09_rcu_check.txt)
$IHW/10-Monitoring/cve_inventory.sh                            # patch level vs. cycle
```

Live 2026-11-18: `start-all` 2.5 min; a smoke test started right after it
got REP-50001 "server is initializing" (hence the wait loop) – then 32 OK;
`90-oracle_validate.sh` 0 FAIL, 5 known WARN (bundled JDK of the engines,
Derby on 1527, `/etc/nginx/ssl` not readable as oracle, old failed Reports
jobs); no invalid RCU objects; EM / console / Forms servlet / ORDS HTTP 200,
no "Invalid operation" in the logs. `cve_inventory.sh` before the lib switch:
5 FAIL "MISSING – configured for CPU Oct 2026" for the superseded October
patches – expected until the conf is switched.

Expected `diff` of `lspatches` (confirmed live): −40126042 −40058371 −40035655 −40050062
−39979746 −39940047 −39987730, +40289390 +40205408 +40288205 +40155248
+40154045 +40145610 +40181911.

Logs – ADF / GraalVM coordination and the new JAX-WS gate:

```bash
grep -E 'BEA-149205|Unresolved Webapp Library' $DOMAIN_HOME/servers/AdminServer/logs/AdminServer.log   # empty
grep -il 'Invalid operation' $DOMAIN_HOME/servers/*/logs/*.log                                          # empty
```

Functional: EM login (`/em`), a report via `rwservlet` (`15-`), a Forms
session from a Windows PC. A legitimate SOAP client that fails with
"Invalid operation" after the patch → set the gate to `false` (KB694158,
dynamic) and report it.

Forms client bundle with the Windows runtime 21.0.13.1:
`$IHW/09-Install/40-oracle_forms_client_bundle.sh --apply`; Web Start
clients: JRE 8u513 (40239650) through the software distribution.

---

## 10. Rollback

| What | How |
|---|---|
| Everything | stop, restore `oracle_home.tgz`, `oraInventory.tgz`, `domain_home.tgz` of step 4 (or the VM snapshot), JDK link back |
| ADF / OPSS / UMS / OHS | `opatch rollback -id <patch> -silent` (reverse order) – the October bundle is **not** re-applied automatically: apply 40050062 / 39979746 / 39940047 / 39987730 again |
| SPB | `opatch nrollback -oh $ORACLE_HOME -idFile rollback_patchlist.txt` (whole SPB; re-activates the October PSU) |
| JDK | `ln -sfn jdk-21.0.13.0.2 $JDK_HOME` |

October level by hand: [00-patch-references_october_2026.md](../../09-Install/docs/00-patch-references_october_2026.md)
and the [October guide](../FormsReports14_patch_cpu_2026-10/install_14c_patch_set_october_2026_manual.md).

---

## 11. Known problems / references

| Problem | Cause / fix |
|---|---|
| `90-oracle_validate.sh` FAIL `securerandom.source=file:/dev/random` | new JDK unpacked by hand – SecureRandom fix of step 5 missing (live 2026-11-18) |
| Smoke test: REP-50001 "The server is initializing" | test started right after `start-all` – wait for `rwserver_status.sh` OK |
| `cve_inventory.sh` FAIL "MISSING – configured for CPU Oct 2026" | conf not yet switched – the October patches are superseded; switch with `update_plan.md` |
| SOAP fault "Invalid operation" after the patch | new JAX-WS gate of PSU 40205408, default true (KB694158) – set `JAXWSRejectUnknownSEIOperationsEnabled=false` only for a legitimate client |
| EM / ADF app does not deploy, `BEA-149205` nativebridge / `graal-bundle` | ADF BP and WLS PSU / Third-Party BP from different cycles – SPB first, then ADF (PNEWS2138) |
| "OPatch succeeded" but patch missing | prereq failed or component missing ("skipped") – read the output |
| JDK switch refused: Java processes still run from `JDK_HOME` | ORDS unit `ords@ords_1` – `startStop.sh stop-all` stops it |
| Domain still on the old JDK after the link switch | `07-Maintenance/domain_jdk_path.sh --apply` |
| OPatch patches its own JDK / inventory damage | `JAVA_HOME` in `$ORACLE_HOME/oui/.globalEnv.properties` must point outside the home (KB175049) |

MOS: KA1182, CPU450, CPU435, KB694158, KB559857, PNEWS2138, KB379953,
KB175049, KB159467. Background: [00-patch-references.md](../../09-Install/docs/00-patch-references.md).
