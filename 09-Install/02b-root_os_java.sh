#!/bin/bash
# =============================================================================
# Script   : 02b-root_os_java.sh
# Purpose  : Phase 0 – Java installation for Oracle FMW 14.1.2
#            Installs Oracle JDK 21 (primary, for WebLogic) from PATCH_STORAGE
#            and optionally OpenJDK in parallel via dnf.
#            Registers Oracle JDK with alternatives (does NOT change system default).
#            Verifies jps symlink and prints SecureRandom reminder.
# Call     : ./09-Install/02b-root_os_java.sh
#            ./09-Install/02b-root_os_java.sh --apply
# Options  : --apply          Install JDK, create symlink, register alternatives
#            --skip-oracle    Skip Oracle JDK installation check
#            --with-openjdk   Also install OpenJDK via dnf (optional, parallel)
#            --upgrade-jdk    Below JDK_VERSION_MIN: install Oracle's CDN 'latest'
#                             JDK 21 next to the old one, repoint JDK_HOME
#            --help           Show usage
# Requires : tar or dnf, alternatives
# Runs as  : root or oracle with sudo
# NOTE     : Oracle JDK is license-free when used exclusively with Oracle products
#            (WebLogic, Forms, Reports) – see Doc ID 1557737.1.
#            WebLogic JAVA_HOME must always point to Oracle JDK, not OpenJDK.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/01-root_setup_java.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m IHateWeblogic_lib.sh not found: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"
init_log

# =============================================================================
# Arguments
# =============================================================================

APPLY_MODE=0
SKIP_ORACLE=0
WITH_OPENJDK=0
UPGRADE_JDK=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-22s %s\n" "--apply"         "Install JDK, create symlink, register alternatives"
    printf "  %-22s %s\n" "--skip-oracle"   "Skip Oracle JDK install (already done)"
    printf "  %-22s %s\n" "--with-openjdk"  "Also install OpenJDK 21 via dnf (optional, parallel)"
    printf "  %-22s %s\n" "--upgrade-jdk"   "If below JDK_VERSION_MIN: get Oracle's 'latest' JDK 21 from the CDN,"
    printf "  %-22s %s\n" ""                "install it next to the old one and repoint JDK_HOME (needs --apply)"
    printf "  %-22s %s\n" "--help"          "Show this help"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)        APPLY_MODE=1;   shift ;;
        --skip-oracle)  SKIP_ORACLE=1;  shift ;;
        --with-openjdk) WITH_OPENJDK=1; shift ;;
        --upgrade-jdk)  UPGRADE_JDK=1;  shift ;;
        --help|-h)      _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Root / sudo helpers
# =============================================================================

_can_sudo() { sudo -n true 2>/dev/null; }

_run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif _can_sudo; then
        sudo "$@"
    else
        warn "No root/sudo for: $*"
        info "  Run manually: sudo $*"
        return 1
    fi
}

_check_root_access() {
    if [ "$(id -u)" -eq 0 ]; then
        ok "Running as root"
    elif _can_sudo; then
        ok "Running as $(id -un) with sudo"
    else
        fail "Root or sudo access required"
        print_summary; exit 2
    fi
}

# Extract a JDK tar.gz to JDK_PARENT and create a stable JDK_HOME symlink.
# Usage: _install_jdk_tar <tar_path>
# Returns 0 on success, 1 on failure (fail() already called).
_install_jdk_tar() {
    local TAR_PATH="$1"
    _run_root mkdir -p "$JDK_PARENT" || return 1
    _run_root tar xf "$TAR_PATH" -C "$JDK_PARENT" || { fail "tar extraction failed: $TAR_PATH"; return 1; }
    local EXTRACTED
    EXTRACTED="$(tar tf "$TAR_PATH" 2>/dev/null | head -1 | cut -d/ -f1)"
    local EXTRACTED_PATH="$JDK_PARENT/$EXTRACTED"
    if [ -d "$EXTRACTED_PATH" ] && [ "$EXTRACTED_PATH" != "$JDK_HOME" ]; then
        info "  Extracted: $EXTRACTED_PATH"
        _run_root ln -sfn "$EXTRACTED_PATH" "$JDK_HOME"
        ok "Symlink created: $JDK_HOME → $EXTRACTED_PATH"
    elif [ -d "$JDK_HOME" ]; then
        ok "JDK directory already at target path: $JDK_HOME"
    fi
    if [ -x "$JDK_HOME/bin/java" ]; then
        ok "JDK installed: $("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
        return 0
    else
        fail "Extraction completed but $JDK_HOME/bin/java not executable"
        return 1
    fi
}

