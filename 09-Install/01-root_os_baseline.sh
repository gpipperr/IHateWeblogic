#!/bin/bash
# =============================================================================
# Script   : 01-root_os_baseline.sh
# Purpose  : Phase 0 – OS baseline configuration for Oracle FMW 14.1.2 on OL 9
#            SELinux disable, DNF repos, OS update, kernel parameters,
#            Transparent HugePages disable, /dev/shm, core dumps, firewall
#            (safe activation with rollback timer), sshd hardening.
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
ONLY_SECTIONS=""      # --only: comma list – other sections run check-only

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-20s %s\n" "--apply"        "Write configuration changes (reboot required after)"
    printf "  %-20s %s\n" "--skip-update"  "Skip dnf upgrade (use for re-runs)"
    printf "  %-20s %s\n" "--only LIST"    "Apply only these sections (others check-only):"
    printf "  %-20s %s\n" ""               "selinux,repos,update,kernel,thp,shm,swap,core,firewall,ssh"
    printf "  %-20s %s\n" "--help"         "Show this help"
    printf "\nIMPORTANT: A system reboot is required after --apply.\n"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)        APPLY_MODE=1;   shift ;;
        --skip-update)  SKIP_UPDATE=1;  shift ;;
        --only)         ONLY_SECTIONS="${2:?--only needs a list}"; shift 2 ;;
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

# _apply_for key – APPLY_MODE for the next section: the requested --apply,
# or 0 (check only) when --only is given and does not list this section
APPLY_REQUESTED=$APPLY_MODE
_apply_for() {
    APPLY_MODE=$APPLY_REQUESTED
    if [ -n "$ONLY_SECTIONS" ] && [[ ",${ONLY_SECTIONS}," != *",$1,"* ]]; then
        APPLY_MODE=0
    fi
}

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

_apply_for selinux
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
            _run_root cp "$SELINUX_CFG" "${SELINUX_CFG}.bak_$(date +%Y%m%d_%H%M%S)"
            _run_root sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$SELINUX_CFG"
            ok "SELinux set to disabled in config file"
            warn "REBOOT REQUIRED for SELinux change to take effect"
        fi
    fi
fi

# =============================================================================
# 2. DNF Repositories
# =============================================================================

_apply_for repos
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

_apply_for update
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

_apply_for kernel
section "Kernel Parameters"

SYSCTL_FILE="/etc/sysctl.d/99-oracle-fmw.conf"

# Define target values for WebLogic / Forms / Reports (no Oracle Database).
# shmmax/shmall and the block below (kernel.sem through net.core.wmem_max)
# are confirmed against a real 100-500-concurrent-session production host
# (gpiwls01) — see docs/00-root_set_os_parameter.md. Previously only
# shmmax/shmall/port_range were targeted here with different (unconfirmed)
# values; os_check.sh already read/displayed the others without anything
# actually setting them.
declare -A SYSCTL_WANT=(
    ["kernel.shmmax"]="8318808064"
    ["kernel.shmall"]="2030959"
    ["kernel.sem"]="250 32000 100 128"
    ["kernel.shmmni"]="4096"
    ["fs.file-max"]="6815744"
    ["fs.aio-max-nr"]="1048576"
    ["net.core.rmem_default"]="262144"
    ["net.core.rmem_max"]="4194304"
    ["net.core.wmem_default"]="262144"
    ["net.core.wmem_max"]="4194304"
    ["net.ipv4.ip_local_port_range"]="9000 65500"
    ["vm.swappiness"]="10"
    ["kernel.panic_on_oops"]="1"
    ["fs.suid_dumpable"]="1"
    ["kernel.core_uses_pid"]="1"
    ["kernel.core_pattern"]="/var/tmp/core/coredump_%h_.%s.%u.%g_%t_%E_%e"
    ["net.ipv6.conf.all.disable_ipv6"]="1"
    ["net.ipv6.conf.default.disable_ipv6"]="1"
)

# Keys where a LARGER value is always fine (a minimum, not an exact target).
# kernel.shmmax/shmall only count as minimums when a local Oracle DB needs its
# own larger values (LOCAL_REP_DB=true); on a pure WLS host the exact values
# are enforced, because DB-sized shm values are what the conflict fix removes.
SYSCTL_MIN_KEYS=" kernel.shmmni fs.file-max fs.aio-max-nr net.core.rmem_default net.core.rmem_max net.core.wmem_default net.core.wmem_max "
[ "${LOCAL_REP_DB:-false}" = "true" ] && SYSCTL_MIN_KEYS="${SYSCTL_MIN_KEYS}kernel.shmmax kernel.shmall "

