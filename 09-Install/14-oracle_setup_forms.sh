#!/bin/bash
# =============================================================================
# Script   : 14-oracle_setup_forms.sh
# Purpose  : Phase 6 – Copy Oracle Forms configuration templates to the
#            correct domain locations:
#              1. JACOB (WebUtil OLE) – install jar + DLLs from PATCH_STORAGE
#                 if FORMS_WEBUTIL_JACOB=true, sign it with FORMS_SIGN_KEYSTORE
#                 (if set), activate only when signed
#              2. webutil.cfg → FR_INST/server/ AND FR_INST_ALT/server/
#                 (Oracle's webutil.cfg + our transfer.* settings merged)
#              3. default.env → formsapp_*/config/
#              4. formsweb.cfg → formsapp_*/config/
#                 (Oracle's formsweb.cfg + our [default] overrides merged)
#              5. Registry.dat → formsapp_*/config/oracle/forms/registry/
#              6. fmrweb_utf8.res + fmrwebd.res → FR_INST/admin/resource/D/
# Call     : ./09-Install/14-oracle_setup_forms.sh
#            ./09-Install/14-oracle_setup_forms.sh --apply
# Options  : --apply   Copy templates to domain (default: check only)
#            --help    Show usage
# Requires : environment.conf with FORMS_INSTANCE_NAME + WLS_FORMS_SERVER
#            (optional FORMS_WEBUTIL_JACOB=true + 04- download of JACOB)
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
# JACOB_* (version, sizes, checksum)
# shellcheck source=oracle_software_version.conf
[ -f "$SCRIPT_DIR/oracle_software_version.conf" ] && source "$SCRIPT_DIR/oracle_software_version.conf"
# frm_cfg_set (key in one formsweb.cfg section) – shared with 06-FormsDiag
# shellcheck source=../06-FormsDiag/forms_lib.sh
source "$ROOT_DIR/06-FormsDiag/forms_lib.sh"

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

# Reports-only domain: 08 creates no WLS_FORMS / forms1 – nothing to configure
if [ "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" = "REPORTS_ONLY" ]; then
    info "INSTALL_COMPONENTS=REPORTS_ONLY – no Forms in this domain, step skipped"
    print_summary
    exit "$EXIT_CODE"
fi

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
# _render_template  src  dest
# Text templates: replace ##VAR## placeholders with environment.conf values
# (default.env had hard-coded paths of another host layout before 2026-10-15).
# Binary templates (*.res) are copied unchanged.
_render_template() {
    local src="$1" dest="$2" left
    if ! grep -qI . "$src" 2>/dev/null; then
        cp "$src" "$dest"; return
    fi
    sed -e "s|##ORACLE_HOME##|${ORACLE_HOME}|g" \
        -e "s|##DOMAIN_HOME##|${DOMAIN_HOME}|g" \
        -e "s|##JDK_HOME##|${JDK_HOME}|g" \
        -e "s|##FORMS_INSTANCE_NAME##|${FORMS_INSTANCE_NAME:-forms1}|g" \
        -e "s|##REPORTS_TOOLS_INSTANCE##|${REPORTS_TOOLS_INSTANCE:-reptools1}|g" \
        -e "s|##FORMS_CUSTOMER_DIR##|${FORMS_CUSTOMER_DIR:-${ORACLE_BASE:-/u01/app/oracle}/forms/moduls}|g" \
        -e "s|##FORMS_TMP##|${FORMS_TMP:-${ORACLE_BASE:-/u01/app/oracle}/forms/tmp}|g" \
        -e "s|##TNS_ADMIN##|${TNS_ADMIN:-$DOMAIN_HOME/config/fmwconfig}|g" \
        -e "s|##WEBUTIL_ARCHIVE##|${WEBUTIL_ARCHIVE:-frmwebutil.jar}|g" \
        "$src" > "$dest"
    left="$(grep -oE '##[A-Z_]+##' "$dest" | sort -u | xargs)"
    if [ -n "$left" ]; then
        fail "Unresolved placeholders in $(basename "$dest"): $left"
        return 1
    fi
}

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
        _render_template "$src" "$dest" || return 1
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
            _render_template "$src" "$dest2" || return 0
            ok "Synced:  $tname → $(basename "$dest2_dir")/$(basename "$dest2")"
        else
            info "  Dry-run – would also copy to secondary location"
        fi
    fi
}

