#!/bin/bash
# =============================================================================
# Script   : update_tools_from_git.sh
# Purpose  : Update the customer tools in THIS directory ($ORACLE_BASE/tools)
#            from the IHateWeblogic repository: download the Linux tools ZIP,
#            show per file what is installed and what is new; with --apply
#            replace the changed files, unpack the new ones and install the
#            shell switcher (ihw_shell_env.sh -> ~/.bashrc.d/ihw_env.sh). The
#            template ihw_shell_env.sh is then removed from the tools
#            directory (only ONE copy - the one in ~/.bashrc.d).
#            Read-only without --apply. Standalone (it may update
#            ihw_tools_lib.sh itself, so it does not use it).
# Call     : ./update_tools_from_git.sh [--apply] [--zip FILE] [--url URL]
#            --apply    replace / unpack / install (backup first)
#            --zip FILE offline: a ZIP copied by hand (FILE.sha256 next to it
#                       is checked when present) - no download
#            --url URL  other source (default: the repository, branch main;
#                       or IHW_TOOLS_URL in the environment)
#            -V         version, -h help
# Download : wget --no-check-certificate (curl -k when there is no wget):
#            customer networks often intercept TLS with their own CA. The
#            SHA-256 (.sha256 next to the ZIP) proves the transfer is
#            complete - not where it came from. Proxy: https_proxy from the
#            environment (wget / curl read it).
# Backup   : <tools>/backup/tools_<yyyymmdd_hhmmss>/ - every replaced file and
#            the old ~/.bashrc.d/ihw_env.sh; the newest 3 backups are kept.
#            ~/.ihw_env.conf (homes detected by setdb) is not touched.
# Exit     : 0 up to date / applied, 1 updates available (read-only), 2 error
# Runs as  : the owner of the tools (oracle), not root
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

set -u
umask 022
VERSION="2026-11-19.1"   # bump on every change

URL="${IHW_TOOLS_URL:-https://github.com/gpipperr/IHateWeblogic/raw/main/70-Customer-Projects/tools/ihw_customer_tools_linux.zip}"
APPLY=false; ZIP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=true ;;
        --zip) ZIP="${2:-}"; shift ;;
        --url) URL="${2:-}"; shift ;;
        -h|--help) sed -n '2,31p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s (--apply, --zip FILE, --url URL, -h)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '  %s\n' "$*"; }
err()  { printf '  ERROR %s\n' "$*" >&2; }
line() { printf '  %s\n' "------------------------------------------------------------------------"; }

[ "$(id -u)" -eq 0 ] && { err "do not run as root - run as the owner of the tools (oracle)"; exit 2; }
for c in unzip sha256sum; do command -v "$c" >/dev/null 2>&1 || { err "missing: $c"; exit 2; }; done

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRC="$HOME/.bashrc.d"
ENVF="$BRC/ihw_env.sh"
# shellcheck disable=SC2088  # label only, not a path
ENVL="~/.bashrc.d/ihw_env.sh"
WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "${WORK:?}"' EXIT

