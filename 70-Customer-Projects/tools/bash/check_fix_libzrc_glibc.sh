#!/bin/bash
# =============================================================================
# Script   : check_fix_libzrc_glibc.sh
# Purpose  : Forms / Reports 14.1.2 (12.2.1.19) on Oracle Linux 9 / glibc 2.34:
#            the Reports QPR rebuilds $ORACLE_HOME/lib/libzrc.so.0 against
#            the system glibc ("genshlib zrc 0"), every later Forms relink
#            (Forms QPR, frmweb / dejvm) links against lib/stubs (glibc 2.28)
#            and fails: "libzrc.so: undefined reference to dlsym@GLIBC_2.34"
#            (MOS KB873815, Bug 38892485). Standalone version of
#            _fix_libzrc_glibc in 09-Install/06-oracle_patch_forms_reports.sh.
#            Checks (read-only by default):
#              1. lib/libzrc* - libzrc.so.0, the link libzrc.so -> libzrc.so.0,
#                 libzrc.a, libzrc.so_back (Oracle's KB873815 workaround moves
#                 libzrc.so away - half done = the link stays missing)
#              2. GLIBC versions libzrc.so.0 needs that lib/stubs lacks
#              3. frmweb / libfrmjapi.so.0 (Forms XML tools) / rwserver: is
#                 libzrc found (ldd), frmweb linked static or dynamic?
#              4. leftovers of a failed Forms patch: inventory/oneoffs/<nr>
#                 not in "opatch lspatches", bin/dejvm missing, OPatch logs
#                 with GLIBC_2.34
#            --apply (Forms / Reports processes must be stopped):
#              - rebuild libzrc.so.0 from lib/libzrc.a against lib/stubs
#                (backup libzrc.so.0.glibc_<ts>, restored on failure)
#              - create the missing link libzrc.so -> libzrc.so.0
#              - prints the relink commands (dejvm, frmweb) - not run here
#            --show: changes nothing - prints the commands of the repair for
#              THIS home (backup, rebuild, link, relink, check), one per line,
#              to run them by hand
# Call     : ./check_fix_libzrc_glibc.sh [-o ORACLE_HOME] [-t OUTDIR] [--apply|--show] [--no-opatch]
#              -o           default: environment, running WebLogic, /app/oracle/mw,
#                           /u01/app/oracle/fmw …
#              -t           directory of the log file (default /tmp)
#              --apply      repair libzrc (see above)
#              --show       print the manual repair commands, change nothing
#              --no-opatch  skip "opatch lspatches" (leftover check, ~20 s)
# Runs as  : the software owner (oracle); needs nm / readelf (binutils), for
#            --apply also ar + gcc
# Output   : stdout + <OUTDIR>/libzrc_check_<host>_<yyyymmdd_hhmmss>.log
# Exit     : 0 = ok, 1 = to fix, 2 = error
# Doc      : 09-Install/docs/06-oracle_patch_forms_reports.md
#            ("Forms relink fails after a Reports QPR")
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================
set -u
VERSION="2026-11-26.1"   # bump on every change

OH="${ORACLE_HOME:-}"; OUTBASE="/tmp"; APPLY=false; OPATCH=true; SHOW=false
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OH="${2:-}"; shift ;;
        -t) OUTBASE="${2:-/tmp}"; shift ;;
        --apply) APPLY=true ;;
        --no-opatch) OPATCH=false ;;
        --show) SHOW=true ;;
        -h|--help) sed -n '2,45p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
$APPLY && $SHOW && { printf -- '--apply and --show exclude each other\n' >&2; exit 2; }

LOG="$OUTBASE/libzrc_check_$(hostname -s 2>/dev/null || hostname)_$(date +%Y%m%d_%H%M%S).log"
: > "$LOG" 2>/dev/null || LOG=/dev/null
N_FIX=0; N_FAIL=0
_p()   { printf '%s\n' "$*" | tee -a "$LOG"; }
ok()   { printf '\033[32m  OK  \033[0m %s\n' "$*"; printf '  OK   %s\n' "$*" >> "$LOG"; }
fix()  { N_FIX=$((N_FIX + 1)); printf '\033[33m FIX  \033[0m %s\n' "$*"; printf ' FIX   %s\n' "$*" >> "$LOG"; }
fail() { N_FAIL=$((N_FAIL + 1)); printf '\033[31m FAIL \033[0m %s\n' "$*"; printf ' FAIL  %s\n' "$*" >> "$LOG"; }
info() { printf '       %s\n' "$*" | tee -a "$LOG"; }
section() { _p ""; _p "=== $* ==="; }

