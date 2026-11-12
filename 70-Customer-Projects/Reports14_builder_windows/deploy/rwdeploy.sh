#!/bin/bash
# =============================================================================
# rwdeploy.sh - deployment queue for Oracle Reports sources (.rdf + images)
# =============================================================================
# Runs on the Linux Reports server (DEV or PROD) as the SSH forced command of
# the GitLab deploy key (authorized_keys: command="...rwdeploy.sh",restrict,
# from="<runner ip>"). The GitLab job sends a tar of the files to deploy;
# rwdeploy.sh queues it and a worker copies the files into the Reports source
# folders - one job after the other, with a backup of every replaced file.
#
# Commands (from SSH_ORIGINAL_COMMAND, or as arguments when run locally):
#   enqueue <sha> <delta|tag|snapshot>  tar on stdin -> spool/incoming, start worker
#   status  <sha> [--wait <sec>]     result of the newest job for <sha>
#                                    exit 0 = done, 1 = failed, 2 = pending
#   last                             SHA of the last successful job (or "none")
#   list                             the last 15 jobs with their state
#   work                             run the worker (also from cron)
#
# delta    (DEV)  : push to main - the files changed since the last DEV deploy
# tag      (PROD) : tag prod-* - the files of the tagged commit (one report)
# snapshot        : the whole source/ + images/ (not used by
#                   ci_deploy.sh any more; files missing in git but present
#                   on the server -> warning)
# Nothing is ever deleted on the server.
#
# Config: rwdeploy.conf next to this script (or RWDEPLOY_CONF), see
#         rwdeploy.conf.template.
# Doc   : Git_deploy.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
# =============================================================================

set -u
set -f          # no globbing of the remote command words
umask 022

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
CONF="${RWDEPLOY_CONF:-$SCRIPT_DIR/rwdeploy.conf}"

say()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

[ -r "$CONF" ] || die "config not found: $CONF"
# shellcheck source=/dev/null
. "$CONF"

: "${SPOOL_DIR:?SPOOL_DIR missing in $CONF}"
: "${TARGET_SOURCE_DIR:?TARGET_SOURCE_DIR missing in $CONF}"
: "${TARGET_IMAGE_DIR:?TARGET_IMAGE_DIR missing in $CONF}"
MAX_TAR_MB="${MAX_TAR_MB:-100}"

IN="$SPOOL_DIR/incoming"
WORK="$SPOOL_DIR/work"
DONE="$SPOOL_DIR/done"
FAILED="$SPOOL_DIR/failed"
LOGD="$SPOOL_DIR/log"
STAGE="$SPOOL_DIR/staging"
BACKUP="$SPOOL_DIR/backup"
STATE="$SPOOL_DIR/state"
for d in "$IN" "$WORK" "$DONE" "$FAILED" "$LOGD" "$STAGE" "$BACKUP" "$STATE"; do
    mkdir -p "$d" || die "cannot create $d"
done

valid_sha() { [[ "$1" =~ ^[0-9a-f]{7,40}$ ]]; }

# --- enqueue ------------------------------------------------------------------
cmd_enqueue() {
    local sha="${1:-}" kind="${2:-}"
    valid_sha "$sha" || die "invalid sha '$sha'"
    [[ "$kind" == "delta" || "$kind" == "tag" || "$kind" == "snapshot" ]] || die "kind must be delta, tag or snapshot"

    local job part max size
    job="$(date +%Y%m%d-%H%M%S-%N)-${sha:0:12}"
    part="$IN/.$job.part"
    max=$(( MAX_TAR_MB * 1024 * 1024 ))
    # read at most max+1 bytes - more means: too large
    head -c $(( max + 1 )) > "$part" || { rm -f "$part"; die "cannot write $part"; }
    size=$(stat -c %s "$part")
    if [ "$size" -gt "$max" ]; then
        rm -f "$part"
        die "tar larger than MAX_TAR_MB=$MAX_TAR_MB"
    fi
    printf 'sha=%s\nkind=%s\nfrom=%s\nqueued=%s\n' \
        "$sha" "$kind" "${SSH_CLIENT%% *}" "$(date '+%Y-%m-%d %H:%M:%S')" > "$IN/$job.meta"
    mv "$part" "$IN/$job.tar"       # atomic: the worker only sees complete jobs
    say "QUEUED $job ($kind, $size bytes)"

    # start the worker in the background (does nothing if one is running)
    SSH_ORIGINAL_COMMAND='' nohup setsid "$SCRIPT" work > /dev/null 2>&1 < /dev/null &
}

