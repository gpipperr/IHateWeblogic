#!/bin/bash
# =============================================================================
# Script   : 03-root_user_oracle.sh
# Purpose  : Phase 0 – Create oracle OS user, groups, limits, sudo, directories.
#            Final Phase 0 step: transfers IHateWeblogic repo ownership to oracle.
# Call     : ./09-Install/03-root_user_oracle.sh
#            ./09-Install/03-root_user_oracle.sh --apply
# Options  : --apply   Create user, configure limits, sudo, dirs, transfer ownership
#            --help    Show usage
# Requires : useradd, groupadd, visudo
# Runs as  : root or oracle with sudo
#
# Bootstrap note:
#   This script is run by root after git clone.
#   At the end (--apply), it transfers ownership of ROOT_DIR to oracle:oinstall
#   so that all subsequent scripts run under the oracle user.
#
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/03-root_user_oracle.md
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

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-16s %s\n" "--apply" "Create user, configure system, transfer ownership to oracle"
    printf "  %-16s %s\n" "--help"  "Show this help"
    printf "\nAfter this script completes, all subsequent scripts run as the oracle user.\n"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)   APPLY_MODE=1; shift ;;
        --help|-h) _usage ;;
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
        print_summary; exit 2
    fi
}

# =============================================================================
# Configuration (from environment.conf with defaults)
# =============================================================================

ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"
ORACLE_HOME="${ORACLE_HOME:-$ORACLE_BASE/fmw}"
JDK_HOME="${JDK_HOME:-$ORACLE_BASE/java/jdk-21}"
DOMAIN_HOME="${DOMAIN_HOME:-/u01/user_projects/domains/fr_domain}"
PATCH_STORAGE="${PATCH_STORAGE:-/srv/patch_storage}"

ORACLE_UID="${ORACLE_UID:-1100}"
OINSTALL_GID="${OINSTALL_GID:-1000}"

# =============================================================================
# Banner
# =============================================================================

printLine
section "Oracle User Setup – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "ORACLE_BASE:"    "$ORACLE_BASE"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "ORACLE_HOME:"    "$ORACLE_HOME"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "JDK_HOME:"       "$JDK_HOME"      | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "DOMAIN_HOME:"    "$DOMAIN_HOME"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "PATCH_STORAGE:"  "$PATCH_STORAGE" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "IHW repo root:"  "$ROOT_DIR"      | tee -a "${LOG_FILE:-/dev/null}"
[ "$APPLY_MODE" -eq 1 ] && \
    printf "  %-26s %s\n" "Mode:" "APPLY (will create user and dirs)" \
        | tee -a "${LOG_FILE:-/dev/null}"
printLine

_check_root_access

# =============================================================================
# 1. OS Groups
# =============================================================================

section "OS Groups"

_check_group() {
    local grp="$1" gid="$2"
    if getent group "$grp" > /dev/null 2>&1; then
        ACTUAL_GID="$(getent group "$grp" | cut -d: -f3)"
        ok "Group exists: $grp (gid=$ACTUAL_GID)"
    else
        warn "Group missing: $grp (expected gid=$gid)"
        if [ "$APPLY_MODE" -eq 1 ]; then
            _run_root groupadd -g "$gid" "$grp" && \
                ok "Group created: $grp (gid=$gid)" || \
                warn "groupadd $grp failed – GID $gid may be taken; groupadd will assign next free GID"
            # Retry without fixed GID if taken
            getent group "$grp" > /dev/null 2>&1 || \
                { _run_root groupadd "$grp" && ok "Group created: $grp (auto GID)"; }
        fi
    fi
}

_check_group oinstall "$OINSTALL_GID"
info "Note: dba/oper groups are Oracle Database groups – not required for WebLogic/Forms/Reports"

# =============================================================================
# 2. oracle User
# =============================================================================

section "oracle User"

