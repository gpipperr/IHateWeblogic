#!/bin/bash
# =============================================================================
# Script   : 04-db_setup_listener.sh
# Purpose  : Create Oracle Net configuration and start the TNS Listener.
#              - listener.ora  (TCP, host IP, port 1521)
#              - sqlnet.ora    (basic name resolution)
#              - tnsnames.ora  (CDB + PDB aliases)
#              - Start LISTENER
#              - systemd oracle-listener.service for auto-start at boot
#            Must run BEFORE 05-db_create_database.sh — DBCA requires the
#            listener to be running for dynamic service registration.
# Call     : ./60-RCU-DB-19c/04-db_setup_listener.sh
#            ./60-RCU-DB-19c/04-db_setup_listener.sh --apply
#            ./60-RCU-DB-19c/04-db_setup_listener.sh --help
# Runs as  : oracle  (systemd unit install requires root — script prompts)
# Requires : environment.conf, environment_db.conf
# Ref      : 60-RCU-DB-19c/docs/04-db_setup_listener.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
ENV_DB_CONF="$SCRIPT_DIR/environment_db.conf"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2
fi
source "$LIB"

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

_usage() {
    printf "Usage: %s [--apply] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"  "Dry-run: show configuration, no changes"
    printf "  %-12s %s\n" "--apply" "Write Net config, start listener, install systemd unit"
    printf "  %-12s %s\n" "--help"  "Show this help"
    printf "\nRuns as: oracle (systemd unit install requires root — prompted)\n"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)   APPLY=true ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 1 ;;
    esac
done
unset _arg

export ORACLE_HOME="$DB_ORACLE_HOME"

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – DB Listener Setup\033[0m\n"               | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                              | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"                 | tee -a "$LOG_FILE"
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                     | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ -x "$DB_ORACLE_HOME/bin/lsnrctl" ] \
    && ok "lsnrctl: $DB_ORACLE_HOME/bin/lsnrctl" \
    || { fail "lsnrctl not found — run 02-db_patch_db_software.sh --apply first"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# Resolve listener host
_listener_host="${DB_LISTENER_HOST:-}"
if [ -z "$_listener_host" ]; then
    _listener_host="$(hostname -f 2>/dev/null || hostname)"
fi
_listener_port="${DB_LISTENER_PORT:-1521}"

# Warn if host resolves to loopback
_resolved_ip="$(getent hosts "$_listener_host" 2>/dev/null | awk '{print $1}' | head -1)"
if printf "%s" "${_resolved_ip:-}" | grep -qE '^127\.'; then
    warn "$_listener_host resolves to loopback ($_resolved_ip)"
    warn "  Remote connections (FMW, RCU) will NOT work"
    warn "  Set DB_LISTENER_HOST to the external hostname/IP in environment_db.conf"
else
    ok "Listener host: $_listener_host (resolves to: ${_resolved_ip:-unknown})"
fi

printList "Listener port"   28 "$_listener_port"
printList "ORACLE_HOME"     28 "$DB_ORACLE_HOME"

_net_admin="$DB_ORACLE_HOME/network/admin"
printList "network/admin"   28 "$_net_admin"

# =============================================================================
# Dry-run exit
# =============================================================================

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to apply settings."
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# 1. listener.ora
# =============================================================================

section "listener.ora"

_listener_ora="$_net_admin/listener.ora"
backup_file "$_listener_ora" "$_net_admin" 2>/dev/null || true

info "Writing: $_listener_ora"
cat > "$_listener_ora" << LSNEOF
# =============================================================================
# listener.ora
# Managed by: IHateWeblogic/60-RCU-DB-19c/03a-db_setup_listener.sh
# DO NOT EDIT manually — re-run the script to regenerate.
# =============================================================================

LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${_listener_host})(PORT = ${_listener_port}))
    )
  )

# Dynamic registration — PMON registers running instances automatically.
# Static registration is not required for DBCA or standard operations.

LSNEOF

chmod 640 "$_listener_ora"
ok "listener.ora written"

# =============================================================================
# 2. sqlnet.ora
# =============================================================================

section "sqlnet.ora"

_sqlnet_ora="$_net_admin/sqlnet.ora"
backup_file "$_sqlnet_ora" "$_net_admin" 2>/dev/null || true

info "Writing: $_sqlnet_ora"
cat > "$_sqlnet_ora" << SQLEOF
# =============================================================================
# sqlnet.ora
# Managed by: IHateWeblogic/60-RCU-DB-19c/03a-db_setup_listener.sh
# =============================================================================

NAMES.DIRECTORY_PATH = (TNSNAMES, EZCONNECT)

# Reduce default connect timeout (default 60 s is too long for diagnostics)
SQLNET.OUTBOUND_CONNECT_TIMEOUT = 10

SQLEOF

chmod 640 "$_sqlnet_ora"
ok "sqlnet.ora written"

# =============================================================================
# 3. tnsnames.ora (CDB + PDB aliases)
# =============================================================================

