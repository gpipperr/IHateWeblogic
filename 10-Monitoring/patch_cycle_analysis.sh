#!/bin/bash
# =============================================================================
# Script   : patch_cycle_analysis.sh
# Purpose  : Start the standardised Oracle patch-cycle analysis with Claude
#            (skill 10-Monitoring/patch_cycle_analysis_skill.md, Claude Code
#            skill /patch-cycle-analysis):
#              status   configured cycle, advisories released after it,
#                       Patch-Doku folders and their stage (default)
#              prepare  stage 1a: create 10-Monitoring/Patch-Doku/<yyyy-mm>_<cycle>/
#                       and start Claude - it reads the public Oracle sources
#                       and writes readme_list.md (what the user downloads)
#              analyse  stage 1b: after the user dropped the READMEs into
#                       readmes/ (+ collector archive into env/), start Claude -
#                       analysis README + manual guide; maintainer mode also
#                       freezes 00-patch-references, creates the 70 folder and
#                       update_plan.md (= the prompt for switching the lib)
#            Patch-Doku/ is not in Git (Oracle documents, customer data).
#            Nothing is changed without --apply; Claude itself never commits.
#
# Call     : ./10-Monitoring/patch_cycle_analysis.sh [status]
#            ./10-Monitoring/patch_cycle_analysis.sh prepare [--cycle ID] [--apply]
#            ./10-Monitoring/patch_cycle_analysis.sh analyse [--cycle ID]
#                  [--mode customer|maintainer] [--env ARCHIVE] [--apply]
#              --cycle ID      e.g. cspunov2026, cpujan2027 (default: the
#                              oldest advisory after PATCH_CYCLE_DATE)
#              --mode M        customer (default, writes only into Patch-Doku)
#                              or maintainer (repo docs + update_plan.md)
#              --env ARCHIVE   collector archive (70-Customer-Projects/tools/
#                              collect_fmw_env.sh --full) -> env/
#              --print-prompt  show the Claude prompt and stop
#              --apply         create folders / start Claude
# Requires : claude (Claude Code CLI) in PATH, curl for the advisory index
# Doc      : 10-Monitoring/patch_cycle_analysis_skill.md, 10-Monitoring/README.md
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

VERSION_CONF="$ROOT_DIR/09-Install/oracle_software_version.conf"
# shellcheck source=../09-Install/oracle_software_version.conf
[ -f "$VERSION_CONF" ] && source "$VERSION_CONF"

DOKU_BASE="$SCRIPT_DIR/Patch-Doku"
SKILL_DOC="10-Monitoring/patch_cycle_analysis_skill.md"

# =============================================================================
# Arguments
# =============================================================================
ACTION="status"
CYCLE=""
MODE="customer"
ENV_ARCHIVE=""
APPLY=false
PRINT_PROMPT=false

_usage() {
    sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        status|prepare|analyse) ACTION="$1" ;;
        --cycle)        shift; CYCLE="${1:?--cycle needs an id (e.g. cspunov2026)}" ;;
        --mode)         shift; MODE="${1:?--mode needs customer|maintainer}" ;;
        --env)          shift; ENV_ARCHIVE="${1:?--env needs an archive}" ;;
        --apply)        APPLY=true ;;
        --print-prompt) PRINT_PROMPT=true ;;
        --help|-h)      _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done
case "$MODE" in customer|maintainer) ;; *)
    printf "\033[31mERROR\033[0m --mode must be customer or maintainer\n" >&2; exit 2 ;; esac

init_log

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

printLine
section "Patch-cycle analysis – $(date '+%Y-%m-%d %H:%M:%S')"
printList "Action"           20 "$ACTION$([ "$ACTION" = status ] || { $APPLY && printf ' (apply)' || printf ' (dry-run)'; })"
printList "Configured cycle" 20 "${PATCH_CYCLE:-?} (${PATCH_CYCLE_DATE:-?})"
printList "Patch-Doku"       20 "$DOKU_BASE"
printLine

if [ "$(id -u)" -eq 0 ]; then
    fail "Do not run as root – run as the repository owner (oracle)"
    print_summary; exit 2
fi