# =============================================================================
# 2. JACOB – Java COM bridge for WebUtil OLE (FORMS_WEBUTIL_JACOB=true only)
#
# Only needed for CLIENT_OLE2 / Office automation. Not shipped by Oracle:
# 04-oracle_pre_download.sh puts jacob-<ver>.zip into $PATCH_STORAGE/jacob/.
# jacob.jar from the release is unsigned – Java Web Start refuses unsigned
# all-permissions jars. With FORMS_SIGN_KEYSTORE set (PKCS12, e.g. from
# 08-SSL/ssl_local_ca.sh codesign) the script signs it; jacob.jar is only
# activated (WebUtilArchive, extensions.jnlp) when it is signed.
# Background: 80-FMW-Architecture/forms_jakob_webutil.md
# =============================================================================

section "JACOB (WebUtil OLE / Office automation)"

JACOB_ACTIVE=false
WEBUTIL_ARCHIVE="frmwebutil.jar"
_JACOB_VER="${JACOB_VERSION:-1.21}"
_JACOB_JAR="$ORACLE_HOME/forms/java/jacob.jar"
_JACOB_DLL32="$ORACLE_HOME/forms/webutil/win32/jacob-${_JACOB_VER}-x86.dll"
_JACOB_DLL64="$ORACLE_HOME/forms/webutil/win64/jacob-${_JACOB_VER}-x64.dll"
_EXT_JNLP="$ORACLE_HOME/forms/java/extensions.jnlp"

_JDK_BIN="${JDK_HOME:-$ORACLE_HOME/oracle_common/jdk}/bin"

# _jacob_signed jar – 0 if jarsigner verifies the jar
_jacob_signed() {
    local js="$_JDK_BIN/jarsigner"
    [ -x "$js" ] || js="$(command -v jarsigner 2>/dev/null)"
    [ -n "$js" ] && "$js" -verify "$1" 2>/dev/null | grep -q '^jar verified'
}

# _jacob_install src dest – copy with backup if different
# A signed jacob.jar whose unsigned original (jacob.jar.orig, kept by
# _jacob_sign) equals the source is up to date – do not overwrite it
_jacob_install() {
    local src="$1" dest="$2"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        ok "$(printf "  %-22s up to date  %s" "$(basename "$dest")" "$dest")"
        return 0
    fi
    if [ -f "$dest" ] && [ -f "${dest}.orig" ] && cmp -s "$src" "${dest}.orig" \
       && _jacob_signed "$dest"; then
        ok "$(printf "  %-22s up to date (signed)  %s" "$(basename "$dest")" "$dest")"
        return 0
    fi
    if ! $APPLY; then
        info "$(printf "  %-22s dry-run – would install  %s" "$(basename "$dest")" "$dest")"
        return 0
    fi
    [ -f "$dest" ] && cp -p "$dest" "${dest}.bak_$(date +%Y%m%d_%H%M%S)"
    if cp "$src" "$dest"; then
        ok "$(printf "  %-22s installed  %s" "$(basename "$dest")" "$dest")"
    else
        fail "Copy failed: $src → $dest"
        return 1
    fi
}