# Upgrade the JDK at JDK_HOME to Oracle's current public JDK 21 ("latest" CDN link).
# The new JDK is extracted NEXT TO the old one and the JDK_HOME symlink is
# repointed – the old directory stays as rollback (ln -sfn <old dir> JDK_HOME).
# Usage: _upgrade_jdk_latest <min_version>
_upgrade_jdk_latest() {
    local min="$1"
    local url="https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.tar.gz"
    local dl_dir="${PATCH_STORAGE:-/tmp}/jdk"
    local dl_tar="$dl_dir/jdk-21_linux-x64_bin.tar.gz"
    local new_ver sha_remote sha_local final_tar pids

    section "JDK Upgrade (Oracle CDN latest JDK 21)"
    info "  Source: $url"

    # Peek at the version on the CDN (streams only the first tar entry)
    new_ver="$(curl -sL --max-time 60 "$url" 2>/dev/null | tar tzf - 2>/dev/null | head -1 | cut -d/ -f1 | sed 's/^jdk-//')"
    if [ -z "$new_ver" ]; then
        fail "Cannot determine the JDK version offered at $url (no internet access?)"
        return 1
    fi
    if [ "$(printf '%s\n%s\n' "$new_ver" "$min" | sort -V | head -1)" != "$min" ]; then
        fail "CDN 'latest' offers $new_ver – still below the minimum $min"
        info "  Get the required update from MOS instead (see JDK_PATCH_NR in oracle_software_version.conf)"
        return 1
    fi
    ok "CDN 'latest' offers JDK $new_ver (>= $min)"

    if [ "$APPLY_MODE" -ne 1 ]; then
        info "  Dry-run: would download to $dl_dir, verify SHA-256, extract next to the"
        info "  current JDK and repoint $JDK_HOME → $(dirname "$JDK_HOME")/jdk-$new_ver"
        return 0
    fi

    # Never swap the JDK under a running JVM (WebLogic, NodeManager, tools)
    pids="$(pgrep -f "$(readlink -f "$JDK_HOME")/bin/java|$JDK_HOME/bin/java" 2>/dev/null | tr '\n' ' ')"
    if [ -n "$pids" ]; then
        fail "Java processes still run from $JDK_HOME (PID $pids) – stop them first (01-Run/startStop.sh stop-all --apply)"
        return 1
    fi

    mkdir -p "$dl_dir" || { fail "Cannot create $dl_dir"; return 1; }
    info "  Downloading (about 200 MB) ..."
    if ! curl -L --fail --max-time 900 --silent --show-error -o "$dl_tar" "$url"; then
        fail "Download failed: $url"
        rm -f "$dl_tar"
        return 1
    fi
    sha_remote="$(curl -L --fail --max-time 30 --silent "$url.sha256" | awk '{print $1}')"
    sha_local="$(sha256sum "$dl_tar" | awk '{print $1}')"
    if [ -z "$sha_remote" ] || [ "$sha_remote" != "$sha_local" ]; then
        fail "SHA-256 mismatch or not retrievable (remote: ${sha_remote:-none}, local: $sha_local)"
        rm -f "$dl_tar"
        return 1
    fi
    ok "SHA-256 verified: $sha_local"

    # Keep the tarball under a versioned name – also used by fresh installs
    final_tar="$dl_dir/jdk-${new_ver}_linux-x64_bin.tar.gz"
    mv -f "$dl_tar" "$final_tar" && ok "Stored: $final_tar"

    local old_target
    old_target="$(readlink -f "$JDK_HOME")"
    _install_jdk_tar "$final_tar" || return 1
    ok "JDK upgraded: $JDK_HOME → $(readlink -f "$JDK_HOME")"
    info "  Rollback: ln -sfn $old_target $JDK_HOME   (old JDK kept)"
    info "  SecureRandom check below runs against the new java.security"
    return 0
}

