#!/bin/bash
# =============================================================================
# Script   : 09-db_patch_rcu.sh
# Purpose  : Patch the existing RCU repository database OUT-OF-PLACE: move the
#            instance from the running home (DB_ORACLE_HOME) into a new, already
#            patched home and run datapatch.
#            The new home is built before with
#              01-db_install_software.sh --target-home <new home> --fresh-patches --apply
#            (AutoUpgrade download of the current RU + OJVM + DPBP + OPatch + JDK,
#            runInstaller -applyRU). Flow with --apply:
#              1  checks: disk space FIRST, homes, RU versions, DB state,
#                 PDB$SEED, db_securefile, FMW requirements
#              2  backup: Data Pump of the RCU schemas (rcu_repository_check.sh
#                 --apply) + copy of dbs/, network/admin/, oratab, environment_db.conf
#              3  stop: FMW domain (startStop.sh stop-all), database, listener;
#                 VM snapshot pause (confirm_snapshot)
#              4  spfile / password file / network files -> new home
#              5  relink uniaud_on in the new home if the old one has it
#              6  /etc/oratab + environment_db.conf (DB_ORACLE_HOME, DB_ORACLE_HOME_PREV)
#                 switched; root commands for the two systemd units printed
#              7  listener + database started from the new home, service registration
#              8  datapatch -verbose, utlrp in all containers (catcon)
#              9  verification, FMW domain started, rcu_repository_check.sh
#            --rollback: the same back into DB_ORACLE_HOME_PREV; datapatch from
#            the old home rolls the SQL part of the newer RU back.
#            The old home is never removed by this script.
# Call     : ./60-RCU-DB-19c/09-db_patch_rcu.sh --new-home <dir>            (dry-run)
#            ./60-RCU-DB-19c/09-db_patch_rcu.sh --new-home <dir> --apply
#            ./60-RCU-DB-19c/09-db_patch_rcu.sh --rollback [--apply]
# Runs as  : oracle (on the DB host; systemd unit update needs root - printed)
# Requires : environment.conf, environment_db.conf (DB_ORACLE_HOME, DB_SID,
#            DB_PDB_NAME), the new home installed and registered in the inventory
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/09-db_patch_rcu.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
ENV_DB_CONF="$SCRIPT_DIR/environment_db.conf"
REQ_SQL="$SCRIPT_DIR/rcu_db_requirements.sql"

source "$LIB" 2>/dev/null || { printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2; }
for _f in "$ENV_CONF" "$ENV_DB_CONF"; do
    [ ! -f "$_f" ] && { printf "\033[31mFATAL\033[0m: Config not found: %s\n" "$_f" >&2; exit 2; }
    source "$_f"
done
unset _f

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false
ROLLBACK=false
NEW_HOME_ARG=""

_usage() {
    printf "Usage: %s --new-home <dir> [--apply] | --rollback [--apply]\n\n" "$(basename "$0")"
    printf "  %-18s %s\n" "--new-home DIR" "patched home built by 01-db_install_software.sh --target-home DIR"
    printf "  %-18s %s\n" "--rollback"     "back into DB_ORACLE_HOME_PREV (datapatch from the old home)"
    printf "  %-18s %s\n" "--apply"        "execute (default: checks + plan only)"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --new-home) shift; NEW_HOME_ARG="${1:?--new-home needs a directory}" ;;
        --rollback) ROLLBACK=true ;;
        --apply)    APPLY=true ;;
        --help|-h)  _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done

FROM_HOME="${DB_ORACLE_HOME:-}"
if $ROLLBACK; then
    TO_HOME="${DB_ORACLE_HOME_PREV:-}"
    [ -z "$TO_HOME" ] && { printf "\033[31mERROR\033[0m DB_ORACLE_HOME_PREV not set in environment_db.conf – nothing to roll back to\n" >&2; exit 1; }
else
    TO_HOME="$NEW_HOME_ARG"
    [ -z "$TO_HOME" ] && _usage
fi
TO_HOME="${TO_HOME%/}"; FROM_HOME="${FROM_HOME%/}"
SID="${DB_SID:?DB_SID not set}"
PDB="${DB_PDB_NAME:-}"
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$DIAG_LOG_DIR/rcu_patch_$TS"

