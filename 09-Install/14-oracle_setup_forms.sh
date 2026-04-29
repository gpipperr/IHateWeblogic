#!/bin/bash
# =============================================================================
# Script   : 14-oracle_setup_forms.sh
# Purpose  : Phase 8 – Copy Oracle Forms configuration templates to the
#            correct domain locations:
#              1. Check jacob.jar + WebUtil DLLs (check only)
#              2. webutil.cfg → FR_INST/server/ AND FR_INST_ALT/server/
#              3. default.env → formsapp_*/config/
#              4. formsweb.cfg → formsapp_*/config/
#              5. Registry.dat → formsapp_*/config/oracle/forms/registry/
#              6. fmrweb_utf8.res + fmrwebd.res → FR_INST/admin/resource/D/
# Call     : ./09-Install/14-oracle_setup_forms.sh
#            ./09-Install/14-oracle_setup_forms.sh --apply
# Options  : --apply   Copy templates to domain (default: check only)
#            --help    Show usage
# Requires : environment.conf with FORMS_INSTANCE_NAME + WLS_FORMS_SERVER
#            09-Install/forms_templates/ templates edited by customer
#            Domain created (08-oracle_setup_domain.sh)
# Runs as  : oracle
# Ref      : 09-Install/docs/14-forms-detail-settings.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
TEMPLATES_DIR="$SCRIPT_DIR/forms_templates"

if [ ! -f "$LIB_SH" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB_SH" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB_SH"

check_env_conf "$ROOT_DIR/environment.conf" || exit 2
# shellcheck source=../environment.conf
source "$ROOT_DIR/environment.conf"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false

for _arg in "$@"; do
    case "$_arg" in
        --apply)    APPLY=true ;;
        --help|-h)
            printf "Usage: %s [--apply]\n\n" "$(basename "$0")"
            printf "  %-16s %s\n" "--apply"  "Copy templates to domain locations"
            printf "\nWithout --apply: check only, no files copied.\n"
            printf "Templates: %s/\n" "$TEMPLATES_DIR"
            exit 0 ;;
        *) warn "Unknown argument: $_arg" ;;
    esac
done
unset _arg

# =============================================================================
# Log setup
# =============================================================================

LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/forms_setup_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
{
    printf "# 14-oracle_setup_forms.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Apply   : %s\n" "$APPLY"
} > "$LOG_FILE"

# =============================================================================
# Header
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – Forms Configuration Setup\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host              : %s\n" "$(_get_hostname)"              | tee -a "$LOG_FILE"
printf "  DOMAIN_HOME       : %s\n" "${DOMAIN_HOME:-?}"             | tee -a "$LOG_FILE"
printf "  FORMS_INSTANCE    : %s\n" "${FORMS_INSTANCE_NAME:-?}"     | tee -a "$LOG_FILE"
printf "  WLS_FORMS_SERVER  : %s\n" "${WLS_FORMS_SERVER:-?}"        | tee -a "$LOG_FILE"
printf "  Templates dir     : %s\n" "$TEMPLATES_DIR"                | tee -a "$LOG_FILE"
printf "  Apply             : %s\n" "$APPLY"                        | tee -a "$LOG_FILE"
printf "  Log               : %s\n" "$LOG_FILE"                     | tee -a "$LOG_FILE"
printLine

# =============================================================================
# 1. Prerequisites
# =============================================================================

section "Prerequisites"

_prereq_fail=false

for _var in ORACLE_HOME DOMAIN_HOME FORMS_INSTANCE_NAME WLS_FORMS_SERVER; do
    if [ -z "${!_var:-}" ]; then
        fail "$_var is not set in environment.conf"
        _prereq_fail=true
    else
        ok "$(printf "  %-22s = %s" "$_var" "${!_var}")"
    fi
done
unset _var
$_prereq_fail && { print_summary; exit "$EXIT_CODE"; }
unset _prereq_fail

