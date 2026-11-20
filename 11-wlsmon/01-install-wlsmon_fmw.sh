#!/bin/bash
# =============================================================================
# Script   : 01-install-wlsmon_fmw.sh
# Purpose  : wlsmon installation step 2 of 3 (FMW owner). Needs the wlsmon.conf
#            of 00-setup-interview.sh. Installs the runtime below $WLSMON_BASE:
#              bin/wlsmon.py, share/wlsmon_rules.cfg   program + default rules
#              www/ + www/ui.json                       GUI, /i/ library paths
#              etc/wlsmon_rules.local.cfg               skeleton, never overwritten
#              api/ hosts/ state/ log/                  data directories
#            and the WebLogic monitor user (group Monitors only) through the REST
#            API - one call at installation, never at runtime. The admin
#            password is used for that call only (library, or asked; memory only).
#            Checks the Reports monUser and ends with wlsmon.py collect --check.
# Call     : ./11-wlsmon/01-install-wlsmon_fmw.sh                 (dry-run)
#            ./11-wlsmon/01-install-wlsmon_fmw.sh --apply
#            ./11-wlsmon/01-install-wlsmon_fmw.sh --reset-monitor-password --apply
#            ./11-wlsmon/01-install-wlsmon_fmw.sh --remove [--apply]
# Options  : --apply                   install / create the monitor user
#            --reset-monitor-password  set the WebLogic password of the monitor
#                                      user to the wls_monitor secret again
#            --no-user                 skip the monitor user (tests, GUI role)
#            --remove                  remove bin/ share/ www/ api/ hosts/ state/
#                                      log/ - etc/ is kept, the monitor user is
#                                      only listed (the domain stays untouched)
#            --base DIR                WLSMON_BASE (default from wlsmon.conf search)
#            --help
# Runs as  : FMW owner (oracle), never root
# Ref      : 11-wlsmon/docs/01-wlsmon_concept.md §9.2, docs/03-wlsmon_development.md step 10,
#            80-FMW-Architecture/weblogic_rest_monitoring.md §5
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
WLSMON_PY="$SCRIPT_DIR/wlsmon.py"

HAVE_LIB=false
if [ -f "$LIB_SH" ]; then
    # shellcheck source=../00-Setup/IHateWeblogic_lib.sh
    source "$LIB_SH"
    HAVE_LIB=true
else
    CNT_OK=0; CNT_WARN=0; CNT_FAIL=0
    ok()      { CNT_OK=$((CNT_OK + 1));     printf "\033[32m  OK\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
    warn()    { CNT_WARN=$((CNT_WARN + 1)); printf "\033[33mWARN\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
    fail()    { CNT_FAIL=$((CNT_FAIL + 1)); printf "\033[31mFAIL\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
    info()    { printf "\033[34mINFO\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
    section() { printf "\n\033[1m=== %s ===\033[0m\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
    print_summary() {
        printf "\n  OK: %d  WARN: %d  FAIL: %d\n" "$CNT_OK" "$CNT_WARN" "$CNT_FAIL" | tee -a "${LOG_FILE:-/dev/null}"
        EXIT_CODE=0; [ "$CNT_WARN" -gt 0 ] && EXIT_CODE=1; [ "$CNT_FAIL" -gt 0 ] && EXIT_CODE=2
    }
fi

# =============================================================================
# Arguments
# =============================================================================
APPLY=false
REMOVE=false
RESET_PW=false
NO_USER=false
BASE_ARG=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply)   APPLY=true ;;
        --remove)  REMOVE=true ;;
        --reset-monitor-password) RESET_PW=true ;;
        --no-user) NO_USER=true ;;
        --base)    BASE_ARG="${2:-}"; shift ;;
        --help|-h)
            printf "Usage: %s [--apply] [--reset-monitor-password] [--no-user] [--remove] [--base DIR]\n\n" "$(basename "$0")"
            printf "  %-26s %s\n" "(none)"   "Dry-run: show what would be installed / created"
            printf "  %-26s %s\n" "--apply"  "Install below WLSMON_BASE, create the monitor user"
            printf "  %-26s %s\n" "--reset-monitor-password" "WebLogic password of the monitor user = wls_monitor secret"
            printf "  %-26s %s\n" "--no-user" "Skip the monitor user"
            printf "  %-26s %s\n" "--remove" "Remove the runtime (etc/ kept, monitor user only listed)"
            printf "\nBefore: 00-setup-interview.sh --apply   After: sudo 02-install-wlsmon_root.sh --apply\n"
            exit 0 ;;
        *) printf "Unknown argument: %s (--help)\n" "$1" >&2; exit 2 ;;
    esac
    shift
done

