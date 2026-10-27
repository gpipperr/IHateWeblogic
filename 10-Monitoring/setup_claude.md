# Claude Code on an FMW host – setup and hardening

How Claude Code is installed and locked down for the Claude-based parts of
the lib: the patch-cycle analysis
([patch_cycle_analysis.sh](patch_cycle_analysis.sh)) now, the proactive log
analysis ([README.md](README.md#architecture)) later. Check script:
[claude_setup_check.sh](claude_setup_check.sh); files to install:
[claude/](claude/).

> **WARNING – test and admin hosts only.**
> Claude Code is **never** installed or started on a production FMW server.
> Production data reaches Claude only as a collector archive
> (`70-Customer-Projects/tools/collect_fmw_env.sh --full`), analysed on a test
> or admin host. A host with `IHW_ENV_TYPE=prod` in `environment.conf` is
> refused by `claude_setup_check.sh` and `patch_cycle_analysis.sh`, and the
> guard hook denies every changing command there.

Facts checked against the Claude Code documentation (code.claude.com/docs,
settings / permissions / sandboxing / hooks / managed settings) with CLI
2.1.287 on 2026-10-27. Points marked **to verify** are confirmed only at the
first rollout.

## 1. Placement

```
 production FMW host                 analysis host (test host / admin VM)
 ─────────────────────               ─────────────────────────────────────
 IHW_ENV_TYPE=prod                   IHW_ENV_TYPE=test
 no Claude Code                      Claude Code + sandbox + guard
 collect_fmw_env.sh --full  ──scp──▶ Patch-Doku/<cycle>/env/   (patch analysis)
 (later: log dirs exported           (later: read-only mount of the log dirs,
  read-only)                 ──────▶  log analysis – to decide)
```

| Host | `IHW_ENV_TYPE` | Claude | Profile |
|---|---|---|---|
| our test host | `test` | yes – development of the lib | `maintainer` |
| customer admin / analysis VM | `test` | yes – patch analysis, later log analysis | `customer` |
| customer test FMW server | `test` | possible, analysis only | `customer` |
| any production server | `prod` | **no** | – |

## 2. Installation (as the analysis user, not root)

```bash
node --version                      # Node.js as required by Claude Code (test host: v20)
npm config set prefix ~/.npm-global # no root, as on our test host
npm install -g @anthropic-ai/claude-code@<version>   # pin a version
export PATH="$HOME/.npm-global/bin:$PATH"            # .bash_profile
claude --version
claude                              # first start: login (claude.ai account or API key)
```

- **Account:** the customer's own Claude account / API key, never ours, never
  in a file of the repo. Which account is used at the customer is agreed
  before the first session (section 7).
- **Updates:** deliberate only – the managed settings set
  `DISABLE_AUTOUPDATER=1`; update with `npm install -g …@<new version>` and
  re-run `claude_setup_check.sh`.
- **Egress:** Claude itself needs `api.anthropic.com:443`; the patch analysis
  additionally `www.oracle.com` (advisories). Proxy / firewall: see
  [weblogic_outbound_connections.md](../80-FMW-Architecture/weblogic_outbound_connections.md)
  and `02-Checks/egress_check.sh`; check 8 of `claude_setup_check.sh` tests
  both.

## 3. Data protection

What Claude sees is sent to Anthropic for processing:

| Claude reads | Claude never reads (deny rules + sandbox) |
|---|---|
| repo files, Oracle READMEs in `Patch-Doku/`, collector archive, configuration files (`config.xml`, `rwserver.conf`, `formsweb.cfg` …), logs | `*.des3`, `weblogic_sec.conf`, `boot.properties`, `SerializedSystemIni.dat`, `cwallet.sso`, `ewallet.p12`, `*.jks`, `*.key`, `.getMOSPatch.cfg`, `~/.ssh` |

- The collector archive contains host names, user names and paths – the
  customer approves its use (GDPR / data processing agreement with Anthropic
  on the customer's account) **before** the first analysis.
- Session transcripts stay local in `~/.claude/projects/` – retention: delete
  after the cycle (`cleanupPeriodDays` in user settings, or by hand).
- Customer data never goes into the repo; `Patch-Doku/` is gitignored.

## 4. Hardening – five layers

| # | Layer | What it does | Enforced by |
|---|---|---|---|
| 1 | Placement | no Claude on production (section 1) | this document, check 2 + 3 |
| 2 | Permission rules | `Read` deny for the secret files, `Edit` deny for `environment.conf`, `git push` = ask, bypass mode off; profile `customer` also auto mode off | managed settings |
| 3 | Sandbox | Bash and every child process: writes only in the working directory + temp, reads denied for the secret files found on the host, network only to the allowed domains | managed settings, bubblewrap + socat |
| 4 | Guard hook | `ihw_guard.sh` before every Bash call: `--apply`, OPatch apply/rollback, WLST, start/stop scripts, RCU / config.sh, sqlplus / rman / Data Pump, systemctl changes, sudo / su, `rm -r`, kill, package or crontab changes, `git push` → **ask** on `test`, **deny** on `prod` / unknown | managed settings, `/etc/claude-code/` (root-owned) |
| 5 | Environment type | `IHW_ENV_TYPE=test\|prod` in `environment.conf` (interview / `init_env.sh`); fixed into the hook command at install time – a later change of the conf makes the hook treat the host as `prod` | `environment.conf` + managed settings |

Why several layers (documented behaviour of Claude Code):

- **Permission rules** match the command text: `Read` / `Edit` deny rules
  cover Claude's file tools and the file commands Claude Code recognises in
  Bash (`cat`, `head`, `sed`, redirections …), not a script that opens a file
  itself; `Bash(...)` rules do not stop `sh -c '…'` or absolute paths.
- **The sandbox** is the OS-level boundary (bubblewrap) – but only for shell
  commands; Read / Edit / WebFetch run outside it. Hence both.
- **The hook** only sees the text, too, and a timed-out hook does not block
  (`onFailure: block` needs CLI 2.1.295+). It makes the intent visible and
  asks the user; the sandbox stops what slips through.
- **Managed settings** (`/etc/claude-code/managed-settings.json`) cannot be
  overridden by user, project or `--settings` values. The file must be
  **readable** by the analysis user (`0644 root:root`) – a root-only file is
  skipped and Claude starts *without* the policy. Hook script and settings
  are root-owned, so Claude cannot edit its own guard.

### Profiles

| | `customer` (default) | `maintainer` (our test host) |
|---|---|---|
| unsandboxed retry (`allowUnsandboxedCommands`) | off – what fails in the sandbox fails | allowed, every retry asks |
| auto mode | off (`disableAutoMode`) | allowed |
| network (sandbox) | `www.oracle.com` | + `*.oracle.com`, `github.com`, `localhost`, `127.0.0.1` |

On the test host the lib is developed: `opatch lspatches` (writes
`cfgtoollogs`), sqlplus to the RCU database, scripts that decrypt a `.des3`
file and `git push` fail inside the sandbox and are retried unsandboxed after
a prompt. **To verify** at the first rollout: `localhost` / IP entries in
`allowedDomains`, the `//**/` patterns in `Read` deny rules of a managed file.

### Install

```bash
./10-Monitoring/claude_setup_check.sh --profile customer --apply   # or maintainer
#   renders log/<date>/managed-settings.json (template + secret files of this host)
#   and prints the root commands:
dnf install -y bubblewrap socat
install -d -o root -g root -m 0755 /etc/claude-code
install -o root -g root -m 0755 <repo>/10-Monitoring/claude/ihw_guard.sh /etc/claude-code/ihw_guard.sh
install -o root -g root -m 0644 <repo>/log/<date>/managed-settings.json /etc/claude-code/managed-settings.json
```

Then start a new session: `/status` shows `Enterprise managed settings
(file)` in *Setting sources*; `claude doctor` lists rejected entries. Re-run
`--apply` after new secret files, a changed `IHW_ENV_TYPE` or a new template
(check 4 reports the difference).

Template: [claude/managed-settings.json.template](claude/managed-settings.json.template)
(placeholders `@IHW_ROOT@`, `@ENV_CONF_TARGET@`, `@IHW_ENV_TYPE@`; the script
adds the secret files to `sandbox.filesystem.denyRead` and the profile keys).
`allowManagedPermissionRulesOnly` is **not** set – the project / user allow
rules stay usable; a customer who wants only managed rules adds it.

## 5. Use cases on this sandbox

| Use case | Status | Inputs (read) | Outputs (write) |
|---|---|---|---|
| Patch-cycle analysis | implemented – `patch_cycle_analysis.sh`, [skill](patch_cycle_analysis_skill.md) | public Oracle pages (curl), `Patch-Doku/<cycle>/readmes/`, `env/` | `Patch-Doku/<cycle>/result/`; maintainer: repo docs |
| Proactive log analysis | concept – [README.md](README.md#architecture) | logs (local, or a read-only mount of the production log dirs – to decide), findings of the 01–07 checks | `10-Monitoring/reports/` |

The log analysis will run headless (`claude -p`, read-only tools, cron) in
the same sandbox and reports only the *unusual* entries – availability,
thresholds and known patterns stay with the customer's monitoring (Nagios,
Prometheus …). The read-only input / own output split above is the model for
it: inputs never writable, outputs only below the repo.

## 6. Check

```bash
./10-Monitoring/claude_setup_check.sh                      # profile customer
./10-Monitoring/claude_setup_check.sh --profile maintainer # our test host
journalctl -t ihw-claude                                   # guard decisions (ask / deny)
```

| # | Check | FAIL / WARN when |
|---|---|---|
| 1 | Claude CLI, auto-update | auto-update on |
| 2 | `IHW_ENV_TYPE` | `prod` (FAIL), not set (WARN), profile maintainer without `test` (FAIL) |
| 3 | WebLogic processes | running and the host is not `test` |
| 4 | managed settings | missing, not readable (FAIL), not root 0644, not equal to the rendering |
| 5 | bubblewrap, socat | not installed |
| 6 | guard hook | missing, not root 0755, differs from the repo copy; self-test ask / deny wrong (FAIL) |
| 7 | secret files | a file not in `denyRead` |
| 8 | egress | `api.anthropic.com` / `www.oracle.com` not reachable |

`patch_cycle_analysis.sh` runs the check before it starts Claude (FAIL on
`prod`, WARN otherwise).

## 7. Operations

- Version: pinned, updated deliberately, check afterwards.
- Account at the customer: the customer's own (API key or Team / Enterprise
  login); agree who pays and who sees the usage.
- Transcripts: `~/.claude/projects/` – delete after the cycle at the
  customer.
- Never run `claude --dangerously-skip-permissions` (refused by the managed
  settings anyway); never edit a script while a user runs it.