# _jacob_sign jar – sign with the code-signing keystore (doc 14, Step 1.3):
# keep the unsigned original as jar.orig, add the security attributes to the
# MAIN manifest section (the release has them only under "Name: com/jacob/"),
# jarsigner with the password from forms_sign_sec.conf.des3 via a temp file,
# verify (integrity, no -strict); on failure the original is restored
_jacob_sign() {
    local jar="$1" rc
    local ks="${FORMS_SIGN_KEYSTORE}" alias="${FORMS_SIGN_ALIAS:-forms_codesign}"
    local sec="$ROOT_DIR/forms_sign_sec.conf.des3"

    if ! $APPLY; then
        info "  dry-run – would sign $jar with $ks (alias $alias)"
        return 0
    fi
    [ -f "$ks" ]  || { fail "FORMS_SIGN_KEYSTORE not found: $ks"; return 1; }
    [ -f "$sec" ] || { fail "Keystore password file missing: $sec"; return 1; }
    [ -x "$_JDK_BIN/jarsigner" ] && [ -x "$_JDK_BIN/jar" ] \
        || { fail "jar / jarsigner not found in $_JDK_BIN (JDK_HOME)"; return 1; }

    local tmp; tmp="$(mktemp -d)"; chmod 700 "$tmp"
    load_secrets_file "$sec" || { rm -rf "$tmp"; return 1; }
    if [ -z "${FORMS_SIGN_STOREPASS:-}" ]; then
        fail "FORMS_SIGN_STOREPASS not in $sec"; rm -rf "$tmp"; return 1
    fi
    ( umask 077; printf '%s\n' "$FORMS_SIGN_STOREPASS" > "$tmp/ks.pw" )
    unset FORMS_SIGN_STOREPASS

    cp -p "$jar" "${jar}.orig"
    printf 'Permissions: all-permissions\nCodebase: *\nApplication-Name: Java-Windows Bridge\n' \
        > "$tmp/manifest.add"
    "$_JDK_BIN/jar" ufm "$jar" "$tmp/manifest.add" >> "$LOG_FILE" 2>&1

    local tsa=()
    if [ -n "${FORMS_SIGN_TSA_URL:-}" ]; then
        tsa=(-tsa "$FORMS_SIGN_TSA_URL")
    else
        warn "  FORMS_SIGN_TSA_URL empty – signature without timestamp (invalid after the certificate expires)"
    fi
    "$_JDK_BIN/jarsigner" -keystore "$ks" -storetype PKCS12 -storepass:file "$tmp/ks.pw" \
        -digestalg SHA-256 "${tsa[@]}" "$jar" "$alias" >> "$LOG_FILE" 2>&1
    rc=$?
    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        fail "jarsigner failed (rc=$rc) – original restored, see $LOG_FILE"
        cp -p "${jar}.orig" "$jar"
        return 1
    fi

    # Verify the signature itself (integrity, every entry signed). No -strict:
    # with an own / company CA the server JDK's cacerts does not know the root
    # ("PKIX path building failed") – trust is decided on the client (root
    # imported there). "nonexistent signed entries: [com/jacob/]" comes from
    # the per-entry manifest section of the JACOB release and is harmless.
    local vout
    vout="$("$_JDK_BIN/jarsigner" -verify -verbose "$jar" 2>&1)"
    printf '%s\n' "$vout" | grep -vE '^ *(s|sm|m)? +[0-9]+ ' >> "$LOG_FILE"
    if ! printf '%s\n' "$vout" | grep -q '^jar verified' \
       || printf '%s\n' "$vout" | grep -q 'unsigned entries'; then
        fail "jarsigner -verify failed after signing – original restored, see $LOG_FILE"
        cp -p "${jar}.orig" "$jar"
        return 1
    fi
    ok "$(printf "  %-22s signed (alias %s%s)" "$(basename "$jar")" "$alias" \
        "$([ -n "${FORMS_SIGN_TSA_URL:-}" ] && printf ', timestamp')")"
    printf '%s\n' "$vout" | grep -m1 'Signed by' | sed 's/^[ -]*/  /' | tee -a "$LOG_FILE"
    if printf '%s\n' "$vout" | grep -q 'PKIX path building failed'; then
        info "  chain not in the server JDK cacerts (expected for an own / company CA)"
        info "  clients must trust the root – 08-SSL/README.md, section ssl_local_ca.sh"
    fi
    return 0
}

if [ "${FORMS_WEBUTIL_JACOB:-false}" != "true" ]; then
    info "FORMS_WEBUTIL_JACOB=${FORMS_WEBUTIL_JACOB:-false} – JACOB not installed"
    info "  Only needed for WebUtil OLE (CLIENT_OLE2, Word/Excel automation);"
    info "  enable: FORMS_WEBUTIL_JACOB=true in environment.conf, then 04- and 14- --apply"
    [ -f "$_JACOB_JAR" ] && info "  (jacob.jar is present anyway: $_JACOB_JAR)"
