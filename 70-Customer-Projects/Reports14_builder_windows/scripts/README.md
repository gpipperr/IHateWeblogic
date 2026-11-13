---
nav_title: "Scripts (English)"
title: "Oracle Reports Development with Git – the Developer Workflow"
description: "Daily workflow of Oracle Reports developers with Git on Windows: menu, pull, check-in, status and release to production with a prod tag."
permalink: /70-Customer-Projects/Reports14_builder_windows/scripts/
---

# Reports development with Git – the workflow

> German version for the developers at the customer:
> [README_DE.md](README_DE.md). The scripts print German messages – the
> screen examples below are shown as they appear, the tables explain them.

These scripts connect the Oracle Reports Builder with a Git repository.
Every developer works in an own copy (clone) under
`E:\git\<your login>\oracle-report`, gets the latest state before starting
and checks finished reports in again. On check-in every report is also
stored as a readable XML file – so the Git server shows *what* changed.

You need no Git commands for this – the scripts do it.

## The workflow at a glance

```
  START OF WORK
        |
        v
  +-------------------------------+
  | 1. pull.ps1                   |   get the latest state from the Git server
  +-------------------------------+   (your own changes are kept)
        |
        v
  +-------------------------------+
  | 2. start the Reports Builder  |   desktop shortcut "Reports Builder (Git)"
  +-------------------------------+   (with administrator rights)
        |
        v
  +-------------------------------+
  | 3. open the report, change,   |   reports are in source\*.rdf,
  |    save and close it          |   images in images\
  +-------------------------------+
        |
        |   (at any time in between:  status.ps1 - what is open?)
        v
  +-------------------------------+
  | 4. checkin.ps1                |   a) newer state on the server? -> get it first
  |                               |   b) list of the changed files:
  |                               |      number / a (all) / x (cancel)
  |                               |   c) comment: what and why
  |                               |   d) convert report .rdf -> .xml
  |                               |   e) check in (every report on its own)
  |                               |      and upload
  +-------------------------------+
        |
        v
  GIT SERVER (main)  -->  automatically to DEV
        |                 (colleagues get it with pull.ps1)
        v
  +-------------------------------+
  | 5. release_tag.ps1            |   tested on DEV? set the prod tag
  +-------------------------------+   --> production
```

## Layout of the repository

```
  E:\git\<your login>\oracle-report\    (your copy of the repository)
    menu.cmd, menu.ps1, menu.ini        menu for a double click
    README.md
    deploy\                             all scripts (pull.ps1, checkin.ps1, ...)
    source\                             reports (.rdf) - opened by the Builder
    xml\                                XML of every report (written by checkin.ps1)
    images\                             images of the reports
```

Only `source\*.rdf` and `images\*` go to production.

## One-time set-up (per user)

1. **Git for Windows** is installed (ask the administrator).
2. **Get the repository** – in a PowerShell window:

   ```powershell
   git clone https://<git-server>/<group>/oracle-report.git E:\git\$env:USERNAME\oracle-report
   ```

   If your Git login is an LDAP account with a name different from your
   Windows login, it goes into the address:
   `https://<ldap-login>@<git-server>/...` (Git asks for the password once
   and remembers it).
3. **Set name and e-mail** – once:

   ```powershell
   cd E:\git\$env:USERNAME\oracle-report
   .\deploy\git_setup.ps1
   ```

4. **DB login for the XML conversion** – a file with one line
   `userid=<db user>/<password>@<tns alias>`, either personal in
   `%USERPROFILE%\.rwconv\login.txt` or at the fixed place your
   administrator entered in [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1). The file is never in
   the repository.
5. **Desktop shortcut "Reports Builder (Git)"** – set up by the
   administrator; it starts the Builder with your Git folders as search
   path (`REPORTS_PATH`).
6. **Desktop icon for the menu** – once:
   - right-click `E:\git\<your login>\oracle-report\menu.cmd` → *Send to*
     → *Desktop (create shortcut)*.
   - shortcut → *Properties* → *Advanced* → tick **"Run as
     administrator"** ([`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) needs it).

## Without typing: the menu

A double click on the desktop icon opens the menu:

```
============================================================
 Oracle Reports Git Handling
============================================================

 1 - pull.ps1              - Hole die letzten Änderungen vom Git-Server
 2 - status.ps1            - Zeige den aktuellen Status an
 3 - status_detail.ps1     - Liste der letzten Check-ins mit Tag und Stand in Produktion
 4 - checkin.ps1           - Bericht einchecken und nach DEV verteilen
 5 - release_tag.ps1 -List - Zeige, was noch nicht in Produktion ist
 6 - release_tag.ps1       - Release-Tag setzen - Bericht in Produktion einspielen

 c = Bildschirm loeschen und Menue neu anzeigen   x / q = beenden
------------------------------------------------------------

Wähle eine Option oder breche mit x / q ab :
```