section "tnsnames.ora"

_tnsnames_ora="$_net_admin/tnsnames.ora"
backup_file "$_tnsnames_ora" "$_net_admin" 2>/dev/null || true

info "Writing: $_tnsnames_ora"
cat > "$_tnsnames_ora" << TNSEOF
# =============================================================================
# tnsnames.ora
# Managed by: IHateWeblogic/60-RCU-DB-19c/03a-db_setup_listener.sh
# =============================================================================

# CDB (admin / SYS access)
${DB_CDB_NAME} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${_listener_host})(PORT = ${_listener_port}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${DB_CDB_NAME})
    )
  )

# PDB (FMW RCU schemas — use this for DB_SERVICE in environment.conf)
${DB_PDB_NAME} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${_listener_host})(PORT = ${_listener_port}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${DB_PDB_NAME})
    )
  )

TNSEOF

chmod 640 "$_tnsnames_ora"
ok "tnsnames.ora written"

# =============================================================================
# 4. Start Listener
# =============================================================================

section "Start Listener"

# Check if already running
if "$DB_ORACLE_HOME/bin/lsnrctl" status LISTENER >/dev/null 2>&1; then
    ok "Listener already running — reloading configuration"
    "$DB_ORACLE_HOME/bin/lsnrctl" reload LISTENER 2>&1 | tee -a "$LOG_FILE"
else
    info "Starting LISTENER ..."
    "$DB_ORACLE_HOME/bin/lsnrctl" start LISTENER 2>&1 | tee -a "$LOG_FILE"
    _lsnr_rc=${PIPESTATUS[0]}
    [ "$_lsnr_rc" -eq 0 ] \
        && ok "Listener started" \
        || { fail "lsnrctl start failed (rc=$_lsnr_rc)"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    unset _lsnr_rc
fi

# Quick status check
"$DB_ORACLE_HOME/bin/lsnrctl" status LISTENER 2>&1 \
    | grep -E "^(Alias|Version|Status|Uptime|Listener)" \
    | while IFS= read -r _line; do info "  $_line"; done

# =============================================================================
# 5. systemd oracle-listener.service
# =============================================================================
# The unit file must be installed by root.  The script writes the unit to a
# temp file and prompts for root to install + enable it.

section "systemd oracle-listener.service"

_unit_name="oracle-listener.service"
_unit_target="/etc/systemd/system/${_unit_name}"
_unit_tmp="$(mktemp /tmp/oracle-listener-XXXXXX.service)"

cat > "$_unit_tmp" << UNITEOF
# =============================================================================
# ${_unit_name}
# Managed by: IHateWeblogic/60-RCU-DB-19c/03a-db_setup_listener.sh
# Install  : cp ${_unit_tmp} ${_unit_target}
#            systemctl daemon-reload
#            systemctl enable ${_unit_name}
# =============================================================================
[Unit]
Description=Oracle TNS Listener (${_listener_host}:${_listener_port})
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=oracle
Group=oinstall
Environment=ORACLE_HOME=${DB_ORACLE_HOME}
Environment=ORACLE_BASE=${ORACLE_BASE}
ExecStart=${DB_ORACLE_HOME}/bin/lsnrctl start LISTENER
ExecStop=${DB_ORACLE_HOME}/bin/lsnrctl stop LISTENER
ExecReload=${DB_ORACLE_HOME}/bin/lsnrctl reload LISTENER
RemainAfterExit=yes
TimeoutStartSec=60
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNITEOF

info "systemd unit written to: $_unit_tmp"

printf "\n"
printf "  \033[33m┌──────────────────────────────────────────────────────────────┐\033[0m\n"
printf "  \033[33m│  Run as root NOW to install the systemd listener unit:       │\033[0m\n"
printf "  \033[33m│                                                              │\033[0m\n"
printf "  \033[33m│  cp %s %s  │\033[0m\n" "$_unit_tmp" "$_unit_target"
printf "  \033[33m│  systemctl daemon-reload                                     │\033[0m\n"
printf "  \033[33m│  systemctl enable --now oracle-listener                      │\033[0m\n"
printf "  \033[33m└──────────────────────────────────────────────────────────────┘\033[0m\n"
printf "\n"

if askYesNo "Press Enter / type 'yes' after systemd unit has been installed" "y"; then
    if systemctl is-enabled "$_unit_name" >/dev/null 2>&1; then
        ok "oracle-listener.service enabled: $(systemctl is-enabled "$_unit_name")"
    else
        warn "oracle-listener.service not yet enabled — install commands above not run?"
    fi
else
    warn "systemd unit not confirmed — listener will NOT auto-start after reboot"
    info "  Unit file kept at: $_unit_tmp"
fi

unset _unit_name _unit_target _unit_tmp

# =============================================================================

unset _listener_host _listener_port _net_admin
unset _listener_ora _sqlnet_ora _tnsnames_ora _resolved_ip

print_summary
exit $EXIT_CODE
