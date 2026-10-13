# Oracle Reports: Greek / Symbol Glyphs in the HTML Parameter Form

Author: Gunther Pipperr | https://pipperr.de | License: Apache 2.0

> How the HTML parameter form (and HTML output) of Oracle Reports 12c/14c on
> Oracle Linux resolves fonts, why it can render every text in the **Symbol**
> font (Latin text shown as Greek letters) while PDF output is perfectly fine,
> and how to fix it with domain-local AFM files and `ttf2reports_afm.py`.

---

## TL;DR

| Problem | Cause | Fix |
|---------|-------|-----|
| HTML parameter form shows Greek glyphs, HTML contains `<font face="symbol">` | The **screen printer** uses PPD + AFM metrics. The standard AFMs have `EncodingScheme AdobeStandardEncoding`, which does not match `NLS_LANG=...WE8MSWIN1252`. Only `Symbol` (`FontSpecific`) passes the charset check. | Copy the standard AFMs into the **domain** AFM directory and set `EncodingScheme FontSpecific` (MOS Doc ID 300416.1) |
| After that fix every text is `Courier` | Font is not in `screenprinter.ppd` or has no AFM. Reports falls back to `*DefaultFont: Courier`. **uifont.ali aliases are not applied** here. | Generate an AFM from the TTF with `ttf2reports_afm.py`, add a `*Font` line to `screenprinter.ppd` |
| PDF is fine the whole time | PDF uses `[PDF:Subset]` + TTF files from `REPORTS_FONT_DIRECTORY` (different code path) | nothing to do |

Result after the fix: `<font size="4" face="arial">` in the HTML parameter form.

---

## Table of Contents

