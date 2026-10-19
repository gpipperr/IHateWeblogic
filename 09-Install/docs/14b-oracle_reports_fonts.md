# Step 6b – 14b-oracle_reports_fonts.sh

**Script:** `09-Install/14b-oracle_reports_fonts.sh`
**Runs as:** `oracle`
**Phase:** 6 – Runtime Configuration (after `13-`/`14-` and the first domain start)

---

## Purpose

Configure the Reports fonts and the `cgicmd.dat` default key once the Reports
components exist. Split off `09-oracle_configure.sh` on 2026-10-15:

- `uifont.ali` lives in the **ReportsTools component**
  (`$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/<instance>/guicommon/tk/admin/`),
  created by `13-oracle_setup_reports.sh`.
- `cgicmd.dat` lives in the **WLS_REPORTS application directory**
  (`$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/`),
  which only exists after WLS_REPORTS has been **started once**.

Right after `08-oracle_setup_domain.sh` neither exists, so these steps cannot
run in `09-`.

This script does **not implement new functionality** — it orchestrates the
existing font scripts from `04-ReportsFonts/`.

---

## Prerequisites

| Prerequisite | Check | If missing |
|---|---|---|
| Domain exists | `$DOMAIN_HOME/config/config.xml` | FAIL – run `08-` |
| Reports installed | `$ORACLE_HOME/reports` | exit OK – nothing to do |
| ReportsTools instance | `ReportsToolsComponent/*/` | FAIL – run `13-oracle_setup_reports.sh --apply` (not checked with `--skip-fonts`) |
| WLS_REPORTS started once | `cgicmd.dat` directory | WARN, step 5 skipped – start WLS_REPORTS, re-run |

---

## Without the Script (manual)

```bash
# 1. Copy fonts into $DOMAIN_HOME/reports/fonts (REPORTS_FONT_DIR)
./04-ReportsFonts/deploy_fonts.sh --apply
# 2. Rebuild the font cache
./04-ReportsFonts/font_cache_reset.sh --apply
# 3. uifont.ali [PDF:Subset] mappings
./04-ReportsFonts/uifont_ali_update.sh --apply
# 4. REPORTS_FONT_DIRECTORY etc. in setUserOverrides.sh
./04-ReportsFonts/fontpath_config.sh --apply
# 5. Screen-printer metrics: FontSpecific AFMs + AFMs for the TTFs + PPD entries
./04-ReportsFonts/paramform_afm_setup.sh --apply
```

**Step 5 – HTML form, and PDF with substitute fonts** (confirmed live
2026-10-19, rwrun and Reports server): a report font whose own TTF is in
`REPORTS_FONT_DIRECTORY` (e.g. a real `arial.ttf`, no `[Global]` alias)
renders in the PDF without it. A **substitute** font (Arial / Helvetica /
Times New Roman / Courier New / Tahoma mapped to Liberation / DejaVu – the
normal case without Windows font licences) is resolved through the screen
printer (`screenprinter.ppd` + AFM files) first; without step 5 the test
report showed all of them as non-embedded **Type 1 "Symbol"** (Greek
glyphs), with step 5 + `uifont_ali_update.sh` as embedded TrueType.
`NLS_LANG` (`AL32UTF8` / `WE8MSWIN1252`) made no difference. The script
always runs step 5 – it does no harm when the original TTFs are present.
Restart the Reports server afterwards – the engines read the files at start.

`cgicmd.dat` – default key for the report calls of the applications
(server = Reports server **component**, `REPORTS_SERVER_NAME`, not the managed
server `WLS_REPORTS`; `authid` = execution user from `12-`):

```bash
CGICMD_DAT="$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/cgicmd.dat"
# default: server=repserver01 %* authid=RepRunner/<password>
chmod 640 "$CGICMD_DAT"
```

Call: `/reports/rwservlet?cmdkey=default&report=<file>.rdf&userid=<db>&destype=cache&desformat=pdf`.

- `%*` passes all URL parameters – without it `REP-50004 No report is specified`
  (tested 2026-10-16).
- `authid` after `%*`: an `authid` in the URL does not override it (the key
  wins – tested with `monUser`).
- The `authid` is checked only by a secured Reports server (`13-`,
  `REPORTS_SECURITY=ldap`); then a call without key and login gets HTTP 499.
- Anyone who can call the key runs reports as this user – restrict
  `/reports/` (Nginx, firewall) to the calling application servers.
- rwservlet reads `cgicmd.dat` at start – restart `WLS_REPORTS`.

Then back up and restart:

```bash
./07-Maintenance/backup_config.sh --apply
./01-Run/startStop.sh stop-all --apply && ./01-Run/startStop.sh start-all --apply
```

---

## What the Script Does

| Order | Action | Script called |
|---|---|---|
| 1 | Deploy fonts | `04-ReportsFonts/deploy_fonts.sh --apply` |
| 2 | Font cache | `04-ReportsFonts/font_cache_reset.sh --apply` |
| 3 | uifont.ali | `04-ReportsFonts/uifont_ali_update.sh --apply` |
| 4 | Font path | `04-ReportsFonts/fontpath_config.sh --apply` |
| 4b | Screen-printer AFM/PPD | `04-ReportsFonts/paramform_afm_setup.sh --apply` – HTML form; PDF with substitute fonts (see above) |
| 5 | cgicmd.dat | `response_files/cgicmd.dat.template` with the `authid` from `reports_users.conf.des3` (`REPORTS_EXEC_USER/PWD`): append, or **replace** an existing IHateWeblogic block; `chmod 640`; password never logged |
| 6 | Config backup | `07-Maintenance/backup_config.sh --apply` (now incl. Reports/Forms/font config) |

- `CGICMD_DAT` comes from `environment.conf` or defaults to the path above.
- `server=` in `cgicmd.dat` = `REPORTS_SERVER_NAME` (default `repserver01`).
  Before 2026-10-15 `09-` wrongly used `WLS_MANAGED_SERVER` for it.
- Steps 1–4b are skipped with `--skip-fonts`.

---

## Flags

| Flag | Description |
|---|---|
| (none) | Dry-run: prerequisites + planned steps |
| `--apply` | Execute all steps |
| `--skip-fonts` | Only cgicmd.dat + backup (skips steps 1–4b) |
| `--help` | Show usage |

---

## Notes

- Safe to re-run: the font scripts are idempotent, the `cgicmd.dat` block
  between the markers `# --- IHateWeblogic BEGIN/END ---` is rewritten (own
  keys belong after the END marker). Backups `cgicmd.dat.bak_*` contain the
  password in clear text – delete them when no longer needed.
- Restart WLS_REPORTS and the Reports components afterwards — fonts and
  `cgicmd.dat` are read at startup.
