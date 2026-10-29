# Step 02b – Java Installation

> Certificates, keys and trust stores of the whole stack (terms, where what lives, who needs what, customer PKI / TLS interception): [certificates_trust_stores.md](../../80-FMW-Architecture/certificates_trust_stores.md)

**Script:** `09-Install/02b-root_os_java.sh`
**Runs as:** `root`
**Phase:** 0 – OS Preparation (bootstrap JDK); again after `04-oracle_pre_download.sh --mos`
with `--upgrade-jdk` – **before** `05-` (the FMW installer and `createDomain`
write the JDK path)

```bash
./09-Install/02b-root_os_java.sh                          # check only
./09-Install/02b-root_os_java.sh --apply                  # phase 0: install JDK 21, alternatives, jps, SecureRandom
./09-Install/02b-root_os_java.sh --apply --upgrade-jdk    # JDK of the patch cycle from patches/<JDK_PATCH_NR>/
```

| Option | Effect |
|---|---|
| `--apply` | install JDK, create the `jdk-21` symlink, register `alternatives`, `jps`, SecureRandom fix |
| `--upgrade-jdk` | install the JDK 21 of `JDK_PATCH_NR` from the patch repository next to the old one if newer, repoint `JDK_HOME` (needs `--apply`) |
| `--skip-oracle` | skip the Oracle JDK part (already installed) |
| `--with-openjdk` | additionally install OpenJDK 21 via dnf (parallel, not for WebLogic) |

