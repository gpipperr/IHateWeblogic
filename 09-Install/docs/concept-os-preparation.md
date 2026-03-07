# Concept: OS Preparation for Oracle FMW 14.1.2 on Oracle Linux 9

## Source Reference

Based on: https://www.pipperr.de/dokuwiki/doku.php?id=linux:linux_8_system_grundeinstellungen_oracle_datenbank_rac
Adapted for: WebLogic / Oracle Forms & Reports (not Oracle Database / RAC)
Target OS: Oracle Linux 9 (OL 9) — features and defaults aligned to OL 9

---

## Design Decisions (resolved)

| Topic | Decision | Rationale |
|---|---|---|
| HugePages | Disable THP only; no standard HugePages | JVM heap is dynamic + GC-managed — static HugePages interfere with G1GC/ZGC pause times. Standard HugePages are a DB SGA optimization, not a JVM optimization. |
| SELinux | Disable in installation phase; proper policy in separate security chapter later | Correct WLS SELinux policy is non-trivial. Get the system running first, harden in a dedicated step. The security chapter will document how to do it properly. |
| IPv6 | Disable by default + configure all WLS/NM listen addresses explicitly to IPv4 | Root cause of WLS/Node Manager IPv4/IPv6 mismatch is unset listen addresses (NM binds to `::1`, Admin to `127.0.0.1`). Fix: explicit `ListenAddress=127.0.0.1` everywhere. IPv6 disable is the pragmatic default for single-server WLS without IPv6 network requirements. |
| NTP → Chrony | Use chrony only (OL 9 default); no ntpd | OL 9 ships chrony as the default time sync daemon; ntpd is deprecated. Legacy reason for NTP in Oracle stacks was Oracle Application Server — not relevant for WLS. chrony is more accurate and better suited for VM environments. |
| Firewall | Configure (not disable) | WLS runs behind Nginx proxy — specific port rules are meaningful. Disabling firewall is a DB RAC pattern for interconnect performance, not applicable here. |
| Reboot | Script announces reboot requirement, does not execute it | Admin controls the reboot window. Script detects on next run whether reboot occurred (SELinux + kernel). |
| Swap | 4 GB, no dynamic sizing | Java processes that swap are effectively non-functional (GC pause explodes). Swap is a safety net, not a resource. Monitor and alert if swap is used at runtime. |
| umask | `022` | Oracle standard. `027` causes subtle WLS inter-process file access failures (Reports Server). Document the trade-off. |
| `/u01` filesystem | WARN if not a dedicated mount point | Cannot automate partition layout (OS install time decision), but check and warn. |
| DNS / hosts | `nsswitch: files dns` — `/etc/hosts` takes priority | Ensures hostname resolution is consistent even if DNS has a conflicting record. |
| DNF proxy | `HTTP_PROXY` as optional interview parameter | Most production environments have no direct internet access. |
| NTP server | `NTP_SERVER` as optional interview parameter | chrony is checked for sync status regardless; NTP server is only configured if parameter is set. |

---

## Scope: What We Adopt vs. What We Skip

### Adopted from the DB guide (adapted for WLS)

| Topic | DB guide | WLS adaptation |
|---|---|---|
| Network config | hostname, /etc/hosts, NOZEROCONF, IPv6 | identical; IPv6 disable default |
| DNF repository | oracle-database-preinstall-19c | oracle-epel-release-el9 only; no DB preinstall RPM |
| SELinux | disable | same — disable now, proper policy later (security chapter) |
| OS update | dnf upgrade | same |
| Package list | DB-specific libs + tools | adapted list (see Step 3) |
| Transparent HugePages | disable (grub) | same — critical for JVM GC |
| Standard HugePages | preallocate for SGA | **not used** — JVM/GC incompatibility |
| Firewall | disable | **configure** — specific ports only |
| Time sync | NTP / chrony | **chrony only** (OL 9 default, ntpd removed) |
| Kernel parameters | DB-tuned shmmax/sem/net | adapted subset — no ASM/RAC params |
| TempFS / /dev/shm | configure size | same — JVM IPC uses /dev/shm |
| Oracle user + groups | oracle + grid + asmadmin | oracle only — no grid, no ASM groups |
| Shell limits | nofile/nproc 131072 | same values, adapted context |
| sudo | briefly mentioned | central element — oracle needs selective sudo |
| Core dumps | /var/tmp/core + sysctl | /var/crash + sysctl — useful for JVM crash analysis |
| NMON | in tools list | yes — excellent for WLS performance monitoring |
| tmux, lsof, strace | in tools list | yes — standard admin tools |
| SSH / X11 | X11Forwarding yes | yes — Oracle config tools (RCU GUI etc.) |

