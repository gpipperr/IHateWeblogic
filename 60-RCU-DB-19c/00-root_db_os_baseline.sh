#!/bin/bash
# =============================================================================
# Script   : 00-root_db_os_baseline.sh
# Purpose  : Apply Oracle DB-specific OS settings on top of (or instead of)
#            the FMW baseline:
#              - Install oracle-database-preinstall-19c RPM
#              - DB-specific sysctl params (sem, aio, file-max, …)
#              - Upgrade shmmax/shmall to DB-sized values (calculated from RAM)
#            Safe to run AFTER 09-Install FMW software install — WLS runtime
#            does not need the smaller shmmax/shmall values set during WLS OUI.
# Call     : ./60-RCU-DB-19c/00-root_db_os_baseline.sh
#            ./60-RCU-DB-19c/00-root_db_os_baseline.sh --apply
#            ./60-RCU-DB-19c/00-root_db_os_baseline.sh --help
# Runs as  : root
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/01-db_os_baseline.md
# =============================================================================

# --- Auto-elevate via sudo if not already root --------------------------------
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -v >/dev/null 2>&1; then
        exec sudo "$0" "$@"
    fi
    printf "\033[31mFATAL\033[0m: Must run as root or have sudo rights\n" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

# --- Source environment.conf (for ORACLE_BASE) --------------------------------
if [ ! -f "$ENV_CONF" ]; then
    printf "\033[31mFATAL\033[0m: environment.conf not found: %s\n" "$ENV_CONF" >&2
    printf "  Run first: 09-Install/01-setup-interview.sh --apply\n" >&2; exit 2
fi
# shellcheck source=../environment.conf
source "$ENV_CONF"

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false

_usage() {
    printf "Usage: %s [--apply] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"  "Dry-run: show calculated values, no changes"
    printf "  %-12s %s\n" "--apply" "Apply all OS settings"
    printf "  %-12s %s\n" "--help"  "Show this help"
    printf "\nRuns as: root\n"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)   APPLY=true ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 1 ;;
    esac
