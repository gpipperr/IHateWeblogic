#!/bin/bash
# =============================================================================
# Script   : 05-setup-nginx.sh
# Purpose  : Publish an ORDS instance (ords_N) and its APEX images through Nginx:
#              1. oracle-wls.conf includes /etc/nginx/oracle-wls.d/*.conf in the
#                 443 server block (09-Install/nginx-wls.conf.template)
#              2. ORDS answers on 127.0.0.1:<port><context>
#              3. APEX images: link $APEX_WEB_DIR/apex_N, version = database,
#                 IMAGE_PREFIX of the instance = ORDS_N_IMAGE_PREFIX, readable
#                 for the nginx user, SELinux contexts if enforcing
#              4. render templates/nginx-ords.conf.template ->
#                 /etc/nginx/oracle-wls.d/ords_N.conf (backup, nginx -t, reload,
#                 rollback on error) – X-Forwarded-For overwritten, never appended
#              5. HTTPS check: <prefix>apex_version.txt and <context>/
# Call     : ./12-APEX-Ords/05-setup-nginx.sh [--apply] [--instance N] [--sys-sec FILE]
# Runs as  : oracle (Nginx files via sudo, else the commands are printed)
# Requires : 04-install-ords.sh, 09-Install/04-root_nginx.sh + 05-root_nginx_ssl.sh
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 12-APEX-Ords/README.md §5.7, 80-FMW-Architecture/ords_architecture.md
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
PREFIX="$(_v IMAGE_PREFIX "/i/")"
WEB="${APEX_WEB_DIR:-/srv/apex}"
IMAGE_DIR="$WEB/apex_${INST}"
MAIN_CONF="/etc/nginx/conf.d/oracle-wls.conf"
INC_DIR="/etc/nginx/oracle-wls.d"
CONF="$INC_DIR/ords_${INST}.conf"
FQDN="${WLS_SERVER_FQDN:-$(hostname -f)}"

printLine
section "Nginx for ORDS / APEX – ords_${INST} ($(date '+%Y-%m-%d %H:%M:%S'))"
printList "Location"     20 "${CTX}/ -> http://127.0.0.1:${PORT}${CTX}/"
printList "Images"       20 "${PREFIX} -> ${IMAGE_DIR}/"
printList "Nginx file"   20 "$CONF"
printList "Public URL"   20 "https://${FQDN}${CTX}/"

# =============================================================================
# 1. Nginx main configuration includes the instance files
# =============================================================================
section "Nginx main configuration"
if [ ! -r "$MAIN_CONF" ]; then
    fail "$MAIN_CONF missing – 09-Install/04-root_nginx.sh --apply first"; print_summary; exit 2
fi
if grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/oracle-wls\.d/\*\.conf;' "$MAIN_CONF"; then
    ok "$MAIN_CONF includes $INC_DIR/*.conf"
    INC_OK=true
else
    fail "$MAIN_CONF has no 'include $INC_DIR/*.conf;' – re-render it: 09-Install/04-root_nginx.sh --apply (template since 2026-10-23)"
    INC_OK=false
fi

# =============================================================================
# 2. ORDS listener
# =============================================================================
section "ORDS"
_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}${CTX}/" 2>/dev/null)"
if [ "${_code:-000}" != "000" ] && [ "$_code" -lt 500 ]; then
    ok "ORDS answers on 127.0.0.1:${PORT}${CTX}/ (HTTP $_code)"
else
    fail "ORDS does not answer on 127.0.0.1:${PORT} (HTTP ${_code:-none}) – 04-install-ords.sh / systemctl status ords@ords_${INST}"
fi

# =============================================================================
# 3. APEX images
# =============================================================================
section "APEX images"
IMG_VER=""
if [ -L "$IMAGE_DIR" ] && [ -f "$IMAGE_DIR/apex_version.txt" ]; then
    IMG_VER="$(sed -n 's/.*Version:[[:space:]]*\([0-9.]*\).*/\1/p' "$IMAGE_DIR/apex_version.txt" | head -1)"
    ok "$IMAGE_DIR -> $(readlink "$IMAGE_DIR") (images $IMG_VER)"
else
    fail "$IMAGE_DIR is no link to an image copy – 02-install-apex.sh --apply"
fi
if [ -n "$ALIAS" ] && load_secrets_file "$SYS_SEC" > /dev/null 2>&1 && [ -n "${DB_SYS_PWD:-}" ]; then
    IHW_SYS_PWD="$DB_SYS_PWD"; unset DB_SYS_PWD DB_SCHEMA_PWD
    R="$(_q "select 'APEX|'||version from dba_registry where comp_id = 'APEX';
select 'PFX|'||apex_instance_admin.get_parameter('IMAGE_PREFIX') from dual;")"
    DB_VER="$(printf '%s\n' "$R" | sed -n 's/^APEX|//p' | cut -d. -f1-2)"
    DB_PFX="$(printf '%s\n' "$R" | sed -n 's/^PFX|//p')"
    [ -n "$DB_VER" ] && [ "$DB_VER" = "$(printf '%s' "$IMG_VER" | cut -d. -f1-2)" ] \
        && ok "image version $IMG_VER = APEX in the database ($DB_VER)" \
        || warn "image version ${IMG_VER:-?} <> APEX in the database ${DB_VER:-?} – wrong link?"
    if [ "$DB_PFX" = "$PREFIX" ]; then
        ok "APEX IMAGE_PREFIX = $PREFIX"
    else
        warn "APEX IMAGE_PREFIX '$DB_PFX' <> ORDS_${INST}_IMAGE_PREFIX '$PREFIX' – fix as SYS: exec apex_instance_admin.set_parameter('IMAGE_PREFIX','$PREFIX'); commit;"
    fi
    IHW_SYS_PWD=""