[ ! -d "$ORACLE_HOME" ] && { fail "ORACLE_HOME not found: $ORACLE_HOME"; print_summary; exit "$EXIT_CODE"; }
[ ! -d "$DOMAIN_HOME" ] && {
    fail "DOMAIN_HOME not found: $DOMAIN_HOME"
    info "  Run 08-oracle_setup_domain.sh first"
    print_summary; exit "$EXIT_CODE"
}
ok "ORACLE_HOME and DOMAIN_HOME exist"

# Templates directory
if [ -d "$TEMPLATES_DIR" ]; then
    ok "Templates dir: $TEMPLATES_DIR"
else
    fail "Templates directory not found: $TEMPLATES_DIR"
    info "  Expected: 09-Install/forms_templates/"
    print_summary; exit "$EXIT_CODE"
fi

# Derive path variables
_FORMS_INST_NAME="${FORMS_INSTANCE_NAME:-forms1}"
FR_INST="$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/$_FORMS_INST_NAME"
FR_INST_ALT="$DOMAIN_HOME/config/fmwconfig/components/FORMS/$_FORMS_INST_NAME"
unset _FORMS_INST_NAME

printf "  %-26s %s\n" "FR_INST:"     "$FR_INST"     | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "FR_INST_ALT:" "$FR_INST_ALT" | tee -a "${LOG_FILE:-/dev/null}"

[ -d "$FR_INST" ]     && ok "FR_INST exists"     || warn "FR_INST not found (domain not yet configured?): $FR_INST"
[ -d "$FR_INST_ALT" ] && ok "FR_INST_ALT exists" || warn "FR_INST_ALT not found: $FR_INST_ALT"

# Detect Forms application directory (version is part of name: formsapp_14.1.2.0.0)
_FORMS_APP_BASE="$DOMAIN_HOME/config/fmwconfig/servers/${WLS_FORMS_SERVER}/applications"
FORMS_APP_DIR=""
if [ -d "$_FORMS_APP_BASE" ]; then
    FORMS_APP_DIR="$(find "$_FORMS_APP_BASE" -maxdepth 1 -type d -name 'formsapp_*' 2>/dev/null \
        | sort | tail -1)"
fi
unset _FORMS_APP_BASE

if [ -n "$FORMS_APP_DIR" ]; then
    ok "Forms app dir: $FORMS_APP_DIR"
else
    warn "Forms app dir not found under $DOMAIN_HOME/config/fmwconfig/servers/$WLS_FORMS_SERVER/applications/"
    info "  Expected: formsapp_14.1.2.0.0 or formsapp_12.2.1"
    info "  Sections 3, 4, 5 will be skipped"
fi

# =============================================================================
# Helper: copy a template file with backup
# _copy_template  src_template  dest_file  [dest_file_2]
# =============================================================================

_copy_template() {
    local src="$1" dest="$2" dest2="${3:-}"
    local tname
    tname="$(basename "$src" .template)"

    if [ ! -f "$src" ]; then
        warn "Template missing: $src"
        info "  Check 09-Install/forms_templates/ and edit before running --apply"
        return 1
    fi

    # Primary destination
    printf "  %-30s %s\n" "$tname" "$dest" | tee -a "${LOG_FILE:-/dev/null}"
    if $APPLY; then
        local dest_dir
        dest_dir="$(dirname "$dest")"
        if [ ! -d "$dest_dir" ]; then
            warn "Target directory does not exist: $dest_dir"
            info "  Create directory first or verify domain configuration"
            return 1
        fi
        [ -f "$dest" ] && cp "$dest" "${dest}.bak_$(date +%Y%m%d_%H%M%S)"
        cp "$src" "$dest"
        ok "Copied: $tname → $(basename "$dest_dir")/$(basename "$dest")"
    else
        if [ -f "$dest" ]; then
            info "  Dry-run – would overwrite (backup first)"
        else
            info "  Dry-run – would create"
        fi
    fi

    # Optional second destination (two-location sync)
    if [ -n "$dest2" ]; then
        printf "  %-30s %s  (sync)\n" "" "$dest2" | tee -a "${LOG_FILE:-/dev/null}"
        if $APPLY; then
            local dest2_dir
            dest2_dir="$(dirname "$dest2")"
            if [ ! -d "$dest2_dir" ]; then
                warn "Secondary target directory does not exist: $dest2_dir"
                info "  Skipping secondary location – copy manually if needed"
                return 0
            fi
            [ -f "$dest2" ] && cp "$dest2" "${dest2}.bak_$(date +%Y%m%d_%H%M%S)"
            cp "$src" "$dest2"
            ok "Synced:  $tname → $(basename "$dest2_dir")/$(basename "$dest2")"
        else
            info "  Dry-run – would also copy to secondary location"
        fi
    fi
}

