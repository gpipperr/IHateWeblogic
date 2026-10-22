#!/bin/bash
# =============================================================================
# Script   : 40-oracle_forms_client_bundle.sh
# Purpose  : Build the Forms client bundle that Nginx serves under
#            FORMS_CLIENT_URL_PATH from FORMS_CLIENT_DIR (concept
#            docs/40-forms_client_distribution.md):
#              - Windows Java runtime: jlink from the jmods of the client JDK
#                (MOS patch, platform CLIENT_JDK_PLATFORM, downloaded by
#                04-oracle_pre_download.sh into client/jdk/<nr>/) or the full JDK
#              - CA of the Nginx TLS certificate inside the runtime's cacerts
#              - frmsal.jar of THIS Forms server, JACOB x64 DLL
#              - manifest.json (versions, sizes, SHA-256, start parameters)
#            Files carry their version in the name; the new manifest.json is
#            moved into place last (atomic switch), the previous one stays as
#            manifest.prev.json (rollback).
# Call     : ./09-Install/40-oracle_forms_client_bundle.sh
#            ./09-Install/40-oracle_forms_client_bundle.sh --apply [--force]
#            ./09-Install/40-oracle_forms_client_bundle.sh --apply --rollback
# Options  : (none)      Read-only: sources, current bundle, planned actions
#            --apply     Build when a source changed
#            --force     With --apply: rebuild every component
#            --rollback  With --apply: make manifest.prev.json current again
#            --help      Show usage
# Runs as  : oracle
# Requires : FORMS_CLIENT_DIST=true (Forms installs), FORMS_CLIENT_DIR (03-),
#            client JDK in the patch storage (04- --apply --mos), JDK_HOME
#            with jlink/keytool, unzip, zip, sha256sum, python3
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/40-forms_client_distribution.md (§10)
#            80-FMW-Architecture/java_jlink_forms_env.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
SW_CONF="$SCRIPT_DIR/oracle_software_version.conf"
TEMPLATE_DIR="$SCRIPT_DIR/client_templates"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
# shellcheck source=../environment.conf
source "$ENV_CONF"
# shellcheck source=./oracle_software_version.conf
[ -f "$SW_CONF" ] && source "$SW_CONF"

init_log

# =============================================================================
# Arguments
# =============================================================================
APPLY=false
FORCE=false
ROLLBACK=false

_usage() {
    printf "Usage: %s [--apply] [--force] [--rollback] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"     "Read-only: sources, current bundle, planned actions"
    printf "  %-12s %s\n" "--apply"    "Build the bundle when a source changed"
    printf "  %-12s %s\n" "--force"    "With --apply: rebuild every component"
    printf "  %-12s %s\n" "--rollback" "With --apply: make manifest.prev.json current again"
    printf "\nRef: 09-Install/docs/40-forms_client_distribution.md\n"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)    APPLY=true ;;
        --force)    FORCE=true ;;
        --rollback) ROLLBACK=true ;;
        --help|-h)  _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 2 ;;
    esac
done
unset _arg

# =============================================================================
# Settings
# =============================================================================
CLIENT_DIR="${FORMS_CLIENT_DIR:-/srv/formsWeb}"; CLIENT_DIR="${CLIENT_DIR%/}"
URL_PATH="${FORMS_CLIENT_URL_PATH:-/formsWeb}";  URL_PATH="${URL_PATH%/}"
BASE_URL="${FORMS_CLIENT_BASE_URL:-https://${WLS_SERVER_FQDN:-$(_get_hostname)}}"; BASE_URL="${BASE_URL%/}"
RUNTIME_MODE="${FORMS_CLIENT_RUNTIME:-jlink}"
CJ_NR="${CLIENT_JDK_PATCH_NR:-${JDK_PATCH_NR:-}}"
CJ_DIR="$PATCH_STORAGE/client/jdk/$CJ_NR"
# Module list – java_jlink_forms_env.md §3 (Windows modules included)
JLINK_MODULES="${FORMS_CLIENT_JLINK_MODULES:-java.base,java.desktop,java.management,java.net.http,jdk.jsobject,java.logging,java.naming,java.xml,java.prefs,jdk.crypto.ec,jdk.crypto.mscapi,jdk.charsets,jdk.localedata,jdk.unsupported,jdk.zipfs,jdk.accessibility}"
CA_ALIAS="ihw-forms-ca"
MANIFEST="$CLIENT_DIR/manifest.json"
MANIFEST_PREV="$CLIENT_DIR/manifest.prev.json"

