#!/bin/bash
# =============================================================================
# Script   : 01-db_install_software.sh
# Purpose  : Download patches via AutoUpgrade and install Oracle 19c directly
#            to the patched ORACLE_HOME using runInstaller -applyRU.
#            AutoUpgrade is used for MOS-authenticated patch download ONLY —
#            no create_home, no cp-a, no separate base home, no relink hacks.
#
#            Flow:
#              1. Extract 19.3.0 base ZIP to a staging directory (base_stage)
#              2. Download RU + OJVM + DPBP + OPatch + DB home JDK from MOS via
#                 AutoUpgrade (refreshed to the newest autoupgrade.jar first;
#                 skipped if patchdir already contains ZIPs)
#              3. Update OPatch in staging + identify RU / OneOff patch dirs
#              4. runInstaller -applyRU <RU> [-applyOneOffs <OJVM>,<DPBP>,<JDK>] -silent
#                 → installs directly to DB_ORACLE_HOME (19.30.0 target)
#              5. root.sh prompt + chopt disable olap/rat
#
#            uniaud_on relink is NOT done here — it runs in 05-db_create_database.sh
#            before DBCA (requires the complete DB home).
#
# Call     : ./60-RCU-DB-19c/01-db_install_software.sh
#            ./60-RCU-DB-19c/01-db_install_software.sh --apply
#            ./60-RCU-DB-19c/01-db_install_software.sh --target-home <dir> --fresh-patches --apply
#              (additional patched home for an existing DB -> 09-db_patch_rcu.sh)
#            ./60-RCU-DB-19c/01-db_install_software.sh --clean [--apply]
#            ./60-RCU-DB-19c/01-db_install_software.sh --help
# Runs as  : oracle
# Requires : environment.conf, environment_db.conf
#            DB_INSTALL_ARCHIVE  – 19.3.0 base ZIP (manual download from eDelivery)
#            mos_sec.conf.des3   – MOS credentials (only if patch download needed)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/01-db_install_software.md
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
CLEAN=false
TARGET_HOME_ARG=""
FRESH_PATCHES=false

_usage() {
    printf "Usage: %s [--apply] [--clean [--apply]] [--help]\n\n" "$(basename "$0")"
    printf "  %-20s %s\n" "(none)"          "Dry-run: show configuration, no install"
    printf "  %-20s %s\n" "--apply"         "Extract base + download patches + install via -applyRU"
    printf "  %-20s %s\n" "--clean"         "Dry-run: show what --clean --apply would remove"
    printf "  %-20s %s\n" "--clean --apply" "Remove DB_ORACLE_HOME + base_stage, then install"
    printf "  %-20s %s\n" "--target-home DIR" "Install into DIR instead of DB_ORACLE_HOME (new home for 09-db_patch_rcu.sh)"
    printf "  %-20s %s\n" "--fresh-patches" "Move patchdir ZIPs to patchdir_<timestamp> first -> download the current set"
    printf "  %-20s %s\n" "--help"          "Show this help"
    printf "\nRuns as: oracle\n"
    printf "Patch ZIPs in patchdir/ are NOT removed by --clean (reused on re-runs).\n"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)         APPLY=true ;;
        --clean)         CLEAN=true ;;
        --target-home)   shift; TARGET_HOME_ARG="${1:?--target-home needs a directory}" ;;
        --fresh-patches) FRESH_PATCHES=true ;;
        --help|-h)       _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done