LOG_FILE="/dev/null"
if mkdir -p "$ROOT_DIR/log/$(date +%Y%m%d)" 2>/dev/null; then
    LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/wlsmon_install_fmw_$(date +%H%M%S).log"
fi
printf "\n\033[1m  wlsmon – install, FMW owner part (step 2 of 3)\033[0m\n" | tee -a "$LOG_FILE"
printf "  Apply: %s  Remove: %s  Reset monitor password: %s\n" "$APPLY" "$REMOVE" "$RESET_PW" | tee -a "$LOG_FILE"

# =============================================================================
# Configuration
# =============================================================================
section "Configuration"
if [ "$(id -u)" -eq 0 ]; then
    fail "Runs as the FMW owner, not as root"
    print_summary; exit "${EXIT_CODE:-2}"
fi

BASE="${BASE_ARG:-}"
if [ -z "$BASE" ]; then
    _ob="${ORACLE_BASE:-}"
    if [ -z "$_ob" ] && [ -f "$ROOT_DIR/environment.conf" ]; then
        _ob="$(sed -n 's/^ORACLE_BASE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT_DIR/environment.conf" | head -1)"
    fi
    BASE="${_ob:-/u01/app/oracle}/admin/wlsmon"
fi
CONF="$BASE/etc/wlsmon.conf"
if [ ! -f "$CONF" ]; then
    fail "No $CONF – run first: ./11-wlsmon/00-setup-interview.sh --apply"
    print_summary; exit "${EXIT_CODE:-2}"
