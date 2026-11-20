#!/bin/bash
# =============================================================================
# Script   : 02-install-wlsmon_root.sh
# Purpose  : wlsmon installation step 3 of 3 (root). Needs 00-setup-interview.sh
#            and 01-install-wlsmon_fmw.sh before. Does everything that needs root:
#              group wlsmon (nginx + FMW owner), setgid www/ api/ hosts/
#              traverse ACLs for nginx on the parents of WLSMON_BASE (if needed)
#              read ACL for the FMW owner on the nginx logs (requests, 5xx, errors)
#              SELinux context httpd_sys_content_t (only when SELinux is on)
#              etc/pending/* -> etc/creds/*.cred (systemd-creds, host bound),
#                               the clear text is deleted; htpasswd files to
#                               /etc/nginx/wlsmon/ (root:nginx 640)
#              nginx include + headers + limit zone from the templates,
#                               nginx -t (rollback on error) + reload
#              systemd units + timers, first run, local access test
#            Without --apply: shows every change (diffs of the rendered files).
# Call     : sudo ./11-wlsmon/02-install-wlsmon_root.sh                (dry-run)
#            sudo ./11-wlsmon/02-install-wlsmon_root.sh --apply
#            sudo ./11-wlsmon/02-install-wlsmon_root.sh --remove [--apply]
# Options  : --apply          make the changes
#            --remove         timers, units, nginx files, htpasswd, credentials,
#                             group, ACLs, SELinux context (reverse order; then
#                             01-install-wlsmon_fmw.sh --remove)
#            --base DIR       WLSMON_BASE (default $ORACLE_BASE/admin/wlsmon)
#            --no-start       install, but do not enable the timers / first run
#            --test-root DIR  TESTS ONLY: /etc and /var/log below DIR; the root
#                             commands come from a fake PATH (tests/)
#            --help
# Runs as  : root, or the FMW owner with sudo
# Ref      : 11-wlsmon/docs/01-wlsmon_concept.md §3b, §5, §6, §9,
#            docs/04-wlsmon_operations.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
TPL_DIR="$SCRIPT_DIR/templates"
RENDER="$SCRIPT_DIR/tools/render_template.py"

if [ -f "$LIB_SH" ]; then
    # shellcheck source=../00-Setup/IHateWeblogic_lib.sh
    source "$LIB_SH"
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
NO_START=false
BASE_ARG=""
TEST_ROOT=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply)     APPLY=true ;;
        --remove)    REMOVE=true ;;
        --no-start)  NO_START=true ;;
        --base)      BASE_ARG="${2:-}"; shift ;;
        --test-root) TEST_ROOT="${2:-}"; shift ;;
        --help|-h)
            printf "Usage: %s [--apply] [--remove] [--no-start] [--base DIR]\n\n" "$(basename "$0")"
            printf "  %-14s %s\n" "(none)"     "Dry-run: show every change, diffs of the rendered files"
            printf "  %-14s %s\n" "--apply"    "Group, ACLs, credentials, nginx, systemd, first run"
            printf "  %-14s %s\n" "--remove"   "Remove all of it (then 01-install-wlsmon_fmw.sh --remove)"
            printf "  %-14s %s\n" "--no-start" "Install without enabling the timers / first run"
            printf "\nBefore: 00-setup-interview.sh --apply, 01-install-wlsmon_fmw.sh --apply (as the FMW owner)\n"
            exit 0 ;;
        *) printf "Unknown argument: %s (--help)\n" "$1" >&2; exit 2 ;;
    esac
    shift
done

if [ -n "$TEST_ROOT" ]; then
    case "$TEST_ROOT" in /|/etc*|/usr*|/var*) printf "--test-root must be a test directory\n" >&2; exit 2 ;; esac
    [ -z "$BASE_ARG" ] && { printf "--test-root needs --base\n" >&2; exit 2; }
    mkdir -p "$TEST_ROOT/etc/nginx/conf.d" "$TEST_ROOT/etc/nginx/oracle-wls.d" "$TEST_ROOT/etc/systemd/system" || exit 2
fi
T="$TEST_ROOT"
NGINX_DIR="$T/etc/nginx"
NGINX_WLSMON="$NGINX_DIR/wlsmon"
NGINX_INC="$NGINX_DIR/oracle-wls.d/wlsmon.conf"
NGINX_ZONE="$NGINX_DIR/conf.d/wlsmon_zone.conf"
UNIT_DIR="$T/etc/systemd/system"