# _sql HOME "statements" - local sqlplus / as sysdba against $SID from HOME.
# TNS_ADMIN is set to the home's network/admin: with the shared TNS_ADMIN an
# instance started here could not resolve a local_listener alias (2026-10-28).
_sql() {
    ORACLE_HOME="$1" ORACLE_SID="$SID" TNS_ADMIN="$1/network/admin" \
    LD_LIBRARY_PATH="$1/lib" "$1/bin/sqlplus" -S -L / as sysdba <<SQLEOF 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 300 VERIFY OFF TRIMSPOOL ON
$2
EXIT;
SQLEOF
}
_lsnr() { ORACLE_HOME="$1" TNS_ADMIN="$1/network/admin" "$1/bin/lsnrctl" "$2" LISTENER 2>&1; }
_ru_of() {   # RU version of a home, e.g. 19.30.0.0.260120
    ORACLE_HOME="$1" "$1/OPatch/opatch" lspatches 2>/dev/null \
        | grep -m1 -oE 'Database Release Update ?: ?[0-9]+(\.[0-9]+){4}' | grep -oE '[0-9]+(\.[0-9]+){4}'
}
_pmon_home() {   # home of the running PMON of $SID (empty = down)
    local pid; pid="$(pgrep -f "^ora_pmon_${SID}$" | head -1)"
    [ -n "$pid" ] && readlink -f "/proc/$pid/exe" 2>/dev/null | sed 's#/bin/oracle$##'
}
_free_gb() { local d="$1"; while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
    df -Pk "$d" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1048576 }'; }

printLine
printf "\n\033[1m  IHateWeblogic – RCU database patch (out-of-place)\033[0m\n" | tee -a "$LOG_FILE"
printList "Mode"      20 "$($ROLLBACK && printf 'ROLLBACK' || printf 'PATCH')$($APPLY || printf ' – dry-run')"
printList "From home" 20 "$FROM_HOME"
printList "To home"   20 "$TO_HOME"
printList "SID / PDB" 20 "$SID / ${PDB:-?}"
printLine

# =============================================================================
# 1. Checks – disk space first
# =============================================================================

section "1a. Disk space"
_pfx="${DB_SCHEMA_PREFIX:-DEV}"
_dp_dir="$(_sql "$FROM_HOME" "ALTER SESSION SET CONTAINER=${PDB:-CDB\$ROOT};
SELECT directory_path FROM dba_directories WHERE directory_name='DATA_PUMP_DIR';" | grep '^/' | head -1)"
_rcu_mb="$(_sql "$FROM_HOME" "ALTER SESSION SET CONTAINER=${PDB:-CDB\$ROOT};
SELECT CEIL(NVL(SUM(bytes),0)/1048576) FROM dba_segments WHERE owner LIKE '${_pfx}\\_%' ESCAPE '\\';" | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d '[:space:]' | head -1)"
_need_gb=$(( (${_rcu_mb:-0} * 12 / 10) / 1024 + 1 ))
_chk_space() {   # label dir min_gb rec_gb
    local f; f="$(_free_gb "$2")"
    local m; m="$(printf "  %-26s %4s GB free (min %s, rec %s)  %s" "$1" "${f:-?}" "$3" "$4" "$2")"
    if [ "${f:-0}" -lt "$3" ]; then fail "$m"; elif [ "${f:-0}" -lt "$4" ]; then warn "$m"; else ok "$m"; fi
}
info "$(printf "  RCU schemas %s_*: %s MB -> Data Pump needs ~%s GB" "$_pfx" "${_rcu_mb:-?}" "$_need_gb")"
_chk_space "Data Pump (DATA_PUMP_DIR)" "${_dp_dir:-$ORACLE_BASE/admin}" "$_need_gb" $(( _need_gb + 1 ))
_chk_space "backup copy (log dir)"     "$DIAG_LOG_DIR" 1 1
_chk_space "data files (datapatch)"    "${DB_DATA_DIR:-$ORACLE_BASE/oradata}" 1 2
unset _rcu_mb _need_gb

section "1b. Homes and database"
# from-home runs the instance
_run_home="$(_pmon_home)"
if [ -z "$_run_home" ]; then
    fail "Instance $SID is not running – start it from $FROM_HOME first"
elif [ "$_run_home" = "$FROM_HOME" ]; then
    ok "Instance $SID runs from $FROM_HOME"