(The texts come from [`menu.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ini) – German at the customer: get the
latest changes, show the status, list of the last check-ins with tag and
production state, check in a report and deploy to DEV, show what is not in
production yet, set the release tag.)

- Enter a number: a short explanation, then the script runs **in the same
  window**. Afterwards the menu appears **again right below** – the output
  of the script stays above it (scroll up). The next step is simply the
  next number.
- `c` = clear the screen and show the menu again (when it gets confusing
  after several scripts).
- `x` or `q` = quit, the window closes.
- Only if a script was cancelled with Ctrl+C and the menu is gone:
  **`m` + Enter** starts it again in the same window.
- What the menu shows (order, texts, parameters) is set in
  [`menu.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ini) – changes there are made by the Git contact person.
- The scripts are in `deploy\`, the menu in the top folder – `menu.ini`
  says so with `SkriptPfad = deploy`. Another place: change `SkriptPfad`,
  for all in `[Menue]` or per entry, relative (`deploy`, `..`) or absolute
  with `%VARIABLE%` (`E:\git\%USERNAME%\oracle-report\deploy`).
  [`menu.cmd`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.cmd), [`menu.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ps1) and `menu.ini` always stay together in one folder.
- The window size (60 lines) is set at the top of `menu.cmd` (`ZEILEN`,
  `SPALTEN`). In Windows Terminal (Windows 11) its own setting applies.

The scripts can still be started directly in a PowerShell window, as
described below.

## Step by step

### 1. Start of work: `pull.ps1`

Start PowerShell **as administrator** (right-click → "Run as
administrator") – [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) needs it later, so one window does
everything. Then:

```powershell
cd E:\git\$env:USERNAME\oracle-report
.\deploy\pull.ps1
```

The script gets the check-ins of the colleagues and shows the last five.
Your own changes that are not checked in yet are kept. If a colleague
changed exactly the report you are working on, it stops – **nothing is
overwritten**. Then ask the Git contact person.

### 2. Start the Reports Builder

Via the desktop shortcut **"Reports Builder (Git)"**. Always open reports
from `E:\git\<your login>\oracle-report\source\` and save them there – not
from other folders.

### 3. Work

Change the report, **save and close** it. New images go to `images\`.
Agree who works on which report – Git cannot merge two people working on
the same report (`.rdf` is a binary file).

### 4. In between: `status.ps1` (display only)

```powershell
.\deploy\status.ps1
```

Shows, without changing anything:

- which files you changed but have not checked in yet,
- check-ins saved on your PC but not on the Git server yet,
- check-ins on the Git server that you do not have yet,
- the last 5 check-ins – on your PC and on the Git server.

At the end it says which script is next.

More details on the last check-ins – one line per file, with tag and the
state in production:

```powershell
.\deploy\status_detail.ps1        # the last 20 check-ins
.\deploy\status_detail.ps1 50     # the last 50
```

```
|Datum           |Commit ID|Datei            |Tag                                     |Prod |
|----------------|---------|-----------------|----------------------------------------|-----|
|2026-11-12 17:08|1c28588  |source/kunde.rdf |NO_TAG                                  |offen|
|2026-11-12 17:08|f7c434c  |source/umsatz.rdf|prod-2026-11-12_1708_umsatz.rdf         |PROD |
|2026-11-12 17:08|f7c434c  |xml/umsatz.xml   |  Freigabe Produktion: umsatz.rdf -     |-    |
|                |         |                 |  Umsatz Spalte                         |     |
|2026-11-12 17:07|52819c1  |source/umsatz.rdf|NO_TAG                                  |alt  |
|2026-11-12 17:07|52819c1  |xml/umsatz.xml   |                                        |-    |

Offen fuer die Produktion (in dieser Liste): 1 Datei(en) - kunde.rdf
```

(Columns: date, commit ID, file, tag, production state.)

- **Tag:** the tag of the check-in, `NO_TAG` without a tag. If the tag has
  a message (`git tag -a`), it is shown indented in the line below, long
  messages wrapped – so the table stays narrow.
- **Prod:**

  | Prod | Meaning |
  |---|---|
  | `PROD` | exactly this version is in production |
  | `offen` (open) | waits for the release: the file was **never** in production (e.g. a new report) **or** this version is **newer** than the one in production. Several open versions of a file: normally the newest is released – it becomes `PROD`, the older open ones become `alt` |
  | `alt` (old) | an older version – production has another one |
  | `-` | does not go to production (`.xml`, scripts, docs, deleted files) |

- Below: which files **of this list** are still open – only the check-ins
  shown; older open ones only with a larger number
  (`status_detail.ps1 50`). Then a short legend of the Prod column.
- The name of the release script is shown only when it is entered at the
  top of the script in `$ReleaseSkript` (default: empty – every customer
  has an own one, e.g. `release_tag.ps1`).
- Tags and state are those of the last [`pull.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1) – the script gets
  nothing from the Git server. If it reports "production has newer
  versions than your state": run `pull.ps1` first.