else
    _zip="$PATCH_STORAGE/jacob/${JACOB_ZIP:-jacob-${_JACOB_VER}.zip}"
    if [ ! -f "$_zip" ]; then
        fail "JACOB ZIP not found: $_zip"
        info "  Download: 09-Install/04-oracle_pre_download.sh --apply"
    elif [ -n "${JACOB_SHA256:-}" ] && \
         [ "$(sha256sum "$_zip" | cut -d' ' -f1)" != "${JACOB_SHA256,,}" ]; then
        fail "JACOB ZIP SHA-256 mismatch: $_zip – download again with 04-"
    else
        ok "JACOB ZIP: $_zip"
        _tmp="$(mktemp -d)"
        unzip -q -o "$_zip" -d "$_tmp"
        _src_jar="$(find "$_tmp" -name jacob.jar | head -1)"
        _src32="$(find "$_tmp" -name "jacob-${_JACOB_VER}-x86.dll" | head -1)"
        _src64="$(find "$_tmp" -name "jacob-${_JACOB_VER}-x64.dll" | head -1)"
        _ok=true
        for _f in "$_src_jar" "$_src32" "$_src64"; do
            [ -n "$_f" ] || { fail "ZIP incomplete – jacob.jar / jacob-${_JACOB_VER}-x86|x64.dll missing"; _ok=false; break; }
        done
        # webutil.cfg install.syslib checks name|size – the DLLs must match exactly
        if $_ok; then
            for _pair in "$_src32:${JACOB_DLL_X86_SIZE:-}" "$_src64:${JACOB_DLL_X64_SIZE:-}"; do
                _f="${_pair%%:*}"; _exp="${_pair##*:}"; _sz="$(stat -c %s "$_f")"
                if [ -n "$_exp" ] && [ "$_sz" != "$_exp" ]; then
                    fail "$(basename "$_f"): $_sz bytes, webutil.cfg expects $_exp"
                    _ok=false
                fi
            done
        fi
        if $_ok; then
            _jacob_install "$_src_jar" "$_JACOB_JAR"
            _jacob_install "$_src32"   "$_JACOB_DLL32"
            _jacob_install "$_src64"   "$_JACOB_DLL64"
        fi
        rm -rf "${_tmp:?}"
        unset _tmp _src_jar _src32 _src64 _f _pair _exp _sz _ok
    fi
    unset _zip

    # Signing (only with FORMS_SIGN_KEYSTORE) – then activation only for a signed jar
    if [ -f "$_JACOB_JAR" ] && ! _jacob_signed "$_JACOB_JAR"; then
        # FORMS_SIGN_LOCALCA=true (interview: keystore did not exist) – create it
        # with the own root CA; ssl_local_ca.sh reads 08-SSL/ssl.conf + FORMS_SIGN_*
        if [ -n "${FORMS_SIGN_KEYSTORE:-}" ] && [ ! -f "$FORMS_SIGN_KEYSTORE" ] \
           && [ "${FORMS_SIGN_LOCALCA:-false}" = "true" ]; then
            _ca_sh="$ROOT_DIR/08-SSL/ssl_local_ca.sh"
            _ca_dir="$(grep -E '^SSL_CA_DIR=' "$ROOT_DIR/08-SSL/ssl.conf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"')"
            _ca_dir="${_ca_dir:-${ORACLE_BASE}/admin/pki}"
            if ! $APPLY; then
                info "  dry-run – would create the keystore with the local CA: $FORMS_SIGN_KEYSTORE"
                [ -f "$_ca_dir/ca/ca.crt" ] || info "  dry-run – would create the root CA first: $_ca_dir"
            else
                info "Creating code-signing keystore with the local CA (08-SSL/ssl_local_ca.sh)"
                if [ ! -f "$_ca_dir/ca/ca.crt" ]; then
                    "$_ca_sh" init --apply 2>&1 | tee -a "$LOG_FILE" >/dev/null
                    [ -f "$_ca_dir/ca/ca.crt" ] && ok "Root CA created: $_ca_dir/ca/ca.crt (distribute ca.cer to the clients)" \
                                                || fail "Root CA creation failed – see $LOG_FILE"
                fi
                if [ -f "$_ca_dir/ca/ca.crt" ]; then
                    "$_ca_sh" codesign --apply 2>&1 | tee -a "$LOG_FILE" >/dev/null
                    [ -f "$FORMS_SIGN_KEYSTORE" ] && ok "Keystore created: $FORMS_SIGN_KEYSTORE" \
                                                  || fail "Keystore creation failed – see $LOG_FILE"
                fi
            fi
            unset _ca_sh _ca_dir
        fi
        if [ -n "${FORMS_SIGN_KEYSTORE:-}" ] && { [ -f "$FORMS_SIGN_KEYSTORE" ] || ! $APPLY; }; then
            _jacob_sign "$_JACOB_JAR"
        elif [ -n "${FORMS_SIGN_KEYSTORE:-}" ]; then
            fail "FORMS_SIGN_KEYSTORE not found: $FORMS_SIGN_KEYSTORE"
            info "  copy the keystore there, or create it: ./08-SSL/ssl_local_ca.sh codesign --apply"
        else
            info "FORMS_SIGN_KEYSTORE not set – jacob.jar is not signed by this script"
        fi
    fi
    if [ -f "$_JACOB_JAR" ]; then
        if _jacob_signed "$_JACOB_JAR"; then
            ok "jacob.jar is signed – activating it for the Forms client"
            JACOB_ACTIVE=true
            WEBUTIL_ARCHIVE="frmwebutil.jar,jacob.jar"
        elif ! $APPLY && [ -n "${FORMS_SIGN_KEYSTORE:-}" ]; then
            info "  dry-run – jacob.jar would be activated after signing"
        else
            warn "jacob.jar is not signed – NOT activated (WebUtilArchive / extensions.jnlp unchanged)"
            info "  Java Web Start refuses unsigned all-permissions jars. Sign it: set"
            info "  FORMS_SIGN_KEYSTORE (e.g. ./08-SSL/ssl_local_ca.sh codesign --apply) and run 14- --apply again"
        fi
    elif ! $APPLY; then
        info "  Activation is decided after the install (jacob.jar must be signed)"
    fi
