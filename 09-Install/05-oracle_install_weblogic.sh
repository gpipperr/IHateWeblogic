#!/bin/bash
# =============================================================================
# Script   : 05-oracle_install_weblogic.sh
# Purpose  : Silent installation of Oracle FMW Infrastructure 14.1.2.0.0
#            (WebLogic Server base layer).
#            CV_ASSUME_DISTID is exported only for the installer run and
#            unset immediately after — it is NOT set globally.
# Call     : ./09-Install/05-oracle_install_weblogic.sh
#            ./09-Install/05-oracle_install_weblogic.sh --apply
#            ./09-Install/05-oracle_install_weblogic.sh --help
# Options  : (none)    Dry-run: show paths and installer version
#            --apply   Run the silent installer
#            --help    Show usage
# Runs as  : oracle
# Requires : JDK_HOME/bin/java, PATCH_STORAGE/wls/FMW_INFRA_JAR (or ZIP)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/05-oracle_install_weblogic.md
#            09-Install/oracle_software_version.conf
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
SW_CONF="$SCRIPT_DIR/oracle_software_version.conf"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

# --- Source environment.conf --------------------------------------------------
if [ ! -f "$ENV_CONF" ]; then
    printf "\033[31mFATAL\033[0m: environment.conf not found: %s\n" "$ENV_CONF" >&2
    printf "  Run first: 00-Setup/env_check.sh --apply\n" >&2; exit 2
fi
# shellcheck source=../environment.conf
source "$ENV_CONF"

# --- Source oracle_software_version.conf --------------------------------------
if [ ! -f "$SW_CONF" ]; then
    printf "\033[31mFATAL\033[0m: oracle_software_version.conf not found: %s\n" "$SW_CONF" >&2; exit 2
fi
# shellcheck source=./oracle_software_version.conf
source "$SW_CONF"

# --- Bootstrap log ------------------------------------------------------------
DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false

_usage() {
    printf "Usage: %s [--apply] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"    "Dry-run: show paths and installer version"
    printf "  %-12s %s\n" "--apply"   "Run the silent FMW Infrastructure installer"
    printf "  %-12s %s\n" "--help"    "Show this help"
    printf "\nRuns as: oracle\n"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)   APPLY=true ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 1 ;;
    esac
done
unset _arg

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – FMW Infrastructure 14.1.2 Installation\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"              | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"  | tee -a "$LOG_FILE"
printf "  Apply       : %s\n" "$APPLY"                         | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                      | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

