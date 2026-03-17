#!/bin/bash
# =============================================================================
# Script   : 06-oracle_install_forms_reports.sh
# Purpose  : Silent installation of Oracle Forms & Reports 14.1.2.0.0
#            into the existing ORACLE_HOME (FMW Infrastructure must be
#            installed first: 05-oracle_install_weblogic.sh).
# Call     : ./09-Install/06-oracle_install_forms_reports.sh
#            ./09-Install/06-oracle_install_forms_reports.sh --apply
#            ./09-Install/06-oracle_install_forms_reports.sh --help
# Options  : (none)    Dry-run: show install type, paths, pre-checks
#            --apply   Run the silent Forms/Reports installer
#            --help    Show usage
# Runs as  : oracle
# Requires : ORACLE_HOME/wlserver/ (05-oracle_install_weblogic.sh done)
#            PATCH_STORAGE/fr/fmw_14.1.2.0.0_fr_linux64.bin (or ZIP)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/06-oracle_install_forms_reports.md
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
    printf "  %-12s %s\n" "(none)"   "Dry-run: show install type, paths, pre-checks"
    printf "  %-12s %s\n" "--apply"  "Run the silent Forms/Reports installer"
    printf "  %-12s %s\n" "--help"   "Show this help"
    printf "\nRuns as: oracle\n"
    printf "Requires: 05-oracle_install_weblogic.sh must have completed.\n"
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
# Map INSTALL_COMPONENTS → INSTALL_TYPE
# =============================================================================

# In 14.1.2 the installer always deploys both Forms AND Reports binaries.
# INSTALL_TYPE has two options:
#   "Forms and Reports Deployment"  – server installation (default)
#   "Standalone Forms Builder"      – developer workstation only
# The INSTALL_COMPONENTS variable (FORMS_ONLY / REPORTS_ONLY) takes effect
# later at configuration time (Configuration Wizard), not at install time.
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_AND_REPORTS|FORMS_ONLY|REPORTS_ONLY)
        INSTALL_TYPE="Forms and Reports Deployment" ;;
    STANDALONE_FORMS_BUILDER)
        INSTALL_TYPE="Standalone Forms Builder" ;;
    *)
        printf "\033[31mFATAL\033[0m: Unknown INSTALL_COMPONENTS: %s\n" \
            "$INSTALL_COMPONENTS" >&2
        printf "  Valid values: FORMS_AND_REPORTS | FORMS_ONLY | REPORTS_ONLY\n" >&2
        exit 2 ;;
esac

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – Oracle Forms & Reports 14.1.2 Installation\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host             : %s\n" "$(_get_hostname)"             | tee -a "$LOG_FILE"
printf "  Date             : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
printf "  Apply            : %s\n" "$APPLY"                        | tee -a "$LOG_FILE"
printf "  INSTALL_COMPONENTS: %s\n" "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" | tee -a "$LOG_FILE"
printf "  INSTALL_TYPE     : %s\n" "$INSTALL_TYPE"                | tee -a "$LOG_FILE"
printf "  Log              : %s\n" "$LOG_FILE"                     | tee -a "$LOG_FILE"
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