fi

# extensions.jnlp: Java Web Start loads extra jars from here (webutil.jnlp /
# base.jnlp reference it); Oracle ships the jacob entry commented out
if $JACOB_ACTIVE && [ -f "$_EXT_JNLP" ]; then
    if grep -qE '^[[:space:]]*<jar href="jacob\.jar"' "$_EXT_JNLP"; then
        ok "extensions.jnlp: jacob.jar entry active"
    elif $APPLY; then
        cp -p "$_EXT_JNLP" "${_EXT_JNLP}.bak_$(date +%Y%m%d_%H%M%S)"
        sed -i 's|<!--[[:space:]]*<jar href="jacob.jar"/>[[:space:]]*-->|<jar href="jacob.jar"/>|' "$_EXT_JNLP"
        grep -qE '^[[:space:]]*<jar href="jacob\.jar"' "$_EXT_JNLP" \
            || sed -i 's|</resources>|<jar href="jacob.jar"/>\n</resources>|' "$_EXT_JNLP"
        ok "extensions.jnlp: jacob.jar entry activated ($_EXT_JNLP)"
    else
        info "extensions.jnlp: dry-run – would activate the jacob.jar entry"
    fi
fi
printList "WebUtilArchive" 22 "$WEBUTIL_ARCHIVE"
unset _JACOB_VER _JACOB_DLL32 _JACOB_DLL64

# =============================================================================
# 3. webutil.cfg – two locations
#
# Base = Oracle's own webutil.cfg ($ORACLE_HOME/forms/templates/config/), our
# template only overrides keys. Until 2026-10-15 the template replaced the
# whole file – all install.syslib.* entries were lost, WebUtil could not
# install any native library on the client (d2kwut60.dll, JNIsharedstubs.dll,
# jacob DLLs).
# =============================================================================

section "webutil.cfg (two locations)"

WEBUTIL_BASE="$ORACLE_HOME/forms/templates/config/webutil.cfg"

