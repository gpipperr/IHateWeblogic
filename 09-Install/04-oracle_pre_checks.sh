#!/bin/bash
# =============================================================================
# Script   : 04-oracle_pre_checks.sh
# Purpose  : Phase 1 – Pre-install prerequisite validation.
#            Verifies OS, Java, ports, disk, limits, oraInst.loc, and DB
#            connectivity before any software is downloaded or installed.
#            Read-only – no changes are made.
# Call     : ./09-Install/04-oracle_pre_checks.sh
#            ./09-Install/04-oracle_pre_checks.sh --skip-db
#            ./09-Install/04-oracle_pre_checks.sh --help
# Options  : --skip-db   Skip database connectivity check (no DB access yet)
#            --help      Show usage
# Requires : 02-Checks/os_check.sh, java_check.sh, port_check.sh,
#            db_connect_check.sh (optional with --skip-db)
# Runs as  : oracle
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/04-oracle_pre_checks.md
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

SKIP_DB=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-16s %s\n" "--skip-db" "Skip database connectivity check"
    printf "  %-16s %s\n" "--help"    "Show this help"
    printf "\nThis script is read-only – it checks and reports but makes no changes.\n"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-db) SKIP_DB=1; shift ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Configuration (from environment.conf with defaults)
# =============================================================================

ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"
ORACLE_HOME="${ORACLE_HOME:-$ORACLE_BASE/fmw}"
JDK_HOME="${JDK_HOME:-$ORACLE_BASE/java/jdk-21}"
DOMAIN_HOME="${DOMAIN_HOME:-/u01/user_projects/domains/fr_domain}"
PATCH_STORAGE="${PATCH_STORAGE:-/srv/patch_storage}"

# Minimum disk space in GB
MIN_ORACLE_HOME_GB=10
MIN_ORACLE_BASE_GB=5
MIN_PATCH_STORAGE_GB=10

# =============================================================================
# Banner
# =============================================================================

printLine
section "Pre-Install Checks – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "ORACLE_BASE:"   "$ORACLE_BASE"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "ORACLE_HOME:"   "$ORACLE_HOME"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "JDK_HOME:"      "$JDK_HOME"      | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "DOMAIN_HOME:"   "$DOMAIN_HOME"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "PATCH_STORAGE:" "$PATCH_STORAGE" | tee -a "${LOG_FILE:-/dev/null}"
[ "$SKIP_DB" -eq 1 ] && \
    printf "  %-26s %s\n" "DB check:" "SKIPPED (--skip-db)" | tee -a "${LOG_FILE:-/dev/null}"
printLine

# =============================================================================
# Helper: call a sub-script, capture its exit code, propagate FAIL
# =============================================================================

_run_check_script() {
    local script="$1"
    shift
    local label="$1"
    shift

    section "$label"

    if [ ! -x "$script" ]; then
        fail "Check script not found or not executable: $script"
        return 1
    fi

    # Run the sub-script; it prints its own output and summary.
    # We only capture the exit code to decide whether to FAIL here.
    "$script" "$@"
    local rc=$?

    if [ "$rc" -eq 0 ]; then
        ok "$(printf "%-30s exit 0 (all OK)" "$label")"
    elif [ "$rc" -eq 1 ]; then
        warn "$(printf "%-30s exit 1 (warnings present)" "$label")"
    else
        fail "$(printf "%-30s exit %s (FAIL – fix before proceeding)" "$label" "$rc")"
    fi
    return "$rc"
}

# =============================================================================
# Check 1 – OS version, kernel, RAM, disk, ulimits, packages
# =============================================================================

_run_check_script "$ROOT_DIR/02-Checks/os_check.sh" "OS Check (os_check.sh)"

# =============================================================================
# Check 2 – Oracle JDK at JDK_HOME (pre-install inline check)
# =============================================================================
# java_check.sh re-sources environment.conf and therefore always uses JAVA_HOME
# (= FMW embedded JDK, not yet installed at this phase). We check JDK_HOME
# directly instead – no delegation to java_check.sh.