# =============================================================================
# Banner
# =============================================================================

JDK_HOME="${JDK_HOME:-/u01/app/oracle/java/jdk-21}"
JDK_PARENT="$(dirname "$JDK_HOME")"

printLine
section "Java Installation – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:"          "$(hostname -f 2>/dev/null || hostname)" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "JDK_HOME:"      "$JDK_HOME" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "PATCH_STORAGE:" "${PATCH_STORAGE:-(not set)}" \
    | tee -a "${LOG_FILE:-/dev/null}"
[ "$APPLY_MODE"   -eq 1 ] && printf "  %-26s %s\n" "Mode:" "APPLY" \
    | tee -a "${LOG_FILE:-/dev/null}"
[ "$WITH_OPENJDK" -eq 1 ] && printf "  %-26s %s\n" "OpenJDK:" "will also install" \
    | tee -a "${LOG_FILE:-/dev/null}"
printLine

info "License note: Oracle JDK is free when used exclusively for Oracle products"
info "  (WebLogic, Forms, Reports) – Doc ID 1557737.1"
info "  For WebLogic: always use Oracle JDK as JAVA_HOME, not OpenJDK."

_check_root_access

# =============================================================================
# 1. Oracle JDK 21 (primary – for WebLogic)
# =============================================================================

section "Oracle JDK 21 (primary for WebLogic)"

if [ "$SKIP_ORACLE" -eq 1 ]; then
    info "Oracle JDK check skipped (--skip-oracle)"
