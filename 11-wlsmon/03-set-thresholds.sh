#!/bin/bash
# =============================================================================
# Script   : 03-set-thresholds.sh
# Purpose  : wlsmon operation (after the installation, as often as needed):
#            show and change the WARN / CRIT thresholds in
#            $WLSMON_BASE/etc/wlsmon.conf. The overview puts every threshold
#            next to the value measured now and the maximum / average of the
#            last 24 h (day.json), so a limit that fires all day is visible.
#            Values are checked before anything is written (two numbers,
#            warn < crit, percent 0..100, days reversed); a backup of
#            wlsmon.conf is taken; the collector reads the new values at its
#            next run (no restart) - collect --check shows them at once.
# Call     : ./11-wlsmon/03-set-thresholds.sh                         (overview)
#            ./11-wlsmon/03-set-thresholds.sh --set HEAP_PCT=85,95    (dry-run)
#            ./11-wlsmon/03-set-thresholds.sh --set HEAP_PCT=85,95 --apply
#            ./11-wlsmon/03-set-thresholds.sh --interactive --apply
#            ./11-wlsmon/03-set-thresholds.sh --reset HEAP_PCT --apply
# Options  : --set KEY=VALUE  new value (KEY with or without WLSMON_), repeatable
#            --reset KEY      back to the built-in default, repeatable
#            --interactive    ask every threshold (Enter = keep, "-" = default)
#            --apply          write wlsmon.conf (backup first) + collect --check
#            --base DIR       WLSMON_BASE (default $ORACLE_BASE/admin/wlsmon)
#            --help
# Fixed    : stuck / hogging threads, DOWN, core dumps have fixed levels; the
#            levels of log messages come from etc/wlsmon_rules.local.cfg.
# Runs as  : FMW owner (oracle), never root
# Ref      : 11-wlsmon/docs/04-wlsmon_operations.md §3a,
#            docs/01-wlsmon_concept.md §9.2 / §9.3
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
WLSMON_PY="$SCRIPT_DIR/wlsmon.py"

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
INTERACTIVE=false
BASE_ARG=""
SETS=()          # KEY=VALUE, keys normalised to WLSMON_*
RESETS=()

_norm() { case "$1" in WLSMON_*) printf "%s" "$1" ;; *) printf "WLSMON_%s" "$1" ;; esac; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply)       APPLY=true ;;
        --interactive) INTERACTIVE=true ;;
        --set)         _kv="${2:-}"; shift
                       [[ "$_kv" == *=* ]] || { printf "--set needs KEY=VALUE\n" >&2; exit 2; }
                       SETS+=("$(_norm "${_kv%%=*}")=${_kv#*=}") ;;
        --reset)       RESETS+=("$(_norm "${2:-}")"); shift ;;
        --base)        BASE_ARG="${2:-}"; shift ;;
        --help|-h)
            printf "Usage: %s [--set KEY=VALUE ...] [--reset KEY ...] [--interactive] [--apply] [--base DIR]\n\n" "$(basename "$0")"
            printf "  %-18s %s\n" "(none)"        "Overview: thresholds, value now, max / avg of the last 24 h"
            printf "  %-18s %s\n" "--set K=V"     "New value, e.g. --set HEAP_PCT=85,95 (warn,crit)"
            printf "  %-18s %s\n" "--reset K"     "Back to the built-in default"
            printf "  %-18s %s\n" "--interactive" "Ask every threshold (Enter = keep, - = default)"
            printf "  %-18s %s\n" "--apply"       "Write wlsmon.conf (backup) and run collect --check"
            printf "\nThe collector reads the new values at its next run (at most 5 min) - no restart.\n"
            exit 0 ;;
        *) printf "Unknown argument: %s (--help)\n" "$1" >&2; exit 2 ;;
    esac
    shift
done

LOG_FILE="/dev/null"
if mkdir -p "$ROOT_DIR/log/$(date +%Y%m%d)" 2>/dev/null; then
    LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/wlsmon_set_thresholds_$(date +%H%M%S).log"
fi
printf "\n\033[1m  wlsmon – WARN / CRIT thresholds\033[0m\n" | tee -a "$LOG_FILE"
printf "  Apply: %s  Interactive: %s\n" "$APPLY" "$INTERACTIVE" | tee -a "$LOG_FILE"