# --- ORACLE_HOME: FMW Infrastructure must already be there -------------------
[ -n "$ORACLE_HOME" ] \
    && ok "ORACLE_HOME = $ORACLE_HOME" \
    || { fail "ORACLE_HOME not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "$ORACLE_BASE" ] \
    && ok "ORACLE_BASE = $ORACLE_BASE" \
    || { fail "ORACLE_BASE not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

if [ -d "$ORACLE_HOME/wlserver" ]; then
    ok "FMW Infrastructure present: $ORACLE_HOME/wlserver"
else
    fail "FMW Infrastructure NOT found in ORACLE_HOME: $ORACLE_HOME/wlserver"
    fail "  Run first: 05-oracle_install_weblogic.sh --apply"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# --- Idempotency: skip if already installed -----------------------------------
if [ -d "$ORACLE_HOME/forms" ] && [ -d "$ORACLE_HOME/reports" ]; then
    ok "Forms & Reports already installed in ORACLE_HOME — nothing to do"
    info "  Existing: $ORACLE_HOME/forms/"
    info "  Existing: $ORACLE_HOME/reports/"
    print_summary; exit $EXIT_CODE
fi

# --- PATCH_STORAGE + installer -----------------------------------------------
[ -n "$PATCH_STORAGE" ] \
    && ok "PATCH_STORAGE = $PATCH_STORAGE" \
    || { fail "PATCH_STORAGE not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

FR_DIR="$PATCH_STORAGE/fr"
FR_BIN="$FR_DIR/${FMW_FR_FILENAME:-fmw_14.1.2.0.0_fr_linux64.bin}"
FR_ZIP="$FR_DIR/${FMW_FR_ZIP:-V1045121-01.zip}"

if [ -f "$FR_BIN" ]; then
    ok "Installer found: $FR_BIN"
    FR_SIZE="$(du -sh "$FR_BIN" 2>/dev/null | awk '{print $1}')"
    ok "$(printf "%-22s %s" "Installer size:" "$FR_SIZE")"
elif [ -f "$FR_ZIP" ]; then
    warn "Installer not yet extracted – found ZIP: $FR_ZIP"
    if $APPLY; then
        section "Extracting installer"
        info "unzip $FR_ZIP → $FR_DIR/"
        unzip -q "$FR_ZIP" -d "$FR_DIR" || {
            fail "unzip failed: $FR_ZIP"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        }
        [ -f "$FR_BIN" ] \
            && ok "Extracted: $FR_BIN" \
            || { fail "Installer not found after unzip: $FR_BIN"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
        chmod +x "$FR_BIN"
    else
        warn "Dry-run: would extract $FR_ZIP before installing"
    fi
else
    fail "Installer not found – neither BIN nor ZIP present"
    fail "  Expected BIN: $FR_BIN"
    fail "  Expected ZIP: $FR_ZIP"
    info "  Run first: 04-oracle_pre_download.sh --apply"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# --- CV override value -------------------------------------------------------
CV_DISTID="${CV_ASSUME_DISTID:-OEL8}"
ok "$(printf "%-22s %s  (source: oracle_software_version.conf)" "CV_ASSUME_DISTID:" "$CV_DISTID")"

# --- oraInst.loc (created by WLS installer — must exist) --------------------
ORA_INST_LOC="$ORACLE_BASE/oraInst.loc"
[ -f "$ORA_INST_LOC" ] \
    && ok "oraInst.loc found: $ORA_INST_LOC" \
    || warn "oraInst.loc not found: $ORA_INST_LOC – installer will create it"

# --- Dry-run exit -------------------------------------------------------------
if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to run the installer."
    info "Would install into : $ORACLE_HOME"
    info "INSTALL_TYPE       : $INSTALL_TYPE"
    info "Using Java         : $JDK_HOME/bin/java"
    info "Installer          : $FR_BIN"
    info "CV override        : CV_ASSUME_DISTID=$CV_DISTID  (scoped to installer run only)"
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Response file
# =============================================================================

section "Response File"

RSP_FILE="$FR_DIR/fr_install.rsp"

info "Generating response file: $RSP_FILE"
cat > "$RSP_FILE" << EOF
[ENGINE]

#DO NOT CHANGE THIS.
Response File Version=1.0.0.0.0

[GENERIC]

#Set this to true if you wish to skip software updates
DECLINE_AUTO_UPDATES=true

#My Oracle Support User Name
MOS_USERNAME=

#My Oracle Support Password
MOS_PASSWORD=

#Proxy Server Name to connect to My Oracle Support
SOFTWARE_UPDATES_PROXY_SERVER=

#Proxy Server Port
SOFTWARE_UPDATES_PROXY_PORT=

#Proxy Server Username
SOFTWARE_UPDATES_PROXY_USER=

#Proxy Server Password
SOFTWARE_UPDATES_PROXY_PASSWORD=

#The oracle home location.
ORACLE_HOME=${ORACLE_HOME}

#The federated oracle home locations (leave empty for standard install)
FEDERATED_ORACLE_HOMES=

#Set this variable value to the Installation Type selected as either
#Standalone Forms Builder OR Forms and Reports Deployment
INSTALL_TYPE=${INSTALL_TYPE}

#The jdk home location.
JDK_HOME=${JDK_HOME}
EOF

[ -f "$RSP_FILE" ] \
    && ok "Response file created: $RSP_FILE" \
    || { fail "Failed to create response file: $RSP_FILE"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

printList "ORACLE_HOME"  24 "$ORACLE_HOME"
printList "INSTALL_TYPE" 24 "$INSTALL_TYPE"

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

section "Forms & Reports Silent Installation"

printList "Installer"    24 "$FR_BIN"
printList "ORACLE_HOME"  24 "$ORACLE_HOME"
printList "JDK_HOME"     24 "$JDK_HOME"
printList "oraInst.loc"  24 "$ORA_INST_LOC"
printLine

printf "\n  Installation started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
printf "  Log: %s/oraInventory/logs/\n\n" "$ORACLE_BASE" | tee -a "$LOG_FILE"

"$FR_BIN" \
    -silent \
    -responseFile "$RSP_FILE" \
    -invPtrLoc "$ORA_INST_LOC" \
    -ignoreSysPrereqs \
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
    fail "  Check: $ORACLE_BASE/oraInventory/logs/"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
ok "Installer completed successfully"

# =============================================================================
# Verification
# =============================================================================

section "Verification"

OPATCH="$ORACLE_HOME/OPatch/opatch"

# --- OPatch inventory ---------------------------------------------------------
if [ -x "$OPATCH" ]; then
    printf "\n" | tee -a "$LOG_FILE"
    info "Running: opatch lsinventory | grep -iE \"forms|reports\""
    "$OPATCH" lsinventory 2>&1 \
        | grep -iE "forms|reports|installed" \
        | tee -a "$LOG_FILE"
else
    warn "OPatch not found at: $OPATCH"
fi

# --- Key directories and binaries --------------------------------------------
_verify_dir()  { [ -d "$1" ] && ok "$(printf "%-40s exists" "$1")" || fail "$(printf "%-40s MISSING" "$1")"; }
_verify_bin()  { [ -x "$1" ] && ok "$(printf "%-40s found"  "$1")" || fail "$(printf "%-40s MISSING" "$1")"; }

case "$INSTALL_TYPE" in
    Complete|Forms)
        _verify_dir "$ORACLE_HOME/forms"
        _verify_bin "$ORACLE_HOME/forms/bin/frmcmp_batch"
        printf "\n" | tee -a "$LOG_FILE"
        info "Forms version:"
        "$ORACLE_HOME/forms/bin/frmcmp_batch" 2>&1 \
            | head -3 | tee -a "$LOG_FILE" || true
        ;;
esac

case "$INSTALL_TYPE" in
    Complete|Reports)
        _verify_dir "$ORACLE_HOME/reports"
        _verify_bin "$ORACLE_HOME/reports/bin/rwrun"
        ;;
esac

unset -f _verify_dir _verify_bin

printf "\n" | tee -a "$LOG_FILE"
info "Next step: apply Forms/Reports patches"
info "  06-oracle_patch_forms_reports.sh --apply"

# =============================================================================
print_summary
exit $EXIT_CODE