# =============================================================================
# 2. jacob.jar + WebUtil DLLs (check only)
# =============================================================================

section "jacob.jar + WebUtil DLLs (check only – manual install)"

_JACOB_JAR="$ORACLE_HOME/forms/java/jacob.jar"
_JACOB_DLL32="$(find "$ORACLE_HOME/forms/webutil/win32/" -name 'jacob-*.dll' 2>/dev/null | head -1)"
_JACOB_DLL64="$(find "$ORACLE_HOME/forms/webutil/win64/" -name 'jacob-*.dll' 2>/dev/null | head -1)"

if [ -f "$_JACOB_JAR" ]; then
    ok "jacob.jar found: $_JACOB_JAR"
else
    warn "jacob.jar not found: $_JACOB_JAR"
    info "  Manual install:"
    info "    cp <PATCH_STORAGE>/jacob-1.18-M2/jacob.jar $ORACLE_HOME/forms/java/"
fi

if [ -n "$_JACOB_DLL32" ]; then
    ok "win32 DLL found: $_JACOB_DLL32"
else
    warn "win32 jacob DLL not found in: $ORACLE_HOME/forms/webutil/win32/"
    info "  Manual install:"
    info "    cp <PATCH_STORAGE>/jacob-1.18-M2/jacob-1.18-M2-x86.dll $ORACLE_HOME/forms/webutil/win32/"
fi

if [ -n "$_JACOB_DLL64" ]; then
    ok "win64 DLL found: $_JACOB_DLL64"
else
    warn "win64 jacob DLL not found in: $ORACLE_HOME/forms/webutil/win64/"
    info "  Manual install:"
    info "    cp <PATCH_STORAGE>/jacob-1.18-M2/jacob-1.18-M2-x64.dll $ORACLE_HOME/forms/webutil/win64/"
fi
unset _JACOB_JAR _JACOB_DLL32 _JACOB_DLL64

# =============================================================================
# 3. webutil.cfg – two locations
# =============================================================================

section "webutil.cfg (two locations)"

_copy_template \
    "$TEMPLATES_DIR/webutil.cfg.template" \
    "$FR_INST/server/webutil.cfg" \
    "$FR_INST_ALT/server/webutil.cfg"

# =============================================================================
# 4. default.env
# =============================================================================

section "default.env"

if [ -n "$FORMS_APP_DIR" ]; then
    _copy_template \
        "$TEMPLATES_DIR/default.env.template" \
        "$FORMS_APP_DIR/config/default.env"
else
    warn "Skipping default.env – Forms app dir not found"
fi

# =============================================================================
# 5. formsweb.cfg
# =============================================================================

section "formsweb.cfg"

if [ -n "$FORMS_APP_DIR" ]; then
    _copy_template \
        "$TEMPLATES_DIR/formsweb.cfg.template" \
        "$FORMS_APP_DIR/config/formsweb.cfg"
else
    warn "Skipping formsweb.cfg – Forms app dir not found"
fi

# =============================================================================
# 6. Registry.dat
# =============================================================================

section "Registry.dat"