# _ver FILE - first VERSION="..." / *_VERSION="..." of a file (as make_customer_zip.sh)
_ver() { local v; v="$(grep -m1 -oE '[A-Z_]*VERSION="[0-9][^"]*"' "$1" 2>/dev/null | sed 's/.*="//; s/"$//')"; printf '%s' "${v:--}"; }
_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
# _newer LOCAL REPO - 0 when the local version is newer than the repository one
# (test / maintainer hosts) - such a file is never downgraded
_newer() { [ "$1" != "-" ] && [ "$2" != "-" ] && [ -n "$2" ] && [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

say "update_tools_from_git.sh $VERSION"
say "tools directory : $TOOLS"

# =============================================================================
# 1. get the ZIP
# =============================================================================
Z="$WORK/tools.zip"
if [ -n "$ZIP" ]; then
    [ -r "$ZIP" ] || { err "ZIP not readable: $ZIP"; exit 2; }
    cp "$ZIP" "$Z" || exit 2
    [ -r "$ZIP.sha256" ] && cp "$ZIP.sha256" "$Z.sha256"
    say "source          : $ZIP (offline)"
else
    say "source          : $URL"
    say "                  (certificate check off - TLS interception in customer networks;"
    say "                   the SHA-256 proves a complete transfer, not the origin)"
    if command -v wget >/dev/null 2>&1; then
        wget -q --no-check-certificate -O "$Z" "$URL" || { err "download failed (wget rc $?) - proxy? https_proxy=... or --zip FILE"; exit 2; }
        wget -q --no-check-certificate -O "$Z.sha256" "$URL.sha256" || rm -f "$Z.sha256"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSLk -o "$Z" "$URL" || { err "download failed (curl rc $?) - proxy? https_proxy=... or --zip FILE"; exit 2; }
        curl -fsSLk -o "$Z.sha256" "$URL.sha256" || rm -f "$Z.sha256"
    else
        err "neither wget nor curl - copy the ZIP by hand and use --zip FILE"; exit 2
    fi
fi

# =============================================================================
# 2. check
# =============================================================================
if [ -s "$Z.sha256" ]; then
    _want="$(awk '{print $1; exit}' "$Z.sha256")"
    if [ "$(_sha "$Z")" = "$_want" ]; then
        say "SHA-256         : OK ($_want)"
    else
        err "SHA-256 of the ZIP does not match its .sha256 - download broken, nothing changed"; exit 2
    fi
else
    say "SHA-256         : no .sha256 - not checked"
fi
unzip -tq "$Z" >/dev/null 2>&1 || { err "ZIP broken (unzip -t) - nothing changed"; exit 2; }
mkdir -p "$WORK/new" && unzip -q -o "$Z" -d "$WORK/new" || { err "unzip failed"; exit 2; }
NEW="$WORK/new/tools"
[ -f "$NEW/VERSIONS.txt" ] || { err "no tools/VERSIONS.txt in the ZIP - not a tools ZIP"; exit 2; }

# =============================================================================
# 3. compare
# =============================================================================
N_CHG=0; N_NEW=0; N_SAME=0; ENV_ACT=""; TPL_DEL=false
: > "$WORK/todo"                                # files to install: relpath
line
printf '  %-40s %-10s %s\n' "file" "status" "version installed -> repository"
line
while IFS=';' read -r f v s; do
    case "$f" in ''|\#*) continue ;; esac
    [ "$f" = "ihw_shell_env.sh" ] && continue   # below: compared with ~/.bashrc.d/ihw_env.sh
    if [ ! -f "$TOOLS/$f" ]; then
        printf '  %-40s %-10s %s\n' "$f" "new" "- -> ${v:--}"; N_NEW=$((N_NEW + 1)); printf '%s\n' "$f" >> "$WORK/todo"
    elif [ "$(_sha "$TOOLS/$f")" = "$s" ]; then
        N_SAME=$((N_SAME + 1))
    elif _newer "$(_ver "$TOOLS/$f")" "$v"; then
        printf '  %-40s %-10s %s\n' "$f" "local newer" "$(_ver "$TOOLS/$f") -> ${v:--} (kept, no downgrade)"; N_SAME=$((N_SAME + 1))
    else
        printf '  %-40s %-10s %s\n' "$f" "changed" "$(_ver "$TOOLS/$f") -> ${v:--}"; N_CHG=$((N_CHG + 1)); printf '%s\n' "$f" >> "$WORK/todo"
    fi
done < "$NEW/VERSIONS.txt"
[ $((N_CHG + N_NEW)) -eq 0 ] && say "all $N_SAME tool files are current"
# tools version list itself (no entry in VERSIONS.txt)
[ "$(_sha "$TOOLS/VERSIONS.txt")" = "$(_sha "$NEW/VERSIONS.txt")" ] || printf '%s\n' "VERSIONS.txt" >> "$WORK/todo"
# local files that are not in the ZIP - stay as they are
_loc="$(cd "$TOOLS" && find . -type f ! -path './backup/*' 2>/dev/null | sed 's#^\./##' | sort \
        | grep -vxF -f <(cut -d';' -f1 "$NEW/VERSIONS.txt" | grep -v '^#'; printf 'VERSIONS.txt\n') | paste -sd' ' -)"
[ -n "$_loc" ] && say "local only (unchanged): $_loc"
line
# shell switcher: the template is compared with the INSTALLED copy
NEWENV="$NEW/ihw_shell_env.sh"
if [ -f "$NEWENV" ]; then
    _nv="$(_ver "$NEWENV")"
    if [ ! -f "$ENVF" ]; then
        ENV_ACT="install"; say "$(printf '%-40s %-10s %s' "$ENVL (setdb)" "new" "not installed -> $_nv")"
    elif _newer "$(_ver "$ENVF")" "$_nv"; then
        say "$(printf '%-40s %-10s %s' "$ENVL (setdb)" "local newer" "$(_ver "$ENVF") -> $_nv (kept, no downgrade)")"
    elif [ "$(_sha "$ENVF")" != "$(_sha "$NEWENV")" ]; then
        ENV_ACT="replace"; say "$(printf '%-40s %-10s %s' "$ENVL (setdb)" "changed" "$(_ver "$ENVF") -> $_nv")"
    else
        say "$(printf '%-40s %-10s %s' "$ENVL (setdb)" "current" "$_nv")"
    fi
fi
if [ -f "$TOOLS/ihw_shell_env.sh" ]; then
    TPL_DEL=true; say "$(printf '%-40s %-10s %s' "ihw_shell_env.sh (template)" "remove" "installed copy is ~/.bashrc.d/ihw_env.sh - the template confuses")"
fi
# hints: second copy in ~/.bashrc.d, loop in ~/.bashrc
for _f in "$BRC"/*; do
    [ -f "$_f" ] && [ "$_f" != "$ENVF" ] && grep -q '^IHW_SHELL_ENV_VERSION=' "$_f" 2>/dev/null && \
        say "HINT  second copy of the shell switcher: $_f - it overrides ihw_env.sh, delete it"
done
grep -qs 'bashrc\.d' "$HOME/.bashrc" || \
    say "HINT  ~/.bashrc has no loop over ~/.bashrc.d - add: for rc in ~/.bashrc.d/*; do [ -f \"\$rc\" ] && . \"\$rc\"; done"
line
_todo=$((N_CHG + N_NEW))
say "$(printf 'summary: %d changed, %d new, %d current; setdb: %s%s' "$N_CHG" "$N_NEW" "$N_SAME" "${ENV_ACT:-current}" "$($TPL_DEL && printf ', template to remove')")"

if ! $APPLY; then
    if [ "$_todo" -gt 0 ] || [ -n "$ENV_ACT" ] || $TPL_DEL; then
        say "-> update with: $0 --apply$( [ -n "$ZIP" ] && printf ' --zip %s' "$ZIP")"
        exit 1
    fi
    say "nothing to do"
    exit 0
fi

# =============================================================================
# 4. apply
# =============================================================================
if [ "$_todo" -eq 0 ] && [ -z "$ENV_ACT" ] && ! $TPL_DEL && [ ! -s "$WORK/todo" ]; then
    say "nothing to do"; exit 0
fi
BK="$TOOLS/backup/tools_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BK" || { err "cannot create $BK"; exit 2; }
# _put SRC DST MODE - backup DST, then temp file in the target directory + mv
# (new inode: a running script - also this one - keeps its old copy)
_put() {
    local src="$1" dst="$2" mode="$3" rel="$4" tmp
    mkdir -p "$(dirname "$dst")" || return 1
    if [ -f "$dst" ]; then mkdir -p "$(dirname "$BK/$rel")" && cp -p "$dst" "$BK/$rel" || return 1; fi
    tmp="$(dirname "$dst")/.$(basename "$dst").new.$$"
    cp "$src" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}
RC=0
while read -r f; do
    case "$f" in *.sh) m=755 ;; *) m=644 ;; esac
    if _put "$NEW/$f" "$TOOLS/$f" "$m" "$f"; then say "OK    $f"; else err "$f not written"; RC=2; fi
done < "$WORK/todo"
if [ -n "$ENV_ACT" ]; then
    mkdir -p "$BRC" && chmod 700 "$BRC"
    if _put "$NEWENV" "$ENVF" 644 "bashrc.d/ihw_env.sh"; then say "OK    $ENVL ($ENV_ACT, $(_ver "$ENVF"))"; else err "$ENVL not written"; RC=2; fi
fi
if $TPL_DEL && [ -f "$ENVF" ]; then
    mkdir -p "$BK" && cp -p "$TOOLS/ihw_shell_env.sh" "$BK/ihw_shell_env.sh" && rm -f "$TOOLS/ihw_shell_env.sh" \
        && say "OK    template ihw_shell_env.sh removed from the tools directory"
fi
# keep the newest 3 backups
ls -1d "$TOOLS"/backup/tools_* 2>/dev/null | sort | head -n -3 | while read -r d; do rm -rf "${d:?}"; done
line
say "backup          : $BK"
say "collect_fmw_env : $(_ver "$TOOLS/collect_fmw_env.sh")"
[ "$RC" -eq 0 ] || { err "not every file was written - see above (backup: $BK)"; exit "$RC"; }
say "Tools aktualisiert."
[ -n "$ENV_ACT" ] && say "Bitte ab- und neu anmelden (ssh / su - oracle), damit setdb (~/.bashrc.d/ihw_env.sh) neu geladen wird."
exit 0