# _merge_webutil_cfg overlay dest – base with the keys of overlay replaced;
# numbered transfer.appsrv.read.N / write.N of the base not in the overlay are
# dropped (Oracle's c:\temp examples); new keys appended at the end
_merge_webutil_cfg() {
    local overlay="$1" dest="$2"
    awk -v ovf="$overlay" '
        BEGIN {
            n = 0
            while ((getline line < ovf) > 0) {
                if (line ~ /^[[:space:]]*#/ || line !~ /=/) continue
                k = line; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k)
                v = line; sub(/^[^=]*=/, "", v)
                if (!(k in ov)) order[++n] = k
                ov[k] = v
            }
            print "# Generated by 09-Install/14-oracle_setup_forms.sh: Oracle webutil.cfg"
            print "# + overrides from 09-Install/forms_templates/webutil.cfg.template"
        }
        /^[[:space:]]*#/ || !/=/ { print; next }
        {
            k = $0; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k)
            if (k in ov) { print k "=" ov[k]; used[k] = 1; next }
            if (k ~ /^transfer\.appsrv\.(read|write)\.[0-9]+$/) { print "# (IHW removed) " $0; next }
            print
        }
        END {
            hdr = 0
            for (i = 1; i <= n; i++) if (!(order[i] in used)) {
                if (!hdr) { print ""; print "# --- added by 14-oracle_setup_forms.sh ---"; hdr = 1 }
                print order[i] "=" ov[order[i]]
            }
        }
    ' "$WEBUTIL_BASE" > "$dest"
}

_deploy_webutil_cfg() {
    local overlay tmp dest
    if [ ! -f "$WEBUTIL_BASE" ]; then
        fail "Oracle webutil.cfg not found: $WEBUTIL_BASE"
        return 1
    fi
    overlay="$(mktemp)"
    _render_template "$TEMPLATES_DIR/webutil.cfg.template" "$overlay" || { rm -f "$overlay"; return 1; }
    # JACOB version other than Oracle's preset: syslib entries name|size|version
    if [ "${FORMS_WEBUTIL_JACOB:-false}" = "true" ] && [ -n "${JACOB_DLL_X86_SIZE:-}" ]; then
        printf 'install.syslib.0.0.7.1=jacob-%s-x86.dll|%s|%s|true\n' \
            "${JACOB_VERSION}" "${JACOB_DLL_X86_SIZE}" "${JACOB_VERSION}" >> "$overlay"
        printf 'install.syslib.0.1.7.1=jacob-%s-x64.dll|%s|%s|true\n' \
            "${JACOB_VERSION}" "${JACOB_DLL_X64_SIZE}" "${JACOB_VERSION}" >> "$overlay"
    fi
    tmp="$(mktemp)"
    _merge_webutil_cfg "$overlay" "$tmp"
    rm -f "$overlay"
    printf "  %-30s %s\n" "webutil.cfg (base)" "$WEBUTIL_BASE" | tee -a "${LOG_FILE:-/dev/null}"
    info "$(printf "  %d install.syslib entries kept from Oracle's file" "$(grep -c '^install\.syslib' "$tmp")")"
    for dest in "$FR_INST/server/webutil.cfg" "$FR_INST_ALT/server/webutil.cfg"; do
        if [ ! -d "$(dirname "$dest")" ]; then
            warn "Target directory does not exist: $(dirname "$dest")"
            continue
        fi
        if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
            ok "$(printf "  up to date: %s" "$dest")"
        elif $APPLY; then
            [ -f "$dest" ] && cp "$dest" "${dest}.bak_$(date +%Y%m%d_%H%M%S)"
            cp "$tmp" "$dest" && ok "$(printf "  written: %s" "$dest")"
        else
            info "$(printf "  dry-run – would write: %s" "$dest")"
        fi
    done
    rm -f "$tmp"
}

_deploy_webutil_cfg

# =============================================================================
# 3b. Forms directories (FORMS_CUSTOMER_DIR = modules, FORMS_TMP = TMPDIR)
# =============================================================================

section "Forms Directories"

