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
scripts are a flow sketch (section 4), not written yet.

Related:
- Builder server set-up: [ReportBuilder_Windows_Kochbuch_en.txt](ReportBuilder_Windows_Kochbuch_en.txt).
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
        |  2. edit in the Builder E:\git\%USERNAME%\Reports\source\*.rdf
        |  3. checkin.ps1 "comment"
        |        a) fetch: behind the remote? -> stop, "run pull.ps1 first"
        |        b) changed .rdf -> rwconverter -> Reports\xml\<name>.xml
        |        c) git add source xml images ; commit -m "comment" ; push
        v
 Git server (HTTPS) --> later: automation to the Linux DEV Reports server
```

| Item | Value |
|---|---|
| clone per developer | `E:\git\%USERNAME%` – the folder name = the Windows login, e.g. `E:\git\gpi` for the user `gpi` |
| report sources | `E:\git\%USERNAME%\Reports\source\*.rdf` |
| images | `E:\git\%USERNAME%\Reports\images\` (file names in lower case, see the image article) |
| XML of every report | `E:\git\%USERNAME%\Reports\xml\<name>.xml` – written by `checkin.ps1`, never by hand |
| scripts | `E:\git\%USERNAME%\Reports\pull.ps1`, `...\checkin.ps1` (part of the repository, so every clone has the same version) |
| Git | Git for Windows (command line), remote via HTTPS, personal user |
| Builder start | desktop file `rwbuilder_git.bat` = copy of the original with `REPORTS_PATH=E:\git\%USERNAME%\Reports\source;...\images` in front (3.5) |
| user in commands and scripts | always the variable **`%USERNAME%`** (cmd) / **`$env:USERNAME`** (PowerShell) – no user name is written into a command, a script or `reports.bat`; the same text works for every developer. `gpi` is only the demo user of the examples |
| rights | the developer account is a **local administrator**, and the scripts / `rwconverter.bat` run in an **elevated session** (2.1) |

## 2. rdf → xml from the command line

### 2.1 Command on Windows (to confirm at the customer)

The Reports tools need the environment of the tools instance – the same as
for `rwbuilder.bat`. `rwconverter.bat` of the domain sets it itself (it
calls `reports.bat`).

**Rights: local administrator, elevated session.** The Oracle installer
breaks the inheritance of permissions below `E:\oracle`, so a normal user
account cannot run the Reports tools – the same as for the Builder
(confirmed live at the customer 2026-10-27, README "Multi-user operation",
cookbook "User accounts"). Therefore:
- the developer account is a member of the local group **Administrators**;
- `rwconverter.bat`, `pull.ps1` and `checkin.ps1` run in a shell started with
  **"Run as administrator"** (cmd or PowerShell) – with UAC switched on, a
  normal window of an admin account still runs with standard rights.
  **Assumption:** `rwconverter` behaves like the Builder here (to confirm at
  the customer, section 5). A shortcut "Reports check-in" can be set to
  "Run as administrator" (shortcut → Properties → Advanced).

```bat
%DOMAIN_HOME%\reports\bin\rwconverter.bat source=E:\git\%USERNAME%\Reports\source\sales.rdf stype=rdffile ^
    dest=E:\git\%USERNAME%\Reports\xml\sales.xml dtype=xmlfile batch=yes overwrite=yes ^
    cmdfile=%USERPROFILE%\.rwconv\login.txt
```

In PowerShell (as the scripts will call it) – the clone folder from
`$env:USERNAME`:

```powershell
$repo = "E:\git\$env:USERNAME\Reports"
& "$env:DOMAIN_HOME\reports\bin\rwconverter.bat" "source=$repo\source\sales.rdf" stype=rdffile `
    "dest=$repo\xml\sales.xml" dtype=xmlfile batch=yes overwrite=yes `
    "cmdfile=$env:USERPROFILE\.rwconv\login.txt"
