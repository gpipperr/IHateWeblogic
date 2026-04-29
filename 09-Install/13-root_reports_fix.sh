#!/bin/bash
# =============================================================================
# Script   : 13-root_reports_fix.sh
# Purpose  : Phase 7 – OS-level fix for Oracle Reports 14c on Oracle Linux 9
#            Creates the libnsl.so.2 symlink required by the standalone
#            Reports Server (compiled against libnsl.so.2, OL9 ships .so.3).
# Call     : sudo ./09-Install/13-root_reports_fix.sh
#            sudo ./09-Install/13-root_reports_fix.sh --apply
# Options  : --apply   Create the symlink (default: check only)
#            --help    Show usage
# Runs as  : root (or oracle with sudo)
# Ref      : Oracle Support Doc ID 3069675.1
#            09-Install/docs/13-reports-detail-settings.md  Step 1
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
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
    printf "  %-20s %s\n" "--apply"  "Create the libnsl.so.2 symlink"
    printf "  %-20s %s\n" "--help"   "Show this help"
    printf "\nRef: Oracle Support Doc ID 3069675.1\n"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY_MODE=1; shift ;;
        --help|-h)  _usage ;;
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
# Banner
# =============================================================================

printLine
section "Reports OS Fix – libnsl.so.2 – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:"        "$(hostname -f 2>/dev/null || hostname)" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "ORACLE_HOME:" "${ORACLE_HOME:-(not set)}" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Mode:" "$([ "$APPLY_MODE" -eq 1 ] && echo APPLY || echo CHECK)" \
    | tee -a "${LOG_FILE:-/dev/null}"
printLine

_check_root_access

# =============================================================================
# 1. OS Version Check
# =============================================================================

section "OS Version"

OS_RELEASE_FILE=""
for f in /etc/oracle-release /etc/redhat-release /etc/os-release; do
    [ -f "$f" ] && OS_RELEASE_FILE="$f" && break
done

OS_STRING="$(cat "$OS_RELEASE_FILE" 2>/dev/null | head -1)"
printf "  %-26s %s\n" "OS:" "$OS_STRING" | tee -a "${LOG_FILE:-/dev/null}"

OS_MAJOR="$(grep -oE 'release [0-9]+' "$OS_RELEASE_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
printf "  %-26s %s\n" "Major version:" "${OS_MAJOR:-(unknown)}" | tee -a "${LOG_FILE:-/dev/null}"

if [ "${OS_MAJOR:-0}" -ge 9 ]; then
    ok "OL9/RHEL9 detected – libnsl.so.2 fix is required"
    NEEDS_FIX=1
else
    ok "OL${OS_MAJOR:-?} detected – libnsl.so.2 fix is NOT required on this OS version"
    NEEDS_FIX=0
fi

# =============================================================================
# 2. Check ORACLE_HOME
# =============================================================================

section "ORACLE_HOME"

if [ -z "${ORACLE_HOME:-}" ]; then
    fail "ORACLE_HOME is not set in environment.conf"
    print_summary; exit 2
fi

if [ -d "$ORACLE_HOME" ]; then
    ok "ORACLE_HOME exists: $ORACLE_HOME"
else
    fail "ORACLE_HOME directory not found: $ORACLE_HOME"
    info "  Verify that Oracle FMW is installed before running this script"
    print_summary; exit 2
fi

LIBNSL_TARGET_DIR="$ORACLE_HOME/lib"
if [ -d "$LIBNSL_TARGET_DIR" ]; then
    ok "ORACLE_HOME/lib exists: $LIBNSL_TARGET_DIR"
else
    fail "ORACLE_HOME/lib not found: $LIBNSL_TARGET_DIR"
    info "  FMW installation may be incomplete"
    print_summary; exit 2
fi

# =============================================================================
# 3. libnsl.so.2 Symlink Check
# =============================================================================

section "libnsl.so.2 Symlink"

# Source library on the OS – OL9 ships libnsl.so.3.0.0
LIBNSL_SRC="/lib64/libnsl.so.3.0.0"
LIBNSL_LINK="$ORACLE_HOME/lib/libnsl.so.2"

printf "  %-26s %s\n" "Symlink target (OS):" "$LIBNSL_SRC"  | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Symlink location:"    "$LIBNSL_LINK" | tee -a "${LOG_FILE:-/dev/null}"

# Check source library exists on OS
if [ -f "$LIBNSL_SRC" ]; then
    ok "OS library exists: $LIBNSL_SRC"
else
    if [ "$NEEDS_FIX" -eq 1 ]; then
        fail "OS library not found: $LIBNSL_SRC"
        info "  Install: dnf install libnsl2"
        info "  Ref: Doc ID 3069675.1"
    else
        info "OS library not found: $LIBNSL_SRC (expected on OL8 or earlier)"
    fi
