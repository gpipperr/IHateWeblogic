# Oracle Reports fonts – how a font gets into the output, and who may use which font

Reports are designed on Windows with Windows font names (Arial, Times New
Roman, Verdana, Calibri, a barcode font …) and are run on a server, often
Linux. This article explains **how the server finds and uses a font** and
**which fonts may be used on which server** (Microsoft licence vs. free
replacements vs. customer-bought fonts). It also covers what this means
when an existing installation is moved, Windows → Linux or old → new
server.

The configuration steps are in
[04-ReportsFonts/README.md](../04-ReportsFonts/README.md). The HTML parameter
form (screen printer, AFM) is in
[HTML_ParameterForm_Fonts.md](../04-ReportsFonts/HTML_ParameterForm_Fonts.md).
This page is the background for both, and for the font classes of
[`70-Customer-Projects/tools/bash/export_forms_reports_conf.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/export_forms_reports_conf.sh).

Markers as in the rest of this folder: **confirmed (live)**, **documented**,
**assumption**, **open**.

> This page explains licence terms as published by the vendors (sources in
> section 9). It is not legal advice: the binding text is the licence the
> customer actually holds (Windows / Office / font vendor).

---

## 1. The parts

```
 Reports Builder (Windows)          design time: the font picker shows the fonts of the
   report.rdf / .rep / .jsp           Windows PC; the report stores only the font NAME
        |                             ("Arial", 10 pt, bold) - never the font file
        v
 Reports server / rwrun (Linux or Windows)
   engine rwEng-N                   runtime: resolves the name to a file
     |  1. uifont.ali [Global]        alias  "Times New Roman" = times
     |  2. screen printer             screenprinter.ppd + AFM: metrics for the layout
     |  3. [PDF:Subset] / [PDF:Embed] which TTF is embedded for the resolved family
     |  4. REPORTS_FONT_DIRECTORY     the TTF / TTC files (REPORTS_ENHANCED_FONTHANDLING=yes)
     v
 output
   PDF        font subset EMBEDDED in the file (CID TrueType) - the reader needs no font
   HTML / paramform   only the NAME is sent - the browser uses ITS fonts
   printer    font sent to / resolved by the printer
```

- The report file holds **names**, not fonts. Which file is used is decided
  on the server, by `uifont.ali` and the font directory. The same `.rdf`
  can therefore look different on two servers (**documented** in principle;
  layout shift with substitutes **confirmed (live)** 2026-10-19).
- The **engine** renders the PDF, not WebLogic. It gets
  `REPORTS_FONT_DIRECTORY` / `REPORTS_ENHANCED_FONTHANDLING` from
  `$DOMAIN_HOME/reports/bin/reports.sh`, and `uifont.ali`, PPD and AFM from
  the ReportsTools instance (`reptools1`). `TK_FONTALIAS` is ignored by
  `rwrun` (**confirmed (live)**, strace 2026-10-19 –
  [reports_engine_architecture.md](reports_engine_architecture.md) §5.1).
- The **layout** (line breaks, field widths, page breaks) is computed from
  the **metrics** of the font that was found, i.e. the widths of its
  characters. A different font with other metrics means a different
  layout: text overflows, fields are cut, an extra page appears.

The resolution chain with the observed results per case (own TTF vs.
substitute, `Symbol` glyphs without AFM) is in
[04-ReportsFonts/README.md §3](../04-ReportsFonts/README.md#3-font-resolution-chain-runtime);
the six conditions for embedded TrueType are in its "Lessons Learned".

## 2. Two ways for a font: original or substitute

| Way | What is on the server | PDF result | Layout |
|---|---|---|---|
| **Original** | the same TTF the report was designed with (e.g. `arial.ttf`) in `REPORTS_FONT_DIRECTORY`, not renamed by `[Global]` | embedded TrueType – no screen-printer step needed (**confirmed (live)** 2026-10-19) | identical to the Builder |
| **Substitute** | a different font file, mapped by `uifont.ali` (Arial → Liberation Sans) | embedded after the screen-printer step ([`paramform_afm_setup.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/paramform_afm_setup.sh)) – without it `Symbol Type 1`, Latin text as Greek glyphs (**confirmed (live)**) | identical **only** with a metric-compatible substitute (section 4) |

