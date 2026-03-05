# Oracle Reports – Font Configuration Guide

Author: Gunther Pipperr | https://pipperr.de | License: Apache 2.0

> This guide explains the Oracle Reports font system on Oracle Linux 8/9
> and how to use the `04-ReportsFonts/` scripts to resolve common font problems.

---

## Lessons Learned

Five conditions must ALL be true for Oracle Reports to embed TrueType fonts in PDFs.
If any one is missing, the font falls back to Type 1 (non-embedded).

| # | Condition | How to verify | Fix |
|---|-----------|---------------|-----|
| 1 | **TTF file exists in REPORTS_FONT_DIRECTORY** | `ls $DOMAIN_HOME/reports/fonts/*.ttf` | `deploy_fonts.sh --apply` |
| 2 | **REPORTS_FONT_DIRECTORY is set in the JVM** | `cat /proc/$(pgrep -f WLS_REPORTS)/environ \| tr '\0' '\n' \| grep REPORTS` | `fontpath_config.sh --apply` + restart |
| 3 | **Font cache is current** (fontconfig) | `fc-list \| grep <fontname>` | `fc-cache -fv $DOMAIN_HOME/reports/fonts/` |
| 4 | **uifont.ali [PDF:Subset] mapping is correct** | `mfontchk <uifont.ali>` | `uifont_ali_update.sh --apply` |
| 5 | **Reports Server was restarted** after every change | `rwserver_status.sh` | `startStop.sh STOP/START WLS_REPORTS` |

**Critical syntax rule for uifont.ali `[PDF:Subset]`:**

```ini
"FontName"..  = "filename.ttf"    ← right side MUST be in quotes WITH .ttf extension
"FontName"..  = filename.ttf      ← WRONG – no quotes
"FontName"..  = "filename"        ← WRONG – no extension
```

Without the correct syntax (`"filename.ttf"` with both quotes and extension),
mfontchk may accept the file but Oracle Reports silently skips the mapping
and falls back to Type 1 PostScript — `pdffonts` then shows `emb=no`.

---

## Table of Contents

