# Step 3b – 06-oracle_patch_forms_reports.sh

**Script:** `09-Install/06-oracle_patch_forms_reports.sh`
**Runs as:** `oracle`
**Phase:** 3 – Forms & Reports Installation

---

## Purpose

Background – the QPRs relink native binaries (`frmweb` per Forms session,
`rwserver` / engines / `rwrun`), so every process of the home must be down:
[forms_runtime_architecture.md §1](../../80-FMW-Architecture/forms_runtime_architecture.md#1-the-parts),
[report_engine_architecture.md §1](../../80-FMW-Architecture/report_engine_architecture.md#1-the-parts);
the same patches on a running system: `07-Maintenance/82-`.

Apply Forms & Reports specific patches after the base F&R install. Patches
are listed in `INSTALL_PATCHES_REPORTS` and `INSTALL_PATCHES_FORMS` in
`oracle_software_version.conf` and applied **only for the component(s)
actually present** in `$ORACLE_HOME` — this project supports Reports-only
installs, so `INSTALL_PATCHES_FORMS` is automatically skipped when
`$ORACLE_HOME/forms` does not exist (and vice versa for a Forms-only host).

**If neither list has an applicable patch for this host, the script exits
OK — nothing to do.**

F&R and WLS share the same `ORACLE_HOME`. The WLS patches from `INSTALL_PATCHES`
(applied by `05-oracle_patch_weblogic.sh`: the WLS Stack Patch Bundle and,
since CPU Oct 2026, the eight FMW Infrastructure bundle patches) already
cover the shared home.
`INSTALL_PATCHES_REPORTS`/`INSTALL_PATCHES_FORMS` are only needed for patches
that are F&R-specific and not included in the WLS bundle.

A newer QPR typically **supersedes** (and OPatch-conflicts with) the one it
replaces. The script handles this automatically via a `SUPERSEDES` map: if
the old patch is found installed, it is rolled back before the new one is
applied — see "What the Script Does" below.

> **Current state (14.1.2, CPU Oct 2026):**
> `INSTALL_PATCHES_FR_COMMON="39951765 39987730 39100536"` (PERL SPU
> supersedes `38590500`, OHS BP, WebGate BP),
> `INSTALL_PATCHES_REPORTS="39600348"` (supersedes `38827528`),
> `INSTALL_PATCHES_FORMS="39842516"` (supersedes `38874285`) – the QPRs are
> unchanged since Aug/Sep 2026. Source: MOS KA1182 / KA204, see
> [`docs/00-patch-references.md`](00-patch-references.md); README facts and
> the manual procedure:
> [`70-Customer-Projects/Forms14_reports14_patch_analyse_10_2026/`](../../70-Customer-Projects/Forms14_reports14_patch_analyse_10_2026/README.md).

---

## INSTALL_PATCHES_REPORTS / INSTALL_PATCHES_FORMS

Defined in `09-Install/oracle_software_version.conf` (space-separated lists):

```bash
INSTALL_PATCHES_FR_COMMON="39951765 39987730 39100536"   # if Forms OR Reports is installed
INSTALL_PATCHES_REPORTS="39600348"
INSTALL_PATCHES_FORMS="39842516"
INSTALL_PATCHES_FR_OPTIONAL="38936596"   # only if REPORTS_BIDIPARENTHESIS=YES
```

`INSTALL_PATCHES_FR_COMMON` holds patches for components that only the Forms
& Reports installer brings – currently the FMW PERL SPU 39951765 (component
`oracle.perlint`, CVE-2026-4176), the OHS bundle patch 39987730 (`oracle.ohs2*`)
and the WebGate bundle patch 39100536 (`oracle.oamclient.webgate.ohs`). OHS and
WebGate are patched although Nginx is the frontend – the binaries are on disk;
their post-install (KB559857) needs nothing without an OHS instance. They are
applied before the QPRs (no dependency between them). In the
infrastructure-only home `05-` would
have it skipped by OPatch ("none of the components from patch are present",
confirmed 2026-10-14). If OPatch still skips a patch here, `06-` reports it
as **SKIPPED** (WARN), not as applied.

Apply and conflict check evaluate the OPatch **output**, not only the return
code (OPatch says "OPatch succeeded" with rc=0 even when the prereq failed or
the patch was skipped).

Current patches (Aug/Sep 2026):

| Patch | Product | Version | Platform | Date | Supersedes |
|---|---|---|---|---|---|
| `39600348` | Oracle Reports Developer | 14.1.2.0.0 | Linux x86-64 | Aug 2026 | `38827528` |
| `39842516` | Oracle Forms | 14.1.2.0.0 | Linux x86-64 | Sep 2026 | `38874285` |
| `38936596` | One-off (BiDi parentheses) | 14.1.2.0.0 | Generic (`p38936596_141200_Generic.zip`, MOS 2026-10-30) | — | — (complements `39600348`) |

**Reports `39600348` key fixes:** a superset of `38827528`'s fixes
(rwconverter ORA-00933, Hebrew text with parenthesis, ADB 23ai SRW package
registration, cgicmd.dat encryption for password values) plus additional
fixes for this cycle — see
`90-Source-MetaData/claude-memory/FMW14_Reports_Patch_CSPU_2026-09.md`
section 6 for the full bug list.

**Forms `39842516`:** superset of `38874285`'s fixes — only relevant if
Forms is actually installed in this `ORACLE_HOME`.

> **Note on KA204 platform confusion:** the KA204 article has repeatedly
> listed QPR entries under inconsistent version labels (e.g. "12.2.1.19")
> without a clear OS filter. Always verify platform (`Linux x86-64`) **and**
> product version (`14.1.2.0.0`) on the MOS patch detail page before
> downloading — do not trust the KA204 table alone.

To add a future Forms/Reports-specific patch:
1. Add a row to `09-Install/download/patches_fmw.csv` (role `reports` /
   `forms` / `fr_common`, exact file regexp, `dir` `patches/<nr>`, sha256
   after the first download) – the conf derives `INSTALL_PATCHES_REPORTS` /
   `INSTALL_PATCHES_FORMS` from it
2. Download the patch ZIP via `04-oracle_pre_download.sh --apply --mos`
   (or `mos_patch_download.sh` on a host with MOS access, see
   [download/README.md](../download/README.md))
3. If it supersedes an older patch, add that mapping to the `SUPERSEDES`
   array at the top of the "Automatic rollback of superseded QPRs" section
   in `06-oracle_patch_forms_reports.sh`
4. Run `06-oracle_patch_forms_reports.sh --check-only` first
5. Run `06-oracle_patch_forms_reports.sh --apply`

---

## Without the Script (manual)

The manual procedure is versioned **per patch cycle** – one folder per cycle
with the analysis (patch list, facts of every patch README) and a
step-by-step guide:

- **current:** [70-Customer-Projects/Forms14_reports14_patch_analyse_10_2026/install_14c_patch_set_october_2026_manual.md](../../70-Customer-Projects/Forms14_reports14_patch_analyse_10_2026/install_14c_patch_set_october_2026_manual.md)
  (CPU October 2026)
- older cycles: the folders `70-Customer-Projects/Forms14_reports14_patch_analyse_<mm>_<yyyy>/`
  and the frozen `00-patch-references_<month>_<year>.md` snapshots – see the
  cycle table in [00-patch-references.md](00-patch-references.md)

This section used to carry manual steps with fixed patch numbers (OPatch,
UMS bundle of January 2026); they aged with every cycle and were removed on
2026-10-24.

---

## What the Script Does

- Detects installed components: `$ORACLE_HOME/forms` and `$ORACLE_HOME/reports`
  (at least one must exist, or the script fails — run
  `06-oracle_install_forms_reports.sh --apply` first). Cross-checks this
  against `INSTALL_COMPONENTS` and warns (does not fail) on a mismatch
- Composes the wanted patch list (in this order): `INSTALL_PATCHES_FR_COMMON`,
  `INSTALL_PATCHES_FORMS` if `forms/` exists, `INSTALL_PATCHES_REPORTS` if
  `reports/` exists, plus `INSTALL_PATCHES_FR_OPTIONAL` if
  `REPORTS_BIDIPARENTHESIS=YES` – **Forms before Reports**, see
  "Forms relink fails after a Reports QPR" below
- Checks `lib/libzrc.so.0` against the glibc stubs (pre-check, before every
  Forms patch, and once more after all patches); with `--apply` it is rebuilt
  if needed – see the same section
- If the composed list is empty → exits OK with info message
- Reads current patch inventory via `opatch lspatches`
- **Automatic rollback of superseded QPRs**: for each patch about to be
  applied, checks a `SUPERSEDES` map (currently `39600348`→`38827528`,
  `39842516`→`38874285`, PERL `39951765`→`38590500`) and rolls back the old patch first if found
  installed — same idiom as the `23335292` pre-check in
  `05-oracle_patch_weblogic.sh`
- Skips patches already installed (idempotent)
- For remaining patches: extract ZIP to staging, conflict check, apply
- Cleans up staging directory after apply
- Verifies each applied patch appears in `opatch lspatches`
- **Does NOT upgrade OPatch** — already done in `05-oracle_patch_weblogic.sh`
- After a successful apply (`rc=0`), checks the `opatch apply` output for
  `"completed with warnings"` and surfaces it as a `warn()` (not a
  failure) — see the caveat below for what that means and which patterns
  are already known-harmless

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show pending Forms/Reports patches for the components actually installed |
| `--apply` | Apply pending patches, skip already-installed |
| `--check-only` | Conflict check only, do not apply |
| `--help` | Show usage |

---

## Notes

- `INSTALL_PATCHES_REPORTS`/`INSTALL_PATCHES_FORMS` are in
  `oracle_software_version.conf` (not `environment.conf`)
- F&R and WLS share one `ORACLE_HOME` — OPatch operates on the whole home
- FMW Bundle Patches often cover both WLS and F&R components; check the CPU
  advisory whether a separate F&R patch is listed
- OPatch upgrade is not repeated here (done in `05-oracle_patch_weblogic.sh`)
- Reports-only hosts: `forms/` simply does not exist, so
  `INSTALL_PATCHES_FORMS` is silently skipped — this is expected, not an error

---

## "Completed with warnings" — Patch 39600348 (confirmed 2026-10-14)

`opatch apply` for the Reports QPR `39600348` can end with
`"OPatch Session completed with warnings"` instead of the usual
`"OPatch succeeded"`, even though the patch itself applied correctly
(`rc=0`, and `"Patch 39600348 successfully applied."` is printed just
before it). The warnings come from two non-fatal linker (`ld`) notices
emitted during this patch's internal relink step, both confirmed
harmless:

- `the use of 'mktemp' is dangerous, better use 'mkstemp' or 'mkdtemp'` —
  a glibc linker notice, because Oracle's own `sobwv.c` still calls the
  deprecated `mktemp()`. Not fixable from our side, not an error.
- ``size of symbol `zrmpu_functypes' changed from 16 ... to 64 ...`` — the
  linker is only reporting that a symbol in the freshly patched `librw.a`
  is larger than a *common* placeholder in `rwsjni.o` (the Reports JNI
  bridge). A real conflict here would produce a hard
  `multiple definition` error, not a warning.

The Forms QPR `39842516` also ends with "completed with warnings"
(confirmed 2026-10-14): `the use of 'tempnam' is dangerous` (iebrw.c,
siedt.c, sdejm.c) and `ld: warning: -z lazyload ignored` (Solaris-only
linker option) – both harmless, the relink itself succeeds.

`06-oracle_patch_forms_reports.sh` detects `"completed with warnings"` in
the `opatch apply` output after a successful (`rc=0`) apply and surfaces
it via `warn()`, calling out the known patterns by name when present —
this does **not** change pass/fail, which is still decided purely by the
exit code.

Because the warning involves `rwsjni` specifically, test the JNI path
after applying this patch: run a report via `rwservlet` (PDF and HTML),
`rwrun` from the command line, `rwconverter` (fixes Bug 35740116 in this
QPR), and `showjobs` (fixes Bug 37595589).

If a *different*, unrecognized warning text appears for this or another
patch, it is not covered by the two patterns above — check
`$ORACLE_HOME/cfgtoollogs/opatch/` and consider an SR if anything looks
off after testing.

---

## Forms relink fails after a Reports QPR – libzrc.so / glibc (OL9, confirmed 2026-10-14)

Order applied: `38590500` → `39600348` (Reports) → `39842516` (Forms) on
Oracle Linux 9 (glibc 2.34). The Forms patch failed with `rc=73`:

```
Make failed to invoke "/usr/bin/make -f ins_forms.mk frmweb_install ..."
/usr/bin/ld: /u01/app/oracle/fmw/lib//libzrc.so: undefined reference to `dlsym@GLIBC_2.34'
Re-link fails on target "frmweb_install".
Re-link fails on target "dejvm_install".
OPatch failed to restore OH '/u01/app/oracle/fmw'.
```

**Cause:**
- The Reports QPR runs `make -f ins_reports.mk zrcsharedlib` →
  `$ORACLE_HOME/bin/genshlib zrc 0`. On Linux `genshlib` links with plain
  `gcc -shared *.o` – against the **system** glibc. On OL9 the new
  `lib/libzrc.so.0` therefore needs `dlsym@GLIBC_2.34`.
- The Forms relink (`frmweb`, `dejvm`) links with `-L$ORACLE_HOME/lib/stubs`.
  These stubs are glibc **2.28** and know no `GLIBC_2.34` → undefined reference.
- Every Forms relink after a Reports QPR fails – also with future QPRs.

**What the script does (automatic):**
- Applies Forms patches **before** Reports patches.
- `_fix_libzrc_glibc` checks which GLIBC versions `libzrc.so.0` needs that
  `lib/stubs/libc.so.6`/`libdl.so.2` do not provide. Dry-run/`--check-only`
  only report it (WARN); `--apply` rebuilds the library from `lib/libzrc.a`
  against the stubs (backup `libzrc.so.0.glibc_<timestamp>` next to it).
- Runs in the pre-checks, before every Forms patch and after all patches
  (keeps the home ready for the next Forms QPR).

**Manual fix (same as the script):**

```bash
export ORACLE_HOME=/u01/app/oracle/fmw
cp -p $ORACLE_HOME/lib/libzrc.so.0 $ORACLE_HOME/lib/libzrc.so.0.glibc_$(date +%Y%m%d_%H%M%S)
mkdir /tmp/libzrc && cd /tmp/libzrc
ar x $ORACLE_HOME/lib/libzrc.a
gcc -shared -Wl,-G,-hlibzrc.so.0 -L$ORACLE_HOME/lib/stubs -o libzrc.so.0 *.o -ldl
install -m 755 libzrc.so.0 $ORACLE_HOME/lib/libzrc.so.0
nm -D $ORACLE_HOME/lib/libzrc.so.0 | grep -w dlsym     # expected: dlsym@GLIBC_2.2.5
cd / && rm -rf /tmp/libzrc
```

**Clean-up after a failed Forms apply (seen on the test host):**
- OPatch restored the files, but not the binaries: `bin/dejvm` was deleted
  by `dejvm_clean`, and `inventory/oneoffs/<patch>` was left behind (the
  patch is not in `opatch lspatches`).
- Fix libzrc as above, remove `inventory/oneoffs/<patch>` (what OPatch's
  `restore.sh` in `.patch_storage/NApply/<timestamp>/` does), relink:
  ```bash
  cd $ORACLE_HOME/procbuilder/lib && make -f ins_procbuilder.mk dejvm_install ORACLE_HOME=$ORACLE_HOME
  cd $ORACLE_HOME/forms/lib       && make -f ins_forms.mk frmweb_install       ORACLE_HOME=$ORACLE_HOME
  ```
- Then apply the Forms patch again (`06-oracle_patch_forms_reports.sh --apply`).

Reports-only hosts that never apply a Forms patch are not affected.

**Oracle reference:** MOS **KB873815** – "ALERT: LIBZRC.SO: UNDEFINED REFERENCE
TO `DLSYM@GLIBC_2.34` error applying Forms QPR or relinking Forms after applying
Reports QPR on Linux 9" (last updated Sep 30, 2026).
- Tracked as **Bug 38892485**, status "being investigated" – **no fix patch yet**.
  (The MOS Support AI named 37795631 as fix – wrong: that patch belongs to
  KB177278, the Forms EXIT_FORM crash FRM-93656/93652, Bug 36749613, and is
  already covered by DB RU 39264447 from the SPB – see `00-patch-references.md`.)
- Also affects 12.2.1.19 (Reports QPR 38617683) and 14.1.2 since Reports QPR
  38827528 (Jan 2026).
- Oracle's workaround: move `lib/libzrc.so` away, so the Forms relink
  links `libzrc.a` statically, then rebuild the Reports side:
  ```bash
  cd $ORACLE_HOME/lib         && mv libzrc.so libzrc.so_back
  cd $ORACLE_HOME/forms/lib   && make -f ins_forms.mk frmweb_install
  cd $ORACLE_HOME/reports/lib && make -f ins_reports.mk install
  make -f ins_reports.mk zrcsharedlib
  ```
  Difference: `zrcsharedlib` builds `libzrc.so.0` against the system glibc again,
  so the next Forms relink hits the problem again. Our rebuild against
  `lib/stubs` keeps the home relink-safe.

---

## How to Find the Current F&R QPR Patch Number

Since January 2022 Oracle delivers Forms fixes as **Quarterly Patch Releases (QPRs)**
on the same schedule as the CPU (January / April / July / October).
Oracle Reports was added to this programme in **May 2025**.

**Authoritative source — MOS Knowledge Article KA204:**

> *Oracle Forms and Reports Quarterly Patch Information*
> MOS → Search → Knowledge → **KA204**
> Applies to: Oracle Forms / Reports all versions

The article lists QPR patches per product and version.

**Steps to check for new QPR patches each CPU cycle:**
1. Open MOS → Knowledge → search `KA204`
2. Note the patch numbers listed for **Forms** and **Reports**
3. Click on the patch number → MOS shows a **list of platform-specific patches**
   for that QPR release (Linux, Windows, Solaris, AIX, HP-UX …)
4. Select **Linux x86-64** → verify on the patch detail page:
   - Platform = `Linux x86-64`
   - Product Version = `14.1.2.0.0`
5. Note the patch number for this platform variant
6. Update `INSTALL_PATCHES_REPORTS` or `INSTALL_PATCHES_FORMS` (whichever
   product the patch is for) in `oracle_software_version.conf`, and add a
   `SUPERSEDES` entry in the script if it replaces an older patch
7. Run `04-oracle_pre_download.sh --apply --mos` to download
8. Run `06-oracle_patch_forms_reports.sh --check-only` then `--apply`

> **KA204 platform selection — important:**
> After clicking a patch link in KA204 you land on a list of platform variants.
> Oracle does **not** sort this list consistently — Linux x86-64 can appear anywhere,
> not necessarily at the top. Scan the full list and select `Linux x86-64` explicitly.
> Do not assume the first entry or the largest file is the correct one.
>
> Additionally, KA204 itself has no OS filter and may mix version labels in the same
> table (e.g. "12.2.1.19" and "14.1.2" entries side by side). Always confirm
> platform **and** product version on the patch detail page before updating the config.

**QPR release schedule:** January / April / July / October (same as CPU).
Oracle Reports joined the QPR programme in **May 2025**.