for _d in "${FORMS_CUSTOMER_DIR:-${ORACLE_BASE:-/u01/app/oracle}/forms/moduls}" \
          "${FORMS_TMP:-${ORACLE_BASE:-/u01/app/oracle}/forms/tmp}"; do
    if [ -d "$_d" ]; then
        if [ -w "$_d" ]; then
            ok "$(printf "  exists   %s" "$_d")"
        else
            warn "$(printf "  exists, not writable for %s: %s" "$(id -un)" "$_d")"
        fi
    elif $APPLY; then
        if mkdir -p "$_d" && chmod 750 "$_d"; then
            ok "$(printf "  created  %s (750)" "$_d")"
        else
            fail "$(printf "  cannot create %s - create it as root and chown to %s" "$_d" "$(id -un)")"
        fi
    else
        info "$(printf "  dry-run - would create %s (750)" "$_d")"
    fi
done
unset _d

# =============================================================================
# 4. default.env
# =============================================================================

section "default.env"

if [ -n "$FORMS_APP_DIR" ]; then
    _copy_template \
        "$TEMPLATES_DIR/default.env.template" \
        "$FORMS_APP_DIR/config/default.env"
    # TNS_ADMIN of environment.conf (one directory for all processes, check:
    # 02-Checks/tns_admin_check.sh); fallback = Oracle's domain default
    if [ -z "${TNS_ADMIN:-}" ]; then
        warn "TNS_ADMIN not set in environment.conf – default.env uses \$DOMAIN_HOME/config/fmwconfig"
    elif [ ! -f "$TNS_ADMIN/tnsnames.ora" ]; then
        warn "No tnsnames.ora in TNS_ADMIN=$TNS_ADMIN – Forms logins work only with EZConnect (host:port/service)"
    else
        ok "TNS_ADMIN=$TNS_ADMIN (tnsnames.ora present)"
    fi
else
    warn "Skipping default.env – Forms app dir not found"
fi

# =============================================================================
# 5. formsweb.cfg
# =============================================================================

section "formsweb.cfg"

# Oracle's file is the base (serverArgs, otherparams, [webstart],
# [standaloneapp], [webutil_*] ...); the template only overrides keys in
# [default]. Until 2026-10-16 the template replaced the whole file: without
# [webstart]/[standaloneapp] config=webstart fell back to the applet page
# ("Oracle Java is required to run this application").
FORMSWEB_BASE="$ORACLE_HOME/forms/templates/config/formsweb.cfg"

# _merge_formsweb_cfg  overlay  dest
_merge_formsweb_cfg() {
    local overlay="$1" dest="$2"
    awk -v ovf="$overlay" '
        BEGIN {
            n = 0
            while ((getline line < ovf) > 0) {
                if (line ~ /^[[:space:]]*#/ || line !~ /=/) continue
                k = line; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k)
                v = line; sub(/^[^=]*=/, "", v)
                if (!(k in ov)) order[++n] = k
                ov[k] = v
            }
            print "# Generated by 09-Install/14-oracle_setup_forms.sh: Oracle formsweb.cfg"
            print "# + [default] overrides from 09-Install/forms_templates/formsweb.cfg.template"
        }
        function add_missing(   i, hdr) {
            hdr = 0
            for (i = 1; i <= n; i++) if (!(order[i] in used)) {
                if (!hdr) { print "# --- added by 14-oracle_setup_forms.sh ---"; hdr = 1 }
                print order[i] "=" ov[order[i]]; used[order[i]] = 1
            }
            if (hdr) print ""
        }
        /^\[/ {
            if (sec == "default") add_missing()
            sec = $0; gsub(/[][[:space:]]/, "", sec)
            print; next
        }
        sec == "default" && !/^[[:space:]]*#/ && /=/ {
            k = $0; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k)
            if (k in ov) { print k "=" ov[k]; used[k] = 1; next }
        }
        { print }
        END { if (sec == "default") add_missing() }
    ' "$FORMSWEB_BASE" > "$dest"
}

if [ -z "$FORMS_APP_DIR" ]; then
    warn "Skipping formsweb.cfg – Forms app dir not found"
elif [ ! -f "$FORMSWEB_BASE" ]; then
    fail "Oracle formsweb.cfg not found: $FORMSWEB_BASE"
