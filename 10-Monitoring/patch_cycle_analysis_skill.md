# Skill: Oracle patch-cycle analysis (Forms & Reports 14.1.2 / customer homes)

How a patch cycle (CPU quarterly, CSPU in the months between, Security Alerts)
is analysed and documented with Claude. Written from the CPU October 2026 run
(2026-10-22 … 26). Started by
[`patch_cycle_analysis.sh`](patch_cycle_analysis.sh) or directly with the
Claude Code skill `/patch-cycle-analysis` (`.claude/skills/patch-cycle-analysis/`,
local – `.claude/` is not in Git; template
[`claude/skills/patch-cycle-analysis/SKILL.md`](claude/skills/patch-cycle-analysis/SKILL.md),
install: `mkdir -p .claude/skills && cp -r 10-Monitoring/claude/skills/patch-cycle-analysis .claude/skills/`).

Precondition: Claude Code set up as in [setup_claude.md](setup_claude.md)
(`claude_setup_check.sh` OK, never on a host with `IHW_ENV_TYPE=prod`).

## 1. One cycle = three stages, two use cases

```
1 ANALYSE   prepare: public sources            -> readme_list.md (what to download)
            analyse: READMEs + environment     -> analysis README + manual guide
2 MANUAL    patches applied by hand (manual guide) or with the released lib
            (07-Maintenance/80-82); live results turn [Doku] into [live]
3 UPDATE    maintainer only: update_plan.md = the prompt that switches the lib
```

| | **customer** (uses the lib, default) | **maintainer** (develops the lib) |
|---|---|---|
| analysis output | `Patch-Doku/<cycle>/result/` – nothing in the repo is touched | freeze + new `09-Install/docs/00-patch-references.md`, new `70-Customer-Projects/Forms14_reports14_patch_analyse_<mm>_<yyyy>/` |
| `update_plan.md` | not created | created in the 70 folder |
| end of the cycle | patches by hand; for automation pull the current release of the lib | session with `update_plan.md` as prompt → lib switched, commit, `git tag <cycle>` → the customer's next pull closes the loop |

`Patch-Doku/` lives in `10-Monitoring/Patch-Doku/<yyyy-mm>_<cycle>/` and is
**not** in Git (`.gitignore`): it holds Oracle documents (READMEs, KA1182 PDF)
and customer data. Layout:

```
10-Monitoring/Patch-Doku/2026-11_cspunov2026/
  cycle.info        cycle id, advisory URL, release date, configured cycle, mode
  readme_list.md    phase 1 result: checklist of documents to download
  readmes/          the user drops every README / KA1182 PDF / MOS note here
  env/              collector archive(s) (70-Customer-Projects/tools/collect_fmw_env.sh --full)
  result/           customer mode: analysis README + manual guide
```

## 2. Phase 1 – prepare (public sources only)

Inputs: `cycle.info` (cycle id, URL), the current
`09-Install/docs/00-patch-references.md` and
`09-Install/oracle_software_version.conf` (what is installed / configured).

1. **Fetch** with `curl -sfL -m 30 -A "Mozilla/5.0" <url>` – oracle.com
   answers WebFetch-style clients with **403**. Save to `Patch-Doku/<cycle>/src/`
   and extract text with a small Python/regex step.
   - index `https://www.oracle.com/security-alerts/`
   - the advisory of the cycle (`cpu<mon><yyyy>.html` / `cspu<mon><yyyy>.html`)
     and its **text risk matrix** / CSAF JSON (links on the advisory page)
   - every **Security Alert** released since the configured cycle
     (`alert-cve-…html`) and the Java SE matrix of the cycle
