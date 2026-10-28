#!/bin/bash
# =============================================================================
# Script   : mos_patch_download.sh
# Purpose  : Download a list of My Oracle Support patches (CSV) in one run with
#            getMOSPatch.jar - the right platform and file per patch, a check
#            of every ZIP (unzip -t, SHA-256) and a summary.
#            Standalone - no IHateWeblogic library, plain bash + coreutils +
#            Java (for getMOSPatch) + python (pseudo terminal for the password).
# Call     : ./mos_patch_download.sh -c <patches.csv> -d <patch dir> [--apply]
#              -c FILE      patch list (format: see the header of the CSV files
#                           in 70-Customer-Projects/*/patches_*.csv)
#              -d DIR       target directory, one sub-directory per patch
#              -j JAR       getMOSPatch.jar (default: ./getMOSPatch.jar, then
#                           <DIR>/getMOSPatch.jar, then the script directory)
#              -u USER      MOS user (default: $MOS_USER, else asked)
#              --all        also the rows with required=optional
#              --only N,N   only these patch numbers
#              --java JAVA  Java binary (default: $JAVA_HOME/bin/java, java in PATH)
#              --proxy H:P  HTTPS proxy for getMOSPatch (-Dhttps.proxyHost/Port)
#              --apply      download (default: show the plan only)
#            The MOS password is asked once (hidden) and typed into
#            getMOSPatch through a pseudo terminal - never on a command line,
#            never stored, masked in the output.
# Output   : <DIR>/<patch>/p<patch>_*.zip, <DIR>/patches_sha256.txt,
#            <DIR>/mos_patch_download_<ts>.log
# Exit     : 0 = all required patches present, 1 = optional missing,
#            2 = required missing / error
# Doc      : 70-Customer-Projects/tools/README.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================
set -u
umask 022
VERSION="2026-10-28.2"   # bump on every change

CSV=""; DIR=""; JAR=""; MOS_USER="${MOS_USER:-}"; ALL=false; ONLY=""; APPLY=false
JAVA_BIN=""; PROXY=""; LANG_CODE="4L"; RETRIES=3
while [ $# -gt 0 ]; do
    case "$1" in
        -c) CSV="${2:-}"; shift ;;
        -d) DIR="${2:-}"; shift ;;
        -j) JAR="${2:-}"; shift ;;
        -u) MOS_USER="${2:-}"; shift ;;
        --all) ALL=true ;;
        --only) ONLY=",${2:-},"; shift ;;
        --java) JAVA_BIN="${2:-}"; shift ;;
        --proxy) PROXY="${2:-}"; shift ;;
        --apply) APPLY=true ;;
        -h|--help) sed -n '2,31p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$CSV" ] && [ -n "$DIR" ] || { sed -n '9,25p' "$0"; exit 2; }
[ -f "$CSV" ] || { printf 'CSV not found: %s\n' "$CSV" >&2; exit 2; }

