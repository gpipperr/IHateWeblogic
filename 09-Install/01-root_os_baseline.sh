#!/bin/bash
# =============================================================================
# Script   : 01-root_os_baseline.sh
# Purpose  : Phase 0 – OS baseline configuration for Oracle FMW 14.1.2 on OL 9
#            SELinux disable, DNF repos, OS update, kernel parameters,
#            Transparent HugePages disable, /dev/shm, core dumps, firewall.
# Call     : ./09-Install/01-root_os_baseline.sh
#            ./09-Install/01-root_os_baseline.sh --apply
# Options  : --apply        Write configuration changes
#            --skip-update  Skip dnf upgrade (faster re-runs)
#            --help         Show usage
# Requires : sysctl, grubby, firewall-cmd, dnf, systemctl
# Runs as  : root or oracle with sudo
# NOTE     : REBOOT REQUIRED after --apply (SELinux + kernel changes)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/00-root_set_os_parameter.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m IHateWeblogic_lib.sh not found: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"
init_log

# =============================================================================
# Arguments
# =============================================================================

APPLY_MODE=0
SKIP_UPDATE=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-20s %s\n" "--apply"        "Write configuration changes (reboot required after)"
    printf "  %-20s %s\n" "--skip-update"  "Skip dnf upgrade (use for re-runs)"
    printf "  %-20s %s\n" "--help"         "Show this help"
    printf "\nIMPORTANT: A system reboot is required after --apply.\n"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)        APPLY_MODE=1;   shift ;;
        --skip-update)  SKIP_UPDATE=1;  shift ;;
        --help|-h)      _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Root / sudo helpers
# =============================================================================

_can_sudo() { sudo -n true 2>/dev/null; }

_run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif _can_sudo; then
        sudo "$@"
    else
        warn "No root/sudo for: $*"
        info "  Run manually: sudo $*"
        return 1
    fi
}

_check_root_access() {
    if [ "$(id -u)" -eq 0 ]; then
        ok "Running as root"
    elif _can_sudo; then
        ok "Running as $(id -un) with sudo"
    else
        fail "Root or sudo access required"
        info "  Configure: /etc/sudoers.d/oracle-fmw"
        print_summary; exit 2
    fi
}

# =============================================================================
# Banner
# =============================================================================

printLine
section "OS Baseline Configuration – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:"        "$(hostname -f 2>/dev/null || hostname)" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "OS:"          "$(cat /etc/oracle-release 2>/dev/null \
    || cat /etc/redhat-release 2>/dev/null || echo 'unknown')" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Kernel:"      "$(uname -r)" | tee -a "${LOG_FILE:-/dev/null}"
[ "$APPLY_MODE" -eq 1 ] && \
    printf "  %-26s %s\n" "Mode:" "APPLY (REBOOT REQUIRED AFTER)" \
        | tee -a "${LOG_FILE:-/dev/null}"
printLine

_check_root_access

# =============================================================================
# 1. SELinux
# =============================================================================

section "SELinux"

SELINUX_CFG="/etc/selinux/config"
SELINUX_CURRENT="$(getenforce 2>/dev/null || echo 'Unknown')"
SELINUX_FILE_VAL="$(grep -E '^SELINUX=' "$SELINUX_CFG" 2>/dev/null \
    | cut -d= -f2 | tr -d '[:space:]')"

printf "  %-26s %s\n" "Runtime state:"  "$SELINUX_CURRENT"    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Config file:"    "$SELINUX_FILE_VAL"   | tee -a "${LOG_FILE:-/dev/null}"

REBOOT_NEEDED=0

if [ "$SELINUX_CURRENT" = "Disabled" ] && [ "$SELINUX_FILE_VAL" = "disabled" ]; then
    ok "SELinux is disabled"
else
    if [ "$SELINUX_FILE_VAL" = "disabled" ]; then
        warn "SELinux config=disabled but runtime=$SELINUX_CURRENT – reboot pending"
    else
        fail "SELinux is $SELINUX_CURRENT – must be disabled for WLS native libraries"
        info "  WLS Forms/Reports native libs use memory patterns blocked by SELinux"
        info "  Future: proper SELinux policy in the security hardening chapter"
        REBOOT_NEEDED=1
    fi

    if [ "$APPLY_MODE" -eq 1 ] && [ "$SELINUX_FILE_VAL" != "disabled" ]; then
        if askYesNo "Set SELINUX=disabled in $SELINUX_CFG?" "y"; then
            backup_file "$SELINUX_CFG"
            _run_root sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$SELINUX_CFG"
            ok "SELinux set to disabled in config file"
            warn "REBOOT REQUIRED for SELinux change to take effect"
        fi
    fi