# --target-home: build an ADDITIONAL home (out-of-place patching, 09-db_patch_rcu.sh)
# - everything below installs into DB_ORACLE_HOME, so it is redirected here;
# the running home stays in DB_ORACLE_HOME_CURRENT (environment_db.conf is not changed)
DB_ORACLE_HOME_CURRENT="$DB_ORACLE_HOME"
if [ -n "$TARGET_HOME_ARG" ]; then
    case "$TARGET_HOME_ARG" in /*) ;; *) printf "\033[31mERROR\033[0m --target-home must be absolute\n" >&2; exit 1 ;; esac
    [ "$TARGET_HOME_ARG" = "$DB_ORACLE_HOME_CURRENT" ] && {
        printf "\033[31mERROR\033[0m --target-home is the running home (%s)\n" "$DB_ORACLE_HOME_CURRENT" >&2; exit 1; }
    DB_ORACLE_HOME="$TARGET_HOME_ARG"
fi

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – DB Software Install + Patch (19c)\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                               | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"                  | tee -a "$LOG_FILE"
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                      | tee -a "$LOG_FILE"
printLine

# --- Disk space (first: before any download / unzip) -------------------------
# home: patched 19c home ~8 GB incl. RU / OJVM / JDK; staging (AutoUpgrade home):
# base_stage ~6.5 GB unpacked + patch ZIPs ~3 GB + patch_stage unpacked ~4 GB
_fs_free_gb() {   # free GB of the file system that will hold $1
    local d="$1"; while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
    df -Pk "$d" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1048576 }'
}
_fs_dev() { local d="$1"; while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
    df -P "$d" 2>/dev/null | awk 'NR==2 { print $1 }'; }
# (19.33 gold image unpacked + OneOffs = 11 GB, live 2026-10-28)
_home_min="${DB_HOME_MIN_FREE_GB:-12}";  _home_rec="${DB_HOME_REC_FREE_GB:-15}"
_stage_min="${DB_STAGE_MIN_FREE_GB:-8}"; _stage_rec="${DB_STAGE_REC_FREE_GB:-14}"
[ -f "$DB_AUTOUPGRADE_HOME/base_stage/runInstaller" ] && { _stage_min=$(( _stage_min - 6 )); _stage_rec=$(( _stage_rec - 6 )); }
[ "$_stage_min" -lt 2 ] && _stage_min=2; [ "$_stage_rec" -lt 4 ] && _stage_rec=4
_disk_fail=false
_disk_row() {   # label dir min rec
    local free; free="$(_fs_free_gb "$2")"
    local msg; msg="$(printf "  %-22s %4s GB free  (min %s, recommended %s GB)  %s" "$1" "${free:-?}" "$3" "$4" "$2")"
    if [ "${free:-0}" -lt "$3" ]; then fail "$msg"; _disk_fail=true
    elif [ "${free:-0}" -lt "$4" ]; then warn "$msg"
    else ok "$msg"; fi
}
section "Disk space"
if [ -z "${DB_ORACLE_HOME:-}" ] || [ -z "${DB_AUTOUPGRADE_HOME:-}" ]; then
    fail "DB_ORACLE_HOME / DB_AUTOUPGRADE_HOME not set in environment_db.conf"; print_summary; exit 2
fi
if [ "$(_fs_dev "$DB_ORACLE_HOME")" = "$(_fs_dev "$DB_AUTOUPGRADE_HOME")" ]; then
    _disk_row "home + staging (same fs)" "$DB_ORACLE_HOME" $(( _home_min + _stage_min )) $(( _home_rec + _stage_rec ))
else
    _disk_row "new home" "$DB_ORACLE_HOME" "$_home_min" "$_home_rec"
    _disk_row "staging (AutoUpgrade)" "$DB_AUTOUPGRADE_HOME" "$_stage_min" "$_stage_rec"
fi
if $_disk_fail && $APPLY; then
    fail "Not enough disk space – free space first (or move DB_AUTOUPGRADE_HOME)"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
unset _home_min _home_rec _stage_min _stage_rec _disk_fail

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ -n "${ORACLE_BASE:-}" ] \
    && ok "ORACLE_BASE = $ORACLE_BASE" \
    || { fail "ORACLE_BASE not set"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "${DB_ORACLE_HOME:-}" ] \
    && ok "DB_ORACLE_HOME = $DB_ORACLE_HOME" \
    || { fail "DB_ORACLE_HOME not set in environment_db.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "${DB_INSTALL_ARCHIVE:-}" ] \
    && ok "DB_INSTALL_ARCHIVE = $DB_INSTALL_ARCHIVE" \
    || { fail "DB_INSTALL_ARCHIVE not set in environment_db.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -f "$DB_INSTALL_ARCHIVE" ] \
    && ok "Install archive found: $DB_INSTALL_ARCHIVE  ($(du -sh "$DB_INSTALL_ARCHIVE" 2>/dev/null | cut -f1))" \
    || { fail "Install archive not found: $DB_INSTALL_ARCHIVE"
         info "  Manual download from eDelivery (V982063-01 / LINUX.X64_193000_db_home.zip)"
         info "  Place at: \${PATCH_STORAGE}/database/LINUX.X64_193000_db_home.zip"
         EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "${DB_AUTOUPGRADE_HOME:-}" ] \
    && ok "DB_AUTOUPGRADE_HOME = $DB_AUTOUPGRADE_HOME" \
    || { fail "DB_AUTOUPGRADE_HOME not set in environment_db.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- Already installed? -------------------------------------------------------
# Reliable indicator: Inventory XML entry for DB_ORACLE_HOME
# /etc/oraInst.loc is the canonical location (created by 00-root_db_os_baseline.sh)
_inv_xml="$(grep "^inventory_loc=" /etc/oraInst.loc 2>/dev/null | cut -d= -f2)/ContentsXML/inventory.xml"

if [ -f "$_inv_xml" ] && grep -q "LOC=\"$DB_ORACLE_HOME\"" "$_inv_xml" 2>/dev/null; then
    ok "DB home already registered in Oracle Inventory — installation complete"
    section "Verification"
    ORACLE_HOME="$DB_ORACLE_HOME" "$DB_ORACLE_HOME/OPatch/opatch" lspatches 2>/dev/null \
        | head -10 | while IFS= read -r _line; do info "  $_line"; done
    print_summary; exit $EXIT_CODE
fi
unset _inv_xml

# =============================================================================
# Configuration Summary
# =============================================================================

section "Install Configuration"

_AU_PATCHDIR="$DB_AUTOUPGRADE_HOME/patchdir"
_AU_BASE_STAGE="$DB_AUTOUPGRADE_HOME/base_stage"
_AU_PATCH_STAGE="$DB_AUTOUPGRADE_HOME/patch_stage"
_AU_JAR="$DB_AUTOUPGRADE_HOME/bin/autoupgrade.jar"
_AU_CONFIG="$DB_AUTOUPGRADE_HOME/config/db19patch.cfg"
_AU_KEYSTORE_CFG="$DB_AUTOUPGRADE_HOME/config/keystore.cfg"

printList "ORACLE_BASE"         28 "$ORACLE_BASE"
printList "DB_ORACLE_HOME"      28 "$DB_ORACLE_HOME$([ -n "$TARGET_HOME_ARG" ] && printf '  (--target-home; running home: %s)' "$DB_ORACLE_HOME_CURRENT")"
printList "Edition"             28 "${DB_EDITION:-EE}  (EE=Enterprise / SE2=Standard)"
printList "Install archive"     28 "$DB_INSTALL_ARCHIVE"
printList "AutoUpgrade home"    28 "$DB_AUTOUPGRADE_HOME"
printList "Base staging dir"    28 "$_AU_BASE_STAGE"
printList "Patch dir"           28 "$_AU_PATCHDIR"
printList "Target RU"           28 "${DB_TARGET_RU:-RECOMMENDED}"

# Check patchdir state for dry-run info
_patch_zip_count=$(ls "$_AU_PATCHDIR"/p[0-9]*.zip 2>/dev/null | grep -v 'p6880880' | wc -l)
if [ "$_patch_zip_count" -gt 0 ] && $FRESH_PATCHES; then
    info "$(printf "Patchdir: %d patch ZIP(s) – --fresh-patches moves them to patchdir_<timestamp>, then fresh download" "$_patch_zip_count")"
elif [ "$_patch_zip_count" -gt 0 ]; then
    ok "$(printf "Patchdir: %d patch ZIP(s) present — download will be skipped" "$_patch_zip_count")"
else
    info "Patchdir: empty — AutoUpgrade will download patches (requires MOS credentials)"
fi
unset _patch_zip_count

if ! $APPLY && ! $CLEAN; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to install."
    print_summary; exit $EXIT_CODE
fi

# =============================================================================
# --clean: Remove DB_ORACLE_HOME + base_stage
# =============================================================================

if $CLEAN; then
    section "Clean – Remove Target Home and Staging"

    if ! $APPLY; then
        info "Dry-run: the following would be removed (use --clean --apply to execute):"
        printf "\n" | tee -a "$LOG_FILE"
        [ -d "$DB_ORACLE_HOME" ] \
            && warn "  1. Detach from Oracle Inventory + rm -rf $DB_ORACLE_HOME" \
            || info "  1. DB_ORACLE_HOME already absent: $DB_ORACLE_HOME"
        [ -d "$_AU_BASE_STAGE" ] \
            && warn "  2. rm -rf $_AU_BASE_STAGE  (re-extracted on next run)" \
            || info "  2. base_stage already absent: $_AU_BASE_STAGE"
        info "  Preserved: $_AU_PATCHDIR  (patch ZIPs — reused on next run)"
        printf "\n" | tee -a "$LOG_FILE"
        warn "Run --clean --apply to execute"
        print_summary; exit $EXIT_CODE
    fi

    # 1. Detach DB_ORACLE_HOME from Oracle Inventory
    _inv_xml_cl="$(grep "^inventory_loc=" /etc/oraInst.loc 2>/dev/null | cut -d= -f2)/ContentsXML/inventory.xml"

    if [ -d "$DB_ORACLE_HOME" ]; then
        if [ -f "$_inv_xml_cl" ] && grep -q "LOC=\"$DB_ORACLE_HOME\"" "$_inv_xml_cl" 2>/dev/null; then
            info "Detaching home from Oracle Inventory ..."
            if [ -x "$DB_ORACLE_HOME/oui/bin/runInstaller" ]; then
                "$DB_ORACLE_HOME/oui/bin/runInstaller" \
                    -silent -detachHome \
                    "ORACLE_HOME=$DB_ORACLE_HOME" \
                    2>&1 | tee -a "$LOG_FILE" || true
                ok "detachHome completed"
            else
                warn "OUI runInstaller not found in target home — skipping detachHome"
            fi
        else
            info "Home not registered in inventory — no detach needed"
        fi
        rm -rf "$DB_ORACLE_HOME"
        ok "Removed: $DB_ORACLE_HOME"
    else
        ok "DB_ORACLE_HOME already absent: $DB_ORACLE_HOME"
    fi
    unset _inv_xml_cl

    # 2. Remove base_stage (force re-extraction of base ZIP)
    if [ -d "$_AU_BASE_STAGE" ]; then
        rm -rf "$_AU_BASE_STAGE"
        ok "Removed: $_AU_BASE_STAGE"
    else
        ok "base_stage already absent: $_AU_BASE_STAGE"
    fi

    ok "Clean completed — continuing with install"
    printf "\n" | tee -a "$LOG_FILE"
fi

# =============================================================================
# 1. Setup directories
# =============================================================================

section "AutoUpgrade Directories"

for _dir in \
    "$DB_AUTOUPGRADE_HOME/bin" \
    "$DB_AUTOUPGRADE_HOME/logs" \
    "$DB_AUTOUPGRADE_HOME/config" \
    "$_AU_PATCHDIR" \
    "$DB_AUTOUPGRADE_HOME/keystore" \
    "$_AU_BASE_STAGE" \
    "$_AU_PATCH_STAGE"; do
    mkdir -p "$_dir"
    ok "$(printf "  %-55s" "$_dir")"
done
unset _dir

# =============================================================================
# 2. Extract 19.3.0 base ZIP to staging
# =============================================================================

section "Extract 19.3.0 Base ZIP → Staging"

# A gold image in patchdir (downloaded before) is a complete home - the 19.3
# base stage (~6.6 GB) is not needed then
_GOLD_PRESENT="$(ls -1 "$_AU_PATCHDIR"/db_goldimage_*.zip 2>/dev/null | head -1)"
if [ -n "$_GOLD_PRESENT" ] && ! $FRESH_PATCHES; then
    ok "Gold image present ($(basename "$_GOLD_PRESENT")) – base ZIP not needed, skipping unzip"
elif [ -f "$_AU_BASE_STAGE/runInstaller" ]; then
    ok "Base already extracted (runInstaller found) — skipping unzip"
else
    info "Extracting: $(basename "$DB_INSTALL_ARCHIVE") ..."
    printf "  Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
    unzip -q -o "$DB_INSTALL_ARCHIVE" -d "$_AU_BASE_STAGE" 2>&1 | tee -a "$LOG_FILE"
    _unzip_rc=$?
    printf "  Finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_unzip_rc" | tee -a "$LOG_FILE"
    [ "$_unzip_rc" -eq 0 ] \
        && ok "Archive extracted to: $_AU_BASE_STAGE" \
        || { fail "Unzip failed (rc=$_unzip_rc)"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    unset _unzip_rc
fi
unset _GOLD_PRESENT

# =============================================================================
# 3. Java detection (AutoUpgrade requires Java 11; DB bundled JDK used first)
# =============================================================================

section "Java for AutoUpgrade"

# AutoUpgrade 26.x requires Java 11 — rejects Java 21.
# Try 19.3.0 staging JDK first, then system java-11-openjdk, then /usr/bin/java.
JAVA_BIN=""
for _jbin in \
    "$_AU_BASE_STAGE/jdk/bin/java" \
    $(ls /usr/lib/jvm/java-11-openjdk*/bin/java 2>/dev/null | head -1) \
    "/usr/bin/java"; do
    [ -n "$_jbin" ] && [ -x "$_jbin" ] && { JAVA_BIN="$_jbin"; break; }
