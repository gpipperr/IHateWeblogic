# Oracle Reports – Font Configuration Guide

Author: Gunther Pipperr | https://pipperr.de | License: Apache 2.0

> This guide explains the Oracle Reports font system on Oracle Linux 8/9
> and how to use the `04-ReportsFonts/` scripts to resolve common font problems.

---

## Table of Contents

1. [The Problem in a Nutshell](#1-the-problem-in-a-nutshell)
2. [Font Model – Theory](#2-font-model--theory)
3. [Font Resolution Chain (Runtime)](#3-font-resolution-chain-runtime)
4. [uifont.ali – Format and Sections](#4-uifontalii--format-and-sections)
5. [Standard PostScript → Liberation TTF Mapping](#5-standard-postscript--liberation-ttf-mapping)
6. [Windows-Specific Fonts on Linux](#6-windows-specific-fonts-on-linux)
7. [Key Environment Variables](#7-key-environment-variables)
8. [Step-by-Step Setup with Scripts](#8-step-by-step-setup-with-scripts)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. The Problem in a Nutshell

Oracle Reports are typically **designed on Windows** using font names like `Arial`,
`Helvetica`, `Times New Roman`, or `Courier New`. On Oracle Linux, these fonts
**do not exist** by default. When the Reports engine runs on Linux and cannot find
the font, one of these problems occurs:

- Text is rendered with the wrong font → **layout breaks, text overflows cells**
- PDF contains non-embedded PostScript outlines → **printing fails or looks wrong**
- Report aborts with `REP-1924: Font file cannot be found`

**The solution:**

1. Install free metric-compatible TTF replacements (**Liberation Fonts**, **DejaVu**)
2. Copy TTF files into the Reports font directory (`$DOMAIN_HOME/reports/fonts/`)
3. Map the PostScript/Windows font names to the Linux TTF names via `uifont.ali`
4. Verify that generated PDFs contain embedded TrueType fonts

---

## 2. Font Model – Theory

Oracle Reports on UNIX supports **two font models**:

### 2.1 New Font Model (default, recommended)

Controlled by: `REPORTS_ENHANCED_FONTHANDLING=yes` (default since Reports 12c)

- Reads TTF and TTC files directly from `REPORTS_FONT_DIRECTORY`
- Default font directory: `$DOMAIN_HOME/reports/fonts/`
- **No AFM/TFM conversion needed**
- Correct font metrics prevent text misalignment in output
- `fc-query` is used to discover the exact internal font family names

```
$DOMAIN_HOME/
  reports/
    fonts/           ← place all TTF/TTC files here
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
- AFM files go into: `$ORACLE_HOME/guicommon/tk/admin/AFM/`
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
1. uifont.ali lookup (font alias mapping)
   → Found? Use mapped font name instead
        │
        ▼
2. REPORTS_FONT_DIRECTORY scan (TTF/TTC files)
   → REPORTS_ENHANCED_FONTHANDLING=yes
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
5. No font found → REP-1924 error or substitution with wrong metrics
```

**Key insight:** Step 1 (uifont.ali) happens BEFORE font file lookup.
If `Helvetica` is aliased to `Liberation Sans` in uifont.ali, Oracle Reports
looks for a font named `Liberation Sans` in the font directory – not `Helvetica`.
The TTF file's **internal family name** (from fc-query) must match exactly.

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
# Comment out lines rather than deleting them (for rollback)
#
# Syntax:
#   "Source Font Name" = "Target Font Name"
#   Face.Size.Style.Weight.Width.CharSet = Face.Size.Style.Weight.Width.CharSet
#   (...) dots mean "match any value" for that attribute

[ Global ]
# Applies to all output types

[ Printer ]
# PostScript printer output

[ Printer:PostScript2 ]
# PostScript Level 2 printer output

[ PDF:Subset ]
# TrueType font subsetting for PDF output  ← most important for PDF reports
# The TTF font name here must EXACTLY match what fc-query reports

[ PDF:Embed ]
# Type 1 font embedding: FontName=AFM_file,PFB_file

[ Display:Motif ]
# Screen display (Oracle Reports Builder on UNIX)

[ RWBUILDER ]
# Web Source view and PL/SQL editor in Oracle Reports Builder
```

### Syntax Rules

```ini
# Simple name alias (preserves size, style, weight, width, charset):
"Helvetica" = "Liberation Sans"

# Full attribute mapping:
# Face.Size.Style.Weight.Width.CharSet = Face.Size.Style.Weight.Width.CharSet
# (.) means "match any / keep current"
"Arial"...WE8ISO8859P1 = "Liberation Sans"...WE8ISO8859P1

# Style values: Plain=0, Italic=1, Oblique=2, Underline=4
# Weight values: Light=3, Medium=5, Demibold=6, Bold=7
# Combine styles with + : Italic+Underline = 5

# Wildcards – match any attribute with (.)
Arial..... = "Liberation Sans"
```

> **Important:** Font names with spaces MUST be in double quotes.
> The font name after `=` must exactly match the `fc-query` output.
> Use `get_font_names.sh` to generate correct entries.

> **Do NOT use** weight name `Regular` – it is not supported and causes errors.

---

## 5. Standard PostScript → Liberation TTF Mapping

These are the PostScript font names built into Oracle Reports and their
free metric-compatible replacements from the Liberation font family.

The Liberation fonts are **metrically identical** to Microsoft's core fonts,
meaning text wrapping and page layout will match a Windows rendering exactly.

### [PDF:Subset] section – complete standard mapping

```ini
[ PDF:Subset ]

# ─── Helvetica → Liberation Sans ──────────────────────────────────────────────
"Helvetica"              = "Liberation Sans"
"Helvetica-Bold"         = "Liberation Sans Bold"
"Helvetica-Oblique"      = "Liberation Sans Italic"
"Helvetica-BoldOblique"  = "Liberation Sans Bold Italic"

# ─── Times → Liberation Serif ──────────────────────────────────────────────────
"Times-Roman"            = "Liberation Serif"
"Times-Bold"             = "Liberation Serif Bold"
"Times-Italic"           = "Liberation Serif Italic"
"Times-BoldItalic"       = "Liberation Serif Bold Italic"

# ─── Courier → Liberation Mono ─────────────────────────────────────────────────
"Courier"                = "Liberation Mono"
"Courier-Bold"           = "Liberation Mono Bold"
"Courier-Oblique"        = "Liberation Mono Italic"
"Courier-BoldOblique"    = "Liberation Mono Bold Italic"

# ─── Arial → Liberation Sans (Windows-design-time names) ───────────────────────
"Arial"                  = "Liberation Sans"
"Arial Bold"             = "Liberation Sans Bold"
"Arial Italic"           = "Liberation Sans Italic"
"Arial Bold Italic"      = "Liberation Sans Bold Italic"

# ─── Times New Roman → Liberation Serif (Windows-design-time names) ────────────
"Times New Roman"        = "Liberation Serif"
"Times New Roman Bold"   = "Liberation Serif Bold"
"Times New Roman Italic" = "Liberation Serif Italic"

# ─── Courier New → Liberation Mono (Windows-design-time names) ─────────────────
"Courier New"            = "Liberation Mono"
"Courier New Bold"       = "Liberation Mono Bold"
"Courier New Italic"     = "Liberation Mono Italic"
```

**Getting the exact TTF family names:**

The names above (`Liberation Sans`, `Liberation Sans Bold`, etc.) are the
internal font family names as reported by `fc-query`. Always verify on your
system before updating `uifont.ali`:

```bash
fc-query --format '%{family}\n' /usr/share/fonts/liberation-fonts/LiberationSans-Regular.ttf
# Output: Liberation Sans

fc-query --format '%{family}\n' /usr/share/fonts/liberation-fonts/LiberationSans-Bold.ttf
# Output: Liberation Sans Bold   ← note: Bold is part of the family name!
```

Use `get_font_names.sh` to run this automatically for all installed fonts.

---

## 6. Windows-Specific Fonts on Linux

When reports are designed on Windows using non-standard or Microsoft-licensed fonts,
additional steps are required. The table below shows recommended replacements and
whether they require special handling.

### Metric-Compatible Free Replacements

| Windows Font          | Linux Replacement         | Package                     | Metric Match |
|-----------------------|---------------------------|-----------------------------|--------------|
| Arial                 | Liberation Sans           | liberation-fonts            | ✓ Exact      |
| Arial Narrow          | Liberation Sans Narrow    | liberation-fonts            | ✓ Exact      |
| Times New Roman       | Liberation Serif          | liberation-fonts            | ✓ Exact      |
| Courier New           | Liberation Mono           | liberation-fonts            | ✓ Exact      |
| Calibri               | Carlito                   | google-carlito-fonts        | ✓ Exact      |
| Cambria               | Caladea                   | google-caladea-fonts        | ✓ Exact      |
| Tahoma                | DejaVu Sans               | dejavu-fonts-all            | ~ Close      |
| Verdana               | DejaVu Sans               | dejavu-fonts-all            | ~ Close      |
| Georgia               | Liberation Serif          | liberation-fonts            | ~ Close      |
| Comic Sans MS         | Humor Sans / Titillium    | google-fonts-*              | ✗ Different  |
| Impact                | Liberation Sans Bold      | liberation-fonts            | ✗ Different  |
| Trebuchet MS          | DejaVu Sans               | dejavu-fonts-all            | ~ Close      |
| Palatino Linotype     | Liberation Serif          | liberation-fonts            | ~ Close      |

### Fonts Requiring the Original TTF File

These fonts have no free metric-compatible replacement.
You must obtain the original TTF from a licensed Windows installation and
place it in `custom_fonts_dir/` before running `deploy_fonts.sh`.

| Windows Font   | Issue                                     | Recommendation                          |
|----------------|-------------------------------------------|-----------------------------------------|
| Wingdings      | Symbol font, no free equivalent           | Include Wingdings.ttf from Windows      |
| Wingdings 2/3  | Symbol font, no free equivalent           | Include from Windows                    |
| Webdings       | Symbol font, no free equivalent           | Include from Windows                    |
| Symbol         | Greek/math symbols                        | Include Symbol.ttf or use FreeSerif     |
| Marlett        | UI symbols (should not appear in reports) | Avoid in report designs                 |
| Arial Unicode MS | Full Unicode coverage                  | Use DejaVu Sans or Noto fonts           |

**Legal note:** Copying font files from Windows requires a valid Windows license.
These fonts may be redistributed only under that license.

### Installing Microsoft Core Fonts (Alternative)

On Oracle Linux 8/9, the `msttcore-fonts` package provides the most common
Microsoft fonts (Arial, Times New Roman, Courier New, Verdana, Georgia, etc.)
without requiring a Windows license for basic usage:

```bash
# Check if available in your repos:
dnf search msttcore 2>/dev/null || dnf search msttcorefonts 2>/dev/null

# Alternative: install via cabextract from SourceForge
# (See: https://mscorefonts2.sourceforge.net/)
```

### uifont.ali entries for additional Windows fonts

```ini
[ PDF:Subset ]

# ─── Calibri / Cambria (if Carlito/Caladea installed) ──────────────────────────
"Calibri"               = "Carlito"
"Calibri Bold"          = "Carlito Bold"
"Cambria"               = "Caladea"
"Cambria Bold"          = "Caladea Bold"

# ─── Tahoma / Verdana → DejaVu Sans ────────────────────────────────────────────
"Tahoma"                = "DejaVu Sans"
"Tahoma Bold"           = "DejaVu Sans Bold"
"Verdana"               = "DejaVu Sans"
"Verdana Bold"          = "DejaVu Sans Bold"

# ─── Georgia → Liberation Serif ────────────────────────────────────────────────
"Georgia"               = "Liberation Serif"
"Georgia Bold"          = "Liberation Serif Bold"

# ─── Wingdings (if TTF copied to custom_fonts_dir and deployed) ─────────────────
# "Wingdings"           = "Wingdings"
# → Uncomment only after deploying Wingdings.ttf
```

> **Note on symbol fonts (Wingdings, Symbol):**
> If reports use Wingdings for checkmarks (✓), arrows (→) or other symbols,
> redesigning the report to use Unicode characters (▶ ✓ ✗) with DejaVu Sans
> is the better long-term solution and avoids font licensing issues.

---

## 7. Key Environment Variables

| Variable                      | Default / Required Value          | Purpose                                              |
|-------------------------------|-----------------------------------|------------------------------------------------------|
| `REPORTS_ENHANCED_FONTHANDLING` | `yes`                           | Enable new TTF font model (recommended)              |
| `REPORTS_FONT_DIRECTORY`      | `$DOMAIN_HOME/reports/fonts`      | Directory where TTF/TTC files are placed             |
| `REPORTS_FONTPATH`            | (legacy, old model only)          | Font search path for PostScript/Motif model          |
| `TK_FONTALIAS`                | (optional override)               | Explicit path to `uifont.ali`                        |
| `ORACLE_FONTALIAS`            | (optional override)               | Fallback path to `uifont.ali`                        |
| `NLS_LANG`                    | `GERMAN_GERMANY.UTF8` (example)   | Drives character set for font selection              |

Set `REPORTS_ENHANCED_FONTHANDLING` and `REPORTS_FONT_DIRECTORY` in `rwserver.conf`
or in the oracle user environment (`fr_env.sh`). Use `fontpath_config.sh` to inspect
and set these values.

---

## 8. Step-by-Step Setup with Scripts

Run the following scripts in sequence. All scripts default to **read-only mode**.
Use `--apply` only when ready to make changes.

```
Step 1 – Install required OS packages (run as root)
────────────────────────────────────────────────────
./04-ReportsFonts/get_root_install_libs.sh

Output: ready-to-use dnf install command
Installs: poppler-utils (pdffonts), fontconfig (fc-query), liberation-fonts,
          dejavu-serif-fonts, liberation-fonts-common


Step 2 – Check current font situation
───────────────────────────────────────
./04-ReportsFonts/font_inventory.sh

Shows: existing TTF/PS fonts in FMW and system, uifont.ali location and
       current content, reports/fonts/ directory status


Step 3 – Deploy Liberation + customer fonts to reports/fonts/
──────────────────────────────────────────────────────────────
# Read-only preview:
./04-ReportsFonts/deploy_fonts.sh

# Write (copy fonts, run fc-cache):
./04-ReportsFonts/deploy_fonts.sh --apply

# For customer/corporate fonts: copy *.ttf to custom_fonts_dir/ first


Step 4 – Get exact TTF family names (for uifont.ali)
─────────────────────────────────────────────────────
./04-ReportsFonts/get_font_names.sh

Output: ready-to-paste uifont.ali entries with verified fc-query font names
        Covers standard PS fonts + any TTF files in reports/fonts/


Step 5 – Update uifont.ali with PS→TTF mappings
─────────────────────────────────────────────────
# Preview diff:
./04-ReportsFonts/uifont_ali_update.sh

# Write (backup + update [PDF:Subset] section):
./04-ReportsFonts/uifont_ali_update.sh --apply


Step 6 – Set REPORTS_FONT_DIRECTORY in rwserver.conf
──────────────────────────────────────────────────────
# Read-only check:
./04-ReportsFonts/fontpath_config.sh

# Write:
./04-ReportsFonts/fontpath_config.sh --apply


Step 7 – Restart the Reports Server
─────────────────────────────────────
./01-Run/startStop.sh STOP  WLS_REPORTS
./01-Run/startStop.sh START WLS_REPORTS


Step 8 – Verify fonts in generated PDFs
─────────────────────────────────────────
# Run a test report first, then:
./04-ReportsFonts/pdf_font_verify.sh

Checks: emb=yes (embedded), type=TrueType for all fonts in PDF
FAIL on: Type 1 fonts, non-embedded fonts
```

---

## 9. Troubleshooting

### Font appears wrong / text overflows

```
Cause:  uifont.ali alias exists but font name does not match fc-query output
Fix:    Run get_font_names.sh to get exact names, update uifont.ali
```

### REP-1924: Font file cannot be found

```
Cause:  Font referenced in report not in reports/fonts/ and not in uifont.ali
Fix:    1. Add alias in uifont.ali pointing to available font
        2. Or deploy the missing font TTF via deploy_fonts.sh
```

### PDF contains Type 1 / non-embedded fonts

```
Cause:  uifont.ali [PDF:Subset] section missing or wrong font names
        REPORTS_ENHANCED_FONTHANDLING=no
Fix:    1. Check fontpath_config.sh → REPORTS_ENHANCED_FONTHANDLING=yes
        2. Run uifont_ali_update.sh --apply to add [PDF:Subset] entries
        3. Restart Reports Server
```

### Wingdings / Symbol characters show as squares (□)

```
Cause:  Wingdings/Symbol TTF not deployed; no equivalent available
Fix:    Option A – deploy original Wingdings.ttf (requires Windows license)
                   → custom_fonts_dir/ → deploy_fonts.sh --apply
        Option B – redesign report to use Unicode characters with DejaVu Sans
                   ✓ = U+2713, ✗ = U+2717, → = U+2192
```

### Enable font diagnostic logging in Oracle Reports

Enable trace logging to see exactly which fonts are loaded and which fail:

```bash
# In WebLogic Admin Console → Reports Server → Logging:
# Set Oracle Diagnostic Logging Level = Trace:1 (FINE)
# or TRACE:32 for maximum font detail

# Log files to check:
tail -f $DOMAIN_HOME/servers/WLS_REPORTS/logs/WLS_REPORTS.log
find $DOMAIN_HOME/servers -name "rwEng*diagnostic.log" | xargs tail -f
```

### Verify font registration with fontconfig

```bash
# List all Liberation Sans variants known to fontconfig:
fc-list | grep -i "liberation sans"

# Get exact family name for a specific TTF file:
fc-query --format '%{family}\n' /path/to/font.ttf

# Refresh fontconfig cache after adding fonts:
fc-cache -fv

# Verify font is in the reports/fonts/ directory:
ls -la $DOMAIN_HOME/reports/fonts/*.ttf
```

---

## References

- Oracle Reports 12c Font Usage:
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_xplat001.htm
- Oracle Reports Font Configuration:
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_font001.htm
- Oracle Reports uifont.ali:
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_font003.htm
- Oracle Reports Font Aliasing:
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_font004.htm
- Liberation Fonts Project: https://github.com/liberationfonts/liberation-fonts
- Pipperr.de – Oracle Reports 14c Install Guide:
  https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64
