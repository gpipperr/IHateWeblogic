---
nav_title: "ORDS / APEX – CSPU Nov 2026"
title: "ORDS 26.3.1 update and APEX 26.2.1 patch from the application server"
description: "German cookbook: update a standalone ORDS 26.x (Jetty, systemd) to 26.3.1 and apply the APEX 26.2 Patch Set Bundle 40040466 from the application server, step by step."
permalink: /70-Customer-Projects/OrdsApex_Patch_cspu_202611/
---

# ORDS update and APEX patch – CSPU November 2026

The CSPU November 2026 (Oracle CPU431, Database Products) marks
**ORDS 24.2.0 – 26.3.0** (up to CVSS 9.8) and **APEX 26.2.0**
(CVE-2026-114849 / -114850, 9.8) as affected. The fixes are
**ORDS 26.3.1** (`ords-latest.zip` since 2026-11-04) and the **APEX 26.2
Patch Set Bundle 40040466** (→ 26.2.1).

The cookbook (in German) is the short, manual way for an existing
installation. It does not use the IHateWeblogic scripts:

- [ORDS_APEX_Patch_Kochbuch_CSPU_Nov2026_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/OrdsApex_Patch_cspu_202611/ORDS_APEX_Patch_Kochbuch_CSPU_Nov2026_de.txt)

## Starting point

- ORDS 26.x runs **standalone (Jetty)** as a systemd service on the
  application server. The paths (ORDS software, `--config`, Java, unit) are
  read from the running process.
- Apache or Nginx sits in front and serves `/i/` from the APEX images
  directory.
- APEX 26.2 runs in a PDB. Everything is done from the application server:
  SQL*Plus there, with the connection of the ORDS pool.

## Steps in short

1. Write down the current state: process, unit, `/i/`, versions in the DB.
2. Download `ords-latest.zip` (OTN) and the APEX patch (APEX download page →
   MOS login).
3. Back up the ORDS config, the unit file and the `/i/` directory.
4. Unpack the new ORDS next to the old one (`ords-<version>`).
5. Stop the service and change the path in the unit (or `/etc/ords.conf`), or - if the old ORDS home is a symlink - only repoint the link (case C).
6. `ords --config <existing> install --db-only --admin-user "SYS AS SYSDBA"`:
   this upgrades `ORDS_METADATA` with the existing pool connection.
7. Start the service and test APEX.
8. Unpack the APEX patch, stop ORDS, copy `images/` over the `/i/`
   directory.
9. `NLS_LANG=American_America.AL32UTF8`, connect as SYS to the PDB, run
   `@catpatch.sql`.
10. Start ORDS and test APEX (About → 26.2.1).
11. Clean up after acceptance.

The ORDS schema upgrade and the APEX patch cannot be undone in the database.
The only way back is a database backup or restore point, taken before the
window.

## Related

- Scripted path on our own layout:
  - [12-APEX-Ords/06-patch-ords.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/12-APEX-Ords/06-patch-ords.sh) (ORDS);
  - [12-APEX-Ords/03-patch-apex.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/12-APEX-Ords/03-patch-apex.sh) (APEX);
  - [12-APEX-Ords/README.md](../../12-APEX-Ords/README.md) §6.
- Background: [ords_architecture.md](../../80-FMW-Architecture/ords_architecture.md).
- State before the window: customer tool `collect_ords_apex.sh`
  ([tools README](../tools/README.md)).
- Cycle overview: [09-Install/docs/00-patch-references.md](../../09-Install/docs/00-patch-references.md).
