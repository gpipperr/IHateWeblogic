# render_ascii – ASCII diagrams in Markdown additionally as SVG

The ASCII diagrams in the Markdown files stay the source. The tool creates an
SVG diagram from them, puts the image in front of the block and folds the
ASCII version below it into `<details>`. A second run changes nothing as long
as neither the diagram nor the style template changed.

State: in use since 2026-11-10 (32 diagrams), checked in on 2026-11-11.

## Flow

```
 MD block ```ascii?name=<n>
        |
        v
 diagrams/<n>.prompt   = ### STYLE (template) + ### ASCII (block)
        |  SHA-256 the same as in diagrams/<n>.sha256? -> skip
        v
 LLM (provider)  ->  diagrams/<n>.d2          (engine d2)
        |
        v
 d2 --layout dagre -> diagrams/<n>.svg   (error: back to the LLM once)
        |
        v
 MD: ![<n>](diagrams/<n>.svg?v=<8 hex of the SVG's SHA-256>)
     <sub>Source: [diagrams/<n>.prompt] · [D2]</sub>   (absolute github.com/…/blob/main/ links)
     <details markdown="block"><summary>ASCII version</summary> … block … </details>
```

`diagrams/` lies next to the Markdown file.

**`?v=` cache-busting:** the image link carries the first 8 hex digits of the
SHA-256 of the SVG. A changed SVG gets a new URL, so browsers and GitHub's
image proxy load it again instead of showing the old picture. The tool
updates the value on every run when the SVG changed – never edit it by hand.

**Source links absolute (since 2026-11-12):** the `.prompt` / `.d2` links
point to `https://github.com/gpipperr/IHateWeblogic/blob/main/<dir>/diagrams/…`
– on GitHub Pages a relative link to a raw file is served raw or as a
download. The SVG link stays relative (works on github.com and Pages).

Wrappers written before 2026-11-11 (German "Quelle:" / "ASCII-Version",
image link without `?v=`) are recognised and rewritten on the next run.

## Which diagrams become an image?

Only real **diagrams** – components with arrows, data flows, architecture
(e.g. "Target Picture" in `README.md`, "The parts" in
`80-FMW-Architecture/apex_architecture.md`).

**List-like drawings stay ASCII:** folder trees (repository structure),
step and phase lists in boxes (lifecycle overview), framed tables, console
output, menus. There the text is the information – an image adds nothing
and is harder to search and copy. Such blocks are not marked – the tool only
reports them as "candidate".

## Marking a diagram

Only marked blocks are processed. ```` ``` ```` becomes
```` ```ascii?name=<n> ```` – `<n>` of lower-case letters, digits, `-` and
`_`, unique per Markdown file. Unmarked blocks that look like a diagram are
only reported as "candidate" (file:line).

Why this form (2026-11-12): GitHub Pages (kramdown) accepts after the
backticks only the language plus an optional `?…` – the old marker
```` ```ascii name=<n> ```` was no fence there, and the next ```` ``` ````
opened a code block that swallowed `</details>` and the rest of the page.
`markdown="block"` makes kramdown parse the block inside `<details>`; without
it a placeholder like `<cn>` in the ASCII was read as an HTML tag. github.com
renders both forms the same. The old marker and the old wrapper are still
recognised and rewritten.

## Call

```bash
tools/render_ascii/render_ascii.sh --file 80-FMW-Architecture/apex_architecture.md --dry-run
```

```bash
tools/render_ascii/render_ascii.sh --file 80-FMW-Architecture/apex_architecture.md
```

| Option | Effect |
|---|---|
| `--file X.md` / `--all` | one file / all Markdown files under git (without `customer-analyse/`) |
| `--engine d2` | default: prompt → LLM → D2 → SVG (layout `RENDER_ASCII_LAYOUT`, default `dagre` – places arrow labels without overlap; `elk` selectable) |
| `--engine svgbob` | without LLM: ASCII straight to SVG with svgbob (dense grid drawings) |
| `--dry-run` | only show what would happen – no LLM call, nothing written |
| `--force` | ignore the hash and hand edits of the `.d2`, create it again |

Exit code 0 = all OK, 1 = warnings, 2 = errors. Log:
`log/<date>/render_ascii_<time>.log`, a backup of every changed Markdown file
in `log/<date>/render_ascii_backup/`.

## Changing a diagram

The "Source" link below the image leads to the text file
`diagrams/<n>.prompt`.

1. Change content or style: adapt the section `### ASCII` and/or `### STYLE`
   in `diagrams/<n>.prompt`.
2. Run the tool again. The hand-edited `.prompt` counts as the source: its
   ASCII part is written back into the `<details>` block of the Markdown
   file, an own STYLE part is kept permanently in `diagrams/<n>.style`, then
   the image is created again.

Alternatively change the ASCII drawing directly in the Markdown file – the
tool detects that too. If **both** were changed, it stops for this diagram
so that nothing is overwritten.

**Small text fix without an LLM call:** change the label in
`diagrams/<n>.d2` by hand (and the same text in the ASCII block). A `.d2`
newer than its `.sha256` is not regenerated, only rendered (WARN); the
prompt, the hash and the `?v=` are updated. `--force` creates it again via
the LLM. (Used 2026-11-11 for "ORDS 26.2 → 26.3" in the Target Picture.)

## Style template

Central: `tools/render_ascii/style_default.txt` (rules for the LLM: D2 only,
copy labels exactly, colours – database blue, middleware green, external
grey, dark-red component names as in the blog diagrams). Precedence:

1. `diagrams/<n>.style` – this diagram only
2. `diagrams/_style.txt` – all diagrams next to this Markdown file
3. `tools/render_ascii/style_default.txt`

A change of the template changes the prompt hash – the next run creates the
affected images again.

## Configuration

Copy `render_ascii.conf.example` to `render_ascii.conf` (git-ignored) or set
environment variables (they win over the file). **API keys only as
environment variables**, never in a file.

| Provider (`RENDER_ASCII_PROVIDER`) | Requirement |
|---|---|
| `claude-cli` (default) | Claude Code CLI logged in (`claude -p`), no API key; path via `CLAUDE_BIN` |
| `manual` | no call: the tool writes the `.prompt`, you create the `.d2` yourself (or in a Claude session), then run again |
| `anthropic` | `ANTHROPIC_API_KEY`, model `RENDER_ASCII_MODEL` (default `claude-sonnet-5-5`) |
| `azure` | Azure AI Foundry (GDPR): `AZURE_AI_URL`, `AZURE_AI_FORMAT` (`openai` / `anthropic`), `AZURE_AI_DEPLOYMENT`, `AZURE_AI_KEY` – **not tested yet** |

`RENDER_ASCII_FAKE_LLM=<file>[:<file2>]` returns fixed D2 answers for tests
without an LLM call.

## Installing the tools

- **d2** (engine d2): release binary from
  <https://github.com/d2lang/d2/releases> (`d2-<version>-linux-amd64.tar.gz`,
  checksum against `SHA256SUMS`), `bin/d2` to `~/.local/bin/d2`. Tested:
  v0.9.0.
- **svgbob** (engine svgbob): no ready release binaries –
  `cargo install svgbob_cli` (Rust via rustup), binary to `~/.local/bin`.

The wrapper `render_ascii.sh` puts `~/.local/bin` in front of the `PATH`. If
a tool is missing, the script stops with this hint.