if id oracle > /dev/null 2>&1; then
    ORACLE_INFO="$(id oracle)"
    ok "User 'oracle' exists: $ORACLE_INFO"

    # Check primary group
    ORACLE_GRP="$(id -gn oracle 2>/dev/null)"
    if [ "$ORACLE_GRP" = "oinstall" ]; then
        ok "Primary group: oinstall"
    else
        warn "Primary group is '$ORACLE_GRP' (expected: oinstall)"
    fi

    # Check shell
    ORACLE_SHELL="$(getent passwd oracle | cut -d: -f7)"
    if [ "$ORACLE_SHELL" = "/bin/bash" ]; then
        ok "Shell: /bin/bash"
    else
        warn "Shell: $ORACLE_SHELL (expected: /bin/bash)"
        [ "$APPLY_MODE" -eq 1 ] && _run_root usermod -s /bin/bash oracle
    fi
else
    fail "User 'oracle' does not exist"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Create oracle user (uid=$ORACLE_UID, gid=oinstall)?" "y"; then
            _run_root useradd \
                -m \
                -u "$ORACLE_UID" \
                -g oinstall \
                -s /bin/bash \
                -d /home/oracle \
                oracle
            if id oracle > /dev/null 2>&1; then
                ok "User 'oracle' created"
            else
                fail "useradd failed"
            fi
        fi
    fi
fi

# =============================================================================
# 3. Shell Resource Limits
# =============================================================================

section "Shell Resource Limits"

# Use a drop-in file in limits.d – avoids touching the system limits.conf
LIMITS_FILE="/etc/security/limits.d/oracle-fmw.conf"
LIMITS_SEARCH_DIRS="/etc/security/limits.conf /etc/security/limits.d/"

_check_limit() {
    local domain="$1" type="$2" item="$3" expected="$4"
    # Search both limits.conf and all limits.d files
    if grep -rqE "^[[:space:]]*${domain}[[:space:]]+${type}[[:space:]]+${item}[[:space:]]" \
            $LIMITS_SEARCH_DIRS 2>/dev/null; then
        ACTUAL="$(grep -rhE "^[[:space:]]*${domain}[[:space:]]+${type}[[:space:]]+${item}[[:space:]]" \
            $LIMITS_SEARCH_DIRS 2>/dev/null | awk '{print $4}' | head -1)"
        ok "limits: $domain $type $item = $ACTUAL"
    else
        warn "limits: $domain $type $item not set (expected: $expected)"
        return 1
    fi
}

LIMITS_OK=1
# Oracle WLS SYSRS minimum: soft nofile=4096, hard nofile=65536
# We set soft=hard=65536 (production practice: process starts at max, no self-raise needed)
_check_limit oracle soft nofile 65536     || LIMITS_OK=0
_check_limit oracle hard nofile 65536     || LIMITS_OK=0
# Oracle WLS SYSRS minimum: soft nproc=2047, hard nproc=16384
# We set soft=hard=16384
_check_limit oracle soft nproc  16384     || LIMITS_OK=0
_check_limit oracle hard nproc  16384     || LIMITS_OK=0
_check_limit oracle soft stack  10240     || LIMITS_OK=0
_check_limit oracle hard stack  32768     || LIMITS_OK=0
_check_limit oracle soft core   unlimited || LIMITS_OK=0
_check_limit oracle hard core   unlimited || LIMITS_OK=0
_check_limit oracle soft memlock unlimited || LIMITS_OK=0
_check_limit oracle hard memlock unlimited || LIMITS_OK=0

if [ "$LIMITS_OK" -eq 0 ] && [ "$APPLY_MODE" -eq 1 ]; then
    if askYesNo "Write oracle limits to $LIMITS_FILE?" "y"; then
        [ -f "$LIMITS_FILE" ] && backup_file "$LIMITS_FILE"
        _run_root tee "$LIMITS_FILE" > /dev/null << 'EOF'