fi

# =============================================================================
# 2. DNF Repositories
# =============================================================================

section "DNF Repositories"

_check_repo() {
    local repo="$1"
    if dnf repolist enabled 2>/dev/null | grep -q "$repo"; then
        ok "Repository enabled: $repo"
        return 0
    else
        warn "Repository not enabled: $repo"
        return 1
    fi
}

_check_repo "ol9_baseos_latest" || _check_repo "baseos" || \
    info "  Base OS repo not found – verify Oracle Linux repos are configured"

EPEL_OK=0
# ol9_developer_EPEL and oracle-epel are alternative names for the EPEL repo on OL9.
# Check both; the first match satisfies the requirement – no WARN for the other variant.
if dnf repolist enabled 2>/dev/null | grep -q "ol9_developer_EPEL"; then
    ok "Repository enabled: ol9_developer_EPEL"
    EPEL_OK=1
elif dnf repolist enabled 2>/dev/null | grep -q "oracle-epel"; then
    ok "Repository enabled: oracle-epel"
    EPEL_OK=1
fi

if [ "$EPEL_OK" -eq 0 ]; then
    warn "Oracle EPEL repository not enabled (needed for NMON and other tools)"
    info "  Install: dnf install oracle-epel-release-el9"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Install oracle-epel-release-el9?" "y"; then
            _run_root dnf install -y oracle-epel-release-el9 && \
                ok "EPEL repository enabled" || warn "EPEL install failed – continue manually"
        fi
    fi
fi

# =============================================================================
# 3. OS Update
# =============================================================================

section "OS Update"

if [ "$SKIP_UPDATE" -eq 1 ]; then
    info "OS update skipped (--skip-update)"
else
    # Check for pending updates
    # grep -c always outputs a number (0..n); exit code 1 on zero matches is normal –
    # do NOT use || echo 0 here, that appends a second "0" and breaks integer comparison.
    UPDATE_COUNT="$(_run_root dnf check-update --quiet 2>/dev/null | grep -c '^[a-zA-Z]')"
    UPDATE_COUNT="${UPDATE_COUNT:-0}"
    if [ "${UPDATE_COUNT:-0}" -eq 0 ]; then
        ok "System is up to date"
    else
        warn "Pending updates: ${UPDATE_COUNT} package(s)"
        info "  Install: dnf upgrade --refresh"
        if [ "$APPLY_MODE" -eq 1 ]; then
            if askYesNo "Run dnf upgrade --refresh now?" "y"; then
                _run_root dnf upgrade --refresh -y
                ok "OS update complete"
                REBOOT_NEEDED=1
                warn "Reboot required after kernel update (if kernel was updated)"
            fi
        fi
    fi
fi

# =============================================================================
# 4. Kernel Parameters
# =============================================================================

section "Kernel Parameters"

SYSCTL_FILE="/etc/sysctl.d/99-oracle-fmw.conf"

# Define target values for WebLogic / Forms / Reports (no Oracle Database)
declare -A SYSCTL_WANT=(
    ["kernel.shmmax"]="4294967295"
    ["kernel.shmall"]="9272480"
    ["net.ipv4.ip_local_port_range"]="9000 65500"
    ["vm.swappiness"]="10"
    ["kernel.panic_on_oops"]="1"
    ["fs.suid_dumpable"]="1"
    ["kernel.core_uses_pid"]="1"
    ["kernel.core_pattern"]="/var/tmp/core/coredump_%h_.%s.%u.%g_%t_%E_%e"
    ["net.ipv6.conf.all.disable_ipv6"]="1"
    ["net.ipv6.conf.default.disable_ipv6"]="1"
)

SYSCTL_ISSUES=0
for KEY in "${!SYSCTL_WANT[@]}"; do
    CURRENT_VAL="$(sysctl -n "$KEY" 2>/dev/null)"
    WANT_VAL="${SYSCTL_WANT[$KEY]}"
    if [ "$CURRENT_VAL" = "$WANT_VAL" ]; then
        ok "$(printf "%-42s = %s" "$KEY" "$CURRENT_VAL")"
    else
        warn "$(printf "%-42s = %s  (want: %s)" "$KEY" "${CURRENT_VAL:-(unset)}" "$WANT_VAL")"
        SYSCTL_ISSUES=$((SYSCTL_ISSUES + 1))
    fi