else
    _fw_dest="$FORMS_APP_DIR/config/formsweb.cfg"
    _fw_ovl="$(mktemp)"; _fw_tmp="$(mktemp)"
    if _render_template "$TEMPLATES_DIR/formsweb.cfg.template" "$_fw_ovl"; then
        _merge_formsweb_cfg "$_fw_ovl" "$_fw_tmp"
        # Runtime pooling only in FORMS_PRESTART_SECTION – Oracle: never in
        # [default] (all sections inherit it; 2026-10-19: 50 idle frmweb)
        if [ -n "${FORMS_PRESTART_SECTION:-}" ]; then
            if grep -q "^\[${FORMS_PRESTART_SECTION}\]" "$_fw_tmp"; then
                frm_cfg_set "$_fw_tmp" "$FORMS_PRESTART_SECTION" prestartRuntimes  true
                frm_cfg_set "$_fw_tmp" "$FORMS_PRESTART_SECTION" prestartInit      "${FORMS_PRESTART_INIT:-5}"
                frm_cfg_set "$_fw_tmp" "$FORMS_PRESTART_SECTION" prestartMin       "${FORMS_PRESTART_MIN:-4}"
                frm_cfg_set "$_fw_tmp" "$FORMS_PRESTART_SECTION" prestartIncrement "${FORMS_PRESTART_INCREMENT:-1}"
                info "$(printf "  runtime pooling: [%s] prestartInit=%s prestartMin=%s" "$FORMS_PRESTART_SECTION" "${FORMS_PRESTART_INIT:-5}" "${FORMS_PRESTART_MIN:-4}")"
            else
                warn "FORMS_PRESTART_SECTION=$FORMS_PRESTART_SECTION is not a section of formsweb.cfg – no runtime pooling"
            fi
        else
            info "  runtime pooling off (FORMS_PRESTART_SECTION empty)"
        fi
        printf "  %-30s %s\n" "formsweb.cfg (base)" "$FORMSWEB_BASE" | tee -a "${LOG_FILE:-/dev/null}"
        info "$(printf "  sections kept from Oracle's file: %s" "$(grep -o '^\[[^]]*\]' "$_fw_tmp" | tr -d '[]' | xargs)")"
        if [ -f "$_fw_dest" ] && cmp -s "$_fw_tmp" "$_fw_dest"; then
            ok "$(printf "  up to date: %s" "$_fw_dest")"
        elif $APPLY; then
            [ -f "$_fw_dest" ] && cp "$_fw_dest" "${_fw_dest}.bak_$(date +%Y%m%d_%H%M%S)"
            cp "$_fw_tmp" "$_fw_dest" && chmod 640 "$_fw_dest" \
                && ok "$(printf "  written: %s (restart WLS_FORMS)" "$_fw_dest")"
        else
            info "$(printf "  dry-run – would write: %s" "$_fw_dest")"
        fi
    fi
    rm -f "$_fw_ovl" "$_fw_tmp"
    unset _fw_dest _fw_ovl _fw_tmp
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

# webutil.cfg must keep Oracle's syslib list (native client libraries)
if [ -f "$FR_INST/server/webutil.cfg" ]; then
    grep -q '^install\.syslib\.0\.1\.9\.2=' "$FR_INST/server/webutil.cfg" \
        && ok "  webutil.cfg contains the install.syslib entries" \
        || warn "  webutil.cfg without install.syslib entries – re-run with --apply"
fi

# JACOB (only with FORMS_WEBUTIL_JACOB=true)
if [ "${FORMS_WEBUTIL_JACOB:-false}" = "true" ]; then
    [ -f "$_JACOB_JAR" ] && ok "  jacob.jar present" || warn "  jacob.jar missing"
    $JACOB_ACTIVE && ok "  jacob.jar active (WebUtilArchive + extensions.jnlp)" \
                  || warn "  jacob.jar not active (unsigned or not installed)"
fi
unset _JACOB_JAR _EXT_JNLP

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
    info "  curl -s http://localhost:${WLS_FORMS_PORT:-9001}/forms/frmservlet"
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