# _sysctl_satisfied  key  actual  want  – 0 if actual meets the target
_sysctl_satisfied() {
    local key="$1" actual="$2" want="$3"
    [ "$actual" = "$want" ] && return 0
    case "$SYSCTL_MIN_KEYS" in
        *" $key "*)
            [[ "$actual" =~ ^[0-9]+$ ]] && [[ "$want" =~ ^[0-9]+$ ]] && [ "$actual" -ge "$want" ] && return 0 ;;
    esac
    return 1
}

SYSCTL_ISSUES=0
for KEY in "${!SYSCTL_WANT[@]}"; do
    # sysctl -n may use tabs as separators (e.g. ip_local_port_range) – normalise to single space
    CURRENT_VAL="$(sysctl -n "$KEY" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"
    WANT_VAL="${SYSCTL_WANT[$KEY]}"
    if [ "$CURRENT_VAL" = "$WANT_VAL" ]; then
        ok "$(printf "%-42s = %s" "$KEY" "$CURRENT_VAL")"
    elif _sysctl_satisfied "$KEY" "$CURRENT_VAL" "$WANT_VAL"; then
        ok "$(printf "%-42s = %s  (>= %s, larger is fine)" "$KEY" "$CURRENT_VAL" "$WANT_VAL")"
    else
        warn "$(printf "%-42s = %s  (want: %s)" "$KEY" "${CURRENT_VAL:-(unset)}" "$WANT_VAL")"
        SYSCTL_ISSUES=$((SYSCTL_ISSUES + 1))
    fi
done

# --- Conflict check: other sysctl files that override our values ---
# /etc/sysctl.conf is loaded AFTER all sysctl.d/*.conf and therefore wins.
# oracle-database-preinstall-* sets DB-sized shmmax/shmall that break WLS OUI.
CONFLICT_FILES=()
for KEY in "${!SYSCTL_WANT[@]}"; do
    WANT_VAL="${SYSCTL_WANT[$KEY]}"
    # Search all sysctl config files except our own
    while IFS= read -r CONF_FILE; do
        [ "$CONF_FILE" = "$SYSCTL_FILE" ] && continue
        if grep -qE "^[[:space:]]*${KEY}[[:space:]]*=" "$CONF_FILE" 2>/dev/null; then
            FILE_VAL="$(grep -E "^[[:space:]]*${KEY}[[:space:]]*=" "$CONF_FILE" \
                | tail -1 | sed 's/.*=[[:space:]]*//')"
            # Strip whitespace for comparison
            FILE_VAL_NORM="$(printf "%s" "$FILE_VAL" | tr -s ' \t' ' ' | sed 's/^ //;s/ $//')"
            WANT_VAL_NORM="$(printf "%s" "$WANT_VAL" | tr -s ' \t' ' ' | sed 's/^ //;s/ $//')"
            if ! _sysctl_satisfied "$KEY" "$FILE_VAL_NORM" "$WANT_VAL_NORM"; then
                warn "Conflicting sysctl in $(basename "$CONF_FILE"): $KEY = $FILE_VAL_NORM (overrides our: $WANT_VAL_NORM)"
                info "  File: $CONF_FILE"
                CONFLICT_FILES+=("$CONF_FILE")
            fi
        fi
    done < <(find /etc/sysctl.d /etc/sysctl.conf -maxdepth 1 -type f \
        ! -name "*.bak*" ! -name "*.orig" ! -name "*.rpmsave" 2>/dev/null | sort)
done

