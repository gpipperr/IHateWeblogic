---
title: "Switch the Library to a New Oracle Patch Cycle"
description: "Fixed step list to lift IHateWeblogic to the current Oracle CPU / CSPU after the patch analysis: patch lists, conf, scripts, docs, cookbooks, commit, release."
---

# Switch the Library to a New Oracle Patch Cycle (CPU / CSPU)

The library always follows the **current** Oracle patch cycle. After the
analysis of a new cycle, every place that names a patch number, a JDK build
or a cycle has to move to the new state – in one go, so that conf, scripts,
docs and cookbooks fit together. This page is the **fixed step list** for
that switch. It does not change per cycle; the values of one cycle come from
the `update_plan.md` of that cycle.

Result of every switch: **one commit**, the release tag **`v1.0.<yyyymm>`**
(year + month of the cycle, e.g. `v1.0.202611` for CSPU November 2026) and a
GitHub release.

---

## 1. Place in the patch cycle

[`10-Monitoring/patch_cycle_analysis_skill.md`](../10-Monitoring/patch_cycle_analysis_skill.md)
splits a cycle into three stages:

| Stage | What | Result |
|---|---|---|
| 1 ANALYSE | `patch_cycle_analysis.sh prepare` / `analyse --mode maintainer` | `readme_list.md`, the new cycle folder (section 2), archived + new `00-patch-references.md`, `update_plan.md` |
| 2 MANUAL | live run on the test host with the manual guide or `07-Maintenance/80-`…`82-` | runtimes and findings in §8 of the analysis README, `[Doku]` → `[live]` |
| 3 UPDATE | **this page** + the values of `update_plan.md` | one commit, tag `v1.0.<yyyymm>`, release |

Start of stage 3 (one Claude session, from the repository root):

```bash
claude "Follow docs/update_lib_to_act_cpu.md with the facts of 70-Customer-Projects/FormsReports14_patch_<cpu|cspu>_<yyyy>-<mm>/update_plan.md"
```

`update_plan.md` holds the facts (patch table old → new, SPB marker,
superset findings, live results); this page holds the procedure. Nothing of
the procedure is repeated in `update_plan.md`.

---

## 2. Cycle documents – naming rule

Created in stage 1; the switch only sets their status.

| Document | Rule | CSPU November 2026 |
|---|---|---|
| Previous cycle folder | stays **as it is** – only the one-line header "Frozen – do not edit" with a link to the new folder | `70-Customer-Projects/FormsReports14_patch_cpu_2026-10/` |
| New cycle folder | `70-Customer-Projects/FormsReports14_patch_<cpu\|cspu>_<yyyy>-<mm>/` – spelled like the advisory id | `FormsReports14_patch_cspu_2026-11/` |
| Analysis | `README.md` in the new folder (patch list, README facts 3a, order, open points, runtimes §8) | |
| Manual guide – full | `install_14c_patch_set_<month>_<yyyy>_manual_full.md` – the whole cumulative set, for a home on **any** older level | `install_14c_patch_set_november_2026_manual_full.md` |
| Manual guide – cumulative | `install_14c_patch_set_<month>_<yyyy>_manual_cumulativ_from_<cpu\|cspu><mm><yyyy>.md` – only the patches newer than the **directly previous** cycle | `install_14c_patch_set_november_2026_manual_cumulativ_from_cpu102026.md` |
| Patch references (archive) | the current `09-Install/docs/00-patch-references.md` is copied to `00-patch-references_<month>_<yyyy>.md` – the month it **describes** – plus the "Frozen snapshot … Do not edit" header | `00-patch-references_october_2026.md` |
| Patch references (current) | `00-patch-references.md` rewritten for the new cycle, new row in the cycle table | |
| Switch prompt | `update_plan.md` in the new folder | |

Rule for the cumulative guide: it always goes back **one** cycle. A home
that is older than the previous cycle uses the full guide. Same pattern as
the 12c customer folders (full cookbook + cookbook on top of the previous
cycle).