section "Oracle JDK at JDK_HOME"

info "  Checking JDK_HOME=$JDK_HOME (installed by 02b-root_os_java.sh)"
info "  Note: java_check.sh is used post-install for the FMW embedded JDK."

JAVA_BIN="$JDK_HOME/bin/java"

if [ ! -e "$JDK_HOME" ]; then
    fail "JDK_HOME directory not found: $JDK_HOME"
    info "  Run: ./09-Install/02b-root_os_java.sh --apply"
elif [ ! -x "$JAVA_BIN" ]; then
    fail "java binary not found or not executable: $JAVA_BIN"
    info "  Run: ./09-Install/02b-root_os_java.sh --apply"
else
    ok "java binary found: $JAVA_BIN"

    # Version check
    JAVA_VER_LINE="$("$JAVA_BIN" -version 2>&1 | head -1)"
    ok "$(printf "%-26s %s" "java -version:" "$JAVA_VER_LINE")"

    JAVA_MAJOR="$(printf "%s" "$JAVA_VER_LINE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)"
    if [ "${JAVA_MAJOR:-0}" -eq 21 ] 2>/dev/null; then
        ok "Java major version 21 – certified for WebLogic 14.1.2"
    else
        fail "$(printf "Java major version %s – WebLogic 14.1.2 requires JDK 21" "${JAVA_MAJOR:-(unknown)}")"
    fi

    # Vendor check (Oracle JDK, not OpenJDK alone)
    JAVA_VENDOR="$("$JAVA_BIN" -version 2>&1 | grep -i vendor || "$JAVA_BIN" -XshowSettings:all -version 2>&1 | grep 'java.vendor ' | head -1)"
    if "$JAVA_BIN" -version 2>&1 | grep -qi "java(tm) se runtime\|oracle"; then
        ok "Vendor: Oracle JDK (required for WebLogic support – Doc ID 1557737.1)"
    else
        warn "Vendor not confirmed as Oracle JDK – WebLogic support requires Oracle JDK, not OpenJDK"
        info "  Oracle JDK is license-free when used exclusively with Oracle products"
        info "  See: 09-Install/docs/01-root_setup_java.md"
    fi

    # Symlink check
    if [ -L "$JDK_HOME" ]; then
        JDK_TARGET="$(readlink -f "$JDK_HOME")"
        ok "$(printf "%-26s %s → %s" "JDK_HOME symlink:" "$JDK_HOME" "$JDK_TARGET")"
    else
        info "  JDK_HOME is a direct directory (no symlink)"
    fi
fi

# =============================================================================
# Check 3 – WLS ports must be FREE before installation
# =============================================================================
# post-install: port_check.sh verifies ports are OPEN (WLS running).
# pre-install:  we need the OPPOSITE – ports must be FREE (nothing listening).
# Semantics are inverted → inline check with ss instead of delegating.

section "WLS Ports Free (pre-install)"

info "  Required ports must not be in use before installation starts."

_check_port_free() {
    local port="$1"
    local label="$2"
    if ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"; then
        fail "$(printf "Port %-5s (%s) is already in use – must be free before install" \
            "$port" "$label")"
        ss -tlnp 2>/dev/null | awk '{print $4, $6}' | grep ":${port}" | \
            while IFS= read -r line; do info "    $line"; done
    else
        ok "$(printf "Port %-5s (%s) is free" "$port" "$label")"
    fi
}

_check_port_free 7001 "AdminServer"
_check_port_free 9001 "WLS_FORMS"
_check_port_free 9002 "WLS_REPORTS"
_check_port_free 5556 "NodeManager"

# =============================================================================
# Check 4 – Database connectivity for RCU
# =============================================================================

