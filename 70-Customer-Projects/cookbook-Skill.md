# Skill: writing a customer cookbook (Kochbuch)

How a step-by-step guide for a customer system is written - the style of
[Reports14_Only_manuall_install/Patch_Kochbuch_CPU_Okt2026_de.txt](Reports14_Only_manuall_install/Patch_Kochbuch_CPU_Okt2026_de.txt),
reworked at the customer on 2026-11-03 because dense command blocks were
"too complicated" to type along with.

The rules apply to every cookbook, whatever the language of the text
(German, English) and whatever the shell (bash, PowerShell, cmd).

**Reader:** an administrator who knows the system but not our scripts. They
type every command by hand or by copy & paste, often in a screen-sharing
session with someone looking over their shoulder. They must always see
three things: where they are, what the command does, and whether the
result is right.

**Guiding principle:** rather more steps, each of them simple, than few
clever ones.

---

## 1. File layout

```
==========================================================  header block
  Title, cycle / version
  Zielgruppe / Audience, Umgebung / Environment, Erstellt / Created,
  Grundlage / Sources, Wichtig / Important
==========================================================

TARGET STATE        table: component - target - step
PREREQUISITES       what has to be in place before the maintenance window,
                    folder tree "what ends up where", rules for the whole run

=====================================================
STEP 0: Check the variables  (in EVERY terminal, as oracle)
=====================================================
  ...
  ---------------------------------------------------
  6.1 Do I need this step?
  ---------------------------------------------------
  ...

ROLLBACK            table: what - how
KNOWN PROBLEMS      Problem: / Cause: / Solution: - points back to the step
```

- **Step 0 always sets and checks the variables.** It is repeated in every new
  terminal and after every `su` / `sudo`.
- **Every step header names the user and the state of the system.** Examples:
  "(as oracle, system may still run)", "(as root)".
- **A long step is split into numbered sub-steps** (6.1 ... 6.8), each with a
  short title that is a question or an action:
  - "Do I need this step?"
  - "Remember the starting point"
  - "Switch over"
  - "Back, if something does not start"
- **Optional parts go at the end of the step,** as an "Appendix 12.F". They
  do not go in the middle of the main path. A customer who does not need them
  must not have to read them.
- **Plain text, 80 columns, two spaces of indentation.** Banners are made of
  `=` (step) or `-` (sub-step).
- **ASCII only:** write ae/oe/ue/ss instead of umlauts, and `-` instead of
  typographic dashes. Reasons:
  - the file survives every terminal, editor and copy path;
  - PowerShell 5.1 reads BOM-less files as ANSI;
  - WLST/Jython rejects non-ASCII.

## 2. Commands - the core rules

### 2.1 One command per line, blank line after it

```
  cd $STAGE/39600348

  $ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./ -invPtrLoc $INV_PTR
  # Expected: Prereq "checkConflictAgainstOHWithDetail" passed.

  $ORACLE_HOME/OPatch/opatch apply -silent -invPtrLoc $INV_PTR 2>&1 | tee $LOGDIR/12_reports_qpr.txt
  # Expected: "Patch 39600348 successfully applied."

  cd $STAGE
```

- **Put a blank line BEFORE and AFTER every command.** The command stands on
  its own, so the eye finds it immediately.
- **The comment that explains a command goes directly UNDER it,** with no
  blank line in between. That covers `# Expected:`, `# Check:` and decisions.
  Command and its explanation form one block.
- **A multi-line unit stays one block:** a `\` continuation, a loop, an
  `if`, a heredoc.
- **The formatter** for bash cookbooks is
  `python3 -I tools/cookbook_blank_lines.py <file.txt>`. It only adds blank
  lines. PowerShell and cmd cookbooks are formatted by hand.

### 2.2 Do not nest - use intermediate steps

A command that needs explaining is too long. Split it into named
intermediate results, each on its own line, each one visible:

Bad (one line, three nested substitutions, nothing to check):

```
  ln -sfn $(dirname $JDK_HOME)/$(tar -tzf $(ls $STAGE/jdk-21*.tar.gz) | head -1 | cut -d/ -f1) $JDK_HOME
