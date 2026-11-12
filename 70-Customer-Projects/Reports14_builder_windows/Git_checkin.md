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
        |  2. edit in the Builder E:\git\%USERNAME%\Reports\source\*.rdf
        |  3. checkin.ps1 "comment"
        |        a) fetch: behind the remote? -> fast-forward first
        |        b) list of changed files -> number (only this one), a (all)
        |           or n (nothing new, only send unsent check-ins)
        |        c) selected .rdf -> convert_rdf.ps1 (rwconverter) -> Reports\xml\<name>.xml
        |        d) git add + commit only the selection ; push
        v
 Git server (HTTPS) --> later: automation to the Linux DEV Reports server
```

| Item | Value |
|---|---|
| clone per developer | `E:\git\%USERNAME%` – the folder name = the Windows login, e.g. `E:\git\gpi` for the user `gpi` |
| report sources | `E:\git\%USERNAME%\Reports\source\*.rdf` |
| images | `E:\git\%USERNAME%\Reports\images\` (file names in lower case, see the image article) |
| XML of every report | `E:\git\%USERNAME%\Reports\xml\<name>.xml` – written by `checkin.ps1`, never by hand |
| scripts | `E:\git\%USERNAME%\Reports\pull.ps1`, `...\checkin.ps1`, `...\convert_rdf.ps1`, `...\git_setup.ps1` (part of the repository, so every clone has the same version; `git_setup.ps1` once per user before the first check-in) |
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
| `logfile=<file>` (2026-11-12) | **not usable:** `REP-34551 Feature LOGFILE is deprecated`; the file holds only "Converting … to …" and "Conversion … canceled" – **no `REP-` messages** (they go to the console only); with a wrong login the converter suddenly asks "Enter Password:" despite `batch=yes` and waited for input (hung until the timeout), the log file is not even created | `convert_rdf.ps1` does not use it – it redirects stdout / stderr itself and checks that the XML was written |
| several reports in one call | `source=(a.rdf,b.rdf) dest=(xml/a.xml,xml/b.xml)` works, exit code 0 – **but** the `name=` of the second file was the internal report name, not the file name | one call per report (0.5 s each is cheap) – stable names |

The XML contains the queries and the layout, **no login data** (checked:
neither user nor password of the conversion login in the file).

### 2.3 Open on Windows

- `rwconverter.bat` runs from PowerShell in the RDP session of a developer
  who is a local admin – in an elevated window ("Run as administrator");
  check whether it also works without elevation (UAC) – expected no, as for
  the Builder.
- Exit code arrives in PowerShell – expected 0 / 1 as on Linux.
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
| `Reports\source\*.rdf` | yes (binary) | the file the Builder and the server use |
| `Reports\xml\*.xml` | yes | readable diff, review, restore; written only by `checkin.ps1` |
| `Reports\images\*` | yes | the server needs the same files |
| `Reports\pull.ps1`, `checkin.ps1` | yes | same script version for everyone |
| login file, `*.rep`, Builder backups (`*.rdf~`?), `*.log` | **no** – `.gitignore` | secrets, generated files |

`.gitattributes`: `*.rdf binary`, `*.xml` with a fixed line end (2.3).

### 3.2 No stash, no merge for beginners

`.rdf` is binary – Git cannot merge two changes of the same report
(`*.rdf binary` in `.gitattributes`, template in `scripts/`). Rules the
scripts follow:
- **Only fast-forward, never stash.** `git pull --ff-only` also works with
  own uncommitted changes – Git updates the other files and **aborts by
  itself** ("would be overwritten") when an incoming change touches a file
  the developer changed too. Nothing is overwritten, nothing is stashed.
  The first sketch ("pull.ps1 refuses with local changes, checkin.ps1 stops
  when behind") was dropped – it was a dead end: a developer with changes
  and a newer server could neither pull nor check in.
- `checkin.ps1` runs `git fetch` before converting: behind the server →
  fast-forward first; the same report changed by a colleague → stop.
- **One file or all (2026-11-12):** `checkin.ps1` lists the changed files of
  `source\` and `images\` (new / changed / deleted) with numbers – a number
  checks in only that file (plus its `.xml`), `a` checks in all, `n` checks
  in nothing new and only sends check-ins still waiting locally. Only the
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
  script runs `git merge --abort`: the check-in stays local, the working copy
  is unchanged, the developer asks the Git contact person.
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

## 4. The scripts

Files in [scripts/](https://github.com/gpipperr/IHateWeblogic/tree/main/70-Customer-Projects/Reports14_builder_windows/scripts) – a skeleton for the customer's own
adaptation: plain PowerShell, one step after the other, no nested commands,
**messages and comments in German** (the developers' language), plain ASCII
(Windows PowerShell 5.1 reads files without BOM as ANSI). Copy them into
`E:\git\<repo>\Reports\` of the repository (one level below the top folder
– the scripts find the top folder through `$PSScriptRoot`).

| File | Purpose |
|---|---|
| [pull.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1) | at the start of the work: shows own uncommitted changes (they stay), `git pull --ff-only`, the last 5 check-ins |
| [git_setup.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/git_setup.ps1) | once per Windows user: asks name, e-mail address and `core.autocrlf` (`true` / `input` / `false`, proposal `true`; Enter keeps the shown value), sets them with `git config --global`, shows the result |
| [convert_rdf.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1) | one report `.rdf` → `.xml` with `rwconverter` (`cmdfile=` login file – no password on the command line); output of the converter captured with `Start-Process` (stdout / stderr into temp files, `REP-` / `ORA-` lines shown); success = exit code 0 **and** XML written now; `-Check` = only the checks (admin session, converter, login file). Only the report name: `.\convert_rdf.ps1 bericht` → `source\bericht.rdf` → `xml\bericht.xml` (folders fixed next to the script; always `<name>.xml`, because rwconverter takes the internal report name from the destination file name). Called by `checkin.ps1`, also usable alone |
| [checkin.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) | `.\checkin.ps1 "comment"`: checks (`convert_rdf.ps1 -Check`) → `git fetch` (behind → fast-forward; same report changed → stop) → numbered list of the changed files in source / images, **number = only this file, `a` = all, `n` = nothing new, only send** → comment → convert the selected new / changed `.rdf` with `convert_rdf.ps1` (stop at the first error, nothing committed) → delete the `.xml` of a selected deleted `.rdf` → `git add` + commit **only the selection** → push (rejected → `pull --no-rebase` + push; conflict → `merge --abort`) |
| [template.gitattributes](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/template.gitattributes) | `*.rdf binary`, line ends of `*.xml` (value after the Windows test, 2.3) |
| [template.gitignore](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/template.gitignore) | `*.rep`, logs, backups, `login.txt` |

Settings at the top of `convert_rdf.ps1`: `$DomainHome` (default
`E:\oracle\user_projects\domains\rwbuilder_domain`, the environment variable
`DOMAIN_HOME` wins), the login file `%USERPROFILE%\.rwconv\login.txt`, the
variable `RWCONVERTER` replaces the converter – for tests only. At the top
of `checkin.ps1`: the three folders `Reports/source`, `Reports/xml`,
`Reports/images`.

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
| `n` without unsent check-ins / with 1 unsent check-in | "nichts zu senden", exit 0 / only pushed, "OK - an den Git-Server gesendet" |
| converter moved to `convert_rdf.ps1` | broken report: `REP-1430` from `convert_rdf.ps1`, nothing committed, exit 1; login file missing: message from `-Check` before the list; alone without arguments: usage, exit 1; alone with the report name (`b1`, `b1.rdf` or a path): `xml\b1.xml` written, exit 0; unknown name: "Bericht nicht gefunden", exit 1 |
| `convert_rdf.ps1` with the **real** `rwconverter.sh` 14.1.2 (2026-11-12) | success: XML written, exit 0 (also a second run); broken file: `REP-0110` / `REP-1070` shown, exit 1; wrong login: 3× `REP-0501` + `REP-0309` shown, no hang, exit 1 |
| converter without any output (exit 1, or exit 0 without writing the XML) | "rwconverter hat keine Meldung geliefert …", exit 1 – a missing XML is caught even with exit code 0 |
| `git_setup.ps1` (isolated `HOME`) | first run sets the 3 values; Enter keeps them; `input` changes only `core.autocrlf`; invalid e-mail / value: message, nothing changed |
| colleague pushes during the check-in, **another changed report not selected** | `pull --rebase` would refuse ("unstaged changes") – merge works, the not selected change stays, exit 0 |
| same, colleague changed exactly **that not selected report** | Git: "would be overwritten" before any change, check-in local, the own edit unchanged, exit 1 |
| nothing new, 1 unsent check-in | only pushed |
| login file missing | clear message with the line format, exit 1 |
| both scripts | parse without errors (PowerShell parser), plain ASCII |

Not covered by the scripts (on purpose, kept simple): Git LFS / locking,
several branches, a pre-check that the Builder has saved and closed the
report.

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