The original is the "easy" technical way, but only allowed where the
licence allows it (section 3). The substitute is the normal way on Linux,
and the way our library goes by default (`14b-`, `04-ReportsFonts/`).

## 3. Licences – who may use which font where

### 3.1 Fonts supplied with Windows (Arial, Times New Roman, Courier New, Verdana, Tahoma, Georgia, Wingdings, Symbol …)

Microsoft's font redistribution FAQ (**documented**, learn.microsoft.com,
state 2024-11-19):

- Use: "A Windows application can use the fonts to render content to a
  screen, allow that content to be edited, and allow that content to be
  output to a device, like a printer."
- Copying: "Apart from the document embedding rights described previously,
  you may not redistribute the Windows fonts. **You may not copy them to
  other computers or servers**, and you may not convert them to other
  formats, including bitmap formats, or modify them."
- Documents: "Although the redistribution of fonts supplied with Windows is
  generally not allowed, 'document font embedding' is a special case which
  is allowed in some circumstances" – an application that follows the
  embedding rules of the OpenType / TrueType specification (`fsType` flags)
  may embed the fonts in the documents it creates, PDFs included. Microsoft
  fonts mostly carry "editable embedding". The resulting documents may be
  distributed: "in general, there are no special restrictions around the
  distribution of documents that contain embedded Windows' fonts".
- Print output: no restriction on what is done with printed output (except
  home / student / non-commercial editions).
- Extended rights (e.g. use outside Windows): "Many of the fonts owned by
  Microsoft can be licensed with extended rights from Monotype"; for other
  fonts ask the foundry named in the font properties.

What follows for Reports:

| Situation | Allowed under the Windows licence? |
|---|---|
| Reports server **on Windows** renders PDFs with the fonts installed with **that** Windows | yes – the application on that machine uses the system fonts (**documented**: render + output) |
| copy `arial.ttf` from that Windows into `REPORTS_FONT_DIRECTORY` **on the same host** | not addressed by the FAQ (**assumption**: same machine, same licence – safer to point `REPORTS_FONT_DIRECTORY` to the font location or keep the copy on that host only, **open**: test whether the engine accepts `C:\Windows\Fonts` as `REPORTS_FONT_DIRECTORY`) |
| copy Windows fonts to a **Linux** Reports server (or any other server) | **no** – "You may not copy them to other computers or servers". Needs extended rights (Monotype / foundry) or a free replacement |
| the PDFs the server produces contain embedded subsets of the fonts | document embedding – allowed when the font's `fsType` permits it; whether the Reports engine checks `fsType` is **open** (Arial: editable embedding) |
| HTML output / parameter form names "Arial" | allowed – the browser uses the client's own fonts ("the use of the font occurs on the … device", FAQ, web section) |

**Consequence for a migration Windows → Linux:** the Windows fonts of the
old server do **not** move with it under the Windows licence – even though
the customer owns that Windows. Either the free replacement (section 4) or
fonts licensed for the Linux server (Monotype / foundry).

### 3.2 Fonts installed by Office (Calibri, Cambria, Candara, Consolas …, Arial Unicode MS)

These come with Office or older Office versions, not with Windows. The
Microsoft FAQ covers **only** fonts supplied with Windows: "For fonts
obtained elsewhere or supplied with other apps, you will need to review the
license agreements that accompany those applications." The same principle
applies (**assumption**): use on the licensed machine, no copy to a server.
Arial Unicode MS (23 MB) is usually only there because of an old Office.
Its point is full Unicode coverage, which DejaVu / Noto give for free.