# --- helpers for status -------------------------------------------------------
# newest job file for a sha in a folder (job names start with a timestamp)
newest_job() {
    local dir="$1" sha="$2" f best=""
    for f in "$dir"/*-"${sha:0:12}".*; do
        [ -e "$f" ] || continue
        best="$f"
    done
    printf '%s' "$best"
}

job_state() {
    local sha="$1" d f best="" state=""
    set +f
    for d in "$IN:pending" "$WORK:running" "$DONE:done" "$FAILED:failed"; do
        f="$(newest_job "${d%%:*}" "$sha")"
        [ -n "$f" ] || continue
        if [ -z "$best" ] || [[ "$(basename "$f")" > "$(basename "$best")" ]]; then
            best="$f"; state="${d##*:}"
        fi
    done
    set -f
    [ -n "$best" ] || return 1
    best="$(basename "$best")"
    printf '%s %s' "$state" "${best%.*}"
}

cmd_status() {
    local sha="${1:-}" wait=0 waited=0 st state job
    valid_sha "$sha" || die "invalid sha '$sha'"
    if [ "${2:-}" = "--wait" ]; then
        [[ "${3:-}" =~ ^[0-9]{1,4}$ ]] || die "--wait needs seconds (0-9999)"
        wait="$3"
    fi
    while :; do
        st="$(job_state "$sha")" || die "no job for $sha" 3
        state="${st%% *}"; job="${st#* }"
        if [ "$state" = "done" ] || [ "$state" = "failed" ]; then
            break
        fi
        if [ "$waited" -ge "$wait" ]; then
            say "PENDING $job ($state)"
            exit 2
        fi
        sleep 2; waited=$(( waited + 2 ))
    done
    [ -r "$LOGD/$job.log" ] && cat "$LOGD/$job.log"
    if [ "$state" = "done" ]; then
        say "DONE $job"
        exit 0
    fi
    say "FAILED $job"
    exit 1
}

cmd_last() {
    if [ -s "$STATE/last_sha" ]; then
        cat "$STATE/last_sha"
    else
        say "none"
    fi
}

cmd_list() {
    local f n state
    set +f
    for f in "$IN"/*.meta "$WORK"/*.meta "$DONE"/*.meta "$FAILED"/*.meta; do
        [ -e "$f" ] || continue
        case "$f" in
            "$IN"/*) state="pending" ;; "$WORK"/*) state="running" ;;
            "$DONE"/*) state="done" ;; *) state="failed" ;;
        esac
        n="$(basename "$f" .meta)"
        printf '%s %-8s %s\n' "$n" "$state" "$(sed -n 's/^kind=//p' "$f")"
    done | sort | tail -15
    set -f
}

# --- worker -------------------------------------------------------------------
# allowed tar members (paths as in the repository): directories source/,
# images/, files source/<name>.rdf and images/<name> - nothing else
member_ok() {
    local m="$1"
    case "$m" in
        /*|*..*) return 1 ;;
    esac
    [[ "$m" =~ ^(source|images)/$ ]] && return 0
    [[ "$m" =~ ^source/[^/]+\.rdf$ ]] && return 0
    [[ "$m" =~ ^images/[^/]+$ ]] && return 0
    return 1
}

process_job() {
    local job="$1" log="$LOGD/$1.log" tar meta sha kind stage bad=0
    local line type name rel target copied=0 same=0
    mv "$IN/$job.tar" "$WORK/$job.tar" && mv "$IN/$job.meta" "$WORK/$job.meta" || return
    tar="$WORK/$job.tar"; meta="$WORK/$job.meta"
    sha="$(sed -n 's/^sha=//p' "$meta")"; kind="$(sed -n 's/^kind=//p' "$meta")"
    stage="$STAGE/$job"

    {
        say "job $job  sha $sha  kind $kind  start $(date '+%Y-%m-%d %H:%M:%S')"
        # 1. check every member BEFORE extracting: type (file / dir) and name
        if ! tar -tvf "$tar" > "$stage.list" 2> /dev/null; then
            say "ERROR: not a readable tar"; bad=1
        fi
        if [ "$bad" -eq 0 ]; then
            while IFS= read -r line; do
                type="${line:0:1}"
                if [ "$type" != "-" ] && [ "$type" != "d" ]; then
                    say "ERROR: not a plain file or folder: $line"; bad=1
                fi
            done < "$stage.list"
            while IFS= read -r name; do
                if ! member_ok "$name"; then
                    say "ERROR: path not allowed: $name"; bad=1
                fi
            done < <(tar -tf "$tar")
        fi
        rm -f "$stage.list"

        # 2. extract into staging, then copy changed files with backup
        if [ "$bad" -eq 0 ]; then
            mkdir -p "$stage"
            tar -xf "$tar" -C "$stage" --no-same-owner --no-same-permissions || bad=1
        fi
        if [ "$bad" -eq 0 ] && { [ -d "$stage/source" ] || [ -d "$stage/images" ]; }; then
            while IFS= read -r -d '' rel; do
                rel="${rel#"$stage"/}"
                case "$rel" in
                    source/*) target="$TARGET_SOURCE_DIR/${rel#source/}" ;;
                    images/*) target="$TARGET_IMAGE_DIR/${rel#images/}" ;;
                    *) continue ;;
                esac
                if [ -f "$target" ] && cmp -s "$stage/$rel" "$target"; then
                    same=$(( same + 1 )); continue
                fi
                if [ -f "$target" ]; then
                    mkdir -p "$BACKUP/$job/$(dirname "$rel")"
                    cp -p "$target" "$BACKUP/$job/$rel" || { say "ERROR: backup of $target"; bad=1; break; }
                fi
                # copy to a temp name, then rename - Reports never reads half a file
                if cp "$stage/$rel" "$target.rwdeploy.tmp" && mv "$target.rwdeploy.tmp" "$target"; then
                    say "  copied  $rel -> $target"
                    copied=$(( copied + 1 ))
                else
                    rm -f "$target.rwdeploy.tmp"
                    say "ERROR: copy $rel -> $target"; bad=1; break
                fi
            done < <(find "$stage" -type f -print0 | sort -z)
        fi

        # 3. snapshot: files on the server that are no longer in git
        if [ "$bad" -eq 0 ] && [ "$kind" = "snapshot" ]; then
            set +f
            for target in "$TARGET_SOURCE_DIR"/*.rdf; do
                [ -e "$target" ] || continue
                [ -e "$stage/source/$(basename "$target")" ] || \
                    say "  WARNING not in git (kept): $target"
            done
            set -f
        fi
        say "copied $copied, unchanged $same"
    } >> "$log" 2>&1

    rm -rf "$stage"
    if [ "$bad" -eq 0 ]; then
        printf '%s\n' "$sha" > "$STATE/last_sha.tmp" && mv "$STATE/last_sha.tmp" "$STATE/last_sha"
        mv "$tar" "$meta" "$DONE/"
        say "result DONE $(date '+%Y-%m-%d %H:%M:%S')" >> "$log"
    else
        mv "$tar" "$meta" "$FAILED/"
        say "result FAILED $(date '+%Y-%m-%d %H:%M:%S') - nothing more copied" >> "$log"
    fi
}

cmd_work() {
    local next f
    exec 9> "$SPOOL_DIR/worker.lock"
    flock -n 9 || exit 0            # another worker is running - it takes the job
    while :; do
        next=""
        set +f
        for f in "$IN"/*.tar; do
            [ -e "$f" ] || continue
            next="$(basename "$f" .tar)"; break   # oldest first (timestamp names)
        done
        set -f
        [ -n "$next" ] || break
        [ -e "$IN/$next.meta" ] || { sleep 1; [ -e "$IN/$next.meta" ] || { mv "$IN/$next.tar" "$FAILED/"; continue; }; }
        process_job "$next"
    done
    exec 9>&-
    # a job queued while this worker was finishing: start again
    set +f
    for f in "$IN"/*.tar; do
        [ -e "$f" ] && exec "$SCRIPT" work
    done
    set -f
}

# --- main -------------------------------------------------------------------
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    read -r -a ARGS <<< "$SSH_ORIGINAL_COMMAND"
else
    ARGS=("$@")
fi
[ "${#ARGS[@]}" -gt 0 ] || die "usage: enqueue <sha> <delta|tag|snapshot> | status <sha> [--wait N] | last | list | work"

case "${ARGS[0]}" in
    enqueue) cmd_enqueue "${ARGS[1]:-}" "${ARGS[2]:-}" ;;
    status)  cmd_status "${ARGS[1]:-}" "${ARGS[2]:-}" "${ARGS[3]:-}" ;;
    last)    cmd_last ;;
    list)    cmd_list ;;
    work)    cmd_work ;;
    *)       die "unknown command '${ARGS[0]}'" ;;
esac
exit 0
