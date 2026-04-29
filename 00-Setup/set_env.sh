#!/bin/bash
# =============================================================================
# Script   : set_env.sh
# Purpose  : Select the active environment.conf when multiple Oracle homes exist:
#              - FMW / WebLogic domains (ORACLE_HOME + DOMAIN_HOME + JDK_HOME)
#              - Oracle Database homes  (ORACLE_HOME + ORACLE_SID)
#            Shows a numbered menu of all *.conf files in 00-Setup/environments/,
#            updates the environment.conf symlink in the project root, and –
#            when sourced – activates the selected environment in the current shell.
#
# IMPORTANT: Source this script to set environment variables in your shell:
#              . ./00-Setup/set_env.sh        # interactive menu
#              . ./00-Setup/set_env.sh 1      # direct select #1, no menu
#
#            Running directly (./set_env.sh) only updates the symlink;
#            environment variables are NOT set in the calling shell.
#
# Conf file format (00-Setup/environments/*.conf):
#   Standard environment.conf variables, plus two optional header comments:
#     # ENV_TYPE=FMW          FMW/WebLogic domain  (default when DOMAIN_HOME set)
#     # ENV_TYPE=DB           Oracle Database home  (default when ORACLE_SID set)
#     # ENV_LABEL=Production  Human-readable name for the menu
#
# Call     : . ./00-Setup/set_env.sh [number]
#            ./00-Setup/set_env.sh --list
#            ./00-Setup/set_env.sh --help
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

# =============================================================================
# Bootstrap – locate root, source lib
# (Must run before environment.conf exists, so we locate paths manually)
# =============================================================================

_SE_SCRIPT="${BASH_SOURCE[0]}"
_SE_DIR="$(cd "$(dirname "$_SE_SCRIPT")" && pwd)"
_SE_ROOT="$(cd "$_SE_DIR/.." && pwd)"
_SE_CONF_DIR="$_SE_DIR/environments"
_SE_LINK="$_SE_ROOT/environment.conf"

# Are we sourced or executed directly?
_SE_SOURCED=false
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && _SE_SOURCED=true

# Source the central library (color helpers, ok/warn/fail, printLine, printError ...)
_SE_LIB="$_SE_DIR/IHateWeblogic_lib.sh"
if [ ! -f "$_SE_LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$_SE_LIB" >&2
    if $_SE_SOURCED; then return 2; else exit 2; fi
fi
# shellcheck source=IHateWeblogic_lib.sh
source "$_SE_LIB"

# Exit helper – return when sourced, exit when executed
_se_exit() {
    local _rc="${1:-0}"
    # Capture _SE_SOURCED BEFORE unset – otherwise $var expands to empty
    # string, the if-condition becomes a no-op (exit 0 = true), and return
    # is called instead of exit, letting the script continue unintentionally.
    local _sourced="$_SE_SOURCED"
    # Clean up set_env-specific helpers and variables
    unset _SE_SCRIPT _SE_DIR _SE_ROOT _SE_CONF_DIR _SE_LINK _SE_SOURCED _SE_LIB
    unset _SE_FILES _SE_LABELS _SE_TYPES _SE_SIDS _SE_DOMAINS _SE_ORACLES _SE_NLS
    unset _SE_PRE_SELECT _LIST_ONLY
    unset -f _se_read_conf _se_apply_fmw _se_apply_db _se_exit
    # "$_sourced" expands to the command "true" or "false" – always valid
    if "$_sourced"; then return "$_rc"; else exit "$_rc"; fi
}

# =============================================================================
# Parse arguments
# =============================================================================

_SE_PRE_SELECT=""
_LIST_ONLY=false

case "${1:-}" in
    --help|-h)
        printf "Usage:\n"
        printf "  . ./00-Setup/set_env.sh          # interactive menu, sets shell env\n"
        printf "  . ./00-Setup/set_env.sh 1        # direct select #1, no menu\n"
        printf "  ./00-Setup/set_env.sh --list     # list environments (no env change)\n"
        printf "\nEnvironment files: %s/*.conf\n" "$_SE_CONF_DIR"
        printf "\nConf file header comments:\n"
        printf "  # ENV_TYPE=FMW    # or DB\n"
        printf "  # ENV_LABEL=Production FR Domain\n"
        _se_exit 0 ;;
    --list)
        _LIST_ONLY=true ;;
    ''|--*)
        : ;;
    *)
        if [[ "${1}" =~ ^[0-9]+$ ]]; then
            _SE_PRE_SELECT="${1}"
        else
            printError "Unknown argument: ${1}"
            _se_exit 1
        fi ;;
esac

# =============================================================================
# Discover environment files
# =============================================================================

if [ ! -d "$_SE_CONF_DIR" ]; then
    printError "environments directory not found: $_SE_CONF_DIR"
    printf "  mkdir -p %s\n" "$_SE_CONF_DIR" >&2
    _se_exit 1
fi