# --- ORACLE_HOME ------------------------------------------------------------------
if [ -z "$OH" ] || [ ! -d "$OH/OPatch" ]; then
    OH="$(ps -eo args= 2>/dev/null | sed -n 's/.*-Dweblogic\.home=\([^ ]*\)\/wlserver\/server.*/\1/p' | head -1)"
    if [ ! -d "${OH:-/x}/OPatch" ]; then
        OH=""
        for c in /app/oracle/mw /oracle/product/mw /u01/app/oracle/fmw /u01/oracle/fmw \
                 /u01/app/oracle/middleware /u01/oracle/middleware; do
            [ -d "$c/OPatch" ] && { OH="$c"; break; }
        done
    fi
fi
while [ "${OH%/}" != "$OH" ] && [ "$OH" != / ]; do OH="${OH%/}"; done
[ -d "${OH:-/x}/OPatch" ] || { printf 'ORACLE_HOME not found - use -o\n' >&2; exit 2; }
LIB="$OH/lib"; ZRC="$LIB/libzrc.so.0"; STUBS="$LIB/stubs"

_p "check_fix_libzrc_glibc.sh $VERSION - $(date '+%Y-%m-%d %H:%M:%S')"
_p "ORACLE_HOME : $OH"
_p "Mode        : $($APPLY && printf 'APPLY (repair)' || { $SHOW && printf 'check + show the manual repair (read-only)' || printf 'check only (read-only)'; })"
_p "Log         : $LOG"
[ -d "$OH/forms" ] || info "no forms/ in this home (Reports only) - a Forms relink never happens here"
for t in nm readelf; do command -v "$t" >/dev/null 2>&1 || { fail "$t missing (binutils) - GLIBC check not possible"; }; done

# _bad_versions - GLIBC versions libzrc.so.0 needs that lib/stubs lacks
_bad_versions() {
    local need have v
    [ -f "$ZRC" ] && [ -f "$STUBS/libc.so.6" ] || return 0
    need="$(nm -D --undefined-only "$ZRC" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -u)"
    have="$(readelf -V "$STUBS"/libc.so.6 "$STUBS"/libdl.so.2 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -u)"
    for v in $need; do printf '%s\n' "$have" | grep -qx "$v" || printf '%s ' "$v"; done
}

# =============================================================================
# 1. lib/libzrc*
# =============================================================================
section "1. Files lib/libzrc*"
ls -l --time-style='+%Y-%m-%d %H:%M' "$LIB"/libzrc* 2>/dev/null | sed 's/^/       /' | tee -a "$LOG"
NEED_LINK=false; NEED_REBUILD=false; NEED_DEJVM=false; LEFTOVERS=""
[ -f "$ZRC" ] && ok "libzrc.so.0 present" || fail "libzrc.so.0 MISSING - frmweb / rwserver need it (restore from backup / .patch_storage)"
[ -f "$LIB/libzrc.a" ] && ok "libzrc.a present (source for a rebuild)" || info "libzrc.a missing - no rebuild possible"
if [ -L "$LIB/libzrc.so" ]; then
    if [ "$(readlink -f "$LIB/libzrc.so")" = "$(readlink -f "$ZRC")" ]; then ok "libzrc.so -> libzrc.so.0 (link)"
    else fix "libzrc.so is a link to $(readlink -f "$LIB/libzrc.so") - expected libzrc.so.0"; NEED_LINK=true; fi
elif [ -f "$LIB/libzrc.so" ]; then
    info "libzrc.so is a file, not a link (older layout) - left as it is"
else
    fix "libzrc.so (link to libzrc.so.0) MISSING - the Forms XML tools (libfrmjapi.so.0) cannot load"
    NEED_LINK=true
fi
for b in "$LIB"/libzrc.so_back "$LIB"/libzrc.so.0.glibc*; do
    [ -e "$b" ] || continue
    case "$b" in
        *_back) info "libzrc.so_back: Oracle's KB873815 workaround was started (libzrc.so moved away for a static Forms relink)"
                info "  the workaround ends with 'make -f ins_reports.mk zrcsharedlib' - the link was not restored afterwards" ;;
        *)      info "backup of an earlier rebuild: $(basename "$b")" ;;
    esac
done

# =============================================================================
# 2. GLIBC versions of libzrc.so.0 against lib/stubs
# =============================================================================
section "2. GLIBC versions of libzrc.so.0 against lib/stubs (Forms relink safe?)"
if [ ! -f "$STUBS/libc.so.6" ]; then
    info "no lib/stubs/libc.so.6 - check not possible"