LOG_FILE="/dev/null"
if mkdir -p "$ROOT_DIR/log/$(date +%Y%m%d)" 2>/dev/null; then
    LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/wlsmon_install_root_$(date +%H%M%S).log"
    : > "$LOG_FILE"
    # run as root: the log belongs to the owner of the repository, not to root
    [ "$(id -u)" -eq 0 ] && chown --reference="$ROOT_DIR" "$LOG_FILE" "$(dirname "$LOG_FILE")" 2>/dev/null
fi
printf "\n\033[1m  wlsmon – install, root part (step 3 of 3)\033[0m\n" | tee -a "$LOG_FILE"
printf "  Apply: %s  Remove: %s  No start: %s%s\n" "$APPLY" "$REMOVE" "$NO_START" \
    "${T:+  TEST ROOT: $T}" | tee -a "$LOG_FILE"

# =============================================================================
# Helpers
# =============================================================================
# _root CMD... - as root directly, otherwise with sudo -n (never asks)
_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}
# _do "text" CMD... - with --apply run (as root) and report, else only show
_do() {
    local text="$1"; shift
    if $APPLY; then
        if _root "$@" >> "$LOG_FILE" 2>&1; then
            ok "$text"
        else
            fail "$text – failed: $*"
            return 1
        fi
    else
        info "would: $text"
    fi
}
_render() {   # _render TEMPLATE OUT [--keep X ...] [--multi V ...] - with the values of VARS
    local tpl="$1" out="$2"; shift 2
    python3 -I "$RENDER" "$TPL_DIR/$tpl" --out "$out" "${VARS[@]}" "$@" >> "$LOG_FILE" 2>&1
}
# _install_file NEW TARGET MODE OWNER:GROUP "label" - diff, backup, install
CHANGED_NGINX=false
_install_file() {
    local new="$1" target="$2" mode="$3" own="$4" label="$5"
    if _root test -f "$target" && _root cmp -s "$new" "$target"; then
        ok "$(printf "  %-44s unchanged" "$label")"
        return 0
    fi
    if _root test -f "$target"; then
        info "$(printf "  %-44s changes:" "$label")"
        _root diff -u "$target" "$new" | sed -n '3,60p' | sed 's/^/      /' | tee -a "$LOG_FILE"
    else
        info "$(printf "  %-44s new" "$label")"
    fi
    $APPLY || return 0
    if _root test -f "$target"; then
        _root cp -p "$target" "$target.bak_$(date +%Y%m%d_%H%M%S)" || { fail "backup of $target"; return 1; }
        ROLLBACK+=("$target")
    else
        CREATED+=("$target")
    fi
    if _root install -m "$mode" -o "${own%%:*}" -g "${own##*:}" "$new" "$target"; then
        ok "$(printf "  %-44s installed" "$label")"
        case "$target" in "$NGINX_DIR"/*) CHANGED_NGINX=true ;; esac
    else
        fail "install $target"
        return 1
    fi
}
ROLLBACK=()
CREATED=()

# =============================================================================
# Pre-checks
# =============================================================================
section "Pre-checks"
if [ "$(id -u)" -eq 0 ]; then
    ok "$(printf "  %-20s %s" "user:" "root")"
elif sudo -n true 2>/dev/null; then
    ok "$(printf "  %-20s %s with sudo" "user:" "$(id -un)")"
else
    fail "Needs root or sudo without a password prompt (sudo ./11-wlsmon/02-install-wlsmon_root.sh)"
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
if ! _root test -f "$CONF"; then
    fail "No $CONF – as the FMW owner first: 00-setup-interview.sh --apply, 01-install-wlsmon_fmw.sh --apply"
    print_summary; exit "${EXIT_CODE:-2}"
fi
declare -A C
while IFS= read -r _line; do
    [[ "$_line" =~ ^(WLSMON_[A-Z0-9_]+)=(.*)$ ]] && C[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
done < <(_root cat "$CONF")
ROLE="${C[WLSMON_ROLE]:-both}"
OWNER="$(_root stat -c %U "$CONF")"
OGROUP="$(_root stat -c %G "$CONF")"
ok "$(printf "  %-20s %s" "WLSMON_BASE:" "$BASE")"
ok "$(printf "  %-20s %s" "role:" "$ROLE")"
ok "$(printf "  %-20s %s:%s (owner of wlsmon.conf)" "FMW owner:" "$OWNER" "$OGROUP")"
if [ "$OWNER" = "root" ]; then
    fail "wlsmon.conf belongs to root – the interview runs as the FMW owner"
    print_summary; exit "${EXIT_CODE:-2}"
fi
if ! $REMOVE && ! _root test -f "$BASE/bin/wlsmon.py"; then
    fail "No $BASE/bin/wlsmon.py – as $OWNER first: ./11-wlsmon/01-install-wlsmon_fmw.sh --apply"
    print_summary; exit "${EXIT_CODE:-2}"
fi
if [ "$ROLE" = "data" ] && [ -z "${C[WLSMON_GUI_IP]:-}" ]; then
    fail "Role data without WLSMON_GUI_IP (IP of the GUI host) – 00-setup-interview.sh --apply"
    print_summary; exit "${EXIT_CODE:-2}"
fi
if command -v nginx > /dev/null 2>&1 || [ -x /usr/sbin/nginx ]; then
    ok "$(printf "  %-20s %s" "nginx:" "installed")"
else
    fail "nginx not installed (09-Install/04-root_nginx.sh)"
    print_summary; exit "${EXIT_CODE:-2}"
fi
SD_VER="$(systemctl --version 2>/dev/null | sed -n '1s/^systemd \([0-9]*\).*/\1/p')"
CREDS=false
if [ "${SD_VER:-0}" -ge 250 ] && command -v systemd-creds > /dev/null 2>&1; then
    CREDS=true
    ok "$(printf "  %-20s systemd %s – secrets as encrypted credentials (host bound)" "credentials:" "$SD_VER")"
else
    warn "$(printf "  %-20s systemd %s without systemd-creds – secrets as files mode 400 (weaker, concept 3b)" "credentials:" "${SD_VER:-?}")"
fi
SELINUX="Disabled"
command -v getenforce > /dev/null 2>&1 && SELINUX="$(getenforce 2>/dev/null)"
[ -n "$T" ] && SELINUX="Disabled"

# which services this role needs
NEED_COLLECT=false; NEED_PULL=false
case "$ROLE" in data|both) NEED_COLLECT=true ;; esac
[ "$ROLE" != "data" ] && [ -n "${C[WLSMON_PULL_HOSTS]:-}" ] && NEED_PULL=true

