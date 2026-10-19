#!/bin/bash
# =============================================================================
# Script   : forms_settings.sh
# Purpose  : Is the Oracle Forms configuration complete and consistent?
#            - the files the deployed Forms application really uses
#              (formsweb.cfg, default.env, instance forms1, webutil.cfg)
#            - frmweb / frmcmp_batch in $ORACLE_HOME/bin, shared libraries
#              with the LD_LIBRARY_PATH of default.env
#            - FORMS_PATH directories and module counts
#            - default.env against environment.conf and the file system
#            - formsweb.cfg config sections and what each one inherits
# Call     : ./forms_settings.sh
#            ./forms_settings.sh --cfg /path/to/formsweb.cfg
# Options  : --cfg PATH   Evaluate another formsweb.cfg (its envFile next to it)
#            --help       Show usage
# Read-only. Performance / session parameters: forms_perf_settings.sh
# Requires : awk, sed, ldd (optional)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 06-FormsDiag/README.md, 80-FMW-Architecture/forms_runtime_architecture.md
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

# shellcheck source=forms_lib.sh
source "$SCRIPT_DIR/forms_lib.sh"

_show() { printf "  %-26s %s\n" "$1" "$2" | tee -a "${LOG_FILE:-/dev/null}"; }

# =============================================================================
# Arguments
# =============================================================================

OVERRIDE_CFG=""

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-20s %s\n" "--cfg PATH" "Evaluate another formsweb.cfg"
    printf "  %-20s %s\n" "--help"     "Show this help"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cfg)     OVERRIDE_CFG="$2"; shift 2 ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

OH="${ORACLE_HOME:-${FMW_HOME:-}}"

# =============================================================================
# Banner
# =============================================================================

printLine
section "Forms Configuration – $(date '+%Y-%m-%d %H:%M:%S')"
_show "Host:"        "$(hostname -f 2>/dev/null || hostname)"
_show "ORACLE_HOME:" "${OH:-not set}"
_show "DOMAIN_HOME:" "${DOMAIN_HOME}"
printLine

# =============================================================================
# 1. Configuration files
# =============================================================================

section "Configuration Files"

if ! frm_find_files "$OVERRIDE_CFG"; then
    fail "formsweb.cfg not found (expected: \$DOMAIN_HOME/config/fmwconfig/servers/<WLS_FORMS>/applications/formsapp_*/config/)"
    print_summary
    exit "$EXIT_CODE"
fi
ok "formsweb.cfg: $FRM_CFG"
if [ -n "$FRM_ENV" ]; then
    ok "default.env:  $FRM_ENV  (envFile of [default])"
else
    fail "envFile of [default] not found in $FRM_CONFIG_DIR"
fi

FORMS_INST="$( [ -n "$FRM_ENV" ] && frm_env_get "$FRM_ENV" FORMS_INSTANCE)"
[ -z "$FORMS_INST" ] && FORMS_INST="$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/${FORMS_INSTANCE_NAME:-forms1}"
if [ -d "$FORMS_INST" ]; then
    ok "Forms instance: $FORMS_INST"
    for _f in server/webutil.cfg server/ftrace.cfg server/forms.conf; do
        if [ -f "$FORMS_INST/$_f" ]; then
            _show "  $_f:" "present"
        else
            info "  $_f not found in the instance"
        fi
    done
else
    fail "Forms instance directory not found: $FORMS_INST (FORMS_INSTANCE in default.env)"
fi

# =============================================================================
# 2. Binaries
# =============================================================================

printLine
section "Forms Binaries (\$ORACLE_HOME/bin)"

FORMS_VER="$(grep -o '<distribution status="installed" name="Oracle Forms Reports" version="[^"]*"' \
    "$OH/inventory/registry.xml" 2>/dev/null | sed 's/.*version="\([^"]*\)"/\1/' | head -1)"
_show "Forms & Reports version:" "${FORMS_VER:-(not found in inventory/registry.xml)}"
info "  patch level: ./10-Monitoring/cve_inventory.sh or opatch lspatches"

