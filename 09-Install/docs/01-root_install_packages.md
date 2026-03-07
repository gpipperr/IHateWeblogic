# Step 02 – 02-root_os_packages.sh

**Script:** `09-Install/02-root_os_packages.sh`
**Runs as:** `root`
**Phase:** 0 – OS Preparation

---

## Purpose

Install all OS packages required by the Oracle FMW 14.1.2 installer and runtime,
including the font stack for Reports PDF rendering.

> **Note:** Oracle's current documentation (WLS 14.1.1 SYSRS, FMW 14.1.2 Readme,
> Forms & Reports 14.1.2 Prerequisites) no longer publishes a complete, explicit
> package list for OL8/OL9 — the list below is derived from the original OL7-era
> WLS installation guide and mapped to OL8/OL9.
>
> Sources:
> - [WLS 14.1.1 System Requirements and Specifications](https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/sysrs/system-requirements-and-specifications.html)
> - [FMW 14.1.2 Download, Installation and Configuration Readme](https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/mstrd/download-installation-and-configuration-readme.html)
> - [Forms & Reports 14.1.2 Installation Prerequisites](https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/preparing-install.html#GUID-F657DBB3-8C18-49E0-87FF-9D32DB46B9DD)

---

## Verified Baseline Package List (tested on OL8, working FMW installation)

The following list was verified against a production FMW installation on OL8,
including 32-bit (i686) libraries that were required in that environment.

```
# 64-bit packages (x86_64)
binutils-2.23.52.0.1
compat-libcap1-1.10
compat-libstdc++-33-3.2.3.x86_64
gcc-4.8.2
gcc-c++-4.8.2
glibc-2.17.x86_64
glibc-devel-2.17.x86_64
libaio-0.3.109.x86_64
libaio-devel-0.3.109.x86_64
libgcc-4.8.2.x86_64
libstdc++-4.8.2.x86_64
libstdc++-devel-4.8.2.x86_64
dejavu-serif-fonts
ksh
make-3.82
sysstat-10.1.5
numactl-2.0.9.x86_64
numactl-devel-2.0.9.x86_64
motif-2.3.4-7.x86_64
motif-devel-2.3.4-7.x86_64
redhat-lsb-4.1.x86_64
redhat-lsb-core-4.1.x86_64
openssl-1.0.1e

# 32-bit packages (i686) – verified required on OL8
compat-libstdc++-33-3.2.3.i686
glibc-2.17.i686
libgcc-4.8.2.i686
libstdc++-4.8.2.i686
```

**OL8 check command:**

```bash
rpm -q binutils compat-libcap1 compat-libstdc++-33 gcc gcc-c++ \
  glibc glibc-devel libaio libaio-devel libgcc libstdc++ libstdc++-devel \
  dejavu-serif-fonts ksh make sysstat numactl numactl-devel \
  motif motif-devel redhat-lsb redhat-lsb-core
```

**OL8 verified output (complete working installation):**

```
binutils-2.27-41.base.el7_7.2.x86_64
compat-libcap1-1.10-7.el7.x86_64
compat-libstdc++-33-3.2.3-72.el7.x86_64
compat-libstdc++-33-3.2.3-72.el7.i686
gcc-4.8.5-39.el7.x86_64
gcc-c++-4.8.5-39.el7.x86_64
glibc-2.17-292.el7.x86_64
glibc-2.17-292.el7.i686
glibc-devel-2.17-292.el7.x86_64
libaio-0.3.109-13.el7.x86_64
libaio-devel-0.3.109-13.el7.x86_64
libgcc-4.8.5-39.el7.x86_64
libgcc-4.8.5-39.el7.i686
libstdc++-4.8.5-39.el7.x86_64
libstdc++-4.8.5-39.el7.i686
libstdc++-devel-4.8.5-39.el7.x86_64
dejavu-serif-fonts-2.33-6.el7.noarch
ksh-20120801-140.el7_7.x86_64
make-3.82-24.el7.x86_64
sysstat-10.1.5-18.el7.x86_64
numactl-2.0.12-3.el7_7.1.x86_64
numactl-devel-2.0.12-3.el7_7.1.x86_64
motif-2.3.4-14.el7_5.x86_64
motif-devel-2.3.4-14.el7_5.x86_64
redhat-lsb-4.1-27.el7.x86_64
redhat-lsb-core-4.1-27.el7.x86_64
```

### Package status: OL8 vs OL9

| Package | OL8 | OL9 |
|---|---|---|
| `binutils` | ✓ install | ✓ install |
| `compat-libcap1` | ✓ install | **removed** — not needed |
| `compat-libstdc++-33` (x86_64) | ✓ install | **removed** — `libstdc++` replaces it |
| `compat-libstdc++-33` (i686) | ✓ install | **removed** — not needed |
| `gcc` / `gcc-c++` | ✓ install | ✓ install |
| `glibc` / `glibc-devel` (x86_64) | ✓ install | ✓ install |
| `glibc` (i686) | ✓ install on OL8 | **not required** on OL9 |
| `libaio` / `libaio-devel` | ✓ install | ✓ install |
| `libgcc` / `libstdc++` / `libstdc++-devel` (x86_64) | ✓ install | ✓ install |
| `libgcc` / `libstdc++` (i686) | ✓ install on OL8 | **not required** on OL9 |
| `dejavu-serif-fonts` | ✓ install | ✓ install |
| `ksh` / `make` / `sysstat` | ✓ install | ✓ install |
| `numactl` / `numactl-devel` | ✓ install | ✓ install |
| `motif` / `motif-devel` | ✓ **install — OUI hard requirement** | ✓ **install — OUI hard requirement** |
| `redhat-lsb` / `redhat-lsb-core` | ✓ install (deprecated) | **removed** — not needed |
| `openssl-1.0.1e` | use `compat-openssl11` | use `compat-openssl11` |

> **motif is a hard requirement for Forms/Reports.** The Oracle Universal Installer
> checks for this package by name and exits immediately if missing:
> ```
> Checking for motif-2.3.4-28.el9-x86_64; Not found. Failed
> Checking for motif-devel-2.3.4-28.el9-x86_64; Not found. Failed
> ```

---

## Installation (OL8 / OL9)

### 1. Check missing packages first

```bash
rpm -q \
  binutils gcc gcc-c++ \
  glibc glibc-devel \
  libaio libaio-devel \
  libgcc libstdc++ libstdc++-devel \
  dejavu-serif-fonts ksh make sysstat \
  numactl numactl-devel \
  motif motif-devel \
  compat-openssl11 fontconfig
# Packages reporting "is not installed" need to be added
```

### 2. FMW prerequisite libraries

```bash
dnf install -y \
  binutils compat-openssl11 cups-libs \
  gcc gcc-c++ \
  glibc glibc-devel ksh \
  libaio libaio-devel libX11 libXau libXi libXrender libXtst \
  libgcc libstdc++ libstdc++-devel libnsl \
  make motif motif-devel \
  net-tools nfs-utils numactl \
  unzip wget curl tar
```

### 3. Font stack (Reports PDF rendering)

```bash
dnf install -y \
  fontconfig freetype \
  dejavu-sans-fonts dejavu-serif-fonts dejavu-sans-mono-fonts \
  dejavu-lgc-sans-fonts dejavu-lgc-serif-fonts \
  liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts \
  xorg-x11-utils xorg-x11-fonts-Type1
```

### 4. Admin and monitoring tools

```bash
dnf install -y \
  sysstat smartmontools nmon tmux \
  lsof strace psmisc xauth \
  bind-utils tcpdump nc
```

### 5. JDK 21

JDK 21 installation is **not** part of this script.
After all packages above are installed, continue with the dedicated Java script:

```bash
sudo bash 09-Install/02b-root_os_java.sh --apply
```

Full documentation (license considerations, Oracle JDK vs OpenJDK, `alternatives`
setup, `jps` tool, SecureRandom fix):

**→ [01-root_setup_java.md](01-root_setup_java.md)**

---

## Verification

```bash
rpm -q \
  binutils gcc gcc-c++ \
  glibc glibc-devel \
  libaio libaio-devel \
  libgcc libstdc++ libstdc++-devel \
  dejavu-serif-fonts ksh make sysstat \
  numactl numactl-devel \
  motif motif-devel \
  compat-openssl11 fontconfig
# Expected: all lines show package-version-release.arch (no "is not installed")
```
