# Step 02 – 02-root_os_packages.sh

**Script:** `09-Install/02-root_os_packages.sh`
**Runs as:** `root`
**Phase:** 0 – OS Preparation

---

## Purpose

Install all OS packages required by the Oracle FMW 14.1.2 installer and runtime,
including the font stack for Reports PDF rendering and JDK 21.

---

## Oracle reference package list (source: WLS/Forms installation guide)

The following packages are listed in the official Oracle Forms & Reports 14.1.2
installation guide as prerequisites. The guide was written for OL6/OL7 — the table
shows the OL8/OL9 status for each entry.

| Oracle reference package | OL8 / OL9 status | Action |
|---|---|---|
| `binutils-2.23.52.0.1` | ✓ available | install |
| `compat-libcap1-1.10` | **removed from RHEL8+** | omit |
| `compat-libstdc++-33-3.2.3` (x86_64 + i686) | **removed from RHEL8+** | omit — replaced by current `libstdc++` |
| `gcc-4.8.2` / `gcc-c++-4.8.2` | ✓ available (newer version) | install |
| `glibc-2.17` (x86_64) | ✓ available | install |
| `glibc-2.17` (i686 / 32-bit) | available but not needed | **omit** — FMW 14.1.2 is 64-bit only |
| `glibc-devel-2.17` (x86_64) | ✓ available | install |
| `libaio-0.3.109` (x86_64) / `libaio-devel` | ✓ available | install |
| `libgcc-4.8.2` (x86_64) | ✓ available | install |
| `libgcc-4.8.2` (i686 / 32-bit) | available but not needed | **omit** — 64-bit only |
| `libstdc++-4.8.2` (x86_64) / `libstdc++-devel` | ✓ available | install |
| `libstdc++-4.8.2` (i686 / 32-bit) | available but not needed | **omit** — 64-bit only |
| `dejavu-serif-fonts` | ✓ available | install |
| `ksh` | ✓ available | install |
| `make-3.82` | ✓ available (newer version) | install |
| `sysstat-10.1.5` | ✓ available (newer version) | install |
| `numactl-2.0.9` / `numactl-devel` | ✓ available | install — JVM NUMA awareness |
| `motif-2.3.4-7` / `motif-devel` | ✓ available on OL8/OL9 | **install — OUI hard requirement** |
| `redhat-lsb` / `redhat-lsb-core` | deprecated on OL9 | omit |
| `openssl-1.0.1e` | **replaced by OpenSSL 3** | use `compat-openssl11` for 1.1 compat |

> **motif is a hard requirement for Forms/Reports:** The Oracle Universal Installer
> checks for this package by name and exits immediately if missing:
> ```
> Checking for motif-2.3.4-28.el9-x86_64; Not found. Failed
> Checking for motif-devel-2.3.4-28.el9-x86_64; Not found. Failed
> ```

---

## Package groups

### 1. FMW prerequisite libraries

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

### 2. Font stack (Reports PDF rendering)

```bash
dnf install -y \
  fontconfig freetype \
  dejavu-sans-fonts dejavu-serif-fonts dejavu-sans-mono-fonts \
  dejavu-lgc-sans-fonts dejavu-lgc-serif-fonts \
  liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts \
  xorg-x11-utils xorg-x11-fonts-Type1
```

### 3. Admin and monitoring tools

```bash
dnf install -y \
  sysstat smartmontools nmon tmux \
  lsof strace psmisc xauth \
  bind-utils tcpdump nc
```

### 4. JDK 21

Java installation including license considerations, OpenJDK vs Oracle JDK decision,
`alternatives` setup, `jps` tool, and SecureRandom fix is documented separately:

**→ [01-root_setup_java.md](01-root_setup_java.md)**

> The script looks for a `.tar.gz` or `.rpm` JDK 21 installer in `$PATCH_STORAGE`
> and offers to install it automatically.

---

## Verification

```bash
# Key packages
rpm -q glibc libaio libstdc++ fontconfig motif

# JDK verification: see 01-root_setup_java.md
```

---

## References

| Topic | URL |
|---|---|
| Oracle Forms & Reports 14.1.2 Installation Prerequisites | https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/preparing-install.html#GUID-F657DBB3-8C18-49E0-87FF-9D32DB46B9DD |