else
    fail "Instance $SID runs from $_run_home, not from DB_ORACLE_HOME=$FROM_HOME"
fi
# to-home installed + registered
_inv_xml="$(grep '^inventory_loc=' /etc/oraInst.loc 2>/dev/null | cut -d= -f2)/ContentsXML/inventory.xml"
if [ -x "$TO_HOME/bin/oracle" ] && grep -q "LOC=\"$TO_HOME\"" "$_inv_xml" 2>/dev/null; then
    ok "Target home installed and registered: $TO_HOME"
else
    fail "Target home not installed / not in the inventory: $TO_HOME"
    info "  Build it: 01-db_install_software.sh --target-home $TO_HOME --fresh-patches --apply"
fi
[ "$TO_HOME" = "$FROM_HOME" ] && fail "Target home = running home"
# RU versions
_ru_from="$(_ru_of "$FROM_HOME")"; _ru_to="$(_ru_of "$TO_HOME")"
info "$(printf "  RU from: %-20s to: %s" "${_ru_from:-?}" "${_ru_to:-?}")"
if ! $ROLLBACK && [ -n "$_ru_from" ] && [ -n "$_ru_to" ]; then
    if [ "$_ru_from" = "$_ru_to" ] || [ "$(printf '%s\n%s\n' "$_ru_from" "$_ru_to" | sort -V | tail -1)" != "$_ru_to" ]; then
        fail "Target home RU $_ru_to is not newer than $_ru_from"
    else
        ok "Target home has the newer RU ($_ru_to)"
    fi
fi
info "  OPatch target: $(ORACLE_HOME="$TO_HOME" "$TO_HOME/OPatch/opatch" version 2>/dev/null | head -1)"
[ -x "$TO_HOME/jdk/bin/java" ] && info "  JDK target   : $("$TO_HOME/jdk/bin/java" -version 2>&1 | head -1)"

if [ -n "$_run_home" ]; then
    # PDB$SEED READ ONLY, db_securefile, OPATCH_XML_INV (datapatch prerequisites)
    _seed="$(_sql "$FROM_HOME" "SELECT open_mode FROM v\$pdbs WHERE name='PDB\$SEED';" | grep -E 'READ|MOUNT' | head -1 | xargs)"
    if [ "$_seed" = "READ ONLY" ]; then ok "PDB\$SEED: READ ONLY"
    else warn "PDB\$SEED: ${_seed:-?} – before the patch: ALTER PLUGGABLE DATABASE PDB\$SEED OPEN READ ONLY (never READ WRITE)"; fi
    for _c in 'CDB$ROOT' "$PDB"; do
        [ -z "$_c" ] && continue
        _sf="$(_sql "$FROM_HOME" "ALTER SESSION SET CONTAINER=$_c;
SELECT UPPER(value) FROM v\$parameter WHERE name='db_securefile';" | grep -E '^[A-Z]+$' | head -1)"
        if [ "$_sf" = "FORCE" ]; then
            fail "db_securefile=FORCE in $_c – datapatch scripts can fail with ORA-43853 (set PREFERRED SCOPE=MEMORY for the patch)"
        else
            ok "db_securefile=${_sf:-?} in $_c"
        fi
    done
    _xi="$(_sql "$FROM_HOME" "SELECT COUNT(*) FROM opatch_xml_inv;" | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | head -1 | xargs)"
    [ -n "$_xi" ] && ok "OPATCH_XML_INV readable (datapatch inventory query)" \
        || warn "OPATCH_XML_INV not readable – datapatch may fail (QOpatch directory objects)"
    # FMW requirements in the PDB
    if [ -n "$PDB" ] && [ -f "$REQ_SQL" ]; then
        info "FMW 14.1.2 database requirements (PDB $PDB):"
        rcu_db_req_eval "$(_sql "$FROM_HOME" "ALTER SESSION SET CONTAINER=$PDB;
@$REQ_SQL")"
    fi
fi
unset _run_home _inv_xml _seed _c _sf _xi

if [ "${CNT_FAIL:-0}" -gt 0 ]; then
    fail "Checks failed – nothing changed"
    print_summary; exit 2
fi