_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
_size() { stat -c %s "$1" 2>/dev/null; }

# _mf_get <manifest> <component> <key> – value from a manifest (empty if none)
_mf_get() {
    [ -f "$1" ] || return 0
    python3 -I -c '
import json, sys
try:
    m = json.load(open(sys.argv[1]))
    print(m.get("components", {}).get(sys.argv[2], {}).get(sys.argv[3], ""))
except Exception:
    pass' "$1" "$2" "$3"
}

printLine
section "Forms client bundle – $(date '+%Y-%m-%d %H:%M:%S')"
ok "$(printf "%-22s %s" "FORMS_CLIENT_DIR:" "$CLIENT_DIR")"
ok "$(printf "%-22s %s" "URL:" "${BASE_URL}${URL_PATH}/")"
ok "$(printf "%-22s %s" "Runtime mode:" "$RUNTIME_MODE")"
$APPLY && info "Mode: APPLY" || info "Mode: read-only (use --apply to build)"

# =============================================================================
# 1. Pre-checks
# =============================================================================
section "Pre-checks"

case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    REPORTS_ONLY)
        info "INSTALL_COMPONENTS=REPORTS_ONLY – no Forms client, nothing to do"
        print_summary; exit 0 ;;
esac
if [ "${FORMS_CLIENT_DIST:-false}" != "true" ]; then
    info "FORMS_CLIENT_DIST is not true – client distribution not configured, nothing to do"
    info "  Enable: 09-Install/01-setup-interview.sh (Forms client distribution)"
    print_summary; exit 0
fi

PRE_FAIL=0
for _t in unzip zip sha256sum python3; do
    command -v "$_t" >/dev/null 2>&1 || { fail "$_t not installed"; PRE_FAIL=1; }
done
for _t in jlink keytool; do
    [ -x "$JDK_HOME/bin/$_t" ] || { fail "$JDK_HOME/bin/$_t missing (JDK_HOME)"; PRE_FAIL=1; }
done
unset _t
case "$RUNTIME_MODE" in
    jlink|jdk) ;;
    *) fail "FORMS_CLIENT_RUNTIME=$RUNTIME_MODE – allowed: jlink, jdk"; PRE_FAIL=1 ;;
esac
if [ -d "$CLIENT_DIR" ] && [ -w "$CLIENT_DIR" ]; then
    ok "$CLIENT_DIR exists and is writable"
else
    fail "$CLIENT_DIR missing or not writable – as root: 09-Install/03-root_user_oracle.sh --apply"
    PRE_FAIL=1
fi
[ "$PRE_FAIL" -ne 0 ] && { print_summary; exit 2; }

# =============================================================================
# Rollback: previous manifest becomes current
# =============================================================================
if $ROLLBACK; then
    section "Rollback"
    if [ ! -f "$MANIFEST_PREV" ]; then
        fail "No $MANIFEST_PREV – nothing to roll back to"
        print_summary; exit 2
    fi
    if ! $APPLY; then
        info "Would switch: manifest.prev.json -> manifest.json (use --apply --rollback)"
        print_summary; exit 0
    fi
    cp -p "$MANIFEST" "$CLIENT_DIR/.manifest.rollback.tmp" 2>/dev/null
    mv -f "$MANIFEST_PREV" "$MANIFEST" \
        && ok "manifest.prev.json is current again – clients switch at their next start"
    [ -f "$CLIENT_DIR/.manifest.rollback.tmp" ] && mv -f "$CLIENT_DIR/.manifest.rollback.tmp" "$MANIFEST_PREV" \
        && info "The replaced manifest is kept as manifest.prev.json"
    print_summary; exit $EXIT_CODE