### 3.3 Free fonts – what the library installs

| Font | Replaces | Licence | On OL 9 |
|---|---|---|---|
| Liberation Sans / Serif / Mono (2.x) | Arial / Times New Roman / Courier New – **identical metrics** | SIL Open Font License 1.1 since 2.00.0 (older 1.x: GPLv2 with font exception) | `liberation-*-fonts` 2.1.3, installed by [`09-Install/02-root_os_packages.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/02-root_os_packages.sh) (**confirmed (live)**, `rpm -qi`: License OFL) |
| Liberation Sans Narrow | Arial Narrow – identical metrics | only in the 1.x line (2.x dropped it): licence "Liberation" (GPLv2 with font exception – embedding in documents allowed) | `liberation-narrow-fonts` 1.07.6 (`ol9_appstream`), installed by `02-` since 2026-11-03 |
| Carlito | Calibri – identical metrics | SIL OFL 1.1 | `google-carlito-fonts` 1.103 (`ol9_appstream`), installed by `02-` since 2026-11-03 |
| Caladea | Cambria – identical metrics | SIL OFL 1.1 | not in the OL 9 base repositories (**open**: EPEL / upstream) |
| DejaVu Sans / Serif / Mono | Verdana, Tahoma, Trebuchet MS – **similar only**; broad Unicode | Bitstream Vera licence + public-domain changes (copy, distribute, bundle allowed; not sold on their own; modified versions must be renamed) | `dejavu-*-fonts` 2.37, installed by `02-` (**confirmed (live)**) |

The OFL allows use, embedding and redistribution. Documents created with
the fonts are not bound by the font licence ("The requirement for fonts to
remain under this license does not apply to any document created using the
fonts"). Free fonts can therefore be copied to every server, embedded in
every PDF and kept in a golden image.

### 3.4 Customer-bought fonts (barcode, corporate fonts)

Example: `IDAutomationC128L.ttf` (Code 128 barcode). The licence is the
vendor's – often **per server / per CPU / per developer**, sometimes with a
separate "server licence" for applications that generate documents for
others. These fonts have **no** replacement: a barcode font with other
metrics gives an unreadable barcode. For a new or additional server, check
the vendor licence (**open** per customer). Technically they are deployed
like any TTF (`04-ReportsFonts/custom_fonts_dir/` → [`deploy_fonts.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/deploy_fonts.sh),
gitignored).

## 4. Metric compatibility – "identical" vs. "similar"

**Metric-compatible** means every character has the same advance width and
the same line metrics as the original. Text then breaks at the same
places, fields keep their width, and a page holds the same lines. The
glyphs themselves look different (Liberation Sans is not Arial), but the
layout of the report does not change. "Visual similarity is not the same as
metric compatibility" – a font that looks alike can still break every line
differently.

| Original | Replacement | Metrics | Effect on a report |
|---|---|---|---|
| Arial, Times New Roman, Courier New | Liberation Sans / Serif / Mono | identical | none – the default of the library |
| Calibri | Carlito | identical | none – set up 2026-11-03 (`[Global] Calibri = Carlito`), embedded in the PDF (**confirmed (live)**, `pdffonts`) |
| Arial Narrow | Liberation Sans Narrow | identical | none – set up 2026-11-03 (`[Global] "Arial Narrow" = LiberationSansNarrow`), embedded (**confirmed (live)**) |
| Cambria | Caladea | identical | not set up – Caladea is not in the OL 9 base repositories (section 8) |
| Verdana, Tahoma, Trebuchet MS | DejaVu Sans | **similar** | Verdana is wide: lines / fields can shift – check every report that uses it |
| Georgia, Palatino Linotype | Liberation Serif | **similar** | as above |
| Wingdings, Webdings, Symbol | – | none | check boxes / arrows become other characters: original font with a licence, or change the report to Unicode characters with DejaVu |
| barcode / corporate font | – | none | the original with the vendor licence |