done

if [ "$SYSCTL_ISSUES" -gt 0 ] && [ "$APPLY_MODE" -eq 1 ]; then
    if askYesNo "Write kernel parameters to $SYSCTL_FILE?" "y"; then
        _run_root tee "$SYSCTL_FILE" > /dev/null << 'SYSCTL_EOF'
# Oracle FMW 14.1.2 – kernel parameters for WebLogic / Forms / Reports
# Managed by: 09-Install/01-root_os_baseline.sh
# References:
#   Oracle WLS 14.1.1 SYSRS: kernel.shmmax required by Oracle Universal Installer
#   https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/sysrs/
#   https://dbainsight.com/2026/02/oracle-weblogic-14c-installation-on-linux

# Shared memory – required by Oracle Universal Installer (WLS SYSRS)
# Note: NOT the Oracle Database values (shmmax=4TB, shmall=1073741824)
kernel.shmmax         = 4294967295
kernel.shmall         = 9272480

# Ephemeral port range (WLS / Forms / Reports use many concurrent connections)
net.ipv4.ip_local_port_range = 9000 65500

# JVM GC stability – reduce swap pressure on JVM heap
vm.swappiness         = 10

# Server stability – panic on kernel oops to force clean restart
kernel.panic_on_oops  = 1

# Core dumps (JVM / Oracle Forms crash analysis)
# fs.suid_dumpable=1 required so oracle user (non-root) produces core files
# /var/tmp/core must be chmod 777 so any uid can write there
# Pattern fields: %h=host %s=signal %u=uid %g=gid %t=epoch %E=exe-path %e=exe-name
fs.suid_dumpable      = 1
kernel.core_uses_pid  = 1
kernel.core_pattern   = /var/tmp/core/coredump_%h_.%s.%u.%g_%t_%E_%e

# IPv6 disable (WLS Node Manager listen address stability: 127.0.0.1 vs ::1)
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL_EOF
        _run_root sysctl --system > /dev/null 2>&1
        ok "Kernel parameters written to $SYSCTL_FILE and applied"
    fi
fi

# =============================================================================
# 5. Transparent HugePages
# =============================================================================

section "Transparent HugePages (THP)"

THP_FILE="/sys/kernel/mm/transparent_hugepage/enabled"
if [ -f "$THP_FILE" ]; then
    THP_STATE="$(cat "$THP_FILE" 2>/dev/null)"
    printf "  %-26s %s\n" "THP state:" "$THP_STATE" | tee -a "${LOG_FILE:-/dev/null}"

    if printf "%s" "$THP_STATE" | grep -q '\[never\]'; then
        ok "Transparent HugePages disabled (required for JVM GC performance)"
    else
        fail "Transparent HugePages are active – causes JVM GC pause spikes"
        info "  THP background compaction interrupts G1GC/ZGC"
        info "  Current: $THP_STATE"
        if [ "$APPLY_MODE" -eq 1 ]; then
            if command -v grubby > /dev/null 2>&1; then
                if askYesNo "Disable THP permanently via grubby (requires reboot)?" "y"; then
                    _run_root grubby --update-kernel=ALL \
                        --args="transparent_hugepage=never"
                    ok "THP disable added to kernel cmdline (takes effect after reboot)"
                    REBOOT_NEEDED=1
                fi
            else
                warn "grubby not found – add 'transparent_hugepage=never' to GRUB_CMDLINE_LINUX manually"
            fi
        fi
    fi
else
    info "THP sysfs file not found – check if THP is compiled into kernel"
fi

# Check grubby cmdline already has it
if command -v grubby > /dev/null 2>&1; then
    GRUB_ARGS="$(grubby --info=DEFAULT 2>/dev/null | grep '^args=')"
    if printf "%s" "$GRUB_ARGS" | grep -q "transparent_hugepage=never"; then
        ok "THP=never is in default kernel cmdline (persistent)"
    elif [ "$APPLY_MODE" -eq 0 ]; then
        info "THP kernel cmdline entry not yet set"
    fi
fi

