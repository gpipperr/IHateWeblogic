# Reports server – images, `REPORTS_PATH` and `<folderAccess>`

**Scope:** Oracle Reports 14.1.2 (FMW 14.1.2.0.0, Reports QPR 39600348),
standalone Reports server (`ReportsServerComponent`) called through the
rwservlet. Reports migrated from Windows, where images were linked with
absolute paths (`D:\…`, `E:\…`). Sources: `rwserverconf.xsd` and
`confmbean.jar` of the installation, a test series on the test host
(2026-10-16), one customer case (2026-10-16).

Markers as in [README.md](README.md): **confirmed (code)**, **confirmed
(live)**, **documented**, **assumption**.

---

## 1. How an image gets into a report

| Report Builder | Where the image is | On a Linux server |
|---|---|---|
| *Insert → Image* (imported boilerplate image) | **embedded** in the `.rdf` | works, no path involved |
| *Link File* object, *Source File Format* = Image, *Source Filename* = `E:\berichte\grafiken\stamp.jpg` | read from disk **at run time** | the stored name must be resolvable on Linux |
| Database column with *Read from File* = Yes | the column value is the file name | the value from the database must be resolvable |

Only the last two need attention after a migration.

## 2. How a file name is resolved

- A name **without directory** (`stamp.jpg`) is searched in the current
  directory, then in the directories of `REPORTS_PATH` in order
  (**documented**; confirmed indirectly by the customer case below).
- `REPORTS_PATH` is an ordinary environment variable, on Linux separated by
  `:`. The Reports server engines get it from `rwserver.conf`
  (`<environment>` → `<envVariable name="REPORTS_PATH" …/>`), the Reports
  tools on the server (`rwrun`, `rwconverter`, Builder) from the shell or
  `$DOMAIN_HOME/reports/bin/reports.sh` – they do **not** read
  `rwserver.conf`.
- A **Windows path** in the report is **not** reduced to its file name
  (**confirmed (live)**, customer 2026-10-16): with the image directory in
  `REPORTS_PATH` and in `<folderAccess>`, and the server restarted, the run
  still fails with

  ```
  REP-108: Datei E:\berichte\grafiken\stamp.jpg wurde nicht gefunden.
  ```

  The full Windows string appears in the message, there is no fallback to
  `stamp.jpg`.
- Likely explanation (**assumption**): on Linux the string does not start
  with `/`, so Reports takes `E:\berichte\grafiken\stamp.jpg` as **one
  relative file name** (backslash and colon are ordinary characters in a
  Linux file name) and searches exactly that name in `REPORTS_PATH`.
  Test: a file literally named like that in the image directory –

  ```bash
  cp stamp.jpg '/u01/reports/images/E:\berichte\grafiken\stamp.jpg'
  ```

  – if the image then appears, the assumption is confirmed. Diagnosis only,
  not a solution (unreadable names, one copy per distinct path).

## 3. `<folderAccess>` – where the server may read

`REPORTS_PATH` says **where to search**, `<folderAccess>` says **where the
server may read** report definition files. A file outside is refused even if
`REPORTS_PATH` finds it:

```
REP-69: Ein interner Fehler ist aufgetreten
REP-56132: Access is denied to the report definition file.
```

Facts:

- The schema `$ORACLE_HOME/reports/dtd/rwserverconf.xsd` allows **exactly one**
  `<read>` and one `<write>` in `<folderAccess>` (no `maxOccurs`), the config
  class `oracle.reports.admin.rwserver.FolderAccess` (`confmbean.jar`) has a
  single `String m_read` (**confirmed (code)**).
- Several directories go into **one** `<read>`, separated by **`;`** – also
  on Linux, unlike `REPORTS_PATH` (**confirmed (live)**, test series below).
- Two `<read>` elements are accepted without an error, but only the **last**
  one counts (**confirmed (live)**) – customer case: the `.rdf` directory was
  first, the image directory second → every report REP-56132.
