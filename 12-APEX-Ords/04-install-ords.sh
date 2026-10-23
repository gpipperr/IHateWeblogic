#!/bin/bash
# =============================================================================
# Script   : 04-install-ords.sh
# Purpose  : First installation of an ORDS instance (ords_N) for APEX:
#              1. ORDS ZIP from the patch storage -> $APEX_ORDS_BASE/ords-<ver>,
#                 home ords_N/ (config 700, link ords -> ../ords-<ver>)
#              2. ords install (non-interactive): ORDS_METADATA + ORDS_PUBLIC_USER
#                 in the APEX tablespace, pool "default" via TNS alias,
#                 PL/SQL gateway proxied to APEX_PUBLIC_USER, risky features off
#              3. ords config set: standalone.binds 127.0.0.1, port, context,
#                 caches, pool, GraphQL off,
#                 trusted origin, requestValidationFunction; logging.properties
#              4. runtime accounts -> profile APEX_DB_PROFILE (no expiry)
#              5. systemd ords@.service (template unit), enable --now, wait
#            Checks first: Java >= 17, APEX VALID, ORDS >= APEX and the APEXlang
#            compiler inside ords.war >= APEX (APEX 26 apps are compiled in ORDS).
#            A newer ORDS release later: 06-patch-ords.sh.
# Call     : ./12-APEX-Ords/04-install-ords.sh [--apply] [--instance N] [--sys-sec FILE]
# Runs as  : oracle (systemd + /var/log via sudo, else the commands are printed)
# Requires : 01-prepare-database.sh, 02-install-apex.sh, 04-oracle_pre_download.sh
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 12-APEX-Ords/README.md §5, 80-FMW-Architecture/ords_architecture.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"
check_env_conf "$ENV_CONF" || exit 2
# shellcheck source=../environment.conf
source "$ENV_CONF"
# shellcheck source=apex_ords_lib.sh
source "$SCRIPT_DIR/apex_ords_lib.sh"

init_log

APPLY=false; INST=1; SYS_SEC="$ROOT_DIR/db_sys_sec.conf.des3"
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY=true ;;
        --instance) INST="${2:-}"; shift ;;
        --sys-sec)  SYS_SEC="${2:-}"; shift ;;
        --help|-h)
            printf "Usage: %s [--apply] [--instance N] [--sys-sec FILE]\n" "$(basename "$0")"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done

_v() { local n="ORDS_${INST}_$1"; printf '%s' "${!n:-$2}"; }
ALIAS="$(_v DB_ALIAS "")"
PORT="$(_v PORT $((8080 + INST)))"
CTX="$(_v CONTEXT "/ords")"
HEAP="${ORDS_JAVA_HEAP:-2G}"
APEX_ORDS_BASE="${APEX_ORDS_BASE:-$ORACLE_BASE/product/ords}"
HOME_N="$APEX_ORDS_BASE/ords_${INST}"
CFG="$HOME_N/config"
LOG_BASE="${ORDS_LOG_BASE:-/var/log}"
LOG_DIR="$LOG_BASE/ords_${INST}"
TS="${APEX_TABLESPACE:-APEX_DATA}"; TS="${TS^^}"
TEMP="${APEX_TEMP_TABLESPACE:-TEMP}"; TEMP="${TEMP^^}"
PUB_URL="${ORDS_PUBLIC_URL:-https://${WLS_SERVER_FQDN:-$(hostname -f)}}"
APEX_SEC="$ROOT_DIR/apex_sec.conf.des3"
PWD_KEY="ORDS_${INST}_PUBLIC_PWD"
UNIT="ords@ords_${INST}.service"
UNIT_FILE="/etc/systemd/system/ords@.service"

ORDS_ZIP="$(otn_newest_zip "$PATCH_STORAGE/ords" 'ords*.zip')"
SW_VER="$( [ -n "$ORDS_ZIP" ] && ords_zip_ver "$ORDS_ZIP")"

