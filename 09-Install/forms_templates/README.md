# Forms Configuration Templates

These templates must be **edited by the customer** before running `14-oracle_setup_forms.sh`.

## Workflow

1. Edit each `*.template` file to match your environment
2. Run `14-oracle_setup_forms.sh --apply` to copy the configured templates
   to the correct domain locations

The script copies each template to its target path(s) and creates a
`.bak_YYYYMMDD_HHMMSS` backup of any existing file.

## Files in this folder

| Template | Target(s) in domain | Notes |
|---|---|---|
| `default.env.template` | `$DOMAIN_HOME/config/fmwconfig/servers/$WLS_FORMS_SERVER/applications/formsapp_*/config/` | Main Forms environment file |
| `formsweb.cfg.template` | Same config dir as `default.env` | `[default]` overrides merged into Oracle's formsweb.cfg (keeps `[webstart]`, `[standaloneapp]` …) |
| `webutil.cfg.template` | `$FR_INST/server/` **and** `$FR_INST_ALT/server/` | File transfer settings; merged into Oracle's webutil.cfg, written to both locations |
| `Registry.dat.template` | `.../formsapp_*/config/oracle/forms/registry/` | Font mapping + UI settings |
| `fmrweb_utf8.res.template` | `$FR_INST/admin/resource/D/` | Keyboard bindings (UTF-8 NLS) |
| `fmrwebd.res.template` | `$FR_INST/admin/resource/D/` | Keyboard bindings (non-UTF-8 fallback) |
| `IHateWeblogic.ico` | `$PATCH_STORAGE/icon/IHateWeblogic.ico` (copied by `04-oracle_pre_download.sh --apply`) | Default shortcut icon of the Forms client distribution (`FORMS_CLIENT_ICON`, concept 40) – project logo, 16/32/48/256 px; not used by 14- |

`$FR_INST`     = `$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/$FORMS_INSTANCE_NAME`
`$FR_INST_ALT` = `$DOMAIN_HOME/config/fmwconfig/components/FORMS/$FORMS_INSTANCE_NAME`

## What to adapt in each template

### default.env.template
Paths are `##...##` placeholders filled from `environment.conf` by the script
(`ORACLE_HOME`, `DOMAIN_HOME`, `JDK_HOME`, `FORMS_INSTANCE_NAME`,
`REPORTS_TOOLS_INSTANCE`, `FORMS_CUSTOMER_DIR`, `FORMS_TMP`, `TNS_ADMIN` – from
`environment.conf`, unset = `$DOMAIN_HOME/config/fmwconfig`) – do not replace them by hand. Adapt only:
- `FORMS_PATH` – add further `.fmb` / `.fmx` directories if needed
- `NLS_LANG`, `NLS_DATE_FORMAT` – language/character set

### formsweb.cfg.template
- Overrides for `[default]` only – merged into Oracle's
  `$ORACLE_HOME/forms/templates/config/formsweb.cfg` (keeps `serverArgs`,
  `[webstart]`, `[standaloneapp]`, `[webutil_*]`); see
  `docs/14-forms-detail-settings.md` Step 4
- optional: `form=` (default start form), `pageTitle=`, `background=`,
  `logo=`, `customColorScheme=`
- Application-specific `[section]` blocks: add in the deployed file / EM

### webutil.cfg.template
- Overrides only – merged into Oracle's
  `$ORACLE_HOME/forms/templates/config/webutil.cfg` (keeps the
  `install.syslib.*` list); see `docs/14-forms-detail-settings.md` Step 2
- `transfer.appsrv.read.N=` – directories the server may read from
- `transfer.appsrv.write.N=` – directories the server may write to

### Registry.dat.template
- `colorScheme.<name>.*` – hex colours for a custom colour scheme
- Reference the scheme name from `formsweb.cfg`: `customColorScheme=<name>`

### fmrweb_utf8.res.template / fmrwebd.res.template
- Keyboard mapping is pre-filled with a standard German Forms layout
- Adjust key codes if your application uses different function key assignments