if [ "$SKIP_DB" -eq 1 ]; then
    section "DB Connectivity Check (db_connect_check.sh)"
    info "Skipped via --skip-db"
else
    _run_check_script "$ROOT_DIR/02-Checks/db_connect_check.sh" \
        "DB Connectivity (db_connect_check.sh)"
fi

# =============================================================================
# Check 5 – Disk space
# =============================================================================

section "Disk Space"

_check_disk_gb() {
    local path="$1"
    local min_gb="$2"
    local label="$3"

    # Walk up to the first existing parent directory (path may not exist yet)
    local check_path="$path"
    while [ -n "$check_path" ] && [ ! -d "$check_path" ]; do
        check_path="$(dirname "$check_path")"
    done

    if [ -z "$check_path" ] || [ "$check_path" = "/" ]; then
        warn "$(printf "%-26s cannot determine filesystem (path not found)" "$label")"
        return 1
    fi

    local avail_gb
    avail_gb="$(df -BG "$check_path" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"

    if [ -z "$avail_gb" ]; then
        warn "$(printf "%-26s cannot read df output for %s" "$label" "$check_path")"
        return 1
    fi

    if [ "$avail_gb" -ge "$min_gb" ] 2>/dev/null; then
        ok "$(printf "%-26s %s GB available (min %s GB) on %s" \
            "$label:" "$avail_gb" "$min_gb" "$check_path")"
    else
        fail "$(printf "%-26s only %s GB available, need %s GB on %s" \
            "$label:" "$avail_gb" "$min_gb" "$check_path")"
        return 1
    fi
}

_check_disk_gb "$ORACLE_HOME"   "$MIN_ORACLE_HOME_GB"   "ORACLE_HOME"
_check_disk_gb "$ORACLE_BASE"   "$MIN_ORACLE_BASE_GB"   "ORACLE_BASE"
_check_disk_gb "$PATCH_STORAGE" "$MIN_PATCH_STORAGE_GB" "PATCH_STORAGE"

# =============================================================================
# Check 6 – oracle user limits
# =============================================================================

section "oracle User Limits"

NOFILE="$(ulimit -Hn 2>/dev/null)"
NPROC="$(ulimit -Hu 2>/dev/null)"

if [ -n "$NOFILE" ] && [ "$NOFILE" != "unlimited" ] && [ "$NOFILE" -ge 65536 ] 2>/dev/null; then
    ok "$(printf "%-26s %s (min 65536)" "nofile (hard):" "$NOFILE")"
elif [ "$NOFILE" = "unlimited" ]; then
    ok "$(printf "%-26s unlimited" "nofile (hard):")"
else
    fail "$(printf "%-26s %s (min 65536 required)" "nofile (hard):" "${NOFILE:-(unknown)}")"
    info "  Fix: run 03-root_user_oracle.sh --apply to set limits"
fi

if [ -n "$NPROC" ] && [ "$NPROC" != "unlimited" ] && [ "$NPROC" -ge 16384 ] 2>/dev/null; then
    ok "$(printf "%-26s %s (min 16384)" "nproc (hard):" "$NPROC")"
elif [ "$NPROC" = "unlimited" ]; then
    ok "$(printf "%-26s unlimited" "nproc (hard):")"
else
    fail "$(printf "%-26s %s (min 16384 required)" "nproc (hard):" "${NPROC:-(unknown)}")"
    info "  Fix: run 03-root_user_oracle.sh --apply to set limits"
fi

# =============================================================================
# Check 7 – oraInst.loc
# =============================================================================

section "Oracle Inventory (oraInst.loc)"

ORA_INST_LOC="$ORACLE_BASE/oraInst.loc"
ORA_INVENTORY="$ORACLE_BASE/oraInventory"