- **Subdirectories are not included**: `<read>/u01/reports</read>` does not
  allow `/u01/reports/source/x.rdf` (**confirmed (live)**).
- Changes take effect only after a restart of the Reports server
  (`stopComponent.sh` + `startComponent.sh`; `restartComponent.sh` is not
  supported for Reports server components).
- Not yet verified: whether `<folderAccess>` is also checked for **images**
  (Link File) or only for the report definition file – both directories in
  `<read>` covers either case.

### Test series (test host, 2026-10-16)

Report definition `test_dual.xml` called through the rwservlet with
`report=<absolute path>` and a deliberately invalid `userid`. **REP-501**
(database cannot be connected) means: folder access granted; **REP-56132**:
refused.

| `<read>` content | report in dir 1 | report in dir 2 |
|---|---|---|
| `dir1` only | REP-501 (granted) | REP-56132 |
| `dir1:dir2` | REP-56132 | REP-56132 |
| **`dir1;dir2`** | **REP-501 (granted)** | **REP-501 (granted)** |
| `dir1,dir2` | REP-56132 | REP-56132 |
| two `<read>` elements (`dir1`, `dir2`) | REP-56132 | REP-501 (last one wins) |
| parent directory of both | REP-56132 | REP-56132 |

`dir1:dir2` and `dir1,dir2` are taken as one (non-existent) directory name.

## 4. Working configuration

```xml
<environment id="QS">
  <!-- search path: ':' separated -->
  <envVariable name="REPORTS_PATH" value="/u01/reports/source:/u01/reports/images"/>
  ...
</environment>
...
<folderAccess>
  <!-- read access: ONE element, ';' separated, no subdirectories -->
  <read>/u01/reports/source;/u01/reports/images</read>
  <write>/u01/reports/temp</write>
</folderAccess>
```

File: `$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<server>/rwserver.conf`
(not `$ORACLE_HOME/reports/conf/rwserver.conf` – that one is only a template).

For `rwrun` / the tools on the server additionally in
`$DOMAIN_HOME/reports/bin/reports.sh`:

```bash
REPORTS_PATH=${REPORTS_PATH}:/u01/reports/source:/u01/reports/images; export REPORTS_PATH
```

## 5. Normalising the image references

Because there is no fallback (§2), the path has to leave the report. Target
state: the report contains only the **file name**, the image directory is in
`REPORTS_PATH` on Windows (Builder) and on Linux (server), and all image
files on Linux are **lower case**.

### Way A – Report Builder on Windows (confirmed (live), customer 2026-10-16)

1. Start the Builder with a `REPORTS_PATH` that contains the report source
   **and** the image directory – on Windows separated by `;`. In
   `rwbuilder.bat` (before the Builder is called):

   ```bat
   set REPORTS_PATH=d:\reports\berichte;d:\reports\images
   ```

2. Open the report, on the image element (*Link File*) remove the directory
   from *Source Filename* – only `gpiLogo.jpg` remains. The Builder finds the
   image through `REPORTS_PATH` and saves the report without a path.
3. Copy the `.rdf` to the Linux server (`REPORTS_PATH` directory).
4. On Linux all images are stored in lower case. A report that still uses a
   mixed-case name gets a symbolic link with exactly that spelling:

   ```bash
   cd /u01/reports/images
   ln -s gpilogo.jpg gpiLogo.jpg
   ```

5. Run the report – the image appears.

Result: new and edited reports are normalised (no path); old reports with a
different spelling of the same image need one link per spelling.

### Way B – all reports in one batch via XML (sed tested on sample data)

Normalise every report at once: no path, file name in lower case, then a
list of the images that are present in the image directory and of those
still missing. Only the `sourceFileName` attribute of `<linkFile>` elements
is touched (`$ORACLE_HOME/reports/dtd/reports.dtd`).