done
unset _arg

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – DB OS Baseline\033[0m\n"              | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                          | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"             | tee -a "$LOG_FILE"
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                 | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

ok "Running as: $(id -un) (uid=$(id -u))"

command -v dnf > /dev/null 2>&1 \
    && ok "dnf found: $(dnf --version 2>/dev/null | head -1)" \
    || { fail "dnf not found – Oracle Linux / RHEL required"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# =============================================================================
# Calculate shmmax / shmall from actual RAM
# =============================================================================

section "shmmax / shmall Calculation"

RAM_KB=$(awk '/MemTotal/ { print $2 }' /proc/meminfo)
RAM_BYTES=$(( RAM_KB * 1024 ))
SHMMAX=$(( RAM_BYTES / 2 ))
SHMALL=$(( SHMMAX / 4096 ))   # in 4 kB pages

# Minimum 2 GB even on small VMs
SHMMAX_MIN=$(( 2 * 1024 * 1024 * 1024 ))
[ "$SHMMAX" -lt "$SHMMAX_MIN" ] && SHMMAX=$SHMMAX_MIN && SHMALL=$(( SHMMAX / 4096 ))

printList "Total RAM"  30 "$(( RAM_KB / 1024 )) MB"
printList "shmmax"     30 "$SHMMAX ($(( SHMMAX / 1024 / 1024 / 1024 )) GB)"
printList "shmall"     30 "$SHMALL pages"

SYSCTL_FILE="/etc/sysctl.d/60-oracle-db.conf"
LIMITS_FILE="/etc/security/limits.d/60-oracle-db.conf"
CORE_DIR="/var/tmp/core"

# =============================================================================
# Dry-run exit
# =============================================================================

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to apply settings."
    info "Would write: $SYSCTL_FILE"
    info "Would write: $LIMITS_FILE"
    info "Would create: $CORE_DIR"
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# 1. oracle-database-preinstall-19c RPM
# =============================================================================

section "oracle-database-preinstall-19c"

if rpm -q oracle-database-preinstall-19c > /dev/null 2>&1; then
    ok "oracle-database-preinstall-19c already installed"
else
    info "Installing oracle-database-preinstall-19c ..."
    if dnf install -y oracle-database-preinstall-19c 2>&1 | tee -a "$LOG_FILE"; then
        ok "oracle-database-preinstall-19c installed"
    else
        fail "oracle-database-preinstall-19c installation failed"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
fi

# =============================================================================
# 2. DB-specific sysctl parameters
# =============================================================================

section "sysctl – DB-specific parameters"
info "Writing: $SYSCTL_FILE"

backup_file "$SYSCTL_FILE" "$(dirname "$SYSCTL_FILE")" 2>/dev/null || true

cat > "$SYSCTL_FILE" << SYSCTLEOF
# =============================================================================
# Oracle Database 19c – DB-specific kernel parameters
# Managed by: IHateWeblogic/60-RCU-DB-19c/00-root_db_os_baseline.sh
# Reference : 60-RCU-DB-19c/docs/01-db_os_baseline.md
# DO NOT EDIT manually – re-run the script to regenerate.
# =============================================================================

# --- Shared memory (calculated from RAM: ${RAM_KB} kB) ----------------------
# Overrides the WLS-OUI-sized values from 09-Install/01-root_os_baseline.sh.
# WLS runtime does NOT need the smaller values — only WLS OUI during install.
kernel.shmmax = ${SHMMAX}
kernel.shmall = ${SHMALL}
kernel.shmmni = 4096

# --- Semaphores (required by Oracle background processes) --------------------
kernel.sem = 250 32000 100 128

# --- Async I/O ---------------------------------------------------------------
fs.aio-max-nr = 3145728

# --- File descriptors --------------------------------------------------------
fs.file-max = 6815744

# --- Memory ------------------------------------------------------------------
vm.min_free_kbytes = 524288

# --- IPC message queues ------------------------------------------------------
kernel.msgmax = 65536
kernel.msgmnb = 65536

# --- Oracle Net network buffers ----------------------------------------------
net.core.rmem_default = 262144
net.core.rmem_max     = 4194304
net.core.wmem_default = 262144
net.core.wmem_max     = 1048576

# --- Core dumps (Oracle diagnostic) -----------------------------------------
fs.suid_dumpable        = 1
kernel.core_uses_pid    = 1
kernel.core_pattern     = /var/tmp/core/coredump_%h_.%s.%u.%g_%t_%E_%e
SYSCTLEOF

chmod 644 "$SYSCTL_FILE"
ok "sysctl file written: $SYSCTL_FILE"

info "Applying sysctl settings ..."
if sysctl --system 2>&1 | grep -E "(error|failed)" | tee -a "$LOG_FILE" | grep -q .; then
    warn "sysctl --system reported errors – check log"
else
    ok "sysctl settings applied"
fi

# Verify key values
for _param in kernel.shmmax kernel.shmall kernel.sem fs.aio-max-nr; do
    _val="$(sysctl -n "$_param" 2>/dev/null | tr '\t' ' ')"
    ok "$(printf "  %-30s %s" "$_param" "$_val")"
done
unset _param _val

# =============================================================================
# 3. User limits for oracle
# =============================================================================

section "Security Limits – oracle user"
info "Writing: $LIMITS_FILE"

backup_file "$LIMITS_FILE" "$(dirname "$LIMITS_FILE")" 2>/dev/null || true

cat > "$LIMITS_FILE" << LIMITSEOF
# =============================================================================
# Oracle Database 19c – oracle user limits
# Managed by: IHateWeblogic/60-RCU-DB-19c/00-root_db_os_baseline.sh
# Reference : 60-RCU-DB-19c/docs/01-db_os_baseline.md
# =============================================================================
oracle  soft  nofile    131072
oracle  hard  nofile    131072
oracle  soft  nproc     131072
oracle  hard  nproc     131072
oracle  soft  core      unlimited
oracle  hard  core      unlimited
oracle  soft  memlock   50000000
oracle  hard  memlock   50000000
oracle  soft  stack     10240
LIMITSEOF

chmod 644 "$LIMITS_FILE"
ok "Limits file written: $LIMITS_FILE"

# =============================================================================
# 4. Core dump directory
# =============================================================================

section "Core Dump Directory"

mkdir -p "$CORE_DIR"
chmod 1777 "$CORE_DIR"
ok "Created: $CORE_DIR (mode 1777)"

# =============================================================================
# 5. Transparent Huge Pages check
# =============================================================================

section "Transparent Huge Pages"

THP_FILE="/sys/kernel/mm/transparent_hugepage/enabled"
if [ -f "$THP_FILE" ]; then
    THP_STATUS="$(cat "$THP_FILE")"
    if printf "%s" "$THP_STATUS" | grep -q "\[never\]"; then
        ok "THP already disabled: $THP_STATUS"
    else
        warn "THP not disabled: $THP_STATUS"
        warn "  Run 09-Install/01-root_os_baseline.sh --apply first, or:"
        warn "  grubby --update-kernel=ALL --args='transparent_hugepage=never'"
        warn "  (requires reboot)"
    fi
else
    info "THP sysfs file not found – skipping check"
fi

# =============================================================================

print_summary
exit $EXIT_CODE