Only certain files – part of the file name is enough, case does not
matter (with umlauts the case must match):

```powershell
.\deploy\status_detail.ps1 -File umsatz       # the last 20 check-ins with 'umsatz' in the file name
.\deploy\status_detail.ps1 5 -File umsatz     # only the last 5
```

### 5. Done: `checkin.ps1`

```powershell
.\deploy\checkin.ps1
```

```
Geaenderte Dateien:
    1  geaendert  source/umsatz.rdf
    2  neu        source/kunden.rdf
    3  neu        images/logo.png

Welche Datei einchecken? Nummer (nur diese), a (alle) oder x (abbrechen): 1

Ausgewaehlt: geaendert  source/umsatz.rdf
Kommentar fuer diesen Check-in (was und warum): Spalte Rabatt ergaenzt
Wandle source/umsatz.rdf -> xml/umsatz.xml
...
Check-in: Spalte Rabatt ergaenzt (umsatz.rdf)
...
OK - eingecheckt (1 Check-in(s)): Spalte Rabatt ergaenzt
Die Pipeline in GitLab verteilt die Berichte jetzt auf DEV (Build -> Pipelines).
```

(Changed files – changed / new; which file to check in: number, a = all,
x = cancel; comment: what and why; converts the report to XML; checked in;
the GitLab pipeline now deploys the reports to DEV.)

**Only the selection** is checked in – the other files stay and can be
checked in later. A report always comes with its XML file, which the
script creates itself; never change XML files by hand.

## After the check-in: DEV and production

There is only the branch **`main`**. Every report is checked in **on its
own** – [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) does this itself, also with the selection `a`
(one check-in per report, with its XML file).

- **DEV:** every upload deploys the changed reports automatically to the
  Linux **DEV** Reports server – normally exactly the checked-in report.
  You test it there via `rwservlet`. The result is shown in GitLab under
  **Build → Pipelines** (green or red).
- **Production:** a **`prod-` tag** on the check-in of the report starts
  the deployment to production – exactly this check-in, nothing else.

```
  report tested on DEV
        |
        v
  +----------------------------------+
  | .\deploy\release_tag.ps1         |   a) list: not in production yet
  |                                  |   b) choose the number of the check-in
  |                                  |   c) tag message (Enter = proposal)
  |                                  |   d) set the tag prod-<date>_<report>
  +----------------------------------+      and send it to the Git server
        |
        v
  GitLab: pipeline of the tag  -->  PRODUCTION
          (only the report of this check-in, all others stay as they are)
```

### Release: `release_tag.ps1`

```powershell
.\deploy\release_tag.ps1                  # show, then choose a number (Enter = nothing)
.\deploy\release_tag.ps1 -List            # show only – no question, no tag
.\deploy\release_tag.ps1 -File umsatz     # only files with 'umsatz' in the name
.\deploy\release_tag.ps1 -Filter ''       # all files instead of only .rdf
```

1. **Not in production yet:** the check-ins on the Git server that are
   newer than the state of the report in production – numbered, newest
   first, with files and one list per file. In production is the check-in
   with the most recently set `prod-` tag of the report.
2. **Last check-ins:** the last 20 check-ins by date, newest first – every
   file with the tag of its check-in, `NO_TAG` without a tag:

   ```
   Datum             Commit   Datei              Tag
   2026-11-12 17:08  1c28588  source/kunde.rdf   NO_TAG
   2026-11-12 17:08  f7c434c  source/umsatz.rdf  prod-2026-11-12_1708_umsatz.rdf
   ```

   Then the **last 20 releases**, sorted by tag (newest first) – per tag
   only the files of its check-in:

   ```
   Datum             Tag                              Commit   Datei              Freigeber
   2026-11-12 17:08  prod-2026-11-12_1708_umsatz.rdf  f7c434c  source/umsatz.rdf  gpi
   2026-11-12 17:08  prod-2026-11-12_1708_lager.rdf   70b578b  source/lager.rdf   gpi
   ```

   (Columns: date, tag, commit, file, released by.)
3. **Release:** enter a number from part 1 – or a **commit ID** from
   part 2, also an older check-in → tag with a message on exactly this
   check-in, e.g. `prod-2026-11-12_1430_umsatz.rdf`, sent to the Git server
   → the pipeline deploys the report to production. Newer check-ins do
   **not** go along.

- Released is the state on the **Git server**: first check in and upload
  the report with [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1), test it on DEV, then
  [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1).
- Default: only `.rdf` files. `-Filter '*.png'` shows e.g. only images –
  an image also goes to production this way, with a tag of its own.