done
unset _jbin

# no base stage (gold image case): the JDK of the running DB home works too
[ -z "$JAVA_BIN" ] && [ -x "${DB_ORACLE_HOME_CURRENT}/jdk/bin/java" ] && JAVA_BIN="${DB_ORACLE_HOME_CURRENT}/jdk/bin/java"
if [ -n "$JAVA_BIN" ]; then
    ok "Java found: $JAVA_BIN ($("$JAVA_BIN" -version 2>&1 | head -1))"
else
    fail "No Java found — install java-11-openjdk (run 00-root_db_os_baseline.sh --apply)"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# TLS version: Java 8 does not support TLSv1.3 as JVM property
if "$JAVA_BIN" -version 2>&1 | grep -q '"1\.8\.'; then
    AU_TLS="-Dhttps.protocols=TLSv1.2"
    ok "TLS mode: TLSv1.2  (Java 8 — TLSv1.3 not supported as JVM property)"
else
    AU_TLS="-Dhttps.protocols=TLSv1.3"
    ok "TLS mode: TLSv1.3"
fi

# =============================================================================
# 4. Check patchdir / Download patches
# =============================================================================

section "Patch Download (AutoUpgrade)"

# --fresh-patches: keep the previous patch set (rebuild of the old home), download anew
# (only the patch ZIPs p<nr>_*.zip - the 19.3 base ZIP may live in patchdir too)
if $FRESH_PATCHES && ls "$_AU_PATCHDIR"/p[0-9]*.zip >/dev/null 2>&1; then
    _arch="${_AU_PATCHDIR}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$_arch" && mv "$_AU_PATCHDIR"/p[0-9]*.zip "$_arch"/ \
        && { [ -f "$_AU_PATCHDIR/patches_info.json" ] && mv "$_AU_PATCHDIR/patches_info.json" "$_arch"/; true; } \
        && ok "Previous patch set moved to: $_arch" \
        || { fail "Could not move the patch ZIPs to $_arch"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    unset _arch
fi

# Count non-OPatch patch ZIPs already in patchdir
_existing_zips=$(ls "$_AU_PATCHDIR"/p[0-9]*.zip 2>/dev/null | grep -v 'p6880880' | wc -l)

if [ "$_existing_zips" -gt 0 ]; then
    ok "$(printf "Patchdir has %d patch ZIP(s) — skipping download" "$_existing_zips")"
    info "  Delete $_AU_PATCHDIR/*.zip to force re-download"
    ls "$_AU_PATCHDIR"/*.zip 2>/dev/null | while IFS= read -r _z; do
        info "  $(basename "$_z")  ($(du -sh "$_z" 2>/dev/null | cut -f1))"
    done
else
    # --- 4a. Download autoupgrade.jar -----------------------------------------
    AU_DOWNLOAD_URL="https://download.oracle.com/otn-pub/otn_software/autoupgrade.jar"

    # Always the newest AutoUpgrade: the patch keywords change between releases
    # (26.2 of Feb 2026 had no "jdk" in RECOMMENDED; 26.6 loads the JDK bundle
    # patch with "jdk" - tested 2026-10-28). Keep the old jar as fallback.
    _au_ver() { "$JAVA_BIN" -jar "$1" -version 2>/dev/null | sed -n 's/^build.version[[:space:]]*//p' | head -1; }
    mkdir -p "$(dirname "$_AU_JAR")"
    info "Checking for the newest autoupgrade.jar (no auth required) ..."
    if curl -fsSL -m 300 -o "${_AU_JAR}.new" "$AU_DOWNLOAD_URL" 2>&1 | tee -a "$LOG_FILE" \
       && [ -n "$(_au_ver "${_AU_JAR}.new")" ]; then
        _new_v="$(_au_ver "${_AU_JAR}.new")"; _old_v="$( [ -f "$_AU_JAR" ] && _au_ver "$_AU_JAR")"
        if [ -z "$_old_v" ] || [ "$(printf '%s\n%s\n' "$_old_v" "$_new_v" | sort -V | tail -1)" != "$_old_v" ]; then
            [ -f "$_AU_JAR" ] && cp -p "$_AU_JAR" "${_AU_JAR}.${_old_v:-old}"
            mv -f "${_AU_JAR}.new" "$_AU_JAR"
            ok "autoupgrade.jar ${_old_v:+$_old_v -> }$_new_v"
        else
            rm -f "${_AU_JAR}.new"
            ok "autoupgrade.jar up to date: $_old_v"
        fi
        unset _new_v _old_v
    elif [ -f "$_AU_JAR" ]; then
        rm -f "${_AU_JAR}.new"
        warn "Download of the newest autoupgrade.jar failed – using $(_au_ver "$_AU_JAR")"
    else
        rm -f "${_AU_JAR}.new"
        fail "Download failed — check network or download manually:"
        info "  curl -fsSL $AU_DOWNLOAD_URL -o $_AU_JAR"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    "$JAVA_BIN" -jar "$_AU_JAR" -version 2>&1 | head -2 | while IFS= read -r _line; do info "  $_line"; done

    # --- 4b. MOS credentials --------------------------------------------------
    MOS_SEC_FILE="${MOS_SEC_FILE:-$ROOT_DIR/mos_sec.conf.des3}"
    [ -f "$MOS_SEC_FILE" ] \
        && ok "MOS credentials file: $MOS_SEC_FILE" \
        || { fail "MOS credentials not found: $MOS_SEC_FILE"
             info "  Run first: 00-Setup/mos_sec.sh --apply"
             EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

    info "Loading MOS credentials ..."
    unset MOS_USER MOS_PWD
    if ! load_secrets_file "$MOS_SEC_FILE"; then
        fail "Could not decrypt MOS credentials"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    ok "MOS_USER: $MOS_USER"

    # --- 4c. MOS Keystore -----------------------------------------------------
    cat > "$_AU_KEYSTORE_CFG" << KEOF
global.global_log_dir=${DB_AUTOUPGRADE_HOME}/logs
global.keystore=${DB_AUTOUPGRADE_HOME}/keystore
KEOF

    _ks_dir="$DB_AUTOUPGRADE_HOME/keystore"
    _ks_done_flag="$_ks_dir/.mos_configured"

    if [ -f "$_ks_done_flag" ]; then
        ok "MOS keystore already configured — skipping"
        MOS_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        unset MOS_USER MOS_PWD
    else
        _ks_pass="IHateWeblogic-$(hostname -s 2>/dev/null || printf 'oracle')"
        info "Configuring MOS keystore (-load_password) ..."

        if command -v expect >/dev/null 2>&1; then
            export _AU_KS_BIN="$JAVA_BIN" _AU_KS_JAR="$_AU_JAR" _AU_KS_CFG="$_AU_KEYSTORE_CFG"
            export _AU_KS_PASS="$_ks_pass" _AU_MOS_USER="$MOS_USER" _AU_MOS_PWD="$MOS_PWD"
            export _AU_KS_TLS="$AU_TLS"
            _ks_out=$(expect << 'EXPEOF' 2>&1
set timeout 60
spawn $env(_AU_KS_BIN) $env(_AU_KS_TLS) \
      -jar $env(_AU_KS_JAR) -patch -config $env(_AU_KS_CFG) -load_password
expect {
    "Enter password again:" { send "$env(_AU_KS_PASS)\r"; exp_continue }
    "Enter password:"       { send "$env(_AU_KS_PASS)\r"; exp_continue }
    "MOS>"  { }
    timeout { puts "TIMEOUT waiting for MOS> prompt"; exit 1 }
    eof     { puts "EOF before MOS> prompt"; exit 1 }
}
send "add -user $env(_AU_MOS_USER)\r"
expect "Enter your secret/Password:"
send "$env(_AU_MOS_PWD)\r"
expect "Re-enter your secret/Password:"
send "$env(_AU_MOS_PWD)\r"
expect "MOS>"
send "exit\r"
expect -re {YES|NO}
send "YES\r"
expect -re {YES|NO}
send "YES\r"
expect eof
EXPEOF
)
            unset _AU_KS_BIN _AU_KS_JAR _AU_KS_CFG _AU_KS_PASS _AU_MOS_USER _AU_MOS_PWD _AU_KS_TLS
        else
            warn "expect not found — using stdin pipe (install expect for reliability)"
            _ks_out=$(printf '%s\n%s\nadd -user %s\n%s\n%s\nexit\nYES\nYES\n' \
                "$_ks_pass" "$_ks_pass" "$MOS_USER" "$MOS_PWD" "$MOS_PWD" \
                | "$JAVA_BIN" $AU_TLS \
                    -jar "$_AU_JAR" -config "$_AU_KEYSTORE_CFG" -patch -load_password 2>&1)
        fi

        MOS_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        unset MOS_USER MOS_PWD _ks_pass
        printf '%s\n' "$_ks_out" | tee -a "$LOG_FILE"

        if printf '%s\n' "$_ks_out" | grep -qi "Connection Successful"; then
            touch "$_ks_done_flag"
            ok "MOS keystore configured (Connection Successful)"
        elif printf '%s\n' "$_ks_out" | grep -qi "successfully created\|successfully saved"; then
            touch "$_ks_done_flag"
            warn "MOS keystore saved — connection not yet verified (MOS reachable?)"
        else
            warn "MOS keystore setup may have failed — 'Connection Successful' not found"
            warn "  Retry: rm -rf '${_ks_dir}'/* && ./01-db_install_software.sh --apply"
        fi
        unset _ks_out
    fi
    unset _ks_dir _ks_done_flag

    # --- 4d. Patch config (download-only) -------------------------------------
    _target_ru="${DB_TARGET_RU:-RECOMMENDED}"
    case "${_target_ru^^}" in
        # + jdk: current JDK bundle patch of the DB home (not part of RECOMMENDED)
        RECOMMENDED)
            _patch_spec="recommended,jdk" ;;
        19.*CURRENT*|19.*LATEST*)
            warn "DB_TARGET_RU='$_target_ru' is not valid in AutoUpgrade 26.x → using 'recommended'"
            warn "  Update environment_db.conf: DB_TARGET_RU=\"RECOMMENDED\"  (or e.g. 19.30)"
            _patch_spec="recommended,jdk" ;;
        19.*)
            _patch_spec="ru:${_target_ru},ojvm:${_target_ru},opatch,dpbp,jdk" ;;
        *)
            _patch_spec="${_target_ru}" ;;
    esac

    cat > "$_AU_CONFIG" << CFGEOF
