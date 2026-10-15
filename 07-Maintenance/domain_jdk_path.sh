#!/bin/bash
# =============================================================================
# Script   : domain_jdk_path.sh
# Purpose  : Keep the domain and the Oracle Home on the JDK_HOME symlink
#            (e.g. /u01/app/oracle/java/jdk-21) instead of the versioned JDK
#            directory behind it (jdk-21.0.12.1).
#            WLST createDomain/updateDomain and the FMW installer resolve the
#            symlink and write the real directory into setDomainEnv.sh,
#            setNMJavaHome.sh, nodemanager.properties, the Forms instance
#            scripts, init-info/* (templates updateDomain regenerates from)
#            and oui/.globalEnv.properties (JAVA_HOME of wlst.sh/OPatch).
#            A JDK upgrade that only switches the symlink
#            (02b-root_os_java.sh --upgrade-jdk) would then not take effect.
#            Run after 08 (called there), after every updateDomain / Config
#            Wizard run and after a JDK upgrade.
# Call     : ./domain_jdk_path.sh [--apply]
# Options  : (none)   Read-only: list files that pin a versioned JDK path
#            --apply  Replace it with JDK_HOME (backup first), restart needed
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"

init_log

# =============================================================================
# Parse arguments
# =============================================================================
APPLY=false
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=true ;;
        --help)
            printf "Usage: %s [--apply]\n" "$(basename "$0")"
            printf "  Default: read-only – list domain / Oracle Home files that contain the\n"
            printf "           versioned JDK directory instead of JDK_HOME\n"
            printf "  --apply: replace it with JDK_HOME (backup to ConfigBackup/jdk_path_<ts>/)\n"
            printf "           Takes effect at the next start of NM / servers / WLST.\n"
            exit 0
            ;;
        *) printf "Unknown option: %s (see --help)\n" "$arg" >&2; exit 2 ;;
    esac
done

# =============================================================================
# Pre-checks
# =============================================================================
section "JDK_HOME"

if [ -z "${JDK_HOME:-}" ] || [ ! -x "$JDK_HOME/bin/java" ]; then
    fail "JDK_HOME not set or no bin/java: ${JDK_HOME:-<empty>}"
    print_summary; exit 2
fi
JDK_HOME="${JDK_HOME%/}"
JDK_REAL="$(readlink -f "$JDK_HOME")"

printList "JDK_HOME"    20 "$JDK_HOME"
printList "resolves to" 20 "$JDK_REAL"
printList "DOMAIN_HOME" 20 "${DOMAIN_HOME:-<not set>}"
printList "ORACLE_HOME" 20 "${ORACLE_HOME:-<not set>}"

if [ "$JDK_REAL" = "$JDK_HOME" ]; then
    warn "JDK_HOME is no symlink – a JDK upgrade always means editing all files below"
    info "  02b-root_os_java.sh installs the JDK as <dir>/jdk-21.0.x + symlink <dir>/jdk-21"
fi

# Pinned path = JDK_HOME followed by a version suffix (jdk-21 -> jdk-21.0.12.1,
# also old versions still referenced) or the current symlink target.
_esc() { printf '%s' "$1" | sed 's/[].[*^$]/\\&/g'; }
PIN_RE="$(_esc "$JDK_HOME")[._][0-9][0-9._]*[0-9]"
[ "$JDK_REAL" != "$JDK_HOME" ] && PIN_RE="${PIN_RE}|$(_esc "$JDK_REAL")"

# =============================================================================
# Find files
# =============================================================================
section "Files with a versioned JDK path"

# Domain: everything except logs, server runtime dirs and our own backups.
# Oracle Home: only oui/ (JAVA_HOME of wlst.sh, OPatch, installer) – the
# inventory clone description is history, not configuration.
_find_pinned() {
    if [ -n "${DOMAIN_HOME:-}" ] && [ -d "$DOMAIN_HOME" ]; then
        grep -rIlE "$PIN_RE" "$DOMAIN_HOME" \
            --exclude-dir=servers --exclude-dir=logs --exclude-dir=tmp \
            --exclude='*.log' --exclude='*.out' --exclude='*.bak*' \
            --exclude='nodemanager.log*' 2>/dev/null
    fi
    if [ -n "${ORACLE_HOME:-}" ] && [ -d "$ORACLE_HOME/oui" ]; then
        grep -rIlE "$PIN_RE" "$ORACLE_HOME/oui/.globalEnv.properties" "$ORACLE_HOME/oui/bin" \
            --exclude='*.bak*' 2>/dev/null
    fi
}

mapfile -t PINNED < <(_find_pinned | sort -u)

if [ "${#PINNED[@]}" -eq 0 ]; then
    ok "No file pins a versioned JDK path – all use $JDK_HOME"
    print_summary; exit "$EXIT_CODE"
fi

for _f in "${PINNED[@]}"; do
    _hit="$(grep -oE "$PIN_RE" "$_f" | sort -u | tr '\n' ' ')"
    warn "$(printf "  %-70s %s" "${_f#"${DOMAIN_HOME}/"}" "$_hit")"
done
unset _f _hit

if ! $APPLY; then
    info "Dry-run – re-run with --apply to replace the path with $JDK_HOME"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Apply
# =============================================================================
section "Replace with JDK_HOME"

BACKUP_DIR="$SCRIPT_DIR/ConfigBackup/jdk_path_$(date '+%Y%m%d_%H%M%S')"
if ! mkdir -p "$BACKUP_DIR"; then
    fail "Cannot create backup directory: $BACKUP_DIR"
    print_summary; exit 2
fi

for _f in "${PINNED[@]}"; do
    if [ ! -w "$_f" ]; then
        fail "Not writable (run as the owner of the file): $_f"
        continue
    fi
    if ! cp -p --parents "$_f" "$BACKUP_DIR/"; then
        fail "Backup failed – file not changed: $_f"
        continue
    fi
    if sed -i -E "s#${PIN_RE}#${JDK_HOME}#g" "$_f" && ! grep -qE "$PIN_RE" "$_f"; then
        ok "$(printf "  %s" "$_f")"
    else
        fail "$(printf "  replace failed: %s" "$_f")"
    fi
done
unset _f
info "Backup: $BACKUP_DIR (original paths below it)"

info "Takes effect at the next start – restart Node Manager and servers:"
info "  01-Run/startStop.sh stop-all --apply && 01-Run/startStop.sh start-all --apply"
info "  (with autostart: sudo systemctl restart fmw-$(basename "${DOMAIN_HOME:-domain}"))"

print_summary
exit "$EXIT_CODE"
