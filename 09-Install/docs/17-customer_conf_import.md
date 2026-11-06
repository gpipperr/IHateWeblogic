# Step 17 – Import the customer configuration (overlay)

> The whole process – collect, analyse, build (Way 1 / Way 2), check again –
> is described in
> [00-transfer_customer_settings.md](00-transfer_customer_settings.md). This
> document is the reference of the importer and the overlay.

**Status 2026-11-06: built, Way 1 and Way 2 live at a customer.**
- **Importer:** `00-Setup/customer_conf_import.sh`.
- **Way 2:** `07-Maintenance/apply_customer_conf.sh`.
- **Overlay readers:** `13-`, `14-`, `14b-`, `04-ReportsFonts`.
- **Tested with the first real customer export (12c):**
  - dry run and `--apply` in an isolated copy of the repository, Way 1 (new
    conf) and Way 2 (existing conf);
  - `14-` and the Way 2 sequence as a dry run against the overlay: 0 FAIL.
- **Live in a customer 14c environment (Way 2):**
  - `apply_customer_conf.sh --apply` created two customer Reports servers,
    each with its own `<environment>` from the overlay;
  - 14 customer jars were signed;
  - `13- --remove-server` removed the old default server.

  The fixes found on the way are listed in the pitfalls table of the
  process document.
- **Way 1** has run at a customer as well (reported 2026-11-06).

---

## Purpose

This step brings the configuration of an existing customer environment
(12c or 14c) into a 14c environment built with the IHateWeblogic library.
The source is an export of `70-Customer-Projects/tools/bash/export_forms_reports_conf.sh`,
analysed first with `analyse_forms_reports_export.sh` (report for the
customer).

There are two ways in, and both use **one** code path:

| | Way 1 – new system | Way 2 – existing library environment |
|---|---|---|
| 1 | `customer_conf_import.sh --apply` | `07-Maintenance/backup_config.sh --apply` |
| 2 | `01-setup-interview.sh` – the imported values are shown as `[kept]`; it asks for the host values, the decisions and the passwords | `customer_conf_import.sh --apply` |
| 3 | install chain `04-` … `15-`; `13-`, `14-` and `14b-` read the overlay | `07-Maintenance/apply_customer_conf.sh --apply`: `14-` → `14b-` → `13-` → restart → `15-` smoke test → `90-` validate |

Foreign 14c environments, i.e. ones not built with the library, are not
covered.

---

## The overlay

The overlay lives next to the environment conf. It is customer data and is
git-ignored (`00-Setup/environments/*.customer/`). `environment.conf` points
to it:

```bash
CUSTOMER_CONF_DIR="/development/IHateWeblogic/00-Setup/environments/<env>.customer"
```

If it is empty or unset, there is no overlay and the scripts behave as before.

```
00-Setup/environments/<env>.customer/
  README.txt                      written by the importer: what is where
  IMPORT_DECISIONS.md             every correction: rule, file / key, customer value, 14c value, reason, how to take it back
  forms/formsweb.default.cfg      [default] keys (key=value)                     -> 14- Step 4
  forms/formsweb.sections.cfg     whole customer sections (ini, no [default])    -> 14- Step 4
  forms/env/default.env           key overlay on default.env.template            -> 14- Step 3
  forms/env/<name>.env            one more env file (envFile=<name>.env)         -> 14- Step 3
  forms/webutil.cfg.overrides     key overlay on webutil.cfg.template            -> 14- Step 2
  forms/jars/*.jar                customer jars (deduplicated), signed by 14-    -> 14- Step 4b
  reports/<server>.env            <environment> values per Reports server        -> 13- Step 5
  reports/cgicmd.dat.customer     customer keys, own block after the library one -> 14b- step 5
  fonts/uifont.ali.customer       customer lines with their [section]            -> 14b- step 3
  fonts/*.ttf|ttc|otf             customer fonts                                 -> 14b- step 1
```

- **Values:** an overlay value `__REMOVE__` comments a key of the base out
  (`frm_kv_overlay`, `06-FormsDiag/forms_lib.sh`).
- **Passwords never go into the overlay.** Stored logins of the customer
  configuration (`userid=` in `formsweb.cfg`, logins in `cgicmd.dat`) are
  removed and listed in `IMPORT_DECISIONS.md`. In 14c, logins come from the
  encrypted stores (`cmdkey` with `RepRunner`, boot.properties, wallet).

---

## The importer – `00-Setup/customer_conf_import.sh`

```bash
./00-Setup/customer_conf_import.sh -i <export.zip|.zip.enc|dir> [--env <name>] [--keep-customer RULE ...] [--apply]
./00-Setup/customer_conf_import.sh --rules        # the correction rules
```

- **`--env`:** default = the conf the `environment.conf` link points to.
- **A missing `environments/<name>.conf`** is created with the import block
  only (Way 1, then `01-setup-interview.sh`).
  - Without an `environment.conf`, the importer links it to this file, so
    the interview reads the import block and writes into the same file.
  - The interview takes `REPORTS_SERVER_INSTANCES` of the import as its
    server list (`REPORTS_SERVER_NAMES` / `_NAME`).
- **Already set keys** are kept. When the value differs, the run says so.
  For `REPORTS_SERVER_INSTANCES`, `INSTALL_COMPONENTS` and
  `FORMS_WEBUTIL_JACOB` this is a WARN, because the overlay needs the
  customer value.