- A tag releases **only its check-in**. Older check-ins of other reports
  stay where they are.

| Message of [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) | What to do |
|---|---|
| `ACHTUNG : Es gibt N neuere(n) Check-in(s) dieser Datei(en)` (there are N newer check-ins of this file) | you chose an older version, the newer ones do not go along – cancel with `n` and choose the newer one (unless you deliberately want to go back to the older one) |
| `Der Check-in hat N Dateien - alle gehen in die Produktion` (the check-in has N files – all go to production) | an old check-in with several files – tag it only if all of them should go to production |
| `Alles freigegeben - keine offenen Check-ins` (everything released) | nothing to do |
| pipeline red: `the tag is on a merge commit` | the tag is on a merge – ask the Git contact person (delete the tag, tag the right check-in) |

**Back to an older version:** in `release_tag.ps1` enter the commit ID of
the older check-in from part 2 (or `-Commit <id>`), confirm the ACHTUNG
message with `j` (yes) – it gets a new tag and goes to production again;
the newer check-ins are then listed as open again.

## The selection at check-in

| Input | Meaning |
|---|---|
| number | check in only this one file (a report with its XML file; the report name is added in brackets after the comment) |
| `a` | check in all changed files – each as a check-in of its own (same comment, file name in brackets after it) |
| `n` | check in nothing new, only upload check-ins that are saved on your PC but not on the Git server yet (e.g. after a failed upload). Offered only when there are such check-ins. |
| `x` or Enter | cancel – nothing is checked in |

For a report (`.rdf`) `checkin.ps1` always appends the file name in
brackets to the comment – "Spalte Rabatt ergaenzt (umsatz.rdf)". So
GitLab shows in the list of check-ins which report it was. If the name is
already in the comment, it is not added a second time.

An empty comment cancels as well.

## When a message appears

| Message | Meaning | What to do |
|---|---|---|
| `PowerShell mit 'Als Administrator ausfuehren' starten` | the Reports tools need administrator rights | close PowerShell, start it again with right-click "Run as administrator" |
| `DB-Login-Datei nicht gefunden` | the file for the XML conversion is missing | set it up as in the set-up, point 4 |
| `Wandlung von ... fehlgeschlagen` with a `REP-` message | the report cannot be converted (error in the report or wrong DB login) | open and compile the report in the Builder, check the login file – nothing was checked in |
| `rwconverter hat keine Meldung geliefert` | the conversion gave no result | as above |
| `Ein Kollege hat denselben Bericht geaendert` | you and a colleague changed the same report | nothing was overwritten – save the report, ask the Git contact person |
| `Ihr Check-in ist lokal gespeichert, aber NICHT auf dem Git-Server` | the upload failed (network, server, colleague at the same time) | run [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) again later – `n` only uploads |
| `Ungueltige Auswahl` | the input was no valid number | start the script again |

## The scripts

| Script | When |
|---|---|
| [`menu.cmd`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.cmd) / [`menu.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ps1) | menu for a double click (desktop icon): choose a script, it runs in the same window, then the menu comes back (`c` = clear the screen, `x` / `q` = quit); content from [`menu.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ini) |
| [`git_setup.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/git_setup.ps1) | once per user: name, e-mail, line ends |
| [`pull.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1) | at the start of work: get the latest state |
| [`status.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status.ps1) | at any time: what is open – locally and on the Git server (changes nothing) |
| [`status_detail.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status_detail.ps1) | list of the last 20 check-ins: date, commit ID, file, tag, Prod (`PROD` / `offen` / `alt`) – one line per file (changes nothing) |
| [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) | check in reports: selection, comment, conversion to XML, upload |
| [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1) | called by [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1); on its own: `.\deploy\convert_rdf.ps1 umsatz` converts `source\umsatz.rdf` to `xml\umsatz.xml` |
| [`checkin_only.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin_only.ps1) | like [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1), but without the Reports part – for a PC without the Reports Builder |
| [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) | release a tested report to production: shows open check-ins and the last `prod-` tags, sets the tag – the pipeline then deploys to production; default only `.rdf`, `-Filter` changes that; `-List` = show only |

## Rules

- There is only the branch `main` ([`status.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status.ps1) warns otherwise).
- Every report is a check-in of its own – [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) does this itself.
- [`pull.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1) before the work, `checkin.ps1` afterwards – if possible on the same day.
- To production only via a `prod-` tag with [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) – never copy by hand.
- One report – one person at a time (agree on it).
- XML files are created only by the script.
- Passwords never in files in the repository and never in a comment.
- No `git stash`, no merging by hand – if in doubt, ask the Git contact
  person.

Technical background: [`Git_checkin.md`](../Git_checkin.md) and
[`Git_deploy.md`](../Git_deploy.md) in the IHateWeblogic project, folder
`70-Customer-Projects/Reports14_builder_windows`.