for _b in frmweb frmcmp_batch frmbld; do
    if [ -x "$OH/bin/$_b" ]; then
        ok "$(printf "%-14s %s" "$_b" "$OH/bin/$_b")"
    else
        [ "$_b" = "frmbld" ] && info "frmbld not found (Builder, optional on a server)" \
                             || fail "$_b not found in $OH/bin"
    fi
done

if [ -x "$OH/bin/frmweb" ] && command -v ldd > /dev/null 2>&1; then
    # same library path as the runtime: LD_LIBRARY_PATH of default.env
    _ldp="$( [ -n "$FRM_ENV" ] && frm_env_get "$FRM_ENV" LD_LIBRARY_PATH)"
    MISSING="$(LD_LIBRARY_PATH="${_ldp:-$OH/lib}" ldd "$OH/bin/frmweb" 2>/dev/null \
        | awk '/not found/ {print $1}' | sort -u)"
    if [ -n "$MISSING" ]; then
        fail "frmweb: shared libraries not found (LD_LIBRARY_PATH of default.env):"
        printf '%s\n' "$MISSING" | while IFS= read -r _l; do printf "    %s\n" "$_l" | tee -a "${LOG_FILE:-/dev/null}"; done
        info "  install the OS package (09-Install/02-root_os_packages.sh) or fix LD_LIBRARY_PATH in default.env"
    else
        ok "frmweb: all shared libraries resolved (LD_LIBRARY_PATH of default.env)"
    fi
fi

# =============================================================================
# 3. FORMS_PATH
# =============================================================================

printLine
section "FORMS_PATH (modules)"

FP="$( [ -n "$FRM_ENV" ] && frm_env_get "$FRM_ENV" FORMS_PATH)"
if [ -z "$FP" ]; then
    warn "FORMS_PATH not set in default.env – Forms finds modules only by full path (FRM-40010)"
else
    IFS=':' read -ra _dirs <<< "$FP"
    for _d in "${_dirs[@]}"; do
        [ -z "$_d" ] && continue
        if [ -d "$_d" ]; then
            _fmx="$(find "$_d" -maxdepth 1 -name '*.fmx' 2>/dev/null | wc -l)"
            _mmx="$(find "$_d" -maxdepth 1 -name '*.mmx' 2>/dev/null | wc -l)"
            _plx="$(find "$_d" -maxdepth 1 \( -name '*.plx' -o -name '*.pll' \) 2>/dev/null | wc -l)"
            printf "  %s\n      fmx %s, mmx %s, plx/pll %s\n" "$_d" "$_fmx" "$_mmx" "$_plx" | tee -a "${LOG_FILE:-/dev/null}"
        else
            warn "FORMS_PATH entry does not exist: $_d"
        fi
    done
    if [ -n "${FORMS_CUSTOMER_DIR:-}" ]; then
        case ":$FP:" in
            *":$FORMS_CUSTOMER_DIR:"*) ok "FORMS_CUSTOMER_DIR is in FORMS_PATH" ;;
            *) warn "FORMS_CUSTOMER_DIR ($FORMS_CUSTOMER_DIR) is not in FORMS_PATH" ;;
        esac
    fi
fi

# =============================================================================
# 4. default.env against environment.conf / file system
# =============================================================================

printLine
section "default.env – Environment of the frmweb Processes"