```

Good (one idea per line, the result is shown before it is used):

```
  JDK_BASE=$(dirname "$JDK_HOME")

  TGZ=$(ls $STAGE/jdk-21*_linux-x64_bin.tar.gz)

  NEWJDK=$JDK_BASE/$(tar -tzf "$TGZ" | head -1 | cut -d/ -f1)

  echo "new JDK: $NEWJDK"
  # Expected e.g.: /u01/oracle/java/jdk-21.0.13.0.2

  ln -sfn "$NEWJDK" "$JDK_HOME"
```

- **Allowed:** at most ONE `$( ... )` per line, and at most one pipe to
  filter the output (`| grep`, `| head -1`, `| tee`).
- **Avoid `&&` / `||` chains and `;`.** A decision belongs to the reader (see
  2.4), not hidden in a chain. Exception: a one-line guard where both
  branches are obvious, e.g.
  `touch "$D/.test" && rm "$D/.test" && echo "write access OK"`.
- **Use a loop only when it saves a lot of repetition** (8 identical patches).
  Then keep it simple: one action per line in the body and a visible
  `echo "== $P"`. For two or three items, write the commands out instead.
- **Use subshells / `( unset ... )` only where the product demands it**
  (OPatch napply). Then add one comment line saying why.

### 2.3 Variables instead of typed values

- **Paths and versions are derived,** never typed in:
  - `dirname`, `readlink -f`, the name inside the archive;
  - a version number typed by the customer is the most common error.
- **Show every variable before it is used** (`echo "JDK_HOME=$JDK_HOME"`) and
  say what an empty value means: "EMPTY? -> first STEP 0".
- **Empty variables are dangerous:**
  - `grep -E "$A|$B"` with an empty `$A` matches everything;
  - `rm -rf $DIR/` with an empty `$DIR` deletes `/`.

  For deletions use `"${DIR:?}"`, or show the path first and delete in a
  separate step.
- **Persist what is needed later in a file** under `$LOGDIR`, not only in a
  shell variable. A new terminal, a `su` or the next day loses the variable.
  Example: `echo "$OLDJDK" > $LOGDIR/06_oldjdk.txt`. The rollback then
  works anywhere: `ln -sfn "$(cat $LOGDIR/06_oldjdk.txt)" "$JDK_HOME"`.
- **One script or file sets all variables** (`patch_env.sh` /
  `patch_env.ps1`). Without the script, show the same values as `export`
  lines, one per line.

### 2.4 Expected output and decisions

- **After every command that changes something or decides something,** add
  `# Expected:` with the real text of the output (copied from the test run,
  shortened with `...`).
- **"Expected: no output" is a statement too,** and it must be written down.
- **Decisions are written as a table in comments:**

```
  $ORACLE_HOME/OPatch/opatch lspatches | grep -E "39600348|38827528"
  # "39600348;..." shown        -> done, continue with STEP 13
  # only "38827528;..." (old)   -> 12.2
  # no line                     -> 12.3
```

- **STOP points in capitals,** with the action: "failed": do NOT continue -
  save the output, report it.
