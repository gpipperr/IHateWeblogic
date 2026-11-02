#!/bin/bash
# =============================================================================
# Script   : 00a-db_env_interview.sh
# Purpose  : Create and maintain 60-RCU-DB-19c/environment_db.conf from the
#            template environment_db.conf.example – instead of cp + vi:
#              1. new file from the template; an existing file gets the keys
#                 the template has and the file misses (new template keys
#                 arrive with git pull), its values are kept
#              2. ORACLE_BASE / ORACLE_INVENTORY are NOT asked: they come from
#                 environment.conf – a fixed value overriding them is replaced
#                 by the template's default form (customer 2026-11-02:
#                 /u01 values overrode /oracle + /opt/oraInventory)
#              3. asks only what differs per installation (DB home with the
#                 RU of patches_db.csv, edition, SID / CDB / PDB = DB_SERVICE,
#                 listener port = DB_PORT, SGA / PGA from RAM, data / FRA,
#                 archivelog, audit retention, FMW tablespace = RCU_TABLESPACE)
#              4. consistency check against environment.conf, /etc/oraInst.loc,
#                 patches_db.csv, RAM, disk and an already installed DB
#            Every change on a working copy: dry-run shows the diff, --apply
#            writes it (backup first, chmod 600).
# Call     : ./60-RCU-DB-19c/00a-db_env_interview.sh            (dry-run)
#            ./60-RCU-DB-19c/00a-db_env_interview.sh --apply
#            ./60-RCU-DB-19c/00a-db_env_interview.sh --reset --apply
#            ./60-RCU-DB-19c/00a-db_env_interview.sh --check
# Options  : --apply   write environment_db.conf
#            --reset   ask all values again (current value = default)
#            --check   read-only consistency check of the existing file
#            --help    show usage
# Runs as  : oracle (before 00b- / 01-; after 09-Install/01-setup-interview.sh)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/00a-db_env_interview.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"
DB_CONF="$SCRIPT_DIR/environment_db.conf"
TEMPLATE="$SCRIPT_DIR/environment_db.conf.example"
PATCHES_DB="$ROOT_DIR/09-Install/download/patches_db.csv"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"
check_env_conf "$ENV_CONF" || { printf "  Run first: 09-Install/01-setup-interview.sh --apply\n" >&2; exit 2; }
# shellcheck source=../environment.conf
source "$ENV_CONF"
init_log

APPLY=false; RESET=false; CHECK_ONLY=false
_usage() {
    printf "Usage: %s [--apply] [--reset] [--check]\n\n" "$(basename "$0")"
    printf "  %-10s %s\n" "(none)"  "dry-run: interview, show the diff, write nothing"
    printf "  %-10s %s\n" "--apply" "write environment_db.conf (backup first)"
    printf "  %-10s %s\n" "--reset" "ask all values again (current value = default)"
    printf "  %-10s %s\n" "--check" "read-only consistency check of the existing file"
    exit 0
}
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=true ;;
        --reset) RESET=true ;;
        --check) CHECK_ONLY=true ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done
[ -f "$TEMPLATE" ] || { fail "Template missing: $TEMPLATE"; print_summary; exit 2; }

# =============================================================================
# Working copy + line helpers
# =============================================================================
WORK="$(mktemp)"; trap 'rm -f "$WORK" "$WORK.tmp"' EXIT
NEW_FILE=false
if [ -f "$DB_CONF" ]; then cp -p "$DB_CONF" "$WORK"; else cp "$TEMPLATE" "$WORK"; NEW_FILE=true; fi