printLine
section "ORDS installation – ords_${INST} ($(date '+%Y-%m-%d %H:%M:%S'))"
printList "ORDS ZIP"       20 "${ORDS_ZIP:-(none – 09-Install/04-oracle_pre_download.sh --apply)}"
printList "Home / config"  20 "$HOME_N  ($CFG)"
printList "TNS alias"      20 "${ALIAS:-(ORDS_${INST}_DB_ALIAS not set)}"
printList "Listener"       20 "127.0.0.1:${PORT}${CTX}"
printList "Tablespace"     20 "$TS / $TEMP  (ORDS_METADATA beside APEX)"
printList "Trusted origin" 20 "$PUB_URL"
printList "Features"       20 "SDW=${ORDS_FEATURE_SDW:-false} REST-SQL=${ORDS_FEATURE_REST_SQL:-false} DB-API=${ORDS_FEATURE_DB_API:-false} GraphQL=${ORDS_FEATURE_GRAPHQL:-disable_all}"
printList "Heap / logs"    20 "$HEAP / $LOG_DIR"
[ -n "${ORDS_PUBLIC_URL:-}" ] || info "ORDS_PUBLIC_URL not set – default $PUB_URL (interview block 4b)"

[ -n "$ORDS_ZIP" ] || { fail "No ORDS ZIP in $PATCH_STORAGE/ords/"; print_summary; exit 2; }
[ -n "$ALIAS" ]    || { fail "ORDS_${INST}_DB_ALIAS not set (interview block 4b)"; print_summary; exit 2; }

load_secrets_file "$SYS_SEC" > /dev/null 2>&1
IHW_SYS_PWD="${DB_SYS_PWD:-}"; unset DB_SYS_PWD DB_SCHEMA_PWD
[ -n "$IHW_SYS_PWD" ] || { fail "SYS password not found in $SYS_SEC (DB_SYS_PWD)"; print_summary; exit 2; }

# =============================================================================
# 0. Prerequisites
# =============================================================================
section "Prerequisites"
_jm="$(java_major "${JDK_HOME:-/nonexistent}")"
if [ "${_jm:-0}" -ge 17 ]; then
    ok "Java $_jm ($JDK_HOME) – ORDS 26 supports 17 / 21 / 25"
else
    fail "JDK_HOME ${JDK_HOME:-?}: Java ${_jm:-?} – ORDS needs 17 or newer"
fi
STATE="$(_q "select 'CON|'||sys_context('userenv','con_name') from dual;
select 'APEX|'||version||'|'||status from dba_registry where comp_id = 'APEX';
select 'TS|'||tablespace_name from dba_tablespaces where tablespace_name in ('$TS', '$TEMP');
select 'USR|'||username||'|'||default_tablespace from dba_users where username in ('ORDS_METADATA','ORDS_PUBLIC_USER');")"
printf '%s\n' "$STATE" | grep -q '^CON|' || { fail "Cannot connect as SYS to $ALIAS"; print_summary; exit 2; }
IFS='|' read -r APEX_VER APEX_STAT <<< "$(printf '%s\n' "$STATE" | sed -n 's/^APEX|//p')"
if [ "$APEX_STAT" = "VALID" ]; then
    ok "APEX $APEX_VER VALID"
else
    warn "APEX ${APEX_VER:-not installed} ${APEX_STAT:-} – ORDS installs anyway, APEX pages need 02-install-apex.sh"
fi
for _t in "$TS" "$TEMP"; do
    printf '%s\n' "$STATE" | grep -qx "TS|$_t" && ok "Tablespace $_t exists" \
        || fail "Tablespace $_t missing – 01-prepare-database.sh --apply"
done
if [ -n "${APEX_VER:-}" ]; then
    _amm="$(printf '%s' "$APEX_VER" | cut -d. -f1-2)"
    ver_ge "$SW_VER" "$_amm" && ok "ORDS $SW_VER >= APEX $_amm" \
        || fail "ORDS $SW_VER older than APEX $_amm – rule ORDS >= APEX (APEX 26.2 needs ORDS 26.3.0+)"
    _wd="$(mktemp -d)"
    unzip -q -o "$ORDS_ZIP" ords.war -d "$_wd" 2>/dev/null
    _al="$(ords_apexlang_ver "$_wd")"; rm -rf "$_wd"
    if [ -n "$_al" ]; then
        ver_ge "$_al" "$_amm" && ok "APEXlang compiler in ords.war: $_al (>= APEX $_amm)" \
            || fail "APEXlang compiler in ords.war $_al older than APEX $_amm – newer ORDS needed"
    else
        warn "No apexlang-compiler jar found in ords.war – ORDS before 26.1.1?"
    fi