if ! $APPLY; then
    section "Plan (with --apply)"
    info "  2 backup: rcu_repository_check.sh --apply (Data Pump) + copy to $BACKUP_DIR"
    info "  3 stop: FMW domain (startStop.sh stop-all), database + listener from $FROM_HOME, snapshot pause"
    info "  4 spfile${SID}.ora, orapw${SID}, network/admin/*.ora -> $TO_HOME"
    info "  5 uniaud_on relink in $TO_HOME (if $FROM_HOME has it)"
    info "  6 /etc/oratab, environment_db.conf (DB_ORACLE_HOME / DB_ORACLE_HOME_PREV), systemd units (root)"
    info "  7 start listener + database from $TO_HOME, wait for service registration"
    info "  8 datapatch -verbose, utlrp (catcon, all containers)"
    info "  9 verify, start FMW domain, rcu_repository_check.sh"
    warn "Dry-run – use --apply to execute (downtime of the FMW domain)"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# 2. Backup
# =============================================================================

section "2. Backup"
if ! $ROLLBACK && [ -x "$ROOT_DIR/07-Maintenance/rcu_repository_check.sh" ]; then
    info "Data Pump export of the RCU schemas (rcu_repository_check.sh --apply) ..."
    "$ROOT_DIR/07-Maintenance/rcu_repository_check.sh" --apply >> "$LOG_FILE" 2>&1
    _rc=$?
    if [ "$_rc" -ge 2 ]; then
        fail "rcu_repository_check.sh --apply rc=$_rc – see $LOG_FILE"
        print_summary; exit 2
    fi
    ok "Data Pump export done (rc=$_rc, dump files in DATA_PUMP_DIR)"
fi
mkdir -p "$BACKUP_DIR/dbs" "$BACKUP_DIR/network_admin"
cp -p "$FROM_HOME/dbs/"*"$SID"* "$FROM_HOME/dbs/init.ora" "$BACKUP_DIR/dbs/" 2>/dev/null
cp -p "$FROM_HOME/network/admin/"*.ora "$BACKUP_DIR/network_admin/" 2>/dev/null
cp -p /etc/oratab "$ENV_DB_CONF" "$BACKUP_DIR/" 2>/dev/null
ok "Config backup: $BACKUP_DIR"

# =============================================================================
# 3. Stop
# =============================================================================

section "3. Stop"
if [ "${LOCAL_REP_DB:-false}" = "true" ] && [ -x "$ROOT_DIR/01-Run/startStop.sh" ]; then
    info "Stopping the FMW domain (startStop.sh stop-all) ..."
    "$ROOT_DIR/01-Run/startStop.sh" stop-all --apply >> "$LOG_FILE" 2>&1 \
        && ok "FMW domain stopped" || warn "startStop.sh stop-all reported problems – see $LOG_FILE"
else
    warn "FMW domain not on this host (LOCAL_REP_DB=${LOCAL_REP_DB:-false}) – stop it on the FMW host now"
    askYesNo "FMW domain stopped?" "n" || { fail "Aborted – domain still running"; print_summary; exit 2; }
