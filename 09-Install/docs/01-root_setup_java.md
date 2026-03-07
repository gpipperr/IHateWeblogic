# Step 02b – Java Installation

**Script:** `09-Install/02b-root_os_java.sh`
**Runs as:** `root`
**Phase:** 0 – OS Preparation

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

> The `/latest/` URL always points to the current JDK 21 patch release.
> SHA256 is verified automatically by `02b-root_os_java.sh`.

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

After FMW is installed, WebLogic uses its own embedded JDK at
`$FMW_HOME/oracle_common/jdk`. This separate `java.security` must also be fixed:

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
