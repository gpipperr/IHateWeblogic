#!/bin/bash
# =============================================================================
# Script   : domain_secret_check.sh
# Purpose  : Protection of the WebLogic domain key (security/SerializedSystemIni.dat)
#            and of the values it decrypts (boot.properties, config.xml, JDBC
#            modules) - and the blast radius of the domain owner account.
#            Two real attack paths (80-FMW-Architecture/fmw_pwd_handling.md §1a):
#              a) a file-read hole -> key + {AES} values -> offline decryption
#                 -> admin login -> deployment = code execution
#              b) code execution as the domain owner (unpatched / reachable
#                 console, T3) -> everything that account can read and do
#            Checks:
#              1 file modes of the key, config.xml, JDBC modules, every
#                boot.properties (server + Node Manager cache), group members
#              2 boot.properties still in clear text
#              3 file-read paths of the stack: WebUtil transfer.appsrv
#                (both webutil.cfg), Reports folderAccess (every rwserver.conf)
#              4 admin interfaces: Nginx /console /em /management only from
#                ADMIN_IP_RANGE; AdminServer / Node Manager on loopback (ss)
#              5 account lockout (config.xml), admin user name
#              6 blast radius: groups / sudo of the owner, DB on the host,
#                other domains, copies of the domain key outside the domain
#              7 DISA STIG items (WebLogic 12c V2R2): password rule of the
#                domain, lockout values, configuration audit / auditing
#                provider, OPSS audit filterPreset, applications on the
#                AdminServer, umask of the owner (80-FMW-Architecture/
#                stig_weblogic_forms_reports.md)
#            --apply: chmod 600 on SerializedSystemIni.dat and every
#            boot.properties (old modes saved to log/<date>/) - nothing else.
# Call     : ./02-Checks/domain_secret_check.sh            (read-only)
#            ./02-Checks/domain_secret_check.sh --apply    (modes 600)
# Runs as  : the domain owner (oracle)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 80-FMW-Architecture/fmw_pwd_handling.md, stig_weblogic_forms_reports.md, 02-Checks/README.md
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
# shellcheck disable=SC1090
source "$ENV_CONF"
init_log

APPLY=false
for _a in "$@"; do
    case "$_a" in
        --apply) APPLY=true ;;
        --help|-h)
            printf "Usage: %s [--apply]\n\n" "$(basename "$0")"
            printf "  %-10s %s\n" "--apply" "chmod 600 on SerializedSystemIni.dat and every boot.properties (old modes saved)"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_a" >&2; exit 1 ;;
    esac
done

DH="${DOMAIN_HOME:-}"
OH="${ORACLE_HOME:-${FMW_HOME:-}}"
[ -d "$DH/config" ] || { fail "DOMAIN_HOME not found: ${DH:-?}"; print_summary; exit 2; }
KEY="$DH/security/SerializedSystemIni.dat"
OWNER="$(stat -c %U "$DH" 2>/dev/null)"

printLine
printf "\n\033[1m  IHateWeblogic – domain key / admin access / blast radius\033[0m\n" | tee -a "$LOG_FILE"
printList "Domain"        20 "$DH"
printList "Domain owner"  20 "${OWNER:-?}"
printList "Mode"          20 "$($APPLY && printf 'apply (modes 600)' || printf 'read-only')"
printLine

# _others_in_group GROUP OWNER - members of GROUP other than OWNER (secondary
# members from getent + users whose primary group it is)
_others_in_group() {
    local g="$1" o="$2" gid mem
    gid="$(getent group "$g" | cut -d: -f3)"
    mem="$(getent group "$g" | cut -d: -f4 | tr ',' '\n')"
    [ -n "$gid" ] && mem="$mem
$(getent passwd | awk -F: -v g="$gid" '$4 == g {print $1}')"
    printf '%s\n' "$mem" | sed '/^$/d' | sort -u | grep -vx "$o" | paste -sd, -
}