fi
_sql "$FROM_HOME" "SHUTDOWN IMMEDIATE" | tee -a "$LOG_FILE" | grep -E 'ORACLE instance shut down|ORA-' | head -3
[ -z "$(_pmon_home)" ] && ok "Database $SID stopped" || { fail "Database still running"; print_summary; exit 2; }
_lsnr "$FROM_HOME" stop >> "$LOG_FILE" && ok "Listener stopped ($FROM_HOME)" || warn "Listener stop reported an error"
confirm_snapshot || { EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# =============================================================================
# 4. Files -> target home
# =============================================================================

section "4. spfile / password file / network files"
for _f in "spfile${SID}.ora" "orapw${SID}" init.ora; do
    if [ -f "$FROM_HOME/dbs/$_f" ]; then
        [ -f "$TO_HOME/dbs/$_f" ] && cp -p "$TO_HOME/dbs/$_f" "$TO_HOME/dbs/$_f.bak_$TS"
        cp -p "$FROM_HOME/dbs/$_f" "$TO_HOME/dbs/$_f" && ok "  dbs/$_f"
    fi
done
for _f in "$FROM_HOME/network/admin/"*.ora; do
    [ -f "$_f" ] || continue
    _b="$(basename "$_f")"
    [ -f "$TO_HOME/network/admin/$_b" ] && cp -p "$TO_HOME/network/admin/$_b" "$TO_HOME/network/admin/$_b.bak_$TS"
    cp -p "$_f" "$TO_HOME/network/admin/$_b" && ok "  network/admin/$_b"
done
unset _f _b

# =============================================================================
# 5. Unified auditing link
# =============================================================================

section "5. Unified auditing (uniaud_on)"
_uniaud() { ar -t "$1/rdbms/lib/libknlopt.a" 2>/dev/null | grep -q kzaiang && printf on || printf off; }
_ua_from="$(_uniaud "$FROM_HOME")"; _ua_to="$(_uniaud "$TO_HOME")"
if [ "$_ua_from" = "on" ] && [ "$_ua_to" != "on" ]; then
    info "Relinking $TO_HOME with uniaud_on ..."
    ( cd "$TO_HOME/rdbms/lib" && ORACLE_HOME="$TO_HOME" make -f ins_rdbms.mk uniaud_on ioracle ) >> "$LOG_FILE" 2>&1
    [ "$(_uniaud "$TO_HOME")" = "on" ] && ok "uniaud_on linked in $TO_HOME" || { fail "uniaud_on relink failed – see $LOG_FILE"; print_summary; exit 2; }
else
    ok "uniaud: from=$_ua_from to=$_ua_to – nothing to do"
fi
unset _ua_from _ua_to

# =============================================================================
# 6. Switch the configuration
# =============================================================================

section "6. oratab / environment_db.conf / systemd"
if grep -q "^${SID}:" /etc/oratab 2>/dev/null; then
    sed -i "s#^${SID}:[^:]*:#${SID}:${TO_HOME}:#" /etc/oratab \
        && ok "/etc/oratab: ${SID}:${TO_HOME}" || warn "/etc/oratab not writable – set ${SID}:${TO_HOME}:Y by hand"
else
    warn "/etc/oratab has no entry for $SID"
fi
cp -p "$ENV_DB_CONF" "$ENV_DB_CONF.bak_$TS"
sed -i "s#^DB_ORACLE_HOME=.*#DB_ORACLE_HOME=\"${TO_HOME}\"#" "$ENV_DB_CONF"
if grep -q '^DB_ORACLE_HOME_PREV=' "$ENV_DB_CONF"; then
    sed -i "s#^DB_ORACLE_HOME_PREV=.*#DB_ORACLE_HOME_PREV=\"${FROM_HOME}\"#" "$ENV_DB_CONF"
else
    printf '# previous home - 09-db_patch_rcu.sh --rollback (%s)\nDB_ORACLE_HOME_PREV="%s"\n' "$TS" "$FROM_HOME" >> "$ENV_DB_CONF"
fi
ok "environment_db.conf: DB_ORACLE_HOME=$TO_HOME, DB_ORACLE_HOME_PREV=$FROM_HOME"
_units=""
for _u in /etc/systemd/system/oracle-listener.service /etc/systemd/system/oracle-db.service; do
    grep -q "$FROM_HOME" "$_u" 2>/dev/null && _units="$_units $_u"
done
if [ -n "$_units" ]; then
    warn "systemd units still point to the old home – as root:"
    info "    sed -i 's#${FROM_HOME}#${TO_HOME}#g'${_units}"
    info "    systemctl daemon-reload"
else
    ok "systemd units: no reference to the old home"
fi
unset _units _u

# =============================================================================
# 7. Start from the target home
# =============================================================================

section "7. Start from $TO_HOME"
_lsnr "$TO_HOME" start >> "$LOG_FILE" && ok "Listener started" || { fail "Listener start failed"; print_summary; exit 2; }
_sql "$TO_HOME" "STARTUP" | tee -a "$LOG_FILE" | grep -E 'Database opened|ORA-' | head -3
[ "$(_pmon_home)" = "$TO_HOME" ] && ok "Database $SID runs from $TO_HOME" \
    || { fail "Database did not start from $TO_HOME – see $LOG_FILE"; print_summary; exit 2; }
_sql "$TO_HOME" "ALTER SYSTEM REGISTER;" > /dev/null
_svc_ok=false
for _i in $(seq 1 24); do
    if _lsnr "$TO_HOME" status | grep -qi "Service \"${PDB:-$SID}\""; then _svc_ok=true; break; fi
    sleep 5
done
$_svc_ok && ok "Service ${PDB:-$SID} registered with the listener" \
    || warn "Service ${PDB:-$SID} not registered after 120 s – check local_listener (lsnrctl status)"
unset _i _svc_ok

# =============================================================================
# 8. datapatch + utlrp
# =============================================================================

section "8. datapatch"
info "datapatch -verbose (CDB + PDBs) ..."
( cd "$TO_HOME/OPatch" && ORACLE_HOME="$TO_HOME" ORACLE_SID="$SID" TNS_ADMIN="$TO_HOME/network/admin" \
    ./datapatch -verbose ) >> "$LOG_FILE" 2>&1
_dp_rc=$?
_sp="$(_sql "$TO_HOME" "SELECT con_id||' '||patch_id||' '||action||' '||status FROM cdb_registry_sqlpatch
WHERE action_time > SYSDATE - 1/24 ORDER BY action_time;")"
printf '%s\n' "$_sp" | grep -E '^[0-9]' | while read -r _cid _pid _act _st; do
    _m="$(printf "  con %-3s patch %-10s %-10s %s" "$_cid" "$_pid" "$_act" "$_st")"
    [ "$_st" = "SUCCESS" ] && ok "$_m" || fail "$_m"
done
if [ "$_dp_rc" -ne 0 ] || printf '%s\n' "$_sp" | grep -qE ' (WITH ERRORS|FAILED|END)$'; then
    fail "datapatch rc=$_dp_rc – logs: $TO_HOME/cfgtoollogs/sqlpatch/ – domain stays stopped"
    print_summary; exit 2
fi
ok "datapatch completed (rc=0)"
info "utlrp in all containers (catcon) ..."
( cd "$TO_HOME/rdbms/admin" && ORACLE_HOME="$TO_HOME" ORACLE_SID="$SID" \
    "$TO_HOME/perl/bin/perl" catcon.pl -n 1 -d "$TO_HOME/rdbms/admin" -l "$BACKUP_DIR" -b utlrp utlrp.sql ) >> "$LOG_FILE" 2>&1 \
    && ok "utlrp done" || warn "utlrp reported problems – see $BACKUP_DIR/utlrp*.log"
unset _dp_rc _sp

# =============================================================================
# 9. Verify + start the domain
# =============================================================================

section "9. Verification"
info "  version: $(_sql "$TO_HOME" "SELECT version_full FROM v\$instance;" | grep -E '^[0-9]' | head -1)"
[ "$(_pmon_home)" = "$TO_HOME" ] && ok "PMON binary from $TO_HOME" || fail "PMON not from $TO_HOME"
if [ -n "$PDB" ] && [ -f "$REQ_SQL" ]; then
    rcu_db_req_eval "$(_sql "$TO_HOME" "ALTER SESSION SET CONTAINER=$PDB;
@$REQ_SQL")"
fi
if [ "${LOCAL_REP_DB:-false}" = "true" ] && [ -x "$ROOT_DIR/01-Run/startStop.sh" ]; then
    info "Starting the FMW domain (startStop.sh start-all) ..."
    "$ROOT_DIR/01-Run/startStop.sh" start-all --apply >> "$LOG_FILE" 2>&1 \
        && ok "FMW domain started" || warn "startStop.sh start-all reported problems – see $LOG_FILE"
    "$ROOT_DIR/07-Maintenance/rcu_repository_check.sh" >> "$LOG_FILE" 2>&1
    _rc=$?
    [ "$_rc" -lt 2 ] && ok "rcu_repository_check.sh rc=$_rc (data sources log in)" \
        || fail "rcu_repository_check.sh rc=$_rc – see $LOG_FILE"
else
    info "Start the FMW domain on its host now, then run 07-Maintenance/rcu_repository_check.sh"
fi

section "Next steps"
info "  Old home kept: $FROM_HOME  (way back: $(basename "$0") --rollback --apply)"
info "  After some days of stable operation remove it:"
info "    $FROM_HOME/deinstall/deinstall -checkonly   then   -silent"
info "  Data Pump dumps: DATA_PUMP_DIR (rcu_${_pfx}_*_*.dmp) – delete when no longer needed"

print_summary
exit "$EXIT_CODE"