# AutoUpgrade patch config – generated by 01-db_install_software.sh
# $(date '+%Y-%m-%d %H:%M:%S')

global.global_log_dir=${DB_AUTOUPGRADE_HOME}/logs
global.keystore=${DB_AUTOUPGRADE_HOME}/keystore

patch1.source_home=${_AU_BASE_STAGE}
patch1.folder=${_AU_PATCHDIR}
patch1.patch=${_patch_spec}
patch1.target_version=19
patch1.download=YES
CFGEOF
    ok "Patch config: $_AU_CONFIG  (spec: $_patch_spec)"
    unset _target_ru _patch_spec

    # --- 4e. AutoUpgrade download -m download ---------------------------------
    printf "\n  Download started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
    "$JAVA_BIN" $AU_TLS \
        -jar "$_AU_JAR" \
        -config "$_AU_CONFIG" \
        -patch -mode download \
        2>&1 | tee -a "$LOG_FILE"
    _dl_rc=${PIPESTATUS[0]}
    printf "\n  Download finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_dl_rc" | tee -a "$LOG_FILE"
    if [ "$_dl_rc" -ne 0 ]; then
        fail "Patch download failed (rc=$_dl_rc)"
        info "  Logs: $DB_AUTOUPGRADE_HOME/logs/"
        info "  Retry: re-run --apply (existing ZIPs are kept)"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    ok "Patch ZIPs downloaded to: $_AU_PATCHDIR"
    unset _dl_rc