else
    info "no SYS password – database version / IMAGE_PREFIX not checked"
fi
if [ -f "$IMAGE_DIR/apex_version.txt" ]; then
    if ! ihw_can_sudo; then
        info "no sudo – readability for the nginx user not checked"
    elif sudo -n -u nginx test -r "$IMAGE_DIR/apex_version.txt" 2>/dev/null; then
        ok "readable for the nginx user"
    else
        warn "nginx user cannot read $IMAGE_DIR (directory mode 755 / files 644 on the whole path?)"
    fi
fi
SELINUX="$(getenforce 2>/dev/null || printf 'n/a')"
if [ "$SELINUX" = "Enforcing" ]; then
    _ctx="$(ls -Zd "$(readlink -f "$IMAGE_DIR")" 2>/dev/null | awk '{print $1}')"
    _bool="$(getsebool httpd_can_network_connect 2>/dev/null | awk '{print $3}')"
    [[ "$_ctx" == *httpd_sys_content_t* ]] && ok "SELinux context $_ctx" || warn "SELinux context ${_ctx:-?} – --apply sets httpd_sys_content_t"
    [ "$_bool" = "on" ] && ok "SELinux httpd_can_network_connect on" || warn "SELinux httpd_can_network_connect ${_bool:-?} – --apply sets it"
else
    ok "SELinux $SELINUX – no file contexts needed"
fi

# =============================================================================
# 4. Instance file
# =============================================================================
section "Nginx instance file"
TMP="$(mktemp)"
tpl_render "$SCRIPT_DIR/templates/nginx-ords.conf.template" "$TMP" \
    "CONTEXT=$CTX" "PORT=$PORT" "PREFIX=$PREFIX" "IMAGE_DIR=$IMAGE_DIR" "INST=ords_${INST}" \
    || { rm -f "$TMP"; print_summary; exit 2; }
if ihw_run_root cmp -s "$TMP" "$CONF" 2>/dev/null; then
    ok "$CONF up to date"; NEW_CONF=false
else
    [ -f "$CONF" ] && info "$CONF differs from the template" || info "$CONF does not exist yet"
    NEW_CONF=true
fi

if ! $APPLY; then
    $NEW_CONF && info "Dry-run – --apply writes $CONF, runs nginx -t and reloads Nginx"
    rm -f "$TMP"; printLine; print_summary; exit "$EXIT_CODE"
fi
if [ "${CNT_FAIL:-0}" -gt 0 ]; then
    fail "Not deployed – fix the FAIL lines above first"; rm -f "$TMP"; print_summary; exit 2
fi

if [ "$SELINUX" = "Enforcing" ]; then
    ihw_run_root semanage fcontext -a -t httpd_sys_content_t "${WEB}(/.*)?" 2>/dev/null \
        || ihw_run_root semanage fcontext -m -t httpd_sys_content_t "${WEB}(/.*)?"
    ihw_run_root restorecon -R "$WEB" && ok "SELinux: httpd_sys_content_t on $WEB"
    ihw_run_root setsebool -P httpd_can_network_connect 1 && ok "SELinux: httpd_can_network_connect on"
fi

if $NEW_CONF; then
    ihw_run_root mkdir -p "$INC_DIR"
    BAK=""
    if [ -f "$CONF" ]; then
        BAK="$INC_DIR/.ords_${INST}.conf.bak_$(date +%Y%m%d_%H%M%S)"   # dot file: not matched by *.conf
        ihw_run_root cp -p "$CONF" "$BAK" && ok "backup: $BAK"
    fi
    ihw_run_root install -m 644 "$TMP" "$CONF" && ok "written: $CONF"
    if ihw_run_root nginx -t > /dev/null 2>&1; then
        ok "nginx -t OK"
        ihw_run_root systemctl reload nginx && ok "Nginx reloaded"
    else
        fail "nginx -t failed: $(ihw_run_root nginx -t 2>&1 | grep -m1 emerg)"
        if [ -n "$BAK" ]; then
            ihw_run_root cp -p "$BAK" "$CONF" && warn "previous $CONF restored"
        else
            ihw_run_root rm -f "$CONF" && warn "$CONF removed again – Nginx unchanged"
        fi
    fi
fi
rm -f "$TMP"

# =============================================================================
# 5. Through Nginx (HTTPS, local resolve of the public name)
# =============================================================================
section "HTTPS check"
_c=(-sk --max-time 15 --resolve "${FQDN}:443:127.0.0.1")
# reload is asynchronous – old workers answer for a moment (404 seen live)
for _i in 1 2 3 4 5; do
    _txt="$(curl "${_c[@]}" "https://${FQDN}${PREFIX}apex_version.txt" 2>/dev/null | tr -d '\r')"
    [[ "$_txt" == *"Version"* ]] && break
    sleep 2
done
[[ "$_txt" == *"Version"* ]] && ok "https://${FQDN}${PREFIX}apex_version.txt: $(printf '%s' "$_txt" | tr -s ' ')" \
    || fail "https://${FQDN}${PREFIX}apex_version.txt not served"
_code="$(curl "${_c[@]}" -o /dev/null -w '%{http_code}' "https://${FQDN}${CTX}/apex" 2>/dev/null)"
case "$_code" in
    200|301|302|303) ok "https://${FQDN}${CTX}/apex -> HTTP $_code" ;;
    *)               fail "https://${FQDN}${CTX}/apex -> HTTP ${_code:-none} (Nginx error log, ${ORDS_LOG_BASE:-/var/log}/ords_${INST})" ;;
esac
info "Browser: https://${FQDN}${CTX}/apex – workspace INTERNAL, user ADMIN (password in apex_sec.conf.des3)"

printLine
print_summary
exit "$EXIT_CODE"