Full table with package names:
[04-ReportsFonts/README.md §7](../04-ReportsFonts/README.md#7-windows-specific-fonts-on-linux).

## 5. Builder, server, browser – three places, three font sets

| Place | Fonts used | Consequence |
|---|---|---|
| Reports Builder on the developer PC / Windows terminal server | Windows (+ Office) fonts of that machine | the preview shows the **originals** |
| Reports server / `rwrun` (PDF, printer) | `REPORTS_FONT_DIRECTORY` + `uifont.ali` of the server | Linux: substitutes – identical layout only with identical metrics |
| browser (HTML, parameter form) | fonts of the **client** | not controlled by the server; the screen printer / AFM only decides metrics on the server side |

The test that counts is therefore a PDF **from the server** (`pdffonts`
shows which fonts were embedded), not the Builder preview –
[reports_rwbuilder.md](reports_rwbuilder.md) (Builder on Windows, server on
Linux: "different fonts = different layout").

## 6. Migration – old server → new server

```
 old server (Windows or Linux)                     new 14c server (Linux)
 REPORTS_FONT_DIRECTORY / uifont.ali               free fonts:   02- installs, 14b- deploys + maps
   |                                               customer:     vendor licence for the new server,
   |  export_forms_reports_conf.sh                               04-ReportsFonts/custom_fonts_dir/
   |  ihw_import/fonts.txt  class:                 Microsoft:    replacement by default;
   |    customer  -> must move ----------------->                original only with extended rights
   |    ms        -> replacement / licence ----->                (Monotype / foundry)
   |    free      -> skipped (OS package)
   v
 decision with the customer per font, then deploy_fonts.sh + uifont_ali_update.sh + test PDFs
```

Per font:

1. **customer** class: always needed. Clarify the vendor licence for the
   new server, then `custom_fonts_dir/`.
2. **ms** class with an *identical* replacement (Arial, Times New Roman,
   Courier New, Calibri, Arial Narrow; Cambria once section 8 is done): use the
   replacement. The old TTF stays behind.
3. **ms** class with a *similar* replacement (Verdana, Tahoma, Georgia):
   find the reports that use it and test them with the replacement. If the
   layout breaks: change the report font (to Arial → Liberation), or license
   the original for the new server.
4. **ms** symbol fonts (Wingdings …): original with licence, or change the
   report to Unicode characters.
5. Test with PDFs from the **server** (`pdffonts`, [`04-ReportsFonts/pdf_font_verify.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/pdf_font_verify.sh)),
   reports that use each font, compared page by page with the old output.

Which reports use which font: the export tool does not read the binary
`.rdf`. The report XML (`rwconverter … dtype=xmlfile`) contains
`<font face="…">` and gives the list (**assumption** for a migration
script, the format is **confirmed (live)** in the font test of 2026-10-19).

A Windows → Windows move (Reports server stays on Windows) is simpler: the
new Windows has the same system fonts, and only customer and Office fonts
need a decision.

## 7. Where the library implements this

| Where | What |
|---|---|
| [09-Install/02-root_os_packages.sh](../09-Install/docs/01-root_install_packages.md) | installs Liberation (Sans / Serif / Mono) and DejaVu (all six packages) |
| [`09-Install/14b-oracle_reports_fonts.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/14b-oracle_reports_fonts.sh) | deploys the fonts to `REPORTS_FONT_DIRECTORY`, `uifont.ali`, AFM / PPD step |
| [04-ReportsFonts/](../04-ReportsFonts/README.md) | [`deploy_fonts.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/deploy_fonts.sh), [`uifont_ali_update.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/uifont_ali_update.sh) (template [`uifont_ali_template.ali`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/uifont_ali_template.ali): `[Global]` Arial = helvetica, Verdana / Tahoma = DejaVuSans, `[PDF:Subset]` families), [`paramform_afm_setup.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/paramform_afm_setup.sh), [`pdf_font_verify.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/pdf_font_verify.sh), [`font_inventory.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/font_inventory.sh); `custom_fonts_dir/` for customer fonts (gitignored – licence) |
| [70-Customer-Projects/tools/bash/export_forms_reports_conf.sh](../70-Customer-Projects/tools/README.md#export_forms_reports_confsh) | fonts of an existing installation in three classes `customer` / `ms` / `free` with the 14c replacement (`ihw_import/fonts.txt`, since 2026-11-03) |
| [reports_rwbuilder.md](reports_rwbuilder.md) | Builder on Windows vs. server fonts |
| [reports_engine_architecture.md](reports_engine_architecture.md) | which process reads which font configuration |

Rule for the repository: **no font file that is not free** goes into git
(`.gitignore`: `04-ReportsFonts/custom_fonts_dir/*`); Microsoft and customer
fonts live only on the customer's servers.

## 8. Open points

- **Cambria → Caladea:** not in the OL 9 base repositories (EPEL / the
  upstream release would be needed). Calibri → Carlito and Arial Narrow →
  Liberation Sans Narrow are done (2026-11-03): packages in `02-`,
  [`deploy_fonts.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/deploy_fonts.sh) copies Carlito, `[Global]` + `[PDF:Subset]` entries,
  font test of `15-` with both families – all `CID TrueType emb=yes
  sub=yes` (**confirmed (live)**).
- **`fsType`:** does the Reports engine respect the embedding flags of a
  font (e.g. "restricted licence – no embedding" of some bought fonts)? Not
  documented, not tested.
- **Windows server:** can `REPORTS_FONT_DIRECTORY` point to `C:\Windows\Fonts`
  (no copy at all)? Test at the Windows customer.
- **Oracle documentation 14.1.2:** the Reports font chapters were found
  only for 11g / 12.2.1.3 ("Configuring Fonts"); 14.1.2 is unchanged
  according to Oracle's statement that Reports 14.1.2 equals 12.2.1.3
  ([Reports14_builder_windows/README.md](../70-Customer-Projects/Reports14_builder_windows/README.md)).
- A list of the fonts used per report (from the report XML) as part of the
  export / migration tooling.

## 9. Sources

- Microsoft, *Font redistribution FAQ* (Windows-supplied fonts: use, document
  embedding, no copy to other computers / servers, extended rights via
  Monotype), updated 2024-11-19:
  <https://learn.microsoft.com/en-us/typography/fonts/font-faq>
- OpenType specification, OS/2 table `fsType` (embedding permissions):
  <https://learn.microsoft.com/en-us/typography/opentype/spec/os2#fstype>
- Liberation fonts (OFL 1.1 from 2.00.0, metric compatibility):
  <https://github.com/liberationfonts/liberation-fonts> ,
  <https://en.wikipedia.org/wiki/Liberation_fonts>
- Carlito (OFL 1.1, Calibri-compatible): <https://ctan.org/pkg/carlito>
- DejaVu fonts licence: <https://dejavu-fonts.github.io/License.html>
- SIL Open Font License 1.1: <https://openfontlicense.org/>
- Oracle Reports 12.2.1.3 – *Using Oracle Reports*, fonts and PDF
  (font model, `REPORTS_ENHANCED_FONTHANDLING`, `[PDF:Subset]`):
  <https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_pdf001.htm>
- Oracle Reports 11g – *Overview of the Font Model*:
  <https://docs.oracle.com/cd/E24269_01/doc.11120/e24479/pbr_xplat002.htm>
- Live tests: [04-ReportsFonts/README.md](../04-ReportsFonts/README.md) (2026-10-19),
  `rpm -qi liberation-sans-fonts dejavu-sans-fonts` and `dnf repoquery` on
  the OL 9 test host (2026-11-03).
