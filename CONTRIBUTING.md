# Contributing to IHateWeblogic

← Back to the [root README](README.md)

IHateWeblogic is a private project, maintained alongside customer work by
Gunther Pipperr together with Claude as AI co-author. Findings are very
welcome; they are handled on a best-effort basis, without guaranteed response
times.

**Scope:** Oracle Fusion Middleware **14.1.2 and later** (Forms 14c,
Reports 14c, WebLogic 14c) on Oracle Linux 9. 12c and WebLogic before 14.1.2
are not supported.

## Report a finding

Open a [GitHub issue](https://github.com/gpipperr/IHateWeblogic/issues/new/choose)
(template "Finding") with:

| What | How to get it |
|---|---|
| FMW version and patch cycle | `$ORACLE_HOME/OPatch/opatch lspatches` (first lines) |
| OS | `cat /etc/oracle-release`, `uname -r` |
| Script and repository state | file name + commit (`git log -1 --format=%h`) or the release / download date; customer tools: the `VERSION=` line |
| Exact command | incl. flags (`--apply`?) |
| Output | the relevant part of the output or of `log/<date>/<script>_*.log` – **anonymised** |
| Expected vs. actual | what you expected and what happened |

**Anonymise before you post:** replace host names, domain names, IP
addresses, database / PDB names, user names and company names – for example
with the [demo data](README.md#demo-data) of this repository. Never attach
`*.des3` files, `environment.conf`, `setup.conf`, export / collector archives
or unredacted logs: they contain host names, IPs and encrypted credentials
of a real system.

Not here:

- **Security problems** of this repository → privately, see [SECURITY.md](SECURITY.md).
- **Bugs in Oracle products** (WebLogic, Forms, Reports, JDK, OPatch …) →
  Oracle Support (Service Request). A finding *how to work around* such a bug
  with these scripts is welcome here.

## Pull requests

**Open an issue first** and agree on the change there – pull requests without
a preceding issue may be closed. A pull request must:

- pass the `lint` workflow (`tools/ci_lint.sh`: `bash -n` + ShellCheck errors),
- pass the pre-commit hook (below) – no customer data, no secrets,
- follow the conventions below and change the matching documentation in the
  same pull request.

Contributions are accepted under the project licence (Apache 2.0, section 5:
inbound = outbound); there is no separate contributor agreement.

## Conventions

### Scripts

- Every script sources `environment.conf` (via `check_env_conf`) and
  `00-Setup/IHateWeblogic_lib.sh` – paths and settings come from
  `environment.conf`, never hard-coded.
- **Read-only by default.** Anything that writes or installs runs only with
  `--apply`; without it the script shows what it would do.
- **Backup before every config change** (`backup_file` / `07-Maintenance/backup_config.sh`).
- Output only via `ok` / `warn` / `fail` / `info` of the library. They take a
  plain string – pre-format with `printf`:
  `ok "$(printf "  %-14s  %s" "$label" "$value")"`. `printf`, never `echo -e`.
- Output goes to stdout **and** the log: `tee -a "${LOG_FILE:-/dev/null}"`.
- End every script with `print_summary` and `exit "$EXIT_CODE"`.
- Customer tools (`70-Customer-Projects/tools/`) carry a `VERSION="YYYY-MM-DD.N"`
  line – bump it on every change (shown in their report and in `VERSIONS.txt`).
- **Passwords never** on a command line, in a file in clear text or in a log
  – use the encrypted `.des3` files of the library (concept:
  [docs/general_security.md](docs/general_security.md)); pass secrets to
  WLST / SQL\*Plus via environment variables or stdin.
- Generated WLST / Jython code is **pure ASCII**; own helper functions are
  prefixed `_ihw_` (WLST overrides globals after `connect()`).
- Merge single keys into Oracle configuration files – do not replace whole
  files with a template (Oracle entries would be lost).

### Documentation

- **Doc-as-master** in `09-Install/`: `docs/NN-*.md` is the specification,
  `NN-*.sh` must match it – change both together.
- Documentation in **English**; cookbooks for manual work may be German
  (`*_de.txt`, `*Kochbuch*`).
- Every finding is checked on a real system before it is marked
  "confirmed live" – say what was tested and what was not.
- Diagrams: the ASCII drawing in the Markdown file is the source, the SVG is
  generated with [`tools/render_ascii/`](tools/render_ascii/README.md).

### Commits

- One topic per commit, message starts with the file or folder
  (`02-Checks/ssl_check.sh: …`), body says *why*.
- Test `--apply` changes on a non-production host or an isolated copy, never
  on a live system first.

## Customer-data rule

**No customer data in this repository – not in files, file names, examples,
comments or commit messages.** Customer data is everything that identifies a
real installation: host and domain names, IP addresses, database / PDB /
schema names, Reports server and domain names, user names, people, company
and project names, certificates, configuration exports.

Use instead:

- the **demo data** of the test host ([README → Demo Data](README.md#demo-data)):
  `orafusion01.pipperr.local`, `10.10.10.124` / `10.10.10.0/24`, `FMWCDB` /
  `fmwpdb`, `fr_domain`, `repserver01`, `reportGPI`, user `gpi` – or
- generic placeholders where the reader must adapt the value
  (`<host>`, `<password>`, `fr_domain`).

Cookbooks from customer projects in `70-Customer-Projects/` are anonymised
to the demo data before they are committed.

### Pre-commit hook

[`tools/hooks/pre-commit`](tools/hooks/pre-commit) checks every commit –
only the **staged** lines and file names:

| Check | Blocks |
|---|---|
| customer names | entries of your local list `~/.config/ihw/customer_patterns` |
| forbidden files | `*.des3`, `environment.conf`, `setup.conf`, `*_sec.conf`, `ihw_export_*`, keys / keystores – also with `git add -f` |
| secrets | private keys, GitHub tokens, `password=<real value>` |
| private IPs | `10/8`, `172.16/12`, `192.168/16` except the demo net `10.10.10.0/24` |
| `bash -n` | staged `*.sh` with a syntax error |
| customer ZIPs | `70-Customer-Projects/tools/` changed but the ZIP is stale |

Install once per clone:

```bash
tools/hooks/install.sh
```

It sets `git config core.hooksPath tools/hooks` and creates
`~/.config/ihw/customer_patterns` (mode 600) from
[`customer_patterns.example`](tools/hooks/customer_patterns.example). Put the
names of **your** customers there – the list stays outside every clone and
never goes into git (it would publish exactly the names it protects).
Without the list the hook only warns that customer names are not checked.

A confirmed false positive: add an `allow:` line to your local list. Last
resort: `git commit --no-verify` – then check the diff by hand.

## Local checks before a push

```bash
tools/ci_lint.sh
```

Same as the GitHub Actions gate: `bash -n` on all scripts + ShellCheck
(errors block, warnings are reported; needs `shellcheck`, on Oracle Linux 9
from the `ol9_developer_EPEL` repository).

```bash
70-Customer-Projects/tools/make_customer_zip.sh --apply
```

After a change in `70-Customer-Projects/tools/bash` or `…/powershell` –
rebuilds the download ZIPs (the hook blocks a stale ZIP).