1. [Environment and Symptom](#1-environment-and-symptom)
2. [Two Font Paths: PDF vs. HTML](#2-two-font-paths-pdf-vs-html)
3. [Root Cause Analysis](#3-root-cause-analysis)
4. [The Fix, Step by Step](#4-the-fix-step-by-step)
5. [ttf2reports_afm.py: Summary](#5-ttf2reports_afmpy-summary)
6. [Automation](#6-automation)
7. [Diagnosis Toolkit](#7-diagnosis-toolkit)
8. [What Did NOT Work](#8-what-did-not-work)
9. [Caveats and Open Points](#9-caveats-and-open-points)
10. [File Locations](#10-file-locations)
11. [References](#11-references)

---

## 1. Environment and Symptom

Observed on:

| Item | Value |
|------|-------|
| Oracle Reports | 14.1.2 (`reports_14.1.2`), standalone Reports Server `repServer01` |
| OS | Oracle Linux 9.7 |
| `NLS_LANG` | `GERMAN_GERMANY.WE8MSWIN1252` |
| `REPORTS_ENHANCED_FONTHANDLING` | `YES` |
| `REPORTS_DEFAULT_DISPLAY` | `YES` |
| `REPORTS_NO_DUMMY_PRINTER` | `TRUE` |
| `rwservlet.properties` | `<inprocess>no</inprocess>`, `<server>repServer01</server>` |

Report definition (XML), parameter form boilerplate:

```xml
<text name="PB_4" pageNumber="1" minWidowLines="1">
  <textSegment>
    <font face="Arial" size="15" bold="yes"/>
    <string><![CDATA[Geben Sie die Parameterwerte ein]]></string>
  </textSegment>
</text>
```

Generated HTML parameter form (`rwservlet?...&paramform=yes`):

```html
<font size="4" face="symbol">Geben&nbsp;Sie&nbsp;die&nbsp;Parameterwerte&nbsp;ein</font>
```

The browser renders the Symbol font, so the Latin text is shown as Greek
letters. **Every** font in the form is affected (Arial, Courier New, even the
plain PostScript name `Courier`). The PDF output of the same report is correct.

---

## 2. Two Font Paths: PDF vs. HTML

The key insight: Reports 12c/14c uses **two different font mechanisms** in
the same engine.

```
                         Report font name ("Arial")
                                   │
             ┌─────────────────────┴─────────────────────┐
             ▼                                           ▼
     PDF output (Java part)                  HTML / parameter form (TK layer)
             │                                           │
  uifont.ali [PDF:Subset]                     uiscreenprint.txt
  "Arial".. = "LiberationSans-Regular.ttf"    SCREENPRINTER:PostScript:1:...:screenprinter.ppd:
             │                                           │
  TTF from REPORTS_FONT_DIRECTORY             screenprinter.ppd  (*Font list)
             │                                           │
  embedded TrueType subset                    AFM metric file per *Font entry
             │                                           │
         ✓ works                              charset check against NLS_LANG
                                                         │
                                         no match → Symbol (FontSpecific)
                                         not in PPD/no AFM → *DefaultFont Courier
```

With `REPORTS_DEFAULT_DISPLAY=YES` the HTML formatting is done against the
**screen printer** defined in `uiscreenprint.txt` (12c and later; the 11g
equivalent was `screenprinter.ps`). That printer is a PostScript Level 1
printer, and for a PostScript printer the TK layer takes the font list from
the PPD and the metrics from AFM files. Enhanced font handling and
`REPORTS_FONT_DIRECTORY` are **not** used on this path: a `strace` of the
engine while generating the parameter form shows that not a single `.ttf`
file is opened.

---

## 3. Root Cause Analysis

### 3.1 What the engine reads (strace)

Excerpt from `strace -f -e trace=open,openat,access` on the engine while the
parameter form is generated:

```
openat(.../reptools1/guicommon/tk/admin/uifont.ali)
openat(.../reptools1/guicommon/tk/admin/uiscreenprint.txt)
openat(.../reptools1/guicommon/tk/admin/PPD/screenprinter.ppd)
access(.../reptools1/guicommon/tk/admin/AFM/Helvetica)      = -1 ENOENT
access($ORACLE_HOME/guicommon/tk/admin/AFM/Helvetica)       = 0
openat($ORACLE_HOME/guicommon/tk/admin/AFM/Helvetica)
...                                       (one lookup per *Font in the PPD)
access($ORACLE_HOME/guicommon/tk/admin/AFM/Arial)           = -1 ENOENT
openat(.../reports/cache/xxxxxxxx.htm, O_CREAT)
```

Two important observations:

1. **AFM lookup order**: the engine looks in the **domain** TK directory
   (`$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/<reptools>/guicommon/tk/admin/AFM/`)
   first and only then in `$ORACLE_HOME/guicommon/tk/admin/AFM/`. A modified
   AFM in the domain therefore overrides the Oracle Home version without
   touching the Oracle Home (patch safe).
2. **No TTF access at all** for HTML formatting.

### 3.2 Why everything becomes Symbol

```bash
grep -H '^EncodingScheme' $ORACLE_HOME/guicommon/tk/admin/AFM/{Helvetica,Courier,Symbol}
.../AFM/Helvetica:EncodingScheme AdobeStandardEncoding
.../AFM/Courier:EncodingScheme AdobeStandardEncoding
.../AFM/Symbol:EncodingScheme FontSpecific
```

The TK layer only selects fonts whose character set fits the character set of
`NLS_LANG`. `AdobeStandardEncoding` does not match `WE8MSWIN1252`, so all
standard fonts are rejected. `Symbol` declares `FontSpecific` and is accepted
as charset neutral, so it is the only candidate left. This is documented in
**MOS Doc ID 300416.1** ("Symbol Characters (Greek) Instead Of Expected
Characters Are Displayed in Reports or Reports Parameter Form", Reports
12.2.1.4 and later, Generic UNIX), Solutions #2 and #3: set the
`EncodingScheme` of the used AFM files to `FontSpecific`.

The `Tk2Motif.rgb` change from the same note is **not** required when
`REPORTS_DEFAULT_DISPLAY=YES` is set.

### 3.3 Why Arial still does not work after that: aliases are ignored

After the `FontSpecific` fix, `face="Helvetica"` in the report is rendered
correctly, but `face="Arial"` becomes `courier` (the `*DefaultFont` of
`screenprinter.ppd`; the HTML additionally wraps the text in `<tt>`).

Tests performed, all with the same result (`courier`):

- `Arial = helvetica` in `[ Global ]`
- the same mapping in `[ Printer ]` and `[ Printer:PostScript1 ]`
  (the screen printer is `PostScript:1`)
- quoted variant with style qualifier: `"Arial"...Bold = "helvetica"...Bold`
- a font name that is mapped but has **no** TTF (`MS Sans Serif = helvetica`)
- the **unmodified Oracle template** `uifont.ali`

Conclusion: for the screen printer path of the parameter form, Reports 14c
matches the font name **directly** against the PPD `*Font` list and the AFM
files. uifont.ali aliases have no effect there. A font that should appear in
the HTML parameter form must therefore exist as PPD entry **and** AFM file
under its own name.

---

## 4. The Fix, Step by Step

All steps as user `oracle` (files created as root may later be unreadable
for the engine). Set the paths first:

```bash
export ORACLE_HOME=/u01/oracle/fmw
export DOMAIN_HOME=/u01/user_projects/domains/reportPisa
export TK_ADMIN=$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/reptools1/guicommon/tk/admin
export OH_AFM=$ORACLE_HOME/guicommon/tk/admin/AFM
export FONT_DIR=$DOMAIN_HOME/reports/fonts
```

### Step 1: FontSpecific copies of the standard AFMs (fixes "Greek")

```bash
mkdir -p $TK_ADMIN/AFM
for f in $OH_AFM/Helvetica* $OH_AFM/Courier* $OH_AFM/Times*; do
  sed 's/^EncodingScheme .*/EncodingScheme FontSpecific/' "$f" > "$TK_ADMIN/AFM/$(basename "$f")"
done
grep -H '^EncodingScheme' $TK_ADMIN/AFM/*
```

The Oracle Home stays untouched. AFM files have **no file extension**; the
file name is the PostScript font name used in the PPD.

### Step 2: Generate AFMs for the TTF fonts (fixes "Courier instead of Arial")

Requires `python3-fonttools` (`dnf install python3-fonttools`, OL9 AppStream;
tested with fontTools 4.19.1). `fontforge` is **not** available for OL9, not
even in `ol9_developer_EPEL`.

```bash
for pair in arial.ttf:Arial arialbd.ttf:Arial-Bold ariali.ttf:Arial-Italic arialbi.ttf:Arial-BoldItalic; do
  python3 ttf2reports_afm.py "$FONT_DIR/${pair%%:*}" "${pair##*:}" > "$TK_ADMIN/AFM/${pair##*:}"
done

grep -E '^(FullName|Weight|ItalicAngle|CapHeight|XHeight)' $TK_ADMIN/AFM/Arial*
```

Expected for Arial: `FullName Arial Bold` (English name, not the French
"Arial Gras"), `ItalicAngle -12` for the italic variants, `CapHeight 716`,
`XHeight 519`. A `CapHeight 0` / `XHeight 0` (old OS/2 table) or a
localized `FullName` caused the AFM to be ignored in earlier attempts; the
script handles both.

### Step 3: Add the fonts to the screen printer PPD

```bash
cp -p $TK_ADMIN/PPD/screenprinter.ppd $TK_ADMIN/PPD/screenprinter.ppd.bak_$(date +%Y%m%d_%H%M%S)
```

Add after the last existing `*Font` line, in the same style as the working
standard entries:

```
*Font Arial: Standard "(001.000)" Standard ROM
*Font Arial-Bold: Standard "(001.000)" Standard ROM
*Font Arial-Italic: Standard "(001.000)" Standard ROM
*Font Arial-BoldItalic: Standard "(001.000)" Standard ROM
```

The `Standard` keyword can stay; the decisive charset information comes from
`EncodingScheme FontSpecific` in the AFM.

### Step 4: Restart the engine

The fonts are read when an engine starts. Killing the engine is enough, the
Reports Server starts a new one (`minEngine`):

```bash
pgrep -af 'RWEngine name=rwEng'
kill -TERM $(pgrep -f 'RWEngine name=rwEng-0')
```

In 14c the engine is a **Java process** (`oracle.reports.engine.RWEngine`),
not a `rwengine` binary.

### Step 5: Verify

- Open the parameter form, check the HTML source: `face="arial"` (Reports
  writes the face name in lower case), no `<tt>` around the text.
- Check umlauts (`ÄÖÜß`) and `€` in a label.
- Check that PDF output is unchanged: `pdffonts <file>.pdf` should still show
  `TrueType emb=yes sub=yes`.

---

## 5. ttf2reports_afm.py: Summary

Source of truth: `04-ReportsFonts/ttf2reports_afm.py` (do not duplicate it
here — this section only summarizes what it does so the two files cannot
drift out of sync).

**Core logic** (`generate_afm()`): reads a TTF via fontTools, builds an AFM
with character codes 32..255 mapped through `--encoding` (default `cp1252`,
must match the Reports environment's `NLS_LANG` charset), metrics scaled to
1000 units/em, English (Windows en-US) name records for `FullName`/
`FamilyName`, `CapHeight`/`XHeight` from `OS/2` or glyph bounds as fallback,
and always `EncodingScheme FontSpecific` (bypasses the `NLS_LANG` charset
check that rejects `AdobeStandardEncoding` fonts — see MOS Doc ID 300416.1).

**CLI** (`argparse`, backward-compatible with the original 2-positional-arg
call):

```
python3 ttf2reports_afm.py <font.ttf> <AFM-Name> [--encoding ENC] [-o FILE]
python3 ttf2reports_afm.py --check <afm-file>
```

- `--encoding` (default `cp1252`): must match `NLS_LANG`, e.g. `iso8859-15`
  for `WE8ISO8859P15` — not meaningful for `AL32UTF8`, see section 9.
- `-o/--output`: write to a file instead of stdout (default stdout, keeps
  shell-loop composability).
- `--check <afm-file>`: parses an existing AFM as plain text (no fontTools
  needed) and flags the defects known to make Reports silently reject it:
  `CapHeight`/`XHeight` of `0`, `EncodingScheme` other than `FontSpecific`,
  a `FontName` that doesn't match the AFM file's own name, and (best-effort,
  non-ASCII only) a localized `FullName`. Exit 0 if clean, 1 otherwise —
  this is what `paramform_afm_setup.sh` gates on after each generation.

Requires: `python3-fonttools` (OL9 AppStream) — generation only; `--check`
has no extra dependency.

### How the generated AFM looks

```
StartFontMetrics 2.0
Comment Generated by ttf2reports_afm.py from arialbd.ttf
FontName Arial-Bold
FullName Arial Bold
FamilyName Arial
Weight Bold
ItalicAngle 0
IsFixedPitch false
FontBBox -628 -376 2000 1010
UnderlinePosition -106
UnderlineThickness 105
Version ...
EncodingScheme FontSpecific
CapHeight 716
XHeight 519
Ascender 728
Descender -210
StartCharMetrics 218
C 32 ; WX 278 ; N space ; B 0 0 0 0 ;
...
EndCharMetrics
EndFontMetrics
```

### Design decisions

| Decision | Reason |
|----------|--------|
| Codes 32..255 from cp1252 | With `FontSpecific` Reports passes the bytes of the `WE8MSWIN1252` text 1:1. The AFM code must therefore be the cp1252 byte, so umlauts and `€` (0x80) get correct widths. |
| `EncodingScheme FontSpecific` | Skips the charset check against `NLS_LANG` that rejects `AdobeStandardEncoding` fonts. |
| Scaling to 1000 units/em | AFM convention; TTFs usually use 2048 units/em. |
| English name records only | A TTF contains name records in many languages; taking the last one produced `FullName Arial Gras`. |
| CapHeight / XHeight fallback | Older TTFs (OS/2 version < 2) have no `sCapHeight` / `sxHeight`; a value of `0` made the AFM unusable. |
| Output to stdout | Keeps the script composable in shell loops and deploy scripts. |

---

## 6. Automation

Implemented as `04-ReportsFonts/paramform_afm_setup.sh` — integrated into the
module's existing workflow (dry-run by default, `--apply` to write, same
`environment.conf`/`IHateWeblogic_lib.sh` conventions as every other script
here; see the README section 9 "behaviour" entry for the full description).
It automates exactly the three manual steps from section 4:

- **Step A**: `FontSpecific` copies of the standard PostScript AFMs
  (`Helvetica*`/`Courier*`/`Times*`) from the Oracle Home AFM directory into
  the domain-local AFM directory
- **Step B**: generates an AFM for every TTF in `REPORTS_FONT_DIR` (keys
  derived from `fc-query`, not hardcoded) via `ttf2reports_afm.py`, then
  runs `--check` on each one
- **Step C**: idempotent `*Font <key>` line insertion into
  `screenprinter.ppd`, with a single backup per run

Plus an optional `--scan-reports <dir>` that lists the `face="..."` fonts
used in XML report sources and flags any with no PPD/AFM entry — this
replaces the standalone `grep` one-liner this section used to show:

```bash
./04-ReportsFonts/paramform_afm_setup.sh --scan-reports /u01/reports/source
```

---

## 7. Diagnosis Toolkit

### Check the environment of the engine, not only of the server

```bash
EPID=$(pgrep -f 'RWEngine name=rwEng-0')
tr '\0' '\n' < /proc/$EPID/environ | grep -E 'REPORTS_|NLS_LANG|TK_' | sort
```

The engine has no `envId` in `rwserver.conf` by default and inherits the
environment of `rwserver`.

### strace the engine start without breaking the server

Fonts are read when the engine starts. Attach to the **running** `rwserver`
with `-f` and let it spawn a new engine:

```bash
RWPID=$(pgrep -f 'rwserver server=repServer01' | head -1)
strace -f -e trace=open,openat,access -o /tmp/rw_eng.txt -p $RWPID &
kill -TERM $(pgrep -f 'RWEngine name=rwEng-0')
# call the parameter form in the browser, then detach:
kill -INT %1

grep -iE 'uiscreenprint|uifont|\.ppd|/AFM/|\.ttf' /tmp/rw_eng.txt \
  | awk -F'"' '{ st = ($0 ~ /ENOENT/) ? "MISSING" : "ok"; print st, $2 }' | sort -u
```

> **Warning:** Do not start `rwserver.sh` in the foreground under strace and
> then start the server normally again. The first instance stays registered
> and the second start fails with `REP-56040: Server repserver01 already
> exists in the network`; `rwservlet` reports `REP-51002: Bind to Reports
> Server failed`. Check with `$DOMAIN_HOME/reports/bin/rwdiag.sh -findAll`
> and kill leftovers before restarting.

### Quick tests that isolate the problem

| Test in the report | Result | Meaning |
|--------------------|--------|---------|
| `face="Helvetica"` | `symbol` | encoding problem (Step 1 missing) |
| `face="Helvetica"` | `helvetica` | Step 1 ok |
| `face="Arial"` | `courier` | Arial has no PPD entry or AFM (Steps 2/3) |
| `face="MS Sans Serif"` with alias to helvetica | `courier` | confirms that aliases are not applied on this path |

---

## 8. What Did NOT Work

| Attempt | Result |
|---------|--------|
| Commenting out `Arial = helvetica` in `[Global]` | no change, still `symbol` |
| `[Display]` mapping `"Courier New" = CourierNew` | no effect (target not in PPD, no AFM) |
| Charset alias `.....WE8MSWIN1252 = .....WE8ISO8859P1` | no effect |
| Adding `*Font Arial...` to the PPD without AFM | ignored, still `courier` |
| Alias mappings in `[Global]`, `[Printer]`, `[Printer:PostScript1]` | ignored by the parameter form |
| Unmodified Oracle template `uifont.ali` | still `courier` for Arial |
| Looking for `screenprinter.ps` | 11g only; 12c+ uses `uiscreenprint.txt` |
| `fontforge` for AFM generation | not packaged for OL9 (not in AppStream, not in `ol9_developer_EPEL`) |
| First AFM version with `FullName Arial Gras`, `CapHeight 0` | AFM not accepted |

---

## 9. Caveats and Open Points

- **FontSpecific disables charset conversion** for these fonts on the
  screen printer path. That is exactly what we want for `WE8MSWIN1252`,
  because the AFM codes are cp1252. For a different `NLS_LANG` (for example
  `AL32UTF8` or `WE8ISO8859P15`), `ttf2reports_afm.py --encoding <enc>` now
  lets the code table be swapped without editing the script — but which
  encoding value is actually correct for each `NLS_LANG` is still
  **unverified**, see test plan below.
- **Font names with spaces** (`Courier New`, `Times New Roman`) are not yet
  verified. PPD option keywords cannot contain spaces. To be tested: PPD key
  `CourierNew-Bold` with `FamilyName Courier New` in the AFM, versus using
  the PostScript name in the report.
- **Not verified** whether the HTML **report body** (`desformat=html`,
  `htmlcss`) takes exactly the same path; very likely, because it is the same
  screen printer.
- **Field widths** in the parameter form are calculated from the AFM metrics.
  With correct Arial AFMs this matches the browser rendering; with the
  `Courier` fallback the layout is noticeably wider.
- **Patches / domain rebuild** can replace `screenprinter.ppd`. Keep the
  backup, and put the steps into the deployment scripts.
- Related to PDF, not to this issue: if a `[PDF:Subset]` entry like
  `"Symbol".. = "DejaVuSans.ttf"` was added as a workaround for "Greek PDF"
  symptoms, re-check with `pdffonts` whether it is still needed.

### Pragmatic alternative

If AFM generation is not possible, the visual result in the browser can be
fixed with CSS in the **Before Form Value** of the parameter form
(`beforeFormValue`), because CSS overrides the `face` attribute of `<font>`:

```html
<style>
  body, td, font, tt, b { font-family: Arial, Helvetica, sans-serif !important; }
</style>
```

The internal layout metrics then still come from the fallback font. Step 1
(FontSpecific) is required in any case to get rid of the Symbol glyphs.

### Open test plan (not yet executed — no live Reports Server on the dev host)

Each test: set up the precondition, run `paramform_afm_setup.sh --apply`
(or the specific manual step noted), reload the parameter form in the
browser, fill in **Actual** and **Pass/Fail**.

**Test 1 — Font name with a space, matched via PPD key**

| | |
|---|---|
| Precondition | Deploy a TTF whose `fc-query` family is e.g. `Corp Font` (contains a space); report design references it as `"Corp Font"` |
| Steps | 1. `paramform_afm_setup.sh --apply` generates AFM key `CorpFont` (spaces stripped per section 6) and `FamilyName Corp Font` inside the AFM, plus `*Font CorpFont:` in the PPD<br>2. Open the parameter form in the browser |
| Expected | Reports resolves `"Corp Font"` to the `CorpFont` AFM via `FamilyName`, not via the PPD key directly — confirm which field TK actually matches on |
| Actual | _(fill in)_ |
| Pass/Fail | _(fill in)_ |

**Test 2 — Font name with a space, matched via PostScript name**

| | |
|---|---|
| Precondition | Same TTF as Test 1, but report design references the compact PS name `"CorpFont"` (no space) instead |
| Steps | Same as Test 1 |
| Expected | Also resolves correctly, since PPD key and report reference now match exactly (no space involved on either side) |
| Actual | _(fill in)_ |
| Pass/Fail | _(fill in)_ |

**Test 3 — HTML report body (desformat=html/htmlcss) vs. parameter form**

| | |
|---|---|
| Precondition | A font with a known-good AFM/PPD entry (e.g. the Arial fix from section 4) |
| Steps | 1. Run the report with `desformat=html` (or `htmlcss`) and inspect the font in the generated report body<br>2. Open the same report's parameter form and compare |
| Expected | Both use the same screen-printer AFM/PPD path (per the section 2 diagram) — if the report body differs, the "two font paths" model in this document is incomplete and needs a third path documented |
| Actual | _(fill in)_ |
| Pass/Fail | _(fill in)_ |

**Test 4 — `--encoding` for `AL32UTF8`**

| | |
|---|---|
| Precondition | `NLS_LANG` set to an `AL32UTF8` (UTF-8) variant on the Reports Server |
| Steps | 1. Generate an AFM with the default `--encoding cp1252` and compare rendering of non-ASCII characters (umlauts, `€`) in the parameter form<br>2. Repeat with `--encoding utf-8` (or another Python codec that matches byte-for-byte what the engine actually sends) |
| Expected | Exactly one encoding value renders non-ASCII characters correctly; document the winning value here once confirmed — UTF-8 is multi-byte, so a 1-byte-per-code AFM model may not map cleanly at all, which would mean `AL32UTF8` needs a documented limitation rather than a working `--encoding` value |
| Actual | _(fill in)_ |
| Pass/Fail | _(fill in)_ |

**Test 5 — `--encoding` for `WE8ISO8859P15`**

| | |
|---|---|
| Precondition | `NLS_LANG` set to `WE8ISO8859P15` |
| Steps | Generate an AFM with `--encoding iso8859-15` and compare rendering of `€` and the Western European accented characters covered by ISO 8859-15 but not cp1252 |
| Expected | Correct rendering of the ISO-8859-15-specific characters (`€`, `Š`, `š`, `Ž`, `ž`, `Œ`, `œ`, `Ÿ`) that differ from cp1252's layout |
| Actual | _(fill in)_ |
| Pass/Fail | _(fill in)_ |

---

## 10. File Locations

| File | Location (12c/14c domain) | Purpose |
|------|---------------------------|---------|
| `uifont.ali` | `$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/<reptools>/guicommon/tk/admin/` | font aliases, `[PDF:Subset]` |
| `uiscreenprint.txt` | same directory | defines `SCREENPRINTER:PostScript:1:...:screenprinter.ppd:` |
| `uiprint.txt` | same directory | real printers (here only `Not A Printer`) |
| `screenprinter.ppd` | `.../tk/admin/PPD/` | `*Font` list and `*DefaultFont: Courier` of the screen printer |
| AFM (domain, read first) | `.../tk/admin/AFM/` | create this directory; overrides the Oracle Home AFMs |
| AFM (Oracle Home) | `$ORACLE_HOME/guicommon/tk/admin/AFM/` | the 35 standard PostScript fonts, do not modify |
| `rwserver.conf` | `$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<server>/` | engine definition |
| `rwservlet.properties` | `$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/` | in-process vs. standalone server |
| Engine logs | `find $DOMAIN_HOME -name 'rwEng*diagnostic*.log'` | |

---

## 11. References

- MOS Doc ID 300416.1: Symbol Characters ("Greek") Instead Of Expected
  Characters Are Displayed in Reports or Reports Parameter Form
- MOS Doc ID 1321509.1: How to Change the Default Font for a Parameter Form
- MOS Doc ID 2988373.1: Oracle Reports 12c: How to Troubleshoot a Fonts Issue
  When Report PDF Output Shows Symbol / Greek Font (Unix Specific)
- MOS KB117127: Troubleshooting Guide for Font Aliasing / Font Subsetting /
  Font Embedding Issues (section "Problems related to the Character Set")
- MOS KB83026: How to Use TTF Fonts for Font Metrics On Unix With Reports
- Oracle Reports documentation, NLS chapter: "Repairing Garbled Fonts When
  Using the WE8ISO8859P15 Character Set"
  https://docs.oracle.com/html/B14048_02/pbr_nls.htm
- Oracle Reports Font Configuration Files (uifont.ali):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_font003.htm
- fontTools: https://github.com/fonttools/fonttools
- Adobe Font Metrics File Format Specification (AFM 4.1), Adobe Technical Note #5004
- See also `README.md` in this directory for the PDF font setup.