# Arrays: parallel indexed lists
_SE_FILES=()
_SE_LABELS=()
_SE_TYPES=()     # FMW | DB | UNKNOWN
_SE_SIDS=()      # ORACLE_SID  (DB)
_SE_DOMAINS=()   # DOMAIN_HOME (FMW)
_SE_ORACLES=()   # ORACLE_HOME (both)
_SE_NLS=()       # NLS_LANG    (DB)

# _se_read_conf  <file>  <var_name>
# Reads a shell variable assignment from a conf file (handles = with or without quotes)
_se_read_conf() {
    local _file="$1" _var="$2"
    grep -m1 "^${_var}=" "$_file" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"
}

while IFS= read -r _f; do
    _SE_FILES+=("$_f")

    # ENV_LABEL from comment line
    _lbl="$(grep -m1 '^#[[:space:]]*ENV_LABEL=' "$_f" 2>/dev/null \
            | sed 's/^#[[:space:]]*ENV_LABEL=//')"
    [ -z "$_lbl" ] && _lbl="$(basename "$_f" .conf)"
    _SE_LABELS+=("$_lbl")

    # ENV_TYPE – explicit comment or auto-detect from keys present
    _typ="$(grep -m1 '^#[[:space:]]*ENV_TYPE=' "$_f" 2>/dev/null \
            | sed 's/^#[[:space:]]*ENV_TYPE=//' | tr '[:lower:]' '[:upper:]')"
    if [ -z "$_typ" ]; then
        if   [ -n "$(_se_read_conf "$_f" DOMAIN_HOME)" ]; then _typ="FMW"
        elif [ -n "$(_se_read_conf "$_f" ORACLE_SID)"  ]; then _typ="DB"
        else                                                     _typ="UNKNOWN"
        fi
    fi
    _SE_TYPES+=("$_typ")

    _SE_ORACLES+=("$(_se_read_conf "$_f" ORACLE_HOME)")
    _SE_DOMAINS+=("$(_se_read_conf "$_f" DOMAIN_HOME)")
    _SE_SIDS+=("$(_se_read_conf    "$_f" ORACLE_SID)")
    _SE_NLS+=("$(_se_read_conf     "$_f" NLS_LANG)")
done < <(find "$_SE_CONF_DIR" -maxdepth 1 -name "*.conf" 2>/dev/null | sort)

unset _f _lbl _typ

if [ "${#_SE_FILES[@]}" -eq 0 ]; then
    printError "No *.conf files found in $_SE_CONF_DIR"
    printf "  Copy your environment.conf there and add the header comment:\n" >&2
    printf "    cp environment.conf %s/prod.conf\n" "$_SE_CONF_DIR" >&2
    printf "    # ENV_TYPE=FMW\n" >&2
    _se_exit 1
fi

# =============================================================================
# Display menu
# =============================================================================

printf "\n"
_color_bold "  IHateWeblogic – Environment Selection"; printf "\n"
printf "  Host : %s\n" "$(_get_hostname)"

# Show current active symlink
if [ -L "$_SE_LINK" ]; then
    _act="$(readlink "$_SE_LINK")"
    printf "  Active : "; _color_green "$(basename "$_act" .conf)"; printf "  (%s)\n" "$_act"
elif [ -f "$_SE_LINK" ]; then
    printf "  Active : %s (regular file – not a symlink)\n" "$_SE_LINK"
else
    printf "  Active : "; _color_yellow "(none – no environment.conf symlink)"; printf "\n"
fi
unset _act
printf "\n"

printLine

_count="${#_SE_FILES[@]}"
for (( _i=0; _i<_count; _i++ )); do
    _nr=$(( _i + 1 ))
    _file="${_SE_FILES[$_i]}"
    _label="${_SE_LABELS[$_i]}"
    _type="${_SE_TYPES[$_i]}"
    _oh="${_SE_ORACLES[$_i]}"
    _dh="${_SE_DOMAINS[$_i]}"
    _sid="${_SE_SIDS[$_i]}"
    _nls="${_SE_NLS[$_i]}"

    # Active marker
    _mark="  "
    if [ -L "$_SE_LINK" ] && [ "$(readlink "$_SE_LINK")" = "$_file" ]; then
        _mark="* "
    fi

    printf "%s" "$_mark"
    _color_yellow "[$_nr]"; printf "  "
    _color_bold "$_label"; printf "  "

    case "$_type" in
        FMW)     _color_cyan "[FMW/WebLogic]" ;;
        DB)      _color_green "[Database]" ;;
        UNKNOWN) _color_yellow "[?]" ;;
    esac
    printf "\n"

    printf "       ORACLE_HOME  : %s\n" "${_oh:-(not set)}"

    case "$_type" in
        FMW) printf "       DOMAIN_HOME  : %s\n" "${_dh:-(not set)}" ;;
        DB)
            printf "       ORACLE_SID   : %s\n" "${_sid:-(not set)}"
            [ -n "$_nls" ] && printf "       NLS_LANG     : %s\n" "$_nls"
            ;;
    esac

    printf "       File         : %s\n" "$(basename "$_file")"
    printLine
done
unset _i _nr _file _label _type _oh _dh _sid _nls _mark

printf "\n"

if $_LIST_ONLY; then
    _se_exit 0
fi

# =============================================================================
# Selection
# =============================================================================

