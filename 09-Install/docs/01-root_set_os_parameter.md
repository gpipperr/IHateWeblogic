# Step 0b – 01-root_set_os_parameter.sh

**Script:** `09-Install/01-root_set_os_parameter.sh`
**Runs as:** `root` or `oracle` with sudo
**Phase:** 0 – OS Preparation

---

## Purpose

Install required OS packages, set kernel parameters for Oracle FMW, and install JDK 21.
These are prerequisites for the FMW installer.

---

## Without the Script (manual)

### 1. Install required packages

```bash
dnf install -y \
  binutils compat-openssl11 cups-libs \
  glibc glibc-devel ksh \
  libaio libaio-devel libX11 libXau libXi libXrender libXtst \
  libgcc libstdc++ libstdc++-devel libnsl \
  make net-tools nfs-utils smartmontools sysstat \
  unzip wget curl tar \
  fontconfig freetype \
  dejavu-sans-fonts dejavu-serif-fonts dejavu-sans-mono-fonts \
  liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts \
  xorg-x11-utils
```

### 2. Set kernel parameters

Create `/etc/sysctl.d/99-oracle-fmw.conf`:

```
kernel.sem            = 250 32000 100 128
kernel.shmall         = 1073741824
kernel.shmmax         = 4398046511104
kernel.shmmni         = 4096
net.core.rmem_default = 262144
net.core.rmem_max     = 4194304
net.core.wmem_default = 262144
net.core.wmem_max     = 1048576
net.ipv4.ip_local_port_range = 9000 65500
vm.swappiness         = 10
```

Apply immediately:

```bash
sysctl -p /etc/sysctl.d/99-oracle-fmw.conf
```

### 3. Install JDK 21

Download JDK 21 from Oracle (requires MOS or Oracle account):

```bash
# Extract to JDK_HOME (NOT into ORACLE_HOME – stays independent):
tar xf jdk-21.0.x_linux-x64_bin.tar.gz -C /u01/app/oracle/java/
ln -sf /u01/app/oracle/java/jdk-21.0.x /u01/app/oracle/java/jdk-current

# Do NOT change the system JDK (/usr/bin/java) – FMW uses its own JDK
```

Verify:

```bash
/u01/app/oracle/java/jdk-21.0.x/bin/java -version
```

### 4. Verify OS certification

According to the FMW 14.1.2 Certification Matrix (`90-Source-MetaData/fmw-141200-certmatrix.xlsx`):
- Oracle Linux 9.x ✓
- JDK 21.0.x ✓
- Kernel ≥ 5.4 ✓

---

## What the Script Does

- Reads `ORACLE_BASE`, `JDK_HOME`, `PATCH_STORAGE` from `environment.conf`
- Checks which packages are already installed (skips installed ones)
- Installs missing packages via `sudo dnf install`
- Writes kernel parameter file and applies with `sudo sysctl -p`
- Checks if JDK is already present at `JDK_HOME`; if not, looks for installer in `PATCH_STORAGE`
- If JDK installer found: extracts to `JDK_HOME`, verifies with `java -version`
- If JDK installer not found: prints download instructions and exits WARN
- Validates final state: package versions, sysctl values, JDK version

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show current state and what would change |
| `--apply` | Install packages and apply kernel settings |
| `--help` | Show usage |

---

## Verification

```bash
# Kernel parameters
sysctl kernel.sem kernel.shmall net.ipv4.ip_local_port_range

# JDK
$JDK_HOME/bin/java -version
# Expected: java version "21.x.x"

# Key packages
rpm -q glibc libaio libstdc++ fontconfig
```
