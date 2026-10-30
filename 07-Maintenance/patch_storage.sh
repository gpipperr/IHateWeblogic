#!/bin/bash
# =============================================================================
# Script   : patch_storage.sh
# Purpose  : Local PATCH_STORAGE as a working copy of a (slow, big) patch
#            archive PATCH_ARCHIVE (NFS / ZFS mount, same layout): show what
#            is where, pull the files of the NEXT step to local disk, free the
#            files of the steps that already ran successfully.
#            "Successfully" comes from the run history (log/run_history.csv,
#            written by print_summary of every install / maintenance script).
#            Item list = download/patches_fmw.csv (+ patches_db.csv) and the
#            base installers of oracle_software_version.conf – no own list.
# Call     : ./07-Maintenance/patch_storage.sh [status]
#            ./07-Maintenance/patch_storage.sh pull <script|role> [--apply]
#            ./07-Maintenance/patch_storage.sh clean [--apply] [--yes]
#            ./07-Maintenance/patch_storage.sh history
# Options  : status   per file: local / archive, consumer step, its last
#                     --apply run, proposal (pull / free / keep) – default
#            pull X   copy the files of step X (script name, e.g.
#                     05-oracle_patch_weblogic.sh, or a CSV role, e.g. spb)
#                     from PATCH_ARCHIVE to PATCH_STORAGE (free space checked)
#            clean    free local files of done steps: in the archive -> delete
#                     the local copy; not in the archive -> archive (copy,
#                     verify SHA-256, delete) / delete / keep; plus leftovers
#                     (extracted installers, --fresh-patches archives,
#                     $ORACLE_BASE/tmp staging dirs of finished runs)
#            history  last run per script from the run history
#            --apply  do it (default: show only)
#            --yes    clean without questions: take each proposal
#            --help   Show usage
# Runs as  : oracle
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 07-Maintenance/README.md (patch_storage.sh)
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
# shellcheck source=../09-Install/oracle_software_version.conf
source "$ROOT_DIR/09-Install/oracle_software_version.conf"
# 19c base ZIP of the local RCU database: only DB_INSTALL_ARCHIVE, read in a
# subshell – environment_db.conf sets its own ORACLE_BASE / ORACLE_HOME
DB_CONF="$ROOT_DIR/60-RCU-DB-19c/environment_db.conf"
DB_INSTALL_ARCHIVE=""
if [ "${LOCAL_REP_DB:-false}" = "true" ] && [ -f "$DB_CONF" ]; then
    # shellcheck source=/dev/null
    DB_INSTALL_ARCHIVE="$(source "$DB_CONF" > /dev/null 2>&1; printf '%s' "${DB_INSTALL_ARCHIVE:-}")"
fi

init_log

# =============================================================================
# Arguments
# =============================================================================
CMD="status"; TARGET=""; APPLY=false; YES=false
_usage() {
    printf "Usage: %s [status | pull <script|role> | clean | history] [--apply] [--yes]\n\n" "$(basename "$0")"
    printf "  %-24s %s\n" "status"            "where is each installer / patch, what can be pulled / freed (default)"
    printf "  %-24s %s\n" "pull <script|role>" "copy the files of one step from PATCH_ARCHIVE to PATCH_STORAGE"
    printf "  %-24s %s\n" "clean"             "free local files of steps whose last --apply run succeeded"
    printf "  %-24s %s\n" "history"           "last run per script (log/run_history.csv)"
    printf "  %-24s %s\n" "--apply"           "do it (default: show only)"
    printf "  %-24s %s\n" "--yes"             "clean: take each proposal without asking"
    exit 0
}
while [ $# -gt 0 ]; do
    case "$1" in
        status|clean|history) CMD="$1" ;;
        pull)    CMD="pull"; TARGET="${2:-}"; shift ;;
        --apply) APPLY=true ;;
        --yes)   YES=true ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done
[ "$CMD" = "pull" ] && [ -z "$TARGET" ] && { printf "pull needs a script name or role\n" >&2; exit 1; }