fi
REPO="$(ords_repo_ver)"
LINKED="$(ords_linked_ver "$INST")"
printList "ORDS repository" 20 "${REPO:-(none)}"
printList "Linked software" 20 "${LINKED:-(none)}"
if [ -n "$REPO" ] && [ -f "$CFG/databases/default/pool.xml" ]; then
    INSTALL_DONE=true
    ok "ORDS repository $REPO + pool config present – ords install skipped (newer release: 06-patch-ords.sh)"
else
    INSTALL_DONE=false
    [ -n "$REPO" ] && warn "ORDS_METADATA $REPO exists without this config – ords install validates / upgrades it"
fi
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
    systemctl is-active --quiet "$UNIT" 2>/dev/null && ok "Port $PORT used by $UNIT" \
        || fail "Port $PORT already in use by another process"
else
    ok "Port $PORT free"
fi
_avail="$(free -m | awk '/^Mem:/ {print $7}')"
_heap_mb="$(( ${HEAP%[GgMm]} * ( $( [[ "$HEAP" == *[Gg] ]] && printf 1024 || printf 1) ) ))"
[ "${_avail:-0}" -gt "$(( _heap_mb + 512 ))" ] && ok "Memory: ${_avail} MB available, heap ${HEAP}" \
    || warn "Memory: only ${_avail} MB available for heap ${HEAP} – lower ORDS_JAVA_HEAP"
ihw_can_sudo && ok "sudo available (systemd, $LOG_DIR)" || warn "No sudo – the root steps are printed"

if [ "${CNT_FAIL:-0}" -gt 0 ] || ! $APPLY; then
    $APPLY || info "Dry-run – --apply installs ORDS (ords install ~1-2 min) and starts $UNIT"
    IHW_SYS_PWD=""; printLine; print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# 1. Software + home
# =============================================================================
section "Software + home"
SW_DIR="$(ords_unpack "$ORDS_ZIP")" && ok "software: $SW_DIR" \
    || { fail "unzip of $ORDS_ZIP failed"; print_summary; exit 2; }
mkdir -p "$CFG" && chmod 700 "$CFG"
ln -sfn "../ords-$SW_VER" "$HOME_N/ords" && ok "link $HOME_N/ords -> ords-$SW_VER"
_v_out="$(ords_cmd "$INST" --version 2>&1 | grep -m1 'Oracle REST Data Services')"
[ -n "$_v_out" ] && ok "$_v_out" || fail "ords --version failed (JDK_HOME?)"

# =============================================================================
# 2. ords install – repository + pool (passwords via stdin only)
# =============================================================================
if ! $INSTALL_DONE; then
    section "ords install"
    [ -f "$APEX_SEC" ] && load_secrets_file "$APEX_SEC" > /dev/null 2>&1
    PUB_PWD="${!PWD_KEY:-}"
    if [ -z "$PUB_PWD" ]; then
        PUB_PWD="Op$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24)5"
        merge_secrets_file "$APEX_SEC" "$PWD_KEY=$PUB_PWD" > /dev/null \
            && ok "ORDS_PUBLIC_USER password generated -> $(basename "$APEX_SEC") ($PWD_KEY)" \
            || { fail "cannot write $APEX_SEC"; print_summary; exit 2; }
    fi
    INST_LOG="$(dirname "$LOG_FILE")/ords_install_${INST}_$(date +%H%M%S)"
    mkdir -p "$INST_LOG"
    info "started $(date '+%H:%M:%S') – log folder $INST_LOG"
    # password order = order of the user options: --admin-user, then --proxy-user;
    # no --db-pool: the pool is "default" anyway and ORDS 26.3 rejects
    # "--db-pool default" ("The default name is not allowed", live 2026-10-23)
    ords_cmd "$INST" install \
        --admin-user "SYS AS SYSDBA" \
        --proxy-user \
        --db-tns-dir "$TNS_ADMIN" --db-tns-alias "$ALIAS" \
        --schema-tablespace "$TS" --schema-temp-tablespace "$TEMP" \
        --proxy-user-tablespace "$TS" --proxy-user-temp-tablespace "$TEMP" \
        --gateway-mode proxied --gateway-user APEX_PUBLIC_USER \
        --feature-sdw "${ORDS_FEATURE_SDW:-false}" \
        --feature-rest-enabled-sql "${ORDS_FEATURE_REST_SQL:-false}" \
        --feature-db-api "${ORDS_FEATURE_DB_API:-false}" \
        --log-folder "$INST_LOG" \
        --password-stdin > "$INST_LOG/ords_install_stdout.log" 2>&1 <<EOF