# =============================================================================
# Advisories after the configured cycle
# =============================================================================
ADVISORIES="$WORK_DIR/advisories.txt"
: > "$ADVISORIES"
if curl -sfL -m 30 -A "Mozilla/5.0" -o "$WORK_DIR/index.html" https://www.oracle.com/security-alerts/; then
    ihw_oracle_advisories "$WORK_DIR/index.html" "${PATCH_CYCLE_DATE:-1970-01-01}" > "$ADVISORIES"
else
    warn "https://www.oracle.com/security-alerts/ not reachable – advisory list unknown"
fi

# _cycle_rel ID – release date of a cpu<mon><yyyy> / cspu<mon><yyyy> id, else today
_cycle_rel() {
    local id="$1" mon yr mm
    if [[ "$id" =~ ^c(s)?pu[a-z]{3}[0-9]{4}$ ]]; then
        mon="${id: -7:3}"; yr="${id: -4}"
        mm="$(date -d "1 $mon $yr" +%m 2>/dev/null)" && { ihw_third_tuesday "$yr" "$mm"; return; }
    fi
    date +%F
}

# _stage DIR – one-line stage summary of a Patch-Doku folder
_stage() {
    local d="$1" n_list n_files n_res
    n_list="$(grep -c '^ *- \[' "$d/readme_list.md" 2>/dev/null)"; n_list="${n_list:-0}"
    n_files="$(find "$d/readmes" -type f 2>/dev/null | wc -l)"
    n_res="$(find "$d/result" -type f 2>/dev/null | wc -l)"
    if [ ! -f "$d/readme_list.md" ]; then
        printf 'created – phase 1 (prepare) not run yet'
    elif [ "$n_res" -gt 0 ] || grep -q '^analysed=' "$d/cycle.info" 2>/dev/null; then
        printf 'analysed (%s result files)' "$n_res"
    else
        printf 'prepared – %s of %s documents in readmes/' "$n_files" "$n_list"
    fi
}

# =============================================================================
# status
# =============================================================================
if [ "$ACTION" = "status" ]; then
    section "Oracle advisories after ${PATCH_CYCLE:-the configured cycle}"
    if [ -s "$ADVISORIES" ]; then
        while read -r _t _n _r _u _s; do
            if [ "$_s" = "released" ]; then
                warn "$(printf "%-5s %-12s %s  released – not covered yet  %s" "$_t" "$_n" "$_r" "$_u")"
            else
                info "$(printf "%-5s %-12s %s  announced (pre-release)     %s" "$_t" "$_n" "$_r" "$_u")"
            fi
        done < "$ADVISORIES"
    else
        ok "No CPU / CSPU advisory after ${PATCH_CYCLE:-?} listed on the index (alerts: see the index page)"
    fi

    section "Patch-Doku folders"
    _found=false
    for _d in "$DOKU_BASE"/*/; do
        [ -d "$_d" ] || continue
        _found=true
        info "$(printf "%-28s %s" "$(basename "$_d")" "$(_stage "$_d")")"
    done
    $_found || info "none yet – start with: $0 prepare --apply"

    section "update_plan.md (maintainer, stage 3)"
    _found=false
    for _p in "$ROOT_DIR"/70-Customer-Projects/*/update_plan.md; do
        [ -f "$_p" ] || continue
        _found=true
        _open="$(grep -c '^ *- \[ \]' "$_p")"
        _msg="$(printf "%-55s %s open items" "${_p#"$ROOT_DIR"/}" "$_open")"
        if [ "$_open" -gt 0 ]; then warn "$_msg"; else ok "$_msg"; fi
    done
    $_found || info "none – written by 'analyse --mode maintainer'"
    print_summary
    exit "$EXIT_CODE"
fi

# =============================================================================
# prepare / analyse – which cycle?
# =============================================================================
if [ -z "$CYCLE" ]; then
    CYCLE="$(awk '$5=="released"{print $2; exit}' "$ADVISORIES")"
    if [ -z "$CYCLE" ]; then
        CYCLE="$(awk '{print $2; exit}' "$ADVISORIES")"
        [ -n "$CYCLE" ] && warn "No released advisory after ${PATCH_CYCLE:-?} – using the announced $CYCLE (pre-release)"
    fi
fi
if [ -z "$CYCLE" ] && [ -n "${PATCH_CYCLE_DATE:-}" ]; then
    # Not on the index yet: next month after the configured cycle -
    # CPU in Jan/Apr/Jul/Oct, CSPU in the months between
    _m="$(date -d "${PATCH_CYCLE_DATE:0:7}-01 +1 month" +%m)"
    _y="$(date -d "${PATCH_CYCLE_DATE:0:7}-01 +1 month" +%Y)"
    _mon="$(date -d "$_y-$_m-01" +%b | tr '[:upper:]' '[:lower:]')"
    case "$_m" in 01|04|07|10) CYCLE="cpu${_mon}${_y}" ;; *) CYCLE="cspu${_mon}${_y}" ;; esac
    info "Not on the index yet – next cycle by the calendar: $CYCLE (check with --cycle if Oracle names it differently)"