# =============================================================================
# Remove
# =============================================================================
if $REMOVE; then
    section "Remove – systemd"
    for u in wlsmon-collect wlsmon-pull; do
        if _root test -f "$UNIT_DIR/$u.timer" || _root test -f "$UNIT_DIR/$u.service"; then
            [ -z "$T" ] && _do "stop + disable $u.timer" systemctl disable --now "$u.timer"
            _do "remove $u.service / .timer" rm -f "$UNIT_DIR/$u.service" "$UNIT_DIR/$u.timer"
        fi
    done
    [ -z "$T" ] && $APPLY && _root systemctl daemon-reload

    section "Remove – nginx"
    ACL_LIST="$NGINX_WLSMON/root_acl.list"
    ACLS=""
    _root test -f "$ACL_LIST" && ACLS="$(_root cat "$ACL_LIST")"
    for f in "$NGINX_INC" "$NGINX_ZONE"; do
        _root test -f "$f" && _do "remove $f" rm -f "$f"
    done
    _root test -d "$NGINX_WLSMON" && _do "remove $NGINX_WLSMON (headers, htpasswd)" rm -rf "$NGINX_WLSMON"
    if $APPLY && [ -z "$T" ]; then
        if _root nginx -t >> "$LOG_FILE" 2>&1; then
            _root systemctl reload nginx && ok "nginx -t + reload"
        else
            fail "nginx -t fails after the removal – check /etc/nginx (log)"
        fi
    fi

    section "Remove – credentials, ACLs, group"
    for f in $(_root sh -c "ls '$BASE/etc/creds/' 2>/dev/null"); do
        _do "remove etc/creds/$f" rm -f "$BASE/etc/creds/$f"
    done
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        _do "ACL removed: ${line#* } (${line%% *})" setfacl -x "${line%% *}" "${line#* }"
    done <<< "$ACLS"
    if [ "$SELINUX" != "Disabled" ]; then
        for d in www api hosts; do
            _do "SELinux context removed: $BASE/$d" semanage fcontext -d "$BASE/$d(/.*)?"
        done
    fi
    for d in www api hosts; do
        _root test -d "$BASE/$d" && _do "group of $d back to $OGROUP" chgrp -R "$OGROUP" "$BASE/$d"
    done
    _do "group of $BASE back to $OGROUP" chgrp "$OGROUP" "$BASE"
    if getent group wlsmon > /dev/null 2>&1; then
        _do "group wlsmon removed" groupdel wlsmon
    fi
    info "Next (as $OWNER): ./11-wlsmon/01-install-wlsmon_fmw.sh --remove --apply"
    $APPLY || info "Dry-run – nothing changed. Run with --remove --apply."
    print_summary
    exit "${EXIT_CODE:-0}"