if [ -n "$FRM_ENV" ]; then
    E_OH="$(    frm_env_get "$FRM_ENV" ORACLE_HOME)"
    E_TNS="$(   frm_env_get "$FRM_ENV" TNS_ADMIN)"
    E_NLS="$(   frm_env_get "$FRM_ENV" NLS_LANG)"
    E_TMP="$(   frm_env_get "$FRM_ENV" TMPDIR)"
    E_PATH="$(  frm_env_get "$FRM_ENV" PATH)"
    E_TRACE="$( frm_env_get "$FRM_ENV" FORMS_TRACE_DIR)"
    _show "ORACLE_HOME:"     "${E_OH:-(not set)}"
    _show "TNS_ADMIN:"       "${E_TNS:-(not set)}"
    _show "NLS_LANG:"        "${E_NLS:-(not set – client default AMERICAN_AMERICA.US7ASCII)}"
    _show "TMPDIR:"          "${E_TMP:-(not set – /tmp)}"
    _show "FORMS_TRACE_DIR:" "${E_TRACE:-(not set – Oracle default below the domain)}"

    [ -n "$E_OH" ] && [ "$E_OH" != "$OH" ] && fail "ORACLE_HOME in default.env ($E_OH) differs from environment.conf ($OH)"
    if [ -n "$E_TNS" ]; then
        if [ -f "$E_TNS/tnsnames.ora" ]; then ok "TNS_ADMIN/tnsnames.ora present"
        else warn "No tnsnames.ora in TNS_ADMIN=$E_TNS (only EZConnect strings work)"; fi
    fi
    if [ -n "${FORMS_TMP:-}" ] && [ "$E_TMP" != "$FORMS_TMP" ]; then
        warn "TMPDIR in default.env (${E_TMP:-unset}) differs from FORMS_TMP in environment.conf ($FORMS_TMP)"
    fi
    [ -n "$E_TMP" ] && [ ! -d "$E_TMP" ] && fail "TMPDIR does not exist: $E_TMP"
    case "$E_NLS" in
        *.UTF8) info "NLS_LANG character set UTF8 (= old CESU-8) – AL32UTF8 is the full Unicode set; check against the DB" ;;
    esac
    IFS=':' read -ra _pdirs <<< "$E_PATH"
    for _d in "${_pdirs[@]}"; do
        [ -n "$_d" ] && [ ! -d "$_d" ] && warn "PATH entry in default.env does not exist: $_d"
    done
else
    info "default.env not available"
fi

# =============================================================================
# 5. formsweb.cfg sections
# =============================================================================

printLine
section "formsweb.cfg – Config Sections"

mapfile -t SECTIONS < <(frm_sections "$FRM_CFG")
_show "Sections:" "${#SECTIONS[@]}  (URL parameter config=<name>)"
printf "\n  \033[1m%-23s %-22s %-14s %-8s %s\033[0m\n" "Section" "serverURL" "form" "WebUtil" "prestartRuntimes" | tee -a "${LOG_FILE:-/dev/null}"
for _s in "${SECTIONS[@]}"; do
    _url="$( frm_cfg_get "$FRM_CFG" "$_s" serverURL)"
    _form="$(frm_cfg_get "$FRM_CFG" "$_s" form)"
    _wu="$(  frm_cfg_get "$FRM_CFG" "$_s" WebUtilArchive)"
    _pre="$( frm_cfg_get "$FRM_CFG" "$_s" prestartRuntimes)"
    _prew="$(frm_cfg_where "$FRM_CFG" "$_s" prestartRuntimes)"
    printf "  %-23s %-22s %-14s %-8s %s\n" "$_s" "${_url:--}" "${_form:--}" \
        "$( [ -n "$_wu" ] && printf 'yes' || printf '-')" \
        "$( [ "${_pre,,}" = "true" ] && printf 'true (%s)' "$( [ "$_prew" = "$_s" ] && printf 'own' || printf 'from default')" || printf '-')" \
        | tee -a "${LOG_FILE:-/dev/null}"
done
printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
info "WebUtil = WebUtilArchive set (effective). A section inherits every key it does not set from [default] – evaluation of the values: forms_perf_settings.sh"

# =============================================================================
# 6. Runtime overview
# =============================================================================

printLine
section "Runtime Overview"

WLS_FORMS_SRV="$(frm_wls_server)"
WLS_FORMS_PID="$(frm_wls_pid "$WLS_FORMS_SRV")"
if [ -z "$WLS_FORMS_PID" ]; then
    warn "$WLS_FORMS_SRV not running"
    info "  Start: ./01-Run/startStop.sh start $WLS_FORMS_SRV --apply"
else
    FRMWEB_N="$(frm_frmweb_list "$WLS_FORMS_PID" | wc -l)"
    ok "$(printf "%s running (PID %s), %s frmweb process(es)" "$WLS_FORMS_SRV" "$WLS_FORMS_PID" "$FRMWEB_N")"
    info "  per section, memory, prestart pool vs. sessions: ./06-FormsDiag/forms_perf_analyse.sh"
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