### Skipped (DB/RAC specific)

| What | Why |
|---|---|
| GRID user | Grid Infrastructure is Oracle DB only |
| `asmadmin`, `asmdba` groups | ASM not used |
| ACFS / ASM | Storage layer for Oracle DB |
| CVU (Cluster Verification Utility) | Oracle DB RAC tool |
| `oracle-database-preinstall-19c` RPM | Sets DB kernel params — we control our own |
| RAC / cluster networking | Single-node installation |
| nscd | RAC cluster name caching |
| Loopback MTU 16436 | RAC interconnect optimization |
| ntpd | Replaced by chrony on OL 9 |

---

## Proposed Script Split — Phase 0

Four focused scripts replace the original two. Each does one clearly scoped job
and can be re-run independently.

```
Phase 0 – OS Preparation (as root or oracle with sudo)

  00-root_os_network.sh
      Hostname (FQDN), /etc/hosts, NOZEROCONF
      IPv6 disable (sysctl)
      nsswitch.conf (files before dns)
      SSH config (X11, AddressFamily inet)
      chrony: verify sync + configure NTP_SERVER if set
      → No reboot required

  01-root_os_baseline.sh
      SELinux → disabled (/etc/selinux/config)
      DNF repos (oracle-epel-release-el9)
      OS update (dnf upgrade --refresh)
      Kernel parameters (/etc/sysctl.d/99-oracle-fmw.conf)
      Transparent HugePages → disable (grubby)
      /dev/shm (tmpfs size in /etc/fstab)
      Core dump config (/var/crash + sysctl)
      Firewall: open 80/tcp + 443/tcp, keep WLS ports internal
      → REBOOT REQUIRED (SELinux mode change + possible kernel update)

  02-root_os_packages.sh
      dnf install: FMW prerequisite libs
      dnf install: font stack (Reports PDF)
      dnf install: admin tools (NMON, tmux, lsof, strace, sysstat, smartmontools)
      dnf install: network tools (bind-utils, tcpdump, nc)
      JDK 21 install (from PATCH_STORAGE or RPM)
      → No reboot required

  03-root_user_oracle.sh
      OS groups: oinstall, dba, oper
      oracle user: uid, groups, shell, home
      Shell limits (/etc/security/limits.conf)
      PAM check (/etc/pam.d/login)
      bash_profile + .bashrc (ORACLE_BASE, JAVA_HOME, PATH, umask 022)
      sudo (/etc/sudoers.d/oracle-fmw)
      Directory structure (/u01 tree, /srv/patch_storage, /var/crash)
      oraInst.loc
      → No reboot required
```

**Reboot sequence:**
```
Run 00  →  Run 01  →  ** REBOOT **  →  Run 02  →  Run 03  →  continue with 04+
```

The reboot after `01` is mandatory (SELinux mode change only takes effect after reboot;
grubby THP change also requires reboot). Both scripts 00 and 01 can run in sequence
before the single reboot.

---

## Step 1 – Network (`00-root_os_network.sh`)

### Hostname

```
hostnamectl set-hostname wls01.company.local
```

- Must be a fully qualified domain name (FQDN)
- Must resolve: `getent hosts $(hostname -f)` must return the server's own IP
- Must NOT resolve to `127.0.0.1` or `127.0.1.1` (loopback — WLS will bind incorrectly)

### /etc/hosts

```
127.0.0.1       localhost localhost.localdomain
# :: 1          localhost  ← comment out IPv6 loopback if IPv6 disabled
10.0.1.20       wls01.company.local wls01
```

- The server's own FQDN must point to its real interface IP (not loopback)
- Ensures WLS/NM hostname resolution works independently of DNS