fi
unset _existing_zips

# =============================================================================
# 5. Identify patches and update OPatch in staging
# =============================================================================

section "Identify Patches"

# Update OPatch in staging dir so the installer uses the latest OPatch for -applyRU
_opatch_zip=$(ls "$_AU_PATCHDIR"/p6880880_*.zip 2>/dev/null | sort -V | tail -1)
if [ ! -d "$_AU_BASE_STAGE/OPatch" ]; then
    info "No base stage (gold image) – OPatch is updated in the new home"
elif [ -n "$_opatch_zip" ]; then
    info "Updating OPatch in staging dir: $(basename "$_opatch_zip") ..."
    unzip -q -o "$_opatch_zip" -d "$_AU_BASE_STAGE" 2>&1 | tee -a "$LOG_FILE"
    ok "OPatch updated: $(ORACLE_HOME="$_AU_BASE_STAGE" "$_AU_BASE_STAGE/OPatch/opatch" version 2>/dev/null | head -1)"
else
    warn "OPatch ZIP (p6880880_*.zip) not found in patchdir — using bundled OPatch"
    ok "Bundled: $(ORACLE_HOME="$_AU_BASE_STAGE" "$_AU_BASE_STAGE/OPatch/opatch" version 2>/dev/null | head -1)"
fi
unset _opatch_zip