# Oracle FMW 14.1.2 – oracle user resource limits
# Managed by: 09-Install/03-root_user_oracle.sh
# Reference : Oracle Forms & Reports 14.1.2 Installation Guide
oracle   soft   nofile     65536
oracle   hard   nofile     65536
oracle   soft   nproc      16384
oracle   hard   nproc      16384
oracle   soft   stack      10240
oracle   hard   stack      32768
oracle   soft   core       unlimited
oracle   hard   core       unlimited
oracle   soft   memlock    unlimited
oracle   hard   memlock    unlimited
EOF
        ok "Limits written to $LIMITS_FILE"
    fi
fi

# PAM check
if grep -q 'pam_limits.so' /etc/pam.d/login 2>/dev/null || \
   grep -q 'pam_limits.so' /etc/pam.d/system-auth 2>/dev/null; then
    ok "PAM: pam_limits.so configured"
else
    warn "PAM: pam_limits.so not found in /etc/pam.d/login or system-auth"
    info "  Limits may not be applied – verify /etc/pam.d/login contains:"
    info "  session required pam_limits.so"
fi

# =============================================================================
# 4. bash_profile for oracle
# =============================================================================

section "oracle .bash_profile"

ORACLE_HOME_DIR="/home/oracle"
ORACLE_PROFILE="$ORACLE_HOME_DIR/.bash_profile"

# Build expected content markers
PROFILE_MARKER="# Oracle FMW environment"

if [ -f "$ORACLE_PROFILE" ] && grep -q "$PROFILE_MARKER" "$ORACLE_PROFILE" 2>/dev/null; then
    ok ".bash_profile: Oracle FMW block already present"
    # Check key values
    grep -E "ORACLE_BASE|JAVA_HOME" "$ORACLE_PROFILE" | while IFS= read -r line; do
        info "  $line"
    done
else
    warn ".bash_profile: Oracle FMW environment block not found"
    info "  JDK_HOME will be set to: $JDK_HOME"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Add Oracle FMW environment block to $ORACLE_PROFILE?" "y"; then
            # Extract JDK version string from JDK_HOME path for the profile
            JDK_VERSION_STR="$(basename "$JDK_HOME")"
            _run_root tee -a "$ORACLE_PROFILE" > /dev/null << EOF

# Oracle FMW environment
# Managed by: 09-Install/03-root_user_oracle.sh
export ORACLE_BASE=${ORACLE_BASE}
export ORACLE_HOME=${ORACLE_HOME}
export JAVA_HOME=${JDK_HOME}
export PATH=\$JAVA_HOME/bin:\$ORACLE_HOME/OPatch:\$PATH
# Unicode locale – required for Oracle Forms/Reports Unicode support
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
# Oracle NLS setting – must match the database character set (AL32UTF8)
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
export TMP=/tmp
export TMPDIR=/tmp
umask 0022
EOF
            _run_root chown oracle:oinstall "$ORACLE_PROFILE"
            ok ".bash_profile: Oracle FMW block added"
        fi
    fi
fi

# =============================================================================
# 5. Unicode / Locale
# =============================================================================

section "Unicode / Locale"

# System locale (OL9 uses /etc/locale.conf, readable via localectl)
SYS_LANG="$(grep '^LANG=' /etc/locale.conf 2>/dev/null | cut -d= -f2 | tr -d '"')"
if printf "%s" "${SYS_LANG:-}" | grep -qi 'UTF-8'; then
    ok "System locale: $SYS_LANG"
else
    warn "System locale: '${SYS_LANG:-(not set)}' – expected en_US.UTF-8 or similar UTF-8 locale"
    info "  Set with: localectl set-locale LANG=en_US.UTF-8"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Set system locale to en_US.UTF-8?" "y"; then
            _run_root localectl set-locale LANG=en_US.UTF-8
            ok "System locale set to en_US.UTF-8"
        fi
    fi
fi

# oracle user profile – check LANG and LC_ALL
LOCALE_MARKER="Unicode locale"
if [ -f "$ORACLE_PROFILE" ] && grep -q "$LOCALE_MARKER" "$ORACLE_PROFILE" 2>/dev/null; then
    ok ".bash_profile: LANG / LC_ALL block present"
    grep -E "^export (LANG|LC_ALL)" "$ORACLE_PROFILE" | while IFS= read -r line; do
        info "  $line"
    done