# =============================================================================
section "1. File modes of the domain secrets"
# =============================================================================
TO_600=()
_mode_check() {   # file label [apply600]
    local f="$1" l="$2" a="${3:-}" m u g oth
    [ -f "$f" ] || return 0
    m="$(stat -c %a "$f")"; u="$(stat -c %U "$f")"; g="$(stat -c %G "$f")"
    local msg; msg="$(printf "  %-30s %s %s:%s  %s" "$l" "$m" "$u" "$g" "$f")"
    if [ $(( 0${m: -1} & 4 )) -ne 0 ]; then
        fail "$msg – readable for EVERY user"
        [ -n "$a" ] && TO_600+=("$f")
    elif [ $(( 0${m: -2:1} & 4 )) -ne 0 ]; then
        oth="$(_others_in_group "$g" "$u")"
        if [ -n "$oth" ]; then
            warn "$msg – group $g has further members: $oth (each of them can decrypt the domain)"
        else
            info "$msg – group $g has no further members"
        fi
        [ -n "$a" ] && TO_600+=("$f")
    else
        ok "$msg"
    fi
}
if [ -f "$KEY" ]; then
    _mode_check "$KEY" "domain key" apply
else
    fail "Domain key missing: $KEY"
fi
_mode_check "$DH/config/config.xml" "config.xml"
for _f in "$DH"/config/jdbc/*.xml; do _mode_check "$_f" "JDBC $(basename "$_f")"; done
BOOTS=()
while IFS= read -r _f; do BOOTS+=("$_f"); done < <(find "$DH/servers" -name boot.properties -type f 2>/dev/null | sort)
for _f in "${BOOTS[@]}"; do
    _l="boot.properties ($(printf '%s' "$_f" | sed -n 's#.*/servers/\([^/]*\)/.*#\1#p'))"
    case "$_f" in */data/nodemanager/*) _l="$_l NM cache" ;; esac
    _mode_check "$_f" "$_l" apply
done
info "  Key next to the values: whoever can read the key AND one {AES} value has the password (offline)."

# =============================================================================
section "2. boot.properties in clear text"
# =============================================================================
_clear=0
for _f in "${BOOTS[@]}"; do
    if grep -qE '^[[:space:]]*password[[:space:]]*=' "$_f" && ! grep -qE '^[[:space:]]*password[[:space:]]*=[[:space:]]*\{AES' "$_f"; then
        warn "  clear-text password: $_f – start the server once (it encrypts the file) or rewrite it (09-Install/10-oracle_boot_properties.sh)"
        _clear=$((_clear + 1))
    fi
done
[ "$_clear" -eq 0 ] && ok "  every boot.properties is encrypted ({AES...})"

# =============================================================================
section "3. File-read paths of Forms / Reports"
# =============================================================================
# _covers DIR - 0 when DIR is "/" or lies above / at DOMAIN_HOME or ORACLE_HOME
_covers() {
    local d="${1%/}"; [ -z "$d" ] && return 0
    local t; for t in "$DH" "$OH"; do
        [ -n "$t" ] || continue
        case "$t/" in "$d"/*) return 0 ;; esac
        case "$d/" in "$t"/*) return 0 ;; esac
    done
    return 1
}
_wfound=0
while IFS= read -r _w; do
    _wfound=1
    _ac="$(sed -n 's/^[[:space:]]*transfer\.appsrv\.accessControl[[:space:]]*=[[:space:]]*//p' "$_w" | tail -1 | tr -d '[:space:]' | tr 'a-z' 'A-Z')"
    _en="$(sed -n 's/^[[:space:]]*transfer\.appsrv\.enabled[[:space:]]*=[[:space:]]*//p' "$_w" | tail -1 | tr -d '[:space:]' | tr 'a-z' 'A-Z')"
    if [ "$_en" = "TRUE" ] && [ "$_ac" != "TRUE" ]; then
        fail "  $_w: transfer.appsrv enabled with accessControl=${_ac:-unset} – every file of the OS user can be read/written"
        continue
    fi
    _bad=""
    while IFS='=' read -r _k _v; do
        _v="$(printf '%s' "$_v" | sed 's/[[:space:]]*$//')"
        for _p in $(printf '%s' "$_v" | tr ',;' '  '); do _covers "$_p" && _bad="$_bad $_k=$_p"; done
    done < <(grep -E '^[[:space:]]*transfer\.appsrv\.(read\.[0-9]+|write\.[0-9]+|workAreaRoot)[[:space:]]*=' "$_w" | sed 's/^[[:space:]]*//')
    if [ -n "$_bad" ]; then
        fail "  $_w: WebUtil can reach the domain / Oracle home:$_bad"
    else
        ok "  $(printf '%s' "$_w" | sed "s#^$DH/##"): transfer.appsrv paths outside DOMAIN_HOME / ORACLE_HOME"
    fi