# Extract non-OPatch patch ZIPs to patch_stage and identify RU / OneOffs
rm -rf "$_AU_PATCH_STAGE"
mkdir -p "$_AU_PATCH_STAGE"

for _zip in "$_AU_PATCHDIR"/p[0-9]*.zip; do
    [ -f "$_zip" ] || continue
    case "$_zip" in *p6880880*) continue ;; esac
    info "  Extracting: $(basename "$_zip") ..."
    unzip -q -o "$_zip" -d "$_AU_PATCH_STAGE" 2>&1 | tee -a "$LOG_FILE" \
        || warn "  Extract failed: $(basename "$_zip")"
done

# Identify RU (contains bundle.xml) and OneOffs
_RU_DIR=""
_ONEOFF_LIST=""
for _pd in "$_AU_PATCH_STAGE"/*/; do
    [ -d "$_pd" ] || continue
    if [ -f "${_pd}bundle.xml" ]; then
        _RU_DIR="${_pd%/}"
        ok "$(printf "RU identified  : %s" "$(basename "$_RU_DIR")")"
    else
        _ONEOFF_LIST="${_ONEOFF_LIST:+${_ONEOFF_LIST},}${_pd%/}"
        ok "$(printf "OneOff         : %s" "$(basename "${_pd%/}")")"
    fi
done

# Gold image (AutoUpgrade 26.6 "recommended" for 19.33, live 2026-10-28): a
# complete, already patched home (RU + OCW RU inside) instead of an RU ZIP ->
# unzip it as the new home and run ITS runInstaller with the OneOffs only
_GOLD_ZIP="$(ls -1t "$_AU_PATCHDIR"/db_goldimage_*.zip 2>/dev/null | head -1)"
if [ -z "$_RU_DIR" ] && [ -n "$_GOLD_ZIP" ]; then
    ok "$(printf "Gold image     : %s  (%s)" "$(basename "$_GOLD_ZIP")" "$(du -sh "$_GOLD_ZIP" 2>/dev/null | cut -f1)")"
elif [ -z "$_RU_DIR" ]; then
    fail "No RU patch identified (no bundle.xml found in patch_stage subdirectories)"
    info "  Expected: a patch ZIP that extracts to a dir containing bundle.xml (e.g. RU 19.30)"
    info "  Patchdir: $_AU_PATCHDIR"
    info "  Delete patchdir ZIPs and re-run --apply to trigger fresh download"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

[ -n "$_RU_DIR" ] && ok "$(printf "RU dir         : %s" "$_RU_DIR")"
[ -n "$_ONEOFF_LIST" ] && ok "$(printf "OneOffs        : %s" "$_ONEOFF_LIST")"

# =============================================================================
# 6. Install with runInstaller -applyRU
# =============================================================================

section "runInstaller -applyRU"

if [ -d "$DB_ORACLE_HOME" ] && [ -n "$(ls -A "$DB_ORACLE_HOME" 2>/dev/null)" ]; then
    fail "DB_ORACLE_HOME already exists: $DB_ORACLE_HOME"
    info "  Use --clean --apply to remove it and reinstall"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

mkdir -p "$DB_ORACLE_HOME"
chmod 775 "$DB_ORACLE_HOME"

# /etc/oraInst.loc: canonical inventory pointer (created by 00-root_db_os_baseline.sh).
# The 19c runInstaller reads /etc/oraInst.loc; no -invPtrLoc argument needed.
_inv_target="${ORACLE_INVENTORY:-$(dirname "$ORACLE_BASE")/oraInventory}"
if [ -f "/etc/oraInst.loc" ]; then
    _inv_current="$(grep "^inventory_loc=" /etc/oraInst.loc 2>/dev/null | cut -d= -f2)"
    if [ "$_inv_current" = "$_inv_target" ]; then
        ok "$(printf "/etc/oraInst.loc : inventory_loc=%s" "$_inv_current")"
    else
        warn "$(printf "/etc/oraInst.loc: inventory_loc='%s' expected '%s'" "$_inv_current" "$_inv_target")"
        warn "  Re-run 00-root_db_os_baseline.sh --apply to correct"
    fi
    unset _inv_current
else
    # DB-only server where 00-root_db_os_baseline.sh was not run with --apply
    info "/etc/oraInst.loc not found — creating via sudo"
    mkdir -p "$_inv_target"
    if sudo tee /etc/oraInst.loc > /dev/null << EOF
inventory_loc=${_inv_target}
inst_group=oinstall
EOF
    then
        sudo chmod 644 /etc/oraInst.loc
        ok "Created: /etc/oraInst.loc  (inventory: $_inv_target)"
    else
        fail "Cannot create /etc/oraInst.loc — re-run 00-root_db_os_baseline.sh --apply as root"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
fi
unset _inv_target

# Build -applyRU / -applyOneOffs arguments
_INSTALLER="$_AU_BASE_STAGE/runInstaller"
_ru_args=()
if [ -n "$_RU_DIR" ]; then
    _ru_args=(-applyRU "$_RU_DIR")
else
    # gold image: unpack it as the new home, newest OPatch into it, then its runInstaller
    info "Unpacking gold image into $DB_ORACLE_HOME ..."
    printf "  Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
    unzip -q -o "$_GOLD_ZIP" -d "$DB_ORACLE_HOME" 2>&1 | tee -a "$LOG_FILE"
    [ -x "$DB_ORACLE_HOME/runInstaller" ] \
        || { fail "Gold image unzip failed – no runInstaller in $DB_ORACLE_HOME"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    printf "  Finished: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
    _opatch_zip=$(ls "$_AU_PATCHDIR"/p6880880_*.zip 2>/dev/null | sort -V | tail -1)
    [ -n "$_opatch_zip" ] && unzip -q -o "$_opatch_zip" -d "$DB_ORACLE_HOME" 2>&1 | tee -a "$LOG_FILE"
    ok "Gold image unpacked, $(ORACLE_HOME="$DB_ORACLE_HOME" "$DB_ORACLE_HOME/OPatch/opatch" version 2>/dev/null | head -1)"
    _INSTALLER="$DB_ORACLE_HOME/runInstaller"
    unset _opatch_zip
fi
# -applyOneOffs only with -applyRU: with a gold image runInstaller rejected the
# OJVM RU as "not applicable" (checkComponents not executed, live 2026-10-28) -
# there the OneOffs are applied with opatch after the installation (below)
_POST_ONEOFFS=""
if [ -n "$_RU_DIR" ]; then
    [ -n "$_ONEOFF_LIST" ] && _ru_args+=(-applyOneOffs "$_ONEOFF_LIST")
else
    _POST_ONEOFFS="$_ONEOFF_LIST"
fi
unset _RU_DIR _ONEOFF_LIST _GOLD_ZIP

_edition="${DB_EDITION:-EE}"
# Oracle home name: unique in the central inventory - first install OraDB19Home1,
# an additional home (--target-home) OraDB19Home_<version dir>, e.g. OraDB19Home_19_33_0
if [ -n "$TARGET_HOME_ARG" ]; then
    _home_name="OraDB19Home_$(basename "$(dirname "$DB_ORACLE_HOME")" | tr -c 'A-Za-z0-9\n' '_')"
else
    _home_name="OraDB19Home1"
fi
_inv_xml_n="$(grep "^inventory_loc=" /etc/oraInst.loc 2>/dev/null | cut -d= -f2)/ContentsXML/inventory.xml"
if grep -q "NAME=\"$_home_name\"" "$_inv_xml_n" 2>/dev/null; then
    _home_name="${_home_name}_$(date +%Y%m%d)"
fi
unset _inv_xml_n
info "$(printf "%-28s %s" "Oracle home name:" "$_home_name")"
# CV_ASSUME_DISTID: the 19.3.0 base installer predates OL8/OL9 (MOS Doc ID 2584365.1).
# With -applyRU the RU provides updated makefiles (resolves rc=252 on OL9).
# -ignorePrereqFailure + CV_ASSUME_DISTID together suppress the supportedOSCheck NPE.
_cv_distid="${DB_CV_ASSUME_DISTID:-OEL7.6}"
export CV_ASSUME_DISTID="$_cv_distid"
info "$(printf "%-28s %s  (OL8/OL9 compat)" "CV_ASSUME_DISTID:" "$CV_ASSUME_DISTID")"
info "$(printf "%-28s %s" "Edition:" "$_edition")"
info "$(printf "%-28s %s" "RU args:" "${_ru_args[*]}")"

printf "\n  Install started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

ORACLE_HOME="$DB_ORACLE_HOME" "$_INSTALLER" \
    -silent \
    -ignorePrereqFailure \
    -waitforcompletion \
    "${_ru_args[@]}" \
    "oracle.install.option=INSTALL_DB_SWONLY" \
    "ORACLE_BASE=$ORACLE_BASE" \
    "ORACLE_HOME=$DB_ORACLE_HOME" \
    "ORACLE_HOME_NAME=$_home_name" \
    "oracle.install.db.InstallEdition=$_edition" \
    "oracle.install.db.OSDBA_GROUP=dba" \
    "oracle.install.db.OSOPER_GROUP=oper" \
    "oracle.install.db.OSBACKUPDBA_GROUP=dba" \
    "oracle.install.db.OSDGDBA_GROUP=dba" \
    "oracle.install.db.OSKMDBA_GROUP=dba" \
    "oracle.install.db.OSRACDBA_GROUP=dba" \
    "SECURITY_UPDATES_VIA_MYORACLESUPPORT=false" \
    "DECLINE_SECURITY_UPDATES=true" \
    2>&1 | tee -a "$LOG_FILE"

_install_rc=${PIPESTATUS[0]}
printf "\n  Install finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_install_rc" | tee -a "$LOG_FILE"
unset CV_ASSUME_DISTID
unset _ru_args _cv_distid _edition _home_name _INSTALLER

# Installer log location
_inv_loc_v="$(grep "^inventory_loc=" /etc/oraInst.loc 2>/dev/null | cut -d= -f2)"
_installer_log=$(ls -t "${_inv_loc_v}/logs/InstallActions"*.log 2>/dev/null | head -1)
[ -n "$_installer_log" ] && info "  Installer log: $_installer_log"
unset _inv_loc_v _installer_log

# rc=6 = "Successfully Setup Software with warning(s)" (optional prerequisites,
# e.g. INS-13014 / INS-32056 inventory under ORACLE_BASE) - success (live 2026-10-28)
if [ "$_install_rc" -eq 6 ]; then
    warn "runInstaller rc=6 – software set up with warnings (optional prerequisites, see the installer log)"
    _install_rc=0
fi
if [ "$_install_rc" -ne 0 ]; then
    fail "runInstaller exited with rc=$_install_rc"
    info "  With -applyRU on OL9 and RU >= 19.22, rc=0 is expected."
    info "  rc=252 from the BASE 19.3.0 installer is resolved by -applyRU (OL9 makefiles fixed in RU)."
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
unset _install_rc

ok "runInstaller completed (rc=0)"

# Gold image: OneOffs (OJVM RU, Data Pump bundle, JDK bundle) with opatch into the
# registered home - OPatch "succeeded" is not enough, a SKIPPED patch is a failure
if [ -n "$_POST_ONEOFFS" ]; then
    section "OneOffs with opatch apply (gold image)"
    IFS=',' read -r -a _po <<< "$_POST_ONEOFFS"
    for _pd in "${_po[@]}"; do
        info "opatch apply $(basename "$_pd") ..."
        _out="$(cd "$_pd" && ORACLE_HOME="$DB_ORACLE_HOME" "$DB_ORACLE_HOME/OPatch/opatch" apply -silent -oh "$DB_ORACLE_HOME" 2>&1)"
        printf '%s\n' "$_out" >> "$LOG_FILE"
        if printf '%s\n' "$_out" | grep -q 'OPatch succeeded' \
           && ! printf '%s\n' "$_out" | grep -qiE 'skipped|not applicable|Prerequisite check .* failed'; then
            ok "  $(basename "$_pd") applied"
        else
            fail "  $(basename "$_pd"): $(printf '%s\n' "$_out" | grep -iE 'error|fail|skip|not applicable' | head -1)"
            EXIT_CODE=2
        fi
    done
    unset _po _pd _out
    [ "$EXIT_CODE" -ge 2 ] && { info "  Logs: $DB_ORACLE_HOME/cfgtoollogs/opatch/"; print_summary; exit $EXIT_CODE; }
fi
unset _POST_ONEOFFS

# Cleanup patch staging dir (ZIPs in patchdir are kept for reproducibility)
rm -rf "$_AU_PATCH_STAGE"
ok "Patch staging dir cleaned: $_AU_PATCH_STAGE"

# =============================================================================
# 7. root.sh (requires root)
# =============================================================================

section "root.sh (requires root)"

# root.sh must run AFTER the installer completes (sets SUID on oracle binary).
_root_sh="$DB_ORACLE_HOME/root.sh"
if sudo -n "$_root_sh" 2>/dev/null; then
    ok "root.sh executed via sudo"
else
    printf "\n"
    printf "  \033[33m┌──────────────────────────────────────────────────────────────┐\033[0m\n"
    printf "  \033[33m│  Run as root NOW (open a second terminal):                   │\033[0m\n"
    printf "  \033[33m│                                                              │\033[0m\n"
    printf "  \033[33m│  %-62s│\033[0m\n" "$_root_sh"
    printf "  \033[33m└──────────────────────────────────────────────────────────────┘\033[0m\n"
    printf "\n"
    if askYesNo "Press Enter / type 'yes' after root.sh has completed" "y"; then
        ok "root.sh confirmed completed"
    else
        warn "root.sh not confirmed — run it before creating the database"
        EXIT_CODE=1
    fi
fi
unset _root_sh

# =============================================================================
# 8. Disable unused options (chopt)
# =============================================================================

section "Disable Unused Options (chopt)"

for _opt in olap rat; do
    info "Disabling option: $_opt ..."
    ORACLE_HOME="$DB_ORACLE_HOME" \
        "$DB_ORACLE_HOME/bin/chopt" disable "$_opt" 2>&1 | tee -a "$LOG_FILE"
    _chopt_rc=${PIPESTATUS[0]}
    [ "$_chopt_rc" -eq 0 ] \
        && ok "$(printf "chopt disable %-8s  OK" "$_opt")" \
        || warn "$(printf "chopt disable %-8s  rc=%s (may already be disabled)" "$_opt" "$_chopt_rc")"
    unset _chopt_rc
done
unset _opt

# =============================================================================
# 9. Verification
# =============================================================================

section "Verification"

[ -x "$DB_ORACLE_HOME/bin/sqlplus" ] \
    && ok "sqlplus: $DB_ORACLE_HOME/bin/sqlplus" \
    || { fail "sqlplus not found — check installer log"; EXIT_CODE=1; }

if [ -x "$DB_ORACLE_HOME/OPatch/opatch" ]; then
    info "Installed patches:"
    ORACLE_HOME="$DB_ORACLE_HOME" \
        "$DB_ORACLE_HOME/OPatch/opatch" lspatches 2>/dev/null \
        | head -10 | while IFS= read -r _line; do info "  $_line"; done
    info "OPatch version:"
    ORACLE_HOME="$DB_ORACLE_HOME" \
        "$DB_ORACLE_HOME/OPatch/opatch" version 2>/dev/null \
        | head -1 | while IFS= read -r _line; do info "  $_line"; done
fi

printf "\n" | tee -a "$LOG_FILE"
if [ -n "$TARGET_HOME_ARG" ]; then
    info "Next step: move the database into the new home (datapatch)"
    info "  09-db_patch_rcu.sh --new-home $DB_ORACLE_HOME          (dry-run first)"
else
    info "Next step: configure the listener"
    info "  04-db_setup_listener.sh --apply"
fi

# =============================================================================
print_summary
exit $EXIT_CODE