2. **Filter** the risk-matrix rows: affected versions incl. **14.1.2.0.0** (and
   the customer's release, e.g. 12.2.1.4.0) and products that are part of a
   Forms & Reports home (WebLogic, FMW Infrastructure components – OPSS, OWSM,
   ADF/JDeveloper runtime, EM/FMW Control, UMS, LibOVD, OAM client – OHS,
   WebGate, Forms, Reports, Perl, Coherence, third-party components). Java SE
   rows for the JDK at `JDK_HOME` and the client JRE. Database / Instant
   Client / SQLcl / APEX / ORDS rows separately (own release cycles).
3. **Compare** with the patch list of the current 00-patch-references: which
   areas get a new patch, which stay.
4. **Write `readme_list.md`** – a checklist for the user, one line per
   document, grouped:
   - MOS KA1182 "FMW CPU Patch Advisor" (PDF of the cycle) – always first;
     the patch numbers come from there (tabs WebLogic Server 14.1.2.0, FMW
     Infrastructure 14.1.2.0, Forms and Reports 14.1.2.0, Proxy Plug-In)
   - Java: CPU patch-availability document of the cycle, JDK patch numbers
   - expected patches: area, product, platform (**Generic** or Linux x86-64 /
     Microsoft Windows x64), number if already known (else "from KA1182"),
     why (CVE / superseding the current one)
   - MOS notes named in READMEs of the last cycle that may have changed
     (KB694158 WLS PSU post-install, KB559857 OHS post-install, PNEWS2138 ADF)
   - for each patch: "README from the **ZIP**" when the portal text was a
     placeholder before (e.g. 39988381 in Sep 2026)
   Ask the user before writing when the cycle has no FMW rows at all
   (possible for a CSPU) – then the result is a short "nothing to do" note.

## 3. Phase 2 – analyse

Inputs: `readmes/`, `env/` (optional), `readme_list.md`, the current
00-patch-references and the previous cycle folder as template.

1. **Completeness:** compare `readmes/` with `readme_list.md`, list what is
   missing, ask whether to continue.
2. **Read every README** and record per patch (table "3a" of the October
   folder): method (`opatch apply` / `napply`), prerequisites (OPatch
   minimum, other patches, DB client), post-install (MOS note, command or
   none), rollback, notes / CVEs confirmed.
3. **Environment:** unpack the collector archive (read-only), take OS /
   glibc, OPatch version, `lspatches`, JDKs, components (Reports? Forms?
   OHS instance?), web tier. Without an archive (maintainer, 14c stack) use
   the test host directly (`opatch lspatches`, conf).
4. **Ask** the open questions interactively (one block, numbered) – e.g.
   superseded one-offs, platform variants, components present or not.
5. **Write the results:**
   - analysis README: header (cycle, sources, roles), 1 check / 1a
     inventory, 2 patch list, 3a README facts, 6 order of work, 7 open
     points, 8 runtimes (empty until stage 2)
   - manual guide `install_14c_patch_set_<month>_<year>_manual.md`: steps
     0 prerequisites … 13 known problems, each step names the script that
     automates it; markers **documented** / **confirmed (live)** /
     **assumption**
   - customer mode: both into `Patch-Doku/<cycle>/result/` (German cookbook
     style if the customer wants German – ask)
   - maintainer mode:
     1. freeze `00-patch-references.md` → `00-patch-references_<month>_<year>.md`
        (rule "Rule for every new cycle" in that file), new row in the cycle
        table, rework the file for the new cycle
     2. new folder `70-Customer-Projects/Forms14_reports14_patch_analyse_<mm>_<yyyy>/`,
        previous folder header "Frozen – do not edit"
     3. **`update_plan.md`** in the new folder (section 5)
6. **No** conf / script change and **no** commit in this phase.

## 4. Rules learned (CPU October 2026)

- Fetch oracle.com with `curl -A "Mozilla/5.0"`; `ops.java` pages can be down
  – note it, do not guess their content.
- The README **inside the ZIP** is authoritative; MOS portal texts can be
  placeholders (E-Business-Suite AutoPatch text for 39988381).
- MOS patch titles can be misleading ("MERGE REQUEST … FOR BUGS a b c" while
  the README lists 31 bugs); the **Linux README can list fewer bugs** than the
  Windows/Solaris README – compare with `opatch lsinventory -bugs_fixed`.
- `opatch napply -report` shows supersets (old SPU replaced by the new PSU) –
  record them; an overlay on an old PSU cannot stay.
- KA1182: the Forms & Reports tab points to the FMW Infrastructure tab – the
  infrastructure bundles are required whenever only the WLS SPB is applied.
- Platform: Generic vs Linux x86-64 vs Microsoft Windows x64 – check every
  platform patch for each platform in use (Windows Reports Builder).
- Java: the target is the **alert** build when an alert follows the CPU; the
  ZIP name of "JDK latest" patches never changes – check the version inside.
- Bundled JDK (`oracle_common/jdk`) and FMW DBCLIENT are only updated by
  Oracle's FMW patches – never by hand / with a regular DB client RU.
- No verbatim MOS / KA text in the repo – own words, facts, numbers.
- Customer data never in committed files – run the scan pattern of the
  project memory before every commit; `Patch-Doku/` stays local.
- Customer cookbooks are German and pure ASCII (`*.txt`); repo docs English.
- Never edit a script while the user runs it (bash reads incrementally).
- Never read secret files (`*.des3`, `boot.properties`, wallets, keys) – the
  deny rules / sandbox of setup_claude.md block them; do not work around a
  block, ask the user.

## 5. `update_plan.md` – the prompt for stage 3 (maintainer)

Written at the end of phase 2, **self-contained**, so that one Claude session
switches the whole lib in one go without re-reading the READMEs. Started
after the live run (stage 2) with

```bash
claude "$(cat 70-Customer-Projects/Forms14_reports14_patch_analyse_<mm>_<yyyy>/update_plan.md)"
```

Structure:

1. **Role + goal** – "Switch the IHateWeblogic lib from cycle A to cycle B;
   the live run on the test host is done (date)."
2. **Facts** – patch table (number, title, platform, Generic/OS, supersedes,
   OPatch minimum, SPB marker, superset findings), live results and runtimes
   of stage 2 (from section 8 of the analysis README).
3. **Change list** – one checkbox per file from the registry below, with the
   concrete old → new values and the sections / text blocks to touch.
4. **Rules** – section 4 of this skill (doc-as-master, ASCII cookbooks,
   no MOS text, customer-data scan, no edit of running scripts).
5. **Checks** – `bash -n` of changed scripts, dry-runs of 04/05/06,
   link check of changed Markdown, customer-data scan, ASCII check of the
   `*.txt` cookbooks, `cve_inventory.sh` shows the new cycle.
6. **Finish** – status "lib switched" in the 70 folder and the cycle row of
   00-patch-references; ask before commit / push / `git tag <cycle>`.

## 6. Registry – where the cycle lives in the lib

Template for every change list (built from the October 2026 switch: commits
7fbc79c, 2412d70, 1f8e0cd, 90c970c, 539b22b, f48ff46):

| Area | Places |
|---|---|
| conf | `09-Install/oracle_software_version.conf`: `PATCH_CYCLE`, `PATCH_CYCLE_DATE`, `PATCH_CYCLE_ADVISORY`, `OPATCH_VERSION_MIN/_INSTALL`, `OPATCH_PATCHES_MIN`, `WLS_SPB_PATCH_NR/_VERSION/_MARKER_PATCH`, `WLS_SPB_CHECK_BUGS`, `JDK_VERSION_MIN`, `CLIENT_JDK_*`, `INSTALL_PATCHES`, `INSTALL_PATCHES_FR_COMMON/_FORMS/_REPORTS/_FR_OPTIONAL`, the comment blocks and the "Superseded" list |
| scripts | `09-Install/06-oracle_patch_forms_reports.sh` `SUPERSEDES` map; `04-`/`05-`/`06-` and `07-Maintenance/80-82` only if the patch model changed (new mechanism, new pre-check) |
| install docs | `09-Install/docs/00-patch-references.md` (cycle row → "lib switched"), `04-oracle_pre_download.md` (conf table, manual download block, storage tree), `05-oracle_patch_weblogic.md` (current set, SPB section), `06-oracle_patch_forms_reports.md` (current state, `SUPERSEDES`) |
| cycle folder | `70-Customer-Projects/Forms14_reports14_patch_analyse_<mm>_<yyyy>/`: status, "Automated" lines of the guide; previous folder frozen |
| customer cookbooks | `70-Customer-Projects/Reports14_Only_manuall_install/`: `FMW_Kochbuch_de.txt` step 3, `Reports_kochbuch_de.txt` step 2, `OS_Kochbuch_de.txt` JDK example + Java note, `Reports_security.txt` step 12, `README.md` download checklist + "Patchstand"; `70-Customer-Projects/Reports14_ReportBuilder_MS_Windows/`: download checklist + step 4 of the cookbook (Windows variants) |
| overview | root `README.md` (Project Status, Security & Patch Status, Known Gaps, Open Items), `70-Customer-Projects/README.md` |
| monitoring | `10-Monitoring/cve_inventory.sh` follows the conf – check its output; new alert types → this skill |
| follow-ups | `04-oracle_pre_download.sh --apply --fresh-patches --mos` (archives the previous ZIPs), Java / OS alerts after the cycle, SR drafts (`SR/`, local), memory of the session |
