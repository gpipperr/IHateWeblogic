---
nav_title: "Update plan CSPU Nov 2026"
title: "Update Plan – Switch the Library to the CSPU November 2026"
description: "Prompt and facts to switch the IHateWeblogic library from CPU October 2026 to CSPU November 2026: patch table, change list per file, checks, release v1.0.202611"
---

# Update plan – switch the library from CPU October 2026 to CSPU November 2026

> **Done 2026-11-18** – library switched, release `v1.0.202611`. Kept as the
> record of this switch (facts + change list).

**Start (after the live run on the test host):**

```bash
claude "Follow docs/update_lib_to_act_cpu.md with the facts of 70-Customer-Projects/FormsReports14_patch_cspu_2026-11/update_plan.md"
```

## 1. Role and goal

Switch the IHateWeblogic library from **CPU October 2026** (`cpuoct2026`,
2026-10-20) to **CSPU November 2026** (`cspunov2026`, 2026-11-17) – in one
commit, release tag **`v1.0.202611`**. The procedure is
[docs/update_lib_to_act_cpu.md](../../docs/update_lib_to_act_cpu.md); this
file holds only the facts of this cycle.

Already done in stage 1 (2026-11-18, not part of the switch commit's work,
but part of the same commit if not committed before):
`09-Install/docs/00-patch-references_october_2026.md` (frozen),
`00-patch-references.md` (reworked for November), this folder (README,
two guides, this plan), `docs/update_lib_to_act_cpu.md`.