else
    warn ".bash_profile: LANG / LC_ALL not set for oracle user"
    info "  Oracle Forms/Reports requires UTF-8 locale for correct Unicode handling"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Add LANG / LC_ALL to $ORACLE_PROFILE?" "y"; then
            _run_root tee -a "$ORACLE_PROFILE" > /dev/null << 'EOF'

# Unicode locale – required for Oracle Forms/Reports Unicode support
# Managed by: 09-Install/03-root_user_oracle.sh
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
EOF
            ok ".bash_profile: LANG / LC_ALL added"
        fi
    else
        info "  Add to /home/oracle/.bash_profile:"
        info "    export LANG=en_US.UTF-8"
        info "    export LC_ALL=en_US.UTF-8"
    fi
fi

# =============================================================================
# 6. sudo Configuration
# =============================================================================

section "sudo Configuration (/etc/sudoers.d/oracle-fmw)"

SUDOERS_FILE="/etc/sudoers.d/oracle-fmw"

# /etc/sudoers.d/ has mode 750 (root:root) – oracle cannot traverse it.
# All existence checks and reads require _run_root.
if _run_root test -f "$SUDOERS_FILE"; then
    ok "Sudoers file exists: $SUDOERS_FILE"
    # Validate syntax (needs root to read the 440 file)
    if _run_root visudo -c -f "$SUDOERS_FILE" > /dev/null 2>&1; then
        ok "Sudoers syntax valid"
    else
        fail "Sudoers syntax error in $SUDOERS_FILE"
        info "  Fix: visudo -f $SUDOERS_FILE"
    fi
    # Spot-check key entries (needs root to read the 440 file)
    _run_root grep -q "dnf install"  "$SUDOERS_FILE" && ok  "sudo: dnf install configured" \
                                                       || warn "sudo: dnf install not found in $SUDOERS_FILE"
    _run_root grep -q "nginx"        "$SUDOERS_FILE" && ok  "sudo: nginx configured" \
                                                       || warn "sudo: nginx not found in $SUDOERS_FILE"
    _run_root grep -q "fc-cache"     "$SUDOERS_FILE" && ok  "sudo: fc-cache configured" \
                                                       || warn "sudo: fc-cache not found in $SUDOERS_FILE"
else
    warn "Sudoers file not found: $SUDOERS_FILE"
    info "  oracle needs sudo for: dnf, sysctl, nginx, firewall-cmd, fc-cache"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Create $SUDOERS_FILE?" "y"; then
            _run_root tee "$SUDOERS_FILE" > /dev/null << 'EOF'
# Oracle FMW 14.1.2 – oracle user sudo rights
# Managed by: 09-Install/03-root_user_oracle.sh

# Package management
oracle ALL=(root) NOPASSWD: /usr/bin/dnf install *
oracle ALL=(root) NOPASSWD: /usr/bin/dnf update *

# Kernel parameters
oracle ALL=(root) NOPASSWD: /usr/sbin/sysctl -p *
oracle ALL=(root) NOPASSWD: /usr/sbin/sysctl --system

# Nginx management
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
EOF
            _run_root chmod 440 "$SUDOERS_FILE"
            if _run_root visudo -c -f "$SUDOERS_FILE" > /dev/null 2>&1; then
                ok "Sudoers file created and validated"
            else
                fail "Sudoers syntax error – please review $SUDOERS_FILE"
            fi
        fi
    fi
fi

# =============================================================================
# 7. Directory Structure
# =============================================================================

section "Directory Structure"