done < <(find "$DH/config/fmwconfig/components" -name webutil.cfg -type f 2>/dev/null)
[ "$_wfound" -eq 0 ] && info "  no webutil.cfg in the domain (no Forms)"
_rfound=0
while IFS= read -r _rc; do
    _rfound=1
    _rd="$(tr -d '\n' < "$_rc" | grep -o '<folderAccess>.*</folderAccess>' | grep -o '<read>[^<]*</read>' | sed 's#</\{0,1\}read>##g')"
    _bad=""; IFS=';' read -r -a _rds <<< "$_rd"
    for _p in "${_rds[@]}"; do _p="$(printf '%s' "$_p" | xargs)"; [ -n "$_p" ] && _covers "$_p" && _bad="$_bad $_p"; done
    _rn="${_rc#"$DH"/config/fmwconfig/}"; _rn="${_rn%/rwserver.conf}"
    if [ -z "$_rd" ]; then
        info "  rwserver.conf $_rn: no <folderAccess><read> (Reports default)"
    elif [ -n "$_bad" ]; then
        fail "  rwserver.conf $_rn: folderAccess read covers the domain / Oracle home:$_bad"
    else
        ok "  rwserver.conf $_rn: folderAccess read = $_rd"
    fi
done < <(find "$DH/config/fmwconfig" -name rwserver.conf -type f 2>/dev/null)
[ "$_rfound" -eq 0 ] && info "  no rwserver.conf in the domain (no Reports)"

# =============================================================================
section "4. Admin interfaces – reachability"
# =============================================================================
_ngx=()
# IHW_TEST_NGINX_CONF (tests only): files instead of the Nginx configuration
for _f in ${IHW_TEST_NGINX_CONF:-/etc/nginx/conf.d/*.conf /etc/nginx/oracle-wls.d/*.conf}; do [ -r "$_f" ] && _ngx+=("$_f"); done
if [ "${#_ngx[@]}" -eq 0 ]; then
    info "  no readable Nginx configuration (/etc/nginx/conf.d, oracle-wls.d) – web tier not checked"
else
    for _f in "${_ngx[@]}"; do
        # every location block on an admin path: needs "deny all" after an allow
        awk -v f="$_f" '
            /^[[:space:]]*location[[:space:]]/ { inloc=1; path=$0; depth=0; allow=""; deny=0 }
            inloc { n=gsub(/\{/, "{"); depth+=n; m=gsub(/\}/, "}"); depth-=m
                    if ($1 == "allow") { a=$2; sub(/;$/, "", a); allow=allow " " a }
                    if ($1 == "deny" && $2 ~ /^all;?$/) deny=1
                    if (depth <= 0 && (n > 0 || m > 0)) {
                        if (path ~ /\/(console|em|management|rconsole|consolehelp|wls-exporter)([[:space:];{\/]|$)/) {
                            p=path; sub(/^[[:space:]]*location[[:space:]]+/, "", p); sub(/[[:space:]]*\{.*/, "", p)
                            print f ";" p ";" (deny ? "deny" : "open") ";" allow }
                        inloc=0 } }' "$_f"
    done | while IFS=';' read -r _f _p _d _al; do
        if [ "$_d" != "deny" ] || printf ' %s ' "$_al" | grep -qE ' (all|0\.0\.0\.0/0|::/0) '; then
            _m="$(printf "  Nginx %s: location %s open for every client – admin login = code execution" "$(basename "$_f")" "$_p")"
            # ADMIN_IP_RANGE=any is a documented decision of 04-root_nginx.sh (no admin network)
            if [ "${ADMIN_IP_RANGE:-}" = "any" ]; then warn "$_m (ADMIN_IP_RANGE=any – decided; then the WebLogic login is the only barrier)"
            else fail "$_m"; fi
        else
            ok "  Nginx $(basename "$_f"): location $_p only from$_al"
        fi
    done
    if grep -hE '^[[:space:]]*location[^{]*/management' "${_ngx[@]}" >/dev/null 2>&1; then
        info "  /management (REST deployments) is proxied – see the rows above"
    else
        ok "  /management (WebLogic REST, deployments possible) not proxied by Nginx"
    fi
