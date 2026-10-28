#!/bin/bash
# =============================================================================
# Script   : claude_setup_check.sh
# Purpose  : Check whether Claude Code is set up on this host as described in
#            10-Monitoring/setup_claude.md (sandbox, managed settings, guard
#            hook, environment type) – the precondition for the Claude based
#            scripts (patch_cycle_analysis.sh, later the log analysis).
#              1  claude CLI, version, auto-update off
#              2  IHW_ENV_TYPE (prod -> FAIL: Claude is never used here)
#              3  WebLogic / NodeManager running on this host
#              4  /etc/claude-code/managed-settings.json – present, readable,
#                 root-owned, equal to the rendering of the template
#              5  sandbox packages bubblewrap + socat
#              6  guard hook /etc/claude-code/ihw_guard.sh – root-owned, equal
#                 to the repo copy, self-test (ask / deny)
#              7  secret files covered by the sandbox denyRead list
#              8  egress: api.anthropic.com, www.oracle.com
#            --apply renders the managed settings for this host into the log
#            directory and prints the root commands – it never writes to /etc.
#
# Call     : ./10-Monitoring/claude_setup_check.sh [--profile customer|maintainer] [--apply]
#              --profile customer    (default) strict: no unsandboxed retry,
#                                    auto mode off, network www.oracle.com only
#              --profile maintainer  our test host: unsandboxed retry only with
#                                    a prompt, auto mode allowed, network also
#                                    *.oracle.com, github.com, localhost
# Exit     : 0 = OK, 1 = warnings, 2 = errors
# Doc      : 10-Monitoring/setup_claude.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
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

CLAUDE_ETC="/etc/claude-code"
MANAGED="$CLAUDE_ETC/managed-settings.json"
GUARD_ETC="$CLAUDE_ETC/ihw_guard.sh"
GUARD_REPO="$SCRIPT_DIR/claude/ihw_guard.sh"
TEMPLATE="$SCRIPT_DIR/claude/managed-settings.json.template"

PROFILE="customer"
APPLY=false
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) shift; PROFILE="${1:?--profile needs customer|maintainer}" ;;
        --apply)   APPLY=true ;;
        --help|-h) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done
case "$PROFILE" in customer|maintainer) ;; *)
    printf "\033[31mERROR\033[0m --profile must be customer or maintainer\n" >&2; exit 2 ;; esac

init_log

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

printLine
section "Claude Code setup check – $(date '+%Y-%m-%d %H:%M:%S')"
printList "Profile"      20 "$PROFILE$($APPLY && printf ' (apply: render + root commands)')"
printList "IHW_ENV_TYPE" 20 "${IHW_ENV_TYPE:-<not set>}"
printList "Doc"          20 "10-Monitoring/setup_claude.md"
printLine

# =============================================================================
# Secret files on this host (sandbox denyRead, check 7)
# =============================================================================
SECRETS="$WORK_DIR/secrets.txt"
{
    find "$ROOT_DIR" -path "$ROOT_DIR/log" -prune -o -type f \
        \( -name '*.des3' -o -name 'weblogic_sec.conf' -o -name '.getMOSPatch.cfg' \) -print 2>/dev/null
    [ -n "${DOMAIN_HOME:-}" ] && [ -d "$DOMAIN_HOME" ] && \
        find "$DOMAIN_HOME" -type f \( -name 'boot.properties' -o -name 'SerializedSystemIni.dat' \
            -o -name 'cwallet.sso' -o -name 'ewallet.p12' -o -name '*.jks' -o -name '*.key' \) -print 2>/dev/null
    [ -n "${ORACLE_BASE:-}" ] && [ -d "$ORACLE_BASE/admin" ] && \
        find "$ORACLE_BASE/admin" -type f \( -name '*.key' -o -name '*.p12' -o -name '*.jks' \
            -o -name 'cwallet.sso' -o -name 'ewallet.p12' \) -print 2>/dev/null
    find "$HOME" -maxdepth 1 -type f -name '.getMOSPatch.cfg' -print 2>/dev/null
} | sort -u > "$SECRETS"