fi

# =============================================================================
# 2. Sources
# =============================================================================
section "Sources"

# --- Client JDK (Windows) ----------------------------------------------------
CJ_ZIP=""
[ -n "$CJ_NR" ] && CJ_ZIP="$(ls -t "$CJ_DIR"/p"${CJ_NR}"_*.zip 2>/dev/null | grep -v Linux | head -1)"
if [ -z "$CJ_ZIP" ]; then
    fail "No client JDK ZIP in $CJ_DIR"
    info "  Download: 09-Install/04-oracle_pre_download.sh --apply --mos"
    print_summary; exit 2
fi
CJ_INNER="$(unzip -Z1 "$CJ_ZIP" 2>/dev/null | grep -E '^jdk-[0-9.]+_windows-x64_bin\.zip$' | head -1)"
if [ -z "$CJ_INNER" ]; then
    fail "No jdk-*_windows-x64_bin.zip in $(basename "$CJ_ZIP") – wrong platform?"
    print_summary; exit 2
fi
CJ_VER="$(printf '%s' "$CJ_INNER" | sed -n 's/^jdk-\([0-9.]*\)_windows-x64_bin\.zip$/\1/p')"
CJ_SHA_EXP="$(unzip -p "$CJ_ZIP" SHA256_VALUES 2>/dev/null | grep -F "($CJ_INNER)" | awk '{print $NF}')"
ok "$(printf "%-22s %s" "Client JDK:" "$(basename "$CJ_ZIP") → $CJ_INNER")"

# --- frmsal.jar -------------------------------------------------------------
FSAL_SRC="$ORACLE_HOME/forms/java/frmsal.jar"
if [ ! -f "$FSAL_SRC" ]; then
    fail "frmsal.jar missing: $FSAL_SRC (Forms installed?)"
    print_summary; exit 2
fi
FSAL_SHA="$(_sha "$FSAL_SRC")"
FSAL_VER="${FMW_PRODUCT_RELEASE:-14.1.2.0.0}-${FSAL_SHA:0:8}"
ok "$(printf "%-22s %s" "frmsal.jar:" "$FSAL_SRC ($FSAL_VER)")"

# --- JACOB x64 DLL (only FORMS_WEBUTIL_JACOB=true) --------------------------
JACOB_ON=false
JACOB_DLL_NAME=""
if [ "${FORMS_WEBUTIL_JACOB:-false}" = "true" ]; then
    JACOB_SRC_ZIP="$PATCH_STORAGE/jacob/${JACOB_ZIP:-jacob-1.21.zip}"
    JACOB_DLL_NAME="jacob-${JACOB_VERSION:-1.21}-x64.dll"
    if [ -f "$JACOB_SRC_ZIP" ] && unzip -Z1 "$JACOB_SRC_ZIP" 2>/dev/null | grep -q "/${JACOB_DLL_NAME}\$"; then
        JACOB_ON=true
        JACOB_ZIP_SHA="$(_sha "$JACOB_SRC_ZIP")"   # fingerprint – no server path in the public manifest
        ok "$(printf "%-22s %s" "JACOB DLL:" "$JACOB_DLL_NAME from $(basename "$JACOB_SRC_ZIP")")"
    else
        warn "FORMS_WEBUTIL_JACOB=true but $JACOB_DLL_NAME not found in $JACOB_SRC_ZIP – bundle without JACOB"
    fi
else
    info "$(printf "%-22s %s" "JACOB DLL:" "not part of the bundle (FORMS_WEBUTIL_JACOB=false)")"
fi

