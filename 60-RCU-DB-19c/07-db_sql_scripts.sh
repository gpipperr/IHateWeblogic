#!/bin/bash
# =============================================================================
# Script   : 07-db_sql_scripts.sh
# Purpose  : DBA SQL script collection (OraDBASQLScripts: login.sql + analysis
#            scripts) as a git clone in ~oracle/sql on a host with a LOCAL
#            repository DB. The shell switcher (setdb, ~/.bashrc.d/ihw_env.sh)
#            exports SQLPATH / ORACLE_PATH to it.
#            - missing / empty ~/sql  -> git clone (with --apply)
#            - existing clone         -> git pull --ff-only (with --apply)
#            - other content          -> WARN, nothing is overwritten
#            - --archive <zip|tgz>    -> offline: unpack into an empty ~/sql
# Call     : ./60-RCU-DB-19c/07-db_sql_scripts.sh
#            ./60-RCU-DB-19c/07-db_sql_scripts.sh --apply
#            ./60-RCU-DB-19c/07-db_sql_scripts.sh --archive <file> --apply
#            ./60-RCU-DB-19c/07-db_sql_scripts.sh --help
# Runs as  : oracle
# Requires : environment.conf, git (09-Install/02-root_os_packages.sh),
#            egress github.com:443 (or --archive)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/07-db_sql_scripts.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
ENV_DB_CONF="$SCRIPT_DIR/environment_db.conf"

source "$LIB" 2>/dev/null || { printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2; }
check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"
# environment_db.conf is optional here (only the two DB_SQL_SCRIPTS_* settings)
[ -f "$ENV_DB_CONF" ] && source "$ENV_DB_CONF"

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false
ARCHIVE=""

_usage() {
    printf "Usage: %s [--apply] [--archive <zip|tar.gz>] [--help]\n\n" "$(basename "$0")"
    printf "  %-22s %s\n" "(none)"            "Dry-run: show the state of ~/sql and what would be done"
    printf "  %-22s %s\n" "--apply"           "git clone (missing / empty) or git pull --ff-only (clone)"
    printf "  %-22s %s\n" "--archive <file>"  "offline: unpack a GitHub ZIP / tar.gz into an empty ~/sql"
    printf "  %-22s %s\n" "--help"            "Show this help"
    printf "\nRuns as: oracle\n"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)   APPLY=true ;;
        --archive) shift; ARCHIVE="${1:-}" ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done

SQL_REPO="${DB_SQL_SCRIPTS_REPO:-https://github.com/gpipperr/OraDBASQLScripts.git}"
SQL_DIR="${DB_SQL_SCRIPTS_DIR:-$HOME/sql}"

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – DBA SQL Scripts (~/sql)\033[0m\n"              | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                                 | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"                    | tee -a "$LOG_FILE"
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                        | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

if [ "$(id -un)" = "root" ]; then
    fail "Run as oracle, not root (the clone belongs to the oracle user)"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

if [ "${LOCAL_REP_DB:-false}" != "true" ]; then
    info "LOCAL_REP_DB is not true – no local database on this host, nothing to do"
    info "  (the SQL scripts belong to the DB host)"
    print_summary; exit $EXIT_CODE
fi
ok "LOCAL_REP_DB = true"

printList "Repository" 22 "$SQL_REPO"
printList "Target"     22 "$SQL_DIR"
[ -L "$SQL_DIR" ] && printList "  symlink to" 22 "$(readlink -f "$SQL_DIR")"

if [ -z "$ARCHIVE" ]; then
    if command -v git > /dev/null 2>&1; then
        ok "git: $(git --version)"
    else
        fail "git not installed – root: 09-Install/02-root_os_packages.sh --apply (git-core)"
        info "  offline alternative: --archive <OraDBASQLScripts-main.zip>"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
fi

# =============================================================================
# 1. State of the target directory
# =============================================================================

section "State of $SQL_DIR"

STATE=""
if [ -e "$SQL_DIR/.git" ]; then
    STATE="clone"
elif [ ! -e "$SQL_DIR" ]; then
    STATE="missing"
elif [ -d "$SQL_DIR" ] && [ -z "$(ls -A "$SQL_DIR" 2>/dev/null)" ]; then
    STATE="empty"
else
    STATE="other"
fi

case "$STATE" in
    clone)
        _remote="$(git -C "$SQL_DIR" remote get-url origin 2>/dev/null)"
        printList "Remote"      22 "${_remote:--}"
        printList "Last commit" 22 "$(git -C "$SQL_DIR" log -1 --format='%h %cs %s' 2>/dev/null)"
        if [ "${_remote%.git}" != "${SQL_REPO%.git}" ]; then
            warn "Clone of a different remote – not changed (DB_SQL_SCRIPTS_REPO = $SQL_REPO)"
            STATE="foreign"
        elif [ -n "$(git -C "$SQL_DIR" status --porcelain 2>/dev/null)" ]; then
            warn "Local changes in the clone – a pull may fail (git -C $SQL_DIR status)"
        else
            ok "Git clone of OraDBASQLScripts, no local changes"
        fi
        unset _remote
        ;;
    missing) info "Not present – will be created" ;;
    empty)   info "Empty directory – will be filled" ;;
    other)
        warn "Directory with files but no git clone: $SQL_DIR – nothing is overwritten"
        info "  Move it aside (mv $SQL_DIR ${SQL_DIR}.old) and run again"
        ;;