fi

# Check whether symlink already exists and is correct
if [ -L "$LIBNSL_LINK" ]; then
    CURRENT_TARGET="$(readlink "$LIBNSL_LINK" 2>/dev/null)"
    printf "  %-26s %s\n" "Existing symlink →" "$CURRENT_TARGET" | tee -a "${LOG_FILE:-/dev/null}"

    if [ "$CURRENT_TARGET" = "$LIBNSL_SRC" ]; then
        ok "libnsl.so.2 symlink is correct"
        # Verify the target is reachable
        if [ -f "$LIBNSL_LINK" ]; then
            ok "Symlink resolves correctly (target file exists)"
        else
            fail "Symlink target is broken: $CURRENT_TARGET does not exist"
        fi
    else
        warn "libnsl.so.2 symlink points to wrong target: $CURRENT_TARGET"
        info "  Expected: $LIBNSL_SRC"

        if [ "$APPLY_MODE" -eq 1 ] && [ "$NEEDS_FIX" -eq 1 ]; then
            if [ -f "$LIBNSL_SRC" ]; then
                _run_root ln -sf "$LIBNSL_SRC" "$LIBNSL_LINK"
                ok "Symlink updated: $LIBNSL_LINK → $LIBNSL_SRC"
            else
                fail "Cannot fix: source library missing ($LIBNSL_SRC)"
            fi
        fi
    fi

elif [ -f "$LIBNSL_LINK" ]; then
    # Regular file, not a symlink
    warn "libnsl.so.2 exists as a regular file (not a symlink): $LIBNSL_LINK"
    info "  This is unusual – verify it is the correct library before replacing"
    info "  File: $(file "$LIBNSL_LINK" 2>/dev/null)"

else
    # Does not exist at all
    if [ "$NEEDS_FIX" -eq 1 ]; then
        fail "libnsl.so.2 not found in ORACLE_HOME/lib – Reports Server will fail to start"
        info "  Doc ID 3069675.1: ln -s $LIBNSL_SRC $LIBNSL_LINK"

        if [ "$APPLY_MODE" -eq 1 ]; then
            if [ -f "$LIBNSL_SRC" ]; then
                _run_root ln -s "$LIBNSL_SRC" "$LIBNSL_LINK"
                ok "Symlink created: $LIBNSL_LINK → $LIBNSL_SRC"

                # Post-create verification
                if [ -L "$LIBNSL_LINK" ] && [ -f "$LIBNSL_LINK" ]; then
                    ok "Verification passed – symlink resolves correctly"
                else
                    fail "Verification failed – symlink created but target not reachable"
                    info "  Check: ls -la $LIBNSL_LINK"
                fi
            else
                fail "Cannot create symlink – source library missing: $LIBNSL_SRC"
                info "  Install: dnf install libnsl2"
            fi
        else
            info "  Re-run with --apply to create the symlink"
        fi
    else
        info "libnsl.so.2 not present (not required on this OS version)"
    fi
fi

# =============================================================================
# 4. Verification: ldd on Reports binary
# =============================================================================

section "Reports Binary ldd Check"

RWSERVER_BIN="$ORACLE_HOME/bin/rwserver"

if [ -f "$RWSERVER_BIN" ]; then
    printf "  %-26s %s\n" "Binary:" "$RWSERVER_BIN" | tee -a "${LOG_FILE:-/dev/null}"

    LDD_OUT="$(ldd "$RWSERVER_BIN" 2>&1)"
    LDD_NSL="$(printf "%s" "$LDD_OUT" | grep libnsl)"

    if [ -n "$LDD_NSL" ]; then
        printf "  libnsl entry:\n" | tee -a "${LOG_FILE:-/dev/null}"
        printf "%s" "$LDD_NSL" | while IFS= read -r _line; do
            printf "    %s\n" "$_line" | tee -a "${LOG_FILE:-/dev/null}"
        done

        if printf "%s" "$LDD_NSL" | grep -q "not found"; then
            fail "ldd reports libnsl.so.2 as NOT FOUND – Reports Server will not start"
        elif printf "%s" "$LDD_NSL" | grep -q "=>"; then
            ok "ldd resolves libnsl.so.2 correctly"
        else
            warn "ldd libnsl entry unexpected format – review manually"
        fi
    else
        info "ldd: no libnsl entry found in rwserver"
        info "  This may be normal if the binary does not link libnsl directly"
    fi
else
    info "rwserver binary not found: $RWSERVER_BIN"
    info "  Run this check after Oracle FMW installation is complete"
fi

# =============================================================================
# Summary
# =============================================================================

printLine
if [ "$APPLY_MODE" -eq 0 ]; then
    info "Re-run with --apply to create the symlink"
fi

print_summary
exit "$EXIT_CODE"