# --- CA ----------------------------------------------------------------------
CA_FILE="${FORMS_CLIENT_TRUST_CA:-}"
CA_SHA=""
if [ -n "$CA_FILE" ]; then
    if [ -f "$CA_FILE" ] && openssl x509 -in "$CA_FILE" -noout 2>/dev/null; then
        CA_SHA="$(_sha "$CA_FILE")"
        ok "$(printf "%-22s %s" "Truststore CA:" "$CA_FILE ($(openssl x509 -in "$CA_FILE" -noout -subject 2>/dev/null | sed 's/^subject=//'))")"
    else
        fail "FORMS_CLIENT_TRUST_CA $CA_FILE is no readable certificate"
        print_summary; exit 2
    fi
else
    info "$(printf "%-22s %s" "Truststore CA:" "none (public CA – Java's default cacerts)")"
fi

# --- Setup templates (Baustein 3, optional) ---------------------------------
SETUP_PS1="$TEMPLATE_DIR/FormsWeb-Setup.ps1"
SETUP_CMD="$TEMPLATE_DIR/FormsWeb-Install.cmd"
if [ -f "$SETUP_PS1" ] && [ -f "$SETUP_CMD" ]; then
    ok "$(printf "%-22s %s" "Setup scripts:" "$TEMPLATE_DIR")"
else
    warn "$(printf "%-22s %s" "Setup scripts:" "not yet in $TEMPLATE_DIR – manifest without \"setup\"")"
fi

# =============================================================================
# 3. Change check against the current manifest
# =============================================================================
section "Change check"

JAVA_FP="$(printf '%s|%s|%s|%s|%s' "$(_sha "$CJ_ZIP")" "$CJ_INNER" "$RUNTIME_MODE" "$JLINK_MODULES" "$CA_SHA" | sha256sum | cut -d' ' -f1)"
NEED_JAVA=true; NEED_FSAL=true; NEED_JACOB=$JACOB_ON
if ! $FORCE && [ -f "$MANIFEST" ]; then
    _cur_java_fp="$(_mf_get "$MANIFEST" java source)"
    _cur_java_file="$(_mf_get "$MANIFEST" java file)"
    [ "$_cur_java_fp" = "$JAVA_FP" ] && [ -f "$CLIENT_DIR/$_cur_java_file" ] && NEED_JAVA=false
    _cur_fsal_fp="$(_mf_get "$MANIFEST" fsal source)"
    _cur_fsal_file="$(_mf_get "$MANIFEST" fsal file)"
    [ "$_cur_fsal_fp" = "$FSAL_SHA" ] && [ -f "$CLIENT_DIR/$_cur_fsal_file" ] && NEED_FSAL=false
    if $JACOB_ON; then
        _cur_jacob_file="$(_mf_get "$MANIFEST" jacob file)"
        [ -n "$_cur_jacob_file" ] && [ -f "$CLIENT_DIR/$_cur_jacob_file" ] && NEED_JACOB=false
    fi
    unset _cur_java_fp _cur_java_file _cur_fsal_fp _cur_fsal_file _cur_jacob_file
fi
_setup_changed=false
# "setup" lives at the top level of the manifest, not under "components"
[ -f "$SETUP_PS1" ] && _setup_changed=true
if [ -f "$SETUP_PS1" ] && [ -f "$MANIFEST" ] && ! $FORCE; then
    _cur_setup="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("setup",{}).get("sha256",""))' "$MANIFEST" 2>/dev/null)"
    [ "$_cur_setup" = "$(_sha "$SETUP_PS1")" ] && _setup_changed=false || _setup_changed=true
    # the bootstrap .cmd carries the bundle URL (@@BASE_URL@@) – compare the rendered file
    if [ -f "$SETUP_CMD" ] && ! sed "s|@@BASE_URL@@|${BASE_URL}${URL_PATH}/|g" "$SETUP_CMD" \
            | cmp -s - "$CLIENT_DIR/FormsWeb-Install.cmd"; then
        _setup_changed=true
    fi
    unset _cur_setup
fi

$NEED_JAVA  && info "Java runtime : build ($CJ_VER, $RUNTIME_MODE)" || ok "Java runtime : up to date"
$NEED_FSAL  && info "frmsal.jar   : copy ($FSAL_VER)"               || ok "frmsal.jar   : up to date"
if $JACOB_ON; then
    $NEED_JACOB && info "JACOB DLL    : copy ($JACOB_DLL_NAME)" || ok "JACOB DLL    : up to date"