# --- Java ---------------------------------------------------------------------
[ -n "$JDK_HOME" ] \
    && ok "JDK_HOME = $JDK_HOME" \
    || { fail "JDK_HOME not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -x "$JDK_HOME/bin/java" ] \
    && ok "java found: $JDK_HOME/bin/java" \
    || { fail "java not executable: $JDK_HOME/bin/java"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

JAVA_VERSION="$("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
ok "java version: $JAVA_VERSION"

# --- ORACLE_HOME target -------------------------------------------------------
[ -n "$ORACLE_HOME" ] \
    && ok "ORACLE_HOME = $ORACLE_HOME" \
    || { fail "ORACLE_HOME not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "$ORACLE_BASE" ] \
    && ok "ORACLE_BASE = $ORACLE_BASE" \
    || { fail "ORACLE_BASE not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

if [ -d "$ORACLE_HOME" ] && [ "$(ls -A "$ORACLE_HOME" 2>/dev/null)" ]; then
    fail "ORACLE_HOME already exists and is not empty: $ORACLE_HOME"
    fail "  To re-install: remove the directory first or choose a different ORACLE_HOME"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
else
    ok "ORACLE_HOME target is free: $ORACLE_HOME"
fi

# --- PATCH_STORAGE + installer JAR -------------------------------------------
[ -n "$PATCH_STORAGE" ] \
    && ok "PATCH_STORAGE = $PATCH_STORAGE" \
    || { fail "PATCH_STORAGE not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

WLS_DIR="$PATCH_STORAGE/wls"
WLS_JAR="$WLS_DIR/${FMW_INFRA_FILENAME:-fmw_14.1.2.0.0_infrastructure.jar}"
WLS_ZIP="$WLS_DIR/${FMW_INFRA_ZIP:-V1045135-01.zip}"

if [ -f "$WLS_JAR" ]; then
    ok "Installer JAR found: $WLS_JAR"
    JAR_SIZE="$(du -sh "$WLS_JAR" 2>/dev/null | awk '{print $1}')"
    ok "$(printf "%-20s %s" "JAR size:" "$JAR_SIZE")"
elif [ -f "$WLS_ZIP" ]; then
    warn "JAR not yet extracted – found ZIP: $WLS_ZIP"
    if $APPLY; then
        section "Extracting installer JAR"
        info "unzip $WLS_ZIP → $WLS_DIR/"
        unzip -q "$WLS_ZIP" -d "$WLS_DIR" || {
            fail "unzip failed: $WLS_ZIP"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        }
        [ -f "$WLS_JAR" ] \
            && ok "Extracted: $WLS_JAR" \
            || { fail "JAR not found after unzip: $WLS_JAR"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    else
        warn "Dry-run: would extract $WLS_ZIP before installing"
    fi
else
    fail "Installer not found – neither JAR nor ZIP present"
    fail "  Expected JAR: $WLS_JAR"
    fail "  Expected ZIP: $WLS_ZIP"
    info "  Run first: 04-oracle_pre_download.sh --apply"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# --- CV override value --------------------------------------------------------
CV_DISTID="${CV_ASSUME_DISTID:-OEL8}"
ok "$(printf "%-20s %s  (source: oracle_software_version.conf)" "CV_ASSUME_DISTID:" "$CV_DISTID")"

# --- Dry-run exit -------------------------------------------------------------
if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to run the installer."
    info "Would install to: $ORACLE_HOME"
    info "Using Java      : $JDK_HOME/bin/java"
    info "Installer JAR   : $WLS_JAR"
    info "CV override     : CV_ASSUME_DISTID=$CV_DISTID  (scoped to installer run only)"
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# oraInst.loc
# =============================================================================

section "Oracle Inventory Location"

# /etc/oraInst.loc is the system-wide inventory pointer, created by root in
# 03-root_user_oracle.sh.  This script (running as oracle) only reads it.
ORA_INST_LOC="/etc/oraInst.loc"
ORA_INVENTORY="${ORACLE_INVENTORY:-$(dirname "$ORACLE_BASE")/oraInventory}"

if [ -f "$ORA_INST_LOC" ]; then
    ok "oraInst.loc exists: $ORA_INST_LOC"
    printList "Content" 20 "$(tr '\n' ' ' < "$ORA_INST_LOC")"
    _inv_in_file="$(grep '^inventory_loc=' "$ORA_INST_LOC" 2>/dev/null | cut -d= -f2)"
    if [ "${_inv_in_file:-}" != "$ORA_INVENTORY" ]; then
        warn "inventory_loc='${_inv_in_file}' expected '${ORA_INVENTORY}'"
        warn "  Check ORACLE_INVENTORY in environment.conf and re-run 03-root_user_oracle.sh"
    fi
    unset _inv_in_file
else
    fail "oraInst.loc not found: $ORA_INST_LOC"
    fail "  Fix: run 03-root_user_oracle.sh --apply (requires root/sudo)"
    fail "  oraInst.loc must be created by root before oracle can install software"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# =============================================================================
# Response file
# =============================================================================

section "Response File"

RSP_FILE="$WLS_DIR/wls_install.rsp"

info "Generating response file: $RSP_FILE"
cat > "$RSP_FILE" << EOF
[ENGINE]
Response File Version=1.0.0.0.0

[GENERIC]
ORACLE_HOME=${ORACLE_HOME}
INSTALL_TYPE=Fusion Middleware Infrastructure
MYORACLESUPPORT_USERNAME=
MYORACLESUPPORT_PASSWORD=
DECLINE_SECURITY_UPDATES=true
SECURITY_UPDATES_VIA_MYORACLESUPPORT=false
PROXY_HOST=
PROXY_PORT=
PROXY_USER=
PROXY_PWD=
COLLECTOR_SUPPORTHUB_URL=
EOF

[ -f "$RSP_FILE" ] \
    && ok "Response file created: $RSP_FILE" \
    || { fail "Failed to create response file: $RSP_FILE"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

printList "ORACLE_HOME"   24 "$ORACLE_HOME"
printList "INSTALL_TYPE"  24 "Fusion Middleware Infrastructure"

# =============================================================================
# CV Override – scoped to installer run only
# =============================================================================

section "CV Override (OL9 compatibility)"

info "Exporting CV_ASSUME_DISTID=$CV_DISTID for installer run"
info "  → tells Oracle CV checker to treat this system as OEL8"
info "  → will be unset immediately after installer exits"
export CV_ASSUME_DISTID="$CV_DISTID"

# =============================================================================
# Run the installer
# =============================================================================

section "FMW Infrastructure Silent Installation"

printList "Installer" 24 "$WLS_JAR"
printList "ORACLE_HOME" 24 "$ORACLE_HOME"
printList "JDK_HOME"   24 "$JDK_HOME"
printList "oraInst.loc" 24 "$ORA_INST_LOC"
printLine

printf "\n  Installation started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
printf "  Log: %s/logs/\n\n" "$ORA_INVENTORY" | tee -a "$LOG_FILE"

"$JDK_HOME/bin/java" -jar "$WLS_JAR" \
    -silent \
    -responseFile "$RSP_FILE" \
    -invPtrLoc "$ORA_INST_LOC" \
    -jreLoc "$JDK_HOME" \
    2>&1 | tee -a "$LOG_FILE"

INSTALLER_RC=${PIPESTATUS[0]}

printf "\n  Installation finished: %s  (rc=%s)\n" \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$INSTALLER_RC" | tee -a "$LOG_FILE"

# --- Unset CV override immediately -------------------------------------------
unset CV_ASSUME_DISTID
info "CV_ASSUME_DISTID unset"

# --- Cleanup response file ---------------------------------------------------
rm -f "$RSP_FILE"
info "Response file removed"

# --- Installer exit code check -----------------------------------------------
if [ "$INSTALLER_RC" -ne 0 ]; then
    fail "Installer exited with rc=$INSTALLER_RC"
    fail "  Check: $ORA_INVENTORY/logs/"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
ok "Installer completed successfully"

# =============================================================================
# Verification
# =============================================================================

section "Verification"

OPATCH="$ORACLE_HOME/OPatch/opatch"

if [ -x "$OPATCH" ]; then
    ok "OPatch found: $OPATCH"
    OPATCH_VER="$("$OPATCH" version 2>/dev/null | grep 'OPatch Version' | awk '{print $NF}')"
    printList "OPatch version" 24 "$OPATCH_VER"

    printf "\n" | tee -a "$LOG_FILE"
    info "Running: opatch lsinventory"
    "$OPATCH" lsinventory 2>&1 | tee -a "$LOG_FILE"
    OPATCH_RC=${PIPESTATUS[0]}

    [ "$OPATCH_RC" -eq 0 ] \
        && ok "opatch lsinventory successful" \
        || warn "opatch lsinventory returned rc=$OPATCH_RC"
else
    warn "OPatch not found at: $OPATCH"
    warn "  Verify installation manually: ls $ORACLE_HOME/wlserver/"
fi

# Key directories
for _dir in \
    "$ORACLE_HOME/wlserver" \
    "$ORACLE_HOME/oracle_common" \
    "$ORACLE_HOME/OPatch"; do
    [ -d "$_dir" ] \
        && ok "$(printf "%-30s exists" "$_dir")" \
        || fail "$(printf "%-30s MISSING" "$_dir")"
done
unset _dir

printf "\n" | tee -a "$LOG_FILE"
info "Next step: update OPatch + apply WLS patches"
info "  05-oracle_patch_weblogic.sh --apply   (OPatch upgrade + INSTALL_PATCHES)"

# =============================================================================
print_summary
exit $EXIT_CODE