fi

# =============================================================================
# 1. Group wlsmon and directories
# =============================================================================
section "Group and directories"
if getent group wlsmon > /dev/null 2>&1; then
    ok "$(printf "  %-20s exists" "group wlsmon:")"
else
    _do "group wlsmon created (system group)" groupadd -r wlsmon
fi
for m in nginx "$OWNER"; do
    if id -nG "$m" 2>/dev/null | tr ' ' '\n' | grep -qx wlsmon; then
        ok "$(printf "  %-20s %s is a member" "group wlsmon:" "$m")"
    else
        _do "$m added to the group wlsmon" usermod -aG wlsmon "$m"
    fi
done

# $BASE: owner:wlsmon 750 - nginx may enter, only www/ api/ hosts/ are readable
cur="$(_root stat -c '%G %a' "$BASE")"
if [ "$cur" = "wlsmon 750" ]; then
    ok "$(printf "  %-20s %s:wlsmon 750" "$BASE" "$OWNER")"
else
    _do "$BASE -> group wlsmon, 750 (was $cur)" sh -c "chgrp wlsmon '$BASE' && chmod 750 '$BASE'"
fi
for d in www api hosts; do
    _root test -d "$BASE/$d" || _do "$d/ created" install -d -m 2750 -o "$OWNER" -g wlsmon "$BASE/$d"
    cur="$(_root stat -c '%G %a' "$BASE/$d" 2>/dev/null)"
    bad="$(_root find "$BASE/$d" \( -type d \( ! -group wlsmon -o ! -perm 2750 \) \) -o \
           \( -type f \( ! -group wlsmon -o -perm /027 \) \) 2>/dev/null | head -1)"
    if [ "$cur" = "wlsmon 2750" ] && [ -z "$bad" ]; then
        ok "$(printf "  %-20s group wlsmon, setgid 2750, files 640" "$d/")"
    else
        _do "$d/ -> group wlsmon, dirs 2750 (setgid), files 640" sh -c \
            "chgrp -R wlsmon '$BASE/$d' && find '$BASE/$d' -type d -exec chmod 2750 {} + \
             && find '$BASE/$d' -type f -exec chmod 640 {} +"
    fi
done
for d in bin share etc state log; do
    _root test -d "$BASE/$d" || continue
    cur="$(_root stat -c '%a' "$BASE/$d")"
    [ "$cur" = "700" ] || _do "$d/ -> 700 (was $cur, FMW owner only)" chmod 700 "$BASE/$d"
done

# traverse right of nginx on every parent of $BASE (customer with 750 parents)
section "ACLs"
ACL_NEW=()
p="$(dirname "$BASE")"
while [ "$p" != "/" ] && [ -n "$p" ]; do
    if _root runuser -u nginx -- test -x "$p" 2>/dev/null; then
        :
    else
        _do "nginx may traverse $p (ACL u:nginx:x, no listing)" setfacl -m u:nginx:x "$p" \
            && ACL_NEW+=("u:nginx $p")
    fi
    p="$(dirname "$p")"
done
[ "${#ACL_NEW[@]}" -eq 0 ] && ok "$(printf "  %-20s nginx can traverse every parent of %s" "traverse:" "$BASE")"

# FMW owner reads the nginx logs (requests per minute, 4xx / 5xx, error.log).
# Default ACL on the directory: files logrotate creates inherit the right.
NGX_ACC="${C[WLSMON_NGINX_ACCESS_LOG]:-/var/log/nginx/access.log}"
NGX_ERR="${C[WLSMON_NGINX_ERROR_LOG]:-/var/log/nginx/error.log}"
NGX_LOGDIR="$T$(dirname "$NGX_ACC")"
if _root test -d "$NGX_LOGDIR"; then
    if _root runuser -u "$OWNER" -- test -r "$T$NGX_ACC" 2>/dev/null \
       && _root getfacl -p "$NGX_LOGDIR" 2>/dev/null | grep -q "^default:user:$OWNER:r"; then
        ok "$(printf "  %-20s %s reads %s (ACL, also after logrotate)" "nginx logs:" "$OWNER" "$NGX_LOGDIR")"
    else
        _do "$OWNER may read $NGX_LOGDIR (ACL u:$OWNER:rx + default u:$OWNER:r)" sh -c \
            "setfacl -m u:$OWNER:rx '$NGX_LOGDIR' && setfacl -d -m u:$OWNER:r '$NGX_LOGDIR' \
             && for f in '$T$NGX_ACC' '$T$NGX_ERR'; do [ -f \"\$f\" ] && setfacl -m u:$OWNER:r \"\$f\"; done; true" \
            && ACL_NEW+=("u:$OWNER $NGX_LOGDIR" "d:u:$OWNER $NGX_LOGDIR" "u:$OWNER $T$NGX_ACC" "u:$OWNER $T$NGX_ERR")
    fi
