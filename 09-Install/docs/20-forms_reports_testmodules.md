# Creating Forms & Reports Test Modules Without a GUI Builder

Manual procedure for building a minimal Oracle Forms test module (FMX) and a
minimal Oracle Reports demo report (RDF/REP), entirely from the command line —
no Forms Builder, no Reports Builder, no GUI/X server required. Both test
artifacts only need a plain database connection (`select sysdate from dual`,
`select * from user_objects`) and are meant to give a fast, scriptable
smoke test that Forms and Reports are correctly installed and can compile,
run, and reach the database.

> **Status:** Procedure worked out and the XML sources are well-formed.
> First live test against a real FMW 14.1.2 host happened on 2026-08-01 —
> see [Live Test Log](#live-test-log-orafusion01pipperrlocal-2026-08-01)
> below. Several assumptions turned out wrong (tool names/locations); the
> actual XML→FMB/RDF conversion itself is still **not confirmed working
> end-to-end**. Follow the open verification points in each section before
> relying on this.

---

## Testkit Layout

Implemented as (see [Next Steps](#next-steps) for status):

| File | Purpose |
|---|---|
| `09-Install/forms_templates/test_form.xml` | Forms XML module: control block `BL_DATA`, items `IT_SYSDATE`/`IT_OBJ_COUNT`, a `WHEN-NEW-FORM-INSTANCE` trigger populates both from `user_objects` |
| `09-Install/reports_templates/test_dual.xml` | Reports XML: `to_char(sysdate, ...) as sys_datum from dual` (**not** `current_date` as alias — reserved word!) |
| `09-Install/reports_templates/test_user_objects.xml` | Reports XML: tabular listing of `object_name, object_type, status from user_objects`, filtered by a `<userParameter>` + `<parameterForm>` (object-name pattern, default `%`) — see `REPORTS_XML_SYNTAX_REFERENCE.md` for the parameter/parameter-form syntax |
| `09-Install/15-deploy-test-report-forms_template.sh` | Driver script: `frmxml2f` → `frmcmp` (Forms) and `rwconverter` (Reports), deploys into `FORMS_CUSTOMER_DIR`/`REPORTS_CUSTOMER_DIR`. Only deploys the component(s) selected in `INSTALL_COMPONENTS`. |

Not implemented yet:
- `MakeTestForm.java` — JDAPI fallback (Plan B) for building the FMB
  programmatically, in case `frmxml2f` rejects the XML
- A `rwrun`/live smoke-test-execution step in the driver script (currently
  copy + compile only)

---

## Part 1 — Forms Test Module

### Key Finding

- The "FMT plain-text syntax" (`Begin Form ... End`) that circulates online is
  **fabricated** — it does not exist and will not compile.
- `.fmt` is real, but only as an undocumented property dump produced by
  `frmcmp script=yes` (FMB→FMT) and consumed by `frmcmp parse=yes` (FMT→FMB).
  It is not meant to be hand-written.
- **The actual text-based path is Forms XML** together with the CLI tools
  `frmf2xml` / `frmxml2f` — no Builder GUI needed.

### Step 1 — Write the Forms XML Module

Create `test_form.xml` (see format reference below for element structure).
It defines:
- One control block `BL_DATA` (not database-bound)
- Two items: `IT_SYSDATE`, `IT_OBJ_COUNT`
- A `WHEN-NEW-FORM-INSTANCE` trigger that populates both items by querying
  `user_objects`

### Step 2 — Convert XML → FMB

> **Confirmed on FMW 14.1.2 (live test, 2026-08-01): `frmxml2f` is not a
> binary.** It does not exist anywhere under `$ORACLE_HOME`. The real
> implementation is the Java class `oracle.forms.util.xmltools.XML2Forms` in
> `$ORACLE_HOME/jlib/frmxmltools.jar`. See the Live Test Log for the full
> discovery and the confirmed real usage text. Direct invocation:

```bash
export LD_LIBRARY_PATH=$JAVA_HOME/lib/server:$ORACLE_HOME/lib
CP="$ORACLE_HOME/jlib/frmjdapi.jar:$ORACLE_HOME/jlib/frmxmltools.jar:$ORACLE_HOME/oracle_common/modules/oracle.xdk/xmlparserv2.jar"
java -classpath "$CP" oracle.forms.util.xmltools.XML2Forms \
  OVERWRITE=YES USERID=$CONNECT test_form.xml
```

> **Needs a live DB connection itself** (`USERID=`, uppercase), not just the
> later `frmcmp` compile step — confirmed both by a real-world failure
> report (Oracle Forums, 2006: without `userid=`, fails with `error
> connecting to database` / `jniconnect failed`) and by the tool's own usage
> text on this FMW 14.1.2 install: *"USERID=database connection string - for
> record group queries"*. Options come **before** the filename
> (`frmxml2f [options] file.xml`), not after.
>
> **Also requires a working X display** (`DISPLAY` + Xvfb) — without it,
> JDAPI initialization fails with `_jni_initialize: Failed to create new
> forms context` even before reaching the database connection. See Live
> Test Log.

### Step 3 — Compile FMB → FMX

```bash
frmcmp.sh module=test_form.fmb userid=$CONNECT \
          module_type=form batch=yes compile_all=yes \
          output_file=test_form.fmx
```

### Optional — Roundtrip a Real FMB to Learn the Exact Syntax

If the hand-written XML is rejected, build (or obtain) any working FMB and
dump it back to XML to see the exact, tool-generated syntax:

```bash
frmf2xml.sh OVERWRITE=YES DUMP=ALL test_form.fmb
```

### XML Format Reference

(Verified against a real 10g dump — see references below for 12.2.1.x
sources.)

- Root element: `<Module version="..." xmlns="http://xmlns.oracle.com/Forms">`
- Child structure: `<FormModule Name= ConsoleWindow= Title=>` containing
  `<Coordinate/>`, `<Window/>`, `<Canvas/>`, `<Block><Item/></Block>`,
  `<Trigger Name="WHEN-NEW-FORM-INSTANCE" TriggerText="..."/>`
- Trigger source code is stored as an XML attribute; line breaks are encoded
  as `&#10;`
- An XSD can be generated with `frmxmlsg` (ships alongside `frmf2xml` in the
  Forms `BIN` directory) — use it to validate hand-written XML
- `frmf2xml` must run with `USE_PROPERTY_IDS=NO` (this is the default)

### Plan B — JDAPI (if `frmxml2f` rejects the XML)

Build the FMB programmatically instead, using the Java Developer API:

```java
FormModule fmb = new FormModule("TEST_FORM");
Canvas cv = new Canvas(fmb, "CV_MAIN"); cv.setWindowName("WIN_MAIN");
Block blk = new Block(fmb, "BL_DATA"); blk.setDatabaseBlock(false);
Item it = new Item(blk, "IT_SYSDATE"); it.setCanvasName("CV_MAIN"); // canvas name must be UPPERCASE!
Trigger trg = new Trigger(fmb, "WHEN-NEW-FORM-INSTANCE"); trg.setTriggerText("...");
fmb.save("test_form.fmb"); Jdapi.shutdown();
```

- Jar location: `$ORACLE_HOME/jlib/frmjdapi.jar` (12c FMW) or
  `forms/java/frmjdapi.jar` (Forms Developer Suite 10g)
- Running it requires the full Forms environment plus
  `LD_LIBRARY_PATH=$ORACLE_HOME/lib` (native libraries)

### Open Verification Points — Forms

1. **`version` attribute on the `<Module>` tag**: 10g dumps use the numeric
   form `101020002`. Whether `12.2.1.4.0` is correct for FMW 14.1.2/12.2.1.4
   is **unverified**. If compilation fails on this attribute: use the JDAPI
   path (Plan B) instead, then roundtrip the result with
   `frmf2xml DUMP=ALL` and copy the real value from there.
2. Attribute names such as `PromptAttachmentEdge`, `ViewportWidth` look
   plausible but must be validated against the XSD (`frmxmlsg`) before trusting
   them.
3. Item type defaults to Text Item / Char — `setItemType`/`setDataType` were
   deliberately left unset; add them explicitly if a different item type is
   needed.
4. **`<Property Name= Value=/>` child elements vs. plain attributes**: at
   least one secondary source shows Forms XML items structured as
   `<Item Name="..."><Property Name="PromptText" Value="..."/></Item>`
   instead of attributes directly on `<Item>` (as used in `test_form.xml` and
   the Forms2XML documentation referenced below). Weak/unconfirmed signal —
   the source is a conceptual blog post, not a tool-generated dump — but
   worth checking against the XSD (`frmxmlsg`) or a real `frmf2xml` roundtrip
   before assuming attributes are correct.
5. **Oracle staff explicitly discourage cross-version XML conversion**
   (Oracle Forums, 2006, Michael Ferrante/Oracle, in response to a
   `frmxml2f` failure report): *"I would not recommend taking XML files from
   [an older version] and try to convert them in [a newer one]... That was
   not how the xml formatted files were intended to be used. I would
   recommend converting to FMB in [the old version] then upgrading and/or
   compiling the FMB in [the new version]."* This raises the stakes on Point
   1 above: if `frmxml2f` on FMW 14.1.2 rejects a hand-written XML module
   with an unfamiliar `version`, that may not be a fixable syntax issue —
   the JDAPI path (Plan B) should then be treated as the **primary** approach
   for this Forms version, not just a fallback.

### References — Forms

- Forms2XML/XML2Forms documentation (options, syntax):
  https://docs.oracle.com/database/apex-18.1/AEMIG/Converting_FormModules_ObjectLibraries_MenuModules_to_XML.htm
- Older equivalent (same content):
  https://docs.oracle.com/database/apex-5.1/AEMIG/Converting_FormModules_ObjectLibraries_MenuModules_to_XML.htm
- Real XML dump of an FMB (10.1.2, structural reference):
  https://odieweblog.wordpress.com/2011/11/23/oracle-xml-db-a-practical-example/
- Forms→XML in practice (Oracle APEX blog):
  https://blogs.oracle.com/apex/forms-to-apex-converting-fmbs-to-xml
- `frmf2xml` practical walkthrough (also documents the older `Forms2XML` /
  `iff2xml90.bat` tool for 9i/10g, a different name than `frmf2xml`/
  `frmxml2f` — and a third, different `version` attribute example,
  `90040019`, reinforcing that this value is strictly version-specific):
  https://www.sqlines.com/articles/oracle-forms/convert-to-xml
- JDAPI example: building an FMB from scratch (Block/Item/Trigger/setters):
  http://www.e-ammar.net/Oracle_TIPS/Forms_API.htm
- JDAPI further examples (openModule/save/shutdown):
  http://www.e-ammar.net/Oracle_TIPS/more_JDAPI.htm
- JDAPI dump example (Oracle 11g documentation):
  https://docs.oracle.com/cd/E28280_01/doc.1111/e54906/forms.htm
- Versioning Oracle Forms with XML — conceptual overview, shows Forms XML
  items structured with `<Property Name= Value=/>` child elements rather
  than plain attributes (see Open Verification Point 4 above; unconfirmed
  against a real tool dump):
  https://www.linkedin.com/pulse/versioning-oracle-forms-using-xml-instead-binary-orclapex-developer-wet2f
- Oracle Forums (2006) — real `frmxml2f` failure report and the Oracle-staff
  reply used in Open Verification Point 5 above:
  https://forums.oracle.com/ords/apexds/post/convert-xml-file-to-fmb-very-urgent-1747
- Oracle Forums — related thread (could not be fetched to review; check
  manually if relevant):
  https://forums.oracle.com/ords/apexds/post/convert-xml-file-to-fmb-8731

---

## Part 2 — Reports Demo Report

### Key Finding

- XML report definitions are **officially documented** and run standalone
  once the data model and a complete layout are present — no Reports Builder
  needed.
- The `.rex` extension seen in Oracle's sample files is misleading — the
  actual file extension is `.xml`. Conversion to RDF/REP happens via
  `rwconverter` with `stype=xmlfile`.

### Step 1 — Write the Reports XML Definition

Create `test_dual.xml` (see format reference below). It defines a single
data source querying `to_char(sysdate, ...) as sys_datum from dual`, and a
tabular layout displaying that column.

> **Alias trap:** do not use `current_date` as a column alias — it is a
> reserved Oracle function name. Use a neutral alias such as `sys_datum`.

### Step 2 — Convert XML → RDF (or REP)

> **Confirmed on FMW 14.1.2 (live test, 2026-08-01): `rwconverter` is a real
> binary at `$ORACLE_HOME/bin/rwconverter`** (not under `reports/bin/` as
> initially assumed — see Live Test Log). It also **requires a working X
> display** (`DISPLAY` + Xvfb) — without it, it aborts (`SIGABRT`) as soon as
> it is given real arguments (bare invocation / `-help` do not need it).

```bash
export DISPLAY=:99   # Xvfb must be running on this display
export LD_LIBRARY_PATH=$JAVA_HOME/lib/server:$ORACLE_HOME/lib

# -> RDF (source definition)
rwconverter userid=$CONNECT batch=yes overwrite=yes \
  source=test_dual.xml stype=xmlfile dest=test_dual.rdf dtype=rdffile

# -> REP (compiled runtime file) — same command with dtype=repfile
```

### Step 3 — Run / Test

```bash
# Run the XML definition directly (no conversion needed)
rwrun.sh report=test_dual.xml userid=$CONNECT destype=file \
  desformat=pdf desname=test_dual.pdf batch=yes

# Or test against a running Reports Server (recommended — see note below)
rwclient.sh server=<rep_server> report=test_dual.rdf userid=$CONNECT \
  destype=cache desformat=pdf
```

### XML Format Reference

- Root element: `<report name="..." DTDVersion="9.0.2.0.0">` (this DTD
  version number is correct for 11g and 12c as well, per Oracle's own docs)
- Data model: `<data><dataSource name="Q_1"><select>...</select></dataSource></data>`
- Layout: `<layout><section name="main"><tabular name="M_1"><labelAttribute/><field name= source= label=/></tabular></section></layout>`
- Section types: `header`, `main`, `trailer`
- Simple layout styles: `tabular`, `groupLeft`
- Column aliases in the `SELECT` are **mandatory** for unambiguous column
  names; `source=` in the layout references that alias
- The DTD ships with the installation:
  `$ORACLE_HOME/reports/dtd/report.dtd`
- Additional elements as needed: `<link>` (master-detail),
  `<formula>`, `<exception>`/`<condition>` (format triggers), and the
  `beforeReportTrigger` attribute on the `<report>` tag
- Parameters (`<userParameter>`, bind-variable styles, `<parameterForm>`):
  not covered here — see
  `09-Install/reports_templates/REPORTS_XML_SYNTAX_REFERENCE.md` for the
  full syntax (kept separate so it's reusable for debugging any Reports
  XML, not just these two demo reports)

### Open Verification Points — Reports

1. The `template` attribute on `<tabular>` was deliberately left out. If the
   resulting layout is empty or broken, add
   `template="rwbeige.tdf"` (templates live under
   `$ORACLE_HOME/reports/templates`).
2. `rwrun` exists in 12.2.1.4 but runs in-process; prefer `rwclient` against
   the Reports Server for a realistic test.
3. Alias trap (see above): `CURRENT_DATE` is an Oracle function — always use
   a neutral alias like `sys_datum`.
4. **Not yet confirmed**: whether `test_dual.xml` actually converts
   successfully. The one live attempt (2026-08-01) crashed with `SIGABRT`,
   but on a host that was simultaneously under severe memory pressure (see
   Live Test Log) — inconclusive, needs a clean re-test with valid DB
   credentials and headroom to rule out an actual tool/XML problem.

**Resolved by live testing (2026-08-01):**
- `libnsl.so.2` fix (`13-root_reports_fix.sh`): the hardcoded source path
  `/lib64/libnsl.so.3.0.0` is **confirmed correct** — the `libnsl2` RPM
  (`dnf install libnsl2`, available in `ol9_appstream`) provides exactly
  that file.
- `rwconverter` needs an active X display (`DISPLAY` + Xvfb) even for
  non-interactive/batch conversion.

### References — Reports

- XML Report Definitions overview + standalone XML reports (10g AS):
  https://docs.oracle.com/cd/B14504_01/dl/web/B12099_01/adx14rep.htm
- Creating XML Customizations, including a runnable standalone example (11g):
  https://docs.oracle.com/middleware/11119/classic/use-reports/pbr_xml002.htm
- Creating XML Data Models, including DTD fragments (12.2.1.3):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_xml003.htm
- Data Models, 11.1.2 variant:
  https://docs.oracle.com/cd/E38115_01/doc.111210/e24479/pbr_xml003.htm
- Customization examples (colors, format masks, exceptions):
  https://docs.oracle.com/cd/E28280_01/bi.1111/b32121/pbr_xml002.htm
- Historical baseline doc "Customizing Reports at Runtime" (9i, still a good read):
  https://docs.oracle.com/html/A73173_01/output/pbr_xml.htm

---

## Live Test Log (orafusion01.pipperr.local, 2026-08-01)

First real test of this procedure, against the actual FMW 14.1.2 install on
`orafusion01.pipperr.local` (Oracle Linux 9.7). `environment.conf` confirms
`ORACLE_HOME=/u01/app/oracle/fmw`, `DOMAIN_HOME=/u01/app/oracle/domains/fr_domain`.
WebLogic AdminServer and the `WLS_REPORTS` managed server were running at
the start of the test.

### Setup performed

- `TEST_DB_CONNECT` was **not** set yet in `environment.conf` at test time —
  `15-deploy-test-report-forms_template.sh` correctly failed its prereq
  check and stopped (as designed).
- As root: `dnf install -y xorg-x11-server-Xvfb libnsl2`.
- Verified `rpm -ql libnsl2 | grep libnsl` → `/usr/lib64/libnsl.so.3`,
  `/usr/lib64/libnsl.so.3.0.0` — matches `13-root_reports_fix.sh`'s
  hardcoded `LIBNSL_SRC` exactly.
- Ran `13-root_reports_fix.sh --apply` as root: symlink created
  successfully, `ldd` on `rwserver` now resolves `libnsl.so.2` correctly.
  Script worked exactly as designed — this was a case of the fix genuinely
  not having been applied yet on this host, not a bug in the script.

### Finding 1 — `frmxml2f`/`frmf2xml` are not binaries at all

Neither exists anywhere under `$ORACLE_HOME` as an executable. They are
**Java classes** inside `$ORACLE_HOME/jlib/frmxmltools.jar`:
`oracle.forms.util.xmltools.XML2Forms` (= `frmxml2f`), `.Forms2XML` (=
`frmf2xml`), `.SchemaGenerator` (= `frmxmlsg`), plus `.XMLValidator` and
`.ConverterUtilities` (not previously mentioned in this doc).

The actual `.sh` wrapper scripts exist, but as **templates**, not deployed
executables: `$ORACLE_HOME/forms/templates/scripts/frmxml2f.sh` /
`frmf2xml.sh` — containing `%ORACLE_HOME%`-style placeholders meant to be
substituted "by the Forms installation process", with a comment "please
make these changes manually if not". Their actual invocation, confirmed by
reading the template source:

```bash
java -classpath \
  $ORACLE_HOME/jlib/frmjdapi.jar:$ORACLE_HOME/jlib/frmxmltools.jar:$ORACLE_HOME/oracle_common/modules/oracle.xdk/xmlparserv2.jar \
  oracle.forms.util.xmltools.XML2Forms "$@"
```

Running this directly (with `$JAVA_HOME/lib/server` + `$ORACLE_HOME/lib` on
`LD_LIBRARY_PATH`) produced the **real, confirmed usage text**:

```
Oracle Forms 14.1.2 XML to Forms Tool
Copyright(c) 2001, 2024, Oracle and/or its affiliates.

Correct usage:
  frmxml2f [options] file.xml [file2...]
Options: (default value in brackets)
OVERWRITE=YES/NO overwrite files that already exist (NO)
PRINTTREE=YES/NO prints a forms object tree as the xml is parsed (NO)
USERID=database connection string - for record group queries (none)
OUTPUTDIR=[directory path] specifies the directory where the binary file will
be written. ... (none)
```

This confirms: `USERID=` (uppercase) is real, options precede the filename,
and — importantly — the forum-reported DB-connection requirement is real
(`for record group queries`), though `test_form.xml` has no record group so
it's unclear yet whether `USERID=` is strictly mandatory for this
particular module.

### Finding 2 — All Forms/Reports CLI binaries live directly under `$ORACLE_HOME/bin/`

Confirmed via `ls`: `frmcmp`, `frmcmp_batch`, `frmbld`, `frmweb`,
`rwconverter`, `rwrun`, `rwclient`, `rwbuilder`, etc. are all directly under
`$ORACLE_HOME/bin/` — **not** under `$ORACLE_HOME/forms/bin/` or
`$ORACLE_HOME/reports/bin/` as this doc originally assumed (matching the
`00-Setup/init_env.sh` convention, e.g. `RWRUN="${FMW_HOME}/bin/rwrun"`,
which turned out to be the accurate one).

> **Cross-reference:** `09-Install/06-oracle_install_forms_reports.sh`'s
> post-install verification checks `$ORACLE_HOME/forms/bin/frmcmp_batch` and
> `$ORACLE_HOME/reports/bin/rwrun` — both **wrong paths** per this live
> system. Needs a follow-up fix in that script (out of scope for this doc's
> update, tracked here as a reminder).

### Finding 3 — Both tools need a working X display, even for batch conversion

- `XML2Forms` (frmxml2f): without `DISPLAY`, fails immediately with
  `Error initialising the Forms Jdapi: _jni_initialize: Failed to create
  new forms context`.
- `rwconverter`: without `DISPLAY`, aborts (`SIGABRT`) as soon as it's given
  real arguments — bare invocation or `-help` run fine without a display,
  which is misleading (looks like the tool doesn't need one until it does).
- No `Xvfb` was installed on this host at all before this test.
  `environment.conf`'s `DISPLAY_VAR=":99"` was already the intended value —
  just nothing was listening on it.

### Finding 4 — `rwconverter` test was inconclusive (host under severe memory pressure)

With `libnsl2` fixed and `Xvfb :99` running, `rwconverter userid=scott/tiger@//10.10.10.124:1521/fmwpdb
batch=yes overwrite=yes source=test_dual.xml stype=xmlfile dest=test_dual.rdf
dtype=rdffile` (deliberately invalid demo credentials, since `TEST_DB_CONNECT`
was not yet configured) **aborted with `SIGABRT`** (empty `core_<pid>/`
directories were created, no usable core file — `ulimit -c` was `unlimited`
but no `gdb` was available to inspect further).

At the same time, `dmesg` showed a real **OOM-kill of the `WLS_REPORTS`
managed server** (`Out of memory: Killed process ... (java) ...`), and
`free -h` showed the host at ~5.4/7.2 GB RAM used with swap essentially
full (2.0/2.0 GB). Given this, the `rwconverter` abort is more likely a
memory-allocation failure than a genuine tool/XML problem — **not a
confirmed finding**, needs a clean re-test once the host has headroom again
and with valid `TEST_DB_CONNECT` credentials.

**Action needed:** restart `WLS_REPORTS` (it was not deliberately stopped)
and confirm the host has sufficient free memory before the next live test —
running Forms/Reports native tools alongside the already-running WLS
processes pushed this constrained host over the edge.

### Finding 5 — JDAPI fallback path confirmed available

`$ORACLE_HOME/jlib/frmjdapi.jar` exists on this install, so the Plan B path
(Part 1) remains usable if `XML2Forms` continues to reject `test_form.xml`
once retested. Not yet exercised.

### Not yet tested

- `XML2Forms` conversion of `test_form.xml` with Xvfb running (Finding 3 was
  discovered first; testing paused to investigate the Reports-side crash
  and the OOM condition before using more memory on further native process
  launches)
- `frmcmp` compile step (Forms)
- Anything with valid, non-demo DB credentials (`TEST_DB_CONNECT` still
  needs to be set in `environment.conf`)

---

## Next Steps

**Implemented:**
- `09-Install/forms_templates/test_form.xml` and
  `09-Install/reports_templates/test_dual.xml` — the two XML sources
  described above
- `09-Install/15-deploy-test-report-forms_template.sh` — copies + converts +
  compiles both, respecting `INSTALL_COMPONENTS` (only deploys Forms and/or
  Reports if that component is actually selected), deploys into
  `FORMS_CUSTOMER_DIR`/`REPORTS_CUSTOMER_DIR`. **Currently still calls
  `frmxml2f`/`frmcmp`/`rwconverter` by searching `forms/bin`/`reports/bin`
  for plain binaries or `.sh` wrappers — needs updating per Findings 1+2
  above** (the script itself has not been changed yet; this doc records the
  findings first, as requested).

**Plan C (preferred, in progress) — external Forms 14 developer:** asked a
developer friend with real Oracle Forms 14 experience to build the minimal
test form directly in Forms Builder (or export `test_form.xml` from a real,
working Forms 14 module) instead of continuing the trial-and-error approach
below. This would resolve Open Verification Points 1-4 above (`version`
attribute, attribute names, `<Property>` vs. plain-attribute structure)
directly, with a confirmed-working source instead of a guess. If/when that
lands, it supersedes `test_form.xml` as written and items 5-6 below become
unnecessary; until then, items 1-6 remain the fallback path.

**Still open, updated after the 2026-08-01 live test:**
1. Restart `WLS_REPORTS` and confirm free memory before the next live test
   (Finding 4).
2. Set `TEST_DB_CONNECT` in `environment.conf` for a clean, credentialed
   re-test.
3. Update `15-deploy-test-report-forms_template.sh` to invoke `XML2Forms`
   via `java -classpath ...` (Finding 1) instead of searching for a
   `frmxml2f` binary, and to look for `frmcmp`/`rwconverter` directly under
   `$ORACLE_HOME/bin/` (Finding 2).
4. Fix the same wrong-path assumption in
   `09-Install/06-oracle_install_forms_reports.sh`'s post-install
   verification (Finding 2 cross-reference).
5. Re-test `rwconverter` cleanly (Finding 4) and, for the first time, test
   `XML2Forms`+`frmcmp` end-to-end with Xvfb running (highest remaining
   unknown: the Forms `version` attribute and item/canvas attributes, per
   Part 1's Open Verification Points).
6. If `XML2Forms` rejects `test_form.xml`: implement the JDAPI fallback
   (`MakeTestForm.java`, Plan B in Part 1) and use its `Forms2XML`/`DUMP=ALL`
   roundtrip output to correct `test_form.xml`.
7. Once the compile step is confirmed working, consider adding an optional
   `rwrun`/live smoke-test-execution step to
   `15-deploy-test-report-forms_template.sh`.