fi
if [ -z "$CYCLE" ]; then
    fail "No cycle found after ${PATCH_CYCLE:-?} – give one with --cycle (e.g. --cycle cspunov2026)"
    print_summary; exit 2
fi

CYCLE_REL="$(_cycle_rel "$CYCLE")"
CYCLE_URL="https://www.oracle.com/security-alerts/${CYCLE}.html"
DOKU_DIR="$DOKU_BASE/${CYCLE_REL:0:7}_${CYCLE}"
printList "Cycle"     20 "$CYCLE (release $CYCLE_REL)"
printList "Advisory"  20 "$CYCLE_URL"
printList "Folder"    20 "$DOKU_DIR"
printList "Mode"      20 "$MODE"

# with the Claude Code skill the prompt starts as its slash command
SKILL_CMD="Patch-cycle analysis, phase "
[ -f "$ROOT_DIR/.claude/skills/patch-cycle-analysis/SKILL.md" ] && SKILL_CMD="/patch-cycle-analysis "

if [ "$ACTION" = "prepare" ]; then
    PROMPT="${SKILL_CMD}prepare ${DOKU_DIR}

Phase 1 of the IHateWeblogic patch-cycle analysis for ${CYCLE} (${CYCLE_URL}, release ${CYCLE_REL}).
The configured cycle of the lib is ${PATCH_CYCLE:-?} (${PATCH_CYCLE_DATE:-?}). Follow ${SKILL_DOC}
section 2: read the public Oracle sources (curl with a browser user agent), filter the
rows for Forms & Reports 14.1.2 homes, compare with 09-Install/docs/00-patch-references.md
and write ${DOKU_DIR}/readme_list.md - the checklist of documents the user downloads
into ${DOKU_DIR}/readmes/. Answer in German."
else
    PROMPT="${SKILL_CMD}analyse ${DOKU_DIR} mode=${MODE}

Phase 2 of the IHateWeblogic patch-cycle analysis for ${CYCLE} (${CYCLE_URL}).
Follow ${SKILL_DOC} section 3: check ${DOKU_DIR}/readmes/ against readme_list.md, read
every README and the environment in ${DOKU_DIR}/env/, ask the open questions, then write
the analysis README and the manual guide. Mode ${MODE}: $( [ "$MODE" = maintainer ] \
  && printf 'freeze and rework 09-Install/docs/00-patch-references.md, new 70-Customer-Projects folder, previous one frozen, and update_plan.md (section 5) as the prompt for switching the lib.' \
  || printf 'write only into %s/result/ - do not change the repository.' "$DOKU_DIR" )
No conf / script changes, no commit. Answer in German."
fi

if $PRINT_PROMPT; then
    section "Claude prompt"
    printf '%s\n' "$PROMPT" | tee -a "${LOG_FILE:-/dev/null}"
    print_summary
    exit "$EXIT_CODE"
fi

# =============================================================================
# Checks before starting Claude
# =============================================================================
section "Checks"
if command -v claude > /dev/null 2>&1; then
    ok "claude: $(command -v claude) ($(claude --version 2>/dev/null | head -1))"
else
    fail "claude (Claude Code CLI) not in PATH – install it or start the skill in an open Claude session"
fi
[ -f "$ROOT_DIR/$SKILL_DOC" ] && ok "Skill document: $SKILL_DOC" || fail "Skill document missing: $SKILL_DOC"
[ -f "$ROOT_DIR/.claude/skills/patch-cycle-analysis/SKILL.md" ] \
    && ok "Claude Code skill: .claude/skills/patch-cycle-analysis/SKILL.md" \
    || warn "Claude Code skill missing – the prompt still names the skill document (install: mkdir -p .claude/skills && cp -r 10-Monitoring/claude/skills/patch-cycle-analysis .claude/skills/)"