- **Name known harmless warnings** where they appear ("KNOWN AND HARMLESS:
  ..."). Otherwise the customer stops at a warning that is fine.
- **A success message is not proof.** Add a check command after it
  (`opatch lspatches | grep <nr>` after "OPatch succeeded").

### 2.5 Output into the log

- **Every relevant output** goes with `| tee $LOGDIR/<step>_<what>.txt` into
  the step log. The step number comes first, so the files sort in run order.
- **The before/after files** (`02_lspatches_before.txt` /
  `13_lspatches_after.txt`) are the customer's evidence. Do not delete them
  at clean-up.

### 2.6 Safety

- **Back up before every change:**
  - `cp -p <file> <file>.bak`;
  - for an archive: `tar` of the home;
  - in addition, a VM snapshot through the responsible team.
- **The old version stays in place** (JDK next to JDK, link switch).
  Switching back is ONE command and is written in the step.
- **No passwords in commands, files or logs.** Use placeholders
  `<IDENTIFIER_PASSWORD>`, or let the tool ask for it hidden.
- **No customer names, hosts or IPs in a committed cookbook.** Use
  generic examples such as `reportrpgpi`, `fr_domain` and `<host>`.

### 2.7 Input for another tool (WLST, SQL*Plus, vi)

- **Commands typed INSIDE a tool are not shell commands.** Mark the block
  and indent it four more spaces:

```
  $WLST

  # --- in WLST eingeben ---

      connect(url='t3://localhost:7001')

      listCred(map='reports.idstore', key='embeddedldap')
      # Erwartet: "User Name : cn=Admin"

      exit()

  # --- Ende WLST ---
```

- **The same rules apply inside the block:** one call per line, a blank
  line between calls, `# Erwartet:` under the call.
- **Long arguments go into variables first** (`rw_role = '...'`). Use names
  WLST does not use itself (WLST namespace shadowing).
- **For vi, write the keystrokes as a comment,** e.g. `/<\/serviceInstances>`,
  `k`, `:r <file>`. Generate the text to insert beforehand with a heredoc
  that fills in the variables. The customer then pastes nothing by hand.
- **Ask for passwords hidden** with `read -s -p "...: " PW`, then a bare
  `echo` for the line break. In WLST and in files use a placeholder
  `<NAME_KENNWORT>`.

## 3. Language and shell independence

The structure is the same everywhere; only the syntax changes.

| Rule | bash | PowerShell | cmd |
|---|---|---|---|
| comment / Expected | `# Expected: ...` | `# Expected: ...` | `REM Expected: ...` |
| set a variable | `X=$(...)` / `export X=...` | `$X = ...` / `$env:X = '...'` | `set X=...` |
| show it | `echo "X=$X"` | `"X=$X"` or `Write-Host "X=$X"` | `echo X=%X%` |
| empty check | `echo "X=$X"` + "EMPTY? -> step 0" | `if (-not $env:X) { 'EMPTY -> step 0' }` | `if "%X%"=="" echo EMPTY` |
| filter | `\| grep` | `\| Select-String` | `\| findstr` |
| log | `\| tee $LOGDIR/x.txt` | `\| Tee-Object $env:LOGDIR\x.txt` | `> %LOGDIR%\x.txt` then `type` |
| switch | `ln -sfn` | `cmd /c rmdir <link>` + `cmd /c mklink /J <link> <target>` (never `Remove-Item -Recurse` on a junction - PS 5.1 deletes the target content) | `rmdir <link>` + `mklink /J <link> <target>` |
| variables file | `. patch_env.sh` | `. .\patch_env.ps1` | `call patch_env.cmd` |

- **PowerShell:**
  - prefer cmdlets with clear names over aliases (`Get-ChildItem`, not `gci`);
  - one pipeline per line;
  - no PowerShell 7-only syntax (`??`, `?.`, `&&`), so it runs on 5.1;
  - the call must work without changing the machine policy:
    `powershell -ExecutionPolicy Bypass -File ...`.
- **cmd:** use it only where needed (`mklink`, `.cmd` scripts of the
  product); everything else in PowerShell.
- **Text language:** follows the customer. Commands, file names and quoted
  product output stay in the original. "Expected:" may be translated
  ("Erwartet:"), the quoted text may not.
- **The file name says the language:**
  - `*_Kochbuch_de.txt` for German;
  - `*_cookbook_en.txt` for English;
  - Windows cookbooks name the platform: `*_Windows_Kochbuch_de.txt`.

## 4. Checklist before handing it over

1. **Every step is tested once** on the test host (or in an isolated copy).
   The `# Expected:` lines come from that run.
2. **Every command stands alone,** with a blank line before and after it
   (bash: run the formatter).
3. **No line has more than one `$( ... )`,** and there are no `&&` chains
   with consequences.
4. **Every value used later comes from a variable** or a file under
   `$LOGDIR`, never typed.
5. **Step 0 sets and checks all variables.** Every step names its user.
6. **Every change has its way back,** in the step and in the ROLLBACK table.
7. **ASCII check:** `grep -nP '[^\x00-\x7F]' <file>` gives no output.
8. **Customer-data scan before the commit** (no real names, hosts, IPs,
   passwords).

## 5. Asking Claude for a cookbook

Prompt pattern:

> Write a cookbook for <task> on <environment>, following
> `70-Customer-Projects/cookbook-Skill.md`. Language <de/en>, shell
> <bash/PowerShell/cmd>. Sources: <docs / scripts>. Test it on the test host
> and put the real output into the "Expected" lines.

Examples:
- [Reports14_Only_manuall_install/](Reports14_Only_manuall_install/)
  (bash, German);
- [Reports14_ReportBuilder_MS_Windows/](Reports14_ReportBuilder_MS_Windows/)
  (Windows, German);
- tools: [tools/README.md](tools/README.md).