# =============================================================================
# 6. /dev/shm (tmpfs)
# =============================================================================

section "/dev/shm (tmpfs)"

SHM_SIZE="$(df -m /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')"
TOTAL_RAM_MB="$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)"
SHM_WANT_MB=$(( TOTAL_RAM_MB / 4 ))
[ "$SHM_WANT_MB" -lt 2048 ] && SHM_WANT_MB=2048

printf "  %-26s %s MB\n" "Current /dev/shm:"  "${SHM_SIZE:-(unknown)}" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s MB (25%% of RAM, min 2 GB)\n" "Recommended minimum:" "$SHM_WANT_MB" \
    | tee -a "${LOG_FILE:-/dev/null}"

if [ -n "$SHM_SIZE" ] && [ "$SHM_SIZE" -ge "$SHM_WANT_MB" ]; then
    ok "/dev/shm size OK: ${SHM_SIZE} MB"
else
    warn "/dev/shm too small: ${SHM_SIZE:-unknown} MB (minimum: $SHM_WANT_MB MB)"
    info "  Add to /etc/fstab: tmpfs /dev/shm tmpfs rw,exec,size=${SHM_WANT_MB}M 0 0"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Update /dev/shm size in /etc/fstab to ${SHM_WANT_MB}M?" "y"; then
            backup_file /etc/fstab
            if grep -q '/dev/shm' /etc/fstab; then
                _run_root sed -i \
                    "s|.*tmpfs[[:space:]]*/dev/shm.*|tmpfs /dev/shm tmpfs rw,exec,size=${SHM_WANT_MB}M 0 0|" \
                    /etc/fstab
            else
                printf "tmpfs /dev/shm tmpfs rw,exec,size=%sM 0 0\n" "$SHM_WANT_MB" \
                    | _run_root tee -a /etc/fstab > /dev/null
            fi
            _run_root mount -o remount /dev/shm
            ok "/dev/shm updated to ${SHM_WANT_MB}M"
        fi
    fi
fi

# exec flag check (required for JVM)
SHM_OPTS="$(findmnt -n -o OPTIONS /dev/shm 2>/dev/null)"
if printf "%s" "$SHM_OPTS" | grep -q "noexec"; then
    fail "/dev/shm is mounted noexec – JVM requires exec"
    info "  Remove noexec from /dev/shm mount options"
else
    ok "/dev/shm: exec flag OK"
fi

# Temp file cleanup configuration
TMPFILES_CONF="/usr/lib/tmpfiles.d/oracle-fmw.conf"
if [ -f "$TMPFILES_CONF" ]; then
    ok "tmpfiles cleanup: $TMPFILES_CONF exists"
else
    info "tmpfiles cleanup not configured (optional)"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Create tmpfiles cleanup for /tmp/.oracle* ?" "y"; then
            _run_root tee "$TMPFILES_CONF" > /dev/null << 'EOF'
# Oracle FMW temp file cleanup
x /tmp/.oracle*
x /var/tmp/.oracle*
EOF
            ok "tmpfiles.d/oracle-fmw.conf created"
        fi
    fi
fi

# =============================================================================
# 7. Core Dump Directory
# =============================================================================

section "Core Dump Directory"

# /var/tmp/core – central core dump directory, world-writable (chmod 777)
# Oracle Forms in particular can produce core dumps; if they land in the FMW
# process working directory (/u01/.../bin) they silently fill up the disk.
# Centralising via kernel.core_pattern makes them visible and manageable.
# fs.suid_dumpable=1 is required so the oracle user (non-root) produces core files.
# Test: su - oracle; ulimit -c unlimited; kill -s SIGSEGV $$  → check /var/tmp/core/
CORE_DIR="/var/tmp/core"
if [ -d "$CORE_DIR" ]; then
    CORE_PERMS="$(stat -c '%a' "$CORE_DIR" 2>/dev/null)"
    ok "Core dump directory exists: $CORE_DIR (mode: $CORE_PERMS)"
    if [ "$CORE_PERMS" != "777" ]; then
        warn "Core dump directory mode is $CORE_PERMS (expected 777 – oracle user must be able to write)"
        [ "$APPLY_MODE" -eq 1 ] && _run_root chmod 777 "$CORE_DIR" && ok "Mode corrected to 777"
    fi
    # Check free space (JVM core = roughly heap size, typically 2–8 GB)
    CORE_FREE_GB="$(df -BG "$CORE_DIR" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')"
    if [ -n "$CORE_FREE_GB" ] && [ "$CORE_FREE_GB" -lt 5 ]; then
        warn "Only ${CORE_FREE_GB}G free in $CORE_DIR – JVM core dump needs ~heap size in free space"
    else
        ok "Free space in $CORE_DIR: ${CORE_FREE_GB:-unknown}G"
    fi
