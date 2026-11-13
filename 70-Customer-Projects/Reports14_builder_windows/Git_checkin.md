# Git check-in for Reports developers – rdf → xml, `pull.ps1` / `checkin.ps1`

A very simple Git "deployment queue" for the Reports Builder server on
Windows ([README](README.md)): developers without Git experience keep their
normal Reports folders, run one script at the start of the work and one to
check in. The `.rdf` is converted to XML on every check-in, so the history
shows readable changes.

Status 2026-11-11: **step 1 of the architecture** – the rdf → xml
conversion from the command line – is tested on the Linux test host (same
Reports 14.1.2 tools runtime, `rwconverter`). **The Windows commands below
are to be confirmed at the customer** (test procedure in section 5). The
scripts are in [scripts/](https://github.com/gpipperr/IHateWeblogic/tree/main/70-Customer-Projects/Reports14_builder_windows/scripts) (section 4) – tested on Linux with
PowerShell 7.4, to confirm with Windows PowerShell 5.1 at the customer.

Related:
- Builder server set-up: [ReportBuilder_Windows_Kochbuch_en.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/ReportBuilder_Windows_Kochbuch_en.txt).
- Development workflow (copy → Builder → Git → DEV server → test):
  [reports_rwbuilder.md §6](../../80-FMW-Architecture/reports_rwbuilder.md#6-development-workflow--from-the-old-report-to-the-linux-dev-server).
- Image references (file name only, `REPORTS_PATH`):
  [reports_server_image_handling.md](../../80-FMW-Architecture/reports_server_image_handling.md).

---

## 1. The idea

```
 developer (RDP, personal login, e.g. gpi)
        |
        |  1. pull.ps1            at the start of the work
        |  2. edit in the Builder E:\git\%USERNAME%\oracle-report\source\*.rdf
        |  3. checkin.ps1 "comment"
        |        a) fetch: behind the remote? -> fast-forward first
        |        b) list of changed files -> number (only this one), a (all)
        |           (n = only upload unsent check-ins - offered only when there are some;
        |            x or Enter = cancel)
        |        c) selected .rdf -> convert_rdf.ps1 (rwconverter) -> xml\<name>.xml
        |        d) git add + commit only the selection ; push
        v
 Git server (HTTPS) --> later: automation to the Linux DEV Reports server
```

| Item | Value |
|---|---|
| clone per developer | `E:\git\%USERNAME%\oracle-report` – the folder above = the Windows login, e.g. `E:\git\gpi\oracle-report` for the user `gpi` |
| repository layout | top folder: [`menu.cmd`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.cmd) / [`menu.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ps1) / [`menu.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ini), `.gitlab-ci.yml`, `README.md`; folders `deploy\` (all scripts, also [`ci_deploy.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_deploy.sh) / [`rwdeploy.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.sh)), `source\` (`.rdf`), `xml\` (`.xml`), `images\` – layout of the customer, adopted 2026-11-12 |
| report sources | `E:\git\%USERNAME%\oracle-report\source\*.rdf` |
| images | `E:\git\%USERNAME%\oracle-report\images\` (file names in lower case, see the image article) |
| XML of every report | `E:\git\%USERNAME%\oracle-report\xml\<name>.xml` – written by [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1), never by hand |
| scripts | `E:\git\%USERNAME%\oracle-report\deploy\pull.ps1`, `...\checkin.ps1`, `...\convert_rdf.ps1`, `...\git_setup.ps1` (part of the repository, so every clone has the same version; [`git_setup.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/git_setup.ps1) once per user before the first check-in) |
| Git | Git for Windows (command line), remote via HTTPS, personal user |
| Builder start | desktop file `rwbuilder_git.bat` = copy of the original with `REPORTS_PATH=E:\git\%USERNAME%\oracle-report\source;...\images` in front (3.5) |
| user in commands and scripts | always the variable **`%USERNAME%`** (cmd) / **`$env:USERNAME`** (PowerShell) – no user name is written into a command, a script or `reports.bat`; the same text works for every developer. `gpi` is only the demo user of the examples |
| rights | the developer account is a **local administrator**, and the scripts / `rwconverter.bat` run in an **elevated session** (2.1) |

## 2. rdf → xml from the command line

### 2.1 Command on Windows (to confirm at the customer)

The Reports tools need the environment of the tools instance – the same as
for `rwbuilder.bat`. `rwconverter.bat` of the domain sets it itself (it
calls `reports.bat`).