mkdir -p "$DIR" || { printf 'Cannot create %s\n' "$DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/mos_patch_download_$(date +%Y%m%d_%H%M%S).log"
N_OK=0; N_WARN=0; N_FAIL=0

# --- output helpers (stdout + log) ----------------------------------------------
_p()   { printf '%s\n' "$*" | tee -a "$LOG"; }
ok()   { N_OK=$((N_OK + 1));     printf '\033[32m  OK  \033[0m %s\n' "$*"; printf '  OK   %s\n' "$*" >> "$LOG"; }
warn() { N_WARN=$((N_WARN + 1)); printf '\033[33m WARN \033[0m %s\n' "$*"; printf ' WARN  %s\n' "$*" >> "$LOG"; }
fail() { N_FAIL=$((N_FAIL + 1)); printf '\033[31m FAIL \033[0m %s\n' "$*"; printf ' FAIL  %s\n' "$*" >> "$LOG"; }
info() { printf '       %s\n' "$*" | tee -a "$LOG"; }
section() { _p ""; _p "=== $* ==="; }

_p "mos_patch_download.sh $VERSION – $(date '+%Y-%m-%d %H:%M:%S') – $(hostname -s 2>/dev/null)"
_p "CSV : $CSV"
_p "Dir : $DIR"
_p "Mode: $($APPLY && printf 'APPLY (download)' || printf 'plan only (use --apply to download)')"

# =============================================================================
# 1. Prerequisites
# =============================================================================
section "1. Prerequisites"
if [ -z "$JAVA_BIN" ]; then
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then JAVA_BIN="$JAVA_HOME/bin/java"
    else JAVA_BIN="$(command -v java 2>/dev/null)"; fi
fi
if [ -n "$JAVA_BIN" ] && [ -x "$JAVA_BIN" ]; then
    ok "Java: $JAVA_BIN ($("$JAVA_BIN" -version 2>&1 | head -1))"
else
    fail "No Java found – set JAVA_HOME or use --java"
fi
if [ -z "$JAR" ]; then
    for _j in ./getMOSPatch.jar "$DIR/getMOSPatch.jar" "$SCRIPT_DIR/getMOSPatch.jar"; do
        [ -f "$_j" ] && { JAR="$(cd "$(dirname "$_j")" && pwd)/$(basename "$_j")"; break; }
    done
fi
[ -n "$JAR" ] && [ -f "$JAR" ] && ok "getMOSPatch: $JAR" \
    || fail "getMOSPatch.jar not found (-j, ./, $DIR, $SCRIPT_DIR) – see tools/README.md"
for _t in unzip sha256sum; do
    command -v "$_t" > /dev/null 2>&1 && ok "$_t found" || fail "$_t not installed"
done
PY=""
for _p in python3 /usr/libexec/platform-python python; do
    command -v "$_p" > /dev/null 2>&1 && { PY="$(command -v "$_p")"; break; }
done
[ -n "$PY" ] && ok "python for the password terminal: $PY" \
    || warn "no python – getMOSPatch asks for user / password itself for every patch"
_free="$(df -Pk "$DIR" | awk 'NR==2 { printf "%d", $4 / 1048576 }')"
if [ "${_free:-0}" -lt 15 ]; then warn "Free space in $DIR: ${_free} GB (recommended >= 15 GB for a CPU set)"
else ok "Free space in $DIR: ${_free} GB"; fi
JAVA_OPTS=()
if [ -n "$PROXY" ]; then
    JAVA_OPTS=(-Dhttps.proxyHost="${PROXY%:*}" -Dhttps.proxyPort="${PROXY##*:}")
    info "HTTPS proxy: $PROXY"
fi
[ "$N_FAIL" -gt 0 ] && { _p ""; _p "Prerequisites missing – nothing downloaded"; exit 2; }

# =============================================================================
# 2. Read the CSV
# =============================================================================
section "2. Patch list"
ROWS=()
while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%$'\r'}"
    case "$_line" in ''|'#'*|patch\;*) continue ;; esac
    IFS=';' read -r _nr _plat _re _req _step _desc <<< "$_line"
    [[ "$_nr" =~ ^[0-9]+$ ]] || { warn "skipped line (no patch number): $_line"; continue; }
    if [ -n "$ONLY" ] && [[ "$ONLY" != *",$_nr,"* ]]; then continue; fi
    if [ "${_req:-yes}" != "yes" ] && ! $ALL && [ -z "$ONLY" ]; then
        info "$(printf '%-10s optional – skipped (use --all)  %s' "$_nr" "$_desc")"; continue
    fi
    ROWS+=("$_nr;$_plat;$_re;${_req:-yes};$_step;$_desc")
    info "$(printf '%-10s %-11s step %-6s %-9s %s' "$_nr" "$_plat" "${_step:--}" "${_req:-yes}" "$_desc")"
done < "$CSV"
[ "${#ROWS[@]}" -gt 0 ] || { fail "no patch selected"; exit 2; }
info "${#ROWS[@]} patch(es) selected"