### NOZEROCONF

`/etc/sysconfig/network`:
```
NOZEROCONF=yes
```
Prevents spurious 169.254.x.x route that confuses WLS network binding.

### nsswitch.conf

`/etc/nsswitch.conf`:
```
hosts: files dns myhostname
```
`files` before `dns` ensures `/etc/hosts` takes priority — WLS hostname resolution
is reliable even if DNS has a different record.

### IPv6

```
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
```

Applied via sysctl. Permanent in `/etc/sysctl.d/99-oracle-fmw.conf` (or handled
in the baseline script together with other sysctl settings).

Complementary: all WLS and Node Manager listen addresses are set to explicit IPv4
addresses during domain creation (`08-oracle_setup_domain.sh`).

### SSH

`/etc/ssh/sshd_config`:
```
X11Forwarding yes
X11UseLocalhost no
AddressFamily inet
```
`AddressFamily inet` forces SSH to use IPv4 only — avoids confusion on systems
where IPv6 is disabled at the kernel level but sshd still tries to bind to IPv6.

### Chrony

OL 9 uses `chronyd` as default time sync daemon (ntpd is removed).

Script checks:
- `systemctl is-active chronyd` → must be `active`
- `timedatectl` → `System clock synchronized: yes`
- If `NTP_SERVER` is set in `environment.conf`: add to `/etc/chrony.conf` and restart

```bash
# /etc/chrony.conf
server <NTP_SERVER> iburst
```

Why chrony matters for WLS: SSL certificate validation, Kerberos (if used),
cluster heartbeat timing, and WLS license checks all depend on accurate system time.

---

## Step 2 – OS Baseline (`01-root_os_baseline.sh`)

### SELinux → disabled

`/etc/selinux/config`:
```
SELINUX=disabled
```

Current state detection:
- `getenforce` returns `Enforcing` → change to disabled, REBOOT REQUIRED
- `getenforce` returns `Permissive` → change to disabled, REBOOT REQUIRED
- `getenforce` returns `Disabled` → already done, skip

**Future:** A dedicated security chapter will document how to run WLS with SELinux
in enforcing mode using a proper WLS policy module. This is a non-trivial task
involving `audit2allow` and policy compilation, not suitable for the installation phase.

### DNF Repositories

```bash
dnf install -y oracle-epel-release-el9     # extra packages (NMON, additional tools)
```

No `oracle-database-preinstall-19c` — that RPM sets kernel parameters for Oracle DB
(different values, different focus). We manage our own kernel parameters.

### OS Update

```bash
dnf upgrade --refresh
```

Run before any software installation. If a new kernel is installed, it will be picked
up in the same reboot triggered by the SELinux change.

### Kernel Parameters

File: `/etc/sysctl.d/99-oracle-fmw.conf`

```
# Shared memory (JVM IPC)
kernel.shmmax         = 4398046511104
kernel.shmall         = 1073741824
kernel.shmmni         = 4096
kernel.sem            = 250 32000 100 128

# File descriptors
fs.file-max           = 6815744
fs.aio-max-nr         = 1048576

# Network buffers (WLS HTTP / T3 throughput)
net.core.rmem_default = 262144
net.core.rmem_max     = 4194304
net.core.wmem_default = 262144
net.core.wmem_max     = 1048576
net.ipv4.ip_local_port_range = 9000 65500

# System stability + JVM
vm.swappiness         = 10
vm.min_free_kbytes    = 524288
kernel.panic_on_oops  = 1

# Core dumps
kernel.core_uses_pid  = 1
kernel.core_pattern   = /var/crash/coredump_%h_%t_%e.%p
fs.suid_dumpable      = 1

# IPv6 (here or in network step)
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
```

Removed from DB guide: `net.ipv4.conf.all.rp_filter=2` (RAC routing), loopback MTU.

### Transparent HugePages → disable

```bash
grubby --update-kernel=ALL --args="transparent_hugepage=never"
```

Takes effect after reboot. Verify post-reboot:
```bash
cat /sys/kernel/mm/transparent_hugepage/enabled
# Expected: always madvise [never]
```