_sel_idx=""

if [ -n "$_SE_PRE_SELECT" ]; then
    if [ "$_SE_PRE_SELECT" -ge 1 ] && [ "$_SE_PRE_SELECT" -le "$_count" ]; then
        _sel_idx=$(( _SE_PRE_SELECT - 1 ))
    else
        printError "Selection '$_SE_PRE_SELECT' out of range (1-$_count)"
        _se_exit 1
    fi
elif [ "$_count" -eq 1 ]; then
    info "Only one environment available – auto-selecting."
    _sel_idx=0
else
    while true; do
        printf "  Select environment [1-%d]: " "$_count"
        read -r _answer </dev/tty
        if [[ "$_answer" =~ ^[0-9]+$ ]] && \
           [ "$_answer" -ge 1 ] && [ "$_answer" -le "$_count" ]; then
            _sel_idx=$(( _answer - 1 ))
            break
        fi
        printf "  "; _color_red "Invalid input"; printf " – enter a number between 1 and %d\n" "$_count"
    done
    unset _answer
fi

_sel_file="${_SE_FILES[$_sel_idx]}"
_sel_label="${_SE_LABELS[$_sel_idx]}"
_sel_type="${_SE_TYPES[$_sel_idx]}"

# =============================================================================
# Update symlink
# =============================================================================

printf "\n"
printLine

if ln -sfn "$_sel_file" "$_SE_LINK" 2>/dev/null; then
    ok "Symlink: $_SE_LINK"
    info "      -> $_sel_file"
else
    fail "Cannot update symlink: $_SE_LINK"
    printf "  Check write permissions on: %s\n" "$_SE_ROOT" >&2
    _se_exit 1
fi

# =============================================================================
# Apply – source conf + set PATH  (only when script is sourced)
# =============================================================================

# _se_apply_fmw – activate FMW/WebLogic environment
_se_apply_fmw() {
    # shellcheck source=/dev/null
    source "$_sel_file"
    export ORACLE_HOME DOMAIN_HOME JDK_HOME
    export PATH="$ORACLE_HOME/bin:$ORACLE_HOME/oracle_common/common/bin:$JDK_HOME/bin:$PATH"
    ok "FMW environment active: $_sel_label"
    info "     ORACLE_HOME  = ${ORACLE_HOME:-(not set)}"
    info "     DOMAIN_HOME  = ${DOMAIN_HOME:-(not set)}"
    info "     JDK_HOME     = ${JDK_HOME:-(not set)}"
}

# _se_apply_db – activate Oracle Database environment
_se_apply_db() {
    # shellcheck source=/dev/null
    source "$_sel_file"
    export ORACLE_HOME ORACLE_SID ORACLE_BASE NLS_LANG
    export PATH="$ORACLE_HOME/bin:$PATH"
    ok "DB environment active: $_sel_label"
    info "     ORACLE_HOME  = ${ORACLE_HOME:-(not set)}"
    info "     ORACLE_SID   = ${ORACLE_SID:-(not set)}"
    info "     ORACLE_BASE  = ${ORACLE_BASE:-(not set)}"
    info "     NLS_LANG     = ${NLS_LANG:-(not set)}"
}

if $_SE_SOURCED; then
    case "$_sel_type" in
        FMW) _se_apply_fmw ;;
        DB)  _se_apply_db  ;;
        *)
            # shellcheck source=/dev/null
            source "$_sel_file"
            export ORACLE_HOME
            [ -n "${DOMAIN_HOME:-}" ] && export DOMAIN_HOME
            [ -n "${ORACLE_SID:-}"  ] && export ORACLE_SID
            [ -n "${JDK_HOME:-}"    ] && export JDK_HOME
            export PATH="$ORACLE_HOME/bin:$PATH"
            warn "ENV_TYPE unknown – sourced conf, exported ORACLE_HOME"
            ;;
    esac
else
    printf "\n"
    _color_yellow "WARNING"; printf ": Script was executed directly – environment variables were NOT exported to your shell.\n"
    printf "\n"
    printf "  The following variables are NOT set in your current session:\n"
    case "$_sel_type" in
        FMW)
            printf "    ORACLE_HOME  DOMAIN_HOME  JDK_HOME  PATH\n" ;;
        DB)
            printf "    ORACLE_HOME  ORACLE_SID  ORACLE_BASE  NLS_LANG  PATH\n" ;;
        *)
            printf "    ORACLE_HOME  PATH\n" ;;
    esac
    printf "\n"
    printf "  Commands like \$DOMAIN_HOME/bin/startWebLogic.sh will fail with\n"
    printf "  'No such file or directory' because the variable is empty.\n"
    printf "\n"
    printf "  \033[1mSource the script instead:\033[0m\n"
    printf "    \033[1m. %s/%s\033[0m\n" \
        "$(realpath --relative-to="$PWD" "$_SE_DIR" 2>/dev/null || printf "00-Setup")" \
        "$(basename "$_SE_SCRIPT")"
    printf "\n"
    printf "  Note the leading dot (.) – it sources the script in the current shell.\n"
fi

printLine
printf "\n"

_se_exit 0