Oracle reference (Publishing Reports 12.2.1.3 – Reports 14.1.2 refers to it):
[`rwconverter`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla002.htm#i634710) (A.2.4) and its keywords
[`SOURCE`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla008.htm#RSPUB23898), [`STYPE`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla008.htm#RSPUB23904),
[`DEST`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla005.htm#RSPUB23818), [`DTYPE`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla006.htm#RSPUB23822),
[`BATCH`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla005.htm#RSPUB23796), [`OVERWRITE`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla007.htm#RSPUB23855),
[`CMDFILE`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla005.htm#RSPUB23803), [`USERID`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla008.htm#RSPUB23910).

**Rights: local administrator, elevated session.** The Oracle installer
breaks the inheritance of permissions below `E:\oracle`, so a normal user
account cannot run the Reports tools – the same as for the Builder
(confirmed live at the customer 2026-10-27, README "Multi-user operation",
cookbook "User accounts"). Therefore:
- the developer account is a member of the local group **Administrators**;
- `rwconverter.bat`, [`pull.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1) and [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) run in a shell started with
  **"Run as administrator"** (cmd or PowerShell) – with UAC switched on, a
  normal window of an admin account still runs with standard rights
  ([how User Account Control works](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/user-account-control/how-it-works)).
  **Assumption:** `rwconverter` behaves like the Builder here (to confirm at
  the customer, section 5). A shortcut "Reports check-in" can be set to
  "Run as administrator" (shortcut → Properties → Advanced).

```bat
%DOMAIN_HOME%\reports\bin\rwconverter.bat source=E:\git\%USERNAME%\oracle-report\source\sales.rdf stype=rdffile ^
    dest=E:\git\%USERNAME%\oracle-report\xml\sales.xml dtype=xmlfile batch=yes overwrite=yes ^
    cmdfile=%USERPROFILE%\.rwconv\login.txt
```

In PowerShell (as the scripts will call it) – the clone folder from
`$env:USERNAME`:

```powershell
$repo = "E:\git\$env:USERNAME\oracle-report"
& "$env:DOMAIN_HOME\reports\bin\rwconverter.bat" "source=$repo\source\sales.rdf" stype=rdffile `
    "dest=$repo\xml\sales.xml" dtype=xmlfile batch=yes overwrite=yes `
    "cmdfile=$env:USERPROFILE\.rwconv\login.txt"
```

The scripts take the clone from their own location: they change to
`$PSScriptRoot` and from there to the top folder of the repository
(`git rev-parse --show-toplevel`) – the folder name does not even have to
match the login, and the folder they are started from does not matter.

- [`cmdfile=`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla005.htm#RSPUB23803) holds one line [`userid=<user>/<password>@<tns-alias>`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla008.htm#RSPUB23910) – the DB
  login, see 2.2. It is not on the command line (process list) and not in
  the repository.
- [`batch=yes`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla005.htm#RSPUB23796) = no dialog; [`overwrite=yes`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla007.htm#RSPUB23855) = replace the old XML.
- **Same base name** for `.rdf` and `.xml` (2.2, "report name").

Example of the login file – shown for the demo user `gpi` (DB user `gpi`, TNS alias
`fmwpdb` from the shared `tnsnames.ora` of the domain), created once in a cmd
shell of the developer:

```bat
mkdir %USERPROFILE%\.rwconv
```

```bat
notepad %USERPROFILE%\.rwconv\login.txt
```

Content – exactly one line, no blank at the end, save, close:

```
userid=gpi/<password>@fmwpdb
```

Only the developer may read the file (remove inherited rights, grant the own
account full access – [`icacls`](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/icacls)):

```bat
icacls %USERPROFILE%\.rwconv\login.txt /inheritance:r /grant:r "%USERNAME%:F"
```

```bat
icacls %USERPROFILE%\.rwconv\login.txt
```

Expected: only one line with `<computer>\gpi:(F)`. `%USERPROFILE%` is
`C:\Users\gpi` for the user `gpi` – outside the clone `E:\git\%USERNAME%\oracle-report`, so Git
never sees the file. A changed DB password = edit this one line.

**Other place (2026-11-12):** [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1) looks for
`%USERPROFILE%\.rwconv\login.txt` first; when it does not exist, it takes the
fixed file in `$LoginFileFixed` at the top of the script (default
`E:\oracle\rwconv\login.txt` – the customer sets the real place, e.g. one
shared conversion login for all developers, protected with `icacls` the same
way). Neither found → the message lists both paths.

### 2.2 Results – confirmed (live) on the Linux test host, 2026-11-11

Reports 14.1.2 + QPR 39600348, `$DOMAIN_HOME/reports/bin/rwconverter.sh`
(the Linux counterpart of `rwconverter.bat`), report `test_dual.rdf`:

| Question | Result | Consequence for [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) |
|---|---|---|
| without a DB login (`userid`) | **fails**: `REP-3022 internal error processing a window resource`, `REP-1430 ... compilation errors found`, `Conversion ... canceled`, exit code 1 – also with a virtual display (Xvfb). The converter compiles the report's PL/SQL and needs a database for that. | **A DB login is needed** – one `cmdfile` per developer (2.1), any account that can log in to the application DB |
| with `userid` via `cmdfile=` | works, **0.4–0.7 s** per report, exit code 0 | fast enough to convert every changed report on each check-in |
| display | not needed with a login (Linux without `DISPLAY`); on Windows the RDP session has a desktop anyway | – |
| same `.rdf` converted twice | **byte-identical XML** – no time stamp, no random id | a re-conversion of an unchanged report gives no Git change |
| report name | the `name=` attribute in line 2 of the XML: when the source file name equals the report's internal name, it is taken from the **destination file name** (`test_dual.rdf` → `dest=a.xml` → `name="a"`); **corrected 2026-11-12:** a renamed / copied `.rdf` (`umbenannt.rdf`, internal name still `test_dual`) keeps its internal name (`name="test_dual"`), whatever the destination is called | always `dest=<same base name>.xml` – then the XML is stable; a report copied in Explorer shows its old internal name in the XML (save it once in the Builder under the new name) |
| **umlauts** in the report name (2026-11-12) | `Übersicht.rdf`, `Umsatz_März.rdf` converted via [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1), exit 0, `xml\Übersicht.xml` written (XML `encoding="UTF-8"`); test host `NLS_LANG=AMERICAN_AMERICA.AL32UTF8` | works on Linux; Windows: to confirm (2.3) |
| round trip xml → rdf → xml | first round: the XML loses empty default elements (`<visualSettings><visualSettingsPrivate nullFlags="4294967295"/>`), second round stable | the XML is a complete source; a report saved from XML may show such a one-time difference |
| report file missing | `REP-1950 The Source specified is invalid`, exit code 1 | check the exit code – stop the check-in |
| broken file | `REP-0110 ... cannot be opened`, `REP-1070`, exit code 1 | the same |
| wrong DB login | three tries `REP-0501`, then `REP-0309 ... after three attempts. Access denied.`, exit code 1 | the same; message "check your login file" |
| `logfile=<file>` (2026-11-12) | **not usable:** `REP-34551 Feature LOGFILE is deprecated`; the file holds only "Converting … to …" and "Conversion … canceled" – **no `REP-` messages** (they go to the console only); with a wrong login the converter suddenly asks "Enter Password:" despite `batch=yes` and waited for input (hung until the timeout), the log file is not even created | [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1) does not use it – it redirects stdout / stderr itself and checks that the XML was written |
| several reports in one call | `source=(a.rdf,b.rdf) dest=(xml/a.xml,xml/b.xml)` works, exit code 0 – **but** the `name=` of the second file was the internal report name, not the file name | one call per report (0.5 s each is cheap) – stable names |

The XML contains the queries and the layout, **no login data** (checked:
neither user nor password of the conversion login in the file).

### 2.3 Open on Windows

- `rwconverter.bat` runs from PowerShell in the RDP session of a developer
  who is a local admin – in an elevated window ("Run as administrator");
  check whether it also works without elevation (UAC) – expected no, as for
  the Builder.
- Exit code arrives in PowerShell – expected 0 / 1 as on Linux.
- **Umlauts** in a report name (`Übersicht.rdf`): converted on Linux
  (`NLS_LANG` AL32UTF8). On Windows the file name goes through the ANSI
  code page (1252 has ä ö ü ß) and `NLS_LANG` of the Oracle home – convert one
  report with an umlaut once by hand with [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1).
- **Messages:** a plain call of `rwconverter.bat` returns no message to
  PowerShell on Windows (`rwconverter.exe` is a Windows program without a
  console – seen at the customer). `convert_rdf.ps1` starts it with
  `Start-Process -RedirectStandardOutput / -RedirectStandardError` and
  counts a conversion as successful only when the exit code is 0 **and**
  the XML was written now. To check on Windows: do the `REP-` lines arrive
  in the redirected output? If not, the script says "rwconverter hat keine
  Meldung geliefert" and the developer compiles the report in the Builder.
- Byte-identical XML on Windows (line ends: Windows may write CRLF – then set
  `*.xml text eol=crlf` or `-text` in `.gitattributes` so Git does not report
  every file as changed).
- Time per report on the Windows server.

## 3. Design decisions

### 3.1 What goes into Git

| Path | In Git | Why |
|---|---|---|
| `source\*.rdf` | yes (binary) | the file the Builder and the server use |
| `xml\*.xml` | yes | readable diff, review, restore; written only by [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) |
| `images\*` | yes | the server needs the same files |
| `deploy\*.ps1`, `menu.*` | yes | same script version for everyone |
| login file, `*.rep`, Builder backups (`*.rdf~`?), `*.log` | **no** – `.gitignore` | secrets, generated files |

[`.gitattributes`](https://git-scm.com/docs/gitattributes): `*.rdf binary`, `*.xml` with a fixed line end (2.3);
[`.gitignore`](https://git-scm.com/docs/gitignore) for the rest.

### 3.2 No stash, no merge for beginners

`.rdf` is binary – Git cannot merge two changes of the same report
(`*.rdf binary` in `.gitattributes`, template in `scripts/`). Rules the
scripts follow:
- **Only fast-forward, never stash.** [`git pull --ff-only`](https://git-scm.com/docs/git-pull) also works with
  own uncommitted changes – Git updates the other files and **aborts by
  itself** ("would be overwritten") when an incoming change touches a file
  the developer changed too. Nothing is overwritten, nothing is stashed.
  The first sketch ("pull.ps1 refuses with local changes, checkin.ps1 stops
  when behind") was dropped – it was a dead end: a developer with changes
  and a newer server could neither pull nor check in.
- [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) runs `git fetch` before converting: behind the server →
  fast-forward first; the same report changed by a colleague → stop.
- **One file or all (2026-11-12):** `checkin.ps1` lists the changed files of
  `source\` and `images\` (new / changed / deleted) with numbers – a number
  checks in only that file (plus its `.xml`), `a` checks in all, `n` checks
  in nothing new and only uploads check-ins that are committed locally but
  not yet on the server (after a failed push) – `n` is offered only when
  there are such check-ins, with their number; `x` or just Enter cancels
  ("Abgebrochen", exit 0, nothing checked in). Before the comment the
  script shows what the comment is for ("Ausgewaehlt: neu  <file>" or
  "Ausgewaehlt: 2 Dateien") and, when unsent check-ins exist, the note that
  they are uploaded together with this one; the question is neutral
  ("Kommentar fuer diesen Check-in (was und warum)") – "what did you change"
  did not fit a new or deleted file. Only the
  selection is staged and committed (`git commit -- <paths>`); the other
  changes stay in the working copy for a later check-in.
- **Rejected push → merge, not rebase (2026-11-12):** when a colleague pushed
  between `fetch` and `push` (or local check-ins not yet on the server meet a
  newer server), the script runs `git pull --no-rebase --ff` and pushes again.
  A rebase refuses to run while other, not selected reports are changed –
  with the file selection that is the normal case (tested). A merge works
  with them and **aborts before touching anything** when one of them would
  be overwritten – no stash, nothing can get lost. Price: in this rare case a
  merge commit appears in the history. On a conflict (same report) the
  script runs [`git merge --abort`](https://git-scm.com/docs/git-merge): the check-in stays local, the working copy
  is unchanged, the developer asks the Git contact person.
- The same report changed by two developers at the same time stays a
  conflict that a person resolves (agree who works on which report; Git LFS
  file locking would be the technical answer – later, if needed).

### 3.3 Credentials

- **Git over HTTPS:** Git for Windows brings the **[Git Credential Manager](https://github.com/git-ecosystem/git-credential-manager)** –
  the developer types user and password (or token) once, Windows keeps them
  in the credential store of the personal login. Nothing in the scripts.
- **DB login for the conversion:** one file per developer outside the
  repository, e.g. `%USERPROFILE%\.rwconv\login.txt` (`userid=...@alias`),
  readable only for the user. [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) asks for it once if it is
  missing ([`Read-Host -AsSecureString`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/read-host)) and writes the file. Alias from the
  shared `tnsnames.ora` of the domain.

### 3.4 `REPORTS_PATH` per developer

Today `reports.bat` holds one [`REPORTS_PATH`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_rfap001.htm#i648209) (Oracle: B.1.61) for all users (cookbook step
8.2: `E:\reports\src;E:\reports\images`). With one clone per user the Builder
must search the user's own clone – **decided: a copy of `rwbuilder.bat` on
the desktop sets it from `%USERNAME%` (3.5).** `reports.bat` itself stays
unchanged, so a patch or a new tools instance does not touch the per-user
part.

### 3.5 Builder start from the desktop – own `rwbuilder.bat` with `%USERNAME%`

The developer starts the Builder **only** through this file. It is a copy of
the original `%DOMAIN_HOME%\reports\bin\rwbuilder.bat` ([`rwbuilder`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla002.htm#i634624), Oracle A.2.3) with one added line
that puts the own clone at the front of `REPORTS_PATH` – report sources and
images (the Builder finds images through `REPORTS_PATH`, see the image
article). One file for all developers, because the user comes from
`%USERNAME%`.

| Item | Value |
|---|---|
| original | `%DOMAIN_HOME%\reports\bin\rwbuilder.bat` (written by `createReportsToolsInstance`, cookbook step 7) |
| copy | `C:\Users\Public\Desktop\rwbuilder_git.bat` – the public desktop, every RDP user sees it |
| added line | `set REPORTS_PATH=E:\git\%USERNAME%\oracle-report\source;E:\git\%USERNAME%\oracle-report\images;%REPORTS_PATH%` – **after** the line that calls `reports.bat` (that file sets `REPORTS_PATH` itself) and before the call of `rwbuilder.exe` |
| start | with administrator rights (2.1) – a `.bat` has no "Run as administrator" setting of its own, so a shortcut to it does (below) |

Create it once, as administrator, in a cmd shell after
`call E:\oracle\builder_env.cmd`:

```bat
copy %DOMAIN_HOME%\reports\bin\rwbuilder.bat C:\Users\Public\Desktop\rwbuilder_git.bat
```

```bat
findstr /n /i "reports.bat rwbuilder" C:\Users\Public\Desktop\rwbuilder_git.bat
```

Expected: one line that calls `reports.bat`, one later line that starts
`rwbuilder` (`%ORACLE_HOME%\bin\rwbuilder.exe` or similar – note the line
numbers).

```bat
notepad C:\Users\Public\Desktop\rwbuilder_git.bat
```

Insert directly **below** the `reports.bat` line (and above the `rwbuilder`
line):

```bat
rem IHW: own Git clone first - E:\git\<Windows login>\oracle-report
set REPORTS_PATH=E:\git\%USERNAME%\oracle-report\source;E:\git\%USERNAME%\oracle-report\images;%REPORTS_PATH%
```

Check – the line is there and stands between the two others:

```bat
findstr /n /i "reports.bat IHW REPORTS_PATH rwbuilder" C:\Users\Public\Desktop\rwbuilder_git.bat
```

Shortcut with administrator rights (Explorer, on the public desktop):
right click → New → Shortcut → target
`C:\Users\Public\Desktop\rwbuilder_git.bat`, name "Reports Builder (Git)";
then shortcut → Properties → Shortcut → **Advanced → "Run as
administrator"**; "Start in": `%DOMAIN_HOME%\reports\bin` written out as
the real path (e.g. `E:\oracle\user_projects\domains\rwbuilder_domain\reports\bin`).
Optionally hide the `.bat` itself and leave only the shortcut visible.

Test as a developer (e.g. `gpi`): start "Reports Builder (Git)", open a
report from `E:\git\gpi\source`, preview – images with a file name
only (no path) must appear. Help → About shows 14.1.2.0.0.

Notes:
- **After every patch and after a new `createReportsToolsInstance`**
  compare the copy with the original (`fc %DOMAIN_HOME%\reports\bin\rwbuilder.bat
  C:\Users\Public\Desktop\rwbuilder_git.bat`) – the only difference must be
  the two IHW lines; otherwise copy again and add the lines again.
- `%USERNAME%` = the Windows login; the clone folder has the same name (1.).
- **Assumption, to confirm at the customer:** the exact content of the
  Windows `rwbuilder.bat` (the Linux `rwbuilder.sh` of the test host sources
  `reports.sh`, sets the tools instance `reptools1` and then starts
  `$ORACLE_HOME/bin/rwbuilder`; `reports.sh` puts its own directories in
  front of an existing `REPORTS_PATH` and keeps the rest). If `reports.bat`
  should not keep an existing `REPORTS_PATH`, the added line after it still
  wins – that is why it stands below the `reports.bat` call.
- The old shortcut "Oracle Reports Builder" of cookbook step 8.4 (to the
  original `rwbuilder.bat`) should be removed for the Git developers, so
  nobody works against `E:\reports\src` by mistake.

## 4. The scripts

Files in [scripts/](https://github.com/gpipperr/IHateWeblogic/tree/main/70-Customer-Projects/Reports14_builder_windows/scripts) – a skeleton for the customer's own
adaptation: plain PowerShell, one step after the other, no nested commands,
**messages and comments in German** (the developers' language), plain ASCII
(Windows PowerShell 5.1 reads files without BOM as ANSI). Copy them into
`deploy\` of the repository, [`menu.cmd`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.cmd) / [`menu.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ps1) / [`menu.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ini) into the top folder (the scripts change to the top folder
themselves – `Set-Location` [`$PSScriptRoot`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables), then [`git rev-parse
--show-toplevel`](https://git-scm.com/docs/git-rev-parse) – so they work from any start folder; all paths in the
scripts are relative to the top folder: `source`, `xml`,
`images`).

| File | Purpose |
|---|---|
| [pull.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1) | at the start of the work: shows own uncommitted changes (they stay), `git pull --ff-only`, the last 5 check-ins |
| [git_setup.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/git_setup.ps1) | once per Windows user: asks name, e-mail address and `core.autocrlf` (`true` / `input` / `false`, proposal `true`; Enter keeps the shown value), sets them with `git config --global`, shows the result |
| [convert_rdf.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1) | one report `.rdf` → `.xml` with `rwconverter` (`cmdfile=` login file – no password on the command line); output of the converter captured with `Start-Process` (stdout / stderr into temp files, `REP-` / `ORA-` lines shown); success = exit code 0 **and** XML written now; `-Check` = only the checks (admin session, converter, login file). Only the report name: `.\convert_rdf.ps1 bericht` → `source\bericht.rdf` → `xml\bericht.xml` (folders relative to the top folder of the repository, same values as in [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1); always `<name>.xml`, so the XML stays stable – see the report-name row in 2.2). Called by `checkin.ps1`, also usable alone |
| [checkin.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) | `.\checkin.ps1 "comment"`: checks (`convert_rdf.ps1 -Check`) → `git fetch` (behind → fast-forward; same report changed → stop) → numbered list of the changed files in source / images, **number = only this file, `a` = all, `n` = nothing new, only send** → comment → convert the selected new / changed `.rdf` with [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1) (stop at the first error, nothing committed) → delete the `.xml` of a selected deleted `.rdf` → `git add` + commit **only the selection, one check-in per file** (a report together with its `.xml`; with several files the file name is appended to the comment – the tag concept of [Git_deploy.md](Git_deploy.md) needs one report per check-in) → push (rejected → `pull --no-rebase` + push; conflict → `merge --abort`) |
| [checkin_only.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin_only.ps1) | the same Git flow **without the Reports part** – no admin check, no `.rdf` → `.xml` conversion, the list shows every changed file of the repository (number / `a` / `n`, commit only the selection – one check-in per file, merge on a rejected push). For a PC without Reports and without admin rights – to try the Git flow before the Builder server is ready. Stand-alone file, no shared code (the customer wants each script as simple as possible) |
| [status.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status.ps1) | **read only**: `git fetch` (files unchanged), then branch + server branch, files changed but not checked in, local check-ins not yet on the server, server check-ins not yet here (with the right next script: [`pull.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1), or [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) when both sides have new check-ins – `pull.ps1` can only fast-forward), the last 5 check-ins locally and on the server (hash, date, author, comment) |
| [status_detail.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status_detail.ps1) | **read only**: the last 20 check-ins of the current branch (`status_detail.ps1 50` = 50) as a Markdown table with the columns Datum, Commit ID, Datei, Tag, Prod – one row per changed file, `-` for a check-in without files (merge), tags from `--decorate-refs=refs/tags/`, `NO_TAG` without tag; the first line of an annotated tag's message goes into the row(s) below the tag name (indented, wrapped at the width of the longest tag name, at least 40 – keeps the table narrow; the rows of the commit's other files are used first); **Prod** = `PROD` (this version is in production: commit of the most recently created `prod-*` tag of the file, same logic as [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1), one `git diff-tree --stdin` for all tags), `offen` (newer than that), `alt` (older, or production is on a commit not yet pulled – then a hint [`pull.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1)), `-` (not deployed: anything but `source/*.rdf` / `images/*`, deleted files); below the table the open files of this list and a pointer to `release_tag.ps1 -List`; no fetch; `-File <text>` = only files whose name contains the text (pathspec `:(glob,icase)**/*<text>*`, special characters escaped; the count then means the last N check-ins of those files; case-insensitive only for a-z) |
| [menu.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ps1) / [menu.cmd](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.cmd) / [menu.ini](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ini) | **start menu for a double click** (customer request 2026-11-12): [`menu.cmd`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.cmd) (desktop shortcut, set to *Run as administrator* for [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1)) starts `powershell.exe -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File menu.ps1 -Fenster -Zeilen %ZEILEN% -Spalten %SPALTEN%`; window size set at the top of `menu.cmd` (`ZEILEN=60`, `SPALTEN=0` = keep width), [`menu.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ps1) sets `RawUI.WindowSize` capped at `MaxPhysicalWindowSize` plus a 3000-line buffer (not `mode con`, which would drop the scrollback), errors ignored (Windows Terminal ignores the size); `menu.ps1` reads [`menu.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ini) (UTF-8, one section per entry: `Sortierung`, `Skript`, `Parameter`, `Kurz`, `Lang`, `Admin`; section `[Menue]` = `Titel`, `Frage`, `SkriptPfad`; `SkriptPfad` = folder of the scripts – empty = folder of `menu.ps1`, relative = from the folder of `menu.ps1` (`..\Reports`), absolute with `%VARIABLE%` expanded (`E:\git\%USERNAME%\Reports`), a `SkriptPfad` in an entry wins over the one in `[Menue]`; surrounding quotes are ignored, spaces allowed; `menu.cmd` / `.ps1` / `.ini` stay together), shows the numbered list sorted by `Sortierung`, asks until a valid number or `x`; the chosen script runs in the same window via `& 'path' <Parameter>` (its `exit` ends only the script), the long text is shown first, the return code afterwards; `-NoExit` keeps the window open with the result; `x` closes the window (`[Environment]::Exit` only with `-Fenster`, otherwise just returns); `Admin = ja` checks for an elevated window first; `menu.ps1` defines a global function `m` (`Set-Item function:global:m`, same `-Ini` / `-Fenster`, no resize) so `m` + Enter in the open window starts the menu again; `x` or `q` (any case) ends the menu, and with `-Fenster` global functions `x` / `q` (`[Environment]::Exit(0)`) close the window after a script, too; a missing script is shown as "Skript fehlt". All German texts with umlauts live in `menu.ini`, the `.ps1` stays ASCII; [`template.gitattributes`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/template.gitattributes) gets `*.cmd` / `*.ini` `eol=crlf` |
| [release_tag.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) | **release of one check-in to production** (customer script rebuilt in our style, adapted to the tag concept 2026-11-12): part 1 = check-ins on `origin/main` newer than the production state of their file (= commit of the most recently created `prod-*` tag of that file, so a rollback tag counts), numbered with files and a per-file summary; part 2 = the last 20 check-ins sorted by date (`--date-order`), one row per file with the tag of its own commit or `NO_TAG`, then the last 20 releases sorted by tag date with only the files of the tagged commit; part 3 = number from part 1 **or a commit id** (`-Commit`, also an older check-in – checked: exists, on the branch, no merge), warnings (newer check-ins of the same file are listed – they do not go along; several files), annotated tag `prod-<yyyy-MM-dd_HHmm>_<file>` on the chosen commit, `git push origin <tag>` – starts the PROD pipeline ([Git_deploy.md](Git_deploy.md)). Default filter `-Filter '*.rdf'` (`-like` on the whole path, `''` = all files), `-File <text>` = part of the file name (case-insensitive incl. umlauts, both filters applied in PowerShell); further `-Branch`, `-TagPrefix`, `-Anzahl`, `-Nummer`, `-TagDatei`, `-Nachricht`, `-Ja`, `-NoPush`, `-NoFetch`; `-List` = only parts 1 and 2, no question, no tag (not together with `-Nummer` / `-Commit`) |
| [README_DE.md](scripts/README_DE.md) | **for the developers, German:** the daily workflow with an ASCII diagram (pull → Builder → save → status → check-in), one-time set-up, the selection (number / `a` / `n` / `x`), what each message means, rules – goes into the customer repository next to the scripts |
| [template.gitattributes](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/template.gitattributes) | `*.rdf binary`, line ends of `*.xml` (value after the Windows test, 2.3) |
| [template.gitignore](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/template.gitignore) | `*.rep`, logs, backups, `login.txt` |

Settings at the top of [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1): `$DomainHome` (default
`E:\oracle\user_projects\domains\rwbuilder_domain`, the environment variable
`DOMAIN_HOME` wins), the login file `%USERPROFILE%\.rwconv\login.txt` –
when missing the fixed `$LoginFileFixed` (default `E:\oracle\rwconv\login.txt`,
adapt it) –, the variable `RWCONVERTER` replaces the converter – for tests only. At the top
of [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1): the three folders `source`, `xml`,
`images`.

### 4.1 Tested on Linux (2026-11-11, file selection 2026-11-12) – Windows to confirm

PowerShell 7.4 on the Linux test host, a local bare repository as the Git
server, two clones (`gpi`, `kollege`), a fake converter (writes the XML,
fails with `REP-1430` for a report containing `BROKEN`). Windows
PowerShell 5.1 and the real `rwconverter.bat` are to be confirmed at the
customer (section 5).

| Case | Result |
|---|---|
| pull, clean | "Already up to date", last check-ins, exit 0 |
| check-in: 1 changed + 1 new report | both converted, 4 files committed and pushed, exit 0 |
| check-in without changes | "Nichts einzuchecken", exit 0 |
| server ahead, own change in another report | fast-forward first, then check-in – exit 0 |
| pull with own change in another report | change kept, pull done |
| **colleague changed the same report** – check-in / pull | Git: "would be overwritten", script stops, nothing changed, exit 1 |
| broken report | `REP-1430` shown, nothing committed, exit 1 |
| report deleted | `.rdf` and matching `.xml` deleted and checked in |
| colleague pushes **during** the check-in (other report) | first push rejected → `pull --no-rebase` → push, exit 0 |
| same, **same report** | merge conflict → `merge --abort`; check-in local, own change kept, no merge left open, exit 1 |
| local unsent check-in + newer server | message, commit, merge on push – both on the server, exit 0 |
| **file selection** (2026-11-12): 4 changes, number 4 = new report | only that `.rdf` + its `.xml` committed, the other 3 changes stay |
| selection: deleted report / new image | only the deletion / only the image committed |
| selection `a` | all changes + converted `.xml` committed |
| invalid number (`9`) | "Ungueltige Auswahl", nothing checked in, exit 1 |
| selection display (both scripts) | number: "Ausgewaehlt: neu  doc/n1.txt"; `a` with 1 file: the same with its state; `a` with 2: "Ausgewaehlt: 2 Dateien"; comment as parameter: display, no question; with 1 unsent check-in: the note "… wird/werden mit hochgeladen", both check-ins on the server afterwards |
| **umlauts** (2026-11-12, seen at the customer: `f<C3><BC>r` in `git log`) | cause 1: Git's pager (`less`) shows the UTF-8 bytes of the comment raw – the comment itself is stored correctly (UTF-8, checked byte by byte); cause 2, worse: a file name with an umlaut came as `"doc/\303\234bersicht.txt"` (Git quotes non-ASCII paths) – listed as "geloescht", `git add` failed. Fix in all three scripts: `[Console]::OutputEncoding = UTF8`, `git -c core.quotePath=false` for `ls-files` / `diff` / `status`, `git --no-pager log --no-decorate`. After it: `doc/Übersicht.txt`, `doc/Größe.txt` listed and checked in, comment "Übersicht für Test" shown correctly |
| empty comment (Enter) | "Abgebrochen (kein Kommentar) - es wurde nichts eingecheckt.", exit 0 – same as `x` in the list |
| `x`, `X` or just Enter (both scripts, also when `n` is offered) | "Abgebrochen - es wurde nichts eingecheckt.", exit 0; files and unsent check-ins untouched |
| `n` without unsent check-ins / with 1 unsent check-in | not offered – the question shows only "Nummer (nur diese) oder a (alle)", `n` = "Ungueltige Auswahl", exit 1 / offered with the count ("… n (nichts einchecken, nur die 1 noch nicht gesendete(n) Check-in(s) hochladen)"), only pushed, "OK - an den Git-Server gesendet" (both scripts) |
| converter moved to [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1) | broken report: `REP-1430` from `convert_rdf.ps1`, nothing committed, exit 1; login file missing: message from `-Check` before the list; alone without arguments: usage, exit 1; alone with the report name (`b1`, `b1.rdf` or a path): `xml\b1.xml` written, exit 0; unknown name: "Bericht nicht gefunden", exit 1 |
| login file: personal file missing → fixed `$LoginFileFixed` used; both missing → message with both paths, exit 1 |  as expected (2026-11-12) |
| [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1) with the **real** `rwconverter.sh` 14.1.2 (2026-11-12) | success: XML written, exit 0 (also a second run); broken file: `REP-0110` / `REP-1070` shown, exit 1; wrong login: 3× `REP-0501` + `REP-0309` shown, no hang, exit 1 |
| converter without any output (exit 1, or exit 0 without writing the XML) | "rwconverter hat keine Meldung geliefert …", exit 1 – a missing XML is caught even with exit code 0 |
| [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) / [`checkin_only.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin_only.ps1) selection `a` (2026-11-12, tag concept) | one check-in per file (`checkin.ps1`: report + its `.xml`), comment `<comment> (<file>)`; the push carries all of them |
| [`checkin_only.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin_only.ps1) (2026-11-12) | list of all changed files; number = only `doc/c.txt` committed, the rest stays; `x` invalid, exit 1; `a` = new, changed and deleted file committed; server ahead + another changed file: fast-forward, then only the selection; `n`-case with an unsent commit + newer server: merge, pushed |
| [`status.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status.ps1) (2026-11-12) | clean: "OK - lokal und Git-Server sind gleich"; 1 changed file + 1 unsent + 1 newer server check-in: all three listed with the hint [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) (pull.ps1 would fail); only behind: hint [`pull.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1); umlauts in comments shown correctly; working copy unchanged afterwards |
| [`status_detail.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status_detail.ps1) (2026-11-12) | one row per file; two tags on one commit shown as `v1.0, v1.1`; annotated tag with umlaut message `v2.0` + `Freigabe Übersicht Q4` (since the Prod column in the row below, before in brackets), only the first line; tag with empty message shown as name only; `-File umsatz` finds `umsatz.rdf` and `UMSATZ_neu.rdf` but not `umsatz_dir/a.txt` (name only), `-File [1]` / `*` taken literally, `-File Übersicht` ok (`übersicht` not – git icase only a-z), no match: message, exit 0; merge commit shown with `-`; umlaut file name in clear text; `2` = only 2 commits; `0`: message, exit 1. Prod column (tag-concept sandbox): tagged `umsatz.rdf` `PROD`, its older check-in `alt`, untagged `kunde.rdf` `offen` + summary line, `.xml` / scripts `-`, tag message wrapped into the following rows; rollback tag on the older `umsatz` → older `PROD`, newer `offen`, a pipe sign in the message shown as `/`; HEAD on an older commit with a newer prod tag → `alt` + hint [`pull.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1) |
| [`menu.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ps1) (2026-11-12, pwsh 7.4 on Linux, input piped) | menu from [`menu.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ini) sorted, umlauts from the UTF-8 ini shown correctly; `9` / `abc`: message, asks again; `3` runs [`status_detail.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status_detail.ps1) in the same process, end line "Fertig"; `5` passes `-List` to [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1); ini entry with `-List -Nummer 1`: script error shown with "Rueckgabe 1"; `Admin = ja` without elevation: message, script not started; section without `Skript`: warning, skipped; missing script file marked in red with the searched path below the list; `x` rc 0 with and without `-Fenster`; `-NoExit` session: `3`, `m`, `2`, `m`, `x` = menu three times, two scripts, then closed; `q` / `Q` / `X` rc 0; `2`, then `x` at the prompt closes the session (next line not run); without `-Fenster` `q` only returns and no `x` function is defined; menu in its own folder: `SkriptPfad = ../Reports`, absolute with `%VAR%` and per-entry `SkriptPfad` find and run the scripts, empty = all marked "Skript fehlt". Menu one level above the scripts (`SkriptPfad = Reports`, path with a space, started from another folder) and in a subfolder (`..`) ok; `"Reports"` in quotes failed first – fixed. Open: double click / `-NoExit` / elevated shortcut on Windows PS 5.1 |
| layout switch (2026-11-12, sandbox `<user>/oracle-report`: bare repo, `deploy/`, `source/`, `xml/`, `images/`, `menu.*` in the top folder) | [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) (`a`): one check-in for `images/logo.png`, one for `source/umsatz.rdf` + `xml/umsatz.xml`; `ci_deploy.sh dev` (no last, BEFORE fallback): both files copied to DEV; `release_tag.ps1 -Nummer 1 -Ja`: tag pushed; `ci_deploy.sh prod`: only `umsatz.rdf` to PROD; [`status_detail.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status_detail.ps1): `umsatz.rdf` `PROD`, `logo.png` `offen`, scripts `-`; menu started from `/`: all 6 scripts found in `deploy`; [`rwdeploy.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.sh) rejects `Reports/source/a.rdf`, `source/sub/b.rdf`, `source/c.txt` |
| [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) (2026-11-12, bare repo as server) | default only `.rdf`: doc-only check-in hidden; tag pushed (`ls-remote` shows it); `-Filter ''`: check-in with 2 files asks for the file, `Übersicht.rdf` -> tag `..._Uebersicht.rdf`; tag concept (only `main`): older version of a report chosen → "ACHTUNG … neuerer Check-in", after the tag on the newest version both check-ins of the report no longer open, part 2 date-sorted with `NO_TAG` for untagged check-ins; rollback tag on the older `umsatz` → the newer one open again; `-File UMS` / `-File übersicht` case-insensitive; `-Nummer 9`, input `x`, unknown branch: message, exit 1; Enter: nothing tagged, exit 0; `-NoPush`: tag only local; `-List`: lists only, exit 0; `-List -Nummer 1`: message, exit 1 |
| [`git_setup.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/git_setup.ps1) (isolated `HOME`) | first run sets the 3 values; Enter keeps them; `input` changes only `core.autocrlf`; invalid e-mail / value: message, nothing changed |
| colleague pushes during the check-in, **another changed report not selected** | `pull --rebase` would refuse ("unstaged changes") – merge works, the not selected change stays, exit 0 |
| same, colleague changed exactly **that not selected report** | Git: "would be overwritten" before any change, check-in local, the own edit unchanged, exit 1 |
| nothing new, 1 unsent check-in | only pushed |
| login file missing | clear message with the line format, exit 1 |
| both scripts | parse without errors (PowerShell parser), plain ASCII |

Not covered by the scripts (on purpose, kept simple): Git LFS / locking,
several branches, a pre-check that the Builder has saved and closed the
report.

**Branch and deployment (2026-11-12, customer decision):** there is only
the branch `main` ([`status.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status.ps1) warns on any other branch); every report is
its own check-in. A push to `main` deploys the changed reports to the Linux
DEV Reports server; a `prod-*` tag set with [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) deploys
exactly the files of the tagged check-in to production – no merge requests:
[Git_deploy.md](Git_deploy.md).

## 5. Test procedure for the customer appointment (Windows, cmd)

As a developer account (**local administrator**) on the Builder server, in a
cmd shell started with **"Run as administrator"**, after
`call E:\oracle\builder_env.cmd` (cookbook step 0.2). Use a copy of a real
report in a temporary folder. At the end, run the first conversion once more
in a **normal** (not elevated) cmd window – does it fail? That decides
whether the scripts must ask for elevation.

```bat
mkdir E:\temp\xmltest\xml
```

```bat
copy E:\reports\src\<report>.rdf E:\temp\xmltest\
```

```bat
notepad E:\temp\xmltest\login.txt
```

One line `userid=<user>/<password>@<alias>`, save, close.

```bat
%DOMAIN_HOME%\reports\bin\rwconverter.bat source=E:\temp\xmltest\<report>.rdf stype=rdffile dest=E:\temp\xmltest\xml\<report>.xml dtype=xmlfile batch=yes overwrite=yes cmdfile=E:\temp\xmltest\login.txt
```

```bat
echo %ERRORLEVEL%
```

Expected: `0`, and `E:\temp\xmltest\xml\<report>.xml` exists (open it:
`<report name="<report>" ...>`).

Determinism – convert again into a second file name **with the same base
name** in another folder and compare:

```bat
mkdir E:\temp\xmltest\xml2
```

```bat
%DOMAIN_HOME%\reports\bin\rwconverter.bat source=E:\temp\xmltest\<report>.rdf stype=rdffile dest=E:\temp\xmltest\xml2\<report>.xml dtype=xmlfile batch=yes overwrite=yes cmdfile=E:\temp\xmltest\login.txt
```

```bat
fc /b E:\temp\xmltest\xml\<report>.xml E:\temp\xmltest\xml2\<report>.xml
```

Expected: `FC: no differences encountered`.

Error case – exit code for a missing report:

```bat
%DOMAIN_HOME%\reports\bin\rwconverter.bat source=E:\temp\xmltest\nosuch.rdf stype=rdffile dest=E:\temp\xmltest\xml\nosuch.xml dtype=xmlfile batch=yes overwrite=yes cmdfile=E:\temp\xmltest\login.txt
```

```bat
echo %ERRORLEVEL%
```

Expected: `1` (and `REP-1950` in the output).

PowerShell check (as [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) will run it):

```powershell
& "$env:DOMAIN_HOME\reports\bin\rwconverter.bat" source=E:\temp\xmltest\<report>.rdf stype=rdffile dest=E:\temp\xmltest\xml\<report>.xml dtype=xmlfile batch=yes overwrite=yes cmdfile=E:\temp\xmltest\login.txt; $LASTEXITCODE
```

Expected: `0`.

Clean up – the login file first:

```bat
del E:\temp\xmltest\login.txt
```

```bat
rmdir /s /q E:\temp\xmltest
```

Note the results (time per report, `fc` result, line ends of the XML) –
they decide 2.3 and the `.gitattributes`.

## 6. References

Checked 2026-11-13 (all addresses HTTP 200, anchors present). Reports
14.1.2 refers to the 12.2.1.3 documentation library for Oracle Reports.

| Topic | Original documentation |
|---|---|
| converter | Oracle Publishing Reports 12.2.1.3: [`rwconverter` (A.2.4)](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla002.htm#i634710); keywords [`SOURCE`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla008.htm#RSPUB23898), [`STYPE`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla008.htm#RSPUB23904), [`DEST`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla005.htm#RSPUB23818), [`DTYPE`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla006.htm#RSPUB23822), [`BATCH`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla005.htm#RSPUB23796), [`OVERWRITE`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla007.htm#RSPUB23855), [`CMDFILE`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla005.htm#RSPUB23803), [`USERID`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla008.htm#RSPUB23910) |
| Builder, search path | Oracle: [`rwbuilder` (A.2.3)](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla002.htm#i634624), [`REPORTS_PATH` (B.1.61)](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_rfap001.htm#i648209) |
| fast-forward, merge, commit | Git [`git pull`](https://git-scm.com/docs/git-pull) (`--ff-only`, `--no-rebase`), [`git merge`](https://git-scm.com/docs/git-merge) (`--abort`), [`git commit`](https://git-scm.com/docs/git-commit) (`-- <paths>` = only the selection), [`git log`](https://git-scm.com/docs/git-log), [`git rev-parse`](https://git-scm.com/docs/git-rev-parse) (`--show-toplevel`) |
| settings | Git [`git config`](https://git-scm.com/docs/git-config) (`core.autocrlf`, `core.quotePath`, `user.name` / `user.email`), [`gitattributes`](https://git-scm.com/docs/gitattributes) (`binary`, `eol`), [`gitignore`](https://git-scm.com/docs/gitignore) |
| HTTPS login | [Git Credential Manager](https://github.com/git-ecosystem/git-credential-manager) |
| PowerShell | [`Start-Process`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process) (`-RedirectStandardOutput` / `-RedirectStandardError`, `-Wait`, `-PassThru`), [`$PSScriptRoot`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables), [`Read-Host -AsSecureString`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/read-host), [execution policies](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies) (`-ExecutionPolicy Bypass` in `menu.cmd`), [`powershell.exe` options](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe) (`-NoExit`, `-NoLogo`, `-NoProfile`, `-File`) |
| Windows rights | [`icacls`](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/icacls), [how User Account Control works](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/user-account-control/how-it-works) ("Run as administrator") |