**Why:** THP causes latency spikes in JVM (kernel background compaction interrupts
GC). Oracle formally recommends THP disabled for WLS. No benefit for Java workloads.

**Standard HugePages:** Not configured. JVM G1GC/ZGC manage their own page structures.
The DB pattern of preallocating huge pages for a static SGA does not apply to
a dynamically resizing JVM heap.

### /dev/shm (tmpfs)

`/etc/fstab`:
```
tmpfs   /dev/shm   tmpfs   rw,exec,size=4096M   0 0
```

Size: at minimum 25% of RAM, minimum 2 GB. JVM uses /dev/shm for IPC mechanisms.
`exec` flag required (some JVM operations require executable anonymous mappings).

Temp file cleanup: `/usr/lib/tmpfiles.d/oracle-fmw.conf`:
```
x /tmp/.oracle*
x /var/tmp/.oracle*
```

### Core Dumps

```bash
mkdir -p /var/crash
chmod 1777 /var/crash
```

Sysctl (included in kernel parameters above):
- `kernel.core_pattern=/var/crash/coredump_%h_%t_%e.%p`
- `kernel.core_uses_pid=1`
- `fs.suid_dumpable=1`

JVM also writes its own `hs_err_pid<N>.log` on crash — these go to the working
directory of the JVM process (usually `$DOMAIN_HOME`). Both are valuable for support.

Note on disk space: a JVM core dump = JVM heap size (e.g. 4 GB heap → 4 GB dump).
`/var/crash` should have enough space for at least one full dump. Script checks
available space and warns if insufficient.

### Firewall

```bash
# External access (Nginx)
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp

# WLS ports (7001, 9001, 9002) stay CLOSED externally
# Nginx proxies them on 127.0.0.1

# SSH (typically already open)
firewall-cmd --permanent --add-service=ssh

firewall-cmd --reload
```

Optional: admin console access restricted to admin network:
```bash
firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=<ADMIN_NET>/24 port port=7001 protocol=tcp accept'
```

WARN if firewalld is not running. Do not start firewalld automatically — it may
disrupt existing network rules. Inform and let admin decide.

---

## Step 3 – Packages (`02-root_os_packages.sh`)

### FMW prerequisite libraries

```
binutils compat-openssl11 cups-libs glibc glibc-devel ksh
libaio libaio-devel libX11 libXau libXi libXrender libXtst
libgcc libstdc++ libstdc++-devel libnsl make
net-tools nfs-utils unzip wget curl tar
```

### Font stack (Reports PDF rendering)

```
fontconfig freetype
dejavu-sans-fonts dejavu-serif-fonts dejavu-sans-mono-fonts
dejavu-lgc-sans-fonts dejavu-lgc-serif-fonts
liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts
xorg-x11-utils xorg-x11-fonts-Type1
```

### Admin and monitoring tools

```
sysstat          # sar, iostat, mpstat — time-series performance data
smartmontools    # smartctl — disk health
nmon             # real-time dashboard (CPU, memory, disk, network) — from EPEL
tmux             # terminal multiplexer — keep sessions alive during installs
lsof             # list open files / ports (essential for WLS port diagnostics)
strace           # system call trace (for deep WLS / native lib debugging)
psmisc           # pstree, fuser, killall
xauth            # X11 forwarding authentication token
```

### Network tools

```
bind-utils       # dig, nslookup — DNS verification
tcpdump          # packet capture (WLS network debugging)
nc               # netcat — port testing, quick connectivity checks
```

### JDK 21

Install to a standalone path, **not** under ORACLE_HOME:

```
$ORACLE_BASE/java/jdk-21.0.x/    ← JDK_HOME
```

Install options (in priority order):
1. From tar.gz in `$PATCH_STORAGE`: `tar xf jdk-21.0.x_linux-x64_bin.tar.gz -C $JDK_PARENT`
2. From RPM in `$PATCH_STORAGE`: `dnf install --nogpgcheck jdk-21.0.x.rpm`
3. From Oracle dnf repo (if configured)

Register via `alternatives` but **do not set as system default** (system JDK unchanged):
```bash
alternatives --install /usr/bin/java java $JDK_HOME/bin/java 1000
# Do NOT run: alternatives --set java $JDK_HOME/bin/java
```