Background – two JDKs on an FMW host (`JDK_HOME` for WebLogic / Node Manager /
OPatch, `oracle_common/jdk` for the Reports engines and tools):
[weblogic_middleware_architecture.md §1](../../80-FMW-Architecture/weblogic_middleware_architecture.md#1-terms--the-four-homes),
[report_engine_architecture.md §1](../../80-FMW-Architecture/report_engine_architecture.md#1-the-parts).

---

## License Overview

> **Rule:** Oracle JDK may be used without a paid license **only** when it is used
> exclusively as the runtime for another Oracle product (WebLogic, Forms, Reports).
> Any use outside of Oracle products (CLI tools, cron jobs, custom apps) requires
> either a paid Oracle Java SE subscription or a switch to OpenJDK for those uses.
>
> Reference: **Oracle Support Doc ID 1557737.1**
> _Support Entitlement for Java SE When Used As Part of Another Oracle Product_

| Usage scenario | License required? |
|---|---|
| WebLogic uses Java internally (embedded JDK / `JAVA_HOME`) | **No** |
| Java applications deployed on WebLogic (using it as middleware) | **No** |
| Java used outside WebLogic (CLI tools, cron jobs, other apps on same host) | **Yes** |

See also:
- https://redresscompliance.com/decoding-oracle-java-licensing-java-licensing-changes-2023.html
- https://www.oracle.com/in/a/ocom/docs/corporate/pricing/java-se-subscription-pricelist-5028356.pdf

---

## Decision: Which Java for WebLogic?

**For WebLogic / FMW: use Oracle JDK — not OpenJDK.**

The reason is practical: Oracle Support will always ask for the Java version and
vendor when a service request is opened. Using OpenJDK immediately triggers the
question whether it is certified and supported in that combination. Oracle JDK
avoids this conversation entirely.

Since the FMW host uses Java exclusively for Oracle products (WebLogic, Forms,
Reports), Oracle JDK is license-free under Doc ID 1557737.1.

**OpenJDK can be installed in parallel** via `alternatives` for system tools or
other uses, but `JAVA_HOME` for WebLogic must explicitly point to the Oracle JDK —
not to whatever `alternatives` selects as the system default.

| JDK | Used for | Managed via |
|---|---|---|
| Oracle JDK 21 | WebLogic / Forms / Reports | `JAVA_HOME` in oracle `.bash_profile` |
| OpenJDK (optional) | OS tools, parallel installs | `alternatives` system default |

---

## Option A – Oracle JDK 21 (primary, for WebLogic)

### Download URLs

| File | URL |
|---|---|
| Installer (latest) | `https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.tar.gz` |
| SHA256 checksum | `https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.tar.gz.sha256` |
| All versions / RPM | https://www.oracle.com/java/technologies/downloads/ |

> The `/latest/` URL stays at **21.0.12.1** – the last JDK 21 release under
> the NFTC (September 2026). Later updates: MOS Patch 35702194, see
> "Patch-cycle minimum and upgrade" below. SHA256 is verified automatically
> by `02b-root_os_java.sh`.

### Installer search order in 02b-root_os_java.sh

The script searches in this priority order:

1. **`$PATCH_STORAGE`** – if configured in `environment.conf`, searches for `jdk-21*.tar.gz` / `*.rpm`
2. **`/tmp`** – pre-placed installer (`scp jdk-21_linux-x64_bin.tar.gz root@server:/tmp/`)
   — SHA256 is always verified (read-only, no `--apply` required)
3. **Oracle CDN** – download offered interactively (default: `n`); internet access required
   — SHA256 verified after download; on mismatch the file is deleted immediately

The download itself does **not** require `--apply` (file lands in `/tmp`).
Only the extraction requires `--apply`.

### Installation via tar.gz (recommended for FMW)

Preferred: the JDK lives under `ORACLE_BASE`, independent of system paths and
protected from OS package updates.

```bash
# Extract – JDK stays INDEPENDENT of FMW_HOME
tar xf jdk-21_linux-x64_bin.tar.gz -C /u01/app/oracle/java/

# Result: /u01/app/oracle/java/jdk-21.0.10/  (version depends on download date)
```

Create a stable symlink so `JAVA_HOME` does not need to change on patch updates:

```bash
# Script creates this automatically:
ln -sfn /u01/app/oracle/java/jdk-21.0.10 /u01/app/oracle/java/jdk-21
# → JAVA_HOME=/u01/app/oracle/java/jdk-21  (always stable)
```

### Patch-cycle minimum and upgrade (`--upgrade-jdk`)

**Where JDK 21 updates come from (since October 2026).** Oracle's download
page: "JDK 21 will receive updates under the NFTC, until September 2026, a
year after the release of the next LTS. Subsequent JDK 21 updates will be
licensed under the Java SE OTN License" (checked 2026-10-20). The public
`/java/21/latest/` link therefore stays at **21.0.12.1** – every later update
comes from My Oracle Support as **Patch 35702194** (`JDK_PATCH_NR`; one patch
number for "the current JDK 21", the Linux ZIP contains
`jdk-21.0.x_linux-x64_bin.tar.gz`, `.rpm`, `.deb`, `SHA256_VALUES` – about
565 MB, confirmed by download 2026-10-20). Use with Oracle products only:
Doc ID 1557737.1.

**One download place:** the MOS patch is downloaded with all other patches
by `04-oracle_pre_download.sh --apply --mos` into
`$PATCH_STORAGE/patches/$JDK_PATCH_NR/`. `02b-` and `07-Maintenance/80-`
never download a JDK update themselves – they only look into the patch
repository.

`oracle_software_version.conf`: `JDK_PATCH_NR`, `JDK_VERSION_MIN` (minimum
of the current patch cycle, CSPU Sep 2026: **21.0.12.1**). The script warns
if the JDK at `JDK_HOME` is older.

```bash
./09-Install/02b-root_os_java.sh --upgrade-jdk           # dry-run: version in the patch repository
./09-Install/02b-root_os_java.sh --apply --upgrade-jdk   # upgrade
./07-Maintenance/80-patch_java_os.sh --apply             # same, as maintenance step (domain stopped)
```

What `--upgrade-jdk` does:

1. Looks for `p<JDK_PATCH_NR>_*_Linux-x86-64.zip` in
   `$PATCH_STORAGE/patches/<JDK_PATCH_NR>/`. **Not there → WARN** with the
   hint `04-oracle_pre_download.sh --apply --mos`, nothing else happens.
2. Reads the JDK version from the tarball inside the ZIP. Not newer than the
   JDK at `JDK_HOME` → OK, nothing to do (idempotent). Below
   `JDK_VERSION_MIN` → WARN (the repository holds an old cycle – download again
   with `--fresh-patches`).
3. Refuses to run while any JVM uses this JDK (stop WebLogic first).
4. Extracts the tarball to `$PATCH_STORAGE/jdk/` and verifies its SHA-256
   against `SHA256_VALUES` of the ZIP.
5. Extracts next to the current JDK and repoints the `jdk-21` symlink. The old
   directory stays – rollback: `ln -sfn <old jdk dir> /u01/app/oracle/java/jdk-21`.
6. The SecureRandom section of the same run fixes the new `java.security`.

**First installation (bootstrap):** `02b-` runs in phase 0, before `04-` –
and getMOSPatch itself needs a Java. A fresh host therefore still gets its
first JDK 21 from `$PATCH_STORAGE` / `/tmp` / the public CDN (21.0.12.1,
NFTC, see the search order above); the update to the current cycle follows
after `04-` with `--upgrade-jdk`.

`alternatives` and `/usr/bin/jps` point to `jdk-21/...` and follow the symlink
automatically.

**Existing domain:** WLST `createDomain` / `updateDomain` and the FMW installer
resolve the symlink and write `jdk-21.0.x` into the domain and
`$ORACLE_HOME/oui/` – the symlink switch alone does not reach them. `08-`
resets this after the domain is created; after an upgrade (or any
`updateDomain`) run as oracle and restart NM + servers:

```bash
07-Maintenance/domain_jdk_path.sh            # list files that pin jdk-21.0.x
07-Maintenance/domain_jdk_path.sh --apply    # backup + replace with JDK_HOME
```

`--upgrade-jdk` prints this hint when `DOMAIN_HOME/config/config.xml` exists.

**FMW-bundled JDK (`$ORACLE_HOME/oracle_common/jdk`, 17.0.12):** not touched
by this step. It is an OPatch component of the Oracle Home (`oracle.jdk`
17.0.12.8.0 in `inventory/ContentsXML/comps.xml`, confirmed 2026-10-20) and
is used by the Reports server, the Reports engines and the Forms/Reports
tool wrappers (`reports.sh`, `rwengine.sh`, `frmcmp.sh` … hard-code
`oracle_common/jdk`). Its update comes as an OPatch patch for that
component – patch number still to be determined (`FMW_JDK_PATCH_NR` in
`oracle_software_version.conf`, open item).

### Installation via RPM (alternative)

```bash
dnf install --nogpgcheck jdk-21_linux-x64_bin.rpm
```

The Oracle JDK RPM automatically creates the symlink `/usr/java/latest`.

---

## Option B – OpenJDK (parallel installation, not for WebLogic)

Install via dnf if needed for other tools on the same host:

```bash
dnf install java-21-openjdk java-21-openjdk-devel
```

The `JAVA_HOME` path after installation:

```
/usr/lib/jvm/java-21-openjdk-21.x.x.x-x.el9.x86_64
```

> **Note:** OpenJDK does **not** create `/usr/java/latest`. The path must be set
> explicitly if needed. For WebLogic, `JAVA_HOME` always points to the Oracle JDK.

---

## JAVA_HOME – WebLogic Configuration

Set in `/home/oracle/.bash_profile` (done by `03-root_user_oracle.sh`):

```bash
export JAVA_HOME=/u01/app/oracle/java/jdk-21
export PATH=$JAVA_HOME/bin:$PATH
```

This is **independent of the system `alternatives` default** — WebLogic always
uses the Oracle JDK regardless of what `java` resolves to system-wide.

---

## alternatives – Managing Multiple Java Versions

The `alternatives` system allows coexistence of multiple JDK versions for the
OS-level `/usr/bin/java`:

```bash
# Register Oracle JDK with alternatives (priority: version digits, e.g. 21006)
/usr/sbin/alternatives --install /usr/bin/java java /u01/app/oracle/java/jdk-21/bin/java 21006

# Register OpenJDK (if installed via dnf, it registers itself automatically)

# Show registered versions
/usr/sbin/alternatives --display java

# Switch interactively
/usr/sbin/alternatives --config java
```

> **WebLogic is not affected by `alternatives`** — it always uses `$JAVA_HOME`
> from the oracle user environment, not `/usr/bin/java`.

---

## jps – Java Process Status Tool

`jps` is essential for WebLogic maintenance — it lists all running JVM processes
with their main class and arguments:

```bash
jps -m
```

After a Java upgrade or `alternatives` switch, `jps` may need to be re-linked:

```bash
# Test first
jps -m

# If not found or pointing to the wrong JDK:
rm /usr/bin/jps
ln -s /u01/app/oracle/java/jdk-21/bin/jps /usr/bin/jps
```

---

## java.security – SecureRandom (WebLogic Startup Speed)

WebLogic starts significantly slower when `securerandom.source=file:/dev/random`
is active in `java.security` (blocking entropy source).

The fix sets:
```
securerandom.source=file:/dev/./urandom
```
> `/dev/./urandom` instead of `/dev/urandom`: the JVM uses a string match to detect
> `/dev/random` as blocking. `/dev/./urandom` resolves to the same device but bypasses
> that check — it is the correct and documented fix.

### Step 1 – Oracle JDK (this script)

`02b-root_os_java.sh --apply` checks and fixes the Oracle JDK's `java.security`
directly. This runs at installation time, before FMW is installed.

```
JDK 21:  $JDK_HOME/conf/security/java.security
JDK 8:   $JDK_HOME/jre/lib/security/java.security
```

### Step 2 – FMW embedded JDK (after FMW installation)

After FMW is installed, the Oracle Home has its own embedded JDK at
`$ORACLE_HOME/oracle_common/jdk` – used by the Reports server, the Reports
engines and the Forms/Reports tools (WebLogic itself runs on `JDK_HOME`).
This separate `java.security` must also be fixed:

```
02-Checks/weblogic_performance.sh --apply  →  Section 1 – java.security
```

> **Both fixes are required.** The Oracle JDK fix covers the installation phase.
> The FMW embedded JDK fix covers the running WebLogic instance.

---

## Remove Old Java Versions

Check installed versions first:

```bash
dnf list installed "java*" "jdk*"
```

Remove (example — OpenJDK 11):

```bash
dnf erase java-11-openjdk java-11-openjdk-headless
```

Check `alternatives` entries afterwards:

```bash
/usr/sbin/alternatives --display java
```

---

## Verification

```bash
# Oracle JDK via JAVA_HOME (as oracle user)
su - oracle -c "echo \$JAVA_HOME"
su - oracle -c "\$JAVA_HOME/bin/java -version"
# Expected: java version "21.x.x"  ← must be Oracle JDK, not OpenJDK

# System default (may differ – not used by WebLogic)
java -version

# jps available
jps -m

# alternatives state
/usr/sbin/alternatives --display java
```

---

## References

| Topic | Source |
|---|---|
| Oracle Java SE license when used with Oracle products | Oracle Support Doc ID 1557737.1 |
| Oracle Java licensing changes 2023 | https://redresscompliance.com/decoding-oracle-java-licensing-java-licensing-changes-2023.html |
| Oracle Java SE subscription price list | https://www.oracle.com/in/a/ocom/docs/corporate/pricing/java-se-subscription-pricelist-5028356.pdf |
| Oracle JDK 21 downloads (all versions) | https://www.oracle.com/java/technologies/downloads/ |
| Oracle JDK 21 latest – direct CDN link | `https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.tar.gz` |
| Oracle JDK 21 latest – SHA256 checksum | `https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.tar.gz.sha256` |
| SecureRandom fix for WebLogic | `02-Checks/weblogic_performance.sh` – Section 1 |