1. [The Problem in a Nutshell](#1-the-problem-in-a-nutshell)
2. [Font Model – Theory](#2-font-model--theory)
3. [Font Resolution Chain (Runtime)](#3-font-resolution-chain-runtime)
4. [uifont.ali – Format and Sections](#4-uifontalii--format-and-sections)
5. [Standard PostScript → Liberation TTF Mapping](#5-standard-postscript--liberation-ttf-mapping)
6. [Custom and Corporate Fonts](#6-custom-and-corporate-fonts)
7. [Windows-Specific Fonts on Linux](#7-windows-specific-fonts-on-linux)
8. [Key Environment Variables](#8-key-environment-variables)
9. [Scripts Reference](#9-scripts-reference)
10. [Step-by-Step Setup](#10-step-by-step-setup)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. The Problem in a Nutshell

Oracle Reports are typically **designed on Windows** using font names like `Arial`,
`Helvetica`, `Times New Roman`, or `Courier New`. On Oracle Linux, these fonts
**do not exist** by default. When the Reports engine runs on Linux and cannot find
the font, one of these problems occurs:

- Text is rendered with the wrong font → **layout breaks, text overflows cells**
- PDF contains non-embedded PostScript outlines → **printing fails or looks wrong**
- Font glyphs render as wrong characters (e.g. Latin text rendered as Greek symbols)
- Report aborts with `REP-1924: Font file cannot be found`

**The solution:**

1. Install free metric-compatible TTF replacements (**Liberation Fonts**, **DejaVu**)
2. Copy TTF files into the Reports font directory (`$DOMAIN_HOME/reports/fonts/`)
3. Map the PostScript/Windows font names to the Linux TTF filenames via `uifont.ali`
4. Set `REPORTS_FONT_DIRECTORY` and `REPORTS_ENHANCED_FONTHANDLING=yes` in the server environment
5. Verify that generated PDFs contain embedded TrueType fonts

---

## 2. Font Model – Theory

Oracle Reports on UNIX supports **two font models**:

### 2.1 New Font Model (default, recommended)

Controlled by: `REPORTS_ENHANCED_FONTHANDLING=yes` (default since Reports 12c)

- Reads TTF and TTC files directly from `REPORTS_FONT_DIRECTORY`
- Font directory: `$DOMAIN_HOME/reports/fonts/` (stable across FMW patches)
- **No AFM/TFM conversion needed**
- Correct font metrics prevent text misalignment in output
- `fc-query` is used to discover the exact internal font family names

```
$DOMAIN_HOME/
  reports/
    fonts/           ← place all TTF/TTC files here (REPORTS_FONT_DIRECTORY)
      LiberationSans-Regular.ttf
      LiberationSans-Bold.ttf
      LiberationSans-Italic.ttf
      LiberationSans-BoldItalic.ttf
      LiberationSerif-Regular.ttf
      ...
```

### 2.2 Legacy Font Model (PostScript/Motif – avoid on OL8/9)

Controlled by: `REPORTS_ENHANCED_FONTHANDLING=no`

- Uses PostScript Type 1 fonts (.afm, .pfb, .pfm files)
- Font path configured via `REPORTS_FONTPATH` in `rwserver.conf`
- PostScript Type 1 support is unreliable on Oracle Linux 8/9
- **Do not use this model for new installations**

---

## 3. Font Resolution Chain (Runtime)

When Oracle Reports needs to render a font at runtime, it follows this order:

```
Report font name (e.g. "Helvetica")
        │
        ▼
1. uifont.ali lookup
   [Global] section: alias to another name
   [PDF:Subset] section: map to TTF filename
   → Found? Use mapped TTF file directly
        │
        ▼
2. REPORTS_FONT_DIRECTORY scan (TTF/TTC files)
   → REPORTS_ENHANCED_FONTHANDLING=yes required
   → Match by font family name (exact! as reported by fc-query)
        │
        ▼
3. System font lookup (fallback)
   → Fontconfig / X11 system fonts
        │
        ▼
4. Nearest match fallback
   → Same character set, different face
   → May cause layout problems
        │
        ▼
5. No font found → REP-1924 error or Symbol/wrong-font substitution
```

**Key insight:** The `[PDF:Subset]` key must match the font name **as used in the
report design**. This name may differ from the `fc-query` family name when:
- The report was designed on Windows (different family name registration)
- The font family name contains spaces (`"Corp Font"`) but the report used the
  compact PostScript name (`"CorpFont"` without space)

`uifont_ali_update.sh` automatically detects this mismatch using `%{postscriptname}`
from `fc-query` and generates duplicate entries for both the family name and the
PostScript name.

---

## 4. uifont.ali – Format and Sections

### Location on UNIX/Linux

Oracle Reports searches for `uifont.ali` in this order:
1. Path defined by `TK_FONTALIAS` environment variable
2. Path defined by `ORACLE_FONTALIAS` environment variable
3. Default: `$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/<reptools_name>/guicommon/tk/admin/uifont.ali`
4. Fallback: `$ORACLE_HOME/guicommon/tk/admin/uifont.ali`

Use `font_inventory.sh` to find the active location on your system.

### File Format

```ini
# Comments start with # in the first column

[ Global ]
# Applies to all output types
# Syntax: "Source Name" = "Target Family Name"
"OldName"  =  "NewFamilyName"

[ Printer ]
# PostScript printer output

[ PDF:Subset ]
# TrueType font subsetting for PDF output  ← most important for PDF reports
# Syntax: "PSFontName"[qualifier]  =  "ttf-filename.ttf"
# Rule: right side is ALWAYS in double quotes AND always includes the .ttf extension.
# Example: "Tahoma".. = "DejaVuSans.ttf"
# Source: Oracle Reports 12.2.1 Font Config doc (pbr_font003#i1009745)
# Note: this quoting/extension rule applies ONLY to [PDF:Subset].
#
# qualifier placed OUTSIDE the left-side quotes for style/weight:
#   ..Italic.Bold  → Bold Italic (most specific – must come first)
#   ...Bold        → Bold
#   ..Italic       → Italic
#   ...Light       → Light
#   (empty) / ..   → Regular (least specific – must come last per family)

[ PDF:Embed ]
# Type 1 font embedding: FontName=AFM_file,PFB_file

[ Display:Motif ]
# Screen display (Oracle Reports Builder on UNIX)
```

### Syntax Rules for [PDF:Subset]

```ini
# Right side is ALWAYS in double quotes AND always includes the .ttf extension.
# This applies to all entries – with and without hyphen in the filename.
"Helvetica"..Italic.Bold                 = "LiberationSans-BoldItalic.ttf"
"Helvetica"...Bold                       = "LiberationSans-Bold.ttf"
"Helvetica"..Italic                      = "LiberationSans-Italic.ttf"
"Helvetica"..                            = "LiberationSans-Regular.ttf"

# Complete example with style/weight qualifiers (most specific first):
"Corp Font"..Italic.Bold                 = "CorpFont_BdIt.ttf"
"Corp Font"...Bold                       = "CorpFont_Bd.ttf"
"Corp Font"..Italic                      = "CorpFont_It.ttf"
"Corp Font"..                            = "CorpFont_Rg.ttf"

# PostScript alias for the same font (no-space PS name → same TTF):
"CorpFont"..Italic.Bold                  = "CorpFont_BdIt.ttf"
"CorpFont"...Bold                        = "CorpFont_Bd.ttf"
"CorpFont"..Italic                       = "CorpFont_It.ttf"
"CorpFont"..                             = "CorpFont_Rg.ttf"
```

> **Important rules:**
> - Font names with spaces MUST be in double quotes on the **left** side
> - The right side is the **TTF filename with `.ttf` extension, always in double quotes**:
>   `= "LiberationSans-Bold.ttf"` — both quotes and extension are mandatory
>   (ref: Oracle Reports 12.2.1 Font Configuration – [pbr_font003](https://docs.oracle.com/middleware/1221/formsandreports/use-reports/pbr_font003.htm#i1009745))
> - More-specific entries (BoldItalic, Bold, Italic) **must precede** less-specific (Regular) within a family
> - This quoting rule applies **only to `[PDF:Subset]`** — other sections (`[Global]`, `[Printer]`) use different syntax
> - Use `uifont_ali_update.sh` to generate correct entries automatically

---

## 5. Standard PostScript → Liberation TTF Mapping

The Liberation fonts are **metrically identical** to Microsoft's core fonts,
meaning text wrapping and page layout matches a Windows rendering exactly.

These entries are generated automatically by `uifont_ali_update.sh`:

```ini
[ PDF:Subset ]
# Right side: always "filename.ttf" with quotes and extension – [PDF:Subset] only!

# ─── Helvetica / Arial → Liberation Sans ──────────────────────────────────────
"Helvetica"..Italic.Bold                 = "LiberationSans-BoldItalic.ttf"
"Helvetica"...Bold                       = "LiberationSans-Bold.ttf"
"Helvetica"..Italic                      = "LiberationSans-Italic.ttf"
"Helvetica"..                            = "LiberationSans-Regular.ttf"
"Helvetica-Bold"                         = "LiberationSans-Bold.ttf"
"Helvetica-Oblique"                      = "LiberationSans-Italic.ttf"
"Helvetica-BoldOblique"                  = "LiberationSans-BoldItalic.ttf"
"Arial"..Italic.Bold                     = "LiberationSans-BoldItalic.ttf"
"Arial"...Bold                           = "LiberationSans-Bold.ttf"
"Arial"..Italic                          = "LiberationSans-Italic.ttf"
"Arial"..                                = "LiberationSans-Regular.ttf"
"Arial Bold"                             = "LiberationSans-Bold.ttf"
"Arial Italic"                           = "LiberationSans-Italic.ttf"
"Arial Bold Italic"                      = "LiberationSans-BoldItalic.ttf"

# ─── Times / Times New Roman → Liberation Serif ────────────────────────────────
"Times New Roman"..Italic.Bold           = "LiberationSerif-BoldItalic.ttf"
"Times New Roman"...Bold                 = "LiberationSerif-Bold.ttf"
"Times New Roman"..Italic                = "LiberationSerif-Italic.ttf"
"Times New Roman"..                      = "LiberationSerif-Regular.ttf"
"Times New Roman Bold"                   = "LiberationSerif-Bold.ttf"
"Times New Roman Italic"                 = "LiberationSerif-Italic.ttf"
"Times-Roman"                            = "LiberationSerif-Regular.ttf"
"Times-Bold"                             = "LiberationSerif-Bold.ttf"
"Times-Italic"                           = "LiberationSerif-Italic.ttf"
"Times-BoldItalic"                       = "LiberationSerif-BoldItalic.ttf"

# ─── Courier / Courier New → Liberation Mono ───────────────────────────────────
"Courier"..Italic.Bold                   = "LiberationMono-BoldItalic.ttf"
"Courier"...Bold                         = "LiberationMono-Bold.ttf"
"Courier"..Italic                        = "LiberationMono-Italic.ttf"
"Courier"..                              = "LiberationMono-Regular.ttf"
"Courier-Bold"                           = "LiberationMono-Bold.ttf"
"Courier-Oblique"                        = "LiberationMono-Italic.ttf"
"Courier-BoldOblique"                    = "LiberationMono-BoldItalic.ttf"
"Courier New"..Italic.Bold               = "LiberationMono-BoldItalic.ttf"
"Courier New"...Bold                     = "LiberationMono-Bold.ttf"
"Courier New"..Italic                    = "LiberationMono-Italic.ttf"
"Courier New"..                          = "LiberationMono-Regular.ttf"
"Courier New Bold"                       = "LiberationMono-Bold.ttf"
"Courier New Italic"                     = "LiberationMono-Italic.ttf"

# ─── Tahoma / Verdana → DejaVu Sans (approximate metric match) ─────────────────
"Tahoma"...Bold                          = "DejaVuSans-Bold.ttf"
"Tahoma"..                               = "DejaVuSans.ttf"
"Tahoma Bold"                            = "DejaVuSans-Bold.ttf"
"Verdana"...Bold                         = "DejaVuSans-Bold.ttf"
"Verdana"..                              = "DejaVuSans.ttf"
"Verdana Bold"                           = "DejaVuSans-Bold.ttf"
```

**Getting the exact TTF family names:**

```bash
fc-query --format '%{family}\n'         /path/to/Font.ttf   # family name
fc-query --format '%{style}\n'          /path/to/Font.ttf   # style (Bold, Italic …)
fc-query --format '%{postscriptname}\n' /path/to/Font.ttf   # PS name (no spaces)
```

Use `get_font_names.sh` to run this automatically for all installed fonts.

---

## 6. Custom and Corporate Fonts

Place proprietary or licensed TTF files in `custom_fonts_dir/` before running
`deploy_fonts.sh`. The script will copy them to `REPORTS_FONT_DIRECTORY` and
`uifont_ali_update.sh` will generate the correct `[PDF:Subset]` entries.

### Font name considerations

Corporate fonts often have a **family name with spaces** (as returned by `fc-query`)
but reports may have been designed using the **PostScript name without spaces**:

| fc-query `%{family}` | fc-query `%{postscriptname}` | Used in report design |
|----------------------|-----------------------------|-----------------------|
| `Corp Font`          | `CorpFont`                  | `CorpFont`            |
| `Corp Font`          | `CorpFont`                  | `Corp Font`           |

`uifont_ali_update.sh` detects this automatically and generates entries for **both**
names, so reports work regardless of which naming convention was used.

### Font style variants

For a complete font family, place all four variants in `custom_fonts_dir/`:

```
CorpFont_Rg.ttf       ← Regular
CorpFont_Bd.ttf       ← Bold
CorpFont_It.ttf       ← Italic
CorpFont_BdIt.ttf     ← Bold Italic
```

Generated uifont.ali entries (in specificity order):

```ini
# Corp Font
"Corp Font"..Italic.Bold                 = CorpFont_BdIt
"Corp Font"...Bold                       = CorpFont_Bd
"Corp Font"..Italic                      = CorpFont_It
"Corp Font"                              = CorpFont_Rg

# CorpFont  (PS-name alias → "Corp Font")
"CorpFont"..Italic.Bold                  = CorpFont_BdIt
"CorpFont"...Bold                        = CorpFont_Bd
"CorpFont"..Italic                       = CorpFont_It
"CorpFont"                               = CorpFont_Rg
```

---

## 7. Windows-Specific Fonts on Linux

### Metric-Compatible Free Replacements

| Windows Font          | Linux Replacement         | Package                     | Metric Match |
|-----------------------|---------------------------|-----------------------------|--------------|
| Arial                 | Liberation Sans           | liberation-fonts            | ✓ Exact      |
| Arial Narrow          | Liberation Sans Narrow    | liberation-fonts            | ✓ Exact      |
| Times New Roman       | Liberation Serif          | liberation-fonts            | ✓ Exact      |
| Courier New           | Liberation Mono           | liberation-fonts            | ✓ Exact      |
| Calibri               | Carlito                   | google-carlito-fonts        | ✓ Exact      |
| Cambria               | Caladea                   | google-caladea-fonts        | ✓ Exact      |
| Tahoma                | DejaVu Sans               | dejavu-sans-fonts           | ~ Close      |
| Verdana               | DejaVu Sans               | dejavu-sans-fonts           | ~ Close      |
| Georgia               | Liberation Serif          | liberation-fonts            | ~ Close      |
| Trebuchet MS          | DejaVu Sans               | dejavu-sans-fonts           | ~ Close      |
| Palatino Linotype     | Liberation Serif          | liberation-fonts            | ~ Close      |

> **DejaVu package names on RHEL / Oracle Linux** (kein `dejavu-fonts-all`):
> `dejavu-sans-fonts`, `dejavu-sans-mono-fonts`, `dejavu-serif-fonts`,
> `dejavu-lgc-sans-fonts`, `dejavu-lgc-sans-mono-fonts`, `dejavu-lgc-serif-fonts`

### Fonts Requiring the Original TTF File

| Windows Font     | Issue                            | Recommendation                               |
|------------------|----------------------------------|----------------------------------------------|
| Wingdings        | Symbol font, no free equivalent  | Include Wingdings.ttf (requires Windows license) |
| Wingdings 2/3    | Symbol font, no free equivalent  | Include from Windows                         |
| Webdings         | Symbol font, no free equivalent  | Include from Windows                         |
| Symbol           | Greek/math symbols               | Include Symbol.ttf or use FreeSerif          |
| Arial Unicode MS | Full Unicode coverage            | Use DejaVu Sans or Noto fonts                |

**Legal note:** Copying font files from Windows requires a valid Windows license.

> **Note on symbol fonts (Wingdings, Symbol):**
> If reports use Wingdings for checkmarks (✓) or arrows (→), redesigning the report
> to use Unicode characters (▶ ✓ ✗) with DejaVu Sans is the better long-term solution.

---

## 8. Key Environment Variables

| Variable                        | Value                         | Purpose                                              |
|---------------------------------|-------------------------------|------------------------------------------------------|
| `REPORTS_ENHANCED_FONTHANDLING` | `yes`                         | Enable new TTF font model – **required**             |
| `REPORTS_FONT_DIRECTORY`        | `$DOMAIN_HOME/reports/fonts`  | Directory where TTF/TTC files are placed             |
| `REPORTS_FONTPATH`              | (legacy, old model only)      | Font search path for PostScript/Motif model          |
| `TK_FONTALIAS`                  | (optional override)           | Explicit path to `uifont.ali`                        |
| `ORACLE_FONTALIAS`              | (optional override)           | Fallback path to `uifont.ali`                        |
| `NLS_LANG`                      | `GERMAN_GERMANY.UTF8` (example) | Drives character set for font selection            |

Both variables must reach the **JVM process** of the Reports Server. Use
`fontpath_config.sh --apply` to write them into `setUserOverrides.sh` as both
OS environment exports **and** JVM `-D` system properties (belt-and-suspenders
for Node Manager environments):

```bash
export REPORTS_FONT_DIRECTORY="/u01/.../reports/fonts"
export REPORTS_ENHANCED_FONTHANDLING="yes"
export JAVA_OPTIONS="${JAVA_OPTIONS} -DREPORTS_FONT_DIRECTORY=\"/u01/.../reports/fonts\""
export JAVA_OPTIONS="${JAVA_OPTIONS} -DREPORTS_ENHANCED_FONTHANDLING=yes"
```

Verify the variables are active in the running process:

```bash
cat /proc/$(pgrep -f WLS_REPORTS)/environ | tr '\0' '\n' | grep REPORTS
```

---

## 9. Scripts Reference

| Script | Purpose | Modifies |
|--------|---------|----------|
| `get_root_install_libs.sh` | Generate `dnf install` command for required OS packages | nothing (generates command) |
| `font_inventory.sh` | Show current TTF/PS fonts, uifont.ali location, font dir status | nothing |
| `get_font_names.sh` | Run `fc-query` on deployed fonts, show ready-to-paste uifont.ali entries | nothing |
| `deploy_fonts.sh` | Copy Liberation, DejaVu, and custom TTFs to `REPORTS_FONT_DIRECTORY` | font directory |
| `uifont_ali_update.sh` | Rewrite `uifont.ali` with fresh `[PDF:Subset]` section | uifont.ali |
| `fontpath_config.sh` | Set `REPORTS_FONT_DIRECTORY` + `REPORTS_ENHANCED_FONTHANDLING` in `setUserOverrides.sh` | setUserOverrides.sh |
| `pdf_font_verify.sh` | Verify PDF fonts are TrueType and embedded (`pdffonts`) | nothing |
| `font_cache_reset.sh` | Rebuild Linux fontconfig cache (`fc-cache`) after font deploy; shows restart hints | font cache |

All scripts default to **dry-run** mode. Add `--apply` to write changes.

### uifont_ali_update.sh – behaviour

- **Rewrites the entire `uifont.ali`** from scratch on each `--apply` run
- Preserves sections before the first `[PDF` header (`[Global]`, `[Printer]`, `[Display]`)
- Discards all existing `[PDF:*]` content and replaces with a fresh `[PDF:Subset]`
- Generates entries for standard fonts (Helvetica, Arial, Times, Courier, Tahoma, Verdana)
- Scans `custom_fonts_dir/` for corporate TTFs and generates qualified entries:
  `"Family"..Italic.Bold`, `"Family"...Bold`, `"Family"..Italic`, `"Family"` (Regular)
- Detects family name / PostScript name mismatch via `fc-query %{postscriptname}`
  and automatically adds alias entries for the compact PS name
- Requires: `fc-query` (fontconfig), `diff`, `cp`, `find` — **no Python3**

### fontpath_config.sh – behaviour

- Checks `REPORTS_FONT_DIRECTORY` in `setUserOverrides.sh`, `setDomainEnv.sh`, `rwserver.conf`
- Writes a managed block to `setUserOverrides.sh` (idempotent, replace-on-rerun):
  OS env exports + JAVA_OPTIONS `-D` flags for Node Manager environments
- Requires: `grep`, `cp` — **no Python3**

---

## 10. Step-by-Step Setup

Run the following scripts in sequence. All scripts default to **read-only mode**.
Use `--apply` only when ready to make changes.

```
Step 1 – Install required OS packages (run as root)
────────────────────────────────────────────────────
./04-ReportsFonts/get_root_install_libs.sh

Installs: poppler-utils (pdffonts), fontconfig (fc-query),
          liberation-fonts, liberation-fonts-common, dejavu-serif-fonts


Step 2 – Check current font situation
───────────────────────────────────────
./04-ReportsFonts/font_inventory.sh

Shows: TTF/PS fonts in FMW and system, uifont.ali location and content,
       REPORTS_FONT_DIR status


Step 3 – Copy custom/corporate fonts (if needed)
──────────────────────────────────────────────────
cp /path/to/CorpFont*.ttf ./04-ReportsFonts/custom_fonts_dir/


Step 4 – Deploy all fonts to REPORTS_FONT_DIRECTORY
─────────────────────────────────────────────────────
./04-ReportsFonts/deploy_fonts.sh           # dry-run preview
./04-ReportsFonts/deploy_fonts.sh --apply   # copy Liberation + DejaVu + custom fonts


Step 5 – Get exact TTF family and PS names (for reference)
───────────────────────────────────────────────────────────
./04-ReportsFonts/get_font_names.sh

Output: fc-query names for all fonts in REPORTS_FONT_DIR


Step 6 – Rewrite uifont.ali with correct [PDF:Subset] mappings
────────────────────────────────────────────────────────────────
./04-ReportsFonts/uifont_ali_update.sh            # preview diff
./04-ReportsFonts/uifont_ali_update.sh --apply    # rewrite file + create backup


Step 7 – Set REPORTS_FONT_DIRECTORY in setUserOverrides.sh
────────────────────────────────────────────────────────────
./04-ReportsFonts/fontpath_config.sh              # check current state
./04-ReportsFonts/fontpath_config.sh --apply      # write managed block


Step 8 – Restart the Reports Server
─────────────────────────────────────
$DOMAIN_HOME/bin/stopComponent.sh  repServer01
$DOMAIN_HOME/bin/startComponent.sh repServer01

# Verify env vars are active in the JVM process:
cat /proc/$(pgrep -f WLS_REPORTS)/environ | tr '\0' '\n' | grep REPORTS


Step 9 – Verify fonts in generated PDFs
─────────────────────────────────────────
# Generate a test PDF first, then:
./04-ReportsFonts/pdf_font_verify.sh /path/to/test.pdf

Expected: type=TrueType  emb=yes  sub=yes  for all fonts
```

---

## 11. Troubleshooting

### PDF shows Type 1 / non-embedded fonts

```
Symptom: pdf_font_verify shows Type 1 emb=no
Cause A: Reports Server not restarted after fontpath_config.sh --apply
         → REPORTS_ENHANCED_FONTHANDLING not yet active in JVM
Fix A:   Restart Reports Server, verify via /proc/<PID>/environ

Cause B: uifont.ali [PDF:Subset] mapping key does not match the font name
         used in the report design
Fix B:   Run uifont_ali_update.sh --apply (generates both family and PS-name
         entries), restart server
```

### Text renders with wrong characters (e.g. Greek glyphs instead of Latin)

```
Symptom: Letters replaced by wrong glyphs (Symbol font substitution)
Cause:   Oracle Reports fell back to Symbol font – font was not found
Fix:     1. Confirm font TTF is in REPORTS_FONT_DIRECTORY
         2. Confirm uifont.ali has correct [PDF:Subset] entry for that font name
         3. Confirm REPORTS_ENHANCED_FONTHANDLING=yes is active in JVM process
         4. Restart Reports Server
```

### Font name mismatch (PS name vs fc-query family name)

```
Symptom: mfontchk shows no error but PDF still uses Type 1
Cause:   Report uses compact PS name (e.g. "CorpFont") but uifont.ali only
         has the fc-query family name (e.g. "Corp Font" with space)
Fix:     Run uifont_ali_update.sh --apply
         → automatically adds PS-name alias entries via fc-query %{postscriptname}
```

### REPORTS_FONT_DIRECTORY not reaching the JVM

```
Symptom: env var set in shell but /proc/<PID>/environ does not show it
Cause:   setUserOverrides.sh OS export is not enough for Node Manager-started servers
Fix:     fontpath_config.sh --apply writes both:
           export REPORTS_FONT_DIRECTORY="..."
           export JAVA_OPTIONS="${JAVA_OPTIONS} -DREPORTS_FONT_DIRECTORY=..."
         Restart required after change
```

### REPORTS_FONT_DIR path mismatch

```
Symptom: deploy_fonts.sh copies to one path, REPORTS_FONT_DIRECTORY points elsewhere
Cause:   environment.conf REPORTS_FONT_DIR set to component path
         (guicommon/tk/admin/fonts) instead of stable domain path
Fix:     In environment.conf:
           REPORTS_FONT_DIR="${DOMAIN_HOME}/reports/fonts"
         Re-run fontpath_config.sh --apply + restart
```

### REP-1924: Font file cannot be found

```
Cause:  Font referenced in report not in REPORTS_FONT_DIRECTORY
Fix:    1. Add missing TTF to custom_fonts_dir/, run deploy_fonts.sh --apply
        2. Or add uifont.ali alias pointing to an available font
        3. Run uifont_ali_update.sh --apply
        4. Restart Reports Server
```

### Font appears wrong / text overflows

```
Cause:  uifont.ali alias exists but maps to wrong metric font
Fix:    Check uifont.ali – ensure the TTF on the right side (e.g. LiberationSans-Regular)
        actually exists in REPORTS_FONT_DIRECTORY
        Run: ls $DOMAIN_HOME/reports/fonts/LiberationSans-Regular.ttf
```

### Wingdings / Symbol characters show as squares (□)

```
Cause:  Wingdings/Symbol TTF not deployed; no equivalent available
Fix:    Option A – deploy original Wingdings.ttf (requires Windows license)
                   → custom_fonts_dir/ → deploy_fonts.sh --apply
        Option B – redesign report to use Unicode characters with DejaVu Sans
                   ✓ = U+2713, ✗ = U+2717, → = U+2192
```

### Symbol font appears as Type 1 (emb=no) in pdffonts output

```
Symptom: pdffonts shows:
           Symbol   Type 1   Symbol   no  no  no
         The font is not embedded – it relies on the viewer/printer having Symbol installed.

Cause:  No [PDF:Subset] mapping exists for "Symbol" in uifont.ali.
        Oracle Reports falls back to the legacy PostScript Symbol font (Type 1).

Step 1 – Identify what the report uses as "Symbol":
         strings /path/to/report.rdf | grep -i 'symbol' | sort -u
         → Look for fontName="Symbol" entries

Step 2 – Choose a TTF substitute:
         A) Arrows, checkmarks (✓ ✗ → ●) only → use DejaVuSans.ttf (already deployed)
            Add to uifont_ali_update.sh Symbol section, uncomment:
              NEW_SUBSET_LINES+=("$(_subset_line_q "Symbol" ".." "DejaVuSans")")

         B) Greek letters (α β γ) or math symbols (∑ ∫) → deploy Symbol.ttf from Windows
            cp /windows/Fonts/Symbol.ttf ./04-ReportsFonts/custom_fonts_dir/
            Run deploy_fonts.sh --apply
            Then uncomment in uifont_ali_update.sh:
              NEW_SUBSET_LINES+=("$(_subset_line_q "Symbol" ".." "Symbol")")

Step 3 – Verify the [PDF:Subset] entry uses the correct syntax:
         The mapping MUST use double quotes AND .ttf extension on the right side:
           "Symbol"..  = "DejaVuSans.ttf"      ← correct
           "Symbol"..  = DejaVuSans             ← wrong (no quotes, no extension)
           "Symbol"..  = "DejaVuSans"           ← wrong (no extension)
         Without the correct syntax, mfontchk may accept the file but Oracle Reports
         will not perform TTF substitution → Symbol stays as Type 1.

Step 4 – Run uifont_ali_update.sh --apply and restart Reports Server.
Step 5 – Verify with pdffonts: Symbol should now show TrueType emb=yes sub=yes.
```

### Enable font diagnostic logging in Oracle Reports

```bash
# In WebLogic Admin Console → Reports Server → Logging:
# Set Oracle Diagnostic Logging Level = TRACE:32 for maximum font detail

# Log files to check:
tail -f $DOMAIN_HOME/servers/WLS_REPORTS/logs/WLS_REPORTS.log
find $DOMAIN_HOME/servers -name "rwEng*diagnostic.log" | xargs tail -f
```

### Which fonts are referenced in a .rdf report definition?

Oracle Reports `.rdf` files are binary. Use `strings` to extract readable text and
grep for `fontName` attributes – this shows which fonts the report designer used
and must therefore be available on the Linux server:

```bash
# Extract all fontName values from a single report
strings Testbericht.rdf | sed -n 's/.*fontName="\([^"]*\)".*/\1/p' | sort -u

# Broader scan – catches unusual or older attribute names
strings Testbericht.rdf | grep -i 'font' | sort -u

# Scan all .rdf files in a directory at once
find ./reports/source -name "*.rdf" -exec bash -c \
  'echo "=== $(basename "$1") ==="; strings "$1" | sed -n '"'"'s/.*fontName="\([^"]*\)".*/\1/p'"'"' | sort -u' \
  _ {} \;
```

Typical output shows names like `Arial`, `Courier New`, `Times New Roman`, or
custom Windows font names like `New Courier`, `Arial Narrow`, `Tahoma`.
Every name found here must have a matching `[PDF:Subset]` entry in `uifont.ali`.

**Workflow:** Scan `.rdf` → identify all font names used → compare against
`uifont.ali` → add missing mappings with `uifont_ali_update.sh --apply`.

---

### PDF Font Embedding and Subsetting – What to Expect

**Subsetting** a TrueType font in a PDF means embedding only the specific glyphs
(characters) used in that document, not the entire font file. This reduces PDF size
and ensures consistent rendering on any device without requiring the font to be
installed on the recipient's system.

Key characteristics of a correctly subsetted PDF font:

- **Type:** `TrueType` (not `Type 1`) — Oracle Reports must use the TTF font model
- **emb=yes** — the font is embedded in the PDF
- **sub=yes** — only the used glyphs are embedded (subset), not the full font
- **Name prefix:** A 6-character random tag followed by `+` (e.g. `ABCDEF+Arial`)
  is added by the PDF generator to avoid conflicts with system fonts.
  If the recipient edits the PDF and types a character not in the original document,
  it will not display correctly — this is expected and by design.

#### Bad output (Oracle Reports without correct font configuration)

```
pdffonts testbericht.pdf
name                                 type              encoding         emb sub uni object ID
------------------------------------ ----------------- ---------------- --- --- --- ---------
Courier                              Type 1            WinAnsi          no  no  no       7  0
Companyymbol                         Type 1            WinAnsi          no  no  no       8  0
Symbol                               Type 1            Symbol           no  no  no      11  0
CompanyRg                            Type 1            WinAnsi          no  no  no      12  0
CompanyRg,Bold                       Type 1            WinAnsi          no  no  no      15  0
```

**Problems:**
- All fonts are `Type 1` — the legacy PostScript font model is active
- `emb=no` and `sub=no` — no fonts are embedded at all
- No `XXXXXX+` subset prefix — fonts are referenced by name only
- Printing on a system without these fonts will fail or produce wrong output
- Corporate fonts (`CompanyRg`) are not embedded → layout unreproducible

**Root cause:** `REPORTS_ENHANCED_FONTHANDLING=yes` not active, or `uifont.ali`
has no `[PDF:Subset]` mappings for these font names.

> **Note on `Symbol Type 1 emb=no`:** The PostScript `Symbol` font (Greek/math glyphs)
> appears as Type 1 non-embedded when no `[PDF:Subset]` mapping exists for it.
> See troubleshooting section *"Symbol font appears as Type 1"* below.

#### Good output (after correct TTF configuration)

```
pdffonts testbericht.pdf
name                                 type              encoding         emb sub uni object ID
------------------------------------ ----------------- ---------------- --- --- --- ---------
ABCDEF+LiberationMono-Regular        TrueType          WinAnsi          yes yes no       7  0
GHIJKL+Companyymbol                  TrueType          WinAnsi          yes yes no       8  0
MNOPQR+Symbol                        TrueType          Symbol           yes yes no      11  0
STUVWX+CompanyRg                     TrueType          WinAnsi          yes yes no      12  0
YZABCD+CompanyRg-Bold                TrueType          WinAnsi          yes yes no      15  0
```

**Correct indicators:**
- All fonts are `TrueType`
- `emb=yes sub=yes` for every font
- `XXXXXX+` prefix confirms proper subsetting
- Corporate fonts (`CompanyRg`) are embedded → PDF is self-contained

**Required setup to reach this state:**
1. TTF files for all fonts deployed to `REPORTS_FONT_DIRECTORY`
2. `uifont.ali` `[PDF:Subset]` has entries for every font used in the report
   — including `Symbol` if the report uses it (see below)
3. `REPORTS_ENHANCED_FONTHANDLING=yes` active in the JVM process
4. Reports Server restarted

Verify with `pdf_font_verify.sh` — it parses `pdffonts` output and flags any
`Type 1`, `emb=no`, or missing subset prefix automatically.

---

### Verify font files and fontconfig

```bash
# List all fonts known to fontconfig in REPORTS_FONT_DIR:
fc-list | grep -i "liberation"

# Get family name, style and PS name for a specific TTF:
fc-query --format '%{family} | %{style} | %{postscriptname}\n' /path/to/Font.ttf

# Refresh fontconfig cache after adding fonts:
fc-cache -fv $DOMAIN_HOME/reports/fonts/

# List all TTFs in REPORTS_FONT_DIR:
ls -la $DOMAIN_HOME/reports/fonts/*.ttf

# Validate uifont.ali with Oracle's mfontchk:
# Without REPORTS_FONT_DIR: mfontchk checks syntax only (no TTF file lookup).
export LD_LIBRARY_PATH=$ORACLE_HOME/lib:$LD_LIBRARY_PATH
mfontchk $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/reptools1/guicommon/tk/admin/uifont.ali
# → "Schriftartaliasdatei erfolgreich geparst" = syntax OK

# With REPORTS_FONT_DIR: mfontchk additionally checks that TTF files exist.
export REPORTS_FONT_DIR=$DOMAIN_HOME/reports/fonts
export REPORTS_FONT_DIRECTORY=$DOMAIN_HOME/reports/fonts
mfontchk $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/reptools1/guicommon/tk/admin/uifont.ali
# ^ on right side = TTF not found in REPORTS_FONT_DIR (deploy fonts first)
# ^ on left  side = font name syntax error in uifont.ali
# NOTE: [Global] alias targets (e.g. "= helvetica") are always flagged as
#       "Invalid font specification" because mfontchk checks OS font existence.
#       This is expected – [Global] aliases resolve at runtime, not at parse time.
#       The authoritative test is PDF generation + pdffonts output.
```

---

## References

- Oracle Reports 12c Font Usage:
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_xplat001.htm
- Oracle Reports Font Configuration:
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_font001.htm
- Oracle Reports uifont.ali – Font Config Files (12.2.1.3):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_font003.htm
- Oracle Reports uifont.ali – Font Config Files (12.2.1, with [PDF:Subset] syntax detail):
  https://docs.oracle.com/middleware/1221/formsandreports/use-reports/pbr_font003.htm#i1009745
- Oracle Reports Font Aliasing:
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_font004.htm
- Oracle Reports 11g uifont.ali [PDF:Subset] examples (with quoted filenames):
  https://docs.oracle.com/cd/E17904_01/bi.1111/b32121/pbr_pdf003.htm#RSPUB23424
- Liberation Fonts Project: https://github.com/liberationfonts/liberation-fonts
- Pipperr.de – Oracle Reports 14c Install Guide:
  https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64