_check_dir() {
    local dir="$1" owner="${2:-oracle}" group="${3:-oinstall}"
    if [ -d "$dir" ]; then
        ACTUAL_OWNER="$(stat -c '%U' "$dir" 2>/dev/null)"
        ACTUAL_GROUP="$(stat -c '%G' "$dir" 2>/dev/null)"
        if [ "$ACTUAL_OWNER" = "$owner" ] && [ "$ACTUAL_GROUP" = "$group" ]; then
            ok "Directory OK: $dir (owner: $owner:$group)"
        else
            warn "Directory $dir exists but owner is $ACTUAL_OWNER:$ACTUAL_GROUP (expected $owner:$group)"
            if [ "$APPLY_MODE" -eq 1 ]; then
                _run_root chown "$owner:$group" "$dir"
                ok "Ownership fixed: $dir → $owner:$group"
            fi
        fi
    else
        warn "Directory missing: $dir"
        if [ "$APPLY_MODE" -eq 1 ]; then
            _run_root mkdir -p "$dir"
            _run_root chown "$owner:$group" "$dir"
            _run_root chmod 755 "$dir"
            ok "Created: $dir"
        fi
    fi
}

# Create and verify directory tree
_check_dir "$ORACLE_BASE"
_check_dir "$(dirname "$ORACLE_HOME")"     oracle oinstall
_check_dir "$ORACLE_HOME"
_check_dir "$(dirname "$JDK_HOME")"        oracle oinstall
_check_dir "$(dirname "$DOMAIN_HOME")"     oracle oinstall
_check_dir "$(dirname "$(dirname "$DOMAIN_HOME")")"  oracle oinstall
_check_dir "$PATCH_STORAGE"                oracle oinstall
_check_dir "$PATCH_STORAGE/bin"            oracle oinstall
_check_dir "/var/crash"                    root   root

# OUI Central Inventory – one level above ORACLE_BASE
# ORACLE_INVENTORY is set in environment.conf by 01-setup-interview.sh
ORA_INVENTORY="${ORACLE_INVENTORY:-$(dirname "$ORACLE_BASE")/oraInventory}"
if [ "${ORACLE_INVENTORY:-}" != "$ORA_INVENTORY" ]; then
    warn "ORACLE_INVENTORY not set in environment.conf – using derived default: $ORA_INVENTORY"
fi
_check_dir "$ORA_INVENTORY"

# /etc/oraInst.loc – system-wide Oracle inventory pointer (root-owned)
# Oracle installers (OUI, OPatch, runInstaller) check /etc/oraInst.loc first.
# Do NOT place oraInst.loc inside ORACLE_BASE — it must survive ORACLE_BASE recreation.
ORA_INST_LOC="/etc/oraInst.loc"
if [ -f "$ORA_INST_LOC" ]; then
    ok "oraInst.loc exists: $ORA_INST_LOC"
    _inv_in_file="$(grep '^inventory_loc=' "$ORA_INST_LOC" 2>/dev/null | cut -d= -f2)"
    if [ "$_inv_in_file" = "$ORA_INVENTORY" ]; then
        ok "oraInst.loc: inventory_loc = $ORA_INVENTORY"
    else
        warn "oraInst.loc: inventory_loc='${_inv_in_file}' expected '${ORA_INVENTORY}'"
        if [ "$APPLY_MODE" -eq 1 ]; then
            if askYesNo "Update /etc/oraInst.loc to point to $ORA_INVENTORY?" "y"; then
                _run_root tee "$ORA_INST_LOC" > /dev/null << EOF
inventory_loc=${ORA_INVENTORY}
inst_group=oinstall
EOF
                ok "Updated: $ORA_INST_LOC"
            fi
        fi
    fi
    unset _inv_in_file
else
    info "oraInst.loc not found: $ORA_INST_LOC"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Create /etc/oraInst.loc?" "y"; then
            _run_root tee "$ORA_INST_LOC" > /dev/null << EOF
inventory_loc=${ORA_INVENTORY}
inst_group=oinstall
EOF
            ok "Created: $ORA_INST_LOC"
        fi
    else
        info "  Will create /etc/oraInst.loc pointing to $ORA_INVENTORY"
    fi
