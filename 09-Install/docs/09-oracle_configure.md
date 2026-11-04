# Step 5a – 09-oracle_configure.sh

**Script:** `09-Install/09-oracle_configure.sh`
**Runs as:** `oracle`
**Phase:** 5 – Configuration & Validation

```bash
./09-Install/09-oracle_configure.sh                 # dry-run: planned steps
./09-Install/09-oracle_configure.sh --apply         # all steps (1 is interactive)
./09-Install/09-oracle_configure.sh --apply --skip-fonts
```

Checked against the script 2026-11-03. Before it: `08-oracle_setup_domain.sh
--apply`; the domain is **not** started yet.

---

## Purpose

Apply the standard configuration to a freshly created domain **before its first
start**: boot.properties, JVM settings (SecureRandom, heap per server), font OS
packages, a validation of the domain artifacts and an initial backup.

This script does **not implement new functionality** — it orchestrates existing
scripts from modules 00–07.

> **Split 2026-10-15:** the font configuration (`deploy_fonts`, font cache,
> `uifont.ali`, font path) and the `cgicmd.dat` default key moved to
> [`14b-oracle_reports_fonts.sh`](14b-oracle_reports_fonts.md). They need the
> ReportsTools component (created by `13-oracle_setup_reports.sh`) and the
> WLS_REPORTS application directory (exists only after the first start of
> WLS_REPORTS). Right after `08-` none of that exists — `uifont_ali_update.sh`
> failed with "Target directory does not exist" (confirmed 2026-10-15).

---

## Without the Script (manual)

Same order as the script, after `08-`, domain not started:

```bash
# 0. boot.properties (AdminServer; WLS_FORMS / WLS_REPORTS dirs follow at the first start)
./09-Install/10-oracle_boot_properties.sh --apply

# 1. JVM settings (interactive, backup first):
#    securerandom.source=file:/dev/./urandom in java.security of JAVA_HOME (oracle profile = JDK_HOME),
#    setUserOverrides.sh: heap per server + Log4j guard (LOG4J_FORMAT_MSG_NO_LOOKUPS=true)
./02-Checks/weblogic_performance.sh --apply

# 1b. TNS_ADMIN for every WebLogic JVM (export + -Doracle.net.tns_admin in setUserOverrides.sh)
./02-Checks/tns_admin_check.sh --apply

# 2. font OS packages (runs "sudo dnf install" itself when not root)
./04-ReportsFonts/get_root_install_libs.sh --apply

# 3. check the domain artifacts
ls -l $DOMAIN_HOME/config/config.xml $DOMAIN_HOME/bin/setDomainEnv.sh \
      $DOMAIN_HOME/bin/setUserOverrides.sh $DOMAIN_HOME/nodemanager/nodemanager.properties \
      $DOMAIN_HOME/servers/AdminServer/security/boot.properties
grep -E '^Listen(Address|Port)' $DOMAIN_HOME/nodemanager/nodemanager.properties

# 4. initial config backup (without --apply it only lists)
./07-Maintenance/backup_config.sh --apply
```

> Font deployment, font cache, `uifont.ali`, font path and `cgicmd.dat` follow
> later in [`14b-oracle_reports_fonts.sh`](14b-oracle_reports_fonts.md).

---

## What the Script Does

Background – why own JVM settings and `TNS_ADMIN` go into
`setUserOverrides.sh` (sourced by Oracle's `setDomainEnv.sh`, which patches
and `updateDomain` rewrite): [who starts whom](../../80-FMW-Architecture/weblogic_middleware_architecture.md#4-who-starts-whom--the-control-chain).

Orchestrates the configuration sequence:

| Order | Action | Script called | Doc |
|---|---|---|---|
| 0 | boot.properties | `09-Install/10-oracle_boot_properties.sh --apply` | [10-oracle_boot_properties.md](10-oracle_boot_properties.md) |
| 1 | JVM settings | `02-Checks/weblogic_performance.sh --apply` – **interactive** (asks per setting) | |
| 1b | TNS_ADMIN for all WebLogic JVMs | `02-Checks/tns_admin_check.sh --apply` | `export TNS_ADMIN` + `-Doracle.net.tns_admin` in `setUserOverrides.sh` (value from `environment.conf`), [tns_admin_check.sh](../../02-Checks/README.md#tns_admin_checksh) |
| 2 | Font OS packages | `04-ReportsFonts/get_root_install_libs.sh --apply` – as root, or as oracle when `sudo -n -l /usr/bin/dnf install …` is allowed (the rule of `03-root_user_oracle.sh`; the script calls `sudo dnf` itself); otherwise the manual command + the package list | |
| 3 | Domain validation | verify domain artifacts + `nodemanager.properties` | |
| 4 | Config backup | `07-Maintenance/backup_config.sh --apply` | |
| – | Fonts, uifont.ali, cgicmd.dat | **later:** `14b-oracle_reports_fonts.sh` | [14b-oracle_reports_fonts.md](14b-oracle_reports_fonts.md) |

> Step 2 is skipped with `--skip-fonts`.
>
> Expected on a fresh domain (not errors): `10-oracle_boot_properties.sh` warns
> that `servers/WLS_REPORTS` does not exist yet (created on first start – `10-`
> runs again in Phase 6), `weblogic_performance.sh` creates `setUserOverrides.sh`.

Each called script reports its own OK/WARN/FAIL. The orchestrator counts per
step: rc ≥ 2 = FAIL (exit 2), rc 1 = WARN; a missing called script stops it
in the pre-checks. Unknown options: exit 1. At the end it prints the Phase 6
order (`detect_env_conf.sh`, `10-` … `14b-`).

> Until 2026-11-03 step 2 tested `sudo -n true` – false with the restricted
> sudoers of `03-` (only `dnf install *` etc.), so the packages were never
> installed automatically on such a host; a failed step was only a WARN.

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show what would be configured |
| `--apply` | Execute all configuration steps |
| `--skip-fonts` | Skip the font OS package step |
| `--help` | Show usage |

---

## Notes

- This script is safe to re-run — all called scripts are idempotent (read-only without `--apply`)
- Font OS packages need root or the `dnf install` sudo rule; without it the
  script shows the manual command and the missing packages
- The domain does not need to be running for this step — configuration files are
  written directly