PS="${PATCH_STORAGE:-}"
PA="${PATCH_ARCHIVE:-}"
[ -n "$PS" ] || { fail "PATCH_STORAGE not set in environment.conf"; print_summary; exit 2; }

# =============================================================================
# Consumers: which successful run frees which file
# =============================================================================
# spec "script|script2[ +token][ -token]": +token must, -token must not be in
# the arguments of the --apply run (02b --apply without --upgrade-jdk only
# installs the bootstrap JDK; 05- --opatch-only applies no patch)
_role_consumer() {
    case "$1" in
        opatch|spb|wls)       printf '09-Install/05-oracle_patch_weblogic.sh|07-Maintenance/81-patch_weblogic.sh -opatch-only' ;;
        fr_common|reports|forms|fr_optional)
                              printf '09-Install/06-oracle_patch_forms_reports.sh|07-Maintenance/82-patch_forms_reports.sh' ;;
        jdk)                  printf '09-Install/02b-root_os_java.sh|07-Maintenance/80-patch_java_os.sh +upgrade-jdk' ;;
        client_jdk)           printf '09-Install/40-oracle_forms_client_bundle.sh' ;;
        cvu)                  printf '60-RCU-DB-19c/00b-db_cvu_check.sh' ;;
        apex)                 printf '12-APEX-Ords/03-patch-apex.sh' ;;
        db_*|ojvm|dpbp)       printf '60-RCU-DB-19c/01-db_install_software.sh' ;;
        *)                    printf '' ;;
    esac
}

# _consumer_done SPEC – prints "rc;timestamp;script" of the newest matching
# --apply run with rc 0/1, nothing if none
_consumer_done() {
    local spec="$1" scripts plus="" minus="" t f
    scripts="${spec%% *}"
    for t in ${spec#"$scripts"}; do
        case "$t" in
            +*) plus="--${t#+}" ;;
            -*) minus="--${t#-}" ;;
        esac
    done
    f="$(run_history_file)"
    [ -f "$f" ] || return 0
    # 80-patch_java_os.sh has no --upgrade-jdk: the +token only binds 02b
    awk -F';' -v s="|$scripts|" -v p="$plus" -v m="$minus" '
        NR > 1 && index(s, "|" $4 "|") && $6 == "yes" && $7 <= 1 {
            a = " " $5 " "
            if (m != "" && index(a, " " m " ")) next
            if (p != "" && $4 ~ /02b-root_os_java/ && !index(a, " " p " ")) next
            last = $7 ";" $1 ";" $4
        }
        END { if (last != "") print last }' "$f"
}

# =============================================================================
# Item catalogue: "kind;relpath_local;relpath_archive;consumer_spec;label;role;sha"
#   kind: file (archive-able) | extract (re-creatable, never archived)
# =============================================================================
ITEMS=()
_add() { ITEMS+=("$1;$2;$3;$4;$5;$6;$7"); }

_rel() { printf '%s' "${1#"$2"/}"; }

# CSV rows (role decides whether this installation needs the row)
_need_role() {
    case "$1" in
        forms)       case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in FORMS_AND_REPORTS|FORMS_ONLY) return 0 ;; esac; return 1 ;;
        fr_optional) [ "${REPORTS_BIDIPARENTHESIS:-}" = "YES" ] ;;
        client_jdk)  [ "${FORMS_CLIENT_DIST:-false}" = "true" ] ;;
        cvu|db_*|ojvm|dpbp) [ "${LOCAL_REP_DB:-false}" = "true" ] ;;
        apex)        [ "${INSTALL_APEX:-false}" = "true" ] ;;
        *)           return 0 ;;
    esac
}
_add_csv_rows() {
    local rows="$1" row nr st desc dir re lz az lrel arel sha
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        IFS=';' read -r nr _ re _ st desc dir sha <<< "$row"
        _need_role "$st" || continue
        lz="$(patch_row_zip "$row" "$PS")"
        az=""; [ -n "$PA" ] && az="$(patch_row_zip "$row" "$PA")"
        lrel=""; [ -n "$lz" ] && lrel="$(_rel "$lz" "$PS")"
        arel=""; [ -n "$az" ] && arel="$(_rel "$az" "$PA")"
        # neither copy: show the expected place
        [ -z "$lrel$arel" ] && lrel="${dir:-$nr}/(${re:-p${nr}_*.zip})"
        _add "file" "$lrel" "$arel" "$(_role_consumer "$st")" "$st $nr" "$st" "$sha"
    done <<< "$rows"
}
_add_csv_rows "${IHW_PATCH_ROWS:-}"
if [ "${LOCAL_REP_DB:-false}" = "true" ] && [ -f "$ROOT_DIR/09-Install/download/patches_db.csv" ]; then
    _add_csv_rows "$(grep -E '^[0-9]+;' "$ROOT_DIR/09-Install/download/patches_db.csv")"