**Gate:** live run of stage 2 – **done 2026-11-18** (README section 8, "Live
results" below).

## 2. Facts

### Patch table (old → new)

| Role (`patches_fmw.csv`) | Old (CPU Oct 2026) | New (CSPU Nov 2026) | Platform / file | OPatch min | ARU (ZIP) | SHA-256 (ZIP, 2026-11-18) |
|---|---|---|---|---|---|---|
| `opatch` | 28186730 (.25) | **unchanged** | `p28186730_1394225_Generic.zip` | – | – | unchanged |
| `spb` | 40125898 (14.1.2.0.261007) | **40289362** (14.1.2.0.261112) | 226P\|2000P, `p40289362_141200_Generic\.zip` | 13.9.4.2.25 | – (bundle) | `2b5a0951c6c9afd70df2bb6b11b667f1bb4b2f4d3e67e7284ca8f2d8ff5651b6` |
| `wls` ADF | 40050062 (.260920) | **40155248** (.261013) | 226P\|2000P, `p40155248_141200_Generic\.zip` | 13.9.4.2.17 | 29510056 | `a96c88248b8b28dabaaca905f040ae9e56a5a8caa5b71a0040cfb91db1b4fa15` |
| `wls` WebCenter Core | 40035984 | unchanged | | | | |
| `wls` OWSM | 40024749 | unchanged | | | | |
| `wls` FMW Control | 39995927 | unchanged | | | | |
| `wls` OAMCLIENT | 40057999 | unchanged | | | | |
| `wls` UMS | 39940047 (.260827) | **40145610** (.261012) | 226P\|2000P, `p40145610_141200_Generic\.zip` | 13.9.4.2.17 | 29500732 | `3069d53f0edc58630934c820e1f0d7dddbdf41c6afe7464d6f1ec81534624b22` |
| `wls` OPSS | 39979746 (.260904) | **40154045** (.261013) | 226P\|2000P, `p40154045_141200_Generic\.zip` | 13.9.4.2.17 | 29506290 | `22854270194918883bf126d7309cdf2c8ff65d2b4325992b7c79507d30dd4a9d` |
| `wls` LibOVD | 39726399 | unchanged | | | | |
| `fr_common` PERL | 39951765 | unchanged | | | | |
| `fr_common` OHS | 39987730 (.260907) | **40181911** (.261020) | 226P, `p40181911_141200_Linux-x86-64\.zip` | 13.9.4.2.17 | 29522371 | `111a479d7567b1d815979231e7b03c96149bb8451eedee2d95b121771f106bee` |
| `fr_common` WebGate | 39100536 | unchanged | | | | |
| `reports` / `forms` QPR | 39600348 / 39842516 | unchanged | | | | |
| `jdk` | 35702194 = 21.0.13.0.2 | 35702194 = **21.0.13.1** (fixed 40239626) | 226P, `p35702194_2100_Linux-x86-64\.zip` | – | – | `89cbcb2c30c13635dd18a6c3071b8fd3a656fcc67ca1199081213c5e055fa0bd` |
| `client_jdk` | 35702194 Windows = 21.0.13.0.2 | **21.0.13.1** | 233P, `p35702194_2100_MSWIN-x86-64\.zip` | – | – | `1bdefe790d9d1a39dc5dee04bba64653575c1bdf5b0dc07b6376daaf2758f0c7` |
| `apex` | – (APEX 26.2.0) | **40040466** (→ 26.2.1, PATCH_VERSION 1) | 2000P, `p40040466_262_Generic\.zip` | – | – | `620fa757d89d37af0a753f1062a7d17e95c86e43921c15d1329b78156699100a` |

`patches_db.csv` (repository DB 19c):

| Role | Old | New | File | Note | SHA-256 |
|---|---|---|---|---|---|
| `db_ru` / `ojvm` / `dpbp` / `db_opatch` | 39915792 / 39803650 / 40057600 / 6880880 (12.2.0.1.55) | unchanged | | | |
| MRP (new role, e.g. `db_mrp`) | – | **40196156** DB MRP 19.33.0.0.261117 | `p40196156_1933000DBRU_Linux-x86-64\.zip` | `opatch napply` + `datapatch`; DB OPatch ≥ 12.2.0.1.52 | `3b2eb60cc8e7812ab9dd126ecfc56fcf495abfd4b212135cd375374bef22678e` |
| `db_jdk` | 39902051 (8u511) | **40245331** (8u513) | `p40245331_190000_Linux-x86-64\.zip` | DB OPatch ≥ 12.2.0.1.54; ARU 29556470 | `0b0a8ca39b1320f3a9b3e34eec04b2d67221fa98ecbfef8ad8c169a64e13efbc` |

### SPB facts

- Marker **40289390** (interim 40289366) → `WLS_SPB_MARKER_PATCH`.
- PSU 40205408 cumulative incl. 39924025 → `WLS_SPB_CHECK_BUGS="39924025"`
  stays; candidate to add: `40073770` (JAX-WS gate – proves the November
  PSU) – decide in the switch.
- OPatch minimum stays 13.9.4.2.25 (`OPATCH_VERSION_MIN/_INSTALL`,
  `OPATCH_PATCHES_MIN` unchanged).
- Java minimum of the SPB unchanged (17.0.12+ / 21.0.4+); the cycle demands
  `JDK_VERSION_MIN="21.0.13.1"`.
- SPB directory `WLS_SPB_14.1.2.0.261112/`, patch lists unchanged names.

### Other values

| Item | Old | New |
|---|---|---|
| `PATCH_CYCLE` / `_DATE` / `_ADVISORY` | `CPU Oct 2026` / `2026-10-20` / `cpuoct2026` | `CSPU Nov 2026` / `2026-11-17` / `cspunov2026` |
| Client JRE 8 (Web Start, customer docs) | 40186686 (8u511) | **40239650** (8u513-b04) |
| ORDS | 26.3.0 | **26.3.1** (`ords-latest.zip`, 2026-11-04) |
| New PSU behaviour | – | `JAXWSRejectUnknownSEIOperationsEnabled` default true (KB694158) |
| Release | `v1.0.0` | `v1.0.202611` |

### Live results (stage 2) – test host 2026-11-18

- Applied **by hand** with the cumulative guide (README section 8): JDK
  21.0.13.1, SPB 40289362 (`-report` ~8 min, `napply` ~11 min), ADF / OPSS /
  UMS (~14 min), OHS (~4.5 min); start 2.5 min; smoke test 32 OK;
  `90-oracle_validate.sh` 0 FAIL; no invalid RCU objects; no JAX-WS "Invalid
  operation" faults; EM / console / Forms / ORDS HTTP 200.
- `napply -report`: supersets 40205408 > 40058371, 40288205 > 40035655,
  40289390 > 40126042; duplicates 39264447 / 39984190 / 39646824 / 39487373 /
  38391376; Samples skipped. **Bundle replacement:** OPatch made 40050062 /
  39979746 / 39940047 / 39987730 "inactive" by itself (sub-set) – **no
  `SUPERSEDES` entry needed** for `05-` / `06-` (check: does `06-` /
  `cve_inventory.sh` treat an *inactive* old patch correctly? `lspatches`
  no longer lists them).
- **Lib-relevant finding:** a manual JDK unpack misses the SecureRandom fix
  (new JDK = `file:/dev/random`) – the scripts `02b-` / `80-` do it; guides
  fixed. Check during the switch that `80-patch_java_os.sh --apply` really
  applies it non-interactively (it did in October) – no code change
  expected.
- `cve_inventory.sh` with the October conf: 5 FAIL "MISSING" for the
  superseded October patches → must be 0 after the conf switch (check of
  section 6). Optional improvement (TODO): recognise "superseded by an
  installed newer patch".
- `15-` smoke test right after `start-all`: REP-50001 "server is
  initializing" – optional improvement (TODO): retry / wait for
  `rwserver_status`.
- Forms session from a Windows PC after the live run: **OK** (Gunther,
  2026-11-18). Client bundle `40- --apply` (21.0.13.1) after the conf switch.
- **DB window live 2026-11-18:** MRP 40196156 in-place `opatch napply` (~9
  min) + DB JDK 40245331 `opatch apply` (~3 min) on the 19.33 home, both
  conflict checks passed; `datapatch` had **nothing to apply** (MRP
  one-offs binary-only); smoke / RCU check OK; downtime ~17 min. For the
  `09- --mrp` mode: stop domain → `systemctl stop oracle-db oracle-listener`
  (listener unit ends "failed" – `reset-failed`) → prereq → `napply` →
  DB JDK `apply` → start → open PDBs → `datapatch` (keep it – a later MRP
  can carry SQL) → `dba_registry_sqlpatch` / invalid objects → start domain.
  Always export `ORACLE_HOME` of the DB home before `opatch`.
- **APEX / ORDS window live 2026-11-18:** `03-patch-apex.sh --apply` with a
  temporary CSV (`IHW_PATCH_CSV`, current list + `apex` row 40040466) →
  APEX 26.2.1 (24 s); `06-patch-ords.sh --apply` → ORDS 26.3.1.303.1615 (25
  s, repository 26.3.1.r3031615). For the switch: the `apex` row as tested
  (`apex/patch/40040466`, ZIP already in the live storage); `04-` must
  recognise a **newer** `ords-latest.zip` than the stored one (today: ORDS
  ZIP downloaded by hand to `ords/26.3.1.303.1615/`) – fix in the switch or
  TODO; `06-` confirmation prompt needs `y` in non-interactive runs.
- **Java4Shell (CVE-2026-114938)** documented in `00-patch-references.md`
  (section "Java4Shell"): fixed for `JDK_HOME` by 21.0.13.1; the bundled
  JDK 17.0.12 of the Reports engines is in the affected range without an FMW
  patch – on AVX-512 VBMI hosts mitigate with `-XX:-UseBASE64Intrinsics`
  (test host: no AVX-512). In the switch: mention it in
  `80-FMW-Architecture/security_overview.md` (was `docs/forms_reports_security.md`) and the customer cookbooks
  (`Reports14_linux_manual_install/Reports_security.txt`, Java note of
  `OS_Kochbuch_de.txt`); Forms client bundle `40- --apply` (21.0.13.1) has
  priority right after the switch (client PCs often Zen 4 / Ice Lake+).
- All windows of the cycle are done on the test host (FMW, DB MRP + JDK,
  APEX, ORDS) – the switch can start.
- The live patch storage is still on October; the November ZIPs are in
  `/srv/patch_storage/staging_cspunov2026/` (section 7: move / archive).

## 3. Change list

Areas as in [docs/update_lib_to_act_cpu.md](../../docs/update_lib_to_act_cpu.md) section 5.

### A – Patch lists
- [ ] `09-Install/download/patches_fmw.csv`: header "CSPU November 2026 (2026-11-17, cspunov2026)", sources line (KA1182, CPU450, CPU435, this folder); rows 40125898 → 40289362, 40050062 → 40155248, 39940047 → 40145610, 39979746 → 40154045, 39987730 → 40181911 (file regexps, descriptions with the new versions, `dir`, sha256 + aru from section 2); both 35702194 rows: description 21.0.13.1 + new sha256; new row `apex` 40040466 (2000P, `apex/40040466`).
- [ ] `09-Install/download/patches_db.csv`: **new role `db_mrp`** with 40196156 (header comment: "MRP / CSPU patch of the month on top of the RU of the last CPU – two layers"), `db_jdk` 39902051 → 40245331. Check how `60-RCU-DB-19c/01-` / `09-` read the roles (an unknown role must not break them).
- [ ] `70-Customer-Projects/Reports14_linux_manual_install/`: new `patches_cspu_reports_14c_nov2026.csv` + `Patch_Kochbuch_CSPU_Nov2026_de.txt` (German ASCII, from the cumulative guide); the October files stay.

### B – Conf `09-Install/oracle_software_version.conf`
- [ ] `PATCH_CYCLE*` (section 2); header comment → `FormsReports14_patch_cspu_2026-11/`, previous cycle frozen in `docs/00-patch-references_october_2026.md`.
- [ ] `OPATCH_VERSION_MIN` comment "(CSPU Nov 2026, Patch 40289362)".
- [ ] `WLS_SPB_VERSION="14.1.2.0.261112"`, `WLS_SPB_MARKER_PATCH="40289390"`, `WLS_SPB_CHECK_BUGS` (+ 40073770?), comment block; "Superseded" line: SPB 40125898 / marker 40126042 (CPU Oct 2026).
- [ ] `JDK_VERSION_MIN="21.0.13.1"` + comment (CPU435, ZIP checked 2026-11-18: `jdk-21.0.13.1_linux-x64_bin.*`; closes CVE-2026-114820).
- [ ] APEX / ORDS pins if any (`APEX_ZIP_URL` stays 26.2 base; ORDS via `ords-latest.zip`).

### C – Scripts
- [ ] `09-Install/06-oracle_patch_forms_reports.sh` `SUPERSEDES` – live run: **not needed** (OPatch deactivates the sub-set bundles); leave unchanged.
- [ ] `09-Install/05-oracle_patch_weblogic.sh` – bundle replacement and bug check worked live? No change expected.
- [ ] `12-APEX-Ords/04-install-ords.sh` / `06-patch-ords.sh` – expected ORDS version text 26.3.0 → 26.3.1 where named.
- [ ] **DB MRP in the lib (decided 2026-11-18):** *(2026-11-18: `09-db_patch_rcu.sh --mrp` implemented, dry-run tested – first `--apply` with the December MRP; the AutoUpgrade question below stays open)* first check whether AutoUpgrade (newest jar, as `01-` loads it) delivers the MRP with `recommended` or needs an own keyword (e.g. `mrp`) – result decides the new-install route of `01-` (`recommended,jdk` → `recommended,mrp,jdk`?) and is documented in `docs/01-db_install_software.md` (keyword table). For an existing home on the right RU: `09-db_patch_rcu.sh` gets an **in-place MRP mode** (`--mrp`: stop DB + listener, `opatch prereq CheckConflictAgainstOHWithDetail`, `opatch napply <mrp dir>`, start, `datapatch` with all PDBs open, check `dba_registry_sqlpatch`) – plus `docs/09-db_patch_rcu.md`. Live test in the DB window (MRP 40196156 + DB JDK 40245331 on the test host) before the switch commit, or the MRP part stays "documented" and the conf keeps it optional.
- [ ] `00-Setup/detect_env_conf.sh` – version examples (21.0.13.0.2).

### D – Install docs
- [x] `09-Install/docs/00-patch-references.md` – new section "What a home needs – CPU vs. CSPU" (written 2026-11-18, before the switch); after the DB MRP decision update its DB row.
- [ ] `09-Install/docs/00-patch-references.md` – cycle row "lib switched 2026-MM-DD", state block at the top.
- [ ] `09-Install/docs/04-oracle_pre_download.md` – conf table, download block, storage tree (`WLS_SPB_14.1.2.0.261112`, 40040466).
- [ ] `09-Install/docs/05-oracle_patch_weblogic.md` – current set, SPB section, **hardening list: November 2026 JAX-WS gate (default true)** next to the Aug / Sep editions.
- [ ] `09-Install/docs/06-oracle_patch_forms_reports.md` – current state (OHS 40181911).
- [ ] `09-Install/docs/40-forms_client_distribution.md` – client JDK 21.0.13.1, JRE 8u513.
- [ ] `09-Install/download/README.md`, `09-Install/README.md`.
- [ ] `60-RCU-DB-19c/docs/09-db_patch_rcu.md`, `60-RCU-DB-19c/README.md`, `60-RCU-DB-19c/docs/01-db_install_software.md` – MRP + DB JDK 8u513.
- [ ] `12-APEX-Ords/README.md` – APEX 26.2.1, ORDS 26.3.1.

### E – Cycle folder
- [ ] This folder: README state "lib switched", both guides "Automated" lines / status "confirmed (live)".
- [ ] `70-Customer-Projects/FormsReports14_patch_cpu_2026-10/README.md` (+ guide): only the frozen header with a link here.
- [ ] `70-Customer-Projects/README.md`: index entry of this folder, October marked frozen.

### F – Customer folders (current patch level; patch-run folders stay frozen)
- [ ] `Reports14_linux_manual_install/`: `FMW_Kochbuch_de.txt` step 3, `Reports_kochbuch_de.txt` step 2, `OS_Kochbuch_de.txt` (JDK 21.0.13.1 example + Java note), `Reports_security.txt` step 12, `README.md` download checklist + "Patchstand".
- [ ] `14-ReportsBuilder/`: `ReportBuilder_Windows_Kochbuch_de.txt` / `_en.txt` download checklist + step 4, `ReportsBuilder_install_windows.md` – Windows variants: SPB with `windows64_patchlist.txt`, bundles Generic (ADF 40155248, OPSS 40154045, UMS 40145610), OHS 40181911 **Windows x64 ZIP** only if OHS is in the Builder home, JDK 21.0.13.1 Windows ZIP; check every platform patch for its 233P ZIP.
- [ ] `FormsReports_change_java/Java_wechsel_Kochbuch_de.txt` – JDK 21.0.13.1.
- [ ] `cookbook-Skill.md` – examples.

### G – Architecture pages (current-state statements only)
- [ ] `80-FMW-Architecture/`: `java_jlink_forms_env.md`, `certificates_trust_stores.md`, `oracle_patch_basics.md`, `ords_architecture.md`, `apex_architecture.md`, and the other hits of the sweep (`weblogic_middleware_architecture.md`, `reports_engine_architecture.md`, `fmw_forms_reports_licence.md`, …).

### H – Overview
- [ ] root `README.md` (Project Status, Security & Patch Status), `docs/project_status.md`, `80-FMW-Architecture/security_overview.md` §2 (was `docs/forms_reports_security.md`), `docs/forms_reports_sizing.md`, `10-Monitoring/README.md`, `TODO.md`.
- [ ] `CHANGELOG.md`: `## v1.0.202611 – CSPU November 2026` (areas A–J).

### I – Customer tools
- [ ] If a tool or a CSV it reads changed: bump `VERSION`, `70-Customer-Projects/tools/make_customer_zip.sh --apply`.

### J – Monitoring and skill
- [ ] `10-Monitoring/cve_inventory.sh` output shows CSPU Nov 2026.
- [ ] `10-Monitoring/patch_cycle_analysis_skill.md`: §4 new rules – **KA1182 is cumulative: in a CSPU month the full set still contains the CPU patches, never drop unchanged rows; two layers only for the repository DB (RU of the CPU + MRP) and APEX (release + patch set bundle); overlay case (CSPU patch on the CPU PSU = `spb` + `wls` row)** – "Service Delivery Platform" = UMS in the phase-1 filter; matrix vs. PAD (CPU450) differ → follow the PAD; final advisory can change the affected range (ORDS) → always re-read; MOS README text can carry template errors (DB MRP base RU) → trust the inventory. §1 / §3.5 / §5 / §6: two guides per cycle, archive name `00-patch-references_<month>_<yyyy>.md`, release tag `v1.0.<yyyymm>`, pointer to `docs/update_lib_to_act_cpu.md`.
- [ ] `docs/project_status.md`: link to `docs/update_lib_to_act_cpu.md`.

## 4. Sweep – old values of this cycle

```bash
git grep -n -E '40125898|40126042|261007|40058371|40035655|40050062|39979746|39940047|39987730|21\.0\.13\.0\.2|40186074|40186686|39902051|CPU Oct(ober)? 2026|cpuoct2026|ORDS 26\.3\.0|26\.3\.0\.272' -- . \
    ':!09-Install/docs/00-patch-references_*.md' \
    ':!70-Customer-Projects/FormsReports1*_patch_*/' \
    ':!70-Customer-Projects/Reports14_linux_manual_install/Patch_Kochbuch_*' \
    ':!70-Customer-Projects/Reports14_linux_manual_install/patches_*_reports_14c_*.csv' \
    ':!CHANGELOG.md' ':!diagrams/'
```

Expected kept hits: dated history ("applied 2026-10-24", "Superseded"
lists), the eMudhra / Java history in `00-patch-references.md`.

## 5. Rules

From the skill §4 and the project: doc-as-master; customer cookbooks German
pure ASCII, 80 columns, blank line after every command; no verbatim MOS / KA
text; customer-data scan (pre-commit hook); never edit a script while it
runs; `--apply` tests only in isolated copies; no commit / push / tag
without Gunther's go.

## 6. Checks

As in [docs/update_lib_to_act_cpu.md](../../docs/update_lib_to_act_cpu.md)
section 7, plus for this cycle:

- `mos_patch_download.sh -c 09-Install/download/patches_fmw.csv -d <scratch> --all`
  (plan) resolves 40289362 / 40155248 / 40154045 / 40145610 / 40181911 /
  40040466;
- `04-oracle_pre_download.sh` (plan) names `WLS_SPB_14.1.2.0.261112`;
- `05-` / `81- --check-only` on the switched test host: all "already
  applied", marker 40289390 found, 39924025 found;
- `02b-root_os_java.sh` (check mode): JDK 21.0.13.1 ≥ `JDK_VERSION_MIN`;
- `cve_inventory.sh`: cycle "CSPU Nov 2026".

## 7. Finish

- README of this folder and the cycle row in `00-patch-references.md`:
  "lib switched YYYY-MM-DD".
- `git diff --cached --stat`, ask → one commit "Lib switched to CSPU Nov
  2026 (release v1.0.202611)", ask → push, `git tag -a v1.0.202611`,
  `gh release create` with the tools ZIPs + `.sha256`.
- Archive the October ZIPs and move the staging ZIPs into the patch storage
  (`04-oracle_pre_download.sh --apply --fresh-patches --mos` or move
  `/srv/patch_storage/staging_cspunov2026/*` into place).
- Session memory.