esac

# =============================================================================
# 2. Offline: unpack an archive
# =============================================================================

if [ -n "$ARCHIVE" ]; then
    section "Offline archive"
    if [ ! -f "$ARCHIVE" ]; then
        fail "Archive not found: $ARCHIVE"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    printList "Archive" 22 "$ARCHIVE"
    if [ "$STATE" != "missing" ] && [ "$STATE" != "empty" ]; then
        fail "$SQL_DIR is not empty – unpack only into an empty / missing directory"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    if $APPLY; then
        _tmp="$(mktemp -d)"
        case "$ARCHIVE" in
            *.zip)            unzip -q "$ARCHIVE" -d "$_tmp" ;;
            *.tar.gz|*.tgz)   tar -xzf "$ARCHIVE" -C "$_tmp" ;;
            *) fail "Unknown archive type (zip, tar.gz): $ARCHIVE"; rm -rf "${_tmp:?}"; EXIT_CODE=2; print_summary; exit $EXIT_CODE ;;
        esac
        # GitHub archives hold one top directory (OraDBASQLScripts-main/) - strip it
        _src="$_tmp"
        _top="$(ls -A "$_tmp")"
        [ "$(printf '%s\n' "$_top" | wc -l)" -eq 1 ] && [ -d "$_tmp/$_top" ] && _src="$_tmp/$_top"
        mkdir -p "$SQL_DIR"
        cp -a "$_src/." "$SQL_DIR/"
        rm -rf "${_tmp:?}"
        unset _tmp _src _top
        ok "Unpacked into $SQL_DIR ($(find "$SQL_DIR" -maxdepth 1 -name '*.sql' | wc -l) .sql files)"
        info "  Offline copy without .git – update the same way again"
    else
        info "Dry-run – would unpack into $SQL_DIR (--apply)"
    fi
fi

# =============================================================================
# 3. Online: clone or pull
# =============================================================================

if [ -z "$ARCHIVE" ]; then
    section "git clone / pull"
    case "$STATE" in
        missing|empty)
            if timeout 20 git ls-remote --heads "$SQL_REPO" > /dev/null 2>&1; then
                ok "Repository reachable: $SQL_REPO"
            else
                fail "Repository not reachable (egress to github.com:443? 02-Checks/egress_check.sh)"
                info "  offline: download .../archive/refs/heads/main.zip on a workstation, then"
                info "  $(basename "$0") --archive /tmp/OraDBASQLScripts-main.zip --apply"
                EXIT_CODE=2; print_summary; exit $EXIT_CODE
            fi
            if $APPLY; then
                if git clone --quiet "$SQL_REPO" "$SQL_DIR" 2>&1 | tee -a "$LOG_FILE"; then
                    ok "Cloned: $SQL_DIR ($(git -C "$SQL_DIR" log -1 --format='%h %cs'))"
                else
                    fail "git clone failed"
                fi
            else
                info "Dry-run – would run: git clone $SQL_REPO $SQL_DIR"
            fi
            ;;
        clone)
            _behind="$(timeout 30 git -C "$SQL_DIR" fetch --dry-run 2>&1)"
            if [ $? -ne 0 ]; then
                warn "git fetch failed (egress to github.com:443?)"
            elif [ -z "$_behind" ]; then
                ok "Up to date with $SQL_REPO"
            else
                info "Updates available on the remote"
                if $APPLY; then
                    if git -C "$SQL_DIR" pull --ff-only --quiet 2>&1 | tee -a "$LOG_FILE"; then
                        ok "Updated: $(git -C "$SQL_DIR" log -1 --format='%h %cs %s')"
                    else
                        fail "git pull --ff-only failed (local changes / diverged)"
                    fi
                else
                    info "Dry-run – would run: git -C $SQL_DIR pull --ff-only"
                fi
            fi
            unset _behind
            ;;
        *)  info "Skipped (see state above)" ;;
    esac
fi

# =============================================================================
# 4. Use: login.sql + SQLPATH
# =============================================================================

section "Use"

if [ -f "$SQL_DIR/login.sql" ]; then
    ok "login.sql present: $SQL_DIR/login.sql"
elif [ "$STATE" = "missing" ] || [ "$STATE" = "empty" ]; then
    info "login.sql – after --apply"
else
    warn "No login.sql in $SQL_DIR"
fi

if [ -f "$HOME/.bashrc.d/ihw_env.sh" ]; then
    ok "Shell switcher installed (~/.bashrc.d/ihw_env.sh) – a DB entry of setdb exports SQLPATH / ORACLE_PATH = ~/sql"
else
    warn "Shell switcher not installed – SQLPATH is not set (09-Install/03-root_user_oracle.sh)"
    info "  or by hand: export SQLPATH=$SQL_DIR ORACLE_PATH=$SQL_DIR"
fi
info "Use: new shell, setdb -> DB entry, sqlplus / as sysdba, then @<script>"

printf "\n" | tee -a "$LOG_FILE"
info "Next step: 08-db_auto_start.sh --apply"

# =============================================================================
print_summary
exit $EXIT_CODE