# =============================================================================
# Configuration
# =============================================================================
section "Configuration"
if [ "$(id -u)" -eq 0 ]; then
    fail "Runs as the FMW owner, not as root"
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
if [ ! -f "$CONF" ]; then
    fail "No $CONF – install first: 00-setup-interview.sh, 01-install-wlsmon_fmw.sh"
    print_summary; exit "${EXIT_CODE:-2}"
fi
ok "$(printf "  %-20s %s" "wlsmon.conf:" "$CONF")"
INSTALLED="$BASE/bin/wlsmon.py"
if [ -f "$INSTALLED" ] && ! cmp -s "$WLSMON_PY" "$INSTALLED"; then
    warn "Installed bin/wlsmon.py differs from the repository – run 01-install-wlsmon_fmw.sh --apply first (new keys such as WLSMON_SWAP_MB need the new program)"
fi

_py() { WLSMON_BASE="$BASE" python3 -I "$WLSMON_PY" "$@"; }
OVERVIEW="$(_py thresholds)" || { fail "wlsmon.py thresholds failed"; print_summary; exit "${EXIT_CODE:-2}"; }

# one row per key: KEY|current|effective|default|now|max|avg|level|label|kind
_rows() {
    printf '%s' "$OVERVIEW" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
def f(v):
    if v is None: return "-"
    if isinstance(v, list): return ",".join("%g" % x for x in v)
    if isinstance(v, float): return "%g" % v
    return str(v)
for r in d["rows"]:
    print("|".join([r["key"], r["current"] or "", f(r.get("effective")), r["default"] or "",
                    f(r["now"]), f(r["max_24h"]), f(r["avg_24h"]), r["level"] or "-", r["label"], r["kind"]]))
'
}

# =============================================================================
# Overview
# =============================================================================
section "Thresholds (warn,crit) – value now, max / avg of the last 24 h"
printf "  %-22s %-10s %-10s %-8s %-8s %-8s %s\n" "key" "current" "default" "now" "24h max" "24h avg" "meaning" | tee -a "$LOG_FILE"
declare -A CUR DEF
while IFS='|' read -r k cur eff def nowv mx avg _lv label kind; do
    CUR[$k]="$cur"; DEF[$k]="$def"
    shown="${cur:-${eff}}"; [ -z "$cur" ] && [ "$eff" != "-" ] && shown="($eff)"
    [ -z "$cur" ] && [ "$eff" = "-" ] && shown="(none)"
    # the memory tile shows FREE memory, the limit counts USED memory
    if [ "$k" = "WLSMON_MEM_USED_PCT" ] && [[ "$eff" == *,* ]]; then
        label="$label (= WARN at <= $(awk -v x="${eff%%,*}" 'BEGIN{printf "%g", 100-x}') % free, CRIT at <= $(awk -v x="${eff##*,}" 'BEGIN{printf "%g", 100-x}') % free)"
    fi
    line="$(printf "  %-22s %-10s %-10s %-8s %-8s %-8s %s" "$k" "$shown" "${def:--}" "$nowv" "$mx" "$avg" "$label")"
    # a limit that the last 24 h reached is worth a look
    hit=""
    if [ "$eff" != "-" ] && [ "$mx" != "-" ] && [[ "$eff" == *,* ]]; then
        w="${eff%%,*}"
        if [ "$kind" = "rev" ]; then
            awk -v m="$mx" -v w="$w" 'BEGIN{exit !(m<=w)}' && hit="24 h reached WARN"
        else
            awk -v m="$mx" -v w="$w" 'BEGIN{exit !(m>=w)}' && hit="24 h max reached WARN"
        fi
    fi
    if [ -n "$hit" ]; then warn "${line#  }   <- $hit"; else printf "%s\n" "$line" | tee -a "$LOG_FILE"; fi
done < <(_rows)
info "(x,y) = not set, computed / default; (none) = no limit. Fixed levels, not changed here:"
printf '%s' "$OVERVIEW" | python3 -I -c 'import json,sys; [print("        - " + x) for x in json.load(sys.stdin)["fixed"]]' | tee -a "$LOG_FILE"

# =============================================================================
# Interactive
# =============================================================================
if $INTERACTIVE; then
    if [ ! -t 0 ]; then
        fail "--interactive needs a terminal"
        print_summary; exit "${EXIT_CODE:-2}"
    fi
    section "Interactive (Enter = keep, - = default)"
    for k in $(_rows | cut -d'|' -f1); do
        read -r -p "  $k [${CUR[$k]:-none}] (default ${DEF[$k]:-none}): " _ans
        case "$_ans" in
            "")  ;;
            -)   RESETS+=("$k") ;;
            *)   SETS+=("$k=$_ans") ;;
        esac
    done