if [ -n "$FORMS_APP_DIR" ]; then
    _REG_DIR="$FORMS_APP_DIR/config/oracle/forms/registry"
    if $APPLY && [ ! -d "$_REG_DIR" ]; then
        mkdir -p "$_REG_DIR" && ok "Created registry dir: $_REG_DIR"
    fi
    _copy_template \
        "$TEMPLATES_DIR/Registry.dat.template" \
        "$_REG_DIR/Registry.dat"
    unset _REG_DIR
else
    warn "Skipping Registry.dat – Forms app dir not found"
fi

# =============================================================================
# 7. Keyboard resource files
# =============================================================================

section "Keyboard Resources (fmrweb_utf8.res + fmrwebd.res)"

_RES_DIR="$FR_INST/admin/resource/D"
printf "  %-26s %s\n" "Resource dir:" "$_RES_DIR" | tee -a "${LOG_FILE:-/dev/null}"

if [ -d "$_RES_DIR" ] || $APPLY; then
    if $APPLY && [ ! -d "$_RES_DIR" ]; then
        warn "Resource dir not found: $_RES_DIR"
        info "  Cannot copy keyboard resources – verify FR_INST path"
    else
        _copy_template \
            "$TEMPLATES_DIR/fmrweb_utf8.res.template" \
            "$_RES_DIR/fmrweb_utf8.res"
        _copy_template \
            "$TEMPLATES_DIR/fmrwebd.res.template" \
            "$_RES_DIR/fmrwebd.res"
    fi
else
    warn "Resource dir not found: $_RES_DIR"
    info "  Keyboard resources will be copied when FR_INST exists"
fi
unset _RES_DIR

# =============================================================================
# 8. Verification
# =============================================================================

section "Verification"

_check_target() {
    local label="$1" file="$2"
    if [ -f "$file" ]; then
        ok "$(printf "  %-20s %s" "$label" "$file")"
    else
        warn "$(printf "  %-20s %s  (missing)" "$label" "$file")"
    fi
}

_check_target "webutil.cfg:"    "$FR_INST/server/webutil.cfg"
_check_target "webutil(alt):"   "$FR_INST_ALT/server/webutil.cfg"

if [ -n "$FORMS_APP_DIR" ]; then
    _check_target "default.env:"   "$FORMS_APP_DIR/config/default.env"
    _check_target "formsweb.cfg:"  "$FORMS_APP_DIR/config/formsweb.cfg"
    _check_target "Registry.dat:"  "$FORMS_APP_DIR/config/oracle/forms/registry/Registry.dat"
fi

_check_target "fmrweb_utf8.res:" "$FR_INST/admin/resource/D/fmrweb_utf8.res"
_check_target "fmrwebd.res:"     "$FR_INST/admin/resource/D/fmrwebd.res"

# jacob (check only)
[ -f "$ORACLE_HOME/forms/java/jacob.jar" ] \
    && ok "  jacob.jar present" \
    || warn "  jacob.jar missing (manual install required if WebUtil file transfer is used)"

# =============================================================================
# 9. Next Steps
# =============================================================================

section "Next Steps"
if $APPLY; then
    info "Restart WLS_FORMS to pick up configuration changes:"
    info "  \$DOMAIN_HOME/bin/stopManagedWebLogic.sh $WLS_FORMS_SERVER t3://localhost:${WLS_ADMIN_PORT:-7001}"
    info "  \$DOMAIN_HOME/bin/startManagedWebLogic.sh $WLS_FORMS_SERVER t3://localhost:${WLS_ADMIN_PORT:-7001} &"
    info ""
    info "Verify Forms servlet:"
    info "  curl -s http://localhost:${WLS_FORMS_PORT:-8001}/forms/frmservlet"
else
    info "Re-run with --apply to copy templates to domain locations"
    info ""
    info "Before running --apply, edit the templates in:"
    info "  $TEMPLATES_DIR/"
    info "  See: $TEMPLATES_DIR/README.md"
fi

# =============================================================================
print_summary
exit "$EXIT_CODE"
