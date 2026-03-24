#!/bin/bash
# =============================================================================
# Script   : 08-db_auto_start.sh
# Purpose  : Register the Oracle CDB in /etc/oratab and install a systemd
#            unit (oracle-db.service) for automatic DB start at boot.
#            - Verify/add /etc/oratab entry (required by dbstart/dbshut)
#            - Write oracle-db.service unit to /tmp/, prompt root to install
#            - Depends on oracle-listener.service (listener must start first)
#            PDB auto-open is handled via SAVE STATE (done in 05-db_create_database.sh).
# Call     : ./60-RCU-DB-19c/08-db_auto_start.sh
#            ./60-RCU-DB-19c/08-db_auto_start.sh --apply
#            ./60-RCU-DB-19c/08-db_auto_start.sh --help
# Runs as  : oracle  (systemd unit install requires root — script prompts)
# Requires : environment.conf, environment_db.conf, /etc/oratab writable
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/08-db_auto_start.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
ENV_DB_CONF="$SCRIPT_DIR/environment_db.conf"

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

_usage() {
    printf "Usage: %s [--apply] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"  "Dry-run: show what would be configured"
    printf "  %-12s %s\n" "--apply" "Add oratab entry + write systemd unit + prompt root install"
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
export ORACLE_SID="${DB_SID}"

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – DB Auto-Start Setup\033[0m\n"                 | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                                 | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"                    | tee -a "$LOG_FILE"
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                        | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ -n "${DB_ORACLE_HOME:-}" ] \
    && ok "DB_ORACLE_HOME = $DB_ORACLE_HOME" \
    || { fail "DB_ORACLE_HOME not set"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "${DB_SID:-}" ] \
    && ok "DB_SID = $DB_SID" \
    || { fail "DB_SID not set"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -x "$DB_ORACLE_HOME/bin/dbstart" ] \
    && ok "dbstart found: $DB_ORACLE_HOME/bin/dbstart" \
    || { fail "dbstart not found — DB_ORACLE_HOME correct?"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# =============================================================================
# 1. /etc/oratab
# =============================================================================

section "/etc/oratab"

_oratab="/etc/oratab"
_oratab_entry="${DB_SID}:${DB_ORACLE_HOME}:Y"

if [ ! -f "$_oratab" ]; then
    warn "/etc/oratab not found — dbstart requires this file"
    warn "  Create as root: printf '%s\\n' '${_oratab_entry}' > /etc/oratab"
    info "  DBCA normally creates /etc/oratab automatically."
    EXIT_CODE=1
elif grep -q "^${DB_SID}:" "$_oratab"; then
    _existing=$(grep "^${DB_SID}:" "$_oratab")
    ok "oratab entry found: $_existing"
    # Check if auto-start flag is Y
    _flag=$(printf "%s" "$_existing" | cut -d: -f3 | tr -d ' \r')
    if [ "$_flag" != "Y" ]; then
        warn "Auto-start flag is '$_flag' (not Y) — dbstart will skip this DB"
        printf "\n"
        printf "  \033[33m┌──────────────────────────────────────────────────────────────┐\033[0m\n"
        printf "  \033[33m│  Run as root NOW to set the auto-start flag to Y:            │\033[0m\n"
        printf "  \033[33m│                                                              │\033[0m\n"
        printf "  \033[33m│  sed -i 's|^%-14s:.*|%-34s|' /etc/oratab │\033[0m\n" \
            "${DB_SID}" "${_oratab_entry}"
        printf "  \033[33m└──────────────────────────────────────────────────────────────┘\033[0m\n"
        printf "\n"
        if askYesNo "Press Enter / type 'yes' after flag has been set to Y" "y"; then
            _flag_after=$(grep "^${DB_SID}:" "$_oratab" | cut -d: -f3 | tr -d ' \r')
            if [ "$_flag_after" = "Y" ]; then
                ok "Auto-start flag now: Y"
            else
                warn "Flag is still '${_flag_after:-not found}' — systemd unit will be created but dbstart will skip the DB"
                EXIT_CODE=1
            fi
            unset _flag_after
        else
            warn "oratab not updated — dbstart will skip $DB_SID at boot"
            EXIT_CODE=1
        fi
    else
        ok "Auto-start flag: Y"
    fi
    unset _existing _flag
else
    warn "No oratab entry for $DB_SID"
    info "  Would add: $_oratab_entry"
    if $APPLY; then
        if [ -w "$_oratab" ]; then
            printf "%s\n" "$_oratab_entry" >> "$_oratab" \
                && ok "Added: $_oratab_entry" \
                || { fail "Could not write to $_oratab"; EXIT_CODE=2; }
        else
            fail "/etc/oratab is not writable by $(id -un) — run as root:"
            info "  printf '%s\\n' '${_oratab_entry}' >> /etc/oratab"
            EXIT_CODE=2
        fi
    fi
fi

printList "Expected entry" 28 "$_oratab_entry"

# =============================================================================
# Configuration Summary
# =============================================================================

section "Auto-Start Configuration"

printList "CDB SID"        28 "$DB_SID"
printList "ORACLE_HOME"    28 "$DB_ORACLE_HOME"
printList "ORACLE_BASE"    28 "${ORACLE_BASE:-}"
printList "dbstart"        28 "$DB_ORACLE_HOME/bin/dbstart"
printList "dbshut"         28 "$DB_ORACLE_HOME/bin/dbshut"
printList "Unit name"      28 "oracle-db.service"
printList "Depends on"     28 "oracle-listener.service"
printList "TimeoutStart"   28 "180 s"
printList "TimeoutStop"    28 "120 s"

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to write the systemd unit."
    print_summary; exit $EXIT_CODE
fi

# =============================================================================
# 2. systemd oracle-db.service
# =============================================================================
# The unit file must be installed by root.  The script writes the unit to a
# temp file and prompts for root to install + enable it.

section "systemd oracle-db.service"

_unit_name="oracle-db.service"
_unit_target="/etc/systemd/system/${_unit_name}"
_unit_tmp="$(mktemp /tmp/oracle-db-XXXXXX.service)"

cat > "$_unit_tmp" << UNITEOF
# =============================================================================
# ${_unit_name}
# Managed by: IHateWeblogic/60-RCU-DB-19c/08-db_auto_start.sh
# Install  : cp ${_unit_tmp} ${_unit_target}
#            systemctl daemon-reload
#            systemctl enable ${_unit_name}
# =============================================================================
[Unit]
Description=Oracle Database CDB (${DB_SID})
After=network-online.target oracle-listener.service
Wants=network-online.target
Requires=oracle-listener.service

[Service]
Type=forking
User=oracle
Group=oinstall
Environment=ORACLE_HOME=${DB_ORACLE_HOME}
Environment=ORACLE_BASE=${ORACLE_BASE}
Environment=ORACLE_SID=${DB_SID}
# dbstart/dbshut read /etc/oratab — entry must exist with :Y flag
ExecStart=${DB_ORACLE_HOME}/bin/dbstart  ${DB_ORACLE_HOME}
ExecStop=${DB_ORACLE_HOME}/bin/dbshut   ${DB_ORACLE_HOME}
RemainAfterExit=yes
TimeoutStartSec=180
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
UNITEOF

info "systemd unit written to: $_unit_tmp"

printf "\n"
printf "  \033[33m┌──────────────────────────────────────────────────────────────┐\033[0m\n"
printf "  \033[33m│  Run as root NOW to install the systemd DB unit:             │\033[0m\n"
printf "  \033[33m│                                                              │\033[0m\n"
printf "  \033[33m│  cp %-57s│\033[0m\n" "$_unit_tmp \\"
printf "  \033[33m│     %-57s│\033[0m\n" "$_unit_target"
printf "  \033[33m│  systemctl daemon-reload                                     │\033[0m\n"
printf "  \033[33m│  systemctl enable --now oracle-db                            │\033[0m\n"
printf "  \033[33m└──────────────────────────────────────────────────────────────┘\033[0m\n"
printf "\n"

if askYesNo "Press Enter / type 'yes' after systemd unit has been installed" "y"; then
    if systemctl is-enabled "$_unit_name" >/dev/null 2>&1; then
        ok "oracle-db.service enabled: $(systemctl is-enabled "$_unit_name")"
    else
        warn "oracle-db.service not yet enabled — install commands above not run?"
        EXIT_CODE=1
    fi
else
    warn "systemd unit not confirmed — DB will NOT auto-start after reboot"
    info "  Unit file kept at: $_unit_tmp"
    EXIT_CODE=1
fi

unset _unit_name _unit_target _unit_tmp _oratab _oratab_entry

# =============================================================================
print_summary
exit $EXIT_CODE