fi

# base installers (eDelivery) + their extracted installer
_add "file"    "wls/$FMW_INFRA_ZIP"      "wls/$FMW_INFRA_ZIP"      "09-Install/05-oracle_install_weblogic.sh"      "FMW Infrastructure ZIP" "base" "${FMW_INFRA_SHA256:-}"
_add "extract" "wls/$FMW_INFRA_FILENAME" ""                        "09-Install/05-oracle_install_weblogic.sh"      "extracted $FMW_INFRA_FILENAME" "base" ""
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_AND_REPORTS|FORMS_ONLY|REPORTS_ONLY)
        _add "file"    "fr/$FMW_FR_ZIP"      "fr/$FMW_FR_ZIP"      "09-Install/06-oracle_install_forms_reports.sh" "Forms & Reports ZIP" "base" "${FMW_FR_SHA256:-}"
        _add "extract" "fr/$FMW_FR_FILENAME" ""                    "09-Install/06-oracle_install_forms_reports.sh" "extracted $FMW_FR_FILENAME" "base" "" ;;
esac
# 19c base of the local RCU database (only when it lives below PATCH_STORAGE)
if [ "${LOCAL_REP_DB:-false}" = "true" ]; then
    _db_zip="${DB_INSTALL_ARCHIVE:-$PS/database/LINUX.X64_193000_db_home.zip}"
    case "$_db_zip" in
        "$PS"/*) _add "file" "$(_rel "$_db_zip" "$PS")" "$(_rel "$_db_zip" "$PS")" \
                      "60-RCU-DB-19c/01-db_install_software.sh" "Database 19c base ZIP" "base" "" ;;
    esac
    unset _db_zip
fi
# APEX / ORDS: one item per version directory
if [ "${INSTALL_APEX:-false}" = "true" ]; then
    for _d in "$PS"/apex/[0-9]* "$PS"/ords/[0-9]* ${PA:+"$PA"/apex/[0-9]* "$PA"/ords/[0-9]*}; do
        [ -d "$_d" ] || continue
        case "$_d" in "$PS"/*) _r="$(_rel "$_d" "$PS")" ;; *) _r="$(_rel "$_d" "$PA")" ;; esac
        printf '%s\n' "${ITEMS[@]}" | grep -q ";$_r;" && continue
        case "$_r" in
            apex/*) _add "file" "$_r" "$_r" "12-APEX-Ords/02-install-apex.sh" "APEX ${_r#apex/}" "apex_base" "" ;;
            ords/*) _add "file" "$_r" "$_r" "12-APEX-Ords/04-install-ords.sh" "ORDS ${_r#ords/}" "ords_base" "" ;;
        esac
    done
    unset _d _r
fi

# =============================================================================
# Helpers
# =============================================================================
_size() {   # bytes of a file or directory, empty if missing
    [ -e "$1" ] || return 0
    if [ -d "$1" ]; then du -sbL "$1" 2>/dev/null | cut -f1; else stat -L -c %s "$1" 2>/dev/null; fi
}
_h() {      # human readable
    [ -n "$1" ] || { printf -- '-'; return; }
    numfmt --to=iec "$1" 2>/dev/null || printf '%s' "$1"
}
# _copy SRC DSTDIR – rsync -a --partial (resumable), else cp -p via a .part
# name, so an interrupted copy never looks like a complete file
_copy() {
    local src="$1" dstdir="$2" name
    name="$(basename "$src")"
    if command -v rsync > /dev/null 2>&1; then
        rsync -a --partial "$src" "$dstdir/"
    else
        rm -rf -- "$dstdir/$name.part" && cp -pr -- "$src" "$dstdir/$name.part" \
            && mv -f -- "$dstdir/$name.part" "$dstdir/$name"
    fi
}
_free_bytes() { df -PB1 "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'; }
_short() { basename "${1%%|*}" .sh; }   # first consumer script, short

# _state ITEM – sets S_KIND S_LREL S_AREL S_SPEC S_LABEL S_ROLE S_SHA S_LOC S_ARC
#               S_LSIZE S_ASIZE S_DONE (rc;ts;script or empty)
_state() {
    IFS=';' read -r S_KIND S_LREL S_AREL S_SPEC S_LABEL S_ROLE S_SHA <<< "$1"
    S_LOC=""; S_ARC=""; S_LSIZE=""; S_ASIZE=""
    [ -n "$S_LREL" ] && [ -e "$PS/$S_LREL" ] && { S_LOC=1; S_LSIZE="$(_size "$PS/$S_LREL")"; }
    [ -n "$PA" ] && [ -n "$S_AREL" ] && [ -e "$PA/$S_AREL" ] && { S_ARC=1; S_ASIZE="$(_size "$PA/$S_AREL")"; }
    S_DONE=""; [ -n "$S_SPEC" ] && S_DONE="$(_consumer_done "$S_SPEC")"
}

# _proposal – pull | free | archive | keep | missing | -
_proposal() {
    if [ -n "$S_LOC" ]; then
        if [ -z "$S_DONE" ]; then printf 'keep'
        elif [ "$S_KIND" = "extract" ]; then printf 'free'
        elif [ -n "$S_ARC" ] && [ "$S_LSIZE" = "$S_ASIZE" ]; then printf 'free'
        elif [ -n "$PA" ] && [ -w "$PA" ]; then printf 'archive'
        else printf 'keep'
        fi
    elif [ -n "$S_ARC" ]; then
        [ -z "$S_DONE" ] && printf 'pull' || printf -- '-'
    else
        # extracted installer: re-created from the ZIP; DB patches: AutoUpgrade
        # downloads them online, patches_db.csv is only the offline route
        case "$S_KIND:$S_ROLE" in
            extract:*|*:db_*|*:ojvm|*:dpbp) printf -- '-' ;;
            *) printf 'missing' ;;
        esac
    fi
}

_matches_target() {   # item belongs to the pull target (script or role)?
    local t="$1"
    [ "$S_ROLE" = "$t" ] && return 0
    case "|$S_SPEC" in *"/$t"|*"/$t|"*|*"/$t "*|*"/$t.sh"*) return 0 ;; esac
    return 1
}

# leftovers in $ORACLE_BASE/tmp: staging dirs "<name>_<pid>" of finished runs
_tmp_leftovers() {
    local d pid
    for d in "${ORACLE_BASE:-/u01/app/oracle}"/tmp/{mw_patches,fr_patches,wls_spb,opatch_src,opatch_upgrade}_*; do
        [ -d "$d" ] || continue
        pid="${d##*_}"
        [[ "$pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$pid" ] && continue
        printf '%s\n' "$d"
    done
}

# =============================================================================
# status / history
# =============================================================================
_show_status() {
    section "Patch storage – local $PS / archive ${PA:-(none)}"
    [ -n "$PA" ] && [ ! -d "$PA" ] && warn "PATCH_ARCHIVE not mounted / not found: $PA"
    printf "  %-26s %7s %-3s %-3s %-30s %-16s %s\n" "Item" "Size" "Loc" "Arc" "Needed by" "Last --apply ok" "Proposal" \
        | tee -a "${LOG_FILE:-/dev/null}"
    local it p free_sum=0 pull_sum=0
    for it in "${ITEMS[@]}"; do
        _state "$it"
        p="$(_proposal)"
        printf "  %-26s %7s %-3s %-3s %-30s %-16s %s\n" "${S_LABEL:0:26}" "$(_h "${S_LSIZE:-$S_ASIZE}")" \
            "${S_LOC:+yes}" "${S_ARC:+yes}" "$(_short "$S_SPEC")" "$(printf '%s' "$S_DONE" | cut -d';' -f2 | cut -c1-16)" "$p" \
            | tee -a "${LOG_FILE:-/dev/null}"
        case "$p" in
            free|archive) free_sum=$(( free_sum + ${S_LSIZE:-0} )) ;;
            pull)         pull_sum=$(( pull_sum + ${S_ASIZE:-0} )) ;;
            missing)      warn "$(printf "  %s: neither local nor in the archive – 09-Install/04-oracle_pre_download.sh" "$S_LABEL")" ;;
        esac
    done
    local d n=0 s=0
    for d in "$PS"/patches_[0-9]* "$PS"/client/jdk_[0-9]*; do
        [ -d "$d" ] || continue; n=$((n + 1)); s=$(( s + $(_size "$d") ))
    done
    [ "$n" -gt 0 ] && info "$(printf "  %d --fresh-patches archive dir(s) in PATCH_STORAGE: %s (clean)" "$n" "$(_h "$s")")"
    free_sum=$(( free_sum + s ))
    n=0; s=0
    while IFS= read -r d; do [ -n "$d" ] && { n=$((n + 1)); s=$(( s + $(_size "$d") )); }; done < <(_tmp_leftovers)
    [ "$n" -gt 0 ] && info "$(printf "  %d staging dir(s) of finished runs in \$ORACLE_BASE/tmp: %s (clean)" "$n" "$(_h "$s")")"
    free_sum=$(( free_sum + s ))
    if [ -d "${ORACLE_HOME:-/nonexistent}/.patch_storage" ]; then
        info "$(printf "  \$ORACLE_HOME/.patch_storage (OPatch rollback data): %s – Oracle's own cleanup: opatch util cleanup" \
            "$(_h "$(_size "$ORACLE_HOME/.patch_storage")")")"
    fi
    printLine
    ok "$(printf "Free in PATCH_STORAGE: %s  |  can be freed (clean): %s  |  to pull for pending steps: %s" \
        "$(_h "$(_free_bytes "$PS")")" "$(_h "$free_sum")" "$(_h "$pull_sum")")"
    [ -n "$PA" ] || info "No PATCH_ARCHIVE – everything stays local; clean can only delete (09-Install/01-setup-interview.sh)"
}

_show_history() {
    local f; f="$(run_history_file)"
    section "Run history – last run per script ($f)"
    [ -f "$f" ] || { info "No run history yet"; return 0; }
    awk -F';' 'NR > 1 { last[$4] = $1 "  apply=" $6 "  rc=" $7 "  (OK " $8 " WARN " $9 " FAIL " $10 ")" }
               END { for (s in last) printf "  %-48s %s\n", s, last[s] }' "$f" | sort | tee -a "${LOG_FILE:-/dev/null}"
}

# =============================================================================
# pull
# =============================================================================
_pull() {
    section "Pull for '$TARGET' – $PA -> $PS"
    [ -n "$PA" ] || { fail "PATCH_ARCHIVE not set – nothing to pull from (09-Install/01-setup-interview.sh)"; return; }
    [ -d "$PA" ] || { fail "PATCH_ARCHIVE not mounted: $PA"; return; }
    local it need=0 list=() free hit=0
    for it in "${ITEMS[@]}"; do
        _state "$it"
        _matches_target "$TARGET" || continue
        hit=1
        if [ -n "$S_LOC" ]; then
            ok "$(printf "  %-28s already local" "$S_LABEL")"
        elif [ -n "$S_ARC" ]; then
            list+=("$it"); need=$(( need + S_ASIZE ))
            info "$(printf "  %-28s %8s  %s" "$S_LABEL" "$(_h "$S_ASIZE")" "$S_AREL")"
        elif [ "$S_KIND" != "extract" ]; then
            warn "$(printf "  %-28s not in the archive either – download first" "$S_LABEL")"
        fi
    done
    [ "$hit" -eq 1 ] || { fail "No item belongs to '$TARGET' (script name like 05-oracle_patch_weblogic.sh or role like spb)"; return; }
    [ "${#list[@]}" -gt 0 ] || { ok "Nothing to pull for '$TARGET'"; return; }
    free="$(_free_bytes "$PS")"
    if [ -n "$free" ] && [ "$free" -lt $(( need + need / 10 )) ]; then
        fail "$(printf "Not enough space in %s: need %s (+10 %%), free %s – run clean first" "$PS" "$(_h "$need")" "$(_h "$free")")"
        return
    fi
    ok "$(printf "Space OK: need %s, free %s" "$(_h "$need")" "$(_h "$free")")"
    $APPLY || { info "Show only – add --apply to copy"; return; }
    command -v rsync > /dev/null 2>&1 || info "rsync not installed – cp is used (not resumable; dnf install rsync)"
    for it in "${list[@]}"; do
        _state "$it"
        mkdir -p "$(dirname "$PS/$S_AREL")"
        info "Copying $S_AREL ..."
        if _copy "$PA/$S_AREL" "$(dirname "$PS/$S_AREL")"; then
            if [ "$(_size "$PS/$S_AREL")" = "$S_ASIZE" ]; then
                ok "$(printf "  %-28s copied (%s)" "$S_LABEL" "$(_h "$S_ASIZE")")"
                if [ -n "$S_SHA" ] && [ -f "$PS/$S_AREL" ]; then
                    [ "$(sha256sum "$PS/$S_AREL" | awk '{print tolower($1)}')" = "$(printf '%s' "$S_SHA" | tr 'A-F' 'a-f')" ] \
                        && ok "  SHA-256 matches the list" \
                        || warn "  SHA-256 differs from the list (re-released by Oracle?) – compare on MOS"
                fi
            else
                fail "  $S_LABEL: size differs after the copy – check $PS/$S_AREL"
            fi
        else
            fail "  copy failed: $PA/$S_AREL"
        fi
    done
}

# =============================================================================
# clean
# =============================================================================
# _ask_action DEFAULT CHOICES – a | d | k (stdin is the terminal)
_ask_action() {
    local def="$1" choices="$2" ans
    if $YES || [ ! -t 0 ]; then printf '%s' "$def"; return; fi
    printf "      %s [%s]: " "$choices" "$def" > /dev/tty
    read -r ans < /dev/tty
    ans="${ans:-$def}"
    printf '%s' "${ans:0:1}"
}

_rm_local() {   # only below PATCH_STORAGE or $ORACLE_BASE/tmp
    local p="$1"
    case "$p" in
        "$PS"/?*|"${ORACLE_BASE:-/nonexistent}"/tmp/?*) ;;
        *) fail "Refusing to delete outside PATCH_STORAGE / ORACLE_BASE/tmp: $p"; return 1 ;;
    esac
    rm -rf -- "$p" && ok "  deleted $p" || return 1
    rmdir --ignore-fail-on-non-empty -- "$(dirname "$p")" 2>/dev/null   # empty patches/<nr>/
    return 0
}

_archive_then_rm() {   # copy to the archive, verify, delete local
    local rel="$1" src="$PS/$1" dst="$PA/$1"
    mkdir -p "$(dirname "$dst")" || { fail "  cannot create $(dirname "$dst")"; return 1; }
    _copy "$src" "$(dirname "$dst")" || { fail "  copy to the archive failed: $rel"; return 1; }
    if [ -f "$src" ]; then
        [ "$(sha256sum "$src" | cut -d' ' -f1)" = "$(sha256sum "$dst" | cut -d' ' -f1)" ] \
            || { fail "  SHA-256 of the archive copy differs – local copy kept: $rel"; return 1; }
    else
        [ "$(_size "$src")" = "$(_size "$dst")" ] \
            || { fail "  size of the archive copy differs – local copy kept: $rel"; return 1; }
    fi
    ok "  archived (verified): $dst"
    _rm_local "$src"
}

_clean() {
    section "Clean – free local files of finished steps"
    $APPLY || info "Show only – add --apply (and answer per file, or --yes for the proposals)"
    local it p a freed=0 choices
    for it in "${ITEMS[@]}"; do
        _state "$it"
        [ -n "$S_LOC" ] || continue
        p="$(_proposal)"
        [ "$p" = "keep" ] && [ -z "$S_DONE" ] && continue      # step still pending
        info "$(printf "  %-28s %8s  %s  (%s done %s)" "$S_LABEL" "$(_h "$S_LSIZE")" "$S_LREL" \
            "$(_short "$(printf '%s' "$S_DONE" | cut -d';' -f3)")" "$(printf '%s' "$S_DONE" | cut -d';' -f2)")"
        $APPLY || { info "      proposal: $p"; continue; }
        case "$p" in
            free)    choices="[d]elete local copy ($( [ -n "$S_ARC" ] && printf 'copy in the archive' || printf 're-created from the ZIP' )) / [k]eep"
                     a="$(_ask_action d "$choices")" ;;
            archive) a="$(_ask_action a "[a]rchive (copy+verify+delete) / [d]elete / [k]eep")" ;;
            *)       a="$(_ask_action k "[d]elete (no archive copy – download again when needed) / [k]eep")" ;;
        esac
        case "$a" in
            d) _rm_local "$PS/$S_LREL" && freed=$(( freed + S_LSIZE )) ;;
            a) if [ -n "$PA" ] && [ -w "$PA" ]; then
                   _archive_then_rm "$S_LREL" && freed=$(( freed + S_LSIZE ))
               else
                   warn "  no writable PATCH_ARCHIVE – kept"
               fi ;;
            *) info "      kept" ;;
        esac
    done

    # --fresh-patches archives of earlier cycles
    local d s
    for d in "$PS"/patches_[0-9]* "$PS"/client/jdk_[0-9]*; do
        [ -d "$d" ] || continue
        s="$(_size "$d")"
        info "$(printf "  %-28s %8s  %s" "old cycle (--fresh-patches)" "$(_h "$s")" "${d#"$PS"/}")"
        $APPLY || { info "      proposal: $( [ -n "$PA" ] && printf archive || printf delete )"; continue; }
        if [ -n "$PA" ] && [ -w "$PA" ]; then
            a="$(_ask_action a "[a]rchive / [d]elete / [k]eep")"
        else
            a="$(_ask_action d "[d]elete / [k]eep")"
        fi
        case "$a" in
            d) _rm_local "$d" && freed=$(( freed + s )) ;;
            a) [ -n "$PA" ] && _archive_then_rm "${d#"$PS"/}" && freed=$(( freed + s )) ;;
            *) info "      kept" ;;
        esac
    done

    # staging dirs of finished runs ($ORACLE_BASE/tmp/<name>_<pid>, pid gone)
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        s="$(_size "$d")"
        info "$(printf "  %-28s %8s  %s" "staging leftover" "$(_h "$s")" "$d")"
        $APPLY || { info "      proposal: delete"; continue; }
        a="$(_ask_action d "[d]elete / [k]eep")"
        [ "$a" = "d" ] && _rm_local "$d" && freed=$(( freed + s ))
    done < <(_tmp_leftovers)

    printLine
    $APPLY && ok "$(printf "Freed: %s  |  free in PATCH_STORAGE now: %s" "$(_h "$freed")" "$(_h "$(_free_bytes "$PS")")")"
}

# =============================================================================
# Main
# =============================================================================
printLine
section "patch_storage.sh $CMD – $(date '+%Y-%m-%d %H:%M:%S')"
case "$CMD" in
    status)  _show_status ;;
    history) _show_history ;;
    pull)    _pull ;;
    clean)   _clean ;;
esac
print_summary
exit "$EXIT_CODE"