fi

for k in "${RESETS[@]}"; do SETS+=("$k=${DEF[$k]-}"); done

if [ "${#SETS[@]}" -eq 0 ]; then
    info "Nothing to change – e.g.: $(basename "$0") --set HEAP_PCT=85,95 --apply   (or --interactive --apply)"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Check + diff
# =============================================================================
section "Changes"
CHECK_ARGS=()
for kv in "${SETS[@]}"; do CHECK_ARGS+=(--check "$kv"); done
BAD=0
while IFS='|' read -r k v okv why; do
    old="${CUR[$k]-}"
    if [ "$okv" != "True" ]; then
        fail "$(printf "  %-22s %-10s -> %-10s %s" "$k" "${old:-none}" "${v:-none}" "$why")"
        BAD=1
    elif [ "$old" = "$v" ]; then
        info "$(printf "  %-22s %-10s unchanged" "$k" "${old:-none}")"
    else
        ok "$(printf "  %-22s %-10s -> %s" "$k" "${old:-none}" "${v:-none (no limit / computed)}")"
    fi
done < <(_py thresholds "${CHECK_ARGS[@]}" | python3 -I -c '
import json, sys
for r in json.load(sys.stdin):
    print("|".join([r["key"], r["value"], str(r["ok"]), r["reason"]]))
')
if [ "$BAD" -ne 0 ]; then
    fail "Nothing written – fix the values above"
    print_summary; exit "${EXIT_CODE:-2}"
fi
if ! $APPLY; then
    info "Dry-run – nothing written. Write with: --apply"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Write
# =============================================================================
section "Write"
BAK="$CONF.bak_$(date +%Y%m%d_%H%M%S)"
cp -p "$CONF" "$BAK" || { fail "Backup of $CONF failed – nothing written"; print_summary; exit "${EXIT_CODE:-2}"; }
ok "$(printf "  %-20s %s" "backup:" "$BAK")"
TMP="$(mktemp "$CONF.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
# replace KEY=... in place, append keys that are not in the file yet (e.g. WLSMON_LOAD)
if python3 -I - "$CONF" "$TMP" "${SETS[@]}" <<'PYEOF'
import sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
new = dict(p.split("=", 1) for p in pairs)
out, seen = [], set()
for line in open(src, encoding="utf-8"):
    key = line.split("=", 1)[0].strip()
    if "=" in line and not line.lstrip().startswith("#") and key in new:
        out.append("%s=%s\n" % (key, new[key]))
        seen.add(key)
    else:
        out.append(line)
missing = [k for k in new if k not in seen]
if missing:
    out.append("\n# --- added by 03-set-thresholds.sh ---\n")
    out.extend("%s=%s\n" % (k, new[k]) for k in missing)
open(dst, "w", encoding="utf-8").writelines(out)
PYEOF
then
    chmod --reference="$CONF" "$TMP" && mv "$TMP" "$CONF" \
        && ok "$(printf "  %-20s %s" "written:" "$CONF")"
else
    fail "Writing $CONF failed – the file is unchanged (backup: $BAK)"
    print_summary; exit "${EXIT_CODE:-2}"
fi

# =============================================================================
# Check
# =============================================================================
section "Check"
if [ -f "$INSTALLED" ]; then
    WLSMON_BASE="$BASE" python3 -I "$INSTALLED" collect --check < /dev/null 2>&1 | sed 's/^/    /' | tee -a "$LOG_FILE"
    info "The service uses the new values at its next run (at most 5 min) – no restart needed"
else
    warn "No $INSTALLED – run 01-install-wlsmon_fmw.sh --apply"
fi

print_summary
exit "$EXIT_CODE"
