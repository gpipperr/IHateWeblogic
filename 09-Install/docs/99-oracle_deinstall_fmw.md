# 99 – Deinstall FMW (keep the database)

Script: `09-Install/99-oracle_deinstall_fmw.sh`

Removes the complete Fusion Middleware installation (Forms/Reports 14.1.2 +
WebLogic) from a host so it can be rebuilt from scratch with
`01-setup-interview.sh` and the current patch level — while leaving a
repository database on the **same host** untouched. Typical use: a test host
whose state has become unclear after many experiments.

> **Irreversible.** Default is a read-only dry-run. `--apply` additionally
> requires typing `DEINSTALL <hostname>` before anything is changed.

---

## What is removed / what is kept

| Removed (FMW) | Kept |
|---|---|
| `$ORACLE_HOME` – first via the Oracle deinstaller, then any leftovers | Database homes under `$ORACLE_BASE/product/`, `oradata/`, `admin/<DB_NAME>/`, `audit/`, `flash_recovery_area/`, `autoupgrade/`, `cfgtoollogs/` |
| `$DOMAIN_HOME` and the parent `domains/` directory if it is then empty | `$ORACLE_BASE/diag/` – on a shared host this is the **database** ADR (`rdbms`, `tnslsnr`) |
| Autostart (`30-configure_autostart.sh`): unit `fmw-<DOMAIN_NAME>.service` (disabled + removed before the stop) and `$ORACLE_BASE/admin/<DOMAIN_NAME>` | Every other directory under `$ORACLE_BASE/admin` (database admin dirs such as `admin/<DB_NAME>`) |
| `~/oradiag_oracle` – client ADR of the FMW tools (`rwrun`, `rwconverter`, … crash incidents) | Central inventory – only the FMW home entry is removed (by the deinstaller) |
| `REPORTS_TMP` and `/tmp/ihw_*` staging leftovers, if present | `JDK_HOME` (installed by root in Phase 0), `PATCH_STORAGE` (downloads are reused) |
| | This repository incl. `*.des3` password files, `log/`, `07-Maintenance/ConfigBackup/` |
| | Nginx, OS settings, `FORMS_CUSTOMER_DIR`/`REPORTS_CUSTOMER_DIR` (customer data) |
| | RCU schemas in the database (see [Reinstall](#reinstall-afterwards)) |
| | ORDS / APEX (`$ORACLE_BASE/product/ords`, `product/apex`, `/srv/apex`, units `ords@ords_N`, `/var/log/ords_N`) – under `product/`, never touched; ORDS keeps running |
| | Forms client bundle `FORMS_CLIENT_DIR` (`/srv/formsWeb`), the `TNS_ADMIN` directory (`$ORACLE_BASE/admin/tns_names`), the local CA (`$ORACLE_BASE/admin/pki`) |
| | crontab of `oracle` (e.g. `10-Monitoring/cert_expiry_check.sh`) – remove with `--cron --remove --apply` if the host is retired |

## Why the database needs special care

Background – which RCU schemas the domain uses and why the OPSS store is bound
to this domain: [rcu_middleware_architecture.md](../../80-FMW-Architecture/rcu_middleware_architecture.md);
inventory, homes and what lives where:
[weblogic_middleware_architecture.md §7](../../80-FMW-Architecture/weblogic_middleware_architecture.md#7-where-is-what--homes-configuration-logs);
the local RCU DB itself: [60-RCU-DB-19c/README.md](../../60-RCU-DB-19c/README.md).

On a host where the repository database runs locally (e.g. built with
`60-RCU-DB-19c/`), FMW and DB **share one central inventory**. Deleting the
inventory, using `pkill -u oracle`, or removing `$ORACLE_BASE/diag/` would
damage the database. The script therefore:

- reads the inventory location from `/etc/oraInst.loc` (the value the
  installers actually use), not from `ORACLE_INVENTORY` in `environment.conf`;
- identifies the FMW home by `LOC == $ORACLE_HOME` in `inventory.xml` and
  refuses to touch any other registered home;
- stops only WebLogic/Forms/Reports processes by exact pattern, never `ora_*`
  or `tnslsnr`;
- routes every delete through a guard (`_safe_rm_target`) that rejects empty
  paths, `/`, anything outside `ORACLE_BASE` (except the explicit temp/ADR
  targets), any registered DB home, `product/`, `oradata/` and the repository.

## Steps

### 0. Preflight (always, read-only – any failure aborts)

1. Load `environment.conf` (`ROOT_DIR` must be set, `SEC_CONF` is relative to it).
2. **Password gate** – decrypt every password file in a subshell and check the
   values are non-empty, without printing them:
   `weblogic_sec.conf.des3` (WebLogic admin), `db_sys_sec.conf.des3`
   (`DB_SYS_PWD`, `DB_SCHEMA_PWD`), `mos_sec.conf.des3` (`MOS_PWD`). The files
   live in the repository, outside the delete area, and are keyed to this
   machine's system identifier — but if one can no longer be decrypted, it must
   be fixed **before** the domain (and its `boot.properties`) is gone.
3. Read the central inventory, show all registered homes, confirm the FMW home.
4. Show database status (pmon/listener) – information only.
5. List every delete and keep target with its size.

### 1. Backup

- `07-Maintenance/backup_config.sh --apply`
- Additionally copy `$DOMAIN_HOME/config/config.xml` and the real
  `environment.conf` (symlink target) into the same `ConfigBackup/<timestamp>/`.

### 2. Stop everything FMW (database keeps running)

- `01-Run/startStop.sh stop-all --apply`
- Gate: `require_wls_stopped` (shared library).
- Remaining FMW processes are stopped by exact pattern only: `weblogic.Name=`,
  `weblogic.nodemanager`, process names `rwrun`, `rwserver`, `rwengine`,
  `frmweb`, and `Xvfb` on `DISPLAY_VAR`.

### 3. Deinstall via OUI

The FMW 14.1.2 Forms & Reports home contains two distributions (see
`$ORACLE_HOME/inventory/registry.xml`). They are removed in reverse install
order:

```bash
$ORACLE_HOME/oui/bin/deinstall.sh -silent -distributionName "Oracle Forms Reports"
$ORACLE_HOME/oui/bin/deinstall.sh -silent -distributionName "WebLogic Server for FMW"
```

Afterwards the FMW home entry in `inventory.xml` is marked `REMOVED="T"`
(OUI does not delete the line — confirmed on FMW 14.1.2, 2026-10-14), while all
other homes are still present and unmarked. If the deinstaller fails, the script stops
and deletes nothing; the OUI log is in `<inventory>/logs/`.

### 4. Remove leftovers

`$ORACLE_HOME` (whatever the deinstaller leaves), `$DOMAIN_HOME`, empty
`domains/`, `~/oradiag_oracle`, `REPORTS_TMP`, `/tmp/ihw_*` – all via the guard.

### 5. Put environment.conf aside

The symlink target (e.g. `00-Setup/environments/prod.conf`) is renamed to
`<name>.pre_deinstall_<timestamp>` and the `environment.conf` symlink is
removed, so the interview starts clean. The `*.des3` files stay in place —
`01-setup-interview.sh` detects them and keeps the passwords
(`[existing encrypted file]`).

## Reinstall afterwards

1. `09-Install/01-setup-interview.sh --apply`
   - **Set `ORACLE_INVENTORY` to the existing central inventory** shown by the
     script (e.g. `/u01/app/oracle/oraInventory`), not the suggested default
     `$(dirname ORACLE_BASE)/oraInventory`. Otherwise
     `03-root_user_oracle.sh` rewrites `/etc/oraInst.loc` and the database
     homes disappear from the inventory the installers see.
2. Phase 0–3 as usual (`09-Install/README.md`).
3. Recreate the RCU schemas — the OPSS security store in the old schemas is
   bound to the old domain's encryption key and cannot simply be reused:
   ```bash
   ./09-Install/07-oracle_setup_repository.sh --drop
   ./09-Install/07-oracle_setup_repository.sh --apply
   ```
   This needs `rcu` from the **new** `$ORACLE_HOME`, so it can only run after
   Phase 3; the deinstall script deliberately does not drop the schemas.
4. Continue with `08-oracle_setup_domain.sh` and the remaining phases.

## Manual procedure (without the script)

```bash
./01-Run/startStop.sh stop-all --apply
cat /etc/oraInst.loc                                  # inventory location
grep '<HOME ' <inventory>/ContentsXML/inventory.xml   # FMW home vs. DB homes
$ORACLE_HOME/oui/bin/deinstall.sh -silent -distributionName "Oracle Forms Reports"
$ORACLE_HOME/oui/bin/deinstall.sh -silent -distributionName "WebLogic Server for FMW"
grep '<HOME ' <inventory>/ContentsXML/inventory.xml   # FMW home now REMOVED="T"
rm -rf "$ORACLE_HOME" "$DOMAIN_HOME" ~/oradiag_oracle  # check each path first!
```

## Verification after a run

- `inventory.xml`: database homes unchanged, FMW home marked `REMOVED="T"`.
- Database still up: `pgrep -a ora_pmon`, `lsnrctl status`, a `sqlplus`
  connection to the PDB.
- Password files still decrypt (`load_secrets_file` / `load_weblogic_password`).
- `$ORACLE_HOME`, `$DOMAIN_HOME`, `~/oradiag_oracle` are gone.