fi
_aport="${WLS_ADMIN_PORT:-7001}"
_nmport="$(sed -n 's/^ListenPort=//p' "$DH/nodemanager/nodemanager.properties" 2>/dev/null | head -1)"
for _pp in "AdminServer:$_aport" "Node Manager:${_nmport:-5556}"; do
    _n="${_pp%%:*}"; _p="${_pp##*:}"
    _addrs="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ":${_p}\$" | sed "s/:${_p}\$//" | sort -u | paste -sd' ' -)"
    if [ -z "$_addrs" ]; then
        info "  $_n port $_p: not listening (server down?)"
    elif printf '%s\n' $_addrs | grep -qvE '^(127\.[0-9.]+|\[::1\]|::1|\[::ffff:127\.[0-9.]+\])$'; then
        warn "  $_n port $_p listens on $_addrs – reachable past Nginx (entry point of CVE-2020-14882-type attacks): listen address 127.0.0.1"
    else
        ok "  $_n port $_p on loopback only ($_addrs)"
    fi
done

# =============================================================================
section "5. Account lockout / admin user"
# =============================================================================
# config.xml writes the realm elements with the prefix "sec:" (14.1.2)
_ulm="$(tr -d '\n' < "$DH/config/config.xml" | grep -oE '<(sec:)?user-lockout-manager>.*</(sec:)?user-lockout-manager>' | head -1 | sed 's#<\(/\{0,1\}\)sec:#<\1#g')"
if [ -z "$_ulm" ]; then
    info "  no <user-lockout-manager> in config.xml = WebLogic defaults (lockout on, 5 failed logins, 30 min, reset after 5 min)"
elif printf '%s' "$_ulm" | grep -q '<lockout-enabled>false</lockout-enabled>'; then
    fail "  account lockout DISABLED (config.xml <lockout-enabled>false</lockout-enabled>) – unlimited password guessing"
else
    _th="$(printf '%s' "$_ulm" | grep -o '<lockout-threshold>[0-9]*' | grep -o '[0-9]*$')"
    _m="$(printf "  account lockout on (threshold %s)" "${_th:-5 (default)}")"
    if [ -n "$_th" ] && [ "$_th" -gt 10 ]; then warn "$_m – more than 10 attempts"; else ok "$_m"; fi
fi
case "${WLS_ADMIN_USER:-}" in
    weblogic|admin|system) info "  admin user name '${WLS_ADMIN_USER}' – the first name every attacker tries (recommendation: an own name)" ;;
    "") info "  WLS_ADMIN_USER not set in environment.conf" ;;
    *) ok "  admin user name is not a default name" ;;
esac

