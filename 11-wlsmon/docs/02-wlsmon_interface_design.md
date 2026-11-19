---
nav_title: "wlsmon interface design"
title: "wlsmon – Interface Design: Colour Concept"
description: "Interface design of the wlsmon runtime monitor for Oracle Forms & Reports 14.1.2: colour concept based on the IHateWeblogic / pipperr.de corporate colours, reserved status colours, chart series colours, light and dark mode – checked for contrast and colour blindness."
---

# wlsmon – interface design

← [11-wlsmon](../README.md) · [concept](01-wlsmon_concept.md)

**State 2026-11-19: colour concept.** Layout, components and pages follow in
later sections. This document is the master for the GUI files in
`11-wlsmon/www/` (Doc-as-Master, like the concept).

## 1. Basis: the colours of the project site

The monitor uses the colours of the
[IHateWeblogic site](https://gpipperr.github.io/IHateWeblogic/)
(`assets/css/ihw.css`, which follows the corporate colours of pipperr.de).
The monitor, the documentation and the analysis reports then look like one
family:

| Token | Hex | Use on the site |
|---|---|---|
| `--ihw-gold` | ![#feb80a](colors/feb80a.svg) `#FEB80A` | header line, heading marks, hover background in the menu |
| `--ihw-black` | ![#000000](colors/000000.svg) `#000000` | text, left page border |
| `--ihw-white` | ![#ffffff](colors/ffffff.svg) `#FFFFFF` | page background |
| `--ihw-darkred` | ![#990000](colors/990000.svg) `#990000` | active menu entry, link hover |
| `--ihw-grey-line` | ![#e8e8e8](colors/e8e8e8.svg) `#e8e8e8` | thin separator lines |
| `--ihw-gold-tint` | ![#fff6dd](colors/fff6dd.svg) `#fff6dd` | table header background |
| `--ihw-grey-text` | ![#333333](colors/333333.svg) `#333333` | quotes, secondary text |
| `--ihw-grey-muted` | ![#888888](colors/888888.svg) `#888888` | separators in the menu |

Font: `Arial, Verdana, Helvetica, sans-serif`, the same as on the site.

## 2. The central rule: frame colours and data colours are kept apart

The site colours are for the **frame**: header, menu, headings, links. The
**data area** – tiles, badges, charts – gets its own colours, chosen to fit
the site colours.

The reason: the corporate gold and dark red are the classic warning and
alarm colours. Used in the data area, they would carry a false meaning:

- Gold `#FEB80A` and the common warning yellow (`#fab219`) are almost the
  same colour (measured distance ΔE 1.7; below about 15 nobody can tell them
  apart).
- Dark red `#990000` and an alarm red (`#d03b3b`) are close (ΔE 14.7).

That gives three rules:

1. **Gold appears only as a line or a mark,** never as a fill in the data
   area: the header line, heading marks, the focus ring. No gold hover
   background on tiles. A gold area next to a status tile would look like a
   warning.
2. **Dark red stays in the menu** (active entry). Links in the data area are
   black and underlined.
3. **Status colours** (section 3) are only used for status and never for
   anything else – not for a series, not for decoration.

## 3. Status colours (reserved)

Four states, from the levels of the concept: OK, WARN, CRIT and STALE (data
too old or missing). DOWN is shown as CRIT with its own word.

| Status | Light mode | Dark mode | Text on the fill | Icon (font-apex) | Word |
|---|---|---|---|---|---|
| OK | ![#0b8a5f](colors/0b8a5f.svg) `#0b8a5f` | ![#12a874](colors/12a874.svg) `#12a874` | white | `fa-check-circle` | OK |
| WARN | ![#e67700](colors/e67700.svg) `#e67700` | ![#e67700](colors/e67700.svg) `#e67700` | **black** | `fa-exclamation-triangle` | WARN |
| CRIT | ![#d03b3b](colors/d03b3b.svg) `#d03b3b` | ![#d03b3b](colors/d03b3b.svg) `#d03b3b` | white | `fa-times-circle` | CRIT / DOWN |
| STALE | ![#888888](colors/888888.svg) `#888888` outline, no fill | ![#888888](colors/888888.svg) `#888888` outline | black / light text | `fa-clock-o` | STALE + age |

**A status always has three signs:** colour, icon and word. Colour alone is
never the only carrier – about one man in twelve sees red and green poorly,
and an ops screen may be grey on a projector.

Why these colours and not the usual traffic light:
- **WARN is orange (`#e67700`), not yellow:** it stays clearly apart from the
  corporate gold (ΔE 16.1) and still reaches 3:1 contrast on white. On the
  orange fill the text is black (7:1); white would only reach 3:1.
- **OK is a blue-green (`#0b8a5f`), not a pure green:** a pure green
  (`#0ca30c`) and the alarm red look almost the same with red-green colour
  blindness (ΔE 4.1). The blue-green raises that distance to 7.1 and to 8.1
  against WARN.
- **STALE is an outline,** dashed, with the age of the data ("STALE 17 min"),
  not a grey area. So it does not compete with the three real states.
- **CRIT keeps a distance from the corporate dark red** (ΔE 14.7). Since dark
  red is only used in the menu, the two never meet in the data area.

### Measured values

Checked with the method of a data-visualisation guide: contrast to WCAG 2;
colour distance as OKLab ΔE × 100 with normal vision and with simulated
red-green colour blindness (protanopia / deuteranopia, Machado 2009). The
target for distance is 8 or more. Values between 6 and 8 are acceptable only
when a second sign (icon, word, outline) is present. That is always the case
here.

| Pair (light mode, on white) | Normal | Red-green colour blind |
|---|---|---|
| OK – WARN | 26.5 | 8.1 |
| OK – CRIT | 28.6 | 7.1 (icon + word) |
| WARN – CRIT | 14.3 | 12.0 |
| WARN – STALE | 17.9 | 12.8 |
| CRIT – STALE | 19.3 | 10.1 |
| OK – STALE | 13.7 | 6.0 (outline + word) |

Contrast on white: OK 4.4, WARN 3.0, CRIT 4.8, STALE 3.5. Dark mode on
`#1a1a19`: OK 5.7, WARN 5.8, CRIT 3.6, STALE 4.9.

## 4. Chart colours

Charts show key figures over time (day / week / year). They never use status
colours for their lines.

| Use | Light mode | Dark mode |
|---|---|---|
| **Single series** (one measured value per chart – load, memory, Reports queue) | ![#333333](colors/333333.svg) `#333333` (corporate dark grey) | ![#f0efec](colors/f0efec.svg) `#f0efec` |
| Series 1 when several are shown (e.g. heap per managed server) | ![#2a78d6](colors/2a78d6.svg) `#2a78d6` blue | ![#3987e5](colors/3987e5.svg) `#3987e5` |
| Series 2 | ![#e87ba4](colors/e87ba4.svg) `#e87ba4` magenta | ![#d55181](colors/d55181.svg) `#d55181` |
| Series 3 | ![#6250d6](colors/6250d6.svg) `#6250d6` violet | ![#9085e9](colors/9085e9.svg) `#9085e9` |
| Threshold line WARN | ![#e67700](colors/e67700.svg) `#e67700`, dashed | same |
| Threshold line CRIT | ![#d03b3b](colors/d03b3b.svg) `#d03b3b`, dashed | same |
| Grid lines | ![#e8e8e8](colors/e8e8e8.svg) `#e8e8e8` (corporate line grey) | ![#2c2c2a](colors/2c2c2a.svg) `#2c2c2a` |
| Axis, axis labels | ![#888888](colors/888888.svg) `#888888` | ![#888888](colors/888888.svg) `#888888` |

Rules:
- **A single series is dark grey,** in the style of the site (black text on
  white). The chart then shows status only where a threshold is crossed: the
  dashed WARN / CRIT line marks the limit, and the line itself stays neutral.
- **Several series use blue, magenta, violet,** in this fixed order. These
  three hues belong to none of the status colours and are far from gold.
  The order is part of the check: blue–magenta 13.0 and magenta–violet 19.9
  with red-green colour blindness. Blue and violet are not neighbours,
  because they would be too close (4.5).
- **Never more than three series in one chart.** A fourth server goes into a
  second chart (small multiples) – not into a fourth colour.
- **The colour follows the entity:** `WLS_FORMS` keeps the same colour in
  every chart and on every page. A filter that hides a server does not
  repaint the others.
- **A legend from two series on;** text in the legend and labels in text
  colours, never in the series colour.
- **One y-axis per chart.** Heap % and the number of sessions are two charts,
  never one chart with two scales.
- **Values in tooltips and tables:** every chart has a table view, so no
  value depends on colour.

## 5. Surfaces and text

| Token | Light mode | Dark mode | Use |
|---|---|---|---|
| `--wm-page` | ![#ffffff](colors/ffffff.svg) `#FFFFFF` | ![#0d0d0d](colors/0d0d0d.svg) `#0d0d0d` | page background |
| `--wm-surface` | ![#ffffff](colors/ffffff.svg) `#FFFFFF` | ![#1a1a19](colors/1a1a19.svg) `#1a1a19` | tiles, chart area |
| `--wm-border` | ![#e8e8e8](colors/e8e8e8.svg) `#e8e8e8` | ![#2c2c2a](colors/2c2c2a.svg) `#2c2c2a` | tile border, separators |
| `--wm-ink` | ![#000000](colors/000000.svg) `#000000` | ![#f0efec](colors/f0efec.svg) `#f0efec` | main text, values |
| `--wm-ink-2` | ![#333333](colors/333333.svg) `#333333` | ![#c3c2b7](colors/c3c2b7.svg) `#c3c2b7` | secondary text |
| `--wm-muted` | ![#888888](colors/888888.svg) `#888888` | ![#888888](colors/888888.svg) `#888888` | labels, axes, time stamps |
| `--wm-accent` | ![#feb80a](colors/feb80a.svg) `#FEB80A` | ![#feb80a](colors/feb80a.svg) `#FEB80A` | header line, heading mark, focus ring (lines only) |
| `--wm-nav-active` | ![#990000](colors/990000.svg) `#990000` | ![#ff6b6b](colors/ff6b6b.svg) `#ff6b6b` | active menu entry only |
| `--wm-table-head` | ![#fff6dd](colors/fff6dd.svg) `#fff6dd` | ![#262522](colors/262522.svg) `#262522` | table headers (as on the site) |

- **Dark mode** is a real second set, not an inverted page: the site has
  none, but a monitor often runs on a wall screen or in a dark ops room. It
  follows the system setting (`prefers-color-scheme`); a switch in the page
  can override it. Gold on black keeps the corporate look.
- **The dark-mode menu red** `#ff6b6b` is a lighter step of the dark red,
  because `#990000` would be too dark on black (contrast 2.2; `#ff6b6b`
  reaches 7.0). It is only used for the active menu entry.
- **The table header** keeps the light gold tint of the site. It is a very
  pale area behind black text and does not look like a status.

## 6. CSS tokens

All colours are CSS custom properties in one file `www/css/wlsmon.css`. The
page uses only the token names, never a hex value. Light and dark mode are
switched in one place:

```css
:root {
  color-scheme: light;
  --wm-page: #FFFFFF;  --wm-surface: #FFFFFF;  --wm-border: #e8e8e8;
  --wm-ink: #000000;   --wm-ink-2: #333333;    --wm-muted: #888888;
  --wm-accent: #FEB80A; --wm-nav-active: #990000; --wm-table-head: #fff6dd;
  --wm-ok: #0b8a5f;  --wm-warn: #e67700;  --wm-crit: #d03b3b;  --wm-stale: #888888;
  --wm-on-ok: #FFFFFF; --wm-on-warn: #000000; --wm-on-crit: #FFFFFF;
  --wm-series-single: #333333;
  --wm-series-1: #2a78d6; --wm-series-2: #e87ba4; --wm-series-3: #6250d6;
  --wm-grid: #e8e8e8;  --wm-axis: #888888;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) { /* dark set, see below */ }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --wm-page: #0d0d0d;  --wm-surface: #1a1a19;  --wm-border: #2c2c2a;
  --wm-ink: #f0efec;   --wm-ink-2: #c3c2b7;    --wm-muted: #888888;
  --wm-nav-active: #ff6b6b; --wm-table-head: #262522;
  --wm-ok: #12a874;
  --wm-series-single: #f0efec;
  --wm-series-1: #3987e5; --wm-series-2: #d55181; --wm-series-3: #9085e9;
  --wm-grid: #2c2c2a;
}
```

The dark set is written twice in the real file (inside the media query and
for `data-theme="dark"`), so that the switch in the page wins in both
directions.

Oracle JET gets its series colours from these tokens (read once with
`getComputedStyle`), not from its own theme – so the charts match the page
in both modes.

## 7. What comes from APEX `/i/` – and what not (decision 2026-11-19)

The Universal Theme CSS of APEX (`Core.min.css` with Redwood or Vita) brings
its own colours, which would cover the site colours. The GUI therefore takes
only two libraries from `/i/`:

- **font-apex** for the icons (status icons above);
- **Oracle JET** for the charts – drawn in our own design: series and
  threshold colours of section 4, grid, axes, font and tooltips from the
  tokens of section 6, not from the JET theme. JET's own theme CSS is loaded
  only as far as `oj-chart` needs it to work (to verify in P1).

The **Universal Theme CSS is not loaded.** Layout and colours come from one
small own file `www/css/wlsmon.css`, built from the tokens of section 6 and
the frame of `assets/css/ihw.css` (header with gold line, left black border,
Arial).

The icon names in section 3 follow Font Awesome 4, which font-apex keeps;
they are checked against the font-apex version on the test host in P1.

## 8. Language, date and number format

- **Texts are English** – labels, states, tooltips, messages.
- **Date and number format are German by default** – the usual format of the
  operators:

  | What | Default (`de-DE`) | Example |
  |---|---|---|
  | Date | `DD.MM.YYYY` | `19.11.2026` |
  | Time | 24 h, `HH:MM` (seconds only in tooltips) | `14:05` |
  | Date and time | `DD.MM.YYYY HH:MM` | `19.11.2026 14:05` |
  | Decimal separator | comma | `87,5 %` |
  | Thousands separator | point | `12.480 MB` |
  | Units | space before the unit | `3,2 GB`, `87 %`, `17 min` |

- **Switchable when needed:** one key `WLSMON_LOCALE` in `wlsmon.conf`
  (default `de-DE`, e.g. `en-GB` or `en-US`), asked by the interview. The
  installation writes it into `www/ui.json`, which the page reads at start.
- **Formatting only in the browser** with the standard `Intl.DateTimeFormat`
  and `Intl.NumberFormat` – no library, and only the display changes. The
  JSON files always hold ISO 8601 times with offset (`2026-11-19T14:05:00+01:00`)
  and plain numbers with a decimal point, so the data stay the same whatever
  the display format is.
- **Time zone:** times are shown in the time zone of the host that measured
  them (the offset in the JSON), with the zone in the tooltip – an operator
  in another time zone sees the same times as in the server logs.
- Oracle JET gets the same locale for its axes and tooltips.

## 9. Next sections (open)

- Layout and grid: overview page (tiles per host), host view, phone width.
- Components: tile, status badge, key figure, chart card, table view, stale
  notice.
- Accessibility: keyboard, focus ring, `forced-colors`, print.