# _render OUT – managed settings for this host from the template
_render() {
    python3 -I - "$TEMPLATE" "$1" "$PROFILE" "$ROOT_DIR" "$(readlink -f "$ENV_CONF")" \
        "${IHW_ENV_TYPE:-prod}" "$SECRETS" <<'PYEOF'
import json, sys
tpl, out, profile, root, conf_target, env_type, secrets = sys.argv[1:8]
def sub(v):
    if isinstance(v, str):
        return (v.replace("@IHW_ROOT@", root.lstrip("/") if v.startswith(("Read(//", "Edit(//")) else root)
                 .replace("@ENV_CONF_TARGET@", conf_target.lstrip("/"))
                 .replace("@IHW_ENV_TYPE@", env_type))
    if isinstance(v, list):
        return [sub(x) for x in v]
    if isinstance(v, dict):
        return {k: sub(x) for k, x in v.items()}
    return v
d = sub(json.load(open(tpl)))
# environment.conf is usually a symlink - without one both Edit rules are equal
d["permissions"]["deny"] = list(dict.fromkeys(d["permissions"]["deny"]))
fs = d["sandbox"]["filesystem"]
fs["denyRead"] += [l.strip() for l in open(secrets) if l.strip()]
if profile == "maintainer":
    d["sandbox"]["allowUnsandboxedCommands"] = True
    d["sandbox"]["network"]["allowedDomains"] += ["*.oracle.com", "github.com", "localhost", "127.0.0.1"]
else:
    d["disableAutoMode"] = "disable"
json.dump(d, open(out, "w"), indent=2)
open(out, "a").write("\n")
PYEOF
}
RENDERED="$WORK_DIR/managed-settings.json"
if ! _render "$RENDERED"; then
    fail "Cannot render $TEMPLATE"
    print_summary; exit 2
fi

# =============================================================================
# 1 claude CLI
# =============================================================================
section "1 – Claude Code CLI"
if command -v claude > /dev/null 2>&1; then
    ok "$(printf "  %-22s %s (%s)" "claude" "$(command -v claude)" "$(claude --version 2>/dev/null | head -1)")"
    if [ -n "${DISABLE_AUTOUPDATER:-}" ] || grep -q '"DISABLE_AUTOUPDATER"' "$MANAGED" 2>/dev/null; then
        ok "  Auto-update off (DISABLE_AUTOUPDATER)"
    else
        warn "  Auto-update on – updates should be deliberate (managed settings env DISABLE_AUTOUPDATER)"
    fi
    # Node.js runtime: supported LTS with the Brotli fix CVE-2026-111497
    # (22.23.4 / 24.22.1 / 26.12.1; 20 and older = end of life, no fix)
    _nv="$(node --version 2>/dev/null | tr -d v)"
    if [ -z "$_nv" ]; then
        info "  node not in PATH (native Claude Code build?)"
    else
        case "${_nv%%.*}" in
            22) _min=22.23.4 ;; 24) _min=24.22.1 ;; 26) _min=26.12.1 ;; *) _min="" ;;
        esac
        if [ -z "$_min" ]; then
            warn "  node $_nv – not a supported LTS line with the Brotli fix (CVE-2026-111497) – use 22 / 24 / 26"
        elif [ "$(printf '%s\n%s\n' "$_min" "$_nv" | sort -V | head -1)" = "$_min" ]; then
            ok "  node $_nv (>= $_min, Brotli CVE-2026-111497 fixed)"
        else
            warn "  node $_nv – below $_min (Brotli CVE-2026-111497) – update"
        fi
    fi
    unset _nv _min
else
    info "  claude not in PATH – nothing runs here (fine for a production host)"
fi

# =============================================================================
# 2 environment type
# =============================================================================
section "2 – Environment type (IHW_ENV_TYPE)"
case "${IHW_ENV_TYPE:-}" in
    test) ok "  IHW_ENV_TYPE=test – Claude allowed with sandbox + guard" ;;
    prod) fail "  IHW_ENV_TYPE=prod – do not use Claude Code on this host (collector archive -> analysis host)" ;;
    *)    warn "  IHW_ENV_TYPE not set (test|prod) – 00-Setup/init_env.sh; the guard treats it as prod" ;;
esac
if [ "$PROFILE" = "maintainer" ] && [ "${IHW_ENV_TYPE:-}" != "test" ]; then
    fail "  --profile maintainer needs IHW_ENV_TYPE=test"
fi

# =============================================================================
# 3 FMW processes on this host
# =============================================================================
section "3 – WebLogic processes on this host"
_wls="$(pgrep -fc 'weblogic\.(Server|NodeManager)' 2>/dev/null)"; _wls="${_wls:-0}"
if [ "$_wls" -eq 0 ]; then
    ok "  No WebLogic / NodeManager process – analysis host"
elif [ "${IHW_ENV_TYPE:-}" = "test" ]; then
    ok "  $_wls WebLogic / NodeManager process(es) – test host with domain (expected)"
else
    warn "  $_wls WebLogic / NodeManager process(es) – FMW server; Claude belongs on a test / admin host"
fi

# =============================================================================
# 4 managed settings
# =============================================================================
section "4 – Managed settings ($MANAGED)"
if [ ! -e "$MANAGED" ]; then
    warn "  Not installed – Claude runs without sandbox / guard (--apply prints the root commands)"
elif [ ! -r "$MANAGED" ]; then
    fail "  Not readable for $(id -un) – Claude starts WITHOUT the policy (chmod 0644)"