else
    warn "Core dump directory not found: $CORE_DIR"
    info "  Oracle Forms may dump to FMW bin/ directory and silently fill the disk"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Create $CORE_DIR with mode 777?" "y"; then
            _run_root mkdir -p "$CORE_DIR"
            _run_root chmod 777 "$CORE_DIR"
            ok "Created: $CORE_DIR (mode 777)"
        fi
    else
        info "  Create manually: mkdir /var/tmp/core && chmod 777 /var/tmp/core"
    fi
fi

# Verify kernel.core_pattern points here (already set in sysctl block above)
ACTUAL_PATTERN="$(sysctl -n kernel.core_pattern 2>/dev/null)"
if printf "%s" "$ACTUAL_PATTERN" | grep -q "^/var/tmp/core/"; then
    ok "kernel.core_pattern → $ACTUAL_PATTERN"
else
    warn "kernel.core_pattern = '$ACTUAL_PATTERN' (expected: /var/tmp/core/...)"
    info "  Will be set when sysctl block is applied"
fi

# =============================================================================
# 8. Firewall
# =============================================================================

section "Firewall"

if ! command -v firewall-cmd > /dev/null 2>&1; then
    warn "firewall-cmd not found – install firewalld or configure firewall manually"
elif ! _run_root firewall-cmd --state > /dev/null 2>&1; then
    warn "firewalld is not running"
    info "  WLS is accessible without firewall but that is a security risk"
    info "  Start: systemctl enable --now firewalld"
else
    ok "firewalld is running"

    # Check external-facing ports (Nginx)
    _fw_check() {
        local port="$1" label="$2"
        if _run_root firewall-cmd --query-port="${port}/tcp" > /dev/null 2>&1; then
            ok "Firewall: port $port/tcp open ($label)"
        else
            warn "Firewall: port $port/tcp not open ($label)"
            if [ "$APPLY_MODE" -eq 1 ]; then
                if askYesNo "Open port $port/tcp ($label)?" "y"; then
                    _run_root firewall-cmd --permanent --add-port="${port}/tcp"
                    ok "Port $port/tcp opened"
                fi
            fi
        fi
    }

    _fw_check 80  "HTTP  → Nginx redirect"
    _fw_check 443 "HTTPS → Nginx proxy"

    # WLS ports must NOT be open externally
    for PORT in "${WLS_ADMIN_PORT:-7001}" "${WLS_FORMS_PORT:-9001}" "${WLS_REPORTS_PORT:-9002}" 5556; do
        if _run_root firewall-cmd --query-port="${PORT}/tcp" > /dev/null 2>&1; then
            warn "Firewall: WLS port $PORT/tcp is open externally – should be closed (Nginx proxies this)"
            info "  Close: firewall-cmd --permanent --remove-port=${PORT}/tcp"
        else
            ok "Firewall: WLS port $PORT/tcp correctly closed externally"
        fi
    done

    # Apply pending firewall changes
    if [ "$APPLY_MODE" -eq 1 ]; then
        _run_root firewall-cmd --reload > /dev/null 2>&1 && \
            ok "Firewall rules reloaded"
    fi
fi

# =============================================================================
# Summary + reboot notice
# =============================================================================

printLine
if [ "$APPLY_MODE" -eq 1 ] && [ "$REBOOT_NEEDED" -eq 1 ]; then
    printf "\n\033[33m  *** REBOOT REQUIRED ***\033[0m\n"
    printf "  SELinux mode change and/or kernel update requires a reboot.\n"
    printf "  After reboot, continue with: ./09-Install/02-root_os_packages.sh\n\n" \
        | tee -a "${LOG_FILE:-/dev/null}"
elif [ "$APPLY_MODE" -eq 1 ]; then
    info "No reboot required – continue with: ./09-Install/02-root_os_packages.sh"
else
    info "Re-run with --apply to apply reported changes"
fi

print_summary
exit "$EXIT_CODE"
