# Step 5b – 10-oracle_boot_properties.sh

**Script:** `09-Install/10-oracle_boot_properties.sh`
**Runs as:** `oracle`
**Phase:** 5 – Configuration & Validation

---

## Purpose

Create `boot.properties` files for the WebLogic AdminServer and all managed
servers so that WebLogic starts **without an interactive password prompt**.

Without this file WebLogic blocks on startup waiting for credentials to be
typed at the console — which makes unattended or scripted starts impossible.

This script must run **before the first domain start**.

> **Note:** `08-oracle_setup_domain.sh` already writes AdminServer's
> `boot.properties` right after domain creation, so it can be started
> immediately without waiting for this step. Re-running this script overwrites
> that file with identical content (harmless) and additionally covers the
> managed servers (`WLS_FORMS`, `WLS_REPORTS`), which `08-oracle_setup_domain.sh`
> does not.

---

## Background

WebLogic reads startup credentials from:

```
$DOMAIN_HOME/servers/<server>/security/boot.properties
```

The file is written in plaintext initially:

```
username=weblogic
password=admin1234
```

On the **first successful start** WebLogic rewrites the file with AES-encrypted
values:

```
username={AES256}abc123...
password={AES256}xyz789...
```

(FMW 14.1.2 writes `{AES256}`, 12c `{AES}` – the script checks for the prefix
`{AES`.) After that the plaintext is gone and the file is safe to keep on
disk. The key is the domain's `security/SerializedSystemIni.dat` – the
encrypted values work only in this domain.

Without `boot.properties` a server started by the Node Manager / `startStop.sh`
dies at once (`BEA-090782`) – why the Node Manager needs it:
[who starts whom](../../80-FMW-Architecture/weblogic_middleware_architecture.md#4-who-starts-whom--the-control-chain).

---

## Without the Script (manual)

```bash
# AdminServer
mkdir -p $DOMAIN_HOME/servers/AdminServer/security
cd       $DOMAIN_HOME/servers/AdminServer/security
cat > boot.properties <<EOF
username=weblogic
password=admin1234
EOF
chmod 600 boot.properties

# WLS_REPORTS (repeat for every managed server)
mkdir -p $DOMAIN_HOME/servers/WLS_REPORTS/security
cd       $DOMAIN_HOME/servers/WLS_REPORTS/security
cat > boot.properties <<EOF
username=weblogic
password=admin1234
EOF
chmod 600 boot.properties
```

> The password must match the WebLogic Admin password stored in
> `weblogic_sec.conf.des3`.

---

## With the Script

The script reads credentials automatically from `weblogic_sec.conf.des3`
(decrypted via the machine-local key) and writes `boot.properties` for all
relevant servers:

```bash
# Dry-run – show which files would be written
./09-Install/10-oracle_boot_properties.sh

# Write boot.properties
./09-Install/10-oracle_boot_properties.sh --apply
```

### Servers covered

All `<server>` entries of `$DOMAIN_HOME/config/config.xml` (AdminServer,
WLS_FORMS, WLS_REPORTS, ...). A missing `servers/<name>/security/` directory is
**created** – on a fresh domain it only appears with the first start, and that
first start needs `boot.properties`: a production-mode managed server started
via `nohup` without it dies at once (`BEA-090782 ... System Console ... not
found`, `shutDownStatus=255`, confirmed 2026-10-15). Before that date managed
servers were skipped until their directory existed.

### Skip logic

If a `boot.properties` already contains `{AES` (encrypted by WebLogic –
`{AES256}` in 14.1.2, `{AES}` in older releases) the file is **not
overwritten** — the entry is reported as `OK … already encrypted`.

---

## What the Script Does

| Step | Action |
|---|---|
| 1 | Validate `DOMAIN_HOME` from `environment.conf` |
| 2 | Decrypt `weblogic_sec.conf.des3` → `WL_USER` + `INTERNAL_WL_PWD` |
| 3 | For each server: create `security/` dir (chmod 750) |
| 4 | Write `boot.properties` with `username=` and `password=` (chmod 600) |
| 5 | Clear password from memory |

---

## File Permissions

| Path | Permissions | Reason |
|---|---|---|
| `servers/<name>/security/` | `750` | Directory not world-readable |
| `servers/<name>/security/boot.properties` | `600` | Plaintext until first start |

---

## Related Scripts

| Script | Purpose |
|---|---|
| `00-Setup/weblogic_sec.sh` | Store WebLogic credentials (prerequisite) |
| `09-Install/09-oracle_configure.sh` | Calls this script as Step 0 |
| `01-Run/startStop.sh` | Warns if boot.properties is missing before start |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `startWebLogic.sh` hangs waiting for input | `boot.properties` missing | Run this script with `--apply` |
| `Decryption failed` | Wrong machine or corrupted `.des3` file | Re-run `00-Setup/weblogic_sec.sh --apply` |
| `Server directory not found` | Domain not yet created | Run `08-oracle_setup_domain.sh` first, then this script |
| File already encrypted – no overwrite | WebLogic already started once | No action needed |