fi

# Mount point advisory
MOUNT_CHECK="$(df -h "$ORACLE_BASE" 2>/dev/null | awk 'NR==2 {print $6}')"
if [ "$MOUNT_CHECK" = "/" ]; then
    warn "$ORACLE_BASE is on the root filesystem (recommended: dedicated mount point)"
    info "  Production: create separate LVM volume for /u01"
else
    ok "$ORACLE_BASE is on a dedicated filesystem: $MOUNT_CHECK"
fi

# =============================================================================
# 8. Transfer IHateWeblogic repo ownership to oracle  (Bootstrap handover)
# =============================================================================

section "IHateWeblogic Repo Ownership (Bootstrap Handover)"

IHW_OWNER="$(stat -c '%U' "$ROOT_DIR" 2>/dev/null)"
IHW_GROUP="$(stat -c '%G' "$ROOT_DIR" 2>/dev/null)"

printf "  %-26s %s\n" "IHW repo path:"  "$ROOT_DIR"           | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Current owner:"  "$IHW_OWNER:$IHW_GROUP" | tee -a "${LOG_FILE:-/dev/null}"

if [ "$IHW_OWNER" = "oracle" ] && [ "$IHW_GROUP" = "oinstall" ]; then
    ok "Repo already owned by oracle:oinstall"
else
    warn "Repo currently owned by $IHW_OWNER:$IHW_GROUP"
    info "  After this step the oracle user takes ownership of all IHW scripts and configs"
    info "  All subsequent install scripts (04+) run as oracle"

    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Transfer $ROOT_DIR ownership to oracle:oinstall now?" "y"; then
            _run_root chown -R oracle:oinstall "$ROOT_DIR"
            _run_root chmod -R u+rwX,go+rX-w "$ROOT_DIR"
            # Ensure scripts remain executable
            _run_root find "$ROOT_DIR" -name "*.sh" -exec chmod u+x {} \;
            ok "Ownership transferred: $ROOT_DIR → oracle:oinstall"
            info ""
            info "  *** PHASE 0 COMPLETE ***"
            info "  From this point on, switch to the oracle user:"
            info "    su - oracle"
            info "  Then continue with:"
            info "    cd $ROOT_DIR"
            info "    ./09-Install/04-oracle_pre_checks.sh"
        fi
    else
        info "Run with --apply to transfer repo ownership to oracle"
    fi
fi

# =============================================================================
# Final verification as cross-check
# =============================================================================

section "Final Verification"

# Verify oracle can read the lib
if id oracle > /dev/null 2>&1; then
    if _run_root su - oracle -c "test -r '$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh'" 2>/dev/null; then
        ok "oracle user can read IHateWeblogic_lib.sh"
    else
        warn "oracle user cannot read $ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
        info "  Check permissions on $ROOT_DIR"
    fi

    # Verify ulimits take effect
    NOFILE="$(_run_root su - oracle -c 'ulimit -n' 2>/dev/null)"
    if [ -n "$NOFILE" ] && [ "$NOFILE" -ge 65536 ] 2>/dev/null; then
        ok "oracle ulimit -n (nofile): $NOFILE"
    else
        warn "oracle ulimit -n: ${NOFILE:-(unknown)} (expected: ≥ 65536)"
        info "  Limits in /etc/security/limits.conf only take effect on new logins"
        info "  Test with: su - oracle -c 'ulimit -n'"
    fi
fi

# =============================================================================
# Summary
# =============================================================================

printLine
if [ "$APPLY_MODE" -eq 1 ] && [ "$CNT_FAIL" -eq 0 ]; then
    printf "\n\033[32m  Phase 0 complete.\033[0m\n"
    printf "  Switch to oracle user and continue the installation:\n"
    printf "    su - oracle\n"
    printf "    cd %s\n" "$ROOT_DIR"
    printf "    ./09-Install/04-oracle_pre_checks.sh\n\n"
fi

print_summary
exit "$EXIT_CODE"