# _have NR REGEX - is a matching ZIP already in <DIR>/<NR>/ ?
_have() {
    local f b
    for f in "$DIR/$1"/*.zip; do
        [ -f "$f" ] || continue; b="$(basename "$f")"
        if [ -n "$2" ]; then [[ "$b" =~ ^$2$ ]] && return 0
        else [[ "$b" == p"$1"_* ]] && return 0; fi
    done
    return 1
}

if ! $APPLY; then
    section "Plan"
    for _r in "${ROWS[@]}"; do
        IFS=';' read -r _nr _plat _re _req _step _desc <<< "$_r"
        if _have "$_nr" "$_re"; then info "$(printf '%-10s present – will be skipped' "$_nr")"
        else info "$(printf '%-10s download  platform %-11s file %s' "$_nr" "$_plat" "${_re:-<all>}")"; fi
    done
    _p ""; _p "Plan only – start with --apply (MOS user + password are asked once)"
    exit 0
fi

# =============================================================================
# 3. Download
# =============================================================================
section "3. Download"
if [ -z "$MOS_USER" ]; then printf '  MOS user (e-mail): '; read -r MOS_USER; fi
printf '  MOS password for %s: ' "$MOS_USER"; read -rs MOS_PWD; printf '\n'
[ -n "$MOS_PWD" ] || { fail "empty password"; exit 2; }

# _gmp ARGS... - getMOSPatch in a pseudo terminal; user / password typed when
# asked (same mechanism as 09-Install/04-oracle_pre_download.sh, 2026-10-20)
_gmp() {
    if [ -z "$PY" ]; then
        "$JAVA_BIN" "${JAVA_OPTS[@]}" -jar "$JAR" "$@"; return $?
    fi
    printf '%s\n%s\n' "$MOS_USER" "$MOS_PWD" | "$PY" -I -c '
import os, pty, select, sys
user = sys.stdin.readline().rstrip("\n"); pwd = sys.stdin.readline().rstrip("\n")
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
tail, sent_u, sent_p = b"", False, False
while True:
    r, _, _ = select.select([fd], [], [], 1800)
    if not r:
        break
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    tail = (tail + d)[-300:].lower()
    if not sent_u and b"username" in tail:
        os.write(fd, (user + "\n").encode()); sent_u, tail = True, b""
    elif sent_u and not sent_p and b"password" in tail:
        os.write(fd, (pwd + "\n").encode()); sent_p, tail = True, b""
    if pwd:
        d = d.replace(pwd.encode(), b"****")
    sys.stdout.buffer.write(d); sys.stdout.flush()
_, st = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 1)
' "$JAVA_BIN" "${JAVA_OPTS[@]}" -jar "$JAR" "$@"
}

for _r in "${ROWS[@]}"; do
    IFS=';' read -r _nr _plat _re _req _step _desc <<< "$_r"
    _d="$DIR/$_nr"
    if _have "$_nr" "$_re"; then ok "$(printf '%-10s already present – skipped' "$_nr")"; continue; fi
    mkdir -p "$_d"
    _got=false
    IFS='|' read -r -a _plats <<< "$_plat"
    for _pl in "${_plats[@]}"; do
        printf '%s;%s\n' "$_pl" "$LANG_CODE" > "$_d/.getMOSPatch.cfg"   # read from the working dir
        for _try in $(seq 1 "$RETRIES"); do
            info "$(printf '%-10s platform %s, attempt %s – %s' "$_nr" "$_pl" "$_try" "$_desc")"
            # getMOSPatch matches the regexp (String.matches) against the file
            # name WITHOUT ".zip" – strip a trailing \.zip / .zip of the CSV value
            _gre="${_re%\\.zip}"; _gre="${_gre%.zip}"
            _args=("patch=$_nr" "download=all"); [ -n "$_gre" ] && _args+=("regexp=$_gre")
            _out="$(cd "$_d" && _gmp "${_args[@]}" 2>&1)"
            printf '%s\n' "$_out" >> "$LOG"
            if _have "$_nr" "$_re"; then _got=true; break; fi
            printf '%s\n' "$_out" | grep -qi 'no files available\|not available for' && break
            sleep 10
        done
        $_got && break
    done
    if $_got; then
        ok "$(printf '%-10s downloaded (platform %s)' "$_nr" "$_pl")"
    elif [ "$_req" = "yes" ]; then
        fail "$(printf '%-10s not downloaded – %s' "$_nr" "$(printf '%s\n' "$_out" | grep -iE 'error|not|denied|invalid' | tail -1)")"
    else
        warn "$(printf '%-10s (optional) not downloaded' "$_nr")"
    fi
done
MOS_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; unset MOS_PWD

# =============================================================================
# 4. Check
# =============================================================================
section "4. Check (unzip -t, SHA-256)"
SUMFILE="$DIR/patches_sha256.txt"
: > "$SUMFILE"
_missing_req=0; _missing_opt=0
for _r in "${ROWS[@]}"; do
    IFS=';' read -r _nr _plat _re _req _step _desc <<< "$_r"
    _f=""
    for _z in "$DIR/$_nr"/*.zip; do
        [ -f "$_z" ] || continue; _b="$(basename "$_z")"
        if [ -z "$_re" ] || [[ "$_b" =~ ^$_re$ ]]; then _f="$_z"; break; fi
    done
    if [ -z "$_f" ]; then
        [ "$_req" = "yes" ] && _missing_req=$((_missing_req + 1)) || _missing_opt=$((_missing_opt + 1))
        continue
    fi
    if unzip -tq "$_f" > /dev/null 2>&1; then
        _sha="$(sha256sum "$_f" | awk '{print toupper($1)}')"
        printf '%s  %s\n' "$_sha" "${_f#$DIR/}" >> "$SUMFILE"
        ok "$(printf '%-10s %-42s %6s  %s…' "$_nr" "$(basename "$_f")" "$(du -h "$_f" | cut -f1)" "${_sha:0:16}")"
    else
        fail "$(printf '%-10s %s is damaged (unzip -t) – delete it and run again' "$_nr" "$(basename "$_f")")"
        _missing_req=$((_missing_req + 1))
    fi
done
info "SHA-256 list: $SUMFILE  (compare with the values on MOS)"

_p ""
_p "=== Summary: OK $N_OK  WARN $N_WARN  FAIL $N_FAIL – log $LOG"
[ "$_missing_req" -gt 0 ] && { _p "$_missing_req required patch(es) missing"; exit 2; }
[ "$_missing_opt" -gt 0 ] && { _p "$_missing_opt optional patch(es) missing"; exit 1; }
exit 0