if [ "${#CONFLICT_FILES[@]}" -gt 0 ]; then
    # Deduplicate
    mapfile -t CONFLICT_FILES < <(printf "%s\n" "${CONFLICT_FILES[@]}" | sort -u)
    info "  These files are loaded after 99-oracle-fmw.conf and win the merge."
    info "  Typical cause: oracle-database-preinstall-* RPM (DB-sized shm values)."

    if [ "${LOCAL_REP_DB:-false}" = "true" ]; then
        # Oracle DB runs on this host – it needs the large shm values; only warn, never touch.
        warn "$(printf "%d" "${#CONFLICT_FILES[@]}") sysctl file(s) have values sized for Oracle DB (LOCAL_REP_DB=true – not modified)"
        info "  kernel.shmmax/shmall are intentionally set for the local DB, not for WLS OUI."
        info "  If WLS OUI fails during install, temporarily set LOCAL_REP_DB=false and re-run."
    else
        fail "$(printf "%d" "${#CONFLICT_FILES[@]}") external sysctl file(s) override our WebLogic parameters"
        info "  LOCAL_REP_DB=false – no local Oracle DB; these large shm values are not needed."
        info "  Fix: comment out the conflicting keys (--apply), or set LOCAL_REP_DB=true to skip."
        if [ "$APPLY_MODE" -eq 1 ]; then
            for CF in "${CONFLICT_FILES[@]}"; do
                if askYesNo "Comment out conflicting keys in $(basename "$CF")?" "y"; then
                _run_root cp "$CF" "${CF}.bak_$(date +%Y%m%d_%H%M%S)"
                for KEY in "${!SYSCTL_WANT[@]}"; do
                    WANT_VAL="${SYSCTL_WANT[$KEY]}"
                    if grep -qE "^[[:space:]]*${KEY}[[:space:]]*=" "$CF" 2>/dev/null; then
                        FILE_VAL="$(grep -E "^[[:space:]]*${KEY}[[:space:]]*=" "$CF" \
                            | tail -1 | sed 's/.*=[[:space:]]*//' \
                            | tr -s ' \t' ' ' | sed 's/^ //;s/ $//')"
                        WANT_VAL_NORM="$(printf "%s" "$WANT_VAL" \
                            | tr -s ' \t' ' ' | sed 's/^ //;s/ $//')"
                        if ! _sysctl_satisfied "$KEY" "$FILE_VAL" "$WANT_VAL_NORM"; then
                            _run_root sed -i \
                                "s|^\([[:space:]]*${KEY}[[:space:]]*=\)|# [oracle-fmw] \1|" "$CF"
                            ok "Commented out $KEY in $(basename "$CF")"
                        fi
                    fi
                done
                _run_root sysctl --system > /dev/null 2>&1
                ok "sysctl reloaded"
            fi
        done
        fi  # APPLY_MODE
    fi  # LOCAL_REP_DB=false
fi  # CONFLICT_FILES

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

# --- IPv6 per network interface -----------------------------------------------
# net.ipv6.conf.default only applies to interfaces created AFTER it was set –
# an interface that already exists keeps its own value, and NetworkManager
# (ipv6.method) re-enables IPv6 on its connections at every activation.
# Seen at a customer 2026-10-15: all=1, default=1, ens33=0 with an fe80::
# address -> the JVMs listened via the IPv6 stack ([::ffff:127.0.0.1]:5556).
# Runtime fix: sysctl per interface; persistent fix: nmcli ipv6.method disabled.
IPV6_IF_ISSUES=0
for _ifdir in /proc/sys/net/ipv6/conf/*; do
    _if="$(basename "$_ifdir")"
    case "$_if" in all|default|lo) continue ;; esac
    _val="$(cat "$_ifdir/disable_ipv6" 2>/dev/null)"
    if [ "$_val" = "1" ]; then
        ok "$(printf "%-42s = %s" "net.ipv6.conf.${_if}.disable_ipv6" "$_val")"
    else
        warn "$(printf "%-42s = %s  (want: 1 – IPv6 still active on this interface)" "net.ipv6.conf.${_if}.disable_ipv6" "${_val:-?}")"
        IPV6_IF_ISSUES=$((IPV6_IF_ISSUES + 1))
        if [ "$APPLY_MODE" -eq 1 ] && askYesNo "Disable IPv6 on interface ${_if} now?" "y"; then
            _run_root sysctl -w "net.ipv6.conf.${_if}.disable_ipv6=1" > /dev/null \
                && ok "IPv6 disabled on ${_if} (runtime)"
        fi
    fi
    # NetworkManager: keep it from re-enabling IPv6 at the next activation/boot
    if command -v nmcli > /dev/null 2>&1; then
        _con="$(nmcli -g GENERAL.CONNECTION device show "$_if" 2>/dev/null | head -1)"
        if [ -n "$_con" ]; then
            _method="$(nmcli -g ipv6.method connection show "$_con" 2>/dev/null)"
            if [ "$_method" = "disabled" ] || [ "$_method" = "ignore" ]; then
                ok "$(printf "%-42s = %s" "NM connection '${_con}' ipv6.method" "$_method")"
            else
                warn "$(printf "%-42s = %s  (want: disabled)" "NM connection '${_con}' ipv6.method" "${_method:-?}")"
                IPV6_IF_ISSUES=$((IPV6_IF_ISSUES + 1))
                if [ "$APPLY_MODE" -eq 1 ] && askYesNo "Set ipv6.method=disabled on NM connection '${_con}' (takes effect at next activation/boot)?" "y"; then
                    _run_root nmcli connection modify "$_con" ipv6.method disabled \
                        && ok "NM connection '${_con}': ipv6.method=disabled"
                fi
            fi
        fi
    fi
done
unset _ifdir _if _val _con _method
[ "$IPV6_IF_ISSUES" -gt 0 ] && [ "$APPLY_MODE" -ne 1 ] && \
    info "  Re-run with --apply; after changing it restart the WLS/Reports JVMs (they bind their stack at start)"

# =============================================================================
# 5. Transparent HugePages
# =============================================================================

_apply_for thp
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

_apply_for shm
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
            _run_root cp /etc/fstab "/etc/fstab.bak_$(date +%Y%m%d_%H%M%S)"
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
# 6b. Swap Space
# =============================================================================

_apply_for swap
section "Swap Space"

# OUI hard check: "Checking swap space: must be greater than 512 MB."
# On VMs swap is often 0 MB – OUI refuses to run.
# vm.swappiness=10 (set above) means swap is rarely used in practice;
# it is present purely as OUI prereq and emergency memory buffer.

SWAP_TOTAL_MB="$(free -m 2>/dev/null | awk '/Swap/ {print $2}')"
SWAP_TOTAL_MB="${SWAP_TOTAL_MB:-0}"
SWAP_OUI_MIN_MB=512
SWAP_WANT_MB=2048
SWAPFILE="${ORACLE_BASE:-/u01/app/oracle}/swapfile"

printf "  %-26s %s MB\n" "Current swap total:"  "$SWAP_TOTAL_MB"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s MB\n" "OUI minimum:"          "$SWAP_OUI_MIN_MB" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s MB\n" "Recommended:"          "$SWAP_WANT_MB"    | tee -a "${LOG_FILE:-/dev/null}"

SWAP_ACTIVE="$(swapon --show --noheadings 2>/dev/null)"
if [ -n "$SWAP_ACTIVE" ]; then
    info "Active swap devices/files:"
    printf "%s\n" "$SWAP_ACTIVE" | while IFS= read -r _swline; do
        printf "    %s\n" "$_swline" | tee -a "${LOG_FILE:-/dev/null}"
    done
else
    info "No swap devices or files currently active"
fi

# A 2 GiB swapfile shows as 2047 MB in `free -m` (one header page) – allow 32 MB slack
if [ "$SWAP_TOTAL_MB" -ge "$((SWAP_WANT_MB - 32))" ]; then
    ok "Swap OK: ${SWAP_TOTAL_MB} MB (recommended: ${SWAP_WANT_MB} MB)"
elif [ "$SWAP_TOTAL_MB" -ge "$SWAP_OUI_MIN_MB" ]; then
    warn "Swap ${SWAP_TOTAL_MB} MB meets OUI minimum (${SWAP_OUI_MIN_MB} MB) but below recommended ${SWAP_WANT_MB} MB"
else
    fail "Swap ${SWAP_TOTAL_MB} MB is below OUI minimum ${SWAP_OUI_MIN_MB} MB – OUI will refuse to run"
    info "  Swapfile location: ${SWAPFILE}  (${SWAP_WANT_MB} MB)"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Create ${SWAP_WANT_MB}M swapfile at ${SWAPFILE}?" "y"; then
            AVAIL_MB="$(df -m "$(dirname "$SWAPFILE")" 2>/dev/null | awk 'NR==2 {print $4}')"
            if [ -z "$AVAIL_MB" ] || [ "$AVAIL_MB" -lt "$SWAP_WANT_MB" ]; then
                fail "Not enough space: need ${SWAP_WANT_MB}M, have ${AVAIL_MB:-?}M in $(dirname "$SWAPFILE")"
                info "  Free up space or adjust ORACLE_BASE in environment.conf"
            else
                # fallocate is instant on ext4/xfs; dd is fallback for e.g. NFS/tmpfs
                if _run_root fallocate -l "${SWAP_WANT_MB}M" "$SWAPFILE" 2>/dev/null; then
                    ok "Swapfile created with fallocate: $SWAPFILE"
                else
                    info "fallocate not supported on this filesystem – using dd (this may take a while)..."
                    _run_root dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_WANT_MB" \
                        2>&1 | tee -a "${LOG_FILE:-/dev/null}"
                fi
                _run_root chmod 600 "$SWAPFILE"
                _run_root mkswap "$SWAPFILE" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
                _run_root swapon "$SWAPFILE"
                # Persist across reboots
                if ! grep -q "$SWAPFILE" /etc/fstab 2>/dev/null; then
                    _run_root cp /etc/fstab "/etc/fstab.bak_$(date +%Y%m%d_%H%M%S)"
                    printf "%s none swap sw 0 0\n" "$SWAPFILE" \
                        | _run_root tee -a /etc/fstab > /dev/null
                    ok "Swapfile added to /etc/fstab (persistent)"
                fi
                SWAP_NOW_MB="$(free -m 2>/dev/null | awk '/Swap/ {print $2}')"
                ok "Swapfile activated – swap total now: ${SWAP_NOW_MB} MB"
            fi
        fi
    else
        info "  Run with --apply to create swapfile automatically"
        info "  Manual: fallocate -l 2G $SWAPFILE && chmod 600 $SWAPFILE && mkswap $SWAPFILE && swapon $SWAPFILE"
        info "  Persist: echo \"$SWAPFILE none swap sw 0 0\" >> /etc/fstab"
    fi
fi

# =============================================================================
# 7. Core Dump Directory
# =============================================================================

_apply_for core
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

_apply_for firewall
section "Firewall"

# Doc: docs/00-root_set_os_parameter.md, "Firewall and SSH hardening".
# Enabling firewalld is the step that can cut connections: question with
# default "no", ssh pre-check, rollback timer that stops firewalld again
# unless a new ssh login was confirmed.
FW_ROLLBACK_MIN="${FIREWALL_ROLLBACK_MIN:-10}"
FW_RUNNING=0

if ! command -v firewall-cmd > /dev/null 2>&1; then
    warn "firewall-cmd not found – install firewalld or configure firewall manually"
elif _run_root firewall-cmd --state > /dev/null 2>&1; then
    FW_RUNNING=1
    ok "firewalld is running ($(_run_root systemctl is-enabled firewalld 2>/dev/null))"
else
    warn "firewalld is not running – every listening process is reachable from the network"
    info "  (Forms frmweb / rwserver / Reports engines / Coherence listen on all interfaces)"
    _zone="$(_run_root firewall-offline-cmd --get-default-zone 2>/dev/null)"
    _zone="${_zone:-public}"
    if ! _run_root firewall-offline-cmd --zone="$_zone" --query-service=ssh > /dev/null 2>&1; then
        fail "ssh is NOT in the permanent firewalld zone '$_zone' – enabling firewalld would lock out ssh"
        info "  Add first: firewall-offline-cmd --zone=$_zone --add-service=ssh"
    elif [ "$APPLY_MODE" -eq 1 ]; then
        info "  Zone '$_zone' allows ssh. Keep a console session (VM console) open."
        if askYesNo "Enable firewalld now (rollback timer ${FW_ROLLBACK_MIN} min)?" "n"; then
            # Safety net: stops firewalld again unless cancelled below
            _run_root systemctl stop ihw-fw-rollback.timer > /dev/null 2>&1
            if _run_root systemd-run --on-active="${FW_ROLLBACK_MIN}min" --unit=ihw-fw-rollback \
                    systemctl stop firewalld > /dev/null 2>&1; then
                ok "Rollback timer set: firewalld stops in ${FW_ROLLBACK_MIN} min unless confirmed"
                if _run_root systemctl start firewalld; then
                    FW_RUNNING=1
                    FW_JUST_STARTED=1
                    ok "firewalld started (zone $_zone)"
                else
                    fail "systemctl start firewalld failed"
                    _run_root systemctl stop ihw-fw-rollback.timer > /dev/null 2>&1
                fi
            else
                fail "systemd-run (rollback timer) failed – firewalld NOT started"
            fi
        fi
    else
        info "  Enable: re-run with --apply (with ${FW_ROLLBACK_MIN}-min rollback timer)"
    fi
    unset _zone
fi

if [ "$FW_RUNNING" -eq 1 ]; then
    # _fw_add  firewall-cmd-args  label – permanent + runtime (no reload needed)
    _fw_add() {
        _run_root firewall-cmd --permanent "$1" > /dev/null 2>&1 \
            && _run_root firewall-cmd "$1" > /dev/null 2>&1
    }
    # _fw_need  query-arg add-arg label  – check, open on --apply (question)
    _fw_need() {
        local q="$1" a="$2" label="$3"
        if _run_root firewall-cmd --permanent "$q" > /dev/null 2>&1; then
            ok "Firewall: $label open"
        else
            warn "Firewall: $label not open"
            if [ "$APPLY_MODE" -eq 1 ] && { [ "${FW_JUST_STARTED:-0}" -eq 1 ] || askYesNo "Open $label?" "y"; }; then
                _fw_add "$a" && ok "Firewall: $label opened" || fail "Firewall: opening $label failed"
            fi
        fi
    }

    _fw_need --query-service=ssh   --add-service=ssh   "ssh (22/tcp)"
    _fw_need --query-service=http  --add-service=http  "http (80/tcp → Nginx redirect)"
    _fw_need --query-service=https --add-service=https "https (443/tcp → Nginx proxy)"

    # Reports server discovery (multicast 228.5.6.7, UDP, port from rwnetwork.conf).
    # The Reports server sends a multicast packet at start and requires to
    # RECEIVE packets (at least its own) - with the UDP port blocked it dies
    # with "REP-50600 Broadcasting is disabled" and the Node Manager restarts
    # it in a loop (RWServer.startServer, ServerPacketHandler.packetsReceived;
    # customer 2026-10-15). Port = REPORTS_BROADCAST_PORT, the same value
    # 13-oracle_setup_reports.sh writes into the three rwnetwork.conf files
    # (default 14027, unique per environment in the subnet: 14021-14030).
    case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
        *REPORTS*)
            _bport="${REPORTS_BROADCAST_PORT:-14027}"
            _fw_need --query-port="${_bport}/udp" --add-port="${_bport}/udp" \
                "${_bport}/udp (Reports multicast discovery, else REP-50600)"
            [ -z "${REPORTS_BROADCAST_PORT:-}" ] && \
                info "  REPORTS_BROADCAST_PORT not set yet (init_env.sh) – default 14027 used; keep both in sync"
            unset _bport
            ;;
    esac

    # WLS ports must NOT be open externally
    for PORT in "${WLS_ADMIN_PORT:-7001}" "${WLS_FORMS_PORT:-9001}" "${WLS_REPORTS_PORT:-9002}" 5556; do
        if _run_root firewall-cmd --query-port="${PORT}/tcp" > /dev/null 2>&1; then
            warn "Firewall: WLS port $PORT/tcp is open externally – should be closed (Nginx proxies this)"
            info "  Close: firewall-cmd --permanent --remove-port=${PORT}/tcp"
        else
            ok "Firewall: WLS port $PORT/tcp correctly closed externally"
        fi
    done

    # Services not needed on an FMW server (default zone of OL9 has cockpit)
    for _svc in ${FIREWALL_REMOVE_SERVICES-cockpit}; do
        if _run_root firewall-cmd --permanent --query-service="$_svc" > /dev/null 2>&1; then
            warn "Firewall: service '$_svc' is open – not needed on an FMW server"
            if [ "$APPLY_MODE" -eq 1 ] && askYesNo "Remove service '$_svc' from the zone?" "n"; then
                _run_root firewall-cmd --permanent --remove-service="$_svc" > /dev/null 2>&1 \
                    && _run_root firewall-cmd --remove-service="$_svc" > /dev/null 2>&1 \
                    && ok "Firewall: service '$_svc' removed"
            else
                info "  Remove: firewall-cmd --permanent --remove-service=$_svc && firewall-cmd --reload"
            fi
        fi
    done
    unset _svc

    # Local repository DB: its listener must stay reachable for external DB
    # clients (report only – never opened automatically)
    if [ "${LOCAL_REP_DB:-false}" = "true" ]; then
        if _run_root firewall-cmd --query-port="${DB_PORT:-1521}/tcp" > /dev/null 2>&1; then
            ok "Firewall: DB listener port ${DB_PORT:-1521}/tcp open (LOCAL_REP_DB=true)"
        else
            info "Firewall: DB listener ${DB_PORT:-1521}/tcp closed – local WLS → DB uses lo (fine);"
            info "  open only if other hosts need the DB: firewall-cmd --permanent --add-port=${DB_PORT:-1521}/tcp"
        fi
    fi

    # Just enabled: confirm a NEW ssh login before the rollback timer is removed
    if [ "${FW_JUST_STARTED:-0}" -eq 1 ]; then
        printf "\n" >&2
        info "Test NOW in a second window: a new ssh login (keep this session open)"
        if askYesNo "New ssh login works – keep firewalld enabled?" "n"; then
            _run_root systemctl enable firewalld > /dev/null 2>&1 && ok "firewalld enabled (starts at boot)"
            _run_root systemctl stop ihw-fw-rollback.timer > /dev/null 2>&1 \
                && ok "Rollback timer removed"
        else
            warn "Not confirmed – rollback timer stops firewalld within ${FW_ROLLBACK_MIN} min"
            info "  Stop it now: systemctl stop firewalld"
        fi
    fi
fi

# =============================================================================
# 9. SSH hardening (sshd) – only with SSH_ALLOW_USERS set
# =============================================================================

_apply_for ssh
section "SSH hardening (sshd)"

SSHD_DROPIN="/etc/ssh/sshd_config.d/10-ihw-hardening.conf"
SSHD_MATCH="/etc/ssh/sshd_config.d/99-ihw-match.conf"

# Current effective values (sshd -T needs root)
_sshd_eff="$(_run_root sshd -T 2>/dev/null)"
for _k in permitrootlogin passwordauthentication x11forwarding maxauthtries allowusers allowtcpforwarding; do
    _v="$(printf '%s\n' "$_sshd_eff" | awk -v k="$_k" '$1 == k {$1=""; sub(/^ /,""); printf "%s%s", (n++?" ":""), $0}')"
    printList "$_k" 26 "${_v:-(not set)}"
done
unset _k _v

if [ -z "${SSH_ALLOW_USERS:-}" ]; then
    info "SSH_ALLOW_USERS not set in environment.conf – check only (no sshd changes)"
    info "  Example: SSH_ALLOW_USERS=\"admin oracle\"  SSH_PASSWORD_USERS=\"admin\""
    printf '%s\n' "$_sshd_eff" | grep -q '^permitrootlogin no' \
        || warn "root may log in via ssh (PermitRootLogin != no)"
    printf '%s\n' "$_sshd_eff" | grep -q '^x11forwarding yes' \
        && warn "X11Forwarding yes – not needed on a server (installs run headless by script)"
else
    _ssh_ok=1
    for _u in $SSH_ALLOW_USERS; do
        if ! getent passwd "$_u" > /dev/null; then
            fail "SSH_ALLOW_USERS: user '$_u' does not exist"; _ssh_ok=0; continue
        fi
        case " ${SSH_PASSWORD_USERS:-} " in
            *" $_u "*) ok "$(printf "  %-10s allowed, password + key" "$_u")" ;;
            *)
                _home="$(getent passwd "$_u" | cut -d: -f6)"
                if _run_root test -s "$_home/.ssh/authorized_keys"; then
                    ok "$(printf "  %-10s allowed, key only (%s)" "$_u" "$_home/.ssh/authorized_keys")"
                else
                    fail "$(printf "  %-10s key only, but no %s – would be locked out" "$_u" "$_home/.ssh/authorized_keys")"
                    info "  Add a key, or put '$_u' into SSH_PASSWORD_USERS"
                    _ssh_ok=0
                fi
                ;;
        esac
    done
    unset _u _home

    # Desired file content
    _want="$(printf '%s\n' \
        "# Managed by IHateWeblogic 09-Install/01-root_os_baseline.sh – do not edit" \
        "# docs/00-root_set_os_parameter.md \"Firewall and SSH hardening\"" \
        "PermitRootLogin no" \
        "MaxAuthTries 3" \
        "X11Forwarding no" \
        "AllowUsers ${SSH_ALLOW_USERS}" \
        "PasswordAuthentication no")"
    _want_match=""
    if [ -n "${SSH_PASSWORD_USERS:-}" ]; then
        _want_match="$(printf '%s\n' \
            "# Managed by IHateWeblogic 09-Install/01-root_os_baseline.sh – do not edit" \
            "# Must be the last sshd_config.d file: a Match block ends with its file" \
            "Match User ${SSH_PASSWORD_USERS// /,}" \
            "    PasswordAuthentication yes")"
    fi

    if [ "$(_run_root cat "$SSHD_DROPIN" 2>/dev/null)" = "$_want" ] \
       && [ "$(_run_root cat "$SSHD_MATCH" 2>/dev/null)" = "$_want_match" ]; then
        ok "sshd hardening in place: $SSHD_DROPIN${_want_match:+, $SSHD_MATCH}"
    elif [ "$_ssh_ok" -eq 0 ]; then
        fail "sshd hardening NOT applied – fix the FAIL items above first"
    elif [ "$APPLY_MODE" -eq 0 ]; then
        warn "sshd hardening not in place – re-run with --apply"
    elif askYesNo "Write sshd hardening (AllowUsers ${SSH_ALLOW_USERS}) and reload sshd?" "n"; then
        _ts="$(date +%Y%m%d_%H%M%S)"
        for _f in "$SSHD_DROPIN" "$SSHD_MATCH"; do
            _run_root test -f "$_f" && _run_root cp -p "$_f" "${_f}.bak_${_ts}"
        done
        printf '%s\n' "$_want" | _run_root tee "$SSHD_DROPIN" > /dev/null
        if [ -n "$_want_match" ]; then
            printf '%s\n' "$_want_match" | _run_root tee "$SSHD_MATCH" > /dev/null
        else
            _run_root rm -f "$SSHD_MATCH"
        fi
        _run_root chmod 600 "$SSHD_DROPIN" "$SSHD_MATCH" 2>/dev/null
        if _run_root sshd -t 2>&1 | tee -a "${LOG_FILE:-/dev/null}" && [ "${PIPESTATUS[0]}" -eq 0 ]; then
            # Safety net: remove the files again and reload unless confirmed
            _run_root systemctl stop ihw-ssh-rollback.timer > /dev/null 2>&1
            _run_root systemd-run --on-active="${FW_ROLLBACK_MIN}min" --unit=ihw-ssh-rollback \
                /bin/sh -c "rm -f $SSHD_DROPIN $SSHD_MATCH; systemctl reload sshd" > /dev/null 2>&1 \
                && ok "Rollback timer set: hardening removed in ${FW_ROLLBACK_MIN} min unless confirmed"
            _run_root systemctl reload sshd && ok "sshd reloaded – existing sessions stay"
            for _u in $SSH_ALLOW_USERS root; do
                _eff="$(_run_root sshd -T -C "user=$_u,host=check,addr=10.0.0.1" 2>/dev/null \
                        | awk '$1 ~ /^(passwordauthentication|permitrootlogin|x11forwarding)$/ {printf "%s=%s ", $1, $2}')"
                info "$(printf "  effective for %-8s %s" "$_u:" "$_eff")"
            done
            info "Test NOW in a second window: new ssh login as: ${SSH_ALLOW_USERS}"
            if askYesNo "New logins work – keep the sshd hardening?" "n"; then
                _run_root systemctl stop ihw-ssh-rollback.timer > /dev/null 2>&1 && ok "Rollback timer removed"
            else
                warn "Not confirmed – rollback timer removes the hardening within ${FW_ROLLBACK_MIN} min"
            fi
        else
            fail "sshd -t failed – hardening files removed, sshd NOT reloaded"
            _run_root rm -f "$SSHD_DROPIN" "$SSHD_MATCH"
        fi
        unset _ts _f _eff _u
    fi
    unset _want _want_match _ssh_ok
fi
unset _sshd_eff

APPLY_MODE=$APPLY_REQUESTED

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