# Claude setup (10-Monitoring/setup_claude.md): never on prod, sandbox + guard
case "${IHW_ENV_TYPE:-}" in
    prod) fail "IHW_ENV_TYPE=prod – no Claude on this host; analyse a collector archive on a test / admin host" ;;
    test) ok "IHW_ENV_TYPE=test" ;;
    *)    warn "IHW_ENV_TYPE not set (test|prod) – 00-Setup/init_env.sh" ;;
esac
"$SCRIPT_DIR/claude_setup_check.sh" >> "${LOG_FILE:-/dev/null}" 2>&1
case $? in
    0) ok "claude_setup_check.sh: sandbox, managed settings, guard OK" ;;
    *) warn "claude_setup_check.sh reports WARN/FAIL – run it and see 10-Monitoring/setup_claude.md" ;;
esac

if [ "$ACTION" = "analyse" ]; then
    if [ ! -f "$DOKU_DIR/readme_list.md" ]; then
        fail "$DOKU_DIR/readme_list.md missing – run 'prepare' first"
    else
        _list="$(grep -c '^ *- \[' "$DOKU_DIR/readme_list.md")"
        _files="$(find "$DOKU_DIR/readmes" -type f 2>/dev/null | wc -l)"
        if [ "$_files" -eq 0 ]; then
            fail "No documents in $DOKU_DIR/readmes/ – download the list of readme_list.md first"
        elif [ "$_files" -lt "$_list" ]; then
            warn "$_files documents in readmes/, readme_list.md has $_list entries – Claude lists what is missing"
        else
            ok "$_files documents in readmes/ (readme_list.md: $_list entries)"
        fi
    fi
    if [ -n "$ENV_ARCHIVE" ] && [ ! -f "$ENV_ARCHIVE" ]; then
        fail "--env archive not found: $ENV_ARCHIVE"
    fi
    if [ "$MODE" = "maintainer" ] && [ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]; then
        warn "Working tree not clean – the analysis writes repo files; commit or stash first"
    fi
fi

if [ "${CNT_FAIL:-0}" -gt 0 ]; then
    print_summary; exit 2
fi

if ! $APPLY; then
    info "Dry-run – with --apply: create/update $DOKU_DIR and start Claude"
    info "  (--print-prompt shows the prompt)"
    print_summary
    exit "$EXIT_CODE"
fi

# =============================================================================
# Create the folder, start Claude
# =============================================================================
section "Patch-Doku folder"
mkdir -p "$DOKU_DIR/readmes" "$DOKU_DIR/env" "$DOKU_DIR/src" "$DOKU_DIR/result"
if [ ! -f "$DOKU_DIR/cycle.info" ]; then
    {
        printf 'cycle=%s\nurl=%s\nrelease=%s\n' "$CYCLE" "$CYCLE_URL" "$CYCLE_REL"
        printf 'configured_cycle=%s\nconfigured_date=%s\ncreated=%s\n' \
            "${PATCH_CYCLE:-}" "${PATCH_CYCLE_DATE:-}" "$(date +%F)"
    } > "$DOKU_DIR/cycle.info"
    ok "Created: $DOKU_DIR (readmes/ env/ src/ result/ cycle.info)"
else
    ok "Exists: $DOKU_DIR"
fi
sed -i '/^mode=/d' "$DOKU_DIR/cycle.info"; printf 'mode=%s\n' "$MODE" >> "$DOKU_DIR/cycle.info"

if [ -n "$ENV_ARCHIVE" ]; then
    cp -p "$ENV_ARCHIVE" "$DOKU_DIR/env/" && ok "Environment archive copied: $(basename "$ENV_ARCHIVE")"
fi

info "Starting Claude in $ROOT_DIR – the session continues interactively"
info "  next step after prepare: download the list of readme_list.md into readmes/,"
info "  then: $0 analyse --cycle $CYCLE --mode $MODE --apply"
print_summary
cd "$ROOT_DIR" || exit 2
exec claude "$PROMPT"