fi
[ -f "$SETUP_PS1" ] && { $_setup_changed && info "Setup script : copy" || ok "Setup script : up to date"; }

if ! $NEED_JAVA && ! $NEED_FSAL && ! $NEED_JACOB && ! $_setup_changed && [ -f "$MANIFEST" ]; then
    ok "Bundle is up to date – nothing to do (--force rebuilds)"
    print_summary; exit $EXIT_CODE
fi

if ! $APPLY; then
    info "Read-only – run with --apply to build"
    print_summary; exit $EXIT_CODE
fi

# =============================================================================
# 4. Build
# =============================================================================
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ihw_fcb_XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
umask 022

# --- 4a Java runtime ---------------------------------------------------------
if $NEED_JAVA; then
    section "Java runtime ($RUNTIME_MODE)"
    if ! unzip -q -o "$CJ_ZIP" "$CJ_INNER" -d "$WORK"; then
        fail "Cannot extract $CJ_INNER from $CJ_ZIP"; print_summary; exit 2
    fi
    _sha_act="$(_sha "$WORK/$CJ_INNER")"
    if [ -z "$CJ_SHA_EXP" ]; then
        warn "No SHA256_VALUES entry for $CJ_INNER – checksum not verified ($_sha_act)"
    elif [ "${_sha_act,,}" = "${CJ_SHA_EXP,,}" ]; then
        ok "SHA-256 of $CJ_INNER matches SHA256_VALUES"
    else
        fail "SHA-256 mismatch for $CJ_INNER: $_sha_act (expected $CJ_SHA_EXP)"
        print_summary; exit 2
    fi
    unset _sha_act

    RT="$WORK/runtime"
    if [ "$RUNTIME_MODE" = "jlink" ]; then
        if ! unzip -q -o "$WORK/$CJ_INNER" '*/jmods/*' -d "$WORK/jdk"; then
            fail "No jmods/ in $CJ_INNER – use FORMS_CLIENT_RUNTIME=jdk"; print_summary; exit 2
        fi
        _jmods="$(ls -d "$WORK"/jdk/*/jmods 2>/dev/null | head -1)"
        info "jlink $("$JDK_HOME/bin/jlink" --version) with $(ls "$_jmods" | wc -l) jmods of $CJ_VER"
        if ! "$JDK_HOME/bin/jlink" --module-path "$_jmods" --add-modules "$JLINK_MODULES" \
                --strip-debug --no-header-files --no-man-pages --compress=zip-6 \
                --output "$RT" >> "${LOG_FILE:-/dev/null}" 2>&1; then
            fail "jlink failed – see $LOG_FILE"; print_summary; exit 2
        fi
        unset _jmods
    else
        unzip -q -o "$WORK/$CJ_INNER" -d "$WORK/jdk" || { fail "Cannot extract $CJ_INNER"; print_summary; exit 2; }
        mv "$(ls -d "$WORK"/jdk/*/ | head -1)" "$RT"
    fi
    rm -rf "$WORK/jdk" "$WORK/$CJ_INNER"

    RT_VER="$(sed -n 's/^JAVA_VERSION="\(.*\)"/\1/p' "$RT/release")"
    [ -f "$RT/bin/javaw.exe" ] || { fail "javaw.exe missing in the built runtime"; print_summary; exit 2; }
    ok "$(printf "Runtime %s built: %s, %s modules" "$RT_VER" "$(du -sh "$RT" | cut -f1)" \
        "$(sed -n 's/^MODULES="\(.*\)"/\1/p' "$RT/release" | wc -w)")"

    if [ -n "$CA_FILE" ]; then
        if "$JDK_HOME/bin/keytool" -importcert -noprompt -alias "$CA_ALIAS" -file "$CA_FILE" \
                -keystore "$RT/lib/security/cacerts" -storepass changeit >> "${LOG_FILE:-/dev/null}" 2>&1; then
            ok "CA imported into lib/security/cacerts (alias $CA_ALIAS)"
        else
            fail "keytool import of $CA_FILE failed"; print_summary; exit 2
        fi
    fi

    JAVA_FILE="jre-${RT_VER}-win-x64.zip"
    # never overwrite a file a manifest may reference (clients could be downloading it)
    [ -f "$CLIENT_DIR/$JAVA_FILE" ] && JAVA_FILE="jre-${RT_VER}-win-x64-${JAVA_FP:0:8}.zip"
    [ -f "$CLIENT_DIR/$JAVA_FILE" ] && JAVA_FILE="jre-${RT_VER}-win-x64-${JAVA_FP:0:8}-$(date +%Y%m%d%H%M%S).zip"
    ( cd "$RT" && zip -q -r -X "$WORK/$JAVA_FILE" . ) || { fail "zip of the runtime failed"; print_summary; exit 2; }
    install -m 644 "$WORK/$JAVA_FILE" "$CLIENT_DIR/$JAVA_FILE"
    ok "$(printf "%-22s %s (%s)" "Java runtime:" "$JAVA_FILE" "$(du -h "$CLIENT_DIR/$JAVA_FILE" | cut -f1)")"
    JAVA_VERSION_OUT="$RT_VER"
    rm -rf "$RT"