# =============================================================================
section "6. Blast radius of the domain owner"
# =============================================================================
info "  Code execution in any WebLogic JVM runs as ${OWNER:-?} – everything below belongs to it."
_grp=" $(id -nG "${OWNER:-x}" 2>/dev/null) "
case "$_grp" in *" wheel "*|*" sudo "*|*" admin "*) warn "  ${OWNER} is in an admin group ($(printf '%s' "$_grp" | grep -owE 'wheel|sudo|admin' | paste -sd, -)) – root via sudo is one step away" ;; esac
if [ "$(id -un)" = "$OWNER" ]; then
    _sl="$(sudo -n -l 2>/dev/null)"
    if printf '%s' "$_sl" | grep -q 'NOPASSWD'; then
        warn "  ${OWNER} has sudo rules WITHOUT password ($(printf '%s\n' "$_sl" | grep -m2 'NOPASSWD' | sed 's/^[[:space:]]*//' | paste -sd'|' -)) – RCE in WebLogic = root (lab host acceptable, production never)"
    elif sudo -n true 2>/dev/null; then
        warn "  ${OWNER} can run sudo without a password – RCE in WebLogic = root"
    else
        ok "  no password-less sudo for ${OWNER}"
    fi
fi
_db=false; { pgrep -f '^ora_pmon_' >/dev/null 2>&1 || [ "${LOCAL_REP_DB:-false}" = "true" ]; } && _db=true
case "$_grp" in
    *" dba "*|*" oper "*|*" backupdba "*)
        if $_db; then
            warn "  ${OWNER} is in the DB groups ($(printf '%s' "$_grp" | grep -owE 'dba|oper|backupdba|dgdba|kmdba|racdba' | paste -sd, -)) and a database runs on this host – RCE in WebLogic = sqlplus / as sysdba (production: own OS user for the DB)"
        else
            info "  ${OWNER} is in DB groups, no database on this host"
        fi ;;
    *) ok "  ${OWNER} not in DB OS groups" ;;