else
    info "stubs provide up to: $(readelf -V "$STUBS/libc.so.6" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)"
    info "system glibc       : $(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')"
    BAD="$(_bad_versions)"
    if [ -z "$BAD" ]; then
        ok "libzrc.so.0 needs no GLIBC version beyond lib/stubs - a Forms relink works"
    else
        fix "libzrc.so.0 needs ${BAD% } - not in lib/stubs: the next Forms relink / Forms QPR fails (rc=73)"
        info "  dlsym: $(nm -D "$ZRC" 2>/dev/null | grep -w dlsym | sed 's/^ *//')"
        NEED_REBUILD=true
    fi
fi

# =============================================================================
# 3. Who finds libzrc?
# =============================================================================
section "3. frmweb, libfrmjapi.so.0, rwserver - libzrc resolved?"
for b in "$OH/bin/frmweb" "$OH/lib/libfrmjapi.so.0" "$OH/bin/rwserver" "$OH/bin/dejvm"; do
    if [ ! -e "$b" ]; then
        case "$b" in
            */dejvm) [ -d "$OH/forms" ] && { fix "bin/dejvm MISSING - left by a failed Forms relink (dejvm_clean) - relink dejvm"; NEED_DEJVM=true; } ;;
            *) info "$(basename "$b") not in this home" ;;
        esac
        continue
    fi
    l="$(ldd "$b" 2>/dev/null)"
    z="$(printf '%s\n' "$l" | grep -E 'libzrc' | sed 's/^[[:space:]]*//')"
    nf="$(printf '%s\n' "$l" | grep 'not found' | sed 's/^[[:space:]]*//' | paste -sd, -)"
    name="${b#"$OH"/}"
    if [ -n "$nf" ]; then fix "$name: not found: $nf"
    elif [ -n "$z" ]; then ok "$name: $z"
    else
        case "$b" in
            */frmweb) info "$name: no libzrc in ldd - linked STATIC (libzrc.a, e.g. after Oracle's KB873815 workaround) ($(stat -c '%y' "$b" | cut -c1-16))" ;;
            *) ok "$name: needs no libzrc" ;;
        esac
    fi
done

