# Creating Forms & Reports Test Modules Without a GUI Builder

Procedure for building a minimal Oracle Forms test module (FMB/FMX) and a
minimal Oracle Reports demo report (RDF), entirely from the command line —
no Forms Builder, no Reports Builder, no X display. Both test artifacts only
need a plain database connection (`select sysdate from dual`,
`select count(*) from user_objects`) and give a fast, scriptable smoke test
that Forms and Reports are correctly installed, can compile, reach the
database and – for Reports – run through the Reports server.

> **Status: VERIFIED end-to-end on FMW 14.1.2 (2026-10-16)** with
> `15-deploy-test-report-forms_template.sh --apply`:
> Forms XML → FMB → FMX (trigger compiled against the DB),
> Reports XML → RDF → `rwservlet` → PDF. 19 OK / 0 FAIL, no X display.
> See [Live Test Log](#live-test-log).

---

## Testkit Layout

| File | Purpose |
|---|---|
| `09-Install/forms_templates/test_form.xml` | Forms XML module: control block `BL_DATA`, items `IT_SYSDATE`/`IT_OBJ_COUNT`, a `WHEN-NEW-FORM-INSTANCE` trigger populates both (`sysdate`, `user_objects`) |
| `09-Install/reports_templates/test_dual.xml` | Reports XML: `to_char(sysdate, ...) as sys_datum from dual` (**not** `current_date` as alias — reserved word!) |
| `09-Install/reports_templates/test_user_objects.xml` | Reports XML: tabular listing of `object_name, object_type, status from user_objects`, filtered by a `<userParameter>` + `<parameterForm>` (object-name pattern, default `%`) — see `REPORTS_XML_SYNTAX_REFERENCE.md` |
| `09-Install/15-deploy-test-report-forms_template.sh` | Driver script: `frmxml2f.sh` → `frmcmp_batch.sh` (Forms), `rwconverter.sh` (Reports), deploy into `FORMS_CUSTOMER_DIR` / `REPORTS_CUSTOMER_DIR`, run `test_dual.rdf` via `rwservlet` (PDF check). Only the component(s) selected in `INSTALL_COMPONENTS`. |

### Test database credentials

| Item | Source |
|---|---|
| user + password | `test_db_sec.conf.des3` (`TEST_DB_USER`, `TEST_DB_PWD`) – asked once by `15- --apply` on a terminal, stored encrypted (not in Git, not in `environment.conf`) |
| host / port / service | `TEST_DB_HOST` / `TEST_DB_PORT` / `TEST_DB_SERVICE` if set, else `DB_HOST` / `DB_PORT` / `DB_SERVICE` (repository DB) |

Any schema with `CREATE SESSION` works (only `DUAL` / `USER_OBJECTS` are read).
The former plain `TEST_DB_CONNECT` in `environment.conf` is no longer used.

---

## Part 1 — Forms Test Module

### Key Findings

- The "FMT plain-text syntax" (`Begin Form ... End`) that circulates online is
  **fabricated** — it does not exist and will not compile.
- `.fmt` is real, but only as an undocumented property dump produced by
  `frmcmp script=yes` (FMB→FMT) and consumed by `frmcmp parse=yes`.
- **The text-based path is Forms XML** with `frmf2xml` / `frmxml2f` (Java
  classes `oracle.forms.util.xmltools.Forms2XML` / `XML2Forms` in
  `$ORACLE_HOME/jlib/frmxmltools.jar`).
- Use the **wrapper scripts of the Forms instance** – they set the
  environment:
  `$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/<inst>/bin/`
  `frmxml2f.sh`, `frmf2xml.sh`, `frmxmlsg.sh` (schema), `frmxmlv.sh`
  (validator), `frmcmp_batch.sh`, `frmcmp.sh`.
- **`FORMS_API_TK_BYPASS=TRUE`** ("init the API without Motif", in Oracle's
  wrapper only set for AIX): without it JDAPI fails with
  `_jni_initialize: Failed to create new forms context` – **with it no X
  display / Xvfb is needed** (2026-10-16; the 2026-08 conclusion "needs
  Xvfb" was wrong).
- **Forms tools split `userid` at `/`:** EZConnect
  (`user/pwd@host:port/service` or `@//host:port/service`) fails –
  `XML2Forms` prints `_jni_connect failed`, `frmcmp_batch` only
  `Form not created` (rc=0!). Use a **TNS alias**. The script writes a
  temporary `tnsnames.ora` (alias `IHW_SMOKE_DB` + existing aliases) and
  points `TNS_ADMIN` to it.

### Step 1 — Forms XML module

`test_form.xml` defines one control block `BL_DATA` (`DatabaseBlock="false"`),
two text items and a `WHEN-NEW-FORM-INSTANCE` trigger. Verified syntax
(schema from `frmxmlsg.sh`, roundtrip of `$ORACLE_HOME/forms/test.fmb` with
`frmf2xml.sh`):

```xml
<Module version="141020000" xmlns="http://xmlns.oracle.com/Forms">
  <FormModule Name="TEST_FORM" ConsoleWindow="WIN_MAIN" Title="...">
    <Coordinate CoordinateSystem="Real" RealUnit="Point" CharacterCellWidth="5" CharacterCellHeight="14"/>
    <Block Name="BL_DATA" DatabaseBlock="false">
      <Item Name="IT_SYSDATE" ItemType="Text Item" CanvasName="CV_MAIN" DatabaseItem="false"
            Prompt="Server Date/Time" DataType="Char" MaximumLength="40"
            XPosition="150" YPosition="30" Width="160" Height="18"/>
      ...
    </Block>
    <Canvas Name="CV_MAIN" WindowName="WIN_MAIN" CanvasType="Content" Width="400" Height="120"/>
    <Window Name="WIN_MAIN" Title="..." PrimaryCanvas="CV_MAIN" Width="400" Height="120"/>
    <Trigger Name="WHEN-NEW-FORM-INSTANCE" TriggerText="BEGIN&amp;#10;  ...&amp;#10;END;"/>
  </FormModule>
</Module>
```

| Wrong (2026-08 guess) | Correct (schema / roundtrip) |
|---|---|
| `version="12.2.1.4.0"` | `version="141020000"` (type `long`, = 14.1.2) |
| `DatabaseBlock="No"`, `ShowScrollBar="Yes"` | booleans `true` / `false` |
| `PromptText`, `MaxLength` | `Prompt`, `MaximumLength` |
| `CoordinateSystem="Char"`, `CharUnit`, `SnapToGrid` | `CoordinateSystem="Character"\|"Real"`, `RealUnit`, `CharacterCellWidth/Height` |
| `Window` `ViewportX/Y/Width/Height` | `Window` `Width` / `Height` (viewport attributes belong to `Canvas`) |
| trigger line break `&#10;` | `&amp;#10;` (as written by `frmf2xml`) |

The `<Property Name= Value=/>` child-element structure seen in a blog post
does **not** exist – properties are plain attributes.

### Step 2 — Convert XML → FMB

```bash
FB=$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/forms1/bin
export FORMS_API_TK_BYPASS=TRUE TNS_ADMIN=<dir with alias>
$FB/frmxml2f.sh OVERWRITE=YES USERID=user/pwd@ALIAS test_form.xml
#  -> "Module saved as test_form.fmb"
```

`USERID=` is only for record group queries – without a working connection
the tool continues ("Record Group Queries will be lost").

### Step 3 — Compile FMB → FMX

```bash
$FB/frmcmp_batch.sh module=test_form.fmb userid=user/pwd@ALIAS \
    module_type=form compile_all=yes output_file=test_form.fmx
#  -> "No compilation errors." / "Created form file test_form.fmx"
```

`frmcmp_batch` returns rc=0 also on `Form not created` – check the `.fmx`
file. Without DB logon the trigger fails with
`PL/SQL ERROR 201 ... identifier 'USER_OBJECTS' must be declared`.

### Useful tools

```bash
$FB/frmxmlsg.sh                                # writes forms.xsd (schema of this version)
$FB/frmf2xml.sh OVERWRITE=YES some.fmb         # roundtrip a real FMB -> some_fmb.xml
```

### Plan B — JDAPI (no longer needed)

The JDAPI (`$ORACLE_HOME/jlib/frmjdapi.jar`) can build an FMB
programmatically (`new FormModule(...)`, `Block`, `Item`, `Trigger`,
`fmb.save()`). Not needed since the XML path works.

### References — Forms

- Forms2XML/XML2Forms documentation (options, syntax):
  https://docs.oracle.com/database/apex-18.1/AEMIG/Converting_FormModules_ObjectLibraries_MenuModules_to_XML.htm
- Real XML dump of an FMB (10.1.2, structural reference):
  https://odieweblog.wordpress.com/2011/11/23/oracle-xml-db-a-practical-example/
- `frmf2xml` practical walkthrough: https://www.sqlines.com/articles/oracle-forms/convert-to-xml
- JDAPI example: http://www.e-ammar.net/Oracle_TIPS/Forms_API.htm
- Oracle Forums (2006) — `frmxml2f` failure report / Oracle-staff advice
  against cross-version XML: https://forums.oracle.com/ords/apexds/post/convert-xml-file-to-fmb-very-urgent-1747

---

## Part 2 — Reports Demo Report

### Key Findings

- XML report definitions are **officially documented**; the Reports server
  runs them directly (`report=test_dual.xml`) or after conversion to RDF.
- Conversion via **`$DOMAIN_HOME/reports/bin/rwconverter.sh`** (wrapper of
  the ReportsTools instance, sources `reports.sh`). `$ORACLE_HOME/bin/rwconverter`
  alone aborts with `SIGABRT` – the Reports environment (`REPORTS_CLASSPATH`,
  `libjvm` path …) is missing. That – not memory pressure or a missing X
  display – was the cause of the 2026-08 crash.
- No X display needed (`REPORTS_DEFAULT_DISPLAY=YES` from `reports.sh`).
- `REP-0004: User preference file cannot be opened` is harmless noise.

### Step 1 — Reports XML definition

`test_dual.xml`: one data source `to_char(sysdate, ...) as sys_datum from dual`
and a tabular layout.

> **Alias trap:** do not use `current_date` as a column alias — it is a
> reserved Oracle function name. Use a neutral alias such as `sys_datum`.

### Step 2 — Convert XML → RDF

```bash
$DOMAIN_HOME/reports/bin/rwconverter.sh userid=user/pwd@ALIAS batch=yes overwrite=yes \
    source=test_dual.xml stype=xmlfile dest=test_dual.rdf dtype=rdffile
# -> REP (compiled runtime file): same command with dtype=repfile
```

### Step 3 — Run through the Reports server

The RDF is copied to `REPORTS_CUSTOMER_DIR` (in `<folderAccess><read>`) and
run via `rwservlet`; the engine resolves the DB itself (EZConnect works
there):

```bash
curl -s -o test_dual.pdf \
  "http://localhost:9002/reports/rwservlet?cmdkey=default&report=test_dual.rdf&destype=cache&desformat=pdf&userid=user/pwd@//host:port/service"
head -c 5 test_dual.pdf      # %PDF-
```

- With a `cgicmd.dat` key `default` (14b-, `server=… %* authid=…`) the key
  is used – required for a secured Reports server (`REPORTS_SECURITY=ldap`,
  otherwise HTTP 499 login page). Without the key `server=` is passed.
- The script passes the URL to `curl` via a config on stdin (`-K -`) so the
  password does not show up in the process list.

### XML Format Reference

- Root element: `<report name="..." DTDVersion="9.0.2.0.0">`
- Data model: `<data><dataSource name="Q_1"><select>...</select></dataSource></data>`
- Layout: `<layout><section name="main"><tabular name="M_1"><labelAttribute/><field name= source= label=/></tabular></section></layout>`
- Section types: `header`, `main`, `trailer`; simple styles `tabular`, `groupLeft`
- Column aliases in the `SELECT` are **mandatory**; `source=` in the layout
  references the alias
- DTD: `$ORACLE_HOME/reports/dtd/report.dtd`
- Parameters (`<userParameter>`, `<parameterForm>`): see
  `09-Install/reports_templates/REPORTS_XML_SYNTAX_REFERENCE.md`

### References — Reports

- XML Report Definitions overview + standalone XML reports (10g AS):
  https://docs.oracle.com/cd/B14504_01/dl/web/B12099_01/adx14rep.htm
- Creating XML Customizations, runnable standalone example (11g):
  https://docs.oracle.com/middleware/11119/classic/use-reports/pbr_xml002.htm
- Creating XML Data Models, DTD fragments (12.2.1.3):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_xml003.htm
- Customization examples (colors, format masks, exceptions):
  https://docs.oracle.com/cd/E28280_01/bi.1111/b32121/pbr_xml002.htm

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `_jni_initialize: Failed to create new forms context` | JDAPI tries to initialise Motif/X | `FORMS_API_TK_BYPASS=TRUE` |
| `XML-24523/24535 … not expected / invalid value` | attribute name/value not in the schema of this version | compare with `frmxmlsg.sh` (`forms.xsd`) or a `frmf2xml.sh` roundtrip |
| `XML2Forms`: `_jni_connect failed`; `frmcmp_batch`: `Form not created` (no message, rc=0) | DB logon failed – EZConnect in `userid`, wrong user/password | TNS alias (script does it), check `test_db_sec.conf.des3` |
| `PL/SQL ERROR 201 … 'USER_OBJECTS' must be declared` | compiled without DB logon (`logon=no`) | compile with `userid=` |
| `rwconverter` `Aborted (core dumped)`, rc=134 | `$ORACLE_HOME/bin/rwconverter` without the Reports environment | `$DOMAIN_HOME/reports/bin/rwconverter.sh` |
| report run returns no PDF, HTTP 499 | secured Reports server, no `cmdkey` | `cgicmd.dat` key `default` (14b-) |
| report run `REP-56132` | RDF directory not in `<folderAccess><read>` | `REPORTS_PATH` / 13- |

---

## Live Test Log

### 2026-10-16 – rebuilt test domain, FMW 14.1.2 (verified)

`15-deploy-test-report-forms_template.sh --apply`, `DISPLAY` unset,
`REPORTS_SECURITY=ldap` (secured server, `cgicmd.dat` key `default`):

```
OK  XML2Forms succeeded: test_form.fmb
    Compiling WHEN-NEW-FORM-INSTANCE trigger on form...  No compilation errors.
OK  frmcmp succeeded: test_form.fmx (trigger compiled against the DB)
OK  Deployed: /u01/app/oracle/forms/moduls/test_form.{fmb,fmx}
OK  rwconverter succeeded: test_dual.rdf
OK  Deployed: /u01/app/oracle/reports/source/test_dual.rdf
OK  Report run OK: PDF 1038 bytes (HTTP 200)
Summary: OK 19  WARN 0  FAIL 0
```

Way there:
1. Old script (2026-08): `XML2Forms` → `Failed to create new forms context`
   even with Xvfb; `$ORACLE_HOME/bin/rwconverter` → SIGABRT.
2. `rwconverter.sh` of the ReportsTools instance → RDF at once.
3. `FORMS_API_TK_BYPASS=TRUE` → JDAPI starts (also without `DISPLAY`) and
   shows the real schema errors of the hand-written XML.
4. `frmxmlsg.sh` (schema) + `frmf2xml.sh` roundtrip of
   `$ORACLE_HOME/forms/test.fmb` → corrected `test_form.xml` → FMB.
5. `frmcmp_batch` with EZConnect: `Form not created`; sqlplus with the same
   credentials works; TNS alias → FMX created.

### 2026-08-01 – first attempt (superseded)

Found: `frmxml2f`/`frmf2xml` are Java classes, not binaries in
`$ORACLE_HOME/bin`; all Forms/Reports binaries are directly under
`$ORACLE_HOME/bin/` (not `forms/bin` / `reports/bin`); `libnsl2` fix of
`13-root_reports_fix.sh` correct. Wrong conclusions of that day, corrected
2026-10-16: "both tools need an X display" (→ `FORMS_API_TK_BYPASS`,
instance wrapper) and "rwconverter crash probably memory pressure" (→
missing Reports environment).

---

## Starting the Test Form

The FMX in `FORMS_CUSTOMER_DIR` (first entry of `FORMS_PATH`) is called by
name without extension. Browsers no longer run the Java plugin, so a form is
started with **Java Web Start** or the **Forms Standalone Launcher (FSAL)**.
`15-` prints these URLs at the end (`<host>` = `WLS_SERVER_FQDN`; NGINX
`https://` when `WLS_LISTEN_ADDRESS=localhost`, else
`http://<host>:WLS_FORMS_PORT`):

| Client | URL / command |
|---|---|
| Java Web Start | `https://<host>/forms/frmservlet?config=webstart&form=test_form` – downloads a `.jnlp`, open with `javaws` (Oracle Java 8) or OpenWebStart |
| FSAL | `java -jar frmsal.jar -url "https://<host>/forms/frmservlet?config=standaloneapp&form=test_form" -t 30000` – `frmsal.jar` from `https://<host>/forms/html/fsal.htm`, client needs Java 8+ |
| Browser (legacy plugin) | `https://<host>/forms/frmservlet?form=test_form` – modern browsers: *"Oracle Java is required to run this application … Consider using Java Web Start or Standalone Launcher instead"* (servlet, `formsweb.cfg` and `FORMS_PATH` work – only the client is missing) |

- No `userid=` in the URL – the Forms logon dialog asks; a password in the
  URL ends up in browser history and access logs.
- Expected: `IT_SYSDATE` = server date/time, `IT_OBJ_COUNT` = number of
  `USER_OBJECTS` of the logged-on schema.
- `config=webstart` / `standaloneapp` need Oracle's sections in
  `formsweb.cfg` – `14-` keeps them since 2026-10-16 (before, they were
  missing and `config=webstart` returned the applet page). `15-` checks that
  `config=webstart` returns `application/x-java-jnlp-file`.
- Through NGINX the JNLP carries `codebase="https://<host>:443/forms/java/"`
  (checked 2026-10-16) – the proxy passes the host correctly.

## Open Items

- Interactive start of the form with Java Web Start / FSAL on a client
  (server side verified: JNLP, `fsal.htm`, `frmsal.jar` via NGINX).
- `test_user_objects.xml` (parameter form) is not part of the script run.