else
    JAVA_FILE="$(_mf_get "$MANIFEST" java file)"
    JAVA_VERSION_OUT="$(_mf_get "$MANIFEST" java version)"
fi

# --- 4b frmsal.jar -----------------------------------------------------------
FSAL_FILE="frmsal-${FSAL_VER}.jar"
if $NEED_FSAL; then
    install -m 644 "$FSAL_SRC" "$CLIENT_DIR/$FSAL_FILE"
    ok "$(printf "%-22s %s" "frmsal.jar:" "$FSAL_FILE")"
fi

# --- 4c JACOB DLL --------------------------------------------------------------
if $JACOB_ON && $NEED_JACOB; then
    unzip -q -o -j "$JACOB_SRC_ZIP" "*/$JACOB_DLL_NAME" -d "$WORK" \
        && install -m 644 "$WORK/$JACOB_DLL_NAME" "$CLIENT_DIR/$JACOB_DLL_NAME"
    _jsize="$(_size "$CLIENT_DIR/$JACOB_DLL_NAME")"
    if [ -n "${JACOB_DLL_X64_SIZE:-}" ] && [ "$_jsize" != "$JACOB_DLL_X64_SIZE" ]; then
        warn "$JACOB_DLL_NAME has $_jsize bytes, webutil.cfg expects $JACOB_DLL_X64_SIZE"
    else
        ok "$(printf "%-22s %s (%s bytes)" "JACOB DLL:" "$JACOB_DLL_NAME" "$_jsize")"
    fi
    unset _jsize
fi

# --- 4d Setup scripts ----------------------------------------------------------
if [ -f "$SETUP_PS1" ] && [ -f "$SETUP_CMD" ]; then
    install -m 644 "$SETUP_PS1" "$CLIENT_DIR/FormsWeb-Setup.ps1"
    sed "s|@@BASE_URL@@|${BASE_URL}${URL_PATH}/|g" "$SETUP_CMD" > "$CLIENT_DIR/FormsWeb-Install.cmd"
    chmod 644 "$CLIENT_DIR/FormsWeb-Install.cmd"
    ok "$(printf "%-22s %s" "Setup scripts:" "FormsWeb-Setup.ps1 $(sed -n "s/^\\\$FormsWebSetupVersion *= *'\\(.*\\)'.*/\\1/p" "$SETUP_PS1" | tr -d '\r'), FormsWeb-Install.cmd -> ${BASE_URL}${URL_PATH}/")"
fi

# =============================================================================
# 5. Manifest (atomic switch)
# =============================================================================
section "manifest.json"

