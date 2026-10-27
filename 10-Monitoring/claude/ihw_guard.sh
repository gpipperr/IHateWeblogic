#!/bin/bash
# =============================================================================
# Script   : ihw_guard.sh
# Purpose  : Claude Code PreToolUse hook (matcher Bash) – second layer next to
#            the sandbox and the permission rules of managed-settings.json:
#            commands that change an Oracle environment are
#              IHW_ENV_TYPE=test   -> ask   (the user confirms each one)
#              IHW_ENV_TYPE=prod   -> deny
#              unknown / mismatch  -> deny  (treated as prod)
#            Everything else: no decision (normal permission flow).
#            Text matching is best effort (sh -c, absolute paths, aliases are
#            not seen) – the sandbox is the hard boundary, this hook makes the
#            intent visible and stops the usual forms.
#
# Install  : as root, root-owned, outside the repo (Claude cannot edit it):
#              install -o root -g root -m 0755 ihw_guard.sh /etc/claude-code/ihw_guard.sh
#            managed-settings.json calls it with the environment type fixed
#            at install time (claude_setup_check.sh --apply prints both):
#              /etc/claude-code/ihw_guard.sh --env-type test --conf <repo>/environment.conf
# Input    : hook JSON on stdin (tool_name, tool_input.command, cwd, …)
# Output   : hookSpecificOutput JSON (permissionDecision ask|deny) or nothing
# Exit     : always 0 (a decision is given as JSON)
# Self-test: echo '{"tool_name":"Bash","tool_input":{"command":"x.sh --apply"}}' \
#              | ./ihw_guard.sh --env-type prod
# Doc      : 10-Monitoring/setup_claude.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

ENV_TYPE=""
CONF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --env-type) shift; ENV_TYPE="${1:-}" ;;
        --conf)     shift; CONF="${1:-}" ;;
    esac
    shift
done

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print((d.get("tool_input") or {}).get("command", ""))
except Exception:
    print("__IHW_UNPARSEABLE__")
' 2>/dev/null)"

# --- Environment type: install-time value, cross-checked with the conf -------
CONF_TYPE=""
if [ -n "$CONF" ] && [ -r "$CONF" ]; then
    CONF_TYPE="$(sed -n 's/^IHW_ENV_TYPE="\{0,1\}\([a-z]*\)"\{0,1\}.*/\1/p' "$CONF" | tail -1)"
fi
MODE="$ENV_TYPE"
case "$MODE" in test|prod) ;; *) MODE="prod" ;; esac
[ -n "$CONF_TYPE" ] && [ "$CONF_TYPE" != "$ENV_TYPE" ] && MODE="prod"   # conf changed after install

# --- Commands that change an Oracle environment ---------------------------------
# label|ERE (matched against the whole command text, any sub-command)
RULES=(
    'apply flag|(^|[[:space:]])--apply([[:space:]=]|$)'
    'OPatch change|opatch[^|;&]*[[:space:]](apply|napply|rollback|nrollback|util[[:space:]]+cleanup)'
    'WLST|(^|[/[:space:]])wlst(\.sh)?([[:space:]]|$)'
    'start/stop|(startStop|fmw_ctl|startWebLogic|stopWebLogic|startManagedWebLogic|stopManagedWebLogic|startNodeManager|stopNodeManager|startComponent|stopComponent)(\.sh)?'
    'RCU / domain config|(^|[/[:space:]])(rcu|config\.sh|config_builder\.sh|pack\.sh|unpack\.sh)([[:space:]]|$)'
    'SQL session|(^|[/[:space:]])(sqlplus|sql|rman|expdp|impdp)([[:space:]]|$)'
    'systemd change|systemctl[[:space:]]+(--[a-z-]+[[:space:]]+)*(start|stop|restart|reload|enable|disable|mask|kill|daemon-reload)'
    'root|(^|[[:space:];&|(])(sudo|su|pkexec|doas)([[:space:]]|$)'
    'recursive delete|(^|[[:space:];&|(])rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)'
    'kill|(^|[[:space:];&|(])(kill|pkill|killall)([[:space:]]|$)'
    'package change|(dnf|yum|rpm)[[:space:]]+(-[a-zA-Z]*[iUe]|install|remove|erase|update|upgrade)'
    'crontab change|crontab[[:space:]]+(-[re]|[^-l[:space:]])'
    'git push|git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+push'
)

HIT=""
if [ "$CMD" = "__IHW_UNPARSEABLE__" ]; then
    HIT="unparseable hook input"
else
    for _r in "${RULES[@]}"; do
        if printf '%s' "$CMD" | grep -Eq -- "${_r#*|}"; then HIT="${_r%%|*}"; break; fi
    done
fi
[ -z "$HIT" ] && exit 0

DECISION="deny"; [ "$MODE" = "test" ] && DECISION="ask"
REASON="IHateWeblogic guard ($MODE): $HIT - $( [ "$DECISION" = ask ] \
    && printf 'changes the environment, confirm it yourself' \
    || printf 'not allowed on this host, run it yourself outside Claude' )"

logger -t ihw-claude -p "user.$( [ "$DECISION" = deny ] && printf warning || printf notice )" \
    "$DECISION ($MODE, $HIT): ${CMD:0:200}" 2>/dev/null

python3 -I -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
    "permissionDecision": sys.argv[1], "permissionDecisionReason": sys.argv[2]}}))
' "$DECISION" "$REASON"
exit 0