fi
declare -A C
while IFS= read -r _line; do
    [[ "$_line" =~ ^(WLSMON_[A-Z0-9_]+)=(.*)$ ]] && C[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
done < "$CONF"
ROLE="${C[WLSMON_ROLE]:-both}"
ok "$(printf "  %-20s %s" "WLSMON_BASE:" "$BASE")"
ok "$(printf "  %-20s %s" "role:" "$ROLE")"
[ "$ROLE" = "gui" ] && NO_USER=true

# =============================================================================
# Remove
# =============================================================================
if $REMOVE; then
    section "Remove"
    for _d in bin share www api hosts state log; do
        [ -e "$BASE/$_d" ] || continue
        if $APPLY; then
            rm -rf "${BASE:?}/$_d" && ok "removed $BASE/$_d"
        else
            info "would remove $BASE/$_d"
        fi
    done
    info "kept: $BASE/etc (wlsmon.conf, local rules, secrets) – remove by hand when wlsmon is gone for good"
    if [ "$ROLE" != "gui" ]; then
        info "WebLogic user ${C[WLSMON_MON_USER]:-wlsmon_monitor} is NOT removed (domain untouched) – remove it in the console if wanted"
    fi
    info "root part first / as well: sudo ./11-wlsmon/02-install-wlsmon_root.sh --remove --apply"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Program, rules, GUI
# =============================================================================
section "Program, rules, GUI"

# _sync SRC DST MODE - copy when different; report
_sync() {
    local src="$1" dst="$2" m="$3"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        ok "$(printf "  %-34s unchanged" "${dst#"$BASE"/}")"
        return 0
    fi
    if ! $APPLY; then
        info "$(printf "  %-34s would be %s" "${dst#"$BASE"/}" "$([ -f "$dst" ] && printf updated || printf installed)")"
        return 0
    fi
    # umask 027: new parent dirs come out 750 (+ setgid inherited) - no chmod needed later
    ( umask 027; install -D -m "$m" "$src" "$dst" ) && ok "$(printf "  %-34s installed" "${dst#"$BASE"/}")"
}

# _dirmode DIR MODE - chmod only when the permission bits differ, ignoring setgid.
# Linux clears setgid on EVERY chmod by an owner who is not in the file's group
# (here: an oracle login older than the usermod -aG wlsmon of 02) - an
# unconditional chmod 750 removed the 2750 of 02 and nginx got 403 (2026-11-20).
_dirmode() {
    local d="$1" m="$2" cur
    cur="$(stat -c %a "$d" 2>/dev/null)" || return 0
    [ "${cur: -3}" = "$m" ] || chmod "$m" "$d"
}

if $APPLY; then
    mkdir -p "$BASE"/{bin,share,www,api,hosts,state,log} || { fail "Cannot create the directories below $BASE"; print_summary; exit "${EXIT_CODE:-2}"; }
    for _d in bin share state log; do _dirmode "$BASE/$_d" 700; done
    for _d in www api hosts; do _dirmode "$BASE/$_d" 750; done   # 02-install: group wlsmon + setgid (2750)
fi
_sync "$WLSMON_PY" "$BASE/bin/wlsmon.py" 700
_sync "$SCRIPT_DIR/rules/wlsmon_rules.cfg" "$BASE/share/wlsmon_rules.cfg" 600
while IFS= read -r -d '' _f; do
    _rel="${_f#"$SCRIPT_DIR/www/"}"
    [ "$_rel" = "ui.json" ] && continue
    _sync "$_f" "$BASE/www/$_rel" 640
done < <(find "$SCRIPT_DIR/www" -type f -print0 | sort -z)
if $APPLY; then
    while IFS= read -r -d '' _d; do _dirmode "$_d" 750; done < <(find "$BASE/www" -type d -print0)
    # files of www/ / api/ / hosts/ must carry group wlsmon (nginx reads via the group)
    _bad="$(find "$BASE/www" "$BASE/api" "$BASE/hosts" ! -group wlsmon -print -quit 2>/dev/null)"
    if getent group wlsmon >/dev/null 2>&1 && [ -n "$_bad" ]; then
        warn "Not group wlsmon: ${_bad#"$BASE"/} (setgid lost?) - nginx answers 403; run 02-install-wlsmon_root.sh --apply"
    fi
fi

# ui.json: locale + the /i/ libraries of this host (newest versions, wlsmon.py detect)
UI_TMP="$(mktemp)"
trap 'rm -f "$UI_TMP"' EXIT
python3 -I "$WLSMON_PY" detect --oracle-home "${C[WLSMON_ORACLE_HOME]:-/u01/app/oracle/fmw}" \
        --apex "${C[WLSMON_APEX_DIR]:-/srv/apex/apex_1}" 2>/dev/null \
  | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
ui = {"locale": sys.argv[1] or "de-DE"}
if d.get("libs"):
    ui["libs"] = d["libs"]
print(json.dumps(ui, indent=1))' "${C[WLSMON_LOCALE]:-de-DE}" > "$UI_TMP"
if grep -q '"jet"' "$UI_TMP"; then
    ok "$(printf "  %-34s %s" "GUI libraries (/i/):" "$(python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))["libs"]; print(", ".join(v.split("/")[3]+" "+v.split("/")[4] for k,v in l.items() if k in ("jet","font_apex")))' "$UI_TMP")")"
    [ -n "$(grep '"knockout"' "$UI_TMP")" ] || warn "JET without its knockout module – charts fall back to SVG"
else
    warn "No APEX images directory with JET / font-apex at ${C[WLSMON_APEX_DIR]:-?} – the GUI uses its own SVG charts and icons"
fi
_sync "$UI_TMP" "$BASE/www/ui.json" 640

# local rules: skeleton once, never overwritten
LOCAL_RULES="$BASE/etc/wlsmon_rules.local.cfg"
if [ -f "$LOCAL_RULES" ]; then
    ok "$(printf "  %-34s kept (local rules)" "etc/wlsmon_rules.local.cfg")"
elif $APPLY; then
    ( umask 077; cat > "$LOCAL_RULES" <<'EOF'
# wlsmon_rules.local.cfg - local log rules of THIS host (never overwritten by an update)
# Same format as share/wlsmon_rules.cfg: type;id;level;source;regex;reason
# A rule with the id of a default rule replaces it. An ignore rule needs a reason.
# Test: wlsmon.py rules --test <logfile> --source wls,forms,reports
EOF
    ) && ok "$(printf "  %-34s created (skeleton)" "etc/wlsmon_rules.local.cfg")"
else
    info "$(printf "  %-34s would be created (skeleton)" "etc/wlsmon_rules.local.cfg")"
fi

# =============================================================================
# WebLogic monitor user (REST, one call at installation)
# =============================================================================
ADMIN_USER=""
ADMIN_PWD=""
_admin_secret() {
    [ -n "$ADMIN_PWD" ] && return 0
    if $HAVE_LIB && [ -f "$ROOT_DIR/weblogic_sec.conf.des3" ]; then
        load_weblogic_password "$ROOT_DIR/weblogic_sec.conf.des3" > /dev/null 2>&1 \
            && { ADMIN_USER="${WL_USER:-}"; ADMIN_PWD="${INTERNAL_WL_PWD:-}"; INTERNAL_WL_PWD=""; }
    fi
    if [ -z "$ADMIN_PWD" ] && [ -t 0 ]; then
        read -r -p "  WebLogic admin user: " ADMIN_USER
        read -r -s -p "  Password of $ADMIN_USER (memory only): " ADMIN_PWD; printf "\n"
    fi
    [ -n "$ADMIN_PWD" ]
}

_mon_call() {   # _mon_call check|create|reset -> JSON in MON_JSON, rc
    local pw=""
    [ -s "$BASE/etc/pending/wls_monitor" ] && pw="$(cat "$BASE/etc/pending/wls_monitor")"
    MON_JSON="$(printf 'admin_user=%s\nadmin_password=%s\nwls_monitor=%s\n' "$ADMIN_USER" "$ADMIN_PWD" "$pw" \
                | WLSMON_BASE="$BASE" python3 -I "$WLSMON_PY" monitor-user "$1" --secrets-stdin)"
    local rc=$?
    pw=""
    return $rc
}
_mj() { printf '%s' "$MON_JSON" | python3 -I -c "import json,sys; v=json.load(sys.stdin).get('$1'); print('' if v is None else v)"; }

MON_OK=false     # the monitor password is passed to the check only for a verified user
if ! $NO_USER; then
    section "WebLogic monitor user"
    MON="${C[WLSMON_MON_USER]:-wlsmon_monitor}"
    if ! _admin_secret; then
        warn "No admin password (library weblogic_sec.conf.des3 or input) – monitor user not checked"
    else
        _mon_call check
        if [ -n "$(_mj error)" ]; then
            fail "$(printf "  %-20s %s" "REST:" "$(_mj error)")"
        elif [ "$(_mj exists)" != "True" ]; then
            if [ ! -s "$BASE/etc/pending/wls_monitor" ]; then
                fail "User $MON missing and no pending/wls_monitor – run: 00-setup-interview.sh --secret wls_monitor --apply"
            elif $APPLY; then
                if _mon_call create; then
                    ok "$(printf "  %-20s %s created, group %s" "monitor user:" "$MON" "$(_mj groups)")"
                    [ "$(_mj login)" = "200" ] && MON_OK=true
                else
                    fail "$(printf "  %-20s %s" "createUser:" "$(_mj error)$(_mj reason)")"
                fi
            else
                info "$(printf "  %-20s %s would be created (group Monitors)" "monitor user:" "$MON")"
            fi
        else
            ok "$(printf "  %-20s %s exists, groups %s" "monitor user:" "$MON" "$(_mj groups)")"
            [ "$(_mj only_monitors)" = "True" ] || warn "$MON is not only in Monitors – the monitor needs read rights only"
            case "$(_mj login)" in
                200) ok "$(printf "  %-20s works with the wls_monitor secret" "login:")"; MON_OK=true ;;
                "")  info "No pending/wls_monitor (already encrypted) – login is tested by the service (02-install)" ;;
                401) if $RESET_PW && $APPLY; then
                         if _mon_call reset; then
                             ok "password of $MON reset to the wls_monitor secret"; MON_OK=true
                         else
                             fail "resetUserPassword: $(_mj error)$(_mj reason)"
                         fi
                     else
                         warn "login of $MON refused (HTTP 401) – password differs: --reset-monitor-password --apply"
                     fi ;;
                *)   warn "login test of $MON: HTTP $(_mj login)" ;;
            esac
        fi
    fi
    ADMIN_PWD=""