$IHW_SYS_PWD
$PUB_PWD
EOF
    _rc=$?
    unset PUB_PWD "$PWD_KEY"
    info "finished $(date '+%H:%M:%S') (rc=$_rc)"
    REPO="$(ords_repo_ver)"
    if [ -n "$REPO" ] && [ -f "$CFG/databases/default/pool.xml" ]; then
        ok "ORDS repository $REPO installed, pool config written"
    else
        fail "ords install failed (rc=$_rc) – see $INST_LOG"
        grep -hE 'ORA-[0-9]+|Error|SEVERE' "$INST_LOG"/*.log 2>/dev/null | head -5 | sed 's/^/    /'
        IHW_SYS_PWD=""; print_summary; exit 2
    fi
    if grep -qhiE 'ORA-[0-9]+' "$INST_LOG"/*.log 2>/dev/null; then
        warn "ORA- messages in the install log: $(grep -ohE 'ORA-[0-9]+' "$INST_LOG"/*.log | sort -u | tr '\n' ' ')– check $INST_LOG"
    fi
fi

# =============================================================================
# 3. Settings (ords config set – never edit the XML by hand)
# =============================================================================
section "Settings"
# config set accepts UNKNOWN keys silently (standalone.http.host was taken
# without an error, Jetty still listened on 0.0.0.0 – live 2026-10-23), so
# every key is checked with "config info" first
_set() {
    local k="$1" val="$2" cur
    if ords_cmd "$INST" config info "$k" 2>&1 | grep -q 'not a recognized'; then
        fail "ORDS does not know the setting $k – script / ORDS release mismatch"; return 1
    fi
    cur="$(ords_cmd "$INST" config get "$k" 2>/dev/null | tail -1)"
    if [ "$cur" = "$val" ]; then
        ok "$(printf "%-42s %s" "$k" "$val")"
    elif ords_cmd "$INST" config set "$k" "$val" > /dev/null 2>&1; then
        ok "$(printf "%-42s %s  (set)" "$k" "$val")"; CHANGED=true
    else
        fail "config set $k $val failed"
    fi
}
CHANGED=false
_set standalone.binds                     127.0.0.1
_set standalone.http.port                 "$PORT"
_set standalone.context.path              "$CTX"
_set standalone.access.log                "$LOG_DIR"
_set cache.metadata.enabled               true
_set cache.metadata.timeout               900
_set jdbc.InitialLimit                    10
_set jdbc.MinLimit                        10
_set jdbc.MaxLimit                        50
_set plsql.gateway.mode                   proxied
_set feature.graphql                      "${ORDS_FEATURE_GRAPHQL:-disable_all}"
_set security.externalSessionTrustedOrigins "$PUB_URL"
_set security.requestValidationFunction   ords_util.authorize_plsql_gateway
_lp="$CFG/global/logging.properties"
mkdir -p "$CFG/global"
_tmp="$(mktemp)"
tpl_render "$SCRIPT_DIR/templates/logging.properties.template" "$_tmp" "LOG_DIR=$LOG_DIR" || { rm -f "$_tmp"; print_summary; exit 2; }
if cmp -s "$_tmp" "$_lp"; then
    ok "logging.properties up to date"; rm -f "$_tmp"
else
    mv "$_tmp" "$_lp" && ok "logging.properties written ($LOG_DIR/ords_sys_N.log, 5 x 10 MB)"; CHANGED=true
fi
_foreign="$(find "$CFG" -type f \( -name '*.bak' -o -name '*.old' -o -name '*~' -o -name '*.orig' \) 2>/dev/null)"
[ -z "$_foreign" ] && ok "no backup copies below config/ (ORDS reads every file there)" \
    || warn "files below config/ that ORDS would read: $(printf '%s ' $_foreign)– move them out"

# =============================================================================
# 4. Runtime accounts – profile without expiry, proxy rights
# =============================================================================
section "Runtime accounts"
apex_profile_run assign
_q "select 'PX|'||proxy||'|'||client from proxy_users where proxy = 'ORDS_PUBLIC_USER' order by client;
select 'U|'||username||'|'||default_tablespace||'|'||account_status from dba_users where username in ('ORDS_METADATA','ORDS_PUBLIC_USER') order by 1;" \
| while IFS='|' read -r _k _a _b _c; do
    case "$_k" in
        PX) ok "proxy right: $_a -> $_b" ;;
        U)  [ "$_b" = "$TS" ] && ok "$_a in tablespace $_b ($_c)" || warn "$_a in tablespace $_b ($_c) – expected $TS" ;;
    esac
done

# =============================================================================
# 5. Autostart – systemd template unit ords@.service
# =============================================================================
section "Autostart (systemd)"
_unit_tmp="$(mktemp)"
tpl_render "$SCRIPT_DIR/templates/ords@.service.template" "$_unit_tmp" \
    "ORDS_BASE=$APEX_ORDS_BASE" "JDK_HOME=$JDK_HOME" "HEAP=$HEAP" \
    "LOG_BASE=$LOG_BASE" "TNS_ADMIN=$TNS_ADMIN" || { rm -f "$_unit_tmp"; print_summary; exit 2; }
if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    ok "log directory $LOG_DIR"
else
    ihw_run_root install -d -o oracle -g oinstall -m 750 "$LOG_DIR" && ok "log directory $LOG_DIR created"
fi
if cmp -s "$_unit_tmp" "$UNIT_FILE" 2>/dev/null; then
    ok "unit $UNIT_FILE up to date"
else
    ihw_run_root install -m 644 "$_unit_tmp" "$UNIT_FILE" && ok "unit installed: $UNIT_FILE" \
        && ihw_run_root systemctl daemon-reload && CHANGED=true
fi
rm -f "$_unit_tmp"
systemctl is-enabled --quiet "$UNIT" 2>/dev/null && ok "$UNIT enabled" \
    || { ihw_run_root systemctl enable "$UNIT" > /dev/null 2>&1 && ok "$UNIT enabled (boot)"; }
if systemctl is-active --quiet "$UNIT"; then
    if $CHANGED; then
        ihw_run_root systemctl restart "$UNIT" && ok "$UNIT restarted (configuration changed)"
    else
        ok "$UNIT running"
    fi
else
    ihw_run_root systemctl start "$UNIT" && ok "$UNIT started"
fi
_code="$(ords_wait_http "http://127.0.0.1:${PORT}${CTX}/" 150)"
if [ "${_code:-000}" != "000" ] && [ "$_code" -lt 500 ]; then
    ok "ORDS answers: http://127.0.0.1:${PORT}${CTX}/ -> HTTP $_code"
else
    fail "ORDS does not answer on 127.0.0.1:${PORT} (HTTP ${_code:-none}) – journalctl -u $UNIT, $LOG_DIR"
fi
_listen="$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -E "[:.]${PORT}\$" | sort -u | tr '\n' ' ')"
if [ -n "$_listen" ] && ! printf '%s' "$_listen" | grep -qvE '^(127\.0\.0\.1|\[::1\]):'; then
    ok "listens on loopback only: $_listen"
else
    warn "listener: ${_listen:-none} – expected 127.0.0.1:${PORT} only"
fi
info "Next: 12-APEX-Ords/05-setup-nginx.sh --apply (Nginx ${CTX}/ + images)"

IHW_SYS_PWD=""
printLine
print_summary
exit "$EXIT_CODE"