else
    warn "nginx log directory $NGX_LOGDIR missing – nginx figures stay n/a"
fi

# SELinux (our baseline disables it; a customer may run it enforcing)
if [ "$SELINUX" = "Disabled" ]; then
    ok "$(printf "  %-20s disabled – no context needed" "SELinux:")"
else
    for d in www api hosts; do
        _do "SELinux: httpd_sys_content_t on $BASE/$d" sh -c \
            "{ semanage fcontext -a -t httpd_sys_content_t '$BASE/$d(/.*)?' 2>/dev/null \
               || semanage fcontext -m -t httpd_sys_content_t '$BASE/$d(/.*)?'; } && restorecon -R '$BASE/$d'"
    done
fi

# =============================================================================
# 2. Secrets: pending -> credentials, htpasswd
# =============================================================================
section "Secrets"
PEND="$BASE/etc/pending"
CRED_DIR="$BASE/etc/creds"
_root test -d "$CRED_DIR" || _do "etc/creds/ created (700)" install -d -m 700 -o "$OWNER" -g "$OGROUP" "$CRED_DIR"

declare -A HAVE_CRED
_cred() {   # _cred NAME - pending -> .cred (or OL8 file 400), clear text deleted
    local n="$1" target
    if $CREDS; then target="$CRED_DIR/$n.cred"; else target="$CRED_DIR/$n"; fi
    if _root test -s "$PEND/$n"; then
        if $CREDS; then
            _do "$n -> etc/creds/$n.cred (encrypted, host bound), clear text deleted" sh -c \
                "systemd-creds encrypt --name='$n' '$PEND/$n' '$target' && chown root:root '$target' \
                 && chmod 400 '$target' && rm -f '$PEND/$n'" && HAVE_CRED[$n]=1
        else
            _do "$n -> etc/creds/$n (mode 400, $OWNER – weaker variant)" sh -c \
                "install -m 400 -o '$OWNER' -g '$OGROUP' '$PEND/$n' '$target' && rm -f '$PEND/$n'" && HAVE_CRED[$n]=1
        fi
    elif _root test -s "$target"; then
        ok "$(printf "  %-14s %s" "$n" "present (etc/creds)")"
        HAVE_CRED[$n]=1
    else
        return 1
    fi
}
if $NEED_COLLECT; then
    _cred wls_monitor || warn "wls_monitor missing – WebLogic figures n/a (00-setup-interview.sh --secret wls_monitor --apply)"
    _cred reports_mon || warn "reports_mon missing – Reports figures n/a (00-setup-interview.sh --secret reports_mon --apply)"
    if [ "${C[WLSMON_RCU_CHECK]:-false}" = "true" ]; then
        _cred db_monitor || warn "db_monitor missing – the RCU check reports 'not checked'"
    fi
fi
if $NEED_PULL; then
    _cred pull_user || fail "pull_user missing – the GUI host cannot pull (00-setup-interview.sh --secret pull_user --apply)"
fi

# htpasswd files: root:nginx 640 in /etc/nginx/wlsmon/ - not in the Oracle tree,
# whoever takes over the FMW owner cannot add GUI logins
_root test -d "$NGINX_WLSMON" || _do "$NGINX_WLSMON created (root, 755)" install -d -m 755 "$NGINX_WLSMON"
NGINX_GROUP="nginx"
[ -n "$T" ] && NGINX_GROUP="$(id -gn)"
_htpasswd() {   # _htpasswd PENDING_NAME TARGET
    local n="$1" target="$2"
    if _root test -s "$PEND/$n"; then
        _do "$n -> $target (root:$NGINX_GROUP 640), pending deleted" sh -c \
            "install -m 640 -o root -g '$NGINX_GROUP' '$PEND/$n' '$target' && rm -f '$PEND/$n'"
    elif _root test -s "$target"; then
        ok "$(printf "  %-14s %s present (%s user(s))" "$n" "$target" "$(_root grep -c : "$target")")"
    else
        return 1
    fi
}
if [ "$ROLE" != "data" ]; then
    _htpasswd gui_htpasswd "$NGINX_WLSMON/htpasswd" \
        || fail "No GUI login (gui_htpasswd) – 00-setup-interview.sh --secret gui_htpasswd --apply"