else
    _own="$(stat -c '%U:%G %a' "$MANAGED")"
    [[ "$_own" == root:root\ 644 ]] && ok "  Owner / mode: $_own" \
        || warn "  Owner / mode: $_own (expected root:root 644)"
    if ! python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$MANAGED" 2>/dev/null; then
        fail "  Not valid JSON – Claude refuses to start"
    elif python3 -I - "$MANAGED" "$RENDERED" <<'PYEOF'
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)
PYEOF
    then
        ok "  Equal to the rendering of the template (profile $PROFILE)"
    else
        warn "  Differs from the rendering (profile $PROFILE, new secret files, changed IHW_ENV_TYPE?) – re-run with --apply"
    fi
fi

# =============================================================================
# 5 sandbox packages
# =============================================================================
section "5 – Sandbox packages (Linux: bubblewrap + socat)"
for _p in bubblewrap socat; do
    if rpm -q "$_p" > /dev/null 2>&1; then
        ok "$(printf "  %-12s %s" "$_p" "$(rpm -q "$_p")")"
    else
        warn "$(printf "  %-12s not installed – sandbox cannot start (failIfUnavailable stops Claude)" "$_p")"
    fi
done

# =============================================================================
# 6 guard hook
# =============================================================================
section "6 – Guard hook ($GUARD_ETC)"
_guard="$GUARD_REPO"
if [ ! -e "$GUARD_ETC" ]; then
    warn "  Not installed – self-test with the repo copy"
else
    _guard="$GUARD_ETC"
    _own="$(stat -c '%U:%G %a' "$GUARD_ETC")"
    [[ "$_own" == root:root\ 755 ]] && ok "  Owner / mode: $_own" \
        || warn "  Owner / mode: $_own (expected root:root 755 – Claude must not be able to edit it)"
    cmp -s "$GUARD_ETC" "$GUARD_REPO" && ok "  Equal to the repo copy" \
        || warn "  Differs from $GUARD_REPO – install the current version"
fi
_gt() {   # _gt TYPE COMMAND EXPECTED
    local got
    got="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$2" \
        | "$_guard" --env-type "$1" 2>/dev/null \
        | sed -n 's/.*"permissionDecision": *"\([a-z]*\)".*/\1/p')"
    got="${got:-none}"
    if [ "$got" = "$3" ]; then
        ok "$(printf "  %-5s %-34s -> %s" "$1" "$2" "$got")"
    else
        fail "$(printf "  %-5s %-34s -> %s (expected %s)" "$1" "$2" "$got" "$3")"
    fi
}
_gt test "./x.sh --apply"         ask
_gt prod "./x.sh --apply"         deny
_gt prod "opatch napply -silent"  deny
_gt test "opatch lspatches"       none
_gt prod "ls -la"                 none

# =============================================================================
# 7 secret files
# =============================================================================
section "7 – Secret files (sandbox denyRead)"
_n="$(wc -l < "$SECRETS")"
if [ "$_n" -eq 0 ]; then
    info "  No secret files found"
elif [ -r "$MANAGED" ]; then
    _miss=0
    while read -r _f; do
        if ! grep -qF "\"$_f\"" "$MANAGED"; then
            warn "  Not in denyRead: $_f"; _miss=$((_miss + 1))
        fi
    done < "$SECRETS"
    [ "$_miss" -eq 0 ] && ok "  All $_n secret files covered by the installed denyRead list"
else
    info "  $_n secret files found – covered once the managed settings are installed"
fi

# =============================================================================
# 8 egress
# =============================================================================
section "8 – Egress"
for _u in https://api.anthropic.com https://www.oracle.com/security-alerts/; do
    _code="$(curl -s -o /dev/null -m 10 -A "Mozilla/5.0" -w '%{http_code}' "$_u" 2>/dev/null)"
    if [ -n "$_code" ] && [ "$_code" != "000" ]; then
        ok "$(printf "  %-45s HTTP %s (reachable)" "$_u" "$_code")"
    else
        warn "$(printf "  %-45s not reachable (proxy / firewall, 02-Checks/egress_check.sh)" "$_u")"
    fi
done

# =============================================================================
# apply: rendered file + root commands
# =============================================================================
if $APPLY && [ "${CNT_FAIL:-0}" -gt 0 ]; then
    section "Apply – install as root"
    fail "  Not rendered – fix the FAIL items first"
elif $APPLY; then
    section "Apply – install as root"
    _out="$(dirname "${LOG_FILE:-$WORK_DIR/x}")/managed-settings.json"
    cp "$RENDERED" "$_out" && ok "  Rendered: $_out"
    info "  Review the file, then as root:"
    {
        printf '    dnf install -y bubblewrap socat\n'
        printf '    install -d -o root -g root -m 0755 %s\n' "$CLAUDE_ETC"
        printf '    install -o root -g root -m 0755 %s %s\n' "$GUARD_REPO" "$GUARD_ETC"
        printf '    install -o root -g root -m 0644 %s %s\n' "$_out" "$MANAGED"
    } | tee -a "${LOG_FILE:-/dev/null}"
    info "  Then start a new Claude session: /status shows 'Enterprise managed settings (file)'"
else
    info "Dry-run – --apply renders the managed settings and prints the root commands"
fi

print_summary
exit "$EXIT_CODE"