Verify:
```bash
$JDK_HOME/bin/java -version
$JDK_HOME/bin/java -XX:+PrintFlagsFinal -version 2>&1 | grep -i hugepage
# HugePages support available but NOT configured (expected)
```

---

## Step 4 – Oracle User (`03-root_user_oracle.sh`)

### Groups (WLS — no ASM groups)

```bash
groupadd -g 1000 oinstall    # primary — FMW installer requirement
groupadd -g 1001 dba         # DBA operations (also conventional for WLS)
groupadd -g 1002 oper        # operator (optional, keep for FMW installer compatibility)
```

No `asmadmin`, `asmdba`, `asmoper` — ASM is not used.

### oracle User

```bash
useradd -u 1100 -g oinstall -G dba,oper -s /bin/bash -d /home/oracle oracle
```

### Shell Limits (`/etc/security/limits.conf`)

```
oracle   soft   nofile     131072
oracle   hard   nofile     131072
oracle   soft   nproc      131072
oracle   hard   nproc      131072
oracle   soft   stack      10240
oracle   hard   stack      32768
oracle   soft   core       unlimited
oracle   hard   core       unlimited
oracle   soft   memlock    50000000
oracle   hard   memlock    50000000
```

PAM check: `/etc/pam.d/login` must contain `session required pam_limits.so`.
Script verifies this line exists.

### .bash_profile

```bash
export ORACLE_BASE=/u01/app/oracle
export ORACLE_HOME=$ORACLE_BASE/fmw
export JAVA_HOME=$ORACLE_BASE/java/jdk-21.0.x
export PATH=$JAVA_HOME/bin:$ORACLE_HOME/OPatch:$PATH
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
export TMP=/tmp
export TMPDIR=/tmp
umask 0022
```

### sudo (`/etc/sudoers.d/oracle-fmw`)

```
# Package management
oracle ALL=(root) NOPASSWD: /usr/bin/dnf install *
oracle ALL=(root) NOPASSWD: /usr/bin/dnf update *

# Kernel parameters
oracle ALL=(root) NOPASSWD: /usr/sbin/sysctl -p *
oracle ALL=(root) NOPASSWD: /usr/sbin/sysctl --system

# Nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl start nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl stop nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl enable nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl status nginx

# Config files (scoped paths only)
oracle ALL=(root) NOPASSWD: /bin/cp /etc/sysctl.d/*.conf /etc/sysctl.d/
oracle ALL=(root) NOPASSWD: /bin/cp /etc/security/limits.conf /etc/security/limits.conf
oracle ALL=(root) NOPASSWD: /usr/bin/firewall-cmd *

# Font cache
oracle ALL=(root) NOPASSWD: /usr/bin/fc-cache -f -v
```

Validate: `visudo -c -f /etc/sudoers.d/oracle-fmw`

### Directory Structure

```
/u01/                              ← dedicated mount point recommended (own LVM volume)
├── app/oracle/
│   ├── fmw/                       ← ORACLE_HOME
│   ├── java/jdk-21.0.x/           ← JDK_HOME
│   └── oraInventory/              ← OUI inventory
└── user_projects/
    └── domains/
        └── fr_domain/             ← DOMAIN_HOME

/srv/patch_storage/                ← installers + patches (own volume if possible)
/var/crash/                        ← core dumps (standard Linux location)
```

Mount point check: script warns (does not fail) if `/u01` is not a dedicated
filesystem — running with root filesystem is possible but not recommended for production.

### oraInst.loc

```
/u01/app/oracle/oraInst.loc:
  inventory_loc=/u01/app/oracle/oraInventory
  inst_group=oinstall
```

---

## Open Items for Security Chapter (later)

The following items are deferred to a dedicated security hardening chapter
(created after the system is fully installed and validated):

- SELinux: enforcing mode with proper WLS audit2allow policy
- SSH hardening (key-only auth, fail2ban, login restrictions)
- WLS SSL configuration (demo certs → production certs)
- Network segmentation (WLS admin network vs. application network)
- Audit logging (auditd rules for oracle user actions)
- File integrity monitoring (AIDE or similar)
- Password policy (`/etc/security/pwquality.conf`)