```

The scripts may also take the clone from their own location
(`$PSScriptRoot` = `E:\git\%USERNAME%\Reports`) – then the folder name does not
even have to match the login.

- `cmdfile=` holds one line `userid=<user>/<password>@<tns-alias>` – the DB
  login, see 2.2. It is not on the command line (process list) and not in
  the repository.
- `batch=yes` = no dialog; `overwrite=yes` = replace the old XML.
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
account full access):

```bat
icacls %USERPROFILE%\.rwconv\login.txt /inheritance:r /grant:r "%USERNAME%:F"
```

```bat
icacls %USERPROFILE%\.rwconv\login.txt
```

Expected: only one line with `<computer>\gpi:(F)`. `%USERPROFILE%` is
`C:\Users\gpi` for the user `gpi` – outside the clone `E:\git\%USERNAME%`, so Git
never sees the file. A changed DB password = edit this one line.

### 2.2 Results – confirmed (live) on the Linux test host, 2026-11-11

Reports 14.1.2 + QPR 39600348, `$DOMAIN_HOME/reports/bin/rwconverter.sh`
(the Linux counterpart of `rwconverter.bat`), report `test_dual.rdf`:

| Question | Result | Consequence for `checkin.ps1` |
|---|---|---|
| without a DB login (`userid`) | **fails**: `REP-3022 internal error processing a window resource`, `REP-1430 ... compilation errors found`, `Conversion ... canceled`, exit code 1 – also with a virtual display (Xvfb). The converter compiles the report's PL/SQL and needs a database for that. | **A DB login is needed** – one `cmdfile` per developer (2.1), any account that can log in to the application DB |
| with `userid` via `cmdfile=` | works, **0.4–0.7 s** per report, exit code 0 | fast enough to convert every changed report on each check-in |
| display | not needed with a login (Linux without `DISPLAY`); on Windows the RDP session has a desktop anyway | – |
| same `.rdf` converted twice | **byte-identical XML** – no time stamp, no random id | a re-conversion of an unchanged report gives no Git change |
| report name | the `name=` attribute in line 2 of the XML is taken from the **destination file name** (`dest=a.xml` → `name="a"`) | always `dest=<same base name>.xml` – otherwise the XML changes |
| round trip xml → rdf → xml | first round: the XML loses empty default elements (`<visualSettings><visualSettingsPrivate nullFlags="4294967295"/>`), second round stable | the XML is a complete source; a report saved from XML may show such a one-time difference |
| report file missing | `REP-1950 The Source specified is invalid`, exit code 1 | check the exit code – stop the check-in |
| broken file | `REP-0110 ... cannot be opened`, `REP-1070`, exit code 1 | the same |
| wrong DB login | three tries `REP-0501`, then `REP-0309 ... after three attempts. Access denied.`, exit code 1 | the same; message "check your login file" |
| several reports in one call | `source=(a.rdf,b.rdf) dest=(xml/a.xml,xml/b.xml)` works, exit code 0 – **but** the `name=` of the second file was the internal report name, not the file name | one call per report (0.5 s each is cheap) – stable names |

The XML contains the queries and the layout, **no login data** (checked:
neither user nor password of the conversion login in the file).

### 2.3 Open on Windows

- `rwconverter.bat` runs from PowerShell in the RDP session of a developer
  who is a local admin – in an elevated window ("Run as administrator");
  check whether it also works without elevation (UAC) – expected no, as for
  the Builder.
- Exit code arrives in PowerShell (`$LASTEXITCODE`) – expected 0 / 1 as on
  Linux.
- Byte-identical XML on Windows (line ends: Windows may write CRLF – then set
  `*.xml text eol=crlf` or `-text` in `.gitattributes` so Git does not report
  every file as changed).
- Time per report on the Windows server.

## 3. Design decisions

### 3.1 What goes into Git

| Path | In Git | Why |
|---|---|---|
| `Reports\source\*.rdf` | yes (binary) | the file the Builder and the server use |
| `Reports\xml\*.xml` | yes | readable diff, review, restore; written only by `checkin.ps1` |
| `Reports\images\*` | yes | the server needs the same files |
| `Reports\pull.ps1`, `checkin.ps1` | yes | same script version for everyone |
| login file, `*.rep`, Builder backups (`*.rdf~`?), `*.log` | **no** – `.gitignore` | secrets, generated files |

`.gitattributes`: `*.rdf binary`, `*.xml` with a fixed line end (2.3).

### 3.2 No stash, no merge for beginners

`.rdf` is binary – Git cannot merge two changes of the same report. Rules
the scripts enforce:
- `checkin.ps1` first runs `git fetch` and compares (`git rev-list --count
  HEAD..@{u}`): **behind the remote → stop** with "run pull.ps1 first". It
  never pulls by itself into a working copy with changes.
- `pull.ps1` refuses when the working copy has uncommitted changes
  (`git status --porcelain` not empty) – "check in first" – and otherwise runs
  `git pull --ff-only`. No stash, no merge commit.
- The same report changed by two developers at the same time stays a
  conflict that a person resolves (agree who works on which report; Git LFS
  file locking would be the technical answer – later, if needed).

### 3.3 Credentials

- **Git over HTTPS:** Git for Windows brings the **Git Credential Manager** –
  the developer types user and password (or token) once, Windows keeps them
  in the credential store of the personal login. Nothing in the scripts.
- **DB login for the conversion:** one file per developer outside the
  repository, e.g. `%USERPROFILE%\.rwconv\login.txt` (`userid=...@alias`),
  readable only for the user. `checkin.ps1` asks for it once if it is
  missing (`Read-Host -AsSecureString`) and writes the file. Alias from the
  shared `tnsnames.ora` of the domain.

### 3.4 `REPORTS_PATH` per developer

Today `reports.bat` holds one `REPORTS_PATH` for all users (cookbook step
8.2: `E:\reports\src;E:\reports\images`). With one clone per user the Builder
must search the user's own clone – **decided: a copy of `rwbuilder.bat` on
the desktop sets it from `%USERNAME%` (3.5).** `reports.bat` itself stays
unchanged, so a patch or a new tools instance does not touch the per-user
part.

### 3.5 Builder start from the desktop – own `rwbuilder.bat` with `%USERNAME%`

The developer starts the Builder **only** through this file. It is a copy of
the original `%DOMAIN_HOME%\reports\bin\rwbuilder.bat` with one added line
that puts the own clone at the front of `REPORTS_PATH` – report sources and
images (the Builder finds images through `REPORTS_PATH`, see the image
article). One file for all developers, because the user comes from
`%USERNAME%`.

| Item | Value |
|---|---|
| original | `%DOMAIN_HOME%\reports\bin\rwbuilder.bat` (written by `createReportsToolsInstance`, cookbook step 7) |
| copy | `C:\Users\Public\Desktop\rwbuilder_git.bat` – the public desktop, every RDP user sees it |
| added line | `set REPORTS_PATH=E:\git\%USERNAME%\Reports\source;E:\git\%USERNAME%\Reports\images;%REPORTS_PATH%` – **after** the line that calls `reports.bat` (that file sets `REPORTS_PATH` itself) and before the call of `rwbuilder.exe` |
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
rem IHW: own Git clone first - E:\git\<Windows login>\Reports
set REPORTS_PATH=E:\git\%USERNAME%\Reports\source;E:\git\%USERNAME%\Reports\images;%REPORTS_PATH%
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
report from `E:\git\gpi\Reports\source`, preview – images with a file name
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

## 4. Flow sketch of the scripts (not written yet)

`pull.ps1`:
1. `cd` to the folder of the script (`$PSScriptRoot\..`).
2. `git status --porcelain` not empty → "You have changes – run checkin.ps1
   first", exit 1.
3. `git pull --ff-only` → on error: show the message, exit 1.
4. Show the last 5 commits (`git log --oneline -5`).

`checkin.ps1 "comment"`:
1. Comment missing → ask for it (`Read-Host`); empty → exit.
2. `git fetch`; behind the remote → "run pull.ps1 first", exit 1.
3. Changed / new `.rdf` (`git status --porcelain Reports/source`), for each:
   `rwconverter.bat ... dest=Reports\xml\<name>.xml ... cmdfile=<login>`;
   exit code ≠ 0 → show the REP lines, exit 1 (nothing committed).
4. Deleted `.rdf` → delete the matching `.xml`.
5. `git add Reports/source Reports/xml Reports/images`, `git commit -m
   "<comment>"`, `git push`.
6. Push rejected (someone pushed in between) → "run pull.ps1, then check in
   again".

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

PowerShell check (as `checkin.ps1` will run it):

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