esac
_doms="$( { sed -n 's/^[^#=]*=//p' "$DH/nodemanager/nodemanager.domains" 2>/dev/null
            sed -n 's/.*location="\([^"]*\)".*/\1/p' "$OH/domain-registry.xml" 2>/dev/null
            for _s in "$(dirname "$DH")"/*/; do [ -f "$_s/config/config.xml" ] && printf '%s\n' "${_s%/}"; done; } \
          | xargs -n1 readlink -f 2>/dev/null | sort -u | grep -vx "$(readlink -f "$DH")" | paste -sd' ' -)"
if [ -n "$_doms" ]; then
    warn "  further domains of the same owner: $_doms – one RCE reaches all of them (UAT next to PROD: separate users / hosts)"
else
    ok "  no further WebLogic domain of this owner found"
fi
_copies="$(timeout 120 find "${ORACLE_BASE:-$(dirname "$(dirname "$DH")")}" "$(dirname "$DH")" -xdev -maxdepth 9 -name SerializedSystemIni.dat -type f 2>/dev/null \
           | sort -u | grep -vx "$KEY" | paste -sd' ' -)"
if [ -n "$_copies" ]; then
    warn "  further copies of a domain key: $_copies – a backup / old domain copy holds key + {AES} values = passwords"
else
    ok "  no copy of the domain key outside $DH/security (below ${ORACLE_BASE:-the domain parent})"
fi

# =============================================================================
section "7. DISA STIG items (WebLogic 12c V2R2, transferable to 14.1.2)"
# =============================================================================
# 80-FMW-Architecture/stig_weblogic_forms_reports.md - read-only, recommendations
_cx="$(tr -d '\n' < "$DH/config/config.xml")"
# V-235966-70 password rule of the domain (SystemPasswordValidator)
_pv="$(printf '%s' "$_cx" | grep -o '<sec:password-validator.*</sec:password-validator>' | head -1)"
_pmin="$(printf '%s' "$_pv" | grep -o 'min-password-length>[0-9]*' | grep -o '[0-9]*$' | head -1)"
_pnum="$(printf '%s' "$_pv" | grep -o 'min-numeric-or-special-characters>[0-9]*\|min-numeric-characters>[0-9]*' | grep -o '[0-9]*$' | head -1)"
_pup="$(printf '%s' "$_pv" | grep -o 'min-uppercase-characters>[0-9]*' | grep -o '[0-9]*$' | head -1)"
_m="$(printf "  password rule of the domain: min length %s, digits/special %s, upper case %s (STIG: 15 / 1 / 1, plus lower case + special)" "${_pmin:-?}" "${_pnum:-0}" "${_pup:-0}")"
if [ -z "$_pv" ]; then
    warn "  no SystemPasswordValidator in config.xml – no password rule for WebLogic users"
elif [ "${_pmin:-0}" -lt 12 ]; then
    warn "$_m – admin, RepRunner and the Reports users may get short passwords (V-235966)"
else
    ok "$_m"
fi
# V-235936-38 lockout values of the STIG (section 5 rates on / off)
_lt="$(printf '%s' "$_cx" | grep -oE '<(sec:)?lockout-threshold>[0-9]*' | grep -o '[0-9]*$' | head -1)"
_ld="$(printf '%s' "$_cx" | grep -oE '<(sec:)?lockout-duration>[0-9]*' | grep -o '[0-9]*$' | head -1)"
_lr="$(printf '%s' "$_cx" | grep -oE '<(sec:)?lockout-reset-duration>[0-9]*' | grep -o '[0-9]*$' | head -1)"
_m="$(printf "  lockout %s / %s / %s (threshold / duration / reset; STIG 3 / 15 / 15 – library 3 / 30 / 15: Oracle warns below 30 min, BEA-090978)" "${_lt:-5}" "${_ld:-30}" "${_lr:-5}")"
if [ "${_lt:-5}" -le 3 ] && [ "${_lr:-5}" -ge 15 ]; then ok "$_m"
else info "$_m – 07-Maintenance/wls_lockout_config.sh; mind the service users RepRunner / monUser (a guessed login locks them)"; fi
# V-235933/34 configuration audit + auditing provider
_cat="$(printf '%s' "$_cx" | grep -o '<configuration-audit-type>[^<]*' | sed 's/.*>//' | head -1)"
_aud="$(printf '%s' "$_cx" | grep -o '<sec:auditor' | head -1)"
case "${_cat:-none}" in
    logaudit) ok "  configuration audit: Change Log and Audit (logaudit)" ;;
    log|audit) info "  configuration audit: ${_cat} (STIG: logaudit = Change Log and Audit)" ;;
    *) warn "  configuration audit off (no <configuration-audit-type>) – admin changes / deployments leave no trail (V-235933)" ;;
esac
[ -n "$_aud" ] && ok "  auditing provider configured in the realm" \
    || info "  no auditing provider in the realm (STIG: at least one, e.g. DefaultAuditor – needed for configuration audit 'audit' / 'logaudit')"
# V-235931/35/39 OPSS audit policy
# the audit service instance of the default jpsContext counts (14.1.2: "audit.db";
# the file-based "audit" instance keeps its own, unused value)
_jc="$DH/config/fmwconfig/jps-config.xml"
_ai="$(tr -d '\n' < "$_jc" 2>/dev/null | grep -o '<jpsContext name="default">.*' | sed 's#</jpsContext>.*##' | grep -o 'serviceInstanceRef ref="audit[^"]*"' | head -1 | sed 's/.*ref="//; s/"$//')"
_fp="$(tr -d '\n' < "$_jc" 2>/dev/null | grep -o "<serviceInstance name=\"${_ai:-audit}\"[^>]*>.*" | sed 's#</serviceInstance>.*##' | grep -o 'name="audit.filterPreset" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"$//')"
if [ -z "$_fp" ]; then
    info "  OPSS audit: no audit.filterPreset in jps-config.xml"
elif [ "$_fp" = "None" ]; then
    warn "  OPSS audit filterPreset=None – no OPSS security events (logins, policy / credential changes) are recorded (V-235931)"
else
    ok "  OPSS audit filterPreset=$_fp (service instance ${_ai:-audit})"
fi
# V-235983 no applications on the AdminServer except the FMW infrastructure
_infra='^(em|opss-rest|DMS Application.*|state-management-provider.*|coherence-transaction-rar|wsm-pm|FMW Welcome Page Application.*|fmw-welcome.*|mds-.*|owsm-.*|jms-.*|wls-.*|bea_wls.*|ORDS.*-rest|sdpmessaging.*|usermessagingserver.*)$'
_adm="$(printf '%s' "$_cx" | grep -o '<app-deployment>.*</app-deployment>' | sed 's#</app-deployment>#&\n#g' \
        | sed -n 's#.*<name>\([^<]*\)</name>.*<target>\([^<]*\)</target>.*#\1|\2#p' \
        | awk -F'|' '("," $2 ",") ~ /,AdminServer,/ {print $1}' | grep -vE "$_infra" | paste -sd, -)"
if [ -n "$_adm" ]; then
    warn "  applications on the AdminServer besides the FMW infrastructure: $_adm – management and application in one JVM (V-235983)"
else
    ok "  only FMW infrastructure on the AdminServer (EM, OPSS REST, DMS, adapters); Forms / Reports on the managed servers"
fi
# Overview 2.1.2 umask 027 of the installation user
_um="$(grep -hE '^[[:space:]]*umask[[:space:]]+[0-7]+' "$(getent passwd "${OWNER:-x}" | cut -d: -f6)/.bash_profile" 2>/dev/null | tail -1 | awk '{print $2}')"
if [ -z "$_um" ]; then
    info "  no umask in ~${OWNER}/.bash_profile (system default; the WebLogic start scripts set 027 themselves)"
elif [ "$(( 8#$_um & 8#007 ))" -eq 7 ]; then
    ok "  umask $_um in ~${OWNER}/.bash_profile"
else
    info "  umask $_um in ~${OWNER}/.bash_profile – files of our scripts are world-readable (STIG: 027; WebLogic writes the domain with 027 anyway – keep files Nginx must read, e.g. the Forms client bundle, readable)"
fi
info "  Deliberate deviation: STIG wants SSL-only listen ports on every server – here TLS ends at Nginx, WebLogic listens on 127.0.0.1 only (stig_weblogic_forms_reports.md)"

# =============================================================================
# --apply: chmod 600
# =============================================================================
if [ "${#TO_600[@]}" -gt 0 ]; then
    section "Modes 600 (key + boot.properties)"
    if $APPLY; then
        _ml="$DIAG_LOG_DIR"; [ -n "$_ml" ] || _ml="$ROOT_DIR/log/$(date +%Y%m%d)"
        mkdir -p "$_ml"; _mf="$_ml/domain_secret_modes_$(date +%H%M%S).txt"
        for _f in "${TO_600[@]}"; do printf '%s %s\n' "$(stat -c %a "$_f")" "$_f"; done > "$_mf"
        info "  old modes saved: $_mf (way back: while read m f; do chmod \$m \"\$f\"; done < file)"
        for _f in "${TO_600[@]}"; do
            chmod 600 "$_f" && ok "$(printf "  chmod 600 %s" "$_f")" || fail "$(printf "  chmod 600 failed: %s" "$_f")"
        done
        info "  Restart needed? No – only modes changed. The Node Manager rewrites data/nodemanager/boot.properties"
        info "  at the next start via the AdminServer and keeps the mode (600, test host 2026-11-18)"
    else
        info "$(printf "  %d file(s) would get mode 600 – run with --apply" "${#TO_600[@]}")"
    fi
fi

print_summary
exit "$EXIT_CODE"