START_URL="${BASE_URL}/forms/frmservlet?config=${FORMS_CLIENT_CONFIG:-standaloneapp}"
[ -n "${FORMS_CLIENT_FORM:-}" ] && START_URL="${START_URL}&form=${FORMS_CLIENT_FORM}"

_tmp_mf="$CLIENT_DIR/.manifest.json.tmp"
if ! python3 -I - "$CLIENT_DIR" "$_tmp_mf" <<PYEOF
import hashlib, json, os, sys, datetime
d, out = sys.argv[1], sys.argv[2]
def comp(f, version, source):
    p = os.path.join(d, f)
    h = hashlib.sha256(open(p, "rb").read()).hexdigest()
    return {"version": version, "file": f, "size": os.path.getsize(p), "sha256": h, "source": source}
m = {
    "schemaVersion": 1,
    "generated": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "server": "${BASE_URL}",
    "baseUrl": "${BASE_URL}${URL_PATH}/",
    "components": {
        "java": comp("${JAVA_FILE}", "${JAVA_VERSION_OUT}", "${JAVA_FP}"),
        "fsal": comp("${FSAL_FILE}", "${FSAL_VER}", "${FSAL_SHA}"),
    },
    "start": {
        "url": "${START_URL}",
        "fsalArgs": ["-t", "30000", "-cert_truststore", "java"],
        "shortcutName": "${FORMS_CLIENT_APP_NAME:-Oracle Forms}",
    },
}
if "${JACOB_ON}" == "true":
    m["components"]["jacob"] = comp("${JACOB_DLL_NAME}", "${JACOB_VERSION:-1.21}", "${JACOB_ZIP_SHA:-}")
setup = os.path.join(d, "FormsWeb-Setup.ps1")
if os.path.exists(setup):
    h = hashlib.sha256(open(setup, "rb").read()).hexdigest()
    ver = "0"
    for line in open(setup, encoding="utf-8", errors="replace"):
        if line.startswith("\$FormsWebSetupVersion"):
            ver = line.split("=", 1)[1].strip().strip("'\"")
            break
    m["setup"] = {"version": ver, "file": "FormsWeb-Setup.ps1", "sha256": h,
                  "bootstrap": "FormsWeb-Install.cmd"}
json.dump(m, open(out, "w"), indent=2)
PYEOF
then
    fail "Writing the manifest failed"; rm -f "$_tmp_mf"; print_summary; exit 2
fi
chmod 644 "$_tmp_mf"
[ -f "$MANIFEST" ] && mv -f "$MANIFEST" "$MANIFEST_PREV" && info "Previous manifest kept as manifest.prev.json"
mv -f "$_tmp_mf" "$MANIFEST"
ok "manifest.json switched – clients see the new bundle at their next start"
unset _tmp_mf

# =============================================================================
# 6. Clean-up: own files referenced by neither manifest
# =============================================================================
section "Clean-up"
_keep="$(python3 -I -c '
import json, sys
for f in sys.argv[1:]:
    try:
        m = json.load(open(f))
    except Exception:
        continue
    for c in m.get("components", {}).values():
        print(c.get("file", ""))
' "$MANIFEST" "$MANIFEST_PREV")"
_removed=0
for _f in "$CLIENT_DIR"/jre-*.zip "$CLIENT_DIR"/frmsal-*.jar "$CLIENT_DIR"/jacob-*.dll; do
    [ -f "$_f" ] || continue
    if ! printf '%s\n' "$_keep" | grep -qxF "$(basename "$_f")"; then
        rm -f "$_f" && info "Removed (no longer referenced): $(basename "$_f")"
        _removed=$(( _removed + 1 ))
    fi
done
[ "$_removed" -eq 0 ] && ok "Nothing to remove"
unset _keep _removed _f

section "Result"
ls -la "$CLIENT_DIR" | tail -n +2 | while IFS= read -r _l; do info "  $_l"; done
info "Check: curl -sk ${BASE_URL}${URL_PATH}/manifest.json"

print_summary
exit $EXIT_CODE