**CPU or CSPU makes no difference for the FMW lists.** KA1182 is cumulative:
in a CSPU month it still lists the patches of the last CPU (release column
"Oct 2026" etc.). The full guide and `patches_fmw.csv` therefore always hold
the **complete current KA1182 set** – a never patched home gets "CPU + CSPU"
in one run, a home on the previous cycle only the new rows. Two layers
exist only outside KA1182: the **repository DB** (RU of the last CPU + MRP /
CSPU patch of the month) and **APEX** (base release + patch set bundle).
Details and the overlay special case (a CSPU patch on top of the CPU's PSU):
[00-patch-references.md – What a home needs](../09-Install/docs/00-patch-references.md#what-a-home-needs--cpu-vs-cspu-one-list-two-starting-points).
Never drop an unchanged row from `patches_fmw.csv` because "it came with the
CPU" – it is still part of the set.

---

## 3. Gates – check before starting

Stop and report if one of them is open.

- [ ] Analysis `README.md`, both manual guides and `update_plan.md` exist in
      the new cycle folder.
- [ ] Every README was read **from the ZIP** (portal texts can be
      placeholders) – section 3a of the analysis is complete.
- [ ] `00-patch-references.md` is archived and rewritten (section 2).
- [ ] Live run on the test host done – by hand with the **cumulative
      guide** (the scripts still read the old conf) or with
      `07-Maintenance/80-`…`82-` after a temporary conf: OPatch without
      errors, start + smoke test `15-` OK, `09-Install/90-oracle_validate.sh`
      0 FAIL, Forms session from a Windows PC OK, runtimes and findings in
      §8, live results in `update_plan.md`.
- [ ] Own windows of the cycle done or consciously postponed (noted in
      `update_plan.md`): repository DB (RU / MRP + DB home JDK), APEX patch
      set bundle, ORDS release.
- [ ] `patches_sha256.csv` of the download run is available (sha256 + aru
      of every ZIP).
- [ ] `opatch lspatches` after the live run is in the analysis README.
- [ ] `main` in sync with `origin/main`; the only uncommitted files are
      the stage-1 documents of this cycle (archive + new
      `00-patch-references.md`, the cycle folder, notes in `TODO.md`) – they
      go into the switch commit. Anything else uncommitted: stop and ask.
- [ ] Nobody runs a library script on the test host right now (never edit a
      running script).

---

## 4. Inputs

| Input | Used for |
|---|---|
| `update_plan.md` | old → new values, change list of the cycle |
| analysis `README.md` §3a / §7 / §8 | README facts, open points, live results, runtimes |
| `09-Install/docs/00-patch-references.md` (new) | patch numbers, CVE table, KA1182 state |
| `<PATCH_STORAGE>/patches_sha256.csv` (download run) | columns `sha256` / `aru` of the patch lists |
| `opatch lspatches` of the test host | SPB marker, superseded patches, final check |

---

## 5. Change steps

One block per area. Old → new values always from `update_plan.md`.

### A – Patch lists

| File | Change |
|---|---|
| [`09-Install/download/patches_fmw.csv`](../09-Install/download/README.md) | header line (cycle, date, advisory id); replace the rows of new patches; `sha256` / `aru` from `patches_sha256.csv` (empty `aru` for SPB / OPatch / JDK / CVU); remove superseded rows (they are documented in the conf "Superseded" list); new roles only if the conf reads them (e.g. `apex`) |
| `09-Install/download/patches_db.csv` | DB RU or MRP, OJVM, Data Pump BP, DB home JDK, DB OPatch of the cycle (repository DB) |
| `70-Customer-Projects/Reports14_linux_manual_install/` | new cycle files `patches_<cpu\|cspu>_reports_14c_<mon><yyyy>.csv` and `Patch_Kochbuch_<CPU\|CSPU>_<Mon><yyyy>_de.txt`; the files of the previous cycle stay as history |

### B – Conf `09-Install/oracle_software_version.conf`

- `PATCH_CYCLE`, `PATCH_CYCLE_DATE`, `PATCH_CYCLE_ADVISORY`
- `OPATCH_VERSION_MIN`, `OPATCH_VERSION_INSTALL`, `OPATCH_PATCHES_MIN`
- `WLS_SPB_VERSION`, `WLS_SPB_MARKER_PATCH`, `WLS_SPB_CHECK_BUGS`
- `JDK_VERSION_MIN`
- APEX / ORDS download URLs or versions, if they are pinned
- `ORDS_VERSION_MIN` – lowest ORDS release without an open CVE of the cycle
  (risk matrix "Oracle REST Data Services"; read by the customer patch analysis)
- comment blocks per patch and the **"Superseded"** list (old numbers with
  the cycle that replaced them)

The patch numbers themselves (`WLS_SPB_PATCH_NR`, `INSTALL_PATCHES*`,
`JDK_PATCH_NR`, `CLIENT_JDK_*`, `APEX_PATCH_NR`, …) are derived from the CSV
– never hard-code them in the conf.

### C – Scripts

| Script | When |
|---|---|
| `09-Install/06-oracle_patch_forms_reports.sh` | `SUPERSEDES` map (new QPR / PERL / OHS replaces an old one) |
| `09-Install/05-oracle_patch_weblogic.sh` | new post-install checks (bug check, gate) |
| `09-Install/04-`/`05-`/`06-`, `07-Maintenance/80-`…`82-` | only if the patch model changed (new mechanism, new pre-check, new role) |
| `12-APEX-Ords/03-patch-apex.sh`, `04-install-ords.sh`, `06-patch-ords.sh` | APEX patch set bundle (via CSV role `apex`), expected ORDS version |
| `60-RCU-DB-19c/01-db_install_software.sh`, `09-db_patch_rcu.sh` | via `patches_db.csv`; code changes when the DB patch route changes – e.g. a new vehicle type (CSPU month: MRP on top of the RU = new role, in-place `opatch napply` + `datapatch` instead of the out-of-place RU route) |
| `00-Setup/detect_env_conf.sh` | only version examples / defaults |
| `70-Customer-Projects/tools/bash/*` | only if the tools need the new cycle (section I) |

### D – Install docs (doc-as-master)

- `09-Install/docs/00-patch-references.md` – cycle row → **"lib switched
  YYYY-MM-DD"**
- `09-Install/docs/04-oracle_pre_download.md` – conf table, manual download
  block, storage tree
- `09-Install/docs/05-oracle_patch_weblogic.md` – current set, SPB section,
  new feature gates / hardening of the PSU
- `09-Install/docs/06-oracle_patch_forms_reports.md` – current state,
  `SUPERSEDES`
- `09-Install/docs/40-forms_client_distribution.md` – client JDK / JRE
- `09-Install/download/README.md`, `09-Install/README.md`
- `60-RCU-DB-19c/docs/09-db_patch_rcu.md`, `60-RCU-DB-19c/README.md` – DB
  patch of the cycle
- `12-APEX-Ords/README.md` – APEX / ORDS versions

### E – Cycle folder

- New folder: status "lib switched", the **"Automated"** lines in **both**
  manual guides (which script does the step).
- Previous folder: unchanged apart from the frozen header (section 2).
- `70-Customer-Projects/README.md`: index entry of the new folder, previous
  one marked "frozen".

### F – Customer folders and cookbooks

**Rule:** every customer folder in `70-Customer-Projects/` and
`14-ReportsBuilder/` is lifted to the **current** patch level – patch
numbers, JDK build, download checklists, examples. **Exception:** folders and
files that document **one patch run** themselves
(`FormsReports1*_patch_<cycle>/`, `Patch_Kochbuch_<cycle>_de.txt`) – they stay
frozen; the new cycle gets its own folder / file.

| Place | What |
|---|---|
| `Reports14_linux_manual_install/` | `FMW_Kochbuch_de.txt` step 3 (patches), `Reports_kochbuch_de.txt` step 2, `OS_Kochbuch_de.txt` JDK example + Java note, `Reports_security.txt` step 12, `README.md` download checklist + "Patchstand" |
| `14-ReportsBuilder/` – **fully, incl. patches** | `ReportBuilder_Windows_Kochbuch_de.txt` / `_en.txt` (download checklist: patch numbers, file names, platform, size; patch step 4) and `ReportsBuilder_install_windows.md`: the **Windows variant** of every platform patch (233P / `MSWIN-x86-64`: SPB with `windows64_patchlist.txt`, OHS Windows ZIP if OHS is in the Builder home, JDK 21 Windows ZIP), the Generic bundles as in the Linux home, Windows Forms / Reports QPR if KA1182 lists one. Check every platform patch for its Windows ZIP |
| `FormsReports_change_java/` | JDK build and patch number |
| `cookbook-Skill.md` | examples only |
| other folders | `git grep` (section 6) shows the rest |

Cookbooks stay German, pure ASCII, 80 columns, blank line after every
command ([`70-Customer-Projects/cookbook-Skill.md`](../70-Customer-Projects/cookbook-Skill.md)).

### G – Architecture pages `80-FMW-Architecture/`

Change only statements of the **current state** ("the library installs
21.0.13.0.2", "current SPB …"). Dated history ("on 2026-10-24 we
applied …") stays. Typical pages: `java_jlink_forms_env.md`,
`certificates_trust_stores.md`, `oracle_patch_basics.md`,
`ords_architecture.md`, `apex_architecture.md`.

### H – Overview pages

- root `README.md` – Project Status, Security & Patch Status
- `docs/project_status.md`, [`80-FMW-Architecture/security_overview.md`](../80-FMW-Architecture/security_overview.md#2-current-patch-cycle)
  §2 "Current patch cycle" (cycle box + what matters),
  `docs/forms_reports_sizing.md` (if versions appear)
- `10-Monitoring/README.md`, `TODO.md` (cycle items done, new follow-ups)
- `CHANGELOG.md` – release section **`## v1.0.<yyyymm> – <cycle>`** with the
  areas of this list

### I – Customer tools

When a tool under `70-Customer-Projects/tools/` or a CSV it reads changed:
bump its `VERSION`, then

```bash
70-Customer-Projects/tools/make_customer_zip.sh --apply
```

(the pre-commit hook rejects stale ZIPs).

### J – Monitoring and the skill

- `10-Monitoring/cve_inventory.sh` follows the conf – its output must show
  the new cycle.
- **11-wlsmon** on every host where it runs: raise the expected cycle
  `WLSMON_PATCH_BASELINE` (`11-wlsmon/00-setup-interview.sh --apply` or
  `etc/wlsmon.conf`), and after an APEX patch run
  `11-wlsmon/01-install-wlsmon_fmw.sh --apply` (new `/i/` library paths in
  `ui.json`) – [04-wlsmon_operations.md §1a](../11-wlsmon/docs/04-wlsmon_operations.md#1a-update).
- New lessons of the cycle → `10-Monitoring/patch_cycle_analysis_skill.md`
  §4 (rules learned), new alert types / product names in the phase-1
  filter.
- Keep the skill, `00-patch-references.md` ("Rule for every new cycle") and
  this page consistent: two manual guides per cycle, archive name
  `00-patch-references_<month>_<yyyy>.md`, release tag `v1.0.<yyyymm>`.
  Pointers to this page: skill §5 (switch prompt) and §6 (registry), rule
  list of `00-patch-references.md`, `docs/project_status.md`.

### K – Patch storage of the test host (not in Git)

The analysis downloads into a staging area
(`$PATCH_STORAGE/staging_<cycle>/`, `download_<cycle>.csv` in the
Patch-Doku), the live storage stays on the previous cycle until the switch.
With the new `patches_fmw.csv` / `patches_db.csv`:

```bash
09-Install/04-oracle_pre_download.sh --apply --fresh-patches --mos   # archives patches/ to patches_<ts>/, loads the new set
```

(host without MOS access: `04-oracle_pre_download.sh --offline-list` → CSV
for `mos_patch_download.ps1` on a PC, tree copied back), or move the staged
ZIPs into place (`patches/<nr>/`, `client/jdk/<nr>/`,
`apex/patch/<nr>/`, `database/patches/<nr>/`, `ords/<ver>/`) and archive
the replaced ones; then `04-` without `--apply` must report every row
"present". Newer OTN releases (ORDS / APEX / SQLcl "latest") are not
detected by `04-` while an older ZIP is stored (TODO) – check the version by
hand. Remove the staging area after the release.

---

## 6. Sweep for stale values

The change list never catches everything – a grep over the old values does.

1. Collect the **old values** from `update_plan.md`: SPB number, marker,
   SPB version, every replaced bundle number, JDK build, client JRE, cycle
   name ("CPU Oct 2026", "CPU October 2026"), ORDS / APEX / DB versions.
2. Search:

   ```bash
   git grep -n -E '<old1>|<old2>|<old3>' -- . \
       ':!09-Install/docs/00-patch-references_*.md' \
       ':!70-Customer-Projects/FormsReports1*_patch_*/' \
       ':!70-Customer-Projects/Reports14_linux_manual_install/Patch_Kochbuch_*' \
       ':!70-Customer-Projects/Reports14_linux_manual_install/patches_*_reports_14c_*.csv' \
       ':!CHANGELOG.md' ':!diagrams/'
   ```

   Re-include the **new** cycle folder / files in a second run (they may
   name old values on purpose: "replaces 40125898").
3. Every hit is either changed or consciously kept as dated history.
   Target: **0 unexplained hits**.
4. Diagrams (`diagrams/`): only re-render when the content of the picture
   changed (version in a box), with the render tool – never edit the SVG.

---

## 7. Checks – all before the commit

| Check | Command / expectation |
|---|---|
| Syntax + ShellCheck | `tools/ci_lint.sh` → rc 0 |
| Changed scripts | `bash -n <script>` |
| Patch list | `70-Customer-Projects/tools/bash/mos_patch_download.sh -c 09-Install/download/patches_fmw.csv -d <scratch dir> --all` (plan only) → all rows resolve |
| Download / patch scripts | `09-Install/04-oracle_pre_download.sh` without `--apply`; `05-` / `06-` resp. `07-Maintenance/81-` / `82-` with `--check-only` → new numbers, "already applied" on the test host |
| Acceptance | `09-Install/90-oracle_validate.sh` → no FAIL |
| CVE view | `10-Monitoring/cve_inventory.sh` → shows the new cycle |
| Links | `python3 tools/check_pages_links.py` → 0 findings |
| Cookbooks | `grep -P '[^\x00-\x7F]' <files>` → nothing; `70-Customer-Projects/tools/cookbook_blank_lines.py` on a **scratch copy** → 0 lines added (or only known false positives) |
| New pages | front matter: title ≤ 60 characters, description 150–160 |
| Customer data / secrets | pre-commit hook `tools/hooks/pre-commit` (customer patterns, secrets, private IPs, stale customer ZIPs) |
| Stale values | section 6 → 0 unexplained hits |
| Test host after the switch | `07-Maintenance/81-` / `82-` `--check-only` → every patch "already applied", marker found, `WLS_SPB_CHECK_BUGS` found; `80-patch_java_os.sh` (check) → JDK ≥ `JDK_VERSION_MIN`; `cve_inventory.sh` → **0 FAIL "MISSING"** (before the switch the superseded patches of the old cycle show up as MISSING) |

---

## 8. One commit, tag, release

1. `git add` everything, review with `git diff --cached --stat` and a skim of
   the diff.
2. **Ask Gunther** – then exactly **one** commit:

   ```
   Lib switched to <cycle> (release v1.0.<yyyymm>)

   A patch lists: ...
   B conf: ...
   ...
   J monitoring / skill: ...

   Co-Authored-By: ...
   ```

3. After the next approval: `git push`, then the annotated tag and the
   release:

   ```bash
   git tag -a v1.0.<yyyymm> -m "IHateWeblogic v1.0.<yyyymm> – <cycle>"
   git push origin v1.0.<yyyymm>
   gh release create v1.0.<yyyymm> --title "v1.0.<yyyymm> – <cycle>" \
       --notes-file <CHANGELOG section as file> \
       <tools ZIP 1> <tools ZIP 1>.sha256 <tools ZIP 2> <tools ZIP 2>.sha256
   ```

   Same assets as for `v1.0.0` (the two customer tools ZIPs + `.sha256` of
   that commit); check the release page with `gh release view`.
4. Follow-ups on the test host (no commit): Forms client bundle
   `09-Install/40-oracle_forms_client_bundle.sh --apply` (new client
   runtime), remove the staging area / old archives, session memory (cycle
   switched, commit, tag).

Why one commit: conf, CSV, scripts and docs of a cycle only work together.
A half-switched `main` (new CSV, old conf comment, old cookbook) is exactly
the state this page prevents – and one commit can be reverted as a whole.

---

## 9. Way back

- `git revert <switch commit>` brings the library back to the previous cycle
  completely; the previous release tag stays the reference.
- A host goes back by snapshot / backup, or by hand with the manual guide of
  the previous cycle folder and the archived `00-patch-references_<month>_<yyyy>.md`.

---

## 10. Worked example – CSPU November 2026

State 2026-11-18 (KA1182 of 2026-11-17, CPU450, CPU435, CPU431; portal
READMEs; all values confirmed from the ZIPs and the live run of
2026-11-18).

| Item | CPU October 2026 | CSPU November 2026 |
|---|---|---|
| Cycle / advisory | `CPU Oct 2026` / `cpuoct2026` | `CSPU Nov 2026` / `cspunov2026` (2026-11-17) |
| WLS SPB | 40125898 (14.1.2.0.261007) | **40289362** (14.1.2.0.261112) |
| SPB marker (`WLS_SPB_MARKER_PATCH`) | 40126042 | **40289390** |
| WLS PSU / Third-Party BP (in the SPB) | 40058371 / 40035655 | 40205408 / 40288205 |
| ADF BP | 40050062 | **40155248** |
| OPSS BP | 39979746 | **40154045** |
| UMS BP | 39940047 | **40145610** (CVE-2026-114826, 9.8) |
| OHS BP (Linux) | 39987730 | **40181911** |
| OPatch | 13.9.4.2.25 | unchanged |
| `WLS_SPB_CHECK_BUGS` | 39924025 | unchanged (PSU cumulative, live: 39924025 → 40205408) |
| WebCenter Core, OWSM, FMW Control, OAMCLIENT, LibOVD, PERL, WebGate, Forms / Reports QPR | | unchanged |
| `JDK_VERSION_MIN` (35702194 latest) | 21.0.13.0.2 | **21.0.13.1** (ZIP checked) |
| Client JRE 8 | 8u511 | 8u513 (40239650) |
| APEX (`APEX_PATCH_NR`) | none (26.2.0) | **40040466** → 26.2.1 |
| ORDS | 26.3.0 | **26.3.1** |
| Repository DB 19c | RU 19.33 + OJVM + DPBP + DB-JDK 39902051 | + **MRP 40196156** (19.33.0.0.261117), DB home JDK **40245331** (8u513) |
| New PSU behaviour | – | feature gate `JAXWSRejectUnknownSEIOperationsEnabled`, **default true** (KB694158) → `05-` doc + "known problems" of both guides |
| Cycle folder | `FormsReports14_patch_cpu_2026-10/` (frozen) | `FormsReports14_patch_cspu_2026-11/` with `…_manual_full.md` + `…_manual_cumulativ_from_cpu102026.md` |
| Patch references archive | | `00-patch-references_october_2026.md` |
| Release | `v1.0.0` | **`v1.0.202611`** |
