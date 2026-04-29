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
| `formsweb.cfg.template` | Same config dir as `default.env` | URL-to-form mapping; add custom sections manually |
| `webutil.cfg.template` | `$FR_INST/server/` **and** `$FR_INST_ALT/server/` | File transfer settings; copied to both locations |
| `Registry.dat.template` | `.../formsapp_*/config/oracle/forms/registry/` | Font mapping + UI settings |
| `fmrweb_utf8.res.template` | `$FR_INST/admin/resource/D/` | Keyboard bindings (UTF-8 NLS) |
| `fmrwebd.res.template` | `$FR_INST/admin/resource/D/` | Keyboard bindings (non-UTF-8 fallback) |

`$FR_INST`     = `$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/$FORMS_INSTANCE_NAME`
`$FR_INST_ALT` = `$DOMAIN_HOME/config/fmwconfig/components/FORMS/$FORMS_INSTANCE_NAME`

## What to adapt in each template

### default.env.template
- `ORACLE_HOME` – your FMW installation path
- `FORMS_INSTANCE` – full path to Forms instance
- `TNS_ADMIN` – path to Oracle Net `tnsnames.ora`
- `FORMS_PATH` – application source directory (`.fmb` / `.fmx`)
- `NLS_LANG`, `NLS_DATE_FORMAT` – language/character set
- `COMPONENT_CONFIG_PATH` – path to ReportsTools instance
- `PATH`, `LD_LIBRARY_PATH`, `LD_PRELOAD` – adjust JDK version path

### formsweb.cfg.template
- `form=` in `[default]` – your default start form (`.fmx`)
- `pageTitle=` – application name shown in browser tab
- `ssoSuccessLogonURL=` – host and port for SSO logout redirect
- `background=`, `logo=` – customer branding GIFs (optional)
- Add application-specific `[section]` blocks after the `[default]` section

### webutil.cfg.template
- `transfer.appsrv.read.N=` – directories the server may read from
- `transfer.appsrv.write.N=` – directories the server may write to

### Registry.dat.template
- `colorScheme.<name>.*` – hex colours for a custom colour scheme
- Reference the scheme name from `formsweb.cfg`: `customColorScheme=<name>`

### fmrweb_utf8.res.template / fmrwebd.res.template
- Keyboard mapping is pre-filled with a standard German Forms layout
- Adjust key codes if your application uses different function key assignments