# =============================================================================
# 4. Leftovers of a failed Forms patch
# =============================================================================
section "4. Leftovers of a failed Forms patch"
if $OPATCH && [ -x "$OH/OPatch/opatch" ]; then
    LSP="$("$OH/OPatch/opatch" lspatches -oh "$OH" 2>/dev/null | grep -oE '^[0-9]+' | sort -u)"
    # only Forms patches: inventory/oneoffs also keeps superseded / rolled back
    # bundles, so "not in lspatches" alone proves nothing - a Forms oneoff that
    # is not applied and is newer than the applied Forms patch is the suspect
    for d in "$OH"/inventory/oneoffs/*/; do
        [ -d "$d" ] || continue
        n="$(basename "$d")"
        grep -q "oracle.developer.forms" "$d"etc/config/inventory.xml 2>/dev/null || continue
        if printf '%s\n' "$LSP" | grep -qx "$n"; then
            ok "Forms patch $n applied ($(stat -c '%y' "$d" | cut -c1-16))"
        else
            LEFTOVERS="$LEFTOVERS $n"
            fix "Forms patch $n: inventory/oneoffs/$n present ($(stat -c '%y' "$d" | cut -c1-16)), NOT in 'opatch lspatches' - superseded, or leftover of a failed apply (check the OPatch log of that date)"
        fi
    done
    [ -n "$LSP" ] && ok "inventory/oneoffs checked against opatch lspatches ($(printf '%s\n' "$LSP" | wc -l) patches)"
else
    info "opatch lspatches skipped (--no-opatch) - oneoffs not checked"
fi
LOGS="$(grep -l -E 'undefined reference to .?dlsym@GLIBC|Re-link fails on target|failed to restore OH' "$OH"/cfgtoollogs/opatch/*.log 2>/dev/null | tail -5)"
if [ -n "$LOGS" ]; then
    info "OPatch logs with the libzrc / relink error (history - WHEN it happened; the state today is sections 1-3):"
    for f in $LOGS; do
        info "  $(stat -c '%y' "$f" | cut -c1-16)  $f"
        grep -m2 -hE 'undefined reference to .?dlsym@GLIBC|Re-link fails on target|failed to restore OH' "$f" | cut -c1-150 | sed 's/^/           /' | tee -a "$LOG"
    done
else
    ok "no OPatch log with the libzrc / relink error"
fi

# =============================================================================
# Show: the manual repair for this home (nothing is run)
# =============================================================================
if $SHOW; then
    section "Manual repair - commands for this home (NOT run, as $(id -un))"
    TS="$(date +%Y%m%d_%H%M%S)"
    if ! $NEED_REBUILD && ! $NEED_LINK && ! $NEED_DEJVM && [ -z "$LEFTOVERS" ]; then
        info "nothing to repair - libzrc.so.0 relink safe, link present, dejvm there"
    else
        _s() { printf '%s\n' "$*" | tee -a "$LOG"; }
        _s ""
        _s "  # 0. Stop Forms and Reports of this home (WLS_FORMS, WLS_REPORTS, Reports server)"
        _s "  #    - all users lose their sessions. Check that nothing runs any more:"
        _s ""
        _s "  pgrep -l -x 'frmweb|rwserver|dejvm'"
        _s "  # Expected: no output"
        _s ""
        _s "  export ORACLE_HOME=$OH"
        _s ""
        _s "  cd \$ORACLE_HOME/lib"
        _s ""
        _s "  ls -l libzrc*"
        _s "  # Remember the state before the repair."
        if $NEED_REBUILD; then
            _s ""
            _s "  # 1. Backup of libzrc.so.0, then rebuild it from libzrc.a against lib/stubs"
            _s ""
            _s "  cp -p libzrc.so.0 libzrc.so.0.glibc_$TS"
            _s ""
            _s "  mkdir -p /tmp/libzrc_$TS"
            _s ""
            _s "  cd /tmp/libzrc_$TS"
            _s ""
            _s "  ar x \$ORACLE_HOME/lib/libzrc.a"
            _s ""
            _s "  gcc -shared -Wl,-G,-hlibzrc.so.0 -L\$ORACLE_HOME/lib/stubs -o libzrc.so.0 ./*.o -ldl"
            _s "  # Expected: no output (warnings of the linker are harmless)"
            _s ""
            _s "  nm -D libzrc.so.0 | grep -w dlsym"
            _s "  # Expected: U dlsym@GLIBC_2.2.5   (NOT GLIBC_2.34 - else STOP)"
            _s ""
            _s "  install -m 755 libzrc.so.0 \$ORACLE_HOME/lib/libzrc.so.0"
            _s ""
            _s "  cd \$ORACLE_HOME/lib"
            _s ""
            _s "  rm -rf /tmp/libzrc_$TS"
        fi
        if $NEED_LINK; then
            _s ""
            _s "  # 2. The link libzrc.so -> libzrc.so.0 (Forms XML tools, libfrmjapi.so.0)"
            [ -L "$LIB/libzrc.so" ] && { _s ""; _s "  rm libzrc.so"; _s "  # (wrong link target: $(readlink "$LIB/libzrc.so"))"; }
            [ -e "$LIB/libzrc.so_back" ] && { _s "  # libzrc.so_back stays as it is (Oracle's KB873815 workaround) - it is not used"; }
            _s ""
            _s "  ln -s libzrc.so.0 libzrc.so"
            _s ""
            _s "  ls -l libzrc.so"
            _s "  # Expected: libzrc.so -> libzrc.so.0"
        fi
        if [ -n "$LEFTOVERS" ]; then
            _s ""
            _s "  # 3. Leftover Forms patch(es) in the inventory:$LEFTOVERS"
            _s "  #    ONLY if the OPatch log of that date shows the failed apply (section 4 above);"
            _s "  #    a superseded patch stays. Move it away (not delete):"
            for n in $LEFTOVERS; do
                _s ""
                _s "  mv \$ORACLE_HOME/inventory/oneoffs/$n /tmp/oneoffs_${n}_$TS"
            done
        fi
        _s ""
        _s "  # 4. Relink the Forms binaries against the repaired libzrc"
        _s ""
        _s "  cd \$ORACLE_HOME/procbuilder/lib"
        _s ""
        _s "  make -f ins_procbuilder.mk dejvm_install ORACLE_HOME=\$ORACLE_HOME"
        _s "  # Expected: ends without 'Error' - bin/dejvm is new"
        _s ""
        _s "  cd \$ORACLE_HOME/forms/lib"
        _s ""
        _s "  make -f ins_forms.mk frmweb_install ORACLE_HOME=\$ORACLE_HOME"
        _s "  # Expected: ends without 'Error' - bin/frmweb is new"
        _s ""
        _s "  ls -l \$ORACLE_HOME/bin/frmweb \$ORACLE_HOME/bin/dejvm"
        _s "  # Expected: both with today's date"
        _s ""
        _s "  ldd \$ORACLE_HOME/bin/frmweb | grep -E 'zrc|not found'"
        _s "  # Expected: libzrc.so.0 => \$ORACLE_HOME/lib/libzrc.so.0, no 'not found'"
        _s ""
        _s "  # 5. Check again, then start Forms and Reports"
        _s ""
        _s "  $(readlink -f "$0") -o \$ORACLE_HOME"
        _s "  # Expected: Result: 0 FAIL, 0 FIX"
        _s ""
        _s "  # Back (if something does not start):"
        $NEED_REBUILD && _s "  #   cp -p \$ORACLE_HOME/lib/libzrc.so.0.glibc_$TS \$ORACLE_HOME/lib/libzrc.so.0"
        $NEED_LINK && _s "  #   rm \$ORACLE_HOME/lib/libzrc.so"
        _s "  #   then relink as in step 4"
        _s "  # Then apply the Forms QPR again - the relink of the patch now works."
    fi
fi

# =============================================================================
# Apply
# =============================================================================
if $APPLY && { $NEED_REBUILD || $NEED_LINK; }; then
    section "Repair"
    # processes of THIS Oracle Home that map libzrc (frmweb, rwserver, dejvm ...)
    RUNP="$(for p in $(pgrep -x 'frmweb|rwserver|dejvm|frmcmp_batch' 2>/dev/null); do
                case "$(readlink -f "/proc/$p/exe" 2>/dev/null)" in "$(readlink -f "$OH")"/*) printf '%s ' "$p" ;; esac
            done)"
    if [ -n "$RUNP" ]; then
        fail "Forms / Reports processes of this home running (pid $RUNP) - stop WLS_FORMS / WLS_REPORTS / the Reports server first"
        _p ""; _p "Result: nothing changed"; exit 2
    fi
    if $NEED_REBUILD; then
        for t in ar gcc; do command -v "$t" >/dev/null 2>&1 || { fail "$t missing - cannot rebuild libzrc.so.0"; exit 2; }; done
        [ -f "$LIB/libzrc.a" ] || { fail "libzrc.a missing - cannot rebuild"; exit 2; }
        BAK="$ZRC.glibc_$(date +%Y%m%d_%H%M%S)"
        cp -p "$ZRC" "$BAK" || { fail "backup failed"; exit 2; }
        info "backup: $BAK"
        TMPD="$(mktemp -d)"
        if ( cd "$TMPD" && ar x "$LIB/libzrc.a" && gcc -shared -Wl,-G,-hlibzrc.so.0 -L"$STUBS" -o libzrc.so.0 ./*.o -ldl ) >> "$LOG" 2>&1 \
           && install -m 755 "$TMPD/libzrc.so.0" "$ZRC.new" && mv -f "$ZRC.new" "$ZRC"; then
            BAD="$(_bad_versions)"
            if [ -z "$BAD" ]; then ok "libzrc.so.0 rebuilt against lib/stubs ($(nm -D "$ZRC" | grep -w dlsym | awk '{print $NF}'))"
            else fail "libzrc.so.0 still needs ${BAD% } - restoring the backup"; cp -p "$BAK" "$ZRC"; fi
        else
            fail "rebuild failed (see $LOG) - restoring the backup"; cp -p "$BAK" "$ZRC"
        fi
        rm -rf "${TMPD:?}"
    fi
    if $NEED_LINK && [ -f "$ZRC" ]; then
        [ -L "$LIB/libzrc.so" ] && rm -f "$LIB/libzrc.so"
        ln -s libzrc.so.0 "$LIB/libzrc.so" && ok "link created: lib/libzrc.so -> libzrc.so.0"
    fi
    section "Next steps (by hand, Forms / Reports stopped)"
    info "relink the Forms binaries against the repaired libzrc:"
    info "  cd \$ORACLE_HOME/procbuilder/lib && make -f ins_procbuilder.mk dejvm_install ORACLE_HOME=\$ORACLE_HOME"
    info "  cd \$ORACLE_HOME/forms/lib       && make -f ins_forms.mk frmweb_install       ORACLE_HOME=\$ORACLE_HOME"
    info "leftover inventory/oneoffs/<nr> of a failed apply: remove it (what OPatch's restore.sh does), then apply the Forms QPR again"
    info "then: $0 again - expected 0 FIX"
elif $APPLY; then
    section "Repair"
    ok "nothing to repair in lib/ (libzrc.so.0 relink safe, link present)"
fi

_p ""
_p "Result: $N_FAIL FAIL, $N_FIX FIX - log: $LOG"
$APPLY || $SHOW || { [ "$N_FIX" -gt 0 ] && info "--apply repairs libzrc.so.0 / the link (Forms / Reports stopped), --show prints the manual commands"; }
[ "$N_FAIL" -gt 0 ] && exit 2
[ "$N_FIX" -gt 0 ] && exit 1
exit 0