fi
if [ "$ROLE" = "data" ]; then
    _htpasswd pull_hash "$NGINX_WLSMON/pull_htpasswd" \
        || fail "No pull hash – 00-setup-interview.sh --secret pull_hash --apply (hash from the GUI host)"
fi
left="$(_root sh -c "ls '$PEND' 2>/dev/null")"
[ -n "$left" ] && $APPLY && info "still in etc/pending (not needed for role $ROLE): $(printf '%s' "$left" | tr '\n' ' ')"

# =============================================================================
# 3. nginx
# =============================================================================
section "nginx"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# /i/ only from our include when no other include routes it (APEX / ORDS)
I_KEEP=()
I_DIR="${C[WLSMON_APEX_DIR]:-}"
if _root grep -lsE '^\s*location\s+(\^~\s+)?/i/' "$NGINX_DIR"/oracle-wls.d/*.conf "$NGINX_DIR"/conf.d/*.conf 2>/dev/null \
     | grep -qv "/wlsmon.conf$"; then
    ok "$(printf "  %-20s routed by another include (APEX / ORDS)" "/i/:")"
elif [ -n "$I_DIR" ] && [ -d "$I_DIR" ]; then
    I_KEEP=(--keep WLSMON_I)
    info "$(printf "  %-20s served by the wlsmon include from %s" "/i/:" "$I_DIR")"
else
    info "$(printf "  %-20s no APEX images – the GUI uses its SVG fallback" "/i/:")"
fi
ADMIN_RANGE="${C[WLSMON_ADMIN_IP_RANGE]:-any}"
[ -z "$ADMIN_RANGE" ] && ADMIN_RANGE="any"
[ "$ADMIN_RANGE" = "any" ] && [ "$ROLE" != "data" ] \
    && warn "WLSMON_ADMIN_IP_RANGE=any – the GUI is protected by the login only (no IP limit)"
VARS=(--var "WLSMON_BASE=$BASE" --var "ADMIN_IP_RANGE=$ADMIN_RANGE" --var "WLSMON_GUI_IP=${C[WLSMON_GUI_IP]:-any}"
      --var "WLSMON_STYLE_SRC=${C[WLSMON_STYLE_SRC]:-'self'}" --var "WLSMON_I_DIR=${I_DIR:-/nonexistent}"
      --var "FMW_OWNER=$OWNER" --var "FMW_GROUP=$OGROUP")
case "$ROLE" in
    data) ROLE_KEEP=(--keep WLSMON_DATA) ;;
    *)    ROLE_KEEP=(--keep WLSMON_GUI) ;;
esac
RENDER_OK=true
_render wlsmon-headers.conf.template "$TMP/headers.conf"                         || RENDER_OK=false
_render wlsmon_zone.conf.template    "$TMP/wlsmon_zone.conf"                     || RENDER_OK=false
_render wlsmon-nginx.conf.template   "$TMP/wlsmon.conf" "${ROLE_KEEP[@]}" "${I_KEEP[@]}" \
        --multi ADMIN_IP_RANGE --multi WLSMON_GUI_IP                              || RENDER_OK=false
if ! $RENDER_OK; then
    fail "Rendering an nginx template failed (log) – nothing written"
    print_summary; exit "${EXIT_CODE:-2}"
fi
# the include file uses the htpasswd / headers path of the test root in a test
[ -n "$T" ] && sed -i "s#/etc/nginx/wlsmon/#$NGINX_WLSMON/#g" "$TMP/wlsmon.conf"
_install_file "$TMP/headers.conf"     "$NGINX_WLSMON/headers.conf" 644 root:root "nginx wlsmon/headers.conf"
_install_file "$TMP/wlsmon_zone.conf" "$NGINX_ZONE"                644 root:root "nginx conf.d/wlsmon_zone.conf"
_install_file "$TMP/wlsmon.conf"      "$NGINX_INC"                 644 root:root "nginx oracle-wls.d/wlsmon.conf"

# ACLs set in this run -> list for --remove (root-owned, next to the htpasswd)
if $APPLY && [ "${#ACL_NEW[@]}" -gt 0 ]; then
    printf '%s\n' "${ACL_NEW[@]}" | _root sh -c "cat >> '$NGINX_WLSMON/root_acl.list'"
fi

if $APPLY && $CHANGED_NGINX && [ -z "$T" ]; then
    if _root nginx -t >> "$LOG_FILE" 2>&1; then
        ok "nginx -t: configuration valid"
        if _root systemctl is-active -q nginx; then
            _root systemctl reload nginx && ok "nginx reloaded"
        else
            warn "nginx is not running – start it: systemctl start nginx"
        fi
    else
        fail "nginx -t failed – rolling back the wlsmon files (details in the log)"
        _root nginx -t 2>&1 | tail -5 | sed 's/^/      /' | tee -a "$LOG_FILE"
        for f in "${CREATED[@]}"; do _root rm -f "$f"; done
        for f in "${ROLLBACK[@]}"; do
            b="$(_root sh -c "ls -1t '$f'.bak_* 2>/dev/null | head -1")"
            [ -n "$b" ] && _root cp -p "$b" "$f"
        done
        print_summary; exit "${EXIT_CODE:-2}"
    fi
fi

# =============================================================================
# 4. systemd
# =============================================================================
section "systemd"
CRED_KEEP=()
# core directory of kernel.core_pattern (or WLSMON_CORE_DIR): bound into the
# PrivateTmp namespace of the unit (systemd-coredump "|..." needs nothing)
CORE_DIR="${C[WLSMON_CORE_DIR]:-}"
if [ -z "$CORE_DIR" ]; then
    _pat="$(cat /proc/sys/kernel/core_pattern 2>/dev/null)"
    case "$_pat" in /*) CORE_DIR="$(dirname "$_pat")" ;; esac
fi
if [ -n "$CORE_DIR" ]; then
    CRED_KEEP+=(--keep CORE_DIR)
    VARS+=(--var "WLSMON_CORE_DIR=$CORE_DIR")
    ok "$(printf "  %-20s %s (bound read-only into the unit)" "core directory:" "$CORE_DIR")"
fi
if $CREDS; then
    [ -n "${HAVE_CRED[wls_monitor]:-}" ] && CRED_KEEP+=(--keep CRED_WLS)
    [ -n "${HAVE_CRED[reports_mon]:-}" ] && CRED_KEEP+=(--keep CRED_REP)
    [ -n "${HAVE_CRED[db_monitor]:-}" ]  && CRED_KEEP+=(--keep CRED_DB)
    [ -n "${HAVE_CRED[pull_user]:-}" ]   && CRED_KEEP+=(--keep CRED_PULL)
fi
UNITS=()
$NEED_COLLECT && UNITS+=(wlsmon-collect)
$NEED_PULL    && UNITS+=(wlsmon-pull)
CHANGED_UNITS=false
for u in "${UNITS[@]}"; do
    for kind in service timer; do
        _render "$u.$kind.template" "$TMP/$u.$kind" "${CRED_KEEP[@]}" || { fail "render $u.$kind"; continue; }
        before="${#CREATED[@]}${#ROLLBACK[@]}"
        _install_file "$TMP/$u.$kind" "$UNIT_DIR/$u.$kind" 644 root:root "systemd $u.$kind"
        [ "$before" != "${#CREATED[@]}${#ROLLBACK[@]}" ] && CHANGED_UNITS=true
    done
done
for u in wlsmon-collect wlsmon-pull; do
    case " ${UNITS[*]} " in *" $u "*) continue ;; esac
    _root test -f "$UNIT_DIR/$u.timer" && warn "$u.timer installed, but not needed for role $ROLE – --remove + --apply cleans up"
done

if [ -z "$T" ] && $APPLY; then
    $CHANGED_UNITS && _root systemctl daemon-reload && ok "systemctl daemon-reload"
    if $NO_START; then
        info "--no-start: timers not enabled"
    else
        for u in "${UNITS[@]}"; do
            if _root systemctl is-enabled -q "$u.timer" 2>/dev/null && _root systemctl is-active -q "$u.timer"; then
                ok "$(printf "  %-20s enabled + active" "$u.timer")"
            else
                _do "$u.timer enabled + started" systemctl enable --now "$u.timer"
            fi
        done
    fi
fi

# =============================================================================
# 5. First run and local access test
# =============================================================================
section "First run"
if [ -n "$T" ] || ! $APPLY || $NO_START; then
    info "skipped (dry-run / --no-start / test root)"
elif $NEED_COLLECT; then
    t0=$(date +%s)
    if _root systemctl start wlsmon-collect.service >> "$LOG_FILE" 2>&1; then
        ok "$(printf "  %-20s finished in %s s" "wlsmon-collect:" "$(( $(date +%s) - t0 ))")"
    else
        fail "wlsmon-collect.service failed – journalctl -u wlsmon-collect -n 30"
        _root journalctl -u wlsmon-collect -n 15 --no-pager 2>&1 | sed 's/^/      /' | tee -a "$LOG_FILE"
    fi
    NOW="$BASE/api/now.json"
    if _root test -f "$NOW"; then
        _root cat "$NOW" | python3 -I -c '
import json, sys
n = json.load(sys.stdin)
print("      overall %s   generated_at %s   %d ms" % (n["overall"]["level"].upper(), n["generated_at"],
      n["collector"]["duration_ms"]))
for e in n["collector"]["errors"]:
    print("      %-5s %s" % (e["level"].upper(), e["text"]))' | tee -a "$LOG_FILE"
        _root grep -q '"no credential' "$NOW" \
            && warn "now.json reports a missing credential – check the LoadCredentialEncrypted lines"
    else
        fail "No $NOW after the first run"
    fi
fi

section "Access test (local)"
if [ -n "$T" ] || ! $APPLY; then
    info "skipped (dry-run / test root)"
else
    SN="$(_root sed -n 's/^\s*server_name\s\+\([^ ;]*\).*/\1/p' "$NGINX_DIR/conf.d/oracle-wls.conf" 2>/dev/null | head -1)"
    PORT="${C[WLSMON_NGINX_PORT]:-443}"
    SN="${SN:-localhost}"
    # local self-check against our own nginx: -k is acceptable here (loopback,
    # own certificate) - never between hosts (concept 3a)
    _code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$SN:$PORT:127.0.0.1" "$@"; }
    if [ "$ROLE" = "data" ]; then
        c="$(_code "https://$SN:$PORT/wlsmon/api/now.json")"
        case "$c" in 401|403) ok "$(printf "  %-36s HTTP %s (protected)" "api/now.json without login:" "$c")" ;;
                     *) fail "$(printf "  %-36s HTTP %s – expected 401 / 403" "api/now.json without login:" "$c")" ;; esac
        c="$(_code "https://$SN:$PORT/wlsmon/index.html")"
        [ "$c" = "404" ] && ok "$(printf "  %-36s HTTP 404 (no GUI on a data host)" "/wlsmon/index.html:")" \
                         || fail "$(printf "  %-36s HTTP %s – expected 404" "/wlsmon/index.html:" "$c")"
    else
        c="$(_code "https://$SN:$PORT/wlsmon/")"
        case "$c" in
            401) ok "$(printf "  %-36s HTTP 401 (login needed)" "/wlsmon/ without login:")" ;;
            403) ok "$(printf "  %-36s HTTP 403 (127.0.0.1 outside WLSMON_ADMIN_IP_RANGE)" "/wlsmon/ without login:")" ;;
            *)   fail "$(printf "  %-36s HTTP %s – expected 401" "/wlsmon/ without login:" "$c")" ;;
        esac
        c="$(_code -X POST "https://$SN:$PORT/wlsmon/api/now.json")"
        case "$c" in 401|403|405) ok "$(printf "  %-36s HTTP %s (refused)" "POST:" "$c")" ;;
                     *) fail "$(printf "  %-36s HTTP %s – expected 401 / 403" "POST:" "$c")" ;; esac
        c="$(_code "https://$SN:$PORT/console/")"
        info "$(printf "  %-36s HTTP %s (unchanged by wlsmon)" "/console/ for comparison:" "$c")"
        info "With login (your browser): https://$SN/wlsmon/  – user(s): ${C[WLSMON_GUI_USERS]:-?}"
    fi
fi

section "Next"
if $APPLY; then
    info "Status:  systemctl list-timers 'wlsmon-*'   ·   journalctl -u wlsmon-collect -n 20"
    info "Update:  01-install-wlsmon_fmw.sh --apply; this script again only when a template changed"
    info "Password changed: 00-setup-interview.sh --secret <name> --apply, then this script --apply"
else
    info "Dry-run – nothing changed. Run with --apply."
fi
print_summary
exit "${EXIT_CODE:-0}"