```bash
IMG_DIR=/u01/reports/images
BAK=rdf_backup_$(date +%Y%m%d_%H%M%S)
mkdir -p xml "$BAK" && cp -p *.rdf "$BAK"/                        # keep the originals

# 1. rdf -> xml (needs the ReportsTools environment, see note)
for r in *.rdf; do
  rwconverter.sh source="$r" stype=rdffile dest="xml/${r%.rdf}.xml" dtype=xmlfile batch=yes overwrite=yes
done

# 2. remove the directory, lower-case the file name (backup *.xml.bak)
sed -E -i.bak '/<linkFile/ s#(sourceFileName=")([^"]*\\)?([^"\\]*)"#\1\L\3\E"#' xml/*.xml

# 3. images referenced by the reports: present / missing in IMG_DIR
grep -ohE '<linkFile[^>]*sourceFileName="[^"]*"' xml/*.xml \
  | sed -E 's#.*sourceFileName="([^"]*)"#\1#' | sort -u \
  | while read -r f; do [ -e "$IMG_DIR/$f" ] && echo "OK      $f" || echo "MISSING $f"; done

# 4. xml -> rdf
for x in xml/*.xml; do
  b=$(basename "$x" .xml)
  rwconverter.sh source="$x" stype=xmlfile dest="$b.rdf" dtype=rdffile batch=yes overwrite=yes
done
```

Test with sample data: `E:\berichte\grafiken\gpiLogo.jpg` → `gpilogo.jpg`,
`d:\Graphiken\Stamp.JPG` → `stamp.jpg`, a name without path is only lowered,
`sourceFileName` of other elements stays unchanged; the list shows
`OK gpilogo.jpg` / `MISSING stamp.jpg`. Not yet run on real customer reports.

Notes:

- `sed` works line by line – if the converter writes the attribute on its own
  line apart from `<linkFile`, adjust the address. Check afterwards that no
  drive path is left:
  `grep -n 'sourceFileName="[A-Za-z]:\\' xml/*.xml`
- The extension is lowered too (`.JPG` → `.jpg`) – consistent with the
  lower-case files on Linux.
- `rwconverter` needs the ReportsTools environment (`COMPONENT_CONFIG_PATH`,
  `reports.sh`); without it, it dumps core.
- Database columns with *Read from File*: remove the path and lower the name
  in the data (`UPDATE … SET col = LOWER(REGEXP_REPLACE(col, '^.*[\\/]', ''))`)
  or in the query.
- Avoid non-ASCII characters (`ä`, `ß`) in image file names – the file system
  is UTF-8, the engines often run with `NLS_LANG=…WE8MSWIN1252`
  (**assumption**: the name may not match).

## 6. Diagnosis

| Message | Meaning | Check |
|---|---|---|
| `REP-56132: Access is denied to the report definition file` | `.rdf` outside `<read>` | one `<read>`, `;`-separated, exact directory (no parent), server restarted |
| `REP-108: Datei E:\…\x.jpg wurde nicht gefunden` | Windows path stored in the report | remove the path (§5) |
| `REP-108: Datei x.jpg wurde nicht gefunden` | name not found in `REPORTS_PATH` | directory in `REPORTS_PATH`, exact spelling (lower-case files → link with the spelling of the report, §5), file readable for `oracle` |
| `REP-501` with a test `userid` | folder access fine, database logon failed | expected in the test series |

## 7. Consequences for the repository

| Where | State |
|---|---|
| `70-Customer-Projects/…/Reports_kochbuch_de.txt` | fixed 2026-10-16: 9.7 one `;`-separated `<read>` (the first version of the same day had two elements – wrong), known problems REP-56132 and REP-108 with Way A / Way B |
| `09-Install/13-oracle_setup_reports.sh` | fixed 2026-10-16: writes `<read>` with the `:` of `REPORTS_PATH` converted to `;` |
| `09-Install/docs/13-reports-detail-settings.md` | fixed 2026-10-16: both separators documented |
| possible script | Way B of §5 as a script (dry-run lists paths and missing images, `--apply` converts with backup) – open |