if [ -f "$ORA_INST_LOC" ]; then
    ok "oraInst.loc exists: $ORA_INST_LOC"
    INV_LOC="$(grep '^inventory_loc=' "$ORA_INST_LOC" 2>/dev/null | cut -d= -f2)"
    INV_GRP="$(grep '^inst_group='    "$ORA_INST_LOC" 2>/dev/null | cut -d= -f2)"
    ok "$(printf "%-26s %s" "inventory_loc:" "${INV_LOC:-(not set)}")"
    ok "$(printf "%-26s %s" "inst_group:"    "${INV_GRP:-(not set)}")"
    if [ "${INV_LOC:-}" = "$ORA_INVENTORY" ]; then
        ok "inventory_loc matches expected path"
    else
        warn "$(printf "inventory_loc='%s' expected '%s'" "${INV_LOC:-}" "$ORA_INVENTORY")"
    fi
else
    fail "oraInst.loc not found: $ORA_INST_LOC"
    info "  Fix: run 03-root_user_oracle.sh --apply to create oraInst.loc"
fi

# =============================================================================
# Check 8 – Directory ownership (oracle must own ORACLE_BASE)
# =============================================================================

section "Directory Ownership"

_check_dir_owner() {
    local dir="$1"
    local expected_owner="${2:-oracle}"

    if [ -d "$dir" ]; then
        ACTUAL="$(stat -c '%U' "$dir" 2>/dev/null)"
        if [ "$ACTUAL" = "$expected_owner" ]; then
            ok "$(printf "%-36s owner: %s" "$dir" "$ACTUAL")"
        else
            fail "$(printf "%-36s owner: %s (expected: %s)" "$dir" "$ACTUAL" "$expected_owner")"
            info "  Fix: sudo chown $expected_owner:oinstall $dir"
        fi
    else
        warn "$(printf "%-36s does not exist yet" "$dir")"
    fi
}

_check_dir_owner "$ORACLE_BASE"
_check_dir_owner "$ORACLE_HOME"
_check_dir_owner "$(dirname "$JDK_HOME")"

# =============================================================================
# Check 9 – ORACLE_HOME must be empty (no existing installation)
# =============================================================================

section "ORACLE_HOME Empty Check"

if [ ! -d "$ORACLE_HOME" ]; then
    ok "$(printf "%-36s does not exist (ready for fresh install)" "$ORACLE_HOME")"
elif [ -z "$(ls -A "$ORACLE_HOME" 2>/dev/null)" ]; then
    ok "$(printf "%-36s exists and is empty" "$ORACLE_HOME")"
else
    ENTRY_COUNT="$(ls "$ORACLE_HOME" 2>/dev/null | wc -l)"
    # Check for signs of an existing FMW installation
    if [ -f "$ORACLE_HOME/wlserver/server/bin/startWebLogic.sh" ] || \
       [ -d "$ORACLE_HOME/oracle_common" ]; then
        fail "$(printf "%-36s contains an existing FMW installation (%s entries)" \
            "$ORACLE_HOME" "$ENTRY_COUNT")"
        info "  This script is for fresh installs only."
        info "  To reinstall: deinstall existing FMW first, or use a different ORACLE_HOME."
    else
        warn "$(printf "%-36s not empty (%s entries) – verify before install" \
            "$ORACLE_HOME" "$ENTRY_COUNT")"
        info "  Partial installs or leftover files may cause OUI failures."
    fi
fi

# =============================================================================
# Summary
# =============================================================================

printLine
section "Pre-Install Readiness Summary"

printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
if [ "$CNT_FAIL" -gt 0 ]; then
    info "Fix all FAIL items before proceeding with the installation."
    info "Re-run this script after each fix to verify."
elif [ "$CNT_WARN" -gt 0 ]; then
    info "Review WARN items – some may be acceptable in your environment."
    info "Continue with: ./09-Install/04-oracle_pre_download.sh"
else
    info "All checks passed. Ready to proceed."
    info "Continue with: ./09-Install/04-oracle_pre_download.sh"
fi

print_summary
exit "$EXIT_CODE"
