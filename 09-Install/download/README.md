# download – patch lists per cycle

The patch numbers of the library live **here**, not in the scripts and not in
`oracle_software_version.conf`. One CSV row per patch file; the same file is
read by

- the library – `09-Install/oracle_software_version.conf` loads
  `patches_fmw.csv` and sets the variables the scripts have always used
  (`INSTALL_PATCHES`, `WLS_SPB_PATCH_NR`, `JDK_PATCH_NR`, …); `04-oracle_pre_download.sh --mos`
  downloads with the tool below, `05-`/`06-` apply in row order;
- the standalone download tool
  [70-Customer-Projects/tools/mos_patch_download.sh](../../70-Customer-Projects/tools/README.md#mos_patch_downloadsh)
  – no library, no `environment.conf`: Java + getMOSPatch.jar + MOS account.

| File | Content | Maintained |
|---|---|---|
| [patches_fmw.csv](patches_fmw.csv) | OPatch, WLS Stack Patch Bundle, FMW Infrastructure bundles, Forms/Reports QPRs + common patches, JDK (server + Windows client), standalone CVU, APEX patch | every CPU / CSPU / Security Alert ([patch-cycle analysis](../../10-Monitoring/patch_cycle_analysis_skill.md)) |
| [patches_db.csv](patches_db.csv) | 19c RCU repository: OPatch, OJVM, Data Pump bundle, DB-home JDK (RU row: open, see header) | DB RU cycle – only needed for the offline route; online AutoUpgrade loads the set itself |

The **base software** (eDelivery `V*.zip`, 19c base ZIP) is not in a CSV:
eDelivery cannot be scripted with getMOSPatch, and it changes only per
release – file names and SHA-256 stay in `oracle_software_version.conf` /
`60-RCU-DB-19c/environment_db.conf`; download in the browser and copy.

## Format

```
patch;platform;file_regexp;required;step;description;dir;sha256
40125898;226P|2000P;p40125898_141200_Generic\.zip;yes;spb;WLS Stack Patch Bundle 14.1.2.0.261007;patches/40125898;ad9b79…
```

| Column | Meaning |
|---|---|
| `patch` | MOS patch number (the same number may appear twice – e.g. JDK 35702194 for Linux and Windows) |
| `platform` | MOS platform code, alternatives with `\|`: `226P` Linux x86-64, `2000P` Generic, `233P` Windows x64 (list: `java -jar getMOSPatch.jar patch=<nr> reset=yes`) |
| `file_regexp` | exact file of the patch (Java regex, whole name) – selects the product-version variant; the presence check uses it too |
| `required` | `yes` / `optional` – for the library the role decides (below) |
| `step` | **role** in the library (table below); in the customer lists of `70-Customer-Projects/` the cookbook step |
| `description` | free text |
| `dir` | target below `PATCH_STORAGE` (tool: below `-d`); empty = `<patch>` |
| `sha256` | SHA-256 at analysis time – **soft check** (below) |

Roles of `patches_fmw.csv` (rows of one role in apply order):

| Role | Variable | Downloaded when | Applied by |
|---|---|---|---|
| `opatch` | `OPATCH_UPGRADE_PATCH_NR` | always (present = also when bundled in the SPB) | `05-` (copy in the SPB preferred) |
| `spb` | `WLS_SPB_PATCH_NR` | always | `05-` (`opatch napply`) |
| `wls` | `INSTALL_PATCHES` | always | `05-` |
| `fr_common` | `INSTALL_PATCHES_FR_COMMON` | always | `06-` |
| `reports` / `forms` | `INSTALL_PATCHES_REPORTS` / `_FORMS` | Reports always / Forms only with Forms in `INSTALL_COMPONENTS` | `06-` |
| `fr_optional` | `INSTALL_PATCHES_FR_OPTIONAL` | `REPORTS_BIDIPARENTHESIS=YES` | `06-` |
| `jdk` | `JDK_PATCH_NR` | always | `02b- --upgrade-jdk`, `07-Maintenance/80-` |
| `client_jdk` | `CLIENT_JDK_PATCH_NR`, `CLIENT_JDK_PLATFORM` | `FORMS_CLIENT_DIST=true` (Forms) | `40-oracle_forms_client_bundle.sh` |
| `cvu` | `DB_CVU_PATCH_NR`, `DB_CVU_REGEXP` | `LOCAL_REP_DB=true` | `60-RCU-DB-19c/00b-` |
| `apex` | `APEX_PATCH_NR`, `APEX_PATCH_PLATFORM` | `INSTALL_APEX=true` | `12-APEX-Ords/03-` |

Cycle values that are not patch numbers stay in `oracle_software_version.conf`:
`PATCH_CYCLE*`, `OPATCH_VERSION_MIN/_INSTALL`, `WLS_SPB_VERSION`,
`WLS_SPB_MARKER_PATCH`, `WLS_SPB_CHECK_BUGS`, `JDK_VERSION_MIN`.

## SHA-256 – soft check

The value is the digest at the time of the analysis (MOS "Digest" or the
`patches_sha256.csv` the tool writes). Oracle re-releases ZIPs under the same
patch number – the JDK patch 35702194 with every update, other patches after
a fix of the package. A different value therefore only **WARNs** (tool exit 1,
`05-`/`06-` before the apply) – compare the digest on MOS, then update the
row. Empty = no check. The hard check is `unzip -t` (tool) and the OPatch
package check of `05-`/`06-` (`check_patch_zip`).

## Calls

```bash
# library, host with MOS access – roles from environment.conf
./09-Install/04-oracle_pre_download.sh --apply --mos

# host WITHOUT MOS access (OCI private subnet, egress allow-list):
# 1. on a host that may (share, admin workstation) – no library needed
cp 70-Customer-Projects/tools/mos_patch_download.sh 09-Install/download/patches_fmw.csv <share>/
cd <share> && ./mos_patch_download.sh -c patches_fmw.csv -d <share>/patch_storage --all          # plan
cd <share> && ./mos_patch_download.sh -c patches_fmw.csv -d <share>/patch_storage --all --apply  # download
#    only some roles: --steps spb,wls,fr_common,reports,forms,jdk,opatch
# 2. copy to the target host (same layout as PATCH_STORAGE)
rsync -a <share>/patch_storage/ oracle@<target>:$PATCH_STORAGE/
# 3. target host: inventory only, nothing is downloaded
./09-Install/04-oracle_pre_download.sh
```

`--all` takes the optional rows too (client Java, CVU, opatch) – without it
only `required=yes`. The tool writes `patches_sha256.txt`/`.csv` and its log
into the `-d` directory.

## New cycle

1. Patch-cycle analysis (`10-Monitoring/patch_cycle_analysis.sh`) → new
   numbers, file names, digests.
2. Edit `patches_fmw.csv` (and the cycle values in the conf); keep the old
   state in git – no copy per cycle needed.
3. `04-oracle_pre_download.sh --apply --fresh-patches --mos` (or the tool on
   the share host), then `05-`/`06-` / `07-Maintenance/81-82`.