# _raw KEY [FILE] – value text of KEY= (quotes and trailing comment removed)
_raw() {
    awk -v k="$1" '
        index($0, k "=") == 1 {
            r = substr($0, length(k) + 2)
            if (substr(r, 1, 1) == "\"") { r = substr(r, 2); r = substr(r, 1, index(r, "\"") - 1) }
            else sub(/[ \t]+#.*$|[ \t]*$/, "", r)
            print r; exit
        }' "${2:-$WORK}"
}
_has() { grep -q "^$1=" "${2:-$WORK}"; }
# _set KEY VALUE – replace the value of KEY= in the working copy, keep a
# trailing comment; numbers / true / false unquoted, everything else quoted
_set() {
    local k="$1" v="$2" q='"'
    [[ "$v" =~ ^([0-9]+|true|false)$ ]] && q=""
    if _has "$k"; then
        awk -v k="$k" -v nv="$q$v$q" '
            index($0, k "=") == 1 {
                r = substr($0, length(k) + 2); c = ""
                if (substr(r, 1, 1) == "\"") { t = substr(r, 2); t = substr(t, index(t, "\"") + 1) }
                else { t = r; sub(/^[^ \t#]*/, "", t) }
                if (match(t, /[ \t]+#.*$/)) c = substr(t, RSTART)
                print k "=" nv c; next
            }
            { print }' "$WORK" > "$WORK.tmp" && mv "$WORK.tmp" "$WORK"
    else
        printf '%s=%s%s%s\n' "$k" "$q" "$v" "$q" >> "$WORK"
    fi
}
# _eff KEY – effective value: environment.conf + working copy, expanded
_eff() { ( source "$ENV_CONF" > /dev/null 2>&1; source "$WORK" > /dev/null 2>&1; eval "printf '%s' \"\${$1:-}\"" ); }
_expand() { ( source "$ENV_CONF" > /dev/null 2>&1; source "$WORK" > /dev/null 2>&1; eval "printf '%s' \"$1\"" ); }
_free_gb() { local d="$1"; while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
             df -Pk "$d" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }'; }

# RU of the DB patch list (db_ru row) – "19.33.0"
RU_DIR=""
if [ -f "$PATCHES_DB" ]; then
    RU_DIR="$(awk -F';' '$5 == "db_ru" { if (match($6, /19\.[0-9]+/)) print substr($6, RSTART, RLENGTH) ".0"; exit }' "$PATCHES_DB")"
fi
# installed DB / home – evaluated on the working copy (again after step 2,
# when ORACLE_BASE comes from environment.conf)
ORATAB="${IHW_ORATAB:-/etc/oratab}"   # override only for tests
_detect() {
    DB_EXISTS=false; HOME_EXISTS=false
    _sid_now="$(_eff DB_SID)"
    [ -n "$_sid_now" ] && grep -q "^${_sid_now}:" "$ORATAB" 2>/dev/null && DB_EXISTS=true
    [ -x "$(_eff DB_ORACLE_HOME)/bin/sqlplus" ] && HOME_EXISTS=true
    return 0
}
_detect

printLine
section "DB environment interview – $(date '+%Y-%m-%d %H:%M:%S')"
printList "File"        16 "$DB_CONF$($NEW_FILE && printf ' (new – from the template)')"
printList "Template"    16 "$TEMPLATE"
printList "Mode"        16 "$( $CHECK_ONLY && printf 'check only' || { $APPLY && printf 'APPLY' || printf 'dry-run'; } )$($RESET && printf ', reset')"
printList "Database"    16 "$( $DB_EXISTS && printf '%s exists (/etc/oratab) – SID / PDB are not changed' "$_sid_now" || printf 'not created yet')"
$CHECK_ONLY && $NEW_FILE && { fail "No $DB_CONF – create it: $(basename "$0") --apply"; print_summary; exit 2; }

if ! $CHECK_ONLY; then
# =============================================================================
# 1. Template keys missing in the file
# =============================================================================
section "1. Template keys"
_added=0
while IFS= read -r _line; do
    _k="${_line%%=*}"
    _has "$_k" && continue
    [ "$_added" -eq 0 ] && printf '\n# --- added from environment_db.conf.example by 00a-db_env_interview.sh (%s) ---\n' "$(date +%Y-%m-%d)" >> "$WORK"
    printf '%s\n' "$_line" >> "$WORK"
    info "$(printf "  added: %s" "$_line")"
    _added=$(( _added + 1 ))
done < <(grep -E '^[A-Z_]+=' "$TEMPLATE")
[ "$_added" -eq 0 ] && ok "all template keys present"

# =============================================================================
# 2. Inherited values – never fixed in this file
# =============================================================================
section "2. Inherited from environment.conf (not asked)"
for _k in ORACLE_BASE ORACLE_INVENTORY; do
    _tpl="$(grep -E "^${_k}=" "$TEMPLATE" | head -1)"
    _cur="$(grep -E "^${_k}=" "$WORK" | head -1)"
    if [ "$_cur" = "$_tpl" ]; then
        ok "$(printf "  %-18s from environment.conf: %s" "$_k" "$(_eff "$_k")")"
    else
        warn "$(printf "  %-18s fixed here ('%s') – replaced by the default form (environment.conf: '%s')" "$_k" "$(_raw "$_k")" "${!_k:-}")"
        awk -v k="$_k" -v nl="$_tpl" 'index($0, k "=") == 1 { print nl; next } { print }' "$WORK" > "$WORK.tmp" && mv "$WORK.tmp" "$WORK"
    fi
done

_detect

# =============================================================================
# 3. Interview
# =============================================================================
section "3. Values of this installation"
# _ask_db KEY LABEL DEFAULT [RECHECK]
#   kept when set in an existing file (not --reset); RECHECK non-empty = the
#   kept value contradicts environment.conf -> asked again with DEFAULT
_ask_db() {
    local k="$1" label="$2" def="$3" recheck="${4:-}" cur input
    cur="$(_raw "$k")"
    if ! $NEW_FILE && ! $RESET && [ -z "$recheck" ]; then
        ok "$(printf "  %-26s %s  [kept]" "$k" "$cur")"
        return 0
    fi
    $RESET && [ -n "$cur" ] && [ -z "$recheck" ] && def="$cur"
    [ -n "$recheck" ] && warn "  $k: $recheck"
    printf "  \033[1m%-26s\033[0m %s\n" "$label" "$( [ "$(_expand "$def")" != "$def" ] && printf '(= %s)' "$(_expand "$def")")"
    printf "  %-26s [%s]: " "$k" "$def"
    read -r input
    input="${input:-$def}"
    _set "$k" "$input"
    printf "  \033[32m  ✓  %s = %s\033[0m\n" "$k" "$input" | tee -a "$LOG_FILE"
}
_ask_menu_db() {   # KEY LABEL OPT1 OPT2 … (value:description)
    local k="$1" label="$2" cur sel i=1; shift 2
    cur="$(_raw "$k")"
    if ! $NEW_FILE && ! $RESET; then ok "$(printf "  %-26s %s  [kept]" "$k" "$cur")"; return 0; fi
    printf "  \033[1m%s\033[0m\n" "$label"
    for o in "$@"; do printf "    [%d] %s%s\n" "$i" "${o#*:}" "$( [ "${o%%:*}" = "$cur" ] && printf '  (current)')"; i=$(( i + 1 )); done
    while true; do
        printf "  Selection [1]: "; read -r sel; sel="${sel:-1}"
        [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le $# ] && break
    done
    eval "o=\"\${$sel}\""
    _set "$k" "${o%%:*}"
    printf "  \033[32m  ✓  %s = %s\033[0m\n" "$k" "${o%%:*}" | tee -a "$LOG_FILE"
}

# DB home: the directory names the RU (09-db_patch_rcu.sh installs the next one beside it)
_home_cur="$(_eff DB_ORACLE_HOME)"
_home_re=""
if [ -n "$RU_DIR" ] && ! $HOME_EXISTS && [ "$(basename "$(dirname "$_home_cur")")" != "$RU_DIR" ]; then
    _home_re="directory '$(basename "$(dirname "$_home_cur")")' but the RU of patches_db.csv is $RU_DIR (home not installed yet)"
fi
_ask_db DB_ORACLE_HOME "DB home (directory = RU)" "\${ORACLE_BASE}/product/${RU_DIR:-19.33.0}/db_home1" "$_home_re"
_ask_menu_db DB_EDITION "Database edition (licence)" "EE:Enterprise Edition" "SE2:Standard Edition 2"

if $DB_EXISTS; then
    for _k in DB_SID DB_CDB_NAME DB_PDB_NAME; do ok "$(printf "  %-26s %s  [database exists]" "$_k" "$(_raw "$_k")")"; done
else
    _ask_db DB_SID      "Instance name (SID)"      "$(_raw DB_SID)"
    _ask_db DB_CDB_NAME "Container database name"  "$(_raw DB_CDB_NAME)"
    _pdb_re=""
    [ -n "${DB_SERVICE:-}" ] && [ "${DB_SERVICE^^}" != "$(_eff DB_PDB_NAME | tr '[:lower:]' '[:upper:]')" ] \
        && _pdb_re="PDB '$(_eff DB_PDB_NAME)' but DB_SERVICE in environment.conf is '$DB_SERVICE' (RCU / domain connect to it)"
    _ask_db DB_PDB_NAME "PDB name (= DB_SERVICE)"  "${DB_SERVICE:+${DB_SERVICE^^}}" "$_pdb_re"
fi
_port_re=""
[ -n "${DB_PORT:-}" ] && [ "$DB_PORT" != "$(_eff DB_LISTENER_PORT)" ] && _port_re="listener port $(_eff DB_LISTENER_PORT) but DB_PORT in environment.conf is $DB_PORT"
_ask_db DB_LISTENER_PORT "Listener port (= DB_PORT)" "${DB_PORT:-1521}" "$_port_re"

# memory proposal: the DB shares the host with WebLogic / Forms / Reports
_ram_mb="$(awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo)"
_sga=$(( _ram_mb * 15 / 100 / 256 * 256 )); [ "$_sga" -lt 1536 ] && _sga=1536; [ "$_sga" -gt 4096 ] && _sga=4096
_pga=$(( _sga / 3 / 128 * 128 )); [ "$_pga" -lt 512 ] && _pga=512
info "$(printf "  RAM %s MB (available %s MB) – proposal SGA %s / PGA %s MB (shared FMW host)" "$_ram_mb" \
    "$(awk '/MemAvailable/ { printf "%d", $2 / 1024 }' /proc/meminfo)" "$_sga" "$_pga")"
_ask_db DB_SGA_MB "SGA in MB" "$( $NEW_FILE && printf '%s' "$_sga" || _raw DB_SGA_MB)"
_ask_db DB_PGA_MB "PGA in MB" "$( $NEW_FILE && printf '%s' "$_pga" || _raw DB_PGA_MB)"

info "$(printf "  free on the data file system: %s GB" "$(_free_gb "$(_eff DB_DATA_DIR)")")"
_ask_db DB_DATA_DIR           "Data files"               "$(_raw DB_DATA_DIR)"
_ask_db DB_FAST_RECOVERY_AREA "Fast recovery area"       "$(_raw DB_FAST_RECOVERY_AREA)"
_ask_db DB_RECOVERY_SIZE_MB   "FRA size in MB"           "$(_raw DB_RECOVERY_SIZE_MB)"
_ask_menu_db DB_ARCHIVELOG "Archivelog mode" "false:no – test / development (metadata DB)" "true:yes – production"
_ask_db DB_AUDIT_RETAIN_DAYS  "Audit retention (days)"   "$(_raw DB_AUDIT_RETAIN_DAYS)"
_ts_re=""
[ "${RCU_TABLESPACE:-}" != "$(_eff DB_FMW_TABLESPACE)" ] && _ts_re="DB_FMW_TABLESPACE '$(_eff DB_FMW_TABLESPACE)' but RCU_TABLESPACE in environment.conf is '${RCU_TABLESPACE:-}'"
_ask_db DB_FMW_TABLESPACE "FMW tablespace (= RCU_TABLESPACE, empty = RCU default)" "${RCU_TABLESPACE:-}" "$_ts_re"
fi   # ! CHECK_ONLY

# =============================================================================
# 4. Consistency check (on the working copy = what will be / is written)
# =============================================================================
section "4. Consistency check"
_chk() { if [ "$1" = ok ]; then ok "  $2"; else warn "  $2"; fi; }
for _k in ORACLE_BASE ORACLE_INVENTORY; do
    _e="$(_eff "$_k")"
    [ -z "${!_k:-}" ] || [ "$_e" = "${!_k}" ] && _chk ok "$(printf "%-18s %s (= environment.conf)" "$_k" "$_e")" \
        || _chk warn "$(printf "%-18s %s – environment.conf has %s" "$_k" "$_e" "${!_k}")"
done
_inv_loc="$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc 2>/dev/null | head -1)"
if [ -n "$_inv_loc" ]; then
    [ "$_inv_loc" = "$(_eff ORACLE_INVENTORY)" ] && _chk ok "/etc/oraInst.loc   inventory_loc=$_inv_loc" \
        || _chk warn "/etc/oraInst.loc   inventory_loc=$_inv_loc – ORACLE_INVENTORY is $(_eff ORACLE_INVENTORY) (the installer uses oraInst.loc; fix ORACLE_INVENTORY in environment.conf)"
fi
_pdb="$(_eff DB_PDB_NAME)"
[ "${DB_SERVICE^^}" = "${_pdb^^}" ] && _chk ok "DB_PDB_NAME        $_pdb (= DB_SERVICE)" \
    || _chk warn "DB_PDB_NAME        $_pdb – DB_SERVICE in environment.conf is '${DB_SERVICE:-}' (RCU / data sources connect to DB_SERVICE)"
[ "${DB_PORT:-1521}" = "$(_eff DB_LISTENER_PORT)" ] && _chk ok "DB_LISTENER_PORT   $(_eff DB_LISTENER_PORT) (= DB_PORT)" \
    || _chk warn "DB_LISTENER_PORT   $(_eff DB_LISTENER_PORT) – DB_PORT in environment.conf is ${DB_PORT:-}"
case "${DB_HOST:-}" in
    localhost|127.0.0.1|"$(hostname -s)"|"$(hostname -f)"|$(hostname -I 2>/dev/null | tr ' ' '|' | sed 's/|$//')) _chk ok "DB_HOST            ${DB_HOST} (this host)" ;;
    *) _chk warn "DB_HOST            '${DB_HOST:-}' is not this host – with a local RCU DB use localhost (environment.conf)" ;;
esac
_home="$(_eff DB_ORACLE_HOME)"
if [ -x "$_home/bin/sqlplus" ]; then
    _chk ok "DB_ORACLE_HOME     $_home (installed)"
elif [ -n "$RU_DIR" ] && [ "$(basename "$(dirname "$_home")")" != "$RU_DIR" ]; then
    _chk warn "DB_ORACLE_HOME     $_home – directory does not name the RU $RU_DIR of patches_db.csv"
else
    _f="$(_free_gb "$_home")"
    [ "${_f:-0}" -ge 20 ] && _chk ok "DB_ORACLE_HOME     $_home (not installed, ${_f} GB free)" \
        || _chk warn "DB_ORACLE_HOME     $_home – only ${_f:-?} GB free (home + staging need ~20 GB)"
fi
_mem=$(( $(_eff DB_SGA_MB) + $(_eff DB_PGA_MB) ))
_ram_mb="$(awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo)"
[ "$_mem" -le $(( _ram_mb / 2 )) ] && _chk ok "SGA + PGA          ${_mem} MB of ${_ram_mb} MB RAM" \
    || _chk warn "SGA + PGA          ${_mem} MB – more than half of ${_ram_mb} MB RAM (WebLogic / Reports share the host)"
[ "$(_eff DB_CHAR_SET)" = "AL32UTF8" ] && _chk ok "DB_CHAR_SET        AL32UTF8" || _chk warn "DB_CHAR_SET        $(_eff DB_CHAR_SET) – FMW requires AL32UTF8"
[ "$(_eff DB_FMW_TABLESPACE)" = "${RCU_TABLESPACE:-}" ] && _chk ok "DB_FMW_TABLESPACE  '$(_eff DB_FMW_TABLESPACE)' (= RCU_TABLESPACE)" \
    || _chk warn "DB_FMW_TABLESPACE  '$(_eff DB_FMW_TABLESPACE)' – RCU_TABLESPACE in environment.conf is '${RCU_TABLESPACE:-}'"
_arch="$(_eff DB_INSTALL_ARCHIVE)"
[ -f "$_arch" ] || [ -x "$_home/bin/sqlplus" ] && _chk ok "DB_INSTALL_ARCHIVE $_arch" \
    || info "  DB_INSTALL_ARCHIVE $_arch – not there yet (19.3 base ZIP, needed by 01-)"
$DB_EXISTS && info "  Database $_sid_now exists – the file describes it; SID / PDB / data dir changes would not move it"

# =============================================================================
# 5. Write
# =============================================================================
if ! $CHECK_ONLY; then
    section "5. Result"
    if ! $NEW_FILE && cmp -s "$DB_CONF" "$WORK"; then
        ok "No change – $DB_CONF is up to date"
    else
        if $NEW_FILE; then info "New file from the template"; else
            info "Changes:"; diff -u "$DB_CONF" "$WORK" | sed -n '3,$p' | grep -E '^[-+]' | sed 's/^/    /' | tee -a "$LOG_FILE"; fi
        if $APPLY; then
            $NEW_FILE || backup_file "$DB_CONF" "$SCRIPT_DIR" > /dev/null
            cp "$WORK" "$DB_CONF" && chmod 600 "$DB_CONF" && ok "Written: $DB_CONF (mode 600)$($NEW_FILE || printf ', backup %s' "$(basename "${LAST_BACKUP:-}")")"
            info "Next: ./60-RCU-DB-19c/00-root_db_os_baseline.sh --apply (root), then 00b- / 01-"
        else
            info "Dry-run – nothing written; --apply writes it"
        fi
    fi
fi

print_summary
exit "$EXIT_CODE"