else
    # --- Check if already installed ---
    if [ -x "$JDK_HOME/bin/java" ]; then
        JDK_VERSION="$("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
        ok "Oracle JDK found at JDK_HOME: $JDK_VERSION"

        if printf "%s" "$JDK_VERSION" | grep -q '"21\.'; then
            ok "Version 21 confirmed (required for FMW 14.1.2)"
        else
            warn "JDK at $JDK_HOME is not version 21: $JDK_VERSION"
            info "  FMW 14.1.2 requires Oracle JDK 21"
        fi

        # Minimum update level of the current patch cycle (oracle_software_version.conf)
        _ver_conf="$SCRIPT_DIR/oracle_software_version.conf"
        _jdk_min="$(sed -n 's/^JDK_VERSION_MIN="\([^"]*\)".*/\1/p' "$_ver_conf" 2>/dev/null | head -1)"
        _jdk_patch="$(sed -n 's/^JDK_PATCH_NR="\([^"]*\)".*/\1/p' "$_ver_conf" 2>/dev/null | head -1)"
        _jdk_cur="$(printf "%s" "$JDK_VERSION" | sed -n 's/.*version "\([^"]*\)".*/\1/p')"
        if [ -n "$_jdk_min" ] && [ -n "$_jdk_cur" ]; then
            if [ "$(printf '%s\n%s\n' "$_jdk_cur" "$_jdk_min" | sort -V | head -1)" = "$_jdk_min" ]; then
                ok "JDK $_jdk_cur meets the patch-cycle minimum $_jdk_min"
            else
                warn "JDK $_jdk_cur is below the patch-cycle minimum $_jdk_min (Patch ${_jdk_patch:-see KA1182})"
                if [ "$UPGRADE_JDK" -eq 1 ]; then
                    _upgrade_jdk_latest "$_jdk_min"
                else
                    info "  Automatic: re-run with --apply --upgrade-jdk (Oracle CDN 'latest' JDK 21)"
                    info "  Manual   : extract the new JDK next to the old one, repoint the symlink:"
                    info "    tar xzf <jdk-21.x_linux-x64_bin.tar.gz> -C $(dirname "$JDK_HOME")"
                    info "    ln -sfn $(dirname "$JDK_HOME")/<extracted jdk-21.x dir> $JDK_HOME"
                fi
            fi
        fi
        unset _ver_conf _jdk_min _jdk_patch _jdk_cur

        # Verify it is Oracle JDK (not OpenJDK)
        if "$JDK_HOME/bin/java" -version 2>&1 | grep -qi 'openjdk'; then
            warn "JDK at JDK_HOME appears to be OpenJDK – WebLogic support requires Oracle JDK"
            info "  See: Oracle Support Doc ID 1557737.1"
        else
            ok "JDK vendor: Oracle JDK (not OpenJDK)"
        fi

    else
        fail "Oracle JDK not found at JDK_HOME: $JDK_HOME"
        info "  Download JDK 21 from: https://www.oracle.com/java/technologies/downloads/"

        # --- Search PATCH_STORAGE for installer ---
        JDK_TAR=""
        JDK_RPM=""
        if [ -n "${PATCH_STORAGE:-}" ] && [ -d "$PATCH_STORAGE" ]; then
            JDK_TAR="$(find "$PATCH_STORAGE" -maxdepth 3 -name "jdk-21*.tar.gz" 2>/dev/null | sort | tail -1)"
            JDK_RPM="$(find "$PATCH_STORAGE" -maxdepth 3 -name "jdk-21*.rpm"    2>/dev/null | sort | tail -1)"
        fi

        if [ -n "$JDK_TAR" ]; then
            info "  Installer found (tar.gz): $JDK_TAR"
            if [ "$APPLY_MODE" -eq 1 ]; then
                if askYesNo "Extract $JDK_TAR to $JDK_PARENT?" "y"; then
                    _run_root mkdir -p "$JDK_PARENT"
                    _run_root tar xf "$JDK_TAR" -C "$JDK_PARENT"
                    # Find extracted directory name
                    EXTRACTED="$(tar tf "$JDK_TAR" 2>/dev/null | head -1 | cut -d/ -f1)"
                    EXTRACTED_PATH="$JDK_PARENT/$EXTRACTED"
                    # Create stable symlink jdk-21 → jdk-21.0.x
                    if [ -d "$EXTRACTED_PATH" ] && [ "$EXTRACTED_PATH" != "$JDK_HOME" ]; then
                        info "  Extracted: $EXTRACTED_PATH"
                        _run_root ln -sfn "$EXTRACTED_PATH" "$JDK_HOME"
                        ok "Symlink created: $JDK_HOME → $EXTRACTED_PATH"
                    elif [ -d "$JDK_HOME" ]; then
                        ok "JDK directory already at target path: $JDK_HOME"
                    fi
                    if [ -x "$JDK_HOME/bin/java" ]; then
                        ok "JDK installed: $("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
                    else
                        fail "Extraction completed but $JDK_HOME/bin/java not executable"
                    fi
                fi
            else
                info "  Run with --apply to extract"
                info "  Manual:"
                info "    mkdir -p $JDK_PARENT"
                info "    tar xf $JDK_TAR -C $JDK_PARENT"
                info "    ln -s $JDK_PARENT/jdk-21.0.x $JDK_HOME"
            fi

        elif [ -n "$JDK_RPM" ]; then
            info "  Installer found (RPM): $JDK_RPM"
            if [ "$APPLY_MODE" -eq 1 ]; then
                if askYesNo "Install $JDK_RPM?" "y"; then
                    _run_root dnf install -y --nogpgcheck "$JDK_RPM"
                    ok "Oracle JDK RPM installed (symlink /usr/java/latest created by RPM)"
                    # Create symlink at JDK_HOME if RPM installed elsewhere
                    RPM_JAVA="$(rpm -ql "$(rpm -qp --qf '%{NAME}' "$JDK_RPM" 2>/dev/null)" 2>/dev/null \
                        | grep '/bin/java$' | head -1 | sed 's|/bin/java||')"
                    if [ -n "$RPM_JAVA" ] && [ "$RPM_JAVA" != "$JDK_HOME" ]; then
                        _run_root mkdir -p "$JDK_PARENT"
                        _run_root ln -sfn "$RPM_JAVA" "$JDK_HOME"
                        ok "Symlink created: $JDK_HOME → $RPM_JAVA"
                    fi
                fi
            else
                info "  Run with --apply to install RPM"
                info "  Manual: dnf install --nogpgcheck $JDK_RPM"
            fi

        else
            # --- Fallback 1: search /tmp for pre-placed installer ---
            JDK_TMP_TAR="$(find /tmp -maxdepth 1 -name "jdk-21*linux-x64*.tar.gz" \
                2>/dev/null | sort | tail -1)"
            if [ -n "$JDK_TMP_TAR" ]; then
                info "  Installer found in /tmp: $JDK_TMP_TAR"
                # SHA256 check is read-only – always verify, regardless of --apply
                JDK_SHA_URL="https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.tar.gz.sha256"
                info "  Verifying SHA256 checksum ..."
                SHA256_REMOTE="$(curl -L --fail --max-time 30 --silent \
                    "$JDK_SHA_URL" | awk '{print $1}')"
                SHA256_OK=0
                if [ -z "$SHA256_REMOTE" ]; then
                    warn "Could not retrieve SHA256 from Oracle CDN – skipping checksum check"
                    info "  (no internet access? checksum not verified)"
                    SHA256_OK=1  # proceed anyway – user pre-placed the file
                else
                    SHA256_LOCAL="$(sha256sum "$JDK_TMP_TAR" | awk '{print $1}')"
                    if [ "$SHA256_LOCAL" = "$SHA256_REMOTE" ]; then
                        ok "SHA256 verified: $SHA256_LOCAL"
                        SHA256_OK=1
                    else
                        fail "SHA256 MISMATCH – file corrupt or wrong version"
                        info "  Expected: $SHA256_REMOTE"
                        info "  Got:      $SHA256_LOCAL"
                        info "  Remove and replace: rm $JDK_TMP_TAR"
                    fi
                fi
                if [ "$SHA256_OK" -eq 1 ]; then
                    if [ "$APPLY_MODE" -eq 1 ]; then
                        if askYesNo "Extract $JDK_TMP_TAR to $JDK_PARENT?" "y"; then
                            _install_jdk_tar "$JDK_TMP_TAR"
                        fi
                    else
                        info "  Run with --apply to extract"
                        info "  Manual:"
                        info "    mkdir -p $JDK_PARENT"
                        info "    tar xf $JDK_TMP_TAR -C $JDK_PARENT"
                        info "    ln -s $JDK_PARENT/jdk-21.0.x $JDK_HOME"
                    fi
                fi
            else
                # --- Fallback 2: download from Oracle CDN ---
                JDK_CDN_URL="https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.tar.gz"
                JDK_SHA_URL="https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.tar.gz.sha256"
                JDK_DL_TARGET="/tmp/jdk-21_linux-x64_bin.tar.gz"

                info "  No JDK 21 installer found in PATCH_STORAGE (${PATCH_STORAGE:-(not set)}) or /tmp"
                info "  Options:"
                info "    A) Copy installer manually:  scp jdk-21*linux-x64*.tar.gz root@$(hostname -s):/tmp/"
                info "    B) Download from Oracle CDN: $JDK_CDN_URL"
                # Download is read-only (file lands in /tmp only) – no --apply required.
                # Extraction is gated behind --apply (handled on next run via Fallback 1).
                if askYesNo "Download Oracle JDK 21 from Oracle CDN to /tmp? (requires internet access)" "n"; then
                    info "  Downloading: $JDK_CDN_URL"
                    if ! curl -L --fail --max-time 300 --progress-bar \
                            -o "$JDK_DL_TARGET" "$JDK_CDN_URL"; then
                        fail "Download failed – no internet access or URL changed"
                        info "  Manual copy: scp jdk-21_linux-x64_bin.tar.gz root@$(hostname -s):/tmp/"
                        info "  Then re-run: $0 --apply"
                    else
                        ok "Download complete: $JDK_DL_TARGET"
                        # SHA256 verification – Oracle publishes checksum at .sha256 URL
                        info "  Verifying SHA256 checksum ..."
                        SHA256_REMOTE="$(curl -L --fail --max-time 30 --silent \
                            "$JDK_SHA_URL" | awk '{print $1}')"
                        if [ -z "$SHA256_REMOTE" ]; then
                            fail "Could not retrieve SHA256 from Oracle CDN – aborting"
                            rm -f "$JDK_DL_TARGET"
                            info "  Partial download removed. Re-run to retry."
                        else
                            SHA256_LOCAL="$(sha256sum "$JDK_DL_TARGET" | awk '{print $1}')"
                            if [ "$SHA256_LOCAL" = "$SHA256_REMOTE" ]; then
                                ok "SHA256 verified: $SHA256_LOCAL"
                                if [ "$APPLY_MODE" -eq 1 ]; then
                                    _install_jdk_tar "$JDK_DL_TARGET"
                                else
                                    ok "Installer ready in /tmp – re-run with --apply to extract"
                                fi
                            else
                                fail "SHA256 MISMATCH – download corrupt or tampered"
                                info "  Expected: $SHA256_REMOTE"
                                info "  Got:      $SHA256_LOCAL"
                                rm -f "$JDK_DL_TARGET"
                                info "  Corrupt file removed. Re-run to retry download."
                            fi
                        fi
                    fi
                else
                    info "  Download skipped."
                    info "  Copy installer to /tmp and re-run:"
                    info "    scp jdk-21_linux-x64_bin.tar.gz root@$(hostname -s):/tmp/"
                    info "    $0 --apply"
                fi
            fi
        fi
    fi

    # --- Register with alternatives (without changing system default) ---
    if [ -x "$JDK_HOME/bin/java" ]; then
        section "alternatives – Register Oracle JDK"
        if /usr/sbin/alternatives --display java 2>/dev/null | grep -q "$JDK_HOME"; then
            ok "Oracle JDK already registered with alternatives"
        else
            info "Oracle JDK not yet registered with alternatives"
            if [ "$APPLY_MODE" -eq 1 ]; then
                _run_root /usr/sbin/alternatives --install /usr/bin/java java \
                    "$JDK_HOME/bin/java" 21000
                ok "Registered with alternatives (priority 21000, NOT set as system default)"
                info "  To change system default: /usr/sbin/alternatives --config java"
            else
                info "  Register: /usr/sbin/alternatives --install /usr/bin/java java $JDK_HOME/bin/java 21000"
            fi
        fi
        printf "  %-26s\n" "Current alternatives state:" | tee -a "${LOG_FILE:-/dev/null}"
        /usr/sbin/alternatives --display java 2>/dev/null \
            | grep -E 'link|slave|priority|status' \
            | sed 's/^/    /' | tee -a "${LOG_FILE:-/dev/null}"
    fi
fi

# =============================================================================
# 2. OpenJDK (optional, parallel – NOT for WebLogic)
# =============================================================================

section "OpenJDK (optional parallel installation)"

OPENJDK_PKG="java-21-openjdk"
if rpm -q "$OPENJDK_PKG" > /dev/null 2>&1; then
    OPENJDK_VER="$(rpm -q --qf '%{VERSION}' "$OPENJDK_PKG" 2>/dev/null)"
    ok "OpenJDK installed: $OPENJDK_PKG-$OPENJDK_VER"
    info "  Note: WebLogic JAVA_HOME must NOT point to OpenJDK – use Oracle JDK"
else
    info "OpenJDK not installed (not required for WebLogic)"
    if [ "$WITH_OPENJDK" -eq 1 ]; then
        if [ "$APPLY_MODE" -eq 1 ]; then
            if askYesNo "Install $OPENJDK_PKG via dnf?" "y"; then
                _run_root dnf install -y java-21-openjdk java-21-openjdk-devel
                ok "OpenJDK installed (for parallel use only – not WebLogic JAVA_HOME)"
            fi
        else
            info "  Install: dnf install java-21-openjdk java-21-openjdk-devel"
        fi
    else
        info "  To install in parallel: re-run with --with-openjdk --apply"
    fi
fi

# =============================================================================
# 3. jps – Java Process Status Tool
# =============================================================================

section "jps – Java Process Status Tool"

JPS_TARGET="${JDK_HOME}/bin/jps"
JPS_LINK="/usr/bin/jps"

if [ ! -x "$JPS_TARGET" ]; then
    if [ "$SKIP_ORACLE" -eq 0 ]; then
        warn "jps not found at $JPS_TARGET – Oracle JDK may not be installed yet"
    else
        info "jps check skipped (--skip-oracle)"
    fi
else
    if [ -x "$JPS_LINK" ]; then
        # JDK_HOME is usually itself a symlink (jdk-21 → jdk-21.0.x), so compare
        # the fully resolved paths of both sides.
        CURRENT_JPS="$(readlink -f "$JPS_LINK" 2>/dev/null)"
        if [ "$CURRENT_JPS" = "$(readlink -f "$JPS_TARGET" 2>/dev/null)" ]; then
            ok "jps correctly linked: $JPS_LINK → $JPS_TARGET"
            if [ "$(readlink "$JPS_LINK" 2>/dev/null)" != "$JPS_TARGET" ]; then
                info "  Link uses the versioned path $(readlink "$JPS_LINK") – prefer $JPS_TARGET"
                info "  so it follows future JDK updates of the ${JDK_HOME} symlink"
            fi
        else
            warn "jps points to wrong JDK: $CURRENT_JPS"
            info "  Expected:  $JPS_TARGET"
            if [ "$APPLY_MODE" -eq 1 ]; then
                if askYesNo "Re-link jps to Oracle JDK?" "y"; then
                    _run_root rm -f "$JPS_LINK"
                    _run_root ln -s "$JPS_TARGET" "$JPS_LINK"
                    ok "jps re-linked to Oracle JDK"
                fi
            else
                info "  Fix: rm $JPS_LINK && ln -s $JPS_TARGET $JPS_LINK"
            fi
        fi
    else
        warn "jps not found at $JPS_LINK"
        if [ "$APPLY_MODE" -eq 1 ]; then
            if askYesNo "Create jps symlink at $JPS_LINK?" "y"; then
                _run_root ln -s "$JPS_TARGET" "$JPS_LINK"
                ok "jps symlink created: $JPS_LINK → $JPS_TARGET"
            fi
        else
            info "  Create: ln -s $JPS_TARGET $JPS_LINK"
        fi
    fi

    # Quick functional test
    if [ -x "$JPS_LINK" ]; then
        if jps -l > /dev/null 2>&1; then
            ok "jps -l works ($(jps -l 2>/dev/null | wc -l) JVM processes visible)"
        else
            warn "jps -l returned an error"
        fi
    fi
fi

# =============================================================================
# 4. Old Java versions
# =============================================================================

section "Installed Java Versions"

printf "  Installed java/jdk packages:\n" | tee -a "${LOG_FILE:-/dev/null}"
rpm -qa --qf "    %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n" 2>/dev/null \
    | grep -iE 'java|jdk' | sort | tee -a "${LOG_FILE:-/dev/null}" || true

OLD_JAVA="$(rpm -qa --qf "%{NAME}\n" 2>/dev/null \
    | grep -iE '^java-(1\.|8|11|17)-' | head -5 || true)"
if [ -n "$OLD_JAVA" ]; then
    warn "Old Java version(s) installed – consider removing:"
    printf "%s\n" "$OLD_JAVA" | sed 's/^/    /' | tee -a "${LOG_FILE:-/dev/null}"
    info "  Remove: dnf erase <package-name>"
else
    ok "No old Java versions found (< 21)"
fi

# =============================================================================
# 5. SecureRandom reminder
# =============================================================================

section "SecureRandom – WebLogic Startup Speed"

JAVA_SEC_FILE=""
if [ -x "$JDK_HOME/bin/java" ]; then
    # JDK 11+: conf/security/java.security  |  JDK 8: jre/lib/security/java.security
    if [ -f "$JDK_HOME/conf/security/java.security" ]; then
        JAVA_SEC_FILE="$JDK_HOME/conf/security/java.security"
    elif [ -f "$JDK_HOME/jre/lib/security/java.security" ]; then
        JAVA_SEC_FILE="$JDK_HOME/jre/lib/security/java.security"
    fi
fi

if [ -n "$JAVA_SEC_FILE" ]; then
    SR_VAL="$(grep '^securerandom.source=' "$JAVA_SEC_FILE" 2>/dev/null | head -1)"
    printf "  %-26s %s\n" "java.security:" "$JAVA_SEC_FILE" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "securerandom.source:" "${SR_VAL:-(not set)}" | tee -a "${LOG_FILE:-/dev/null}"
    if printf "%s" "${SR_VAL:-}" | grep -q 'file:/dev/random$'; then
        warn "securerandom.source=file:/dev/random – blocking entropy source slows WLS startup"
        info "  Required: file:/dev/./urandom  (non-blocking; /dev/./urandom bypasses JVM path check)"
        if [ "$APPLY_MODE" -eq 1 ]; then
            if askYesNo "Fix securerandom.source in $JAVA_SEC_FILE?" "y"; then
                # The JDK tree is root-owned – backup_file (runs as the calling
                # user) cannot write there, so copy via _run_root.
                SR_BACKUP="${JAVA_SEC_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
                if _run_root cp -p "$JAVA_SEC_FILE" "$SR_BACKUP"; then
                    ok "Backup created: $SR_BACKUP"
                    _run_root sed -i \
                        's|^securerandom\.source=.*|securerandom.source=file:/dev/./urandom|' \
                        "$JAVA_SEC_FILE"
                    SR_AFTER="$(grep '^securerandom.source=' "$JAVA_SEC_FILE" 2>/dev/null | head -1)"
                    if [ "$SR_AFTER" = "securerandom.source=file:/dev/./urandom" ]; then
                        ok "Fixed: $SR_AFTER"
                    else
                        fail "securerandom.source not changed: ${SR_AFTER:-(not set)}"
                    fi
                else
                    fail "Backup of $JAVA_SEC_FILE failed – not modified"
                fi
                unset SR_BACKUP
            fi
        else
            info "  Fix: re-run with --apply, or: 02-Checks/weblogic_performance.sh --apply"
        fi
    elif printf "%s" "${SR_VAL:-}" | grep -qE 'urandom|/dev/\./'; then
        ok "securerandom.source uses non-blocking source – WebLogic startup not affected"
    else
        warn "securerandom.source not set or unrecognised – check java.security"
        info "  Fix: re-run with --apply, or: 02-Checks/weblogic_performance.sh --apply"
    fi
else
    if [ -x "$JDK_HOME/bin/java" ]; then
        warn "java.security file not found under $JDK_HOME"
    else
        info "SecureRandom check skipped – JDK not yet installed"
    fi
    info "  After JDK install: run 02-Checks/weblogic_performance.sh to check and fix"
fi

# =============================================================================
# Summary
# =============================================================================

printLine
if [ -x "$JDK_HOME/bin/java" ]; then
    info "Oracle JDK ready – next step: 03-root_user_oracle.sh"
    info "  (sets JAVA_HOME=$JDK_HOME in oracle .bash_profile)"
else
    info "Install Oracle JDK 21, then re-run with --apply"
fi
if [ "$CNT_WARN" -gt 0 ] || [ "$CNT_FAIL" -gt 0 ]; then
    info "After resolving issues: run 02-Checks/weblogic_performance.sh --apply"
fi

print_summary
exit "$EXIT_CODE"