- **Values in the overlay** use `##PLACEHOLDER##` for the new paths and the
  host name. `14-` resolves them from `environment.conf`; see doc 14
  "Placeholders".
  - The old `ORACLE_HOME` / `DOMAIN_HOME` become `##ORACLE_HOME##` /
    `##DOMAIN_HOME##`.
  - The main module directory (the one with the most `.fmx`) becomes
    `##FORMS_CUSTOMER_DIR##`.
  - The old host name becomes `##WLS_SERVER_FQDN##`. If the proposal holds
    an IP, the DNS name of the HTTPS listener is used.
  - Other directories are kept and get a `PATH_KEPT` row.
  - Reports `<environment>` values with a path of the old host are not
    taken over; `13-` sets them from `environment.conf`.
- **Decisions without a correction** are documented too:
  - `SECTION_UNUSED`: no application start in the load period;
  - `ENV_UNUSED`: no section uses the env file;
  - `JAR_DUPLICATE`: same content, or the same name in another case;
  - `HOST_MAPPED`, `PATH_MAPPED`;
  - `RCU_NEW`: 14c needs a new RCU;
  - `REPORTS_SECURITY`: the secured server of the library.
- **Rules:** the correction rules (`--rules`, `--keep-customer`) are in the
  importer. The analysis uses its own weighting file,
  `customer-analyse/rules/security_weights.txt`, for the traffic light.

1. **Unpack** with the same function as the analysis (`ihwt_unpack` in
   `ihw_tools_lib.sh`).
2. **Map the export to the overlay** with the parsers `ihwt_sections`,
   `ihwt_keys` and `ihwt_cfgval`:
   - **formsweb.cfg:** `[default]` keys that differ from Oracle's file, plus
     the customer sections (not Oracle's standard sections);
   - **env files:** one per `envFile=` (keys that differ from Oracle's
     `default.env`; old paths rewritten to `FORMS_CUSTOMER_DIR` /
     `REPORTS_CUSTOMER_DIR` with a decision line);
   - **WebUtil:** overrides;
   - **jars:** deduplicated by case and content;
   - **Reports servers:** `REPORTS_SERVER_INSTANCES`, plus `reports/<server>.env`
     from `<environment>` of their `rwserver.conf`;
   - **cgicmd.dat:** customer keys, without logins;
   - **uifont.ali:** the customer lines;
   - **fonts:** only the class `customer`; `ms` only with `--keep-customer FONT_MS`.
3. **environment.conf:** the "from export" values of the analysis report
   (section 13.1) as a `# === CUSTOMER IMPORT` block in
   `environments/<env>.conf` – only keys that are not set yet.
4. **Safe corrections:** the WARN rules of the analysis (one rule list in
   `ihw_tools_lib.sh` for both scripts) set the 14c value:
   - `allow_debug=false`;
   - `userid` removed;
   - 14c `restrictedURLparams`;
   - `FORMS_RESTRICT_ENTER_QUERY=TRUE`;
   - WebUtil `accessControl=TRUE` with directories below `FORMS_TMP`;
   - engine values from `environment.conf`, `-Xoss` dropped;
   - `webcommandaccess` L1;
   - the in-process leftover server is not taken over.

   Each correction is one row in `IMPORT_DECISIONS.md`.
   `--keep-customer RULE` takes the customer value on purpose (also noted).
5. **Modes:** without `--apply` it is a dry run: it shows the tree, the
   decisions and the conf block. `--apply` writes the overlay and the conf
   block, with `backup_file` first. Before it finishes, it runs the same
   clear-text check on the overlay as the analysis.

---

## Way 2 – `07-Maintenance/apply_customer_conf.sh`

```bash
./07-Maintenance/backup_config.sh --apply
./07-Maintenance/apply_customer_conf.sh            # dry run of 14b- / 14- / 13-
./07-Maintenance/apply_customer_conf.sh --apply    # + stop-all / start-all, 15- smoke test, 90- validate
./07-Maintenance/apply_customer_conf.sh --apply --no-restart
```

- **Only a sequence:** `14b-` → `14-` → `13-`, each with the same flag.
  - The section "Reports server names" comes first. It compares the
    overlay, `REPORTS_SERVER_INSTANCES`, `REPORTS_SERVER_NAMES`,
    `REPORTS_SERVER_NAME` and the servers of the domain.
  - After `13-` it runs `30-configure_autostart.sh --apply`, if the
    autostart scripts miss a Reports server (lib `autostart_drift`).
  - After `start-all` it waits for every Reports server to answer
    `getserverinfo` (`IHW_REPORTS_READY_WAIT`, default 240 s), then runs
    `15-`.
- **With `--apply`:**
  - It warns (and asks on a terminal) when there is no configuration backup
    of the last 4 hours.
  - No restart after a failed step.

## What the install scripts do with it (built)

| Script | Overlay part | Behaviour |
|---|---|---|
| `14-oracle_setup_forms.sh` | `forms/*` | [14-forms-detail-settings.md – Customer overlay](14-forms-detail-settings.md#customer-overlay-customer_conf_dir-import-of-an-existing-environment): sections are created or replaced completely, env files are written, WebUtil keys are added, jars are copied and signed |
| `14b-oracle_reports_fonts.sh` (+ `04-ReportsFonts`) | `fonts/*`, `reports/cgicmd.dat.customer` | [14b-oracle_reports_fonts.md – Notes](14b-oracle_reports_fonts.md#what-the-script-does) |
| `13-oracle_setup_reports.sh` | `reports/<server>.env` | [13-reports-detail-settings.md – Server list and customer overlay](13-reports-detail-settings.md#server-list-and-customer-overlay) |

Every part is idempotent: a second run reports `up to date` and writes
nothing (tested 2026-11-04 for `14-` in an isolated copy, and for the
`cgicmd.dat` / `uifont.ali` merges).