fi

# =============================================================================
# Check
# =============================================================================
section "Check"
if $APPLY && [ -f "$BASE/bin/wlsmon.py" ]; then
    _pw_mon=""; _pw_rep=""; _pw_db=""
    # monitor password only for a verified user - no login attempts with a user that is not there
    $MON_OK && [ -s "$BASE/etc/pending/wls_monitor" ] && _pw_mon="$(cat "$BASE/etc/pending/wls_monitor")"
    $MON_OK || info "WebLogic REST is skipped in the check (monitor user not verified in this run)"
    [ -s "$BASE/etc/pending/reports_mon" ] && _pw_rep="$(cat "$BASE/etc/pending/reports_mon")"
    [ -s "$BASE/etc/pending/db_monitor" ] && _pw_db="$(cat "$BASE/etc/pending/db_monitor")"
    _out="$(printf 'wls_monitor=%s\nreports_mon=%s\ndb_monitor=%s\n' "$_pw_mon" "$_pw_rep" "$_pw_db" \
            | WLSMON_BASE="$BASE" python3 -I "$BASE/bin/wlsmon.py" collect --check --secrets-stdin 2>&1)"
    _pw_mon=""; _pw_rep=""; _pw_db=""
    printf '%s\n' "$_out" | sed 's/^/    /' | tee -a "$LOG_FILE"
    if printf '%s' "$_out" | grep -q "overall"; then
        ok "wlsmon.py collect --check ran (values above; files in a temporary directory)"
    else
        fail "wlsmon.py collect --check failed"
    fi
else
    info "collect --check runs after --apply"
fi

section "Next"
info "sudo ./11-wlsmon/02-install-wlsmon_root.sh --apply   (systemd, nginx, credentials, timers)"
print_summary
exit "$EXIT_CODE"
